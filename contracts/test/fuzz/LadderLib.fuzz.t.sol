// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LadderLib} from "../../src/lib/LadderLib.sol";
import {LadderLibHarness, PriceLibHarness} from "../utils/LibHarness.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Property tests for `LadderLib`: exact sums, contiguous geometry and rounding that always favours the vault.
/// @dev Anchors are bounded to `[-350000, 100000]` and spacings to `[1, 200]`. That box covers every configured
///      Amplestocks pool with room to spare — the deepest anchor at launch is `AMPS/USDG` at tick -276330 and the
///      shallowest is `AMPS/SPY` a little above -50000 — while leaving the full 14-bucket ladder inside the usable
///      tick range and keeping v4's `sqrtLower * sqrtUpper / 2**96` intermediate far away from underflowing to zero.
contract LadderLibFuzzTest is Test {
    LadderLibHarness internal ladder;
    PriceLibHarness internal price;

    int24 internal constant MIN_ANCHOR = -350_000;
    int24 internal constant MAX_ANCHOR = 100_000;
    int24 internal constant MAX_SPACING = 200;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// @dev Bundled ladder parameters, so the property tests stay inside solc's stack limit without `via_ir`.
    struct Ladder {
        int24 anchor;
        int24 spacing;
        int24 width;
        int24 base;
        uint8 n;
        bool above;
        uint256 tiltX18;
        uint256 inventory;
    }

    function setUp() public {
        ladder = new LadderLibHarness();
        price = new PriceLibHarness();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Weights and split
    // -------------------------------------------------------------------------------------------------------------

    function testFuzz_weightsSumToOneAndRiseWithPrice(uint256 tiltSeed, uint8 nSeed) public view {
        uint256 tiltX18 = bound(tiltSeed, LadderLib.MIN_TILT_X18, LadderLib.MAX_TILT_X18);
        uint8 n = uint8(bound(uint256(nSeed), LadderLib.MIN_BUCKETS, LadderLib.MAX_BUCKETS));

        uint256[] memory w = ladder.weights(tiltX18, n);
        assertEq(w.length, n, "one weight per bucket");

        uint256 sum;
        for (uint256 k = 0; k < w.length; ++k) {
            sum += w[k];
            if (k > 0) assertGe(w[k], w[k - 1], "monotone non-decreasing");
            assertGt(w[k], 0, "no empty bucket");
        }
        assertEq(sum, 1e18, "sums to exactly 1e18");
    }

    /// @dev I34: bucket `k` holds `tilt^k / sum_j tilt^j` of the placement, within the rounding of the fixed point.
    function testFuzz_weightsMatchTheGeometricSeries(uint256 tiltSeed, uint8 nSeed) public view {
        uint256 tiltX18 = bound(tiltSeed, LadderLib.MIN_TILT_X18, LadderLib.MAX_TILT_X18);
        uint8 n = uint8(bound(uint256(nSeed), LadderLib.MIN_BUCKETS, LadderLib.MAX_BUCKETS));

        uint256[] memory w = ladder.weights(tiltX18, n);
        for (uint256 k = 1; k + 1 < w.length; ++k) {
            // Consecutive weights are in the ratio `tilt`; the last bucket carries the residue and is excluded.
            assertApproxEqRel(w[k] * 1e18 / w[k - 1], tiltX18, 1e10, "ratio of consecutive weights is the tilt");
        }
    }

    function testFuzz_splitIsExact(uint256 amount, uint256 tiltSeed, uint8 nSeed) public view {
        uint256 tiltX18 = bound(tiltSeed, LadderLib.MIN_TILT_X18, LadderLib.MAX_TILT_X18);
        uint8 n = uint8(bound(uint256(nSeed), LadderLib.MIN_BUCKETS, LadderLib.MAX_BUCKETS));
        amount = bound(amount, 0, 1e40);

        uint256[] memory w = ladder.weights(tiltX18, n);
        uint256[] memory out = ladder.split(amount, w);

        uint256 sum;
        for (uint256 k = 0; k < out.length; ++k) {
            sum += out[k];
        }
        assertEq(sum, amount, "split leaves no dust");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Geometry
    // -------------------------------------------------------------------------------------------------------------

    function testFuzz_bucketsAreContiguousAlignedAndOrdered(
        int24 anchorSeed,
        int24 spacingSeed,
        uint8 nSeed,
        bool above
    ) public view {
        Ladder memory l;
        (l.anchor, l.spacing) = _boundAnchor(anchorSeed, spacingSeed);
        l.n = uint8(bound(uint256(nSeed), LadderLib.MIN_BUCKETS, LadderLib.MAX_BUCKETS));
        l.above = above;
        l.width = ladder.doublingTicks(l.spacing);
        l.base = price.alignTick(l.anchor, l.spacing, above);

        (int24 firstLower, int24 firstUpper) = ladder.bucketBounds(l.anchor, l.spacing, 0, above);
        if (above) {
            assertEq(firstLower, l.base, "the ask ladder starts at the aligned anchor");
        } else {
            assertEq(firstUpper, l.base, "the bid ladder ends at the aligned anchor");
        }

        int24 previousLower = firstLower;
        int24 previousUpper = firstUpper;
        for (uint8 k = 1; k < l.n; ++k) {
            (int24 lower, int24 upper) = ladder.bucketBounds(l.anchor, l.spacing, k, above);
            _assertBucketShape(l, lower, upper);
            if (above) {
                assertEq(lower, previousUpper, "contiguous, and therefore non-overlapping");
            } else {
                assertEq(upper, previousLower, "contiguous, and therefore non-overlapping");
            }
            previousLower = lower;
            previousUpper = upper;
        }
    }

    function _assertBucketShape(Ladder memory l, int24 lower, int24 upper) internal pure {
        assertEq(lower % l.spacing, int24(0), "lower aligned to the spacing");
        assertEq(upper % l.spacing, int24(0), "upper aligned to the spacing");
        assertEq(upper - lower, l.width, "exactly one doubling wide");
        assertGe(lower, TickMath.minUsableTick(l.spacing), "inside the usable range");
        assertLe(upper, TickMath.maxUsableTick(l.spacing), "inside the usable range");
        if (l.above) {
            assertGe(lower, l.base, "no ask bucket is ever placed below the anchor");
        } else {
            assertLe(upper, l.base, "no bid bucket is ever placed above the anchor");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Amount <-> liquidity
    // -------------------------------------------------------------------------------------------------------------

    /// @dev amount0 -> liquidity -> amount0 never overstates, and the shortfall is bounded by v4's own precision:
    ///      one liquidity unit of AMPS plus the `sqrtLower * sqrtUpper / 2**96` truncation, i.e. `amount0 / I`.
    function testFuzz_amount0RoundTrip(int24 anchorSeed, int24 spacingSeed, uint8 kSeed, uint256 amountSeed)
        public
        view
    {
        (uint160 sqrtLower, uint160 sqrtUpper) = _boundedBucket(anchorSeed, spacingSeed, kSeed, true);
        uint256 amount0 = bound(amountSeed, 1e12, 1e27);

        uint128 liquidity = ladder.liquidityForAmount0Above(sqrtLower, sqrtUpper, amount0);
        uint256 back = ladder.amount0ForLiquidity(sqrtLower, sqrtUpper, liquidity);

        uint256 intermediate = FullMath.mulDiv(sqrtLower, sqrtUpper, Q96);
        assertGt(intermediate, 0, "the bounded anchor keeps v4's intermediate away from zero");
        uint256 perUnit = ladder.amount0ForLiquidity(sqrtLower, sqrtUpper, 1);

        assertLe(back, amount0, "a position never claims more AMPS than the vault handed it");
        assertLe(amount0 - back, amount0 / intermediate + perUnit + 4, "shortfall is v4's own rounding, no more");
    }

    /// @dev liquidity -> amount0 -> liquidity never inflates the position.
    function testFuzz_liquidity0RoundTrip(int24 anchorSeed, int24 spacingSeed, uint8 kSeed, uint256 liquiditySeed)
        public
        view
    {
        (uint160 sqrtLower, uint160 sqrtUpper) = _boundedBucket(anchorSeed, spacingSeed, kSeed, true);
        uint128 liquidity = uint128(bound(liquiditySeed, 1, 1e30));

        uint256 amount0 = ladder.amount0ForLiquidity(sqrtLower, sqrtUpper, liquidity);
        uint128 back = ladder.liquidityForAmount0Above(sqrtLower, sqrtUpper, amount0);

        uint256 intermediate = FullMath.mulDiv(sqrtLower, sqrtUpper, Q96);
        uint256 delta = uint256(sqrtUpper) - uint256(sqrtLower);

        assertLe(back, liquidity, "never inflates the position");
        assertLe(
            uint256(liquidity) - uint256(back),
            uint256(liquidity) / intermediate + (2 * intermediate) / delta + 3,
            "within one AMPS-wei of liquidity"
        );
    }

    /// @dev amount1 -> liquidity -> amount1 is tight: the only loss is the sub-unit remainder of one liquidity unit.
    function testFuzz_amount1RoundTrip(int24 anchorSeed, int24 spacingSeed, uint8 kSeed, uint256 amountSeed)
        public
        view
    {
        (uint160 sqrtLower, uint160 sqrtUpper) = _boundedBucket(anchorSeed, spacingSeed, kSeed, false);
        uint256 amount1 = bound(amountSeed, 1e12, 1e27);

        uint128 liquidity = ladder.liquidityForAmount1Below(sqrtLower, sqrtUpper, amount1);
        uint256 back = ladder.amount1ForLiquidity(sqrtLower, sqrtUpper, liquidity);
        uint256 perUnit = ladder.amount1ForLiquidity(sqrtLower, sqrtUpper, 1);

        assertLe(back, amount1, "a position never claims more counter asset than the vault handed it");
        assertLe(amount1 - back, perUnit + 2, "within one liquidity unit");
    }

    /// @dev liquidity -> amount1 -> liquidity never inflates the position.
    function testFuzz_liquidity1RoundTrip(int24 anchorSeed, int24 spacingSeed, uint8 kSeed, uint256 liquiditySeed)
        public
        view
    {
        (uint160 sqrtLower, uint160 sqrtUpper) = _boundedBucket(anchorSeed, spacingSeed, kSeed, false);
        uint128 liquidity = uint128(bound(liquiditySeed, 1, 1e30));

        uint256 amount1 = ladder.amount1ForLiquidity(sqrtLower, sqrtUpper, liquidity);
        uint128 back = ladder.liquidityForAmount1Below(sqrtLower, sqrtUpper, amount1);
        uint256 delta = uint256(sqrtUpper) - uint256(sqrtLower);

        assertLe(back, liquidity, "never inflates the position");
        assertLe(uint256(liquidity) - uint256(back), Q96 / delta + 1, "within one counter-asset wei of liquidity");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The whole ladder
    // -------------------------------------------------------------------------------------------------------------

    /// @dev I9 and I34 together: the ladder is one-sided about its anchor, its buckets are contiguous doublings, and
    ///      what is actually placed is the geometric split minus v4's rounding dust — never more than the inventory.
    function testFuzz_ladderPlacesTheWholeInventoryOneSided(
        int24 anchorSeed,
        int24 spacingSeed,
        uint8 nSeed,
        uint256 tiltSeed,
        uint256 inventorySeed,
        bool above
    ) public view {
        Ladder memory l;
        (l.anchor, l.spacing) = _boundAnchor(anchorSeed, spacingSeed);
        l.n = uint8(bound(uint256(nSeed), LadderLib.MIN_BUCKETS, LadderLib.MAX_BUCKETS));
        l.tiltX18 = bound(tiltSeed, LadderLib.MIN_TILT_X18, LadderLib.MAX_TILT_X18);
        l.inventory = bound(inventorySeed, 1e12, 1e27);
        l.above = above;
        l.width = ladder.doublingTicks(l.spacing);
        l.base = price.alignTick(l.anchor, l.spacing, above);

        (int24[] memory lowers, int24[] memory uppers, uint128[] memory liquidities) =
            ladder.ladderAmounts(l.anchor, l.spacing, l.n, l.tiltX18, l.inventory, above);

        assertEq(lowers.length, l.n, "one bucket per rung");
        uint256 placedTotal;
        uint256 previous;
        for (uint256 k = 0; k < l.n; ++k) {
            assertLt(lowers[k], uppers[k], "no degenerate bucket survives");
            _assertBucketShape(l, lowers[k], uppers[k]);

            uint256 placed = _placed(l, lowers[k], uppers[k], liquidities[k]);
            placedTotal += placed;

            // Weights always run with price: rising with `k` for asks, falling with `k` for bids.
            if (k > 0) {
                if (above) {
                    assertGe(placed + placed / 1000 + 2, previous, "ask buckets grow with price");
                } else {
                    assertLe(placed, previous + previous / 1000 + 2, "bid buckets thin out as the price falls");
                }
            }
            previous = placed;
        }

        assertLe(placedTotal, l.inventory, "the ladder never places more than the vault holds");
    }

    function _placed(Ladder memory l, int24 lower, int24 upper, uint128 liquidity) internal view returns (uint256) {
        uint160 sqrtLower = price.tickToSqrtPriceX96(lower);
        uint160 sqrtUpper = price.tickToSqrtPriceX96(upper);
        return l.above
            ? ladder.amount0ForLiquidity(sqrtLower, sqrtUpper, liquidity)
            : ladder.amount1ForLiquidity(sqrtLower, sqrtUpper, liquidity);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    function _boundAnchor(int24 anchorSeed, int24 spacingSeed) internal pure returns (int24 anchor, int24 spacing) {
        anchor = int24(bound(int256(anchorSeed), MIN_ANCHOR, MAX_ANCHOR));
        spacing = int24(bound(int256(spacingSeed), 1, MAX_SPACING));
    }

    /// @dev A real ladder bucket, turned into the sqrt prices the liquidity maths consumes.
    function _boundedBucket(int24 anchorSeed, int24 spacingSeed, uint8 kSeed, bool above)
        internal
        view
        returns (uint160 sqrtLower, uint160 sqrtUpper)
    {
        (int24 anchor, int24 spacing) = _boundAnchor(anchorSeed, spacingSeed);
        uint8 k = uint8(bound(uint256(kSeed), 0, LadderLib.MAX_BUCKETS - 1));
        (int24 lower, int24 upper) = ladder.bucketBounds(anchor, spacing, k, above);
        sqrtLower = price.tickToSqrtPriceX96(lower);
        sqrtUpper = price.tickToSqrtPriceX96(upper);
    }
}
