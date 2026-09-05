// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ILadderPolicy
/// @notice The ladder shape. Pure, stateless, pointer-upgradeable behind the 7-day timelock, and **propose-only**:
///         it returns bucket bounds and liquidities, and the vault decides whether to place them.
///
/// @dev **Phase 3 consumes this; Phase 2 only declares it.** No placement happens until the hook exists. The
///      interface is fixed now so that the vault's storage, its policy pointer set and its governance surface are
///      final in Phase 2 and the vault can stay immutable.
///
/// @dev **The shape.** Ask ladders are AMPS-only ranges strictly *above* the current tick; bid ladders are
///      counter-asset-only ranges strictly *below* it (invariant I9, unconditional). A ladder of `n` buckets spans
///      `n` contiguous price doublings (asks) or halvings (bids) from the anchor, and bucket `k` holds
///      `tilt^k / SUM_j tilt^j` of the placement — weights increasing with price in both directions, so the bucket
///      nearest the anchor is the smallest ask and the largest bid. `LadderLib` already implements the maths
///      (`bucketBounds`, `weights`, `split`, `ladderAmounts`); a policy is a thin, governable wrapper around it,
///      which is what makes swapping the shape a pointer change rather than a migration.
///
/// @dev **Nothing here re-centres or re-widens.** There is no rebalance function and no way to ask for one. A
///      ladder is placed once and is only ever removed by pro-rata redemption, rollout of an unfilled entry-pool
///      bucket, the high-water buyback burn, or migration (I35). New inventory — re-laddered fee AMPS, rolled-out
///      inventory, bonded stock — is a *new* placement across buckets above (asks) or below (bids) the current
///      price with the same relative weights, never a move of an existing one.
///
/// @dev **The policy cannot lie usefully.** The vault re-checks every returned bucket against the same invariants
///      it would check for a hand-built placement: asks strictly above the tick, bids strictly below, contiguous
///      doublings, no bucket at or through the current tick, `SUM(amounts) <= inventory`, and the R1 post-condition
///      `navPerShareAfter >= navPerShareBefore x (1 - 2 bp)` as a revert. A hostile policy therefore cannot move an
///      asset, only fail to propose a useful one.
interface ILadderPolicy {
    /// @notice A placement request.
    /// @param anchorTick The tick the ladder is measured from: `tickOf(P_ref / P_counter)` at placement time for a
    ///        fresh ladder, or the current tick for re-laddered fee AMPS.
    /// @param currentTick The pool's live tick, used to assert sidedness. Asks must start above it, bids below.
    /// @param tickSpacing The pool's tick spacing.
    /// @param buckets `n`: `ladderDoublings` for asks, `seedHalvings` or `bondBidHalvings` for bids.
    /// @param tiltX18 The tilt in force, within `[LADDER_TILT_X18_MIN, LADDER_TILT_X18_MAX]`.
    /// @param inventory The total to place: AMPS wei for an ask ladder, counter-asset raw units for a bid ladder.
    /// @param above True for an ask ladder, false for a bid ladder.
    struct LadderRequest {
        int24 anchorTick;
        int24 currentTick;
        int24 tickSpacing;
        uint8 buckets;
        uint64 tiltX18;
        uint256 inventory;
        bool above;
    }

    /// @notice One proposed bucket.
    /// @param lowerTick Spacing-aligned lower bound.
    /// @param upperTick Spacing-aligned upper bound.
    /// @param amount The token amount assigned to this bucket, exactly (the split sums to `inventory`).
    /// @param liquidity The position liquidity that amount buys over the range, rounded **down**. What a bucket
    ///        loses to liquidity rounding stays in the vault as idle inventory rather than disappearing.
    struct LadderBucket {
        int24 lowerTick;
        int24 upperTick;
        uint256 amount;
        uint128 liquidity;
    }

    /// @notice Thrown when a request cannot be honoured as asked: a bucket collapses against the usable tick range,
    ///         or the requested side conflicts with `currentTick`. The vault never silently truncates a ladder.
    /// @param reason A short identifier, e.g. `bytes32("degenerateBucket")`.
    error LadderNotPlaceable(bytes32 reason);

    /// @notice Proposes a whole ladder.
    /// @param request The placement request.
    /// @return buckets The proposed buckets, ordered from the anchor outward (`k = 0` nearest the anchor).
    function propose(LadderRequest calldata request) external pure returns (LadderBucket[] memory buckets);

    /// @notice The geometric weights this policy would apply, `w_k = tilt^k / SUM_j tilt^j`, in 1e18 fixed point.
    /// @dev Exposed for the dApp's ladder chart and for the invariant that asserts bucket `k` holds
    ///      `tilt^k / SUM tilt^j` of the placement (I34).
    /// @param tiltX18 The tilt.
    /// @param buckets The bucket count.
    /// @return weightsX18 The weights, summing to exactly 1e18.
    function weights(uint64 tiltX18, uint8 buckets) external pure returns (uint256[] memory weightsX18);

    /// @notice Hard floor of `ladderTilt`. 1e18: a flat ladder.
    /// @return value The bound.
    function LADDER_TILT_X18_MIN() external view returns (uint64 value);

    /// @notice Hard ceiling of `ladderTilt`. 1.5e18.
    /// @return value The bound.
    function LADDER_TILT_X18_MAX() external view returns (uint64 value);

    /// @notice Hard floor of `ladderDoublings`. 6.
    /// @return value The bound.
    function LADDER_DOUBLINGS_MIN() external view returns (uint8 value);

    /// @notice Hard ceiling of `ladderDoublings`. 14.
    /// @return value The bound.
    function LADDER_DOUBLINGS_MAX() external view returns (uint8 value);

    /// @notice Hard floor of `seedHalvings` and `bondBidHalvings`. 2.
    /// @return value The bound.
    function HALVINGS_MIN() external view returns (uint8 value);

    /// @notice Hard ceiling of `seedHalvings` and `bondBidHalvings`. 8.
    /// @return value The bound.
    function HALVINGS_MAX() external view returns (uint8 value);

    /// @notice Identifier of this ladder shape, for governance diffs and the dApp.
    /// @return id A short identifier, e.g. `bytes32("geometric-doubling-v1")`.
    function version() external pure returns (bytes32 id);
}
