// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IRolloutPolicy} from "../interfaces/IRolloutPolicy.sol";
import {Constants} from "../types/Constants.sol";
import {OutOfBand} from "../types/Errors.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title RolloutPolicy
/// @notice The launch rollout schedule (`weighted-deficit-v1`): how much unfilled ask inventory may leave the two
///         entry pools for one spoke, given the daily budget, the entry-pool floor, the spoke's index deficit, its
///         rollout weight and whether anything has yet given it stock-side depth. Pure, stateless, holding no
///         funds and propose-only, behind the 7-day pointer.
///
/// @dev **The schedule**, exactly `docs/phase3-state-model.md` §5:
///
///      ```
///      budget    = rolloutBpsPerDay * polTrancheAmps / BPS - movedLast24hAmps      0 when negative
///      floorRoom = entryInventoryAmps - entryFloorBps * polTrancheAmps / BPS       0 when negative
///      deficit   = max(0, targetWeightBps - currentWeightBps) * 1e18 / max(1, targetWeightBps)
///      share     = rolloutWeightBps * (spokeHasDepth ? 1e18 : DEPTHLESS_DISCOUNT_X18) / BPS
///      amount    = min(budget, floorRoom, budget * share/1e18 * (1e18 + deficit)/1e18)
///      floorBinding = (amount == floorRoom) && floorRoom < budget
///      ```
///
///      `deficit` is a fraction of the target weight, so it at most doubles a spoke's share of the day's budget; a
///      spoke already at or above its target gets its plain weighted share. A depthless spoke is preferred half as
///      strongly, because asks placed against no bid side earn nothing until somebody brings stock — but it is
///      still preferred, since receiving asks is how a spoke gets a market at all.
///
/// @dev **`amountAmps == 0` is an answer, not a failure.** A retired or frozen constituent has
///      `rolloutWeightBps == 0` and therefore a zero share, an exhausted daily budget gives a zero budget, and a
///      drained entry pool gives zero floor room. In all three cases the vault treats the decision as a no-op, so
///      an unpaid keeper call costs its caller gas and nothing else. Retirement needs no special case here, which
///      is exactly why `retireConstituent` zeroes the weight instead of asking the schedule to know about
///      lifecycle.
///
/// @dev **Three limits, and this contract can only enforce two of them.** `RolloutRequest` carries amounts, not
///      ticks, so the third limit of I32 — a rolled-out ask is never placed below `P_ref` — is structurally
///      outside this signature. It is enforced where the ticks exist: `rollout` re-checks every destination cell's
///      `lowerTick >= tickOf(P_ref / P_stock)` itself (§3.7), and `LadderPolicy.propose` anchored at that tick
///      cannot return a bucket below it, because bucket 0 of an ask ladder starts at `alignUp(anchorTick)` and
///      every later bucket is a whole doubling higher. `unit/RolloutPolicy.t.sol` pins that composition.
///
/// @dev **The vault re-checks everything.** §3.7 has `rollout` recompute the daily budget, the entry-pool floor
///      and the `P_ref` bound against its own storage and revert `RolloutLimitExceeded` rather than trust this
///      return value, so a hostile policy can only refuse to schedule a move, never cause one.
///
/// @dev **Rounding is one-directional: down.** Every `mulDiv` here floors, so the budget, the floor room and the
///      weighted share are each understated by at most a wei and the proposed move is never larger than the
///      schedule allows.
contract RolloutPolicy is IRolloutPolicy {
    /// @notice Identifier of this schedule. Returned by {version}.
    bytes32 internal constant VERSION_ID = "weighted-deficit-v1";

    /// @inheritdoc IRolloutPolicy
    function propose(RolloutRequest calldata request) external pure returns (RolloutDecision memory decision) {
        if (request.rolloutBpsPerDay > Constants.ROLLOUT_BPS_PER_DAY_MAX) {
            revert OutOfBand("rolloutBpsPerDay", request.rolloutBpsPerDay, 0, Constants.ROLLOUT_BPS_PER_DAY_MAX);
        }
        if (request.entryFloorBps > Constants.ENTRY_FLOOR_BPS_MAX) {
            revert OutOfBand("entryFloorBps", request.entryFloorBps, 0, Constants.ENTRY_FLOOR_BPS_MAX);
        }

        uint256 budget = _budget(request);
        uint256 floorRoom = _floorRoom(request);

        // The weighted share of today's budget, scaled by the depthless discount and boosted by the index deficit.
        uint256 share = FullMath.mulDiv(
            uint256(request.rolloutWeightBps),
            request.spokeHasDepth ? Constants.WAD : Constants.DEPTHLESS_DISCOUNT_X18,
            Constants.BPS
        );
        uint256 amount = FullMath.mulDiv(budget, share, Constants.WAD);
        amount = FullMath.mulDiv(
            amount, Constants.WAD + _deficitX18(request.targetWeightBps, request.currentWeightBps), Constants.WAD
        );

        if (amount > budget) amount = budget;
        if (amount > floorRoom) amount = floorRoom;

        decision.amountAmps = amount;
        decision.dailyBudgetRemaining = budget - amount;
        // "The floor is what limited this move": it bound the answer, and it bound it below the daily budget.
        decision.floorBinding = amount == floorRoom && floorRoom < budget;
    }

    /// @inheritdoc IRolloutPolicy
    function ROLLOUT_BPS_PER_DAY_MAX() external pure returns (uint16 value) {
        value = Constants.ROLLOUT_BPS_PER_DAY_MAX;
    }

    /// @inheritdoc IRolloutPolicy
    function ENTRY_FLOOR_BPS_MAX() external pure returns (uint16 value) {
        value = Constants.ENTRY_FLOOR_BPS_MAX;
    }

    /// @inheritdoc IRolloutPolicy
    function DEPTHLESS_DISCOUNT_X18() external pure returns (uint256 value) {
        value = Constants.DEPTHLESS_DISCOUNT_X18;
    }

    /// @inheritdoc IRolloutPolicy
    function version() external pure returns (bytes32 id) {
        id = VERSION_ID;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev What is left of today's allowance. The window is the vault's rolling 24 hours; this contract only sees
    ///      how much of it has already been spent.
    function _budget(RolloutRequest calldata request) private pure returns (uint256 budget) {
        uint256 allowance = FullMath.mulDiv(request.polTrancheAmps, request.rolloutBpsPerDay, Constants.BPS);
        budget = allowance > request.movedLast24hAmps ? allowance - request.movedLast24hAmps : 0;
    }

    /// @dev How far the entry pools can be drawn down before they hit `entryFloorBps` of the POL tranche.
    function _floorRoom(RolloutRequest calldata request) private pure returns (uint256 room) {
        uint256 floorAmps = FullMath.mulDiv(request.polTrancheAmps, request.entryFloorBps, Constants.BPS);
        room = request.entryInventoryAmps > floorAmps ? request.entryInventoryAmps - floorAmps : 0;
    }

    /// @dev The index deficit as a fraction of the target weight, in 1e18 fixed point and never above 1e18. A
    ///      constituent at or above its target has no deficit and no boost; `max(1, target)` keeps a zero-target
    ///      name (one that is being wound down) from dividing by zero.
    function _deficitX18(uint16 targetWeightBps, uint16 currentWeightBps) private pure returns (uint256 deficitX18) {
        if (currentWeightBps >= targetWeightBps) return 0;
        uint256 target = targetWeightBps == 0 ? 1 : uint256(targetWeightBps);
        deficitX18 = FullMath.mulDiv(uint256(targetWeightBps - currentWeightBps), Constants.WAD, target);
    }
}
