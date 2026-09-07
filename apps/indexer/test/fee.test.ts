// SPDX-License-Identifier: MIT

/**
 * The fee-decoding rules of `docs/phase3-state-model.md` §1.4, pinned against synthetic swaps.
 */

import {describe, expect, it} from 'vitest'

import {blendedBaseBps, decodeSwapFee, isSell} from '../src/lib/fee'

const WAD = 10n ** 18n

describe('direction', () => {
  it('reads a sell off the sign of amount0, because AMPS is currency0 in all 32 pools', () => {
    // The swapper paid 100 AMPS and received 95 USDG: amount0 negative, amount1 positive.
    expect(isSell(-100n * WAD, 95n * 10n ** 6n)).toBe(true)
  })

  it('reads a buy the same way', () => {
    expect(isSell(100n * WAD, -95n * 10n ** 6n)).toBe(false)
  })

  it('falls back to the counter leg on a degenerate zero-amount0 swap', () => {
    expect(isSell(0n, 1n)).toBe(true)
    expect(isSell(0n, -1n)).toBe(false)
  })
})

describe('base fee', () => {
  it('charges sellFeeBps on an uncredited sell', () => {
    const fee = decodeSwapFee({
      amount0: -100n * WAD,
      amount1: 95n * 10n ** 6n,
      feePips: 50_000, // 500 bp
      sellFeeBps: 500,
      buyFeeBps: 30,
    })
    expect(fee.sell).toBe(true)
    expect(fee.baseFeeBps).toBe(500)
    expect(fee.dynamicFeeBps).toBe(0)
    expect(fee.feeBps).toBe(500)
  })

  it('charges the pool buyFeeBps on a buy', () => {
    const fee = decodeSwapFee({
      amount0: 100n * WAD,
      amount1: -95n * 10n ** 6n,
      feePips: 3_000, // 30 bp
      sellFeeBps: 500,
      buyFeeBps: 30,
    })
    expect(fee.sell).toBe(false)
    expect(fee.baseFeeBps).toBe(30)
    expect(fee.dynamicFeeBps).toBe(0)
    expect(fee.ampsAmount).toBe(100n * WAD)
    expect(fee.counterAmount).toBe(95n * 10n ** 6n)
  })

  it('takes the blend from the hook rather than recomputing it', () => {
    const fee = decodeSwapFee({
      amount0: -100n * WAD,
      amount1: 95n * 10n ** 6n,
      feePips: 3_000,
      sellFeeBps: 500,
      buyFeeBps: 30,
      credit: {consumed: 100n * WAD, blendedFeeBps: 30},
    })
    expect(fee.credited).toBe(true)
    expect(fee.creditedAmount).toBe(100n * WAD)
    expect(fee.baseFeeBps).toBe(30)
    expect(fee.dynamicFeeBps).toBe(0)
  })

  it('ignores a credit on a buy — only AMPS-in swaps consume one', () => {
    const fee = decodeSwapFee({
      amount0: 100n * WAD,
      amount1: -95n * 10n ** 6n,
      feePips: 3_000,
      sellFeeBps: 500,
      buyFeeBps: 30,
      credit: {consumed: 10n * WAD, blendedFeeBps: 30},
    })
    expect(fee.credited).toBe(false)
    expect(fee.creditedAmount).toBe(0n)
  })
})

describe('the §1.4 blend itself', () => {
  it('is the buy fee when the credit covers the whole input', () => {
    expect(blendedBaseBps(500, 30, 100n, 100n)).toBe(30)
    expect(blendedBaseBps(500, 30, 100n, 250n)).toBe(30)
  })

  it('is the sell fee when there is no credit', () => {
    expect(blendedBaseBps(500, 30, 100n, 0n)).toBe(500)
  })

  it('rounds up, so a credit never rounds the fee down in the swapper favour', () => {
    // Half covered: buy + ceil((500-30) * 50 / 100) = 30 + 235 = 265.
    expect(blendedBaseBps(500, 30, 100n, 50n)).toBe(265)
    // One-third covered rounds up rather than to 343.33 -> 343.
    expect(blendedBaseBps(500, 30, 3n, 1n)).toBe(30 + Math.ceil((470 * 2) / 3))
  })

  it('does not overflow on an input the naive form would break on', () => {
    const huge = 2n ** 200n
    expect(blendedBaseBps(600, 1, huge, huge / 2n)).toBe(1 + Math.ceil(599 / 2))
  })
})

describe('dynamic component', () => {
  it('is the residual against what v4 actually charged', () => {
    const fee = decodeSwapFee({
      amount0: -100n * WAD,
      amount1: 95n * 10n ** 6n,
      feePips: 62_500, // 625 bp: 500 base + 125 dynamic
      sellFeeBps: 500,
      buyFeeBps: 30,
    })
    expect(fee.feeBps).toBe(625)
    expect(fee.baseFeeBps).toBe(500)
    expect(fee.dynamicFeeBps).toBe(125)
  })

  it('floors at zero rather than going negative when the base moved between blocks', () => {
    const fee = decodeSwapFee({
      amount0: -100n * WAD,
      amount1: 95n * 10n ** 6n,
      feePips: 10_000, // 100 bp charged
      sellFeeBps: 500, // stale base
      buyFeeBps: 30,
    })
    expect(fee.dynamicFeeBps).toBe(0)
  })
})

describe('fee amount', () => {
  it('is the gross input times the pip rate, rounded up', () => {
    const fee = decodeSwapFee({
      amount0: -100n * WAD,
      amount1: 95n * 10n ** 6n,
      feePips: 50_000,
      sellFeeBps: 500,
      buyFeeBps: 30,
    })
    // 100 AMPS x 5% = 5 AMPS.
    expect(fee.feeAmount).toBe(5n * WAD)
    expect(fee.feeAmps).toBe(5n * WAD)
  })

  it('is zero in AMPS on a buy, where the fee is taken in the counter', () => {
    const fee = decodeSwapFee({
      amount0: 100n * WAD,
      amount1: -1_000n * 10n ** 6n,
      feePips: 3_000,
      sellFeeBps: 500,
      buyFeeBps: 30,
    })
    expect(fee.feeAmps).toBe(0n)
    expect(fee.feeAmount).toBe(3n * 10n ** 6n)
  })
})
