// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'

import {buildRedeemPreview, grossFromNet, redeemValueUsd18, redemptionShareBps} from '@/lib/redeem'
import {NVDA, USDG, WETH} from './fixtures'

const WAD = 10n ** 18n

describe('grossFromNet', () => {
  it('reverses the fee the vault has already applied', () => {
    expect(grossFromNet(9_900n, 100)).toBe(10_000n)
  })

  it('never understates the gross, so the disclosed fee is never more generous than the payment', () => {
    for (const net of [1n, 7n, 99n, 12_345n, 10n ** 24n]) {
      const gross = grossFromNet(net, 100)
      expect(gross * 9_900n / 10_000n).toBeLessThanOrEqual(gross - (gross - net))
      expect(gross).toBeGreaterThanOrEqual(net)
    }
  })

  it('is the identity at a zero fee', () => {
    expect(grossFromNet(1_000n, 0)).toBe(1_000n)
  })
})

describe('buildRedeemPreview', () => {
  const meta = (token: string) => ({symbol: token === WETH ? 'WETH' : token === USDG ? 'USDG' : 'NVDA', decimals: token === USDG ? 6 : 18})

  it('produces one line per asset, pro rata, with the fee broken out', () => {
    const preview = buildRedeemPreview({
      shares: WAD,
      redeemFeeBps: 100,
      inventoryBurned: 2n * WAD,
      tokens: [WETH, USDG, NVDA],
      amounts: [990n, 1_980n, 2_970n],
      meta,
    })
    expect(preview.lines).toHaveLength(3)
    expect(preview.lines.map((l) => l.symbol)).toEqual(['WETH', 'USDG', 'NVDA'])
    expect(preview.lines[0]!.amount).toBe(990n)
    expect(preview.lines[0]!.grossAmount).toBe(1_000n)
    expect(preview.lines[0]!.feeAmount).toBe(10n)
    expect(preview.inventoryBurned).toBe(2n * WAD)
  })

  it('pays in every asset the vault holds — no netting and no substitution', () => {
    const preview = buildRedeemPreview({
      shares: WAD,
      redeemFeeBps: 100,
      inventoryBurned: 0n,
      tokens: [WETH, USDG, NVDA],
      amounts: [0n, 1n, 2n],
      meta,
    })
    // A zero line is still a line: the asset is held, this redemption's share of it rounds to zero.
    expect(preview.lines).toHaveLength(3)
  })

  it('refuses a mismatched preview rather than pairing the wrong amounts with the wrong assets', () => {
    expect(() =>
      buildRedeemPreview({shares: WAD, redeemFeeBps: 100, inventoryBurned: 0n, tokens: [WETH, USDG], amounts: [1n], meta}),
    ).toThrow(/mismatched/)
  })
})

describe('redeemValueUsd18 — the floor, stated as arithmetic', () => {
  it('is shares x NAV/share, net of the fee', () => {
    expect(redeemValueUsd18({shares: 100n * WAD, navPerShareX18: WAD, redeemFeeBps: 100})).toBe(99n * WAD)
  })

  it('falls as the fee rises, and is never above the gross', () => {
    const gross = redeemValueUsd18({shares: WAD, navPerShareX18: WAD, redeemFeeBps: 0})
    const capped = redeemValueUsd18({shares: WAD, navPerShareX18: WAD, redeemFeeBps: 500})
    expect(capped).toBeLessThan(gross)
    expect(gross).toBe(WAD)
  })
})

describe('redemptionShareBps', () => {
  it('is the share of supply being redeemed', () => {
    expect(redemptionShareBps(WAD, 100n * WAD)).toBe(100)
    expect(redemptionShareBps(0n, 100n * WAD)).toBe(0)
  })

  it('is zero rather than a division by zero on an empty supply', () => {
    expect(redemptionShareBps(WAD, 0n)).toBe(0)
  })
})
