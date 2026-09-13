// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with the `Amps` share token itself: the two ERC-20 movements that are in scope,
///         plus the two *neutral* movements the standard has a MUST clause about.
///
/// @dev **Why these are in scope at all.** AMPS is the redemption claim, so who holds it and who is allowed to
///      move it is what `redeemProRata`, `AmpsBonds.claim` and every fee burn are measured against. `mint` and
///      `burn` are vault-only by construction and are therefore *not* handlers — they are reached through
///      `AmpsBonds.bond` and through the burns inside `compound` and `redeemProRata`.
abstract contract AmpsHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice The token's secondary surface: move shares between actors, hand an allowance to a protocol
    ///         contract, or make one of the two movements that must change nothing at all.
    /// @param selector Chooses the action.
    /// @param amountSeed Chooses the amount.
    /// @param whoSeed Chooses the counterparty.
    function amps_secondary(uint8 selector, uint256 amountSeed, address whoSeed) public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();
        uint256 supplyBefore = amps.totalSupply();

        selector = uint8(selector % 4);
        if (selector == 0) _amps_transfer(whoSeed, amountSeed);
        else if (selector == 1) _amps_approve(whoSeed, amountSeed);
        else if (selector == 2) _amps_transferAll(whoSeed);
        else _amps_neutral();

        snapshotAfter();
        noteAmpsHolder(toActorNotCurrent(whoSeed));

        // SP-01: nothing on this surface is a mint site.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    /// @dev A partial transfer to another actor, bounded by the sender's balance.
    function _amps_transfer(address toSeed, uint256 amountSeed) internal {
        uint256 balance = amps.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = clampBetween(amountSeed, 1, balance);
        address to = toActorNotCurrent(toSeed);
        if (to == actor) return;

        uint256 toBefore = amps.balanceOf(to);

        vm.prank(actor);
        amps.transfer(to, amount);

        // SP-62.
        property_transferAccountingIsExact(balance, amps.balanceOf(actor), toBefore, amps.balanceOf(to), amount);
    }

    /// @dev The whole balance to another actor: the case that empties a redeemer.
    function _amps_transferAll(address toSeed) internal {
        uint256 balance = amps.balanceOf(actor);
        if (balance == 0) return;
        address to = toActorNotCurrent(toSeed);
        if (to == actor) return;

        uint256 toBefore = amps.balanceOf(to);

        vm.prank(actor);
        amps.transfer(to, balance);

        // SP-62.
        property_transferAccountingIsExact(balance, amps.balanceOf(actor), toBefore, amps.balanceOf(to), balance);
    }

    /// @dev An allowance to one of the protocol's spenders or to another actor. The amount is unclamped on purpose:
    ///      zero and `type(uint256).max` are both meaningful for an ERC-20 allowance.
    function _amps_approve(address spenderSeed, uint256 amountSeed) internal {
        uint256 kind = uint256(uint160(spenderSeed)) % 4;
        address spender = kind == 0
            ? address(vault)
            : (kind == 1 ? address(ampsRouter) : (kind == 2 ? address(swapRouter) : toActorNotCurrent(spenderSeed)));

        vm.prank(actor);
        amps.approve(spender, amountSeed);

        eq(amps.allowance(actor, spender), amountSeed, "SP-62: approve did not install exactly the allowance given");
    }

    /// @dev The two movements the ERC-20 standard requires to succeed and to change nothing: a transfer to
    ///      yourself, and a transfer of zero. Both are wrapped, because the property is that neither reverts.
    function _amps_neutral() internal {
        uint256 balanceBefore = amps.balanceOf(actor);
        address other = toActorNotCurrent(address(uint160(uint256(keccak256(abi.encode(actor))))));

        bool selfOk = true;
        vm.prank(actor);
        try amps.transfer(actor, balanceBefore) returns (bool) {}
        catch {
            selfOk = false;
        }

        bool zeroOk = true;
        vm.prank(actor);
        try amps.transfer(other, 0) returns (bool) {}
        catch {
            zeroOk = false;
        }

        // SP-61.
        property_neutralErc20OpsAreNeutral(selfOk, zeroOk, balanceBefore, amps.balanceOf(actor));
    }
}
