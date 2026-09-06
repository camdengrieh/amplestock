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
/// (for the cap) and timestamp identity (for the accumulator) are deliberately tracked separately.
///
/// ## The head, and why ring insertion is rate-limited
///
/// The accumulator advances on **every** write. The ring does not.
///
/// A ring of `MAX_CARDINALITY` slots that took one slot per distinct second covered only `MAX_CARDINALITY` seconds
/// once a pool traded every second - 63 s against an 1,800 s window - so an actively traded pool destroyed its own
/// TWAP coverage and took the reference gate to `WATCHDOG` with it (`docs/phase3-state-model.md` §12.3 ruling V). On
/// a 100 ms chain that is ordinary trading, not an attack.
///
/// The fix separates the two jobs the old ring was doing at once:
///
/// - **The head** (`headTimestamp` / `headCumulative` / `lastTruncatedTick`, all packed into the state's single
///   scalar slot) is the newest observation. It is overwritten in place on every write, and because each write
///   advances it by `lastTruncatedTick * (now - headTimestamp)` - the tick that really was in force over exactly that
///   interval - the head accumulator is **exact**, whatever the swap cadence.
/// - **The ring** keeps `MAX_CARDINALITY` snapshots of the head, committed no more often than one per
///   `MIN_INSERT_INTERVAL` seconds. `MIN_INSERT_INTERVAL = ceil(MAX_TWAP_WINDOW / (MAX_CARDINALITY - 1))` = 115 s,
///   so a full ring spans `63 * 115 = 7,245 s >= MAX_TWAP_WINDOW`: coverage is bounded **below** by the widest window
///   governance can set, for every governed value, and it can never again fall under a window because the pool is
///   busy. Before the ring has wrapped the oldest slot is still the seed, so coverage is simply the time since
///   `initialize` and is monotone non-decreasing.
///
/// Nothing about the truncation changed: `blockAnchorTick`, the per-block allowance and `highWaterTick` are updated
/// on every write exactly as before, so I25 and I33 are untouched by the rate limit.
///
/// ## Observation semantics, and the one place interpolation is inexact
///
/// `obs[i].tickCumulative` is the accumulator value **at** `obs[i].blockTimestamp`; `headCumulative` likewise at
/// `headTimestamp`. Both are exact. What the ring no longer carries is the *shape* of the tick series between two
/// committed slots: several swaps can share one interval, and only the tick in force at its start is recorded.
/// Readings are therefore taken as:
///
/// - `target >= headTimestamp` - **exact**. `lastTruncatedTick` is in force from `headTimestamp` onward, so
///   `headCumulative + lastTruncatedTick * (target - headTimestamp)` reproduces the accumulator with no error. This
///   is the near end of every `consult`, which is why "now" is never interpolated.
/// - `target` inside `[before.blockTimestamp, after.blockTimestamp]` - **linear between two exact endpoints**, the
///   `after` end being the head when `target` is newer than the newest committed slot. The interpolated value is
///   exact at both ends and, in between, carries the error bounded below.
///
/// ### The interpolation bound
///
/// Write `D` for the length of the committed interval the far end of the window lands in, `B` for the number of
/// blocks *written* inside that interval, and `w` for the window. Linear interpolation reports that interval's
/// *average* tick where the true series had some other shape, and the two can differ by at most the tick's spread
/// inside the interval, which the per-block cap holds under `maxTickMovePerBlock * B`. So
///
///     |consult(w) - consultWithOneSlotPerWrite(w)| <= maxTickMovePerBlock * B * D / w  (+ under 2 of rounding:
///                                                    `_interpolate` ceils, `consult` floors)
///
/// While trading is continuous `D <= MIN_INSERT_INTERVAL`, so for the canonical window that is `cap * B * 115 / 1800`
/// - under 6.4% of `cap * B` - and `B` is itself only the blocks in one 115 s interval, which makes the whole term
/// about 0.4% of the I25 budget `cap * blocksInWindow`. Sparser trading lengthens `D` but empties the interval in the
/// same breath: seconds with no write contribute no spread, so `B` falls with it, and an interval with no write at
/// all is reproduced exactly. Two consequences worth stating: the reported mean stays a time-weighted average of
/// truncated ticks actually in force (so it remains bracketed by the extremes of the series, which is what makes I25
/// a bound on it), and it may reach at most one committed interval further back than the window asked for.
///
/// ## Rounding directions (every one in this library)
///
/// - `_truncate`: exact. Clamping only; no division.
/// - `write`: exact. `headCumulative += lastTruncatedTick * elapsedSeconds` is an exact integer product.
/// - `_tickCumulativeAt` at or after the head: exact. No division on that path.
/// - `_interpolate`, i.e. a target strictly inside a committed interval: rounded **toward positive infinity**. It is
///   only ever the *past* end of a window, so rounding the subtrahend up can only shrink the reported mean, which is
///   the conservative direction (see `consult`).
/// - `consult`: `(cumNow - cumThen) / window` is rounded **toward negative infinity** (floor), matching Uniswap v3's
///   `OracleLibrary.consult`. Solidity's `/` truncates toward zero, so one is subtracted when the delta is negative
///   and the division is inexact. Flooring is the conservative direction for Amplestocks: AMPS is `currency0` in
///   every pool, so a lower tick means a lower AMPS price, and under-reporting `P_mkt` can only shrink `P_ref`
///   toward the NAV floor, tighten the fee wall's `fairTick` and lower the bond quote - never mint AMPS more cheaply.
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

    /// @notice The widest window governance may set, mirroring `Constants.TWAP_WINDOW_MAX`.
    /// @dev    Duplicated here rather than imported so the library stays free-standing (`TWAP_WINDOW` already is);
    ///         `test/unit/TruncatedOracleLib.t.sol` asserts the two cannot drift.
    uint32 internal constant MAX_TWAP_WINDOW = 7200;

    /// @notice Minimum seconds between two committed ring slots, `ceil(MAX_TWAP_WINDOW / (MAX_CARDINALITY - 1))`.
    /// @dev    A full ring holds `MAX_CARDINALITY` committed slots and therefore spans `MAX_CARDINALITY - 1` gaps of
    ///         at least this length: `63 * 115 = 7,245 >= 7,200`, so coverage is bounded below by the widest
    ///         governable window however hard the pool is traded. Writes in between still advance the head.
    uint32 internal constant MIN_INSERT_INTERVAL =
        (MAX_TWAP_WINDOW + uint32(MAX_CARDINALITY) - 2) / (uint32(MAX_CARDINALITY) - 1);

    /// @notice One recorded observation. All four fields pack into a single 32-byte slot (32 + 56 + 24 + 8 = 120 bits)
    ///         so a committed observation costs exactly one SSTORE.
    /// @param blockTimestamp The timestamp the observation was recorded at.
    /// @param tickCumulative The cumulative truncated tick **at** `blockTimestamp`. Exact. Wraps by design.
    /// @param truncatedTick  The truncated tick in force **at** `blockTimestamp`. It is *not* guaranteed to be in
    ///                       force until the next observation - that is what the head and the interpolation bound in
    ///                       the library note are about - so readers interpolate between endpoints rather than
    ///                       extending this value, except past the head where it is exact.
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
    ///         packs into the single "head" slot +64, which they fill exactly
    ///         (16 + 16 + 24 + 24 + 24 + 32 + 32 + 56 + 32 = 256 bits). A write that does not commit a ring slot
    ///         therefore touches **one** slot, and one that does touches two. Solidity's EIP-2200 dirty-slot
    ///         behaviour makes the second and later field writes to an already-written slot cost 100 gas, so
    ///         updating several head fields is still one SSTORE's worth.
    /// @param obs                 The ring buffer of committed observations.
    /// @param index               Index of the most recent **committed** observation.
    /// @param cardinality         Number of populated observations, 0 until `initialize`, capped at MAX_CARDINALITY.
    /// @param highWaterTick       Maximum truncated tick seen since the last `resetHighWater` (drives the buyback
    ///                            burn).
    /// @param lastTruncatedTick   The truncated tick currently in force, i.e. the head observation's tick: in force
    ///                            from `headTimestamp` onward, which is what makes readings past the head exact.
    /// @param blockAnchorTick     The truncated tick as of the end of the previous written block: the anchor the
    ///                            per-block cap is charged against.
    /// @param lastBlockNumber     `uint32(block.number)` of the last write. Only equality is ever tested, so
    ///                            truncating a wider block number to 32 bits is harmless (a block number cannot
    ///                            repeat within a block).
    /// @param headTimestamp       Timestamp of the head observation: the last write that advanced the clock.
    /// @param headCumulative      The accumulator **at** `headTimestamp`. Exact on every write. Wraps by design.
    /// @param lastCommitTimestamp `obs[index].blockTimestamp`, kept here so `write` can decide whether to commit
    ///                            without reading the ring at all.
    struct State {
        Observation[64] obs;
        uint16 index;
        uint16 cardinality;
        int24 highWaterTick;
        int24 lastTruncatedTick;
        int24 blockAnchorTick;
        uint32 lastBlockNumber;
        uint32 headTimestamp;
        int56 headCumulative;
        uint32 lastCommitTimestamp;
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

    /// @notice Seeds the ring and the head with a single observation and arms the per-block cap at `tick`.
    /// @dev    `lastBlockNumber` is deliberately left at zero: the first `write` in any real block (block number != 0)
    ///         therefore counts as a new block and anchors its allowance at `tick`. `lastCommitTimestamp` is seeded
    ///         at `time`, so the first ring slot after the seed is committed `MIN_INSERT_INTERVAL` seconds later.
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
        s.headTimestamp = time;
        s.lastCommitTimestamp = time;
        // `headCumulative` starts at zero, which is the slot's value already.
    }

    /// @notice Records one post-swap tick, truncated to the block's remaining allowance.
    /// @dev    One storage slot in the common case - the packed head, which carries the accumulator - and two when
    ///         the write also commits a ring slot, which happens at most once per `MIN_INSERT_INTERVAL` seconds. The
    ///         ring is never *read* here. Never reverts for an in-range tick once initialized, which is what lets
    ///         `afterSwap` call it unconditionally.
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

        uint32 headTimestamp = s.headTimestamp;
        uint32 elapsed;
        // Safe: uint32 timestamps wrap by design and only the difference is used (Uniswap v3 oracle argument).
        unchecked {
            elapsed = time - headTimestamp;
        }

        if (elapsed != 0) {
            // The head advances by the tick that really was in force over exactly this interval, so the accumulator
            // stays exact however many writes share the interval between two committed slots.
            int56 headCumulative;
            // Safe: the accumulator is meant to wrap (see the library-level overflow note); `elapsed` fits in uint32
            // and `lastTruncatedTick` in int24, so the product cannot overflow int56 on any realistic elapsed time.
            unchecked {
                headCumulative = s.headCumulative + int56(lastTruncatedTick) * int56(uint56(elapsed));
            }
            s.headCumulative = headCumulative;
            s.headTimestamp = time;

            uint32 sinceCommit;
            // Safe: timestamps wrap by design; `lastCommitTimestamp` is always at or before `time`.
            unchecked {
                sinceCommit = time - s.lastCommitTimestamp;
            }
            // Rate-limited ring insertion: the head is snapshotted into a fresh slot only once the previous slot is
            // at least `MIN_INSERT_INTERVAL` seconds old, which is what bounds coverage below by `MAX_TWAP_WINDOW`.
            if (sinceCommit >= MIN_INSERT_INTERVAL) {
                uint16 cardinalityUpdated = cardinality < MAX_CARDINALITY ? cardinality + 1 : MAX_CARDINALITY;
                uint16 indexUpdated;
                // Safe: `index` <= 63 and `cardinalityUpdated` >= 1.
                unchecked {
                    indexUpdated = (s.index + 1) % cardinalityUpdated;
                }

                s.obs[indexUpdated] = Observation({
                    blockTimestamp: time,
                    tickCumulative: headCumulative,
                    truncatedTick: truncatedTick,
                    initialized: true
                });
                s.index = indexUpdated;
                s.lastCommitTimestamp = time;
                if (cardinalityUpdated != cardinality) s.cardinality = cardinalityUpdated;
            }
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

        // The near end is at the head, so it is exact and never interpolated.
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
    /// @return tickCumulatives One accumulator value per entry; exact at or after the head, and interpolated (rounded
    ///                        up) strictly inside a committed interval.
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
    /// @dev    Returns 0 before `initialize`. Exact. Measured from the oldest **committed** slot, which is the seed
    ///         until the ring first wraps (so coverage is monotone non-decreasing over the first
    ///         `MAX_CARDINALITY * MIN_INSERT_INTERVAL` seconds of trading) and at least
    ///         `(MAX_CARDINALITY - 1) * MIN_INSERT_INTERVAL >= MAX_TWAP_WINDOW` seconds afterwards.
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

    /// @notice The most recent observation: the head, which is newer than the newest committed slot whenever the
    ///         pool has traded since the last insertion.
    function newestObservation(State storage s) internal view returns (Observation memory observation) {
        if (s.cardinality == 0) revert NotInitialized();
        observation = _head(s);
    }

    /// @notice The newest observation the ring itself holds, i.e. the last one committed.
    /// @dev    Exposed beside {newestObservation} because the two differ by design: the gap between them is the
    ///         insertion rate limit at work.
    function newestCommittedObservation(State storage s) internal view returns (Observation memory observation) {
        if (s.cardinality == 0) revert NotInitialized();
        observation = s.obs[s.index];
    }

    /// @dev The head observation, assembled from the packed scalar slot.
    function _head(State storage s) private view returns (Observation memory observation) {
        observation = Observation({
            blockTimestamp: s.headTimestamp,
            tickCumulative: s.headCumulative,
            truncatedTick: s.lastTruncatedTick,
            initialized: true
        });
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

    /// @dev The accumulator at `target`. Exact at or after the head (the tick in force there is known, so the
    ///      accumulator simply extends forward); linear between the two exact endpoints that bracket `target`
    ///      otherwise. See the library note for the error that second case carries.
    function _tickCumulativeAt(State storage s, uint32 time, uint32 target)
        private
        view
        returns (int56 tickCumulative)
    {
        uint16 cardinality = s.cardinality;
        if (cardinality == 0) revert NotInitialized();

        uint32 headTimestamp = s.headTimestamp;
        if (_lte(time, headTimestamp, target)) {
            // Safe: timestamps wrap by design, and the accumulator is meant to wrap.
            unchecked {
                return s.headCumulative + int56(s.lastTruncatedTick) * int56(uint56(target - headTimestamp));
            }
        }

        uint16 index = s.index;
        Observation memory beforeOrAt = s.obs[index];
        Observation memory atOrAfter;
        if (_lte(time, beforeOrAt.blockTimestamp, target)) {
            // Between the newest committed slot and the head.
            atOrAfter = _head(s);
        } else {
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
            (beforeOrAt, atOrAfter) = _binarySearch(s, time, target, index, cardinality);
        }

        tickCumulative = _interpolate(beforeOrAt, atOrAfter, target);
    }

    /// @dev Linear interpolation between two exact accumulator readings, rounded toward positive infinity. Exact at
    ///      both endpoints (`target == before_.blockTimestamp` returns `before_.tickCumulative` and
    ///      `target == after_.blockTimestamp` returns `after_.tickCumulative`), so a target that lands on a committed
    ///      slot carries no error at all. The result is `before_` plus a fraction of the interval's accumulator
    ///      delta, which is the interval's *average* truncated tick times the offset - a value the recorded series
    ///      really took, which is why the mean `consult` reports stays inside the series' own extremes.
    function _interpolate(Observation memory before_, Observation memory after_, uint32 target)
        private
        pure
        returns (int56 tickCumulative)
    {
        // Safe: timestamps wrap by design, the accumulator is meant to wrap, and the products below are taken in
        // int256 where they cannot overflow (see the bound argument on `quotient`).
        unchecked {
            uint32 offset = target - before_.blockTimestamp;
            if (offset == 0) return before_.tickCumulative;

            uint32 span = after_.blockTimestamp - before_.blockTimestamp;
            int56 delta = after_.tickCumulative - before_.tickCumulative;

            int256 numerator = int256(delta) * int256(uint256(offset));
            int256 quotient = numerator / int256(uint256(span));
            // Solidity truncates toward zero; step up to make the result a ceiling. Only the *past* end of a window
            // is ever interpolated, so a subtrahend rounded up can only lower the mean `consult` reports.
            if (numerator > 0 && quotient * int256(uint256(span)) != numerator) ++quotient;

            // Casting to `int56` is safe: `offset < span`, so |quotient| <= |delta|, which is an int56.
            // forge-lint: disable-next-line(unsafe-typecast)
            tickCumulative = before_.tickCumulative + int56(quotient);
        }
    }

    /// @dev Uniswap v3's ring binary search, returning the bracketing pair rather than only its left end. Only
    ///      reached when `oldest.blockTimestamp <= target < newestCommitted.blockTimestamp` (on the mod-2**32
    ///      circle), so a bracketing pair always exists and the loop always terminates. Every index it visits is
    ///      populated, because this library grows `cardinality` only as it commits.
    function _binarySearch(State storage s, uint32 time, uint32 target, uint16 index, uint16 cardinality)
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        // Safe: all values are bounded by `cardinality` <= 64 and the loop only narrows a non-empty bracket.
        unchecked {
            uint256 left = (uint256(index) + 1) % cardinality;
            uint256 right = left + cardinality - 1;
            uint256 i;
            while (true) {
                i = (left + right) / 2;
                beforeOrAt = s.obs[i % cardinality];
                atOrAfter = s.obs[(i + 1) % cardinality];
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
