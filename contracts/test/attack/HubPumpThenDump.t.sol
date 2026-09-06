// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

/// @title HubPumpThenDumpTest
/// @notice The plan's named attack **hub pump then dump into spoke bids**, with the reason it fails written out:
///         "spoke bids are static ladder proceeds at the prices they were raised, so the dump only returns those
///         proceeds, pays the sell fee and the bought AMPS is burned".
///
///         The attacker buys AMPS in the hub to mark the price up, then sells the AMPS into a spoke's bid ladder
///         hoping the spoke will pay the *marked* price. It cannot: a bid is a v4 range position at the ticks it
///         was placed at, and nothing in the protocol re-prices or moves one upward (I29). The dump walks down
///         those static bids, pays `sellFeeBps` the whole way, and hands the vault AMPS that the next `compound`
///         burns (I33).
contract HubPumpThenDumpTest is Phase3Fixture {
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

    /// @notice The whole manoeuvre, priced at the feeds and at the NAV that stood before it began: the attacker
    ///         ends with less value than they started with, and every bid they could reach is still at the tick
    ///         that raised it.
    function test_pumpThenDumpIntoSpokeBidsLosesValue() public {
        PoolId spoke = spokePools[0];

        // The spoke's bid ladder, recorded before anybody touches the hub. These are the only prices the dump can
        // ever hit, whatever the hub does.
        int24[] memory bidTicks = _bidTicks(spoke);
        assertGt(bidTicks.length, 0, "the spoke has a bid ladder to attack");

        uint256 navStart = vault.navPerShareX18();
        uint256 usdgMintedBefore = usdg.totalSupply();
        uint256 stockBefore = stocks[0].balanceOf(ATTACKER);

        // 1. Pump the hub as far as the rail allows.
        (uint256 bought,) = climb(hubPool, ATTACKER, 1e6, tickOf(hubPool) + 2624, 200, 3);
        uint256 usdgSpent = usdg.totalSupply() - usdgMintedBefore - usdg.balanceOf(ATTACKER);
        assertGt(bought, 0, "the pump bought AMPS");

        // 2. Dump it into the spoke's bids. The rail refuses whatever it refuses; that is part of the result.
        settleTwap();
        approveStack(address(amps), ATTACKER);
        slide(spoke, ATTACKER, bought / 30, tickOf(spoke) - 20_000, 200, 45);
        uint256 stockGained = stocks[0].balanceOf(ATTACKER) - stockBefore;

        // 3. Price the round trip: USDG at par, stock at its feed, leftover AMPS at the NAV that stood before the
        //    attack began. Valuing the residue at the *pre-attack* NAV is the attacker-friendly choice.
        uint256 spentUsd = usdgSpent * 1e12;
        uint256 gainedUsd =
            stockGained * uint256(stockUsd8[0]) / 1e8 + amps.balanceOf(ATTACKER) * navStart / Constants.WAD;
        console.log("spent (usd18)", spentUsd, "recovered (usd18)", gainedUsd);
        assertLt(gainedUsd, spentUsd, "the pump-and-dump returns less than it cost");

        // 4. The bids the dump could reach are exactly the ones that were there beforehand: none was moved up.
        int24[] memory remaining = _bidTicks(spoke);
        for (uint256 i; i < bidTicks.length; ++i) {
            bool stillThere;
            for (uint256 k; k < remaining.length; ++k) {
                if (remaining[k] == bidTicks[i]) stillThere = true;
            }
            assertTrue(stillThere, "every bid is still at the tick it was raised at (I29)");
        }
    }

    /// @notice And the reason the dump is cheap for the protocol: while the hub is marked up and the spokes have
    ///         not followed, a sell into a spoke is deviation-increasing and the outer rail refuses it outright.
    function test_theRailRefusesTheDumpUntilTheSpokeHasFollowed() public {
        PoolId spoke = spokePools[0];
        (uint256 bought,) = climb(hubPool, ATTACKER, 1e6, tickOf(hubPool) + 2624, 200, 3);
        settleTwap();
        approveStack(address(amps), ATTACKER);

        int24 fair = hook.fairTick(spoke);
        int24 rail = hook.outerRailTicks(spoke);
        if (fair - tickOf(spoke) > rail) {
            (,,, bool refuse) = hook.quoteFee(spoke, true, true, bought / 4);
            assertTrue(refuse, "the spoke refuses a dump while its reference is above it");
        }
        assertGt(bought, 0, "the pump happened");
    }

    /// @notice I33: the AMPS the dump handed the vault is bought-back inventory, and the next `compound` burns it
    ///         rather than re-laddering it.
    function test_theBoughtBackAmpsIsBurned() public {
        (uint256 bought,) = climb(hubPool, ATTACKER, 1e6, tickOf(hubPool) + 2000, 150, 3);
        settleTwap();
        approveStack(address(amps), ATTACKER);
        slide(hubPool, ATTACKER, bought / 30, tickOf(hubPool) - 20_000, 200, 45);
        settleTwap();

        uint256 supplyBefore = amps.totalSupply();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        (, uint256 burned) = vault.compound(hubPool);

        assertGt(burned, 0, "the compound burned the bought-back AMPS");
        assertEq(amps.totalSupply(), supplyBefore - burned, "and totalSupply fell by exactly that");
    }

    /// @dev The lower ticks of every live bid cell in a pool.
    function _bidTicks(PoolId poolId) private view returns (int24[] memory ticks) {
        PlacementRecord[] memory records = ladderOf(poolId);
        uint256 count;
        int24[] memory buffer = new int24[](records.length);
        for (uint256 i; i < records.length; ++i) {
            if (records[i].above || records[i].liquidity == 0) continue;
            buffer[count++] = records[i].lowerTick;
        }
        ticks = new int24[](count);
        for (uint256 i; i < count; ++i) {
            ticks[i] = buffer[i];
        }
    }
}
