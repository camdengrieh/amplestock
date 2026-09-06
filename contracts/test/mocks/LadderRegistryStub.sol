// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolClass, PoolConfig} from "../../src/types/Types.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title LadderRegistryStub
/// @notice The one thing `LadderPositionValuer` asks a registry: `poolConfig(poolId)`, and specifically its
///         `tickSpacing`, `gridBaseTick` and `registered` fields.
///
/// @dev A deliberately narrow stand-in rather than a second `MockPoolRegistry`. The valuer takes an
///      `IPoolRegistry`, but it only ever calls this one selector, so a stub answering it is enough — and it lets
///      the tests write a `gridBaseTick` (including deliberately absurd ones, to prove the valuer clamps rather
///      than reverting at the tick extremes) without touching the shared mock every other suite depends on.
contract LadderRegistryStub {
    mapping(PoolId poolId => PoolConfig config) internal _pools;

    /// @notice Registers `poolId` with the grid the valuer will enumerate.
    /// @param poolId The pool.
    /// @param counter The pool's `currency1`.
    /// @param counterDecimals ERC-20 decimals of `counter`.
    /// @param tickSpacing The pool's tick spacing.
    /// @param gridBaseTick The origin of the pool's canonical doubling grid.
    function setPool(PoolId poolId, address counter, uint8 counterDecimals, int24 tickSpacing, int24 gridBaseTick)
        external
    {
        _pools[poolId] = PoolConfig({
            counter: counter,
            poolClass: PoolClass.ENTRY,
            counterDecimals: counterDecimals,
            tickSpacing: tickSpacing,
            buyFeeBps: 30,
            constituentId: 0,
            registered: true,
            gridBaseTick: gridBaseTick
        });
    }

    /// @notice Writes a whole `PoolConfig`, for the cases that need an unregistered or malformed one.
    /// @param poolId The pool.
    /// @param config The config to answer with.
    function setPoolConfig(PoolId poolId, PoolConfig memory config) external {
        _pools[poolId] = config;
    }

    /// @notice The `IPoolRegistry` read the valuer makes. Never reverts; an unknown pool answers a zeroed config.
    /// @param poolId The pool.
    /// @return config The pool's configuration.
    function poolConfig(PoolId poolId) external view returns (PoolConfig memory config) {
        return _pools[poolId];
    }
}
