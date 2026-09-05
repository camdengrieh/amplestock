// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TruncatedOracleLib} from "../../src/lib/TruncatedOracleLib.sol";
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
}

/// @dev Unit coverage for `TruncatedOracleLib`. Nothing here needs a pool: the library is pure storage mechanics.
contract TruncatedOracleLibTest is Test {
    /// @dev Gas budget for one `write` that opens a new observation, derived from the EVM constants rather than
    ///      guessed: two cold slots (2 * COLD_SLOAD 2100), the observation slot overwritten (SSTORE_RESET 2900) plus
    ///      three further packed field writes at the dirty-slot price (3 * 100), the head slot likewise
    ///      (2900 + 3 * 100), and 1500 of arithmetic/branching around them. That is 2 SSTOREs' worth of state change
    ///      by construction - the library never touches a third slot.
    uint256 internal constant WRITE_GAS_BUDGET = 2100 + 2100 + (2900 + 300) + (2900 + 300) + 1500;

    /// @dev First-ever pass through the ring writes a zero slot, which costs SSTORE_SET (20000) instead of 2900.
    uint256 internal constant COLD_WRITE_GAS_BUDGET = WRITE_GAS_BUDGET + 2 * (20_000 - 2900);

    uint32 internal constant T0 = 1_000_000;

    TruncatedOracleHarness internal oracle;

    function setUp() public {
        oracle = new TruncatedOracleHarness();
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
    // write
    // ---------------------------------------------------------------------------------------------------------

    function test_firstWriteOpensSecondObservation() public {
        oracle.initialize(T0, 0);

        int24 truncated = oracle.write(T0 + 60, 1, 40, 100);
        assertEq(truncated, int24(40), "inside the cap, recorded verbatim");

        TruncatedOracleLib.Observation memory o = oracle.observationAt(1);
        assertEq(o.blockTimestamp, T0 + 60, "timestamp");
        // The tick in force over [T0, T0 + 60] was the seed tick 0, so the accumulator is still zero.
        assertEq(o.tickCumulative, 0, "accumulated with the PREVIOUS tick");
        assertEq(o.truncatedTick, int24(40), "new tick takes effect from here");
        assertEq(oracle.index(), 1, "index advanced");
        assertEq(oracle.cardinality(), 2, "cardinality grew");
        assertEq(oracle.lastBlockNumber(), 1, "block recorded");
        assertEq(oracle.blockAnchorTick(), int24(0), "anchor is the tick the previous block ended on");
    }

    function test_accumulatorUsesThePreviousTickOverTheElapsedInterval() public {
        oracle.initialize(T0, 0);
        oracle.write(T0 + 60, 1, 40, 100);
        oracle.write(T0 + 120, 2, 90, 100);

        // Over [T0 + 60, T0 + 120] the tick in force was 40.
        assertEq(oracle.observationAt(2).tickCumulative, int56(40 * 60), "cumulative");
        assertEq(oracle.observationAt(2).truncatedTick, int24(90), "tick");
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

        // Two further blocks inside the SAME timestamp: each gets its own allowance, but no new observation.
        oracle.write(T0 + 5, 4, 10_000, 100);
        assertEq(oracle.lastTruncatedTick(), int24(200), "new block, new allowance");
        oracle.write(T0 + 5, 5, 10_000, 100);
        assertEq(oracle.lastTruncatedTick(), int24(300), "new block, new allowance");

        assertEq(oracle.cardinality(), 2, "same timestamp: the head observation was updated in place");
        assertEq(oracle.observationAt(1).truncatedTick, int24(300), "in-place update carries the newest tick");
        assertEq(oracle.observationAt(1).blockTimestamp, T0 + 5, "timestamp unchanged");
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

    function test_ringWrapsAfter64Observations() public {
        oracle.initialize(T0, 0);

        // 70 observations at distinct timestamps: 1 seed + 70 writes, so the ring holds the newest 64.
        for (uint32 i = 1; i <= 70; ++i) {
            oracle.write(T0 + i, i, int24(int32(i)), 1000);
        }

        assertEq(oracle.cardinality(), 64, "cardinality saturates");
        // 70 writes after the seed: the head sits at write 70 modulo the ring size.
        assertEq(oracle.index(), uint16(70 % 64), "head wrapped");
        assertEq(oracle.newestObservation().blockTimestamp, T0 + 70, "newest");
        // 71 observations written, 64 retained: the oldest surviving one is the 8th (index 7 in write order).
        assertEq(oracle.oldestObservation().blockTimestamp, T0 + 7, "oldest surviving observation");
        assertEq(oracle.observationCoverage(T0 + 70), 63, "coverage is newest - oldest");

        // Every retained slot is populated and strictly ordered relative to the head.
        for (uint256 i = 0; i < 64; ++i) {
            assertTrue(oracle.observationAt(i).initialized, "slot populated");
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // storage layout
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Locks in the packing the gas budget depends on: 64 observation slots (one SSTORE each) followed by a
    ///      single packed head slot, and nothing after it. `state` is the harness's only storage variable, so the
    ///      ring starts at slot 0.
    function test_storageLayoutIsOneSlotPerObservationPlusOneHead() public {
        oracle.initialize(T0, 500);
        oracle.write(T0 + 60, 7, 540, 1000);

        // obs[0]: blockTimestamp | tickCumulative | truncatedTick | initialized, low bits first.
        uint256 slot0 = uint256(vm.load(address(oracle), bytes32(uint256(0))));
        assertEq(uint32(slot0), T0, "obs[0].blockTimestamp at bit 0");
        assertEq(int56(uint56(slot0 >> 32)), int56(0), "obs[0].tickCumulative at bit 32");
        assertEq(int24(uint24(slot0 >> 88)), int24(500), "obs[0].truncatedTick at bit 88");
        assertEq(uint8(slot0 >> 112), 1, "obs[0].initialized at bit 112");
        assertEq(slot0 >> 120, 0, "obs[0] uses 120 bits of one slot");

        // obs[1] is the next slot, so an observation costs exactly one SSTORE.
        uint256 slot1 = uint256(vm.load(address(oracle), bytes32(uint256(1))));
        assertEq(uint32(slot1), T0 + 60, "obs[1].blockTimestamp");
        assertEq(int56(uint56(slot1 >> 32)), int56(500 * 60), "obs[1].tickCumulative");
        assertEq(int24(uint24(slot1 >> 88)), int24(540), "obs[1].truncatedTick");

        // The head is one slot immediately after the 64-entry ring, and everything in it fits.
        uint256 head = uint256(vm.load(address(oracle), bytes32(uint256(64))));
        assertEq(uint16(head), 1, "index at bit 0");
        assertEq(uint16(head >> 16), 2, "cardinality at bit 16");
        assertEq(int24(uint24(head >> 32)), int24(540), "highWaterTick at bit 32");
        assertEq(int24(uint24(head >> 56)), int24(540), "lastTruncatedTick at bit 56");
        assertEq(int24(uint24(head >> 80)), int24(500), "blockAnchorTick at bit 80");
        assertEq(uint32(head >> 104), 7, "lastBlockNumber at bit 104");
        assertEq(head >> 136, 0, "the head uses 136 bits of one slot");

        assertEq(uint256(vm.load(address(oracle), bytes32(uint256(65)))), 0, "nothing lives past the head");
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
        // 200 observations one second apart at a constant tick: the ring wraps three times, the mean stays 100.
        for (uint32 i = 1; i <= 200; ++i) {
            oracle.write(T0 + i, i, 100, 1000);
        }
        assertEq(oracle.consult(T0 + 200, 63), int24(100), "full ring window");
        assertEq(oracle.consult(T0 + 200, 1), int24(100), "one second");
    }

    function test_consultAcrossTheUint32TimestampWrap() public {
        // The ring stores `uint32` timestamps, which run out in 2106. Uniswap v3 solved this by comparing timestamps
        // on the mod-2**32 circle rather than as plain integers; this library does the same, and this is the case
        // that exercises it.
        uint32 preWrap = type(uint32).max - 59; // 60 seconds before the wrap

        oracle.initialize(preWrap, 0);
        oracle.write(preWrap + 30, 2, 1000, 100_000); // still 30 seconds before the wrap
        uint32 postWrap;
        unchecked {
            postWrap = preWrap + 90; // 30 seconds after it
        }
        assertLt(postWrap, preWrap, "the clock wrapped");
        oracle.write(postWrap, 3, 2000, 100_000);

        assertEq(oracle.observationCoverage(postWrap), 90, "coverage spans the wrap");

        // 30 s at tick 0 then 60 s at tick 1000 = 60000 tick-seconds over 90 s = 666.66..., floored to 666.
        assertEq(oracle.consult(postWrap, 90), int24(666), "mean across the wrap");
        assertEq(oracle.consult(postWrap, 60), int24(1000), "window entirely inside the second leg");

        vm.expectRevert(abi.encodeWithSelector(TruncatedOracleLib.WindowNotCovered.selector, uint32(91), uint32(90)));
        oracle.consult(postWrap, 91);
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

        // After the ring has wrapped, coverage shrinks to what the ring still holds and the error reports it.
        for (uint32 i = 1; i <= 70; ++i) {
            oracle.write(now_ + i, 100 + i, 1000, 100_000);
        }
        uint32 later = now_ + 70;
        uint32 covered = oracle.observationCoverage(later);
        assertEq(covered, 63, "63 seconds of ring left");
        vm.expectRevert(
            abi.encodeWithSelector(TruncatedOracleLib.WindowNotCovered.selector, uint32(1800), uint32(covered))
        );
        oracle.twap30m(later);
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
        // block cannot spike it.
        oracle.initialize(T0, 0);
        oracle.write(T0 + 1, 1, TickMath.MAX_TICK, 100);
        assertEq(oracle.highWaterTick(), int24(100), "one block, one cap");
    }
}

/// @dev Gas measurement lives in its own contract so that the ring is populated by `setUp`, which Foundry commits
///      before the test body runs. That matters: EIP-2200 charges only 100 gas for an SSTORE to a slot already
///      dirtied *in the same transaction*, so measuring right after an in-test warm-up would flatter the result by
///      ~2800 gas per slot. With the writes done in `setUp` the measured call pays the real SSTORE_RESET price, and
///      `vm.cool` restores the cold-access charge on top.
contract TruncatedOracleLibGasTest is Test {
    /// @dev Budget for one `write` that opens a new observation, derived from EVM constants rather than guessed.
    ///      The library mutates exactly two slots - the new observation and the packed head - and reads exactly one
    ///      more, the head observation it accumulates from. A regression that touched a third slot would add at
    ///      least COLD_SLOAD (2100) and blow the budget.
    uint256 internal constant WRITE_GAS_BUDGET = 2 * (2100 + 2900) // the two mutated slots: cold access + SSTORE_RESET
        + 7 * 100 // their further packed field writes, at the EIP-2200 dirty-slot price
        + 2100 // the one extra slot it only reads (the head observation): COLD_SLOAD
        + 2200 // truncation arithmetic, ring index maths, struct packing
        + 1000; // headroom

    /// @dev First pass through a fresh ring writes a zero observation slot: SSTORE_SET (20000) instead of 2900.
    uint256 internal constant COLD_WRITE_GAS_BUDGET = WRITE_GAS_BUDGET + (20_000 - 2900);

    uint32 internal constant T0 = 1_000_000;

    TruncatedOracleHarness internal populated;
    TruncatedOracleHarness internal fresh;

    function setUp() public {
        populated = new TruncatedOracleHarness();
        populated.initialize(T0, 0);
        // Fill the ring so the measured write overwrites an already non-zero slot: the on-chain steady state.
        for (uint32 i = 1; i <= 70; ++i) {
            populated.write(T0 + i, i, int24(int32(i)), 1000);
        }

        fresh = new TruncatedOracleHarness();
        fresh.initialize(T0, 0);
    }

    function test_writeGasIsTwoStoresWorth() public {
        // `forge coverage` compiles with the optimizer off and inserts an instrumentation opcode per statement, so
        // the numbers there measure the instrumented build, not the deployed one. Keep the walk (for coverage) and
        // drop only the assertions.
        bool measuring = !vm.isContext(VmSafe.ForgeContext.Coverage);

        // Cold slots, exactly as an `afterSwap` that has not otherwise read the oracle would find them.
        vm.cool(address(populated));
        (, uint256 newObservationGas) = populated.writeMeasured(T0 + 71, 71, 80, 1000);
        emit log_named_uint("write gas (new block, new observation, ring populated)", newObservationGas);
        emit log_named_uint("write gas budget", WRITE_GAS_BUDGET);
        if (measuring) {
            assertLe(newObservationGas, WRITE_GAS_BUDGET, "steady-state write must stay within two SSTOREs' worth");
        }

        vm.cool(address(fresh));
        (, uint256 coldSlotGas) = fresh.writeMeasured(T0 + 1, 1, 80, 1000);
        emit log_named_uint("write gas (first pass, zero observation slot)", coldSlotGas);
        emit log_named_uint("write gas budget (first pass)", COLD_WRITE_GAS_BUDGET);
        if (measuring) {
            assertLe(coldSlotGas, COLD_WRITE_GAS_BUDGET, "first-pass write must stay within two SSTORE_SETs' worth");
        }
    }

    function test_sameTimestampWriteGasIsCheaper() public {
        vm.cool(address(populated));
        (, uint256 sameTimestampGas) = populated.writeMeasured(T0 + 70, 71, 90, 1000);
        emit log_named_uint("write gas (new block, same timestamp, in-place)", sameTimestampGas);
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) {
            assertLe(sameTimestampGas, WRITE_GAS_BUDGET, "in-place write is cheaper still");
        }
    }

    function test_consultGas() public {
        vm.cool(address(populated));
        vm.startSnapshotGas("TruncatedOracleLib", "consult");
        populated.consult(T0 + 70, 63);
        uint256 gasUsed = vm.stopSnapshotGas();
        emit log_named_uint("consult gas over a full 64-observation ring (incl. external call, cold)", gasUsed);
    }
}
