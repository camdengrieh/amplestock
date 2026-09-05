// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PriceLib} from "./PriceLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title LadderLib
/// @notice The static ask and bid ladders. Amplestocks never re-centres or re-widens a position: inventory is placed
///         once as a geometric series of one-sided range orders and is consumed bottom-up by buyers and arbitrage.
///
/// @dev **Geometry.** A bucket is one price doubling wide. One doubling is `ln(2) / ln(1.0001) = 6931.8184...` ticks;
///      `TICKS_PER_DOUBLING` is that value rounded up to `6932`, and `doublingTicks` rounds it further up to a whole
///      number of tick spacings so that every boundary is placeable. Rounding up means a bucket covers slightly more
///      than a doubling (2.0014x at `tickSpacing == 10`), which is the protocol-favourable direction: ask boundaries
///      sit at or above the nominal price, never below it.
///
/// @dev **Sidedness.** AMPS is `currency0` in all 32 pools, so an ask (AMPS out) is a `currency0`-only range strictly
///      **above** the current tick and a bid (stock / WETH / USDG out) is a `currency1`-only range strictly **below**
///      it. `above` selects between the two everywhere in this library; there is no other ordering branch.
///
/// @dev **Weights.** Bucket weights are `tilt^k / sum_j tilt^j` and always increase with **price**: for an ask ladder
///      that is increasing in `k` (most inventory is raised high, so backing per AMPS climbs with price); for a bid
///      ladder the price falls with `k`, so `ladderAmounts` applies the same weights in reverse and the bucket
///      adjacent to the anchor holds the largest share — matching "four halvings below $1 weighted 1.25x toward $1".
///
/// @dev **Rounding.** Weight and split residues land in the last element so the sums are exact (`sum w == 1e18`,
///      `sum split == amount`). Every amount/liquidity conversion rounds **down**, so a placed position never claims
///      more inventory than the vault holds and a valuation never overstates what a position contains.
library LadderLib {
    /// @notice Scale of the fixed-point weights returned by `weights` (`1e18 == 100%`).
    uint256 internal constant WAD = 1e18;

    /// @notice `ceil(ln(2) / ln(1.0001)) == ceil(6931.8184) == 6932`: ticks spanned by one price doubling.
    int24 internal constant TICKS_PER_DOUBLING = 6932;

    /// @notice Lower bound of `ladderTilt` (flat ladder).
    uint256 internal constant MIN_TILT_X18 = 1e18;

    /// @notice Upper bound of `ladderTilt`.
    uint256 internal constant MAX_TILT_X18 = 1.5e18;

    /// @notice Fewest buckets in a ladder (the `seedHalvings` / `bondBidHalvings` band starts at 2).
    uint8 internal constant MIN_BUCKETS = 2;

    /// @notice Most buckets in a ladder (the `ladderDoublings` band ends at 14).
    uint8 internal constant MAX_BUCKETS = 14;

    /// @dev `tiltX18` outside `[MIN_TILT_X18, MAX_TILT_X18]`.
    error TiltOutOfRange(uint256 tiltX18);

    /// @dev Bucket count outside `[MIN_BUCKETS, MAX_BUCKETS]`.
    error BucketCountOutOfRange(uint8 n);

    /// @dev Bucket index at or above `MAX_BUCKETS`.
    error BucketIndexOutOfRange(uint8 k);

    /// @dev The weight vector handed to `split` does not sum to exactly `WAD`.
    error WeightsNotNormalised(uint256 sumX18);

    /// @dev `split` was given an empty weight vector.
    error EmptyWeights();

    /// @dev A liquidity conversion was given a range with `sqrtLower >= sqrtUpper`.
    error EmptyRange(uint160 sqrtLower, uint160 sqrtUpper);

    /// @dev A ladder bucket collapsed against `TickMath`'s usable range: the ladder does not fit above (or below)
    ///      this anchor. The caller must move the anchor or shorten the ladder rather than silently place less.
    error DegenerateBucket(uint8 k);

    // -------------------------------------------------------------------------------------------------------------
    // Geometry
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Ticks per ladder bucket for a given spacing: one doubling, rounded **up** to a whole spacing.
    /// @dev Rounding up widens each bucket marginally (e.g. 6940 ticks = 2.0014x at `tickSpacing == 10`), so a
    ///      ten-bucket ask ladder spans a little more than 1024x. When `tickSpacing > TICKS_PER_DOUBLING` a bucket is
    ///      exactly one spacing wide, which is the narrowest placeable range.
    /// @param tickSpacing The pool's tick spacing, in `[1, TickMath.MAX_TICK_SPACING]`.
    /// @return width The bucket width in ticks, a positive multiple of `tickSpacing`.
    function doublingTicks(int24 tickSpacing) internal pure returns (int24 width) {
        if (tickSpacing <= 0 || tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert PriceLib.InvalidTickSpacing(tickSpacing);
        }
        // Ceiling division of two positive int24 values; the product is at most 6932 rounded up to 32767, which fits
        // comfortably in int24, so no intermediate can overflow.
        int24 buckets = (TICKS_PER_DOUBLING + tickSpacing - 1) / tickSpacing;
        width = buckets * tickSpacing;
    }

    /// @notice Bounds of ladder bucket `k`, measured from `anchorTick`.
    /// @dev For `above == true` bucket `k` covers prices `[anchor * 2**k, anchor * 2**(k+1))`, i.e. ticks
    ///      `[base + k*D, base + (k+1)*D)` with `base` the anchor aligned **up** and `D == doublingTicks`. For
    ///      `above == false` the buckets are halvings: bucket `k` covers ticks `[base - (k+1)*D, base - k*D)` with
    ///      `base` the anchor aligned **down**. Aligning the anchor away from the current price in both directions is
    ///      the protocol-favourable choice: asks start no lower than the anchor, bids start no higher.
    /// @dev Buckets are contiguous and non-overlapping by construction (`upper_k == lower_{k+1}` above,
    ///      `lower_k == upper_{k+1}` below) and both bounds are clamped into the usable tick range for the spacing.
    ///      A clamp can collapse a bucket to zero width at the extremes; `ladderAmounts` rejects that rather than
    ///      placing an empty position.
    /// @param anchorTick The ladder anchor, in `[TickMath.MIN_TICK, TickMath.MAX_TICK]`.
    /// @param tickSpacing The pool's tick spacing.
    /// @param k The bucket index, `< MAX_BUCKETS`.
    /// @param above True for the ask ladder (doublings above the anchor), false for the bid ladder (halvings below).
    /// @return lower The bucket's lower tick, aligned and clamped.
    /// @return upper The bucket's upper tick, aligned and clamped.
    function bucketBounds(int24 anchorTick, int24 tickSpacing, uint8 k, bool above)
        internal
        pure
        returns (int24 lower, int24 upper)
    {
        if (k >= MAX_BUCKETS) revert BucketIndexOutOfRange(k);

        int24 width = doublingTicks(tickSpacing);
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        // int256 arithmetic: `base` is at most 887272 in magnitude and `(k+1)*width` at most 14*32767 = 458738, so
        // the sum cannot leave int24 range either, but the wider type makes that independent of the constants.
        if (above) {
            int256 base = int256(PriceLib.alignTick(anchorTick, tickSpacing, true));
            lower = _clamp(base + int256(uint256(k)) * int256(width), minUsable, maxUsable);
            upper = _clamp(base + int256(uint256(k) + 1) * int256(width), minUsable, maxUsable);
        } else {
            int256 base = int256(PriceLib.alignTick(anchorTick, tickSpacing, false));
            upper = _clamp(base - int256(uint256(k)) * int256(width), minUsable, maxUsable);
            lower = _clamp(base - int256(uint256(k) + 1) * int256(width), minUsable, maxUsable);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Weights and splitting
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The geometric bucket weights `w_k = tilt^k / sum_j tilt^j`, in 1e18 fixed point.
    /// @dev The powers are accumulated in 1e18 fixed point (`p_0 = 1e18`, `p_{k+1} = p_k * tilt / 1e18`), the shares
    ///      are floored, and the whole rounding residue is added to the last element so that `sum w == 1e18`
    ///      **exactly**. Because `tilt >= 1e18` the result is monotonically non-decreasing in `k`.
    /// @dev Rounds **down** for every element except the last, which absorbs the residue.
    /// @param tiltX18 The ladder tilt in 1e18 fixed point, in `[MIN_TILT_X18, MAX_TILT_X18]` (1.25e18 at launch).
    /// @param n The number of buckets, in `[MIN_BUCKETS, MAX_BUCKETS]`.
    /// @return wX18 The weights, `wX18.length == n`, summing to exactly `WAD`.
    function weights(uint256 tiltX18, uint8 n) internal pure returns (uint256[] memory wX18) {
        if (tiltX18 < MIN_TILT_X18 || tiltX18 > MAX_TILT_X18) revert TiltOutOfRange(tiltX18);
        if (n < MIN_BUCKETS || n > MAX_BUCKETS) revert BucketCountOutOfRange(n);

        uint256 count = uint256(n);
        uint256[] memory powers = new uint256[](count);
        uint256 sum;
        uint256 power = WAD;
        for (uint256 k = 0; k < count; ++k) {
            powers[k] = power;
            sum += power;
            // `tilt <= 1.5e18` and `n <= 14`, so `power <= 1.5**13 * 1e18 < 2e20` and `sum < 1.2e21`: no overflow.
            power = power * tiltX18 / WAD;
        }

        wX18 = new uint256[](count);
        uint256 allocated;
        for (uint256 k = 0; k + 1 < count; ++k) {
            uint256 w = powers[k] * WAD / sum;
            wX18[k] = w;
            allocated += w;
        }
        // Each floored share is at most its exact value, so `allocated <= WAD` and the residue is non-negative.
        wX18[count - 1] = WAD - allocated;
    }

    /// @notice Splits `amount` across buckets by `wX18`, exactly.
    /// @dev Every element but the last is `floor(amount * w_k / 1e18)`; the last takes the remainder, so
    ///      `sum(out) == amount` with no dust left behind. Requires `sum(wX18) == WAD`.
    /// @dev Rounds **down** for every element except the last, which absorbs the residue.
    /// @param amount The total to distribute (AMPS for an ask ladder, counter asset for a bid ladder).
    /// @param wX18 Normalised weights, as returned by `weights`.
    /// @return out The per-bucket amounts, `out.length == wX18.length`, summing to exactly `amount`.
    function split(uint256 amount, uint256[] memory wX18) internal pure returns (uint256[] memory out) {
        uint256 count = wX18.length;
        if (count == 0) revert EmptyWeights();

        uint256 sumX18;
        for (uint256 k = 0; k < count; ++k) {
            sumX18 += wX18[k];
        }
        if (sumX18 != WAD) revert WeightsNotNormalised(sumX18);

        out = new uint256[](count);
        uint256 allocated;
        for (uint256 k = 0; k + 1 < count; ++k) {
            uint256 part = FullMath.mulDiv(amount, wX18[k], WAD);
            out[k] = part;
            allocated += part;
        }
        // `sum floor(amount * w_k / WAD) <= amount * sum(w_k) / WAD == amount`, so the remainder cannot underflow.
        out[count - 1] = amount - allocated;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Amount <-> liquidity
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Liquidity for an AMPS-only (currency0) range that lies entirely **above** the current tick.
    /// @dev `L = amount0 * (sqrtLower * sqrtUpper / 2**96) / (sqrtUpper - sqrtLower)`, rounded **down** by
    ///      `LiquidityAmounts`, so the position never claims more AMPS than the vault handed it.
    /// @dev Returns 0 when the range is so wide, or the amount so small, that a single unit of liquidity would be
    ///      worth more than `amount0`. A zero-liquidity bucket must be treated by the caller as unplaced inventory
    ///      (v4 `modifyLiquidity` with zero liquidity moves nothing), never as a silent loss.
    /// @param sqrtLower The range's lower sqrt price. Must be strictly below `sqrtUpper`.
    /// @param sqrtUpper The range's upper sqrt price.
    /// @param amount0 The AMPS amount to place, in wei.
    /// @return liquidity The position liquidity, rounded down.
    function liquidityForAmount0Above(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtLower >= sqrtUpper) revert EmptyRange(sqrtLower, sqrtUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount0);
    }

    /// @notice Liquidity for a counter-asset-only (currency1) range that lies entirely **below** the current tick.
    /// @dev `L = amount1 * 2**96 / (sqrtUpper - sqrtLower)`, rounded **down** by `LiquidityAmounts`.
    /// @dev Returns 0 under the same conditions as `liquidityForAmount0Above`; the same caller rule applies.
    /// @param sqrtLower The range's lower sqrt price. Must be strictly below `sqrtUpper`.
    /// @param sqrtUpper The range's upper sqrt price.
    /// @param amount1 The counter-asset amount to place, in its own raw units.
    /// @return liquidity The position liquidity, rounded down.
    function liquidityForAmount1Below(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtLower >= sqrtUpper) revert EmptyRange(sqrtLower, sqrtUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount1);
    }

    /// @notice The AMPS (currency0) a fully-above range holds at a given liquidity.
    /// @dev Rounds **down** (`SqrtPriceMath.getAmount0Delta(..., false)`), so NAV never overstates a position.
    /// @param sqrtLower The range's lower sqrt price. Must be strictly below `sqrtUpper`.
    /// @param sqrtUpper The range's upper sqrt price.
    /// @param liquidity The position liquidity.
    /// @return amount0 The AMPS amount, rounded down.
    function amount0ForLiquidity(uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtLower >= sqrtUpper) revert EmptyRange(sqrtLower, sqrtUpper);
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
    }

    /// @notice The counter asset (currency1) a fully-below range holds at a given liquidity.
    /// @dev Rounds **down** (`SqrtPriceMath.getAmount1Delta(..., false)`), so NAV never overstates a position.
    /// @param sqrtLower The range's lower sqrt price. Must be strictly below `sqrtUpper`.
    /// @param sqrtUpper The range's upper sqrt price.
    /// @param liquidity The position liquidity.
    /// @return amount1 The counter-asset amount, rounded down.
    function amount1ForLiquidity(uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtLower >= sqrtUpper) revert EmptyRange(sqrtLower, sqrtUpper);
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The ladder
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Composes a whole ladder: bucket bounds, geometric weights, an exact split and the position liquidity.
    /// @dev Weights increase with price in both directions (see the library notes), so for `above == false` the
    ///      weight vector is applied in reverse and bucket 0 — the halving adjacent to the anchor — is the largest.
    ///      The split is exact, so `sum(amounts) == inventory`; what a bucket loses to liquidity rounding stays in
    ///      the vault as idle inventory rather than disappearing.
    /// @dev Reverts with `DegenerateBucket` if any bucket collapses against the usable tick range: a ladder that does
    ///      not fit must be re-anchored or shortened by the caller, never silently truncated.
    /// @param anchorTick The ladder anchor tick (`tickOf(P_ref / P_counter)` at placement time).
    /// @param tickSpacing The pool's tick spacing.
    /// @param n The number of buckets, in `[MIN_BUCKETS, MAX_BUCKETS]`.
    /// @param tiltX18 The ladder tilt, in `[MIN_TILT_X18, MAX_TILT_X18]`.
    /// @param inventory The total to place: AMPS wei when `above`, counter-asset raw units otherwise.
    /// @param above True for the ask ladder, false for the bid ladder.
    /// @return lowers Per-bucket lower ticks.
    /// @return uppers Per-bucket upper ticks.
    /// @return liquidities Per-bucket position liquidity, rounded down.
    function ladderAmounts(int24 anchorTick, int24 tickSpacing, uint8 n, uint256 tiltX18, uint256 inventory, bool above)
        internal
        pure
        returns (int24[] memory lowers, int24[] memory uppers, uint128[] memory liquidities)
    {
        uint256[] memory amounts = split(inventory, weights(tiltX18, n));

        uint256 count = uint256(n);
        lowers = new int24[](count);
        uppers = new int24[](count);
        liquidities = new uint128[](count);

        for (uint256 k = 0; k < count; ++k) {
            (int24 lower, int24 upper) = bucketBounds(anchorTick, tickSpacing, uint8(k), above);
            if (lower >= upper) revert DegenerateBucket(uint8(k));
            lowers[k] = lower;
            uppers[k] = upper;

            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
            // Ask buckets rise with `k`, bid buckets fall with `k`; the weight vector always runs with price.
            uint256 amount = above ? amounts[k] : amounts[count - 1 - k];
            liquidities[k] = above
                ? liquidityForAmount0Above(sqrtLower, sqrtUpper, amount)
                : liquidityForAmount1Below(sqrtLower, sqrtUpper, amount);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Clamps a wide-integer tick into `[lo, hi]` and narrows it to int24. Both bounds are already valid ticks,
    ///      so the cast is safe on every path.
    function _clamp(int256 value, int24 lo, int24 hi) private pure returns (int24) {
        if (value <= int256(lo)) return lo;
        if (value >= int256(hi)) return hi;
        return int24(value);
    }
}
