// SPDX-License-Identifier: MIT

/**
 * `AmpsQuoter.PoolQuote` as the UI sees it, and the one rule that governs how it is rendered.
 *
 * `AmpsQuoter` never reverts: a failed sub-read leaves its fields at zero and raises a bit in
 * `degraded`. **A zeroed field is not a zero value.** The UI must render every degraded field as
 * *unavailable* — no number, no chart point, no "0.00" — because a zero rendered as data is a lie
 * that a user can trade on. `refuseBuy`/`refuseSell` are the sharpest case: they come back `false`
 * when bit 0 is set, which is the quoter failing **open for display**, and an execution path must
 * never read a degraded quote as permission to trade.
 */

import type {Address, Hex} from 'viem'

import {GateState, PoolClass, Session, gateStateNames, poolClassNames, sessionNames} from './protocol'
import type {GateStateName, PoolClassName, SessionName} from './protocol'

/** The `degraded` bitfield of `IAmpsQuoter.PoolQuote`, bit by bit. */
export const DegradedBit = {
  /** ticks, bands, fees, `refuseBuy`/`refuseSell` */
  HOOK: 1 << 0,
  /** `gateState`, `session`, `feedStale`, `corporateFreeze` */
  GATE: 1 << 1,
  /** the counter-asset price feeding `pMktX18` */
  FEEDS: 1 << 2,
  /** `navPerShareX18`, `pRefX18`, `premiumX18`, `checkpointAge` */
  CHECKPOINT: 1 << 3,
  /** `bondQX18`, `bondDiscountBps`, `bondCapacityLeft`, `bondOpen` */
  BONDS: 1 << 4,
  /** `pMktX18` — the observation ring covers less than `twapWindow` */
  TWAP: 1 << 5,
} as const

export type DegradedBitName = keyof typeof DegradedBit

export const degradedBitOrder: readonly DegradedBitName[] = ['HOOK', 'GATE', 'FEEDS', 'CHECKPOINT', 'BONDS', 'TWAP']

export const degradedBitLabels: Readonly<Record<DegradedBitName, string>> = {
  HOOK: 'Hook read failed — ticks, bands and fees unavailable',
  GATE: 'Oracle gate read failed — gate state and session unavailable',
  FEEDS: 'Feed registry read failed — the counter-asset price is unavailable',
  CHECKPOINT: 'Vault checkpoint read failed — NAV/share, reference and premium unavailable',
  BONDS: 'Bond market read failed — bond price and capacity unavailable',
  TWAP: 'Not enough observation history yet — the market price is not available',
}

/** `IAmpsQuoter.PoolQuote`, decoded. Field names and order mirror the struct exactly. */
export interface PoolQuote {
  poolId: Hex
  poolClass: number
  counter: Address
  pMktX18: bigint
  pRefX18: bigint
  navPerShareX18: bigint
  premiumX18: bigint
  poolTick: number
  fairTick: number
  innerBandTicks: number
  outerRailTicks: number
  buyFeeBps: number
  sellFeeBps: number
  buyFeePips: number
  sellFeePips: number
  dynBps: number
  dynCapBps: number
  refuseSell: boolean
  refuseBuy: boolean
  bondQX18: bigint
  bondDiscountBps: number
  bondCapacityLeft: bigint
  bondOpen: boolean
  gateState: number
  session: number
  feedStale: boolean
  corporateFreeze: boolean
  observationCoverage: number
  checkpointAge: number
  degraded: number
}

export function hasDegradedBit(degraded: number, bit: number): boolean {
  return (degraded & bit) !== 0
}

/** The bits raised, in bit order, for a "why is this unavailable" list. */
export function degradedBits(degraded: number): DegradedBitName[] {
  return degradedBitOrder.filter((name) => hasDegradedBit(degraded, DegradedBit[name]))
}

/**
 * Which *fields* of a quote may be displayed. A field whose source bit is raised is unavailable,
 * full stop — the caller renders a dash and the reason, never the zero.
 */
export interface QuoteAvailability {
  ticksAndBands: boolean
  fees: boolean
  refusals: boolean
  gate: boolean
  counterPrice: boolean
  marketPrice: boolean
  nav: boolean
  premium: boolean
  bond: boolean
  /** True when *any* bit is raised: no execution path may treat this quote as permission to trade. */
  anyDegraded: boolean
}

export function quoteAvailability(degraded: number): QuoteAvailability {
  const hook = !hasDegradedBit(degraded, DegradedBit.HOOK)
  const gate = !hasDegradedBit(degraded, DegradedBit.GATE)
  const feeds = !hasDegradedBit(degraded, DegradedBit.FEEDS)
  const checkpoint = !hasDegradedBit(degraded, DegradedBit.CHECKPOINT)
  const bonds = !hasDegradedBit(degraded, DegradedBit.BONDS)
  const twap = !hasDegradedBit(degraded, DegradedBit.TWAP)
  return {
    ticksAndBands: hook,
    fees: hook,
    refusals: hook,
    gate,
    counterPrice: feeds,
    // `pMktX18` needs both the feed that prices the counter asset and enough ring coverage.
    marketPrice: feeds && twap,
    nav: checkpoint,
    premium: checkpoint,
    bond: bonds,
    anyDegraded: degraded !== 0,
  }
}

/**
 * Whether a quote may back an execution. Never `true` for a degraded quote, and never `true` when
 * the hook says the swap begins beyond the outer rail on the deviation-increasing side.
 */
export function isTradeable(quote: Pick<PoolQuote, 'degraded' | 'refuseBuy' | 'refuseSell'>, side: 'buy' | 'sell'): boolean {
  if (quote.degraded !== 0) return false
  return side === 'buy' ? !quote.refuseBuy : !quote.refuseSell
}

export function gateStateName(ordinal: number): GateStateName | 'UNKNOWN' {
  return gateStateNames[ordinal] ?? 'UNKNOWN'
}

export function sessionName(ordinal: number): SessionName | 'UNKNOWN' {
  return sessionNames[ordinal] ?? 'UNKNOWN'
}

export function poolClassName(ordinal: number): PoolClassName | 'UNKNOWN' {
  return poolClassNames[ordinal] ?? 'UNKNOWN'
}

/** Is this pool registered at all? `PoolClass.NONE` is what an unknown `poolId` comes back as. */
export function isRegistered(quote: Pick<PoolQuote, 'poolClass'>): boolean {
  return quote.poolClass !== PoolClass.NONE
}

/** A gate state that stops placements and compounding but never a swap and never redemption. */
export function gateIsHealthy(gateStateOrdinal: number): boolean {
  return gateStateOrdinal === GateState.GREEN
}

export function sessionIsOpen(sessionOrdinal: number): boolean {
  return sessionOrdinal === Session.REGULAR
}

/**
 * The premium, as a number.
 *
 * `premiumX18 = pRefX18 / navPerShareX18 - 1`, signed, 18 decimals. It is disclosure: nothing on
 * chain consumes it, no path issues at NAV, and it is not a forecast of anything. Returned as
 * basis points so the caller can format it without a float round trip.
 */
export function premiumBps(premiumX18: bigint): number {
  return Number((premiumX18 * 10_000n) / 10n ** 18n)
}
