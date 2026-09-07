// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'

import {
  UNAVAILABLE,
  formatAmount,
  formatBps,
  formatDuration,
  formatPercent,
  formatPremiumBps,
  formatPremiumX18,
  formatUsd18,
  parseAmount,
  shortAddress,
} from '@/lib/format'

const WAD = 10n ** 18n

describe('nothing unavailable is ever rendered as a zero', () => {
  it('formats undefined and null as the unavailable dash', () => {
    expect(formatAmount(undefined, 18)).toBe(UNAVAILABLE)
    expect(formatAmount(null, 18)).toBe(UNAVAILABLE)
    expect(formatUsd18(undefined)).toBe(UNAVAILABLE)
    expect(formatBps(undefined)).toBe(UNAVAILABLE)
    expect(formatPremiumX18(undefined)).toBe(UNAVAILABLE)
    expect(formatDuration(null)).toBe(UNAVAILABLE)
    expect(formatPercent(undefined)).toBe(UNAVAILABLE)
  })

  it('still formats a genuine zero as a zero', () => {
    expect(formatAmount(0n, 18)).toBe('0')
    expect(formatUsd18(0n)).toBe('$0.00')
    expect(formatBps(0)).toBe('0.00%')
  })
})

describe('the premium is a signed number', () => {
  it('carries an explicit sign', () => {
    expect(formatPremiumX18(120_000_000_000_000_000n)).toBe('+12.00%')
    expect(formatPremiumX18(-50_000_000_000_000_000n)).toBe('-5.00%')
    expect(formatPremiumX18(0n)).toBe('0.00%')
    expect(formatPremiumBps(1_250)).toBe('+12.50%')
    expect(formatPremiumBps(-25)).toBe('-0.25%')
  })
})

describe('parseAmount', () => {
  it('parses decimals into raw units', () => {
    expect(parseAmount('1', 18)).toBe(WAD)
    expect(parseAmount('1.5', 18)).toBe(WAD + WAD / 2n)
    expect(parseAmount('0.000001', 6)).toBe(1n)
    expect(parseAmount('.5', 18)).toBe(WAD / 2n)
  })

  it('refuses more precision than the token has', () => {
    expect(parseAmount('0.1234567', 6)).toBeNull()
  })

  it('refuses anything that is not a decimal', () => {
    expect(parseAmount('', 18)).toBeNull()
    expect(parseAmount('abc', 18)).toBeNull()
    expect(parseAmount('1e18', 18)).toBeNull()
    expect(parseAmount('-1', 18)).toBeNull()
  })
})

describe('miscellaneous formatting', () => {
  it('formats durations', () => {
    expect(formatDuration(45)).toBe('45s')
    expect(formatDuration(3_600)).toBe('1h 0m')
    expect(formatDuration(90_000)).toBe('1d 1h')
  })

  it('shortens addresses and refuses a malformed one', () => {
    expect(shortAddress('0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99')).toBe('0x06Af…bf99')
    expect(shortAddress('0x1')).toBe(UNAVAILABLE)
    expect(shortAddress(undefined)).toBe(UNAVAILABLE)
  })
})
