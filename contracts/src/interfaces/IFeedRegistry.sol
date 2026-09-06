// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeedConfig, FeedStatus, Session} from "../types/Types.sol";

/// @title IFeedRegistry
/// @notice The single place Amplestocks reads a Chainlink answer. Layer C of the oracle design: per-feed
///         heartbeats and bounds, session-scaled freshness, and the sanity checks that stand between a bad answer
///         and the NAV.
///
/// @dev Pointer-upgradeable behind the 7-day timelock (it holds no funds); individual feed addresses are also 7-day
///      changes because a swapped feed is indistinguishable from a swapped price.
///
/// @dev **Rules that are not negotiable**, each of which has bitten a protocol on a public chain:
///        1. **Standard proxy only.** Chainlink's SVR (secondary/"smart value recapture") proxies for the same
///           ticker return the same number with different liveness guarantees. {setFeed} hard-`require`s the
///           Standard proxy; there is no override.
///        2. **`answer > 0` and `updatedAt != 0`.** A zero or negative answer is rejected, never floored to zero.
///        3. **Per-ticker bounds.** `minAnswerUsd8 <= answer <= maxAnswerUsd8`, recorded per feed. This is the
///           check that survives an aggregator returning its own circuit-breaker floor.
///        4. **Two-confirmation rule on jumps.** A single-round move above `Constants.ANSWER_JUMP_BPS` (10%) is
///           not accepted until a second round confirms it; until then the previous answer stands and the feed is
///           reported as unconfirmed rather than stale.
///        5. **Never multiplied by `uiMultiplier()`.** A Stock Token's display multiplier and its Chainlink answer
///           are already in the same units. See `IStockToken`.
///
/// @dev **Session-scaled freshness.** The equity feeds are 24/5 with an 86,400 s heartbeat and hold Friday's close
///      over the weekend, so a single `maxAge` is either uselessly loose in the Regular session or trips every
///      Saturday. The bound is `heartbeat x freshnessMultiplier[session] / 100`, with the check **disabled
///      entirely** when the session is `CLOSED` — a closed market's held answer is not stale, it is correct, and
///      the bond path prices it with a haircut instead.
///
/// @dev **Staleness policy is per path, not global**, and is enforced by the *caller*, not here:
///
///      | Path                | Behaviour on a stale feed |
///      |---------------------|---------------------------|
///      | placements, compound | pause |
///      | bonds               | continue, priced at `q_floor` with `h_session` |
///      | swaps               | continue (fees widen; a swap never reverts for a gate reason) |
///      | `redeemProRata`     | feeds are not read at all |
interface IFeedRegistry {
    /// @notice The answer currently in force for a token, as latched by {refresh} or {setFeed}. One storage slot:
    ///         `[0..127] answerUsd8 | [128..159] updatedAt | [160..239] roundId`.
    /// @param answerUsd8 The accepted answer, 8 decimals. Zero means "never latched".
    /// @param updatedAt The `updatedAt` of the round the answer came from.
    /// @param roundId The round the answer came from.
    struct Accepted {
        uint128 answerUsd8;
        uint32 updatedAt;
        uint80 roundId;
    }

    /// @notice A candidate answer held back by the two-confirmation rule. One storage slot:
    ///         `[0..127] answerUsd8 | [128..159] seenAt | [160..239] roundId`.
    /// @param answerUsd8 The unconfirmed answer, 8 decimals.
    /// @param seenAt When the jump was first recorded, for the `confirmSeconds` escape.
    /// @param roundId The round the jump appeared in.
    struct Pending {
        uint128 answerUsd8;
        uint32 seenAt;
        uint80 roundId;
    }

    /// @notice Emitted when a token's feed is set or replaced. 7-day timelock.
    /// @param token The asset the feed prices.
    /// @param previousAggregator The aggregator being replaced, or `address(0)`.
    /// @param aggregator The new Chainlink Standard proxy.
    event FeedSet(address indexed token, address indexed previousAggregator, address indexed aggregator);

    /// @notice Emitted when a feed's heartbeat, threshold or sanity bounds change. 48-hour timelock.
    /// @param token The asset.
    /// @param heartbeat The new heartbeat in seconds.
    /// @param thresholdBps The new deviation threshold in bps.
    /// @param minAnswerUsd8 The new lower sanity bound.
    /// @param maxAnswerUsd8 The new upper sanity bound.
    event FeedConfigured(
        address indexed token, uint32 heartbeat, uint16 thresholdBps, uint128 minAnswerUsd8, uint128 maxAnswerUsd8
    );

    /// @notice Emitted when a session freshness multiplier changes. 48-hour timelock.
    /// @param session The session the multiplier applies to.
    /// @param multiplier The new multiplier, in hundredths (150 == 1.5x).
    event FreshnessMultiplierSet(Session indexed session, uint16 multiplier);

    /// @notice Emitted when a jump above `ANSWER_JUMP_BPS` is seen and held pending confirmation.
    /// @param token The asset.
    /// @param previousAnswerUsd8 The answer still in force.
    /// @param pendingAnswerUsd8 The unconfirmed answer.
    /// @param roundId The round the jump appeared in.
    event AnswerJumpPending(
        address indexed token, uint256 previousAnswerUsd8, uint256 pendingAnswerUsd8, uint80 roundId
    );

    /// @notice Emitted by {refresh} whenever a new answer becomes the accepted one.
    /// @param token The asset.
    /// @param answerUsd8 The newly accepted answer, 8 decimals.
    /// @param updatedAt The answer's publication timestamp.
    /// @param roundId The round it came from.
    event AnswerLatched(address indexed token, uint256 answerUsd8, uint32 updatedAt, uint80 roundId);

    /// @notice Emitted when an aggregator is added to or removed from the Standard-proxy allowlist.
    /// @param aggregator The aggregator.
    /// @param standard Whether it is now recorded as a Standard proxy.
    event StandardProxySet(address indexed aggregator, bool standard);

    /// @notice No feed is configured for `token`.
    /// @param token The asset queried.
    error FeedNotSet(address token);

    /// @notice The feed answered non-positively, or with `updatedAt == 0`.
    /// @param token The asset.
    /// @param answer The rejected answer.
    error InvalidAnswer(address token, int256 answer);

    /// @notice The answer is outside the per-ticker sanity bounds.
    /// @param token The asset.
    /// @param answerUsd8 The rejected answer.
    /// @param minAnswerUsd8 The lower bound.
    /// @param maxAnswerUsd8 The upper bound.
    error AnswerOutOfBounds(address token, uint256 answerUsd8, uint128 minAnswerUsd8, uint128 maxAnswerUsd8);

    /// @notice The answer is older than the session-scaled freshness bound. Thrown only by {priceUsd8}; callers
    ///         that must degrade rather than revert use {latestAnswer}.
    /// @param token The asset.
    /// @param age The answer's age in seconds.
    /// @param maxAge The bound in force.
    error StaleAnswer(address token, uint32 age, uint32 maxAge);

    /// @notice The supplied aggregator is not the ticker's Standard proxy.
    /// @param aggregator The rejected aggregator.
    error NotStandardProxy(address aggregator);

    /// @notice The aggregator could not be read at all: no code at the address, a revert, or a run out of the
    ///         bounded probe's gas budget. A *dead* feed, as distinct from a stale or an out-of-bounds one.
    /// @dev Thrown only by the reverting paths ({priceUsd8}, {setFeed}). The non-reverting reads report a dead
    ///      aggregator by standing on the last latched answer and letting it age out, which is what lets the gate
    ///      degrade to `DEGRADED` instead of a `checkpoint()` reverting because a third party's contract
    ///      misbehaved.
    /// @param token The asset.
    /// @param aggregator The aggregator that failed to answer.
    error FeedDead(address token, address aggregator);

    // -------------------------------------------------------------------------------------------------------------
    // Reads (permissionless)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The configured feed record for `token`.
    /// @param token The asset.
    /// @return config The record; `config.set == false` when no feed is configured.
    function feedConfig(address token) external view returns (FeedConfig memory config);

    /// @notice The aggregator address for `token`, or `address(0)`.
    /// @param token The asset.
    /// @return aggregator The Chainlink Standard proxy.
    function feedOf(address token) external view returns (address aggregator);

    /// @notice The last accepted answer for `token`, without reverting on staleness.
    /// @dev The non-reverting read every gate-aware path uses: it reports `fresh` so the caller can apply its own
    ///      per-path policy, and it applies the positivity, bounds and two-confirmation rules before returning.
    ///      Returns `answerUsd8 == 0` only when no usable answer exists at all.
    /// @param token The asset.
    /// @return answerUsd8 The answer, 8 decimals.
    /// @return updatedAt When the answer was published.
    /// @return fresh Whether the answer is within the session-scaled bound (always true when the session is
    ///         `CLOSED`, where the check is disabled by design).
    function latestAnswer(address token) external view returns (uint256 answerUsd8, uint32 updatedAt, bool fresh);

    /// @notice The last accepted answer for `token`, reverting unless it is valid *and* fresh.
    /// @dev Used by the placement path, which must pause rather than price on a stale feed.
    /// @param token The asset.
    /// @return answerUsd8 The answer, 8 decimals.
    function priceUsd8(address token) external view returns (uint256 answerUsd8);

    /// @notice The same answer converted to 18-decimal USD through `PriceLib`.
    /// @param token The asset.
    /// @return price18 The answer, 18 decimals.
    function priceUsd18(address token) external view returns (uint256 price18);

    /// @notice {latestAnswer} against an explicitly supplied session.
    /// @dev The gate has already computed the session before it asks layer C anything, so this saves it the round
    ///      trip back into {sessionNow} — and keeps `FeedRegistry -> OracleGate -> FeedRegistry` off every hot
    ///      path. The session only ever selects the freshness bound; it never changes the answer.
    /// @param token The asset.
    /// @param session The equity session to apply.
    /// @return answerUsd8 The answer, 8 decimals; 0 when no usable answer exists.
    /// @return updatedAt When the answer was published.
    /// @return fresh Whether it is inside the session-scaled bound.
    function latestAnswerIn(address token, Session session)
        external
        view
        returns (uint256 answerUsd8, uint32 updatedAt, bool fresh);

    /// @notice The 18-decimal form of {latestAnswer}, for callers that value balances rather than quote prices.
    /// @param token The asset.
    /// @return price18 The answer, 18 decimals; 0 when no usable answer exists.
    /// @return updatedAt When the answer was published.
    /// @return fresh Whether it is inside the session-scaled bound.
    function latestAnswerUsd18(address token) external view returns (uint256 price18, uint32 updatedAt, bool fresh);

    /// @notice The complete, never-reverting read of one feed: the shape `AmpsQuoter` renders and the shape a
    ///         degraded dApp falls back to.
    /// @dev Returns an all-zero struct with `configured == false` for a token with no feed, and never reverts for
    ///      any input, any aggregator behaviour or any session.
    /// @param token The asset.
    /// @return status Everything known about the feed right now.
    function feedStatus(address token) external view returns (FeedStatus memory status);

    /// @notice {feedStatus} against an explicitly supplied session.
    /// @param token The asset.
    /// @param session The equity session to apply.
    /// @return status Everything known about the feed in that session.
    function feedStatusIn(address token, Session session) external view returns (FeedStatus memory status);

    /// @notice The answer currently in force for `token`, as latched by {refresh} or {setFeed}.
    /// @param token The asset.
    /// @return answer The latched record; `answer.answerUsd8 == 0` when nothing has been latched.
    function acceptedAnswer(address token) external view returns (Accepted memory answer);

    /// @notice The unconfirmed jump held for `token`, if any.
    /// @param token The asset.
    /// @return answer The pending record; `answer.roundId == 0` when no jump is pending.
    function pendingAnswer(address token) external view returns (Pending memory answer);

    /// @notice Whether an aggregator has been recorded as a ticker's Chainlink **Standard** proxy.
    /// @dev Governance sets this from the Reference Data Directory. An SVR proxy is simply never added, which is
    ///      what makes {setFeed}'s {NotStandardProxy} check a whitelist rather than a heuristic.
    /// @param aggregator The aggregator.
    /// @return standard Whether it is recorded as a Standard proxy.
    function isStandardProxy(address aggregator) external view returns (bool standard);

    /// @notice The equity session in force, from the gate's calendar.
    /// @dev Falls back to `REGULAR` — the *tightest* freshness bound — when no gate is configured or the gate is
    ///      unreadable, so an unreachable gate degrades paths rather than loosening them.
    /// @return session The session.
    function sessionNow() external view returns (Session session);

    /// @notice The gate this registry asks for the current session.
    /// @return gate The `IOracleGate` address, or `address(0)` when unset.
    function oracleGate() external view returns (address gate);

    /// @notice The two-confirmation escape window: how long an unconfirmed jump is held before it is adopted
    ///         without a second agreeing round.
    /// @return value The window in seconds.
    function confirmSeconds() external view returns (uint32 value);

    /// @notice The freshness bound in force for `token` in `session`.
    /// @param token The asset.
    /// @param session The equity session.
    /// @return bound The bound in seconds. `type(uint32).max` when the session is `CLOSED` (check disabled).
    function maxAge(address token, Session session) external view returns (uint32 bound);

    /// @notice The session freshness multiplier table, in hundredths.
    /// @param session The equity session.
    /// @return multiplier 150 / 300 / 600 for Regular / Pre-Post / Overnight; unused when `CLOSED`.
    function freshnessMultiplier(Session session) external view returns (uint16 multiplier);

    // -------------------------------------------------------------------------------------------------------------
    // Hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Hard floor of a freshness multiplier, in hundredths. 100 (1.0x heartbeat).
    /// @return value The bound.
    function FRESHNESS_MULTIPLIER_MIN() external view returns (uint16 value);

    /// @notice Hard ceiling of a freshness multiplier, in hundredths. 2,400 (24x heartbeat).
    /// @return value The bound.
    function FRESHNESS_MULTIPLIER_MAX() external view returns (uint16 value);

    /// @notice The single-round move that arms the two-confirmation rule, in bps. 1,000.
    /// @return value The bound.
    function ANSWER_JUMP_BPS() external view returns (uint16 value);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — the permissionless latch
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Advances the accepted/pending latch for `token` from the aggregator's current round.
    /// @dev **Permissionless and unpaid**, like `IOracleGate.poke`. Reads are `view` and cannot latch, so this is
    ///      where the two-confirmation rule actually advances. It never reverts for a feed reason: a dead
    ///      aggregator, a bad answer or an out-of-bounds answer leave the latch untouched, because the whole point
    ///      of the latch is to hold the last answer that passed every check. It reverts only with {FeedNotSet}.
    /// @param token The asset to refresh.
    /// @return answerUsd8 The answer in force after the call, 8 decimals.
    /// @return updatedAt Its publication timestamp.
    /// @return fresh Whether it is inside the session-scaled bound.
    function refresh(address token) external returns (uint256 answerUsd8, uint32 updatedAt, bool fresh);

    /// @notice {refresh} for several tokens in one transaction. **Permissionless and unpaid.**
    /// @dev Skips tokens with no configured feed instead of reverting, so a keeper can hand it the whole
    ///      constituent set without first filtering it.
    /// @param tokens The assets to refresh.
    function refreshMany(address[] calldata tokens) external;

    // -------------------------------------------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Sets or replaces the aggregator for `token`. **Only timelock (7 d).**
    /// @dev Reverts with {NotStandardProxy} for an SVR proxy. Replacing a feed does not touch any position or any
    ///      NAV number by itself; the next `checkpoint()` re-reads.
    /// @param token The asset.
    /// @param aggregator The Chainlink Standard proxy.
    /// @param config The heartbeat, threshold and sanity bounds to record with it.
    function setFeed(address token, address aggregator, FeedConfig calldata config) external;

    /// @notice Updates a feed's heartbeat, threshold and sanity bounds. **Only timelock (48 h).**
    /// @param token The asset.
    /// @param heartbeat The heartbeat in seconds.
    /// @param thresholdBps The deviation threshold in bps.
    /// @param minAnswerUsd8 The lower sanity bound.
    /// @param maxAnswerUsd8 The upper sanity bound.
    function configureFeed(
        address token,
        uint32 heartbeat,
        uint16 thresholdBps,
        uint128 minAnswerUsd8,
        uint128 maxAnswerUsd8
    ) external;

    /// @notice Sets a session's freshness multiplier. **Only timelock (48 h).**
    /// @param session The equity session.
    /// @param multiplier The multiplier in hundredths, inside
    ///        `[FRESHNESS_MULTIPLIER_MIN, FRESHNESS_MULTIPLIER_MAX]`.
    function setFreshnessMultiplier(Session session, uint16 multiplier) external;

    /// @notice Sets the two-confirmation escape window. **Only timelock (48 h).**
    /// @param value The window in seconds, inside
    ///        `[Constants.ANSWER_CONFIRM_SECONDS_MIN, Constants.ANSWER_CONFIRM_SECONDS_MAX]`.
    function setConfirmSeconds(uint32 value) external;

    /// @notice Re-points the gate this registry reads the session from. **Only timelock (7 d).**
    /// @dev `OracleGate` is itself pointer-upgradeable, so this pointer moves with it.
    /// @param gate The new gate.
    function setOracleGate(address gate) external;

    /// @notice Records or clears an aggregator's status as a ticker's Chainlink **Standard** proxy.
    ///         **Only timelock (7 d).**
    /// @dev Sourced from the Reference Data Directory. {setFeed} and {configureFeed} both refuse an aggregator
    ///      that is not on this list, which is how SVR proxies are kept out with no heuristic and no override.
    /// @param aggregator The aggregator.
    /// @param standard Whether it is the Standard proxy.
    function setStandardProxy(address aggregator, bool standard) external;

    /// @notice Records several Standard proxies at once. **Only timelock (7 d).**
    /// @param aggregators The aggregators.
    /// @param standard Parallel flags.
    function setStandardProxies(address[] calldata aggregators, bool[] calldata standard) external;
}
