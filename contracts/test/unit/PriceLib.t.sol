// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PriceLib} from "../../src/lib/PriceLib.sol";
import {PriceLibHarness} from "../utils/LibHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Concrete vectors, rounding-direction assertions and every revert path of `PriceLib`.
/// @dev AMPS is currency0 everywhere, so a pool price is always counter-asset raw units per AMPS raw unit and the
///      expected sqrt prices below are tiny (6-decimal counters) or fractional (expensive stocks).
contract PriceLibTest is Test {
    PriceLibHarness internal price;

    uint8 internal constant DEC6 = 6;
    uint8 internal constant DEC18 = 18;

    function setUp() public {
        price = new PriceLibHarness();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Concrete vectors
    // -------------------------------------------------------------------------------------------------------------

    /// @dev AMPS $1.00 against USDG ($1.00, 6 decimals): raw price is 1e6 / 1e18 = 1e-12, so the exact sqrt price is
    ///      2**96 * 1e-6 = 79228162514264337593543.950336 and the protocol-favourable (ceiling) answer is ...544.
    function test_vector_ampsOneVsUsdgOne() public view {
        uint160 sqrtPriceX96 = price.ampsPerCounterToSqrtPriceX96(1e18, 1e8, DEC6);
        assertEq(uint256(sqrtPriceX96), 79_228_162_514_264_337_593_544, "AMPS $1 / USDG $1");
        _assertCeilOfExact(sqrtPriceX96, 1e18, 1e8, DEC6);
        _assertRoundTrip(sqrtPriceX96, 1e18, 1e8, DEC6);
    }

    /// @dev AMPS $1.00 against NVDA ($180.00, 18 decimals): raw price is 1/180.
    function test_vector_ampsOneVsNvda180() public view {
        uint160 sqrtPriceX96 = price.ampsPerCounterToSqrtPriceX96(1e18, 180e8, DEC18);
        assertEq(uint256(sqrtPriceX96), 5_905_318_570_476_523_676_536_723_873, "AMPS $1 / NVDA $180");
        _assertCeilOfExact(sqrtPriceX96, 1e18, 180e8, DEC18);
        _assertRoundTrip(sqrtPriceX96, 1e18, 180e8, DEC18);
    }

    /// @dev The top of the launch ask ladder: AMPS $1,024 against SPY ($650, 18 decimals), raw price 1024/650 > 1.
    function test_vector_amps1024VsSpy650() public view {
        uint160 sqrtPriceX96 = price.ampsPerCounterToSqrtPriceX96(1024e18, 650e8, DEC18);
        assertEq(uint256(sqrtPriceX96), 99_442_694_568_943_815_650_207_204_387, "AMPS $1024 / SPY $650");
        _assertCeilOfExact(sqrtPriceX96, 1024e18, 650e8, DEC18);
        _assertRoundTrip(sqrtPriceX96, 1024e18, 650e8, DEC18);
        // Raw price above 1 must still land above tick 0 and below the 2x tick.
        int24 tick = price.sqrtPriceX96ToTick(sqrtPriceX96);
        assertGt(tick, int24(0), "1024/650 > 1");
        assertLt(tick, int24(6932), "1024/650 < 2");
    }

    /// @dev CRWD carries an ERC-8056 display multiplier of 4.0. The Chainlink answer is never multiplied by it, so
    ///      the pool anchor is computed from the $400 feed answer alone; feeding the multiplier-adjusted $100 in by
    ///      mistake would move the anchor by two doublings, which this test pins as a regression.
    function test_vector_crwdMultiplierIsIrrelevant() public view {
        uint160 correct = price.ampsPerCounterToSqrtPriceX96(1e18, 400e8, DEC18);
        assertEq(uint256(correct), 3_961_408_125_713_216_879_677_197_517, "AMPS $1 / CRWD $400");
        _assertCeilOfExact(correct, 1e18, 400e8, DEC18);

        uint160 multiplierApplied = price.ampsPerCounterToSqrtPriceX96(1e18, 100e8, DEC18);
        assertGt(uint256(multiplierApplied), uint256(correct), "applying the multiplier moves the anchor");
        // 4x in price is exactly two doublings of the tick.
        int24 delta = price.sqrtPriceX96ToTick(multiplierApplied) - price.sqrtPriceX96ToTick(correct);
        assertApproxEqAbs(int256(delta), int256(2) * 6931, 3, "4x == two doublings");
    }

    /// @dev The main speculative route: AMPS $1.00 against WETH ($3,000, 18 decimals).
    function test_vector_ampsOneVsEth3000() public view {
        uint160 sqrtPriceX96 = price.ampsPerCounterToSqrtPriceX96(1e18, 3000e8, DEC18);
        assertEq(uint256(sqrtPriceX96), 1_446_501_726_624_926_496_477_173_929, "AMPS $1 / WETH $3000");
        _assertCeilOfExact(sqrtPriceX96, 1e18, 3000e8, DEC18);
        _assertRoundTrip(sqrtPriceX96, 1e18, 3000e8, DEC18);
    }

    /// @dev AMPS $1.00 against AAPL ($250, 18 decimals): raw price 1/250, the scale cited in the design notes.
    function test_vector_ampsOneVsAapl250() public view {
        uint160 sqrtPriceX96 = price.ampsPerCounterToSqrtPriceX96(1e18, 250e8, DEC18);
        assertEq(uint256(sqrtPriceX96), 5_010_828_967_500_958_623_728_276_032, "AMPS $1 / AAPL $250");
        _assertCeilOfExact(sqrtPriceX96, 1e18, 250e8, DEC18);
        _assertRoundTrip(sqrtPriceX96, 1e18, 250e8, DEC18);
    }

    /// @dev The decimals of the counter asset, not just its price, move the anchor: USDG and an 18-decimal token at
    ///      the same USD price differ by exactly 1e12 in raw price, i.e. 1e6 in sqrt price.
    function test_decimalsShiftTheAnchorByTwelveOrdersOfMagnitude() public view {
        uint160 sixDec = price.ampsPerCounterToSqrtPriceX96(1e18, 1e8, DEC6);
        uint160 eighteenDec = price.ampsPerCounterToSqrtPriceX96(1e18, 1e8, DEC18);
        assertApproxEqAbs(uint256(eighteenDec), uint256(sixDec) * 1e6, 1e6, "1e12 in price is 1e6 in sqrt price");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Rounding direction
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `ampsPerCounterToSqrtPriceX96` rounds up, so a ladder anchored here never sells AMPS below its reference.
    function test_sqrtPriceRoundsUpNotDown() public view {
        // 1/3 raw price: the exact sqrt price is irrational, so the ceiling is strictly above the floor.
        uint160 sqrtPriceX96 = price.ampsPerCounterToSqrtPriceX96(1e18, 3e8, DEC18);
        uint256 floorValue = _exactSqrtFloor(1e18, 3e8, DEC18);
        assertEq(uint256(sqrtPriceX96), floorValue + 1, "ceiling, not floor");
    }

    /// @dev `counterValueUsd18` rounds down: NAV is never overstated.
    function test_counterValueRoundsDown() public view {
        // 1 wei of an 18-decimal token at $1 is 1e-18 USD, i.e. 1 unit of an 18-decimal USD value... but at $0.30
        // it is 3e-19, which floors to 0.
        assertEq(price.counterValueUsd18(1, DEC18, 30_000_000), 0, "sub-unit value floors to zero");
        assertEq(price.counterValueUsd18(1, DEC18, 1e8), 1, "1 wei at $1 is 1 unit of usd18");
        // 1 wei of USDG ($1, 6 decimals) is $1e-6 == 1e12 in usd18.
        assertEq(price.counterValueUsd18(1, DEC6, 1e8), 1e12, "USDG scales by 1e12");
    }

    /// @dev `counterAmountFromUsd18` rounds up: the protocol never accepts less than it is owed.
    function test_counterAmountRoundsUp() public view {
        // $1e-18 of a $0.30 18-decimal token is 3.33... wei, which must be charged as 4 wei.
        assertEq(price.counterAmountFromUsd18(1, DEC18, 30_000_000), 4, "ceiling");
        assertEq(price.counterAmountFromUsd18(0, DEC18, 30_000_000), 0, "zero stays zero");
        // Exact cases are not inflated.
        assertEq(price.counterAmountFromUsd18(1e18, DEC6, 1e8), 1e6, "$1 is 1 USDG");
    }

    /// @dev USD -> amount -> USD never loses the protocol money, in either order.
    function test_counterValueRoundTripFavoursTheProtocol() public view {
        uint256 usd18 = 1_234_567_890_123_456_789;
        uint256 amountRaw = price.counterAmountFromUsd18(usd18, DEC6, 137_450_000);
        assertGe(price.counterValueUsd18(amountRaw, DEC6, 137_450_000), usd18, "amount covers the value");

        uint256 raw = 987_654_321;
        uint256 value = price.counterValueUsd18(raw, DEC6, 137_450_000);
        assertLe(price.counterAmountFromUsd18(value, DEC6, 137_450_000), raw, "value never asks for more");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Tick helpers
    // -------------------------------------------------------------------------------------------------------------

    function test_tickRoundTripIsExactAtBoundaries() public view {
        assertEq(uint256(price.tickToSqrtPriceX96(TickMath.MIN_TICK)), uint256(TickMath.MIN_SQRT_PRICE));
        assertEq(price.sqrtPriceX96ToTick(TickMath.MIN_SQRT_PRICE), TickMath.MIN_TICK);
        assertEq(price.sqrtPriceX96ToTick(TickMath.MAX_SQRT_PRICE - 1), TickMath.MAX_TICK - 1);
        assertEq(uint256(price.tickToSqrtPriceX96(0)), uint256(1) << 96, "tick 0 is Q96");
        assertEq(price.sqrtPriceX96ToTick(uint160(uint256(1) << 96)), int24(0));
    }

    function test_alignTickFloorsAndCeils() public view {
        assertEq(price.alignTick(-276_325, 10, false), -276_330, "floor of a negative tick");
        assertEq(price.alignTick(-276_325, 10, true), -276_320, "ceil of a negative tick");
        assertEq(price.alignTick(276_325, 10, false), 276_320, "floor of a positive tick");
        assertEq(price.alignTick(276_325, 10, true), 276_330, "ceil of a positive tick");
        assertEq(price.alignTick(276_320, 10, false), 276_320, "already aligned, floor");
        assertEq(price.alignTick(276_320, 10, true), 276_320, "already aligned, ceil");
        assertEq(price.alignTick(0, 60, true), int24(0), "zero is aligned to everything");
        assertEq(price.alignTick(-5, 10, false), -10, "small negatives floor away from zero");
        assertEq(price.alignTick(-5, 10, true), int24(0), "small negatives ceil toward zero");
        assertEq(price.alignTick(5, 1, true), int24(5), "spacing 1 is the identity");
    }

    function test_alignTickClampsIntoTheUsableRange() public view {
        // MAX_TICK is 887272, which is not a multiple of 10; ceiling would leave the usable range, so it clamps.
        assertEq(price.alignTick(TickMath.MAX_TICK, 10, true), TickMath.maxUsableTick(10));
        assertEq(price.alignTick(TickMath.MAX_TICK, 10, true), 887_270);
        assertEq(price.alignTick(TickMath.MIN_TICK, 10, false), TickMath.minUsableTick(10));
        assertEq(price.alignTick(TickMath.MIN_TICK, 10, false), -887_270);
    }

    /// @dev The launch anchor: AMPS $1 against USDG $1 on a spacing-10 pool.
    function test_fairTickIsAlignedDown() public view {
        int24 tick = price.fairTick(1e18, 1e8, DEC6, 10);
        assertEq(tick, -276_330, "aligned down from -276325");
        assertEq(tick % 10, int24(0), "aligned");
        assertLe(tick, price.sqrtPriceX96ToTick(price.ampsPerCounterToSqrtPriceX96(1e18, 1e8, DEC6)), "down");
    }

    /// @dev A high-price pool exercises the `price >= 2**64` window of the square root.
    function test_largeRawPriceUsesTheWideWindow() public view {
        // AMPS at $1e20 against a $1 18-decimal counter: raw price 1e20, above 2**64 and far below 2**128.
        uint160 sqrtPriceX96 = price.ampsPerCounterToSqrtPriceX96(1e38, 1e8, DEC18);
        assertGt(uint256(sqrtPriceX96), uint256(1) << 96, "raw price above 1");
        uint256 recovered = price.sqrtPriceX96ToAmpsPriceUsd18(sqrtPriceX96, 1e8, DEC18);
        assertApproxEqRel(recovered, 1e38, 1e6, "wide window keeps 1e-12 relative accuracy");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reverts
    // -------------------------------------------------------------------------------------------------------------

    function test_revert_zeroPrices() public {
        vm.expectRevert(PriceLib.ZeroPrice.selector);
        price.ampsPerCounterToSqrtPriceX96(0, 1e8, DEC18);

        vm.expectRevert(PriceLib.ZeroPrice.selector);
        price.ampsPerCounterToSqrtPriceX96(1e18, 0, DEC18);

        vm.expectRevert(PriceLib.ZeroPrice.selector);
        price.counterValueUsd18(1e18, DEC18, 0);

        vm.expectRevert(PriceLib.ZeroPrice.selector);
        price.counterAmountFromUsd18(1e18, DEC18, 0);

        vm.expectRevert(PriceLib.ZeroPrice.selector);
        price.sqrtPriceX96ToAmpsPriceUsd18(uint160(uint256(1) << 96), 0, DEC18);
    }

    function test_revert_decimalsOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(PriceLib.DecimalsOutOfRange.selector, uint8(19)));
        price.ampsPerCounterToSqrtPriceX96(1e18, 1e8, 19);

        vm.expectRevert(abi.encodeWithSelector(PriceLib.DecimalsOutOfRange.selector, uint8(19)));
        price.counterValueUsd18(1e18, 19, 1e8);

        vm.expectRevert(abi.encodeWithSelector(PriceLib.DecimalsOutOfRange.selector, uint8(19)));
        price.counterAmountFromUsd18(1e18, 19, 1e8);

        vm.expectRevert(abi.encodeWithSelector(PriceLib.DecimalsOutOfRange.selector, uint8(255)));
        price.sqrtPriceX96ToAmpsPriceUsd18(uint160(uint256(1) << 96), 1e8, 255);
    }

    function test_revert_priceOverflow() public {
        vm.expectRevert(PriceLib.PriceOverflow.selector);
        price.ampsPerCounterToSqrtPriceX96(type(uint256).max, 1e8, DEC18);

        // decimals 0 makes the AMPS-side scale 1, so the counter-side guard is the one that trips.
        vm.expectRevert(PriceLib.PriceOverflow.selector);
        price.ampsPerCounterToSqrtPriceX96(1, type(uint256).max, 0);

        vm.expectRevert(PriceLib.PriceOverflow.selector);
        price.counterValueUsd18(1, DEC18, type(uint256).max);

        vm.expectRevert(PriceLib.PriceOverflow.selector);
        price.counterAmountFromUsd18(1, DEC18, type(uint256).max);

        vm.expectRevert(PriceLib.PriceOverflow.selector);
        price.sqrtPriceX96ToAmpsPriceUsd18(uint160(uint256(1) << 96), type(uint256).max, DEC18);
    }

    function test_revert_priceBelowMinSqrtPrice() public {
        // AMPS at 1e-18 USD against a $1e10 6-decimal counter: raw price 1e-46, far below MIN_SQRT_PRICE.
        vm.expectRevert(PriceLib.PriceOutOfTickRange.selector);
        price.ampsPerCounterToSqrtPriceX96(1, 1e18, DEC6);
    }

    function test_revert_priceAboveMaxSqrtPrice() public {
        // Raw price 2**128 - 1: below the short circuit, but its square root lands above MAX_SQRT_PRICE. The window
        // between MAX_SQRT_PRICE**2 / 2**192 and 2**128 is only ~7.5e-6 wide in relative terms, which is why the
        // short circuit is set at 2**128 and the final bound check is still needed.
        vm.expectRevert(PriceLib.PriceOutOfTickRange.selector);
        price.ampsPerCounterToSqrtPriceX96(((uint256(1) << 128) - 1) * 1e18, 1e8, DEC18);
    }

    function test_revert_priceAboveTheShortCircuit() public {
        // Raw price 1e39, comfortably above 2**128: rejected before the square root can be attempted.
        vm.expectRevert(PriceLib.PriceOutOfTickRange.selector);
        price.ampsPerCounterToSqrtPriceX96(1e57, 1e8, DEC18);
    }

    function test_revert_sqrtPriceOutOfRange() public {
        vm.expectRevert(
            abi.encodeWithSelector(PriceLib.SqrtPriceOutOfRange.selector, uint160(TickMath.MIN_SQRT_PRICE - 1))
        );
        price.sqrtPriceX96ToTick(TickMath.MIN_SQRT_PRICE - 1);

        vm.expectRevert(abi.encodeWithSelector(PriceLib.SqrtPriceOutOfRange.selector, TickMath.MAX_SQRT_PRICE));
        price.sqrtPriceX96ToTick(TickMath.MAX_SQRT_PRICE);

        vm.expectRevert(abi.encodeWithSelector(PriceLib.SqrtPriceOutOfRange.selector, uint160(0)));
        price.sqrtPriceX96ToAmpsPriceUsd18(0, 1e8, DEC18);
    }

    function test_revert_tickOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(PriceLib.TickOutOfRange.selector, TickMath.MIN_TICK - 1));
        price.tickToSqrtPriceX96(TickMath.MIN_TICK - 1);

        vm.expectRevert(abi.encodeWithSelector(PriceLib.TickOutOfRange.selector, TickMath.MAX_TICK + 1));
        price.tickToSqrtPriceX96(TickMath.MAX_TICK + 1);

        vm.expectRevert(abi.encodeWithSelector(PriceLib.TickOutOfRange.selector, TickMath.MAX_TICK + 1));
        price.alignTick(TickMath.MAX_TICK + 1, 10, false);

        vm.expectRevert(abi.encodeWithSelector(PriceLib.TickOutOfRange.selector, TickMath.MIN_TICK - 1));
        price.alignTick(TickMath.MIN_TICK - 1, 10, false);
    }

    function test_revert_invalidTickSpacing() public {
        vm.expectRevert(abi.encodeWithSelector(PriceLib.InvalidTickSpacing.selector, int24(0)));
        price.alignTick(0, 0, false);

        vm.expectRevert(abi.encodeWithSelector(PriceLib.InvalidTickSpacing.selector, int24(-1)));
        price.alignTick(0, -1, false);

        vm.expectRevert(abi.encodeWithSelector(PriceLib.InvalidTickSpacing.selector, TickMath.MAX_TICK_SPACING + 1));
        price.alignTick(0, TickMath.MAX_TICK_SPACING + 1, false);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Independent floor of the exact sqrt price, computed straight from the documented fraction.
    function _exactSqrtFloor(uint256 pRefUsd18, uint256 counterPriceUsd8, uint8 counterDecimals)
        internal
        pure
        returns (uint256)
    {
        uint256 numerator = pRefUsd18 * (10 ** uint256(counterDecimals));
        uint256 denominator = counterPriceUsd8 * 1e28;
        return Math.sqrt(FullMath.mulDiv(numerator, uint256(1) << 192, denominator));
    }

    /// @dev The library must return the ceiling of the exact value: never below it, never more than 1 ulp above.
    function _assertCeilOfExact(
        uint160 sqrtPriceX96,
        uint256 pRefUsd18,
        uint256 counterPriceUsd8,
        uint8 counterDecimals
    ) internal pure {
        uint256 floorValue = _exactSqrtFloor(pRefUsd18, counterPriceUsd8, counterDecimals);
        assertGe(uint256(sqrtPriceX96), floorValue, "never below the exact sqrt price");
        assertLe(uint256(sqrtPriceX96), floorValue + 1, "never more than one ulp above");
    }

    /// @dev price -> sqrtPrice -> tick -> sqrtPrice -> price must land within one tick of where it started.
    function _assertRoundTrip(uint160 sqrtPriceX96, uint256 pRefUsd18, uint256 counterPriceUsd8, uint8 counterDecimals)
        internal
        view
    {
        int24 tick = price.sqrtPriceX96ToTick(sqrtPriceX96);
        uint160 backToSqrt = price.tickToSqrtPriceX96(tick);
        uint256 backToPrice = price.sqrtPriceX96ToAmpsPriceUsd18(backToSqrt, counterPriceUsd8, counterDecimals);
        assertLe(backToPrice, pRefUsd18, "the tick floor never overstates the price");
        // One tick is 1.0001x in price, i.e. 1e-4 relative; assertApproxEqRel takes 1e18 == 100%.
        assertApproxEqRel(backToPrice, pRefUsd18, 1.1e14, "within one tick");
    }
}
