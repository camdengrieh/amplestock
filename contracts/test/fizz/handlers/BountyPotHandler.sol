// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with `BountyPot`, the USDG purse that pays for `compound`, `rollout` and
///         `deployBonded`.
///
/// @dev **`fund` is permissionless** — anyone may top the pot up — so it is called as the actor, who is minted the
///      USDG the call is about to pull. Draining the pot is what makes the keeper paths' *unpaid* branch reachable:
///      the vault still does the work when the pot cannot pay, and `pay` charges a rolling window rather than
///      reverting, so a pot that runs dry is a legitimate state rather than an error.
///
/// @dev `pay` and `sweep` are not handlers: `pay` is vault-only and is reached through every keeper path in
///      `AmpsVaultHandler`, and `sweep` is a timelock withdrawal that was not selected.
///
/// @dev **This is where SP-30 is asserted.** The pot is excluded from `A` (plan I21), so a top-up is the one
///      movement of protocol-held value that must leave `totalAssetsUsd18` at exactly the number it was. The
///      keeper paths also move the pot, but they move `A` for placement reasons of their own, so the identity is
///      only separable here.
abstract contract BountyPotHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice The pot's secondary surface.
    /// @param selector Chooses the size of the top-up.
    /// @param amountSeed Chooses the amount, in USDG's 6 decimals.
    function bountyPot_secondary(uint8 selector, uint256 amountSeed) public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();

        uint256 supplyBefore = amps.totalSupply();
        uint256[] memory actorsBefore = _actorAmps();
        uint256 aBefore = _tryTotalAssets();
        uint256 navBefore = _tryNavPerShare();
        uint256 potBefore = pot.balance();

        selector = uint8(selector % 2);
        if (selector == 0) _bountyPot_fund(amountSeed);
        else _bountyPot_fundDust(amountSeed);

        snapshotAfter();
        ghosts.potFundedRaw += pot.balance() > potBefore ? pot.balance() - potBefore : 0;

        // SP-01, SP-30 and SP-58.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_potMovementsDoNotMoveA(aBefore, _tryTotalAssets());
        property_governedSetterIsValueNeutral(
            supplyBefore, amps.totalSupply(), actorsBefore, _actorAmps(), navBefore, _tryNavPerShare()
        );
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    /// @dev A realistic top-up: 1 to 100,000 USDG.
    /// @dev Two single-shot pranks rather than one `startPrank` window: `fund` can revert, and a `startPrank` whose
    ///      body reverts leaks the prank into the next handler (see {Base-asActor}).
    function _bountyPot_fund(uint256 amountSeed) internal {
        uint256 amountRaw = clampBetween(amountSeed, 1e6, 100_000e6);
        usdg.mint(actor, amountRaw);

        vm.prank(actor);
        usdg.approve(address(pot), type(uint256).max);
        vm.prank(actor);
        pot.fund(amountRaw);
    }

    /// @dev A dust top-up: one raw unit, i.e. 1e-6 USDG, which is below every bounty the pot can pay.
    function _bountyPot_fundDust(uint256 amountSeed) internal {
        uint256 amountRaw = clampBetween(amountSeed, 1, 1e6);
        usdg.mint(actor, amountRaw);

        vm.prank(actor);
        usdg.approve(address(pot), type(uint256).max);
        vm.prank(actor);
        pot.fund(amountRaw);
    }
}
