// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUsdg
/// @notice Test stand-in for USDG on chain 4663: a plain ERC-20 with a configurable decimals value (6 in every
///         production-shaped test) and an open mint, used to fund `BountyPot`.
/// @dev    The decimals are a constructor argument rather than a hard-coded 6 so that the same mock can prove
///         `BountyPot`'s 18-decimal-USD to raw-units scaling is read from the token and not assumed: the fuzz
///         suite instantiates it at 6, 18 and 0 decimals against the same assertions.
contract MockUsdg is ERC20 {
    uint8 internal immutable _decimals;

    /// @param name_ The token name.
    /// @param symbol_ The token symbol.
    /// @param decimals_ The decimals the token reports.
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mints `amount` raw units to `to`. Test-only: unrestricted by design.
    /// @param to The recipient.
    /// @param amount The raw amount.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burns `amount` raw units from `from`. Test-only: unrestricted by design.
    /// @param from The account to burn from.
    /// @param amount The raw amount.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
