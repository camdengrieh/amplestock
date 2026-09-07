// SPDX-License-Identifier: MIT
import {AMPS_MAINNET_CHAIN_ID, AMPS_TESTNET_CHAIN_ID} from '@amplestocks/config'
import {describe, expect, it} from 'vitest'

import {UNAVAILABLE} from '@/lib/format'
import {figuresIn, headingId, type Block} from '@/lib/docs/blocks'
import {FIGURES, FIGURE_IDS, isFigureId, type FigureId} from '@/lib/docs/figures'
import {GROUPS, PAGES, PAGES_BY_SLUG, READING_ORDER, neighbours, pagesInGroup} from '@/lib/docs/pages'
import {REASONS, resolveDocFigures, type DocsChainReads} from '@/lib/docs/resolve'

const VALID = '0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99' as const

/**
 * The documentation's contract with itself.
 *
 * One rule, tested from three directions: **a figure in the docs is read from a source or it is not
 * printed.** A `rows` or `table` cell may name a figure id or carry prose, and prose may not carry a
 * figure — otherwise a number typed into a page in September is still on the page in December,
 * looking exactly as authoritative as the live one next to it.
 */
describe('the pages are well formed', () => {
  it('has a page in every group and a group for every page', () => {
    for (const group of GROUPS) {
      expect(pagesInGroup(group.id).length).toBeGreaterThan(0)
    }
    const groupIds = GROUPS.map((g) => g.id)
    for (const page of PAGES) {
      expect(groupIds).toContain(page.group)
    }
  })

  it('has unique slugs, and the index agrees with the list', () => {
    const slugs = PAGES.map((p) => p.slug)
    expect(new Set(slugs).size).toBe(slugs.length)
    for (const page of PAGES) expect(PAGES_BY_SLUG[page.slug]).toBe(page)
  })

  it('gives every page a title, a kicker and a lede', () => {
    for (const page of PAGES) {
      expect(page.title.length).toBeGreaterThan(0)
      expect(page.kicker.length).toBeGreaterThan(0)
      expect(page.lede.length).toBeGreaterThan(0)
      expect(page.blocks.length).toBeGreaterThan(0)
    }
  })

  it('pages forward and backward through the whole reading order', () => {
    // Reading order is the groups in order, exactly as the design derives it — not the order the
    // page list happens to be written in — so the sidebar and the pager can never disagree.
    expect(READING_ORDER.length).toBe(PAGES.length)
    expect(READING_ORDER.map((page) => page.group)).toEqual(
      GROUPS.flatMap((group) => pagesInGroup(group.id).map(() => group.id)),
    )
    const first = READING_ORDER[0]!
    const last = READING_ORDER[READING_ORDER.length - 1]!
    expect(neighbours(first.slug).prev).toBeNull()
    expect(neighbours(first.slug).next?.slug).toBe(READING_ORDER[1]!.slug)
    expect(neighbours(last.slug).next).toBeNull()
    expect(neighbours('not-a-page')).toEqual({prev: null, next: null})
  })

  it('gives every page a source for the rail', () => {
    for (const page of PAGES) {
      expect(page.source.length, `${page.slug} has no source`).toBeGreaterThan(0)
    }
  })

  it('gives every h2 a unique anchor for the on-this-page rail', () => {
    for (const page of PAGES) {
      const ids = page.blocks.filter((b): b is Extract<Block, {kind: 'h'}> => b.kind === 'h').map(headingId)
      expect(new Set(ids).size).toBe(ids.length)
      for (const id of ids) expect(id).toMatch(/^[a-z0-9-]+$/)
    }
  })

  it('covers the revision-6 surfaces, and has no staking page', () => {
    const slugs = PAGES.map((p) => p.slug)
    for (const slug of ['overview', 'auction', 'fees', 'pass-through', 'bonds', 'governance', 'addresses']) {
      expect(slugs).toContain(slug)
    }
    expect(slugs).not.toContain('staking')
    const everything = JSON.stringify(PAGES)
    // xAMPS does not exist at all under revision 6, so it is not sayable even in the negative.
    expect(everything).not.toMatch(/xAMPS/)
    // `burnBps` and `stakerBps` may only appear in the sentence that says they are gone.
    for (const removed of ['burnBps', 'stakerBps']) {
      for (const sentence of everything.split('.').filter((s) => s.includes(removed))) {
        expect(sentence, `${removed} named outside the sentence that removes it`).toMatch(/There is no/)
      }
    }
  })
})

describe('every figure a page names is in the catalogue', () => {
  it.each(PAGES.map((page) => [page.slug, page] as const))('%s', (_slug, page) => {
    for (const id of figuresIn(page.blocks)) {
      expect(isFigureId(id), `unknown figure id: ${id}`).toBe(true)
    }
  })

  it('describes every catalogue entry with a label and a source', () => {
    for (const id of FIGURE_IDS) {
      const spec = FIGURES[id]
      expect(spec.label.length, id).toBeGreaterThan(0)
      expect(spec.from.length, id).toBeGreaterThan(0)
      expect(['chain', 'config', 'deployment']).toContain(spec.source)
    }
  })

  it('leaves no catalogue entry unused by the documentation', () => {
    const used = new Set(PAGES.flatMap((page) => figuresIn(page.blocks)))
    const unused = FIGURE_IDS.filter((id) => !used.has(id))
    expect(unused, 'figures in the catalogue that no page prints').toEqual([])
  })
})

describe('a rows or table cell never carries a literal figure', () => {
  // Prose in a cell is allowed — "per pool", "immutable — no setter" — but a percentage, an amount
  // or an address in one would be a number that no source can be checked against.
  const LOOKS_LIKE_DATA = /\d+(\.\d+)?\s*%|0x[0-9a-fA-F]{6,}|\$\s?\d/
  it.each(PAGES.map((page) => [page.slug, page] as const))('%s', (_slug, page) => {
    for (const block of page.blocks) {
      if (block.kind === 'rows') {
        for (const row of block.rows) {
          if (row.text) expect(row.text, `${row.label}`).not.toMatch(LOOKS_LIKE_DATA)
        }
      }
      if (block.kind === 'table') {
        for (const row of block.rows) {
          for (const cell of row) {
            if (cell.text) expect(cell.text).not.toMatch(LOOKS_LIKE_DATA)
          }
        }
      }
    }
  })
})

describe('resolving with nothing available', () => {
  const nothing = resolveDocFigures({
    chainId: AMPS_TESTNET_CHAIN_ID,
    deployment: {},
    auctions: {},
    reads: {},
  })

  it('answers for every id in the catalogue', () => {
    for (const id of FIGURE_IDS) {
      expect(nothing[id], id).toBeDefined()
    }
  })

  it('prints nothing that has no source, and gives a reason for each', () => {
    // The launch parameters are compiled into `@amplestocks/config`, so they resolve with no chain
    // at all. Everything else must be unavailable when nothing has answered.
    const alwaysAvailable = FIGURE_IDS.filter((id) => FIGURES[id].source === 'config' && !id.startsWith('ref'))
    for (const id of FIGURE_IDS) {
      const resolved = nothing[id]
      if (alwaysAvailable.includes(id)) {
        expect(resolved.status, id).toBe('value')
        continue
      }
      expect(resolved.status, `${id} printed a value with no source`).toBe('unavailable')
      if (resolved.status === 'unavailable') expect(resolved.reason.length, id).toBeGreaterThan(0)
    }
  })

  it('never renders a zero for a missing figure', () => {
    for (const id of FIGURE_IDS) {
      const resolved = nothing[id]
      if (resolved.status !== 'value') continue
      expect(resolved.text, id).not.toBe('0')
      expect(resolved.text, id).not.toBe('0.00%')
      expect(resolved.text, id).not.toBe('$0.00')
    }
  })

  it('names the source that did not answer', () => {
    expect(nothing.ampsFee).toEqual({status: 'unavailable', reason: REASONS.chain})
    expect(nothing.addrVault).toEqual({status: 'unavailable', reason: REASONS.deployment})
    // 46630 has no verified reference book, and this must not borrow mainnet's.
    expect(nothing.refPoolManager).toEqual({status: 'unavailable', reason: REASONS.config})
    expect(nothing.auctionUsdgAddress).toEqual({status: 'unavailable', reason: REASONS.deployment})
  })
})

describe('resolving with sources present', () => {
  const reads: DocsChainReads = {
    ampsFeeBps: 500,
    ampsFeeBand: {min: 100, max: 600},
    redeemFeeBps: 250,
    redeemFeeBpsMax: 500,
    navPerShareX18: 10n ** 18n,
    pRefX18: 1_120_000_000_000_000_000n,
    pMktX18: 1_150_000_000_000_000_000n,
    liveCells: 14,
    bondVestSeconds: 43_200,
    poolCount: 32,
    auctions: {
      usdg: {
        phase: 'Live',
        clearingPriceX18: 10n ** 18n,
        currencySymbol: 'USDG',
        raised: 5_000_000_000n,
        currencyDecimals: 6,
        trancheSupply: 3_325n * 10n ** 18n,
        isGraduated: true,
      },
    },
  }

  const resolved = resolveDocFigures({
    chainId: AMPS_MAINNET_CHAIN_ID,
    deployment: {vault: VALID, router: VALID},
    auctions: {usdg: VALID},
    reads,
  })

  it('formats a live percentage rather than restating the raw bps', () => {
    expect(resolved.ampsFee).toEqual({status: 'value', text: '5.00%'})
    expect(resolved.ampsFeeBand).toEqual({status: 'value', text: '1.00% – 6.00%'})
  })

  it('carries the redemption fee live, never the launch value', () => {
    // 2.5% is what revision 6 moves it to; the point is that the number came from the read.
    expect(resolved.redeemFee).toEqual({status: 'value', text: '2.50%'})
    expect(resolved.redeemFeeMax).toEqual({status: 'value', text: '5.00%'})
  })

  it('serves an address that is configured and a dash for one that is not', () => {
    expect(resolved.addrVault).toEqual({status: 'value', text: VALID})
    expect(resolved.addrRouter).toEqual({status: 'value', text: VALID})
    expect(resolved.addrBonds.status).toBe('unavailable')
  })

  it('serves the reference book on the chain that has one', () => {
    expect(resolved.refPoolManager.status).toBe('value')
    expect(resolved.refUniversalRouter.status).toBe('value')
  })

  it('carries the auction figures that were read, and no others', () => {
    expect(resolved.auctionUsdgAddress).toEqual({status: 'value', text: VALID})
    expect(resolved.auctionUsdgPhase).toEqual({status: 'value', text: 'Live'})
    expect(resolved.auctionUsdgGraduated).toEqual({status: 'value', text: 'Yes'})
    expect(resolved.auctionUsdgClearing.status).toBe('value')
    // The ETH auction was not configured, so nothing about it is printed.
    expect(resolved.auctionEthAddress.status).toBe('unavailable')
    expect(resolved.auctionEthClearing.status).toBe('unavailable')
  })

  it('treats a market price of zero as no history rather than as a price', () => {
    const zeroed = resolveDocFigures({
      chainId: AMPS_MAINNET_CHAIN_ID,
      deployment: {},
      reads: {...reads, pMktX18: 0n},
    })
    expect(zeroed.pMkt).toEqual({status: 'unavailable', reason: REASONS.twap})
  })

  it('leaves a figure whose read failed unavailable while its neighbours resolve', () => {
    const partial = resolveDocFigures({chainId: AMPS_MAINNET_CHAIN_ID, deployment: {}, reads: {ampsFeeBps: 500}})
    expect(partial.ampsFee.status).toBe('value')
    expect(partial.redeemFee.status).toBe('unavailable')
    expect(partial.navPerShare).toEqual({status: 'unavailable', reason: REASONS.checkpoint})
  })
})

describe('the whole documentation renders against an empty chain', () => {
  it('resolves every figure every page names, with no gaps', () => {
    const resolved = resolveDocFigures({chainId: AMPS_TESTNET_CHAIN_ID, deployment: {}, reads: {}})
    const ids: FigureId[] = PAGES.flatMap((page) => figuresIn(page.blocks))
    expect(ids.length).toBeGreaterThan(40)
    for (const id of ids) {
      const value = resolved[id]
      expect(value, id).toBeDefined()
      expect(['value', 'unavailable']).toContain(value.status)
      if (value.status === 'value') expect(value.text).not.toBe(UNAVAILABLE)
    }
  })
})
