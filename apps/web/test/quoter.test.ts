// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'

import {
  DegradedBit,
  degradedBits,
  gateIsHealthy,
  gateStateName,
  hasDegradedBit,
  isRegistered,
  isTradeable,
  poolClassName,
  premiumBps,
  quoteAvailability,
  sessionIsOpen,
  sessionName,
} from '@/lib/quoter'
import {poolQuote} from './fixtures'

describe('the degraded bitfield', () => {
  it('names exactly the bits that are raised, in bit order', () => {
    expect(degradedBits(0)).toEqual([])
    expect(degradedBits(DegradedBit.HOOK)).toEqual(['HOOK'])
    expect(degradedBits(DegradedBit.TWAP | DegradedBit.GATE)).toEqual(['GATE', 'TWAP'])
    expect(degradedBits(0b111111)).toEqual(['HOOK', 'GATE', 'FEEDS', 'CHECKPOINT', 'BONDS', 'TWAP'])
  })

  it('maps each bit to the fields it zeroes', () => {
    const hook = quoteAvailability(DegradedBit.HOOK)
    expect(hook.ticksAndBands).toBe(false)
    expect(hook.fees).toBe(false)
    expect(hook.refusals).toBe(false)
    expect(hook.nav).toBe(true)

    const checkpoint = quoteAvailability(DegradedBit.CHECKPOINT)
    expect(checkpoint.nav).toBe(false)
    expect(checkpoint.premium).toBe(false)
    expect(checkpoint.fees).toBe(true)

    const bonds = quoteAvailability(DegradedBit.BONDS)
    expect(bonds.bond).toBe(false)
    expect(bonds.marketPrice).toBe(true)
  })

  it('needs both the feed and the TWAP coverage before a market price may be shown', () => {
    expect(quoteAvailability(DegradedBit.TWAP).marketPrice).toBe(false)
    expect(quoteAvailability(DegradedBit.FEEDS).marketPrice).toBe(false)
    expect(quoteAvailability(0).marketPrice).toBe(true)
  })

  it('flags any degradation at all', () => {
    expect(quoteAvailability(0).anyDegraded).toBe(false)
    expect(quoteAvailability(DegradedBit.GATE).anyDegraded).toBe(true)
  })

  it('has a single-bit test', () => {
    expect(hasDegradedBit(0b100, DegradedBit.FEEDS)).toBe(true)
    expect(hasDegradedBit(0b100, DegradedBit.HOOK)).toBe(false)
  })
})

describe('isTradeable — the quoter fails open for display, never for execution', () => {
  it('is false for any degraded quote, even one whose refusal flags are false', () => {
    const degradedButNotRefusing = poolQuote({degraded: DegradedBit.HOOK, refuseBuy: false, refuseSell: false})
    expect(degradedButNotRefusing.refuseBuy).toBe(false)
    expect(isTradeable(degradedButNotRefusing, 'buy')).toBe(false)
    expect(isTradeable(degradedButNotRefusing, 'sell')).toBe(false)
  })

  it('is false when the hook refuses that direction, and true for the other one', () => {
    const railed = poolQuote({refuseSell: true})
    expect(isTradeable(railed, 'sell')).toBe(false)
    expect(isTradeable(railed, 'buy')).toBe(true)
  })

  it('is true for a clean quote', () => {
    expect(isTradeable(poolQuote(), 'buy')).toBe(true)
    expect(isTradeable(poolQuote(), 'sell')).toBe(true)
  })
})

describe('enum ordinals are ABI', () => {
  it('names gate states, sessions and pool classes by ordinal', () => {
    expect(gateStateName(0)).toBe('GREEN')
    expect(gateStateName(5)).toBe('WATCHDOG')
    expect(gateStateName(99)).toBe('UNKNOWN')
    expect(sessionName(3)).toBe('CLOSED')
    expect(poolClassName(1)).toBe('ENTRY')
    expect(poolClassName(0)).toBe('NONE')
  })

  it('treats PoolClass.NONE as an unregistered pool rather than an entry pool', () => {
    expect(isRegistered(poolQuote({poolClass: 0}))).toBe(false)
    expect(isRegistered(poolQuote({poolClass: 1}))).toBe(true)
  })

  it('reports gate health and session openness', () => {
    expect(gateIsHealthy(0)).toBe(true)
    expect(gateIsHealthy(1)).toBe(false)
    expect(sessionIsOpen(0)).toBe(true)
    expect(sessionIsOpen(3)).toBe(false)
  })
})

describe('premiumBps', () => {
  it('is a signed number and nothing else', () => {
    expect(premiumBps(120_000_000_000_000_000n)).toBe(1_200)
    expect(premiumBps(0n)).toBe(0)
    expect(premiumBps(-50_000_000_000_000_000n)).toBe(-500)
  })
})

describe('the two bits the quoter grew', () => {
  it('names the registry and PoolManager reads', () => {
    expect(DegradedBit.REGISTRY).toBe(0x40)
    expect(DegradedBit.POOL).toBe(0x80)
    expect(degradedBits(DegradedBit.REGISTRY | DegradedBit.POOL)).toEqual(['REGISTRY', 'POOL'])
  })

  it('withdraws the pool identity — class, counter, tick spacing — when the registry read failed', () => {
    const availability = quoteAvailability(DegradedBit.REGISTRY)
    expect(availability.poolIdentity).toBe(false)
    expect(availability.nav).toBe(true)
  })

  it('withdraws the live tick, and the bands measured against it, when the extsload failed', () => {
    const availability = quoteAvailability(DegradedBit.POOL)
    expect(availability.liveTick).toBe(false)
    expect(availability.ticksAndBands).toBe(false)
    expect(availability.fees).toBe(true)
  })

  it('still refuses to call a quote with either bit tradeable', () => {
    expect(isTradeable(poolQuote({degraded: DegradedBit.REGISTRY}), 'buy')).toBe(false)
    expect(isTradeable(poolQuote({degraded: DegradedBit.POOL}), 'sell')).toBe(false)
  })
})
