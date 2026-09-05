// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PriceLib} from "../../src/lib/PriceLib.sol";
import {PriceLibHarness} from "../utils/LibHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Property tests for `PriceLib` over the whole Amplestocks price domain.
/// @dev The domain is bounded rather than rejected: AMPS reference prices from $1e-6 to $1e12, counter-asset feed
///      prices from $0.01 to $1e7, and 6- or 18-decimal counter assets. Every corner of that box maps into
///      `[MIN_SQRT_PRICE, MAX_SQRT_PRICE)`, so no input is wasted on `vm.assume`.
contract PriceLibFuzzTest is Test {
    PriceLibHarness internal price;

    /// @dev $1e-6, in 18-decimal USD.
    uint256 internal constant MIN_PREF_USD18 = 1e12;
    /// @dev $1e12, in 18-decimal USD.
    uint256 internal constant MAX_PREF_USD18 = 1e30;
    /// @dev $0.01, in 8-decimal USD.
    uint256 internal constant MIN_COUNTER_USD8 = 1e6;
    /// @dev $1e7, in 8-decimal USD.
    uint256 internal constant MAX_COUNTER_USD8 = 1e15;

    function setUp() public {
        price = new PriceLibHarness();
    }

    // -------------------------------------------------------------------------------------------------------------
    // sqrt price
    // -------------------------------------------------------------------------------------------------------------

    /// @dev price -> sqrtPrice -> tick -> sqrtPrice -> price stays within one tick, in the protocol's favour.
    function testFuzz_roundTripWithinOneTick(uint256 pRefSeed, uint256 counterSeed, bool eighteenDecimals) public view {
        (uint256 pRefUsd18, uint256 counterUsd8, uint8 decimals) = _bound(pRefSeed, counterSeed, eighteenDecimals);

        uint160 sqrtPriceX96 = price.ampsPerCounterToSqrtPriceX96(pRefUsd18, counterUsd8, decimals);
        int24 tick = price.sqrtPriceX96ToTick(sqrtPriceX96);
        uint160 sqrtBack = price.tickToSqrtPriceX96(tick);
        uint256 pRefBack = price.sqrtPriceX96ToAmpsPriceUsd18(sqrtBack, counterUsd8, decimals);

        // The tick floors, so the recovered price can only be lower.
        assertLe(sqrtBack, sqrtPriceX96, "tick floors the sqrt price");
        assertLe(pRefBack, pRefUsd18, "and therefore floors the price");
        // One tick is 1.0001x, i.e. 1e-4 relative.
        assertApproxEqRel(pRefBack, pRefUsd18, 1.1e14, "one tick");

        // Re-anchoring on the recovered price lands on the same tick, give or take the floor.
        int24 tickBack = price.sqrtPriceX96ToTick(price.ampsPerCounterToSqrtPriceX96(pRefBack, counterUsd8, decimals));
        assertApproxEqAbs(int256(tickBack), int256(tick), 1, "within one tick");
    }

    /// @dev The sqrt price is the ceiling of the exact value: never below it, never more than one ulp above it.
    function testFuzz_sqrtPriceIsTheCeiling(uint256 pRefSeed, uint256 counterSeed, bool eighteenDecimals) public view {
        (uint256 pRefUsd18, uint256 counterUsd8, uint8 decimals) = _bound(pRefSeed, counterSeed, eighteenDecimals);

        uint256 numerator = pRefUsd18 * (10 ** uint256(decimals));
        uint256 denominator = counterUsd8 * 1e28;
        uint256 exactFloor = Math.sqrt(FullMath.mulDiv(numerator, uint256(1) << 192, denominator));

        uint256 actual = uint256(price.ampsPerCounterToSqrtPriceX96(pRefUsd18, counterUsd8, decimals));
        assertGe(actual, exactFloor, "never undersells AMPS");
        assertLe(actual, exactFloor + 1, "never more than one ulp of slack");
    }

    /// @dev The AMPS price and the pool price move together; the counter price moves against it.
    function testFuzz_monotonicity(uint256 pRefSeed, uint256 counterSeed, bool eighteenDecimals) public view {
        (uint256 pRefUsd18, uint256 counterUsd8, uint8 decimals) = _bound(pRefSeed, counterSeed, eighteenDecimals);
        uint256 higherPRef = pRefUsd18 + pRefUsd18 / 8;
        uint256 higherCounter = counterUsd8 + counterUsd8 / 8;

        uint160 base = price.ampsPerCounterToSqrtPriceX96(pRefUsd18, counterUsd8, decimals);
        assertGe(
            uint256(price.ampsPerCounterToSqrtPriceX96(higherPRef, counterUsd8, decimals)),
            uint256(base),
            "dearer AMPS is a higher pool price"
        );
        assertLe(
            uint256(price.ampsPerCounterToSqrtPriceX96(pRefUsd18, higherCounter, decimals)),
            uint256(base),
            "a dearer counter asset is a lower pool price"
        );
    }

    /// @dev `fairTick` is the aligned-down tick of the same anchor, within one spacing of it.
    function testFuzz_fairTickIsTheAlignedAnchor(
        uint256 pRefSeed,
        uint256 counterSeed,
        bool eighteenDecimals,
        int24 spacingSeed
    ) public view {
        (uint256 pRefUsd18, uint256 counterUsd8, uint8 decimals) = _bound(pRefSeed, counterSeed, eighteenDecimals);
        int24 tickSpacing = int24(bound(int256(spacingSeed), 1, TickMath.MAX_TICK_SPACING));

        int24 raw = price.sqrtPriceX96ToTick(price.ampsPerCounterToSqrtPriceX96(pRefUsd18, counterUsd8, decimals));
        int24 fair = price.fairTick(pRefUsd18, counterUsd8, decimals, tickSpacing);

        assertEq(fair % tickSpacing, int24(0), "aligned to the spacing");
        assertLe(fair, raw, "aligned down");
        assertLt(int256(raw) - int256(fair), int256(tickSpacing), "and by less than one spacing");
    }

    // -------------------------------------------------------------------------------------------------------------
    // alignTick
    // -------------------------------------------------------------------------------------------------------------

    function testFuzz_alignTick(int24 tickSeed, int24 spacingSeed, bool roundUp) public view {
        int24 tick = int24(bound(int256(tickSeed), TickMath.MIN_TICK, TickMath.MAX_TICK));
        int24 tickSpacing = int24(bound(int256(spacingSeed), 1, TickMath.MAX_TICK_SPACING));

        int24 aligned = price.alignTick(tick, tickSpacing, roundUp);
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        assertEq(aligned % tickSpacing, int24(0), "multiple of the spacing");
        assertGe(aligned, minUsable, "inside the usable range");
        assertLe(aligned, maxUsable, "inside the usable range");
        // The clamp can only move the result by less than one spacing, so this holds in every case.
        assertLe(_absDiff(aligned, tick), uint256(uint24(tickSpacing)), "within one spacing of the input");

        if (roundUp) {
            assertTrue(aligned >= tick || aligned == maxUsable, "ceils unless clamped at the top");
        } else {
            assertTrue(aligned <= tick || aligned == minUsable, "floors unless clamped at the bottom");
        }

        // Aligning an aligned tick is a no-op in both directions.
        assertEq(price.alignTick(aligned, tickSpacing, true), aligned, "idempotent, up");
        assertEq(price.alignTick(aligned, tickSpacing, false), aligned, "idempotent, down");
    }

    /// @dev Floor and ceiling bracket the input and are one spacing apart whenever the input is not already aligned.
    function testFuzz_alignTickBrackets(int24 tickSeed, int24 spacingSeed) public view {
        int24 tickSpacing = int24(bound(int256(spacingSeed), 1, TickMath.MAX_TICK_SPACING));
        // Stay clear of the clamp so the pure bracketing property is what is being asserted.
        int24 tick = int24(
            bound(
                int256(tickSeed),
                int256(TickMath.minUsableTick(tickSpacing)),
                int256(TickMath.maxUsableTick(tickSpacing))
            )
        );

        int24 floored = price.alignTick(tick, tickSpacing, false);
        int24 ceiled = price.alignTick(tick, tickSpacing, true);
        assertLe(floored, tick, "floor");
        assertGe(ceiled, tick, "ceil");
        if (tick % tickSpacing == 0) {
            assertEq(floored, ceiled, "already aligned");
        } else {
            assertEq(int256(ceiled) - int256(floored), int256(tickSpacing), "exactly one spacing apart");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Counter-asset valuation
    // -------------------------------------------------------------------------------------------------------------

    /// @dev amount -> USD -> amount never asks the protocol for more than it started with.
    function testFuzz_amountValueAmountRoundTrip(uint256 amountSeed, uint256 counterSeed, bool eighteenDecimals)
        public
        view
    {
        uint8 decimals = eighteenDecimals ? 18 : 6;
        uint256 counterUsd8 = bound(counterSeed, MIN_COUNTER_USD8, MAX_COUNTER_USD8);
        uint256 amountRaw = bound(amountSeed, 0, 1e40);

        uint256 usd18 = price.counterValueUsd18(amountRaw, decimals, counterUsd8);
        uint256 amountBack = price.counterAmountFromUsd18(usd18, decimals, counterUsd8);
        assertLe(amountBack, amountRaw, "valuation never inflates the amount");
    }

    /// @dev USD -> amount -> USD always covers what was asked for.
    function testFuzz_valueAmountValueRoundTrip(uint256 usdSeed, uint256 counterSeed, bool eighteenDecimals)
        public
        view
    {
        uint8 decimals = eighteenDecimals ? 18 : 6;
        uint256 counterUsd8 = bound(counterSeed, MIN_COUNTER_USD8, MAX_COUNTER_USD8);
        uint256 usd18 = bound(usdSeed, 0, 1e40);

        uint256 amountRaw = price.counterAmountFromUsd18(usd18, decimals, counterUsd8);
        uint256 usdBack = price.counterValueUsd18(amountRaw, decimals, counterUsd8);
        assertGe(usdBack, usd18, "the requested amount covers the value");
    }

    /// @dev Valuation is linear and monotone in the balance, which is what makes the NAV numerator additive.
    function testFuzz_valuationIsMonotone(uint256 amountSeed, uint256 counterSeed, bool eighteenDecimals) public view {
        uint8 decimals = eighteenDecimals ? 18 : 6;
        uint256 counterUsd8 = bound(counterSeed, MIN_COUNTER_USD8, MAX_COUNTER_USD8);
        uint256 amountRaw = bound(amountSeed, 0, 1e40);

        assertGe(
            price.counterValueUsd18(amountRaw + 1e6, decimals, counterUsd8),
            price.counterValueUsd18(amountRaw, decimals, counterUsd8),
            "monotone in the balance"
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    function _bound(uint256 pRefSeed, uint256 counterSeed, bool eighteenDecimals)
        internal
        pure
        returns (uint256 pRefUsd18, uint256 counterUsd8, uint8 decimals)
    {
        pRefUsd18 = bound(pRefSeed, MIN_PREF_USD18, MAX_PREF_USD18);
        counterUsd8 = bound(counterSeed, MIN_COUNTER_USD8, MAX_COUNTER_USD8);
        decimals = eighteenDecimals ? 18 : 6;
    }

    function _absDiff(int24 a, int24 b) internal pure returns (uint256) {
        return a >= b ? uint256(uint24(a - b)) : uint256(uint24(b - a));
    }
}
