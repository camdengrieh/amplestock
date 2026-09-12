// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice The two probes that are about what an ordinary account *cannot* do.
///
/// @dev **Both assert on the success arm, which is the Medusa-safe shape.** `vm.snapshotState` and
///      `vm.revertToState` are not implemented in Medusa 1.5.1, so a probe cannot take a snapshot, try something
///      forbidden and roll back. Instead each call is made through `try`/`catch` and the *absence* of a revert is
///      the violation. Nothing is left behind either way: a role-gated selector that refuses changes nothing, and
///      one that does not refuse is already the finding.
///
/// @dev **Why the privilege probe is one selector per call rather than a loop.** A `vm.prank` is single-shot: it is
///      consumed by the next external call. A loop over twelve selectors would need twelve pranks, and the one that
///      landed would be the one nobody could attribute. The `selectorSeed` picks one, the fuzzer walks the space.
abstract contract AdversaryHandler is Properties {
    /// @notice Dispatches an unprivileged actor into every role-gated selector in the system, one per call.
    /// @dev New in this pass — see the "Handlers to add" table of `fizz_data/property-plan.md`. This is GL-63's
    ///      reachability half: the global property states the rule, this handler is what makes a violation of it
    ///      appear at all.
    /// @param selectorSeed Chooses which gated selector to try.
    /// @param argSeed Chooses the argument.
    function adversary_callPrivileged(uint256 selectorSeed, uint256 argSeed) public {
        uint256 which = selectorSeed % 14;
        address target;
        bytes memory payload;

        if (which == 0) {
            target = address(vault);
            payload = abi.encodeWithSignature("setRedeemFeeBps(uint16)", uint16(argSeed % 100));
        } else if (which == 1) {
            target = address(vault);
            payload = abi.encodeWithSignature("setRolloutParams(uint16,uint16)", uint16(argSeed % 100), uint16(0));
        } else if (which == 2) {
            target = address(vault);
            payload = abi.encodeWithSignature(
                "place(bytes32,bool,uint256)", PoolId.unwrap(poolFrom(argSeed)), true, uint256(1)
            );
        } else if (which == 3) {
            target = address(vault);
            payload = abi.encodeWithSignature("withdrawRetiredBids(uint16)", constituentFrom(argSeed));
        } else if (which == 4) {
            target = address(vault);
            payload = abi.encodeWithSignature("mintVesting(address,uint256)", actor, uint256(1e18));
        } else if (which == 5) {
            target = address(vault);
            payload = abi.encodeWithSignature(
                "depositBonded(uint16,address,address,uint256)", marketFrom(argSeed), address(usdg), actor, uint256(1)
            );
        } else if (which == 6) {
            target = address(vault);
            payload = abi.encodeWithSignature("emergencyMigrate(address)", actor);
        } else if (which == 7) {
            target = address(amps);
            payload = abi.encodeWithSignature("mint(address,uint256)", actor, uint256(1e18));
        } else if (which == 8) {
            target = address(amps);
            payload = abi.encodeWithSignature("burn(address,uint256)", actor, uint256(1));
        } else if (which == 9) {
            target = address(bonds);
            payload = abi.encodeWithSignature("setMarketOpen(uint16,bool)", marketFrom(argSeed), true);
        } else if (which == 10) {
            target = address(registry);
            payload = abi.encodeWithSignature("retireConstituent(uint16)", constituentFrom(argSeed));
        } else if (which == 11) {
            target = address(gate);
            payload = abi.encodeWithSignature("freezeProtocol(uint32)", uint32(block.timestamp + Constants.ONE_HOUR));
        } else if (which == 12) {
            target = address(hook);
            payload = abi.encodeWithSignature("setAmpsFeeBps(uint16)", uint16(300));
        } else {
            target = address(vault);
            payload = abi.encodeWithSignature("unlockCallback(bytes)", bytes(""));
        }

        vm.prank(actor);
        (bool ok,) = target.call(payload);

        if (ok) ghosts.livenessReverts[keccak256("privilegeAccepted")] += 1;
        t(!ok, "GL-63: a role-gated selector accepted a call from an account that holds no role");
    }

    /// @notice A maximal AMPS allowance from a victim, then an attempt to redeem the victim's shares with it.
    /// @dev New in this pass — see "Handlers to add". `redeemProRata` burns `msg.sender`'s shares and takes no
    ///      `from` parameter, so there is no allowance path into another holder's position at all; what this
    ///      handler proves is that granting one changes nothing.
    /// @param ownerSeed Chooses the victim.
    /// @param sharesSeed Chooses how much to try for.
    function adversary_crossUserRedeem(address ownerSeed, uint256 sharesSeed) public {
        address victim = toActorNotCurrent(ownerSeed);
        if (victim == actor) return;

        uint256 victimBefore = amps.balanceOf(victim);
        if (victimBefore == 0) return;
        uint256 attackerBefore = amps.balanceOf(actor);

        // The victim hands over the largest allowance an ERC-20 knows how to express.
        vm.prank(victim);
        amps.approve(actor, type(uint256).max);

        uint256 shares = clampBetween(sharesSeed, attackerBefore + 1, attackerBefore + victimBefore);
        uint256[] memory before = _actorAmps();

        vm.prank(actor);
        try vault.redeemProRata(shares, actor) returns (address[] memory, uint256[] memory) {
            ghosts.livenessReverts[keccak256("crossUserAccepted")] += 1;
        } catch {}

        // SP-12: whatever happened, the victim's shares are still the victim's.
        eq(amps.balanceOf(victim), victimBefore, "SP-12: an allowance let one holder redeem another's shares");
        property_onlyTheCallersOwnPosition(
            before, _actorAmps(), actor, actor, "SP-12: a cross-user redemption moved a third party's AMPS"
        );
    }
}
