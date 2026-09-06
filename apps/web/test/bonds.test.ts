// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'

import {
  assertBondMinAmpsOut,
  bondFloorQX18,
  bondMinAmpsOut,
  bondWouldSucceed,
  claimableOf,
  fromAmount18,
  isCapacityClamped,
  toAmount18,
  uncappedAmpsOut,
  vestProgress,
  vestedOf,
  type BondQuote,
} from '@/lib/bonds'

const WAD = 10n ** 18n
const OK = `0x${'0'.repeat(64)}` as const

function quote(overrides: Partial<BondQuote> = {}): BondQuote {
  return {
    ampsOut: 8n * WAD,
    qX18: 8n * WAD,
    discountBps: 1_250,
    floorBinding: false,
    capacityLeft: 100n * WAD,
    reason: OK,
    ...overrides,
  }
}

describe('minAmpsOut is always exactly the quote', () => {
  it('returns the quoted ampsOut unchanged', () => {
    expect(bondMinAmpsOut(quote())).toBe(8n * WAD)
  })

  it('is the quote even when the capacity clamp has already reduced it', () => {
    const clamped = quote({ampsOut: 3n * WAD, capacityLeft: 3n * WAD})
    expect(bondMinAmpsOut(clamped)).toBe(3n * WAD)
  })

  it('refuses any lower bound — a slippage tolerance here is consent to be clamped', () => {
    expect(() => assertBondMinAmpsOut(7n * WAD, 8n * WAD)).toThrow(/must equal the quoted ampsOut/)
    expect(() => assertBondMinAmpsOut(0n, 8n * WAD)).toThrow()
    expect(() => assertBondMinAmpsOut(8n * WAD, 8n * WAD)).not.toThrow()
  })

  it('refuses a higher bound too', () => {
    expect(() => assertBondMinAmpsOut(9n * WAD, 8n * WAD)).toThrow()
  })
})

describe('the capacity clamp', () => {
  it('is detected by comparing the quote against what the price alone would have issued', () => {
    const amountIn18 = WAD
    const clamped = quote({qX18: 8n * WAD, ampsOut: 3n * WAD})
    expect(isCapacityClamped({quote: clamped, amountIn18})).toBe(true)
    expect(uncappedAmpsOut({qX18: clamped.qX18, amountIn18})).toBe(8n * WAD)
  })

  it('is not reported when the whole deposit prices through', () => {
    expect(isCapacityClamped({quote: quote(), amountIn18: WAD})).toBe(false)
  })

  it('is not reported for an unpriced market', () => {
    expect(isCapacityClamped({quote: quote({qX18: 0n, ampsOut: 0n}), amountIn18: WAD})).toBe(false)
  })
})

describe('bondWouldSucceed', () => {
  it('needs both a non-zero issue and an empty reason', () => {
    expect(bondWouldSucceed(quote())).toBe(true)
    expect(bondWouldSucceed(quote({ampsOut: 0n}))).toBe(false)
    expect(bondWouldSucceed(quote({reason: `0x${'0'.repeat(62)}01`}))).toBe(false)
  })
})

describe('decimal normalisation', () => {
  it('scales USDG’s six decimals up once, the way the shell does before pricing', () => {
    expect(toAmount18(1_000_000n, 6)).toBe(WAD)
    expect(fromAmount18(WAD, 6)).toBe(1_000_000n)
  })

  it('is the identity at 18', () => {
    expect(toAmount18(WAD, 18)).toBe(WAD)
    expect(fromAmount18(WAD, 18)).toBe(WAD)
  })
})

describe('bondFloorQX18 — NAV plus accretion, haircut by session', () => {
  const navPerShareX18 = WAD

  it('is the collateral price over NAV when nothing is haircut and nothing is required', () => {
    expect(bondFloorQX18({collateralPriceUsd18: 100n * WAD, navPerShareX18, hSessionBps: 0, minAccretionBps: 0})).toBe(
      100n * WAD,
    )
  })

  it('falls as the session haircut rises — which is why markets can stay open through a closed session', () => {
    const regular = bondFloorQX18({collateralPriceUsd18: 100n * WAD, navPerShareX18, hSessionBps: 0, minAccretionBps: 50})
    const closed = bondFloorQX18({collateralPriceUsd18: 100n * WAD, navPerShareX18, hSessionBps: 300, minAccretionBps: 50})
    expect(closed).toBeLessThan(regular)
  })

  it('falls as the required accretion rises', () => {
    const low = bondFloorQX18({collateralPriceUsd18: 100n * WAD, navPerShareX18, hSessionBps: 0, minAccretionBps: 50})
    const high = bondFloorQX18({collateralPriceUsd18: 100n * WAD, navPerShareX18, hSessionBps: 0, minAccretionBps: 500})
    expect(high).toBeLessThan(low)
  })

  it('is zero when NAV per share is unknown, rather than dividing by zero', () => {
    expect(bondFloorQX18({collateralPriceUsd18: 100n * WAD, navPerShareX18: 0n, hSessionBps: 0, minAccretionBps: 50})).toBe(0n)
  })
})

describe('vesting', () => {
  const position = {principal: 12n * WAD, claimed: 0n, start: 1_000, vestSeconds: 12 * 3_600}

  it('is zero before it starts and whole after it ends', () => {
    expect(vestedOf({...position, now: 999})).toBe(0n)
    expect(vestedOf({...position, now: 1_000})).toBe(0n)
    expect(vestedOf({...position, now: 1_000 + 12 * 3_600})).toBe(12n * WAD)
    expect(vestedOf({...position, now: 10_000_000})).toBe(12n * WAD)
  })

  it('is linear in between', () => {
    expect(vestedOf({...position, now: 1_000 + 6 * 3_600})).toBe(6n * WAD)
  })

  it('is monotone non-decreasing and never above the principal', () => {
    let previous = 0n
    for (let t = 0; t <= 13 * 3_600; t += 900) {
      const vested = vestedOf({...position, now: 1_000 + t})
      expect(vested).toBeGreaterThanOrEqual(previous)
      expect(vested).toBeLessThanOrEqual(position.principal)
      previous = vested
    }
  })

  it('claimable is vested less claimed, and never negative', () => {
    expect(claimableOf({...position, claimed: 3n * WAD, now: 1_000 + 6 * 3_600})).toBe(3n * WAD)
    expect(claimableOf({...position, claimed: 9n * WAD, now: 1_000 + 6 * 3_600})).toBe(0n)
  })

  it('reports progress as a fraction', () => {
    expect(vestProgress({start: 1_000, vestSeconds: 100, now: 1_000})).toBe(0)
    expect(vestProgress({start: 1_000, vestSeconds: 100, now: 1_050})).toBe(0.5)
    expect(vestProgress({start: 1_000, vestSeconds: 100, now: 5_000})).toBe(1)
  })
})
