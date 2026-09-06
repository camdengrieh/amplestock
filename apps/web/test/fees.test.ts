// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'

import {
  applyFeePips,
  blendedSellFeeBps,
  bpsOf,
  bpsToPips,
  clampTotalFeeBps,
  creatorBpsAt,
  creditConsumed,
  feeAmount,
  mulDivRoundingUp,
  netOfBps,
  pipsToPercent,
  rotationFeePips,
} from '@/lib/fees'
import {F_MIN_BPS, FROZEN_FEE_FLOOR_BPS, TOTAL_FEE_BPS_MAX} from '@/lib/protocol'

const WAD = 10n ** 18n

describe('mulDivRoundingUp', () => {
  it('rounds up on any remainder', () => {
    expect(mulDivRoundingUp(1n, 1n, 3n)).toBe(1n)
    expect(mulDivRoundingUp(2n, 1n, 3n)).toBe(1n)
    expect(mulDivRoundingUp(3n, 1n, 3n)).toBe(1n)
    expect(mulDivRoundingUp(4n, 1n, 3n)).toBe(2n)
  })

  it('carries the 512-bit intermediate the naive form overflows on', () => {
    // The naive `(buy*c + sell*(in-c) + in-1)/in` overflows for amountIn > 2^256/600.
    const huge = (1n << 255n) / 300n
    expect(() => mulDivRoundingUp(470n, huge, huge)).not.toThrow()
    expect(mulDivRoundingUp(470n, huge, huge)).toBe(470n)
  })
})

describe('blendedSellFeeBps — the rotation-credit blend', () => {
  const sellFeeBps = 500
  const buyFeeBps = 5

  it('an uncredited sell pays the full sell fee', () => {
    expect(blendedSellFeeBps({sellFeeBps, buyFeeBps, amountIn: WAD, credit: 0n})).toBe(500)
  })

  it('a fully credited sell pays the destination pool’s buy fee, not zero', () => {
    expect(blendedSellFeeBps({sellFeeBps, buyFeeBps, amountIn: WAD, credit: WAD})).toBe(5)
    expect(blendedSellFeeBps({sellFeeBps, buyFeeBps, amountIn: WAD, credit: 10n * WAD})).toBe(5)
  })

  it('a half-credited sell pays the exact delta form, rounded up', () => {
    // base = 5 + ceil((500 - 5) * (1e18 - 5e17) / 1e18) = 5 + ceil(247.5) = 5 + 248 = 253
    expect(blendedSellFeeBps({sellFeeBps, buyFeeBps, amountIn: WAD, credit: WAD / 2n})).toBe(253)
  })

  it('rounds up so a credit never rounds the fee down in the swapper’s favour', () => {
    // (500-5) * (3-1) / 3 = 330.0 exactly -> no rounding; use 7 to force a remainder.
    const amountIn = 7n
    const credit = 1n
    const exact = (495 * 6) / 7
    const blended = blendedSellFeeBps({sellFeeBps, buyFeeBps, amountIn, credit})
    expect(blended).toBe(5 + Math.ceil(exact))
    expect(blended).toBeGreaterThan(5 + Math.floor(exact))
  })

  it('is monotone: more credit is never a higher fee', () => {
    let previous = 501
    for (let i = 0; i <= 10; i++) {
      const fee = blendedSellFeeBps({sellFeeBps, buyFeeBps, amountIn: WAD, credit: (WAD * BigInt(i)) / 10n})
      expect(fee).toBeLessThanOrEqual(previous)
      previous = fee
    }
  })

  it('never goes below the destination pool’s buy fee', () => {
    for (const credit of [0n, 1n, WAD / 3n, WAD, WAD * 2n]) {
      expect(blendedSellFeeBps({sellFeeBps, buyFeeBps, amountIn: WAD, credit})).toBeGreaterThanOrEqual(buyFeeBps)
    }
  })

  it('refuses the sellFee < buyFee case, which the hard bands make unreachable on chain', () => {
    expect(() => blendedSellFeeBps({sellFeeBps: 5, buyFeeBps: 500, amountIn: WAD, credit: 0n})).toThrow()
  })

  it('treats a zero amount as an uncredited sell', () => {
    expect(blendedSellFeeBps({sellFeeBps, buyFeeBps, amountIn: 0n, credit: WAD})).toBe(500)
  })
})

describe('creditConsumed', () => {
  it('is capped by the amount actually being sold', () => {
    expect(creditConsumed(WAD, 10n * WAD)).toBe(WAD)
    expect(creditConsumed(WAD, WAD / 4n)).toBe(WAD / 4n)
    expect(creditConsumed(0n, WAD)).toBe(0n)
  })
})

describe('clampTotalFeeBps', () => {
  it('clamps the dynamic part to the pool’s cap', () => {
    expect(clampTotalFeeBps({baseBps: 500, dynBps: 900, dynCapBps: 300})).toBe(800)
  })

  it('floors at F_MIN_BPS', () => {
    expect(clampTotalFeeBps({baseBps: 1, dynBps: 0, dynCapBps: 300})).toBe(F_MIN_BPS)
  })

  it('raises the dynamic floor when the gate is degraded, and never reverts the swap', () => {
    const normal = clampTotalFeeBps({baseBps: 500, dynBps: 0, dynCapBps: 1_000})
    const degraded = clampTotalFeeBps({baseBps: 500, dynBps: 0, dynCapBps: 1_000, degraded: true, frozenFeeFloorBps: FROZEN_FEE_FLOOR_BPS})
    expect(normal).toBe(500)
    expect(degraded).toBe(600)
  })

  it('never exceeds the absolute ceiling', () => {
    expect(clampTotalFeeBps({baseBps: 600, dynBps: 5_000, dynCapBps: 5_000})).toBe(TOTAL_FEE_BPS_MAX)
  })
})

describe('rotationFeePips', () => {
  it('prices hop 2 with the credit hop 1 creates', () => {
    const result = rotationFeePips({
      hop1BuyFeeBps: 5,
      hop2BuyFeeBps: 5,
      sellFeeBps: 500,
      ampsFromHop1: WAD,
      ampsIntoHop2: WAD,
    })
    expect(result.hop1FeePips).toBe(bpsToPips(5))
    expect(result.hop2BaseBps).toBe(5)
    expect(result.creditUsed).toBe(WAD)
  })

  it('shows the whole sell fee when hop 2 sells more than hop 1 bought', () => {
    const result = rotationFeePips({
      hop1BuyFeeBps: 5,
      hop2BuyFeeBps: 5,
      sellFeeBps: 500,
      ampsFromHop1: 0n,
      ampsIntoHop2: WAD,
    })
    expect(result.hop2BaseBps).toBe(500)
    expect(result.creditUsed).toBe(0n)
  })
})

describe('fee application', () => {
  it('takes the fee from the input, rounding the pool’s way', () => {
    expect(applyFeePips(1_000_000n, 50_000)).toBe(950_000n)
    expect(feeAmount(1_000_000n, 50_000)).toBe(50_000n)
  })

  it('formats pips as a percentage', () => {
    expect(pipsToPercent(50_000)).toBe('5.00%')
    expect(pipsToPercent(500)).toBe('0.05%')
  })
})

describe('creatorBpsAt — an immutable schedule that expires by itself', () => {
  const genesis = 1_800_000_000

  it('starts at 100 bp', () => {
    expect(creatorBpsAt({genesisTimestamp: genesis, timestamp: genesis})).toBe(100)
  })

  it('is exactly zero from day 30', () => {
    expect(creatorBpsAt({genesisTimestamp: genesis, timestamp: genesis + 30 * 86_400})).toBe(0)
    expect(creatorBpsAt({genesisTimestamp: genesis, timestamp: genesis + 400 * 86_400})).toBe(0)
  })

  it('is monotone non-increasing', () => {
    let previous = 101
    for (let day = 0; day <= 31; day++) {
      const bps = creatorBpsAt({genesisTimestamp: genesis, timestamp: genesis + day * 86_400})
      expect(bps).toBeLessThanOrEqual(previous)
      previous = bps
    }
  })

  it('is zero before genesis has run', () => {
    expect(creatorBpsAt({genesisTimestamp: 0, timestamp: genesis})).toBe(0)
  })
})

describe('bps helpers', () => {
  it('rounds down, the direction redemption uses', () => {
    expect(bpsOf(9_999n, 100)).toBe(99n)
    expect(netOfBps(9_999n, 100)).toBe(9_899n)
  })
})
