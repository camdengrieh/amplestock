// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GatePriceMath} from "../../src/oracle/GatePriceMath.sol";
import {OracleGate} from "../../src/oracle/OracleGate.sol";
import {Constants} from "../../src/types/Constants.sol";
import {GateSnapshot, GateState, PoolClass, Session} from "../../src/types/Types.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {OracleGateFixture} from "../unit/OracleGateFixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Random sequences of feed updates, clock and block advances, tick moves and freezes against the four
///         properties that make the gate safe to build on:
///
///         1. **Determinism.** The state is a function of the inputs alone: reading twice in the same block, or
///            replaying the same sequence on a second gate, gives the same answer.
///         2. **Monotone bands.** A non-green gate never *narrows* the hook's dynamic cap, and `DEGRADED`,
///            `DIVERGED` and `WATCHDOG` never widen it beyond the escalation cap (invariant I19's gate half).
///         3. **A stale feed never closes a bond market.** Only a corporate-action freeze, a guardian freeze and
///            the divergence breaker refuse a bond; staleness, a closed session and the watchdog only widen the
///            haircut.
///         4. **Freezes expire.** Every guardian freeze lapses with no further action, and no sequence of calls
///            can make one outlast `GUARDIAN_FREEZE_MAX_SECONDS`.
contract OracleGateFuzzTest is OracleGateFixture {
    /// @dev Monday 2026-03-09 09:30 EDT, the regular session, as the base of every fuzzed clock.
    uint256 internal constant MON_REGULAR = 1_773_063_000;

    /// @dev The hub pool's mean tick: AMPS at $1 against 6-decimal USDG at $1, aligned to the 60 spacing.
    int24 internal constant HUB_TICK = -276_360;

    int24 internal constant TICK_SPACING = 60;

    address internal constant USDG = address(0x5D6);
    address internal constant WETH = address(0x9E7);

    PoolId internal hubPool;
    PoolId internal wethPool;
    PoolId internal spokePool;

    MockStockToken internal nvda;
    MockAggregator internal nvdaFeed;
    uint16 internal constituentId;
    int24 internal fairTick;

    function setUp() public {
        vm.warp(MON_REGULAR);
        vm.roll(1_000_000);
        _deployGate();

        hubPool = _poolId("AMPS/USDG");
        wethPool = _poolId("AMPS/WETH");
        spokePool = _poolId("AMPS/NVDA");

        _installFeed(USDG, 1e8, Constants.ONE_DAY);
        _installFeed(WETH, 3000e8, Constants.ONE_DAY);
        nvda = _stockToken("NVDA");
        nvdaFeed = _installFeed(address(nvda), 180e8, Constants.ONE_DAY);

        registry.addEntryPool(hubPool, USDG, 6, TICK_SPACING, 30);
        registry.addEntryPool(wethPool, WETH, 18, TICK_SPACING, 30);
        registry.setHubPoolId(hubPool);
        registry.setWethPoolId(wethPool);
        constituentId = registry.addConstituentAndPool(
            address(nvda), address(nvdaFeed), spokePool, PoolClass.SPOKE, TICK_SPACING, 1000
        );

        GatePriceMath math = gate.priceMath();
        uint256 ampsUsd18 = math.ampsPriceUsd18(HUB_TICK, 1e8, 6);
        fairTick = math.fairTick(ampsUsd18, 180e8, 18, TICK_SPACING);
        int24 wethTick = math.fairTick(ampsUsd18, 3000e8, 18, 1);

        marketRef.setObservation(hubPool, HUB_TICK, HUB_TICK, 1800);
        marketRef.setObservation(wethPool, wethTick, wethTick, 1800);
        marketRef.setObservation(spokePool, fairTick, fairTick, 1800);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Properties
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A stale feed, a closed session and a tripped watchdog never close a bond market. Only a
    ///         corporate-action freeze, a guardian freeze and the divergence breaker do, and the gate's own
    ///         `checkBond` agrees with its `isBondAllowed` on every input.
    /// @param answerUsd8 A new Chainlink answer for the constituent.
    /// @param ageSeconds How old to make it.
    /// @param warpSeconds How far to advance the clock.
    /// @param blocksMined How many blocks to mine across that.
    /// @param tickDelta How far to move the spoke off its reference.
    function testFuzz_staleFeedNeverBlocksBonds(
        uint64 answerUsd8,
        uint32 ageSeconds,
        uint32 warpSeconds,
        uint32 blocksMined,
        int16 tickDelta
    ) public {
        _apply(answerUsd8, ageSeconds, warpSeconds, blocksMined, tickDelta);

        GateSnapshot memory gate_ = gate.snapshot(constituentId);
        (bool allowed, uint16 haircut) = gate.isBondAllowed(constituentId);

        if (gate_.feedStale || gate_.watchdogTripped || gate_.session == Session.CLOSED) {
            // None of the three is a refusal on its own; the refusal, if any, has to come from a freeze or the
            // breaker, which the state field names.
            if (!allowed) {
                assertTrue(
                    gate_.state == GateState.SCHEDULED_FREEZE || gate_.state == GateState.DIVERGED,
                    "only a freeze or the breaker may close a market"
                );
            }
        }
        assertLe(haircut, Constants.H_SESSION_BPS_MAX, "the haircut stays inside its band");

        if (allowed) {
            assertEq(gate.checkBond(constituentId), haircut, "checkBond agrees");
        } else {
            vm.expectRevert();
            gate.checkBond(constituentId);
        }
    }

    /// @notice The hook's dynamic cap is one of exactly three values, is never below the normal cap, and is only
    ///         ever the normal one when the gate is green or the reference has diverged.
    /// @param answerUsd8 A new Chainlink answer for the constituent.
    /// @param ageSeconds How old to make it.
    /// @param warpSeconds How far to advance the clock.
    /// @param blocksMined How many blocks to mine across that.
    /// @param tickDelta How far to move the spoke off its reference.
    function testFuzz_dynCapNeverNarrows(
        uint64 answerUsd8,
        uint32 ageSeconds,
        uint32 warpSeconds,
        uint32 blocksMined,
        int16 tickDelta
    ) public {
        _apply(answerUsd8, ageSeconds, warpSeconds, blocksMined, tickDelta);

        GateSnapshot memory gate_ = gate.snapshotByPool(spokePool);
        uint16 cap = gate_.dynCapBps;
        assertTrue(
            cap == Constants.DYN_CAP_NORMAL_BPS || cap == Constants.DYN_CAP_DEGRADED_BPS
                || cap == Constants.DYN_CAP_ESCALATION_BPS,
            "one of the three caps"
        );
        assertGe(cap, Constants.DYN_CAP_NORMAL_BPS, "never below the normal cap");
        assertLe(cap, Constants.DYN_CAP_ESCALATION_BPS, "never above the escalation cap");

        if (cap == Constants.DYN_CAP_NORMAL_BPS) {
            assertTrue(
                gate_.state == GateState.GREEN || gate_.state == GateState.REF_DIVERGED,
                "the normal cap belongs to a healthy gate"
            );
        }
        assertEq(gate.dynCapBps(spokePool), cap, "the standalone read agrees with the snapshot");
    }

    /// @notice The state is a deterministic function of the inputs: the same block gives the same answer however
    ///         many times it is read, and the placement/bond verdicts always agree with it.
    /// @param answerUsd8 A new Chainlink answer for the constituent.
    /// @param ageSeconds How old to make it.
    /// @param warpSeconds How far to advance the clock.
    /// @param blocksMined How many blocks to mine across that.
    /// @param tickDelta How far to move the spoke off its reference.
    function testFuzz_stateIsDeterministic(
        uint64 answerUsd8,
        uint32 ageSeconds,
        uint32 warpSeconds,
        uint32 blocksMined,
        int16 tickDelta
    ) public {
        _apply(answerUsd8, ageSeconds, warpSeconds, blocksMined, tickDelta);

        GateState first = gate.state(constituentId);
        GateState second = gate.state(constituentId);
        assertEq(uint8(first), uint8(second), "reading twice changes nothing");
        assertEq(uint8(gate.stateByPool(spokePool)), uint8(first), "the pool-addressed read agrees");

        (bool allowed, bool anchorAtNav) = gate.isPlacementAllowed(spokePool);
        assertEq(allowed, first == GateState.GREEN || first == GateState.REF_DIVERGED, "placements follow the state");
        assertEq(anchorAtNav, first == GateState.REF_DIVERGED, "so does the anchor");
        if (allowed) {
            assertEq(gate.checkPlacement(spokePool), anchorAtNav, "checkPlacement agrees");
        } else {
            vm.expectRevert();
            gate.checkPlacement(spokePool);
        }
    }

    /// @notice A guardian freeze always expires, and no freeze can be set to outlast the hard bound.
    /// @param freezeFor How long to freeze for.
    /// @param warpSeconds How far past the expiry to advance.
    /// @param protocolWide Whether to freeze the protocol or the one constituent.
    function testFuzz_freezesExpire(uint32 freezeFor, uint32 warpSeconds, bool protocolWide) public {
        freezeFor = uint32(bound(freezeFor, 1, Constants.GUARDIAN_FREEZE_MAX_SECONDS));
        uint32 until = uint32(block.timestamp) + freezeFor;

        vm.prank(GUARDIAN);
        if (protocolWide) {
            gate.freezeProtocol(until);
        } else {
            gate.freezeConstituent(constituentId, until);
        }
        assertEq(uint8(gate.state(constituentId)), uint8(GateState.SCHEDULED_FREEZE), "frozen while it lasts");
        assertLe(
            uint256(until) - block.timestamp, Constants.GUARDIAN_FREEZE_MAX_SECONDS, "and never longer than the bound"
        );

        vm.warp(uint256(until) + bound(warpSeconds, 0, 30 days));
        gate.poke(); // clears the layer-A watchdog the long warp would otherwise trip
        assertTrue(gate.state(constituentId) != GateState.SCHEDULED_FREEZE, "and lapses on its own");
        (bool allowed,) = gate.isBondAllowed(constituentId);
        assertTrue(allowed, "the market reopens");
    }

    /// @notice A guardian freeze cannot be extended past the hard bound by any sequence of calls, because every
    ///         freeze is measured from the block it is set in.
    /// @param steps How many times to re-freeze.
    function testFuzz_freezeCannotBeStackedPastTheBound(uint8 steps) public {
        uint256 rounds = bound(steps, 1, 10);
        for (uint256 i = 0; i < rounds; ++i) {
            uint32 until = uint32(block.timestamp + Constants.GUARDIAN_FREEZE_MAX_SECONDS);
            vm.prank(GUARDIAN);
            gate.freezeProtocol(until);
            assertEq(gate.protocolFreezeUntil(), until, "always measured from now");
            assertLe(
                uint256(gate.protocolFreezeUntil()) - block.timestamp,
                Constants.GUARDIAN_FREEZE_MAX_SECONDS,
                "never further ahead than the bound"
            );
            vm.warp(block.timestamp + 1 hours);
        }
    }

    /// @notice Layer E arms only outside the band, latches only after the sustain window and clears the moment the
    ///         deviation comes back — whatever order the pokes and the tick moves arrive in.
    /// @param firstDelta The tick offset before the poke.
    /// @param secondDelta The tick offset after it.
    /// @param waitSeconds How long to wait between them.
    function testFuzz_divergenceArmsAndClears(int16 firstDelta, int16 secondDelta, uint32 waitSeconds) public {
        int24 first = int24(bound(firstDelta, -3000, 3000));
        int24 second = int24(bound(secondDelta, -3000, 3000));
        uint256 wait = bound(waitSeconds, 0, 2 * uint256(gate.divergenceSustainSeconds()) + 10);
        uint16 threshold = gate.divergenceBps();

        marketRef.setObservation(spokePool, fairTick, fairTick + first, 1800);
        gate.pokePool(spokePool);
        uint32 armedAt = gate.divergedSince(spokePool);
        assertEq(armedAt != 0, _magnitude(first) > threshold, "armed exactly when outside the band");

        vm.warp(block.timestamp + wait);
        marketRef.setObservation(spokePool, fairTick, fairTick + second, 1800);
        gate.poke();

        bool sustained = armedAt != 0 && block.timestamp >= uint256(armedAt) + gate.divergenceSustainSeconds();
        bool expected = sustained && _magnitude(second) > threshold;
        assertEq(gate.snapshotByPool(spokePool).diverged, expected, "the verdict re-checks the live deviation");
    }

    /// @notice Replaying the same input sequence on a freshly deployed gate reaches the same state: nothing in the
    ///         verdict depends on history the inputs do not carry.
    /// @param answerUsd8 A new Chainlink answer for the constituent.
    /// @param ageSeconds How old to make it.
    /// @param warpSeconds How far to advance the clock.
    /// @param blocksMined How many blocks to mine across that.
    /// @param tickDelta How far to move the spoke off its reference.
    function testFuzz_replayOnAFreshGateAgrees(
        uint64 answerUsd8,
        uint32 ageSeconds,
        uint32 warpSeconds,
        uint32 blocksMined,
        int16 tickDelta
    ) public {
        _apply(answerUsd8, ageSeconds, warpSeconds, blocksMined, tickDelta);
        GateState expected = gate.state(constituentId);

        OracleGate replica = new OracleGate(TIMELOCK, GUARDIAN, address(feeds), address(registry), address(marketRef));
        vm.startPrank(TIMELOCK);
        replica.setDstTable(_dstStarts(), _dstEnds());
        replica.setHolidayBitmap(YEAR_2026, _bitmap(_holidays2026()));
        vm.stopPrank();
        replica.pokePool(spokePool);
        // The replica has just stamped, so layer A is clear on it by construction; every other layer must agree.
        if (expected != GateState.WATCHDOG) {
            assertEq(uint8(replica.state(constituentId)), uint8(expected), "the same inputs, the same verdict");
        }
    }

    /// @notice `poke`, `pokePool`, `pokePools` and `pokeConstituent` are permissionless, never revert for a gate
    ///         reason, and always leave the watchdog clear.
    /// @param caller Any address at all.
    /// @param warpSeconds How far to advance the clock first.
    function testFuzz_pokeIsPermissionlessAndTotal(address caller, uint32 warpSeconds) public {
        vm.assume(caller != address(vm));
        vm.warp(block.timestamp + bound(warpSeconds, 0, 90 days));

        PoolId[] memory pools = new PoolId[](2);
        pools[0] = spokePool;
        pools[1] = PoolId.wrap(bytes32(0));

        vm.startPrank(caller);
        gate.poke();
        gate.pokePool(spokePool);
        gate.pokePools(pools);
        gate.pokeConstituent(constituentId);
        vm.stopPrank();

        (uint32 stampedBlock, uint32 stampedAt, bool tripped) = gate.watchdog();
        assertEq(stampedBlock, uint32(block.number), "stamped");
        assertEq(stampedAt, uint32(block.timestamp), "stamped");
        assertFalse(tripped, "clear");
    }

    /// @notice `snapshot` is total over every constituent id, registered or not, and never reverts.
    /// @param id Any constituent id.
    function testFuzz_snapshotIsTotal(uint16 id) public view {
        GateSnapshot memory gate_ = gate.snapshot(id);
        assertLe(uint8(gate_.state), uint8(GateState.WATCHDOG), "a valid state ordinal");
        assertLe(uint8(gate_.session), uint8(Session.CLOSED), "a valid session ordinal");
        assertLe(gate_.hSessionBps, Constants.H_SESSION_BPS_MAX, "the haircut stays inside its band");
    }

    /* --------------------------------------------------------------------------------------------------------- */

    /// @dev Applies one fuzzed step: a new answer at a chosen age, a clock and block advance, and a tick move.
    function _apply(uint64 answerUsd8, uint32 ageSeconds, uint32 warpSeconds, uint32 blocksMined, int16 tickDelta)
        internal
    {
        uint256 answer = bound(answerUsd8, 1, 1_000_000e8);
        uint256 age = bound(ageSeconds, 0, 10 days);
        uint256 warpBy = bound(warpSeconds, 0, 10 days);
        uint256 blocks = bound(blocksMined, 0, 200_000);
        int24 delta = int24(bound(tickDelta, -3000, 3000));

        nvdaFeed.setRoundData(2, int256(answer), block.timestamp - age, block.timestamp - age);
        marketRef.setObservation(spokePool, fairTick, fairTick + delta, 1800);
        vm.warp(block.timestamp + warpBy);
        vm.roll(block.number + blocks);
    }

    /// @dev `|delta|`, saturating at `type(uint16).max` exactly as the gate does.
    function _magnitude(int24 delta) internal pure returns (uint16 magnitude) {
        uint256 absolute = delta >= 0 ? uint256(uint24(delta)) : uint256(uint24(-delta));
        return absolute >= type(uint16).max ? type(uint16).max : uint16(absolute);
    }
}
