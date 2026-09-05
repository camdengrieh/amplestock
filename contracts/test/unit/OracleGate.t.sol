// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IOracleGate} from "../../src/interfaces/IOracleGate.sol";
import {GatePriceMath} from "../../src/oracle/GatePriceMath.sol";
import {OracleGate} from "../../src/oracle/OracleGate.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotGuardian, NotTimelock, OutOfBand, ZeroAddress} from "../../src/types/Errors.sol";
import {GateSnapshot, GateState, PoolClass, PoolConfig, Session} from "../../src/types/Types.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {OracleGateFixture} from "./OracleGateFixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev A Stock Token stand-in whose every issuer view reverts, so the bounded probes have something hostile to
///      survive. It has code, so the code-size shortcut does not fire and the `try` path is exercised.
contract HostileStockToken {
    error Nope();

    /// @notice Always reverts.
    /// @return Never returned.
    function oraclePaused() external pure returns (bool) {
        revert Nope();
    }

    /// @notice Always reverts.
    /// @return Never returned.
    function effectiveAt() external pure returns (uint256) {
        revert Nope();
    }

    /// @notice Always reverts.
    /// @return Never returned.
    function newUIMultiplier() external pure returns (uint256) {
        revert Nope();
    }

    /// @notice Always reverts.
    /// @return Never returned.
    function uiMultiplier() external pure returns (uint256) {
        revert Nope();
    }
}

/// @dev Every external read reverts. Standing in for a mis-pointed or hostile registry / market reference: the
///      gate must degrade to "unknown" on each one rather than take a swap quote down with it.
contract RevertingContract {
    error Nope();

    /// @notice Reverts on every call, including ones with no matching function.
    fallback() external {
        revert Nope();
    }
}

/// @dev A market reference with an independent revert switch per read, so each bounded probe in the gate has its
///      own failure to survive.
contract PartialMarketReference {
    uint32 public window = 1800;
    int24 public tick;
    uint32 public coverage = 1800;
    bool public failWindow;
    bool public failCoverage;
    bool public failTwap;
    bool public failLast;

    error Nope();

    /// @notice Arms the four failure switches.
    /// @param window_ Whether `twapWindow` reverts.
    /// @param coverage_ Whether `observationCoverage` reverts.
    /// @param twap_ Whether `twapTick` reverts.
    /// @param last_ Whether `lastTruncatedTick` reverts.
    function setFailures(bool window_, bool coverage_, bool twap_, bool last_) external {
        failWindow = window_;
        failCoverage = coverage_;
        failTwap = twap_;
        failLast = last_;
    }

    /// @notice Sets the tick every read reports.
    /// @param tick_ The tick.
    function setTick(int24 tick_) external {
        tick = tick_;
    }

    /// @notice The canonical TWAP window.
    /// @return value The window.
    function twapWindow() external view returns (uint32 value) {
        if (failWindow) revert Nope();
        return window;
    }

    /// @notice The ring coverage.
    /// @return value The seconds covered.
    function observationCoverage(bytes32) external view returns (uint32 value) {
        if (failCoverage) revert Nope();
        return coverage;
    }

    /// @notice The mean tick.
    /// @return value The tick.
    function twapTick(bytes32, uint32) external view returns (int24 value) {
        if (failTwap) revert Nope();
        return tick;
    }

    /// @notice The current truncated tick.
    /// @return value The tick.
    function lastTruncatedTick(bytes32) external view returns (int24 value) {
        if (failLast) revert Nope();
        return tick;
    }
}

/// @dev A layer-C registry that offers only `IFeedRegistry.latestAnswer`, with no session-aware overload: the
///      gate must fall back to it rather than lose the price.
contract LegacyFeedRegistry {
    /// @notice The only read this registry offers.
    /// @return answerUsd8 A fixed answer.
    /// @return updatedAt A fixed timestamp.
    /// @return fresh Always true.
    function latestAnswer(address) external view returns (uint256 answerUsd8, uint32 updatedAt, bool fresh) {
        return (180e8, uint32(block.timestamp), true);
    }
}

/// @notice `OracleGate`: layers A, C, D, E and F, the guardian freezes and every governed band.
/// @dev Layer B has its own suite (`Calendar.t.sol`); this one only uses the calendar to pick a session.
contract OracleGateTest is OracleGateFixture {
    /// @dev Monday 2026-03-09 09:30 EDT, the regular session.
    uint256 internal constant MON_REGULAR = 1_773_063_000;

    /// @dev Monday 2026-03-09 17:00 EDT, the post-market session.
    uint256 internal constant MON_POST = 1_773_090_000;

    /// @dev Monday 2026-03-09 21:00 EDT, the overnight session.
    uint256 internal constant MON_OVERNIGHT = 1_773_104_400;

    /// @dev Friday 2026-03-13 21:00 EDT, an hour past the weekly close.
    uint256 internal constant FRI_CLOSED = 1_773_450_000;

    /// @dev The hub pool's mean tick: AMPS at $1 against 6-decimal USDG at $1, aligned to the 60 spacing.
    int24 internal constant HUB_TICK = -276_360;

    /// @dev Every pool in the fixture uses the 60 tick spacing.
    int24 internal constant TICK_SPACING = 60;

    address internal constant USDG = address(0x5D6);
    address internal constant WETH = address(0x9E7);

    PoolId internal hubPool;
    PoolId internal wethPool;
    PoolId internal spokePool;

    MockStockToken internal nvda;
    MockAggregator internal nvdaFeed;
    MockAggregator internal usdgFeed;
    MockAggregator internal wethFeed;

    uint16 internal constituentId;
    int24 internal fairTick;

    function setUp() public {
        vm.warp(MON_REGULAR);
        vm.roll(1_000_000);
        _deployGate();

        hubPool = _poolId("AMPS/USDG");
        wethPool = _poolId("AMPS/WETH");
        spokePool = _poolId("AMPS/NVDA");

        usdgFeed = _installFeed(USDG, 1e8, Constants.ONE_DAY);
        wethFeed = _installFeed(WETH, 3000e8, Constants.ONE_DAY);
        nvda = _stockToken("NVDA");
        nvdaFeed = _installFeed(address(nvda), 180e8, Constants.ONE_DAY);

        registry.addEntryPool(hubPool, USDG, 6, TICK_SPACING, 30);
        registry.addEntryPool(wethPool, WETH, 18, TICK_SPACING, 30);
        registry.setHubPoolId(hubPool);
        registry.setWethPoolId(wethPool);
        constituentId = registry.addConstituentAndPool(
            address(nvda), address(nvdaFeed), spokePool, PoolClass.SPOKE, TICK_SPACING, 1000
        );

        // The fair tick of every pool is derived from the hub's implied AMPS price, so the fixture starts with
        // every pool exactly on its reference and each test moves one thing.
        GatePriceMath math = gate.priceMath();
        uint256 ampsUsd18 = math.ampsPriceUsd18(HUB_TICK, 1e8, 6);
        fairTick = math.fairTick(ampsUsd18, 180e8, 18, TICK_SPACING);
        int24 wethTick = math.fairTick(ampsUsd18, 3000e8, 18, 1);

        marketRef.setObservation(hubPool, HUB_TICK, HUB_TICK, 1800);
        marketRef.setObservation(wethPool, wethTick, wethTick, 1800);
        marketRef.setObservation(spokePool, fairTick, fairTick, 1800);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The green state
    // -------------------------------------------------------------------------------------------------------------

    /// @notice With every layer satisfied the gate is green, placements run at the reference, bonds run with no
    ///         haircut and the hook's cap is the normal one.
    function test_green() public view {
        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertEq(uint8(gate_.state), uint8(GateState.GREEN), "green");
        assertEq(uint8(gate_.session), uint8(Session.REGULAR), "regular session");
        assertFalse(gate_.feedStale, "fresh");
        assertFalse(gate_.corporateFreeze, "no corporate action");
        assertFalse(gate_.diverged, "in band");
        assertFalse(gate_.watchdogTripped, "blocks are being produced");
        assertEq(gate_.hSessionBps, Constants.H_SESSION_REGULAR_BPS_DEFAULT, "no haircut in the regular session");
        assertEq(gate_.dynCapBps, Constants.DYN_CAP_NORMAL_BPS, "normal cap");
        assertEq(gate_.answerUsd8, 180e8, "the constituent's answer");
        assertEq(gate_.answerUpdatedAt, uint32(MON_REGULAR), "its timestamp");
        assertEq(gate_.poolTick, fairTick, "on the reference");
        assertEq(gate_.fairTick, fairTick, "and the reference itself");
        assertEq(gate_.observedAt, uint32(MON_REGULAR), "observed now");

        (bool allowed, bool anchorAtNav) = gate.isPlacementAllowed(spokePool);
        assertTrue(allowed, "placements run");
        assertFalse(anchorAtNav, "at the reference");
        assertEq(gate.checkPlacement(spokePool), false, "checkPlacement agrees");

        uint16 haircut;
        (allowed, haircut) = gate.isBondAllowed(constituentId);
        assertTrue(allowed, "bonds run");
        assertEq(haircut, 0, "no haircut");
        assertEq(gate.checkBond(constituentId), 0, "checkBond agrees");
        assertEq(gate.dynCapBps(spokePool), Constants.DYN_CAP_NORMAL_BPS, "normal cap");
    }

    /// @notice The pool-addressed reads answer identically to the constituent-addressed ones.
    function test_green_snapshotByPool() public view {
        assertEq(uint8(gate.stateByPool(spokePool)), uint8(GateState.GREEN), "same state");
        GateSnapshot memory byPool = gate.snapshotByPool(spokePool);
        assertEq(byPool.answerUsd8, gate.snapshot(constituentId).answerUsd8, "same answer");
    }

    /// @notice A protocol-wide read (`constituentId == 0`) skips layers C, D and E and reports only the
    ///         protocol-wide layers.
    function test_green_protocolWide() public view {
        GateSnapshot memory gate_ = gate.snapshot(0);
        assertEq(uint8(gate_.state), uint8(GateState.GREEN), "green");
        assertEq(gate_.answerUsd8, 0, "no constituent answer");
        assertFalse(gate_.feedStale, "no feed to be stale");
        assertEq(gate_.poolTick, 0, "no pool");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Layer A: the block-cadence watchdog
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Time alone is not an outage: an hour with no call but with blocks produced leaves the watchdog
    ///         clear, because layer A is a substitute for a sequencer-uptime feed, not a keeper-liveness alarm.
    function test_watchdog_timeAloneDoesNotTrip() public {
        vm.warp(block.timestamp + gate.graceSeconds() + 1);
        vm.roll(block.number + 1000);
        (,, bool tripped) = gate.watchdog();
        assertFalse(tripped, "blocks kept coming");
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "still green");
    }

    /// @notice Wall-clock time past `GRACE` with no blocks produced across it is the outage the watchdog exists
    ///         for. Placements pause; bonds keep running at the session haircut.
    function test_watchdog_trips() public {
        vm.warp(block.timestamp + gate.graceSeconds() + 1);
        (uint32 stampedBlock, uint32 stampedAt, bool tripped) = gate.watchdog();
        assertEq(stampedBlock, uint32(1_000_000), "stamped block");
        assertEq(stampedAt, uint32(MON_REGULAR), "stamped timestamp");
        assertTrue(tripped, "no blocks in an hour");

        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertTrue(gate_.watchdogTripped, "flagged");
        assertEq(uint8(gate_.state), uint8(GateState.WATCHDOG), "watchdog");
        assertEq(gate_.dynCapBps, Constants.DYN_CAP_DEGRADED_BPS, "degraded cap");

        (bool allowed,) = gate.isPlacementAllowed(spokePool);
        assertFalse(allowed, "placements pause");
        vm.expectRevert(abi.encodeWithSelector(IOracleGate.GateRefused.selector, GateState.WATCHDOG, spokePool));
        gate.checkPlacement(spokePool);

        uint16 haircut;
        (allowed, haircut) = gate.isBondAllowed(constituentId);
        assertTrue(allowed, "bonds continue through the watchdog");
        assertEq(gate.checkBond(constituentId), haircut, "at the session haircut");
    }

    /// @notice A partialRef block supply still trips: fewer blocks than `gapSeconds` implies is the test, not zero
    ///         blocks.
    function test_watchdog_partialBlockSupplyTrips() public {
        uint32 grace = gate.graceSeconds();
        uint32 gap = gate.gapSeconds();
        vm.warp(block.timestamp + grace + 1);
        vm.roll(block.number + (uint256(grace + 1) / uint256(gap)) - 1);
        (,, bool tripped) = gate.watchdog();
        assertTrue(tripped, "one block short of the expectation");

        vm.roll(block.number + 1);
        (,, tripped) = gate.watchdog();
        assertFalse(tripped, "exactly the expectation is enough");
    }

    /// @notice `poke` re-stamps, clears the watchdog and reports both edges of the transition it observed.
    function test_watchdog_pokeClears() public {
        vm.warp(block.timestamp + gate.graceSeconds() + 1);
        (,, bool tripped) = gate.watchdog();
        assertTrue(tripped, "tripped");

        vm.expectEmit(false, false, false, true, address(gate));
        emit IOracleGate.WatchdogStamped(uint32(block.number), uint32(block.timestamp));
        vm.expectEmit(false, false, false, true, address(gate));
        emit IOracleGate.WatchdogTripped(true, gate.graceSeconds() + 1);
        vm.expectEmit(false, false, false, true, address(gate));
        emit IOracleGate.WatchdogTripped(false, 0);
        vm.prank(STRANGER);
        gate.poke();

        (uint32 stampedBlock, uint32 stampedAt, bool stillTripped) = gate.watchdog();
        assertEq(stampedBlock, uint32(block.number), "restamped");
        assertEq(stampedAt, uint32(block.timestamp), "restamped");
        assertFalse(stillTripped, "cleared");
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "green again");
    }

    /// @notice A stamp in the future (a chain that rewound its clock) saturates to zero elapsed rather than
    ///         underflowing.
    function test_watchdog_futureStampSaturates() public {
        vm.prank(STRANGER);
        gate.poke();
        vm.warp(block.timestamp - 1000);
        (,, bool tripped) = gate.watchdog();
        assertFalse(tripped, "no negative elapsed");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Layer C: freshness
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A stale feed degrades: placements pause, bonds continue at the session haircut, and the hook's cap
    ///         widens. This is the whole per-path staleness policy in one test.
    function test_degraded_staleFeed() public {
        vm.prank(TIMELOCK);
        feeds.configureFeed(address(nvda), 300, 50, 1, type(uint128).max);
        vm.warp(block.timestamp + 451);
        gate.poke();

        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertEq(uint8(gate_.session), uint8(Session.REGULAR), "still the regular session");
        assertTrue(gate_.feedStale, "stale");
        assertEq(uint8(gate_.state), uint8(GateState.DEGRADED), "degraded");
        assertEq(gate_.dynCapBps, Constants.DYN_CAP_DEGRADED_BPS, "cap widens");

        (bool allowed,) = gate.isPlacementAllowed(spokePool);
        assertFalse(allowed, "placements pause");
        (allowed,) = gate.isBondAllowed(constituentId);
        assertTrue(allowed, "bonds continue");
    }

    /// @notice A closed session is degraded even with a perfectly fresh feed, and the bond haircut is the closed
    ///         one: the weekend-gap bound the 24/7 bond market is priced against.
    function test_degraded_closedSession() public {
        vm.warp(FRI_CLOSED);
        vm.roll(block.number + 100_000);
        gate.poke();

        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertEq(uint8(gate_.session), uint8(Session.CLOSED), "closed");
        assertFalse(gate_.feedStale, "the freshness check is disabled when closed");
        assertEq(uint8(gate_.state), uint8(GateState.DEGRADED), "degraded");
        assertEq(gate_.hSessionBps, Constants.H_SESSION_CLOSED_BPS_DEFAULT, "300 bp");

        (bool allowed, uint16 haircut) = gate.isBondAllowed(constituentId);
        assertTrue(allowed, "the weekend bond market stays open");
        assertEq(haircut, Constants.H_SESSION_CLOSED_BPS_DEFAULT, "at the closed haircut");
    }

    /// @notice The haircut follows the session, and a per-constituent override replaces the table entirely.
    function test_hSession_tableAndOverride() public {
        vm.warp(MON_POST);
        gate.poke();
        (, uint16 haircut) = gate.isBondAllowed(constituentId);
        assertEq(haircut, Constants.H_SESSION_PRE_POST_BPS_DEFAULT, "pre/post");

        vm.warp(MON_OVERNIGHT);
        gate.poke();
        (, haircut) = gate.isBondAllowed(constituentId);
        assertEq(haircut, Constants.H_SESSION_OVERNIGHT_BPS_DEFAULT, "overnight");

        registry.setHSessionOverride(constituentId, 777, true);
        (, haircut) = gate.isBondAllowed(constituentId);
        assertEq(haircut, 777, "the override replaces the table");

        registry.setHSessionOverride(constituentId, 777, false);
        (, haircut) = gate.isBondAllowed(constituentId);
        assertEq(haircut, Constants.H_SESSION_OVERNIGHT_BPS_DEFAULT, "and can be turned off again");
    }

    /// @notice A dead feed is a stale feed, not a revert.
    function test_degraded_deadFeed() public {
        vm.prank(TIMELOCK);
        feeds.configureFeed(address(nvda), 300, 50, 1, type(uint128).max);
        nvdaFeed.setRevert(true);
        vm.warp(block.timestamp + 451);
        gate.poke();
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.DEGRADED), "degraded, not reverting");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Layer D: corporate actions
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `oraclePaused()` closes the constituent: no placements, no bonds, and swaps are untouched.
    function test_corporateAction_oraclePaused() public {
        nvda.setOraclePaused(true);
        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertTrue(gate_.corporateFreeze, "flagged");
        assertEq(uint8(gate_.state), uint8(GateState.SCHEDULED_FREEZE), "frozen");

        (bool allowed,) = gate.isBondAllowed(constituentId);
        assertFalse(allowed, "bonds refuse");
        vm.expectRevert(abi.encodeWithSelector(IOracleGate.GateRefused.selector, GateState.SCHEDULED_FREEZE, spokePool));
        gate.checkBond(constituentId);
        vm.expectRevert(abi.encodeWithSelector(IOracleGate.GateRefused.selector, GateState.SCHEDULED_FREEZE, spokePool));
        gate.checkPlacement(spokePool);

        nvda.setOraclePaused(false);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "and clears by itself");
    }

    /// @notice A scheduled multiplier change freezes the constituent for a window either side of its
    ///         `effectiveAt`, and only while a change is actually pending.
    function test_corporateAction_scheduledEffectiveAt() public {
        uint32 window = gate.corporateActionWindow();

        nvda.scheduleUIMultiplier(4e18, block.timestamp + window + 1);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "outside the window ahead");

        nvda.scheduleUIMultiplier(4e18, block.timestamp + window);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "on the leading edge");

        nvda.scheduleUIMultiplier(4e18, block.timestamp - window);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "on the trailing edge");

        nvda.scheduleUIMultiplier(4e18, block.timestamp - window - 1);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "outside the window behind");

        // A schedule whose pending multiplier already equals the live one is not a change in flight.
        nvda.scheduleUIMultiplier(1e18, block.timestamp);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "nothing actually changes");

        nvda.scheduleUIMultiplier(4e18, block.timestamp);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "a real 4:1 split");
        assertEq(gate.snapshot(constituentId).answerUsd8, 180e8, "and the answer is never multiplied by it");
    }

    /// @notice Governance can force a corporate-action freeze through the registry, independently of the issuer.
    function test_corporateAction_registryOverride() public {
        registry.setCaFreezeOverride(constituentId, true);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "forced");
        registry.setCaFreezeOverride(constituentId, false);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "released");
    }

    /// @notice A Stock Token whose issuer views all revert is *unknown*, not frozen: an upgraded implementation
    ///         must not be able to close a market by misbehaving, and layer C still covers its price.
    function test_corporateAction_hostileTokenIsUnknown() public {
        HostileStockToken hostile = new HostileStockToken();
        registry.setToken(constituentId, address(hostile));
        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertFalse(gate_.corporateFreeze, "unknown is not frozen");
        assertTrue(gate_.feedStale, "but the price is gone, so the gate degrades");
        assertEq(uint8(gate_.state), uint8(GateState.DEGRADED), "degraded");
    }

    /// @notice A codeless constituent token is skipped entirely rather than probed.
    function test_corporateAction_codelessToken() public {
        registry.setToken(constituentId, address(0xC0DE1E55));
        assertFalse(gate.snapshot(constituentId).corporateFreeze, "nothing to probe");
    }

    /// @notice `pokeConstituent` records the layer-D observation for the indexer and re-evaluates the pool.
    function test_corporateAction_pokeEmitsObservation() public {
        nvda.setOraclePaused(true);
        vm.expectEmit(true, false, false, true, address(gate));
        emit IOracleGate.CorporateActionFreeze(constituentId, true, 0);
        vm.prank(STRANGER);
        gate.pokeConstituent(constituentId);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Layer E: the divergence breaker
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A deviation outside the band is not `DIVERGED` until it has been armed and has persisted for
    ///         `divergenceSustainSeconds`; then it closes that one pool's bonds and placements while swaps and
    ///         redemption are untouched.
    function test_divergence_armsThenLatches() public {
        marketRef.setObservation(spokePool, fairTick, fairTick + 700, 1800);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "not armed yet");

        vm.expectEmit(true, false, false, true, address(gate));
        emit IOracleGate.DivergenceLatched(spokePool, 700, true);
        vm.prank(STRANGER);
        gate.pokePool(spokePool);
        assertEq(gate.divergedSince(spokePool), uint32(block.timestamp), "armed");
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "armed but not sustained");

        vm.warp(block.timestamp + gate.divergenceSustainSeconds());
        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertTrue(gate_.diverged, "sustained");
        assertEq(uint8(gate_.state), uint8(GateState.DIVERGED), "diverged");
        assertEq(gate_.poolTick, fairTick + 700, "the observed tick");
        assertEq(gate_.fairTick, fairTick, "against the reference");

        (bool allowed,) = gate.isBondAllowed(constituentId);
        assertFalse(allowed, "that pool's bonds close");
        vm.expectRevert(abi.encodeWithSelector(IOracleGate.GateRefused.selector, GateState.DIVERGED, spokePool));
        gate.checkBond(constituentId);
        (allowed,) = gate.isPlacementAllowed(spokePool);
        assertFalse(allowed, "and its placements");
    }

    /// @notice A deviation that returns inside the band clears the verdict immediately, even before anybody
    ///         clears the timer: the armed timestamp alone can never hold a pool closed.
    function test_divergence_clearsOnItsOwn() public {
        marketRef.setObservation(spokePool, fairTick, fairTick + 700, 1800);
        gate.pokePool(spokePool);
        vm.warp(block.timestamp + gate.divergenceSustainSeconds());
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.DIVERGED), "diverged");

        marketRef.setObservation(spokePool, fairTick, fairTick, 1800);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "back in band, verdict gone");
        assertEq(
            gate.divergedSince(spokePool),
            uint32(block.timestamp - gate.divergenceSustainSeconds()),
            "timer still armed"
        );

        vm.expectEmit(true, false, false, true, address(gate));
        emit IOracleGate.DivergenceLatched(spokePool, 0, false);
        gate.pokePool(spokePool);
        assertEq(gate.divergedSince(spokePool), 0, "and the timer is cleared");
    }

    /// @notice A deviation exactly at the threshold does not arm; one basis point past it does.
    function test_divergence_thresholdIsExclusive() public {
        marketRef.setObservation(spokePool, fairTick, fairTick + int24(uint24(gate.divergenceBps())), 1800);
        gate.pokePool(spokePool);
        assertEq(gate.divergedSince(spokePool), 0, "exactly at the threshold is inside the band");

        marketRef.setObservation(spokePool, fairTick, fairTick + int24(uint24(gate.divergenceBps())) + 1, 1800);
        gate.pokePool(spokePool);
        assertGt(gate.divergedSince(spokePool), 0, "one tick past arms it");
    }

    /// @notice The breaker is symmetric: a pool trading below its reference arms exactly like one above it.
    function test_divergence_isSymmetric() public {
        marketRef.setObservation(spokePool, fairTick, fairTick - 700, 1800);
        gate.pokePool(spokePool);
        vm.warp(block.timestamp + gate.divergenceSustainSeconds());
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.DIVERGED), "below the reference");
    }

    /// @notice `pokePools` arms several pools in one transaction, and a zero pool id is a no-op.
    function test_divergence_pokePools() public {
        marketRef.setObservation(spokePool, fairTick, fairTick + 700, 1800);
        PoolId[] memory pools = new PoolId[](2);
        pools[0] = spokePool;
        pools[1] = PoolId.wrap(bytes32(0));
        vm.prank(STRANGER);
        gate.pokePools(pools);
        assertGt(gate.divergedSince(spokePool), 0, "armed");
    }

    /// @notice With no fair tick available — an unregistered pool, a missing feed or no tick source — the breaker
    ///         measures nothing and never arms.
    function test_divergence_noReferenceNeverArms() public {
        PoolId unknown = _poolId("nowhere");
        gate.pokePool(unknown);
        assertEq(gate.divergedSince(unknown), 0, "an unregistered pool measures nothing");

        marketRef.clear(spokePool);
        gate.pokePool(spokePool);
        assertEq(gate.divergedSince(spokePool), 0, "an unobserved pool measures nothing");
    }

    /// @notice Beyond the protocol's inner-band marker the hook's cap escalates, whatever the gate state is.
    function test_divergence_dynCapEscalates() public {
        marketRef.setObservation(
            spokePool, fairTick, fairTick + int24(uint24(Constants.PLACEMENT_DIVERGENCE_TICKS)) + 1, 1800
        );
        assertEq(gate.dynCapBps(spokePool), Constants.DYN_CAP_ESCALATION_BPS, "escalation");
        assertEq(uint8(gate.stateByPool(spokePool)), uint8(GateState.GREEN), "before the breaker arms");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Layer F: reference integrity
    // -------------------------------------------------------------------------------------------------------------

    /// @notice When the hub and the WETH route disagree by more than the tolerance the reference falls back to
    ///         NAV: placements continue, anchored at NAV, and nothing else changes.
    function test_refDiverged() public {
        GatePriceMath math = gate.priceMath();
        uint256 ampsUsd18 = math.ampsPriceUsd18(HUB_TICK, 1e8, 6);
        int24 wethTick = math.fairTick(ampsUsd18, 3000e8, 18, 1);
        marketRef.setObservation(wethPool, wethTick + 700, wethTick + 700, 1800);

        assertEq(uint8(gate.state(constituentId)), uint8(GateState.REF_DIVERGED), "ref diverged");
        (bool allowed, bool anchorAtNav) = gate.isPlacementAllowed(spokePool);
        assertTrue(allowed, "placements continue");
        assertTrue(anchorAtNav, "anchored at NAV");
        assertTrue(gate.checkPlacement(spokePool), "checkPlacement agrees");

        (allowed,) = gate.isBondAllowed(constituentId);
        assertTrue(allowed, "bonds continue");
        assertEq(gate.dynCapBps(spokePool), Constants.DYN_CAP_NORMAL_BPS, "the cap does not widen");
    }

    /// @notice A tolerance change moves the verdict, and the band is enforced.
    function test_refDiverged_toleranceIsGoverned() public {
        GatePriceMath math = gate.priceMath();
        uint256 ampsUsd18 = math.ampsPriceUsd18(HUB_TICK, 1e8, 6);
        int24 wethTick = math.fairTick(ampsUsd18, 3000e8, 18, 1);
        marketRef.setObservation(wethPool, wethTick + 700, wethTick + 700, 1800);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.REF_DIVERGED), "diverged at 500 bp");

        vm.prank(TIMELOCK);
        gate.setRefDivergenceBps(2000);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "not at 2000 bp");
    }

    /// @notice The WETH leg being unavailable is not a divergence: it only means the cross-check cannot be made.
    function test_refDiverged_missingWethLegIsNotDivergence() public {
        marketRef.clear(wethPool);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "no cross-check, no verdict");
    }

    /// @notice The hub's ring failing to cover the TWAP window is the "no observations" half of the watchdog.
    function test_refIntegrity_hubCoverageIsWatchdog() public {
        marketRef.setObservation(hubPool, HUB_TICK, HUB_TICK, 1799);
        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertTrue(gate_.watchdogTripped, "coverage counts as a watchdog trip");
        assertEq(uint8(gate_.state), uint8(GateState.WATCHDOG), "watchdog");
        (bool allowed,) = gate.isBondAllowed(constituentId);
        assertTrue(allowed, "and bonds still run");
    }

    /// @notice With no tick source at all the gate degrades to the watchdog rather than reverting.
    function test_refIntegrity_noMarketReference() public {
        vm.prank(TIMELOCK);
        gate.setMarketReference(address(0xBEEF));
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.WATCHDOG), "codeless reference");
    }

    /// @notice With no registry at all every constituent and pool read is empty, and the gate still answers.
    function test_noRegistry() public {
        OracleGate bare = new OracleGate(TIMELOCK, GUARDIAN, address(0), address(0), address(0));
        assertEq(uint8(bare.state(1)), uint8(GateState.WATCHDOG), "nothing to read");
        assertEq(uint8(bare.stateByPool(spokePool)), uint8(GateState.WATCHDOG), "by pool too");
        (bool allowed,) = bare.isBondAllowed(1);
        assertTrue(allowed, "and bonds are still not refused by a missing registry");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Guardian freezes
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A guardian freeze on one constituent closes its bonds and placements, leaves every other
    ///         constituent alone, and expires by itself.
    function test_guardian_freezeConstituent() public {
        uint32 until = uint32(block.timestamp + 1 days);
        vm.expectEmit(true, false, false, true, address(gate));
        emit IOracleGate.ConstituentFreezeSet(constituentId, until);
        vm.prank(GUARDIAN);
        gate.freezeConstituent(constituentId, until);

        assertEq(gate.constituentFreezeUntil(constituentId), until, "recorded");
        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertEq(uint8(gate_.state), uint8(GateState.SCHEDULED_FREEZE), "frozen");
        assertFalse(gate_.corporateFreeze, "a guardian freeze is not a corporate action");
        (bool allowed,) = gate.isBondAllowed(constituentId);
        assertFalse(allowed, "bonds refuse");
        assertEq(uint8(gate.state(0)), uint8(GateState.GREEN), "the protocol is untouched");

        vm.warp(until);
        gate.poke();
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "expires with no further action");
    }

    /// @notice A protocol freeze closes every constituent and the protocol-wide read, and expires by itself.
    function test_guardian_freezeProtocol() public {
        uint32 until = uint32(block.timestamp + 1 days);
        vm.expectEmit(false, false, false, true, address(gate));
        emit IOracleGate.ProtocolFreezeSet(until);
        vm.prank(GUARDIAN);
        gate.freezeProtocol(until);

        assertEq(gate.protocolFreezeUntil(), until, "recorded");
        assertEq(uint8(gate.state(0)), uint8(GateState.SCHEDULED_FREEZE), "protocol-wide");
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "and every constituent");
        (bool allowed,) = gate.isPlacementAllowed(spokePool);
        assertFalse(allowed, "placements refuse");

        vm.warp(until);
        gate.poke();
        assertEq(uint8(gate.state(0)), uint8(GateState.GREEN), "expires");
    }

    /// @notice A freeze must end, and must end inside `GUARDIAN_FREEZE_MAX_SECONDS`.
    function test_guardian_freezeWindowIsBounded() public {
        uint256 floorTs = block.timestamp + 1;
        uint256 ceilTs = block.timestamp + Constants.GUARDIAN_FREEZE_MAX_SECONDS;

        vm.startPrank(GUARDIAN);
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("freezeUntil"), block.timestamp, floorTs, ceilTs)
        );
        gate.freezeConstituent(constituentId, uint32(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("freezeUntil"), ceilTs + 1, floorTs, ceilTs));
        gate.freezeProtocol(uint32(ceilTs + 1));

        gate.freezeProtocol(uint32(ceilTs));
        vm.stopPrank();
        assertEq(gate.protocolFreezeUntil(), uint32(ceilTs), "the maximum is accepted");
    }

    /// @notice Only the guardian may freeze; the guardian or the timelock may clear early.
    function test_guardian_accessControl() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(NotGuardian.selector, STRANGER));
        gate.freezeProtocol(uint32(block.timestamp + 1 days));

        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(NotGuardian.selector, TIMELOCK));
        gate.freezeConstituent(constituentId, uint32(block.timestamp + 1 days));

        vm.prank(GUARDIAN);
        gate.freezeProtocol(uint32(block.timestamp + 1 days));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(NotGuardian.selector, STRANGER));
        gate.unfreezeProtocol();

        vm.prank(TIMELOCK);
        gate.unfreezeProtocol();
        assertEq(gate.protocolFreezeUntil(), 0, "the timelock may clear it");

        vm.prank(GUARDIAN);
        gate.freezeConstituent(constituentId, uint32(block.timestamp + 1 days));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(NotGuardian.selector, STRANGER));
        gate.unfreezeConstituent(constituentId);
        vm.prank(GUARDIAN);
        gate.unfreezeConstituent(constituentId);
        assertEq(gate.constituentFreezeUntil(constituentId), 0, "and so may the guardian");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Governed parameters
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Launch values, and the bands and getters the governance drill reads.
    function test_parameters_launchValuesAndBands() public view {
        assertEq(gate.graceSeconds(), Constants.GRACE_SECONDS_DEFAULT, "grace");
        assertEq(gate.gapSeconds(), Constants.GAP_SECONDS_DEFAULT, "gap");
        assertEq(gate.divergenceBps(), Constants.DIVERGENCE_BPS_DEFAULT, "divergence");
        assertEq(gate.divergenceSustainSeconds(), Constants.DIVERGENCE_SUSTAIN_SECONDS_DEFAULT, "sustain");
        assertEq(gate.corporateActionWindow(), Constants.CORPORATE_ACTION_WINDOW_DEFAULT, "ca window");
        assertEq(gate.refDivergenceBps(), Constants.REF_DIVERGENCE_BPS_DEFAULT, "ref divergence");
        assertEq(gate.hSessionBps(Session.REGULAR), Constants.H_SESSION_REGULAR_BPS_DEFAULT, "h regular");
        assertEq(gate.hSessionBps(Session.PRE_POST), Constants.H_SESSION_PRE_POST_BPS_DEFAULT, "h pre/post");
        assertEq(gate.hSessionBps(Session.OVERNIGHT), Constants.H_SESSION_OVERNIGHT_BPS_DEFAULT, "h overnight");
        assertEq(gate.hSessionBps(Session.CLOSED), Constants.H_SESSION_CLOSED_BPS_DEFAULT, "h closed");

        assertEq(gate.GRACE_SECONDS_MIN(), Constants.GRACE_SECONDS_MIN, "grace min");
        assertEq(gate.GRACE_SECONDS_MAX(), Constants.GRACE_SECONDS_MAX, "grace max");
        assertEq(gate.GAP_SECONDS_MAX(), Constants.GAP_SECONDS_MAX, "gap max");
        assertEq(gate.DIVERGENCE_BPS_MAX(), Constants.DIVERGENCE_BPS_MAX, "divergence max");
        assertEq(gate.DIVERGENCE_SUSTAIN_SECONDS_MAX(), Constants.DIVERGENCE_SUSTAIN_SECONDS_MAX, "sustain max");
        assertEq(gate.CORPORATE_ACTION_WINDOW_MAX(), Constants.CORPORATE_ACTION_WINDOW_MAX, "ca max");
        assertEq(gate.H_SESSION_BPS_MAX(), Constants.H_SESSION_BPS_MAX, "haircut max");
        assertEq(gate.GUARDIAN_FREEZE_MAX_SECONDS(), Constants.GUARDIAN_FREEZE_MAX_SECONDS, "freeze max");
        assertEq(gate.REF_DIVERGENCE_BPS_MIN(), Constants.REF_DIVERGENCE_BPS_MIN, "ref min");
        assertEq(gate.REF_DIVERGENCE_BPS_MAX(), Constants.REF_DIVERGENCE_BPS_MAX, "ref max");

        assertEq(gate.feedRegistry(), address(feeds), "feed registry");
        assertEq(gate.registry(), address(registry), "registry");
        assertEq(gate.marketReference(), address(marketRef), "market reference");
        assertEq(gate.timelock(), TIMELOCK, "timelock");
        assertEq(gate.guardian(), GUARDIAN, "guardian");
    }

    /// @notice Every scalar setter enforces its band and names its own parameter in the revert.
    function test_parameters_bands() public {
        vm.startPrank(TIMELOCK);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("graceSeconds"),
                uint256(Constants.GRACE_SECONDS_MIN - 1),
                uint256(Constants.GRACE_SECONDS_MIN),
                uint256(Constants.GRACE_SECONDS_MAX)
            )
        );
        gate.setGraceSeconds(Constants.GRACE_SECONDS_MIN - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("graceSeconds"),
                uint256(Constants.GRACE_SECONDS_MAX + 1),
                uint256(Constants.GRACE_SECONDS_MIN),
                uint256(Constants.GRACE_SECONDS_MAX)
            )
        );
        gate.setGraceSeconds(Constants.GRACE_SECONDS_MAX + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("gapSeconds"), uint256(0), uint256(1), uint256(Constants.GAP_SECONDS_MAX)
            )
        );
        gate.setGapSeconds(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("gapSeconds"),
                uint256(Constants.GAP_SECONDS_MAX + 1),
                uint256(1),
                uint256(Constants.GAP_SECONDS_MAX)
            )
        );
        gate.setGapSeconds(Constants.GAP_SECONDS_MAX + 1);

        // Layer A divides the elapsed time by the gap, so the two windows constrain each other: the grace window
        // must stay strictly wider than one expected block interval, from either side.
        gate.setGapSeconds(Constants.GAP_SECONDS_MAX);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("graceSeconds"),
                uint256(Constants.GRACE_SECONDS_MIN),
                uint256(Constants.GAP_SECONDS_MAX) + 1,
                uint256(Constants.GRACE_SECONDS_MAX)
            )
        );
        gate.setGraceSeconds(Constants.GRACE_SECONDS_MIN);

        gate.setGapSeconds(500);
        gate.setGraceSeconds(1000);
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("gapSeconds"), uint256(1000), uint256(1), uint256(999))
        );
        gate.setGapSeconds(1000);
        gate.setGraceSeconds(Constants.GRACE_SECONDS_DEFAULT);
        gate.setGapSeconds(Constants.GAP_SECONDS_DEFAULT);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("divergenceBps"),
                uint256(0),
                uint256(1),
                uint256(Constants.DIVERGENCE_BPS_MAX)
            )
        );
        gate.setDivergenceBps(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("divergenceSustainSeconds"),
                uint256(Constants.DIVERGENCE_SUSTAIN_SECONDS_MAX + 1),
                uint256(0),
                uint256(Constants.DIVERGENCE_SUSTAIN_SECONDS_MAX)
            )
        );
        gate.setDivergenceSustainSeconds(Constants.DIVERGENCE_SUSTAIN_SECONDS_MAX + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("corporateActionWindow"),
                uint256(Constants.CORPORATE_ACTION_WINDOW_MAX + 1),
                uint256(0),
                uint256(Constants.CORPORATE_ACTION_WINDOW_MAX)
            )
        );
        gate.setCorporateActionWindow(Constants.CORPORATE_ACTION_WINDOW_MAX + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("hSessionBps"),
                uint256(Constants.H_SESSION_BPS_MAX + 1),
                uint256(0),
                uint256(Constants.H_SESSION_BPS_MAX)
            )
        );
        gate.setHSessionBps(Session.REGULAR, Constants.H_SESSION_BPS_MAX + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("refDivergenceBps"),
                uint256(Constants.REF_DIVERGENCE_BPS_MIN - 1),
                uint256(Constants.REF_DIVERGENCE_BPS_MIN),
                uint256(Constants.REF_DIVERGENCE_BPS_MAX)
            )
        );
        gate.setRefDivergenceBps(Constants.REF_DIVERGENCE_BPS_MIN - 1);

        vm.stopPrank();
    }

    /// @notice Values inside the bands are accepted and read back, and every change is announced.
    function test_parameters_setters() public {
        vm.startPrank(TIMELOCK);
        vm.expectEmit(true, false, false, true, address(gate));
        emit IOracleGate.GateParameterChanged("graceSeconds", Constants.GRACE_SECONDS_DEFAULT, 7200);
        gate.setGraceSeconds(7200);
        gate.setGapSeconds(300);
        gate.setDivergenceBps(1000);
        gate.setDivergenceSustainSeconds(0);
        gate.setCorporateActionWindow(0);
        gate.setHSessionBps(Session.REGULAR, 100);
        gate.setHSessionBps(Session.PRE_POST, 200);
        gate.setHSessionBps(Session.CLOSED, 400);
        gate.setHSessionBps(Session.OVERNIGHT, 900);
        gate.setRefDivergenceBps(1500);
        gate.setFeedRegistry(address(0xF33D));
        gate.setRegistry(address(0x1E61));
        gate.setMarketReference(address(0x3EF));
        vm.stopPrank();

        assertEq(gate.graceSeconds(), 7200, "grace");
        assertEq(gate.gapSeconds(), 300, "gap");
        assertEq(gate.divergenceBps(), 1000, "divergence");
        assertEq(gate.divergenceSustainSeconds(), 0, "sustain");
        assertEq(gate.corporateActionWindow(), 0, "ca window");
        assertEq(gate.hSessionBps(Session.REGULAR), 100, "regular haircut");
        assertEq(gate.hSessionBps(Session.PRE_POST), 200, "pre/post haircut");
        assertEq(gate.hSessionBps(Session.OVERNIGHT), 900, "overnight haircut");
        assertEq(gate.hSessionBps(Session.CLOSED), 400, "closed haircut");
        assertEq(gate.refDivergenceBps(), 1500, "ref divergence");
        assertEq(gate.feedRegistry(), address(0xF33D), "feed registry");
        assertEq(gate.registry(), address(0x1E61), "registry");
        assertEq(gate.marketReference(), address(0x3EF), "market reference");
    }

    /// @notice Every governed setter is timelock-only, and the pointers refuse the zero address.
    function test_parameters_accessAndZeroAddress() public {
        vm.startPrank(STRANGER);
        bytes memory expected = abi.encodeWithSelector(NotTimelock.selector, STRANGER);
        vm.expectRevert(expected);
        gate.setGraceSeconds(7200);
        vm.expectRevert(expected);
        gate.setGapSeconds(300);
        vm.expectRevert(expected);
        gate.setDivergenceBps(1000);
        vm.expectRevert(expected);
        gate.setDivergenceSustainSeconds(30);
        vm.expectRevert(expected);
        gate.setCorporateActionWindow(60);
        vm.expectRevert(expected);
        gate.setRefDivergenceBps(600);
        vm.expectRevert(expected);
        gate.setHSessionBps(Session.REGULAR, 10);
        vm.expectRevert(expected);
        gate.setFeedRegistry(address(1));
        vm.expectRevert(expected);
        gate.setRegistry(address(1));
        vm.expectRevert(expected);
        gate.setMarketReference(address(1));
        vm.stopPrank();

        vm.startPrank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        gate.setFeedRegistry(address(0));
        vm.expectRevert(ZeroAddress.selector);
        gate.setRegistry(address(0));
        vm.expectRevert(ZeroAddress.selector);
        gate.setMarketReference(address(0));
        vm.stopPrank();
    }

    /// @notice A deployment helper reached through an external call, so `vm.expectRevert` swallows a reverting
    ///         constructor instead of ending the test at it.
    /// @param timelock_ The governor to deploy with.
    /// @param guardian_ The guardian to deploy with.
    /// @return deployed The new gate.
    function deployGate(address timelock_, address guardian_) external returns (address deployed) {
        return address(new OracleGate(timelock_, guardian_, address(0), address(0), address(0)));
    }

    /// @notice The constructor refuses a zero governor or guardian, and deploys its own price math.
    function test_constructor() public {
        vm.expectRevert(ZeroAddress.selector);
        this.deployGate(address(0), GUARDIAN);
        vm.expectRevert(ZeroAddress.selector);
        this.deployGate(TIMELOCK, address(0));
        assertGt(this.deployGate(TIMELOCK, GUARDIAN).code.length, 0, "and accepts a real pair");
        assertGt(address(gate.priceMath()).code.length, 0, "price math deployed");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Degradation: every bounded probe has a failure to survive
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A layer-C registry with no session-aware read still supplies the price: the gate falls back to the
    ///         plain `IFeedRegistry.latestAnswer` and pays for the session round trip instead of losing the feed.
    function test_degrade_legacyFeedRegistry() public {
        LegacyFeedRegistry legacy = new LegacyFeedRegistry();
        vm.prank(TIMELOCK);
        gate.setFeedRegistry(address(legacy));
        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertEq(gate_.answerUsd8, 180e8, "the fallback read answered");
        assertFalse(gate_.feedStale, "and reported fresh");
    }

    /// @notice A layer-C registry that answers nothing at all leaves the constituent with no price, which the
    ///         gate reports as stale rather than as a revert.
    function test_degrade_deadFeedRegistry() public {
        RevertingContract dead = new RevertingContract();
        vm.prank(TIMELOCK);
        gate.setFeedRegistry(address(dead));
        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertEq(gate_.answerUsd8, 0, "no price");
        assertTrue(gate_.feedStale, "stale");
        assertEq(uint8(gate_.state), uint8(GateState.WATCHDOG), "and the hub reference is gone too");
    }

    /// @notice A registry whose every read reverts leaves the gate with no constituent, no pool and no hub, and it
    ///         still answers every query.
    function test_degrade_revertingRegistry() public {
        RevertingContract broken = new RevertingContract();
        vm.prank(TIMELOCK);
        gate.setRegistry(address(broken));
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.WATCHDOG), "nothing readable");
        assertEq(uint8(gate.stateByPool(spokePool)), uint8(GateState.WATCHDOG), "by pool too");
        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        assertEq(gate_.answerUsd8, 0, "no constituent to price");
        assertEq(gate_.poolTick, 0, "and no pool to measure");
        gate.pokeConstituent(constituentId);
    }

    /// @notice Each of the market reference's four reads failing on its own degrades the gate to the watchdog
    ///         rather than reverting.
    function test_degrade_marketReferenceFailures() public {
        PartialMarketReference partialRef = new PartialMarketReference();
        partialRef.setTick(HUB_TICK);
        vm.prank(TIMELOCK);
        gate.setMarketReference(address(partialRef));

        partialRef.setFailures(true, false, false, false);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.WATCHDOG), "twapWindow");

        partialRef.setFailures(false, true, false, false);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.WATCHDOG), "observationCoverage");

        partialRef.setFailures(false, false, true, false);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.WATCHDOG), "twapTick");

        // With only `lastTruncatedTick` failing the reference is readable, so the gate is healthy again and the
        // breaker simply measures nothing.
        partialRef.setFailures(false, false, false, true);
        gate.pokePool(spokePool);
        assertEq(gate.divergedSince(spokePool), 0, "no pool tick, no arming");

        // And a market reference with no code at all is caught by the cheapest read of the four.
        vm.prank(TIMELOCK);
        gate.setMarketReference(address(0xDEADBEEF));
        gate.pokePool(spokePool);
        assertEq(gate.divergedSince(spokePool), 0, "still nothing to measure");
    }

    /// @notice A registry that answers for the hub but not for the WETH route leaves the cross-check unmade
    ///         rather than reverting: layer F degrades one leg at a time.
    function test_degrade_wethPoolIdUnreadable() public {
        vm.mockCallRevert(address(registry), abi.encodeWithSignature("wethPoolId()"), "");
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "no cross-check, no verdict");
        vm.clearMockedCalls();
    }

    /// @notice An unregistered hub pool is the same thing as no reference at all.
    function test_degrade_unregisteredHubPool() public {
        registry.unregisterPool(hubPool);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.WATCHDOG), "no hub, no reference");
    }

    /// @notice A hub whose counter asset has no feed cannot imply an AMPS price, which is the same degradation.
    function test_degrade_hubCounterWithoutFeed() public {
        registry.addEntryPool(hubPool, address(0xF00DFEE0), 6, TICK_SPACING, 30);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.WATCHDOG), "no USDG answer, no reference");
    }

    /// @notice A spoke whose counter asset has no feed has no fair tick, so the breaker measures nothing while
    ///         every other layer keeps working.
    function test_degrade_spokeCounterWithoutFeed() public {
        registry.setPool(
            spokePool,
            PoolConfig({
                counter: address(0xF00DFEE0),
                poolClass: PoolClass.SPOKE,
                counterDecimals: 18,
                tickSpacing: TICK_SPACING,
                buyFeeBps: 5,
                constituentId: constituentId,
                registered: true
            })
        );
        GateSnapshot memory gate_ = gate.snapshotByPool(spokePool);
        assertEq(gate_.fairTick, 0, "no fair tick");
        assertEq(uint8(gate_.state), uint8(GateState.GREEN), "and nothing else is affected");
    }

    /// @notice A price that `PriceLib` cannot express degrades to "no fair tick" and "no reference" rather than
    ///         reverting out of a view the hook depends on.
    function test_degrade_priceMathOutOfRange() public {
        // Decimals `PriceLib` refuses, set on the spoke only: the hub reference still works.
        registry.setPool(
            spokePool,
            PoolConfig({
                counter: address(nvda),
                poolClass: PoolClass.SPOKE,
                counterDecimals: 27,
                tickSpacing: TICK_SPACING,
                buyFeeBps: 5,
                constituentId: constituentId,
                registered: true
            })
        );
        GateSnapshot memory gate_ = gate.snapshotByPool(spokePool);
        assertEq(gate_.fairTick, 0, "no fair tick");
        assertEq(uint8(gate_.state), uint8(GateState.GREEN), "everything else still works");

        // The same refusal on the hub takes the whole reference with it.
        registry.addEntryPool(hubPool, USDG, 27, TICK_SPACING, 30);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.WATCHDOG), "no reference at all");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Precedence
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Several conditions can hold at once; the gate always reports the one that permits least.
    function test_precedence_mostRestrictiveWins() public {
        // Stale feed, missing coverage, divergence and a freeze, layered on one at a time.
        vm.prank(TIMELOCK);
        feeds.configureFeed(address(nvda), 300, 50, 1, type(uint128).max);
        vm.warp(block.timestamp + 451);
        gate.poke();
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.DEGRADED), "stale");

        marketRef.setObservation(hubPool, HUB_TICK, HUB_TICK, 1799);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.WATCHDOG), "watchdog beats degraded");

        marketRef.setObservation(hubPool, HUB_TICK, HUB_TICK, 1800);
        marketRef.setObservation(spokePool, fairTick, fairTick + 700, 1800);
        gate.pokePool(spokePool);
        vm.warp(block.timestamp + gate.divergenceSustainSeconds());
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.DIVERGED), "diverged beats degraded");

        vm.prank(GUARDIAN);
        gate.freezeConstituent(constituentId, uint32(block.timestamp + 1 days));
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "a freeze beats everything");
    }
}
