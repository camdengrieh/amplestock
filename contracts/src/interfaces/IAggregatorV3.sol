// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAggregatorV3
/// @notice Chainlink's `AggregatorV3Interface`, declared locally so that no Chainlink package enters the build.
/// @dev    Robinhood Chain feeds answer with 8 decimals. The answer is signed; consumers must reject `answer <= 0`
///         and must never multiply it by a Stock Token's `uiMultiplier()`.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 roundId_)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
