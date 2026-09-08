// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title ClaimMinter
/// @notice Turns an ERC-20 balance this contract holds into an ERC-6909 claim owned by someone else, through one
///         `unlock` of the PoolManager: `sync -> transfer -> settle -> mint`.
///
/// @dev **Why a test needs this at all.** §12 ruling F says the AMPS ERC-6909 claim the vault holds is protocol
///      inventory exactly as its idle ERC-20 balance is — it is in `redeemProRata`'s pro-rata base and it is swept
///      to ERC-20 so the burn can happen. Until the 2026-09-07 remediation the way `VaultRedeem.t.sol` produced
///      such a claim was to exploit the very bug that remediation closes: a small merge into a cell holding
///      accrued fees settled to a *positive* `currency0` delta, because `modifyLiquidity` returns
///      `principal + feesAccrued`, and `VaultPlacementLib._settle` minted the residue back as a claim.
///      `place` now collects and splits a pool's fees before it merges, so every settlement it makes is principal
///      and the AMPS side is never positive — the old fixture cannot produce a claim any more, and no placement
///      path can. The ruling is about what the vault does with a claim it holds, not about where the claim came
///      from, so the claim is minted here directly and the property is tested unchanged.
///
/// @dev Test-only. It holds no state, has no access control, and mints against currency it has actually settled,
///      so the PoolManager's solvency is real: the claim the vault receives can be burned and taken.
contract ClaimMinter is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    error NotPoolManager();

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Settles `amount` of `currency` this contract holds and mints the resulting claim to `to`.
    /// @param to The account that ends up holding the ERC-6909 claim.
    /// @param currency The currency.
    /// @param amount The amount, in the currency's own raw units.
    function mintTo(address to, Currency currency, uint256 amount) external {
        poolManager.unlock(abi.encode(to, currency, amount));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address to, Currency currency, uint256 amount) = abi.decode(data, (address, Currency, uint256));

        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
        poolManager.settle();
        poolManager.mint(to, currency.toId(), amount);
        return "";
    }
}
