// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketReference} from "../../src/interfaces/IMarketReference.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title MockMarketReference
/// @notice Settable stand-in for the hook's observation surface (`IMarketReference`) until `AmpsHook` exists.
///         Tests seed a per-pool mean tick and coverage; reads behave exactly like the production surface,
///         including the `PoolNotObserved` and `WindowNotCovered` reverts the vault must degrade on.
contract MockMarketReference is IMarketReference {
    struct Obs {
        bool observed;
        int24 twap;
        int24 last;
        int24 highWater;
        int24 cap;
        uint32 coverage;
    }

    uint32 internal _window = 1800;
    mapping(PoolId => Obs) internal _obs;

    /* ------------------------------------ test setters ------------------------------------ */

    function setObservation(PoolId poolId, int24 twap, int24 last, uint32 coverage) external {
        Obs storage o = _obs[poolId];
        o.observed = true;
        o.twap = twap;
        o.last = last;
        if (last > o.highWater) o.highWater = last;
        o.coverage = coverage;
        if (o.cap == 0) o.cap = 200;
    }

    function setHighWater(PoolId poolId, int24 tick) external {
        _obs[poolId].highWater = tick;
    }

    function setCap(PoolId poolId, int24 cap) external {
        _obs[poolId].cap = cap;
    }

    function setWindow(uint32 window) external {
        _window = window;
    }

    function clear(PoolId poolId) external {
        delete _obs[poolId];
    }

    /* ------------------------------------ IMarketReference ------------------------------------ */

    /// @inheritdoc IMarketReference
    function twapTick(PoolId poolId, uint32 window) public view returns (int24 meanTick) {
        Obs storage o = _obs[poolId];
        if (!o.observed) revert PoolNotObserved(poolId);
        if (o.coverage < window) revert WindowNotCovered(poolId, window, o.coverage);
        return o.twap;
    }

    /// @inheritdoc IMarketReference
    function twapTick30m(PoolId poolId) external view returns (int24 meanTick) {
        return twapTick(poolId, 1800);
    }

    /// @inheritdoc IMarketReference
    function observationCoverage(PoolId poolId) external view returns (uint32 secondsCovered) {
        return _obs[poolId].coverage;
    }

    /// @inheritdoc IMarketReference
    function lastTruncatedTick(PoolId poolId) external view returns (int24 tick) {
        Obs storage o = _obs[poolId];
        if (!o.observed) revert PoolNotObserved(poolId);
        return o.last;
    }

    /// @inheritdoc IMarketReference
    function highWaterTick(PoolId poolId) external view returns (int24 tick) {
        Obs storage o = _obs[poolId];
        if (!o.observed) revert PoolNotObserved(poolId);
        return o.highWater;
    }

    /// @inheritdoc IMarketReference
    function twapWindow() external view returns (uint32 window) {
        return _window;
    }

    /// @inheritdoc IMarketReference
    function maxTickMovePerBlock(PoolId poolId) external view returns (int24 cap) {
        return _obs[poolId].cap;
    }
}
