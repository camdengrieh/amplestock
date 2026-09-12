// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with `PoolRegistry`: retiring and reinstating a constituent, and replacing the
///         index weight vector.
///
/// @dev **All three are `onlyTimelock`** and are pranked as such.
///
/// @dev **The weight vector is *replaced*, not adjusted.** After `setIndexWeights` the target weights of every
///      `ACTIVE` constituent must sum to exactly `BPS`, and each must sit inside `[floor_n, cap_n]` for the current
///      active count. A fuzzed vector satisfies that with probability zero, so the clamped handler builds a legal
///      vector over the live active set — an equal split with the rounding remainder on the first name — and lets the
///      fuzzer choose only how much to tilt it. That keeps the setter's *rebalance* path reachable, which the band
///      check would otherwise hide behind a revert.
///
/// @dev **Retirement is the interesting state.** A retired name has no open bond market (I37), zero rollout weight,
///      and its bids become an exit market that only `withdrawRetiredBids` can move — which is the one caller
///      `AmpsVault.withdrawRetiredBids` accepts, and which `AmpsVaultHandler` drives through here.
///
/// @dev **Two constituents are read around every call**: the *subject* the seed names, for SP-50/SP-51/SP-52, and
///      one *witness* that the call is not about, for SP-53. A full walk of thirty names would not fit the
///      dispatcher's block; the isolation identity is per-record, so a violation on any of them is reachable.
abstract contract PoolRegistryHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice The registry's secondary surface.
    /// @param selector Chooses the action.
    /// @param idSeed Chooses the constituent.
    /// @param weightSeed Chooses the tilt of the weight vector, or the reinstated rollout weight.
    function poolRegistry_secondary(uint8 selector, uint256 idSeed, uint256 weightSeed) public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();

        uint16 subject = constituentFrom(idSeed);
        uint16 witness = constituentFrom(idSeed + 1);
        if (witness == subject) witness = constituentFrom(idSeed + 2);

        uint256 supplyBefore = amps.totalSupply();
        uint256[] memory actorsBefore = _actorAmps();
        uint256 navBefore = _tryNavPerShare();
        uint16 activeBefore = registry.activeConstituentCount();
        ConstituentStatus statusBefore = registry.constituent(subject).status;
        ConstituentStatus witnessStatusBefore = registry.constituent(witness).status;
        uint16 witnessTargetBefore = registry.constituent(witness).targetWeightBps;
        uint32 witnessRetiredBefore = registry.constituent(witness).retiredAt;

        selector = uint8(selector % 3);
        if (selector == 0) _poolRegistry_retireConstituent(subject);
        else if (selector == 1) _poolRegistry_reinstateConstituent(subject, weightSeed);
        else _poolRegistry_setIndexWeights(weightSeed);

        snapshotAfter();

        ConstituentStatus statusAfter = registry.constituent(subject).status;

        // SP-01, SP-50, SP-51, SP-52, SP-53 and SP-58.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_statusMovesOnLegalEdgesOnly(statusBefore, statusAfter);
        property_activeCountDelta(statusBefore, statusAfter, activeBefore, registry.activeConstituentCount());
        property_retireStampsAndZeroes(
            statusBefore,
            statusAfter,
            registry.constituent(subject).rolloutWeightBps,
            registry.constituent(subject).retiredAt
        );
        property_registryCallIsIsolated(
            witnessStatusBefore,
            registry.constituent(witness).status,
            witnessTargetBefore,
            registry.constituent(witness).targetWeightBps,
            witnessRetiredBefore,
            registry.constituent(witness).retiredAt
        );
        property_governedSetterIsValueNeutral(
            supplyBefore, amps.totalSupply(), actorsBefore, _actorAmps(), navBefore, _tryNavPerShare()
        );
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    /// @dev Retires one name: the flag, the rollout weight and the bond market. Refused unless it is `ACTIVE`.
    function _poolRegistry_retireConstituent(uint16 constituentId) internal asAdmin {
        registry.retireConstituent(constituentId);
    }

    /// @dev Reinstates one name with a rollout weight inside `[0, BPS]`. Refused unless it is `RETIRED`, and refused
    ///      again if its stored *target* weight is no longer legal for the count the reinstatement produces.
    function _poolRegistry_reinstateConstituent(uint16 constituentId, uint256 weightSeed) internal asAdmin {
        registry.reinstateConstituent(constituentId, uint16(clampBetween(weightSeed, 0, Constants.BPS)));
    }

    /// @dev A legal weight vector over the live active set: an equal split, the remainder on the first name, then
    ///      one fuzzed unit of tilt moved from the last name to the first as long as both stay inside the band.
    function _poolRegistry_setIndexWeights(uint256 tiltSeed) internal {
        uint16[] memory ids = activeConstituents();
        uint256 n = ids.length;
        if (n == 0) return;

        uint16 floorBps = registry.indexFloorBps();
        uint16 capBps = registry.indexCapBps();
        uint16[] memory weights = new uint16[](n);
        uint256 base = Constants.BPS / n;
        for (uint256 i; i < n; ++i) {
            weights[i] = uint16(base);
        }
        weights[0] = uint16(base + (Constants.BPS - base * n));

        if (n > 1) {
            uint256 headroom = capBps > weights[0] ? capBps - weights[0] : 0;
            uint256 slack = weights[n - 1] > floorBps ? weights[n - 1] - floorBps : 0;
            uint256 tilt = clampBetween(tiltSeed, 0, headroom < slack ? headroom : slack);
            weights[0] = uint16(weights[0] + tilt);
            weights[n - 1] = uint16(weights[n - 1] - tilt);
        }

        vm.prank(admin);
        registry.setIndexWeights(ids, weights);
    }
}
