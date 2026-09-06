// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {NotVault} from "../../src/types/Errors.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title JitEmptyTickTest
/// @notice The plan's named attack **JIT position at an empty tick (no `donate()`)**: a searcher adds liquidity in
///         front of a swap at a tick nobody is quoting, takes the fee, and removes it in the same block.
///
///         Amplestocks is POL-only, and that is enforced rather than asserted: `beforeAddLiquidity` requires
///         `sender == vault`, so there is no way for anybody else to hold a position in any of the 32 pools. The
///         complementary half is that the hook has no way to hand value to a position it does not own either — it
///         never calls `donate`, `swap`, `settle`, `take`, `mint` or `burn`, and carries no returns-delta bit, so
///         a JIT position could not be paid even if one could exist (I13).
contract JitEmptyTickTest is Phase3Fixture {
    address internal constant SEARCHER = address(0x51A4CE);

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    /// @notice Nobody but the vault may open a position, in any pool, at any tick - empty or not.
    function test_onlyTheVaultMayAddLiquidity() public {
        PoolKey memory key = registry.poolKey(hubPool);
        int24 base = gridBaseOf(hubPool);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: base + cellWidth() * 4, tickUpper: base + cellWidth() * 5, liquidityDelta: 1e18, salt: bytes32(0)
        });

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, SEARCHER));
        hook.beforeAddLiquidity(SEARCHER, key, params, "");

        // The router path a searcher would actually use fails the same way, wrapped by the PoolManager.
        vm.prank(SEARCHER);
        vm.expectRevert();
        poolManager.unlock(abi.encode(key, params));
    }

    /// @notice I13, at the bytecode level: the deployed hook contains no reference to any PoolManager mutator. A
    ///         JIT position could not be paid a donation even if one could exist.
    function test_theHookCannotMoveValueAtAll() public view {
        bytes memory code = address(hook).code;
        assertFalse(_contains(code, IPoolManager.donate.selector), "no donate()");
        assertFalse(_contains(code, IPoolManager.swap.selector), "no swap()");
        assertFalse(_contains(code, IPoolManager.modifyLiquidity.selector), "no modifyLiquidity()");
        assertFalse(_contains(code, IPoolManager.take.selector), "no take()");
        assertFalse(_contains(code, IPoolManager.mint.selector), "no mint()");
        assertFalse(_contains(code, IPoolManager.burn.selector), "no burn()");
        assertFalse(_contains(code, bytes4(keccak256("settle()"))), "no settle()");
        assertFalse(_contains(code, bytes4(keccak256("sync(address)"))), "no sync()");
    }

    /// @notice The mined shape: exactly `0x38C0`, no returns-delta bit on either callback, and no
    ///         `BEFORE_REMOVE_LIQUIDITY` bit - so a removal can never be blocked (I18).
    function test_hookPermissionsMatchTheMinedBits() public view {
        uint160 flags = uint160(address(hook)) & uint160(Constants.HOOK_ADDRESS_MASK);
        assertEq(uint256(flags), uint256(HOOK_FLAGS), "the deployed address carries exactly the mined bits");
        assertEq(uint256(flags), 0x38C0, "which is 0x38C0");

        assertEq(flags & uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG), 0, "no beforeSwap returns-delta bit");
        assertEq(flags & uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG), 0, "no afterSwap returns-delta bit");
        assertEq(flags & uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG), 0, "no beforeRemoveLiquidity bit (I18)");
        assertEq(flags & uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG), 0, "no afterRemoveLiquidity bit");
        assertEq(flags & uint160(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG), 0, "no add-liquidity returns-delta bit");

        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeInitialize, "beforeInitialize");
        assertTrue(permissions.afterInitialize, "afterInitialize");
        assertTrue(permissions.beforeAddLiquidity, "beforeAddLiquidity");
        assertTrue(permissions.beforeSwap, "beforeSwap");
        assertTrue(permissions.afterSwap, "afterSwap");
        assertFalse(permissions.beforeRemoveLiquidity, "no beforeRemoveLiquidity");
        assertFalse(permissions.afterRemoveLiquidity, "no afterRemoveLiquidity");
        assertFalse(permissions.beforeDonate, "no beforeDonate");
        assertFalse(permissions.afterDonate, "no afterDonate");
        assertFalse(permissions.beforeSwapReturnDelta, "no beforeSwap delta");
        assertFalse(permissions.afterSwapReturnDelta, "no afterSwap delta");
    }

    /// @notice The vault is the only position owner in every pool: the whole fee stream accrues to POL and there
    ///         is nothing for a searcher to sit in front of.
    function test_everyPositionInEveryPoolBelongsToTheVault() public {
        buyAmps(hubPool, ALICE, 1e6);
        assertEq(poolManager.balanceOf(SEARCHER, uint256(uint160(address(amps)))), 0, "the searcher owns nothing");
        assertEq(vault.liveCells(), countLiveCells(), "and the vault's own count is the whole book");
    }

    /// @dev Whether `code` contains the four bytes of `selector`.
    function _contains(bytes memory code, bytes4 selector) private pure returns (bool found) {
        if (code.length < 4) return false;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (
                code[i] == selector[0] && code[i + 1] == selector[1] && code[i + 2] == selector[2]
                    && code[i + 3] == selector[3]
            ) return true;
        }
    }
}
