// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TruncatedOracleLib} from "../../src/lib/TruncatedOracleLib.sol";
import {TruncatedOracleHarness} from "../unit/TruncatedOracleLib.t.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The manipulation bound of invariant I25:
///
///         "Truncated TWAP over any window moves <= `maxTickMovePerBlock` x `blocksInWindow` regardless of swap
///          sequence."
///
/// @dev Every test here drives the oracle with an adversarial, fully random swap sequence: raw ticks anywhere in the
///      int24 range, 0-10 blocks between writes, and at most one whole second per elapsed block. Robinhood Chain runs
///      ~100 ms blocks against whole-second timestamps, so several blocks routinely share one timestamp and a
///      manipulator gets several capped moves inside one second - which is exactly why the bound is stated in blocks
///      and not in seconds.
///
/// @dev **Ring insertion is rate-limited; the accumulator is not.** Every write advances the head exactly, and a ring
///      slot is committed at most once per `MIN_INSERT_INTERVAL` seconds (see the library note). The properties below
///      are therefore stated against the head - which is exact - and against the committed slots' spacing, rather
///      than against "one observation per second", which the ring deliberately no longer holds.
contract TruncatedOracleLibFuzzTest is Test {
    /// @dev Number of adversarial writes per run.
    uint256 internal constant STEPS = 24;
    /// @dev Quiet blocks written before the attack, so the window is fully covered and the pre-attack mean is exact.
    uint32 internal constant BASELINE_BLOCKS = 40;
    /// @dev Window used for the pre-attack mean; strictly inside the baseline.
    uint32 internal constant BASELINE_WINDOW = 30;
    /// @dev Upper bound on the fuzzed per-block cap. 20000 ticks is ~7.4x, far above any plausible governed value.
    int24 internal constant MAX_FUZZED_CAP = 20_000;

    uint32 internal constant T0 = 1_000_000;

    /// @dev Everything the attack loop carries, kept in memory so the tests stay clear of the stack limit.
    /// @param time           Current `uint32(block.timestamp)`.
    /// @param blockNumber    Current `uint32(block.number)`.
    /// @param cap            The per-block allowance in force.
    /// @param entropy        Seed the per-step blocks/seconds/tick triples are derived from.
    /// @param blocksInWindow Blocks the window spans: the block live when it opened, plus every new block since.
    /// @param lowest         Lowest truncated tick recorded during the attack.
    /// @param highest        Highest truncated tick recorded during the attack.
    /// @param live           The truncated tick currently in force.
    /// @param cumulative     Ghost of the exact accumulator: the integral of the truncated tick series since `T0`.
    struct Run {
        uint32 time;
        uint32 blockNumber;
        int24 cap;
        uint256 entropy;
        uint256 blocksInWindow;
        int24 lowest;
        int24 highest;
        int24 live;
        int256 cumulative;
    }

    TruncatedOracleHarness internal oracle;

    function setUp() public {
        oracle = new TruncatedOracleHarness();
    }

    // ---------------------------------------------------------------------------------------------------------
    // I25
    // ---------------------------------------------------------------------------------------------------------

    /// @notice I25: no swap sequence can move the truncated TWAP by more than `cap x blocksInWindow`.
    function testFuzz_i25_twapBoundedByCapTimesBlocksInWindow(int24 seedTick, int24 seedCap, uint256 entropy) public {
        int24 tick0 = _boundTick(seedTick);
        Run memory r = _baseline(tick0, _boundCap(seedCap), entropy);

        // The window opens here. The last baseline write was alone in its block, so both the live tick and the
        // block's cap anchor are exactly `tick0` - which is what makes the bound below tight.
        uint32 windowStart = r.time;
        int24 meanBefore = oracle.consult(r.time, BASELINE_WINDOW);
        assertEq(meanBefore, tick0, "baseline mean is the baseline tick");
        assertEq(oracle.blockAnchorTick(), tick0, "window opens on a fresh block anchor");
        assertEq(oracle.lastTruncatedTick(), tick0, "window opens at the baseline tick");

        _attack(r);

        uint32 window = r.time - windowStart;
        int256 budget = int256(r.cap) * int256(r.blocksInWindow);

        if (window == 0) {
            // The whole attack happened inside one timestamp, so there is no window to average over. The live tick
            // still carries the bound - the same statement with zero elapsed time.
            assertLe(
                _abs(int256(oracle.lastTruncatedTick()) - int256(meanBefore)),
                budget,
                "I25 (degenerate zero-second window)"
            );
            return;
        }

        // I25. The `+ 1` is the floor in `consult`: the true time-weighted mean is inside `cap * blocksInWindow` of
        // `meanBefore`, and rounding toward negative infinity can move the reported value down by less than a tick.
        // The rate limit does not widen this: every tick the reported mean averages was recorded either inside the
        // window or inside the quiet baseline that precedes it, where the tick was `tick0 == meanBefore` throughout.
        assertLe(
            _abs(int256(oracle.consult(r.time, window)) - int256(meanBefore)),
            budget + 1,
            "I25: |twap after - twap before| <= cap * blocksInWindow"
        );
    }

    /// @notice The same bound over a window shorter than the attack: a partial window is not cheaper to move.
    function testFuzz_i25_holdsForEverySubWindow(int24 seedTick, int24 seedCap, uint256 entropy, uint32 seedWindow)
        public
    {
        int24 tick0 = _boundTick(seedTick);
        Run memory r = _baseline(tick0, _boundCap(seedCap), entropy);
        uint32 windowStart = r.time;

        _attack(r);

        uint32 elapsed = r.time - windowStart;
        if (elapsed == 0) return;

        // Any window that opens at or after the attack began is bounded by the same budget: every truncated tick it
        // averages was recorded inside the attack, or inside the quiet baseline at `tick0`.
        uint32 window = uint32(bound(seedWindow, 1, elapsed));
        assertLe(
            _abs(int256(oracle.consult(r.time, window)) - int256(tick0)),
            int256(r.cap) * int256(r.blocksInWindow) + 1,
            "I25 over a sub-window"
        );
    }

    /// @notice The per-write half of I25, isolated: the recorded tick never leaves the current block's allowance
    ///         band, however many swaps share the block and however far the raw tick jumps. Unaffected by the ring's
    ///         insertion rate limit, which is exactly the point of the fix.
    function testFuzz_truncatedTickNeverMovesMoreThanCapPerBlock(int24 seedTick, int24 seedCap, uint256 entropy)
        public
    {
        int24 cap = _boundCap(seedCap);
        oracle.initialize(T0, _boundTick(seedTick));

        uint32 time = T0;
        uint32 blockNumber = 1;

        for (uint256 i = 0; i < STEPS; ++i) {
            (uint32 blocksElapsed, uint32 secondsElapsed, int24 rawTick) = _step(entropy, i);
            blockNumber += blocksElapsed;
            time += secondsElapsed;

            int24 anchor = _anchorFor(blockNumber);
            int24 truncated = oracle.write(time, blockNumber, rawTick, cap);

            assertLe(_abs(int256(truncated) - int256(anchor)), int256(cap), "per-block cap, both directions");
            assertLe(truncated, TickMath.MAX_TICK, "recorded tick stays a valid tick");
            assertGe(truncated, TickMath.MIN_TICK, "recorded tick stays a valid tick");
            assertEq(oracle.blockAnchorTick(), anchor, "the anchor only moves on a new block");
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // structural invariants
    // ---------------------------------------------------------------------------------------------------------

    /// @notice The head accumulator is *exactly* the integral of the recorded tick series, on every write and
    ///         whatever the cadence. This is the property the rate limit had to preserve: the ring stops taking a
    ///         slot per second, the accumulator does not stop being exact.
    function testFuzz_theHeadAccumulatorIsTheExactIntegralOfTheTickSeries(
        int24 seedTick,
        int24 seedCap,
        uint256 entropy
    ) public {
        Run memory r = _baseline(_boundTick(seedTick), _boundCap(seedCap), entropy);
        assertEq(int256(oracle.headCumulative()), r.cumulative, "exact after the baseline");

        _attack(r);

        assertEq(int256(oracle.headCumulative()), r.cumulative, "exact after the attack");
        assertEq(oracle.headTimestamp(), r.time, "the head clock is the last write that moved it");
        assertEq(oracle.lastTruncatedTick(), r.live, "and the tick in force is the last one recorded");
    }

    /// @notice The committed slots are a strictly increasing, rate-limited sub-sequence of the head's history: each
    ///         carries the exact accumulator at its own timestamp, and consecutive slots are at least
    ///         `MIN_INSERT_INTERVAL` seconds apart, which is what bounds coverage below.
    function testFuzz_committedSlotsAreRateLimitedAndOrdered(int24 seedCap, uint256 entropy, uint8 writes) public {
        int24 cap = _boundCap(seedCap);
        uint256 count = bound(writes, 1, 120);

        oracle.initialize(T0, 0);
        uint32 time = T0;
        uint32 blockNumber = 1;

        for (uint256 i = 0; i < count; ++i) {
            // A coarser cadence than `_step`, so runs regularly cross the insertion interval.
            uint256 word = uint256(keccak256(abi.encode(entropy, i, "coarse")));
            blockNumber += uint32(word % 11) + 1;
            time += uint32(word % (2 * uint256(TruncatedOracleLib.MIN_INSERT_INTERVAL)));
            oracle.write(time, blockNumber, int24(uint24(word >> 32)), cap);
        }

        uint16 index = oracle.index();
        uint16 cardinality = oracle.cardinality();
        assertGe(cardinality, 1, "the seed is always retained");
        assertLe(cardinality, TruncatedOracleLib.MAX_CARDINALITY, "cardinality never exceeds the ring");

        for (uint16 k = 0; k + 1 < cardinality; ++k) {
            TruncatedOracleLib.Observation memory a = oracle.observationAt((index + 1 + k) % cardinality);
            TruncatedOracleLib.Observation memory b = oracle.observationAt((index + 2 + k) % cardinality);

            assertTrue(a.initialized && b.initialized, "retained slots are populated");
            assertGt(b.blockTimestamp, a.blockTimestamp, "strictly increasing");
            assertGe(
                b.blockTimestamp - a.blockTimestamp,
                TruncatedOracleLib.MIN_INSERT_INTERVAL,
                "and at least one insertion interval apart"
            );

            // The accumulator between two committed slots is the integral of ticks that really were in force, so it
            // is bracketed by the extremes of the valid tick range times the elapsed time.
            int256 dt = int256(uint256(b.blockTimestamp - a.blockTimestamp));
            int256 delta = int256(b.tickCumulative) - int256(a.tickCumulative);
            assertLe(delta, int256(TickMath.MAX_TICK) * dt, "bracketed above");
            assertGe(delta, int256(TickMath.MIN_TICK) * dt, "bracketed below");
        }

        // The newest committed slot is a snapshot of the head at the moment it was taken, never newer than it.
        assertLe(oracle.newestCommittedObservation().blockTimestamp, oracle.headTimestamp(), "commit <= head");
        assertEq(oracle.lastCommitTimestamp(), oracle.newestCommittedObservation().blockTimestamp, "commit clock");
    }

    /// @notice The TWAP over any covered window is bracketed by the extremes of the recorded tick series, which is
    ///         what turns the per-block cap on the series into a bound on the mean. Linear interpolation between two
    ///         exact endpoints keeps this true: the value it substitutes is that interval's own average tick.
    function testFuzz_twapLiesBetweenTheExtremesOfTheRecordedSeries(int24 seedTick, int24 seedCap, uint256 entropy)
        public
    {
        Run memory r = _baseline(_boundTick(seedTick), _boundCap(seedCap), entropy);
        uint32 windowStart = r.time;

        _attack(r);

        uint32 window = r.time - windowStart;
        if (window == 0) return;

        int24 mean = oracle.consult(r.time, window);
        // `- 1` on the low side only: `consult` floors.
        assertGe(mean, r.lowest - 1, "mean is at least the lowest recorded tick");
        assertLe(mean, r.highest, "mean is at most the highest recorded tick");
    }

    /// @notice `highWaterTick` is exactly the maximum truncated tick recorded since the last `resetHighWater`, and a
    ///         reset drops it to the live tick without disturbing the series.
    function testFuzz_highWaterIsTheMaximumSinceTheLastReset(
        int24 seedTick,
        int24 seedCap,
        uint256 entropy,
        uint256 resetAt
    ) public {
        int24 tick0 = _boundTick(seedTick);
        int24 cap = _boundCap(seedCap);
        uint256 resetStep = bound(resetAt, 0, STEPS - 1);

        oracle.initialize(T0, tick0);
        uint32 time = T0;
        uint32 blockNumber = 1;

        int24 expectedHighWater = tick0;
        assertEq(oracle.highWaterTick(), expectedHighWater, "seeded high water");

        for (uint256 i = 0; i < STEPS; ++i) {
            if (i == resetStep) {
                // The vault resets after compounding: the mark drops to whatever the pool is worth right now.
                int24 live = oracle.lastTruncatedTick();
                oracle.resetHighWater();
                assertEq(oracle.highWaterTick(), live, "reset lands on the live truncated tick");
                assertEq(oracle.lastTruncatedTick(), live, "reset does not disturb the tick series");
                expectedHighWater = live;
            }

            (uint32 blocksElapsed, uint32 secondsElapsed, int24 rawTick) = _step(entropy, i);
            blockNumber += blocksElapsed;
            time += secondsElapsed;
            int24 truncated = oracle.write(time, blockNumber, rawTick, cap);

            if (truncated > expectedHighWater) expectedHighWater = truncated;
            assertEq(oracle.highWaterTick(), expectedHighWater, "high water is the running maximum since the reset");
            assertGe(oracle.highWaterTick(), truncated, "high water is never below an observed truncated tick");
        }
    }

    /// @notice `observationCoverage` is exactly the largest window `consult` accepts: one second more reverts.
    function testFuzz_observationCoverageIsTheExactAcceptedWindow(int24 seedCap, uint256 entropy, uint8 writes) public {
        int24 cap = _boundCap(seedCap);
        uint256 count = bound(writes, 1, 80);

        oracle.initialize(T0, 0);
        uint32 time = T0;
        uint32 blockNumber = 1;

        for (uint256 i = 0; i < count; ++i) {
            (uint32 blocksElapsed, uint32 secondsElapsed, int24 rawTick) = _step(entropy, i);
            blockNumber += blocksElapsed;
            time += secondsElapsed;
            oracle.write(time, blockNumber, rawTick, cap);
        }

        uint32 covered = oracle.observationCoverage(time);
        assertEq(covered, time - oracle.oldestObservation().blockTimestamp, "coverage is now minus the oldest slot");

        if (covered != 0) oracle.consult(time, covered); // exactly at the edge: fine
        vm.expectRevert(abi.encodeWithSelector(TruncatedOracleLib.WindowNotCovered.selector, covered + 1, covered));
        oracle.consult(time, covered + 1);
    }

    /// @notice The liveness property the rate limit buys, under any cadence: coverage is the whole elapsed time
    ///         until the ring wraps, and never less than a full ring's span afterwards - so it is never destroyed by
    ///         trading, only ever bought by it.
    function testFuzz_coverageIsNeverLostByTrading(int24 seedCap, uint256 entropy, uint16 writes) public {
        int24 cap = _boundCap(seedCap);
        uint256 count = bound(writes, 1, 400);
        uint256 fullRing =
            uint256(TruncatedOracleLib.MAX_CARDINALITY - 1) * uint256(TruncatedOracleLib.MIN_INSERT_INTERVAL);

        oracle.initialize(T0, 0);
        uint32 time = T0;
        uint32 blockNumber = 1;

        for (uint256 i = 0; i < count; ++i) {
            uint256 word = uint256(keccak256(abi.encode(entropy, i, "coverage")));
            blockNumber += uint32(word % 11) + 1;
            // 0 to 3 insertion intervals per step: sometimes several writes share one interval, sometimes a step
            // jumps several intervals at once.
            time += uint32(word % (3 * uint256(TruncatedOracleLib.MIN_INSERT_INTERVAL) + 1));
            oracle.write(time, blockNumber, int24(uint24(word >> 32)), cap);

            uint256 elapsed = time - T0;
            uint256 floorCoverage = elapsed < fullRing ? elapsed : fullRing;
            assertGe(uint256(oracle.observationCoverage(time)), floorCoverage, "coverage is never lost by trading");
        }

        // And once two hours have gone by, the widest governable window is always answerable.
        if (time - T0 >= TruncatedOracleLib.MAX_TWAP_WINDOW) {
            assertGe(
                oracle.observationCoverage(time), TruncatedOracleLib.MAX_TWAP_WINDOW, "the widest window is covered"
            );
            oracle.consult(time, TruncatedOracleLib.MAX_TWAP_WINDOW);
        }
    }

    /// @notice `observe` and `consult` are the same computation: the mean is the accumulator delta over the window.
    function testFuzz_observeAgreesWithConsult(int24 seedCap, uint256 entropy, uint32 seedWindow) public {
        Run memory r = _baseline(0, _boundCap(seedCap), entropy);
        _attack(r);

        uint32 covered = oracle.observationCoverage(r.time);
        if (covered == 0) return;
        uint32 window = uint32(bound(seedWindow, 1, covered));

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        int56[] memory cumulatives = oracle.observe(r.time, secondsAgos);

        int256 delta = int256(cumulatives[1]) - int256(cumulatives[0]);
        int256 expected = delta / int256(uint256(window));
        if (delta < 0 && delta % int256(uint256(window)) != 0) --expected;

        assertEq(int256(oracle.consult(r.time, window)), expected, "consult == floor(observe delta / window)");
    }

    // ---------------------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Writes `BASELINE_BLOCKS` quiet blocks at `tick0`, one second apart, one write per block. Leaves the
    ///      oracle with `lastTruncatedTick == blockAnchorTick == tick0`, a fully covered `BASELINE_WINDOW`, and the
    ///      last write alone in its block, so the attack starts from an unambiguous anchor.
    function _baseline(int24 tick0, int24 cap, uint256 entropy) private returns (Run memory r) {
        r = Run({
            time: T0,
            blockNumber: 1,
            cap: cap,
            entropy: entropy,
            // The block live when the window opens still holds its own unspent allowance, so it counts.
            blocksInWindow: 1,
            lowest: tick0,
            highest: tick0,
            live: tick0,
            cumulative: 0
        });
        oracle.initialize(r.time, tick0);
        for (uint32 i = 0; i < BASELINE_BLOCKS; ++i) {
            ++r.blockNumber;
            ++r.time;
            r.cumulative += int256(r.live);
            r.live = oracle.write(r.time, r.blockNumber, tick0, cap);
        }
    }

    /// @dev `STEPS` adversarial writes, updating the run's clock, block counter, ghost accumulator and extremes.
    function _attack(Run memory r) private {
        for (uint256 i = 0; i < STEPS; ++i) {
            (uint32 blocksElapsed, uint32 secondsElapsed, int24 rawTick) = _step(r.entropy, i);
            r.blockNumber += blocksElapsed;
            r.time += secondsElapsed;
            r.blocksInWindow += blocksElapsed;
            r.cumulative += int256(r.live) * int256(uint256(secondsElapsed));

            int24 anchor = _anchorFor(r.blockNumber);
            int24 truncated = oracle.write(r.time, r.blockNumber, rawTick, r.cap);
            r.live = truncated;

            assertLe(_abs(int256(truncated) - int256(anchor)), int256(r.cap), "per-block cap");
            if (truncated < r.lowest) r.lowest = truncated;
            if (truncated > r.highest) r.highest = truncated;
        }
    }

    /// @dev The anchor `write` will charge the next call against, computed from the harness's public state.
    function _anchorFor(uint32 blockNumber) private view returns (int24) {
        return blockNumber != oracle.lastBlockNumber() ? oracle.lastTruncatedTick() : oracle.blockAnchorTick();
    }

    /// @dev One adversarial step: 0-10 blocks elapsed, at most one whole second per elapsed block (so same-timestamp
    ///      blocks are the common case, as on a 100 ms chain), and a raw tick drawn from the whole int24 range.
    function _step(uint256 entropy, uint256 i)
        private
        pure
        returns (uint32 blocksElapsed, uint32 secondsElapsed, int24 rawTick)
    {
        uint256 word = uint256(keccak256(abi.encode(entropy, i)));
        blocksElapsed = uint32(word % 11);
        secondsElapsed = blocksElapsed == 0 ? 0 : uint32((word >> 8) % (uint256(blocksElapsed) + 1));
        // Reinterpreting 24 bits as int24 draws uniformly from [type(int24).min, type(int24).max], deliberately far
        // outside the valid tick range.
        rawTick = int24(uint24(word >> 32));
    }

    function _boundTick(int24 seedTick) private pure returns (int24) {
        return int24(bound(seedTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
    }

    function _boundCap(int24 seedCap) private pure returns (int24) {
        return int24(bound(seedCap, 1, MAX_FUZZED_CAP));
    }

    function _abs(int256 x) private pure returns (int256) {
        return x < 0 ? -x : x;
    }
}
