// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {V4TestBase} from "../utils/V4TestBase.sol";
import {StubAmpsHook} from "./StubAmpsHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {PathKey} from "hookmate/interfaces/router/PathKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title GasBaselineTest
/// @notice Phase 1 gas baselines for the Amplestocks hook, recorded against `StubAmpsHook` (flags `0x38C0`, the
///         production hook's gas-relevant shape with no business logic).
///
///         Two modes, selected by the `WRITE_GAS_BASELINE` environment variable:
///         - `WRITE_GAS_BASELINE=true`  — measure and write `contracts/gas/baseline.json`.
///         - unset / anything else      — measure, then assert every number is within baseline x 1.2.
///           A missing `baseline.json` logs and skips instead of failing, so a fresh checkout is not blocked.
///
/// @dev    All measurements run inside one test function, hence one EVM transaction: EIP-1153 transient storage is
///         only cleared per transaction, and the rotation credit therefore has to be explicitly re-armed between
///         scenarios (`StubAmpsHook.debugSetRotationCredit`). To keep the numbers representative of a real
///         first-swap-of-the-transaction rather than of an already-warm repeat, every measurement is preceded by
///         `vm.cool` on the whole v4 stack, the hook and the three tokens, so cold `SLOAD`/account-access costs are
///         priced in. Excludes the 21 000 intrinsic gas and calldata cost, which no hook change can move.
///
/// @dev    Run this suite WITHOUT `--isolate`. `--isolate` promotes every top-level call out of a test function
///         into its own transaction, which both clears the transient rotation credit between the two legs of the
///         same-transaction round trip and adds intrinsic gas to every measurement. The rest of the project's
///         `forge test --isolate` CI gate should therefore exclude `test/gas` and run it as a separate step:
///         `forge test --match-path 'test/gas/*'`.
contract GasBaselineTest is V4TestBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Three leading zero bytes, standing in for the CREATE2-mined production AMPS address. Makes AMPS
    ///      `currency0` in both pools, so `zeroForOne == true` is always "selling AMPS".
    address internal constant AMPS_ADDRESS = 0x0000001234567890123456789012345678901234;
    address internal constant USDG_ADDRESS = 0x1111111111111111111111111111111111111111;
    address internal constant STOCK_ADDRESS = 0x2222222222222222222222222222222222222222;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    int24 internal constant TICK_SPACING = 10;
    int24 internal constant TWO_SIDED_HALF_WIDTH = 5000;
    int24 internal constant ASK_LOWER_OFFSET = 1000;
    int24 internal constant ASK_UPPER_OFFSET = 20_000;

    uint24 internal constant EXPECTED_BUY_FEE_PIPS = 3000; // 30 bp
    uint24 internal constant EXPECTED_SELL_FEE_PIPS = 50_000; // 500 bp

    uint256 internal constant USDG_IN = 10_000e6; // $10k buy
    uint256 internal constant AMPS_IN = 10_000e18; // $10k sell
    uint256 internal constant STOCK_IN = 55e18; // ~$9.9k rotation

    string internal constant BASELINE_PATH = "./gas/baseline.json";
    string internal constant FOUNDRY_VERSION = "1.5.1";

    struct Measurements {
        uint256 beforeSwap;
        uint256 afterSwap;
        uint256 swapOneHopBuy;
        uint256 swapOneHopSell;
        uint256 swapTwoHopRotation;
        uint256 swapBuyThenSell;
    }

    MockERC20 internal amps;
    MockERC20 internal usdg;
    MockERC20 internal stock;
    StubAmpsHook internal hook;

    PoolKey internal usdgKey;
    PoolKey internal stockKey;

    function setUp() public {
        deployV4();

        amps = deployTokenAt(AMPS_ADDRESS, "Amplestocks", "AMPS", 18);
        usdg = deployTokenAt(USDG_ADDRESS, "Global Dollar", "USDG", 6);
        stock = deployTokenAt(STOCK_ADDRESS, "Mock Stock Token", "STOCK", 18);

        // The test contract is the "vault": it deploys the hook, initialises the pools and is the sole LP.
        bytes memory args = abi.encode(poolManager, Currency.wrap(AMPS_ADDRESS), address(this));
        (address mined, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(StubAmpsHook).creationCode, args);
        hook = new StubAmpsHook{salt: salt}(poolManager, Currency.wrap(AMPS_ADDRESS), address(this));
        require(address(hook) == mined, "hook address mismatch");
        vm.label(address(hook), "StubAmpsHook");

        usdgKey = _poolKey(USDG_ADDRESS);
        stockKey = _poolKey(STOCK_ADDRESS);

        // AMPS $1.00. USDG is 6-decimal $1.00, so raw amount1/amount0 = 1e6 / 1e18 = 1e-12.
        poolManager.initialize(usdgKey, _sqrtPriceX96(1e6, 1e18));
        // STOCK is 18-decimal $180, so raw amount1/amount0 = 1 / 180.
        poolManager.initialize(stockKey, _sqrtPriceX96(1, 180));

        _seedPool(usdgKey, 1_000_000e18, 1_000_000e6, 500_000e18);
        _seedPool(stockKey, 1_000_000e18, 6000e18, 500_000e18);
    }

    // ------------------------------------------------------------------ //
    //                              the test                              //
    // ------------------------------------------------------------------ //

    /// @notice The mined hook really carries `0x38C0` and neither `*_RETURNS_DELTA` bit, which is what makes the
    ///         numbers below a valid budget for the production hook.
    function test_minedHookAddressCarriesTheDesignFlags() public view {
        assertEq(uint160(address(hook)) & uint160(Hooks.ALL_HOOK_MASK), uint160(0x38C0), "flags must be 0x38C0");
        assertEq(uint160(address(hook)) & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG, 0, "no returns-delta bit");
        assertEq(uint160(address(hook)) & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG, 0, "no returns-delta bit");
        assertEq(uint160(address(hook)) & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG, 0, "no remove-liquidity bit");
    }

    function test_gasBaselines() public {
        _warmUp();

        Measurements memory m;
        uint24 loneSellFee;
        uint24 hop1Fee;
        uint24 hop2Fee;
        (m.beforeSwap, m.afterSwap) = _measureHookInIsolation();
        m.swapOneHopBuy = _measureOneHopBuy();
        (m.swapOneHopSell, loneSellFee) = _measureOneHopSell();
        (m.swapTwoHopRotation, hop1Fee, hop2Fee) = _measureTwoHopRotation();
        m.swapBuyThenSell = _measureBuyThenSell();

        // The rotation credit really is applied: hop 2 of STOCK -> AMPS -> USDG is charged the 30 bp buy fee, while
        // an identical stand-alone sell into the same pool is charged the full 500 bp sell fee.
        assertEq(hop1Fee, EXPECTED_BUY_FEE_PIPS, "hop 1 must be charged the buy fee");
        assertEq(hop2Fee, EXPECTED_BUY_FEE_PIPS, "hop 2 must be charged the credited (buy) fee");
        assertEq(loneSellFee, EXPECTED_SELL_FEE_PIPS, "a lone sell must be charged the full sell fee");

        (uint256 rotatedOut, uint256 uncreditedOut) = _rotationValueAdvantage();
        assertGt(rotatedOut, uncreditedOut, "rotation credit must improve the realised output");
        // (1 - 30bp) / (1 - 500bp) = 1.04947...; second-order price impact keeps it inside 1%.
        assertApproxEqRel((rotatedOut * 1e18) / uncreditedOut, 1.049473684210526315e18, 0.01e18, "hop 2 fee saving");

        _printTable(m, hop1Fee, hop2Fee, loneSellFee, rotatedOut, uncreditedOut);

        if (vm.envOr("WRITE_GAS_BASELINE", false)) {
            _writeBaseline(m);
        } else {
            _assertNoRegression(m);
        }
    }

    // ------------------------------------------------------------------ //
    //                           measurements                             //
    // ------------------------------------------------------------------ //

    /// @dev Marks the whole v4 stack, the hook and the tokens cold again, so each measurement below pays the
    ///      cold-access costs a real transaction pays. Transient storage is untouched.
    function _cool() private {
        vm.cool(address(poolManager));
        vm.cool(address(hook));
        vm.cool(address(swapRouter));
        vm.cool(address(permit2));
        vm.cool(address(amps));
        vm.cool(address(usdg));
        vm.cool(address(stock));
    }

    /// @dev One representative swap of each shape first, so that everything that a real transaction would find
    ///      already initialised on-chain (tick bitmaps, position slots, fee growth) is initialised here too.
    function _warmUp() private {
        hook.debugSetRotationCredit(0);
        _buyAmpsWithUsdg(USDG_IN / 10);
        hook.debugSetRotationCredit(0);
        _sellAmpsForUsdg(AMPS_IN / 10);
        hook.debugSetRotationCredit(0);
        _twoHopStockToUsdg(STOCK_IN / 10);
        hook.debugSetRotationCredit(0);
        _buyAmpsWithStock(STOCK_IN / 10);
        hook.debugSetRotationCredit(0);
    }

    /// @dev Calls the hook directly while impersonating the PoolManager. `beforeSwap` is measured on its most
    ///      expensive path (a credited exact-input sell: SLOAD + TLOAD + TSTORE + the blend), `afterSwap` on its
    ///      most expensive path (a buy: extsload + SLOAD + SSTORE + TLOAD + TSTORE).
    function _measureHookInIsolation() private returns (uint256 gasBeforeSwap, uint256 gasAfterSwap) {
        SwapParams memory sell = SwapParams({
            zeroForOne: true, amountSpecified: -int256(AMPS_IN), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        SwapParams memory buy = SwapParams({
            zeroForOne: false, amountSpecified: -int256(USDG_IN), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        // A realised buy delta: +AMPS to the swapper, -USDG from the swapper.
        BalanceDelta buyDelta = toBalanceDelta(int128(int256(AMPS_IN)), -int128(int256(USDG_IN)));

        // Warm the hook account and the pool's packed slot.
        hook.debugSetRotationCredit(AMPS_IN * 2);
        vm.prank(address(poolManager));
        hook.beforeSwap(address(swapRouter), usdgKey, sell, "");
        vm.prank(address(poolManager));
        hook.afterSwap(address(swapRouter), usdgKey, buy, buyDelta, "");

        hook.debugSetRotationCredit(AMPS_IN * 2);
        _cool();
        vm.prank(address(poolManager));
        uint256 start = gasleft();
        hook.beforeSwap(address(swapRouter), usdgKey, sell, "");
        gasBeforeSwap = start - gasleft();

        _cool();
        vm.prank(address(poolManager));
        start = gasleft();
        hook.afterSwap(address(swapRouter), usdgKey, buy, buyDelta, "");
        gasAfterSwap = start - gasleft();

        hook.debugSetRotationCredit(0);
    }

    function _measureOneHopBuy() private returns (uint256 gasUsed) {
        hook.debugSetRotationCredit(0);
        vm.recordLogs();
        _cool();
        (gasUsed,) = _buyAmpsWithUsdg(USDG_IN);
        assertEq(_swapFees(vm.getRecordedLogs())[0], EXPECTED_BUY_FEE_PIPS, "one-hop buy fee");
        hook.debugSetRotationCredit(0);
    }

    function _measureOneHopSell() private returns (uint256 gasUsed, uint24 fee) {
        hook.debugSetRotationCredit(0);
        vm.recordLogs();
        _cool();
        (gasUsed,) = _sellAmpsForUsdg(AMPS_IN);
        fee = _swapFees(vm.getRecordedLogs())[0];
    }

    function _measureTwoHopRotation() private returns (uint256 gasUsed, uint24 hop1Fee, uint24 hop2Fee) {
        hook.debugSetRotationCredit(0);
        vm.recordLogs();
        _cool();
        (gasUsed,) = _twoHopStockToUsdg(STOCK_IN);
        uint24[] memory fees = _swapFees(vm.getRecordedLogs());
        assertEq(fees.length, 2, "two-hop must emit two Swap events");
        (hop1Fee, hop2Fee) = (fees[0], fees[1]);
        assertEq(hook.rotationCredit(), 0, "hop 2 must consume the whole credit");
    }

    /// @dev A same-transaction buy-then-sell round trip: the sell is fully covered by the credit the buy created,
    ///      so it pays the buy fee, and the credit is left at zero. Nothing carries into the next transaction.
    function _measureBuyThenSell() private returns (uint256 gasUsed) {
        hook.debugSetRotationCredit(0);
        vm.recordLogs();
        _cool();

        uint256 start = gasleft();
        (, uint256 ampsOut) = _buyAmpsWithUsdg(USDG_IN);
        _sellAmpsForUsdg(ampsOut);
        gasUsed = start - gasleft();

        uint24[] memory fees = _swapFees(vm.getRecordedLogs());
        assertEq(fees.length, 2, "round trip must emit two Swap events");
        assertEq(fees[0], EXPECTED_BUY_FEE_PIPS, "buy leg fee");
        assertEq(fees[1], EXPECTED_BUY_FEE_PIPS, "credited sell leg fee");
        assertEq(hook.rotationCredit(), 0, "round trip must consume the whole credit");
        hook.debugSetRotationCredit(0);
    }

    /// @dev Runs the rotation and the equivalent uncredited exit from the *same* pool state, so the difference in
    ///      realised USDG is purely the fee the hook charged on hop 2.
    function _rotationValueAdvantage() private returns (uint256 rotatedOut, uint256 uncreditedOut) {
        uint256 snap = vm.snapshotState();
        hook.debugSetRotationCredit(0);
        (, rotatedOut) = _twoHopStockToUsdg(STOCK_IN);
        vm.revertToState(snap);

        snap = vm.snapshotState();
        hook.debugSetRotationCredit(0);
        (, uint256 ampsOut) = _buyAmpsWithStock(STOCK_IN);
        hook.debugSetRotationCredit(0); // drop the credit: this exit is a plain sell
        (, uncreditedOut) = _sellAmpsForUsdg(ampsOut);
        vm.revertToState(snap);

        hook.debugSetRotationCredit(0);
    }

    // ------------------------------------------------------------------ //
    //                           router calls                             //
    // ------------------------------------------------------------------ //

    /// @dev Single-hop exact-input buy: USDG (currency1) in, AMPS (currency0) out, so `zeroForOne == false`.
    function _buyAmpsWithUsdg(uint256 amountIn) private returns (uint256 gasUsed, uint256 amountOut) {
        uint256 balanceBefore = amps.balanceOf(address(this));
        uint256 deadline = block.timestamp + 1;
        uint256 start = gasleft();
        swapRouter.swapExactTokensForTokens(amountIn, 0, false, usdgKey, "", address(this), deadline);
        gasUsed = start - gasleft();
        amountOut = amps.balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Single-hop exact-input sell: AMPS (currency0) in, so `zeroForOne == true` and the sell fee applies.
    function _sellAmpsForUsdg(uint256 amountIn) private returns (uint256 gasUsed, uint256 amountOut) {
        uint256 balanceBefore = usdg.balanceOf(address(this));
        uint256 deadline = block.timestamp + 1;
        uint256 start = gasleft();
        swapRouter.swapExactTokensForTokens(amountIn, 0, true, usdgKey, "", address(this), deadline);
        gasUsed = start - gasleft();
        amountOut = usdg.balanceOf(address(this)) - balanceBefore;
    }

    function _buyAmpsWithStock(uint256 amountIn) private returns (uint256 gasUsed, uint256 amountOut) {
        uint256 balanceBefore = amps.balanceOf(address(this));
        uint256 deadline = block.timestamp + 1;
        uint256 start = gasleft();
        swapRouter.swapExactTokensForTokens(amountIn, 0, false, stockKey, "", address(this), deadline);
        gasUsed = start - gasleft();
        amountOut = amps.balanceOf(address(this)) - balanceBefore;
    }

    /// @notice The two-hop rotation STOCK -> AMPS -> USDG, as one exact-input `PathKey[]` router call.
    /// @dev    This is the shape the dApp builds and the shape the production hook tests should reuse. `PathKey`
    ///         describes the *output* of each hop, so `path[i].intermediateCurrency` is what that hop buys and the
    ///         router derives `zeroForOne` from the currency ordering. Hop 1 (STOCK in, AMPS out) is
    ///         `zeroForOne == false` (a buy, which credits the rotation slot in `afterSwap`); hop 2 (AMPS in, USDG
    ///         out) is `zeroForOne == true` (a sell, which spends that credit in `beforeSwap`). `fee` must be
    ///         `DYNAMIC_FEE_FLAG` and `hooks` the hook, or the reconstructed `PoolKey` is a different pool.
    function _twoHopStockToUsdg(uint256 amountIn) private returns (uint256 gasUsed, uint256 amountOut) {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(AMPS_ADDRESS),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(USDG_ADDRESS),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        uint256 balanceBefore = usdg.balanceOf(address(this));
        uint256 deadline = block.timestamp + 1;
        uint256 start = gasleft();
        swapRouter.swapExactTokensForTokens(amountIn, 0, Currency.wrap(STOCK_ADDRESS), path, address(this), deadline);
        gasUsed = start - gasleft();
        amountOut = usdg.balanceOf(address(this)) - balanceBefore;
    }

    // ------------------------------------------------------------------ //
    //                     baseline write / regression gate               //
    // ------------------------------------------------------------------ //

    function _writeBaseline(Measurements memory m) private {
        string memory obj = "amplestocks.gas.baseline";
        vm.serializeUint(obj, "beforeSwap", m.beforeSwap);
        vm.serializeUint(obj, "afterSwap", m.afterSwap);
        vm.serializeUint(obj, "swapOneHopBuy", m.swapOneHopBuy);
        vm.serializeUint(obj, "swapOneHopSell", m.swapOneHopSell);
        vm.serializeUint(obj, "swapTwoHopRotation", m.swapTwoHopRotation);
        vm.serializeUint(obj, "swapBuyThenSell", m.swapBuyThenSell);
        vm.serializeString(obj, "foundry", FOUNDRY_VERSION);
        vm.serializeString(obj, "solc", "0.8.30");
        vm.serializeString(obj, "evm", "cancun");
        vm.serializeString(obj, "source", "test/gas/GasBaseline.t.sol (StubAmpsHook, flags 0x38C0)");
        vm.serializeString(obj, "warmth", "cold: vm.cool on the v4 stack, hook and tokens before each measurement");
        string memory json = vm.serializeString(obj, "date", _isoDate(vm.unixTime() / 1000));
        vm.writeJson(json, BASELINE_PATH);
        console.log("wrote %s", BASELINE_PATH);
    }

    function _assertNoRegression(Measurements memory m) private view {
        if (!vm.exists(BASELINE_PATH)) {
            console.log("SKIP: %s not found; run with WRITE_GAS_BASELINE=true to create it", BASELINE_PATH);
            return;
        }
        string memory json = vm.readFile(BASELINE_PATH);
        string[6] memory keys =
            ["beforeSwap", "afterSwap", "swapOneHopBuy", "swapOneHopSell", "swapTwoHopRotation", "swapBuyThenSell"];
        uint256[6] memory measured =
            [m.beforeSwap, m.afterSwap, m.swapOneHopBuy, m.swapOneHopSell, m.swapTwoHopRotation, m.swapBuyThenSell];
        for (uint256 i; i < keys.length; ++i) {
            string memory path = string.concat(".", keys[i]);
            if (!vm.keyExistsJson(json, path)) {
                console.log("SKIP: baseline has no key %s", keys[i]);
                continue;
            }
            uint256 budget = (vm.parseJsonUint(json, path) * 12) / 10;
            assertLe(measured[i], budget, string.concat("gas regression: ", keys[i]));
        }
    }

    function _printTable(
        Measurements memory m,
        uint24 hop1Fee,
        uint24 hop2Fee,
        uint24 loneSellFee,
        uint256 rotatedOut,
        uint256 uncreditedOut
    ) private pure {
        console.log("+--------------------------------------------------+---------+");
        console.log("| measurement                                      |     gas |");
        console.log("+--------------------------------------------------+---------+");
        console.log(_row("beforeSwap  (credited exact-in sell)", m.beforeSwap));
        console.log(_row("afterSwap   (buy, credits rotation slot)", m.afterSwap));
        console.log(_row("swapOneHopBuy       USDG -> AMPS", m.swapOneHopBuy));
        console.log(_row("swapOneHopSell      AMPS -> USDG", m.swapOneHopSell));
        console.log(_row("swapTwoHopRotation  STOCK -> AMPS -> USDG", m.swapTwoHopRotation));
        console.log(_row("swapBuyThenSell     same-tx round trip", m.swapBuyThenSell));
        console.log("+--------------------------------------------------+---------+");
        console.log(_row("fee charged on rotation hop 1 (pips)", hop1Fee));
        console.log(_row("fee charged on rotation hop 2 (pips)", hop2Fee));
        console.log(_row("fee charged on a lone sell    (pips)", loneSellFee));
        console.log(_row("USDG out, rotated exit", rotatedOut));
        console.log(_row("USDG out, uncredited exit", uncreditedOut));
    }

    function _row(string memory label, uint256 value) private pure returns (string memory) {
        return string.concat("| ", _pad(label, 48), " | ", _padLeft(vm.toString(value), 7), " |");
    }

    function _pad(string memory s, uint256 width) private pure returns (string memory out) {
        out = s;
        for (uint256 i = bytes(s).length; i < width; ++i) {
            out = string.concat(out, " ");
        }
    }

    function _padLeft(string memory s, uint256 width) private pure returns (string memory out) {
        out = s;
        for (uint256 i = bytes(s).length; i < width; ++i) {
            out = string.concat(" ", out);
        }
    }

    // ------------------------------------------------------------------ //
    //                              plumbing                              //
    // ------------------------------------------------------------------ //

    function _poolKey(address counterparty) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(AMPS_ADDRESS),
            currency1: Currency.wrap(counterparty),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev `sqrtPriceX96 = sqrt(num / den) * 2**96`, with `num / den` the raw (decimal-inclusive) amount1 per
    ///      amount0. Computed locally so the price constants in this file stay readable.
    function _sqrtPriceX96(uint256 num, uint256 den) private pure returns (uint160) {
        uint256 ratioX96 = FullMath.mulDiv(num, 1 << 96, den);
        return uint160(FixedPointMathLib.sqrt(ratioX96 << 96));
    }

    /// @dev Two-sided liquidity around the current tick plus a one-sided AMPS ask above it, both added by the
    ///      "vault" (this contract) through a bare `unlock` callback, which is the cheapest path that still runs
    ///      the hook's `beforeAddLiquidity` guard.
    function _seedPool(PoolKey memory key, uint256 amount0, uint256 amount1, uint256 askAmount0) private {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());

        int24 lower = _align(tick - TWO_SIDED_HALF_WIDTH);
        int24 upper = _align(tick + TWO_SIDED_HALF_WIDTH);
        _addLiquidity(
            key,
            lower,
            upper,
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
            )
        );

        int24 askLower = _align(tick + ASK_LOWER_OFFSET);
        int24 askUpper = _align(tick + ASK_UPPER_OFFSET);
        _addLiquidity(
            key,
            askLower,
            askUpper,
            LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(askLower), TickMath.getSqrtPriceAtTick(askUpper), askAmount0
            )
        );
    }

    function _addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) private {
        poolManager.unlock(abi.encode(key, tickLower, tickUpper, int256(uint256(liquidity))));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
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

    /// @dev Every `IPoolManager.Swap` fee field in the recorded logs, in emission order (one per hop).
    function _swapFees(Vm.Log[] memory logs) private pure returns (uint24[] memory fees) {
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

    function _align(int24 tick) private pure returns (int24 aligned) {
        aligned = (tick / TICK_SPACING) * TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) aligned -= TICK_SPACING;
    }

    /// @dev Days-to-civil-date (Howard Hinnant's algorithm), so `baseline.json` carries a readable ISO date
    ///      without `ffi`, which the project keeps disabled.
    function _isoDate(uint256 unixSeconds) private pure returns (string memory) {
        uint256 z = unixSeconds / 86_400 + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 year = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 day = doy - (153 * mp + 2) / 5 + 1;
        uint256 month = mp < 10 ? mp + 3 : mp - 9;
        if (month <= 2) ++year;
        return string.concat(vm.toString(year), "-", _twoDigits(month), "-", _twoDigits(day));
    }

    function _twoDigits(uint256 value) private pure returns (string memory) {
        return value < 10 ? string.concat("0", vm.toString(value)) : vm.toString(value);
    }
}
