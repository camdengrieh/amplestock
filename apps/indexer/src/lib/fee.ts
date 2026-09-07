// SPDX-License-Identifier: MIT

/**
 * Fee decoding for a v4 `Swap`, exactly as `docs/phase3-state-model.md` §1.4 charges it.
 *
 * **Direction.** AMPS is `currency0` in all 32 pools by construction, so `zeroForOne == true` is
 * unconditionally "AMPS in", i.e. a sell. The `Swap` event carries the *swapper's* deltas, so the
 * swapper paying currency0 (`amount0 < 0`) is exactly that sell. Nothing infers direction from the
 * sender, the router or the tick move.
 *
 * **Base fee.**
 *
 * ```
 * base = sell ? sellFeeBps : poolConfig.buyFeeBps
 * ```
 *
 * with `sellFeeBps` a hook-wide parameter (`HookParameterChanged("sellFeeBps", 0, …)`) and
 * `buyFeeBps` per pool (set at registration, moved by `HookParameterChanged("buyFeeBps", poolId, …)`
 * or `ConstituentReconfigured(id, "buyFeeBps", …)`).
 *
 * **Rotation credit.** An exact-input sell covered by a same-transaction credit pays a base
 * blended between the buy and sell fee:
 *
 * ```
 * c    = min(credit, amountIn)
 * base = buyFeeBps + ceil((sellFeeBps - buyFeeBps) * (amountIn - c) / amountIn)
 * ```
 *
 * The hook computes that itself and emits `RotationCreditConsumed(poolId, consumed, blendedFeeBps)`
 * from `beforeSwap` — which v4 calls *before* it swaps and emits, so the hook's log always has the
 * smaller log index in the same transaction. The indexer therefore never recomputes the blend: it
 * takes `blendedFeeBps` as the base and `consumed` as the credited amount, and only falls back to
 * the formula when reconstructing a swap in a test.
 *
 * **Dynamic part.** v4's `Swap.fee` is the total the pool actually charged, in pips, after the
 * hook's override. So `dynamic = fee/100 - base`, floored at zero, and that residual is
 * `f_vol + f_dev + f_div + f_session + surge` clamped to `[F_MIN_BPS, base + dynCapBps]`. The
 * components are not separable from the log alone — `SurgeArmed`, `MultiplierStepDetected` and
 * `GateCacheRefreshed` record the arming events that explain them, and are indexed alongside.
 */

import {BPS, PIPS_DENOMINATOR, PIPS_PER_BPS} from './constants'
import {mulDivUp} from './math'

export interface SwapFeeInput {
  /** The swapper's deltas exactly as v4 emitted them. */
  amount0: bigint
  amount1: bigint
  /** `Swap.fee`, in hundredths of a basis point. */
  feePips: number
  /** The hook's `sellFeeBps` in force at this block. */
  sellFeeBps: number
  /** The pool's `buyFeeBps` in force at this block. */
  buyFeeBps: number
  /** From a `RotationCreditConsumed` in the same transaction, for this pool. */
  credit?: {consumed: bigint; blendedFeeBps: number}
}

export interface SwapFee {
  sell: boolean
  /** Gross input in the input currency's own units, fee included. */
  amountIn: bigint
  amountOut: bigint
  /** AMPS wei moved, whichever side it was on. */
  ampsAmount: bigint
  /** Counter units moved, in the counter's own decimals. */
  counterAmount: bigint
  feePips: number
  feeBps: number
  baseFeeBps: number
  dynamicFeeBps: number
  creditedAmount: bigint
  credited: boolean
  /** `gross * feePips / 1e6`, rounded up, in the input currency's units. */
  feeAmount: bigint
  /** The fee in AMPS wei when this was a sell, else zero. */
  feeAmps: bigint
}

/** `true` when the swapper paid currency0, i.e. AMPS in, i.e. `zeroForOne`. */
export function isSell(amount0: bigint, amount1: bigint): boolean {
  if (amount0 !== 0n) return amount0 < 0n
  // Degenerate zero-amount0 swap: fall back to the other leg.
  return amount1 > 0n
}

/** The blend §1.4 applies when a rotation credit covers part of an exact-input sell. */
export function blendedBaseBps(
  sellFeeBps: number,
  buyFeeBps: number,
  amountIn: bigint,
  consumed: bigint,
): number {
  if (amountIn === 0n || consumed === 0n) return sellFeeBps
  if (sellFeeBps <= buyFeeBps) return buyFeeBps
  const c = consumed < amountIn ? consumed : amountIn
  const spread = BigInt(sellFeeBps - buyFeeBps)
  return buyFeeBps + Number(mulDivUp(spread, amountIn - c, amountIn))
}

export function decodeSwapFee(input: SwapFeeInput): SwapFee {
  const sell = isSell(input.amount0, input.amount1)
  const amountIn = sell ? -input.amount0 : -input.amount1
  const amountOut = sell ? input.amount1 : input.amount0
  const feeBps = Math.floor(input.feePips / Number(PIPS_PER_BPS))

  const credited = input.credit !== undefined && input.credit.consumed > 0n && sell
  const baseFeeBps = credited
    ? input.credit!.blendedFeeBps
    : sell
      ? input.sellFeeBps
      : input.buyFeeBps

  const dynamicFeeBps = Math.max(0, feeBps - baseFeeBps)
  const grossIn = amountIn > 0n ? amountIn : 0n
  const feeAmount = mulDivUp(grossIn, BigInt(input.feePips), PIPS_DENOMINATOR)

  return {
    sell,
    amountIn: grossIn,
    amountOut: amountOut > 0n ? amountOut : 0n,
    ampsAmount: sell ? grossIn : amountOut > 0n ? amountOut : 0n,
    counterAmount: sell ? (amountOut > 0n ? amountOut : 0n) : grossIn,
    feePips: input.feePips,
    feeBps,
    baseFeeBps,
    dynamicFeeBps,
    creditedAmount: credited ? input.credit!.consumed : 0n,
    credited,
    feeAmount,
    feeAmps: sell ? feeAmount : 0n,
  }
}

/** A fee in bps applied to a notional. Used for the buy-side USD fee, where the fee is in counter. */
export const feeOf = (notional: bigint, bps: number): bigint => (notional * BigInt(bps)) / BPS
