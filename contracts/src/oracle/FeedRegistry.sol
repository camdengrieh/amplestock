// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IFeedRegistry} from "../interfaces/IFeedRegistry.sol";
import {IOracleGate} from "../interfaces/IOracleGate.sol";
import {PriceLib} from "../lib/PriceLib.sol";
import {Constants} from "../types/Constants.sol";
import {LengthMismatch, NotTimelock, OutOfBand, ZeroAddress} from "../types/Errors.sol";
import {FeedConfig, FeedStatus, Session} from "../types/Types.sol";

/// @title FeedRegistry
/// @notice Layer C of the oracle design and the single place Amplestocks reads a Chainlink answer. Pointer-
///         upgradeable behind the 7-day timelock; holds no funds and no privileged token approvals.
///
/// @dev **Every aggregator read is a bounded probe.** A Robinhood Chain feed is a proxy in front of an aggregator
///      that the protocol does not control: it can be re-pointed, it can revert, it can be self-destructed out
///      from under a configured address, and it can be replaced by an implementation that burns every wei of gas
///      it is handed. So {latestAnswer}, {priceUsd8} and {feedStatus} never call it directly. They check
///      `aggregator.code.length` first — a codeless address is *dead*, not *reverting* — and then call
///      `latestRoundData()` with `gas: FEED_PROBE_GAS` inside a `try`. A failed probe is reported as a dead feed:
///      the last latched answer stands and ages out, so the gate degrades to `DEGRADED` and placements pause,
///      rather than a `checkpoint()` or a `bond()` reverting because a third party's contract misbehaved.
///
/// @dev **The Accepted / Pending two-confirmation rule.** `accepted[token]` is the answer in force. A candidate
///      round whose answer moves more than `ANSWER_JUMP_BPS` (1,000 bp) against it is *not* adopted on sight; it
///      is recorded in `pending[token]` and the accepted answer keeps standing. The jump is adopted when either
///
///        1. a **later round** agrees with the pending level (within `ANSWER_JUMP_BPS` of it) — two independent
///           rounds have now reported the new price; or
///        2. `confirmSeconds` have elapsed since the pending answer was first seen — a real 10% move must not be
///           held back for ever by an aggregator that stops publishing.
///
///      The rule is armed only when the two answers are within one `heartbeat` of each other. Two rounds a day
///      apart are not "a single-round move", and treating them as one would hold back ordinary drift after a
///      quiet weekend. While a jump is pending, {latestAnswer} returns the *accepted* answer and its *accepted*
///      `updatedAt`, so the ordinary freshness bound is what decides whether the caller degrades — an
///      unconfirmed feed becomes stale on schedule instead of pretending to be current.
///
/// @dev **Where the latch is written.** Reads are `view` and cannot latch, so `accepted`/`pending` are advanced by
///      {refresh} (permissionless and unpaid, like `OracleGate.poke()`) and seeded by {setFeed}. Until a feed has
///      ever been latched there is nothing to jump *from*, and the live candidate is returned directly. The rule
///      therefore never blocks bootstrapping and never depends on a keeper for correctness: the worst a missing
///      {refresh} can do is hold a jump behind the accepted answer until `confirmSeconds` elapse.
///
/// @dev **SVR proxies are rejected by construction.** Chainlink publishes a second, "smart value recapture" proxy
///      for many tickers: the same number, different liveness guarantees, and an MEV-recapture path in between.
///      There is no on-chain flag that distinguishes it, so governance records the Standard proxy from the RDD
///      through {setStandardProxy}, and both {setFeed} and {configureFeed} refuse an aggregator that is not on
///      that list. There is no override.
///
/// @dev **The answer is never multiplied by `uiMultiplier()`.** A Stock Token's display multiplier and its
///      Chainlink answer are already in the same units; this contract does not import `IStockToken` at all, which
///      is the structural version of that rule.
contract FeedRegistry is IFeedRegistry {
    // -------------------------------------------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------------------------------------------
    //
    // `Accepted` and `Pending` are declared by `IFeedRegistry` and inherited here; `FeedStatus` lives in
    // `types/Types.sol` because it crosses the interface boundary as a return value. There is one declaration of
    // each, and this contract owns none of them.

    /// @dev Why a candidate round was not usable. `OK` is the only value that adopts the live answer.
    enum ProbeResult {
        OK,
        DEAD,
        BAD_ANSWER,
        OUT_OF_BOUNDS
    }

    // -------------------------------------------------------------------------------------------------------------
    // Hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Gas forwarded to every aggregator probe. Shares the protocol's single probe budget with the Stock
    ///         Token views: a proxy read is one `SLOAD` plus one external call, comfortably inside it.
    uint256 public constant FEED_PROBE_GAS = Constants.STOCK_TOKEN_PROBE_GAS;

    /// @notice Gas forwarded to the gate when this registry has to ask it for the current session.
    /// @dev Larger than {FEED_PROBE_GAS} because the answer is a calendar walk over two governed tables, not a
    ///      single `SLOAD`: capping it too tightly would silently fall back to `REGULAR` on a cold weekend read,
    ///      which is the one case the session is load-bearing for. The gate that would need more than this is
    ///      already misconfigured.
    uint256 public constant SESSION_PROBE_GAS = 4 * Constants.STOCK_TOKEN_PROBE_GAS;

    /// @notice Hard floor of a feed heartbeat. 60 s: the fastest publication cadence any Chainlink feed the
    ///         protocol could adopt.
    uint32 public constant HEARTBEAT_SECONDS_MIN = Constants.FEED_HEARTBEAT_SECONDS_MIN;

    /// @notice Hard ceiling of a feed heartbeat. 86,400 s, which is exactly the RDD heartbeat of every Robinhood
    ///         Chain equity feed.
    uint32 public constant HEARTBEAT_SECONDS_MAX = Constants.FEED_HEARTBEAT_SECONDS_MAX;

    /// @notice Hard floor of `confirmSeconds`. 5 minutes.
    uint32 public constant CONFIRM_SECONDS_MIN = Constants.ANSWER_CONFIRM_SECONDS_MIN;

    /// @notice Hard ceiling of `confirmSeconds`. 24 hours.
    uint32 public constant CONFIRM_SECONDS_MAX = Constants.ANSWER_CONFIRM_SECONDS_MAX;

    /// @notice Largest feed decimals this registry accepts. Every Robinhood Chain feed answers with 8.
    uint8 public constant FEED_DECIMALS_MAX = 18;

    // -------------------------------------------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The sole governance path. Immutable: a registry that could re-point its own governor is not
    ///         governed.
    address public immutable timelock;

    /// @dev slot 0 `[0..159]`: the gate this registry asks for the current {Session}.
    address internal _oracleGate;

    /// @dev slot 0 `[160..175]`: `freshnessMultiplier[REGULAR]`, in hundredths.
    uint16 internal _freshnessRegular;

    /// @dev slot 0 `[176..191]`: `freshnessMultiplier[PRE_POST]`, in hundredths.
    uint16 internal _freshnessPrePost;

    /// @dev slot 0 `[192..207]`: `freshnessMultiplier[OVERNIGHT]`, in hundredths.
    uint16 internal _freshnessOvernight;

    /// @dev slot 0 `[208..223]`: `freshnessMultiplier[CLOSED]`. Recorded for completeness and never read: the
    ///      freshness check is disabled outright when the market is closed.
    uint16 internal _freshnessClosed;

    /// @dev slot 0 `[224..255]`: the two-confirmation escape window.
    uint32 internal _confirmSeconds;

    /// @dev slot 1: per-token feed records.
    mapping(address token => FeedConfig config) internal _feeds;

    /// @dev slot 2: the answer in force per token.
    mapping(address token => Accepted answer) internal _accepted;

    /// @dev slot 3: the unconfirmed jump per token, if any.
    mapping(address token => Pending answer) internal _pending;

    /// @inheritdoc IFeedRegistry
    mapping(address aggregator => bool standard) public override isStandardProxy;

    // -------------------------------------------------------------------------------------------------------------
    // Extra events (beyond `IFeedRegistry`)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Emitted on every governed scalar change in this contract.
    /// @param parameter The parameter name as a short string.
    /// @param previousValue The value before.
    /// @param newValue The value after.
    event FeedRegistryParameterChanged(bytes32 indexed parameter, uint256 previousValue, uint256 newValue);

    // -------------------------------------------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Deploys the registry with the launch freshness table.
    /// @param timelock_ The governance timelock. Immutable.
    /// @param oracleGate_ The gate whose calendar supplies the session, or `address(0)` to set it later.
    constructor(address timelock_, address oracleGate_) {
        if (timelock_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        _oracleGate = oracleGate_;
        _freshnessRegular = Constants.FRESHNESS_MULTIPLIER_REGULAR_DEFAULT;
        _freshnessPrePost = Constants.FRESHNESS_MULTIPLIER_PRE_POST_DEFAULT;
        _freshnessOvernight = Constants.FRESHNESS_MULTIPLIER_OVERNIGHT_DEFAULT;
        _freshnessClosed = Constants.FRESHNESS_MULTIPLIER_MIN;
        _confirmSeconds = Constants.ANSWER_CONFIRM_SECONDS_DEFAULT;
    }

    /// @dev Every governed setter in this contract, and nothing else.
    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IFeedRegistry
    function feedConfig(address token) external view returns (FeedConfig memory config) {
        return _feeds[token];
    }

    /// @inheritdoc IFeedRegistry
    function feedOf(address token) external view returns (address aggregator) {
        return _feeds[token].aggregator;
    }

    /// @inheritdoc IFeedRegistry
    function latestAnswer(address token) external view returns (uint256 answerUsd8, uint32 updatedAt, bool fresh) {
        return latestAnswerIn(token, sessionNow());
    }

    /// @inheritdoc IFeedRegistry
    function latestAnswerIn(address token, Session session)
        public
        view
        override
        returns (uint256 answerUsd8, uint32 updatedAt, bool fresh)
    {
        FeedStatus memory status = _read(token, session);
        return (status.answerUsd8, status.updatedAt, status.fresh);
    }

    /// @inheritdoc IFeedRegistry
    function latestAnswerUsd18(address token)
        external
        view
        override
        returns (uint256 price18, uint32 updatedAt, bool fresh)
    {
        FeedStatus memory status = _read(token, sessionNow());
        price18 = status.answerUsd8 == 0 ? 0 : PriceLib.counterValueUsd18(PriceLib.WAD, 18, status.answerUsd8);
        return (price18, status.updatedAt, status.fresh);
    }

    /// @inheritdoc IFeedRegistry
    function feedStatus(address token) external view override returns (FeedStatus memory status) {
        return _read(token, sessionNow());
    }

    /// @inheritdoc IFeedRegistry
    function feedStatusIn(address token, Session session) external view override returns (FeedStatus memory status) {
        return _read(token, session);
    }

    /// @inheritdoc IFeedRegistry
    function priceUsd8(address token) public view returns (uint256 answerUsd8) {
        FeedConfig memory config = _feeds[token];
        if (!config.set) revert FeedNotSet(token);

        // Classify the *live* round first, so a caller that must pause gets the specific reason rather than a
        // blanket staleness error. The effective answer below may still differ from this round when the
        // two-confirmation rule is holding a jump back.
        (ProbeResult result,, int256 rawAnswer, uint256 candidateUsd8,) = _probe(config);
        if (result == ProbeResult.DEAD) revert FeedDead(token, config.aggregator);
        if (result == ProbeResult.BAD_ANSWER) revert InvalidAnswer(token, rawAnswer);
        if (result == ProbeResult.OUT_OF_BOUNDS) {
            revert AnswerOutOfBounds(token, candidateUsd8, config.minAnswerUsd8, config.maxAnswerUsd8);
        }

        // The classification above already rejected every reading that could leave the effective answer at zero,
        // so what is left is only the freshness question.
        FeedStatus memory status = _read(token, sessionNow());
        if (!status.fresh) revert StaleAnswer(token, status.age, status.maxAgeSeconds);
        return status.answerUsd8;
    }

    /// @inheritdoc IFeedRegistry
    function priceUsd18(address token) external view returns (uint256 price18) {
        return PriceLib.counterValueUsd18(PriceLib.WAD, 18, priceUsd8(token));
    }

    /// @inheritdoc IFeedRegistry
    function maxAge(address token, Session session) public view returns (uint32 bound) {
        return _maxAge(_feeds[token].heartbeat, session);
    }

    /// @inheritdoc IFeedRegistry
    function freshnessMultiplier(Session session) public view returns (uint16 multiplier) {
        if (session == Session.REGULAR) return _freshnessRegular;
        if (session == Session.PRE_POST) return _freshnessPrePost;
        if (session == Session.OVERNIGHT) return _freshnessOvernight;
        return _freshnessClosed;
    }

    /// @inheritdoc IFeedRegistry
    function confirmSeconds() external view override returns (uint32 value) {
        return _confirmSeconds;
    }

    /// @inheritdoc IFeedRegistry
    function oracleGate() external view override returns (address gate) {
        return _oracleGate;
    }

    /// @inheritdoc IFeedRegistry
    function acceptedAnswer(address token) external view override returns (Accepted memory answer) {
        return _accepted[token];
    }

    /// @inheritdoc IFeedRegistry
    function pendingAnswer(address token) external view override returns (Pending memory answer) {
        return _pending[token];
    }

    /// @inheritdoc IFeedRegistry
    /// @dev The call is bounded exactly like an aggregator probe: this contract is read by `AmpsQuoter` and must
    ///      never revert because a governance pointer was set badly.
    function sessionNow() public view override returns (Session session) {
        address gate = _oracleGate;
        if (gate == address(0) || gate.code.length == 0) return Session.REGULAR;
        try IOracleGate(gate).sessionNow{gas: SESSION_PROBE_GAS}() returns (Session reported) {
            return reported;
        } catch {
            return Session.REGULAR;
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Hard bands (interface getters)
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IFeedRegistry
    function FRESHNESS_MULTIPLIER_MIN() external pure returns (uint16 value) {
        return Constants.FRESHNESS_MULTIPLIER_MIN;
    }

    /// @inheritdoc IFeedRegistry
    function FRESHNESS_MULTIPLIER_MAX() external pure returns (uint16 value) {
        return Constants.FRESHNESS_MULTIPLIER_MAX;
    }

    /// @inheritdoc IFeedRegistry
    function ANSWER_JUMP_BPS() external pure returns (uint16 value) {
        return Constants.ANSWER_JUMP_BPS;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative: the permissionless latch
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IFeedRegistry
    function refresh(address token) public override returns (uint256 answerUsd8, uint32 updatedAt, bool fresh) {
        FeedConfig memory config = _feeds[token];
        if (!config.set) revert FeedNotSet(token);

        (ProbeResult result, uint80 roundId,, uint256 candidateUsd8, uint32 candidateUpdatedAt) = _probe(config);
        if (result == ProbeResult.OK) {
            Accepted memory accepted = _accepted[token];
            if (
                accepted.answerUsd8 != 0 && roundId != accepted.roundId
                    && _isJump(config.heartbeat, accepted, candidateUsd8, candidateUpdatedAt)
                    && !_jumpConfirmed(_pending[token], roundId, candidateUsd8)
            ) {
                Pending memory pending = _pending[token];
                if (pending.roundId != roundId) {
                    _pending[token] = Pending({
                        answerUsd8: uint128(candidateUsd8), seenAt: uint32(block.timestamp), roundId: roundId
                    });
                    emit AnswerJumpPending(token, accepted.answerUsd8, candidateUsd8, roundId);
                }
            } else if (roundId != accepted.roundId || accepted.answerUsd8 == 0) {
                _latch(token, candidateUsd8, candidateUpdatedAt, roundId);
            }
        }

        FeedStatus memory status = _read(token, sessionNow());
        return (status.answerUsd8, status.updatedAt, status.fresh);
    }

    /// @inheritdoc IFeedRegistry
    function refreshMany(address[] calldata tokens) external override {
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (_feeds[tokens[i]].set) refresh(tokens[i]);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IFeedRegistry
    function setStandardProxy(address aggregator, bool standard) external override onlyTimelock {
        if (aggregator == address(0)) revert ZeroAddress();
        isStandardProxy[aggregator] = standard;
        emit StandardProxySet(aggregator, standard);
    }

    /// @inheritdoc IFeedRegistry
    function setStandardProxies(address[] calldata aggregators, bool[] calldata standard)
        external
        override
        onlyTimelock
    {
        if (aggregators.length != standard.length) revert LengthMismatch();
        for (uint256 i = 0; i < aggregators.length; ++i) {
            if (aggregators[i] == address(0)) revert ZeroAddress();
            isStandardProxy[aggregators[i]] = standard[i];
            emit StandardProxySet(aggregators[i], standard[i]);
        }
    }

    /// @inheritdoc IFeedRegistry
    /// @dev `config.aggregator`, `config.decimals` and `config.set` are ignored: the aggregator comes from the
    ///      `aggregator` argument, the decimals are read from the aggregator itself (a mismatch between the RDD
    ///      and the deployed contract is exactly the kind of transcription error this catches), and `set` is
    ///      always true afterwards. A successful first read is latched as the accepted answer so the
    ///      two-confirmation rule has something to measure against from block one.
    function setFeed(address token, address aggregator, FeedConfig calldata config) external onlyTimelock {
        if (token == address(0) || aggregator == address(0)) revert ZeroAddress();
        if (!isStandardProxy[aggregator]) revert NotStandardProxy(aggregator);

        (bool ok, uint8 decimals) = _probeDecimals(aggregator);
        if (!ok) revert FeedDead(token, aggregator);
        if (decimals > FEED_DECIMALS_MAX) revert OutOfBand("feedDecimals", decimals, 0, FEED_DECIMALS_MAX);

        _validateFeedBand(config.heartbeat, config.thresholdBps, config.minAnswerUsd8, config.maxAnswerUsd8);

        address previous = _feeds[token].aggregator;
        _feeds[token] = FeedConfig({
            aggregator: aggregator,
            decimals: decimals,
            set: true,
            heartbeat: config.heartbeat,
            thresholdBps: config.thresholdBps,
            minAnswerUsd8: config.minAnswerUsd8,
            maxAnswerUsd8: config.maxAnswerUsd8
        });

        // A replaced aggregator invalidates both the accepted answer and any jump held against it: the new proxy
        // is a different series, and holding the old one's answer against it would mis-fire the jump rule.
        delete _accepted[token];
        delete _pending[token];

        emit FeedSet(token, previous, aggregator);
        emit FeedConfigured(token, config.heartbeat, config.thresholdBps, config.minAnswerUsd8, config.maxAnswerUsd8);

        (ProbeResult result, uint80 roundId,, uint256 candidateUsd8, uint32 candidateUpdatedAt) = _probe(_feeds[token]);
        if (result == ProbeResult.OK) _latch(token, candidateUsd8, candidateUpdatedAt, roundId);
    }

    /// @inheritdoc IFeedRegistry
    /// @dev Re-checks the Standard-proxy allowlist, so revoking a proxy that turned out to be an SVR address
    ///      immediately blocks further tuning of that feed and forces a {setFeed} replacement.
    function configureFeed(
        address token,
        uint32 heartbeat,
        uint16 thresholdBps,
        uint128 minAnswerUsd8,
        uint128 maxAnswerUsd8
    ) external onlyTimelock {
        FeedConfig storage config = _feeds[token];
        if (!config.set) revert FeedNotSet(token);
        if (!isStandardProxy[config.aggregator]) revert NotStandardProxy(config.aggregator);
        _validateFeedBand(heartbeat, thresholdBps, minAnswerUsd8, maxAnswerUsd8);

        config.heartbeat = heartbeat;
        config.thresholdBps = thresholdBps;
        config.minAnswerUsd8 = minAnswerUsd8;
        config.maxAnswerUsd8 = maxAnswerUsd8;
        emit FeedConfigured(token, heartbeat, thresholdBps, minAnswerUsd8, maxAnswerUsd8);
    }

    /// @inheritdoc IFeedRegistry
    /// @dev The `CLOSED` entry is settable but never read: a closed market's held answer is correct, not stale,
    ///      and the bond path prices it with `h_session` instead. Recording it keeps the table complete for the
    ///      dApp and keeps the setter total over `Session`.
    function setFreshnessMultiplier(Session session, uint16 multiplier) external onlyTimelock {
        if (multiplier < Constants.FRESHNESS_MULTIPLIER_MIN || multiplier > Constants.FRESHNESS_MULTIPLIER_MAX) {
            revert OutOfBand(
                "freshnessMultiplier",
                multiplier,
                Constants.FRESHNESS_MULTIPLIER_MIN,
                Constants.FRESHNESS_MULTIPLIER_MAX
            );
        }
        uint16 previous = freshnessMultiplier(session);
        if (session == Session.REGULAR) {
            _freshnessRegular = multiplier;
        } else if (session == Session.PRE_POST) {
            _freshnessPrePost = multiplier;
        } else if (session == Session.OVERNIGHT) {
            _freshnessOvernight = multiplier;
        } else {
            _freshnessClosed = multiplier;
        }
        emit FreshnessMultiplierSet(session, multiplier);
        emit FeedRegistryParameterChanged("freshnessMultiplier", previous, multiplier);
    }

    /// @inheritdoc IFeedRegistry
    function setConfirmSeconds(uint32 value) external override onlyTimelock {
        if (value < CONFIRM_SECONDS_MIN || value > CONFIRM_SECONDS_MAX) {
            revert OutOfBand("confirmSeconds", value, CONFIRM_SECONDS_MIN, CONFIRM_SECONDS_MAX);
        }
        uint32 previous = _confirmSeconds;
        _confirmSeconds = value;
        emit FeedRegistryParameterChanged("confirmSeconds", previous, value);
    }

    /// @inheritdoc IFeedRegistry
    function setOracleGate(address gate) external override onlyTimelock {
        if (gate == address(0)) revert ZeroAddress();
        address previous = _oracleGate;
        _oracleGate = gate;
        emit FeedRegistryParameterChanged("oracleGate", uint256(uint160(previous)), uint256(uint160(gate)));
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The whole read, in one place: probe, latch comparison, two-confirmation rule, freshness.
    function _read(address token, Session session) internal view returns (FeedStatus memory status) {
        FeedConfig memory config = _feeds[token];
        if (!config.set) return status;
        status.configured = true;
        status.maxAgeSeconds = _maxAge(config.heartbeat, session);

        (ProbeResult result, uint80 roundId,, uint256 candidateUsd8, uint32 candidateUpdatedAt) = _probe(config);
        Accepted memory accepted = _accepted[token];

        if (result != ProbeResult.OK) {
            // Dead, non-positive or out-of-bounds: the latched answer stands and ages out. A feed that never
            // latched anything reports `answerUsd8 == 0`, i.e. "no usable answer at all".
            status.answerUsd8 = accepted.answerUsd8;
            status.updatedAt = accepted.updatedAt;
            status.roundId = accepted.roundId;
        } else {
            status.live = true;
            bool holdBack = accepted.answerUsd8 != 0 && roundId != accepted.roundId
                && _isJump(config.heartbeat, accepted, candidateUsd8, candidateUpdatedAt)
                && !_jumpConfirmed(_pending[token], roundId, candidateUsd8);
            if (holdBack) {
                status.unconfirmed = true;
                status.answerUsd8 = accepted.answerUsd8;
                status.updatedAt = accepted.updatedAt;
                status.roundId = accepted.roundId;
            } else {
                status.answerUsd8 = candidateUsd8;
                status.updatedAt = candidateUpdatedAt;
                status.roundId = roundId;
            }
        }

        status.age =
            block.timestamp > status.updatedAt ? uint32(block.timestamp - uint256(status.updatedAt)) : uint32(0);
        status.fresh = status.answerUsd8 != 0 && (session == Session.CLOSED || status.age <= status.maxAgeSeconds);
    }

    /// @dev One bounded probe of `latestRoundData()`, plus positivity, timestamp and per-ticker bound checks.
    ///      Returns the raw answer alongside the scaled one so {priceUsd8} can name it in `InvalidAnswer`.
    function _probe(FeedConfig memory config)
        internal
        view
        returns (ProbeResult result, uint80 roundId, int256 rawAnswer, uint256 answerUsd8, uint32 updatedAt)
    {
        address aggregator = config.aggregator;
        // A self-destructed or never-deployed aggregator answers a `staticcall` with success and no data. Reading
        // the code size first turns that into an explicit "dead", which is the whole reason this branch exists.
        if (aggregator == address(0) || aggregator.code.length == 0) return (ProbeResult.DEAD, 0, 0, 0, 0);

        try IAggregatorV3(aggregator).latestRoundData{gas: FEED_PROBE_GAS}() returns (
            uint80 roundId_, int256 answer_, uint256, uint256 updatedAt_, uint80
        ) {
            roundId = roundId_;
            rawAnswer = answer_;
            if (answer_ <= 0 || updatedAt_ == 0 || updatedAt_ > block.timestamp) {
                return (ProbeResult.BAD_ANSWER, roundId_, answer_, 0, 0);
            }
            // Bounded above by `uint128` so the 8-decimal rescale below cannot overflow; the per-ticker bounds are
            // `uint128` anyway, so anything larger is out of bounds by construction.
            if (uint256(answer_) > type(uint128).max) {
                return (ProbeResult.OUT_OF_BOUNDS, roundId_, answer_, type(uint128).max, uint32(updatedAt_));
            }
            answerUsd8 = _toUsd8(uint256(answer_), config.decimals);
            updatedAt = uint32(updatedAt_);
            if (answerUsd8 < config.minAnswerUsd8 || answerUsd8 > config.maxAnswerUsd8) {
                return (ProbeResult.OUT_OF_BOUNDS, roundId_, answer_, answerUsd8, updatedAt);
            }
            if (answerUsd8 == 0) return (ProbeResult.BAD_ANSWER, roundId_, answer_, 0, updatedAt);
            return (ProbeResult.OK, roundId_, answer_, answerUsd8, updatedAt);
        } catch {
            return (ProbeResult.DEAD, 0, 0, 0, 0);
        }
    }

    /// @dev One bounded probe of `decimals()`.
    function _probeDecimals(address aggregator) internal view returns (bool ok, uint8 decimals) {
        if (aggregator.code.length == 0) return (false, 0);
        try IAggregatorV3(aggregator).decimals{gas: FEED_PROBE_GAS}() returns (uint8 decimals_) {
            return (true, decimals_);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Rescales a feed answer to the protocol's 8-decimal USD unit, rounding **down**.
    function _toUsd8(uint256 answer, uint8 decimals) internal pure returns (uint256 answerUsd8) {
        if (decimals == 8) return answer;
        if (decimals > 8) return answer / (10 ** uint256(decimals - 8));
        return answer * (10 ** uint256(8 - decimals));
    }

    /// @dev `heartbeat x multiplier / 100`, and "no bound at all" when the market is closed.
    function _maxAge(uint32 heartbeat, Session session) internal view returns (uint32 bound) {
        if (session == Session.CLOSED) return type(uint32).max;
        uint256 scaled = (uint256(heartbeat) * uint256(freshnessMultiplier(session))) / 100;
        return scaled >= type(uint32).max ? type(uint32).max : uint32(scaled);
    }

    /// @dev Whether a candidate is a single-round move above `ANSWER_JUMP_BPS` against the accepted answer.
    ///      Rounds published more than one heartbeat apart are not a single-round move and are never jumps.
    function _isJump(uint32 heartbeat, Accepted memory accepted, uint256 candidateUsd8, uint32 candidateUpdatedAt)
        internal
        pure
        returns (bool isJump)
    {
        if (candidateUpdatedAt < accepted.updatedAt) return false;
        if (uint256(candidateUpdatedAt) - uint256(accepted.updatedAt) > uint256(heartbeat)) return false;
        uint256 previous = accepted.answerUsd8;
        uint256 diff = candidateUsd8 > previous ? candidateUsd8 - previous : previous - candidateUsd8;
        return diff * Constants.BPS > uint256(Constants.ANSWER_JUMP_BPS) * previous;
    }

    /// @dev Whether a pending jump has been confirmed, by a later agreeing round or by `confirmSeconds`.
    function _jumpConfirmed(Pending memory pending, uint80 roundId, uint256 candidateUsd8)
        internal
        view
        returns (bool confirmed)
    {
        if (pending.roundId == 0) return false;
        if (block.timestamp >= uint256(pending.seenAt) + uint256(_confirmSeconds)) return true;
        if (roundId <= pending.roundId) return false;
        uint256 held = pending.answerUsd8;
        uint256 diff = candidateUsd8 > held ? candidateUsd8 - held : held - candidateUsd8;
        return diff * Constants.BPS <= uint256(Constants.ANSWER_JUMP_BPS) * held;
    }

    /// @dev Writes the accepted answer and clears any jump held against the old one.
    function _latch(address token, uint256 answerUsd8, uint32 updatedAt, uint80 roundId) internal {
        _accepted[token] = Accepted({answerUsd8: uint128(answerUsd8), updatedAt: updatedAt, roundId: roundId});
        if (_pending[token].roundId != 0) delete _pending[token];
        emit AnswerLatched(token, answerUsd8, updatedAt, roundId);
    }

    /// @dev Every band a feed record must satisfy, each named so the revert says which one failed.
    function _validateFeedBand(uint32 heartbeat, uint16 thresholdBps, uint128 minAnswerUsd8, uint128 maxAnswerUsd8)
        internal
        pure
    {
        if (heartbeat < HEARTBEAT_SECONDS_MIN || heartbeat > HEARTBEAT_SECONDS_MAX) {
            revert OutOfBand("heartbeat", heartbeat, HEARTBEAT_SECONDS_MIN, HEARTBEAT_SECONDS_MAX);
        }
        if (thresholdBps == 0 || thresholdBps > Constants.BPS) {
            revert OutOfBand("thresholdBps", thresholdBps, 1, Constants.BPS);
        }
        if (maxAnswerUsd8 == 0 || minAnswerUsd8 >= maxAnswerUsd8) {
            revert OutOfBand("minAnswerUsd8", minAnswerUsd8, 0, maxAnswerUsd8 == 0 ? 0 : maxAnswerUsd8 - 1);
        }
    }
}
