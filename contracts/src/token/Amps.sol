// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Amps
/// @notice The Amplestocks share token ($AMPS): a plain 18-decimal ERC-20 with EIP-2612 permit and nothing else.
/// @dev    Deliberately minimal so that invariant I3 holds by construction: `totalSupply` moves only through
///         {mint} and {burn}, both restricted to the vault, and `balanceOf` moves only where OZ's `ERC20._update`
///         emits `Transfer`. There are no transfer hooks, callbacks, fees, pausing, blocklists, rebases or
///         upgradeability, so the token can never be the source of a reentrancy or a silent balance change.
///
///         The constructor takes the vault only; the genesis supply is minted later by the vault. That keeps the
///         creation code plus constructor args stable, which is what the CREATE2 salt in `script/01_MineAmps.s.sol`
///         is mined against (AMPS must sort below every counter-asset so that it is `currency0` in every pool).
///
///         {burn} deliberately burns from an arbitrary account without an allowance: the vault burns AMPS it has
///         already taken custody of (redemptions, buybacks, bond settlement). The vault is the trust boundary.
contract Amps is ERC20, ERC20Permit {
    /// @notice The only address allowed to mint, burn and hand the role on. Set in the constructor.
    address public vault;

    /// @notice Emitted on construction (`previousVault == address(0)`) and on every {setVault}.
    event VaultChanged(address indexed previousVault, address indexed newVault);

    /// @notice Thrown when a vault-only entry point is called by anyone else.
    error NotVault(address caller);

    /// @notice Thrown when the vault would be set to the zero address.
    error ZeroVault();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    /// @param vault_ The initial vault: the sole minter/burner and the only address that can call {setVault}.
    constructor(address vault_) ERC20("Amplestocks", "AMPS") ERC20Permit("Amplestocks") {
        if (vault_ == address(0)) revert ZeroVault();
        vault = vault_;
        emit VaultChanged(address(0), vault_);
    }

    /// @notice Mints `amount` to `to`. Vault only.
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    /// @notice Burns `amount` from `from`. Vault only; no allowance is consumed.
    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }

    /// @notice Hands the vault role to `newVault`. Vault only, so a migration can move it atomically in the same
    ///         transaction that moves the liquidity (see `AmpsVault.emergencyMigrate`).
    function setVault(address newVault) external onlyVault {
        if (newVault == address(0)) revert ZeroVault();
        address previousVault = vault;
        vault = newVault;
        emit VaultChanged(previousVault, newVault);
    }
}
