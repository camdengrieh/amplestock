// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPositionValuer} from "../interfaces/IPositionValuer.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title ZeroPositionValuer
/// @notice Phase 2 position valuer: the vault holds no Uniswap v4 positions yet, so every pool is worth zero in
///         the NAV numerator. Phase 3 re-points `AmpsVault.positionValuer` (7-day timelock) at a valuer that
///         decomposes the vault's ladder positions at the reference-implied sqrt price; the NAV formula itself
///         does not change.
contract ZeroPositionValuer is IPositionValuer {
    /// @inheritdoc IPositionValuer
    function valuePool(PoolId, uint160) external pure returns (uint256 amount0, uint256 amount1) {
        return (0, 0);
    }

    /// @inheritdoc IPositionValuer
    function totalLiquidity(PoolId) external pure returns (uint128 liquidity) {
        return 0;
    }

    /// @inheritdoc IPositionValuer
    function version() external pure returns (bytes32 id) {
        return "zero-position-valuer-v1";
    }
}
