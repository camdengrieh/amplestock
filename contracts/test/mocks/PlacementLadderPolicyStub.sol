// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILadderPolicy} from "../../src/interfaces/ILadderPolicy.sol";
import {LadderLib} from "../../src/lib/LadderLib.sol";
import {Constants} from "../../src/types/Constants.sol";

/// @title PlacementLadderPolicyStub
/// @notice `ILadderPolicy` over `LadderLib`, exactly as `docs/phase3-state-model.md` §5 describes
///         `LadderPolicy` (`geometric-doubling-v1`): `bucketBounds`, `weights`, `split` and a `propose` that
///         composes the three. Test-only.
///
/// @dev The real `src/policy/LadderPolicy.sol` is being written concurrently by another agent. This stub exists so
///      the placement suites can exercise the vault's *pointer* — `VaultPlacementLib` asks the policy for the
///      weight vector and falls back to `LadderLib` when the pointer is unset, reverts, or answers with a vector
///      that is the wrong length or does not sum to 1e18. Swapping the real policy in is a `setPolicyPointer`
///      call and nothing else.
///
/// @dev Every function is `pure`, because `ILadderPolicy` declares them so. The fault cases the vault's fallback
///      has to survive — a policy that reverts, one that answers with the wrong length, one whose weights do not
///      sum to 1e18 — are injected in the tests with `vm.mockCall` / `vm.mockCallRevert` rather than with flags
///      this contract could not hold.
contract PlacementLadderPolicyStub is ILadderPolicy {
    /// @inheritdoc ILadderPolicy
    function propose(LadderRequest calldata request) external pure returns (LadderBucket[] memory buckets) {
        (int24[] memory lowers, int24[] memory uppers, uint128[] memory liquidities) = LadderLib.ladderAmounts(
            request.anchorTick, request.tickSpacing, request.buckets, request.tiltX18, request.inventory, request.above
        );
        uint256[] memory amounts =
            LadderLib.split(request.inventory, LadderLib.weights(request.tiltX18, request.buckets));

        buckets = new LadderBucket[](request.buckets);
        for (uint256 k; k < request.buckets; ++k) {
            buckets[k] = LadderBucket({
                lowerTick: lowers[k],
                upperTick: uppers[k],
                amount: request.above ? amounts[k] : amounts[request.buckets - 1 - k],
                liquidity: liquidities[k]
            });
        }
    }

    /// @inheritdoc ILadderPolicy
    function weights(uint64 tiltX18, uint8 buckets) external pure returns (uint256[] memory weightsX18) {
        return LadderLib.weights(tiltX18, buckets);
    }

    /// @inheritdoc ILadderPolicy
    function bucketBounds(int24 anchorTick, int24 tickSpacing, uint8 k, bool above)
        external
        pure
        returns (int24 lowerTick, int24 upperTick)
    {
        return LadderLib.bucketBounds(anchorTick, tickSpacing, k, above);
    }

    /// @inheritdoc ILadderPolicy
    function split(uint256 inventory, uint256[] calldata weightsX18) external pure returns (uint256[] memory amounts) {
        uint256[] memory copied = new uint256[](weightsX18.length);
        for (uint256 i; i < weightsX18.length; ++i) {
            copied[i] = weightsX18[i];
        }
        return LadderLib.split(inventory, copied);
    }

    /// @inheritdoc ILadderPolicy
    function LADDER_TILT_X18_MIN() external pure returns (uint64 value) {
        return Constants.LADDER_TILT_X18_MIN;
    }

    /// @inheritdoc ILadderPolicy
    function LADDER_TILT_X18_MAX() external pure returns (uint64 value) {
        return Constants.LADDER_TILT_X18_MAX;
    }

    /// @inheritdoc ILadderPolicy
    function LADDER_DOUBLINGS_MIN() external pure returns (uint8 value) {
        return Constants.LADDER_DOUBLINGS_MIN;
    }

    /// @inheritdoc ILadderPolicy
    function LADDER_DOUBLINGS_MAX() external pure returns (uint8 value) {
        return Constants.LADDER_DOUBLINGS_MAX;
    }

    /// @inheritdoc ILadderPolicy
    function HALVINGS_MIN() external pure returns (uint8 value) {
        return Constants.HALVINGS_MIN;
    }

    /// @inheritdoc ILadderPolicy
    function HALVINGS_MAX() external pure returns (uint8 value) {
        return Constants.HALVINGS_MAX;
    }

    /// @inheritdoc ILadderPolicy
    function version() external pure returns (bytes32 id) {
        return "geometric-doubling-v1";
    }
}
