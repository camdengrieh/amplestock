// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IMarketReference
/// @notice The read surface the vault, `AmpsBonds` and `AmpsQuoter` use to obtain a *market* price. In production
///         this is implemented by `AmpsHook` over its per-pool `TruncatedOracleLib` rings; in Phase 2, where no
///         hook exists yet, it is implemented by a mock so that the vault, the bond pricing and the reference-price
///         rate limiter can be built and fuzzed against a controllable oracle.
///
/// @dev **Ticks, not prices.** Everything here is denominated in ticks of the pool itself, i.e. *counter asset per
///      AMPS* (AMPS is `currency0` in all 32 pools). The USD conversion is the caller's job and goes through
///      `PriceLib` with the counter asset's Chainlink answer:
///
///      ```
///      int24  meanTick = ref.twapTick(hubPoolId, window);              // AMPS/USDG
///      uint160 sqrtP   = PriceLib.tickToSqrtPriceX96(meanTick);
///      uint256 pMktX18 = PriceLib.sqrtPriceX96ToAmpsPriceUsd18(sqrtP, usdgAnswerUsd8, 6);
///      ```
///
///      Keeping the interface tick-only means the mock needs no feed, the hook needs no USD arithmetic on the swap
///      path, and there is exactly one place (`PriceLib`) where decimals are handled.
///
/// @dev **Truncation is the security property.** The observations behind `twapTick` are written with a per-block
///      tick-move cap, so a TWAP over `w` seconds cannot be moved by more than `maxTickMovePerBlock x blocks(w)`
///      regardless of the swap sequence (invariant I25). A caller must still treat the result as attacker-influenced
///      within that bound: `P_mkt` is a fee input, a band centre and a bond reference, and is *never* the
///      denominator of a share calculation.
///
/// @dev **Coverage before trust.** A freshly initialised pool has a ring that does not reach back `window` seconds.
///      `twapTick` reverts in that case; `observationCoverage` is the non-reverting way to ask first, and every
///      production caller checks it so that a young pool degrades to the NAV-anchored reference rather than
///      bricking a path.
interface IMarketReference {
    /// @notice Thrown when the observation ring does not reach back far enough to answer the requested window.
    /// @param poolId The pool queried.
    /// @param requested The window asked for, in seconds.
    /// @param available The window the ring can actually serve, in seconds.
    error WindowNotCovered(PoolId poolId, uint32 requested, uint32 available);

    /// @notice Thrown when the pool has never been initialised on this reference source.
    /// @param poolId The pool queried.
    error PoolNotObserved(PoolId poolId);

    /// @notice The mean truncated tick of `poolId` over the last `window` seconds.
    /// @dev Reverts with {WindowNotCovered} rather than silently shortening the window: a caller that quietly got a
    ///      5-minute TWAP when it asked for 30 minutes would be manipulable by exactly the amount it thought it had
    ///      excluded.
    /// @param poolId The pool to consult.
    /// @param window The averaging window in seconds, within `[TWAP_WINDOW_MIN, TWAP_WINDOW_MAX]`.
    /// @return meanTick The arithmetic mean of the truncated tick over the window, floored.
    function twapTick(PoolId poolId, uint32 window) external view returns (int24 meanTick);

    /// @notice {twapTick} over the protocol's canonical 30-minute window.
    /// @param poolId The pool to consult.
    /// @return meanTick The 30-minute mean truncated tick.
    function twapTick30m(PoolId poolId) external view returns (int24 meanTick);

    /// @notice How many seconds of history the pool's ring currently covers.
    /// @dev Never reverts for a known pool; returns 0 for an unobserved one. This is the guard every caller uses
    ///      before {twapTick}.
    /// @param poolId The pool to consult.
    /// @return secondsCovered The largest window {twapTick} will accept.
    function observationCoverage(PoolId poolId) external view returns (uint32 secondsCovered);

    /// @notice The truncated tick currently in force for `poolId`, i.e. the value the accumulator is advancing at.
    /// @dev This is the *truncated* tick, not `slot0.tick`. They differ whenever the cap bound the last write, and
    ///      that difference is the whole point: a single-block push moves `slot0` but not this.
    /// @param poolId The pool to consult.
    /// @return tick The truncated tick.
    function lastTruncatedTick(PoolId poolId) external view returns (int24 tick);

    /// @notice The highest truncated tick seen since the vault last reset the mark for this pool.
    /// @dev Drives the buyback burn (I33): AMPS sitting in a bucket whose upper bound the high-water mark has
    ///      crossed is bought-back inventory, and is withdrawn and burned at the next `compound` rather than
    ///      re-placed.
    /// @param poolId The pool to consult.
    /// @return tick The high-water truncated tick.
    function highWaterTick(PoolId poolId) external view returns (int24 tick);

    /// @notice The canonical TWAP window the protocol reads by default.
    /// @return window The window in seconds. 1,800 at launch.
    function twapWindow() external view returns (uint32 window);

    /// @notice The per-block truncation cap in force for `poolId`.
    /// @param poolId The pool to consult.
    /// @return cap The truncation cap, in ticks.
    function maxTickMovePerBlock(PoolId poolId) external view returns (int24 cap);
}
