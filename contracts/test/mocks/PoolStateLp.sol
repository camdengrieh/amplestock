// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title PoolStateLp
/// @notice A second, independent liquidity provider for `PoolStateLib` differential tests: positions in the v4
///         `PoolManager` are keyed by `(owner, tickLower, tickUpper, salt)` and the owner is whoever calls
///         `modifyLiquidity`, so proving that `PoolStateLib.positionKey` separates owners needs a caller that is
///         not the test contract.
/// @dev Deliberately minimal: it unlocks, modifies one position, settles both sides and returns. It is funded by
///       the test with plain ERC-20 transfers and holds nothing between calls.
contract PoolStateLp is IUnlockCallback {
    IPoolManager public immutable poolManager;

    error NotPoolManager();

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Adds (or removes, with a negative delta) liquidity as this contract, so the position is owned here.
    /// @param key The pool.
    /// @param tickLower The lower tick.
    /// @param tickUpper The upper tick.
    /// @param liquidityDelta The signed liquidity change.
    /// @param salt The position salt.
    function modifyLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
        external
    {
        poolManager.unlock(abi.encode(key, tickLower, tickUpper, liquidityDelta, salt));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt) =
            abi.decode(data, (PoolKey, int24, int24, int256, bytes32));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
            }),
            ""
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            poolManager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transfer(address(poolManager), uint256(uint128(-amount)));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
