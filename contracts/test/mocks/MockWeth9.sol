// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title MockWeth9
/// @notice WETH9's two extra entry points — `deposit` and `withdraw` — bolted onto solmate's `MockERC20`, so a
///         suite can exercise `AmpsRouter`'s wrap and unwrap legs against a pool whose counter asset behaves the
///         way the real WETH9 does.
///
/// @dev **It adds no storage.** Every state variable belongs to `MockERC20`/`ERC20`, which is what makes it safe
///      to `vm.etch` this contract's runtime code over a `MockERC20` already deployed at a chosen address (the
///      trick `V4TestBase.deployTokenAt` uses to keep AMPS as `currency0`): the balances, allowances and total
///      supply written before the etch are still exactly where this code looks for them. `decimals` is immutable
///      and travels with the code, which is why the constructor pins it at 18.
///
/// @dev `withdraw` pays out of this contract's native balance, so a fixture that *mints* WETH rather than
///      depositing for it must `vm.deal` the token address enough ether to cover what it minted — exactly as the
///      real WETH9 holds one wei of ether per wei of WETH in issue.
contract MockWeth9 is MockERC20 {
    /// @notice Emitted on a wrap, as WETH9 emits it.
    /// @param account The depositor.
    /// @param amount The amount wrapped.
    event Deposit(address indexed account, uint256 amount);

    /// @notice Emitted on an unwrap.
    /// @param account The withdrawer.
    /// @param amount The amount unwrapped.
    event Withdrawal(address indexed account, uint256 amount);

    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    /// @notice Wraps the ether sent with the call.
    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Unwraps `amount` back to ether, sent to the caller.
    /// @param amount The amount to unwrap.
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        emit Withdrawal(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "MockWeth9: send failed");
    }

    receive() external payable {
        deposit();
    }
}
