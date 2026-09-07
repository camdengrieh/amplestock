// SPDX-License-Identifier: MIT

/**
 * Bond maths and the one rule that is not negotiable.
 *
 * **`minAmpsOut` is always exactly the quoted `ampsOut`.** `docs/phase2-state-model.md` §6: the
 * capacity clamp is applied *after* pricing and reduces the AMPS issued, **never the collateral**.
 * The shell settles the whole `amountIn` and issues the capped `ampsOut`, so a bond that overruns
 * the epoch's capacity hands over its entire deposit for a capped issue *unless `minAmpsOut`
 * refuses it*. A slippage-reduced `minAmpsOut` is therefore not "tolerance", it is consent to be
 * clamped. `quote()` already discloses the clamp; the UI passes the quoted number through
 * unmodified and re-quotes rather than widening it.
 */

import {BPS, WAD} from './protocol'

export interface BondQuote {
  /** AMPS wei the bonder would receive, after the capacity clamp. */
  ampsOut: bigint
  /** The applied price, AMPS wei per 1e18 of collateral. */
  qX18: bigint
  discountBps: number
  /** True when `q_floor` (NAV x (1 + minAccretion), haircut by session) set the price. */
  floorBinding: boolean
  /** AMPS wei this market may still issue this epoch, after the global daily cap. */
  capacityLeft: bigint
  /** `0x00..00` when the bond would succeed, otherwise why not. */
  reason: `0x${string}`
}

/**
 * The `minAmpsOut` to send with `bond()`. Always the quote — there is no slippage parameter and
 * there must never be one.
 */
export function bondMinAmpsOut(quote: Pick<BondQuote, 'ampsOut'>): bigint {
  return quote.ampsOut
}

/**
 * Guard for the write path: refuses to build a `bond()` call whose `minAmpsOut` is below the
 * quote. It exists so that a future "add a slippage slider" change fails a test instead of
 * silently consenting to the capacity clamp.
 */
export function assertBondMinAmpsOut(minAmpsOut: bigint, quotedAmpsOut: bigint): void {
  if (minAmpsOut !== quotedAmpsOut) {
    throw new Error(
      `bond(): minAmpsOut must equal the quoted ampsOut (${quotedAmpsOut}), got ${minAmpsOut}. ` +
        'The capacity clamp takes the whole deposit for a capped issue, so any lower bound is consent to be clamped.',
    )
  }
}

/** Whether a market's own quote says the bond would go through. */
export function bondWouldSucceed(quote: Pick<BondQuote, 'ampsOut' | 'reason'>): boolean {
  return quote.ampsOut > 0n && /^0x0*$/.test(quote.reason)
}

/**
 * True when the deposit would be clamped: the quote's `ampsOut` is less than the price alone
 * would have issued. This is the case the UI has to make loud, because the collateral is taken in
 * full either way.
 */
export function isCapacityClamped(params: {quote: BondQuote; amountIn18: bigint}): boolean {
  if (params.quote.qX18 === 0n || params.amountIn18 === 0n) return false
  const uncapped = (params.amountIn18 * params.quote.qX18) / WAD
  return params.quote.ampsOut < uncapped
}

/** What the price alone would have issued, ignoring capacity. Display only. */
export function uncappedAmpsOut(params: {qX18: bigint; amountIn18: bigint}): bigint {
  return (params.amountIn18 * params.qX18) / WAD
}

/** Raw collateral units scaled to 18 decimals, the way the shell normalises before pricing. */
export function toAmount18(raw: bigint, decimals: number): bigint {
  if (decimals === 18) return raw
  if (decimals > 18) return raw / 10n ** BigInt(decimals - 18)
  return raw * 10n ** BigInt(18 - decimals)
}

/** The inverse, for display of a collateral amount from an 18-decimal figure. */
export function fromAmount18(amount18: bigint, decimals: number): bigint {
  if (decimals === 18) return amount18
  if (decimals > 18) return amount18 * 10n ** BigInt(decimals - 18)
  return amount18 / 10n ** BigInt(18 - decimals)
}

/**
 * `q_floor` — the NAV-plus-accretion ceiling on the bond price, with the session haircut applied.
 * Mirrors `docs/phase2-state-model.md` §6, in the same rounding directions.
 *
 * The floor is computed from the **last Chainlink answer**, never from the pool, which is what
 * makes TWAP manipulation worthless: the best an attacker can do is remove their own discount.
 */
export function bondFloorQX18(params: {
  collateralPriceUsd18: bigint
  navPerShareX18: bigint
  hSessionBps: number
  minAccretionBps: number
}): bigint {
  if (params.navPerShareX18 === 0n) return 0n
  const num = (params.collateralPriceUsd18 * (BPS - BigInt(params.hSessionBps))) / BPS
  const denRaw = params.navPerShareX18 * (BPS + BigInt(params.minAccretionBps))
  // qFloorDen rounds UP.
  const den = denRaw % BPS === 0n ? denRaw / BPS : denRaw / BPS + 1n
  if (den === 0n) return 0n
  return (num * WAD) / den
}

/** Linear vest: AMPS wei of a position vested at `now`, claimed or not. */
export function vestedOf(params: {principal: bigint; start: number; vestSeconds: number; now: number}): bigint {
  if (params.vestSeconds === 0) return params.principal
  const elapsed = params.now - params.start
  if (elapsed <= 0) return 0n
  if (elapsed >= params.vestSeconds) return params.principal
  return (params.principal * BigInt(elapsed)) / BigInt(params.vestSeconds)
}

/** `claimable == vestedOf - claimed`, and never negative. */
export function claimableOf(params: {principal: bigint; claimed: bigint; start: number; vestSeconds: number; now: number}): bigint {
  const vested = vestedOf(params)
  return vested > params.claimed ? vested - params.claimed : 0n
}

/** Fraction of a vest completed, 0..1, for a progress bar. */
export function vestProgress(params: {start: number; vestSeconds: number; now: number}): number {
  if (params.vestSeconds === 0) return 1
  const elapsed = params.now - params.start
  if (elapsed <= 0) return 0
  if (elapsed >= params.vestSeconds) return 1
  return elapsed / params.vestSeconds
}
