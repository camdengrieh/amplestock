// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IOracleGate} from "../../src/interfaces/IOracleGate.sol";
import {Constants} from "../../src/types/Constants.sol";
import {ConstituentFrozen} from "../../src/types/Errors.sol";
import {GateSnapshot, GateState, Session} from "../../src/types/Types.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title MockOracleGate
/// @notice Settable stand-in for the six-layer gate. Every verdict is a stored value rather than a derivation, so
///         a test can put the protocol in any state — DEGRADED, DIVERGED, SCHEDULED_FREEZE, WATCHDOG, a guardian
///         freeze, a weekend session — in one call and assert what each path does about it.
///
/// @dev Fidelity notes that the consuming tests depend on:
///      - {checkBond} is the reverting form of {isBondAllowed} and refuses **only** for the three reasons the
///        design allows: a corporate-action freeze, a guardian freeze (constituent or protocol) and the divergence
///        breaker. A stale feed or a closed session widen {hSessionBps} instead — that is the 24/7 bond decision,
///        and reproducing it here is what makes the bond suite meaningful.
///      - `constituentId == 0` is the protocol-wide bond check that `ENTRY`-class markets use: it consults the
///        protocol freeze and the session table, but no per-constituent state.
///      - {hSessionBps} is a four-entry table indexed by {Session}, seeded with the launch values 0 / 50 / 150 /
///        300 bp. `AmpsBonds.hSessionBps` is a pass-through onto this table, so tests move the haircut here.
///      - `setBondRefusal` forces a refusal with an explicit `GateState`, which is how the guard-symmetry drills
///        put the gate into each non-green state without modelling the layer that produces it.
contract MockOracleGate is IOracleGate {
    /// @notice Per-constituent overrides. `set == false` means "fall back to the globals".
    struct ConstituentState {
        bool set;
        GateState state;
        bool corporateFreeze;
        bool feedStale;
        uint16 hSessionOverrideBps;
        bool hSessionOverrideSet;
        uint32 freezeUntil;
        uint64 answerUsd8;
        uint32 answerUpdatedAt;
    }

    /// @notice Per-pool overrides used by the placement and hook surfaces.
    struct PoolState {
        bool set;
        GateState state;
        bool diverged;
        uint16 dynCapBps;
        int24 poolTick;
        int24 fairTick;
    }

    /// @notice The session every read reports. Seeded to `REGULAR`.
    Session public session;

    /// @notice The state reported for anything with no override.
    GateState public defaultState;

    /// @notice Whether {checkBond} refuses for every constituent, whatever else is set.
    bool public bondRefusedGlobally;

    /// @notice The state {checkBond} blames when it refuses.
    GateState public refusingState = GateState.SCHEDULED_FREEZE;

    /// @notice Whether the watchdog is tripped.
    bool public watchdogTripped;

    /// @notice The protocol-wide guardian freeze expiry.
    uint32 public protocolFreezeUntil;

    /// @notice Governed parameters, reported verbatim.
    uint32 public graceSeconds = Constants.GRACE_SECONDS_DEFAULT;
    uint32 public gapSeconds = Constants.GAP_SECONDS_DEFAULT;
    uint16 public divergenceBps = Constants.DIVERGENCE_BPS_DEFAULT;
    uint32 public divergenceSustainSeconds = Constants.DIVERGENCE_SUSTAIN_SECONDS_DEFAULT;
    uint32 public corporateActionWindow = Constants.CORPORATE_ACTION_WINDOW_DEFAULT;

    /// @notice How many closed hours the calendar reports.
    uint16 public closedHours;

    /// @notice The `AmpsBonds` haircut table, indexed by {Session}.
    uint16[4] internal _hSessionBps = [
        Constants.H_SESSION_REGULAR_BPS_DEFAULT,
        Constants.H_SESSION_PRE_POST_BPS_DEFAULT,
        Constants.H_SESSION_OVERNIGHT_BPS_DEFAULT,
        Constants.H_SESSION_CLOSED_BPS_DEFAULT
    ];

    mapping(uint16 constituentId => ConstituentState state) internal _constituents;
    mapping(PoolId poolId => PoolState state) internal _pools;

    uint32 internal _watchdogBlock;
    uint32 internal _watchdogTimestamp;

    /// @notice How many times {poke} has been called, so tests can assert a path stamped layer A.
    uint256 public pokeCount;

    constructor() {
        _watchdogBlock = uint32(block.number);
        _watchdogTimestamp = uint32(block.timestamp);
    }

    /* ------------------------------------- test setters ------------------------------------- */

    /// @notice Sets the session every read reports, and therefore the haircut bonds pay.
    function setSession(Session session_) external {
        session = session_;
    }

    /// @notice Sets the state reported for constituents and pools with no override.
    function setDefaultState(GateState state_) external {
        defaultState = state_;
    }

    /// @notice Sets one entry of the haircut table.
    function setHSessionBps(Session session_, uint16 bps) external {
        _hSessionBps[uint8(session_)] = bps;
    }

    /// @notice Forces {checkBond} to refuse (or stop refusing) for every constituent.
    /// @param refused Whether to refuse.
    /// @param state_ The state to blame.
    function setBondRefusal(bool refused, GateState state_) external {
        bondRefusedGlobally = refused;
        refusingState = state_;
    }

    /// @notice Sets a constituent's whole override record.
    function setConstituentState(uint16 constituentId, ConstituentState calldata state_) external {
        _constituents[constituentId] = state_;
    }

    /// @notice Marks a constituent corporate-action frozen: the layer-D refusal.
    function setCorporateFreeze(uint16 constituentId, bool frozen) external {
        ConstituentState storage entry = _constituents[constituentId];
        entry.set = true;
        entry.corporateFreeze = frozen;
        entry.state = frozen ? GateState.SCHEDULED_FREEZE : defaultState;
    }

    /// @notice Applies a guardian freeze to one constituent.
    function setConstituentFreezeUntil(uint16 constituentId, uint32 until) external {
        ConstituentState storage entry = _constituents[constituentId];
        entry.set = true;
        entry.freezeUntil = until;
    }

    /// @notice Applies a per-constituent haircut override.
    function setConstituentHaircut(uint16 constituentId, uint16 bps, bool isSet) external {
        ConstituentState storage entry = _constituents[constituentId];
        entry.set = true;
        entry.hSessionOverrideBps = bps;
        entry.hSessionOverrideSet = isSet;
    }

    /// @notice Marks a constituent's feed stale. Does **not** close its bond market by design.
    function setFeedStale(uint16 constituentId, bool stale) external {
        ConstituentState storage entry = _constituents[constituentId];
        entry.set = true;
        entry.feedStale = stale;
        entry.state = stale ? GateState.DEGRADED : defaultState;
    }

    /// @notice Sets a pool's whole override record.
    function setPoolState(PoolId poolId, PoolState calldata state_) external {
        _pools[poolId] = state_;
    }

    /// @notice Latches or clears the divergence breaker on one pool.
    function setDiverged(PoolId poolId, bool diverged) external {
        PoolState storage entry = _pools[poolId];
        entry.set = true;
        entry.diverged = diverged;
        entry.state = diverged ? GateState.DIVERGED : defaultState;
    }

    /// @notice Trips or clears the layer-A watchdog.
    function setWatchdogTripped(bool tripped) external {
        watchdogTripped = tripped;
    }

    /// @notice Sets the protocol-wide guardian freeze expiry.
    function setProtocolFreezeUntil(uint32 until) external {
        protocolFreezeUntil = until;
    }

    /// @notice Sets the closed-hours counter the hook's band widening reads.
    function setClosedHours(uint16 hoursClosed) external {
        closedHours = hoursClosed;
    }

    /* --------------------------------------- IOracleGate --------------------------------------- */

    /// @inheritdoc IOracleGate
    function snapshot(uint16 constituentId) public view returns (GateSnapshot memory gate) {
        ConstituentState storage entry = _constituents[constituentId];
        gate.state = entry.set ? entry.state : defaultState;
        gate.session = session;
        gate.feedStale = entry.feedStale;
        gate.corporateFreeze = entry.corporateFreeze;
        gate.diverged = false;
        gate.watchdogTripped = watchdogTripped;
        gate.hSessionBps = hSessionFor(constituentId);
        gate.dynCapBps = gate.state == GateState.GREEN ? Constants.DYN_CAP_NORMAL_BPS : Constants.DYN_CAP_DEGRADED_BPS;
        gate.observedAt = uint32(block.timestamp);
        gate.answerUpdatedAt = entry.answerUpdatedAt;
        gate.answerUsd8 = entry.answerUsd8;
    }

    /// @inheritdoc IOracleGate
    function snapshotByPool(PoolId poolId) external view returns (GateSnapshot memory gate) {
        PoolState storage entry = _pools[poolId];
        gate.state = entry.set ? entry.state : defaultState;
        gate.session = session;
        gate.diverged = entry.diverged;
        gate.watchdogTripped = watchdogTripped;
        gate.hSessionBps = _hSessionBps[uint8(session)];
        gate.dynCapBps = entry.dynCapBps == 0 ? Constants.DYN_CAP_NORMAL_BPS : entry.dynCapBps;
        gate.poolTick = entry.poolTick;
        gate.fairTick = entry.fairTick;
        gate.observedAt = uint32(block.timestamp);
    }

    /// @inheritdoc IOracleGate
    function state(uint16 constituentId) external view returns (GateState gateState) {
        ConstituentState storage entry = _constituents[constituentId];
        gateState = entry.set ? entry.state : defaultState;
    }

    /// @inheritdoc IOracleGate
    function sessionNow() external view returns (Session current) {
        current = session;
    }

    /// @inheritdoc IOracleGate
    function sessionAt(uint256) external view returns (Session current) {
        current = session;
    }

    /// @inheritdoc IOracleGate
    function isPlacementAllowed(PoolId poolId) public view returns (bool allowed, bool anchorAtNav) {
        PoolState storage entry = _pools[poolId];
        GateState poolState = entry.set ? entry.state : defaultState;
        anchorAtNav = poolState == GateState.REF_DIVERGED || watchdogTripped;
        allowed = !watchdogTripped && (poolState == GateState.GREEN || poolState == GateState.REF_DIVERGED)
            && block.timestamp >= protocolFreezeUntil;
    }

    /// @inheritdoc IOracleGate
    /// @dev The whole 24/7 bond decision in one function: only a corporate-action freeze, a guardian freeze and the
    ///      divergence breaker close a market.
    function isBondAllowed(uint16 constituentId) public view returns (bool allowed, uint16 hSessionBps_) {
        hSessionBps_ = hSessionFor(constituentId);
        if (bondRefusedGlobally) return (false, hSessionBps_);
        if (block.timestamp < protocolFreezeUntil) return (false, hSessionBps_);

        ConstituentState storage entry = _constituents[constituentId];
        if (entry.corporateFreeze) return (false, hSessionBps_);
        if (block.timestamp < entry.freezeUntil) return (false, hSessionBps_);
        if (entry.set && (entry.state == GateState.DIVERGED || entry.state == GateState.SCHEDULED_FREEZE)) {
            return (false, hSessionBps_);
        }
        if (defaultState == GateState.DIVERGED || defaultState == GateState.SCHEDULED_FREEZE) {
            return (false, hSessionBps_);
        }
        allowed = true;
    }

    /// @inheritdoc IOracleGate
    function dynCapBps(PoolId poolId) external view returns (uint16 cap) {
        PoolState storage entry = _pools[poolId];
        cap = entry.dynCapBps == 0 ? Constants.DYN_CAP_NORMAL_BPS : entry.dynCapBps;
    }

    /// @inheritdoc IOracleGate
    function checkPlacement(PoolId poolId) external view returns (bool anchorAtNav) {
        bool allowed;
        (allowed, anchorAtNav) = isPlacementAllowed(poolId);
        if (!allowed) revert GateRefused(defaultState, poolId);
    }

    /// @inheritdoc IOracleGate
    function checkBond(uint16 constituentId) external view returns (uint16 hSessionBps_) {
        bool allowed;
        (allowed, hSessionBps_) = isBondAllowed(constituentId);
        if (allowed) return hSessionBps_;

        ConstituentState storage entry = _constituents[constituentId];
        if (entry.freezeUntil > block.timestamp) revert ConstituentFrozen(constituentId, entry.freezeUntil);
        if (entry.corporateFreeze) revert ConstituentFrozen(constituentId, 0);
        revert GateRefused(refusingState, PoolId.wrap(bytes32(0)));
    }

    /// @inheritdoc IOracleGate
    function watchdog() external view returns (uint32 blockNumber, uint32 timestamp, bool tripped) {
        return (_watchdogBlock, _watchdogTimestamp, watchdogTripped);
    }

    /// @inheritdoc IOracleGate
    function hSessionBps(Session session_) external view returns (uint16 bps) {
        bps = _hSessionBps[uint8(session_)];
    }

    /// @notice The haircut in force for one constituent: its override when set, else the session table.
    /// @param constituentId The constituent, or 0 for the protocol-wide entry-class read.
    /// @return bps The haircut.
    function hSessionFor(uint16 constituentId) public view returns (uint16 bps) {
        ConstituentState storage entry = _constituents[constituentId];
        bps = entry.hSessionOverrideSet ? entry.hSessionOverrideBps : _hSessionBps[uint8(session)];
    }

    /// @inheritdoc IOracleGate
    function constituentFreezeUntil(uint16 constituentId) external view returns (uint32 until) {
        until = _constituents[constituentId].freezeUntil;
    }

    /* ------------------------------------------ bands ------------------------------------------ */

    /// @inheritdoc IOracleGate
    function GRACE_SECONDS_MIN() external pure returns (uint32 value) {
        value = Constants.GRACE_SECONDS_MIN;
    }

    /// @inheritdoc IOracleGate
    function GRACE_SECONDS_MAX() external pure returns (uint32 value) {
        value = Constants.GRACE_SECONDS_MAX;
    }

    /// @inheritdoc IOracleGate
    function GAP_SECONDS_MAX() external pure returns (uint32 value) {
        value = Constants.GAP_SECONDS_MAX;
    }

    /// @inheritdoc IOracleGate
    function DIVERGENCE_BPS_MAX() external pure returns (uint16 value) {
        value = Constants.DIVERGENCE_BPS_MAX;
    }

    /// @inheritdoc IOracleGate
    function DIVERGENCE_SUSTAIN_SECONDS_MAX() external pure returns (uint32 value) {
        value = Constants.DIVERGENCE_SUSTAIN_SECONDS_MAX;
    }

    /// @inheritdoc IOracleGate
    function CORPORATE_ACTION_WINDOW_MAX() external pure returns (uint32 value) {
        value = Constants.CORPORATE_ACTION_WINDOW_MAX;
    }

    /// @inheritdoc IOracleGate
    function H_SESSION_BPS_MAX() external pure returns (uint16 value) {
        value = Constants.H_SESSION_BPS_MAX;
    }

    /// @inheritdoc IOracleGate
    function GUARDIAN_FREEZE_MAX_SECONDS() external pure returns (uint32 value) {
        value = Constants.GUARDIAN_FREEZE_MAX_SECONDS;
    }

    /* ----------------------------------------- mutative ----------------------------------------- */

    /// @inheritdoc IOracleGate
    function poke() external {
        _watchdogBlock = uint32(block.number);
        _watchdogTimestamp = uint32(block.timestamp);
        ++pokeCount;
        emit WatchdogStamped(_watchdogBlock, _watchdogTimestamp);
    }

    /// @inheritdoc IOracleGate
    function freezeConstituent(uint16 constituentId, uint32 until) external {
        ConstituentState storage entry = _constituents[constituentId];
        entry.set = true;
        entry.freezeUntil = until;
        emit ConstituentFreezeSet(constituentId, until);
    }

    /// @inheritdoc IOracleGate
    function unfreezeConstituent(uint16 constituentId) external {
        _constituents[constituentId].freezeUntil = 0;
        emit ConstituentFreezeSet(constituentId, 0);
    }

    /// @inheritdoc IOracleGate
    function freezeProtocol(uint32 until) external {
        protocolFreezeUntil = until;
        emit ProtocolFreezeSet(until);
    }

    /// @inheritdoc IOracleGate
    function unfreezeProtocol() external {
        protocolFreezeUntil = 0;
        emit ProtocolFreezeSet(0);
    }

    /// @inheritdoc IOracleGate
    function setGraceSeconds(uint32 value) external {
        graceSeconds = value;
    }

    /// @inheritdoc IOracleGate
    function setGapSeconds(uint32 value) external {
        gapSeconds = value;
    }

    /// @inheritdoc IOracleGate
    function setDivergenceBps(uint16 value) external {
        divergenceBps = value;
    }

    /// @inheritdoc IOracleGate
    function setDivergenceSustainSeconds(uint32 value) external {
        divergenceSustainSeconds = value;
    }

    /// @inheritdoc IOracleGate
    function setCorporateActionWindow(uint32 value) external {
        corporateActionWindow = value;
    }

    /// @inheritdoc IOracleGate
    function setHolidayBitmap(uint16, uint256[2] calldata) external {}

    /// @inheritdoc IOracleGate
    function setDstTable(uint32[] calldata, uint32[] calldata) external {}
}
