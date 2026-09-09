// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IBountyPot} from "../../src/interfaces/IBountyPot.sol";
import {IPoolRegistry} from "../../src/interfaces/IPoolRegistry.sol";
import {IRolloutPolicy} from "../../src/interfaces/IRolloutPolicy.sol";
import {LadderLib} from "../../src/lib/LadderLib.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotRegistry, RolloutLimitExceeded} from "../../src/types/Errors.sol";
import {ConstituentStatus, PlacementRecord} from "../../src/types/Types.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {PlacementFixture} from "../mocks/PlacementFixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title VaultRolloutTest
/// @notice `docs/phase3-state-model.md` §8.1's row for this file: `rolloutBpsPerDay` and `entryFloorBps` are
///         never breached, no rolled-out ask lands below `P_ref` (I32), retirement returns unfilled asks, and
///         `withdrawRetiredBids` moves what is left into claims.
///
/// @dev The three limits are re-checked by the vault *after* the schedule has proposed, so the tests that matter
///      are the ones where the schedule proposes something the vault must refuse. `IRolloutPolicy.propose` is
///      `pure`, so a hostile proposal is injected with `vm.mockCall` rather than with a flag on the stub.
contract VaultRolloutTest is PlacementFixture {
    /// @dev 200 bp of the 9,000-AMPS POL tranche: 180 AMPS a day at launch.
    uint256 internal constant DAILY_BUDGET =
        Constants.POL_SHARES * Constants.ROLLOUT_BPS_PER_DAY_DEFAULT / Constants.BPS;

    /// @dev 30% of the POL tranche: 2,700 AMPS the entry pools may never be taken below.
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

    /// @notice `rollout` is permissionless and pays the caller a bounty sized to the inventory it **measured**
    ///         itself placing, at the reference price (§12.4 ruling W).
    function test_rolloutIsPermissionlessAndBountied() public {
        uint256 before = usdg.balanceOf(KEEPER);
        uint256 pRefBefore = vault.pRefX18();

        vm.recordLogs();
        vm.prank(KEEPER);
        uint256 moved = vault.rollout(constituentIds[0]);
        assertGt(moved, 0, "anyone may call it");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 movedAmps, uint256 placedAmps) = _rolloutIn(logs);
        assertEq(movedAmps, moved, "the log agrees with the return value");
        assertEq(placedAmps, moved, "and with an empty cell budget the whole move was placed");

        (uint256 workValueUsd18,, uint256 paidRaw,) = _bountyIn(logs);
        assertEq(workValueUsd18, (placedAmps * pRefBefore) / 1e18, "the AMPS placed, valued at P_ref");
        assertGt(paidRaw, 0, "and it pays the caller");
        assertEq(usdg.balanceOf(KEEPER) - before, paidRaw, "exactly what the pot reported");
    }

    /// @notice **The finding this closes** (second wave). `place(strictBudget = false)` may place less than
    ///         rollout harvested — it merges into cells that already exist and leaves the rest idle rather than
    ///         reverting (§12 ruling E) — and the first remediation charged the 24-hour window on `placed`.
    ///         That was the wrong side of the trade: inventory leaves the entry pools on the **harvest**, whether
    ///         or not the destination takes it, so with the live-cell budget saturated `placed` was zero, the
    ///         window was never charged, and the same call could be repeated every sixty seconds — the entry
    ///         pools emptied to `entryFloorBps` at a full daily allowance a minute. The window is charged on
    ///         `moved`; the **bounty** stays on `placed`, because the work the keeper created is what reached the
    ///         spoke; and the remainder goes back into the entry pools it came from in the same call.
    function test_theWindowIsChargedOnWhatMovedAndTheBountyOnWhatWasPlaced() public {
        // A ladder wider than the cells the spoke already holds, and a full cell budget: the four cells the
        // genesis seed ask never opened cannot be opened now, so the destination takes only what it can merge and
        // the rest of the harvest stays idle.
        vm.prank(TIMELOCK);
        vault.setLadderShape(
            Constants.LADDER_TILT_X18_DEFAULT,
            Constants.LADDER_DOUBLINGS_MAX,
            Constants.SEED_HALVINGS_DEFAULT,
            Constants.BOND_BID_HALVINGS_DEFAULT
        );
        forceLiveCells(Constants.MAX_LIVE_CELLS);

        uint256 pRefBefore = vault.pRefX18();
        vm.recordLogs();
        vm.prank(KEEPER);
        uint256 moved = vault.rollout(constituentIds[0]);
        assertGt(moved, 0, "the entry pools gave up inventory");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 movedAmps, uint256 placedAmps) = _rolloutIn(logs);
        assertEq(movedAmps, moved, "the log carries what was harvested");
        assertGt(placedAmps, 0, "the ladder merged into the cells it had");
        assertLt(placedAmps, movedAmps, "but could not take all of it");

        assertEq(_rolloutMoved24h(), movedAmps, "the window was charged what left the entry pools");

        (uint256 workValueUsd18,,,) = _bountyIn(logs);
        assertEq(workValueUsd18, (placedAmps * pRefBefore) / 1e18, "and the bounty only what reached the spoke");
    }

    /// @notice The other half of the same fix: what the destination could not take is put **back** into the entry
    ///         pools' asks in the same call, at the same reference anchor, rather than left idle in the vault. The
    ///         source pools' cooldowns are taken once, after that re-placement, which is what makes it reachable
    ///         at all.
    function test_theUnplacedRemainderGoesBackIntoTheEntryPools() public {
        vm.prank(TIMELOCK);
        vault.setLadderShape(
            Constants.LADDER_TILT_X18_DEFAULT,
            Constants.LADDER_DOUBLINGS_MAX,
            Constants.SEED_HALVINGS_DEFAULT,
            Constants.BOND_BID_HALVINGS_DEFAULT
        );
        forceLiveCells(Constants.MAX_LIVE_CELLS);

        uint256 entryBefore = _entryAskInventory();
        vm.recordLogs();
        vm.prank(KEEPER);
        uint256 moved = vault.rollout(constituentIds[0]);
        assertGt(moved, 0, "the entry pools gave up inventory");

        (uint256 movedAmps, uint256 placedAmps) = _rolloutIn(vm.getRecordedLogs());
        assertLt(placedAmps, movedAmps, "the destination could not take all of it");

        // The whole point: the entry pools are not down by the gap. Whatever the spoke refused went back into
        // cells the harvest had only partly emptied, so the drawdown is bounded by what actually reached the
        // spoke plus the residue no cell could take.
        assertGt(_entryAskInventory(), entryBefore - movedAmps, "the remainder did not stay idle");
        assertEq(vault.lastPlacementAt(hubPool), uint32(block.timestamp), "the hub's cooldown was taken once");
        assertSweepClean("rollout with a partial destination");
    }

    /// @notice And the property the finding is really about: **with the live-cell budget saturated, repeated
    ///         `rollout` calls cannot move more than the daily allowance.** Under the old accounting each call
    ///         charged `placed`, which was zero, so the window never advanced and the entry pools could be drained
    ///         at one full allowance per `PLACEMENT_COOLDOWN_SECONDS`.
    function test_i32_repeatedRolloutsAtASaturatedCellBudgetStayInsideTheDailyAllowance() public {
        uint256 entryBefore = _entryAskInventory();
        uint256 moved;

        for (uint256 i; i < 12; ++i) {
            // Re-saturate: the harvest closes source cells and hands the budget back, which is exactly what an
            // attacker would rely on to keep the destination unable to open one.
            forceLiveCells(Constants.MAX_LIVE_CELLS);
            vm.prank(KEEPER);
            moved += vault.rollout(constituentIds[i % SPOKES]);
            warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
            syncMarket();
        }

        assertLe(moved, DAILY_BUDGET, "twelve minutes cannot spend more than one day's allowance");
        assertGe(_entryAskInventory(), entryBefore - DAILY_BUDGET, "and the entry pools are inside the same bound");
        assertGe(_entryAskInventory(), ENTRY_FLOOR, "never below the floor either");
    }

    /// @notice The move is in the log: `Rollout` names the destination and both the harvested and the placed
    ///         amounts, so an indexer no longer has to reconstruct it from a `Placement` plus the entry pools'
    ///         negative `ModifyLiquidity` in the same transaction (§12.4 ruling Y).
    function test_rolloutEmitsTheMove() public {
        vm.recordLogs();
        uint256 moved = vault.rollout(constituentIds[0]);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != IAmpsVault.Rollout.selector) continue;
            assertEq(uint256(logs[i].topics[1]), constituentIds[0], "the destination constituent");
            assertEq(logs[i].topics[2], PoolId.unwrap(spokePools[0]), "and its pool");
            (uint256 movedAmps, uint256 placedAmps) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(movedAmps, moved, "the harvested amount");
            assertGt(placedAmps, 0, "and what the destination ladder took");
            assertLe(placedAmps, movedAmps, "never more than was moved");
            seen = true;
        }
        assertTrue(seen, "Rollout was emitted");
    }

    /// @notice A rollout that moves nothing pays nothing: the schedule proposing zero returns before the pot is
    ///         ever called, so an unpaid keeper call costs the caller gas and the protocol nothing.
    function test_aRolloutThatMovesNothingPaysNothing() public {
        uint256 potBefore = pot.balance();
        vm.mockCallRevert(address(rolloutPolicy), abi.encodeWithSelector(rolloutPolicy.propose.selector), "down");

        vm.prank(KEEPER);
        assertEq(vault.rollout(constituentIds[0]), 0, "nothing moved");
        assertEq(pot.balance(), potBefore, "and the pot is untouched");
        assertEq(usdg.balanceOf(KEEPER), 0, "the caller earned nothing");
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

    /// @notice **Audit finding 5.** A harvest's realised fees are fees, not principal. `modifyLiquidity` returns
    ///         `principal + feesAccrued` in one delta, and this path used to keep only the sum — so a retired
    ///         spoke's accrued fees were minted as plain vault claims, skipping the creator's slice and the
    ///         mandatory AMPS-side burn that every other realisation pays.
    ///
    /// @dev The bid cells earn their AMPS-side fees from sells that walk the price down into them, which is
    ///      exactly what this test does before retiring the name.
    function test_f05_aRetiredBidWithdrawalRoutesItsAccruedFeesThroughTheSplit() public {
        bondDeposit(address(stocks[0]), 20e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        assertGt(vault.deployBonded(constituentIds[0]), 0, "the spoke has bids");

        // A sell into the spoke pays its fee in AMPS, to the bid cells the price walks into. It is deliberately
        // small: there is no liquidity between the tick and the top bid cell, so any sell reaches the bids, and
        // the AMPS it leaves in them is written off by the valuer (I5) — i.e. it is a real NAV move, and a large
        // one would trip the R1 bleed bound for a reason that has nothing to do with the fee split under test.
        giveShares(BOB, 20e18);
        sellAmps(spokePools[0], 2e18);
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.prank(TIMELOCK);
        registry.retireConstituent(constituentIds[0]);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 creatorBefore = amps.balanceOf(CREATOR);
        uint256 supplyBefore = amps.totalSupply();
        uint256 creatorClaimBefore = poolManager.balanceOf(CREATOR, uint256(uint160(address(stocks[0]))));

        vm.prank(TIMELOCK);
        registry.withdrawRetiredBids(constituentIds[0]);

        assertGt(supplyBefore - amps.totalSupply(), 0, "the AMPS-side fees were burned, not banked as inventory");
        assertGt(amps.balanceOf(CREATOR) - creatorBefore, 0, "and the creator took their slice of them");
        // The counter side of the same removal is principal, which stays with the vault as claims; whatever fee
        // share the creator is owed of it arrives as a claim of their own and never as an in-kind transfer.
        assertGe(
            poolManager.balanceOf(CREATOR, uint256(uint160(address(stocks[0])))),
            creatorClaimBefore,
            "the counter-side slice is a claim"
        );
        assertSweepClean("retired-bid fee split");
    }

    /// @notice **Audit finding 15.** A cell the buyback owns is not rollout's to move. Every unfilled ask cell
    ///         satisfies the second half of §3.5's predicate by construction, so a cell whose upper bound the mark
    ///         had crossed — AMPS the vault sold on the way up and bought back on the way down — was eligible for
    ///         the harvest, and a rollout ordered before the next `compound` moved it into a spoke's **ask** ladder
    ///         to be sold a second time instead of burned. Rollout is permissionless, so that ordering is
    ///         anybody's to choose.
    function test_f15_aRolloutLeavesABoughtBackCellForTheBurn() public {
        // The hub's whole ask ladder is under the mark: every cell of it is bought-back inventory.
        int24 highest;
        PlacementRecord[] memory hubRecords = ladderOf(hubPool);
        for (uint256 i; i < hubRecords.length; ++i) {
            if (hubRecords[i].above && hubRecords[i].upperTick > highest) highest = hubRecords[i].upperTick;
        }
        hook.setHighWaterTick(hubPool, highest);

        uint256 hubBefore = _askInventoryOf(hubPool);
        uint256 wethBefore = _askInventoryOf(wethPool);

        vm.prank(KEEPER);
        uint256 moved = vault.rollout(constituentIds[0]);
        assertGt(moved, 0, "the rollout still ran");

        assertEq(_askInventoryOf(hubPool), hubBefore, "and took nothing out of the hub's marked cells");
        assertLt(_askInventoryOf(wethPool), wethBefore, "everything it moved came from the unmarked pool");

        // And the inventory it left alone is burned by the next `compound`, which is where it was always going.
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        syncMarket();
        uint256 supplyBefore = amps.totalSupply();
        vm.prank(KEEPER);
        (, uint256 burned) = vault.compound(hubPool);
        assertGt(burned, 0, "the compound burned the cells the rollout preserved");
        assertEq(supplyBefore - amps.totalSupply(), burned, "and the supply agrees");
    }

    /// @notice **Audit finding 7.** The EIP-150 reserve compounds with the hops. `rollout` reaches `payBounty`
    ///         through two live `DELEGATECALL` frames, and correcting for a single 63/64 reserve overstated the
    ///         gas by about `txGasLimit / 64` — a term the *caller* chooses, so a keeper could inflate the pot's
    ///         own 3x gas cap simply by sending the job with a large gas limit. With the two-hop correction the
    ///         reported figure is the job's, and sending the same job with ten times the gas limit does not change
    ///         it.
    function test_f07_theTwoHopGasAllowanceIsIndependentOfTheCallersGasLimit() public {
        vm.prank(TIMELOCK);
        pot.setChipBps(Constants.CHIP_BPS_MAX);

        uint256 snapshot = vm.snapshotState();
        uint256 reportedSmall = _rolloutReportedGas(8_000_000);
        vm.revertToState(snapshot);
        uint256 reportedBig = _rolloutReportedGas(40_000_000);

        assertGt(reportedSmall, 0, "the job was measured at all");
        // A single reserve on a two-hop path leaves `limit / 64` of the caller's choosing in the figure: at a 40M
        // limit that is ~625k gas against ~125k at 8M, a difference several times the tolerance below.
        assertApproxEqRel(reportedBig, reportedSmall, 0.05e18, "the same job, whatever the caller's gas limit");
    }

    /// @dev One rollout sent with `gasLimit`, and the gas figure the vault handed the pot, recovered from the
    ///      payment the 3x cap produced. Mirrors `VaultCompound.t.sol`'s single-hop version.
    function _rolloutReportedGas(uint256 gasLimit) private returns (uint256 reportedGas) {
        vm.recordLogs();
        vm.prank(KEEPER);
        this.rolloutWithGas{gas: gasLimit}(constituentIds[0]);

        (, uint256 paidUsd18,,) = _bountyIn(vm.getRecordedLogs());
        uint256 usdPerGas = (Constants.KEEPER_BASEFEE_FLOOR_WEI * WETH_USD8) / 1e8;
        reportedGas = paidUsd18 / Constants.KEEPER_GAS_CAP_MULTIPLE / usdPerGas;
    }

    /// @notice External wrapper so a rollout can be sent with an explicit gas limit.
    function rolloutWithGas(uint16 constituentId) external returns (uint256 moved) {
        moved = vault.rollout(constituentId);
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

        // Top the collateral up past $100 and the same call fires, reporting the collateral it placed at the
        // same feed price the threshold was tested against (§12.4 ruling W).
        bondDeposit(address(stocks[0]), 1e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.recordLogs();
        vm.prank(KEEPER);
        uint256 placed = vault.deployBonded(constituentIds[0]);
        assertGt(placed, 0, "above it, it fires");

        (uint256 workValueUsd18,, uint256 paidRaw,) = _lastBountyPaid();
        assertEq(
            workValueUsd18,
            PriceLib.counterValueUsd18(placed, 18, STOCK_USD8[0]),
            "the collateral placed, at its feed price"
        );
        assertGt(paidRaw, 0, "and pays");
        assertEq(usdg.balanceOf(KEEPER) - before, paidRaw, "exactly what the pot reported");
    }

    /// @notice **The finding this closes.** `deployBonded` checked that the constituent existed and never that it
    ///         was live. `retireConstituent` followed by `withdrawRetiredBids` — the very pair that empties a
    ///         retired spoke's bids into ERC-6909 claims — therefore left that stock idle and deployable, so
    ///         anyone could re-place the whole book as bids in the retired pool, for a bounty, as often as the
    ///         registry withdrew it.
    function test_deployBondedRefusesARetiredConstituent() public {
        bondDeposit(address(stocks[0]), 20e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        assertGt(vault.deployBonded(constituentIds[0]), 0, "an active name deploys");

        vm.prank(TIMELOCK);
        registry.retireConstituent(constituentIds[0]);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(TIMELOCK);
        registry.withdrawRetiredBids(constituentIds[0]);

        uint256 idle = claimOf(address(stocks[0]));
        assertGt(idle, 0, "the withdrawal put the stock back into claims, where redemption pays it");
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 keeperBefore = usdg.balanceOf(KEEPER);
        vm.prank(KEEPER);
        assertEq(vault.deployBonded(constituentIds[0]), 0, "and a retired name refuses to re-place it");
        assertEq(claimOf(address(stocks[0])), idle, "the claim is exactly where the withdrawal left it");
        assertEq(usdg.balanceOf(KEEPER), keeperBefore, "and nothing was paid for the attempt");
    }

    /// @notice The registry's `constituent()` view overlays `FROZEN` on a frozen name, so the same line refuses a
    ///         frozen name — "no bonds, no rollout, no placements" — and lets it deploy again once the freeze is
    ///         lifted.
    function test_deployBondedRefusesAFrozenConstituent() public {
        bondDeposit(address(stocks[0]), 20e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        _setCaFreeze(constituentIds[0], true);
        assertEq(
            uint256(registry.constituent(constituentIds[0]).status),
            uint256(ConstituentStatus.FROZEN),
            "the view reports the freeze"
        );

        vm.prank(KEEPER);
        assertEq(vault.deployBonded(constituentIds[0]), 0, "a frozen name takes no placement");

        _setCaFreeze(constituentIds[0], false);
        vm.prank(KEEPER);
        assertGt(vault.deployBonded(constituentIds[0]), 0, "and deploys again once the freeze is lifted");
    }

    /// @dev Sets or clears the governance corporate-action freeze, which is what `constituent()` overlays as
    ///      `FROZEN` and the only freeze this fixture can reach without a gate callback.
    function _setCaFreeze(uint16 constituentId, bool frozen) private {
        IPoolRegistry.ReconfigureParams memory params;
        params.setCaFreezeOverride = true;
        params.caFreezeOverride = frozen;
        vm.prank(TIMELOCK);
        registry.reconfigureConstituent(constituentId, params);
    }

    // -------------------------------------------------------------------------------------------------------------
    // §5 — `spokeHasDepth`
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **The finding this closes.** `spokeHasDepth` was a hard-coded `false`, so every spoke was
    ///         permanently treated as depthless and the whole `DEPTHLESS_DISCOUNT_X18` branch of the launch
    ///         schedule was unreachable: rollout ran at half rate into exactly the spokes §5 prefers — the ones
    ///         bonds and buys have already given a bid side. It is now read from the vault's own records.
    function test_aSpokeWithBidDepthGetsTheUndiscountedShare() public {
        bondDeposit(address(stocks[0]), 20e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        assertGt(vault.deployBonded(constituentIds[0]), 0, "the spoke has a bid ladder now");
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        syncMarket();

        IRolloutPolicy.RolloutRequest memory request = _request(constituentIds[0], true);
        uint256 undiscounted = rolloutPolicy.propose(request).amountAmps;
        request.spokeHasDepth = false;
        uint256 discounted = rolloutPolicy.propose(request).amountAmps;
        assertGt(undiscounted, discounted, "depth is worth the whole DEPTHLESS_DISCOUNT_X18");

        uint256 moved = vault.rollout(constituentIds[0]);
        assertApproxEqAbs(moved, undiscounted, 1e12, "the spoke was allocated its undiscounted share");
    }

    /// @notice And the other side of the same branch: a spoke with nothing but asks in it is still depthless and
    ///         still receives half a share — which is how it gets a market at all.
    function test_aSpokeWithNoBidDepthStillGetsTheDiscountedShare() public {
        IRolloutPolicy.RolloutRequest memory request = _request(constituentIds[0], false);
        uint256 discounted = rolloutPolicy.propose(request).amountAmps;
        assertGt(discounted, 0, "a depthless spoke is still allocated something");

        uint256 moved = vault.rollout(constituentIds[0]);
        assertApproxEqAbs(moved, discounted, 1e12, "at the discounted share");
    }

    /// @dev The `RolloutRequest` the vault builds for `constituentId` right now, with `spokeHasDepth` supplied by
    ///      the caller so a test can price both branches of the schedule against the same state.
    function _request(uint16 constituentId, bool spokeHasDepth)
        private
        view
        returns (IRolloutPolicy.RolloutRequest memory request)
    {
        request = IRolloutPolicy.RolloutRequest({
            polTrancheAmps: Constants.POL_SHARES,
            entryInventoryAmps: _entryAskInventory(),
            movedLast24hAmps: _rolloutMoved24h(),
            rolloutBpsPerDay: vault.rolloutBpsPerDay(),
            entryFloorBps: vault.entryFloorBps(),
            targetWeightBps: registry.constituent(constituentId).targetWeightBps,
            currentWeightBps: registry.currentWeightBps(constituentId),
            rolloutWeightBps: registry.constituent(constituentId).rolloutWeightBps,
            spokeHasDepth: spokeHasDepth
        });
    }

    /// @dev The AMPS charged against the current 24-hour rollout window: slot 15 [0..127], the layout
    ///      `docs/phase2-state-model.md` §1.1 fixes and `test/unit/VaultLayout.t.sol` pins. The vault has no
    ///      getter for it, which is why this reads the slot.
    function _rolloutMoved24h() private view returns (uint256 moved) {
        return uint256(uint128(uint256(vm.load(address(vault), bytes32(uint256(15))))));
    }

    /// @dev The last `Rollout` in `logs`.
    function _rolloutIn(Vm.Log[] memory logs) private view returns (uint256 movedAmps, uint256 placedAmps) {
        for (uint256 i = logs.length; i != 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(vault) || entry.topics[0] != IAmpsVault.Rollout.selector) continue;
            return abi.decode(entry.data, (uint256, uint256));
        }
        revert("no Rollout");
    }

    /// @dev The last `BountyPaid` in `logs`.
    function _bountyIn(Vm.Log[] memory logs)
        private
        view
        returns (uint256 workValueUsd18, uint256 paidUsd18, uint256 paidRaw, bytes32 reason)
    {
        for (uint256 i = logs.length; i != 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(pot) || entry.topics[0] != IBountyPot.BountyPaid.selector) continue;
            return abi.decode(entry.data, (uint256, uint256, uint256, bytes32));
        }
        revert("no BountyPaid");
    }

    /// @dev The last `BountyPaid` in the recorded logs. `vm.recordLogs()` must have been armed before the call;
    ///      this **drains** the buffer, so a test that also wants the `Rollout` reads the logs once itself.
    function _lastBountyPaid()
        private
        view
        returns (uint256 workValueUsd18, uint256 paidUsd18, uint256 paidRaw, bytes32 reason)
    {
        return _bountyIn(vm.getRecordedLogs());
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

    /// @notice **The finding this closes.** `place` wrote `cooldown[poolId]` unconditionally, and the two
    ///         permissionless paths reach it with `strictBudget == false`: a `deployBonded` that could open no
    ///         cell placed **nothing** and still dated the pool, so anyone could deny a real `compound` — or a
    ///         governance `place` — on that pool for sixty seconds, once a minute, for a gas fee. The cooldown is
    ///         a placement's, so a call that placed nothing does not take it.
    function test_aDeployBondedThatPlacesNothingDoesNotTakeThePoolsCooldown() public {
        bondDeposit(address(stocks[0]), 20e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        forceLiveCells(Constants.MAX_LIVE_CELLS);

        uint32 dated = vault.lastPlacementAt(spokePools[0]);

        vm.prank(KEEPER);
        assertEq(vault.deployBonded(constituentIds[0]), 0, "nothing could be placed");
        assertEq(vault.lastPlacementAt(spokePools[0]), dated, "so the pool was not dated");

        // Same block, same pool: the placement that has something to do is not denied. (The counter is put back
        // where the records say it is, so the governance path is refused by the budget rather than the cooldown.)
        forceLiveCells(countLiveCells());
        vm.prank(TIMELOCK);
        assertGt(vault.place(spokePools[0], true, 1e18), 0, "the timelock still places");
    }

    /// @notice **The finding this closes.** `deployBonded` read the constituent's balance with a typed
    ///         `IERC20.balanceOf`, so a Stock Token whose `balanceOf` reverts bricked the whole bonded-collateral
    ///         deployment for that name. The read is a bounded, hand-decoded `staticcall` now, and bonded
    ///         collateral lives as an ERC-6909 claim, which is readable whatever the issuer does.
    ///
    /// @dev **Cross-slice**, exactly as `VaultPlacement.t.sol`'s twin of this test:
    ///      `AmpsVault.deployBonded` takes its R1 pre-image first and `VaultNavLib.totalAssetsUsd18` still reads
    ///      the same balance with a typed call, which is the vault slice's to harden. Either outcome is asserted,
    ///      and neither of them is `VaultRolloutLib` refusing for want of inventory.
    function test_deployBondedSurvivesAStockTokenWhoseBalanceOfReverts() public {
        bondDeposit(address(stocks[0]), 20e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        stocks[0].setBalanceOfReverts(true);

        vm.prank(KEEPER);
        try vault.deployBonded(constituentIds[0]) returns (uint256 placed) {
            assertGt(placed, 0, "the claim balance alone was enough to deploy");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(MockStockToken.BalanceUnavailable.selector),
                "the only typed balance read left on this path is VaultNavLib's NAV pre-image"
            );
        }

        stocks[0].setBalanceOfReverts(false);
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
