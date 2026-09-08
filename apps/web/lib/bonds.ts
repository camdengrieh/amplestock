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

// ---------------------------------------------------------------------------------------------
// Why a market cannot price a bond
// ---------------------------------------------------------------------------------------------

/**
 * The `reason` a `quote()` comes back with when `ampsOut == 0`, as a person reads it.
 *
 * `AmpsBonds.quote` never reverts for a known market: a market that is closed, frozen, full or
 * unpriceable answers with zero and a `bytes32` reason, which is what lets the board show every
 * market including the ones that cannot be bonded right now. Rendering the raw bytes32 would make
 * the board technically complete and practically useless.
 *
 * `unconfirmedNav` is new in revision 6: the vault's checkpoint was built on a feed answer that has
 * not been confirmed yet, so the NAV floor the shell would price against is not yet trustworthy.
 * It resolves by itself when the feed confirms — there is nothing for the bonder to do but wait,
 * and the label says exactly that rather than implying a fault.
 */
export const BOND_REASON_LABELS: Readonly<Record<string, string>> = {
  unconfirmedNav: 'NAV built on an unconfirmed answer; wait for the feed to confirm',
  closed: 'This market is not accepting bonds',
  frozen: 'A guardian freeze or a corporate action covers this constituent',
  capacity: 'The epoch’s capacity is used up',
  dailyCap: 'The protocol’s daily issuance cap is used up',
  gate: 'The oracle gate is not in a state this market will price through',
  stale: 'The price feed for this collateral is stale',
  staleCheckpoint: 'The vault checkpoint is older than this path accepts — call checkpoint()',
  accretion: 'The price would not clear the minimum accretion to NAV per share',
  session: 'The equity session haircut leaves no discount to offer',
  amount: 'The deposit is below the minimum this market prices',
}

/** Decodes a `bytes32` reason to its ASCII form, or `null` for `bytes32(0)`. */
export function decodeBondReason(reason: string): string | null {
  if (!reason || /^0x0*$/.test(reason)) return null
  const hex = reason.startsWith('0x') ? reason.slice(2) : reason
  let out = ''
  for (let i = 0; i + 1 < hex.length; i += 2) {
    const code = Number.parseInt(hex.slice(i, i + 2), 16)
    if (!Number.isFinite(code) || code === 0) continue
    if (code < 32 || code > 126) return null
    out += String.fromCharCode(code)
  }
  return out === '' ? null : out
}

/**
 * The label for a quote's reason. An unrecognised reason is passed through as its own decoded
 * string rather than swallowed: a reason this app has not learned yet is still information.
 */
export function bondReasonLabel(reason: string): string | null {
  const decoded = decodeBondReason(reason)
  if (decoded === null) return null
  return BOND_REASON_LABELS[decoded] ?? decoded
}
