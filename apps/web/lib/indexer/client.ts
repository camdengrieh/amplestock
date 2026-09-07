// SPDX-License-Identifier: MIT

/**
 * The typed HTTP client for `apps/indexer`.
 *
 * Every method returns `IndexerResult<T>` rather than throwing, because an unreachable indexer is
 * a normal state for this app — the chain reads are the authority and the panels the indexer feeds
 * are history and aggregates. A failed fetch renders "indexer unavailable"; it never renders zero,
 * and it never blocks a trade.
 *
 * The routes are `docs/indexer.md` §7's typed HTTP layer, verbatim. Field-level shapes in
 * `./types` remain the dApp's requirement rather than a transcription of the indexer's own response
 * types, and every reader tolerates a missing field by rendering that panel as unavailable — so an
 * indexer that names a field differently costs one panel, not the page. `bigint` does not survive
 * `JSON.stringify`, so every numeric field crosses the wire as a decimal string.
 */

import type {
  BondBoardRow,
  BurnEvent,
  FlywheelMetrics,
  GateStatusRow,
  IndexerHealth,
  LadderFill,
  NavPoint,
  StakingStats,
  VaultSummary,
} from './types'

export const ENDPOINTS = {
  health: '/health',
  vaultSummary: '/api/vault',
  navHistory: '/api/nav-history',
  premiumHistory: '/api/premium-history',
  pools: '/api/pools',
  /** `/api/pools/:poolId/ladder` — the cell-by-cell ladder with fill and proceeds. */
  ladderFill: (poolId: string) => `/api/pools/${poolId}/ladder`,
  bondBoard: '/api/bonds',
  bondPositions: (owner: string) => `/api/bonds/positions/${owner}`,
  stakingStats: '/api/staking',
  flywheel: '/api/flywheel',
  gateStatus: '/api/gate',
  burnHistory: '/api/burns',
  constituents: '/api/constituents',
  parameters: '/api/parameters',
  reconciliation: '/api/reconciliation',
} as const

export type IndexerResult<T> = {ok: true; data: T} | {ok: false; error: string; unavailable: boolean}

export interface IndexerClientOptions {
  baseUrl: string
  fetchImpl?: typeof fetch
  /** Abort a slow indexer rather than holding a panel open indefinitely. */
  timeoutMs?: number
}

export class IndexerClient {
  readonly baseUrl: string
  private readonly fetchImpl: typeof fetch
  private readonly timeoutMs: number

  constructor(options: IndexerClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, '')
    this.fetchImpl = options.fetchImpl ?? globalThis.fetch.bind(globalThis)
    this.timeoutMs = options.timeoutMs ?? 8_000
  }

  private async get<T>(path: string, query: Record<string, string | number | undefined> = {}): Promise<IndexerResult<T>> {
    if (this.baseUrl === '') {
      return {ok: false, error: 'No indexer configured', unavailable: true}
    }
    const url = new URL(`${this.baseUrl}${path}`)
    for (const [key, value] of Object.entries(query)) {
      if (value !== undefined) url.searchParams.set(key, String(value))
    }
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), this.timeoutMs)
    try {
      const response = await this.fetchImpl(url.toString(), {
        signal: controller.signal,
        headers: {accept: 'application/json'},
      })
      if (!response.ok) {
        return {ok: false, error: `Indexer responded ${response.status}`, unavailable: response.status >= 500}
      }
      const data = (await response.json()) as T
      return {ok: true, data}
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return {ok: false, error: message, unavailable: true}
    } finally {
      clearTimeout(timer)
    }
  }

  health(): Promise<IndexerResult<IndexerHealth>> {
    return this.get<IndexerHealth>(ENDPOINTS.health)
  }

  vaultSummary(): Promise<IndexerResult<VaultSummary>> {
    return this.get<VaultSummary>(ENDPOINTS.vaultSummary)
  }

  /** NAV/share, `A` and `T` over time, oldest first. */
  navHistory(params: {since?: number; limit?: number} = {}): Promise<IndexerResult<NavPoint[]>> {
    return this.get<NavPoint[]>(ENDPOINTS.navHistory, {since: params.since, limit: params.limit ?? 500})
  }

  /** Every registered pool with its live state and ladder totals. */
  pools(): Promise<IndexerResult<LadderFill[]>> {
    return this.get<LadderFill[]>(ENDPOINTS.pools)
  }

  /** One pool's ladder, cell by cell: side, liquidity, principal, fill, proceeds. */
  ladderFill(poolId: string): Promise<IndexerResult<LadderFill>> {
    return this.get<LadderFill>(ENDPOINTS.ladderFill(poolId))
  }

  bondBoard(): Promise<IndexerResult<BondBoardRow[]>> {
    return this.get<BondBoardRow[]>(ENDPOINTS.bondBoard)
  }

  stakingStats(): Promise<IndexerResult<StakingStats>> {
    return this.get<StakingStats>(ENDPOINTS.stakingStats)
  }

  flywheel(params: {days?: number} = {}): Promise<IndexerResult<FlywheelMetrics>> {
    return this.get<FlywheelMetrics>(ENDPOINTS.flywheel, {days: params.days})
  }

  gateStatus(): Promise<IndexerResult<GateStatusRow[]>> {
    return this.get<GateStatusRow[]>(ENDPOINTS.gateStatus)
  }

  /** Burn history by reason, with the total. */
  burnHistory(params: {reason?: string} = {}): Promise<IndexerResult<BurnEvent[]>> {
    return this.get<BurnEvent[]>(ENDPOINTS.burnHistory, {reason: params.reason})
  }
}

/** A client that reports "no indexer configured" for everything. The default in development. */
export const nullIndexerClient = new IndexerClient({baseUrl: ''})

export function createIndexerClient(baseUrl: string, fetchImpl?: typeof fetch): IndexerClient {
  return new IndexerClient({baseUrl, ...(fetchImpl ? {fetchImpl} : {})})
}
