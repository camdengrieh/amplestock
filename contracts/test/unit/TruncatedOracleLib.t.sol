// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TruncatedOracleLib} from "../../src/lib/TruncatedOracleLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice Storage host for one `TruncatedOracleLib.State`, standing in for a single pool's slot inside `AmpsHook`.
/// @dev    Kept in this file (and mirrored by the fuzz suite's own harness) so the library's owner does not have to
///         touch shared test utilities.
contract TruncatedOracleHarness {
    using TruncatedOracleLib for TruncatedOracleLib.State;

    TruncatedOracleLib.State internal state;

    function initialize(uint32 time, int24 tick) external {
        state.initialize(time, tick);
    }

    function write(uint32 time, uint32 blockNumber, int24 tick, int24 maxTickMovePerBlock)
        external
        returns (int24 truncatedTick)
    {
        return state.write(time, blockNumber, tick, maxTickMovePerBlock);
    }

    /// @notice `write`, returning the gas the library call itself consumed (no external-call overhead included).
    function writeMeasured(uint32 time, uint32 blockNumber, int24 tick, int24 maxTickMovePerBlock)
        external
        returns (int24 truncatedTick, uint256 gasUsed)
    {
        uint256 before = gasleft();
        truncatedTick = state.write(time, blockNumber, tick, maxTickMovePerBlock);
        gasUsed = before - gasleft();
    }

    function resetHighWater() external {
        state.resetHighWater();
    }

    function consult(uint32 time, uint32 window) external view returns (int24) {
        return state.consult(time, window);
    }

    function twap30m(uint32 time) external view returns (int24) {
        return state.twap30m(time);
    }

    function observe(uint32 time, uint32[] memory secondsAgos) external view returns (int56[] memory) {
        return state.observe(time, secondsAgos);
    }

    function observationCoverage(uint32 time) external view returns (uint32) {
        return state.observationCoverage(time);
    }

    function oldestObservation() external view returns (TruncatedOracleLib.Observation memory) {
        return state.oldestObservation();
    }

    function newestObservation() external view returns (TruncatedOracleLib.Observation memory) {
        return state.newestObservation();
    }

    function newestCommittedObservation() external view returns (TruncatedOracleLib.Observation memory) {
        return state.newestCommittedObservation();
    }

    function observationAt(uint256 i) external view returns (TruncatedOracleLib.Observation memory) {
        return state.obs[i];
    }

    function index() external view returns (uint16) {
        return state.index;
    }

    function cardinality() external view returns (uint16) {
        return state.cardinality;
    }

    function highWaterTick() external view returns (int24) {
        return state.highWaterTick;
    }

    function lastTruncatedTick() external view returns (int24) {
        return state.lastTruncatedTick;
    }

    function blockAnchorTick() external view returns (int24) {
        return state.blockAnchorTick;
    }

    function lastBlockNumber() external view returns (uint32) {
        return state.lastBlockNumber;
    }

    function headTimestamp() external view returns (uint32) {
        return state.headTimestamp;
    }

    function headCumulative() external view returns (int56) {
        return state.headCumulative;
    }

    function lastCommitTimestamp() external view returns (uint32) {
        return state.lastCommitTimestamp;
    }
}

/// @dev Unit coverage for `TruncatedOracleLib`. Nothing here needs a pool: the library is pure storage mechanics.
contract TruncatedOracleLibTest is Test {
    uint32 internal constant T0 = 1_000_000;

    /// @dev The rate limit under test, hoisted for readability: 115 s at the launch configuration.
    uint32 internal constant STEP = TruncatedOracleLib.MIN_INSERT_INTERVAL;

    TruncatedOracleHarness internal oracle;

    function setUp() public {
        oracle = new TruncatedOracleHarness();
    }

    // ---------------------------------------------------------------------------------------------------------
    // the sizing rule the whole fix rests on
    // ---------------------------------------------------------------------------------------------------------

    /// @notice `MIN_INSERT_INTERVAL` is `ceil(MAX_TWAP_WINDOW / (MAX_CARDINALITY - 1))`, so a full ring spans at
    ///         least the widest window governance can set - which is what bounds coverage below for *every*
    ///         governed `twapWindow`, not merely the launch one.
    function test_theInsertionIntervalCoversTheWidestGovernableWindow() public pure {
        assertEq(uint256(TruncatedOracleLib.MIN_INSERT_INTERVAL), 115, "ceil(7200 / 63)");
        assertGe(
            uint256(TruncatedOracleLib.MIN_INSERT_INTERVAL) * (uint256(TruncatedOracleLib.MAX_CARDINALITY) - 1),
            uint256(TruncatedOracleLib.MAX_TWAP_WINDOW),
            "a full ring spans the widest governable window"
        );
        // And it is the *smallest* interval that does: one second less would leave the widest window uncovered.
        assertLt(
            (uint256(TruncatedOracleLib.MIN_INSERT_INTERVAL) - 1) * (uint256(TruncatedOracleLib.MAX_CARDINALITY) - 1),
            uint256(TruncatedOracleLib.MAX_TWAP_WINDOW),
            "and it is the smallest such interval"
        );
    }

    /// @notice The library's two copies of the window bands cannot drift from `Constants`, which is where the vault
    ///         and the gate read them.
    function test_theWindowConstantsMatchConstants() public pure {
        assertEq(uint256(TruncatedOracleLib.TWAP_WINDOW), uint256(Constants.TWAP_WINDOW_DEFAULT), "canonical window");
        assertEq(uint256(TruncatedOracleLib.MAX_TWAP_WINDOW), uint256(Constants.TWAP_WINDOW_MAX), "widest window");
        assertGe(
            uint256(TruncatedOracleLib.MIN_INSERT_INTERVAL) * (uint256(TruncatedOracleLib.MAX_CARDINALITY) - 1),
            uint256(Constants.TWAP_WINDOW_MAX),
            "every governed window is covered"
        );
    }

    // ---------------------------------------------------------------------------------------------------------
    // initialize
    // ---------------------------------------------------------------------------------------------------------

    function test_initializeSeedsRingAndArmsCap() public {
        oracle.initialize(T0, 500);

        TruncatedOracleLib.Observation memory o = oracle.observationAt(0);
        assertEq(o.blockTimestamp, T0, "timestamp");
        assertEq(o.tickCumulative, 0, "cumulative starts at zero");
        assertEq(o.truncatedTick, int24(500), "seed tick");
        assertTrue(o.initialized, "initialized flag");

        assertEq(oracle.index(), 0, "index");
        assertEq(oracle.cardinality(), 1, "cardinality");
        assertEq(oracle.highWaterTick(), int24(500), "high water seeded");
        assertEq(oracle.lastTruncatedTick(), int24(500), "last truncated seeded");
        assertEq(oracle.blockAnchorTick(), int24(500), "anchor seeded");
        assertEq(oracle.lastBlockNumber(), 0, "block number left at zero so the first write opens a new block");
        assertEq(oracle.headTimestamp(), T0, "head seeded at t0");
        assertEq(oracle.headCumulative(), int56(0), "head accumulator starts at zero");
        assertEq(oracle.lastCommitTimestamp(), T0, "the seed is the first committed slot");
        assertEq(oracle.observationCoverage(T0), 0, "no coverage at t0");
    }

    function test_initializeRevertsWhenAlreadyInitialized() public {
        oracle.initialize(T0, 0);
        vm.expectRevert(TruncatedOracleLib.AlreadyInitialized.selector);
        oracle.initialize(T0 + 1, 0);
    }

    function test_initializeRevertsOnOutOfRangeTick() public {
        vm.expectRevert(abi.encodeWithSelector(TruncatedOracleLib.InvalidTick.selector, TickMath.MAX_TICK + 1));
        oracle.initialize(T0, TickMath.MAX_TICK + 1);

        vm.expectRevert(abi.encodeWithSelector(TruncatedOracleLib.InvalidTick.selector, TickMath.MIN_TICK - 1));
        oracle.initialize(T0, TickMath.MIN_TICK - 1);
    }

    function test_writeRevertsWhenNotInitialized() public {
        vm.expectRevert(TruncatedOracleLib.NotInitialized.selector);
        oracle.write(T0, 1, 0, 100);
    }

    function test_resetHighWaterRevertsWhenNotInitialized() public {
        vm.expectRevert(TruncatedOracleLib.NotInitialized.selector);
        oracle.resetHighWater();
    }

    function test_readsRevertWhenNotInitialized() public {
        vm.expectRevert(TruncatedOracleLib.NotInitialized.selector);
        oracle.consult(T0, 1800);

        vm.expectRevert(TruncatedOracleLib.NotInitialized.selector);
        oracle.oldestObservation();

        vm.expectRevert(TruncatedOracleLib.NotInitialized.selector);
        oracle.newestObservation();

        vm.expectRevert(TruncatedOracleLib.NotInitialized.selector);
        oracle.newestCommittedObservation();

        assertEq(oracle.observationCoverage(T0), 0, "coverage is zero, not a revert");
    }

    function test_writeRevertsOnNonPositiveCap() public {
        oracle.initialize(T0, 0);
        vm.expectRevert(abi.encodeWithSelector(TruncatedOracleLib.InvalidMaxTickMove.selector, int24(0)));
        oracle.write(T0 + 1, 1, 10, 0);

        vm.expectRevert(abi.encodeWithSelector(TruncatedOracleLib.InvalidMaxTickMove.selector, int24(-1)));
        oracle.write(T0 + 1, 1, 10, -1);
    }

    function test_consultRevertsOnZeroWindow() public {
        oracle.initialize(T0, 0);
        vm.expectRevert(TruncatedOracleLib.ZeroWindow.selector);
        oracle.consult(T0, 0);
    }

    // ---------------------------------------------------------------------------------------------------------
    // write: the head, and the rate limit on ring insertion
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A write inside the insertion interval moves the head - and therefore the accumulator, the tick in
    ///         force and the high-water mark - but commits no ring slot.
    function test_aWriteInsideTheIntervalMovesTheHeadAndNotTheRing() public {
        oracle.initialize(T0, 0);

        int24 truncated = oracle.write(T0 + 60, 1, 40, 100);
        assertEq(truncated, int24(40), "inside the cap, recorded verbatim");

        assertEq(oracle.index(), 0, "no slot committed");
        assertEq(oracle.cardinality(), 1, "cardinality unchanged");
        assertEq(oracle.lastCommitTimestamp(), T0, "the last commit is still the seed");
        assertEq(oracle.observationAt(1).blockTimestamp, 0, "slot 1 was never touched");

        // The head carries everything the ring does not.
        assertEq(oracle.headTimestamp(), T0 + 60, "head timestamp");
        // The tick in force over [T0, T0 + 60] was the seed tick 0, so the accumulator is still zero.
        assertEq(oracle.headCumulative(), int56(0), "accumulated with the PREVIOUS tick");
        assertEq(oracle.lastTruncatedTick(), int24(40), "new tick takes effect from here");
        assertEq(oracle.lastBlockNumber(), 1, "block recorded");
        assertEq(oracle.blockAnchorTick(), int24(0), "anchor is the tick the previous block ended on");
        assertEq(oracle.newestObservation().blockTimestamp, T0 + 60, "the head is the newest observation");
        assertEq(oracle.newestCommittedObservation().blockTimestamp, T0, "the newest committed one is the seed");
    }

    /// @notice Once the interval has elapsed the next write snapshots the head into a fresh ring slot.
    function test_aWritePastTheIntervalCommitsASlot() public {
        oracle.initialize(T0, 0);
        oracle.write(T0 + 60, 1, 40, 100); // head only

        oracle.write(T0 + STEP, 2, 90, 100);

        assertEq(oracle.index(), 1, "index advanced");
        assertEq(oracle.cardinality(), 2, "cardinality grew");
        assertEq(oracle.lastCommitTimestamp(), T0 + STEP, "commit clock re-armed");

        TruncatedOracleLib.Observation memory o = oracle.observationAt(1);
        assertEq(o.blockTimestamp, T0 + STEP, "timestamp");
        // 60 s at tick 0 then (STEP - 60) s at tick 40.
        assertEq(o.tickCumulative, int56(int32(40 * (int32(STEP) - 60))), "the committed accumulator is the head's");
        assertEq(o.truncatedTick, int24(90), "and the tick in force at the commit");
        assertTrue(o.initialized, "populated");
        assertEq(o.tickCumulative, oracle.headCumulative(), "a commit is a snapshot of the head");
        assertEq(o.blockTimestamp, oracle.headTimestamp(), "at the same instant");
    }

    /// @notice The accumulator is exact on every write, whatever the cadence: it always advances by the tick that
    ///         really was in force over exactly the elapsed interval.
    function test_theAccumulatorIsExactBetweenCommits() public {
        oracle.initialize(T0, 0);
        oracle.write(T0 + 10, 1, 100, 100_000); // 10 s at tick 0
        assertEq(oracle.headCumulative(), int56(0), "0 x 10");
        oracle.write(T0 + 30, 2, 300, 100_000); // 20 s at tick 100
        assertEq(oracle.headCumulative(), int56(2000), "+ 100 x 20");
        oracle.write(T0 + 60, 3, -200, 100_000); // 30 s at tick 300
        assertEq(oracle.headCumulative(), int56(11_000), "+ 300 x 30");
        oracle.write(T0 + 100, 4, 0, 100_000); // 40 s at tick -200
        assertEq(oracle.headCumulative(), int56(3000), "- 200 x 40");
        assertEq(oracle.cardinality(), 1, "and not one ring slot was spent doing it");
    }

    function test_sameBlockWritesShareOneCapAllowance() public {
        oracle.initialize(T0, 0);

        // Ten swaps, all in block 7, all pushing hard in the same direction. One block, one cap.
        int24 truncated;
        for (uint256 i = 0; i < 10; ++i) {
            truncated = oracle.write(T0 + 1, 7, TickMath.MAX_TICK, 100);
            assertEq(truncated, int24(100), "clamped to the block's single allowance every time");
        }
        assertEq(oracle.lastTruncatedTick(), int24(100), "10 swaps moved the tick by one cap, not ten");
        assertEq(oracle.blockAnchorTick(), int24(0), "anchor untouched inside the block");

        // Same block, now pushing the other way: still measured against the block anchor, so it can reach -100.
        truncated = oracle.write(T0 + 1, 7, TickMath.MIN_TICK, 100);
        assertEq(truncated, int24(-100), "the allowance is a band around the anchor, not a ratchet");

        // Next block re-anchors at where the last one ended.
        truncated = oracle.write(T0 + 2, 8, TickMath.MAX_TICK, 100);
        assertEq(oracle.blockAnchorTick(), int24(-100), "re-anchored");
        assertEq(truncated, int24(0), "-100 + 100");
    }

    function test_sameBlockNewTimestampStillSharesTheAllowance() public {
        // Robinhood Chain: ~100 ms blocks, whole-second timestamps. Several blocks share a timestamp, and (much more
        // rarely, after a stall) a single block can be the first at a new timestamp. Both are handled independently.
        oracle.initialize(T0, 0);
        oracle.write(T0 + 5, 3, 10_000, 100);
        assertEq(oracle.lastTruncatedTick(), int24(100), "block 3 spent its allowance");

        // Two further blocks inside the SAME timestamp: each gets its own allowance, but the head does not move.
        oracle.write(T0 + 5, 4, 10_000, 100);
        assertEq(oracle.lastTruncatedTick(), int24(200), "new block, new allowance");
        oracle.write(T0 + 5, 5, 10_000, 100);
        assertEq(oracle.lastTruncatedTick(), int24(300), "new block, new allowance");

        assertEq(oracle.headTimestamp(), T0 + 5, "the head clock did not move");
        assertEq(oracle.headCumulative(), int56(0), "and neither did the accumulator: zero seconds elapsed");
        assertEq(oracle.cardinality(), 1, "no ring slot was spent");
    }

    function test_capEnforcedInBothDirections() public {
        oracle.initialize(T0, 0);

        int24 up = oracle.write(T0 + 1, 1, TickMath.MAX_TICK, 250);
        assertEq(up, int24(250), "up-move clamped");

        int24 down = oracle.write(T0 + 2, 2, TickMath.MIN_TICK, 250);
        assertEq(down, int24(0), "down-move clamped from 250");

        int24 further = oracle.write(T0 + 3, 3, TickMath.MIN_TICK, 250);
        assertEq(further, int24(-250), "and again");

        // A move inside the cap is recorded verbatim in both directions.
        assertEq(oracle.write(T0 + 4, 4, -300, 250), int24(-300), "inside the band, verbatim");
        assertEq(oracle.write(T0 + 5, 5, -250, 250), int24(-250), "inside the band, verbatim");
    }

    function test_truncatedTickNeverLeavesTheValidTickRange() public {
        // A cap wide enough to jump the whole int24 range in one block must still not record an invalid tick.
        oracle.initialize(T0, 0);
        int24 hugeCap = type(int24).max;

        assertEq(oracle.write(T0 + 1, 1, type(int24).max, hugeCap), TickMath.MAX_TICK, "clamped to MAX_TICK");
        assertEq(oracle.write(T0 + 2, 2, type(int24).min, hugeCap), TickMath.MIN_TICK, "clamped to MIN_TICK");
    }

    function test_ringWrapsAfter64Commits() public {
        oracle.initialize(T0, 0);

        // 70 committed observations: 1 seed + 70 writes an insertion interval apart, so the ring holds the newest 64.
        for (uint32 i = 1; i <= 70; ++i) {
            oracle.write(T0 + i * STEP, i, int24(int32(i)), 1000);
        }

        assertEq(oracle.cardinality(), 64, "cardinality saturates");
        // 70 commits after the seed: the head sits at commit 70 modulo the ring size.
        assertEq(oracle.index(), uint16(70 % 64), "head wrapped");
        assertEq(oracle.newestObservation().blockTimestamp, T0 + 70 * STEP, "newest");
        // 71 observations written, 64 retained: the oldest surviving one is the 8th (index 7 in write order).
        assertEq(oracle.oldestObservation().blockTimestamp, T0 + 7 * STEP, "oldest surviving observation");
        assertEq(oracle.observationCoverage(T0 + 70 * STEP), 63 * STEP, "coverage is newest - oldest");
        assertGe(oracle.observationCoverage(T0 + 70 * STEP), TruncatedOracleLib.MAX_TWAP_WINDOW, "and it covers 2 h");

        // Every retained slot is populated and strictly ordered relative to the head.
        for (uint256 i = 0; i < 64; ++i) {
            assertTrue(oracle.observationAt(i).initialized, "slot populated");
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // coverage under sustained trading - the liveness bug this ring shape exists to fix
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Two hours of trading every single second, and the ring never loses the window. The old shape - one
    ///         slot per distinct second - was down to 63 s of coverage after the first minute.
    function test_perSecondTradingForTwoHoursNeverLosesCoverage() public {
        oracle.initialize(T0, 0);

        uint32 time = T0;
        for (uint32 i = 1; i <= 7200; ++i) {
            time = T0 + i;
            // A tick that keeps moving, so the accumulator is doing real work throughout.
            oracle.write(time, i, int24(int32(i % 400)) - 200, 50);

            uint32 covered = oracle.observationCoverage(time);
            assertEq(covered, i, "coverage is simply the time since initialize: the ring has not wrapped");
            if (covered >= TruncatedOracleLib.TWAP_WINDOW) {
                // The whole point: the 30-minute read answers, every second, under continuous trading.
                oracle.twap30m(time);
            }
        }

        assertGe(oracle.observationCoverage(time), TruncatedOracleLib.TWAP_WINDOW, "still covered after two hours");
        assertLe(oracle.cardinality(), TruncatedOracleLib.MAX_CARDINALITY, "and it used at most one ring");
        assertEq(oracle.cardinality(), uint16(7200 / STEP) + 1, "one slot per insertion interval, plus the seed");
    }

    /// @notice Coverage is monotone non-decreasing while trading continues, and never falls under the widest
    ///         governable window once the ring has wrapped. Driven past the wrap - 64 commits is 7,360 s - so both
    ///         halves of the statement are exercised.
    function test_coverageIsMonotoneUntilTheWrapAndBoundedAfterIt() public {
        oracle.initialize(T0, 0);

        uint32 previous;
        bool wrapped;
        uint32 time = T0;
        // 8,000 seconds: past the first wrap, which is the 64th commit at 64 x 115 = 7,360 s.
        for (uint32 i = 1; i <= 8000; ++i) {
            time = T0 + i;
            oracle.write(time, i, int24(int32(i % 200)) - 100, 50);
            uint32 covered = oracle.observationCoverage(time);

            if (oracle.cardinality() == TruncatedOracleLib.MAX_CARDINALITY && covered < previous) wrapped = true;
            if (!wrapped) assertGe(covered, previous, "coverage never falls before the ring wraps");
            if (i >= TruncatedOracleLib.TWAP_WINDOW) {
                assertGe(covered, TruncatedOracleLib.TWAP_WINDOW, "and never falls under a window once earned");
            }
            previous = covered;
        }

        assertTrue(wrapped, "the ring really did wrap");
        assertGe(
            oracle.observationCoverage(time),
            TruncatedOracleLib.MAX_TWAP_WINDOW,
            "a wrapped ring still spans the widest governable window"
        );
    }

    /// @notice The far end of the window is only ever *interpolated*, never lost: the reported mean tracks the mean
    ///         an unrestricted (one slot per write) ring would have reported, to within the documented bound
    ///         `spread x MIN_INSERT_INTERVAL / window`.
    function test_theTwapTracksTheUnrestrictedTwapWithinTheInterpolationBound() public {
        int24 cap = 5;
        uint32 count = 2600;
        oracle.initialize(T0, 0);

        // Ghost of the exact series: one entry per second, `cum[i]` the accumulator at `T0 + i`.
        int256[] memory cum = new int256[](count + 1);
        int24 live;
        int24 lowest;
        int24 highest;
        for (uint32 i = 1; i <= count; ++i) {
            // A deterministic sawtooth-with-jumps: the raw tick regularly asks for more than the cap allows.
            int24 raw = int24(int256(uint256(keccak256(abi.encode(i))) % 8000)) - 4000;
            cum[i] = cum[i - 1] + int256(live);
            live = oracle.write(T0 + i, i, raw, cap);
            if (live < lowest) lowest = live;
            if (live > highest) highest = live;
        }

        uint32 window = TruncatedOracleLib.TWAP_WINDOW;
        uint32 now_ = T0 + count;
        emit log_named_int("recorded tick spread", int256(highest) - int256(lowest));

        int256 exact = _floorDiv(cum[count] - cum[count - window], int256(uint256(window)));
        int256 reported = int256(oracle.consult(now_, window));

        emit log_named_int("exact TWAP (one slot per write)", exact);
        emit log_named_int("reported TWAP (rate-limited ring)", reported);
        emit log_named_int("interpolation bound", _bound(cap, window));
        assertLe(_abs(reported - exact), _bound(cap, window), "within the documented interpolation bound");

        // And on every shorter window the same bound holds, scaled by that window.
        for (uint32 w = 200; w < window; w += 200) {
            int256 exactW = _floorDiv(cum[count] - cum[count - w], int256(uint256(w)));
            assertLe(_abs(int256(oracle.consult(now_, w)) - exactW), _bound(cap, w), "sub-window inside its bound");
        }
    }

    /// @notice A target that lands exactly on a committed slot, or at or after the head, carries no interpolation
    ///         error at all: those are the two exact paths.
    function test_readingsAtCommittedSlotsAndPastTheHeadAreExact() public {
        oracle.initialize(T0, 0);
        oracle.write(T0 + STEP, 1, 400, 100_000); // commits; 0 for STEP seconds
        oracle.write(T0 + STEP + 30, 2, 900, 100_000); // head only
        oracle.write(T0 + 2 * STEP, 3, 100, 100_000); // commits

        uint32 now_ = T0 + 2 * STEP;
        // Exact accumulator at the second commit: STEP s at 0, 30 s at 400, (STEP - 30) s at 900.
        int56 expected = int56(int32(400 * 30 + 900 * (int32(STEP) - 30)));
        assertEq(oracle.headCumulative(), expected, "head accumulator");
        assertEq(oracle.newestCommittedObservation().tickCumulative, expected, "committed accumulator");

        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = 2 * STEP; // the seed, a committed slot
        secondsAgos[1] = STEP; // the first commit
        secondsAgos[2] = 0; // the head
        int56[] memory cumulatives = oracle.observe(now_, secondsAgos);
        assertEq(cumulatives[0], int56(0), "at the seed");
        assertEq(cumulatives[1], int56(0), "at the first commit: STEP seconds at tick 0");
        assertEq(cumulatives[2], expected, "at the head");

        // Past the head the tick in force extends forward, exactly.
        assertEq(oracle.consult(now_ + 600, 600), int24(100), "flat extrapolation from the head");
    }

    // ---------------------------------------------------------------------------------------------------------
    // storage layout
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Locks in the packing the gas budget depends on: 64 observation slots (one SSTORE each) followed by a
    ///      single packed head slot that the head observation now lives inside, and nothing after it. `state` is the
    ///      harness's only storage variable, so the ring starts at slot 0.
    function test_storageLayoutIsOneSlotPerObservationPlusOneHead() public {
        oracle.initialize(T0, 500);
        oracle.write(T0 + 2 * STEP, 7, 540, 1000);

        // obs[0]: blockTimestamp | tickCumulative | truncatedTick | initialized, low bits first.
        uint256 slot0 = uint256(vm.load(address(oracle), bytes32(uint256(0))));
        assertEq(uint32(slot0), T0, "obs[0].blockTimestamp at bit 0");
        assertEq(int56(uint56(slot0 >> 32)), int56(0), "obs[0].tickCumulative at bit 32");
        assertEq(int24(uint24(slot0 >> 88)), int24(500), "obs[0].truncatedTick at bit 88");
        assertEq(uint8(slot0 >> 112), 1, "obs[0].initialized at bit 112");
        assertEq(slot0 >> 120, 0, "obs[0] uses 120 bits of one slot");

        // obs[1] is the next slot, so a committed observation costs exactly one SSTORE.
        uint256 slot1 = uint256(vm.load(address(oracle), bytes32(uint256(1))));
        assertEq(uint32(slot1), T0 + 2 * STEP, "obs[1].blockTimestamp");
        assertEq(int56(uint56(slot1 >> 32)), int56(int32(500 * 2 * int32(STEP))), "obs[1].tickCumulative");
        assertEq(int24(uint24(slot1 >> 88)), int24(540), "obs[1].truncatedTick");

        // The head is one slot immediately after the 64-entry ring, and it is exactly full: the accumulator, the
        // head clock and the commit clock all fit beside the scalars, so the fix costs zero extra words.
        uint256 head = uint256(vm.load(address(oracle), bytes32(uint256(64))));
        assertEq(uint16(head), 1, "index at bit 0");
        assertEq(uint16(head >> 16), 2, "cardinality at bit 16");
        assertEq(int24(uint24(head >> 32)), int24(540), "highWaterTick at bit 32");
        assertEq(int24(uint24(head >> 56)), int24(540), "lastTruncatedTick at bit 56");
        assertEq(int24(uint24(head >> 80)), int24(500), "blockAnchorTick at bit 80");
        assertEq(uint32(head >> 104), 7, "lastBlockNumber at bit 104");
        assertEq(uint32(head >> 136), T0 + 2 * STEP, "headTimestamp at bit 136");
        assertEq(int56(uint56(head >> 168)), int56(int32(500 * 2 * int32(STEP))), "headCumulative at bit 168");
        assertEq(uint32(head >> 224), T0 + 2 * STEP, "lastCommitTimestamp at bit 224");

        assertEq(uint256(vm.load(address(oracle), bytes32(uint256(65)))), 0, "nothing lives past the head");

        // A write that does not commit moves only the head half of that slot.
        oracle.write(T0 + 2 * STEP + 30, 8, 560, 1000);
        head = uint256(vm.load(address(oracle), bytes32(uint256(64))));
        assertEq(uint16(head), 1, "index unchanged");
        assertEq(uint32(head >> 136), T0 + 2 * STEP + 30, "headTimestamp moved");
        assertEq(uint32(head >> 224), T0 + 2 * STEP, "lastCommitTimestamp did not");
    }

    // ---------------------------------------------------------------------------------------------------------
    // consult
    // ---------------------------------------------------------------------------------------------------------

    function test_consultExactOnHandBuiltSequence() public {
        // tick 0 for 900 s, then tick 1000 for 900 s. The 30-minute mean must be exactly 500.
        oracle.initialize(T0, 0);
        oracle.write(T0 + 900, 1, 1000, 100_000);

        uint32 now_ = T0 + 1800;
        assertEq(oracle.consult(now_, 1800), int24(500), "30-minute mean");
        assertEq(oracle.twap30m(now_), int24(500), "twap30m convenience");
        assertEq(oracle.consult(now_, 900), int24(1000), "second half only");
        assertEq(oracle.consult(now_, 1), int24(1000), "one-second window");
    }

    function test_consultInterpolatesInsideAnObservationInterval() public {
        oracle.initialize(T0, 0);
        oracle.write(T0 + 900, 1, 1000, 100_000);
        uint32 now_ = T0 + 1800;

        // A window whose far end (T0 + 450) falls strictly between two observations: 450 s at tick 0, 900 s at 1000.
        // Mean = 900000 / 1350 = 666.66..., floored to 666.
        assertEq(oracle.consult(now_, 1350), int24(666), "positive mean floors toward zero");

        // Exactly divisible: 600 s at 0 and 900 s at 1000 -> 900000 / 1500 = 600.
        assertEq(oracle.consult(now_, 1500), int24(600), "exact division");
    }

    function test_consultRoundsTowardNegativeInfinity() public {
        oracle.initialize(T0, 0);
        oracle.write(T0 + 900, 1, -1000, 100_000);
        uint32 now_ = T0 + 1800;

        // Mirror of the case above: -900000 / 1350 = -666.66..., floored to -667 (Solidity would truncate to -666).
        assertEq(oracle.consult(now_, 1350), int24(-667), "negative mean floors away from zero");
        assertEq(oracle.consult(now_, 1500), int24(-600), "exact division needs no adjustment");
        assertEq(oracle.consult(now_, 1800), int24(-500), "exact division needs no adjustment");
    }

    function test_consultExtrapolatesPastTheNewestObservation() public {
        oracle.initialize(T0, 0);
        oracle.write(T0 + 900, 1, 600, 100_000);

        // No swap for another hour: the tick in force is still 600, and the mean over the last 30 minutes is 600.
        assertEq(oracle.consult(T0 + 4500, 1800), int24(600), "flat extrapolation from the head observation");
    }

    function test_consultAcrossAWrappedRing() public {
        oracle.initialize(T0, 100);
        // 200 commits at a constant tick: the ring wraps three times, the mean stays 100.
        for (uint32 i = 1; i <= 200; ++i) {
            oracle.write(T0 + i * STEP, i, 100, 1000);
        }
        uint32 now_ = T0 + 200 * STEP;
        assertEq(oracle.cardinality(), 64, "the ring is full");
        assertEq(oracle.consult(now_, 63 * STEP), int24(100), "full ring window");
        assertEq(oracle.consult(now_, TruncatedOracleLib.TWAP_WINDOW), int24(100), "the canonical window");
        assertEq(oracle.consult(now_, 1), int24(100), "one second");
    }

    function test_consultAcrossTheUint32TimestampWrap() public {
        // The ring stores `uint32` timestamps, which run out in 2106. Uniswap v3 solved this by comparing timestamps
        // on the mod-2**32 circle rather than as plain integers; this library does the same, and this is the case
        // that exercises it. The writes are an insertion interval apart so a slot is committed on either side.
        uint32 preWrap;
        unchecked {
            preWrap = type(uint32).max - (2 * STEP) + 60; // the wrap lands inside the second interval
        }

        oracle.initialize(preWrap, 0);
        oracle.write(preWrap + STEP, 2, 1000, 100_000); // still before the wrap
        uint32 postWrap;
        unchecked {
            postWrap = preWrap + 2 * STEP; // after it
        }
        assertLt(postWrap, preWrap, "the clock wrapped");
        oracle.write(postWrap, 3, 2000, 100_000);

        assertEq(oracle.cardinality(), 3, "both writes committed");
        assertEq(oracle.observationCoverage(postWrap), 2 * STEP, "coverage spans the wrap");

        // STEP s at tick 0 then STEP s at tick 1000 = 500 on average; the second half alone is 1000.
        assertEq(oracle.consult(postWrap, 2 * STEP), int24(500), "mean across the wrap");
        assertEq(oracle.consult(postWrap, STEP), int24(1000), "window entirely inside the second leg");

        vm.expectRevert(abi.encodeWithSelector(TruncatedOracleLib.WindowNotCovered.selector, 2 * STEP + 1, 2 * STEP));
        oracle.consult(postWrap, 2 * STEP + 1);
    }

    // ---------------------------------------------------------------------------------------------------------
    // coverage
    // ---------------------------------------------------------------------------------------------------------

    function test_observationCoverageAndWindowNotCovered() public {
        oracle.initialize(T0, 0);
        oracle.write(T0 + 900, 1, 1000, 100_000);
        uint32 now_ = T0 + 1800;

        assertEq(oracle.observationCoverage(now_), 1800, "reaches back to the seed observation");

        // Exactly at the edge is fine; one second beyond is not.
        oracle.consult(now_, 1800);
        vm.expectRevert(
            abi.encodeWithSelector(TruncatedOracleLib.WindowNotCovered.selector, uint32(1801), uint32(1800))
        );
        oracle.consult(now_, 1801);

        // Seventy writes one second apart - the sequence that used to collapse coverage to 63 s - now spend at most
        // one ring slot between them, so coverage only grows.
        for (uint32 i = 1; i <= 70; ++i) {
            oracle.write(now_ + i, 100 + i, 1000, 100_000);
        }
        uint32 later = now_ + 70;
        assertEq(oracle.observationCoverage(later), 1870, "coverage grew with the clock");
        // And the 30-minute read answers instead of reverting. Its window `[T0 + 70, T0 + 1870]` is 830 s at tick 0
        // followed by 970 s at tick 1000, so the mean is `floor(970000 / 1800) = 538`.
        assertEq(oracle.twap30m(later), int24(538), "the 30-minute read answers");
        assertEq(oracle.consult(later, 70), int24(1000), "and a window inside the second leg is the flat tick");
    }

    function test_observationCoverageIsZeroBeforeInitialize() public view {
        assertEq(oracle.observationCoverage(T0), 0, "no observations");
    }

    // ---------------------------------------------------------------------------------------------------------
    // observe
    // ---------------------------------------------------------------------------------------------------------

    function test_observeMatchesConsult() public {
        oracle.initialize(T0, 0);
        oracle.write(T0 + 900, 1, 1000, 100_000);
        uint32 now_ = T0 + 1800;

        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = 1800;
        secondsAgos[1] = 900;
        secondsAgos[2] = 0;

        int56[] memory cumulatives = oracle.observe(now_, secondsAgos);
        assertEq(cumulatives[0], int56(0), "cumulative at T0");
        assertEq(cumulatives[1], int56(0), "cumulative at T0 + 900 (tick was 0 throughout)");
        assertEq(cumulatives[2], int56(900_000), "cumulative now");

        assertEq(int24((cumulatives[2] - cumulatives[0]) / int56(1800)), oracle.consult(now_, 1800), "agrees");
        assertEq(int24((cumulatives[2] - cumulatives[1]) / int56(900)), oracle.consult(now_, 900), "agrees");
    }

    function test_observeRevertsBeyondCoverage() public {
        oracle.initialize(T0, 0);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(TruncatedOracleLib.WindowNotCovered.selector, uint32(1), uint32(0)));
        oracle.observe(T0, secondsAgos);
    }

    // ---------------------------------------------------------------------------------------------------------
    // high water
    // ---------------------------------------------------------------------------------------------------------

    function test_highWaterTracksMaximumAndResetsToTheLiveTick() public {
        oracle.initialize(T0, 0);
        assertEq(oracle.highWaterTick(), int24(0), "seeded at the initial tick");

        oracle.write(T0 + 1, 1, 500, 5000);
        assertEq(oracle.highWaterTick(), int24(500), "raised");

        oracle.write(T0 + 2, 2, 300, 5000);
        assertEq(oracle.highWaterTick(), int24(500), "a lower tick does not lower the mark");

        oracle.write(T0 + 3, 3, 900, 5000);
        assertEq(oracle.highWaterTick(), int24(900), "raised again");

        oracle.write(T0 + 4, 4, -200, 5000);
        assertEq(oracle.highWaterTick(), int24(900), "still the excursion peak");

        // The vault resets after compounding: the mark drops to wherever the pool actually is.
        oracle.resetHighWater();
        assertEq(oracle.highWaterTick(), int24(-200), "reset to the live truncated tick");
        assertEq(oracle.lastTruncatedTick(), int24(-200), "reset does not disturb the series");

        // ...and starts tracking a fresh excursion from there.
        oracle.write(T0 + 5, 5, -150, 5000);
        assertEq(oracle.highWaterTick(), int24(-150), "new excursion");
    }

    function test_highWaterOnlyEverSeesTruncatedTicks() public {
        // The high-water mark drives the buyback burn, so it must be as manipulation-resistant as the TWAP: a single
        // block cannot spike it. It is charged on every write, rate limit or no rate limit.
        oracle.initialize(T0, 0);
        oracle.write(T0 + 1, 1, TickMath.MAX_TICK, 100);
        assertEq(oracle.highWaterTick(), int24(100), "one block, one cap");
        assertEq(oracle.cardinality(), 1, "with no ring slot spent");
    }

    // ---------------------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------------------

    /// @dev The library's documented interpolation bound, `maxTickMovePerBlock * B * D / window`, with one block per
    ///      second so both `B` (blocks inside the committed interval the far end lands in) and `D` (that interval's
    ///      length) are `MIN_INSERT_INTERVAL`. The `+ 2` is the two roundings: `_interpolate` ceils the subtrahend
    ///      (at most 1 / window) and `consult` floors the quotient (less than 1).
    function _bound(int24 cap, uint32 window) private pure returns (int256) {
        int256 step = int256(uint256(TruncatedOracleLib.MIN_INSERT_INTERVAL));
        return int256(cap) * step * step / int256(uint256(window)) + 2;
    }

    function _floorDiv(int256 numerator, int256 denominator) private pure returns (int256 quotient) {
        quotient = numerator / denominator;
        if (numerator < 0 && quotient * denominator != numerator) --quotient;
    }

    function _abs(int256 x) private pure returns (int256) {
        return x < 0 ? -x : x;
    }
}

/// @dev Gas measurement lives in its own contract so that the ring is populated by `setUp`, which Foundry commits
///      before the test body runs. That matters: EIP-2200 charges only 100 gas for an SSTORE to a slot already
///      dirtied *in the same transaction*, so measuring right after an in-test warm-up would flatter the result by
///      ~2800 gas per slot. With the writes done in `setUp` the measured call pays the real SSTORE_RESET price, and
///      `vm.cool` restores the cold-access charge on top.
contract TruncatedOracleLibGasTest is Test {
    /// @dev Budget for the common write: the one that advances the head and commits nothing. The library mutates
    ///      exactly one slot - the packed head, which carries the accumulator - and reads no other, which is the
    ///      whole point of keeping the accumulator out of the ring. A regression that touched the ring on every
    ///      write would add at least COLD_SLOAD + SSTORE_RESET (5,000) and blow this budget.
    uint256 internal constant HEAD_WRITE_GAS_BUDGET = (2100 + 2900) // the head slot: cold access + SSTORE_RESET
        + 5 * 100 // its further packed field writes, at the EIP-2200 dirty-slot price
        + 5 * 100 // and the warm re-reads of the same slot
        + 2000; // truncation arithmetic, struct packing and headroom

    /// @dev Budget for a write that also commits a ring slot, at most one per `MIN_INSERT_INTERVAL` seconds: one
    ///      more slot, cold, plus the ring index maths.
    uint256 internal constant COMMIT_WRITE_GAS_BUDGET = HEAD_WRITE_GAS_BUDGET + 2100 // the ring slot: cold access
        + 2900 // SSTORE_RESET on it
        + 3 * 100 // the observation's three further packed fields
        + 3 * 100 // and `index` / `cardinality` / `lastCommitTimestamp` on the already-dirty head slot
        + 1500; // ring index maths, struct packing and headroom

    /// @dev First pass through a fresh ring writes a zero observation slot: SSTORE_SET (20000) instead of 2900.
    uint256 internal constant COLD_COMMIT_WRITE_GAS_BUDGET = COMMIT_WRITE_GAS_BUDGET + (20_000 - 2900);

    uint32 internal constant T0 = 1_000_000;
    uint32 internal constant STEP = TruncatedOracleLib.MIN_INSERT_INTERVAL;

    TruncatedOracleHarness internal populated;
    TruncatedOracleHarness internal fresh;

    function setUp() public {
        populated = new TruncatedOracleHarness();
        populated.initialize(T0, 0);
        // Fill the ring so a measured commit overwrites an already non-zero slot: the on-chain steady state.
        for (uint32 i = 1; i <= 70; ++i) {
            populated.write(T0 + i * STEP, i, int24(int32(i)), 1000);
        }

        fresh = new TruncatedOracleHarness();
        fresh.initialize(T0, 0);
    }

    function test_headWriteGasIsOneStoresWorth() public {
        // `forge coverage` compiles with the optimizer off and inserts an instrumentation opcode per statement, so
        // the numbers there measure the instrumented build, not the deployed one. Keep the walk (for coverage) and
        // drop only the assertions.
        bool measuring = !vm.isContext(VmSafe.ForgeContext.Coverage);

        // Cold slots, exactly as an `afterSwap` that has not otherwise read the oracle would find them.
        vm.cool(address(populated));
        (, uint256 headGas) = populated.writeMeasured(T0 + 70 * STEP + 1, 1000, 80, 1000);
        emit log_named_uint("write gas (new block, head only, ring populated)", headGas);
        emit log_named_uint("head write gas budget", HEAD_WRITE_GAS_BUDGET);
        if (measuring) {
            assertLe(headGas, HEAD_WRITE_GAS_BUDGET, "a non-committing write must stay within one SSTORE's worth");
        }
    }

    function test_commitWriteGasIsTwoStoresWorth() public {
        bool measuring = !vm.isContext(VmSafe.ForgeContext.Coverage);

        vm.cool(address(populated));
        (, uint256 commitGas) = populated.writeMeasured(T0 + 71 * STEP, 1000, 80, 1000);
        emit log_named_uint("write gas (new block, commits a slot, ring populated)", commitGas);
        emit log_named_uint("commit write gas budget", COMMIT_WRITE_GAS_BUDGET);
        if (measuring) {
            assertLe(commitGas, COMMIT_WRITE_GAS_BUDGET, "a committing write must stay within two SSTOREs' worth");
        }

        vm.cool(address(fresh));
        (, uint256 coldSlotGas) = fresh.writeMeasured(T0 + STEP, 1, 80, 1000);
        emit log_named_uint("write gas (first pass, zero observation slot)", coldSlotGas);
        emit log_named_uint("write gas budget (first pass)", COLD_COMMIT_WRITE_GAS_BUDGET);
        if (measuring) {
            assertLe(coldSlotGas, COLD_COMMIT_WRITE_GAS_BUDGET, "first-pass write must stay within two SSTORE_SETs");
        }
    }

    function test_sameTimestampWriteGasIsCheaper() public {
        vm.cool(address(populated));
        (, uint256 sameTimestampGas) = populated.writeMeasured(T0 + 70 * STEP, 1000, 90, 1000);
        emit log_named_uint("write gas (new block, same timestamp, no accumulator move)", sameTimestampGas);
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) {
            assertLe(sameTimestampGas, HEAD_WRITE_GAS_BUDGET, "an in-place write is cheaper still");
        }
    }

    function test_consultGas() public {
        vm.cool(address(populated));
        vm.startSnapshotGas("TruncatedOracleLib", "consult");
        populated.consult(T0 + 70 * STEP, TruncatedOracleLib.TWAP_WINDOW);
        uint256 gasUsed = vm.stopSnapshotGas();
        emit log_named_uint("consult gas over a full 64-observation ring (incl. external call, cold)", gasUsed);
    }
}
