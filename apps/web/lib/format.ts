// SPDX-License-Identifier: MIT

/**
 * Number formatting.
 *
 * One rule runs through all of it: **a value that is not available is never rendered as a zero.**
 * `formatUnavailable` is the single em-dash the whole app uses, and every component that can be
 * handed a degraded field routes through it.
 */

import {formatUnits} from 'viem'

export const UNAVAILABLE = '—'

export function formatUnavailable(): string {
  return UNAVAILABLE
}

/** A token amount, trimmed to a sensible number of significant figures. */
export function formatAmount(value: bigint | undefined | null, decimals: number, maxFractionDigits = 6): string {
  if (value === undefined || value === null) return UNAVAILABLE
  const raw = formatUnits(value, decimals)
  const n = Number(raw)
  if (!Number.isFinite(n)) return raw
  if (n === 0) return '0'
  if (Math.abs(n) < 10 ** -maxFractionDigits) return `<${10 ** -maxFractionDigits}`
  return n.toLocaleString('en-US', {maximumFractionDigits: maxFractionDigits})
}

/** An 18-decimal USD figure. */
export function formatUsd18(value: bigint | undefined | null, fractionDigits = 2): string {
  if (value === undefined || value === null) return UNAVAILABLE
  const n = Number(formatUnits(value, 18))
  if (!Number.isFinite(n)) return UNAVAILABLE
  return `$${n.toLocaleString('en-US', {minimumFractionDigits: fractionDigits, maximumFractionDigits: fractionDigits})}`
}

export function formatUsdNumber(value: number | undefined | null, fractionDigits = 2): string {
  if (value === undefined || value === null || !Number.isFinite(value)) return UNAVAILABLE
  return `$${value.toLocaleString('en-US', {minimumFractionDigits: fractionDigits, maximumFractionDigits: fractionDigits})}`
}

/** bps as a percentage: `500` -> `"5.00%"`. */
export function formatBps(bps: number | undefined | null, fractionDigits = 2): string {
  if (bps === undefined || bps === null || !Number.isFinite(bps)) return UNAVAILABLE
  return `${(bps / 100).toFixed(fractionDigits)}%`
}

/**
 * The premium to NAV, **as a number**.
 *
 * Signed, explicit, and with no adjective attached anywhere it is used. A premium is what the
 * market is currently paying above the vault's own accounting of what it holds; it is not a
 * forecast, not a target and not a promise, and nothing on chain consumes it.
 */
export function formatPremiumBps(bps: number | undefined | null, fractionDigits = 2): string {
  if (bps === undefined || bps === null || !Number.isFinite(bps)) return UNAVAILABLE
  const sign = bps > 0 ? '+' : ''
  return `${sign}${(bps / 100).toFixed(fractionDigits)}%`
}

/** A signed 18-decimal ratio (`premiumX18`) as a percentage. */
export function formatPremiumX18(value: bigint | undefined | null, fractionDigits = 2): string {
  if (value === undefined || value === null) return UNAVAILABLE
  const n = Number(formatUnits(value, 18)) * 100
  if (!Number.isFinite(n)) return UNAVAILABLE
  const sign = n > 0 ? '+' : ''
  return `${sign}${n.toFixed(fractionDigits)}%`
}

export function formatPercent(fraction: number | undefined | null, fractionDigits = 1): string {
  if (fraction === undefined || fraction === null || !Number.isFinite(fraction)) return UNAVAILABLE
  return `${(fraction * 100).toFixed(fractionDigits)}%`
}

/** A duration in seconds as `2d 3h`, `4h 12m`, `45s`. */
export function formatDuration(seconds: number | undefined | null): string {
  if (seconds === undefined || seconds === null || !Number.isFinite(seconds)) return UNAVAILABLE
  const s = Math.max(0, Math.floor(seconds))
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m ${s % 60}s`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h ${m % 60}m`
  const d = Math.floor(h / 24)
  return `${d}d ${h % 24}h`
}

export function formatTimestamp(seconds: number | undefined | null): string {
  if (!seconds) return UNAVAILABLE
  return new Date(seconds * 1000).toISOString().replace('T', ' ').slice(0, 16) + ' UTC'
}

export function shortAddress(address: string | undefined | null): string {
  if (!address || address.length < 10) return UNAVAILABLE
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

/** Parses a user-typed decimal amount into raw units. Returns `null` for anything unparseable. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const trimmed = input.trim()
  if (trimmed === '') return null
  if (!/^\d*\.?\d*$/.test(trimmed)) return null
  const parts = trimmed.split('.')
  const wholeRaw = parts[0] ?? ''
  const fracRaw = parts[1] ?? ''
  const whole = wholeRaw === '' ? '0' : wholeRaw
  if (fracRaw.length > decimals) return null
  const frac = fracRaw.padEnd(decimals, '0')
  try {
    return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(frac === '' ? '0' : frac)
  } catch {
    return null
  }
}
