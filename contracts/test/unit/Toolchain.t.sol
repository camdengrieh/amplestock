// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {V4TestBase} from "../utils/V4TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @dev Proves the pinned toolchain compiles every dependency the design imports and that a local v4 stack deploys.
contract ToolchainTest is V4TestBase {
    uint160 internal constant AMPS_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    function setUp() public {
        deployV4();
    }

    function test_hookFlagsMatchDesign() public pure {
        assertEq(AMPS_HOOK_FLAGS, 0x38C0, "flags must equal 0x38C0");
        assertEq(AMPS_HOOK_FLAGS & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG, 0, "no remove-liquidity bit");
        assertEq(AMPS_HOOK_FLAGS & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG, 0, "no returns-delta bit");
        assertEq(AMPS_HOOK_FLAGS & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG, 0, "no returns-delta bit");
    }

    function test_maxLpFeeAllowsSellFeePlusDynamicCap() public pure {
        // 600 bp sell fee + 2000 bp dynamic cap = 2600 bp = 260_000 pips
        assertLt(uint24(260_000), LPFeeLibrary.MAX_LP_FEE);
        assertEq(TickMath.MIN_TICK, -887_272);
    }

    function test_localV4StackDeploys() public view {
        assertGt(address(poolManager).code.length, 0, "pool manager");
        assertGt(address(positionManager).code.length, 0, "position manager");
        assertGt(address(swapRouter).code.length, 0, "router");
        assertGt(address(permit2).code.length, 0, "permit2");
    }

    function test_deployTokenAtControlsOrdering() public {
        address low = address(0x00000012345678000000000000000000000000aA);
        deployTokenAt(low, "Amplestocks", "AMPS", 18);
        assertEq(low.code.length > 0, true);
    }
}
