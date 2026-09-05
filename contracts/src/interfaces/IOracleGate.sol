// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {GateSnapshot, GateState, Session} from "../types/Types.sol";

/// @title IOracleGate
/// @notice Layers A-F of the oracle, liveness and freeze design, read identically by the hook, the placement path,
///         `AmpsBonds` and the quoter. Pointer-upgradeable behind the 7-day timelock; holds no funds.
///
/// @dev **The six layers.**
///
///      | Layer | What it watches | Trips to |
///      |---|---|---|
///      | A | block cadence: `(lastBlock, lastTimestamp)` persisted on every state-changing entry, plus a permissionless {poke} | `WATCHDOG` after `GRACE` |
///      | B | market state: a deterministic on-chain 24/5 ET calendar plus a governed holiday bitmap and DST table | sets `Session` |
///      | C | freshness: `heartbeat x freshnessMultiplier[session]`, positivity, per-ticker bounds, two-confirmation jumps (in `FeedRegistry`) | `DEGRADED` |
///      | D | corporate actions: `oraclePaused()` or `effectiveAt` within `corporateActionWindow` | `SCHEDULED_FREEZE` |
///      | E | divergence: `|poolTick - fairTick| > divergenceBps` sustained `divergenceSustainSeconds` | `DIVERGED` |
///      | F | reference integrity: hub TWAP vs `AMPS/WETH x ETH/USD` within `refDivergenceBps` | `REF_DIVERGED` |
///
/// @dev **The gate never stops a swap and never stops a redemption.** A swap is only ever *priced* differently: a
///      non-green gate raises `FROZEN_FEE_FLOOR_BPS` and widens the dynamic cap (I15). `redeemProRata` does not
///      call this contract at all — not `checkX`, not `session()`, not `poke()` — which is what makes the floor
///      structurally unpausable rather than merely un-paused (I14).
///
/// @dev **A no-block substitute, not a sequencer feed.** Robinhood Chain publishes no Chainlink L2 sequencer
///      uptime feed and has no Chainlink Automation, so layer A is a cadence watchdog the protocol maintains
///      itself. It is deliberately cheap to keep honest: every state-changing entry point in the vault stamps it,
///      and {poke} lets anyone stamp it for the cost of gas.
///
/// @dev **Guardian powers are disable-only and expire.** {freezeConstituent} can stop bonds, rollout and
///      placements for one constituent for at most `GUARDIAN_FREEZE_MAX_SECONDS`, and {freezeProtocol} does the
///      same protocol-wide. Neither can move a fund, neither can touch redemption, and both expire without any
///      further action.
interface IOracleGate {
    /// @notice Emitted whenever the effective state for a pool changes. Indexed by the dApp's per-pool status view.
    /// @param poolId The pool, or `bytes32(0)` for a protocol-wide change.
    /// @param previousState The state before.
    /// @param newState The state after.
    event GateChanged(PoolId indexed poolId, GateState previousState, GateState newState);

    /// @notice Emitted by {poke} and by every stamped entry point.
    /// @param blockNumber The block stamped.
    /// @param timestamp The timestamp stamped.
    event WatchdogStamped(uint32 blockNumber, uint32 timestamp);

    /// @notice Emitted when the layer-A watchdog trips or clears.
    /// @param tripped True when tripping, false when clearing.
    /// @param elapsed Seconds since the last stamp at the moment of the change.
    event WatchdogTripped(bool tripped, uint32 elapsed);

    /// @notice Emitted when layer E latches or clears for a pool.
    /// @param poolId The pool.
    /// @param devBps The deviation in bps at the moment of the change.
    /// @param diverged True when latching, false when clearing.
    event DivergenceLatched(PoolId indexed poolId, uint16 devBps, bool diverged);

    /// @notice Emitted when layer D freezes or unfreezes a constituent.
    /// @param constituentId The constituent.
    /// @param frozen True when freezing.
    /// @param effectiveAt The Stock Token's pending `effectiveAt` that caused it, or 0.
    event CorporateActionFreeze(uint16 indexed constituentId, bool frozen, uint32 effectiveAt);

    /// @notice Emitted when the guardian freezes or unfreezes one constituent.
    /// @param constituentId The constituent.
    /// @param until The freeze expiry, or 0 when clearing.
    event ConstituentFreezeSet(uint16 indexed constituentId, uint32 until);

    /// @notice Emitted when the guardian freezes or unfreezes the protocol.
    /// @param until The freeze expiry, or 0 when clearing.
    event ProtocolFreezeSet(uint32 until);

    /// @notice Emitted on every governed parameter change in this contract.
    /// @param parameter The parameter name as a short string.
    /// @param previousValue The value before.
    /// @param newValue The value after.
    event GateParameterChanged(bytes32 indexed parameter, uint256 previousValue, uint256 newValue);

    /// @notice The gate refused the path. Thrown by the `check*` helpers, which are the reverting form of the
    ///         `is*Allowed` views.
    /// @param refusingState The refusing state.
    /// @param poolId The pool, or `bytes32(0)`.
    error GateRefused(GateState refusingState, PoolId poolId);

    // -------------------------------------------------------------------------------------------------------------
    // Reads (permissionless)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The full snapshot for one constituent, including the session, the haircut and the tick pair the
    ///         divergence is measured on.
    /// @param constituentId The constituent, 1-based. Use 0 for a protocol-wide snapshot.
    /// @return gate The snapshot.
    function snapshot(uint16 constituentId) external view returns (GateSnapshot memory gate);

    /// @notice The same snapshot addressed by pool rather than by constituent, so the hook and the quoter need no
    ///         id lookup.
    /// @param poolId The pool.
    /// @return gate The snapshot.
    function snapshotByPool(PoolId poolId) external view returns (GateSnapshot memory gate);

    /// @notice The most restrictive state currently applying to `constituentId`.
    /// @param constituentId The constituent, or 0 for protocol-wide.
    /// @return gateState The state.
    function state(uint16 constituentId) external view returns (GateState gateState);

    /// @notice The equity session right now, from the on-chain 24/5 ET calendar, the holiday bitmap and the DST
    ///         table.
    /// @return session The session.
    function sessionNow() external view returns (Session session);

    /// @notice The equity session at an arbitrary timestamp. Pure with respect to the governed tables.
    /// @param timestamp The timestamp to classify.
    /// @return session The session.
    function sessionAt(uint256 timestamp) external view returns (Session session);

    /// @notice Whole hours the equity market has been continuously closed, used to widen the spoke inner band.
    /// @return hoursClosed Zero when the market is open.
    function closedHours() external view returns (uint16 hoursClosed);

    /// @notice Whether a placement or a `compound` may proceed for `poolId`.
    /// @dev False whenever the gate is anything but GREEN or REF_DIVERGED. Under REF_DIVERGED placements continue
    ///      but anchor at NAV rather than at the rate-limited reference.
    /// @param poolId The pool.
    /// @return allowed Whether the path may proceed.
    /// @return anchorAtNav Whether the caller must anchor at `navPerShare` instead of `P_ref`.
    function isPlacementAllowed(PoolId poolId) external view returns (bool allowed, bool anchorAtNav);

    /// @notice Whether a bond on `constituentId` may proceed, and at what haircut.
    /// @dev Only the corporate-action freeze, a guardian freeze and the divergence breaker close a market. A stale
    ///      feed or a closed session does **not**: the haircut widens instead, which is the 24/7 bond decision.
    /// @param constituentId The constituent.
    /// @return allowed Whether the market may accept a bond.
    /// @return hSessionBps The haircut to apply to the collateral valuation, in bps.
    function isBondAllowed(uint16 constituentId) external view returns (bool allowed, uint16 hSessionBps);

    /// @notice The dynamic-fee cap the hook must apply for `poolId` in its current state.
    /// @param poolId The pool.
    /// @return cap 300 GREEN, 1,000 degraded, 2,000 during band escalation.
    function dynCapBps(PoolId poolId) external view returns (uint16 cap);

    /// @notice Reverting form of {isPlacementAllowed}, for the vault's `_requireHealthy`.
    /// @param poolId The pool.
    /// @return anchorAtNav Whether the caller must anchor at NAV.
    function checkPlacement(PoolId poolId) external view returns (bool anchorAtNav);

    /// @notice Reverting form of {isBondAllowed}.
    /// @param constituentId The constituent.
    /// @return hSessionBps The haircut to apply.
    function checkBond(uint16 constituentId) external view returns (uint16 hSessionBps);

    /// @notice The layer-A watchdog's last stamp.
    /// @return blockNumber The stamped block.
    /// @return timestamp The stamped timestamp.
    /// @return tripped Whether more than `graceSeconds` has elapsed since.
    function watchdog() external view returns (uint32 blockNumber, uint32 timestamp, bool tripped);

    // -------------------------------------------------------------------------------------------------------------
    // Governed parameters
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Layer A: seconds without a stamp before the watchdog trips. 3,600 at launch.
    /// @return value The parameter.
    function graceSeconds() external view returns (uint32 value);

    /// @notice Layer A: the expected worst-case inter-block gap, calibrated from sampled cadence. 120 at launch.
    /// @return value The parameter.
    function gapSeconds() external view returns (uint32 value);

    /// @notice Layer E: the deviation that arms the breaker, in bps. 500 at launch.
    /// @return value The parameter.
    function divergenceBps() external view returns (uint16 value);

    /// @notice Layer E: how long the deviation must persist before `DIVERGED` latches. 60 s at launch.
    /// @return value The parameter.
    function divergenceSustainSeconds() external view returns (uint32 value);

    /// @notice Layer D: how close a pending `effectiveAt` must be to freeze the constituent. 1,800 s at launch.
    /// @return value The parameter.
    function corporateActionWindow() external view returns (uint32 value);

    /// @notice The stale-feed haircut table indexed by {Session}. 0 / 50 / 150 / 300 bp at launch.
    /// @param session The session.
    /// @return bps The haircut.
    function hSessionBps(Session session) external view returns (uint16 bps);

    /// @notice The guardian's protocol-wide freeze expiry, or 0.
    /// @return until The expiry timestamp.
    function protocolFreezeUntil() external view returns (uint32 until);

    /// @notice The guardian's per-constituent freeze expiry, or 0.
    /// @param constituentId The constituent.
    /// @return until The expiry timestamp.
    function constituentFreezeUntil(uint16 constituentId) external view returns (uint32 until);

    // -------------------------------------------------------------------------------------------------------------
    // Hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Hard floor of `graceSeconds`. 300.
    /// @return value The bound.
    function GRACE_SECONDS_MIN() external view returns (uint32 value);

    /// @notice Hard ceiling of `graceSeconds`. 86,400.
    /// @return value The bound.
    function GRACE_SECONDS_MAX() external view returns (uint32 value);

    /// @notice Hard ceiling of `gapSeconds`. 1,800.
    /// @return value The bound.
    function GAP_SECONDS_MAX() external view returns (uint32 value);

    /// @notice Hard ceiling of `divergenceBps`. 2,000.
    /// @return value The bound.
    function DIVERGENCE_BPS_MAX() external view returns (uint16 value);

    /// @notice Hard ceiling of `divergenceSustainSeconds`. 3,600.
    /// @return value The bound.
    function DIVERGENCE_SUSTAIN_SECONDS_MAX() external view returns (uint32 value);

    /// @notice Hard ceiling of `corporateActionWindow`. 86,400.
    /// @return value The bound.
    function CORPORATE_ACTION_WINDOW_MAX() external view returns (uint32 value);

    /// @notice Hard ceiling of any `h_session` entry. 1,000 bp.
    /// @return value The bound.
    function H_SESSION_BPS_MAX() external view returns (uint16 value);

    /// @notice The longest a guardian freeze can last before expiring by itself. 7 days.
    /// @return value The bound.
    function GUARDIAN_FREEZE_MAX_SECONDS() external view returns (uint32 value);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Stamps the layer-A watchdog and re-evaluates the sustained-divergence timers. **Permissionless and
    ///         unpaid** — anyone may call it, and the vault calls it from every state-changing entry point.
    /// @dev Never reverts for a gate reason; a poke during a freeze is exactly what clears the freeze once its
    ///      cause has gone.
    function poke() external;

    /// @notice Freezes one constituent until `until`. **Only guardian.** Disable-only: no bonds, no rollout, no
    ///         placements for that constituent. Swaps and redemption are unaffected.
    /// @param constituentId The constituent.
    /// @param until The expiry, at most `GUARDIAN_FREEZE_MAX_SECONDS` ahead of now.
    function freezeConstituent(uint16 constituentId, uint32 until) external;

    /// @notice Clears a guardian freeze early. **Only guardian or timelock.**
    /// @param constituentId The constituent.
    function unfreezeConstituent(uint16 constituentId) external;

    /// @notice Freezes the protocol until `until`. **Only guardian.** Disable-only and auto-expiring; it cannot
    ///         block `redeemProRata` or `claim` because neither reads this contract.
    /// @param until The expiry, at most `GUARDIAN_FREEZE_MAX_SECONDS` ahead of now.
    function freezeProtocol(uint32 until) external;

    /// @notice Clears the protocol freeze early. **Only guardian or timelock.**
    function unfreezeProtocol() external;

    /// @notice Sets `graceSeconds`. **Only timelock (48 h).**
    /// @param value The new value, inside `[GRACE_SECONDS_MIN, GRACE_SECONDS_MAX]`.
    function setGraceSeconds(uint32 value) external;

    /// @notice Sets `gapSeconds`. **Only timelock (48 h).**
    /// @param value The new value, at most `GAP_SECONDS_MAX`.
    function setGapSeconds(uint32 value) external;

    /// @notice Sets the layer-E threshold. **Only timelock (48 h).**
    /// @param value The new value, at most `DIVERGENCE_BPS_MAX`.
    function setDivergenceBps(uint16 value) external;

    /// @notice Sets the layer-E sustain window. **Only timelock (48 h).**
    /// @param value The new value, at most `DIVERGENCE_SUSTAIN_SECONDS_MAX`.
    function setDivergenceSustainSeconds(uint32 value) external;

    /// @notice Sets the layer-D window. **Only timelock (48 h).**
    /// @param value The new value, at most `CORPORATE_ACTION_WINDOW_MAX`.
    function setCorporateActionWindow(uint32 value) external;

    /// @notice Sets one entry of the stale-feed haircut table. **Only timelock (48 h).**
    /// @param session The session.
    /// @param bps The haircut, at most `H_SESSION_BPS_MAX`.
    function setHSessionBps(Session session, uint16 bps) external;

    /// @notice Replaces the holiday bitmap for one year of the on-chain calendar. **Only timelock (48 h).**
    /// @param year The calendar year.
    /// @param bitmap One bit per day of the year; a set bit means the equity market is closed.
    function setHolidayBitmap(uint16 year, uint256[2] calldata bitmap) external;

    /// @notice Replaces the DST transition table. **Only timelock (48 h).**
    /// @param starts DST start timestamps, ascending.
    /// @param ends DST end timestamps, ascending and parallel to `starts`.
    function setDstTable(uint32[] calldata starts, uint32[] calldata ends) external;
}
