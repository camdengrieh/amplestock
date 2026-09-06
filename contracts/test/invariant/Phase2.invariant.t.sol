// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {Phase2Fixture} from "../integration/Phase2Fixture.sol";
import {Phase2Handler, Phase2Wiring} from "./Phase2Handler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

/// @title Phase2InvariantTest
/// @notice The plan's Verification section, run against the wired Phase 2 system rather than against mocks:
///         I3, I5, I6, I8, I10, I12, I21, I22, I23, I24, I27, I28, I30, I36 and I38, driven by `Phase2Handler`
///         over random interleavings of bonds, claims, redemptions, checkpoints, feed and hub moves, guardian
///         freezes, staking and bounty funding.
///
/// @dev Runs and depth come from `foundry.toml` (64 x 64 by default, 256 x 128 under the `ci` profile) with
///      `fail_on_revert = false`; the handler catches every revert itself and records violations as ghosts, so a
///      legitimate refusal (a full epoch, a frozen gate, an empty balance) is never confused with a breach.
contract Phase2InvariantTest is Phase2Fixture {
    Phase2Handler internal handler;

    function setUp() public {
        deployPhase2World();
        runPhase2Genesis();

        handler = new Phase2Handler(_wiring());

        // The handler is the redeemer and the staker; it gets its shares out of the POL tranche rather than from
        // a mint, so `totalSupply` is still exactly `S0` when the campaign starts and I3 has a fixed origin.
        giveShares(address(handler), 1500e18);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = Phase2Handler.bond.selector;
        selectors[1] = Phase2Handler.claim.selector;
        selectors[2] = Phase2Handler.redeem.selector;
        selectors[3] = Phase2Handler.warp.selector;
        selectors[4] = Phase2Handler.stall.selector;
        selectors[5] = Phase2Handler.moveFeed.selector;
        selectors[6] = Phase2Handler.breakFeed.selector;
        selectors[7] = Phase2Handler.refreshFeeds.selector;
        selectors[8] = Phase2Handler.moveHub.selector;
        selectors[9] = Phase2Handler.checkpoint.selector;
        selectors[10] = Phase2Handler.poke.selector;
        selectors[11] = Phase2Handler.freeze.selector;
        selectors[12] = Phase2Handler.unfreeze.selector;
        selectors[13] = Phase2Handler.notifyReward.selector;
        selectors[14] = Phase2Handler.stake.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        bytes4[] memory more = new bytes4[](3);
        more[0] = Phase2Handler.unstake.selector;
        more[1] = Phase2Handler.fundPot.selector;
        more[2] = Phase2Handler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: more}));
    }

    // -------------------------------------------------------------------------------------------------------------
    // Supply and issuance
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I3 and I10: `totalSupply` moves only through the vault's mint and burn, and after the genesis latch
    ///         the only mint path is `mintVesting` on behalf of `AmpsBonds`.
    function invariant_I3_I10_supplyMovesOnlyThroughBondsAndBurns() public view {
        assertEq(
            amps.totalSupply(),
            Constants.S0 + handler.mintedVesting() - handler.burnedShares() - handler.burnedInventory(),
            "S0 + bond mints - redeemed shares - burned inventory"
        );
        assertEq(amps.vault(), address(vault), "and the vault is still the only minter");
    }

    /// @notice I30: every AMPS bought through a bond is in `totalSupply` from the instant of purchase and sits on
    ///         `AmpsBonds` until it vests — it is never part of the vault's inventory.
    function invariant_I30_vestingIsInSupplyAndNotInventory() public view {
        assertEq(
            amps.balanceOf(address(bonds)),
            handler.mintedVesting() - handler.claimedVesting(),
            "the bonds shell holds exactly the unclaimed principal"
        );
        assertLe(amps.balanceOf(address(bonds)), amps.totalSupply(), "which is inside totalSupply");
        assertLe(vault.inventoryAmps(), amps.totalSupply() - amps.balanceOf(address(bonds)), "and outside inventory");
    }

    /// @notice I28: no fill ever exceeded the capacity its own market disclosed a moment earlier, and no vest ever
    ///         paid more than it was sold.
    function invariant_I28_capacityAndVestingAreBounded() public view {
        assertFalse(handler.capacityEverExceeded(), "per-epoch and daily capacity are never exceeded");
        assertLe(handler.claimedVesting(), handler.mintedVesting(), "claims never exceed purchases");
    }

    // -------------------------------------------------------------------------------------------------------------
    // NAV
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I5: AMPS is never an asset, so every AMPS leg is valued at zero.
    function invariant_I5_ampsIsNeverAnAsset() public view {
        assertFalse(vault.isAsset(address(amps)), "AMPS is not in the NAV sum");
        uint256 count = vault.assetCount();
        for (uint256 i; i < count; ++i) {
            assertTrue(vault.assetAt(i) != address(amps), "nor in the enumeration");
        }
    }

    /// @notice I5 and I6 together: `A` is exactly the priced sum of the vault's own non-AMPS balances and nothing
    ///         else, and the denominator is `Amps.totalSupply()` and nothing else.
    function invariant_I6_navIsAOverTotalSupply() public view {
        uint256 recomputed;
        uint256 count = vault.assetCount();
        for (uint256 i; i < count; ++i) {
            address token = vault.assetAt(i);
            uint256 balance = heldBalance(token);
            if (balance == 0) continue;
            (uint256 answerUsd8,,) = feeds.latestAnswer(token);
            recomputed += PriceLib.counterValueUsd18(balance, IERC20Metadata(token).decimals(), answerUsd8);
        }
        assertEq(vault.totalAssetsUsd18(), recomputed, "A is the priced sum of the balances");
        assertEq(
            vault.previewNavPerShareX18(),
            ((recomputed + 1) * 1e18) / (amps.totalSupply() + Constants.VIRTUAL_SHARES),
            "the denominator is totalSupply and nothing else"
        );
    }

    /// @notice I8: no action other than a market move ever lowered NAV/share.
    function invariant_I8_navPerShareNeverFallsExMarketMoves() public view {
        if (handler.navEverFell()) {
            console.log("[I8] action    ", vm.toString(handler.badNavAction()));
            console.log("[I8] navBefore ", handler.badNavBefore());
            console.log("[I8] navAfter  ", handler.badNavAfter());
        }
        assertFalse(handler.navEverFell(), "NAV/share is monotone non-decreasing ex market moves");
    }

    /// @notice I22: the denominator is never zero and NAV/share is always a finite, non-zero number.
    function invariant_I22_navIsAlwaysFinite() public view {
        assertGt(amps.totalSupply() + Constants.VIRTUAL_SHARES, 0, "T + VIRTUAL_SHARES > 0");
        assertGt(vault.previewNavPerShareX18(), 0, "NAV/share is a number");
        assertLe(vault.previewNavPerShareX18(), type(uint128).max, "and fits the checkpoint word");
    }

    /// @notice I27: no bond ever lowered the live NAV/share.
    /// @dev The handler never refreshes the checkpoint before a bond. `depositBonded` writes a same-block checkpoint
    ///      before it settles and the shell prices after it, so a bond prices against the live pre-deposit NAV under
    ///      every gate state the bond policy admits; the regression is
    ///      `Phase2IntegrationTest.test_b_secondBondInTheSameBlockPricesAgainstTheLiveNav`.
    function invariant_I27_everyBondIsAccretive() public view {
        if (handler.bondEverDiluted()) {
            console.log("[I27] market   ", handler.badBondMarket());
            console.log("[I27] amountIn ", handler.badBondAmountIn());
            console.log("[I27] ampsOut  ", handler.badBondAmpsOut());
            console.log("[I27] navBefore", handler.badBondNavBefore());
            console.log("[I27] navAfter ", handler.badBondNavAfter());
        }
        assertFalse(handler.bondEverDiluted(), "no bond ever lowered NAV/share");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reference price
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I24: `P_ref` is never below NAV, and never rises faster than `refUpRateBps` per hour above it.
    function invariant_I24_referenceIsFlooredAndRateLimited() public view {
        assertGe(vault.pRefX18(), vault.navPerShareX18(), "P_ref >= navPerShare");
        if (handler.referenceEverOutOfBand()) {
            console.log("[I24] pRef    ", handler.badRefPRef());
            console.log("[I24] nav     ", handler.badRefNav());
            console.log("[I24] ceiling ", handler.badRefCeiling());
            console.log("[I24] prevPRef", handler.badRefPrev());
            console.log("[I24] elapsed ", handler.badRefElapsed());
        }
        assertFalse(handler.referenceEverOutOfBand(), "and every checkpoint respected the rate limit");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Custody
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I12: every vault call returns with no registered asset resting on the vault as an ERC-20 balance,
    ///         and `AmpsBonds` never holds one at all.
    /// @dev The vault half is a ghost rather than a direct read because `sweepClean` is a post-condition of the
    ///      vault's own functions: an outright donation legitimately sits on the vault between two calls, and the
    ///      handler checks the property at the only instant the contract claims it.
    function invariant_I12_sweepClean() public view {
        assertFalse(handler.sweepEverDirty(), "no vault call ever returned with an idle ERC-20 balance");
        uint256 count = vault.assetCount();
        for (uint256 i; i < count; ++i) {
            assertEq(IERC20(vault.assetAt(i)).balanceOf(address(bonds)), 0, "and the bonds shell never holds one");
        }
    }

    /// @notice I21: the bounty pot's USDG is outside `A`, and the pot never pays more than it holds.
    function invariant_I21_bountyPotIsOutsideNav() public view {
        assertFalse(vault.isAsset(address(pot)), "the pot is not an asset");
        assertLe(pot.spentLast24h(), pot.dailyCeilingUsd18(), "and never over its own ceiling");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Redemption, claims and staking
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I23: every redemption paid exactly `floor(floor(b x shares / T) x (BPS - fee) / BPS)` of every
    ///         non-AMPS balance and burned exactly `floor(inventory x shares / T)` of the vault's own AMPS.
    function invariant_I23_redemptionIsExact() public view {
        assertFalse(handler.redemptionEverInexact(), "redemption is exactly pro-rata, less the fee");
        assertLe(vault.redeemFeeBps(), Constants.REDEEM_FEE_BPS_MAX, "and the fee is inside its hard cap");
    }

    /// @notice I38: `claim()` never failed on a position with something to claim, whatever the gate, the market,
    ///         the collateral registry or the policy pointer was doing at the time.
    function invariant_I38_claimAlwaysSucceeds() public view {
        assertFalse(handler.claimEverFailed(), "a vest already sold always completes");
    }

    /// @notice I36: `AmpsStaking.totalAssets()` never fell except on a withdrawal, released never exceeds
    ///         notified, and the staker slice is inside its hard cap.
    function invariant_I36_stakingAssetsOnlyFallOnWithdrawals() public view {
        assertFalse(handler.stakingAssetsEverFell(), "totalAssets never falls outside a withdrawal");
        assertLe(staking.releasedRewards(), staking.totalNotified(), "released <= notified");
        assertEq(staking.totalNotified(), handler.notifiedRewards(), "and only the vault ever notified");
        assertLe(vault.stakerBps(), Constants.STAKER_BPS_MAX, "stakerBps <= 5000");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The campaign itself
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every action really does move the system, so the invariants above are not vacuous.
    /// @dev A plain test rather than an invariant: Foundry evaluates invariants once before the first call, when
    ///      no action has landed yet, so "the run was not empty" cannot be expressed as one.
    function test_handlerActionsAllExecute() public {
        handler.bond(0, 0.05e18);
        handler.warp(6 hours);
        handler.refreshFeeds();
        handler.checkpoint();
        handler.claim(0);
        handler.stake(50e18);
        handler.notifyReward(10e18);
        handler.warp(1 hours);
        handler.unstake(Constants.BPS);
        handler.fundPot(100e6);
        handler.donate(1, 1e18);
        handler.moveFeed(2, 120);
        handler.moveHub(1.2e18);
        handler.poke(0);
        handler.redeem(2000);
        handler.freeze(0, 1 days);
        handler.unfreeze(0);
        handler.breakFeed(3, 2);
        handler.stall(2 hours);

        assertGt(handler.bondCount(), 0, "a bond landed");
        assertGt(handler.claimCount(), 0, "a claim landed");
        assertGt(handler.checkpointCount(), 0, "a checkpoint landed");
        assertGt(handler.redeemCount(), 0, "a redemption landed");
        assertGt(handler.mintedVesting(), 0, "the bond minted");
        assertGt(handler.burnedShares(), 0, "the redemption burned");
        assertGt(handler.notifiedRewards(), 0, "the staker slice was paid");

        assertFalse(handler.navEverFell(), "and none of it lowered NAV/share");
        assertFalse(handler.bondEverDiluted(), "nor diluted a holder");
        assertFalse(handler.redemptionEverInexact(), "nor mispaid a redemption");
        assertFalse(handler.claimEverFailed(), "nor blocked a vest");
        assertFalse(handler.capacityEverExceeded(), "nor over-issued");
        assertFalse(handler.referenceEverOutOfBand(), "nor unpinned the reference");
        assertFalse(handler.stakingAssetsEverFell(), "nor lost staked assets");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Packs the fixture's deployment into the handler's one constructor argument.
    function _wiring() private view returns (Phase2Wiring memory w) {
        address[] memory stockAddresses = new address[](CONSTITUENTS);
        address[] memory feedAddresses = new address[](CONSTITUENTS);
        uint16[] memory markets = new uint16[](CONSTITUENTS);
        PoolId[] memory pools = new PoolId[](CONSTITUENTS);
        uint128[] memory prices = new uint128[](CONSTITUENTS);
        for (uint256 i; i < CONSTITUENTS; ++i) {
            stockAddresses[i] = address(stocks[i]);
            feedAddresses[i] = address(stockFeeds[i]);
            markets[i] = marketIds[i];
            pools[i] = spokePools[i];
            prices[i] = STOCK_USD8[i];
        }

        w = Phase2Wiring({
            vault: vault,
            amps: amps,
            bonds: bonds,
            staking: staking,
            pot: pot,
            gate: gate,
            marketRef: marketRef,
            usdg: usdg,
            wethFeed: wethFeed,
            usdgFeed: usdgFeed,
            timelock: TIMELOCK,
            guardian: GUARDIAN,
            hubPool: hubPool,
            wethPool: wethPool,
            wethUsd8: WETH_USD8,
            usdgUsd8: USDG_USD8,
            stocks: stockAddresses,
            stockFeeds: feedAddresses,
            marketIds: markets,
            spokePools: pools,
            stockUsd8: prices
        });
    }
}
