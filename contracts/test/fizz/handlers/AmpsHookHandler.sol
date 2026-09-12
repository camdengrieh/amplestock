// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {PoolClass} from "../../../src/types/Types.sol";
import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with `AmpsHook`'s two governed fee parameters.
///
/// @dev **Both are `onlyTimelock` and both are hard-banded.** `ampsFeeBps` lives in `[100, 600]` and is the fee
///      every buy and sell of AMPS pays in the input currency; `buyFeeBps` is per pool and its band depends on the
///      pool's class — `[5, 100]` for an entry pool, `[1, 50]` for a spoke — so the clamp has to read the class
///      first or the setter only ever exercises `OutOfBand`.
///
/// @dev The rest of the hook's surface is not a handler by construction: the two swap callbacks are only callable
///      by the PoolManager and are driven by every swap in `AmpsRouterHandler`, and `beforeInitialize` /
///      `afterInitialize` / `beforeAddLiquidity` have already run for every pool by the time `setup()` returns.
abstract contract AmpsHookHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice The hook's secondary surface.
    /// @param selector Chooses the setter.
    /// @param arg0 The pool seed, or the fee seed.
    /// @param arg1 The fee seed.
    function ampsHook_secondary(uint8 selector, uint256 arg0, uint256 arg1) public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();

        uint256 supplyBefore = amps.totalSupply();
        uint256[] memory actorsBefore = _actorAmps();
        uint256 navBefore = _tryNavPerShare();

        selector = uint8(selector % 2);
        if (selector == 0) _ampsHook_setAmpsFeeBps(arg0);
        else _ampsHook_setBuyFeeBps(arg0, arg1);

        snapshotAfter();

        // SP-01 and SP-58: a fee parameter is not a value transfer.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_governedSetterIsValueNeutral(
            supplyBefore, amps.totalSupply(), actorsBefore, _actorAmps(), navBefore, _tryNavPerShare()
        );
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    /// @dev The protocol fee every AMPS swap pays, inside `[AMPS_FEE_BPS_MIN, AMPS_FEE_BPS_MAX]`.
    function _ampsHook_setAmpsFeeBps(uint256 valueSeed) internal asAdmin {
        hook.setAmpsFeeBps(uint16(clampBetween(valueSeed, Constants.AMPS_FEE_BPS_MIN, Constants.AMPS_FEE_BPS_MAX)));
    }

    /// @dev One pool's buy fee, inside the band its class carries.
    function _ampsHook_setBuyFeeBps(uint256 poolSeed, uint256 valueSeed) internal {
        PoolId poolId = poolFrom(poolSeed);
        bool entry = registry.poolConfig(poolId).poolClass == PoolClass.ENTRY;
        uint16 value = uint16(
            entry
                ? clampBetween(valueSeed, Constants.BUY_FEE_BPS_ENTRY_MIN, Constants.BUY_FEE_BPS_ENTRY_MAX)
                : clampBetween(valueSeed, Constants.BUY_FEE_BPS_SPOKE_MIN, Constants.BUY_FEE_BPS_SPOKE_MAX)
        );

        vm.prank(admin);
        hook.setBuyFeeBps(poolId, value);
    }
}
