// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {PlacementFixture} from "../mocks/PlacementFixture.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title VaultHostileTokenPlacementTest
/// @notice Audit wave-2 finding 1, on the **placement** side of the same sweep: `compound` and `rollout` exit
///         through `sweepClean` exactly as the redemption does, so a Stock Token that burns whatever gas it is
///         handed on `transfer` used to be able to starve them too.
///
/// @dev This suite runs against the real system — real `PoolRegistry`, real `OracleGate`, real `FeedRegistry`,
///      real v4 pools and a real ladder — because that is where `compound` has anything to do.
contract VaultHostileTokenPlacementTest is PlacementFixture {
    /// @dev More than any bounded call is given.
    uint256 private constant BURN = 5_000_000;

    function setUp() public {
        deployPlacementWorld();
        placeGenesisLadders();
        fundPot(1000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    /// @notice One wei of a gas-burning Stock Token on the vault does not stop `compound`, inside 30M.
    ///
    /// @dev The donation is the whole attack: an idle balance is what puts the token on `sweepClean`, and
    ///      `sweepClean` is the last thing every entry point does.
    function test_aGasBurningStockTokenCannotStarveCompound() public {
        // Real fees, from a real round trip against the real ladder, so `compound` has work to do.
        buyAmps(hubPool, address(usdg), 100e6);
        sellAmps(hubPool, amps.balanceOf(BOB) / 2);
        syncMarket();
        hook.setHighWaterTick(hubPool, tickOf(hubPool));
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        stocks[0].mint(address(vault), 1);
        stocks[0].setTransferGasBurn(BURN);

        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound{gas: 30_000_000}(hubPool);

        assertGt(ampsFees, 0, "the compound really did its work");
        assertEq(stocks[0].balanceOf(address(vault)), 1, "the absorb was skipped and the residue disclosed");
    }

    /// @notice And `checkpoint` and `touch`, the two permissionless upkeep selectors, survive it as well.
    function test_aGasBurningStockTokenCannotStarveTheUpkeepPaths() public {
        stocks[0].mint(address(vault), 1);
        stocks[0].setTransferGasBurn(BURN);

        vault.checkpoint{gas: 30_000_000}();
        vault.touch{gas: 30_000_000}();
    }

    /// @notice A redemption against the live ladder pays every asset, hostile or not, inside 30M.
    function test_aGasBurningStockTokenCannotStarveARedemptionAgainstTheLadder() public {
        giveShares(ALICE, 100e18);
        stocks[0].mint(address(vault), 1);
        stocks[0].setTransferGasBurn(BURN);

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata{gas: 30_000_000}(100e18, ALICE);

        for (uint256 i; i < tokens.length; ++i) {
            if (amounts[i] == 0) continue;
            uint256 paid = _erc20Of(tokens[i], ALICE) + poolManager.balanceOf(ALICE, Currency.wrap(tokens[i]).toId());
            assertGe(paid, amounts[i], "every asset was paid, as tokens or as claims");
        }
    }

    /// @notice Control: with the bomb disarmed the same donation is absorbed into claims.
    function test_theSweepStillAbsorbsAnHonestDonation() public {
        uint256 claimBefore = claimOf(address(stocks[0]));
        stocks[0].mint(address(vault), 5);

        vault.checkpoint();

        assertEq(stocks[0].balanceOf(address(vault)), 0, "absorbed");
        assertEq(claimOf(address(stocks[0])), claimBefore + 5, "into the vault's own claims");
    }

    /// @dev The ERC-20 balance of `token` held by `who`, without assuming which mock it is.
    function _erc20Of(address token, address who) private view returns (uint256 balance) {
        (bool ok, bytes memory returndata) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        if (!ok || returndata.length < 32) return 0;
        return abi.decode(returndata, (uint256));
    }
}
