// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILadderPolicy} from "../interfaces/ILadderPolicy.sol";
import {LadderLib} from "../lib/LadderLib.sol";
import {PriceLib} from "../lib/PriceLib.sol";
import {Constants} from "../types/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title LadderPolicy
/// @notice The launch ladder shape: `n` contiguous price doublings from the anchor, bucket `k` holding
///         `tilt^k / SUM_j tilt^j` of the placement. Pure, stateless, holding no funds and propose-only, so the
///         7-day timelock can re-point the vault's `ladderPolicy()` at a different shape without touching custody,
///         the grid or a single existing position.
///
/// @dev **A governable wrapper over `LadderLib`, not a second implementation.** Every number this contract returns
///      comes out of `LadderLib` — `doublingTicks`, `bucketBounds`, `weights`, `split`,
///      `liquidityForAmount0Above`, `liquidityForAmount1Below` — and every band comes out of `Constants`. The
///      policy adds exactly three things the library deliberately does not have: the governed bucket-count bands
///      (`ladderDoublings` for asks, `seedHalvings`/`bondBidHalvings` for bids), the sidedness assertion against
///      `currentTick` (I9), and the canonical-grid extent check (I39). Anything else would be a place for the
///      library and the policy to disagree.
///
/// @dev **The shape**, for a request of `n` buckets at tilt `t` on a pool of spacing `s`:
///
///      ```
///      D        = LadderLib.doublingTicks(s)                     one doubling, rounded up to a whole spacing
///      base     = above ? alignUp(anchorTick, s) : alignDown(anchorTick, s)
///      bucket k = above ? [base + k*D, base + (k+1)*D)           asks: rising doublings
///                       : [base - (k+1)*D, base - k*D)           bids: falling halvings
///      w_k      = t^k / SUM_j t^j                                floored, residue into w_{n-1}, SUM == 1e18
///      amount_k = above ? split(inventory, w)[k] : split(inventory, w)[n-1-k]
///      L_k      = above ? liquidityForAmount0Above(...) : liquidityForAmount1Below(...)     rounded down
///      ```
///
///      The weight vector always runs **with price**: the largest ask sits highest and the largest bid sits nearest
///      the anchor, which is the plan's "four halvings below $1 weighted 1.25x toward $1". `SUM(amount_k)` is
///      exactly `inventory`; what a bucket loses converting an amount into liquidity stays with the vault as idle
///      inventory rather than disappearing, which is why `LadderBucket` carries both numbers.
///
/// @dev **The canonical grid** (`docs/phase3-state-model.md` §3.2, ruling 1). Every vault position lies on its
///      pool's doubling grid, cell `m` covering `[gridBaseTick + m*D, gridBaseTick + (m+1)*D)` for `m` in
///      `[Constants.GRID_MIN_M, Constants.GRID_MAX_M)`. A ladder built from a grid-snapped anchor **is** a run of
///      grid cells by construction, because the bucket width here and the cell width in
///      `LadderPositionValuer` are the same `LadderLib.doublingTicks(tickSpacing)`. `LadderRequest` carries no
///      `gridBaseTick`, so this contract cannot check absolute cell membership; it checks the half it can — that
///      `n` never exceeds the grid's extent on the requested side (16 cells above the origin, 8 below) — and
///      {cellIndex} exists so the vault, the valuer, the invariant handler and the dApp can do the absolute check
///      against one shared piece of arithmetic. The vault's `OffGrid` gauntlet step is the authority (I39).
///
/// @dev **It never truncates.** A bucket that collapses against `TickMath`'s usable range, a side that conflicts
///      with `currentTick`, a tilt or a bucket count outside its band and a zero inventory are all
///      {ILadderPolicy-LadderNotPlaceable}, never a shorter or emptier ladder than was asked for. A caller that
///      wants fewer buckets asks for fewer buckets.
///
/// @dev **A hostile policy cannot move an asset.** The vault re-derives every returned bucket's bounds, re-checks
///      sidedness, grid membership and `SUM(amounts) <= inventory`, and holds the placement to
///      `navPerShareAfter >= navPerShareBefore x (1 - 2 bp)`. The worst a broken pointer can do is refuse to
///      propose.
contract LadderPolicy is ILadderPolicy {
    /// @notice Identifier of this ladder shape. Returned by {version}.
    bytes32 internal constant VERSION_ID = "geometric-doubling-v1";

    /// @notice Cells the canonical grid has above its origin: `GRID_MAX_M`, so an ask ladder anchored at the origin
    ///         can never need more buckets than this without leaving the grid.
    int24 internal constant GRID_CELLS_ABOVE = Constants.GRID_MAX_M;

    /// @notice Cells the canonical grid has below its origin: `-GRID_MIN_M`, the bid side's equivalent.
    int24 internal constant GRID_CELLS_BELOW = -Constants.GRID_MIN_M;

    /// @inheritdoc ILadderPolicy
    function propose(LadderRequest calldata request) external pure returns (LadderBucket[] memory buckets) {
        _validate(request);

        uint256 n = uint256(request.buckets);
        uint256[] memory amounts =
            LadderLib.split(request.inventory, LadderLib.weights(uint256(request.tiltX18), request.buckets));

        buckets = new LadderBucket[](n);
        for (uint256 k = 0; k < n; ++k) {
            (int24 lower, int24 upper) =
                LadderLib.bucketBounds(request.anchorTick, request.tickSpacing, uint8(k), request.above);
            if (lower >= upper) revert LadderNotPlaceable("degenerateBucket");

            // Asks rise with `k` and bids fall with `k`, so the weight vector is applied in reverse for a bid
            // ladder: bucket 0, the halving adjacent to the anchor, is the largest. Same rule as
            // `LadderLib.ladderAmounts`, and asserted against it by `unit/LadderPolicy.t.sol`.
            uint256 amount = request.above ? amounts[k] : amounts[n - 1 - k];
            buckets[k] = LadderBucket({
                lowerTick: lower,
                upperTick: upper,
                amount: amount,
                liquidity: _liquidity(lower, upper, amount, request.above)
            });
        }

        _requireSidedness(buckets, request.currentTick, request.tickSpacing, request.above);
    }

    /// @inheritdoc ILadderPolicy
    function weights(uint64 tiltX18, uint8 buckets) external pure returns (uint256[] memory weightsX18) {
        weightsX18 = LadderLib.weights(uint256(tiltX18), buckets);
    }

    /// @inheritdoc ILadderPolicy
    function bucketBounds(int24 anchorTick, int24 tickSpacing, uint8 k, bool above)
        external
        pure
        returns (int24 lowerTick, int24 upperTick)
    {
        (lowerTick, upperTick) = LadderLib.bucketBounds(anchorTick, tickSpacing, k, above);
    }

    /// @inheritdoc ILadderPolicy
    function split(uint256 inventory, uint256[] calldata weightsX18) external pure returns (uint256[] memory amounts) {
        amounts = LadderLib.split(inventory, weightsX18);
    }

    /// @notice The canonical grid cell a bucket's lower bound sits in, and whether it is a placeable cell.
    /// @dev Not part of {ILadderPolicy}: it is the inverse of `LadderLib.bucketBounds` and the arithmetic behind
    ///      the vault's `OffGrid` check, `LadderPositionValuer`'s enumeration and the invariant handler's I39
    ///      assertion. Those three plus the dApp have to agree on one lattice, and until this function existed the
    ///      only public form of it was the forward direction. Returns `onGrid == false` — never a revert — for a
    ///      tick that is not a cell boundary and for a cell outside `[GRID_MIN_M, GRID_MAX_M)`, so a caller can use
    ///      it inside a `view` that must not fail.
    /// @param lowerTick The bucket's lower bound.
    /// @param gridBaseTick The pool's grid origin, from `IAmpsHook.gridBaseTick` / `PoolConfig.gridBaseTick`.
    /// @param tickSpacing The pool's tick spacing.
    /// @return m The cell index, `0` when the tick is not a cell boundary at all.
    /// @return onGrid True only when `lowerTick == gridBaseTick + m * doublingTicks(tickSpacing)` for an `m` inside
    ///         `[Constants.GRID_MIN_M, Constants.GRID_MAX_M)`.
    function cellIndex(int24 lowerTick, int24 gridBaseTick, int24 tickSpacing)
        external
        pure
        returns (int24 m, bool onGrid)
    {
        int256 width = int256(LadderLib.doublingTicks(tickSpacing));
        int256 offset = int256(lowerTick) - int256(gridBaseTick);
        // Not a cell boundary at all: the named returns already hold `(0, false)`.
        if (offset % width != 0) return (m, onGrid);

        // `|offset| <= 2 x TickMath.MAX_TICK` and `width >= 1`, so `index` is at most ~1.8e6 and fits `int24`.
        int256 index = offset / width;
        m = int24(index);
        onGrid = index >= Constants.GRID_MIN_M && index < Constants.GRID_MAX_M;
    }

    /// @inheritdoc ILadderPolicy
    function LADDER_TILT_X18_MIN() external pure returns (uint64 value) {
        value = Constants.LADDER_TILT_X18_MIN;
    }

    /// @inheritdoc ILadderPolicy
    function LADDER_TILT_X18_MAX() external pure returns (uint64 value) {
        value = Constants.LADDER_TILT_X18_MAX;
    }

    /// @inheritdoc ILadderPolicy
    function LADDER_DOUBLINGS_MIN() external pure returns (uint8 value) {
        value = Constants.LADDER_DOUBLINGS_MIN;
    }

    /// @inheritdoc ILadderPolicy
    function LADDER_DOUBLINGS_MAX() external pure returns (uint8 value) {
        value = Constants.LADDER_DOUBLINGS_MAX;
    }

    /// @inheritdoc ILadderPolicy
    function HALVINGS_MIN() external pure returns (uint8 value) {
        value = Constants.HALVINGS_MIN;
    }

    /// @inheritdoc ILadderPolicy
    function HALVINGS_MAX() external pure returns (uint8 value) {
        value = Constants.HALVINGS_MAX;
    }

    /// @inheritdoc ILadderPolicy
    function version() external pure returns (bytes32 id) {
        id = VERSION_ID;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Every band and range check, in one place, all of them surfacing as `LadderNotPlaceable` so the vault
    ///      sees one policy-level failure mode rather than four library-level ones. The tilt and bucket-count bands
    ///      are `Constants`' governed bands, which are tighter than `LadderLib`'s own `[MIN_BUCKETS, MAX_BUCKETS]`
    ///      on the ask side (`[6, 14]` against `[2, 14]`) and identical on the bid side (`[2, 8]`).
    function _validate(LadderRequest calldata request) private pure {
        if (request.inventory == 0) revert LadderNotPlaceable("inventory");
        if (request.tiltX18 < Constants.LADDER_TILT_X18_MIN || request.tiltX18 > Constants.LADDER_TILT_X18_MAX) {
            revert LadderNotPlaceable("tilt");
        }
        if (request.tickSpacing <= 0 || request.tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert LadderNotPlaceable("tickSpacing");
        }
        if (request.anchorTick < TickMath.MIN_TICK || request.anchorTick > TickMath.MAX_TICK) {
            revert LadderNotPlaceable("anchorTick");
        }
        if (request.currentTick < TickMath.MIN_TICK || request.currentTick > TickMath.MAX_TICK) {
            revert LadderNotPlaceable("currentTick");
        }

        int24 n = int24(uint24(request.buckets));
        if (request.above) {
            if (request.buckets < Constants.LADDER_DOUBLINGS_MIN || request.buckets > Constants.LADDER_DOUBLINGS_MAX) {
                revert LadderNotPlaceable("buckets");
            }
            if (n > GRID_CELLS_ABOVE) revert LadderNotPlaceable("gridOverflow");
        } else {
            if (request.buckets < Constants.HALVINGS_MIN || request.buckets > Constants.HALVINGS_MAX) {
                revert LadderNotPlaceable("buckets");
            }
            if (n > GRID_CELLS_BELOW) revert LadderNotPlaceable("gridOverflow");
        }
    }

    /// @dev I9, unconditionally: an ask ladder's lowest bucket starts at or above `alignUp(currentTick)` and a bid
    ///      ladder's highest bucket ends at or below `alignDown(currentTick)`. Bucket 0 is the extreme one in both
    ///      directions — asks rise with `k`, bids fall with `k` — so one comparison covers the whole ladder.
    ///      `docs/phase3-state-model.md` §8.2 states the rule in exactly this form; the vault re-checks it against
    ///      the live `slot0.tick` and reverts `WrongSide` rather than trusting this.
    ///
    ///      **The boundary case, stated once.** The comparison is `>=`, not `>`, so when `currentTick` is itself a
    ///      multiple of the spacing an ask may start exactly on it. That is what §8.2's rule permits and what
    ///      genesis needs: §3.3 anchors the entry ladders at the raw `sqrtPriceX96ToTick` of $1.00 and
    ///      `bucketBounds` aligns it **up**, so bucket 0 normally starts strictly above the pool's tick and lands
    ///      on it only when the raw tick happens to be spacing-aligned. In v4 a position whose `tickLower` equals
    ///      `slot0.tick` is two-sided, so a placement path that wants a strictly one-sided first bucket in that
    ///      case must move the anchor up one cell; this policy will not do it silently.
    function _requireSidedness(LadderBucket[] memory buckets, int24 currentTick, int24 tickSpacing, bool above)
        private
        pure
    {
        if (above) {
            if (buckets[0].lowerTick < PriceLib.alignTick(currentTick, tickSpacing, true)) {
                revert LadderNotPlaceable("askBelowTick");
            }
        } else {
            if (buckets[0].upperTick > PriceLib.alignTick(currentTick, tickSpacing, false)) {
                revert LadderNotPlaceable("bidAboveTick");
            }
        }
    }

    /// @dev The bucket's position liquidity, rounded **down** in both directions: an ask is `currency0`-only
    ///      (AMPS) above the tick and a bid is `currency1`-only (counter) below it, so exactly one of the two
    ///      conversions applies and there is no ordering branch anywhere else in this contract.
    function _liquidity(int24 lower, int24 upper, uint256 amount, bool above) private pure returns (uint128) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        return above
            ? LadderLib.liquidityForAmount0Above(sqrtLower, sqrtUpper, amount)
            : LadderLib.liquidityForAmount1Below(sqrtLower, sqrtUpper, amount);
    }
}
