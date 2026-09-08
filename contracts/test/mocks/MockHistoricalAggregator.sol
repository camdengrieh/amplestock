// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @title MockHistoricalAggregator
/// @notice A Chainlink aggregator that keeps a real per-round history, so `getRoundData(roundId - 1)` answers with
///         what round `roundId - 1` actually published rather than with the latest answer.
///
/// @dev `MockAggregator` answers every `getRoundData` with the *current* round, which is all the freshness and
///      dead-feed cases need. `FeedRegistry`'s stateless jump path reads the previous round to decide whether the
///      latest one is a single-round move, and against that mock every round trivially agrees with itself, so it
///      cannot see a jump at all. This mock is the one the two-confirmation suite needs: it records `{answer,
///      startedAt, updatedAt}` per round and refuses rounds it never published.
///
/// @dev The first round id is a constructor argument so a test can place the series at a **phase boundary**. A
///      Chainlink proxy's `roundId` is `phaseId << 64 | aggregatorRoundId`, so starting the series at
///      `(1 << 64) | 1` makes `roundId - 1` belong to the previous phase — the case `FeedRegistry` must read as
///      "no previous round" rather than as an answer.
///
/// @dev `setHistoryRevert(true)` makes only {getRoundData} revert, leaving {latestRoundData} healthy: an
///      aggregator whose history is unreadable is exactly the probe failure the stateless path must survive.
contract MockHistoricalAggregator is IAggregatorV3 {
    /// @notice One published round.
    /// @param answer The answer, in the aggregator's own decimals.
    /// @param startedAt When the round opened.
    /// @param updatedAt When it was published.
    /// @param set Whether the round exists at all.
    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        bool set;
    }

    uint8 internal immutable _decimals;
    string internal _description;

    /// @notice The latest published round id.
    uint80 public latestRound;

    /// @notice When true, {getRoundData} reverts and {latestRoundData} does not.
    bool public historyReverts;

    /// @notice When true, both round views revert.
    bool public reverting;

    mapping(uint80 roundId => Round round) internal _rounds;

    /// @notice Thrown by the round views while the corresponding switch is set, and for an unpublished round.
    error NoData();

    /// @param description_ The feed description.
    /// @param decimals_ The aggregator's decimals.
    /// @param firstRoundId The id of the first round, so a test can sit the series on a phase boundary.
    /// @param answer_ The first answer.
    constructor(string memory description_, uint8 decimals_, uint80 firstRoundId, int256 answer_) {
        _description = description_;
        _decimals = decimals_;
        latestRound = firstRoundId;
        _rounds[firstRoundId] =
            Round({answer: answer_, startedAt: block.timestamp, updatedAt: block.timestamp, set: true});
    }

    /* ----------------------------- AggregatorV3 ----------------------------- */

    /// @inheritdoc IAggregatorV3
    function decimals() external view returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IAggregatorV3
    function description() external view returns (string memory) {
        return _description;
    }

    /// @inheritdoc IAggregatorV3
    function version() external pure returns (uint256) {
        return 4;
    }

    /// @inheritdoc IAggregatorV3
    function getRoundData(uint80 roundId_)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (reverting || historyReverts) revert NoData();
        Round memory round = _rounds[roundId_];
        if (!round.set) revert NoData();
        return (roundId_, round.answer, round.startedAt, round.updatedAt, roundId_);
    }

    /// @inheritdoc IAggregatorV3
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (reverting) revert NoData();
        Round memory round = _rounds[latestRound];
        return (latestRound, round.answer, round.startedAt, round.updatedAt, latestRound);
    }

    /* -------------------------------- setters ------------------------------- */

    /// @notice Publishes the next round at the current block.
    /// @param answer_ The new answer.
    /// @return roundId The round it was published in.
    function publish(int256 answer_) external returns (uint80 roundId) {
        roundId = latestRound + 1;
        latestRound = roundId;
        _rounds[roundId] = Round({answer: answer_, startedAt: block.timestamp, updatedAt: block.timestamp, set: true});
    }

    /// @notice Publishes the next round with an explicit timestamp, for the gap cases.
    /// @param answer_ The new answer.
    /// @param updatedAt_ The publication timestamp to record.
    /// @return roundId The round it was published in.
    function publishAt(int256 answer_, uint256 updatedAt_) external returns (uint80 roundId) {
        roundId = latestRound + 1;
        latestRound = roundId;
        _rounds[roundId] = Round({answer: answer_, startedAt: updatedAt_, updatedAt: updatedAt_, set: true});
    }

    /// @notice Publishes an arbitrary round id, so a test can start a new Chainlink *phase*: a proxy's `roundId`
    ///         is `phaseId << 64 | aggregatorRoundId`, and the first round of a phase has no predecessor.
    /// @param roundId The round id to publish.
    /// @param answer_ The answer.
    /// @param updatedAt_ The publication timestamp.
    function publishRound(uint80 roundId, int256 answer_, uint256 updatedAt_) external {
        latestRound = roundId;
        _rounds[roundId] = Round({answer: answer_, startedAt: updatedAt_, updatedAt: updatedAt_, set: true});
    }

    /// @notice The answer one round holds, for assertions.
    /// @param roundId The round.
    /// @return answer Its answer.
    function answerOf(uint80 roundId) external view returns (int256 answer) {
        return _rounds[roundId].answer;
    }

    /// @notice When true, {getRoundData} reverts while {latestRoundData} keeps working.
    /// @param historyReverts_ The new value.
    function setHistoryRevert(bool historyReverts_) external {
        historyReverts = historyReverts_;
    }

    /// @notice When true, both round views revert.
    /// @param reverting_ The new value.
    function setRevert(bool reverting_) external {
        reverting = reverting_;
    }
}
