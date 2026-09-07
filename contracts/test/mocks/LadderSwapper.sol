// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title LadderSwapper
/// @notice A third-party swapper for the `LadderPositionValuer` suite: it walks a pool's price to an exact
///         `sqrtPriceLimitX96` and settles out of its **own** balances.
///
/// @dev Invariant I7 says forcing `slot0` +/-50% must not move `A`. Testing that needs two things the shared
///      helpers do not give: a swap that lands on a chosen price rather than on a chosen input size, and a
///      swapper that is not the vault — if the test contract (which plays the vault) traded, its idle ERC-20
///      balance would move and the NAV harness would change for a reason that has nothing to do with positions.
contract LadderSwapper is IUnlockCallback {
    IPoolManager public immutable poolManager;

    error NotPoolManager();

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Swaps until the pool reaches `sqrtPriceLimitX96` or `amountSpecified` is exhausted.
    /// @param key The pool.
    /// @param zeroForOne True to sell currency0 (AMPS) and push the price down.
    /// @param amountSpecified Negative for exact input.
    /// @param sqrtPriceLimitX96 The price to stop at.
    function swapToPrice(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
    {
        poolManager.unlock(abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
            abi.decode(data, (PoolKey, bool, int256, uint160));

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
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
