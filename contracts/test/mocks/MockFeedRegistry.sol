// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeedRegistry} from "../../src/interfaces/IFeedRegistry.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {LengthMismatch} from "../../src/types/Errors.sol";
import {FeedConfig, FeedStatus, Session} from "../../src/types/Types.sol";

/// @title MockFeedRegistry
/// @notice Settable stand-in for the accepted-answer store. Every token carries an answer, an `updatedAt` and a
///         freshness flag that a test sets directly, so the weekend, stale-feed and dead-feed cases are one call
///         each rather than a simulated Chainlink round history.
///
/// @dev Fidelity notes the bond suite depends on:
///      - {latestAnswer} never reverts and reports `fresh` separately, which is exactly why `AmpsBonds` can price
///        a bond through a stale feed: the answer feeds the accretion floor and the session haircut bounds it.
///      - {priceUsd8} is the reverting form the placement path uses, and refuses a stale or missing answer.
///      - `setReverting(true)` makes **every** read revert, which is the dead-registry case `claim` must survive
///        and `quote` must degrade on rather than propagate.
///      - The session-scoped reads ({latestAnswerIn}, {feedStatusIn}) ignore the session they are handed and
///        answer from the same stored record: a test moves freshness with {setFresh}, not by moving the clock, so
///        making the session load-bearing here would only let the mock disagree with itself. {sessionNow} reports
///        a settable value for the same reason.
///      - {refresh} is a no-op that returns the stored answer. There is no round history to latch, so the
///        two-confirmation rule has nothing to advance; the real `FeedRegistry` suite covers it.
contract MockFeedRegistry is IFeedRegistry {
    /// @notice One token's answer.
    struct Answer {
        bool set;
        uint128 answerUsd8;
        uint32 updatedAt;
        bool fresh;
    }

    /// @notice When true, every read reverts.
    bool public reverting;

    /// @inheritdoc IFeedRegistry
    /// @dev Purely informational here: the mock never calls the gate.
    address public oracleGate;

    /// @inheritdoc IFeedRegistry
    mapping(address aggregator => bool standard) public isStandardProxy;

    /// @notice The session every session-scoped read reports. Seeded to `REGULAR`.
    Session public session;

    /// @notice The two-confirmation escape window the mock reports.
    uint32 public confirmSeconds = Constants.ANSWER_CONFIRM_SECONDS_DEFAULT;

    mapping(address token => Answer answer) internal _answers;
    mapping(address token => FeedConfig config) internal _configs;
    uint16[4] internal _freshnessMultiplier = [
        Constants.FRESHNESS_MULTIPLIER_REGULAR_DEFAULT,
        Constants.FRESHNESS_MULTIPLIER_PRE_POST_DEFAULT,
        Constants.FRESHNESS_MULTIPLIER_OVERNIGHT_DEFAULT,
        Constants.FRESHNESS_MULTIPLIER_MAX
    ];

    /// @notice Thrown by every read while {reverting} is set.
    error RegistryDown();

    /* ------------------------------------- test setters ------------------------------------- */

    /// @notice Publishes a fresh answer stamped at the current block.
    /// @param token The asset.
    /// @param answerUsd8 The answer, 8 decimals.
    function setAnswer(address token, uint128 answerUsd8) external {
        _answers[token] = Answer({set: true, answerUsd8: answerUsd8, updatedAt: uint32(block.timestamp), fresh: true});
        _configs[token].set = true;
        _configs[token].decimals = 8;
        if (_configs[token].heartbeat == 0) _configs[token].heartbeat = Constants.ONE_DAY;
    }

    /// @notice Sets every field of a token's answer, including a deliberately stale `updatedAt`.
    function setAnswerFull(address token, uint128 answerUsd8, uint32 updatedAt, bool fresh) external {
        _answers[token] = Answer({set: true, answerUsd8: answerUsd8, updatedAt: updatedAt, fresh: fresh});
        _configs[token].set = true;
        _configs[token].decimals = 8;
        if (_configs[token].heartbeat == 0) _configs[token].heartbeat = Constants.ONE_DAY;
    }

    /// @notice Marks a token's existing answer stale (or fresh) without changing it: the weekend case.
    function setFresh(address token, bool fresh) external {
        _answers[token].fresh = fresh;
    }

    /// @notice Removes a token's answer entirely: `latestAnswer` then reports zero, the "no usable answer" case.
    function clearAnswer(address token) external {
        delete _answers[token];
    }

    /// @notice Makes every read revert, or stop reverting.
    function setReverting(bool reverting_) external {
        reverting = reverting_;
    }

    /// @notice Sets the gate pointer this registry reports.
    function setOracleGate(address gate) external {
        oracleGate = gate;
    }

    /// @notice Sets the session every session-scoped read reports.
    function setSession(Session session_) external {
        session = session_;
    }

    /* ------------------------------------- IFeedRegistry ------------------------------------- */

    /// @inheritdoc IFeedRegistry
    function feedConfig(address token) external view returns (FeedConfig memory config) {
        if (reverting) revert RegistryDown();
        config = _configs[token];
    }

    /// @inheritdoc IFeedRegistry
    function feedOf(address token) external view returns (address aggregator) {
        if (reverting) revert RegistryDown();
        aggregator = _configs[token].aggregator;
    }

    /// @inheritdoc IFeedRegistry
    function latestAnswer(address token) external view returns (uint256 answerUsd8, uint32 updatedAt, bool fresh) {
        return latestAnswerIn(token, session);
    }

    /// @inheritdoc IFeedRegistry
    /// @dev The session is ignored: freshness is the stored flag, not a clock comparison.
    function latestAnswerIn(address token, Session)
        public
        view
        returns (uint256 answerUsd8, uint32 updatedAt, bool fresh)
    {
        if (reverting) revert RegistryDown();
        Answer storage answer = _answers[token];
        return (answer.answerUsd8, answer.updatedAt, answer.fresh);
    }

    /// @inheritdoc IFeedRegistry
    function latestAnswerUsd18(address token) external view returns (uint256 price18, uint32 updatedAt, bool fresh) {
        if (reverting) revert RegistryDown();
        Answer storage answer = _answers[token];
        price18 = answer.answerUsd8 == 0
            ? 0
            : PriceLib.counterValueUsd18(PriceLib.WAD, PriceLib.AMPS_DECIMALS, answer.answerUsd8);
        return (price18, answer.updatedAt, answer.fresh);
    }

    /// @inheritdoc IFeedRegistry
    function feedStatus(address token) external view returns (FeedStatus memory status) {
        return feedStatusIn(token, session);
    }

    /// @inheritdoc IFeedRegistry
    /// @dev Never reverts, even while {reverting} is set: {feedStatus} is the read a degraded dApp falls back to,
    ///      and a mock that broke that property would be modelling something the real registry cannot do.
    function feedStatusIn(address token, Session session_) public view returns (FeedStatus memory status) {
        Answer storage answer = _answers[token];
        FeedConfig storage config = _configs[token];
        status.configured = config.set;
        status.answerUsd8 = answer.answerUsd8;
        status.updatedAt = answer.updatedAt;
        status.age = block.timestamp > answer.updatedAt ? uint32(block.timestamp - answer.updatedAt) : 0;
        status.maxAgeSeconds = session_ == Session.CLOSED
            ? type(uint32).max
            : uint32(uint256(config.heartbeat) * _freshnessMultiplier[uint8(session_)] / 100);
        status.fresh = answer.answerUsd8 != 0 && answer.fresh;
        status.live = answer.set;
        return status;
    }

    /// @inheritdoc IFeedRegistry
    function acceptedAnswer(address token) external view returns (Accepted memory answer) {
        Answer storage stored = _answers[token];
        answer = Accepted({answerUsd8: stored.answerUsd8, updatedAt: stored.updatedAt, roundId: 0});
    }

    /// @inheritdoc IFeedRegistry
    /// @dev Always empty: the mock holds no round history, so nothing is ever held back.
    function pendingAnswer(address) external pure returns (Pending memory answer) {
        return answer;
    }

    /// @inheritdoc IFeedRegistry
    function sessionNow() external view returns (Session current) {
        current = session;
    }

    /// @inheritdoc IFeedRegistry
    function priceUsd8(address token) external view returns (uint256 answerUsd8) {
        if (reverting) revert RegistryDown();
        Answer storage answer = _answers[token];
        if (!answer.set || answer.answerUsd8 == 0) revert FeedNotSet(token);
        if (!answer.fresh) revert StaleAnswer(token, uint32(block.timestamp) - answer.updatedAt, 0);
        answerUsd8 = answer.answerUsd8;
    }

    /// @inheritdoc IFeedRegistry
    function priceUsd18(address token) external view returns (uint256 price18) {
        if (reverting) revert RegistryDown();
        Answer storage answer = _answers[token];
        if (!answer.set || answer.answerUsd8 == 0) revert FeedNotSet(token);
        if (!answer.fresh) revert StaleAnswer(token, uint32(block.timestamp) - answer.updatedAt, 0);
        price18 = PriceLib.counterValueUsd18(PriceLib.WAD, PriceLib.AMPS_DECIMALS, answer.answerUsd8);
    }

    /// @inheritdoc IFeedRegistry
    function maxAge(address token, Session session_) external view returns (uint32 bound) {
        if (reverting) revert RegistryDown();
        if (session_ == Session.CLOSED) return type(uint32).max;
        bound = uint32(uint256(_configs[token].heartbeat) * _freshnessMultiplier[uint8(session_)] / 100);
    }

    /// @inheritdoc IFeedRegistry
    function freshnessMultiplier(Session session_) external view returns (uint16 multiplier) {
        multiplier = _freshnessMultiplier[uint8(session_)];
    }

    /// @inheritdoc IFeedRegistry
    function FRESHNESS_MULTIPLIER_MIN() external pure returns (uint16 value) {
        value = Constants.FRESHNESS_MULTIPLIER_MIN;
    }

    /// @inheritdoc IFeedRegistry
    function FRESHNESS_MULTIPLIER_MAX() external pure returns (uint16 value) {
        value = Constants.FRESHNESS_MULTIPLIER_MAX;
    }

    /// @inheritdoc IFeedRegistry
    function ANSWER_JUMP_BPS() external pure returns (uint16 value) {
        value = Constants.ANSWER_JUMP_BPS;
    }

    /// @inheritdoc IFeedRegistry
    function setFeed(address token, address aggregator, FeedConfig calldata config) external {
        _configs[token] = config;
        _configs[token].aggregator = aggregator;
        _configs[token].set = true;
        emit FeedSet(token, address(0), aggregator);
    }

    /// @inheritdoc IFeedRegistry
    function configureFeed(address token, uint32 heartbeat, uint16 thresholdBps, uint128 min, uint128 max) external {
        FeedConfig storage config = _configs[token];
        config.set = true;
        config.heartbeat = heartbeat;
        config.thresholdBps = thresholdBps;
        config.minAnswerUsd8 = min;
        config.maxAnswerUsd8 = max;
        emit FeedConfigured(token, heartbeat, thresholdBps, min, max);
    }

    /// @inheritdoc IFeedRegistry
    function setFreshnessMultiplier(Session session_, uint16 multiplier) external {
        _freshnessMultiplier[uint8(session_)] = multiplier;
        emit FreshnessMultiplierSet(session_, multiplier);
    }

    /// @inheritdoc IFeedRegistry
    /// @dev A no-op latch: the stored answer is already the accepted one.
    function refresh(address token) public returns (uint256 answerUsd8, uint32 updatedAt, bool fresh) {
        if (reverting) revert RegistryDown();
        Answer storage answer = _answers[token];
        emit AnswerLatched(token, answer.answerUsd8, answer.updatedAt, 0);
        return (answer.answerUsd8, answer.updatedAt, answer.fresh);
    }

    /// @inheritdoc IFeedRegistry
    function refreshMany(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (_answers[tokens[i]].set) refresh(tokens[i]);
        }
    }

    /// @inheritdoc IFeedRegistry
    function setConfirmSeconds(uint32 value) external {
        confirmSeconds = value;
    }

    /// @inheritdoc IFeedRegistry
    function setStandardProxy(address aggregator, bool standard) external {
        isStandardProxy[aggregator] = standard;
        emit StandardProxySet(aggregator, standard);
    }

    /// @inheritdoc IFeedRegistry
    function setStandardProxies(address[] calldata aggregators, bool[] calldata standard) external {
        if (aggregators.length != standard.length) revert LengthMismatch();
        for (uint256 i = 0; i < aggregators.length; ++i) {
            isStandardProxy[aggregators[i]] = standard[i];
            emit StandardProxySet(aggregators[i], standard[i]);
        }
    }
}
