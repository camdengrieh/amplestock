// SPDX-License-Identifier: MIT
import {describe, expect, it, vi} from 'vitest'

import {ENDPOINTS, IndexerClient, nullIndexerClient} from '@/lib/indexer/client'

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as Response
}

describe('IndexerClient', () => {
  it('reports "no indexer configured" rather than fetching nowhere', async () => {
    const result = await nullIndexerClient.vaultSummary()
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.unavailable).toBe(true)
      expect(result.error).toMatch(/No indexer configured/)
    }
  })

  it('calls the documented endpoint and returns the body', async () => {
    const seen: string[] = []
    const fetchImpl = vi.fn(async (input: unknown) => {
      seen.push(String(input))
      return jsonResponse({navPerShareX18: '1000000000000000000'})
    })
    const client = new IndexerClient({baseUrl: 'https://indexer.invalid/', fetchImpl: fetchImpl as unknown as typeof fetch})
    const result = await client.vaultSummary()
    expect(result.ok).toBe(true)
    expect(fetchImpl).toHaveBeenCalledOnce()
    expect(seen[0]).toBe(`https://indexer.invalid${ENDPOINTS.vaultSummary}`)
  })

  it('passes query parameters for the windowed endpoints', async () => {
    const seen: string[] = []
    const fetchImpl = vi.fn(async (input: unknown) => {
      seen.push(String(input))
      return jsonResponse([])
    })
    const client = new IndexerClient({baseUrl: 'https://indexer.invalid', fetchImpl: fetchImpl as unknown as typeof fetch})
    await client.navHistory({since: 100, limit: 50})
    const url = new URL(seen[0]!)
    expect(url.pathname).toBe(ENDPOINTS.navHistory)
    expect(url.searchParams.get('since')).toBe('100')
    expect(url.searchParams.get('limit')).toBe('50')
  })

  it('never throws on a network failure — an unreachable indexer is a normal state', async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error('ECONNREFUSED')
    })
    const client = new IndexerClient({baseUrl: 'https://indexer.invalid', fetchImpl: fetchImpl as unknown as typeof fetch})
    const result = await client.burnHistory()
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.unavailable).toBe(true)
      expect(result.error).toMatch(/ECONNREFUSED/)
    }
  })

  it('distinguishes a 4xx from a 5xx', async () => {
    const notFound = new IndexerClient({
      baseUrl: 'https://indexer.invalid',
      fetchImpl: (async () => jsonResponse({}, 404)) as unknown as typeof fetch,
    })
    const broken = new IndexerClient({
      baseUrl: 'https://indexer.invalid',
      fetchImpl: (async () => jsonResponse({}, 503)) as unknown as typeof fetch,
    })
    const a = await notFound.gateStatus()
    const b = await broken.gateStatus()
    expect(a.ok).toBe(false)
    expect(b.ok).toBe(false)
    if (!a.ok) expect(a.unavailable).toBe(false)
    if (!b.ok) expect(b.unavailable).toBe(true)
  })

  it('uses the routes docs/indexer.md §7 publishes, verbatim', () => {
    expect(ENDPOINTS.vaultSummary).toBe('/api/vault')
    expect(ENDPOINTS.navHistory).toBe('/api/nav-history')
    expect(ENDPOINTS.pools).toBe('/api/pools')
    expect(ENDPOINTS.ladderFill('0xabc')).toBe('/api/pools/0xabc/ladder')
    expect(ENDPOINTS.bondBoard).toBe('/api/bonds')
    expect(ENDPOINTS.bondPositions('0x1')).toBe('/api/bonds/positions/0x1')
    expect(ENDPOINTS.stakingStats).toBe('/api/staking')
    expect(ENDPOINTS.flywheel).toBe('/api/flywheel')
    expect(ENDPOINTS.gateStatus).toBe('/api/gate')
    expect(ENDPOINTS.burnHistory).toBe('/api/burns')
  })

  it('covers every panel the plan names for the dApp', () => {
    for (const key of [
      'vaultSummary',
      'navHistory',
      'ladderFill',
      'bondBoard',
      'stakingStats',
      'flywheel',
      'gateStatus',
      'burnHistory',
    ] as const) {
      expect(ENDPOINTS[key]).toBeDefined()
    }
  })
})
