// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IAmps
/// @notice The $AMPS share token: a plain 18-decimal ERC-20 plus the three vault-only entry points the protocol
///         depends on. This is the surface `AmpsVault` reaches the token through, and the only declaration of it.
///
/// @dev **`totalSupply` moves through {mint} and {burn} and nowhere else** (invariant I3). Both are restricted to
///      the vault, and after the genesis latch closes the only reachable mint call site in the vault's bytecode is
///      `AmpsVault.mintVesting` (I10). There are no transfer hooks, callbacks, fees, pausing, blocklists, rebases
///      or upgradeability on the token, which is what makes it structurally incapable of being the source of a
///      reentrancy or a silent balance change.
///
/// @dev **{burn} consumes no allowance.** The vault burns AMPS it has already taken custody of — a redeemer's
///      shares (burned before any asset moves), released inventory, and the buyback burn. The vault is the trust
///      boundary; an allowance between the two would be a second one.
///
/// @dev **{setVault} is the token's half of the migration handover.** It is `onlyVault`, so
///      `AmpsVault.emergencyMigrate` can hand the role to the standby in the same transaction that moves the
///      liquidity, and nobody else can hand it on at all.
interface IAmps is IERC20 {
    /// @notice The only address allowed to mint, burn and hand the role on.
    /// @return vaultAddress The current vault.
    function vault() external view returns (address vaultAddress);

    /// @notice Mints `amount` to `to`. **Only vault.**
    /// @param to The recipient.
    /// @param amount The AMPS wei to mint.
    function mint(address to, uint256 amount) external;

    /// @notice Burns `amount` from `from`. **Only vault**; no allowance is consumed.
    /// @param from The account to burn from.
    /// @param amount The AMPS wei to burn.
    function burn(address from, uint256 amount) external;

    /// @notice Hands the vault role to `newVault`. **Only vault.**
    /// @param newVault The new vault.
    function setVault(address newVault) external;
}
