// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILadderPolicy} from "../../src/interfaces/ILadderPolicy.sol";
import {IRolloutPolicy} from "../../src/interfaces/IRolloutPolicy.sol";
import {LadderPolicy} from "../../src/policy/LadderPolicy.sol";
import {RolloutPolicy} from "../../src/policy/RolloutPolicy.sol";
import {Constants} from "../../src/types/Constants.sol";
import {OutOfBand} from "../../src/types/Errors.sol";
import {PriceLibHarness} from "../utils/LibHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Unit tests for the rollout schedule: the daily budget and the entry-pool floor are never breached, a
///         retired constituent gets nothing, a depthless spoke is discounted by exactly half, and — through the
///         ladder policy it composes with — a rolled-out ask is never placed below `P_ref` (I32).
contract RolloutPolicyTest is Test {
    RolloutPolicy internal policy;
    LadderPolicy internal ladder;
    PriceLibHarness internal price;

    /// @dev The launch state: 4,750 AMPS of POL, 3,325 of it still in the two entry pools, 200 bp a day, a 30%
    ///      entry floor and thirty spokes at roughly 333 bp of rollout weight each.
    uint256 internal constant POL = 4750e18;
    uint256 internal constant ENTRY_INVENTORY = 3325e18;
    uint16 internal constant RATE = Constants.ROLLOUT_BPS_PER_DAY_DEFAULT;
    uint16 internal constant FLOOR = Constants.ENTRY_FLOOR_BPS_DEFAULT;
    uint16 internal constant WEIGHT = 333;

    /// @dev `200 bp x 4,750 AMPS` is 95 AMPS a day.
    uint256 internal constant DAILY_ALLOWANCE = 95e18;

    /// @dev `30% x 4,750 AMPS` is 1,425 AMPS the entry pools must keep.
    uint256 internal constant FLOOR_AMPS = 1425e18;

    function setUp() public {
        policy = new RolloutPolicy();
        ladder = new LadderPolicy();
        price = new PriceLibHarness();
    }

    /* ------------------------------------------- identity ------------------------------------------- */

    function test_version() public view {
        assertEq(policy.version(), bytes32("weighted-deficit-v1"));
    }

    function test_bandsComeFromConstants() public view {
        assertEq(policy.ROLLOUT_BPS_PER_DAY_MAX(), Constants.ROLLOUT_BPS_PER_DAY_MAX, "daily rate ceiling");
        assertEq(policy.ENTRY_FLOOR_BPS_MAX(), Constants.ENTRY_FLOOR_BPS_MAX, "entry floor ceiling");
        assertEq(policy.DEPTHLESS_DISCOUNT_X18(), Constants.DEPTHLESS_DISCOUNT_X18, "depthless discount");
        assertLe(RATE, policy.ROLLOUT_BPS_PER_DAY_MAX(), "the launch rate is inside its band");
        assertLe(FLOOR, policy.ENTRY_FLOOR_BPS_MAX(), "the launch floor is inside its band");
    }

    /* --------------------------------------- the launch schedule --------------------------------------- */

    /// @dev A spoke at its target weight with depth: its plain weighted share of the day's budget.
    function test_launchSchedule() public view {
        IRolloutPolicy.RolloutDecision memory decision = policy.propose(_request());
        // 200 bp of 4,750 == 95 AMPS a day; 333 bp of that is 3.1635 AMPS.
        assertEq(decision.amountAmps, 3.1635e18, "the weighted share");
        assertEq(decision.dailyBudgetRemaining, DAILY_ALLOWANCE - 3.1635e18, "what is left of today");
        assertFalse(decision.floorBinding, "neither limit binds at genesis");
    }

    /// @dev A spoke with no stock-side depth yet is preferred exactly half as strongly.
    function test_depthlessSpokeIsDiscountedByHalf() public view {
        IRolloutPolicy.RolloutRequest memory request = _request();
        uint256 withDepth = policy.propose(request).amountAmps;

        request.spokeHasDepth = false;
        uint256 withoutDepth = policy.propose(request).amountAmps;

        assertEq(withoutDepth * 2, withDepth, "DEPTHLESS_DISCOUNT_X18 == 0.5e18");
        assertGt(withoutDepth, 0, "but a depthless spoke can still receive asks: that is how it gets a market");
    }

    /// @dev The index deficit at most doubles a spoke's share, and a spoke at or above its target gets no boost.
    function test_theDeficitBoostsUpToDouble() public view {
        IRolloutPolicy.RolloutRequest memory request = _request();
        uint256 atTarget = policy.propose(request).amountAmps;

        request.currentWeightBps = 0; // a full deficit
        assertEq(policy.propose(request).amountAmps, atTarget * 2, "a full deficit doubles the share");

        request.currentWeightBps = WEIGHT * 2; // above target
        assertEq(policy.propose(request).amountAmps, atTarget, "no boost above target");

        request.currentWeightBps = WEIGHT / 2; // half the target weight realised
        uint256 halfWay = policy.propose(request).amountAmps;
        assertGt(halfWay, atTarget, "a partial deficit boosts");
        assertLt(halfWay, atTarget * 2, "but by less than a full one");
    }

    /* ------------------------------------- the three limits (I32) ------------------------------------- */

    /// @dev The daily budget is never breached, however large the weight or the deficit.
    function test_theDailyBudgetIsNeverBreached() public view {
        IRolloutPolicy.RolloutRequest memory request = _request();
        request.rolloutWeightBps = 10_000; // the whole index in one spoke
        request.currentWeightBps = 0; // and a full deficit on top
        request.targetWeightBps = 10_000;

        IRolloutPolicy.RolloutDecision memory decision = policy.propose(request);
        assertEq(decision.amountAmps, DAILY_ALLOWANCE, "capped at the day's allowance");
        assertEq(decision.dailyBudgetRemaining, 0, "which leaves nothing");
        assertFalse(decision.floorBinding, "the budget bound it, not the floor");
    }

    /// @dev What has already moved in the trailing 24 hours comes off the budget, and an exhausted budget is a
    ///      zero-amount no-op rather than a revert.
    function test_theRollingWindowConsumesTheBudget() public view {
        IRolloutPolicy.RolloutRequest memory request = _request();
        request.rolloutWeightBps = 10_000;
        request.movedLast24hAmps = 90e18;
        assertEq(policy.propose(request).amountAmps, 5e18, "only the remainder of the day is available");

        request.movedLast24hAmps = DAILY_ALLOWANCE;
        IRolloutPolicy.RolloutDecision memory decision = policy.propose(request);
        assertEq(decision.amountAmps, 0, "an exhausted budget proposes nothing");
        assertEq(decision.dailyBudgetRemaining, 0);

        request.movedLast24hAmps = DAILY_ALLOWANCE * 10; // over-spent: saturates rather than underflowing
        assertEq(policy.propose(request).amountAmps, 0, "and cannot go negative");
    }

    /// @dev The entry pools are never taken below `entryFloorBps` of the POL tranche.
    function test_theEntryFloorIsNeverBreached() public view {
        IRolloutPolicy.RolloutRequest memory request = _request();
        request.rolloutWeightBps = 10_000;
        request.entryInventoryAmps = FLOOR_AMPS + 1e18; // one AMPS of room left

        IRolloutPolicy.RolloutDecision memory decision = policy.propose(request);
        assertEq(decision.amountAmps, 1e18, "only the room above the floor may move");
        assertTrue(decision.floorBinding, "and the floor is what bound it");
        assertEq(request.entryInventoryAmps - decision.amountAmps, FLOOR_AMPS, "the pools land exactly on the floor");

        request.entryInventoryAmps = FLOOR_AMPS;
        decision = policy.propose(request);
        assertEq(decision.amountAmps, 0, "at the floor nothing moves");
        assertTrue(decision.floorBinding);

        request.entryInventoryAmps = FLOOR_AMPS - 1; // already below it
        assertEq(policy.propose(request).amountAmps, 0, "and below the floor nothing moves either");
    }

    /// @dev I32's third limit lives in the ticks, not in the amounts: an ask ladder anchored at
    ///      `tickOf(P_ref / P_stock)` cannot produce a bucket below `P_ref`, because bucket 0 starts at the aligned
    ///      anchor and every later bucket is a whole doubling higher. This is the composition `rollout` performs.
    function test_aRolledOutAskIsNeverPlacedBelowPRef() public view {
        int24 spacing = 60;
        // P_ref = $1.20 (the reference has run above NAV), the stock at $180.
        int24 pRefTick = price.fairTick(1.2e18, 180e8, 18, spacing);
        // The spoke's live tick is well below the reference: an ordinary post-sell state.
        int24 currentTick = pRefTick - 5000;

        ILadderPolicy.LadderBucket[] memory buckets = ladder.propose(
            ILadderPolicy.LadderRequest({
                anchorTick: pRefTick,
                currentTick: currentTick,
                tickSpacing: spacing,
                buckets: Constants.LADDER_DOUBLINGS_DEFAULT,
                tiltX18: Constants.LADDER_TILT_X18_DEFAULT,
                inventory: 3.1635e18,
                above: true
            })
        );

        for (uint256 k = 0; k < buckets.length; ++k) {
            assertGe(buckets[k].lowerTick, pRefTick, "no rolled-out ask below P_ref");
            assertGt(buckets[k].lowerTick, currentTick, "and none at or below the spoke's tick (I9)");
        }
    }

    /* ------------------------------------------- retirement ------------------------------------------- */

    /// @dev Retirement zeroes the weight; the schedule needs no special case for it.
    function test_aRetiredConstituentGetsZero() public view {
        IRolloutPolicy.RolloutRequest memory request = _request();
        request.rolloutWeightBps = 0;
        request.currentWeightBps = 0; // a full deficit cannot resurrect it
        request.targetWeightBps = 0;

        IRolloutPolicy.RolloutDecision memory decision = policy.propose(request);
        assertEq(decision.amountAmps, 0, "a zero weight never wins the allocation");
        assertEq(decision.dailyBudgetRemaining, DAILY_ALLOWANCE, "and does not consume the budget");
        assertFalse(decision.floorBinding);
    }

    /// @dev A zero target weight does not divide by zero.
    function test_aZeroTargetWeightIsSafe() public view {
        IRolloutPolicy.RolloutRequest memory request = _request();
        request.targetWeightBps = 0;
        request.currentWeightBps = 0;
        IRolloutPolicy.RolloutDecision memory decision = policy.propose(request);
        assertEq(decision.amountAmps, 3.1635e18, "no deficit, no boost, the plain weighted share");
    }

    /* -------------------------------------------- refusals -------------------------------------------- */

    function test_revert_governedInputsOutsideTheirBands() public {
        IRolloutPolicy.RolloutRequest memory request = _request();
        request.rolloutBpsPerDay = Constants.ROLLOUT_BPS_PER_DAY_MAX + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("rolloutBpsPerDay"),
                uint256(Constants.ROLLOUT_BPS_PER_DAY_MAX) + 1,
                uint256(0),
                uint256(Constants.ROLLOUT_BPS_PER_DAY_MAX)
            )
        );
        policy.propose(request);

        request = _request();
        request.entryFloorBps = Constants.ENTRY_FLOOR_BPS_MAX + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("entryFloorBps"),
                uint256(Constants.ENTRY_FLOOR_BPS_MAX) + 1,
                uint256(0),
                uint256(Constants.ENTRY_FLOOR_BPS_MAX)
            )
        );
        policy.propose(request);
    }

    /* --------------------------------------------- fuzz --------------------------------------------- */

    /// @dev Neither limit is ever breached, whatever the schedule is asked for.
    function testFuzz_neitherLimitIsEverBreached(
        uint256 polSeed,
        uint256 entrySeed,
        uint256 movedSeed,
        uint16 rateSeed,
        uint16 floorSeed,
        uint16 weightSeed,
        bool hasDepth
    ) public view {
        IRolloutPolicy.RolloutRequest memory request = IRolloutPolicy.RolloutRequest({
            polTrancheAmps: bound(polSeed, 0, 1e30),
            entryInventoryAmps: bound(entrySeed, 0, 1e30),
            movedLast24hAmps: bound(movedSeed, 0, 1e30),
            rolloutBpsPerDay: uint16(bound(rateSeed, 0, Constants.ROLLOUT_BPS_PER_DAY_MAX)),
            entryFloorBps: uint16(bound(floorSeed, 0, Constants.ENTRY_FLOOR_BPS_MAX)),
            targetWeightBps: 500,
            currentWeightBps: 0,
            rolloutWeightBps: uint16(bound(weightSeed, 0, 10_000)),
            spokeHasDepth: hasDepth
        });

        IRolloutPolicy.RolloutDecision memory decision = policy.propose(request);

        uint256 allowance = request.polTrancheAmps * request.rolloutBpsPerDay / Constants.BPS;
        uint256 budget = allowance > request.movedLast24hAmps ? allowance - request.movedLast24hAmps : 0;
        assertLe(decision.amountAmps, budget, "the daily budget is never breached");
        assertEq(decision.dailyBudgetRemaining, budget - decision.amountAmps, "the remainder closes");

        uint256 floorAmps = request.polTrancheAmps * request.entryFloorBps / Constants.BPS;
        if (request.entryInventoryAmps >= floorAmps) {
            assertGe(request.entryInventoryAmps - decision.amountAmps, floorAmps, "the entry floor holds");
        } else {
            assertEq(decision.amountAmps, 0, "a pool already below the floor moves nothing");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    function _request() private pure returns (IRolloutPolicy.RolloutRequest memory request) {
        request = IRolloutPolicy.RolloutRequest({
            polTrancheAmps: POL,
            entryInventoryAmps: ENTRY_INVENTORY,
            movedLast24hAmps: 0,
            rolloutBpsPerDay: RATE,
            entryFloorBps: FLOOR,
            targetWeightBps: WEIGHT,
            currentWeightBps: WEIGHT,
            rolloutWeightBps: WEIGHT,
            spokeHasDepth: true
        });
    }
}
