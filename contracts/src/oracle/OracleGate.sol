// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsHook} from "../interfaces/IAmpsHook.sol";
import {IFeedRegistry} from "../interfaces/IFeedRegistry.sol";
import {IMarketReference} from "../interfaces/IMarketReference.sol";
import {IOracleGate} from "../interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {Constants} from "../types/Constants.sol";
import {LengthMismatch, NotGuardian, NotTimelock, OutOfBand, ZeroAddress} from "../types/Errors.sol";
import {GateSnapshot, GateState, Session} from "../types/Types.sol";
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
///        `Constants.STOCK_TOKEN_PROBE_GAS`, **ORed with the hook's own multiplier-step detector**
///        (`IAmpsHook.poolState(poolId).gateFlags` bit 3, `docs/phase3-state-model.md` §10 ruling 10). A pause, a
///        pending `effectiveAt` within `+/- corporateActionWindow` of now, or an armed hook flag is
///        `SCHEDULED_FREEZE` for that constituent and for nothing else. The hook read is bounded and its failure
///        is silent: a market reference that is absent, is not a hook or reverts leaves layer D exactly as Phase 2
///        left it, which is why the token probes are still the primary source rather than a legacy path.
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

    /// @notice Bit 3 of `HookPoolState.gateFlags`: the hook's own corporate-action arm (`caArmed`), set by its
    ///         `uiMultiplier()` step detector when a step exceeds `Constants.DIVIDEND_STEP_BPS_MAX`.
    uint256 public constant HOOK_GATE_FLAG_CA_ARMED = 0x08;

    /// @dev Words in an ABI-encoded `HookPoolState`: 25 static fields, one word each. A hook that appends fields
    ///      still answers with at least this many, and every field this contract reads keeps its index.
    uint256 private constant HOOK_POOL_STATE_WORDS = 25;

    /// @dev Index of `gateFlags` inside that encoding.
    uint256 private constant HOOK_POOL_STATE_GATE_FLAGS_WORD = 22;

    /// @dev Words in an ABI-encoded `ConstituentConfig`: thirteen static fields, one word each. Appending a
    ///      fourteenth keeps every index this contract reads (0 `token`, 5 `hSessionOverrideBps`,
    ///      6 `hSessionOverrideSet`, 7 `caFreezeOverride`), which is what the append-only rule on the struct buys.
    uint256 private constant CONSTITUENT_WORDS = 13;

    /// @dev Words in an ABI-encoded `PoolConfig`: eight static fields. This contract reads 0 `counter`,
    ///      2 `counterDecimals`, 3 `tickSpacing` and 6 `registered`.
    uint256 private constant POOL_WORDS = 8;

    /// @dev Words in an ABI-encoded `(uint256, uint32, bool)`: the feed registry's answer triple.
    uint256 private constant ANSWER_WORDS = 3;

    /// @dev Words in an ABI-encoded `FeedStatus`: nine static fields, so the struct is encoded inline with no
    ///      offset word. This contract reads 0 `answerUsd8`, 1 `updatedAt`, 5 `fresh` and 7 `unconfirmed`.
    uint256 private constant STATUS_WORDS = 9;

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
        (address token, bool caFreezeOverride,,) = _constituent(constituentId);
        (bool frozen, uint32 effectiveAt) = _corporateAction(token, caFreezeOverride, poolId);
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

        bool hSessionOverrideSet;
        uint16 hSessionOverrideBps;
        if (constituentId != 0) {
            address token;
            bool caFreezeOverride;
            (token, caFreezeOverride, hSessionOverrideSet, hSessionOverrideBps) = _constituent(constituentId);
            (uint256 answerUsd8, uint32 answerUpdatedAt, bool fresh, bool unconfirmed) =
                _feedAnswer(token, gate.session);
            gate.answerUsd8 = answerUsd8 > type(uint64).max ? type(uint64).max : uint64(answerUsd8);
            gate.answerUpdatedAt = answerUpdatedAt;
            // An unconfirmed answer is a stale one for every consumer of this snapshot: layer C is telling the
            // gate it does not yet stand behind the number it just handed over.
            gate.feedStale = !fresh || unconfirmed;
            (gate.corporateFreeze,) = _corporateAction(token, caFreezeOverride, poolId);
        }

        uint16 deviationBps;
        if (PoolId.unwrap(poolId) != bytes32(0)) {
            bool haveDeviation;
            (haveDeviation, deviationBps, gate.poolTick, gate.fairTick) = _deviation(poolId, gate.session);
            uint32 since = _divergedSince[poolId];
            gate.diverged = haveDeviation && since != 0 && deviationBps > _divergenceBps
                && block.timestamp >= uint256(since) + uint256(_divergenceSustainSeconds);
        }

        gate.hSessionBps = hSessionOverrideSet ? hSessionOverrideBps : hSessionBps(gate.session);
        // A stale or unconfirmed feed keeps the bond market open (Decision 10) but must never price it at the
        // regular session's 0 bp: the collateral valuation the accretion floor is built on is exactly the number
        // layer C has just disowned. The weekend haircut is the floor, because a feed that stopped answering is
        // the same exposure as a market that stopped trading. A per-constituent override is subject to it too.
        if (gate.feedStale) {
            uint16 closedBps = hSessionBps(Session.CLOSED);
            if (gate.hSessionBps < closedBps) gate.hSessionBps = closedBps;
        }

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
    /// @dev `feedStatusIn` first, then `latestAnswerIn`, then `latestAnswer`. Handing the registry the session this
    ///      contract has already computed keeps `OracleGate -> FeedRegistry -> OracleGate` off every path the hook
    ///      pays for; the two fallbacks exist so that a layer-C pointer which answers only an older read still
    ///      degrades to a working answer rather than to "no answer at all".
    /// @dev **Why the full status and not the answer triple.** `latestAnswerIn` reports the freshness bound and
    ///      nothing else, so a jump the two-confirmation rule is holding back reads as a perfectly current price.
    ///      The status struct carries `unconfirmed` alongside `fresh`, and this contract treats the two the same
    ///      way: an answer nothing has confirmed is not a price the protocol may act on, so {_snapshot} folds it
    ///      into `feedStale`, which degrades the gate and widens the bond haircut. A registry too old to answer
    ///      {IFeedRegistry.feedStatusIn} reports `unconfirmed == false` here, which is the pre-existing behaviour.
    /// @return answerUsd8 The answer, 8 decimals, or zero when layer C could not be read at all.
    /// @return updatedAt When that answer was published.
    /// @return fresh Whether it is inside the session-scaled freshness bound.
    /// @return unconfirmed Whether the two-confirmation rule is holding a jump behind it.
    function _feedAnswer(address token, Session session)
        internal
        view
        returns (uint256 answerUsd8, uint32 updatedAt, bool fresh, bool unconfirmed)
    {
        if (token == address(0)) return (0, 0, false, false);
        address feeds = _feedRegistry;
        (bool ok, bytes memory data) = _read(
            feeds,
            PROBE_GAS * 8,
            abi.encodeWithSelector(IFeedRegistry.feedStatusIn.selector, token, uint8(session)),
            STATUS_WORDS
        );
        if (ok) return (_wordAt(data, 0), _u32At(data, 1), _wordAt(data, 5) != 0, _wordAt(data, 7) != 0);

        (ok, data) = _read(
            feeds,
            PROBE_GAS * 4,
            abi.encodeWithSelector(IFeedRegistry.latestAnswerIn.selector, token, uint8(session)),
            ANSWER_WORDS
        );
        if (!ok) {
            (ok, data) = _read(
                feeds, PROBE_GAS * 8, abi.encodeWithSelector(IFeedRegistry.latestAnswer.selector, token), ANSWER_WORDS
            );
        }
        if (!ok) return (0, 0, false, false);
        return (_wordAt(data, 0), _u32At(data, 1), _wordAt(data, 2) != 0, false);
    }

    /// @dev Layer D: the hook's own multiplier-step detector, four bounded probes into the Stock Token, and the
    ///      registry's forced-freeze override, ORed. A probe that fails is *unknown*, never a revert; an unknown
    ///      `oraclePaused()` is read as not-paused, but an unknown multiplier pair alongside a pending
    ///      `effectiveAt` is read as a change in flight, because the only thing an `effectiveAt` is ever set for
    ///      is a change.
    /// @dev **Ruling 10.** The hook watches `uiMultiplier()` on every gate-cache refresh and arms
    ///      {HOOK_GATE_FLAG_CA_ARMED} on a step larger than `Constants.DIVIDEND_STEP_BPS_MAX`, which is a signal
    ///      this contract cannot see for itself: the gate is only called when somebody calls it, while the hook is
    ///      called on every swap. Reading it here gives layer D a detector with the pool's own cadence. The token
    ///      probes stay exactly as they were and are the fallback whenever the hook is absent, is not a hook, or
    ///      cannot answer.
    function _corporateAction(address token, bool caFreezeOverride, PoolId poolId)
        internal
        view
        returns (bool frozen, uint32 effectiveAt)
    {
        if (caFreezeOverride) frozen = true;
        if (!frozen && _hookCorporateArmed(poolId)) frozen = true;
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
        // Cheapest read first: with no tick of its own the pool has nothing to compare, whatever the reference
        // would have said.
        (bool havePool, int24 observed) = _lastTruncatedTick(poolId);
        if (!havePool) return (false, 0, 0, 0);

        (bool haveFair, int24 fair) = _fairTick(poolId, session);
        if (!haveFair) return (false, 0, observed, 0);

        int256 delta = int256(observed) - int256(fair);
        uint256 magnitude = delta >= 0 ? uint256(delta) : uint256(-delta);
        return (true, magnitude >= type(uint16).max ? type(uint16).max : uint16(magnitude), observed, fair);
    }

    /// @dev The tick one pool *should* trade at: the hub's implied AMPS price against the pool's own counter
    ///      answer, converted by `GatePriceMath` behind a bounded call. Split out of {_deviation} so neither
    ///      function carries the other's locals.
    function _fairTick(PoolId poolId, Session session) internal view returns (bool ok, int24 tick) {
        (bool registered, address counter, uint8 counterDecimals, int24 tickSpacing) = _poolConfig(poolId);
        if (!registered) return (false, 0);

        (bool haveAmps, uint256 ampsUsd18) = _ampsPriceViaPool(_hubPoolId(), session);
        if (!haveAmps) return (false, 0);

        (uint256 counterUsd8,,,) = _feedAnswer(counter, session);
        if (counterUsd8 == 0) return (false, 0);

        (bool haveFair, bytes memory data) = _read(
            address(_priceMath),
            PROBE_GAS,
            abi.encodeWithSelector(
                GatePriceMath.fairTick.selector, ampsUsd18, counterUsd8, counterDecimals, tickSpacing
            ),
            1
        );
        if (!haveFair) return (false, 0);
        return (true, _tickAt(data, 0));
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
        (bool registered, address counter, uint8 counterDecimals,) = _poolConfig(poolId);
        if (!registered) return (false, 0);

        (bool haveTick, int24 meanTick) = _twapTick(poolId);
        if (!haveTick) return (false, 0);

        (uint256 counterUsd8,,,) = _feedAnswer(counter, session);
        if (counterUsd8 == 0) return (false, 0);

        (bool havePrice, bytes memory data) = _read(
            address(_priceMath),
            PROBE_GAS,
            abi.encodeWithSelector(GatePriceMath.ampsPriceUsd18.selector, meanTick, counterUsd8, counterDecimals),
            1
        );
        if (!havePrice) return (false, 0);
        priceUsd18 = _wordAt(data, 0);
        return (priceUsd18 != 0, priceUsd18);
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

    /// @dev The four fields of the registry's constituent record this contract consumes: the token layer D
    ///      probes, the governance-forced freeze, and the per-constituent bond-haircut override. Narrower than
    ///      `ConstituentConfig` on purpose — a helper that rebuilt the whole thirteen-field struct would cost
    ///      EIP-170 headroom to produce nine fields nobody here reads.
    function _constituent(uint16 constituentId)
        internal
        view
        returns (address token, bool caFreezeOverride, bool hSessionOverrideSet, uint16 hSessionOverrideBps)
    {
        (bool ok, bytes memory data) = _read(
            _registry,
            PROBE_GAS * 2,
            abi.encodeWithSelector(IPoolRegistry.constituent.selector, constituentId),
            CONSTITUENT_WORDS
        );
        if (!ok) return (address(0), false, false, 0);
        return (address(uint160(_wordAt(data, 0))), _wordAt(data, 7) != 0, _wordAt(data, 6) != 0, _u16At(data, 5));
    }

    /// @dev The four fields of the registry's pool record this contract consumes. Same reasoning as
    ///      {_constituent}: `PoolConfig`'s other four fields are the hook's and the valuer's, not the gate's.
    function _poolConfig(PoolId poolId)
        internal
        view
        returns (bool registered, address counter, uint8 counterDecimals, int24 tickSpacing)
    {
        (bool ok, bytes memory data) = _read(
            _registry, PROBE_GAS * 2, abi.encodeWithSelector(IPoolRegistry.poolConfig.selector, poolId), POOL_WORDS
        );
        if (!ok) return (false, address(0), 0, 0);
        uint256 decimals = _wordAt(data, 2);
        return (
            _wordAt(data, 6) != 0,
            address(uint160(_wordAt(data, 0))),
            decimals > type(uint8).max ? type(uint8).max : uint8(decimals),
            _tickAt(data, 3)
        );
    }

    /// @dev The pool a constituent trades in, or `bytes32(0)`.
    function _poolOf(uint16 constituentId) internal view returns (PoolId poolId) {
        if (constituentId == 0) return PoolId.wrap(bytes32(0));
        (bool ok, bytes memory data) =
            _read(_registry, PROBE_GAS, abi.encodeWithSelector(IPoolRegistry.poolIdOf.selector, constituentId), 1);
        return PoolId.wrap(ok ? bytes32(_wordAt(data, 0)) : bytes32(0));
    }

    /// @dev The constituent behind a pool, or 0 for an entry pool or an unknown one.
    function _constituentOfPool(PoolId poolId) internal view returns (uint16 constituentId) {
        (bool ok, bytes memory data) =
            _read(_registry, PROBE_GAS, abi.encodeWithSelector(IPoolRegistry.constituentOfPool.selector, poolId), 1);
        return ok ? _u16At(data, 0) : 0;
    }

    /// @dev The `AMPS/USDG` hub pool id, or `bytes32(0)`.
    function _hubPoolId() internal view returns (PoolId poolId) {
        (bool ok, bytes memory data) =
            _read(_registry, PROBE_GAS, abi.encodeWithSelector(IPoolRegistry.hubPoolId.selector), 1);
        return PoolId.wrap(ok ? bytes32(_wordAt(data, 0)) : bytes32(0));
    }

    /// @dev The `AMPS/WETH` entry pool id, or `bytes32(0)`.
    function _wethPoolId() internal view returns (PoolId poolId) {
        (bool ok, bytes memory data) =
            _read(_registry, PROBE_GAS, abi.encodeWithSelector(IPoolRegistry.wethPoolId.selector), 1);
        return PoolId.wrap(ok ? bytes32(_wordAt(data, 0)) : bytes32(0));
    }

    /// @dev The pool's mean truncated tick over the reference's own window, refusing to shorten it: an uncovered
    ///      ring is "no reference", which is what layer F reports as missing coverage.
    /// @dev **The window is bounded by the governable band, not taken on trust.** A market reference that claims a
    ///      zero window, or one wider than `Constants.TWAP_WINDOW_MAX`, is not a reference this contract can use:
    ///      the first cannot be consulted at all and the second is a claim no honest hook can make, because
    ///      `TruncatedOracleLib`'s ring is sized to exactly that ceiling. Both read as "no reference" rather than
    ///      as a window to obey, which is what stops a garbage answer from becoming a garbage price.
    function _twapTick(PoolId poolId) internal view returns (bool ok, int24 meanTick) {
        address ref = _marketReference;
        (bool haveWindow, bytes memory data) =
            _read(ref, PROBE_GAS, abi.encodeWithSelector(IMarketReference.twapWindow.selector), 1);
        if (!haveWindow) return (false, 0);
        uint32 window = _u32At(data, 0);
        if (window < Constants.TWAP_WINDOW_MIN || window > Constants.TWAP_WINDOW_MAX) return (false, 0);

        (bool haveCoverage, bytes memory coverage) =
            _read(ref, PROBE_GAS, abi.encodeWithSelector(IMarketReference.observationCoverage.selector, poolId), 1);
        if (!haveCoverage || _u32At(coverage, 0) < window) return (false, 0);

        (bool haveTick, bytes memory tick) =
            _read(ref, PROBE_GAS * 2, abi.encodeWithSelector(IMarketReference.twapTick.selector, poolId, window), 1);
        if (!haveTick) return (false, 0);
        return (true, _tickAt(tick, 0));
    }

    /// @dev Ruling 10's read: bit 3 (`caArmed`) of `IAmpsHook.poolState(poolId).gateFlags`, through one bounded
    ///      `staticcall` whose result is unpacked by hand rather than ABI-decoded.
    ///
    ///      Hand-unpacking is not fussiness. `HookPoolState` carries two enums and a `bool`, and a market reference
    ///      that is not the hook — a Phase 2 mock, a mis-pointed address, a hostile contract — can answer with an
    ///      out-of-range ordinal, which Solidity's decoder answers with a `Panic` that `try`/`catch` does **not**
    ///      catch. That would turn a fallback into a revert on `snapshot`, `state` and `isBondAllowed`, which is
    ///      the opposite of what a fallback is for. Reading two words out of the returndata cannot fail that way.
    ///      This was ruling 10's read alone; §12.4 ruling AA extended the same treatment to every external read in
    ///      this file, which is why it is now built on {_read} like the rest of them.
    ///
    ///      Bit 3 and not bit 1: bit 1 (`corporateFreeze`) is the hook's *cache of this contract's own verdict*,
    ///      refreshed at most once per `Constants.GATE_CACHE_SECONDS_DEFAULT`. Reading it back would close a loop —
    ///      gate freezes, hook caches the freeze, gate reads its own freeze — and latch `SCHEDULED_FREEZE` for that
    ///      constituent forever. Bit 3 is the hook's own observation of the token and has no such feedback path.
    function _hookCorporateArmed(PoolId poolId) internal view returns (bool armed) {
        address ref = _marketReference;
        if (PoolId.unwrap(poolId) == bytes32(0) || ref == address(0) || ref.code.length == 0) return false;

        (bool ok, bytes memory data) = _read(
            ref, PROBE_GAS * 4, abi.encodeWithSelector(IAmpsHook.poolState.selector, poolId), HOOK_POOL_STATE_WORDS
        );
        if (!ok) return false;
        return _wordAt(data, 0) != 0 && _wordAt(data, HOOK_POOL_STATE_GATE_FLAGS_WORD) & HOOK_GATE_FLAG_CA_ARMED != 0;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals: the read primitive every bounded call above is built from
    // -------------------------------------------------------------------------------------------------------------
    //
    // **Nothing above is a typed `try`, and that is the point.** Solidity decodes a *successful* call's returndata
    // in the caller's frame, so a callee that answers with five bytes, with no bytes, or with a word that does not
    // fit the declared type raises a `Panic` that `try`/`catch` cannot catch. A gate built on typed `try` reads
    // therefore survives a dependency that *reverts* and not one that lies about its shape, which would turn
    // `snapshot`, `state`, `isBondAllowed`, `checkBond`, `isPlacementAllowed` and `dynCapBps` — every read the
    // hook, the quoter, the bond shell and the placement path make — into reverts precisely when they most need to
    // degrade. Reading whole words out of the returndata and saturating them into their declared ranges cannot
    // fail that way: a short answer is "unknown", and a garbage word is a saturated value the layers above already
    // treat as garbage.
    //
    // The three pointers behind these reads (`marketReference`, `registry`, `feedRegistry`) are 7-day timelocked
    // addresses and never user input, so this is defence in depth against a mis-pointed or half-migrated
    // dependency rather than against a caller. `redeemProRata` reads none of it.

    /// @dev One bounded `staticcall`, answered only when the callee returned at least `minWords` whole words.
    ///      A zero, codeless, reverting, out-of-gas or too-short target is "unknown"; the caller decides what
    ///      unknown means for its layer.
    function _read(address target, uint256 gasCap, bytes memory payload, uint256 minWords)
        private
        view
        returns (bool ok, bytes memory data)
    {
        if (target == address(0) || target.code.length == 0) return (false, data);
        (bool success, bytes memory returned) = target.staticcall{gas: gasCap}(payload);
        if (!success || returned.length < minWords * 32) return (false, data);
        return (true, returned);
    }

    /// @dev Word `index` of a buffer whose length {_read} has already checked.
    function _wordAt(bytes memory data, uint256 index) private pure returns (uint256 word) {
        assembly ("memory-safe") {
            word := mload(add(data, add(0x20, mul(index, 0x20))))
        }
    }

    /// @dev One returndata word as an `int24`, saturating instead of reverting on anything that does not fit.
    function _tickAt(bytes memory data, uint256 index) private pure returns (int24 tick) {
        int256 value = int256(_wordAt(data, index));
        if (value > type(int24).max) return type(int24).max;
        if (value < type(int24).min) return type(int24).min;
        return int24(value);
    }

    /// @dev One returndata word as a `uint32`, saturating.
    function _u32At(bytes memory data, uint256 index) private pure returns (uint32 value) {
        uint256 word = _wordAt(data, index);
        return word > type(uint32).max ? type(uint32).max : uint32(word);
    }

    /// @dev One returndata word as a `uint16`, saturating.
    function _u16At(bytes memory data, uint256 index) private pure returns (uint16 value) {
        uint256 word = _wordAt(data, index);
        return word > type(uint16).max ? type(uint16).max : uint16(word);
    }

    /// @dev The pool's current truncated tick, or "unknown".
    function _lastTruncatedTick(PoolId poolId) internal view returns (bool ok, int24 tick) {
        (bool read, bytes memory data) = _read(
            _marketReference, PROBE_GAS, abi.encodeWithSelector(IMarketReference.lastTruncatedTick.selector, poolId), 1
        );
        if (!read) return (false, 0);
        return (true, _tickAt(data, 0));
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
