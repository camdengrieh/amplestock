// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

/// @title SpokeTwapDumpThenBondTest
/// @notice The plan's named attack **spoke-TWAP dump then bond**, whose stated bound is that "gains are capped at
///         removing the attacker's own discount by `q_floor`".
///
///         The attack is to walk a spoke's AMPS/stock price down - making AMPS look cheap in stock terms - and
///         then bond that stock, hoping the depressed pool price feeds the bond quote and buys more AMPS per unit
///         of collateral. It fails at the root: `AmpsBonds` prices a bond from the vault's **NAV checkpoint** and
///         the collateral's **Chainlink answer**, and caps the result at `q_floor`, which is a NAV quantity. No
///         pool price enters the quote at all, so the dump buys nothing and costs the sell fee.
contract SpokeTwapDumpThenBondTest is Phase3Fixture {
    address internal constant ATTACKER = address(0xA77ACC);

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(100_000e6);
        deepenSpokes(400e18);
        seedSpokeBids(0);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        settleTwap();
    }

    /// @notice The dump moves the spoke and its TWAP, and buys exactly nothing at the bond window.
    function test_dumpingASpokeDoesNotImproveItsBondQuote() public {
        PoolId spoke = spokePools[0];
        uint256 collateral = 1e18;

        // What the market pays before anybody touches anything.
        uint256 snapshot = vm.snapshotState();
        (uint256 honest,) = bondAs(ATTACKER, 0, collateral);
        vm.revertToState(snapshot);

        // Walk the spoke down hard and let the truncated TWAP follow it.
        giveShares(ATTACKER, 400e18);
        int24 before = tickOf(spoke);
        slide(spoke, ATTACKER, 8e18, before - 3000, 120, 45);
        settleTwap();
        assertLt(tickOf(spoke), before, "the spoke really was walked down");
        assertLt(hook.twapTick30m(spoke), before, "and its truncated TWAP followed");

        (uint256 gamed,) = bondAs(ATTACKER, 0, collateral);
        console.log("bond AMPS honest", honest, "after the dump", gamed);
        assertLe(gamed, honest, "the manipulated pool bought no extra AMPS");
    }

    /// @notice And the round trip costs money: the dump pays the sell fee on every AMPS it puts in, and the bond
    ///         still prices against NAV, so the attacker ends with less value than they started with.
    function test_theDumpThenBondRoundTripLosesValue() public {
        PoolId spoke = spokePools[0];
        giveShares(ATTACKER, 400e18);

        uint256 ampsBefore = amps.balanceOf(ATTACKER);
        uint256 stockBefore = stocks[0].balanceOf(ATTACKER);

        int24 before = tickOf(spoke);
        uint256 stockOut = 0;
        (stockOut,) = slide(spoke, ATTACKER, 8e18, before - 3000, 120, 45);
        settleTwap();

        uint256 collateral = stockOut / 2;
        (uint256 ampsOut,) = _bondFromHoldings(ATTACKER, 0, collateral);

        uint256 ampsSpent = ampsBefore - amps.balanceOf(ATTACKER) + ampsOut;
        uint256 stockGained = stocks[0].balanceOf(ATTACKER) - stockBefore;
        uint256 valueSpentUsd = ampsSpent * vault.navPerShareX18() / Constants.WAD;
        uint256 valueGainedUsd =
            stockGained * uint256(stockUsd8[0]) / 1e8 + ampsOut * vault.navPerShareX18() / Constants.WAD;

        console.log("value out (usd18)", valueSpentUsd, "value back (usd18)", valueGainedUsd);
        assertLt(valueGainedUsd, valueSpentUsd, "the whole manoeuvre is a loss, at NAV and at the feed");
    }

    /// @notice I27's half of the same statement: whatever the pool is doing, a bond never lowers NAV/share.
    function test_theBondNeverDilutes() public {
        giveShares(ATTACKER, 400e18);
        int24 before = tickOf(spokePools[0]);
        slide(spokePools[0], ATTACKER, 8e18, before - 3000, 120, 45);
        settleTwap();

        uint256 navBefore = vault.previewNavPerShareX18();
        bondAs(ATTACKER, 0, 1e18);
        assertGe(vault.previewNavPerShareX18(), navBefore, "the bond raised NAV/share, or left it alone");
    }

    /// @dev A bond paid for out of collateral the caller already holds, rather than freshly minted.
    function _bondFromHoldings(address who, uint256 i, uint256 amountIn)
        private
        returns (uint256 ampsOut, uint256 positionId)
    {
        vm.startPrank(who);
        stocks[i].approve(address(vault), type(uint256).max);
        (ampsOut, positionId) = bonds.bond(marketIds[i], amountIn, 0, who);
        vm.stopPrank();
    }
}
