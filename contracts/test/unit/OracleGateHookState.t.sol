// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsHook} from "../../src/interfaces/IAmpsHook.sol";
import {IOracleGate} from "../../src/interfaces/IOracleGate.sol";
import {FeedRegistry} from "../../src/oracle/FeedRegistry.sol";
import {GatePriceMath} from "../../src/oracle/GatePriceMath.sol";
import {OracleGate} from "../../src/oracle/OracleGate.sol";
import {Constants} from "../../src/types/Constants.sol";
import {GateSnapshot, GateState, HookPoolState, PoolClass} from "../../src/types/Types.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockMarketReference} from "../mocks/MockMarketReference.sol";
import {MockPoolRegistry} from "../mocks/MockPoolRegistry.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {QuoterFaultProxy} from "../mocks/QuoterFaultProxy.sol";
import {QuoterHookStub} from "../mocks/QuoterHookStub.sol";
import {OracleGateFixture} from "./OracleGateFixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title OracleGateHookStateTest
/// @notice Ruling 10: layer D reads the hook's own corporate-action arm — `IAmpsHook.poolState(poolId).gateFlags`
///         bit 3 — and ORs it with the Stock Token probes, which stay as the fallback.
///
/// @dev **Why the hook is worth reading at all.** The gate is a `view`: it only sees a corporate action when
///      somebody calls it, and what it sees is whatever the token's four issuer views say at that instant. The
///      hook sees `uiMultiplier()` on every gate-cache refresh, which is to say on every pool that is being
///      traded, and arms bit 3 when a step exceeds `Constants.DIVIDEND_STEP_BPS_MAX`. Reading that arm gives
///      layer D a detector with the *pool's* cadence rather than the caller's. The two sources are ORed and
///      neither can clear the other.
///
/// @dev **Bit 3 and not bit 1.** Bit 1 of the same word is `corporateFreeze`, which is the hook's cache of this
///      gate's own verdict. Reading it back would close a loop and latch `SCHEDULED_FREEZE` forever;
///      {test_hookFlag_isBitThreeNotBitOne} is what pins that the loop is not closed.
///
/// @dev The existing `OracleGate` suite is untouched. It runs against `MockMarketReference`, which has no
///      `poolState` at all, so every one of its 56 tests exercises the fallback path by construction and none of
///      them needed a change.
contract OracleGateHookStateTest is OracleGateFixture {
    /// @dev Monday 2026-03-09, 14:30 UTC = 09:30 ET, the first second of a regular session.
    uint256 internal constant MON_REGULAR = 1_773_063_000;

    /// @dev The hub tick at which AMPS is $1.00 against 6-decimal USDG at $1.00.
    int24 internal constant HUB_TICK = -276_360;

    int24 internal constant TICK_SPACING = 60;

    address internal constant USDG = address(0x5D6);
    address internal constant WETH = address(0x9E7);

    /// @dev Bit 3 of `HookPoolState.gateFlags`, the hook's own multiplier-step arm.
    uint8 internal constant CA_ARMED = 0x08;

    /// @dev Bits 0, 1 and 2: degraded, `corporateFreeze` (the hook's cache of *this* contract's verdict) and
    ///      `refreshFailed`. None of them is a corporate action the gate may act on.
    uint8 internal constant NOT_CA_FLAGS = 0x07;

    QuoterHookStub internal hookRef;

    PoolId internal hubPool;
    PoolId internal wethPool;
    PoolId internal spokePool;
    PoolId internal otherPool;

    MockStockToken internal nvda;
    MockStockToken internal aapl;

    uint16 internal constituentId;
    uint16 internal otherConstituentId;

    int24 internal nvdaTick;
    int24 internal wethTick;

    function setUp() public {
        vm.warp(MON_REGULAR);
        vm.roll(1_000_000);

        // The Phase 2 fixture wires `MockMarketReference`, which has no `poolState`; ruling 10 needs a market
        // reference that is a hook, so the deployment is done here instead of through `_deployGate`.
        registry = new MockPoolRegistry();
        marketRef = new MockMarketReference();
        hookRef = new QuoterHookStub();
        feeds = new FeedRegistry(TIMELOCK, address(0));
        gate = new OracleGate(TIMELOCK, GUARDIAN, address(feeds), address(registry), address(hookRef));
        vm.prank(TIMELOCK);
        feeds.setOracleGate(address(gate));
        _installCalendar();

        hubPool = _poolId("AMPS/USDG");
        wethPool = _poolId("AMPS/WETH");
        spokePool = _poolId("AMPS/NVDA");
        otherPool = _poolId("AMPS/AAPL");

        _installFeed(USDG, 1e8, Constants.ONE_DAY);
        _installFeed(WETH, 3000e8, Constants.ONE_DAY);
        nvda = _stockToken("NVDA");
        aapl = _stockToken("AAPL");
        _installFeed(address(nvda), 180e8, Constants.ONE_DAY);
        _installFeed(address(aapl), 220e8, Constants.ONE_DAY);

        registry.addEntryPool(hubPool, USDG, 6, TICK_SPACING, 30);
        registry.addEntryPool(wethPool, WETH, 18, TICK_SPACING, 30);
        registry.setHubPoolId(hubPool);
        registry.setWethPoolId(wethPool);
        constituentId =
            registry.addConstituentAndPool(address(nvda), address(0), spokePool, PoolClass.SPOKE, TICK_SPACING, 1000);
        otherConstituentId =
            registry.addConstituentAndPool(address(aapl), address(0), otherPool, PoolClass.SPOKE, TICK_SPACING, 1000);

        GatePriceMath math = GatePriceMath(gate.priceMath());
        uint256 ampsUsd18 = math.ampsPriceUsd18(HUB_TICK, 1e8, 6);
        nvdaTick = math.fairTick(ampsUsd18, 180e8, 18, TICK_SPACING);
        int24 aaplTick = math.fairTick(ampsUsd18, 220e8, 18, TICK_SPACING);
        wethTick = math.fairTick(ampsUsd18, 3000e8, 18, TICK_SPACING);

        hookRef.setTwapWindow(Constants.TWAP_WINDOW_DEFAULT);
        hookRef.setObservation(hubPool, HUB_TICK, HUB_TICK, Constants.TWAP_WINDOW_DEFAULT);
        hookRef.setObservation(wethPool, wethTick, wethTick, Constants.TWAP_WINDOW_DEFAULT);
        hookRef.setObservation(spokePool, nvdaTick, nvdaTick, Constants.TWAP_WINDOW_DEFAULT);
        hookRef.setObservation(otherPool, aaplTick, aaplTick, Constants.TWAP_WINDOW_DEFAULT);
        hookRef.initPool(spokePool, PoolClass.SPOKE, 18, TICK_SPACING, 5);
        hookRef.initPool(otherPool, PoolClass.SPOKE, 18, TICK_SPACING, 5);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Both sources clear
    // -------------------------------------------------------------------------------------------------------------

    /// @notice With the hook's arm down and the token quiet, the constituent is green and bonds price normally.
    function test_bothSourcesClear_isGreen() public view {
        GateSnapshot memory snapshot = gate.snapshot(constituentId);
        assertFalse(snapshot.corporateFreeze, "no corporate action");
        assertEq(uint8(snapshot.state), uint8(GateState.GREEN), "green");
        assertEq(gate.checkBond(constituentId), Constants.H_SESSION_REGULAR_BPS_DEFAULT, "bonds open at no haircut");
        (bool allowed,) = gate.isPlacementAllowed(spokePool);
        assertTrue(allowed, "placements open");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The hook's arm
    // -------------------------------------------------------------------------------------------------------------

    /// @notice An armed hook flag is a corporate-action freeze for that constituent: no bonds, no placements.
    function test_hookFlag_freezesTheConstituent() public {
        hookRef.setGateFlags(spokePool, CA_ARMED);

        GateSnapshot memory snapshot = gate.snapshot(constituentId);
        assertTrue(snapshot.corporateFreeze, "the hook's arm is a corporate action");
        assertEq(uint8(snapshot.state), uint8(GateState.SCHEDULED_FREEZE), "frozen");

        (bool bondAllowed,) = gate.isBondAllowed(constituentId);
        assertFalse(bondAllowed, "no bonds");
        vm.expectRevert(abi.encodeWithSelector(IOracleGate.GateRefused.selector, GateState.SCHEDULED_FREEZE, spokePool));
        gate.checkBond(constituentId);

        (bool placementAllowed,) = gate.isPlacementAllowed(spokePool);
        assertFalse(placementAllowed, "no placements");
        vm.expectRevert(abi.encodeWithSelector(IOracleGate.GateRefused.selector, GateState.SCHEDULED_FREEZE, spokePool));
        gate.checkPlacement(spokePool);
    }

    /// @notice The freeze is scoped to the constituent whose spoke carries the flag, and to nothing else.
    function test_hookFlag_scopesToOneConstituent() public {
        hookRef.setGateFlags(spokePool, CA_ARMED);

        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "the flagged constituent");
        assertEq(uint8(gate.state(otherConstituentId)), uint8(GateState.GREEN), "its neighbour is untouched");
        assertEq(uint8(gate.state(0)), uint8(GateState.GREEN), "and so is the protocol-wide read");

        (bool otherAllowed,) = gate.isBondAllowed(otherConstituentId);
        assertTrue(otherAllowed, "the other market stays open");
        (bool entryAllowed,) = gate.isPlacementAllowed(hubPool);
        assertTrue(entryAllowed, "and the entry pools stay open");
    }

    /// @notice **The feedback test.** Bits 0, 1 and 2 are not corporate actions. Bit 1 in particular is the hook's
    ///         cache of this gate's own verdict, and reading it back would latch `SCHEDULED_FREEZE` for good.
    function test_hookFlag_isBitThreeNotBitOne() public {
        hookRef.setGateFlags(spokePool, NOT_CA_FLAGS);
        assertFalse(gate.snapshot(constituentId).corporateFreeze, "degraded, cached and failed are not freezes");
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "still green");

        hookRef.setGateFlags(spokePool, NOT_CA_FLAGS | CA_ARMED);
        assertTrue(gate.snapshot(constituentId).corporateFreeze, "and bit 3 alongside them still arms");
    }

    /// @notice A pool the hook has never initialised cannot arm anything, whatever its flags word says.
    function test_hookFlag_ignoredOnAnUninitializedPool() public {
        hookRef.setPoolState(spokePool, _uninitializedStateWithFlags(CA_ARMED));
        assertFalse(gate.snapshot(constituentId).corporateFreeze, "an uninitialised pool arms nothing");
    }

    /// @notice The flag clears the moment the hook lowers it: layer D stores no verdict of its own.
    function test_hookFlag_clearsWithoutAKeeper() public {
        hookRef.setGateFlags(spokePool, CA_ARMED);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "frozen");
        hookRef.setGateFlags(spokePool, 0);
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "and green again, with no poke");
    }

    /// @notice {pokeConstituent} reports the hook's arm through `CorporateActionFreeze`, so the indexer sees it.
    function test_hookFlag_isReportedByPokeConstituent() public {
        hookRef.setGateFlags(spokePool, CA_ARMED);
        vm.expectEmit(true, false, false, true, address(gate));
        emit IOracleGate.CorporateActionFreeze(constituentId, true, 0);
        gate.pokeConstituent(constituentId);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The token probes are still the fallback
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A market reference that is not a hook — the Phase 2 mock, or any mis-pointed address — leaves layer
    ///         D exactly as it was: the token probes decide.
    function test_fallback_marketReferenceIsNotAHook() public {
        vm.prank(TIMELOCK);
        gate.setMarketReference(address(marketRef));
        marketRef.setObservation(hubPool, HUB_TICK, HUB_TICK, Constants.TWAP_WINDOW_DEFAULT);
        marketRef.setObservation(wethPool, wethTick, wethTick, Constants.TWAP_WINDOW_DEFAULT);
        marketRef.setObservation(spokePool, nvdaTick, nvdaTick, Constants.TWAP_WINDOW_DEFAULT);

        assertFalse(gate.snapshot(constituentId).corporateFreeze, "nothing to read, nothing armed");

        nvda.setOraclePaused(true);
        assertTrue(gate.snapshot(constituentId).corporateFreeze, "and the token probe still freezes");
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "frozen");
    }

    /// @notice A market reference with no code at all.
    function test_fallback_marketReferenceHasNoCode() public {
        vm.prank(TIMELOCK);
        gate.setMarketReference(makeAddr("not a contract"));
        assertFalse(gate.snapshot(constituentId).corporateFreeze, "no code, no arm");
        nvda.setOraclePaused(true);
        assertTrue(gate.snapshot(constituentId).corporateFreeze, "the token probe is untouched");
    }

    /// @notice Every way ruling 10's own read can fail — a revert with or without a reason, an empty answer, a
    ///         short answer, a burnt gas allowance, a returndata flood — leaves the arm down and the token probes
    ///         deciding, which is the fallback the ruling requires.
    /// @dev The proxy is filtered to `poolState` alone, so the rest of the gate's reads stay healthy and the
    ///      assertion is about this read and nothing else. Filtering is not cosmetic: see
    ///      {test_wholeReferenceMisbehaving_isBoundedToRevertsOnly} for what the *unfiltered* case still cannot
    ///      survive, and the `// BUG:` note in `OracleGate._twapTick` for why.
    function test_fallback_poolStateMisbehaves() public {
        QuoterFaultProxy proxy = new QuoterFaultProxy(address(hookRef));
        proxy.setFaultySelector(IAmpsHook.poolState.selector);
        vm.prank(TIMELOCK);
        gate.setMarketReference(address(proxy));
        hookRef.setGateFlags(spokePool, CA_ARMED);

        QuoterFaultProxy.Mode[6] memory modes = [
            QuoterFaultProxy.Mode.REVERT_EMPTY,
            QuoterFaultProxy.Mode.REVERT_REASON,
            QuoterFaultProxy.Mode.EMPTY,
            QuoterFaultProxy.Mode.SHORT,
            QuoterFaultProxy.Mode.OUT_OF_GAS,
            QuoterFaultProxy.Mode.BOMB
        ];
        for (uint256 i = 0; i < modes.length; ++i) {
            proxy.setMode(modes[i]);
            assertFalse(gate.snapshot(constituentId).corporateFreeze, "an unreadable hook arms nothing");
            assertEq(uint8(gate.state(constituentId)), uint8(GateState.GREEN), "and the gate stays open");

            nvda.setOraclePaused(true);
            assertTrue(gate.snapshot(constituentId).corporateFreeze, "the token probe still decides");
            assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "frozen by the token");
            nvda.setOraclePaused(false);
        }
    }

    /// @notice A market reference whose *every* read reverts or burns its gas is survived whole: the gate reports
    ///         `WATCHDOG` for want of a reference and the token probes still close the constituent.
    /// @dev The three modes here are the ones Phase 2's typed `try` reads can absorb. `EMPTY`, `SHORT` and
    ///      `WORD_SOUP` on the *whole* reference make the pre-existing `twapWindow`/`twapTick` decode raise an
    ///      uncatchable `Panic`; that is recorded as a `// BUG:` in `OracleGate._twapTick` and is not introduced,
    ///      touched or fixed by ruling 10, whose own read unpacks by hand and survives all six.
    function test_wholeReferenceMisbehaving_isBoundedToRevertsOnly() public {
        QuoterFaultProxy proxy = new QuoterFaultProxy(address(hookRef));
        vm.prank(TIMELOCK);
        gate.setMarketReference(address(proxy));
        hookRef.setGateFlags(spokePool, CA_ARMED);

        QuoterFaultProxy.Mode[3] memory modes =
            [QuoterFaultProxy.Mode.REVERT_EMPTY, QuoterFaultProxy.Mode.REVERT_REASON, QuoterFaultProxy.Mode.OUT_OF_GAS];
        for (uint256 i = 0; i < modes.length; ++i) {
            proxy.setMode(modes[i]);
            assertFalse(gate.snapshot(constituentId).corporateFreeze, "no arm");
            assertEq(uint8(gate.state(constituentId)), uint8(GateState.WATCHDOG), "no reference at all");

            nvda.setOraclePaused(true);
            assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "the token probe decides");
            nvda.setOraclePaused(false);
        }
    }

    /// @notice A `poolState` that answers with a full-length word soup is read as **armed**.
    /// @dev Documented rather than defended against. `poolState` is not authenticated and cannot be: a caller
    ///      given 25 words of `0xff` cannot tell them from a hook reporting an initialised pool with every flag
    ///      set. What the gate controls is the *direction* of the ambiguity, and for a freeze the safe direction
    ///      is closed: garbage suspends bonds and placements for one constituent, which governance can lift by
    ///      re-pointing the market reference, and can never open anything that was shut. The pointer is a 7-day
    ///      timelocked address, not user input.
    function test_wordSoupIsReadAsArmed() public {
        QuoterFaultProxy proxy = new QuoterFaultProxy(address(hookRef));
        proxy.setFaultySelector(IAmpsHook.poolState.selector);
        vm.prank(TIMELOCK);
        gate.setMarketReference(address(proxy));
        proxy.setMode(QuoterFaultProxy.Mode.WORD_SOUP);

        assertTrue(gate.snapshot(constituentId).corporateFreeze, "garbage fails closed for a freeze");
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "frozen");
        assertEq(uint8(gate.state(0)), uint8(GateState.GREEN), "and never protocol-wide");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The two sources OR
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Either source alone freezes, both together freeze, and neither can clear the other.
    /// @param armHook Whether the hook's arm is up.
    /// @param pauseToken Whether the token reports `oraclePaused()`.
    function testFuzz_sourcesAreOred(bool armHook, bool pauseToken) public {
        hookRef.setGateFlags(spokePool, armHook ? CA_ARMED : 0);
        nvda.setOraclePaused(pauseToken);

        bool expected = armHook || pauseToken;
        assertEq(gate.snapshot(constituentId).corporateFreeze, expected, "OR");
        assertEq(
            uint8(gate.state(constituentId)),
            uint8(expected ? GateState.SCHEDULED_FREEZE : GateState.GREEN),
            "and the state follows it"
        );
    }

    /// @notice The registry's governance-forced override still stands on its own, ahead of both sources.
    function test_registryOverrideStillFreezes() public {
        registry.setCaFreezeOverride(constituentId, true);
        assertTrue(gate.snapshot(constituentId).corporateFreeze, "forced");
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "frozen");
    }

    /// @dev A `HookPoolState` with `initialized == false` and a chosen flags word.
    function _uninitializedStateWithFlags(uint8 flags) private pure returns (HookPoolState memory state) {
        state.gateFlags = flags;
    }
}
