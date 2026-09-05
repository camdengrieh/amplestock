// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @title MockAggregator
/// @notice Settable Chainlink feed for gate tests: fresh, stale, or dead.
/// @dev    `setStale(true)` freezes `updatedAt` at `STALE_UPDATED_AT` so any freshness bound fails while the answer
///         itself stays readable (the weekend-session case). `setRevert(true)` makes the round views revert, which
///         is the dead-feed case every read must survive behind a bounded staticcall.
contract MockAggregator is IAggregatorV3 {
    /// @dev An `updatedAt` old enough to fail every plausible heartbeat bound.
    uint256 public constant STALE_UPDATED_AT = 1;

    uint8 internal _decimals = 8;
    string internal _description;
    uint256 internal _version = 4;

    uint80 internal _roundId = 1;
    int256 internal _answer;
    uint256 internal _startedAt;
    uint256 internal _updatedAt;

    bool public stale;
    bool public reverting;

    error FeedDown();

    constructor(string memory description_, uint8 decimals_, int256 answer_) {
        _description = description_;
        _decimals = decimals_;
        _answer = answer_;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
    }

    /* ----------------------------- AggregatorV3 ----------------------------- */

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external view returns (uint256) {
        return _version;
    }

    function getRoundData(uint80 roundId_)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (reverting) revert FeedDown();
        return (roundId_, _answer, _startedAt, stale ? STALE_UPDATED_AT : _updatedAt, roundId_);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (reverting) revert FeedDown();
        return (_roundId, _answer, _startedAt, stale ? STALE_UPDATED_AT : _updatedAt, _roundId);
    }

    /* -------------------------------- setters ------------------------------- */

    /// @notice Publishes a new answer, stamping `startedAt`/`updatedAt` with the current block and bumping the round.
    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _roundId += 1;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
    }

    /// @notice Sets every round field explicitly, for tests that need an exact round shape.
    function setRoundData(uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setDescription(string calldata description_) external {
        _description = description_;
    }

    function setVersion(uint256 version_) external {
        _version = version_;
    }

    /// @notice When true, both round views report {STALE_UPDATED_AT}.
    function setStale(bool stale_) external {
        stale = stale_;
    }

    /// @notice When true, both round views revert with {FeedDown}.
    function setRevert(bool reverting_) external {
        reverting = reverting_;
    }
}
