// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockPoolRegistry} from "./MockPoolRegistry.sol";

/// @title MockRegistryForBonds
/// @notice {MockPoolRegistry} plus the one view `AmpsBonds` probes for and `IPoolRegistry` does not declare yet:
///         the constituent's *realised* index weight, which is the other half of the bond discount's deficit term.
///
/// @dev `AmpsBonds` reads it through a bounded `staticcall` and treats any failure as "unknown", so the plain
///      {MockPoolRegistry} exercises the `deficit == 0` branch and this subclass exercises the live one. When the
///      view is promoted into `IPoolRegistry`, this contract collapses into the base mock and the shell needs no
///      new bytecode.
contract MockRegistryForBonds is MockPoolRegistry {
    /// @notice When false, {currentWeightBps} reverts, which is how a test forces the "registry cannot report a
    ///         weight" branch on a registry that otherwise answers everything.
    bool public weightSourceEnabled = true;

    mapping(uint16 constituentId => uint16 weightBps) internal _currentWeightBps;

    /// @notice Thrown by {currentWeightBps} while the weight source is disabled.
    error WeightSourceDisabled();

    /// @notice Sets a constituent's realised index weight.
    /// @param constituentId The 1-based constituent id.
    /// @param weightBps The realised weight in bps.
    function setCurrentWeightBps(uint16 constituentId, uint16 weightBps) external {
        _currentWeightBps[constituentId] = weightBps;
    }

    /// @notice Enables or disables the weight source.
    /// @param enabled Whether {currentWeightBps} answers.
    function setWeightSourceEnabled(bool enabled) external {
        weightSourceEnabled = enabled;
    }

    /// @notice The constituent's current share of the index, in bps.
    /// @param constituentId The 1-based constituent id.
    /// @return weightBps The realised weight.
    function currentWeightBps(uint16 constituentId) external view returns (uint16 weightBps) {
        if (!weightSourceEnabled) revert WeightSourceDisabled();
        weightBps = _currentWeightBps[constituentId];
    }
}
