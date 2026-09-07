// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsHook} from "../../src/hook/AmpsHook.sol";
import {Constants} from "../../src/types/Constants.sol";
import {PoolClass, PoolConfig} from "../../src/types/Types.sol";
import {V4TestBase} from "../utils/V4TestBase.sol";
import {HookStubFeePolicy} from "./HookStubFeePolicy.sol";
import {MockOracleGate} from "./MockOracleGate.sol";
import {MockPoolRegistry} from "./MockPoolRegistry.sol";
import {MockStockToken} from "./MockStockToken.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Vm} from "forge-std/Vm.sol";
import {PathKey} from "hookmate/interfaces/router/PathKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title HookTestFixture
/// @notice The wired-up local stack every `AmpsHook` suite runs against: a real v4 PoolManager, three real pools
///         (`AMPS/USDG` and `AMPS/WETH` entry, `AMPS/STOCK` spoke), a `MockPoolRegistry` configured like
///         production, a `MockOracleGate`, a `HookStubFeePolicy` and the mined hook itself.
///
/// @dev **The test contract is the vault.** It deploys the hook, initialises every pool, is the sole liquidity
///      provider, and answers `oracleGate()` — which is where the hook reads the gate pointer from, because
///      `OracleGate` is pointer-upgradeable and a hook that froze its address would go blind after a redeploy.
///
/// @dev **Transient storage.** Foundry 1.8 clears transient storage between top-level calls made by a test, so
///      every scenario that seeds and then spends the rotation credit must run inside one self-call
///      (`this.someEntry()`), exactly as `test/gas/GasBaseline.t.sol` does.
abstract contract HookTestFixture is V4TestBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    /// @dev Three leading zero bytes, standing in for the CREATE2-mined production AMPS address, so AMPS is
    ///      `currency0` in every pool and `zeroForOne == true` is unconditionally "selling AMPS".
    address internal constant AMPS_ADDRESS = 0x0000001234567890123456789012345678901234;
    address internal constant USDG_ADDRESS = 0x1111111111111111111111111111111111111111;
    address internal constant WETH_ADDRESS = 0x3333333333333333333333333333333333333333;

    address internal constant TIMELOCK = address(0x71E10C);
    address internal constant STRANGER = address(0xBADBAD);

    int24 internal constant TICK_SPACING = 10;
    uint16 internal constant SPOKE_CONSTITUENT_ID = 1;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    MockERC20 internal amps;
    MockERC20 internal usdg;
    MockERC20 internal weth;
    MockStockToken internal stock;

    MockPoolRegistry internal registry;
    MockOracleGate internal gate;
    HookStubFeePolicy internal policy;
    AmpsHook internal hook;

    PoolKey internal usdgKey;
    PoolKey internal wethKey;
    PoolKey internal stockKey;
    PoolId internal usdgId;
    PoolId internal wethId;
    PoolId internal stockId;

    /// @notice The gate pointer the hook reads off "the vault". Settable so a suite can break it on purpose.
    address internal gatePointer;

    /// @notice When true, `oracleGate()` reverts, which is the "the vault itself is broken" fault mode.
    bool internal gatePointerReverts;

    // -----------------------------------------------------------------------------------------------------------
    // Set-up
    // -----------------------------------------------------------------------------------------------------------

    function _deployFixture() internal {
        deployV4();

        amps = deployTokenAt(AMPS_ADDRESS, "Amplestocks", "AMPS", 18);
        usdg = deployTokenAt(USDG_ADDRESS, "Global Dollar", "USDG", 6);
        weth = deployTokenAt(WETH_ADDRESS, "Wrapped Ether", "WETH", 18);

        stock = new MockStockToken("Mock Stock Token", "STOCK");
        stock.mint(address(this), 10_000_000e18);
        _approveStack(address(stock));
        vm.label(address(stock), "STOCK");

        registry = new MockPoolRegistry();
        gate = new MockOracleGate();
        policy = new HookStubFeePolicy();
        gatePointer = address(gate);

        registry.setVault(address(this));

        bytes memory args = abi.encode(poolManager, AMPS_ADDRESS, address(this), address(registry), TIMELOCK);
        (address mined, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(AmpsHook).creationCode, args);
        hook = new AmpsHook{salt: salt}(poolManager, AMPS_ADDRESS, address(this), address(registry), TIMELOCK);
        require(address(hook) == mined, "hook address mismatch");
        vm.label(address(hook), "AmpsHook");
        registry.setHook(address(hook));

        vm.prank(TIMELOCK);
        hook.setFeePolicy(address(policy));

        usdgKey = _poolKey(USDG_ADDRESS);
        wethKey = _poolKey(WETH_ADDRESS);
        stockKey = _poolKey(address(stock));
        usdgId = usdgKey.toId();
        wethId = wethKey.toId();
        stockId = stockKey.toId();

        _registerEntry(usdgId, USDG_ADDRESS, 6);
        _registerEntry(wethId, WETH_ADDRESS, 18);
        _registerSpoke(stockId, address(stock), PoolClass.SPOKE);
        registry.setHubPoolId(usdgId);
        registry.setWethPoolId(wethId);

        // AMPS $1.00. USDG is 6-decimal $1.00, so raw amount1/amount0 = 1e6 / 1e18.
        poolManager.initialize(usdgKey, _sqrtPriceX96(1e6, 1e18));
        // WETH is 18-decimal $4,000, so raw amount1/amount0 = 1 / 4000.
        poolManager.initialize(wethKey, _sqrtPriceX96(1, 4000));
        // STOCK is 18-decimal $180.
        poolManager.initialize(stockKey, _sqrtPriceX96(1, 180));

        _seedPool(usdgKey, 1_000_000e18, 1_000_000e6);
        _seedPool(wethKey, 1_000_000e18, 250e18);
        _seedPool(stockKey, 1_000_000e18, 6000e18);
    }

    /// @notice Registers one of the two entry pools exactly as `PoolRegistry.registerEntryPool` would.
    function _registerEntry(PoolId poolId, address counter, uint8 counterDecimals) internal {
        registry.setPool(
            poolId,
            PoolConfig({
                counter: counter,
                poolClass: PoolClass.ENTRY,
                counterDecimals: counterDecimals,
                tickSpacing: TICK_SPACING,
                buyFeeBps: Constants.BUY_FEE_BPS_ENTRY_DEFAULT,
                constituentId: 0,
                registered: true,
                gridBaseTick: 0
            })
        );
    }

    /// @notice Registers a spoke pool and its constituent.
    function _registerSpoke(PoolId poolId, address token, PoolClass poolClass) internal {
        registry.addConstituentAndPool(token, address(0xFEED), poolId, poolClass, TICK_SPACING, 1000);
        registry.setPool(
            poolId,
            PoolConfig({
                counter: token,
                poolClass: poolClass,
                counterDecimals: 18,
                tickSpacing: TICK_SPACING,
                buyFeeBps: poolClass == PoolClass.SPOKE_HIGH_VOL
                    ? Constants.BUY_FEE_BPS_SPOKE_HIGH_VOL_DEFAULT
                    : Constants.BUY_FEE_BPS_SPOKE_DEFAULT,
                constituentId: SPOKE_CONSTITUENT_ID,
                registered: true,
                gridBaseTick: 0
            })
        );
    }

    // -----------------------------------------------------------------------------------------------------------
    // The vault surface the hook reads
    // -----------------------------------------------------------------------------------------------------------

    /// @notice `IAmpsVault.oracleGate()`. The hook reads the gate pointer here rather than holding it immutable.
    /// @return gateAddress The gate.
    function oracleGate() external view returns (address gateAddress) {
        require(!gatePointerReverts, "HookTestFixture: gate pointer reverting");
        return gatePointer;
    }

    /// @notice Points the hook at a different gate, or at nothing.
    function _setGatePointer(address value) internal {
        gatePointer = value;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Pool helpers
    // -----------------------------------------------------------------------------------------------------------

    function _poolKey(address counter) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(AMPS_ADDRESS),
            currency1: Currency.wrap(counter),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev `sqrtPriceX96 = sqrt(num / den) * 2**96`, with `num / den` the raw amount1 per amount0.
    function _sqrtPriceX96(uint256 num, uint256 den) internal pure returns (uint160) {
        uint256 ratioX96 = FullMath.mulDiv(num, 1 << 96, den);
        return uint160(FixedPointMathLib.sqrt(ratioX96 << 96));
    }

    /// @dev Two-sided liquidity around the current tick, added by the "vault" so `beforeAddLiquidity` runs.
    function _seedPool(PoolKey memory key, uint256 amount0, uint256 amount1) internal {
        (uint160 sqrtPriceX96, int24 tick,,) = _slot0(key.toId());
        int24 lower = _align(tick - 20_000);
        int24 upper = _align(tick + 20_000);
        _addLiquidity(
            key,
            lower,
            upper,
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
            )
        );
    }

    function _addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) internal {
        poolManager.unlock(abi.encode(key, tickLower, tickUpper, int256(uint256(liquidity))));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external virtual override returns (bytes memory) {
        require(msg.sender == address(poolManager), "unlockCallback: not the PoolManager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
            abi.decode(data, (PoolKey, int24, int24, int256));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            poolManager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transfer(address(poolManager), uint256(uint128(-amount)));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    /// @dev `slot0` through the manager's own `extsload`, so no test needs `StateLibrary`.
    function _slot0(PoolId poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        bytes32 word = poolManager.extsload(keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(uint256(6)))));
        assembly ("memory-safe") {
            sqrtPriceX96 := and(word, 0xffffffffffffffffffffffffffffffffffffffff)
            tick := signextend(2, shr(160, word))
            protocolFee := and(shr(184, word), 0xffffff)
            lpFee := and(shr(208, word), 0xffffff)
        }
    }

    function _currentTick(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = _slot0(poolId);
    }

    function _align(int24 tick) internal pure returns (int24 aligned) {
        aligned = (tick / TICK_SPACING) * TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) aligned -= TICK_SPACING;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Swaps
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Every router call below passes `type(uint256).max` as the deadline rather than
    ///      `block.timestamp + 1`: solc treats `TIMESTAMP` as loop-invariant and hoists it straight past a
    ///      `vm.warp`, so a deadline computed inside a warping loop is stale by the second iteration.
    ///
    /// @dev Exact-input buy: the counter asset in, AMPS out, so `zeroForOne == false`.
    function _buy(PoolKey memory key, uint256 amountIn) internal returns (uint256 ampsOut) {
        uint256 before = amps.balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(amountIn, 0, false, key, "", address(this), type(uint256).max);
        ampsOut = amps.balanceOf(address(this)) - before;
    }

    /// @dev Exact-input sell: AMPS in, so `zeroForOne == true` and the sell fee applies.
    function _sell(PoolKey memory key, uint256 amountIn) internal returns (uint256 counterOut) {
        MockERC20 counter = MockERC20(Currency.unwrap(key.currency1));
        uint256 before = counter.balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(amountIn, 0, true, key, "", address(this), type(uint256).max);
        counterOut = counter.balanceOf(address(this)) - before;
    }

    /// @dev The router call on its own, with no balance reads around it, so `vm.expectRevert` binds to the swap
    ///      and not to an `IERC20.balanceOf` that happens to come first.
    function _buyRaw(PoolKey memory key, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens(amountIn, 0, false, key, "", address(this), type(uint256).max);
    }

    /// @dev The sell counterpart of {_buyRaw}.
    function _sellRaw(PoolKey memory key, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens(amountIn, 0, true, key, "", address(this), type(uint256).max);
    }

    /// @dev Exact-**output** sell: AMPS in, an exact amount of the counter asset out. Consumes no rotation credit.
    function _sellExactOut(PoolKey memory key, uint256 amountOut) internal returns (uint256 ampsIn) {
        uint256 before = amps.balanceOf(address(this));
        swapRouter.swapTokensForExactTokens(
            amountOut, type(uint256).max, true, key, "", address(this), block.timestamp + 1
        );
        ampsIn = before - amps.balanceOf(address(this));
    }

    /// @dev The two-hop rotation `counterIn -> AMPS -> counterOut` as one exact-input `PathKey[]` router call.
    function _rotate(address counterIn, address counterOut, uint256 amountIn) internal returns (uint256 amountOut) {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(AMPS_ADDRESS),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(counterOut),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        uint256 before = MockERC20(counterOut).balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(
            amountIn, 0, Currency.wrap(counterIn), path, address(this), type(uint256).max
        );
        amountOut = MockERC20(counterOut).balanceOf(address(this)) - before;
    }

    /// @dev Runs `afterSwap` against the pool without moving it: same tick, zero delta, no router. This is how a
    ///      suite forces the gate-cache refresh (after warping past `gateCacheSeconds`) or the multiplier probe
    ///      without also changing the price the next assertion depends on.
    function _pokeAfterSwap(PoolKey memory key, bool zeroForOne) internal {
        SwapParams memory params = SwapParams({zeroForOne: zeroForOne, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), key, params, toBalanceDelta(0, 0), "");
    }

    /// @dev Warps past the cache interval and pokes, so the next quote sees whatever the gate now says.
    function _refreshGate(PoolKey memory key) internal {
        vm.warp(block.timestamp + hook.gateCacheSeconds() + 1);
        _pokeAfterSwap(key, true);
    }

    /// @dev Every `IPoolManager.Swap` fee field in the recorded logs, in emission order (one per hop).
    function _swapFees(Vm.Log[] memory logs) internal pure returns (uint24[] memory fees) {
        uint256 count;
        uint24[] memory buffer = new uint24[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                buffer[count++] = fee;
            }
        }
        fees = new uint24[](count);
        for (uint256 i; i < count; ++i) {
            fees[i] = buffer[i];
        }
    }

    /// @dev The fee the pool actually charged on the last swap, in pips.
    function _lastSwapFee(Vm.Log[] memory logs) internal pure returns (uint24 fee) {
        uint24[] memory fees = _swapFees(logs);
        require(fees.length != 0, "no Swap event");
        fee = fees[fees.length - 1];
    }

    /// @dev A hook revert as the PoolManager re-throws it: ERC-7751 `WrappedError`, not the bare error.
    function _wrapped(bytes4 hookSelector, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
