// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsQuoter} from "../../src/interfaces/IAmpsQuoter.sol";
import {IOracleGate} from "../../src/interfaces/IOracleGate.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {TruncatedOracleLib} from "../../src/lib/TruncatedOracleLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {GateSnapshot, GateState, PoolClass, Session} from "../../src/types/Types.sol";
import {Phase3Fixture} from "./Phase3Fixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

/// @title HubPumpTest
/// @notice `docs/phase3-state-model.md` §8.1's row for `integration/HubPump.t.sol` and the plan's last Phase 3
///         exit clause: a hub pump of +30% in ten minutes, followed by every spoke inside one TWAP window through
///         arbitrage against their own ladders, while `P_ref` — which is a NAV valuation, not a market price —
///         climbs no faster than `refUpRateBps`.
///
/// @dev **How the spokes follow, mechanically.** A spoke's `fairTick` is not its own TWAP: it is
///      `tickOf(P_mkt / P_stock)` with `P_mkt` the **hub's** truncated 30-minute TWAP (§1.5 step 6). So the hub
///      leads and the spokes' reference follows it as the hub's TWAP absorbs the pump. Once it has, a spoke buy is
///      *deviation-decreasing* — it walks the spoke toward its own reference — and the outer rail never refuses a
///      price-improving swap, which is exactly why the follow-on arbitrage is cheap and the pump is not.
contract HubPumpTest is Phase3Fixture {
    /// @dev +30% in ticks: `ln(1.30) / ln(1.0001)` = 2,623.6, rounded up.
    int24 internal constant PUMP_TICKS = 2624;

    /// @dev The plan's window for the pump itself.
    uint256 internal constant PUMP_SECONDS = 600;

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(100_000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The pump, and the spokes following it
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The whole exit clause in one scenario.
    function test_hubPumpIsFollowedByEverySpokeWithinOneTwapWindow() public {
        int24 hubStart = tickOf(hubPool);
        uint256 startedAt = vm.getBlockTimestamp();
        uint256 pRefStart = vault.pRefX18();

        int24[] memory spokeStart = new int24[](spokePools.length);
        for (uint256 i; i < spokePools.length; ++i) {
            spokeStart[i] = tickOf(spokePools[i]);
        }

        // --- the pump: ten minutes, +30%, one rail-limited step at a time -----------------------------------
        (, uint256 steps) = climb(hubPool, BOB, 1e6, hubStart + PUMP_TICKS, 200, 3);
        uint256 pumpElapsed = vm.getBlockTimestamp() - startedAt;
        assertLt(steps, 200, "the pump reached +30% rather than running out of steps");
        assertLe(pumpElapsed, PUMP_SECONDS, "and it did so inside ten minutes");
        assertGe(tickOf(hubPool) - hubStart, PUMP_TICKS, "the hub is up at least 30%");
        console.log("hub pump ticks", vm.toString(tickOf(hubPool) - hubStart), "in seconds", pumpElapsed);

        // --- P_ref lags, by construction and by rate limit ---------------------------------------------------
        vault.checkpoint();
        uint256 pRefAfterPump = vault.pRefX18();
        uint256 allowance = pRefStart + pRefStart * uint256(vault.refUpRateBps()) * pumpElapsed
            / (Constants.BPS * Constants.REF_UP_RATE_PERIOD);
        assertLe(pRefAfterPump, allowance + 1, "P_ref rose no faster than refUpRateBps");
        assertLt(pRefAfterPump, vault.pMktX18() + 1, "and it is behind the market it is chasing");

        // --- the spokes follow, inside one TWAP window --------------------------------------------------------
        uint256 followStart = vm.getBlockTimestamp();
        for (uint256 round; round < 20; ++round) {
            for (uint256 i; i < spokePools.length; ++i) {
                try this.buyAmpsExternal(spokePools[i], ALICE, _spokeUnit(i)) {} catch {}
            }
            advance(80);
        }
        uint256 followElapsed = vm.getBlockTimestamp() - followStart;
        assertLe(followElapsed, Constants.TWAP_WINDOW_DEFAULT, "the follow-through fits inside one TWAP window");

        for (uint256 i; i < spokePools.length; ++i) {
            int24 moved = tickOf(spokePools[i]) - spokeStart[i];
            console.log("spoke", i, "followed by ticks", vm.toString(moved));
            assertGe(moved, PUMP_TICKS * 9 / 10, "every spoke followed the hub to within a tenth of the move");
        }

        // The hub's own reference has absorbed the pump by now, which is what let the spokes move at all.
        assertGe(hook.twapTick30m(hubPool) - hubStart, PUMP_TICKS / 2, "the hub TWAP absorbed the pump");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The fee wall and the rail
    // -------------------------------------------------------------------------------------------------------------

    /// @notice §1.4's fee law on a live entry pool, measured through the hook's own `quoteFee` - which is what
    ///         `beforeSwap` charges. Inside the inner band `f_dev = K_DEV_BPS * dev^2 / 1e4` is strictly
    ///         increasing and convex in the deviation; from the band to the rail it keeps climbing; and the whole
    ///         dynamic part is clamped at `dynCapBps`.
    ///
    /// @dev **The wall is invisible in the normal gate state, and that is the design.** The ramp's ceiling is
    ///      `F_WALL_BPS` = 1,500 bp, but `dynCapBps` is `DYN_CAP_NORMAL_BPS` = 300 until the gate escalates it, so
    ///      the charged fee saturates at 300 bp long before the rail. {test_theWallOnlyShowsOnceTheGateEscalates}
    ///      is the other half of that statement.
    function test_feeIsQuadraticInsideTheBandAndMonotoneToTheRail() public {
        refreshGateCache(hubPool);
        int24 band = hook.innerBandTicks(hubPool);
        int24 rail = hook.outerRailTicks(hubPool);
        int24 fair = hook.fairTick(hubPool);
        assertEq(band, Constants.INNER_BAND_REGULAR_TICKS, "an entry pool uses the flat 200-tick band");
        assertEq(rail, 2000, "and the flat 2,000-tick rail");

        uint16[6] memory inside;
        for (uint256 k; k < 6; ++k) {
            forceTick(hubPool, fair + band * int24(uint24(k)) / 5);
            (,, uint16 dynBps, bool refuse) = hook.quoteFee(hubPool, false, true, 1e6);
            assertFalse(refuse, "nothing inside the band is refused");
            inside[k] = dynBps;
        }
        for (uint256 k = 1; k < 6; ++k) {
            assertGt(inside[k], inside[k - 1], "f_dev is strictly increasing inside the band");
        }
        for (uint256 k = 2; k < 6; ++k) {
            assertGt(
                int256(uint256(inside[k])) - int256(uint256(inside[k - 1])),
                int256(uint256(inside[k - 1])) - int256(uint256(inside[k - 2])),
                "and convex: each step costs more than the last"
            );
        }

        uint16 previous = inside[5];
        uint16 cap = hook.poolState(hubPool).dynCapBps;
        for (int24 dev = band; dev <= rail; dev += 200) {
            forceTick(hubPool, fair + dev);
            (uint24 pips, uint16 baseBps, uint16 dynBps, bool refuse) = hook.quoteFee(hubPool, false, true, 1e6);
            assertFalse(refuse, "nothing inside the rail is refused");
            assertGe(dynBps, previous, "the fee never falls as the deviation grows");
            assertLe(dynBps, cap, "and never exceeds the dynamic cap (I16)");
            assertEq(uint256(pips), uint256(baseBps + dynBps) * Constants.PIPS_PER_BPS, "fee = base + dyn");
            previous = dynBps;
        }
        assertEq(previous, cap, "at the rail the wall is clipped by the cap, not by the ramp");
    }

    /// @notice The other half: the quadratic ramp toward `F_WALL_BPS` only becomes visible once `dynCapBps` is
    ///         escalated. With the gate answering `DYN_CAP_ESCALATION_BPS` the charged dynamic fee climbs well
    ///         past `DYN_CAP_NORMAL_BPS` and up the ramp toward the 1,500 bp wall.
    ///
    /// @dev The gate's answer is mocked here rather than provoked, because what is under test is the **hook's**
    ///      use of the cap, not the gate's escalation rule (which `test/unit/OracleGate.t.sol` owns).
    function test_theWallOnlyShowsOnceTheDynamicCapIsEscalated() public {
        refreshGateCache(hubPool);
        int24 fair = hook.fairTick(hubPool);
        forceTick(hubPool, fair + 1900);

        (,, uint16 clipped,) = hook.quoteFee(hubPool, false, true, 1e6);
        assertEq(clipped, Constants.DYN_CAP_NORMAL_BPS, "at the normal cap the wall is clipped at 300 bp");

        _mockGateCap(hubPool, Constants.DYN_CAP_ESCALATION_BPS, fair);
        refreshGateCache(hubPool);
        assertEq(
            uint256(hook.poolState(hubPool).dynCapBps),
            uint256(Constants.DYN_CAP_ESCALATION_BPS),
            "the hook cached the escalated cap"
        );

        (,, uint16 dynBps, bool refuse) = hook.quoteFee(hubPool, false, true, 1e6);
        assertFalse(refuse, "1,900 ticks is still inside the entry pool's 2,000-tick rail");
        assertGt(dynBps, Constants.DYN_CAP_NORMAL_BPS, "and the wall now shows above the normal cap");
        assertLe(dynBps, Constants.F_WALL_BPS, "bounded by F_WALL_BPS, which is the ramp's own ceiling");
        vm.clearMockedCalls();
    }

    /// @notice §10 ruling 2: the rail refuses **only** a deviation-increasing swap, and only beyond the rail. The
    ///         price-improving direction is never refused, at any deviation.
    ///
    /// @dev The pool is put beyond its rail by moving the **reference**, which is what an overnight gap in the
    ///      underlying does: `fairTick` jumps while the spoke has not traded, and the pool wakes up outside the
    ///      rail on one side. Moving the pool itself cannot get there - that is what the rail is for.
    function test_railRefusesOnlyTheDeviationIncreasingDirection() public {
        PoolId spoke = spokePools[0];
        refreshGateCache(spoke);
        int24 rail = hook.outerRailTicks(spoke);
        int24 poolTick = tickOf(spoke);

        // The reference is far above the pool: a buy walks toward it, a sell away from it.
        _mockGateFair(spoke, poolTick + rail + 500);
        refreshGateCache(spoke);
        assertGt(hook.fairTick(spoke) - poolTick, rail, "the pool is beyond the rail, below its reference");

        (,,, bool refuseBuy) = hook.quoteFee(spoke, false, true, 1e15);
        (,,, bool refuseSell) = hook.quoteFee(spoke, true, true, 1e18);
        assertFalse(refuseBuy, "below the reference, a buy is the improving direction and is never refused");
        assertTrue(refuseSell, "and a sell - which would widen the gap - is refused");

        // And the mirror image, with the reference far below the pool.
        _mockGateFair(spoke, poolTick - rail - 500);
        refreshGateCache(spoke);
        assertGt(poolTick - hook.fairTick(spoke), rail, "the pool is beyond the rail, above its reference");

        (,,, refuseBuy) = hook.quoteFee(spoke, false, true, 1e15);
        (,,, refuseSell) = hook.quoteFee(spoke, true, true, 1e18);
        assertTrue(refuseBuy, "above the reference the buy is the deviation-increasing direction");
        assertFalse(refuseSell, "and the sell is the one that is always allowed");
        vm.clearMockedCalls();
    }

    /// @notice I19 at the integration level: the band a live pool uses is monotone non-decreasing in how closed
    ///         the session is, and the entry pools never widen at all.
    function test_i19_bandWidensWithSessionClosednessAndEntryPoolsNeverDo() public {
        PoolId spoke = spokePools[0];
        refreshGateCache(spoke);
        refreshGateCache(hubPool);
        int24 regularSpoke = hook.innerBandTicks(spoke);
        int24 regularEntry = hook.innerBandTicks(hubPool);
        assertEq(regularSpoke, Constants.INNER_BAND_REGULAR_TICKS, "a Regular spoke uses the Regular band");

        // Saturday: the market is closed and stays closed.
        warpBy(3 days);
        refreshGateCache(spoke);
        refreshGateCache(hubPool);
        assertEq(uint256(gate.sessionAt(vm.getBlockTimestamp())), uint256(Session.CLOSED), "the weekend is CLOSED");
        assertGe(hook.innerBandTicks(spoke), regularSpoke, "the spoke band widened, or at least did not narrow");
        assertEq(hook.innerBandTicks(hubPool), regularEntry, "and the entry pool's band never moves");
    }

    /// @notice The plan's "zero quote reverts inside the outer rail across every band state": every pool, both
    ///         directions, in every session the calendar produces, answered without a revert and without a refusal
    ///         while the pool is inside its rail.
    function test_noQuoteRevertsInsideTheRailInAnyBandState() public {
        uint256[5] memory offsets = [uint256(0), 6 hours, 12 hours, 3 days, 4 days];
        PoolId[] memory ids = allPools();

        for (uint256 s; s < offsets.length; ++s) {
            if (offsets[s] != 0) warpBy(offsets[s]);
            for (uint256 i; i < ids.length; ++i) {
                refreshGateCache(ids[i]);
                int24 dev = _deviation(ids[i]);
                int24 rail = hook.outerRailTicks(ids[i]);

                (uint24 buyPips, uint16 buyBase, uint16 buyDyn, bool refuseBuy) =
                    hook.quoteFee(ids[i], false, true, 1e15);
                (uint24 sellPips, uint16 sellBase, uint16 sellDyn, bool refuseSell) =
                    hook.quoteFee(ids[i], true, true, 1e18);

                if (dev <= rail) {
                    assertFalse(refuseBuy, "no buy is refused inside the rail");
                    assertFalse(refuseSell, "no sell is refused inside the rail");
                }
                // I16: the total is `base + dyn`, `base` is the pool's own buy fee or the sell fee, and neither
                // side ever exceeds the protocol ceiling.
                assertEq(uint256(buyPips), uint256(buyBase + buyDyn) * Constants.PIPS_PER_BPS, "buy fee decomposes");
                assertEq(uint256(sellPips), uint256(sellBase + sellDyn) * Constants.PIPS_PER_BPS, "sell decomposes");
                assertEq(uint256(buyBase), uint256(registry.poolConfig(ids[i]).buyFeeBps), "buy base is the buy fee");
                assertEq(uint256(sellBase), uint256(hook.sellFeeBps()), "sell base is the sell fee");
                assertLe(uint256(buyBase + buyDyn), uint256(hook.TOTAL_FEE_BPS_MAX()), "and both stay under the cap");
                assertLe(uint256(sellBase + sellDyn), uint256(hook.TOTAL_FEE_BPS_MAX()), "on both sides");

                // The quoter agrees with the hook, in every band state, and never reverts doing so.
                IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(ids[i]);
                assertEq(uint256(quote.buyFeePips), uint256(buyPips), "the quoter reports the hook's buy fee");
                assertEq(uint256(quote.sellFeePips), uint256(sellPips), "and the hook's sell fee");
            }
        }
    }

    /// @notice **Regression (liveness), `docs/phase3-state-model.md` §12.3 ruling V.** An actively traded pool must
    ///         not destroy its own TWAP coverage. The ring still holds `TruncatedOracleLib.MAX_CARDINALITY = 64`
    ///         slots, but a slot is committed at most once per `MIN_INSERT_INTERVAL` seconds while the accumulator
    ///         advances on every swap, so a full ring spans `63 x 115 = 7,245 s` - more than the widest window
    ///         governance can set - and coverage is bought with elapsed time rather than spent by trading.
    ///
    /// @dev **What used to happen.** `write` pushed one observation per distinct second, so 64 slots covered 64
    ///      seconds. Seventy writes three seconds apart left 189 s of coverage against an 1,800 s window;
    ///      `twapTick30m` reverted `WindowNotCovered`, `OracleGate._referenceIntegrity` reported `coverageMissing`
    ///      for the hub, the gate went `WATCHDOG` and every gated path - placement, compound, rollout, bonded
    ///      deployment, bonds - refused until trading stopped for a full window. On a 100 ms chain that is ordinary
    ///      trading, not an attack.
    ///
    /// @dev **What this asserts.** The original repro (seventy `afterSwap` writes three seconds apart), then two
    ///      hours of writing in *every* second: coverage stays at or above the window throughout, never falls, the
    ///      30-minute read answers every time, and the gate stays green.
    function test_theObservationRingCoversTheTwapWindowUnderActiveTrading() public {
        assertGe(hook.observationCoverage(hubPool), Constants.TWAP_WINDOW_DEFAULT, "covered to begin with");
        assertEq(uint256(TruncatedOracleLib.MAX_CARDINALITY), 64, "the ring is still 64 observations");
        assertEq(uint256(TruncatedOracleLib.MIN_INSERT_INTERVAL), 115, "one committed slot per 115 s at most");
        assertGe(
            uint256(TruncatedOracleLib.MIN_INSERT_INTERVAL) * (uint256(TruncatedOracleLib.MAX_CARDINALITY) - 1),
            uint256(Constants.TWAP_WINDOW_MAX),
            "a full ring spans the widest governable window"
        );
        assertFalse(gate.snapshotByPool(hubPool).watchdogTripped, "and the gate is green to begin with");

        // --- the original repro: seventy writes, three seconds apart -----------------------------------------
        uint32 opening = hook.observationCoverage(hubPool);
        for (uint256 i; i < 70; ++i) {
            advance(3);
            _pokeAfterSwap(hubPool, i % 2 == 0);
            assertGe(hook.observationCoverage(hubPool), Constants.TWAP_WINDOW_DEFAULT, "covered on every write");
        }

        uint32 coverage = hook.observationCoverage(hubPool);
        console.log("coverage after 70 writes at 3s", coverage, "window", Constants.TWAP_WINDOW_DEFAULT);
        assertEq(coverage, opening + 210, "coverage grew with the clock rather than collapsing to 63 slots");
        hook.twapTick30m(hubPool); // used to revert `WindowNotCovered`
        assertFalse(gate.snapshotByPool(hubPool).watchdogTripped, "the watchdog does not trip");
        assertEq(uint256(gate.snapshotByPool(hubPool).state), uint256(GateState.GREEN), "the reported state is GREEN");

        // --- and two hours of writing in every single second --------------------------------------------------
        // The clock is advanced through cheatcode reads (§12.3 note S) and the feeds are republished periodically,
        // so what is under test is the ring and nothing else.
        uint32 previous = coverage;
        for (uint256 i; i < 7200; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.roll(vm.getBlockNumber() + 1);
            if (i % 300 == 0) refreshFeeds();
            _pokeAfterSwap(hubPool, i % 2 == 0);

            uint32 nowCovered = hook.observationCoverage(hubPool);
            // Coverage only ever grows, until the ring wraps - and a wrapped ring still spans a full
            // `(MAX_CARDINALITY - 1) * MIN_INSERT_INTERVAL`, which is more than the widest governable window.
            assertTrue(
                nowCovered >= previous || nowCovered >= _fullRingSpan(),
                "coverage grows, or has settled on the full-ring floor"
            );
            assertGe(nowCovered, Constants.TWAP_WINDOW_DEFAULT, "and never falls under the window");
            previous = nowCovered;
        }
        refreshFeeds();

        assertGe(hook.observationCoverage(hubPool), Constants.TWAP_WINDOW_MAX, "two hours buys the widest window");
        hook.twapTick30m(hubPool);
        hook.twapTick(hubPool, Constants.TWAP_WINDOW_MAX);
        console.log("coverage after two hours of per-second writes", hook.observationCoverage(hubPool));

        // The gate is green, and the gated path it guards runs.
        _pokeAfterSwap(hubPool, true);
        assertFalse(gate.snapshotByPool(hubPool).watchdogTripped, "the gate is still green");
        assertTrue(gate.snapshotByPool(hubPool).state != GateState.WATCHDOG, "and not in WATCHDOG");
        vm.prank(KEEPER);
        vault.compound(hubPool);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Makes the gate answer one pool's snapshot with a different fair tick, leaving everything else as the
    ///      real gate computed it.
    function _mockGateFair(PoolId poolId, int24 fairTick) private {
        GateSnapshot memory snapshot = gate.snapshotByPool(poolId);
        snapshot.fairTick = fairTick;
        vm.mockCall(address(gate), abi.encodeCall(IOracleGate.snapshotByPool, (poolId)), abi.encode(snapshot));
    }

    /// @dev The same, for the dynamic cap.
    function _mockGateCap(PoolId poolId, uint16 dynCapBps, int24 fairTick) private {
        GateSnapshot memory snapshot = gate.snapshotByPool(poolId);
        snapshot.dynCapBps = dynCapBps;
        snapshot.fairTick = fairTick;
        vm.mockCall(address(gate), abi.encodeCall(IOracleGate.snapshotByPool, (poolId)), abi.encode(snapshot));
    }

    /// @dev The seconds a full ring spans: `(MAX_CARDINALITY - 1) * MIN_INSERT_INTERVAL`, the floor coverage
    ///      settles on once the oldest slot starts being recycled.
    function _fullRingSpan() private pure returns (uint32 span) {
        span = (uint32(TruncatedOracleLib.MAX_CARDINALITY) - 1) * TruncatedOracleLib.MIN_INSERT_INTERVAL;
    }

    /// @dev The stock a spoke arbitrage step spends: a few tenths of a percent of the cell it is walking through.
    function _spokeUnit(uint256 i) private view returns (uint256 unit) {
        unit = uint256(0.05e18) * 1e8 / uint256(stockUsd8[i]);
    }

    /// @dev The pool's live deviation from the reference the hook is charging against.
    function _deviation(PoolId poolId) private view returns (int24 dev) {
        int24 delta = tickOf(poolId) - hook.fairTick(poolId);
        dev = delta < 0 ? -delta : delta;
    }
}
