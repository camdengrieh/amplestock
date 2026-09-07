// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsHook} from "../../src/interfaces/IAmpsHook.sol";
import {IFeePolicy} from "../../src/interfaces/IFeePolicy.sol";
import {FeePolicy} from "../../src/policy/FeePolicy.sol";
import {Constants} from "../../src/types/Constants.sol";
import {BeyondRail} from "../../src/types/Errors.sol";
import {GateState, PoolClass, Session} from "../../src/types/Types.sol";
import {HookTestFixture} from "../mocks/HookTestFixture.sol";
import {MockOracleGate} from "../mocks/MockOracleGate.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title AmpsHookFeeTest
/// @notice The fee the hook returns: the base table by direction and class, the dynamic components through the
///         policy pointer, the floor, the cap, the frozen floor, the override flag, and the I16 decomposition.
contract AmpsHookFeeTest is HookTestFixture {
    function setUp() public {
        _deployFixture();
    }

    // -----------------------------------------------------------------------------------------------------------
    // The base table (§1.4 step 3)
    // -----------------------------------------------------------------------------------------------------------

    function test_baseFeeTableByDirectionAndClass() public view {
        // Entry pools: 30 bp to buy, 500 bp to sell.
        (uint24 pips, uint16 base, uint16 dyn,) = hook.quoteFee(usdgId, false, true, 1e18);
        assertEq(base, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, "entry buy base");
        assertEq(dyn, 0, "no dynamic component at zero deviation");
        assertEq(pips, uint24(Constants.BUY_FEE_BPS_ENTRY_DEFAULT) * Constants.PIPS_PER_BPS, "entry buy pips");

        (pips, base,,) = hook.quoteFee(usdgId, true, true, 1e18);
        assertEq(base, Constants.SELL_FEE_BPS_DEFAULT, "entry sell base");
        assertEq(pips, uint24(Constants.SELL_FEE_BPS_DEFAULT) * Constants.PIPS_PER_BPS, "entry sell pips");

        (, base,,) = hook.quoteFee(wethId, false, true, 1e18);
        assertEq(base, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, "the WETH route is an entry pool too");

        // Spokes: 5 bp to buy (10 bp for a high-volatility name), 500 bp to sell.
        (, base,,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(base, Constants.BUY_FEE_BPS_SPOKE_DEFAULT, "spoke buy base");

        (, base,,) = hook.quoteFee(stockId, true, true, 1e18);
        assertEq(base, Constants.SELL_FEE_BPS_DEFAULT, "the sell fee is protocol-wide");
    }

    function test_theHighVolatilitySpokeBucketIsTenBasisPoints() public {
        vm.prank(TIMELOCK);
        hook.setBuyFeeBps(stockId, Constants.BUY_FEE_BPS_SPOKE_HIGH_VOL_DEFAULT);
        (, uint16 base,,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(base, 10, "SPOKE_HIGH_VOL");
    }

    function test_theGovernedSellFeeMovesEveryPool() public {
        vm.prank(TIMELOCK);
        hook.setSellFeeBps(100);
        (, uint16 base,,) = hook.quoteFee(stockId, true, true, 1e18);
        assertEq(base, 100, "floor of the band");

        vm.prank(TIMELOCK);
        hook.setSellFeeBps(600);
        (, base,,) = hook.quoteFee(usdgId, true, true, 1e18);
        assertEq(base, 600, "ceiling of the band");
    }

    /// @notice What the pool actually charges, read off the `Swap` event rather than the hook's own view.
    function test_theRealisedFeeMatchesTheQuote() public {
        vm.recordLogs();
        _buy(usdgKey, 1000e6);
        assertEq(
            _lastSwapFee(vm.getRecordedLogs()),
            uint24(Constants.BUY_FEE_BPS_ENTRY_DEFAULT) * Constants.PIPS_PER_BPS,
            "a buy pays 30 bp"
        );

        vm.recordLogs();
        _sell(usdgKey, 100e18);
        assertEq(
            _lastSwapFee(vm.getRecordedLogs()),
            uint24(Constants.SELL_FEE_BPS_DEFAULT) * Constants.PIPS_PER_BPS,
            "a lone sell pays 500 bp"
        );
    }

    // -----------------------------------------------------------------------------------------------------------
    // The override flag and the zero delta (I13)
    // -----------------------------------------------------------------------------------------------------------

    function test_beforeSwapReturnsTheOverrideFlagAndAZeroDelta() public {
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -1e6, sqrtPriceLimitX96: 0});

        vm.prank(address(poolManager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(address(this), usdgKey, params, "");

        assertEq(selector, IHooks.beforeSwap.selector, "selector");
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA), "delta");
        assertTrue(fee & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "the override flag is set");
        assertEq(fee & LPFeeLibrary.REMOVE_OVERRIDE_MASK, 3000, "30 bp in pips under the flag");
        assertLe(fee & LPFeeLibrary.REMOVE_OVERRIDE_MASK, Constants.MAX_LP_FEE, "never above MAX_LP_FEE");
    }

    // -----------------------------------------------------------------------------------------------------------
    // f_min (§1.4 step 6)
    // -----------------------------------------------------------------------------------------------------------

    function test_theFeeFloorIsThreeBasisPoints() public {
        vm.prank(TIMELOCK);
        hook.setBuyFeeBps(stockId, Constants.BUY_FEE_BPS_SPOKE_MIN);
        policy.setDynOverride(0);

        (uint24 pips, uint16 base, uint16 dyn,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(base, 1, "the base really is 1 bp");
        assertEq(dyn, 0, "and nothing dynamic");
        assertEq(pips, uint24(Constants.F_MIN_BPS) * Constants.PIPS_PER_BPS, "clamped up to f_min");
    }

    // -----------------------------------------------------------------------------------------------------------
    // dynCap by gate state, and the frozen floor
    // -----------------------------------------------------------------------------------------------------------

    function test_theDynamicCapFollowsTheGateState() public {
        policy.setDynOverride(type(uint16).max - 1); // the law would return an absurd number

        _setGateDynCap(stockId, GateState.GREEN, Constants.DYN_CAP_NORMAL_BPS);
        (, uint16 base, uint16 dyn,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(dyn, Constants.DYN_CAP_NORMAL_BPS, "NORMAL caps at 300 bp");
        assertEq(base, Constants.BUY_FEE_BPS_SPOKE_DEFAULT, "the base is untouched by the cap");

        _setGateDynCap(stockId, GateState.DEGRADED, Constants.DYN_CAP_DEGRADED_BPS);
        (,, dyn,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(dyn, Constants.DYN_CAP_DEGRADED_BPS, "DEGRADED caps at 1,000 bp");

        _setGateDynCap(stockId, GateState.DIVERGED, Constants.DYN_CAP_ESCALATION_BPS);
        (,, dyn,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(dyn, Constants.DYN_CAP_ESCALATION_BPS, "band escalation caps at 2,000 bp");
    }

    /// @notice A degraded gate raises the floor of the dynamic part instead of refusing the swap (I15).
    function test_aDegradedGateFloorsTheDynamicPartAndNeverRefuses() public {
        policy.setDynOverride(0);

        _setGateDynCap(stockId, GateState.GREEN, Constants.DYN_CAP_NORMAL_BPS);
        (,, uint16 dyn, bool refuse) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(dyn, 0, "green: nothing");
        assertFalse(refuse, "green: not refused");

        _setGateDynCap(stockId, GateState.WATCHDOG, Constants.DYN_CAP_DEGRADED_BPS);
        (,, dyn, refuse) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(dyn, Constants.FROZEN_FEE_FLOOR_BPS, "degraded: the 100 bp frozen floor");
        assertFalse(refuse, "a gate reason is never a refusal");

        // And a real swap still goes through in that state.
        vm.recordLogs();
        _buy(stockKey, 1e18);
        assertEq(
            _lastSwapFee(vm.getRecordedLogs()),
            uint24(Constants.BUY_FEE_BPS_SPOKE_DEFAULT + Constants.FROZEN_FEE_FLOOR_BPS) * Constants.PIPS_PER_BPS,
            "base + frozen floor"
        );
    }

    /// @notice Past `GATE_CACHE_MAX_AGE` the cached view is not trusted: widest band, degraded cap, frozen floor.
    function test_aStaleGateCacheSubstitutesTheMostConservativeValues() public {
        policy.setDynOverride(0);
        vm.warp(block.timestamp + Constants.GATE_CACHE_MAX_AGE + 1);

        (,, uint16 dyn,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(dyn, Constants.FROZEN_FEE_FLOOR_BPS, "the frozen floor applies while the cache is stale");
        assertEq(hook.innerBandTicks(stockId), Constants.INNER_BAND_MAX_TICKS, "widest band for the class");
        assertEq(hook.outerRailTicks(stockId), Constants.INNER_BAND_MAX_TICKS * 3, "and the rail that follows");

        policy.setDynOverride(type(uint16).max - 1);
        (,, dyn,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(dyn, Constants.DYN_CAP_DEGRADED_BPS, "and the degraded cap");
    }

    // -----------------------------------------------------------------------------------------------------------
    // f_dev, the band and the rail (§1.4 steps 4 and 5)
    // -----------------------------------------------------------------------------------------------------------

    function test_priceImprovingSwapsPayNoDeviationComponent() public {
        // Put the pool 150 ticks above fair. A sell pushes the tick down, so a sell is price-improving.
        _setFairTick(stockId, _currentTick(stockId) - 150);

        (,, uint16 dynSell,) = hook.quoteFee(stockId, true, true, 1e18);
        assertEq(dynSell, 0, "a deviation-reducing swap pays no f_dev");

        (,, uint16 dynBuy,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(dynBuy, (uint256(Constants.K_DEV_BPS) * 150 * 150) / Constants.BPS, "k_dev * dev^2 / 1e4");
        assertGt(dynBuy, 0, "the deviation-increasing direction pays");
    }

    function test_theDeviationComponentIsQuadraticInsideTheBand() public {
        int24 tick = _currentTick(stockId);
        _setFairTick(stockId, tick - 100);
        (,, uint16 atOneHundred,) = hook.quoteFee(stockId, false, true, 1e18);

        _setFairTick(stockId, tick - 200);
        (,, uint16 atTwoHundred,) = hook.quoteFee(stockId, false, true, 1e18);

        assertEq(atOneHundred, 25, "25 * 100^2 / 1e4");
        assertEq(atTwoHundred, 100, "25 * 200^2 / 1e4 - four times the fee for twice the deviation");
    }

    /// @notice The start-of-swap rail: only the deviation-increasing direction is refused (§10 ruling 2, I15).
    function test_theRailRefusesOnlyTheDeviationIncreasingDirection() public {
        int24 tick = _currentTick(stockId);
        _setFairTick(stockId, tick - 900); // 900 > the 800-tick spoke rail

        (,,, bool refuseBuy) = hook.quoteFee(stockId, false, true, 1e18);
        assertTrue(refuseBuy, "a buy would push it further out");

        (,,, bool refuseSell) = hook.quoteFee(stockId, true, true, 1e18);
        assertFalse(refuseSell, "a sell brings it back and is always allowed");

        vm.expectRevert(
            _wrapped(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BeyondRail.selector, PoolId.unwrap(stockId), int24(900), int24(800))
            )
        );
        _buyRaw(stockKey, 1e18);

        // The other direction really does execute.
        uint256 out = _sell(stockKey, 1e18);
        assertGt(out, 0, "the price-improving side is never refused");
    }

    // -----------------------------------------------------------------------------------------------------------
    // f_session, surge and the dividend capture
    // -----------------------------------------------------------------------------------------------------------

    function test_theSessionComponentIsStockLegsOnly() public {
        gate.setSession(Session.OVERNIGHT);
        _refreshGate(stockKey);
        _refreshGate(usdgKey);

        (,, uint16 spokeDyn,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(spokeDyn, Constants.F_SESSION_OVERNIGHT_BPS, "10 bp overnight on a spoke");

        (,, uint16 entryDyn,) = hook.quoteFee(usdgId, false, true, 1e18);
        assertEq(entryDyn, 0, "entry pools pass Session.REGULAR unconditionally");
        assertEq(uint8(hook.poolState(usdgId).session), uint8(Session.OVERNIGHT), "even though the cache knows");
    }

    function test_aSurgeDecaysOnItsHalfLife() public {
        hook.armSurge(stockId, Constants.SURGE_MAX_BPS, "placement");

        (,, uint16 atZero,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(atZero, Constants.DYN_CAP_NORMAL_BPS, "500 bp armed, capped at the 300 bp NORMAL cap");

        vm.warp(block.timestamp + Constants.SURGE_HALF_LIFE);
        (,, uint16 atOneHalfLife,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(atOneHalfLife, 250, "half of it");

        vm.warp(block.timestamp + Constants.SURGE_HALF_LIFE * 8);
        (,, uint16 atTheHorizon,) = hook.quoteFee(stockId, false, true, 1e18);
        assertEq(atTheHorizon, 0, "gone at eight half-lives");
    }

    /// @notice The capture fee is asymmetric: it applies only to the direction that takes stock out of the pool.
    function test_theDividendCaptureFeeIsDirectional() public {
        stock.setUIMultiplier(1.005e18); // a 50 bp dividend reinvestment
        _refreshGate(stockKey);
        assertEq(hook.poolState(stockId).captureFeeBps, 40, "0.8 x 50 bp");
        assertEq(hook.poolState(stockId).surgeBps, Constants.SURGE_MAX_BPS, "a step also arms a surge");
        _quiet(stockId);

        (,, uint16 dynSell,) = hook.quoteFee(stockId, true, true, 1e18);
        (,, uint16 dynBuy,) = hook.quoteFee(stockId, false, true, 1e18);
        assertGt(dynSell, dynBuy, "the sell takes stock out, so it pays the capture");

        assertEq(dynSell - dynBuy, 40, "exactly the capture fee, and only on the stock-out direction");
        assertEq(dynBuy, 0, "the other direction pays nothing for it");
    }

    function test_theCaptureFeeDoesNotApplyToEntryPools() public {
        // The entry pools have no `uiMultiplier()` to step, and their counter is not a stock.
        assertEq(hook.poolState(usdgId).captureFeeBps, 0, "never armed");
        (,, uint16 dyn,) = hook.quoteFee(usdgId, true, true, 1e18);
        assertEq(dyn, 0, "and nothing to pay");
    }

    // -----------------------------------------------------------------------------------------------------------
    // f_vol
    // -----------------------------------------------------------------------------------------------------------

    /// @notice `f_vol` against the **real** `FeePolicy`, at the calibration points §12.1 ruling H fixes:
    ///         `f_vol_bps = K_VOL_X18 x varianceX18 / 1e36` is a basis point at a per-swap sigma of ~14 ticks and
    ///         the 100 bp cap at ~141 ticks.
    /// @dev The hook stores the EWMA as X12 in its 64-bit packed field and multiplies by 1e6 on the way into
    ///      `FeeInput`, because `141^2 x 1e18` ~ 2e22 does not fit 64 bits. This test asserts the law; the one
    ///      below asserts that what the hook hands the policy really is that number.
    function test_theVolatilityLawIsCalibratedAtItsStatedPoints() public {
        FeePolicy real = _realPolicy();

        assertEq(_fVolAtSigma(real, 14), 0, "sigma 14 is 0.98 bp, which truncates to nothing");
        assertEq(_fVolAtSigma(real, 15), 1, "one basis point from sigma 15");
        assertEq(_fVolAtSigma(real, 100), 50, "5e15 * 100^2 * 1e18 / 1e36");
        assertEq(_fVolAtSigma(real, 141), 99, "just under the cap at sigma 141");
        assertEq(_fVolAtSigma(real, 142), Constants.F_VOL_CAP_BPS, "the 100 bp cap at sigma 142");
        assertEq(_fVolAtSigma(real, 1000), Constants.F_VOL_CAP_BPS, "and it stays capped");
        assertEq(_fVol(real, type(uint128).max), Constants.F_VOL_CAP_BPS, "no overflow at the field's ceiling");
    }

    /// @notice What the hook hands the policy is the X18 EWMA the policy is calibrated against: a real swap
    ///         history produces a `f_vol` that is exactly the law applied to the hook's own stored variance.
    function test_theStoredVarianceDrivesTheChargedFee() public {
        FeePolicy real = _realPolicy();

        // Alternating buys and sells, each moving the tick by tens of ticks, so the EWMA converges on a realistic
        // per-swap variance rather than on a single outlier.
        for (uint256 i; i < 40; ++i) {
            if (i % 2 == 0) _buy(usdgKey, 6000e6);
            else _sell(usdgKey, 6000e18);
        }

        uint256 storedX12 = hook.poolState(usdgId).varianceX18;
        uint256 varianceX18 = storedX12 * 1e6;
        uint256 expected = (Constants.K_VOL_X18 * varianceX18) / 1e36;
        if (expected > Constants.F_VOL_CAP_BPS) expected = Constants.F_VOL_CAP_BPS;
        // The fixture's pool turns a 6,000 USDG swap into a ~55-tick move, so forty of them settle the EWMA at
        // ~3,000 ticks^2 and `f_vol` at ~15 bp: inside the band the law is meant to work in, neither zero nor
        // pinned to the cap.
        assertGt(expected, 0, "a realistic history moves f_vol off zero");
        assertLt(expected, Constants.F_VOL_CAP_BPS, "and does not simply pin it to the cap");
        assertEq(_fVol(real, uint128(varianceX18)), expected, "the policy agrees with the law");

        // Quote the deviation-*reducing* direction, so `f_dev` is out of the way and the dynamic part is f_vol
        // alone (the pool is an entry pool, so `f_session` is zero and there is no capture fee).
        bool sellReducesDeviation = hook.poolState(usdgId).lastTick > hook.fairTick(usdgId);
        (,, uint16 dyn,) = hook.quoteFee(usdgId, sellReducesDeviation, true, 1e18);
        assertEq(dyn, expected, "the charged dynamic component is exactly f_vol");
        assertEq(dyn, hook.poolState(usdgId).fVolBps, "and the cached fallback agrees with it");
    }

    /// @notice The EWMA saturates instead of overflowing, and a saturated pool pays the cap and not a revert.
    function test_theEwmaSaturatesRatherThanOverflowing() public {
        // The rail is not what is under test here, and these swaps drain the pool's whole range. `MAX_TICK` is
        // the one rail a deviation can never exceed: `_deviation` saturates there.
        policy.setRailOverride(TickMath.MAX_TICK);
        _refreshGate(usdgKey);

        for (uint256 i; i < 4; ++i) {
            if (i % 2 == 0) _sell(usdgKey, 5_000_000e18);
            else _buy(usdgKey, 5_000_000e6);
        }

        assertEq(hook.poolState(usdgId).varianceX18, type(uint64).max, "saturated, not wrapped");
        assertEq(hook.poolState(usdgId).fVolBps, Constants.F_VOL_CAP_BPS, "and the cached f_vol is the cap");

        // Saturated, the X18 value the policy sees is 1.8446e25 - three orders of magnitude past the cap - and
        // the fee is still the cap rather than a revert.
        uint256 varianceX18 = uint256(hook.poolState(usdgId).varianceX18) * 1e6;
        assertEq(_fVol(_realPolicy(), uint128(varianceX18)), Constants.F_VOL_CAP_BPS, "capped");
        (uint24 pips,,,) = hook.quoteFee(usdgId, true, true, 1e18);
        assertGt(pips, 0, "and quoting still answers");
    }

    /// @dev The production policy, constructed from the launch coefficients and pointed at by the hook.
    function _realPolicy() private returns (FeePolicy real) {
        real = new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18);
        vm.prank(TIMELOCK);
        hook.setFeePolicy(address(real));
    }

    /// @dev `f_vol` for a per-swap sigma in ticks: `varianceX18 = sigma^2 * 1e18`.
    function _fVolAtSigma(FeePolicy real, uint256 sigmaTicks) private view returns (uint16 bps) {
        bps = _fVol(real, uint128(sigmaTicks * sigmaTicks * 1e18));
    }

    /// @dev The policy's dynamic component with every other term zeroed, so it is `f_vol` alone.
    function _fVol(FeePolicy real, uint128 varianceX18) private view returns (uint16 bps) {
        IFeePolicy.FeeInput memory input = IFeePolicy.FeeInput({
            zeroForOne: false,
            exactInput: true,
            deviationIncreasing: false,
            amountIn: 1e18,
            rotationCredit: 0,
            poolClass: PoolClass.ENTRY,
            sellFeeBps: Constants.SELL_FEE_BPS_DEFAULT,
            buyFeeBps: Constants.BUY_FEE_BPS_ENTRY_DEFAULT,
            devTicks: 0,
            innerBandTicks: Constants.INNER_BAND_REGULAR_TICKS,
            outerRailTicks: Constants.OUTER_RAIL_ENTRY_TICKS,
            varianceX18: varianceX18,
            surgeBps: 0,
            surgeElapsed: 0,
            captureFeeBps: 0,
            captureElapsed: 0,
            captureDirectionTakesStock: false,
            session: Session.REGULAR,
            gate: GateState.GREEN,
            dynCapBps: Constants.DYN_CAP_ESCALATION_BPS
        });
        bps = real.quoteFee(input).dynBps;
    }

    // -----------------------------------------------------------------------------------------------------------
    // The quoter's contract with the hook
    // -----------------------------------------------------------------------------------------------------------

    /// @notice What `AmpsQuoter` is entitled to assume about {IAmpsHook.quoteFee}.
    /// @dev The second parameter is `zeroForOne`, and `zeroForOne == true` is a **sell** (AMPS is `currency0` in
    ///      all 32 pools). It is not "isBuy".
    function test_theQuoteFeeContract() public {
        // 1. `amountIn == 0` gives the un-blended base, in both directions.
        (uint24 pips, uint16 base, uint16 dyn, bool refuse) = hook.quoteFee(usdgId, true, true, 0);
        assertEq(base, hook.sellFeeBps(), "a sell quotes sellFeeBps");
        (, base,,) = hook.quoteFee(usdgId, false, true, 0);
        assertEq(base, hook.buyFeeBps(usdgId), "a buy quotes the pool's buyFeeBps");

        // 2. `feePips` carries no override flag and is the clamped sum, in pips.
        (pips, base, dyn, refuse) = hook.quoteFee(usdgId, true, true, 1e18);
        assertEq(pips & LPFeeLibrary.OVERRIDE_FEE_FLAG, 0, "no override flag on the view");
        uint256 expected = uint256(base) + uint256(dyn);
        if (expected < Constants.F_MIN_BPS) expected = Constants.F_MIN_BPS;
        assertEq(pips, uint24(expected) * Constants.PIPS_PER_BPS, "clamp(base + dyn) in pips");
        assertLe(dyn, hook.poolState(usdgId).dynCapBps, "dyn is already clamped to the cap");
        assertFalse(refuse, "and nothing is refused inside the rail");

        // 3. An unknown pool answers rather than reverting.
        (pips, base, dyn, refuse) = hook.quoteFee(PoolId.wrap(keccak256("nothing")), true, true, 1e18);
        assertEq(pips, 0, "no fee");
        assertTrue(refuse, "and a swap through it would indeed be refused");

        // 4. The mirrored registry fields the quoter reads out of `poolState`.
        assertEq(hook.poolState(stockId).tickSpacing, registry.poolConfig(stockId).tickSpacing, "tickSpacing");
        assertEq(hook.poolState(stockId).counterDecimals, registry.poolConfig(stockId).counterDecimals, "decimals");
        assertEq(uint8(hook.poolState(stockId).poolClass), uint8(registry.poolConfig(stockId).poolClass), "class");
        assertEq(hook.poolState(stockId).buyFeeBps, registry.poolConfig(stockId).buyFeeBps, "buyFeeBps");
    }

    // -----------------------------------------------------------------------------------------------------------
    // I16
    // -----------------------------------------------------------------------------------------------------------

    /// @notice I16: the returned fee is `base + dyn`, with `base` one of the three legal values, `dyn` inside the
    ///         state's cap, and the total below `MAX_LP_FEE`.
    function testFuzz_everyQuoteDecomposesAsBasePlusDyn(
        bool sell,
        bool exactInput,
        uint96 amountIn,
        uint16 dynFromPolicy,
        uint8 gateStateRaw,
        int16 fairOffset
    ) public {
        GateState gateState = GateState(gateStateRaw % 6);
        uint16 cap = gateState == GateState.GREEN
            ? Constants.DYN_CAP_NORMAL_BPS
            : (gateStateRaw % 2 == 0 ? Constants.DYN_CAP_DEGRADED_BPS : Constants.DYN_CAP_ESCALATION_BPS);

        policy.setDynOverride(dynFromPolicy);
        _setGateFairAndCap(stockId, gateState, cap, _currentTick(stockId) + int24(fairOffset));

        (uint24 pips, uint16 base, uint16 dyn,) = hook.quoteFee(stockId, sell, exactInput, amountIn);

        uint16 sellFee = hook.sellFeeBps();
        assertGe(sellFee, Constants.SELL_FEE_BPS_MIN, "sellFeeBps floor");
        assertLe(sellFee, Constants.SELL_FEE_BPS_MAX, "sellFeeBps ceiling");

        if (sell) {
            // Either the full sell fee or a blend between the buy fee and it; with no credit in a fresh
            // transaction it is always the full sell fee.
            assertEq(base, sellFee, "an uncredited sell pays the sell fee in full");
        } else {
            assertEq(base, hook.buyFeeBps(stockId), "a buy pays the pool's buy fee");
        }

        assertLe(dyn, cap, "dyn <= dynCap_state");
        uint256 expected = uint256(base) + uint256(dyn);
        if (expected < Constants.F_MIN_BPS) expected = Constants.F_MIN_BPS;
        assertEq(pips, uint24(expected) * Constants.PIPS_PER_BPS, "fee == clamp(base + dyn)");
        assertLe(expected, Constants.TOTAL_FEE_BPS_MAX, "and below the protocol ceiling");
        assertLe(pips, Constants.MAX_LP_FEE, "and far below MAX_LP_FEE");
    }

    // -----------------------------------------------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------------------------------------------

    function _setGateDynCap(PoolId poolId, GateState state, uint16 cap) private {
        _setGateFairAndCap(poolId, state, cap, 0);
    }

    function _setFairTick(PoolId poolId, int24 tick) private {
        _setGateFairAndCap(poolId, GateState.GREEN, Constants.DYN_CAP_NORMAL_BPS, tick);
    }

    function _setGateFairAndCap(PoolId poolId, GateState state, uint16 cap, int24 fair) private {
        gate.setPoolState(
            poolId,
            MockOracleGate.PoolState({
                set: true, state: state, diverged: false, dynCapBps: cap, poolTick: 0, fairTick: fair
            })
        );
        bytes32 raw = PoolId.unwrap(poolId);
        if (raw == PoolId.unwrap(stockId)) _refreshGate(stockKey);
        else if (raw == PoolId.unwrap(usdgId)) _refreshGate(usdgKey);
        else _refreshGate(wethKey);
        // A fair-tick jump legitimately arms a surge (§1.6); disarm it so the component under test is visible.
        _quiet(poolId);
    }

    /// @dev Clears whatever surge the last refresh armed. Vault-only, and the fixture is the vault.
    function _quiet(PoolId poolId) private {
        hook.armSurge(poolId, 0, "test");
    }
}
