// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title TruncatedOracleLib
/// @author Amplestocks
/// @notice A geometric-mean tick oracle whose per-block movement is capped, kept in a caller-owned storage struct so
///         that `AmpsHook` can hold one independent ring per pool.
///
/// @dev    Written from scratch for Amplestocks (MIT). The *idea* of clamping each block's tick move before it enters
///         the cumulative accumulator comes from Bunni's `TruncGeoOracle` and OpenZeppelin's `PanopticOracle`; the
///         cumulative-tick / ring-buffer / binary-search shape is the one Uniswap v3's `Oracle.sol` established. No
///         code was copied from any of them - see NOTICES.md.
///
/// ## Why truncation
///
/// A plain cumulative-tick TWAP can be moved arbitrarily far in a single block by an attacker willing to pay the swap
/// cost, because the accumulator integrates whatever tick the pool ends the block at. Truncation makes the *recorded*
/// tick move at most `maxTickMovePerBlock` per block, so the recorded series - and therefore any mean taken over it -
/// is a Lipschitz function of block count rather than of capital. Concretely (invariant I25):
///
///     |consult(w) - truncatedTick(t - w)| <= maxTickMovePerBlock * (number of blocks written inside the window)
///
/// regardless of the swap sequence. Manipulating the 30-minute reference therefore costs an attacker the ability to
/// hold the pool away from fair value for many consecutive blocks, not one flash-loaned swap.
///
/// ## Per-block allowance, not per-swap allowance
///
/// The cap is charged against `blockAnchorTick`, the truncated tick as it stood at the end of the previous *block* in
/// which a write happened. Every write inside one block is clamped to that same anchor +/- cap, so N swaps in one
/// block move the recorded tick by at most one cap, not N caps. `blockAnchorTick` is re-anchored to
/// `lastTruncatedTick` on the first write of each new block. Robinhood Chain produces ~100 ms blocks while
/// `block.timestamp` has one-second granularity, so several *blocks* routinely share one *timestamp*: block identity
/// (for the cap) and timestamp identity (for the ring) are deliberately tracked separately.
///
/// ## Observation semantics
///
/// `obs[i].tickCumulative` is the accumulator value **at** `obs[i].blockTimestamp`, and `obs[i].truncatedTick` is the
/// tick in force **from** `obs[i].blockTimestamp` until the next observation. That makes
/// `cumulative(t) = obs[i].tickCumulative + obs[i].truncatedTick * (t - obs[i].blockTimestamp)` exact for every
/// `t` in `[obs[i].blockTimestamp, obs[i+1].blockTimestamp]`, which is why this library interpolates with the
/// recorded tick rather than with Uniswap v3's average-slope formula: the result is exact and carries no rounding.
///
/// ## Rounding directions (every one in this library)
///
/// - `_truncate`: exact. Clamping only; no division.
/// - `write`: exact. `tickCumulative += lastTruncatedTick * elapsedSeconds` is an exact integer product.
/// - `_tickCumulativeAt`: exact (see above). No division anywhere on the interpolation path.
/// - `consult`: the ONLY rounding in the library. `(cumNow - cumThen) / window` is rounded **toward negative
///   infinity** (floor), matching Uniswap v3's `OracleLibrary.consult`. Solidity's `/` truncates toward zero, so one
///   is subtracted when the delta is negative and the division is inexact. Flooring is the conservative direction for
///   Amplestocks: AMPS is `currency0` in every pool, so a lower tick means a lower AMPS price, and under-reporting
///   `P_mkt` can only shrink `P_ref` toward the NAV floor, tighten the fee wall's `fairTick` and lower the bond
///   quote - never mint AMPS more cheaply.
/// - `observationCoverage`: exact.
///
/// ## Overflow
///
/// `tickCumulative` is `int56` and is *intended* to wrap, exactly as in Uniswap v3: only differences of two
/// accumulator readings are ever used, and a difference computed in `unchecked` int56 arithmetic is correct modulo
/// 2**56 whenever the true difference fits in int56. |tick| <= 887272 < 2**20, so the true difference over a window
/// of `w` seconds is at most 887272 * w; for any window under ~4.0e10 seconds (1287 years) that is well inside
/// int56. Timestamps are `uint32` and also wrap (year 2106); `_lte` compares them on the mod-2**32 circle relative to
/// `time`, so the ring keeps working across the wrap.
library TruncatedOracleLib {
    /// @notice Number of observations retained per pool.
    uint16 internal constant MAX_CARDINALITY = 64;

    /// @notice The protocol's canonical reference window: 30 minutes.
    uint32 internal constant TWAP_WINDOW = 1800;

    /// @notice One recorded observation. All four fields pack into a single 32-byte slot (32 + 56 + 24 + 8 = 120 bits)
    ///         so a fresh observation costs exactly one SSTORE.
    /// @param blockTimestamp The timestamp the observation was recorded at.
    /// @param tickCumulative The cumulative truncated tick **at** `blockTimestamp`. Wraps by design.
    /// @param truncatedTick  The truncated tick in force **from** `blockTimestamp` onward.
    /// @param initialized    True once the slot has been populated. Slots `[0, cardinality)` are always populated
    ///                       because this library has no Uniswap-style `grow()`; the flag exists for callers and for
    ///                       explicitness, and is never branched on in the search path.
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        int24 truncatedTick;
        bool initialized;
    }

    /// @notice Per-pool oracle state. `obs` occupies slots +0..+63 (one slot per observation); every scalar below
    ///         packs into the single "head" slot +64 (16 + 16 + 24 + 24 + 24 + 32 = 136 bits), so `write` touches at
    ///         most two slots. Solidity's EIP-2200 dirty-slot behaviour makes the second and later field writes to an
    ///         already-written slot cost 100 gas, so updating several head fields is still one SSTORE's worth.
    /// @param obs               The ring buffer.
    /// @param index             Index of the most recent observation.
    /// @param cardinality       Number of populated observations, 0 until `initialize`, capped at MAX_CARDINALITY.
    /// @param highWaterTick     Maximum truncated tick seen since the last `resetHighWater` (drives the buyback burn).
    /// @param lastTruncatedTick The truncated tick currently in force; equals `obs[index].truncatedTick`. Kept in the
    ///                          head slot so `resetHighWater` and the cap path never have to touch the ring.
    /// @param blockAnchorTick   The truncated tick as of the end of the previous written block: the anchor the
    ///                          per-block cap is charged against.
    /// @param lastBlockNumber   `uint32(block.number)` of the last write. Only equality is ever tested, so truncating
    ///                          a wider block number to 32 bits is harmless (a block number cannot repeat within a
    ///                          block).
    struct State {
        Observation[64] obs;
        uint16 index;
        uint16 cardinality;
        int24 highWaterTick;
        int24 lastTruncatedTick;
        int24 blockAnchorTick;
        uint32 lastBlockNumber;
    }

    /// @notice Thrown by `initialize` when the state already holds observations.
    error AlreadyInitialized();
    /// @notice Thrown by every read/write path when `initialize` has not been called.
    error NotInitialized();
    /// @notice Thrown by `initialize` when the seed tick is outside `[TickMath.MIN_TICK, TickMath.MAX_TICK]`.
    error InvalidTick(int24 tick);
    /// @notice Thrown by `write` when the per-block cap is not strictly positive (a zero cap would freeze the oracle).
    error InvalidMaxTickMove(int24 maxTickMovePerBlock);
    /// @notice Thrown by `consult` when the window is zero.
    error ZeroWindow();
    /// @notice Thrown when the ring does not reach far enough back. Callers that must degrade gracefully should read
    ///         `observationCoverage` first rather than catching this.
    /// @param requestedSecondsAgo How far back the caller asked to look.
    /// @param availableSeconds    How far back the oldest observation actually reaches (== `observationCoverage`).
    error WindowNotCovered(uint32 requestedSecondsAgo, uint32 availableSeconds);

    /// @notice Seeds the ring with a single observation and arms the per-block cap at `tick`.
    /// @dev    `lastBlockNumber` is deliberately left at zero: the first `write` in any real block (block number != 0)
    ///         therefore counts as a new block and anchors its allowance at `tick`.
    /// @param s    The pool's oracle state.
    /// @param time The current `uint32(block.timestamp)`.
    /// @param tick The pool's current tick. Must be a valid tick.
    function initialize(State storage s, uint32 time, int24 tick) internal {
        if (s.cardinality != 0) revert AlreadyInitialized();
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) revert InvalidTick(tick);

        s.obs[0] = Observation({blockTimestamp: time, tickCumulative: 0, truncatedTick: tick, initialized: true});
        s.index = 0;
        s.cardinality = 1;
        s.highWaterTick = tick;
        s.lastTruncatedTick = tick;
        s.blockAnchorTick = tick;
    }

    /// @notice Records one post-swap tick, truncated to the block's remaining allowance.
    /// @dev    Two storage slots at most: the observation (a fresh slot when the timestamp advanced, the head
    ///         observation updated in place when it did not) and the packed head. Never reverts for an in-range tick
    ///         once initialized, which is what lets `afterSwap` call it unconditionally.
    /// @param s                   The pool's oracle state.
    /// @param time                `uint32(block.timestamp)`.
    /// @param blockNumber         `uint32(block.number)`. Used only for equality against the previous write.
    /// @param tick                The raw post-swap pool tick.
    /// @param maxTickMovePerBlock The per-block allowance, strictly positive.
    /// @return truncatedTick The tick actually recorded.
    function write(State storage s, uint32 time, uint32 blockNumber, int24 tick, int24 maxTickMovePerBlock)
        internal
        returns (int24 truncatedTick)
    {
        uint16 cardinality = s.cardinality;
        if (cardinality == 0) revert NotInitialized();
        if (maxTickMovePerBlock <= 0) revert InvalidMaxTickMove(maxTickMovePerBlock);

        int24 lastTruncatedTick = s.lastTruncatedTick;

        // The per-block allowance. A new block re-anchors it at the tick the previous block ended on; every further
        // write inside the same block is measured against that same anchor, so N swaps cannot buy N caps of movement.
        int24 anchor;
        if (blockNumber != s.lastBlockNumber) {
            anchor = lastTruncatedTick;
            s.blockAnchorTick = anchor;
            s.lastBlockNumber = blockNumber;
        } else {
            anchor = s.blockAnchorTick;
        }

        truncatedTick = _truncate(tick, anchor, maxTickMovePerBlock);

        uint16 index = s.index;
        Observation memory last = s.obs[index];
        uint32 elapsed;
        // Safe: uint32 timestamps wrap by design and only the difference is used (Uniswap v3 oracle argument).
        unchecked {
            elapsed = time - last.blockTimestamp;
        }

        if (elapsed != 0) {
            int56 tickCumulative;
            // Safe: the accumulator is meant to wrap (see the library-level overflow note); `elapsed` fits in uint32
            // and `lastTruncatedTick` in int24, so the product cannot overflow int56 on any realistic elapsed time.
            unchecked {
                tickCumulative = last.tickCumulative + int56(lastTruncatedTick) * int56(uint56(elapsed));
            }

            uint16 cardinalityUpdated = cardinality < MAX_CARDINALITY ? cardinality + 1 : MAX_CARDINALITY;
            uint16 indexUpdated;
            // Safe: `index` <= 63 and `cardinalityUpdated` >= 1.
            unchecked {
                indexUpdated = (index + 1) % cardinalityUpdated;
            }

            s.obs[indexUpdated] = Observation({
                blockTimestamp: time, tickCumulative: tickCumulative, truncatedTick: truncatedTick, initialized: true
            });
            s.index = indexUpdated;
            if (cardinalityUpdated != cardinality) s.cardinality = cardinalityUpdated;
        } else {
            // Same timestamp: zero seconds elapsed, so the accumulator is unchanged and there is nothing to record
            // separately. Overwrite the head observation's tick in place, keeping one observation per timestamp.
            s.obs[index].truncatedTick = truncatedTick;
        }

        s.lastTruncatedTick = truncatedTick;
        if (truncatedTick > s.highWaterTick) s.highWaterTick = truncatedTick;
    }

    /// @notice Resets the per-pool high-water mark to the tick currently in force.
    /// @dev    Called by the vault immediately after `compound` has withdrawn and burned the bought-back AMPS, so the
    ///         next compounding measures a fresh excursion. One SLOAD + one SSTORE on the head slot.
    function resetHighWater(State storage s) internal {
        if (s.cardinality == 0) revert NotInitialized();
        s.highWaterTick = s.lastTruncatedTick;
    }

    /// @notice Mean truncated tick over `[time - window, time]`.
    /// @dev    Rounded toward negative infinity; see the library-level rounding note. Reverts `WindowNotCovered` when
    ///         the ring does not reach back `window` seconds - check `observationCoverage` first to degrade.
    /// @param s      The pool's oracle state.
    /// @param time   `uint32(block.timestamp)`.
    /// @param window The averaging window in seconds, strictly positive.
    /// @return meanTruncatedTick The time-weighted arithmetic mean of the truncated tick series.
    function consult(State storage s, uint32 time, uint32 window) internal view returns (int24 meanTruncatedTick) {
        if (window == 0) revert ZeroWindow();

        int56 cumulativeNow = _tickCumulativeAt(s, time, time);
        uint32 target;
        // Safe: uint32 timestamps wrap by design; `_lte` interprets the result on the mod-2**32 circle.
        unchecked {
            target = time - window;
        }
        int56 cumulativeThen = _tickCumulativeAt(s, time, target);

        // Safe: the difference of two wrapped accumulators is exact modulo 2**56 and the true difference fits in
        // int56 for any realistic window (see the library-level overflow note).
        unchecked {
            int56 delta = cumulativeNow - cumulativeThen;
            int56 windowSigned = int56(uint56(window));
            int56 mean = delta / windowSigned;
            // Solidity truncates toward zero; step down to make the result a floor.
            if (delta < 0 && delta % windowSigned != 0) --mean;
            // Casting to `int24` is safe because every recorded tick is clamped into [MIN_TICK, MAX_TICK] by
            // `_truncate`, so the time-weighted mean of the series lies in that range too.
            // forge-lint: disable-next-line(unsafe-typecast)
            meanTruncatedTick = int24(mean);
        }
    }

    /// @notice `consult` over the protocol's canonical 30-minute window.
    function twap30m(State storage s, uint32 time) internal view returns (int24 meanTruncatedTick) {
        return consult(s, time, TWAP_WINDOW);
    }

    /// @notice Uniswap-style batch read of the cumulative accumulator at several points in the past.
    /// @param s           The pool's oracle state.
    /// @param time        `uint32(block.timestamp)`.
    /// @param secondsAgos How far back each reading should be taken. `0` means "now".
    /// @return tickCumulatives One accumulator value per entry, exact (no interpolation rounding).
    function observe(State storage s, uint32 time, uint32[] memory secondsAgos)
        internal
        view
        returns (int56[] memory tickCumulatives)
    {
        uint256 length = secondsAgos.length;
        tickCumulatives = new int56[](length);
        for (uint256 i = 0; i < length; ++i) {
            uint32 target;
            // Safe: uint32 timestamps wrap by design.
            unchecked {
                target = time - secondsAgos[i];
            }
            tickCumulatives[i] = _tickCumulativeAt(s, time, target);
        }
    }

    /// @notice How many seconds of history the ring currently covers, i.e. the largest window `consult` will accept.
    /// @dev    Returns 0 before `initialize`. Exact.
    function observationCoverage(State storage s, uint32 time) internal view returns (uint32 secondsCovered) {
        uint16 cardinality = s.cardinality;
        if (cardinality == 0) return 0;
        // Safe: `index` <= 63 and `cardinality` >= 1; timestamps wrap by design.
        unchecked {
            uint32 oldest = s.obs[(s.index + 1) % cardinality].blockTimestamp;
            secondsCovered = time - oldest;
        }
    }

    /// @notice The oldest observation still retained by the ring.
    function oldestObservation(State storage s) internal view returns (Observation memory observation) {
        uint16 cardinality = s.cardinality;
        if (cardinality == 0) revert NotInitialized();
        // Safe: `index` <= 63 and `cardinality` >= 1.
        unchecked {
            observation = s.obs[(s.index + 1) % cardinality];
        }
    }

    /// @notice The most recent observation.
    function newestObservation(State storage s) internal view returns (Observation memory observation) {
        if (s.cardinality == 0) revert NotInitialized();
        observation = s.obs[s.index];
    }

    /// @dev Clamps `tick` into `[anchor - maxMove, anchor + maxMove]` and then into the valid tick range. Both clamps
    ///      are exact. The second clamp can never widen the first: `anchor` is itself always a valid tick, so pulling
    ///      the result into `[MIN_TICK, MAX_TICK]` moves it toward `anchor`. It is what guarantees, inductively, that
    ///      every recorded tick is a valid tick and hence that the int56 accumulator bound above holds.
    function _truncate(int24 tick, int24 anchor, int24 maxMove) private pure returns (int24) {
        // int256 throughout: `anchor +/- maxMove` can leave int24 even though the clamped result cannot.
        int256 value = int256(tick);
        int256 lower = int256(anchor) - int256(maxMove);
        int256 upper = int256(anchor) + int256(maxMove);
        if (value < lower) value = lower;
        else if (value > upper) value = upper;
        if (value < TickMath.MIN_TICK) value = TickMath.MIN_TICK;
        else if (value > TickMath.MAX_TICK) value = TickMath.MAX_TICK;
        // Casting to `int24` is safe because the two clamps immediately above pin `value` into
        // [MIN_TICK, MAX_TICK], which is well inside int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(value);
    }

    /// @dev The accumulator at `target`, exact. See the observation-semantics note: the tick recorded on an
    ///      observation is constant until the next one, so extending that observation forward by
    ///      `truncatedTick * elapsed` reproduces the accumulator with no interpolation error. When `target` is at or
    ///      after the newest observation the same formula extrapolates with the tick currently in force.
    function _tickCumulativeAt(State storage s, uint32 time, uint32 target)
        private
        view
        returns (int56 tickCumulative)
    {
        Observation memory beforeOrAt = _observationBeforeOrAt(s, time, target);
        // Safe: timestamps wrap by design, and the accumulator is meant to wrap.
        unchecked {
            tickCumulative = beforeOrAt.tickCumulative + int56(beforeOrAt.truncatedTick)
                * int56(uint56(target - beforeOrAt.blockTimestamp));
        }
    }

    /// @dev The newest observation at or before `target`. Reverts `WindowNotCovered` when `target` predates the ring.
    function _observationBeforeOrAt(State storage s, uint32 time, uint32 target)
        private
        view
        returns (Observation memory beforeOrAt)
    {
        uint16 cardinality = s.cardinality;
        if (cardinality == 0) revert NotInitialized();

        uint16 index = s.index;
        beforeOrAt = s.obs[index];
        // Common case: the caller is asking about now, or about a moment after the last swap.
        if (_lte(time, beforeOrAt.blockTimestamp, target)) return beforeOrAt;

        uint16 oldestIndex;
        // Safe: `index` <= 63 and `cardinality` >= 1.
        unchecked {
            oldestIndex = (index + 1) % cardinality;
        }
        uint32 oldestTimestamp = s.obs[oldestIndex].blockTimestamp;
        if (!_lte(time, oldestTimestamp, target)) {
            // Safe: timestamps wrap by design and both differences are taken on the same circle.
            unchecked {
                revert WindowNotCovered(time - target, time - oldestTimestamp);
            }
        }

        return _binarySearch(s, time, target, index, cardinality);
    }

    /// @dev Uniswap v3's ring binary search. Only reached when `oldest.blockTimestamp <= target < newest`
    ///      (on the mod-2**32 circle), so a bracketing pair always exists and the loop always terminates. Every index
    ///      it visits is populated, because this library grows `cardinality` only as it writes.
    function _binarySearch(State storage s, uint32 time, uint32 target, uint16 index, uint16 cardinality)
        private
        view
        returns (Observation memory beforeOrAt)
    {
        // Safe: all values are bounded by `cardinality` <= 64 and the loop only narrows a non-empty bracket.
        unchecked {
            uint256 left = (uint256(index) + 1) % cardinality;
            uint256 right = left + cardinality - 1;
            uint256 i;
            while (true) {
                i = (left + right) / 2;
                beforeOrAt = s.obs[i % cardinality];
                Observation memory atOrAfter = s.obs[(i + 1) % cardinality];
                bool targetAtOrAfter = _lte(time, beforeOrAt.blockTimestamp, target);
                if (targetAtOrAfter && _lte(time, target, atOrAfter.blockTimestamp)) break;
                if (!targetAtOrAfter) right = i - 1;
                else left = i + 1;
            }
        }
    }

    /// @dev `a <= b`, comparing two `uint32` timestamps on the mod-2**32 circle whose "present" is `time`. Lifted in
    ///      spirit (not in code) from Uniswap v3's `Oracle.lte`; it is what keeps the ring correct past 2106.
    function _lte(uint32 time, uint32 a, uint32 b) private pure returns (bool) {
        // Safe: the adjustments are performed in uint256, well clear of any overflow.
        unchecked {
            if (a <= time && b <= time) return a <= b;
            uint256 aAdjusted = a > time ? a : uint256(a) + 2 ** 32;
            uint256 bAdjusted = b > time ? b : uint256(b) + 2 ** 32;
            return aAdjusted <= bAdjusted;
        }
    }
}
