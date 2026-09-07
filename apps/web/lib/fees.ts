// SPDX-License-Identifier: MIT

/**
 * The fee arithmetic the dApp has to be able to reproduce exactly, because the number it shows a
 * user before they sign has to be the number the hook charges.
 *
 * The authority is `AmpsHook.beforeSwap` (`docs/phase3-state-model.md` §1.4) and
 * `AmpsQuoter.quoteRotation` (§6). Everything here is the same arithmetic in the same rounding
 * direction — integer, `bigint`, never floating point — so a mismatch against the on-chain quote
 * is a bug this module's tests can localise rather than a rounding excuse.
 */

import {BPS, F_MIN_BPS, PIPS_PER_BPS, TOTAL_FEE_BPS_MAX} from './protocol'

/** `ceil(a * b / d)`, the hook's `FullMath.mulDivRoundingUp`. */
export function mulDivRoundingUp(a: bigint, b: bigint, d: bigint): bigint {
  if (d === 0n) throw new Error('mulDivRoundingUp: division by zero')
  const product = a * b
  const quotient = product / d
  return product % d === 0n ? quotient : quotient + 1n
}

/**
 * The rotation-credit blend: the base fee, in bps, an **exact-input** sell of `amountIn` AMPS pays
 * when `credit` AMPS of same-transaction rotation credit is available.
 *
 * ```
 * c    = min(credit, amountIn)
 * base = buyFeeBps + ceilDiv((ampsFeeBps - buyFeeBps) * (amountIn - c), amountIn)
 * ```
 *
 * Rounded **up**, so a credit never rounds a fee down in the swapper's favour. Three consequences
 * the UI states plainly rather than burying:
 *
 * - a fully credited sell pays the *buy* fee of the pool it sells into, not zero;
 * - an uncredited sell pays `ampsFeeBps`;
 * - an **exact-output** sell consumes no credit at all and pays `ampsFeeBps` in full, which is why
 *   the router always builds hop 2 as `SWAP_EXACT_IN`.
 *
 * The credit lives in EIP-1153 transient storage: it exists only inside the transaction that
 * created it and can never be carried across transactions.
 */
export function blendedAmpsFeeBps(params: {
  ampsFeeBps: number
  buyFeeBps: number
  amountIn: bigint
  credit: bigint
}): number {
  const {ampsFeeBps, buyFeeBps, amountIn, credit} = params
  if (ampsFeeBps < buyFeeBps) {
    throw new Error('blendedAmpsFeeBps: ampsFeeBps < buyFeeBps is unreachable on chain (bands [100,600] vs [1,100])')
  }
  if (amountIn <= 0n) return ampsFeeBps
  const c = credit < amountIn ? credit : amountIn
  if (c <= 0n) return ampsFeeBps
  const delta = BigInt(ampsFeeBps - buyFeeBps)
  const blended = BigInt(buyFeeBps) + mulDivRoundingUp(delta, amountIn - c, amountIn)
  return Number(blended)
}

/** AMPS wei of credit an exact-input sell of `amountIn` would consume from `credit`. */
export function creditConsumed(amountIn: bigint, credit: bigint): bigint {
  if (amountIn <= 0n || credit <= 0n) return 0n
  return credit < amountIn ? credit : amountIn
}

/**
 * `fee = clamp(base + dyn, F_MIN_BPS, base + dynCapBps)`, then the absolute ceiling.
 *
 * `degraded` raises the *floor* of the dynamic part to `FROZEN_FEE_FLOOR_BPS` — a swap is never
 * reverted for a gate reason (I15), it is only made dearer.
 */
export function clampTotalFeeBps(params: {
  baseBps: number
  dynBps: number
  dynCapBps: number
  frozenFeeFloorBps?: number
  degraded?: boolean
}): number {
  const {baseBps, dynCapBps} = params
  const dyn = params.degraded ? Math.max(params.dynBps, params.frozenFeeFloorBps ?? 0) : params.dynBps
  const raw = baseBps + dyn
  const ceiling = baseBps + dynCapBps
  const clamped = Math.min(Math.max(raw, F_MIN_BPS), ceiling)
  return Math.min(clamped, TOTAL_FEE_BPS_MAX)
}

/** Pips are the unit the pool manager's fee override speaks: 1 bp = 100 pips. */
export function bpsToPips(bps: number): number {
  return bps * Number(PIPS_PER_BPS)
}

export function pipsToBps(pips: number): number {
  return pips / Number(PIPS_PER_BPS)
}

/** A fee in pips as a percentage string for display, e.g. `50000` -> `"5.00%"`. */
export function pipsToPercent(pips: number, fractionDigits = 2): string {
  return `${(pips / 10_000).toFixed(fractionDigits)}%`
}

/** The amount left after a fee quoted in pips is taken from it, rounded the pool's way (down). */
export function applyFeePips(amount: bigint, feePips: number): bigint {
  if (feePips <= 0) return amount
  const pips = BigInt(Math.round(feePips))
  return (amount * (1_000_000n - pips)) / 1_000_000n
}

/** The fee itself, in the input token's units. */
export function feeAmount(amount: bigint, feePips: number): bigint {
  return amount - applyFeePips(amount, feePips)
}

/**
 * The client-side mirror of `AmpsQuoter.quoteRotation`'s **fee** half.
 *
 * Amount-level pricing is `V4Quoter`'s job, off chain; this reproduces the two fee numbers, so the
 * UI can show the rotation saving before any node has answered and can flag a disagreement with
 * the on-chain quote instead of silently preferring one.
 */
export function rotationFeePips(params: {
  hop1BuyFeeBps: number
  hop2BuyFeeBps: number
  ampsFeeBps: number
  /** AMPS out of hop 1 — the credit hop 2 will consume. */
  ampsFromHop1: bigint
  /** AMPS into hop 2. Equal to `ampsFromHop1` for a pure rotation. */
  ampsIntoHop2: bigint
  hop1DynBps?: number
  hop2DynBps?: number
  hop1DynCapBps?: number
  hop2DynCapBps?: number
}): {hop1FeePips: number; hop2FeePips: number; hop2BaseBps: number; creditUsed: bigint} {
  const creditUsed = creditConsumed(params.ampsIntoHop2, params.ampsFromHop1)
  const hop2BaseBps = blendedAmpsFeeBps({
    ampsFeeBps: params.ampsFeeBps,
    buyFeeBps: params.hop2BuyFeeBps,
    amountIn: params.ampsIntoHop2,
    credit: params.ampsFromHop1,
  })
  const hop1TotalBps = clampTotalFeeBps({
    baseBps: params.hop1BuyFeeBps,
    dynBps: params.hop1DynBps ?? 0,
    dynCapBps: params.hop1DynCapBps ?? 0,
  })
  const hop2TotalBps = clampTotalFeeBps({
    baseBps: hop2BaseBps,
    dynBps: params.hop2DynBps ?? 0,
    dynCapBps: params.hop2DynCapBps ?? 0,
  })
  return {
    hop1FeePips: bpsToPips(hop1TotalBps),
    hop2FeePips: bpsToPips(hop2TotalBps),
    hop2BaseBps,
    creditUsed,
  }
}

/**
 * The creator slice of the sell fee at `timestamp`: `100 bp x max(0, 1 - (t - genesis) / 30 days)`,
 * monotone non-increasing and exactly zero from day 30. Immutable — there is no setter.
 */
export function creatorBpsAt(params: {genesisTimestamp: number; timestamp: number; feeBps?: number; decaySeconds?: number}): number {
  const feeBps = params.feeBps ?? 100
  const decay = params.decaySeconds ?? 30 * 86_400
  if (params.genesisTimestamp === 0) return 0
  const elapsed = params.timestamp - params.genesisTimestamp
  if (elapsed <= 0) return feeBps
  if (elapsed >= decay) return 0
  // Integer, floor — the same direction the contract rounds.
  return Number((BigInt(feeBps) * BigInt(decay - elapsed)) / BigInt(decay))
}

/** bps of a bigint amount, rounded down. */
export function bpsOf(amount: bigint, bps: number): bigint {
  return (amount * BigInt(bps)) / BPS
}

/** The amount net of a bps fee, rounded down — the direction `redeemProRata` uses. */
export function netOfBps(amount: bigint, bps: number): bigint {
  return (amount * (BPS - BigInt(bps))) / BPS
}

// ---------------------------------------------------------------------------------------------
// The AMPS fee, behind one accessor
// ---------------------------------------------------------------------------------------------

/**
 * The **AMPS fee** — the protocol's own fee, charged on every swap that touches AMPS, in both
 * directions.
 *
 * Revision 6 changed two things about it. It is charged on buys as well as sells, and the pool's
 * base fee is charged on top of it only for a pass-through route. What did *not* change yet is the
 * name on chain: `AmpsHook` still exposes it as `ampsFeeBps()` / `AMPS_FEE_BPS_MIN` /
 * `AMPS_FEE_BPS_MAX`, and `IAmpsQuoter.PoolQuote` still carries it as `ampsFeeBps`/`sellFeePips`.
 *
 * Everything in the app reads it through the four accessors below and nothing reads the struct
 * field or the function name directly, so the rename — when the hook lands it — is these four
 * lines and nothing else. `test/fees.test.ts` asserts that they agree with the fields they wrap.
 */
export const AMPS_FEE_FUNCTION = 'ampsFeeBps' as const
export const AMPS_FEE_MIN_FUNCTION = 'AMPS_FEE_BPS_MIN' as const
export const AMPS_FEE_MAX_FUNCTION = 'AMPS_FEE_BPS_MAX' as const

/** The AMPS fee in bps, out of a quote. Charged on both sides of the pool. */
export function ampsFeeBpsOf(quote: {ampsFeeBps: number}): number {
  return quote.ampsFeeBps
}

/** The same fee in pips — the unit the pool manager's fee override speaks. */
export function ampsFeePipsOf(quote: {sellFeePips: number}): number {
  return quote.sellFeePips
}

/**
 * The **pool base fee** in bps: 30 bp in an entry pool, 5–10 bp in a spoke.
 *
 * On chain this is `buyFeeBps`, and under revision 6 it is charged **on top of** the AMPS fee only
 * when the swap is one leg of a pass-through. A direct buy or sell pays the AMPS fee alone.
 */
export function poolBaseFeeBpsOf(quote: {buyFeeBps: number}): number {
  return quote.buyFeeBps
}

/**
 * What a direct swap pays, in pips, in the direction given — the authority is the quoter, which
 * has already applied the dynamic component and the clamps.
 */
export function directFeePipsOf(quote: {buyFeePips: number; sellFeePips: number}, side: 'buy' | 'sell'): number {
  return side === 'buy' ? quote.buyFeePips : quote.sellFeePips
}
