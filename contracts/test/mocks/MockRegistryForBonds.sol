// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockPoolRegistry} from "./MockPoolRegistry.sol";

/// @title MockRegistryForBonds
/// @notice {MockPoolRegistry} with a **settable** `IPoolRegistry.currentWeightBps`, so the bond suite can drive a
///         constituent's realised index weight — the other half of the bond discount's deficit term — away from
///         its target and watch the discount widen.
///
/// @dev The base mock answers the target weight (Phase 2's real behaviour), which prices `deficit == 0`. This one
///      answers whatever a test sets, and {setWeightSourceEnabled} makes it revert outright: `AmpsBonds` reads the
///      view through a bounded `try` and treats any failure as "unknown", so that switch is how the suite proves a
///      registry which cannot report a weight still cannot close a bond market.
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

    /// @inheritdoc MockPoolRegistry
    /// @dev Answers the settable realised weight, and reverts entirely while the weight source is disabled.
    function currentWeightBps(uint16 constituentId) external view override returns (uint16 weightBps) {
        if (!weightSourceEnabled) revert WeightSourceDisabled();
        weightBps = _currentWeightBps[constituentId];
    }
}
