// SPDX-License-Identifier: MIT

/**
 * The tick and liquidity maths, and the small fixed-point helpers.
 *
 * The `sqrtPriceX96AtTick` values are the canonical `TickMath` outputs; `amountsForLiquidity` is
 * checked against the closed forms and against the property that matters for the ladder: an ask
 * bucket below the price is pure AMPS, above it is pure counter, and the crossing is monotone.
 */

import {describe, expect, it} from 'vitest'

import {
  GRID_CELLS,
  GRID_MIN_M,
  cellIndexOf,
  doublingIndexOf,
  doublingTicks,
} from '../src/lib/constants'
import {
  Q96,
  amountsForLiquidity,
  changeBps,
  clampInt,
  creatorBpsAt,
  divergenceBps,
  premiumBps,
  premiumX18,
  priceX18FromSqrt,
  sqrtPriceX96AtTick,
  to18,
} from '../src/lib/math'

const WAD = 10n ** 18n

describe('sqrtPriceX96AtTick', () => {
  it('is exactly 2^96 at tick zero', () => {
    expect(sqrtPriceX96AtTick(0)).toBe(Q96)
  })

  it('matches TickMath at the canonical bounds', () => {
    expect(sqrtPriceX96AtTick(-887272)).toBe(4295128739n)
    expect(sqrtPriceX96AtTick(887272)).toBe(1461446703485210103287273052203988822378723970342n)
  })

  it('is monotone and doubles the price roughly every 6932 ticks', () => {
    const a = sqrtPriceX96AtTick(0)
    const b = sqrtPriceX96AtTick(6932)
    expect(b).toBeGreaterThan(a)
    // (sqrt ratio)^2 should be ~2.
    const ratioX18 = (b * b * WAD) / (a * a)
    expect(ratioX18).toBeGreaterThan(1_999_000_000_000_000_000n)
    expect(ratioX18).toBeLessThan(2_001_000_000_000_000_000n)
  })

  it('rejects a tick outside the usable range', () => {
    expect(() => sqrtPriceX96AtTick(900_000)).toThrow()
  })
})

describe('amountsForLiquidity — the ladder decomposition', () => {
  const lower = 0
  const upper = 6960
  const L = 10n ** 18n

  it('is pure AMPS below the range: an unfilled ask', () => {
    const {amount0, amount1} = amountsForLiquidity(sqrtPriceX96AtTick(lower - 60), lower, upper, L)
    expect(amount1).toBe(0n)
    expect(amount0).toBeGreaterThan(0n)
  })

  it('is pure counter above the range: a fully raised ask', () => {
    const {amount0, amount1} = amountsForLiquidity(sqrtPriceX96AtTick(upper + 60), lower, upper, L)
    expect(amount0).toBe(0n)
    expect(amount1).toBeGreaterThan(0n)
  })

  it('is a monotone mix through the range, which is the fill fraction', () => {
    const full = amountsForLiquidity(sqrtPriceX96AtTick(lower), lower, upper, L).amount0
    let previous = full
    for (const tick of [1000, 2000, 3000, 4000, 5000, 6000, 6900]) {
      const {amount0, amount1} = amountsForLiquidity(sqrtPriceX96AtTick(tick), lower, upper, L)
      expect(amount0).toBeLessThan(previous)
      expect(amount1).toBeGreaterThan(0n)
      previous = amount0
    }
    expect(previous).toBeLessThan(full / 2n)
  })

  it('is zero for a removed cell', () => {
    expect(amountsForLiquidity(Q96, lower, upper, 0n)).toEqual({amount0: 0n, amount1: 0n})
  })
})

describe('the doubling grid', () => {
  it('rounds one doubling up to a whole tick spacing', () => {
    expect(doublingTicks(60)).toBe(6960)
    expect(doublingTicks(1)).toBe(6932)
    expect(doublingTicks(10)).toBe(6940)
    expect(doublingTicks(200)).toBe(7000)
  })

  it('rejects a non-positive spacing', () => {
    expect(() => doublingTicks(0)).toThrow()
  })

  it('maps a cell lower tick to its index, and rejects an off-grid tick', () => {
    const base = 0
    expect(cellIndexOf(0, base, 60)).toBe(-GRID_MIN_M)
    expect(cellIndexOf(6960, base, 60)).toBe(-GRID_MIN_M + 1)
    expect(cellIndexOf(-6960, base, 60)).toBe(-GRID_MIN_M - 1)
    expect(cellIndexOf(60, base, 60)).toBe(-1)
    // Out of the [GRID_MIN_M, GRID_MAX_M) window.
    expect(cellIndexOf(6960 * 20, base, 60)).toBe(-1)
    expect(cellIndexOf(0, base, 60)).toBeLessThan(GRID_CELLS)
  })

  it('gives the signed doubling index even outside the window', () => {
    expect(doublingIndexOf(6960 * 3, 0, 60)).toBe(3)
    expect(doublingIndexOf(-6960 * 3, 0, 60)).toBe(-3)
  })
})

describe('fixed point', () => {
  it('reports a premium relative to NAV', () => {
    expect(premiumX18(WAD, (WAD * 105n) / 100n)).toBe(WAD / 20n)
    expect(premiumBps(WAD, (WAD * 105n) / 100n)).toBe(500)
    expect(premiumBps(0n, WAD)).toBe(0)
  })

  it('reports a signed change and an unsigned divergence in bps', () => {
    expect(changeBps(100n, 101n)).toBe(100)
    expect(changeBps(100n, 99n)).toBe(-100)
    expect(changeBps(0n, 99n)).toBe(0)
    expect(divergenceBps(100n, 99n)).toBe(100)
    expect(divergenceBps(99n, 100n)).toBe(100)
    expect(divergenceBps(0n, 0n)).toBe(0)
  })

  it('saturates rather than overflowing a 32-bit column', () => {
    expect(clampInt(10n ** 30n)).toBe(2_147_483_647)
    expect(clampInt(-(10n ** 30n))).toBe(-2_147_483_648)
  })

  it('decays the creator fee linearly to zero over 30 days', () => {
    const genesis = 1_000_000n
    const decay = 30n * 86_400n
    expect(creatorBpsAt(genesis, genesis, 100n, decay)).toBe(100)
    expect(creatorBpsAt(genesis + decay / 2n, genesis, 100n, decay)).toBe(50)
    expect(creatorBpsAt(genesis + decay, genesis, 100n, decay)).toBe(0)
    expect(creatorBpsAt(genesis + decay * 2n, genesis, 100n, decay)).toBe(0)
  })

  it('scales raw amounts to 18 decimals in both directions', () => {
    expect(to18(1_000_000n, 6)).toBe(WAD)
    expect(to18(WAD, 18)).toBe(WAD)
  })

  it('prices currency0 in currency1 with the decimals normalised', () => {
    // 1:1 sqrt price with an 18-decimal currency0 and a 6-decimal currency1 means 1e12 raw units
    // of currency1 per unit of currency0, i.e. a human price of 1e12.
    expect(priceX18FromSqrt(Q96, 18, 6)).toBe(10n ** 12n * WAD)
    expect(priceX18FromSqrt(0n, 18, 6)).toBe(0n)
  })
})
