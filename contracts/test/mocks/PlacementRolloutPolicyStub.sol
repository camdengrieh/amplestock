// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IRolloutPolicy} from "../../src/interfaces/IRolloutPolicy.sol";
import {Constants} from "../../src/types/Constants.sol";

/// @title PlacementRolloutPolicyStub
/// @notice `IRolloutPolicy` implementing `docs/phase3-state-model.md` §5's `weighted-deficit-v1` arithmetic
///         literally. Test-only.
///
/// @dev ```
///      budget    = rolloutBpsPerDay * polTrancheAmps / BPS - movedLast24hAmps            (0 when negative)
///      floorRoom = entryInventoryAmps - entryFloorBps * polTrancheAmps / BPS             (0 when negative)
///      deficit   = max(0, targetWeightBps - currentWeightBps) * 1e18 / max(1, targetWeightBps)
///      share     = rolloutWeightBps * (spokeHasDepth ? 1e18 : DEPTHLESS_DISCOUNT_X18) / BPS
///      amount    = min(budget, floorRoom, budget * share/1e18 * (1e18 + deficit)/1e18)
///      ```
///      `amountAmps == 0` is a valid answer and a no-op for the vault, never a revert.
///
/// @dev The real `src/policy/RolloutPolicy.sol` is being written concurrently. The vault re-checks all three of
///      I32's limits itself after this has proposed, so a policy that over-proposes is refused rather than obeyed;
///      `test/unit/VaultRollout.t.sol` proves that with `vm.mockCall`, because `IRolloutPolicy.propose` is `pure`
///      and this contract can hold no flag of its own.
contract PlacementRolloutPolicyStub is IRolloutPolicy {
    /// @inheritdoc IRolloutPolicy
    function propose(RolloutRequest calldata request) external pure returns (RolloutDecision memory decision) {
        uint256 allowance = request.polTrancheAmps * request.rolloutBpsPerDay / Constants.BPS;
        uint256 budget = allowance > request.movedLast24hAmps ? allowance - request.movedLast24hAmps : 0;

        uint256 floor = request.polTrancheAmps * request.entryFloorBps / Constants.BPS;
        uint256 floorRoom = request.entryInventoryAmps > floor ? request.entryInventoryAmps - floor : 0;

        uint256 deficit = request.targetWeightBps > request.currentWeightBps
            ? uint256(request.targetWeightBps - request.currentWeightBps) * 1e18
                / (request.targetWeightBps == 0 ? 1 : request.targetWeightBps)
            : 0;
        uint256 share = uint256(request.rolloutWeightBps)
            * (request.spokeHasDepth ? uint256(1e18) : Constants.DEPTHLESS_DISCOUNT_X18) / Constants.BPS;

        uint256 amount = budget * share / 1e18;
        amount = amount * (1e18 + deficit) / 1e18;
        if (amount > budget) amount = budget;
        if (amount > floorRoom) amount = floorRoom;

        decision = RolloutDecision({
            amountAmps: amount,
            dailyBudgetRemaining: budget > amount ? budget - amount : 0,
            floorBinding: amount == floorRoom && floorRoom < budget
        });
    }

    /// @inheritdoc IRolloutPolicy
    function ROLLOUT_BPS_PER_DAY_MAX() external pure returns (uint16 value) {
        return Constants.ROLLOUT_BPS_PER_DAY_MAX;
    }

    /// @inheritdoc IRolloutPolicy
    function ENTRY_FLOOR_BPS_MAX() external pure returns (uint16 value) {
        return Constants.ENTRY_FLOOR_BPS_MAX;
    }

    /// @inheritdoc IRolloutPolicy
    function DEPTHLESS_DISCOUNT_X18() external pure returns (uint256 value) {
        return Constants.DEPTHLESS_DISCOUNT_X18;
    }

    /// @inheritdoc IRolloutPolicy
    function version() external pure returns (bytes32 id) {
        return "weighted-deficit-v1";
    }
}
