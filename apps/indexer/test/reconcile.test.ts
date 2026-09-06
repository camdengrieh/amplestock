// SPDX-License-Identifier: MIT

/**
 * The reconciliation rule and its dust bounds.
 */

import {describe, expect, it} from 'vitest'

import {reconcile, reconcileSeverity, withinDust} from '../src/lib/reconcile'

const WAD = 10n ** 18n
const BOUNDS = {dustBps: 2, dustWei: 10n ** 12n}

const base = {
  ...BOUNDS,
  trigger: 'interval' as const,
  navIndexedX18: WAD,
  navOnChainX18: WAD,
  navPreviewX18: WAD,
  pRefIndexedX18: WAD,
  pRefOnChainX18: WAD,
  supplyIndexed: 5_000n * WAD,
  supplyOnChain: 5_000n * WAD,
  inventoryIndexed: 4_750n * WAD,
  inventoryOnChain: 4_750n * WAD,
  assetsIndexedUsd18: 5_000n * WAD,
  assetsOnChainUsd18: 5_000n * WAD,
}

describe('withinDust', () => {
  it('passes on the absolute bound even when the relative bound would fail', () => {
    // Two tiny numbers a wei apart: 5,000 bps of relative divergence, one wei of absolute.
    expect(withinDust(1n, 2n, BOUNDS)).toBe(true)
  })

  it('passes on the relative bound even when the absolute bound would fail', () => {
    // 1 bp of a very large number is far more than dustWei.
    const a = 10n ** 24n
    expect(withinDust(a, a + a / 20_000n, BOUNDS)).toBe(true)
  })

  it('fails when both bounds fail', () => {
    const a = 10n ** 24n
    expect(withinDust(a, a + a / 100n, BOUNDS)).toBe(false)
  })
})

describe('reconcile', () => {
  it('is ok when the two sides agree exactly', () => {
    const result = reconcile(base)
    expect(result.ok).toBe(true)
    expect(result.breached).toBe('')
    expect(result.navDeltaBps).toBe(0)
    expect(result.pRefDeltaBps).toBe(0)
  })

  it('is ok inside the dust bound', () => {
    const result = reconcile({...base, navOnChainX18: WAD + 999n * 10n ** 9n})
    expect(result.ok).toBe(true)
  })

  it('breaches on a NAV divergence past the bound and calls it critical', () => {
    const result = reconcile({...base, navOnChainX18: (WAD * 10_100n) / 10_000n})
    expect(result.ok).toBe(false)
    expect(result.breachedFields).toContain('nav')
    expect(result.navDeltaBps).toBeGreaterThan(2)
    expect(reconcileSeverity(result)).toBe('critical')
  })

  it('breaches on a P_ref divergence and calls that critical too', () => {
    const result = reconcile({...base, pRefOnChainX18: (WAD * 10_050n) / 10_000n})
    expect(result.ok).toBe(false)
    expect(result.breachedFields).toEqual(['pRef'])
    expect(reconcileSeverity(result)).toBe('critical')
  })

  it('breaches on a supply drift and calls that a warning', () => {
    const result = reconcile({...base, supplyOnChain: 6_000n * WAD})
    expect(result.ok).toBe(false)
    expect(result.breachedFields).toEqual(['supply'])
    expect(reconcileSeverity(result)).toBe('warning')
  })

  it('records but never breaches on the three pairs that are not comparable', () => {
    // `totalAssetsUsd18()` and `previewNavPerShareX18()` are live recomputations and `inventory` is
    // the same chain read on both sides; only their deltas are recorded.
    const result = reconcile({
      ...base,
      assetsOnChainUsd18: 9_999n * WAD,
      inventoryOnChain: 1n,
      navPreviewX18: WAD * 2n,
    })
    expect(result.ok).toBe(true)
    expect(result.assetsDeltaBps).toBeGreaterThan(0)
    expect(result.inventoryDeltaWei).toBeGreaterThan(0n)
    expect(result.previewDeltaBps).toBe(5_000)
  })

  it('joins several breaches with a plus', () => {
    const result = reconcile({
      ...base,
      navOnChainX18: WAD * 2n,
      pRefOnChainX18: WAD * 3n,
      supplyOnChain: 6_000n * WAD,
    })
    expect(result.breached).toBe('nav+pRef+supply')
  })

  it('records the preview divergence without ever breaching on it', () => {
    const result = reconcile({...base, navPreviewX18: WAD * 2n})
    expect(result.ok).toBe(true)
    expect(result.previewDeltaBps).toBe(5_000)
  })

  it('reports signed wei deltas', () => {
    const result = reconcile({...base, navOnChainX18: WAD - 1n})
    expect(result.navDeltaWei).toBe(1n)
    const other = reconcile({...base, navOnChainX18: WAD + 1n})
    expect(other.navDeltaWei).toBe(-1n)
  })
})
