// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeedRegistry} from "../interfaces/IFeedRegistry.sol";
import {IMarketReference} from "../interfaces/IMarketReference.sol";
import {IOracleGate} from "../interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {Constants} from "../types/Constants.sol";
import {LengthMismatch, NotGuardian, NotTimelock, OutOfBand, ZeroAddress} from "../types/Errors.sol";
import {ConstituentConfig, GateSnapshot, GateState, PoolConfig, Session} from "../types/Types.sol";
import {GatePriceMath} from "./GatePriceMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title OracleGate
/// @notice Layers A-F of the oracle, liveness and freeze design. Pointer-upgradeable behind the 7-day timelock;
///         holds no funds, moves no token and has no power to stop a redemption.
///
/// @dev **Everything here is read-derived.** With one exception the gate stores no verdict: {state} recomputes
///      the session, the freshness, the corporate-action probes and the tick deviation from live inputs on every
///      call, so a state clears the moment its cause does and no keeper is needed to un-stick it. The exception is
///      layer E's `divergedSince` timer, which by definition needs a clock reading persisted from an earlier
///      block; it is armed and cleared by the permissionless {pokePool}, and even then the effective `DIVERGED`
///      verdict re-checks the *current* deviation, so a stale timer can never hold a pool closed on its own.
///
/// @dev **The layers.**
///
///      - **A, block cadence.** `(lastBlock, lastTimestamp)` are stamped by {poke} and by every state-changing
///        vault entry. Robinhood Chain publishes no Chainlink L2 sequencer uptime feed and runs no Chainlink
///        Automation, so this is the substitute. It trips when the wall clock has advanced by more than
///        `graceSeconds` since the last stamp **and** fewer blocks were produced across that span than
///        `gapSeconds` implies — `blocksAdvanced < elapsed / gapSeconds`. Elapsed time alone is not a trip: on a
///        healthy chain nobody may have called the gate for an hour, and that is not an outage. Missing *blocks*
///        are.
///      - **B, market state.** A deterministic on-chain 24/5 ET calendar: Regular 09:30-16:00, Pre 04:00-09:30,
///        Post 16:00-20:00, Overnight 20:00 to 04:00 of the next trading day, Closed otherwise, with a governed
///        holiday bitmap per year and a governed DST table. {sessionAt} is a pure function of `(timestamp,
///        holidayBitmap, dstTable)` and is the *floor* of layer B; `StreamsSchemaLib` is the restrict-only path a
///        future relay uses to close the market earlier than the calendar, never later.
///      - **C, freshness.** Delegated to `FeedRegistry`: `heartbeat x freshnessMultiplier[session] / 100`,
///        disabled when Closed, plus positivity, per-ticker bounds and the two-confirmation rule.
///      - **D, corporate actions.** Four bounded `staticcall`s into the Stock Token — `oraclePaused()`,
///        `effectiveAt()`, `newUIMultiplier()`, `uiMultiplier()` — each capped at
///        `Constants.STOCK_TOKEN_PROBE_GAS`. A pause, or a pending `effectiveAt` within
///        `+/- corporateActionWindow` of now, is `SCHEDULED_FREEZE` for that constituent.
///      - **E, divergence.** `|poolTick - fairTick| > divergenceBps` sustained for `divergenceSustainSeconds`
///        latches `DIVERGED` for that one pool. `fairTick` is derived from the hub TWAP, the counter asset's
///        Chainlink answer and the registry's pool config; the hook never writes here.
///      - **F, reference integrity.** The `AMPS/USDG` hub TWAP and `AMPS/WETH x ETH/USD` must agree within
///        `refDivergenceBps`, and the hub's observation ring must cover the TWAP window. Disagreement is
///        `REF_DIVERGED` (the reference falls back to NAV and nothing else changes); missing coverage is
///        `WATCHDOG`.
///
/// @dev **The gate never stops a swap and never stops a redemption.** A non-green gate is a *price*: the hook
///      raises its floor and widens its dynamic cap (I15). `AmpsVault.redeemProRata` and `AmpsBonds.claim`
///      contain no reference to this contract at all, which is what makes the redemption floor structurally
///      unpausable rather than merely un-paused (I14).
///
/// @dev **Guardian powers are disable-only and expire.** {freezeConstituent} and {freezeProtocol} take an expiry
///      at most `GUARDIAN_FREEZE_MAX_SECONDS` ahead, refuse anything longer, and lapse with no further action.
///      Neither can move a fund; both can be cleared early by the guardian or the timelock.
contract OracleGate is IOracleGate {
    // -------------------------------------------------------------------------------------------------------------
    // Calendar constants
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Seconds in a day, as an unsigned scalar for the calendar arithmetic.
    uint256 internal constant SECONDS_PER_DAY = 86_400;

    /// @dev 04:00 ET, when the pre-market session opens and the overnight session ends.
    uint256 internal constant PRE_OPEN_SECOND = 4 * 3600;

    /// @dev 09:30 ET, when the regular session opens.
    uint256 internal constant REGULAR_OPEN_SECOND = 9 * 3600 + 1800;

    /// @dev 16:00 ET, when the regular session closes and the post-market session opens.
    uint256 internal constant REGULAR_CLOSE_SECOND = 16 * 3600;

    /// @dev 20:00 ET, when the post-market session closes and the overnight session opens.
    uint256 internal constant POST_CLOSE_SECOND = 20 * 3600;

    /// @dev Seconds ET is behind UTC on standard time (EST, UTC-5).
    uint256 internal constant UTC_OFFSET_STANDARD = 5 * 3600;

    /// @dev Seconds ET is behind UTC on daylight time (EDT, UTC-4).
    uint256 internal constant UTC_OFFSET_DAYLIGHT = 4 * 3600;

    /// @dev Day index of 1970-01-01 mapped onto a Sunday-first week: 1970-01-01 was a Thursday, so
    ///      `(dayIndex + 4) % 7` yields 0 for Sunday through 6 for Saturday.
    uint256 internal constant DOW_EPOCH_SHIFT = 4;

    /// @notice The furthest {closedHours} walks back before giving up and reporting its ceiling. 16 days covers
    ///         every holiday-plus-weekend stretch the US equity calendar can produce.
    uint256 public constant MAX_CLOSED_LOOKBACK_DAYS = 16;

    /// @notice Hard ceiling on the number of DST windows the table may hold, so {sessionAt} stays bounded.
    uint256 public constant DST_TABLE_MAX = 64;

    /// @notice Gas forwarded to every bounded probe into a Stock Token or a market-reference source.
    uint256 public constant PROBE_GAS = Constants.STOCK_TOKEN_PROBE_GAS;

    // -------------------------------------------------------------------------------------------------------------
    // Storage (slot layout per `docs/phase2-state-model.md` §1.5)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The sole governance path. Immutable: a gate that could re-point its own governor is not governed.
    address public immutable timelock;

    /// @notice The guardian Safe. Immutable, and its entire power is a disable-only expiring freeze.
    address public immutable guardian;

    /// @dev The gate's `PriceLib` boundary, deployed by this contract's constructor and read through
    ///      {priceMath}. Held as the concrete type so the two bounded `try` call sites stay typed; exposed as an
    ///      `address` because `IOracleGate` must not depend on an implementation contract.
    GatePriceMath internal immutable _priceMath;

    /// @dev slot 0 `[0..31]`: the block number of the last layer-A stamp, truncated.
    uint32 internal _lastBlock;

    /// @dev slot 0 `[32..63]`: the timestamp of the last layer-A stamp.
    uint32 internal _lastTimestamp;

    /// @dev slot 0 `[64..95]`: layer A, seconds without a stamp before the watchdog may trip.
    uint32 internal _graceSeconds;

    /// @dev slot 0 `[96..127]`: layer A, the expected worst-case inter-block gap.
    uint32 internal _gapSeconds;

    /// @dev slot 0 `[128..159]`: layer E, how long a deviation must persist before `DIVERGED`.
    uint32 internal _divergenceSustainSeconds;

    /// @dev slot 0 `[160..191]`: layer D, the half-width of the corporate-action window.
    uint32 internal _corporateActionWindow;

    /// @dev slot 0 `[192..207]`: layer E, the deviation that arms the breaker, in bps.
    uint16 internal _divergenceBps;

    /// @dev slot 0 `[208..239]`: the guardian's protocol-wide freeze expiry.
    uint32 internal _protocolFreezeUntil;

    /// @dev slot 0 `[240..255]`: layer F, the hub-vs-WETH reference tolerance, in bps. Occupies the free bits the
    ///      state model left at the top of the word.
    uint16 internal _refDivergenceBps;

    /// @dev slot 1 `[0..159]`: layer C.
    address internal _feedRegistry;

    /// @dev slot 1 `[160..175]`: `h_session[REGULAR]`.
    uint16 internal _hSessionRegular;

    /// @dev slot 1 `[176..191]`: `h_session[PRE_POST]`.
    uint16 internal _hSessionPrePost;

    /// @dev slot 1 `[192..207]`: `h_session[OVERNIGHT]`.
    uint16 internal _hSessionOvernight;

    /// @dev slot 1 `[208..223]`: `h_session[CLOSED]`.
    uint16 internal _hSessionClosed;

    /// @dev slot 2: constituent -> token / feed / pool lookups.
    address internal _registry;

    /// @dev slot 3: the tick source for `fairTick` and observation coverage.
    address internal _marketReference;

    /// @dev slot 4: guardian freeze expiry per constituent.
    mapping(uint16 constituentId => uint32 until) internal _constituentFreezeUntil;

    /// @dev slot 5: layer E, when the deviation first left the band for a pool. 0 when inside it.
    mapping(PoolId poolId => uint32 since) internal _divergedSince;

    /// @dev slot 6: one 512-bit bitmap per calendar year, one bit per day of year, set means closed.
    mapping(uint16 year => uint256[2] bitmap) internal _holidayBitmap;

    /// @dev slot 7: DST window starts, UTC, ascending.
    uint32[] internal _dstStarts;

    /// @dev slot 8: DST window ends, UTC, parallel to {_dstStarts}.
    uint32[] internal _dstEnds;

    // -------------------------------------------------------------------------------------------------------------
    // Extra events (beyond `IOracleGate`)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Emitted when a year's holiday bitmap is replaced.
    /// @param year The calendar year.
    /// @param bitmap The new bitmap.
    event HolidayBitmapSet(uint16 indexed year, uint256[2] bitmap);

    /// @notice Emitted when the DST transition table is replaced.
    /// @param windows How many DST windows the table now holds.
    event DstTableSet(uint256 windows);

    // -------------------------------------------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Deploys the gate with the launch parameter set and an immediate layer-A stamp.
    /// @param timelock_ The governance timelock. Immutable.
    /// @param guardian_ The guardian Safe. Immutable.
    /// @param feedRegistry_ The layer-C registry.
    /// @param registry_ The pool and constituent registry.
    /// @param marketReference_ The tick source (a mock in Phase 2, `AmpsHook` in Phase 3).
    constructor(
        address timelock_,
        address guardian_,
        address feedRegistry_,
        address registry_,
        address marketReference_
    ) {
        if (timelock_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        guardian = guardian_;
        _priceMath = new GatePriceMath();
        _feedRegistry = feedRegistry_;
        _registry = registry_;
        _marketReference = marketReference_;

        _graceSeconds = Constants.GRACE_SECONDS_DEFAULT;
        _gapSeconds = Constants.GAP_SECONDS_DEFAULT;
        _divergenceBps = Constants.DIVERGENCE_BPS_DEFAULT;
        _divergenceSustainSeconds = Constants.DIVERGENCE_SUSTAIN_SECONDS_DEFAULT;
        _corporateActionWindow = Constants.CORPORATE_ACTION_WINDOW_DEFAULT;
        _refDivergenceBps = Constants.REF_DIVERGENCE_BPS_DEFAULT;
        _hSessionRegular = Constants.H_SESSION_REGULAR_BPS_DEFAULT;
        _hSessionPrePost = Constants.H_SESSION_PRE_POST_BPS_DEFAULT;
        _hSessionOvernight = Constants.H_SESSION_OVERNIGHT_BPS_DEFAULT;
        _hSessionClosed = Constants.H_SESSION_CLOSED_BPS_DEFAULT;

        _lastBlock = uint32(block.number);
        _lastTimestamp = uint32(block.timestamp);
        emit WatchdogStamped(_lastBlock, _lastTimestamp);
    }

    /// @dev Every governed setter, and nothing else.
    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock(msg.sender);
        _;
    }

    /// @dev The two freeze entry points. Disable-only and expiring, so the guardian needs no delay.
    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian(msg.sender);
        _;
    }

    /// @dev Clearing a freeze early: the guardian that set it, or the timelock over its head.
    modifier onlyGuardianOrTimelock() {
        if (msg.sender != guardian && msg.sender != timelock) revert NotGuardian(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Layer B: the calendar
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleGate
    function sessionNow() external view returns (Session session) {
        return sessionAt(block.timestamp);
    }

    /// @inheritdoc IOracleGate
    /// @dev Pure with respect to the governed holiday bitmap and DST table, and total: every timestamp maps to
    ///      exactly one session with no revert path. The overnight session that *ends* at 04:00 on day `X` exists
    ///      exactly when `X` is a trading day, and runs from 20:00 on `X - 1`. That single rule produces the
    ///      Friday 20:00 close, the Sunday 20:00 reopen, and the correct treatment of the evening before a
    ///      holiday, without a second table.
    function sessionAt(uint256 timestamp) public view returns (Session session) {
        uint256 offset = _utcOffsetAt(timestamp);
        if (timestamp < offset) return Session.CLOSED;
        uint256 local = timestamp - offset;
        uint256 dayIndex = local / SECONDS_PER_DAY;
        uint256 secondOfDay = local % SECONDS_PER_DAY;

        if (secondOfDay >= POST_CLOSE_SECOND) {
            return _isTradingDay(dayIndex + 1) ? Session.OVERNIGHT : Session.CLOSED;
        }
        if (secondOfDay < PRE_OPEN_SECOND) {
            return _isTradingDay(dayIndex) ? Session.OVERNIGHT : Session.CLOSED;
        }
        if (!_isTradingDay(dayIndex)) return Session.CLOSED;
        if (secondOfDay < REGULAR_OPEN_SECOND) return Session.PRE_POST;
        if (secondOfDay < REGULAR_CLOSE_SECOND) return Session.REGULAR;
        return Session.PRE_POST;
    }

    /// @inheritdoc IOracleGate
    /// @dev Walks back one local day at a time from the current closed stretch, which is bounded by
    ///      {MAX_CLOSED_LOOKBACK_DAYS} and in practice terminates after one step (a weekend) or three (a holiday
    ///      weekend). The result is clamped to `type(uint16).max`.
    function closedHours() external view returns (uint16 hoursClosed) {
        uint256 nowTs = block.timestamp;
        if (sessionAt(nowTs) != Session.CLOSED) return 0;

        uint256 offset = _utcOffsetAt(nowTs);
        if (nowTs < offset) return type(uint16).max;
        uint256 dayIndex = (nowTs - offset) / SECONDS_PER_DAY;

        uint256 startDay;
        if (_isTradingDay(dayIndex)) {
            // A trading day that is nonetheless closed can only be closed after 20:00, i.e. the market shut for
            // the week (or for a holiday tomorrow) at this evening's post-market close.
            startDay = dayIndex;
        } else {
            uint256 cursor = dayIndex;
            uint256 steps = 0;
            while (steps < MAX_CLOSED_LOOKBACK_DAYS && cursor > 0 && !_isTradingDay(cursor - 1)) {
                cursor -= 1;
                steps += 1;
            }
            if (cursor == 0 || !_isTradingDay(cursor - 1)) return type(uint16).max;
            startDay = cursor - 1;
        }

        uint256 localStart = startDay * SECONDS_PER_DAY + POST_CLOSE_SECOND;
        // Convert the local close back to UTC using the offset in force *at that instant*: a weekend that spans a
        // DST transition is 47 or 49 hours long, not 48.
        uint256 startUtc = localStart + _utcOffsetAt(localStart + offset);
        if (nowTs <= startUtc) return 0;
        uint256 hrs = (nowTs - startUtc) / 3600;
        return hrs >= type(uint16).max ? type(uint16).max : uint16(hrs);
    }

    /// @inheritdoc IOracleGate
    function isHoliday(uint256 timestamp) external view returns (bool holiday) {
        uint256 offset = _utcOffsetAt(timestamp);
        if (timestamp < offset) return false;
        return _isHolidayDay((timestamp - offset) / SECONDS_PER_DAY);
    }

    /// @inheritdoc IOracleGate
    function holidayBitmap(uint16 year) external view returns (uint256[2] memory bitmap) {
        return _holidayBitmap[year];
    }

    /// @inheritdoc IOracleGate
    function dstTable() external view returns (uint32[] memory starts, uint32[] memory ends) {
        return (_dstStarts, _dstEnds);
    }

    /// @inheritdoc IOracleGate
    function utcOffsetAt(uint256 timestamp) external view returns (uint256 offsetSeconds) {
        return _utcOffsetAt(timestamp);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleGate
    function snapshot(uint16 constituentId) public view returns (GateSnapshot memory gate) {
        return _snapshot(constituentId, _poolOf(constituentId));
    }

    /// @inheritdoc IOracleGate
    function snapshotByPool(PoolId poolId) public view returns (GateSnapshot memory gate) {
        return _snapshot(_constituentOfPool(poolId), poolId);
    }

    /// @inheritdoc IOracleGate
    function state(uint16 constituentId) external view returns (GateState gateState) {
        return snapshot(constituentId).state;
    }

    /// @inheritdoc IOracleGate
    function stateByPool(PoolId poolId) external view returns (GateState gateState) {
        return snapshotByPool(poolId).state;
    }

    /// @inheritdoc IOracleGate
    function isPlacementAllowed(PoolId poolId) public view returns (bool allowed, bool anchorAtNav) {
        GateState gateState = snapshotByPool(poolId).state;
        allowed = gateState == GateState.GREEN || gateState == GateState.REF_DIVERGED;
        anchorAtNav = gateState == GateState.REF_DIVERGED;
    }

    /// @inheritdoc IOracleGate
    /// @dev A stale feed and a closed session are deliberately *not* refusals: they widen the haircut instead,
    ///      which is the 24/7 bond decision. Only a corporate-action freeze, a guardian freeze and the divergence
    ///      breaker close a market.
    /// @dev `constituentId == 0` is the protocol-wide `ENTRY`-class check, and reaches this through {snapshot}:
    ///      {_poolOf} answers `bytes32(0)` for id 0, so {_snapshot} skips layers C, D and E entirely and the only
    ///      refusal left is the guardian's protocol freeze. Nothing on the path can revert with
    ///      `UnknownConstituent` — the gate never looks id 0 up in the registry.
    function isBondAllowed(uint16 constituentId) public view returns (bool allowed, uint16 hSessionBps_) {
        GateSnapshot memory gate = snapshot(constituentId);
        allowed = gate.state != GateState.SCHEDULED_FREEZE && gate.state != GateState.DIVERGED;
        hSessionBps_ = gate.hSessionBps;
    }

    /// @inheritdoc IOracleGate
    function dynCapBps(PoolId poolId) external view returns (uint16 cap) {
        return snapshotByPool(poolId).dynCapBps;
    }

    /// @inheritdoc IOracleGate
    function checkPlacement(PoolId poolId) external view returns (bool anchorAtNav) {
        GateState gateState = snapshotByPool(poolId).state;
        if (gateState != GateState.GREEN && gateState != GateState.REF_DIVERGED) {
            revert GateRefused(gateState, poolId);
        }
        return gateState == GateState.REF_DIVERGED;
    }

    /// @inheritdoc IOracleGate
    /// @dev `constituentId == 0` is valid: see {isBondAllowed}. The refusal it can give is `SCHEDULED_FREEZE`
    ///      under a guardian protocol freeze, and the pool it blames is `bytes32(0)` because an entry-class market
    ///      has no spoke.
    function checkBond(uint16 constituentId) external view returns (uint16 hSessionBps_) {
        GateSnapshot memory gate = snapshot(constituentId);
        if (gate.state == GateState.SCHEDULED_FREEZE || gate.state == GateState.DIVERGED) {
            revert GateRefused(gate.state, _poolOf(constituentId));
        }
        return gate.hSessionBps;
    }

    /// @inheritdoc IOracleGate
    function watchdog() external view returns (uint32 blockNumber, uint32 timestamp, bool tripped) {
        return (_lastBlock, _lastTimestamp, _watchdogTripped());
    }

    // -------------------------------------------------------------------------------------------------------------
    // Governed parameters
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleGate
    function graceSeconds() external view returns (uint32 value) {
        return _graceSeconds;
    }

    /// @inheritdoc IOracleGate
    function gapSeconds() external view returns (uint32 value) {
        return _gapSeconds;
    }

    /// @inheritdoc IOracleGate
    function divergenceBps() external view returns (uint16 value) {
        return _divergenceBps;
    }

    /// @inheritdoc IOracleGate
    function divergenceSustainSeconds() external view returns (uint32 value) {
        return _divergenceSustainSeconds;
    }

    /// @inheritdoc IOracleGate
    function corporateActionWindow() external view returns (uint32 value) {
        return _corporateActionWindow;
    }

    /// @inheritdoc IOracleGate
    function refDivergenceBps() external view returns (uint16 value) {
        return _refDivergenceBps;
    }

    /// @inheritdoc IOracleGate
    function hSessionBps(Session session) public view returns (uint16 bps) {
        if (session == Session.REGULAR) return _hSessionRegular;
        if (session == Session.PRE_POST) return _hSessionPrePost;
        if (session == Session.OVERNIGHT) return _hSessionOvernight;
        return _hSessionClosed;
    }

    /// @inheritdoc IOracleGate
    function protocolFreezeUntil() external view returns (uint32 until) {
        return _protocolFreezeUntil;
    }

    /// @inheritdoc IOracleGate
    function constituentFreezeUntil(uint16 constituentId) external view returns (uint32 until) {
        return _constituentFreezeUntil[constituentId];
    }

    /// @inheritdoc IOracleGate
    function divergedSince(PoolId poolId) external view returns (uint32 since) {
        return _divergedSince[poolId];
    }

    /// @inheritdoc IOracleGate
    function feedRegistry() external view returns (address registryAddress) {
        return _feedRegistry;
    }

    /// @inheritdoc IOracleGate
    function registry() external view returns (address registryAddress) {
        return _registry;
    }

    /// @inheritdoc IOracleGate
    function marketReference() external view returns (address referenceAddress) {
        return _marketReference;
    }

    /// @inheritdoc IOracleGate
    function priceMath() external view returns (address priceMathAddress) {
        return address(_priceMath);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleGate
    function GRACE_SECONDS_MIN() external pure returns (uint32 value) {
        return Constants.GRACE_SECONDS_MIN;
    }

    /// @inheritdoc IOracleGate
    function GRACE_SECONDS_MAX() external pure returns (uint32 value) {
        return Constants.GRACE_SECONDS_MAX;
    }

    /// @inheritdoc IOracleGate
    function GAP_SECONDS_MAX() external pure returns (uint32 value) {
        return Constants.GAP_SECONDS_MAX;
    }

    /// @inheritdoc IOracleGate
    function DIVERGENCE_BPS_MAX() external pure returns (uint16 value) {
        return Constants.DIVERGENCE_BPS_MAX;
    }

    /// @inheritdoc IOracleGate
    function DIVERGENCE_SUSTAIN_SECONDS_MAX() external pure returns (uint32 value) {
        return Constants.DIVERGENCE_SUSTAIN_SECONDS_MAX;
    }

    /// @inheritdoc IOracleGate
    function CORPORATE_ACTION_WINDOW_MAX() external pure returns (uint32 value) {
        return Constants.CORPORATE_ACTION_WINDOW_MAX;
    }

    /// @inheritdoc IOracleGate
    function H_SESSION_BPS_MAX() external pure returns (uint16 value) {
        return Constants.H_SESSION_BPS_MAX;
    }

    /// @inheritdoc IOracleGate
    function GUARDIAN_FREEZE_MAX_SECONDS() external pure returns (uint32 value) {
        return Constants.GUARDIAN_FREEZE_MAX_SECONDS;
    }

    /// @inheritdoc IOracleGate
    function REF_DIVERGENCE_BPS_MIN() external pure returns (uint16 value) {
        return Constants.REF_DIVERGENCE_BPS_MIN;
    }

    /// @inheritdoc IOracleGate
    function REF_DIVERGENCE_BPS_MAX() external pure returns (uint16 value) {
        return Constants.REF_DIVERGENCE_BPS_MAX;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative: the permissionless stamp
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleGate
    /// @dev Stamps layer A only. Re-evaluating the layer-E timer needs a pool argument, and iterating all 32 pools
    ///      inside an unpaid permissionless call is unbounded gas — {pokePool} and {pokePools} do that part.
    function poke() external {
        _stamp();
    }

    /// @inheritdoc IOracleGate
    /// @dev The effective `DIVERGED` verdict always re-checks the *current* deviation as well, so an armed timer
    ///      that nobody clears cannot hold a pool closed by itself.
    function pokePool(PoolId poolId) public {
        _stamp();
        _updateDivergence(poolId);
    }

    /// @inheritdoc IOracleGate
    function pokePools(PoolId[] calldata poolIds) external {
        _stamp();
        for (uint256 i = 0; i < poolIds.length; ++i) {
            _updateDivergence(poolIds[i]);
        }
    }

    /// @inheritdoc IOracleGate
    function pokeConstituent(uint16 constituentId) external {
        _stamp();
        PoolId poolId = _poolOf(constituentId);
        _updateDivergence(poolId);
        ConstituentConfig memory config = _constituent(constituentId);
        (bool frozen, uint32 effectiveAt) = _corporateAction(config);
        emit CorporateActionFreeze(constituentId, frozen, effectiveAt);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Guardian
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleGate
    function freezeConstituent(uint16 constituentId, uint32 until) external onlyGuardian {
        _requireFreezeWindow(until);
        _constituentFreezeUntil[constituentId] = until;
        emit ConstituentFreezeSet(constituentId, until);
    }

    /// @inheritdoc IOracleGate
    function unfreezeConstituent(uint16 constituentId) external onlyGuardianOrTimelock {
        delete _constituentFreezeUntil[constituentId];
        emit ConstituentFreezeSet(constituentId, 0);
    }

    /// @inheritdoc IOracleGate
    function freezeProtocol(uint32 until) external onlyGuardian {
        _requireFreezeWindow(until);
        _protocolFreezeUntil = until;
        emit ProtocolFreezeSet(until);
    }

    /// @inheritdoc IOracleGate
    function unfreezeProtocol() external onlyGuardianOrTimelock {
        _protocolFreezeUntil = 0;
        emit ProtocolFreezeSet(0);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleGate
    /// @dev Also requires `graceSeconds > gapSeconds`: layer A's trip test divides the elapsed time by the gap, so
    ///      a grace window shorter than one expected block gap would trip on an ordinary quiet minute.
    function setGraceSeconds(uint32 value) external onlyTimelock {
        if (value < Constants.GRACE_SECONDS_MIN || value > Constants.GRACE_SECONDS_MAX) {
            revert OutOfBand("graceSeconds", value, Constants.GRACE_SECONDS_MIN, Constants.GRACE_SECONDS_MAX);
        }
        if (value <= _gapSeconds) {
            revert OutOfBand("graceSeconds", value, uint256(_gapSeconds) + 1, Constants.GRACE_SECONDS_MAX);
        }
        uint32 previous = _graceSeconds;
        _graceSeconds = value;
        emit GateParameterChanged("graceSeconds", previous, value);
    }

    /// @inheritdoc IOracleGate
    function setGapSeconds(uint32 value) external onlyTimelock {
        if (value == 0 || value > Constants.GAP_SECONDS_MAX) {
            revert OutOfBand("gapSeconds", value, 1, Constants.GAP_SECONDS_MAX);
        }
        if (value >= _graceSeconds) revert OutOfBand("gapSeconds", value, 1, uint256(_graceSeconds) - 1);
        uint32 previous = _gapSeconds;
        _gapSeconds = value;
        emit GateParameterChanged("gapSeconds", previous, value);
    }

    /// @inheritdoc IOracleGate
    function setDivergenceBps(uint16 value) external onlyTimelock {
        if (value == 0 || value > Constants.DIVERGENCE_BPS_MAX) {
            revert OutOfBand("divergenceBps", value, 1, Constants.DIVERGENCE_BPS_MAX);
        }
        uint16 previous = _divergenceBps;
        _divergenceBps = value;
        emit GateParameterChanged("divergenceBps", previous, value);
    }

    /// @inheritdoc IOracleGate
    function setDivergenceSustainSeconds(uint32 value) external onlyTimelock {
        if (value > Constants.DIVERGENCE_SUSTAIN_SECONDS_MAX) {
            revert OutOfBand("divergenceSustainSeconds", value, 0, Constants.DIVERGENCE_SUSTAIN_SECONDS_MAX);
        }
        uint32 previous = _divergenceSustainSeconds;
        _divergenceSustainSeconds = value;
        emit GateParameterChanged("divergenceSustainSeconds", previous, value);
    }

    /// @inheritdoc IOracleGate
    function setCorporateActionWindow(uint32 value) external onlyTimelock {
        if (value > Constants.CORPORATE_ACTION_WINDOW_MAX) {
            revert OutOfBand("corporateActionWindow", value, 0, Constants.CORPORATE_ACTION_WINDOW_MAX);
        }
        uint32 previous = _corporateActionWindow;
        _corporateActionWindow = value;
        emit GateParameterChanged("corporateActionWindow", previous, value);
    }

    /// @inheritdoc IOracleGate
    function setRefDivergenceBps(uint16 value) external onlyTimelock {
        if (value < Constants.REF_DIVERGENCE_BPS_MIN || value > Constants.REF_DIVERGENCE_BPS_MAX) {
            revert OutOfBand(
                "refDivergenceBps", value, Constants.REF_DIVERGENCE_BPS_MIN, Constants.REF_DIVERGENCE_BPS_MAX
            );
        }
        uint16 previous = _refDivergenceBps;
        _refDivergenceBps = value;
        emit GateParameterChanged("refDivergenceBps", previous, value);
    }

    /// @inheritdoc IOracleGate
    function setHSessionBps(Session session, uint16 bps) external onlyTimelock {
        if (bps > Constants.H_SESSION_BPS_MAX) {
            revert OutOfBand("hSessionBps", bps, 0, Constants.H_SESSION_BPS_MAX);
        }
        uint16 previous = hSessionBps(session);
        if (session == Session.REGULAR) {
            _hSessionRegular = bps;
        } else if (session == Session.PRE_POST) {
            _hSessionPrePost = bps;
        } else if (session == Session.OVERNIGHT) {
            _hSessionOvernight = bps;
        } else {
            _hSessionClosed = bps;
        }
        emit GateParameterChanged("hSessionBps", previous, bps);
    }

    /// @inheritdoc IOracleGate
    /// @dev The bitmap is full-day closures only. A half day (the Friday after Thanksgiving, Christmas Eve) is a
    ///      shortened *regular* session that this table cannot express; the restrict-only Streams path is what
    ///      closes the market early once it exists, and until then a half day is treated as a full trading day —
    ///      which errs towards a *tighter* freshness bound, not a looser one.
    function setHolidayBitmap(uint16 year, uint256[2] calldata bitmap) external onlyTimelock {
        _holidayBitmap[year] = bitmap;
        emit HolidayBitmapSet(year, bitmap);
        emit GateParameterChanged("holidayBitmap", year, bitmap[0]);
    }

    /// @inheritdoc IOracleGate
    /// @dev The windows must be strictly ascending and non-overlapping, so {sessionAt}'s scan can stop at the
    ///      first start above the queried timestamp.
    function setDstTable(uint32[] calldata starts, uint32[] calldata ends) external onlyTimelock {
        if (starts.length != ends.length) revert LengthMismatch();
        if (starts.length > DST_TABLE_MAX) {
            revert OutOfBand("dstTableLength", starts.length, 0, DST_TABLE_MAX);
        }
        for (uint256 i = 0; i < starts.length; ++i) {
            if (starts[i] >= ends[i]) revert OutOfBand("dstWindow", starts[i], 0, ends[i]);
            if (i != 0 && starts[i] <= ends[i - 1]) {
                revert OutOfBand("dstWindow", starts[i], uint256(ends[i - 1]) + 1, type(uint32).max);
            }
        }
        _dstStarts = starts;
        _dstEnds = ends;
        emit DstTableSet(starts.length);
        emit GateParameterChanged("dstTable", 0, starts.length);
    }

    /// @inheritdoc IOracleGate
    function setFeedRegistry(address value) external onlyTimelock {
        if (value == address(0)) revert ZeroAddress();
        address previous = _feedRegistry;
        _feedRegistry = value;
        emit GateParameterChanged("feedRegistry", uint256(uint160(previous)), uint256(uint160(value)));
    }

    /// @inheritdoc IOracleGate
    function setRegistry(address value) external onlyTimelock {
        if (value == address(0)) revert ZeroAddress();
        address previous = _registry;
        _registry = value;
        emit GateParameterChanged("registry", uint256(uint160(previous)), uint256(uint160(value)));
    }

    /// @inheritdoc IOracleGate
    function setMarketReference(address value) external onlyTimelock {
        if (value == address(0)) revert ZeroAddress();
        address previous = _marketReference;
        _marketReference = value;
        emit GateParameterChanged("marketReference", uint256(uint160(previous)), uint256(uint160(value)));
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals: layer A
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Writes the layer-A stamp and reports the transition an indexer needs to see.
    function _stamp() internal {
        bool wasTripped = _watchdogTripped();
        uint32 elapsed = _elapsedSinceStamp();
        _lastBlock = uint32(block.number);
        _lastTimestamp = uint32(block.timestamp);
        emit WatchdogStamped(_lastBlock, _lastTimestamp);
        if (wasTripped) {
            emit WatchdogTripped(true, elapsed);
            emit WatchdogTripped(false, 0);
        }
    }

    /// @dev Seconds since the last stamp, saturating at zero for a stamp in the future.
    function _elapsedSinceStamp() internal view returns (uint32 elapsed) {
        uint256 last = _lastTimestamp;
        return block.timestamp > last ? uint32(block.timestamp - last) : uint32(0);
    }

    /// @dev The layer-A verdict: time has passed *and* blocks have not been produced across it.
    function _watchdogTripped() internal view returns (bool tripped) {
        uint32 elapsed = _elapsedSinceStamp();
        if (elapsed <= _graceSeconds) return false;
        // `_gapSeconds` is non-zero by construction: the constructor seeds it from `Constants` and
        // {setGapSeconds} rejects zero, so the division below needs no guard.
        uint32 gap = _gapSeconds;
        uint32 produced;
        unchecked {
            // Both operands are the truncated block number, so the wrapping difference is the true delta for any
            // span shorter than 2**32 blocks.
            produced = uint32(block.number) - _lastBlock;
        }
        return uint256(produced) < uint256(elapsed) / uint256(gap);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals: layer B
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The UTC offset in force at `timestamp`, from the governed DST table. The table is ascending and
    ///      non-overlapping, so the scan stops at the first window that starts after the query.
    function _utcOffsetAt(uint256 timestamp) internal view returns (uint256 offsetSeconds) {
        uint256 n = _dstStarts.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 start = _dstStarts[i];
            if (timestamp < start) break;
            if (timestamp < _dstEnds[i]) return UTC_OFFSET_DAYLIGHT;
        }
        return UTC_OFFSET_STANDARD;
    }

    /// @dev Whether the local day is a US equity trading day: a weekday with no holiday bit set.
    function _isTradingDay(uint256 dayIndex) internal view returns (bool trading) {
        uint256 dow = (dayIndex + DOW_EPOCH_SHIFT) % 7;
        if (dow == 0 || dow == 6) return false;
        return !_isHolidayDay(dayIndex);
    }

    /// @dev Whether the local day carries a set bit in its year's holiday bitmap.
    function _isHolidayDay(uint256 dayIndex) internal view returns (bool holiday) {
        (uint256 year, uint256 dayOfYear) = _yearAndDayOfYear(dayIndex);
        if (year > type(uint16).max) return false;
        uint256 index = dayOfYear - 1;
        uint256[2] storage bitmap = _holidayBitmap[uint16(year)];
        return (bitmap[index >> 8] >> (index & 255)) & 1 == 1;
    }

    /// @dev Civil year and 1-based day of year for a days-since-epoch index, by Hinnant's `civil_from_days`
    ///      shifted onto an era starting 0000-03-01 so that the leap day is always last.
    function _yearAndDayOfYear(uint256 dayIndex) internal pure returns (uint256 year, uint256 dayOfYear) {
        uint256 z = dayIndex + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 month = mp < 10 ? mp + 3 : mp - 9;
        if (month <= 2) y += 1;
        year = y;
        dayOfYear = dayIndex - _daysToJanuaryFirst(y) + 1;
    }

    /// @dev Days from the Unix epoch to 1 January of `year`, by Hinnant's `days_from_civil` with `m == 1`.
    function _daysToJanuaryFirst(uint256 year) internal pure returns (uint256 dayIndex) {
        uint256 y = year - 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        // `doy` for 1 January in the March-based era is `(153 * 10 + 2) / 5 == 306`.
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + 306;
        return era * 146_097 + doe - 719_468;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals: the snapshot
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The one place every layer is combined. `constituentId == 0` is a protocol-wide read: layers C, D and E
    ///      have nothing to say about it and are skipped.
    function _snapshot(uint16 constituentId, PoolId poolId) internal view returns (GateSnapshot memory gate) {
        gate.observedAt = uint32(block.timestamp);
        gate.session = sessionAt(block.timestamp);

        (bool refDiverged, bool coverageMissing) = _referenceIntegrity(gate.session);
        gate.watchdogTripped = _watchdogTripped() || coverageMissing;

        ConstituentConfig memory config;
        if (constituentId != 0) {
            config = _constituent(constituentId);
            (uint256 answerUsd8, uint32 answerUpdatedAt, bool fresh) = _feedAnswer(config.token, gate.session);
            gate.answerUsd8 = answerUsd8 > type(uint64).max ? type(uint64).max : uint64(answerUsd8);
            gate.answerUpdatedAt = answerUpdatedAt;
            gate.feedStale = !fresh;
            (gate.corporateFreeze,) = _corporateAction(config);
        }

        uint16 deviationBps;
        if (PoolId.unwrap(poolId) != bytes32(0)) {
            bool haveDeviation;
            (haveDeviation, deviationBps, gate.poolTick, gate.fairTick) = _deviation(poolId, gate.session);
            uint32 since = _divergedSince[poolId];
            gate.diverged = haveDeviation && since != 0 && deviationBps > _divergenceBps
                && block.timestamp >= uint256(since) + uint256(_divergenceSustainSeconds);
        }

        gate.hSessionBps = config.hSessionOverrideSet ? config.hSessionOverrideBps : hSessionBps(gate.session);

        bool frozen =
            _protocolFrozen() || (constituentId != 0 && _constituentFrozen(constituentId)) || gate.corporateFreeze;
        gate.state =
            _resolveState(frozen, gate.diverged, gate.watchdogTripped, gate.feedStale, gate.session, refDiverged);
        gate.dynCapBps = _dynCap(gate.state, deviationBps);
    }

    /// @dev The precedence order, most restrictive first. Several conditions can hold at once; the gate reports
    ///      the one that permits least.
    function _resolveState(
        bool frozen,
        bool diverged,
        bool watchdogTripped,
        bool feedStale,
        Session session,
        bool refDiverged
    ) internal pure returns (GateState gateState) {
        if (frozen) return GateState.SCHEDULED_FREEZE;
        if (diverged) return GateState.DIVERGED;
        if (watchdogTripped) return GateState.WATCHDOG;
        if (feedStale || session == Session.CLOSED) return GateState.DEGRADED;
        if (refDiverged) return GateState.REF_DIVERGED;
        return GateState.GREEN;
    }

    /// @dev The hook's dynamic-fee cap. Band escalation is approximated by the protocol's own "beyond the inner
    ///      band" marker, `Constants.PLACEMENT_DIVERGENCE_TICKS`: a pool that far from fair is escalating whatever
    ///      the gate state says. `REF_DIVERGED` keeps the normal cap because nothing about the pool has changed.
    function _dynCap(GateState gateState, uint16 deviationBps) internal pure returns (uint16 cap) {
        if (deviationBps > uint16(uint24(Constants.PLACEMENT_DIVERGENCE_TICKS))) {
            return Constants.DYN_CAP_ESCALATION_BPS;
        }
        if (gateState == GateState.GREEN || gateState == GateState.REF_DIVERGED) {
            return Constants.DYN_CAP_NORMAL_BPS;
        }
        return Constants.DYN_CAP_DEGRADED_BPS;
    }

    /// @dev Whether the guardian's protocol-wide freeze is live right now.
    function _protocolFrozen() internal view returns (bool frozen) {
        return _protocolFreezeUntil > block.timestamp;
    }

    /// @dev Whether a constituent's guardian freeze is live right now.
    function _constituentFrozen(uint16 constituentId) internal view returns (bool frozen) {
        return _constituentFreezeUntil[constituentId] > block.timestamp;
    }

    /// @dev Guardian freezes must end, and must end within `GUARDIAN_FREEZE_MAX_SECONDS`.
    function _requireFreezeWindow(uint32 until) internal view {
        uint256 floorTs = block.timestamp + 1;
        uint256 ceilTs = block.timestamp + Constants.GUARDIAN_FREEZE_MAX_SECONDS;
        if (until < floorTs || until > ceilTs) revert OutOfBand("freezeUntil", until, floorTs, ceilTs);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals: layers C, D, E, F
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Layer C, through a bounded call so a mis-pointed registry degrades rather than reverts.
    /// @dev `latestAnswerIn` first, `latestAnswer` second. Handing the registry the session this contract has
    ///      already computed keeps `OracleGate -> FeedRegistry -> OracleGate` off every path the hook pays for;
    ///      the fallback exists so that a layer-C pointer which answers the older read but not the session-scoped
    ///      one still degrades to a working answer rather than to "no answer at all".
    function _feedAnswer(address token, Session session)
        internal
        view
        returns (uint256 answerUsd8, uint32 updatedAt, bool fresh)
    {
        address feeds = _feedRegistry;
        if (token == address(0) || feeds == address(0) || feeds.code.length == 0) return (0, 0, false);
        try IFeedRegistry(feeds).latestAnswerIn{gas: PROBE_GAS * 4}(token, session) returns (
            uint256 answerUsd8_, uint32 updatedAt_, bool fresh_
        ) {
            return (answerUsd8_, updatedAt_, fresh_);
        } catch {}
        try IFeedRegistry(feeds).latestAnswer{gas: PROBE_GAS * 8}(token) returns (
            uint256 answerUsd8_, uint32 updatedAt_, bool fresh_
        ) {
            return (answerUsd8_, updatedAt_, fresh_);
        } catch {
            return (0, 0, false);
        }
    }

    /// @dev Layer D: four bounded probes into the Stock Token, plus the registry's forced-freeze override. A probe
    ///      that fails is *unknown*, never a revert; an unknown `oraclePaused()` is read as not-paused, but an
    ///      unknown multiplier pair alongside a pending `effectiveAt` is read as a change in flight, because the
    ///      only thing an `effectiveAt` is ever set for is a change.
    function _corporateAction(ConstituentConfig memory config) internal view returns (bool frozen, uint32 effectiveAt) {
        if (config.caFreezeOverride) frozen = true;
        address token = config.token;
        if (token == address(0) || token.code.length == 0) return (frozen, 0);

        (bool okPaused, uint256 paused) = _probeWord(token, IStockToken.oraclePaused.selector);
        if (okPaused && paused != 0) frozen = true;

        (bool okEffective, uint256 effective) = _probeWord(token, IStockToken.effectiveAt.selector);
        if (!okEffective || effective == 0) return (frozen, 0);
        effectiveAt = effective > type(uint32).max ? type(uint32).max : uint32(effective);

        (bool okNew, uint256 newMultiplier) = _probeWord(token, IStockToken.newUIMultiplier.selector);
        (bool okCurrent, uint256 currentMultiplier) = _probeWord(token, IStockToken.uiMultiplier.selector);
        bool changePending = !okNew || !okCurrent || newMultiplier != currentMultiplier;

        uint256 window = _corporateActionWindow;
        bool insideWindow = effective <= block.timestamp + window && effective + window >= block.timestamp;
        if (changePending && insideWindow) frozen = true;
    }

    /// @dev Layer E's measurement: `|poolTick - fairTick|`, reported in bps on the standard first-order identity
    ///      that one tick is one basis point. The approximation understates the true percentage deviation for
    ///      large gaps, so the breaker trips marginally *late* rather than early, which is the safe direction for
    ///      a circuit breaker that closes markets.
    function _deviation(PoolId poolId, Session session)
        internal
        view
        returns (bool ok, uint16 deviationBps, int24 poolTick, int24 fairTick)
    {
        PoolConfig memory pool = _poolConfig(poolId);
        if (!pool.registered) return (false, 0, 0, 0);

        // Cheapest read first: with no tick of its own the pool has nothing to compare, whatever the reference
        // would have said.
        (bool havePool, int24 observed) = _lastTruncatedTick(poolId);
        if (!havePool) return (false, 0, 0, 0);

        (bool haveAmps, uint256 ampsUsd18) = _ampsPriceViaPool(_hubPoolId(), session);
        if (!haveAmps) return (false, 0, observed, 0);

        (uint256 counterUsd8,,) = _feedAnswer(pool.counter, session);
        if (counterUsd8 == 0) return (false, 0, observed, 0);

        int24 fair;
        try _priceMath.fairTick{gas: PROBE_GAS}(
            ampsUsd18, counterUsd8, pool.counterDecimals, pool.tickSpacing
        ) returns (
            int24 fair_
        ) {
            fair = fair_;
        } catch {
            return (false, 0, observed, 0);
        }

        int256 delta = int256(observed) - int256(fair);
        uint256 magnitude = delta >= 0 ? uint256(delta) : uint256(-delta);
        return (true, magnitude >= type(uint16).max ? type(uint16).max : uint16(magnitude), observed, fair);
    }

    /// @dev Layer F. `coverageMissing` is the hub's ring failing to reach back over the TWAP window, which is the
    ///      "no observations" half of the watchdog; the WETH leg being unavailable only means the cross-check
    ///      cannot be made, which is not by itself a divergence.
    function _referenceIntegrity(Session session) internal view returns (bool refDiverged, bool coverageMissing) {
        // Both pool ids are resolved before either is priced, so a registry that cannot answer at all fails the
        // same way on both legs rather than short-circuiting on the first.
        PoolId hub = _hubPoolId();
        PoolId weth = _wethPoolId();
        (bool haveHub, uint256 hubUsd18) = _ampsPriceViaPool(hub, session);
        if (!haveHub) return (false, true);
        (bool haveWeth, uint256 wethUsd18) = _ampsPriceViaPool(weth, session);
        if (!haveWeth) return (false, false);

        uint256 diff = hubUsd18 > wethUsd18 ? hubUsd18 - wethUsd18 : wethUsd18 - hubUsd18;
        return (diff * Constants.BPS > uint256(_refDivergenceBps) * hubUsd18, false);
    }

    /// @dev The AMPS price in USD implied by one entry pool's TWAP and its counter asset's Chainlink answer.
    function _ampsPriceViaPool(PoolId poolId, Session session) internal view returns (bool ok, uint256 priceUsd18) {
        if (PoolId.unwrap(poolId) == bytes32(0)) return (false, 0);
        PoolConfig memory pool = _poolConfig(poolId);
        if (!pool.registered) return (false, 0);

        (bool haveTick, int24 meanTick) = _twapTick(poolId);
        if (!haveTick) return (false, 0);

        (uint256 counterUsd8,,) = _feedAnswer(pool.counter, session);
        if (counterUsd8 == 0) return (false, 0);

        try _priceMath.ampsPriceUsd18{gas: PROBE_GAS}(meanTick, counterUsd8, pool.counterDecimals) returns (
            uint256 price18
        ) {
            return (price18 != 0, price18);
        } catch {
            return (false, 0);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals: bounded external reads
    // -------------------------------------------------------------------------------------------------------------

    /// @dev One bounded `staticcall` returning a single word. A codeless target answers with no data, which is
    ///      read as "unknown" rather than as a revert.
    function _probeWord(address target, bytes4 selector) internal view returns (bool ok, uint256 word) {
        (bool success, bytes memory data) =
            target.staticcall{gas: Constants.STOCK_TOKEN_PROBE_GAS}(abi.encodeWithSelector(selector));
        if (!success || data.length < 32) return (false, 0);
        assembly ("memory-safe") {
            word := mload(add(data, 0x20))
        }
        return (true, word);
    }

    /// @dev The registry's constituent record, or an empty one when the registry is unset or unreadable.
    function _constituent(uint16 constituentId) internal view returns (ConstituentConfig memory config) {
        address reg = _registry;
        if (reg == address(0) || reg.code.length == 0) return config;
        try IPoolRegistry(reg).constituent{gas: PROBE_GAS * 2}(constituentId) returns (
            ConstituentConfig memory config_
        ) {
            return config_;
        } catch {
            return config;
        }
    }

    /// @dev The registry's pool record, or an empty one when the registry is unset or unreadable.
    function _poolConfig(PoolId poolId) internal view returns (PoolConfig memory config) {
        address reg = _registry;
        if (reg == address(0) || reg.code.length == 0) return config;
        try IPoolRegistry(reg).poolConfig{gas: PROBE_GAS * 2}(poolId) returns (PoolConfig memory config_) {
            return config_;
        } catch {
            return config;
        }
    }

    /// @dev The pool a constituent trades in, or `bytes32(0)`.
    function _poolOf(uint16 constituentId) internal view returns (PoolId poolId) {
        address reg = _registry;
        if (constituentId == 0 || reg == address(0) || reg.code.length == 0) return PoolId.wrap(bytes32(0));
        try IPoolRegistry(reg).poolIdOf{gas: PROBE_GAS}(constituentId) returns (PoolId poolId_) {
            return poolId_;
        } catch {
            return PoolId.wrap(bytes32(0));
        }
    }

    /// @dev The constituent behind a pool, or 0 for an entry pool or an unknown one.
    function _constituentOfPool(PoolId poolId) internal view returns (uint16 constituentId) {
        address reg = _registry;
        if (reg == address(0) || reg.code.length == 0) return 0;
        try IPoolRegistry(reg).constituentOfPool{gas: PROBE_GAS}(poolId) returns (uint16 constituentId_) {
            return constituentId_;
        } catch {
            return 0;
        }
    }

    /// @dev The `AMPS/USDG` hub pool id, or `bytes32(0)`.
    function _hubPoolId() internal view returns (PoolId poolId) {
        address reg = _registry;
        if (reg == address(0) || reg.code.length == 0) return PoolId.wrap(bytes32(0));
        try IPoolRegistry(reg).hubPoolId{gas: PROBE_GAS}() returns (PoolId poolId_) {
            return poolId_;
        } catch {
            return PoolId.wrap(bytes32(0));
        }
    }

    /// @dev The `AMPS/WETH` entry pool id, or `bytes32(0)`.
    function _wethPoolId() internal view returns (PoolId poolId) {
        address reg = _registry;
        if (reg == address(0) || reg.code.length == 0) return PoolId.wrap(bytes32(0));
        try IPoolRegistry(reg).wethPoolId{gas: PROBE_GAS}() returns (PoolId poolId_) {
            return poolId_;
        } catch {
            return PoolId.wrap(bytes32(0));
        }
    }

    /// @dev The pool's mean truncated tick over the canonical window, refusing to shorten the window: an
    ///      uncovered ring is "no reference", which is what layer F reports as missing coverage.
    function _twapTick(PoolId poolId) internal view returns (bool ok, int24 meanTick) {
        address ref = _marketReference;
        if (ref == address(0) || ref.code.length == 0) return (false, 0);
        uint32 window;
        try IMarketReference(ref).twapWindow{gas: PROBE_GAS}() returns (uint32 window_) {
            window = window_;
        } catch {
            return (false, 0);
        }
        try IMarketReference(ref).observationCoverage{gas: PROBE_GAS}(poolId) returns (uint32 covered) {
            if (covered < window) return (false, 0);
        } catch {
            return (false, 0);
        }
        try IMarketReference(ref).twapTick{gas: PROBE_GAS * 2}(poolId, window) returns (int24 tick) {
            return (true, tick);
        } catch {
            return (false, 0);
        }
    }

    /// @dev The pool's current truncated tick, or "unknown".
    function _lastTruncatedTick(PoolId poolId) internal view returns (bool ok, int24 tick) {
        address ref = _marketReference;
        if (ref == address(0) || ref.code.length == 0) return (false, 0);
        try IMarketReference(ref).lastTruncatedTick{gas: PROBE_GAS}(poolId) returns (int24 tick_) {
            return (true, tick_);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Arms or clears the layer-E timer for one pool and reports any effective state change.
    function _updateDivergence(PoolId poolId) internal {
        if (PoolId.unwrap(poolId) == bytes32(0)) return;
        Session session = sessionAt(block.timestamp);
        (bool ok, uint16 deviationBps,,) = _deviation(poolId, session);
        uint32 since = _divergedSince[poolId];
        bool outside = ok && deviationBps > _divergenceBps;

        if (outside && since == 0) {
            _divergedSince[poolId] = uint32(block.timestamp);
            emit DivergenceLatched(poolId, deviationBps, true);
        } else if (!outside && since != 0) {
            delete _divergedSince[poolId];
            emit DivergenceLatched(poolId, deviationBps, false);
        }
    }
}
