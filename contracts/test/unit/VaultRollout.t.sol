// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IRolloutPolicy} from "../../src/interfaces/IRolloutPolicy.sol";
import {LadderLib} from "../../src/lib/LadderLib.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotRegistry, RolloutLimitExceeded} from "../../src/types/Errors.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {PlacementFixture} from "../mocks/PlacementFixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title VaultRolloutTest
/// @notice `docs/phase3-state-model.md` §8.1's row for this file: `rolloutBpsPerDay` and `entryFloorBps` are
///         never breached, no rolled-out ask lands below `P_ref` (I32), retirement returns unfilled asks, and
///         `withdrawRetiredBids` moves what is left into claims.
///
/// @dev The three limits are re-checked by the vault *after* the schedule has proposed, so the tests that matter
///      are the ones where the schedule proposes something the vault must refuse. `IRolloutPolicy.propose` is
///      `pure`, so a hostile proposal is injected with `vm.mockCall` rather than with a flag on the stub.
contract VaultRolloutTest is PlacementFixture {
    /// @dev 200 bp of the 4,750-AMPS POL tranche: 95 AMPS a day at launch.
    uint256 internal constant DAILY_BUDGET =
        Constants.POL_SHARES * Constants.ROLLOUT_BPS_PER_DAY_DEFAULT / Constants.BPS;

    /// @dev 30% of the POL tranche: 1,425 AMPS the entry pools may never be taken below.
    uint256 internal constant ENTRY_FLOOR = Constants.POL_SHARES * Constants.ENTRY_FLOOR_BPS_DEFAULT / Constants.BPS;

    function setUp() public {
        deployPlacementWorld();
        placeGenesisLadders();
        fundPot(1000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The happy path
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A rollout takes unfilled ask inventory out of the entry pools and puts it into the spoke's ladder,
    ///         and the AMPS is conserved: what leaves the entry pools arrives in the spoke.
    function test_rolloutMovesUnfilledAsksFromTheEntryPoolsIntoTheSpoke() public {
        uint256 entryBefore = _entryAskInventory();
        uint256 spokeBefore = _askInventoryOf(spokePools[0]);
        assertGt(entryBefore, 0, "the entry pools have unfilled asks to move");

        uint256 moved = vault.rollout(constituentIds[0]);
        assertGt(moved, 0, "something moved");

        assertApproxEqAbs(_entryAskInventory(), entryBefore - moved, 1e12, "it left the entry pools");
        assertGt(_askInventoryOf(spokePools[0]), spokeBefore, "and arrived in the spoke");
        assertSweepClean("rollout");
    }

    /// @notice I32's third limit: a rolled-out ask is never placed below `P_ref`. The anchor `place` uses for
    ///         every ask is `tickOf(P_ref / P_stock)`, snapped **up** onto the grid, so the lowest cell of the
    ///         destination ladder is at or above the reference by construction.
    function test_i32_noRolledOutAskLandsBelowPRef() public {
        vault.rollout(constituentIds[0]);

        int24 refTick = PriceLib.fairTick(vault.pRefX18(), STOCK_USD8[0], 18, TICK_SPACING);
        PlacementRecord[] memory records = ladderOf(spokePools[0]);
        assertGt(records.length, 0, "the spoke has a ladder");
        for (uint256 i; i < records.length; ++i) {
            if (!records[i].above) continue;
            assertGe(records[i].lowerTick, refTick, "no ask below P_ref");
        }
    }

    /// @notice `rollout` is permissionless and pays the caller a bounty out of the segregated pot.
    function test_rolloutIsPermissionlessAndBountied() public {
        uint256 before = usdg.balanceOf(KEEPER);
        vm.prank(KEEPER);
        assertGt(vault.rollout(constituentIds[0]), 0, "anyone may call it");
        assertGt(usdg.balanceOf(KEEPER), before, "and it pays the caller");
    }

    /// @notice A schedule that reverts proposes nothing, which is a no-op: an unpaid keeper call costs the caller
    ///         gas and nothing else, and a broken policy pointer cannot brick the path.
    function test_aRolloutPolicyThatRevertsIsANoOp() public {
        vm.mockCallRevert(address(rolloutPolicy), abi.encodeWithSelector(rolloutPolicy.propose.selector), "policy down");
        assertEq(vault.rollout(constituentIds[0]), 0, "nothing moved, nothing reverted");
    }

    // -------------------------------------------------------------------------------------------------------------
    // I32 — the two limits the vault re-checks
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The daily budget: at most `rolloutBpsPerDay` of the POL tranche moves per rolling 24 hours, and a
    ///         schedule that proposes more is **refused**, not obeyed.
    function test_i32_dailyBudgetIsReCheckedAndRefusesAnOverProposal() public {
        _forceProposal(DAILY_BUDGET + 1e18);
        vm.expectPartialRevert(RolloutLimitExceeded.selector);
        vault.rollout(constituentIds[0]);
    }

    /// @notice And the budget is a rolling 24 hours: whatever the schedule proposes, one day's moves add up to
    ///         at most `rolloutBpsPerDay` of the POL tranche, and the window rolls forward a day later.
    function test_i32_theBudgetIsARolling24Hours() public {
        uint256 spent;
        for (uint256 i; i < 12; ++i) {
            spent += vault.rollout(constituentIds[0]);
            warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        }
        assertGt(spent, 0, "the window was used");
        assertLe(spent, DAILY_BUDGET, "and never past its budget");

        // Force the schedule to ask for the whole budget again: inside the window it is refused.
        _forceProposal(DAILY_BUDGET);
        vm.expectPartialRevert(RolloutLimitExceeded.selector);
        vault.rollout(constituentIds[0]);

        // A day later the window has rolled and the same proposal is inside budget again.
        warpBy(Constants.ONE_DAY);
        syncMarket();
        assertGt(vault.rollout(constituentIds[0]), 0, "a day later the window has rolled");
    }

    /// @notice Cumulative moves inside one window never exceed the budget, whatever the schedule proposes.
    function test_i32_cumulativeMovesStayInsideTheDailyBudget() public {
        uint256 moved;
        for (uint256 i; i < 4; ++i) {
            moved += vault.rollout(constituentIds[i % SPOKES]);
            warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
            syncMarket();
        }
        assertLe(moved, DAILY_BUDGET, "the rolling window held");
    }

    /// @notice The entry-pool floor: the entry pools may never be taken below `entryFloorBps` of the POL tranche,
    ///         and a schedule that would is refused.
    function test_i32_entryFloorIsReCheckedAndRefusesAnOverProposal() public {
        // Raise the daily budget out of the way so the floor is the binding limit.
        vm.prank(TIMELOCK);
        vault.setRolloutParams(Constants.ROLLOUT_BPS_PER_DAY_MAX, Constants.ENTRY_FLOOR_BPS_DEFAULT);

        uint256 room = _entryAskInventory() - ENTRY_FLOOR;
        _forceProposal(room + 1e18);
        vm.expectPartialRevert(RolloutLimitExceeded.selector);
        vault.rollout(constituentIds[0]);
    }

    /// @notice And a floor already at or above what the entry pools hold stops rollout dead: nothing moves, and
    ///         it is a no-op rather than a revert, because "nothing is due" is a valid answer (§5).
    function test_i32_aBindingFloorStopsRolloutDead() public {
        vm.prank(TIMELOCK);
        vault.setRolloutParams(Constants.ROLLOUT_BPS_PER_DAY_MAX, Constants.ENTRY_FLOOR_BPS_MAX);

        uint256 entryBefore = _entryAskInventory();
        assertLt(
            entryBefore,
            Constants.POL_SHARES * Constants.ENTRY_FLOOR_BPS_MAX / Constants.BPS,
            "the floor is above what the entry pools hold"
        );

        assertEq(vault.rollout(constituentIds[0]), 0, "nothing moved");
        assertEq(_entryAskInventory(), entryBefore, "and the entry pools are untouched");
    }

    /// @notice The floor holds across a run of rollouts at the maximum daily rate.
    function test_i32_theEntryPoolsNeverGoBelowTheFloor() public {
        vm.prank(TIMELOCK);
        vault.setRolloutParams(Constants.ROLLOUT_BPS_PER_DAY_MAX, Constants.ENTRY_FLOOR_BPS_DEFAULT);

        for (uint256 i; i < 8; ++i) {
            vault.rollout(constituentIds[i % SPOKES]);
            warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
            assertGe(_entryAskInventory(), ENTRY_FLOOR, "the entry pools never went below the floor");
        }
    }

    /// @notice Only *unfilled* ask cells move: a filled cell's counter asset is the proceeds of the ladder at the
    ///         prices that raised them, and rollout never touches it (I29, I35).
    function test_rolloutNeverTouchesAFilledCell() public {
        // Small enough that `P_mkt` and the hub stay inside `PLACEMENT_DIVERGENCE_TICKS` of each other, so what
        // is under test is the rollout and not the divergence check.
        buyAmps(hubPool, address(usdg), 3e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 hubUsdgBefore = _poolUsdg();
        vault.rollout(constituentIds[0]);
        assertEq(_poolUsdg(), hubUsdgBefore, "not one wei of counter asset moved");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Retirement
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Retirement closes the market and zeroes the rollout weight, so the schedule never allocates to a
    ///         retired name again — which is how "retirement returns unfilled asks" is implemented: the weight
    ///         goes to zero and the next rollout moves the inventory to the names that still have one.
    function test_retirementZeroesTheRolloutWeightSoNothingMoreIsAllocated() public {
        vm.prank(TIMELOCK);
        registry.retireConstituent(constituentIds[0]);
        assertEq(registry.constituent(constituentIds[0]).rolloutWeightBps, 0, "weight zeroed");

        // A retired name gets nothing: the schedule's `share` term is zero.
        assertEq(vault.rollout(constituentIds[0]), 0, "no allocation to a retired name");
    }

    /// @notice `withdrawRetiredBids` is registry-only and moves a retired spoke's remaining bid inventory out of
    ///         its positions and into ERC-6909 claims, where `A` still values it and `redeemProRata` still pays
    ///         it. The asks are left alone.
    function test_withdrawRetiredBidsMovesBidsIntoClaimsAndLeavesAsksAlone() public {
        // Give the spoke a bid ladder out of bonded collateral.
        bondDeposit(address(stocks[0]), 20e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        assertGt(vault.deployBonded(constituentIds[0]), 0, "the spoke has bids");

        uint256 asksBefore = _askInventoryOf(spokePools[0]);
        uint256 claimsBefore = claimOf(address(stocks[0]));

        vm.prank(TIMELOCK);
        registry.retireConstituent(constituentIds[0]);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.expectRevert(abi.encodeWithSelector(NotRegistry.selector, ALICE));
        vm.prank(ALICE);
        vault.withdrawRetiredBids(constituentIds[0]);

        vm.prank(TIMELOCK);
        registry.withdrawRetiredBids(constituentIds[0]);

        assertGt(claimOf(address(stocks[0])), claimsBefore, "the stock came back as claims");
        assertEq(_askInventoryOf(spokePools[0]), asksBefore, "the asks are untouched");

        PlacementRecord[] memory records = ladderOf(spokePools[0]);
        for (uint256 i; i < records.length; ++i) {
            if (!records[i].above) assertEq(records[i].liquidity, 0, "every bid cell is empty");
        }
        assertSweepClean("withdrawRetiredBids");
    }

    // -------------------------------------------------------------------------------------------------------------
    // deployBonded
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Bonded stock becomes the spoke's bid ladder: four halvings below the market, weighted toward the
    ///         tick, and every cell strictly below it (I9).
    function test_deployBondedPlacesFourHalvingsBelowTheMarket() public {
        bondDeposit(address(stocks[0]), 20e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 placed = vault.deployBonded(constituentIds[0]);
        assertEq(placed, 20e18, "the whole idle claim was placed");

        int24 bound = PriceLib.alignTick(tickOf(spokePools[0]), TICK_SPACING, false);
        PlacementRecord[] memory records = ladderOf(spokePools[0]);
        uint256 bids;
        uint256 total;
        for (uint256 i; i < records.length; ++i) {
            if (records[i].above) continue;
            assertLe(records[i].upperTick, bound, "strictly below the market");
            total += records[i].amount;
            ++bids;
        }
        assertEq(bids, Constants.BOND_BID_HALVINGS_DEFAULT, "four halvings");
        assertEq(total, 20e18, "and the split is exact");
    }

    /// @notice `deployBonded` is a no-op below `deployThresholdUsd18`, so it cannot be used to drain the bounty
    ///         pot a wei at a time (§10 ruling 15).
    function test_deployBondedIsANoOpBelowTheThreshold() public {
        // $100 of NVDX at $180 is 0.5555... tokens; a tenth of that is well under the floor.
        bondDeposit(address(stocks[0]), 0.05e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 before = usdg.balanceOf(KEEPER);
        vm.prank(KEEPER);
        assertEq(vault.deployBonded(constituentIds[0]), 0, "below the threshold, nothing is deployed");
        assertEq(usdg.balanceOf(KEEPER), before, "and nothing is paid for it");

        // Top the collateral up past $100 and the same call fires.
        bondDeposit(address(stocks[0]), 1e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        assertGt(vault.deployBonded(constituentIds[0]), 0, "above it, it fires");
        assertGt(usdg.balanceOf(KEEPER), before, "and pays");
    }

    // -------------------------------------------------------------------------------------------------------------
    // §12 ruling E — the bountied paths merge and idle rather than revert
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `rollout` at a full live-cell budget does not revert: it moves what it can into cells the spoke
    ///         already has and leaves the rest as idle inventory.
    function test_e_rolloutDoesNotRevertWhenTheBudgetIsFull() public {
        // Give the spoke a ladder first, so there is something to merge into.
        vault.rollout(constituentIds[0]);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        warpBy(Constants.ONE_DAY);
        syncMarket();

        uint256 before = _askInventoryOf(spokePools[0]);
        forceLiveCells(Constants.MAX_LIVE_CELLS);

        vm.prank(KEEPER);
        vault.rollout(constituentIds[0]);
        assertEq(vault.liveCells(), Constants.MAX_LIVE_CELLS, "no new cell opened");
        assertGe(_askInventoryOf(spokePools[0]), before, "and the spoke did not lose depth");
    }

    /// @notice `deployBonded` at a full budget likewise: the bonded stock that cannot open a cell stays as an
    ///         ERC-6909 claim, where `A` still values it and redemption still pays it.
    function test_e_deployBondedDoesNotRevertWhenTheBudgetIsFull() public {
        bondDeposit(address(stocks[0]), 20e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        forceLiveCells(Constants.MAX_LIVE_CELLS);

        vm.prank(KEEPER);
        uint256 placed = vault.deployBonded(constituentIds[0]);
        assertEq(placed, 0, "nothing could be placed with no cell to open");
        assertEq(vault.liveCells(), Constants.MAX_LIVE_CELLS, "and nothing was opened");
        assertGt(claimOf(address(stocks[0])), 0, "the collateral is still there, as a claim");
    }

    /// @notice The count stays exact across a rollout, which both closes source cells and opens destination ones.
    function test_e_theLiveCellCountIsExactAcrossARollout() public {
        assertEq(vault.liveCells(), countLiveCells(), "exact before");
        vault.rollout(constituentIds[0]);
        assertEq(vault.liveCells(), countLiveCells(), "exact after");
    }

    /// @notice And across `withdrawRetiredBids`, which only ever closes.
    function test_e_theLiveCellCountIsExactAcrossWithdrawRetiredBids() public {
        bondDeposit(address(stocks[0]), 20e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vault.deployBonded(constituentIds[0]);

        uint32 live = vault.liveCells();
        vm.prank(TIMELOCK);
        registry.retireConstituent(constituentIds[0]);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(TIMELOCK);
        registry.withdrawRetiredBids(constituentIds[0]);

        assertLt(vault.liveCells(), live, "the bid cells left the count");
        assertEq(vault.liveCells(), countLiveCells(), "and it is exact");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Forces the schedule's next answer, so the vault's own re-check is what is under test.
    function _forceProposal(uint256 amountAmps) private {
        vm.mockCall(
            address(rolloutPolicy),
            abi.encodeWithSelector(rolloutPolicy.propose.selector),
            abi.encode(
                IRolloutPolicy.RolloutDecision({amountAmps: amountAmps, dailyBudgetRemaining: 0, floorBinding: false})
            )
        );
    }

    /// @dev The AMPS held by a pool's unfilled ask cells, which is what the schedule is measured against.
    function _askInventoryOf(PoolId poolId) private view returns (uint256 inventory) {
        int24 tick = tickOf(poolId);
        PlacementRecord[] memory records = ladderOf(poolId);
        for (uint256 i; i < records.length; ++i) {
            if (!records[i].above || records[i].liquidity == 0 || records[i].lowerTick <= tick) continue;
            inventory += askAmpsIn(records[i]);
        }
    }

    /// @dev The two entry pools' unfilled ask inventory.
    function _entryAskInventory() private view returns (uint256) {
        return _askInventoryOf(hubPool) + _askInventoryOf(wethPool);
    }

    /// @dev The USDG the PoolManager holds, i.e. everything the hub's bids and proceeds are made of.
    function _poolUsdg() private view returns (uint256) {
        return usdg.balanceOf(address(poolManager));
    }
}
