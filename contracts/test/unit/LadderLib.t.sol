// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LadderLib} from "../../src/lib/LadderLib.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {LadderLibHarness, PriceLibHarness} from "../utils/LibHarness.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

/// @notice Shape, geometry and rounding of the static ask/bid ladders, plus the genesis `AMPS/USDG` example.
contract LadderLibTest is Test {
    LadderLibHarness internal ladder;
    PriceLibHarness internal price;

    uint256 internal constant TILT_FLAT = 1e18;
    uint256 internal constant TILT_LAUNCH = 1.25e18;
    uint256 internal constant TILT_MAX = 1.5e18;

    function setUp() public {
        ladder = new LadderLibHarness();
        price = new PriceLibHarness();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Geometry
    // -------------------------------------------------------------------------------------------------------------

    function test_doublingTicksRoundsUpToTheSpacing() public view {
        assertEq(ladder.doublingTicks(1), int24(6932), "ceil(ln2/ln1.0001) == 6932");
        assertEq(ladder.doublingTicks(2), int24(6932), "already a multiple");
        assertEq(ladder.doublingTicks(3), int24(6933), "ceil to the next multiple of 3");
        assertEq(ladder.doublingTicks(10), int24(6940), "the entry pools' spacing");
        assertEq(ladder.doublingTicks(60), int24(6960));
        assertEq(ladder.doublingTicks(200), int24(7000));
        // A spacing wider than a doubling collapses a bucket to the narrowest placeable range.
        assertEq(ladder.doublingTicks(10_000), int24(10_000));
        assertEq(ladder.doublingTicks(TickMath.MAX_TICK_SPACING), TickMath.MAX_TICK_SPACING);
    }

    /// @dev A bucket really is a doubling: 6940 ticks is 2.0014x, i.e. within 0.1% of exactly 2x.
    function test_aBucketIsOneDoublingInPrice() public view {
        int24 width = ladder.doublingTicks(10);
        uint160 lower = price.tickToSqrtPriceX96(0);
        uint160 upper = price.tickToSqrtPriceX96(width);
        // price ratio == (sqrtUpper / sqrtLower)**2, in 1e18 fixed point.
        uint256 sqrtRatioX18 = uint256(upper) * 1e18 / uint256(lower);
        uint256 priceRatioX18 = sqrtRatioX18 * sqrtRatioX18 / 1e18;
        assertApproxEqRel(priceRatioX18, 2e18, 0.001e18, "one bucket doubles the price");
        assertGe(priceRatioX18, 2e18, "rounding up never sells below the nominal doubling");
    }

    function test_bucketBoundsAreContiguousAndAlignedAbove() public view {
        int24 anchor = -276_325;
        int24 spacing = 10;
        int24 width = ladder.doublingTicks(spacing);

        (int24 firstLower,) = ladder.bucketBounds(anchor, spacing, 0, true);
        assertEq(firstLower, price.alignTick(anchor, spacing, true), "first ask bucket starts at the aligned anchor");
        assertEq(firstLower, -276_320, "aligned up from -276325");

        int24 previousUpper = firstLower;
        for (uint8 k = 0; k < 10; ++k) {
            (int24 lower, int24 upper) = ladder.bucketBounds(anchor, spacing, k, true);
            assertEq(lower, previousUpper, "contiguous with the bucket below");
            assertEq(upper - lower, width, "one doubling wide");
            assertEq(lower % spacing, int24(0), "lower aligned");
            assertEq(upper % spacing, int24(0), "upper aligned");
            previousUpper = upper;
        }
        assertEq(previousUpper, -276_320 + 10 * 6940, "ten doublings above the anchor");
    }

    function test_bucketBoundsAreContiguousAndAlignedBelow() public view {
        int24 anchor = -276_325;
        int24 spacing = 10;
        int24 width = ladder.doublingTicks(spacing);

        (, int24 firstUpper) = ladder.bucketBounds(anchor, spacing, 0, false);
        assertEq(firstUpper, price.alignTick(anchor, spacing, false), "first bid bucket ends at the aligned anchor");
        assertEq(firstUpper, -276_330, "aligned down from -276325");

        int24 previousLower = firstUpper;
        for (uint8 k = 0; k < 4; ++k) {
            (int24 lower, int24 upper) = ladder.bucketBounds(anchor, spacing, k, false);
            assertEq(upper, previousLower, "contiguous with the bucket above");
            assertEq(upper - lower, width, "one halving wide");
            assertEq(lower % spacing, int24(0), "lower aligned");
            previousLower = lower;
        }
        assertEq(previousLower, -276_330 - 4 * 6940, "four halvings below the anchor");
    }

    function test_bucketBoundsClampAtTheEdgeOfTheTickRange() public view {
        (int24 lower, int24 upper) = ladder.bucketBounds(TickMath.MAX_TICK, 10, 13, true);
        assertEq(lower, TickMath.maxUsableTick(10), "clamped");
        assertEq(upper, TickMath.maxUsableTick(10), "clamped");

        (lower, upper) = ladder.bucketBounds(TickMath.MIN_TICK, 10, 13, false);
        assertEq(lower, TickMath.minUsableTick(10), "clamped");
        assertEq(upper, TickMath.minUsableTick(10), "clamped");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Weights
    // -------------------------------------------------------------------------------------------------------------

    function test_weightsSumAndShapeAcrossTheGovernedBand() public view {
        uint256[3] memory tilts = [TILT_FLAT, TILT_LAUNCH, TILT_MAX];
        uint8[3] memory counts = [uint8(6), uint8(10), uint8(14)];

        for (uint256 t = 0; t < tilts.length; ++t) {
            for (uint256 c = 0; c < counts.length; ++c) {
                uint256[] memory w = ladder.weights(tilts[t], counts[c]);
                assertEq(w.length, counts[c], "one weight per bucket");

                uint256 sum;
                for (uint256 k = 0; k < w.length; ++k) {
                    sum += w[k];
                    if (k > 0) assertGe(w[k], w[k - 1], "monotone non-decreasing");
                }
                assertEq(sum, 1e18, "weights sum to exactly 1e18");

                if (tilts[t] == TILT_FLAT) {
                    assertApproxEqAbs(w[0], 1e18 / counts[c], 1, "a flat tilt is a uniform ladder");
                } else {
                    assertGt(w[w.length - 1], w[0], "a tilted ladder puts more inventory up high");
                }
            }
        }
    }

    /// @dev The launch shape: ten buckets at 1.25x means the top bucket holds 1.25**9 == 7.4506x the bottom one.
    function test_launchTiltRatioIsSevenPointFourFive() public view {
        uint256[] memory w = ladder.weights(TILT_LAUNCH, 10);
        uint256 ratioX18 = w[9] * 1e18 / w[0];
        assertApproxEqRel(ratioX18, 7.450580596923828e18, 1e12, "1.25**9");
        assertApproxEqAbs(w[0], 0.030072562400417847e18, 1, "bucket 0 is 3.0073%");
        assertApproxEqAbs(w[9], 0.224058049920334282e18, 1, "bucket 9 is 22.4058%");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Split
    // -------------------------------------------------------------------------------------------------------------

    function test_splitIsExact() public view {
        uint256[] memory w = ladder.weights(TILT_LAUNCH, 10);
        uint256[3] memory amounts = [uint256(1), 1662.5e18, 4750e18];

        for (uint256 a = 0; a < amounts.length; ++a) {
            uint256[] memory out = ladder.split(amounts[a], w);
            uint256 sum;
            for (uint256 k = 0; k < out.length; ++k) {
                sum += out[k];
            }
            assertEq(sum, amounts[a], "split leaves no dust");
        }
    }

    function test_splitOfOneWeiLandsInTheLastBucket() public view {
        uint256[] memory w = ladder.weights(TILT_LAUNCH, 10);
        uint256[] memory out = ladder.split(1, w);
        for (uint256 k = 0; k + 1 < out.length; ++k) {
            assertEq(out[k], 0, "floors to zero");
        }
        assertEq(out[9], 1, "the residue lands in the last bucket");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Amount <-> liquidity
    // -------------------------------------------------------------------------------------------------------------

    /// @dev At the launch anchor the round-trip dust is a few hundred thousand wei, i.e. below 1e-12 AMPS.
    function test_amountLiquidityRoundTripAtTheLaunchAnchor() public view {
        int24 anchor = price.fairTick(1e18, 1e8, 6, 10);
        int24 width = ladder.doublingTicks(10);
        uint160 sqrtLower = price.tickToSqrtPriceX96(anchor);
        uint160 sqrtUpper = price.tickToSqrtPriceX96(anchor + width);

        uint256 amount0 = 49.9956e18;
        uint128 liquidity = ladder.liquidityForAmount0Above(sqrtLower, sqrtUpper, amount0);
        assertGt(liquidity, 0, "a real position");
        uint256 back = ladder.amount0ForLiquidity(sqrtLower, sqrtUpper, liquidity);
        assertLe(back, amount0, "never claims more AMPS than it was given");
        assertLt(amount0 - back, 1e9, "dust only");

        // And the other way round: liquidity -> amount -> liquidity.
        uint128 liquidityBack = ladder.liquidityForAmount0Above(sqrtLower, sqrtUpper, back);
        assertLe(liquidityBack, liquidity, "never inflates the position");
        assertApproxEqAbs(uint256(liquidityBack), uint256(liquidity), 1, "within one unit of liquidity");
    }

    /// @dev The bid side, in USDG (6 decimals): $2,500 placed four halvings below the anchor.
    function test_amountLiquidityRoundTripOnTheBidSide() public view {
        int24 anchor = price.fairTick(1e18, 1e8, 6, 10);
        int24 width = ladder.doublingTicks(10);
        uint160 sqrtUpper = price.tickToSqrtPriceX96(anchor);
        uint160 sqrtLower = price.tickToSqrtPriceX96(anchor - width);

        uint256 amount1 = 2500e6;
        uint128 liquidity = ladder.liquidityForAmount1Below(sqrtLower, sqrtUpper, amount1);
        assertGt(liquidity, 0, "a real position");
        uint256 back = ladder.amount1ForLiquidity(sqrtLower, sqrtUpper, liquidity);
        assertLe(back, amount1, "never claims more USDG than it was given");
        assertLe(amount1 - back, 1, "within one unit of USDG dust");
    }

    /// @dev Near `MIN_SQRT_PRICE` v4's own `sqrtLower * sqrtUpper / 2**96` intermediate truncates to zero, so a
    ///      currency0 range there yields zero liquidity however much AMPS is offered. `LadderLib` surfaces that as a
    ///      zero-liquidity bucket rather than as a revert or a silent partial fill: the vault must treat such a bucket
    ///      as unplaced inventory. No configured Amplestocks pool comes near this region (the deepest launch anchor is
    ///      `AMPS/USDG` at tick -276330, half a million ticks above it), but the boundary is pinned here on purpose.
    function test_liquidityUnderflowsToZeroAtTheBottomOfTheTickRange() public view {
        int24 spacing = 10;
        int24 lower = TickMath.minUsableTick(spacing);
        int24 upper = lower + ladder.doublingTicks(spacing);

        uint128 degenerate =
            ladder.liquidityForAmount0Above(price.tickToSqrtPriceX96(lower), price.tickToSqrtPriceX96(upper), 1e27);
        assertEq(degenerate, 0, "v4's intermediate truncates to zero at the bottom of the range");

        // The same call at the launch anchor is a real position, which is what the fuzz bounds rely on.
        int24 anchor = price.fairTick(1e18, 1e8, 6, spacing);
        uint128 real = ladder.liquidityForAmount0Above(
            price.tickToSqrtPriceX96(anchor), price.tickToSqrtPriceX96(anchor + ladder.doublingTicks(spacing)), 1e18
        );
        assertGt(real, 0, "the configured pools are far from that boundary");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The launch ladder
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Genesis `AMPS/USDG`: 1,662.5 AMPS as ten doublings above $1.00 at tilt 1.25 on a spacing-10 pool.
    function test_launchAskLadder() public view {
        int24 anchor = price.fairTick(1e18, 1e8, 6, 10);
        uint256 inventory = 1662.5e18;

        (int24[] memory lowers, int24[] memory uppers, uint128[] memory liquidities) =
            ladder.ladderAmounts(anchor, 10, 10, TILT_LAUNCH, inventory, true);

        console.log("AMPS/USDG genesis ask ladder: anchor tick %s, spacing 10, n 10, tilt 1.25", vm.toString(anchor));
        console.log(" k |   lower |   upper |  price ($) |   AMPS |  share");

        uint256 placedTotal;
        uint256[] memory placed = new uint256[](10);
        for (uint256 k = 0; k < 10; ++k) {
            placed[k] = ladder.amount0ForLiquidity(
                price.tickToSqrtPriceX96(lowers[k]), price.tickToSqrtPriceX96(uppers[k]), liquidities[k]
            );
            placedTotal += placed[k];
            // The bucket's lower bound as a USD price of AMPS, given USDG at $1.00.
            uint256 lowerPriceUsd18 = price.sqrtPriceX96ToAmpsPriceUsd18(price.tickToSqrtPriceX96(lowers[k]), 1e8, 6);
            console.log(
                string.concat(
                    " ",
                    vm.toString(k),
                    " | ",
                    vm.toString(lowers[k]),
                    " | ",
                    vm.toString(uppers[k]),
                    " | ",
                    _usd(lowerPriceUsd18),
                    " | ",
                    _amps(placed[k]),
                    " | ",
                    _pct(placed[k] * 1e18 / inventory)
                )
            );
        }

        // Exact per-bucket AMPS, straight from the geometric weights and the exact split.
        assertEq(placedTotal + (inventory - placedTotal), inventory, "accounting closes");
        assertApproxEqAbs(placed[0], 49_995_634_990_694_670_637, 1e9, "bucket 0 == 49.9956 AMPS");
        assertApproxEqAbs(placed[9], 372_496_507_992_555_743_827, 1e9, "bucket 9 == 372.4965 AMPS");
        assertApproxEqRel(
            placed[0] * 1e18 / inventory, 0.030072562400417847e18, 1e12, "bucket 0 is 3.0% of the tranche"
        );
        assertApproxEqRel(placed[9] * 1e18 / inventory, 0.224058049920334282e18, 1e12, "bucket 9 is 22.4%");
        assertLe(inventory - placedTotal, 1e10, "liquidity rounding leaves only dust unplaced");

        // The ladder runs from the anchor to just past 1,024x it.
        assertEq(lowers[0], anchor, "starts at the aligned anchor");
        assertEq(uppers[9] - lowers[0], 10 * ladder.doublingTicks(10), "ten doublings wide");
        uint256 topPriceUsd18 = price.sqrtPriceX96ToAmpsPriceUsd18(price.tickToSqrtPriceX96(uppers[9]), 1e8, 6);
        assertGe(topPriceUsd18, 1024e18, "the top of the ladder is at or above $1,024");
        assertLe(topPriceUsd18, 1040e18, "and not materially beyond it");
    }

    /// @dev The seed bid ladder: four halvings below $1.00, weighted 1.25x toward the bucket nearest the anchor.
    function test_seedBidLadderIsWeightedTowardTheAnchor() public view {
        int24 anchor = price.fairTick(1e18, 1e8, 6, 10);
        uint256 inventory = 2500e6; // $2,500 of USDG

        (int24[] memory lowers, int24[] memory uppers, uint128[] memory liquidities) =
            ladder.ladderAmounts(anchor, 10, 4, TILT_LAUNCH, inventory, false);

        uint256 previous = type(uint256).max;
        uint256 total;
        for (uint256 k = 0; k < 4; ++k) {
            assertLt(uppers[k], anchor + 1, "every bid bucket sits at or below the anchor");
            uint256 amount = ladder.amount1ForLiquidity(
                price.tickToSqrtPriceX96(lowers[k]), price.tickToSqrtPriceX96(uppers[k]), liquidities[k]
            );
            assertLe(amount, previous, "bids thin out as the price falls");
            previous = amount;
            total += amount;
        }
        assertApproxEqAbs(total, inventory, 4, "the seed is fully placed");
    }

    /// @dev `seedHalvings` and `bondBidHalvings` are governed inside [2, 8]; every count in the band composes.
    function test_bidLaddersForTwoThroughEightHalvings() public view {
        int24 anchor = price.fairTick(1e18, 1e8, 6, 10);
        for (uint8 n = 2; n <= 8; ++n) {
            (int24[] memory lowers, int24[] memory uppers, uint128[] memory liquidities) =
                ladder.ladderAmounts(anchor, 10, n, TILT_LAUNCH, 2500e6, false);
            assertEq(lowers.length, n, "one bucket per halving");
            assertEq(uppers[0], anchor, "the top bid bucket ends at the anchor");
            assertEq(lowers[n - 1], anchor - int24(uint24(n)) * ladder.doublingTicks(10), "n halvings deep");

            uint256 total;
            for (uint256 k = 0; k < n; ++k) {
                assertEq(uppers[k] - lowers[k], ladder.doublingTicks(10), "one halving wide");
                total += ladder.amount1ForLiquidity(
                    price.tickToSqrtPriceX96(lowers[k]), price.tickToSqrtPriceX96(uppers[k]), liquidities[k]
                );
            }
            assertApproxEqAbs(total, 2500e6, uint256(n), "placed within one unit per bucket");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reverts
    // -------------------------------------------------------------------------------------------------------------

    function test_revert_tiltOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(LadderLib.TiltOutOfRange.selector, uint256(1e18 - 1)));
        ladder.weights(1e18 - 1, 10);

        vm.expectRevert(abi.encodeWithSelector(LadderLib.TiltOutOfRange.selector, uint256(1.5e18 + 1)));
        ladder.weights(1.5e18 + 1, 10);
    }

    function test_revert_bucketCountOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(LadderLib.BucketCountOutOfRange.selector, uint8(1)));
        ladder.weights(TILT_LAUNCH, 1);

        vm.expectRevert(abi.encodeWithSelector(LadderLib.BucketCountOutOfRange.selector, uint8(15)));
        ladder.weights(TILT_LAUNCH, 15);
    }

    function test_revert_bucketIndexOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(LadderLib.BucketIndexOutOfRange.selector, uint8(14)));
        ladder.bucketBounds(0, 10, 14, true);
    }

    function test_revert_invalidTickSpacing() public {
        vm.expectRevert(abi.encodeWithSelector(PriceLib.InvalidTickSpacing.selector, int24(0)));
        ladder.doublingTicks(0);

        vm.expectRevert(abi.encodeWithSelector(PriceLib.InvalidTickSpacing.selector, TickMath.MAX_TICK_SPACING + 1));
        ladder.doublingTicks(TickMath.MAX_TICK_SPACING + 1);
    }

    function test_revert_weightsNotNormalised() public {
        uint256[] memory bad = new uint256[](2);
        bad[0] = 0.5e18;
        bad[1] = 0.4e18;
        vm.expectRevert(abi.encodeWithSelector(LadderLib.WeightsNotNormalised.selector, uint256(0.9e18)));
        ladder.split(100, bad);
    }

    function test_revert_emptyWeights() public {
        vm.expectRevert(LadderLib.EmptyWeights.selector);
        ladder.split(100, new uint256[](0));
    }

    function test_revert_emptyRange() public {
        uint160 sqrtPriceX96 = price.tickToSqrtPriceX96(0);
        vm.expectRevert(abi.encodeWithSelector(LadderLib.EmptyRange.selector, sqrtPriceX96, sqrtPriceX96));
        ladder.liquidityForAmount0Above(sqrtPriceX96, sqrtPriceX96, 1e18);

        vm.expectRevert(abi.encodeWithSelector(LadderLib.EmptyRange.selector, sqrtPriceX96, sqrtPriceX96));
        ladder.liquidityForAmount1Below(sqrtPriceX96, sqrtPriceX96, 1e18);

        vm.expectRevert(abi.encodeWithSelector(LadderLib.EmptyRange.selector, sqrtPriceX96, sqrtPriceX96));
        ladder.amount0ForLiquidity(sqrtPriceX96, sqrtPriceX96, 1e18);

        vm.expectRevert(abi.encodeWithSelector(LadderLib.EmptyRange.selector, sqrtPriceX96, sqrtPriceX96));
        ladder.amount1ForLiquidity(sqrtPriceX96, sqrtPriceX96, 1e18);
    }

    /// @dev A ladder that does not fit above (or below) its anchor must fail loudly, not place a truncated ladder.
    function test_revert_degenerateBucket() public {
        vm.expectRevert(abi.encodeWithSelector(LadderLib.DegenerateBucket.selector, uint8(0)));
        ladder.ladderAmounts(TickMath.MAX_TICK, 10, 10, TILT_LAUNCH, 1662.5e18, true);

        vm.expectRevert(abi.encodeWithSelector(LadderLib.DegenerateBucket.selector, uint8(0)));
        ladder.ladderAmounts(TickMath.MIN_TICK, 10, 4, TILT_LAUNCH, 2500e6, false);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Formatting helpers (console output only)
    // -------------------------------------------------------------------------------------------------------------

    function _usd(uint256 valueX18) internal pure returns (string memory) {
        return string.concat(vm.toString(valueX18 / 1e18), ".", _twoDecimals(valueX18 % 1e18));
    }

    function _amps(uint256 amountWei) internal pure returns (string memory) {
        return string.concat(vm.toString(amountWei / 1e18), ".", _twoDecimals(amountWei % 1e18));
    }

    function _pct(uint256 shareX18) internal pure returns (string memory) {
        uint256 bps = shareX18 / 1e14; // 1e18 == 100.00%
        return string.concat(vm.toString(bps / 100), ".", _twoDigits(bps % 100), "%");
    }

    function _twoDecimals(uint256 fraction) internal pure returns (string memory) {
        return _twoDigits(fraction / 1e16);
    }

    function _twoDigits(uint256 value) internal pure returns (string memory) {
        return value < 10 ? string.concat("0", vm.toString(value)) : vm.toString(value);
    }
}
