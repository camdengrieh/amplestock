// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockNavSource
/// @notice Minimal stand-in for the vault's NAV checkpoint, so hook and bond tests can move NAV and the reference
///         price without a vault. Both values are 18-decimal USD per AMPS.
contract MockNavSource {
    /// @notice NAV per share, 1e18 == $1.00.
    uint256 public navPerShareX18 = 1e18;

    /// @notice Reference price, 1e18 == $1.00. `pRef >= navPerShare` by construction in the real vault.
    uint256 public pRefX18 = 1e18;

    /// @notice Timestamp of the last checkpoint, for staleness bounds.
    uint256 public lastCheckpoint;

    event Checkpoint(uint256 navPerShareX18, uint256 pRefX18, uint256 timestamp);

    constructor() {
        lastCheckpoint = block.timestamp;
    }

    function setNavPerShareX18(uint256 navPerShareX18_) external {
        navPerShareX18 = navPerShareX18_;
        lastCheckpoint = block.timestamp;
        emit Checkpoint(navPerShareX18_, pRefX18, block.timestamp);
    }

    function setPRefX18(uint256 pRefX18_) external {
        pRefX18 = pRefX18_;
        lastCheckpoint = block.timestamp;
        emit Checkpoint(navPerShareX18, pRefX18_, block.timestamp);
    }

    /// @notice Sets both legs of the checkpoint at once.
    function setCheckpoint(uint256 navPerShareX18_, uint256 pRefX18_) external {
        navPerShareX18 = navPerShareX18_;
        pRefX18 = pRefX18_;
        lastCheckpoint = block.timestamp;
        emit Checkpoint(navPerShareX18_, pRefX18_, block.timestamp);
    }
}
