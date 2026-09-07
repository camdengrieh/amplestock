// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title QuoterSwapLib
/// @notice A bounded, `view`-only exact-input swap simulation for `AmpsQuoter`, run against the PoolManager's
///         published state rather than against a real swap.
///
/// @dev **Why this exists.** `IAmpsQuoter.quoteRotation` returns an `amountOut`, and the only two ways to produce
///      one are to execute the swap (`V4Quoter` does that, and it is not a `view`) or to walk the curve. A quoter
///      that a router calls blindly cannot take the PoolManager's lock, so it walks.
///
/// @dev **Licensing.** Every number below comes from MIT v4-core: `SwapMath.computeSwapStep` and
///      `SwapMath.getSqrtPriceTarget` for the step, `TickMath` for the tick/price map, `TickBitmap.compress` and
///      `TickBitmap.position` plus `BitMath` for the bitmap search, `LiquidityMath.addDelta` for the crossing and
///      `ProtocolFeeLibrary.calculateSwapFee` for the fee composition. The pool's stored state is read through
///      our own MIT `PoolStateLib`. Nothing here imports, copies or ports `Pool.sol`, `Position.sol`,
///      `StateLibrary` or `TransientStateLibrary`, all of which are BUSL-1.1 or reach it.
///
/// @dev **Bounded by construction.** The walk stops after `maxSteps` tick words even if the input is not consumed,
///      and reports that as `complete == false` so the caller degrades the quote instead of publishing a number it
///      did not finish computing. Each iteration performs at most two `extsload`s (one bitmap word, one tick word),
///      so the whole simulation is `O(maxSteps)` and the caller's gas cap is a hard ceiling on it.
///
/// @dev **Exactness.** The step arithmetic, the ordering of the tick shift and the `zeroForOne ? tickNext - 1`
///      convention reproduce what the PoolManager does to `slot0`, which is what makes a quote comparable to a
///      real swap to the wei. What the library deliberately does **not** model, because it cannot change the
///      swapper's amounts, is fee-growth accounting and the protocol-fee split of a step's fee: only the *total*
///      swap fee in pips reaches the swapper, and that is composed here exactly as the pool composes it.
library QuoterSwapLib {
    /// @notice The outcome of one simulated exact-input swap.
    /// @param amountOut Output in the counter currency's raw units.
    /// @param amountIn Input actually consumed, fee included. Equals the requested amount when `complete`.
    /// @param sqrtPriceX96 The pool's sqrt price after the swap.
    /// @param tick The pool's tick after the swap, with v4's `zeroForOne` decrement applied.
    /// @param liquidity The in-range liquidity after the swap.
    /// @param complete Whether the whole input was consumed inside `maxSteps` without hitting the price limit.
    /// @param initialized Whether the pool has a non-zero sqrt price at all.
    struct Result {
        uint256 amountOut;
        uint256 amountIn;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        bool complete;
        bool initialized;
    }

    /// @notice Everything one simulation needs, in memory, because seven arguments plus a tick walk does not fit
    ///         on the EVM stack under the legacy pipeline.
    /// @param manager The PoolManager, read through `IExtsload`.
    /// @param id The pool.
    /// @param tickSpacing The pool's tick spacing.
    /// @param zeroForOne True to sell currency0 (AMPS) for currency1.
    /// @param amountIn The input amount, in the input currency's raw units.
    /// @param lpFeePips The LP fee the hook would override for this swap, in pips, without the override flag.
    /// @param maxSteps The tick-walk bound.
    struct Params {
        IExtsload manager;
        PoolId id;
        int24 tickSpacing;
        bool zeroForOne;
        uint256 amountIn;
        uint24 lpFeePips;
        uint256 maxSteps;
    }

    /// @dev The walk's own scratch state, kept in memory for the same reason as {Params}.
    struct Cache {
        uint160 sqrtPriceLimitX96;
        uint24 swapFee;
        int256 remaining;
        uint256 steps;
    }

    /// @notice Simulates an exact-input swap of `p.amountIn` at a total swap fee of `p.lpFeePips`.
    /// @dev Reverts only if the PoolManager itself reverts or answers with something undecodable; `AmpsQuoter`
    ///      calls it behind a gas-capped `try`, which is what keeps `IAmpsQuoter`'s never-reverts promise.
    /// @param p The simulation inputs.
    /// @return result The simulation.
    function exactInput(Params memory p) internal view returns (Result memory result) {
        Cache memory cache;
        {
            uint24 protocolFeePacked;
            (result.sqrtPriceX96, result.tick, protocolFeePacked,) = PoolStateLib.slot0(p.manager, p.id);
            result.initialized = result.sqrtPriceX96 != 0;
            if (!result.initialized || p.tickSpacing <= 0) return result;

            // An exact-input amount larger than `int128` can never be swapped: the PoolManager casts the delta to
            // `int128` and reverts. Report it as an unfinished walk, not as a swap that would work.
            if (p.amountIn > uint256(uint128(type(int128).max))) return result;
            result.complete = true;
            if (p.amountIn == 0 || p.lpFeePips > SwapMath.MAX_SWAP_FEE) return result;

            // The swapper pays `lpFee` composed with the directional protocol fee, as `Pool.swap` composes it.
            uint16 protocolFee = p.zeroForOne
                ? ProtocolFeeLibrary.getZeroForOneFee(protocolFeePacked)
                : ProtocolFeeLibrary.getOneForZeroFee(protocolFeePacked);
            cache.swapFee =
                protocolFee == 0 ? p.lpFeePips : ProtocolFeeLibrary.calculateSwapFee(protocolFee, p.lpFeePips);
            if (cache.swapFee > SwapMath.MAX_SWAP_FEE) return result;
        }

        result.liquidity = PoolStateLib.liquidity(p.manager, p.id);
        cache.sqrtPriceLimitX96 = p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        cache.remaining = -int256(p.amountIn);

        while (cache.remaining != 0 && result.sqrtPriceX96 != cache.sqrtPriceLimitX96) {
            if (cache.steps == p.maxSteps) {
                result.complete = false;
                break;
            }
            unchecked {
                ++cache.steps;
            }
            _step(p, result, cache);
        }

        // Reaching the price limit with input left over is not a completed swap either: the real pool would return
        // a smaller delta than the caller asked for, and a router must not be told otherwise.
        if (cache.remaining != 0) result.complete = false;
    }

    /// @dev One tick-word step of the walk, mutating `result` and `cache` in place.
    function _step(Params memory p, Result memory result, Cache memory cache) private view {
        uint160 startSqrtPriceX96 = result.sqrtPriceX96;
        (int24 tickNext, bool initialized) =
            nextInitializedTick(p.manager, p.id, result.tick, p.tickSpacing, p.zeroForOne);
        if (tickNext <= TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
        if (tickNext >= TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;
        uint160 sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(tickNext);

        {
            (uint160 sqrtPriceAfterX96, uint256 stepIn, uint256 stepOut, uint256 stepFee) = SwapMath.computeSwapStep(
                result.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(p.zeroForOne, sqrtPriceNextX96, cache.sqrtPriceLimitX96),
                result.liquidity,
                cache.remaining,
                cache.swapFee
            );
            result.sqrtPriceX96 = sqrtPriceAfterX96;
            unchecked {
                // `SwapMath` guarantees `stepIn + stepFee <= -remaining` for an exact-input step.
                cache.remaining += int256(stepIn + stepFee);
                result.amountIn += stepIn + stepFee;
            }
            result.amountOut += stepOut;
        }

        if (result.sqrtPriceX96 == sqrtPriceNextX96) {
            if (initialized) {
                (, int128 liquidityNet) = PoolStateLib.tickLiquidity(p.manager, p.id, tickNext);
                unchecked {
                    if (p.zeroForOne) liquidityNet = -liquidityNet;
                }
                result.liquidity = LiquidityMath.addDelta(result.liquidity, liquidityNet);
            }
            unchecked {
                result.tick = p.zeroForOne ? tickNext - 1 : tickNext;
            }
        } else if (result.sqrtPriceX96 != startSqrtPriceX96) {
            result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
        }
    }

    /// @notice The next initialised tick at or beyond `tick` within one bitmap word, read by `extsload`.
    /// @dev The search itself is v4-core's MIT `TickBitmap.nextInitializedTickWithinOneWord`, re-expressed against
    ///      a word fetched through {PoolStateLib-tickBitmap} because this contract has no storage mapping to hand
    ///      it. `compress` and `position` are called on the MIT library rather than restated.
    /// @param manager The PoolManager.
    /// @param id The pool.
    /// @param tick The tick to search from.
    /// @param tickSpacing The pool's tick spacing.
    /// @param lte True to search left (a `zeroForOne` swap), false to search right.
    /// @return next The next initialised tick, or the word boundary when the word holds none.
    /// @return initialized Whether `next` is initialised.
    function nextInitializedTick(IExtsload manager, PoolId id, int24 tick, int24 tickSpacing, bool lte)
        internal
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, tickSpacing);
            if (lte) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 masked = PoolStateLib.tickBitmap(manager, id, wordPos)
                    & (type(uint256).max >> (uint256(type(uint8).max) - bitPos));
                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
                uint256 masked = PoolStateLib.tickBitmap(manager, id, wordPos) & ~((1 << bitPos) - 1);
                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }
}
