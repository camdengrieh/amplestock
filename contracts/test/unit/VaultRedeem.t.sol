// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {Constants} from "../../src/types/Constants.sol";
import {GateState, PlacementRecord} from "../../src/types/Types.sol";
import {ClaimMinter} from "../mocks/ClaimMinter.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {PlacementFixture} from "../mocks/PlacementFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice A contract that reverts on every call, for the hostile-timelock half of the drill.
contract AlwaysRevertsInRedeem {
    fallback() external payable {
        revert("down");
    }
}

/// @title VaultRedeemTest
/// @notice `docs/phase3-state-model.md` §8.1 and §3.10: I23 with **live positions** — exactly
///         `floor(L_p x shares / T)` removed from every record in every pool, every counter asset paid less
///         `redeemFeeBps`, the released inventory AMPS burned — and the floor still succeeding with every feed
///         dead, the watchdog tripped, the guardian freezing and the timelock hostile.
contract VaultRedeemTest is PlacementFixture {
    function setUp() public {
        deployPlacementWorld();
        placeGenesisLadders();
        giveShares(ALICE, 500e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // I23 with live positions
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The removal is exactly `floor(L x shares / T)` from **every** record in **every** pool the vault
    ///         has opened — not a netting, not a substitution, not a subset.
    function test_i23_removesExactlyTheProRataLiquidityFromEveryRecord() public {
        uint256 shares = 500e18;
        uint256 supply = amps.totalSupply();

        PoolId[4] memory pools = [hubPool, wethPool, spokePools[0], spokePools[1]];
        uint128[][] memory before = new uint128[][](pools.length);
        for (uint256 p; p < pools.length; ++p) {
            PlacementRecord[] memory records = ladderOf(pools[p]);
            before[p] = new uint128[](records.length);
            for (uint256 i; i < records.length; ++i) {
                before[p][i] = records[i].liquidity;
            }
        }

        vm.prank(ALICE);
        vault.redeemProRata(shares, ALICE);

        uint256 checked;
        for (uint256 p; p < pools.length; ++p) {
            PlacementRecord[] memory records = ladderOf(pools[p]);
            for (uint256 i; i < records.length; ++i) {
                uint128 removed = uint128(uint256(before[p][i]) * shares / supply);
                assertEq(records[i].liquidity, before[p][i] - removed, "exactly floor(L x shares / T) removed");
                if (before[p][i] != 0) ++checked;
            }
        }
        assertGt(checked, 0, "there were live positions to remove from");
        assertSweepClean("redeemProRata");
    }

    /// @notice And the PoolManager agrees: the position liquidity the vault records is the liquidity the pool
    ///         holds, before and after, so the removal really happened rather than being written down.
    function test_i23_thePoolManagerAgreesWithTheVaultsBook() public {
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        // `LadderPositionValuer.totalLiquidity` reads the grid straight out of the PoolManager by `extsload`.
        PoolId[2] memory pools = [hubPool, wethPool];
        for (uint256 p; p < pools.length; ++p) {
            uint256 booked;
            PlacementRecord[] memory records = ladderOf(pools[p]);
            for (uint256 i; i < records.length; ++i) {
                booked += records[i].liquidity;
            }
            assertEq(valuer.totalLiquidity(pools[p]), booked, "the book and the pool agree");
        }
    }

    /// @notice The payout: every non-AMPS asset, net of `redeemFeeBps`, out of claims and idle balances *and* out
    ///         of the positions the removal just freed.
    function test_i23_paysEveryCounterAssetNetOfTheFee() public {
        (address[] memory tokens, uint256[] memory preview,) = vault.previewRedeem(500e18);

        vm.prank(ALICE);
        (address[] memory paidTokens, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        assertEq(paidTokens.length, tokens.length, "the same asset list");
        uint256 nonZero;
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(paidTokens[i], tokens[i], "in the same order");
            assertEq(IERC20(tokens[i]).balanceOf(ALICE), amounts[i], "the redeemer got exactly what was reported");
            if (amounts[i] != 0) ++nonZero;
        }
        assertGt(nonZero, 0, "and something was actually paid");
        preview;
    }

    /// @notice **The preview cannot drift from the payout.** `previewUnwind` mirrors v4's own decomposition — it
    ///         branches on `slot0.tick` against the range, not on the sqrt price, and every amount rounds down —
    ///         so `previewRedeem` and `redeemProRata` agree to the wei even with the whole ladder live.
    function test_previewMatchesThePayoutToTheWeiWithLivePositions() public {
        (address[] memory tokens, uint256[] memory preview, uint256 previewBurn) = vault.previewRedeem(500e18);

        vm.prank(ALICE);
        (, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        for (uint256 i; i < tokens.length; ++i) {
            assertEq(amounts[i], preview[i], "preview == payout, to the wei");
        }
        previewBurn;
    }

    /// @notice **Revision 8, ruling U.** The released inventory AMPS is queued into the 24-hour burn stream, so
    ///         `T` falls by exactly `shares` here and by the released amount over the day that follows. The
    ///         redemption is as accretive as it ever was — the accretion simply lands outside the transaction
    ///         that earned it, which is what removes the split advantage.
    function test_r8_i23_releasedInventoryAmpsIsQueuedNotBurned() public {
        uint256 supplyBefore = amps.totalSupply();
        uint256 navBefore = vault.previewNavPerShareX18();
        (,, uint256 released) = vault.previewRedeem(500e18);
        assertGt(released, 0, "there is inventory to release");

        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        assertEq(amps.totalSupply(), supplyBefore - 500e18, "T fell by exactly the shares redeemed");
        assertEq(vault.pendingInventoryBurn(), released, "the release was queued");
        assertGe(vault.previewNavPerShareX18(), navBefore, "and NAV/share did not fall");

        uint256 navQueued = vault.previewNavPerShareX18();
        warpBy(Constants.REDEEM_BURN_STREAM_SECONDS);
        vault.checkpoint();
        assertEq(vault.pendingInventoryBurn(), 0, "a whole window drains the stream");
        assertEq(amps.totalSupply(), supplyBefore - 500e18 - released, "and T then falls by the released amount");
        assertGt(vault.previewNavPerShareX18(), navQueued, "the drain is what lifts NAV/share");
    }

    /// @notice The fee stays in the vault: the `redeemFeeBps` slice of every payout is left behind as backing for
    ///         the holders who did not redeem.
    function test_theFeeStaysInTheVault() public {
        // The payout is `floor(gross x (BPS - redeemFeeBps) / BPS)` of every asset, where `gross` is the whole
        // pro-rata slice — balances *and* the position principal the unwind would free. Reading the same
        // redemption at a zero fee is the only way to see `gross` without re-deriving it, and the two answers
        // must differ by exactly the fee.
        (address[] memory tokens, uint256[] memory net,) = vault.previewRedeem(500e18);

        vm.prank(TIMELOCK);
        vault.setRedeemFeeBps(0);
        (, uint256[] memory gross,) = vault.previewRedeem(500e18);

        uint256 checked;
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(
                net[i],
                gross[i] * (Constants.BPS - Constants.REDEEM_FEE_BPS_DEFAULT) / Constants.BPS,
                "exactly (1 - redeemFeeBps) of the gross"
            );
            if (gross[i] != 0) ++checked;
        }
        assertGt(checked, 0, "and there was something to take a fee on");

        // The fee is not paid anywhere: it stays as backing for the holders who did not redeem.
        vm.prank(TIMELOCK);
        vault.setRedeemFeeBps(Constants.REDEEM_FEE_BPS_DEFAULT);
        uint256 navBefore = vault.previewNavPerShareX18();
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        assertGe(vault.previewNavPerShareX18(), navBefore, "NAV/share did not fall");
    }

    /// @notice A one-wei redemption removes nothing at all — `floor(L x 1 / T)` is zero for every cell — and so
    ///         cannot be used to sweep a position's whole accrued fee balance into a redeemer's payout.
    function test_aDustRedemptionRemovesNoLiquidityAtAll() public {
        PlacementRecord[] memory before = ladderOf(hubPool);
        giveShares(BOB, 1);

        vm.prank(BOB);
        vault.redeemProRata(1, BOB);

        PlacementRecord[] memory after_ = ladderOf(hubPool);
        for (uint256 i; i < before.length; ++i) {
            assertEq(after_[i].liquidity, before[i].liquidity, "nothing was removed");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // §12 ruling F — the AMPS ERC-6909 claim is inventory too
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A merge-add whose collected fees exceed the principal it owes leaves the vault holding AMPS as an
    ///         ERC-6909 claim. That claim is protocol inventory exactly as the idle ERC-20 balance is, so it is in
    ///         the pro-rata base `floor(inventory x shares / T)` that redemption releases — and the preview says
    ///         so before the claim has been swept.
    function test_f_theAmpsClaimIsInventoryAndIsReleasedProRata() public {
        _leaveAnAmpsClaim();
        uint256 claim = claimOf(address(amps));
        assertGt(claim, 0, "the vault holds AMPS as a claim");

        uint256 idle = amps.balanceOf(address(vault));
        uint256 supply = amps.totalSupply();
        (,, uint256 previewRelease) = vault.previewRedeem(500e18);

        // The preview counts the claim: without it the base would be `idle` alone.
        uint256 positionAmps = previewRelease - (idle + claim) * 500e18 / supply;
        assertEq(
            previewRelease,
            (idle + claim) * 500e18 / supply + positionAmps,
            "the base is the idle balance plus the claim"
        );
        assertGt(previewRelease, idle * 500e18 / supply + positionAmps, "and the claim really moved the number");

        uint256 supplyBefore = amps.totalSupply();
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        // Revision 8, ruling U: the release is queued, so supply falls by the shares alone until the stream runs.
        assertEq(supplyBefore - amps.totalSupply(), 500e18, "burned the shares, and only the shares");
        // **The preview is the floor of what was queued since audit wave 5's lead L-13.** The redemption queues
        // the pro-rata release *plus* the AMPS-side fees the position removal realised — a `view` cannot ask v4
        // what those will be, so `previewRedeem`'s third return is the pro-rata figure alone and the queue is the
        // larger of the pair. `_leaveAnAmpsClaim` trades, so there are fees here.
        uint256 queued = vault.pendingInventoryBurn();
        assertGe(queued, previewRelease, "the preview's figure is the floor of what was queued");
        assertEq(claimOf(address(amps)), 0, "and the claim was swept to ERC-20 so the stream can burn it");

        warpBy(Constants.REDEEM_BURN_STREAM_SECONDS);
        vault.checkpoint();
        assertEq(supplyBefore - amps.totalSupply(), 500e18 + queued, "a window on, the whole queue burned");
    }

    /// @notice And the sweep is not a giveaway. The claim is swept to ERC-20 so the stream's burn *can* happen,
    ///         but what is released is `floor(inventory x shares / T)` — so a one-wei redemption sweeps the claim
    ///         and releases none of it, and the vault's AMPS inventory is exactly as large afterwards as before.
    function test_f_aDustRedemptionSweepsTheClaimButBurnsNoneOfIt() public {
        _leaveAnAmpsClaim();
        assertGt(claimOf(address(amps)), 0, "there is a claim to sweep");

        giveShares(BOB, 1);
        uint256 inventoryBefore = amps.balanceOf(address(vault)) + claimOf(address(amps));
        uint256 supplyBefore = amps.totalSupply();
        vm.prank(BOB);
        vault.redeemProRata(1, BOB);

        assertEq(supplyBefore - amps.totalSupply(), 1, "only the one wei of shares was burned");
        assertEq(claimOf(address(amps)), 0, "the claim was swept to ERC-20");
        assertEq(
            amps.balanceOf(address(vault)) + claimOf(address(amps)),
            inventoryBefore,
            "and the inventory is exactly as large as it was"
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // The floor is ungated (I14), even with the whole Phase 3 machinery linked in
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every feed dead, the watchdog tripped, the guardian freezing and the timelock hostile:
    ///         `redeemProRata` still pays, and still removes from every position.
    function test_theFloorHoldsWithTheWholeWorldBroken() public {
        uint256 supply = amps.totalSupply();
        PlacementRecord[] memory before = ladderOf(hubPool);

        _breakTheWorld();

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        uint256 paid;
        for (uint256 i; i < tokens.length; ++i) {
            paid += amounts[i];
        }
        assertGt(paid, 0, "the floor paid");

        PlacementRecord[] memory after_ = ladderOf(hubPool);
        for (uint256 i; i < before.length; ++i) {
            uint128 removed = uint128(uint256(before[i].liquidity) * 500e18 / supply);
            assertEq(after_[i].liquidity, before[i].liquidity - removed, "and removed from every position");
        }
    }

    /// @notice And every *other* path is refused in that same world, which is what makes the exemption mean
    ///         something.
    function test_everyOtherPathIsRefusedInThatWorld() public {
        _breakTheWorld();
        vm.expectPartialRevert(bytes4(keccak256("GateNotHealthy(uint8,bytes32)")));
        vault.compound(hubPool);
    }

    /// @notice The storage-level half, extended to the linked libraries: a redemption reads no slot of the gate,
    ///         the feed registry, the registry or the market reference — and no slot of the *vault* that holds a
    ///         pointer to one of them. `VaultRedeemLib` runs by `DELEGATECALL`, so its reads are recorded here.
    function test_theRedemptionPathTouchesNoGateOrRegistryStorage() public {
        vm.record();
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        _assertUntouched(address(gate), "oracleGate");
        _assertUntouched(address(feeds), "feedRegistry");
        _assertUntouched(address(registry), "registry");
        _assertUntouched(address(hook), "marketReference");
        _assertUntouched(address(valuer), "positionValuer");

        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(vault));
        assertGt(reads.length, 0, "the recording was on");
        for (uint256 i; i < reads.length; ++i) {
            _assertNotAPointerSlot(reads[i]);
        }
        for (uint256 i; i < writes.length; ++i) {
            _assertNotAPointerSlot(writes[i]);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // §12.3 ruling U — the 24-hour inventory-burn stream (revision 8)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **The ruling-U vector.** 300 AMPS redeemed in one shot against the same 300 redeemed in 60 slices
    ///         inside one block, from the identical state. The split used to return ~2.9% more, because every
    ///         slice's inventory burn shrank the denominator the next slice divided by. With the burn streamed,
    ///         slices in one block settle nothing at all, so the only difference left is the redemption fee's own
    ///         arithmetic — a couple of basis points, not a strategy.
    function test_r8_u_splittingARedemptionNoLongerExtractsMore() public {
        uint256 shares = 300e18;
        uint256 before = usdg.balanceOf(ALICE);

        uint256 snapshot = vm.snapshotState();
        vm.prank(ALICE);
        vault.redeemProRata(shares, ALICE);
        uint256 oneShot = usdg.balanceOf(ALICE) - before;
        vm.revertToState(snapshot);

        for (uint256 i; i < 60; ++i) {
            vm.prank(ALICE);
            vault.redeemProRata(shares / 60, ALICE);
        }
        uint256 sliced = usdg.balanceOf(ALICE) - before;

        emit log_named_uint("ruling U: one shot", oneShot);
        emit log_named_uint("ruling U: 60 slices", sliced);

        // 10 bp of slack against a documented 290 bp advantage: the split is worth nothing anyone would pay gas
        // for, and the residue is the fee's own superadditivity rather than the inventory burn.
        uint256 gap = sliced > oneShot ? sliced - oneShot : oneShot - sliced;
        assertLe(gap * Constants.BPS / oneShot, 10, "splitting a redemption is worth at most 10 bp");
    }

    /// @notice The queued figure is exactly today's `inventoryBurned` formula: `floor(inventory x shares / T)`
    ///         plus the ladder AMPS the unwind released. Nothing about the arithmetic changed; only its effect.
    function test_r8_theQueuedAmountIsTheOldInventoryBurnFormula() public {
        uint256 supply = amps.totalSupply();
        uint256 idle = amps.balanceOf(address(vault));
        uint256 claim = claimOf(address(amps));

        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        // Nothing was burned, so every AMPS wei the unwind freed is still on the vault: the ladder release is the
        // growth of the idle balance less the claim the unwind swept into it. (No pool in this fixture has traded,
        // so the unwind realises no AMPS-side fees and the two terms are the whole of it.)
        uint256 releasedAmps = amps.balanceOf(address(vault)) - idle - claim;
        assertGt(releasedAmps, 0, "the unwind freed ladder AMPS");
        assertEq(
            vault.pendingInventoryBurn(),
            (idle + claim) * 500e18 / supply + releasedAmps,
            "floor(inventory x shares / T) + releasedAmps, queued rather than burned"
        );
    }

    /// @notice The stream is linear in the window: half of it is due after 12 hours, all of it after 24, and a
    ///         settlement never burns more than the vault's idle AMPS balance.
    function test_r8_theStreamReleasesLinearlyAndNeverMoreThanTheIdleBalance() public {
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        uint256 queued = vault.pendingInventoryBurn();
        assertGt(queued, 0, "something is queued");

        // Half the window: half the pending amount, to the rounding of one `mulDiv`.
        uint256 half = vm.snapshotState();
        warpBy(Constants.REDEEM_BURN_STREAM_SECONDS / 2);
        uint256 supplyBefore = amps.totalSupply();
        vault.checkpoint();
        assertApproxEqAbs(supplyBefore - amps.totalSupply(), queued / 2, 1, "half the stream after half a window");
        assertApproxEqAbs(vault.pendingInventoryBurn(), queued - queued / 2, 1, "and the rest is still owed");
        vm.revertToState(half);

        // The whole window: all of it.
        warpBy(Constants.REDEEM_BURN_STREAM_SECONDS);
        supplyBefore = amps.totalSupply();
        vault.checkpoint();
        assertEq(supplyBefore - amps.totalSupply(), queued, "the whole stream after a whole window");
        assertEq(vault.pendingInventoryBurn(), 0, "and nothing is owed");
    }

    /// @notice The idle cap, on its own: with the vault's AMPS inventory moved out from under the stream, a
    ///         settlement burns what is there and keeps owing the rest. The pending figure is never a promise
    ///         against AMPS the vault does not hold.
    ///
    /// @dev The state is forced with `deal` because a placement is the only thing that reaches it in production —
    ///      `place` can ladder idle AMPS the stream is still owed — and reproducing that here would take the whole
    ///      POL tranche. Excluding the queue from `VaultPlacementLib`'s inventory bound was measured and does not
    ///      fit (76 B against 67 B of EIP-170 headroom), so the shortfall is carried: the cap is what makes
    ///      carrying it safe, because a settlement must never revert on the ungated path for want of a balance.
    function test_r8_theStreamIsCappedByTheIdleAmpsBalance() public {
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        uint256 queued = vault.pendingInventoryBurn();
        assertGt(queued, 0, "something is queued");

        // Leave the vault a tenth of what it owes. `deal` is the only way to shrink an ERC-20 balance the
        // protocol itself would never spend down inside one test.
        uint256 kept = queued / 10;
        deal(address(amps), address(vault), kept);

        warpBy(Constants.REDEEM_BURN_STREAM_SECONDS);
        uint256 supplyBefore = amps.totalSupply();
        vault.checkpoint();

        assertEq(supplyBefore - amps.totalSupply(), kept, "the settlement burned the whole idle balance");
        assertEq(vault.pendingInventoryBurn(), queued - kept, "and the remainder is still queued");
    }

    /// @notice A redemption settles the accrued portion before it measures anything, so the supply it divides by
    ///         is the post-settlement one and `previewRedeem` — which settles the same amount in arithmetic —
    ///         still agrees with the payout to the wei.
    function test_r8_aRedemptionSettlesTheStreamFirst() public {
        vm.prank(ALICE);
        vault.redeemProRata(200e18, ALICE);
        uint256 queued = vault.pendingInventoryBurn();
        assertGt(queued, 0, "the first redemption queued");

        warpBy(Constants.REDEEM_BURN_STREAM_SECONDS / 2);

        uint256 supplyBefore = amps.totalSupply();
        (address[] memory previewTokens, uint256[] memory preview, uint256 release) = vault.previewRedeem(100e18);

        vm.prank(ALICE);
        (, uint256[] memory paid) = vault.redeemProRata(100e18, ALICE);

        uint256 settled = supplyBefore - amps.totalSupply() - 100e18;
        assertApproxEqAbs(settled, queued / 2, 1, "the redemption drained the accrued half on the way in");
        assertEq(vault.pendingInventoryBurn(), queued - settled + release, "then queued its own release");
        for (uint256 i; i < previewTokens.length; ++i) {
            assertEq(paid[i], preview[i], "preview == payout across a stream in flight");
        }
    }

    /// @notice `checkpoint()` drains the accrued portion. Queueing is NAV-neutral on the AMPS side and the drain
    ///         is what lifts NAV/share: AMPS inventory is worth zero in `A` (I5), so only `T` moves.
    function test_r8_checkpointDrainsTheStreamAndOnlyTheDrainMovesNav() public {
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        assertEq(amps.totalSupply(), supplyBefore - 500e18, "supply fell by exactly the shares redeemed");
        assertGt(vault.pendingInventoryBurn(), 0, "the queue is standing");

        // Nothing has elapsed, so a checkpoint in the same block drains nothing at all.
        uint256 queued = vault.pendingInventoryBurn();
        vault.checkpoint();
        assertEq(vault.pendingInventoryBurn(), queued, "a same-block checkpoint drains nothing");

        uint256 navQueued = vault.previewNavPerShareX18();
        warpBy(Constants.REDEEM_BURN_STREAM_SECONDS);
        vault.checkpoint();
        assertEq(vault.pendingInventoryBurn(), 0, "checkpoint() drained it");
        assertEq(amps.totalSupply(), supplyBefore - 500e18 - queued, "T fell by the queued amount");
        assertGt(vault.previewNavPerShareX18(), navQueued, "and only the drain moved NAV/share");
    }

    /// @notice **The schedule is one straight line, not a decay.** Settling every hour for 24 hours burns exactly
    ///         the amount a single settlement at the end burns: each settlement takes the remaining amount over
    ///         the remaining time, so a keeper cannot slow the burn down by calling it often.
    function test_r8_hourlySettlementsBurnTheWholeAmountInOneWindow() public {
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        uint256 queued = vault.pendingInventoryBurn();
        uint256 supplyBefore = amps.totalSupply();
        uint256 openedAt = vault.burnStreamStart();

        for (uint256 i; i < 24; ++i) {
            // §12.3 ruling S: solc hoists `TIMESTAMP` as loop-invariant, so `warpBy`'s `block.timestamp + dt`
            // inside a loop warps to the same instant every iteration and silently freezes the clock. The
            // cheatcode reads are calls and cannot be hoisted.
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vm.roll(vm.getBlockNumber() + 1);
            refreshFeeds();
            vault.checkpoint();
            assertEq(vault.burnStreamStart(), openedAt, "a settlement does not move the window's opening");
        }

        assertEq(vault.pendingInventoryBurn(), 0, "24 hourly settlements retire the whole queue");
        assertEq(supplyBefore - amps.totalSupply(), queued, "and burn exactly what was queued");
    }

    /// @notice A second redemption mid-window re-opens one window for the **combined** amount rather than
    ///         stacking a second schedule beside the first, and `burnStreamStart() + D` stays the single deadline.
    ///
    /// @dev **The re-opening is amount-weighted since audit wave 5 (finding 2).** It used to be
    ///      `burnStreamStart = block.timestamp` outright, which re-dated an arbitrarily large outstanding burn by
    ///      a full day for the price of a dust redemption. The opening now lies between the old one and `now`,
    ///      weighted by the amounts the two carry, so it moves in proportion to what the queue adds — which is
    ///      what this test asserts instead of the old "the window restarted here".
    ///      `VaultWave5.t.sol::test_w5_02_aQueueMovesTheDeadlineInProportionToWhatItAdds` is the finding's own
    ///      test; this one keeps the "one window for the combined amount" property it has always been about.
    function test_r8_aSecondQueueRestartsOneWindowForTheCombinedAmount() public {
        vm.prank(ALICE);
        vault.redeemProRata(200e18, ALICE);
        uint256 first = vault.pendingInventoryBurn();
        assertGt(first, 0, "the first redemption queued");

        warpBy(Constants.REDEEM_BURN_STREAM_SECONDS / 2);

        uint256 openedAt = vault.burnStreamStart();
        uint256 supplyBeforeSecond = amps.totalSupply();
        (,, uint256 secondRelease) = vault.previewRedeem(200e18);
        vm.prank(ALICE);
        vault.redeemProRata(200e18, ALICE);

        uint256 settled = supplyBeforeSecond - amps.totalSupply() - 200e18;
        assertApproxEqAbs(settled, first / 2, 1, "the second redemption settled the accrued half first");
        assertEq(vault.pendingInventoryBurn(), first - settled + secondRelease, "then one queue for the combined sum");
        assertGt(vault.burnStreamStart(), openedAt, "the window's opening moved toward now");
        assertLt(vault.burnStreamStart(), block.timestamp, "but not all the way to it: the opening is weighted");

        // A whole window from the restart retires everything, with nothing left over from the first redemption.
        uint256 combined = vault.pendingInventoryBurn();
        uint256 supplyBefore = amps.totalSupply();
        warpBy(Constants.REDEEM_BURN_STREAM_SECONDS);
        vault.checkpoint();
        assertEq(vault.pendingInventoryBurn(), 0, "the combined amount streamed to the restarted deadline");
        assertEq(supplyBefore - amps.totalSupply(), combined, "and all of it burned");
    }

    /// @notice `emergencyMigrate`'s unwind removes every position — `shares == supply == 1` — and queues nothing:
    ///         the queue is written by `redeemProRata` and by nothing else.
    function test_r8_migrationDoesNotQueueABurn() public {
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);

        // The on-chain migration predicate: a constituent that has denylisted the vault.
        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[0].blockAccounts(blocked);

        assertEq(vault.pendingInventoryBurn(), 0, "nothing queued before");
        matureStandby();
        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        assertEq(vault.pendingInventoryBurn(), 0, "and the migration's unwind queued nothing");
        assertEq(vault.burnStreamStart(), 0, "the stream was never started");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Migration brings the ladder home
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `emergencyMigrate` unwinds the whole ladder before the claims move, so nothing is stranded in v4
    ///         positions owned by a vault the standby cannot act for.
    function test_migrationUnwindsTheLadderBeforeTheClaimsMove() public {
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);

        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[0].blockAccounts(blocked);

        matureStandby();
        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        assertEq(valuer.totalLiquidity(hubPool), 0, "the hub's positions are gone");
        assertEq(valuer.totalLiquidity(wethPool), 0, "and the WETH pool's");
        assertGt(IERC20(address(usdg)).balanceOf(address(poolManager)), 0, "the assets are still in the PoolManager");
        assertEq(amps.vault(), STANDBY, "and the role moved");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The floor against a hostile constituent (§7, I12, I14)
    // -------------------------------------------------------------------------------------------------------------
    //
    // "Structurally ungated" has to mean ungated by the *constituents* too, not only by the protocol's own
    // switches. A Stock Token is an issuer-controlled contract that can be paused or can denylist an address at
    // will, and the payout walks every registered asset inside one `unlock`, so before these fixes a single
    // hostile token was a global kill switch for the floor:
    //
    //   * `sweepClean` read `balanceOf` unguarded, absorbed with `safeTransfer` and reverted `SweepDirty` on any
    //     residue — so one wei of a paused token, donated by anybody, bricked **every** entry point; and
    //   * `_payOut` took every asset out as an ERC-20, so one paused constituent refused 100% of every redemption.
    //
    // The three cases below are the three shapes an issuer's refusal takes. In all of them the redemption must
    // complete and the other assets must be paid in full.

    /// @notice A **paused** constituent: the `take` reverts, so the redeemer is handed the ERC-6909 claim instead
    ///         and can `take` it whenever the issuer relents. Every other asset is paid as ERC-20, as always.
    function test_aPausedConstituentDoesNotStopTheFloor() public {
        bondDeposit(address(stocks[0]), 20e18);
        assertGt(claimOf(address(stocks[0])), 0, "the vault holds the hostile token as a claim");

        stocks[0].pause();

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        uint256 pausedIndex = _indexOf(tokens, address(stocks[0]));
        assertGt(amounts[pausedIndex], 0, "the paused token was still part of the payout");
        assertEq(
            poolManager.balanceOf(ALICE, uint256(uint160(address(stocks[0])))),
            amounts[pausedIndex],
            "and the redeemer holds a claim on exactly that amount"
        );

        _assertTheHealthyAssetsWerePaid(tokens, amounts, address(stocks[0]));
    }

    /// @notice A constituent that **denylists the vault**: the vault can no longer move it at all, so `sweepClean`
    ///         cannot fold a donated wei into claims. It reports the residue and carries on; nothing reverts.
    function test_aConstituentThatDenylistsTheVaultDoesNotStopTheFloor() public {
        bondDeposit(address(stocks[0]), 20e18);

        // A one-wei donation, which is all the old `SweepDirty` needed, and then the denylisting that pins it.
        stocks[0].mint(address(vault), 1);
        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[0].blockAccounts(blocked);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IAmpsVault.SweepResidue(address(stocks[0]), 1);

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        assertEq(stocks[0].balanceOf(address(vault)), 1, "the frozen wei is still backing, on the vault");
        _assertTheHealthyAssetsWerePaid(tokens, amounts, address(stocks[0]));
    }

    /// @notice A constituent whose **`balanceOf` reverts**: unreadable is not fatal. It contributes nothing to the
    ///         idle side of the pro-rata base and is skipped by the sweep, and the floor pays everything else.
    function test_aConstituentWhoseBalanceOfRevertsDoesNotStopTheFloor() public {
        bondDeposit(address(stocks[0]), 20e18);
        stocks[0].setBalanceOfReverts(true);

        // The preview shares the arithmetic, so it must survive the same token.
        (address[] memory previewTokens, uint256[] memory preview,) = vault.previewRedeem(500e18);

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i], previewTokens[i], "the same asset list");
            assertEq(amounts[i], preview[i], "preview == payout, to the wei, with a view that reverts");
        }
        _assertTheHealthyAssetsWerePaid(tokens, amounts, address(stocks[0]));

        // And the claim side of the hostile token was still paid: `take` never asks a token for a balance.
        stocks[0].setBalanceOfReverts(false);
        assertGt(stocks[0].balanceOf(ALICE), 0, "the redeemer was paid the unreadable token too");
    }

    /// @notice The griefing case in its purest form: a donated wei of a token nobody can move must not stop the
    ///         *other* entry points either. `checkpoint()` is the permissionless one, so it is the canary.
    function test_aDonatedWeiOfAFrozenTokenDoesNotBrickTheOtherEntryPoints() public {
        stocks[0].mint(address(vault), 1);
        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[0].blockAccounts(blocked);

        vault.checkpoint();
        vault.touch();

        vm.prank(ALICE);
        vault.redeemProRata(1e18, ALICE);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Gas — the worst reachable redemption (§10 ruling 7)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **The live-cell budget is what makes the floor executable** (§12 ruling E). This measures the
    ///         marginal cost of a live cell on a fully occupied fixture and asserts that a redemption at the full
    ///         `Constants.MAX_LIVE_CELLS` fits inside 24M gas — Arbitrum's 32M per-transaction cap with a quarter
    ///         in reserve.
    ///
    /// @dev `fixedGas` is measured with a dust redemption, which walks exactly the same loop over exactly the same
    ///      records and removes nothing (`floor(L x 1 / T)` is zero for every cell), so the difference between the
    ///      two measurements is the `modifyLiquidity` work and nothing else. The floor is never gated,
    ///      rate-limited or split into instalments to make this number fit; the budget is.
    function test_e_gasPerLiveCellFitsTheRedemptionBudget() public {
        // Fill the fixture out: both spokes get a bonded bid ladder on top of their seed asks.
        for (uint256 i; i < SPOKES; ++i) {
            bondDeposit(address(stocks[i]), 20e18);
            warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
            vault.deployBonded(constituentIds[i]);
        }
        uint32 cells = vault.liveCells();
        assertEq(cells, countLiveCells(), "the count is exact");
        assertGt(cells, 0, "there is a ladder to unwind");

        giveShares(BOB, 1);
        vm.prank(BOB);
        uint256 g0 = gasleft();
        vault.redeemProRata(1, BOB);
        uint256 fixedGas = g0 - gasleft();

        vm.prank(ALICE);
        uint256 g1 = gasleft();
        vault.redeemProRata(500e18, ALICE);
        uint256 fullGas = g1 - gasleft();

        uint256 perCell = (fullGas - fixedGas) / cells;
        uint256 budgeted = perCell * Constants.MAX_LIVE_CELLS + fixedGas;

        emit log_named_uint("redeemProRata: live cells", cells);
        emit log_named_uint("redeemProRata: fixed gas (dust redemption)", fixedGas);
        emit log_named_uint("redeemProRata: total gas", fullGas);
        emit log_named_uint("redeemProRata: gas per live cell", perCell);
        emit log_named_uint("redeemProRata: at MAX_LIVE_CELLS", budgeted);

        assertLe(budgeted, 24_000_000, "a redemption at the full live-cell budget fits one transaction");
        // A CI-stable restatement of the same bound with ~20% headroom on the measured figure.
        assertLt(perCell, 46_000, "the marginal cost of a live cell");
    }

    /// @notice **The other half of the redemption budget, and where `MAX_CONSTITUENTS` comes from** (revision 8,
    ///         §12 ruling E closed). A live cell is not the only thing a redemption pays for per unit of registry
    ///         size: each registered constituent adds a pool to the unwind's walk and an asset to the payout. This
    ///         measures that marginal cost directly — two dust redemptions, one at the fixture's four assets and
    ///         one at `MAX_CONSTITUENTS + 2` — and asserts the whole bound the cap is derived from:
    ///
    ///           `perCell x MAX_LIVE_CELLS + perConstituent x (MAX_CONSTITUENTS + 2) + fixed <= 24M`
    ///
    /// @dev The dust redemption is the right probe for the constituent term for the same reason it is the right
    ///      probe for `fixedGas`: `floor(L x 1 / T)` is zero for every cell, so it walks every pool and every
    ///      asset and removes nothing, and the difference between the two measurements is the registry size and
    ///      nothing else.
    function test_r8_constituentCostAtTheCapFitsTheRedemptionBudget() public {
        for (uint256 i; i < SPOKES; ++i) {
            bondDeposit(address(stocks[i]), 20e18);
            warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
            vault.deployBonded(constituentIds[i]);
        }
        uint32 cells = vault.liveCells();
        assertGt(cells, 0, "there is a ladder to unwind");

        giveShares(BOB, 2);

        vm.prank(BOB);
        uint256 g0 = gasleft();
        vault.redeemProRata(1, BOB);
        uint256 baseGas = g0 - gasleft();
        uint256 baseAssets = vault.assetCount();

        uint256 extras = Constants.MAX_CONSTITUENTS - SPOKES;
        _openExtraConstituentPools(extras);
        assertEq(vault.assetCount(), baseAssets + extras, "one asset per extra constituent");
        assertEq(vault.assetCount(), uint256(Constants.MAX_CONSTITUENTS) + 2, "MAX_CONSTITUENTS + the two entry pools");

        vm.prank(BOB);
        uint256 g1 = gasleft();
        vault.redeemProRata(1, BOB);
        uint256 capGas = g1 - gasleft();
        uint256 perConstituent = (capGas - baseGas) / extras;

        vm.prank(ALICE);
        uint256 g2 = gasleft();
        vault.redeemProRata(500e18, ALICE);
        uint256 fullGas = g2 - gasleft();
        uint256 perCell = (fullGas - capGas) / cells;

        uint256 budgeted =
            perCell * Constants.MAX_LIVE_CELLS + perConstituent * (uint256(Constants.MAX_CONSTITUENTS) + 2) + baseGas;

        emit log_named_uint("redeem budget: live cells", cells);
        emit log_named_uint("redeem budget: fixed gas at 4 assets", baseGas);
        emit log_named_uint("redeem budget: fixed gas at MAX_CONSTITUENTS + 2 assets", capGas);
        emit log_named_uint("redeem budget: gas per constituent (one pool + one asset)", perConstituent);
        emit log_named_uint("redeem budget: gas per live cell", perCell);
        emit log_named_uint("redeem budget: at the cap", budgeted);

        assertLe(budgeted, 24_000_000, "a redemption at MAX_LIVE_CELLS and the constituent cap fits one block");
    }

    /// @notice **The cap is tied to the live-cell budget, not to a round number.** At the launch shape every pool
    ///         carries `LADDER_DOUBLINGS_DEFAULT + SEED_HALVINGS_DEFAULT` cells, so `MAX_LIVE_CELLS` admits that
    ///         many pools and `MAX_CONSTITUENTS` is what is left after the two entry pools. Raising either
    ///         constant without the other is what this refuses to let happen silently.
    function test_r8_constituentCapIsTiedToTheLiveCellBudget() public pure {
        uint256 cellsPerPool = uint256(Constants.LADDER_DOUBLINGS_DEFAULT) + Constants.SEED_HALVINGS_DEFAULT;
        assertGe(
            Constants.MAX_LIVE_CELLS / cellsPerPool - 2,
            Constants.MAX_CONSTITUENTS,
            "MAX_LIVE_CELLS / cells-per-pool, less the two entry pools, must cover MAX_CONSTITUENTS"
        );
        assertLe(Constants.LAUNCH_CONSTITUENTS, Constants.MAX_CONSTITUENTS, "the launch set fits inside the cap");
        assertEq(Constants.MAX_COLLATERALS, Constants.MAX_CONSTITUENTS + 2, "and the collateral ceiling follows it");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Opens `count` further vault pools, each with its own freshly deployed counter token, so that the
    ///      redemption walks `count` more pools and pays `count` more assets. It goes through the vault's own
    ///      registry-only entry point rather than through `PoolRegistry.addConstituent`, pranked as the registry:
    ///      what is being measured is the marginal cost of a pool on the **redemption** path, and that cost is the
    ///      `PoolKey` load, the empty-ladder check and one more entry in the payout walk — none of which the hook
    ///      participates in (the hook carries no `BEFORE_REMOVE_LIQUIDITY` bit, I18). The pools are therefore
    ///      opened hookless and at a static fee, which is what lets the fixture add 32 of them without a feed, an
    ///      index weight and an inclusion record each.
    /// @param count How many to open.
    function _openExtraConstituentPools(uint256 count) private {
        for (uint256 i; i < count; ++i) {
            MockStockToken extra = new MockStockToken("Extra", "EXTR");
            // v4 requires `currency0 < currency1`, and AMPS is always `currency0` in this protocol.
            while (address(extra) <= address(amps)) {
                extra = new MockStockToken("Extra", "EXTR");
            }
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(address(amps)),
                currency1: Currency.wrap(address(extra)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
            vm.prank(address(registry));
            vault.initializePool(key, EXTRA_POOL_SQRT_PRICE_X96);
        }
    }

    /// @dev `TickMath.getSqrtPriceAtTick(0)`, i.e. 1:1. The extra pools never trade; only their existence is
    ///      measured.
    uint160 private constant EXTRA_POOL_SQRT_PRICE_X96 = 79_228_162_514_264_337_593_543_950_336;

    /// @dev Leaves the vault holding AMPS as an ERC-6909 claim, which is what §12 ruling F is about.
    ///
    /// @dev **How it used to be done, and why it cannot be any more** (audit fix, 2026-09-07). The old fixture
    ///      merged a *tiny* placement into a cell holding accrued AMPS fees: `modifyLiquidity` returns
    ///      `principal + feesAccrued`, so the settlement's `currency0` side came out **positive** and
    ///      `VaultPlacementLib._settle` minted the residue back as a claim. That netting was itself the finding
    ///      the remediation closes — it routed the AMPS-side fees straight back into the ladder without the
    ///      creator, staker and burn slices of §3.6 step 5 — so `place` now collects and splits a pool's fees
    ///      before it merges, every settlement it makes is principal, and no placement path can leave a positive
    ///      `currency0` delta any more.
    ///
    ///      The ruling is about what the vault *does* with a claim it holds, not about where the claim came from,
    ///      so the claim is minted directly: AMPS the vault already owns is settled into the PoolManager and
    ///      minted back to the vault as an ERC-6909 claim, which leaves the vault's total AMPS inventory exactly
    ///      as large as it was and moves a slice of it from the ERC-20 side to the claim side. That is precisely
    ///      the state the ruling describes.
    function _leaveAnAmpsClaim() private {
        // Up into the first ask cell, so that cell is in range and earns; then back down *past* it, so it is a
        // pure-AMPS ask again and holds the 500 bp of AMPS the sell paid. The positions are live, which is what
        // makes the pro-rata base below more than the idle balance.
        buyAmps(hubPool, address(usdg), 40e6);
        giveShares(BOB, 200e18);
        sellAmps(hubPool, amps.balanceOf(BOB));
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        ClaimMinter minter = new ClaimMinter(IPoolManager(address(poolManager)));
        vm.prank(address(vault));
        amps.transfer(address(minter), 1e18);
        minter.mintTo(address(vault), Currency.wrap(address(amps)), 1e18);
        assertGt(claimOf(address(amps)), 0, "the vault holds AMPS as a claim");
    }

    /// @dev Every feed dead, the watchdog tripped, a guardian freeze running and the timelock replaced by a
    ///      contract that reverts on any call.
    function _breakTheWorld() private {
        for (uint256 i; i < SPOKES; ++i) {
            stockFeeds[i].setRevert(true);
        }
        wethFeed.setRevert(true);
        usdgFeed.setRevert(true);
        vm.prank(GUARDIAN);
        gate.freezeProtocol(uint32(block.timestamp + 7 days));
        vm.etch(TIMELOCK, address(new AlwaysRevertsInRedeem()).code);
    }

    /// @dev Asserts that neither a read nor a write of `target`'s storage was recorded.
    function _assertUntouched(address target, string memory label) private view {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(target);
        assertEq(reads.length, 0, string.concat(label, ": no storage read"));
        assertEq(writes.length, 0, string.concat(label, ": no storage write"));
    }

    /// @dev Slot 4 `registry`, 8 `marketReference`, 9 `oracleGate`, 10 `feedRegistry`, 11 `positionValuer`,
    ///      12 `ladderPolicy`, 13 `rolloutPolicy`, 14 `standbyVault`.
    function _assertNotAPointerSlot(bytes32 slot) private pure {
        uint256 value = uint256(slot);
        assertFalse(value == 4 || (value >= 8 && value <= 14), "the redemption read a pointer slot");
    }

    /// @dev The index of `token` in `tokens`.
    function _indexOf(address[] memory tokens, address token) private pure returns (uint256) {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token) return i;
        }
        revert("token not in the payout");
    }

    /// @dev Every asset but `hostile` reached the redeemer as a real ERC-20, in the reported amount, and at least
    ///      one of them was non-zero — the point being that one refusing constituent costs only itself.
    function _assertTheHealthyAssetsWerePaid(address[] memory tokens, uint256[] memory amounts, address hostile)
        private
        view
    {
        uint256 paid;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == hostile) continue;
            assertEq(IERC20(tokens[i]).balanceOf(ALICE), amounts[i], "a healthy asset was paid in full");
            paid += amounts[i];
        }
        assertGt(paid, 0, "and the floor really did pay");
    }
}
