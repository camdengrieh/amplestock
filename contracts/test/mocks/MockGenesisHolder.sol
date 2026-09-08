// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockGenesisHolder
/// @notice The smallest thing that can stand in for `AmpsGenesis` in a fixture: an address with code that can
///         hold the auction tranche, approve the vault and call `genesisPlace`.
///
/// @dev **Why the fixtures use this rather than the real adapter.** Every fixture below `test/unit` and
///      `test/integration` is about the *vault*, not about an auction: it wants `S0` minted with the real split
///      and a launch reference set, without a factory, a block schedule or a bidding window in the way. This mock
///      is exactly the part of `AmpsGenesis` those fixtures need — the tranche's custody and the second genesis
///      call — and `AmpsGenesis.t.sol` exercises the real adapter against {MockCCAFactory} instead.
///
/// @dev **It keeps the auction tranche.** In a fixture the tranche stands for AMPS that cleared to bidders: it is
///      in `totalSupply` (so NAV/share is `raised / S0`, fully diluted, decision 14) and it is not the vault's
///      inventory (so the POL tranche the ladders are laid out of is exactly `Constants.POL_SHARES`). A fixture
///      that wanted the no-graduation shape instead calls {send} first.
contract MockGenesisHolder {
    /// @notice Approves `spender` for `amount` of `token`. Test-only: unrestricted by design.
    /// @param token The token.
    /// @param spender The spender.
    /// @param amount The allowance.
    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    /// @notice Sends `amount` of `token` to `to`. Test-only: unrestricted by design.
    /// @param token The token.
    /// @param to The recipient.
    /// @param amount The amount.
    function send(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }

    /// @notice Calls `AmpsVault.genesisPlace` as the vault's `genesis` pointer, which is the caller rule the
    ///         adapter satisfies in production.
    /// @param vault The vault.
    /// @param params The placement arguments.
    function place(address vault, IAmpsVault.GenesisPlaceParams calldata params) external {
        IAmpsVault(vault).genesisPlace(params);
    }
}
