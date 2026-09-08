// SPDX-License-Identifier: MIT

/**
 * The typed HTTP client for `apps/indexer`.
 *
 * Every method returns `IndexerResult<T>` rather than throwing, because an unreachable indexer is
 * a normal state for this app — the chain reads are the authority and the panels the indexer feeds
 * are history and aggregates. A failed fetch renders "indexer unavailable"; it never renders zero,
 * and it never blocks a trade.
 *
 * The routes are `docs/indexer.md` §7's typed HTTP layer, verbatim, and `./types` is a
 * transcription of what those routes return rather than a wish list. Every reader still tolerates a
 * missing field by rendering that panel as unavailable, so an indexer that renames a field costs
 * one panel and not the page. `bigint` does not survive `JSON.stringify`, so every numeric field
 * crosses the wire as a decimal string.
 *
 * **The `/api/*` layer answers named envelopes, not bare arrays** — `{points}`, `{pools}`,
 * `{burns, total, count}`, `{status, transitions}`. The methods below unwrap them, so a surface
 * holds the rows and never an envelope; an envelope whose key is absent unwraps to an empty list
 * rather than to `undefined`, because "the indexer answered and there is nothing" and "the indexer
 * did not answer" are different states and only the second is an unavailability.
 */

import type {
  BondsResponse,
  BurnHistory,
  CreatorFeeStatus,
  FlywheelResponse,
  GateResponse,
  IndexerHealth,
  LadderDetail,
  NavPoint,
  PointsResponse,
  PoolRow,
  PoolsResponse,
  PremiumPoint,
  VaultResponse,
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
  flywheel: '/api/flywheel',
  gateStatus: '/api/gate',
  burnHistory: '/api/burns',
  /** The creator schedule and what it has paid in each currency. */
  creatorFee: '/api/creator-fee',
  supply: '/api/supply',
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

  /** The vault summary, the last share sample and the last NAV reconciliation, in one call. */
  vaultSummary(): Promise<IndexerResult<VaultResponse>> {
    return this.get<VaultResponse>(ENDPOINTS.vaultSummary)
  }

  /** NAV/share, `A` and `T` over time, oldest first. */
  async navHistory(params: {since?: number; limit?: number} = {}): Promise<IndexerResult<readonly NavPoint[]>> {
    return unwrap(
      await this.get<PointsResponse<NavPoint>>(ENDPOINTS.navHistory, {
        since: params.since,
        limit: params.limit ?? 500,
      }),
      (data) => data.points ?? [],
    )
  }

  /** `P_ref`, `P_mkt` and the premium over time, oldest first. */
  async premiumHistory(params: {since?: number; limit?: number} = {}): Promise<IndexerResult<readonly PremiumPoint[]>> {
    return unwrap(
      await this.get<PointsResponse<PremiumPoint>>(ENDPOINTS.premiumHistory, {
        since: params.since,
        limit: params.limit ?? 500,
      }),
      (data) => data.points ?? [],
    )
  }

  /** Every registered pool with its live state and ladder totals — not its cells. */
  async pools(): Promise<IndexerResult<readonly PoolRow[]>> {
    return unwrap(await this.get<PoolsResponse>(ENDPOINTS.pools), (data) => data.pools ?? [])
  }

  /** One pool's ladder, cell by cell: side, liquidity, principal, fill, proceeds. */
  ladderFill(poolId: string): Promise<IndexerResult<LadderDetail>> {
    return this.get<LadderDetail>(ENDPOINTS.ladderFill(poolId))
  }

  bondBoard(): Promise<IndexerResult<BondsResponse>> {
    return this.get<BondsResponse>(ENDPOINTS.bondBoard)
  }

  flywheel(params: {days?: number} = {}): Promise<IndexerResult<FlywheelResponse>> {
    return this.get<FlywheelResponse>(ENDPOINTS.flywheel, {days: params.days})
  }

  gateStatus(): Promise<IndexerResult<GateResponse>> {
    return this.get<GateResponse>(ENDPOINTS.gateStatus)
  }

  /** Burn history by reason, with the running total and the count behind it. */
  burnHistory(params: {reason?: string} = {}): Promise<IndexerResult<BurnHistory>> {
    return this.get<BurnHistory>(ENDPOINTS.burnHistory, {reason: params.reason})
  }

  /**
   * The creator schedule and what it has paid, in each currency.
   *
   * Revision 6 pays the creator in kind out of every currency's fees, so the answer has two paid
   * totals — AMPS and a USD aggregate of the counter assets — and the surface shows both rather
   * than adding them into one number that would be neither.
   */
  creatorFee(): Promise<IndexerResult<CreatorFeeStatus>> {
    return this.get<CreatorFeeStatus>(ENDPOINTS.creatorFee)
  }
}

/** Map a successful result's payload; a failure passes through untouched. */
function unwrap<T, U>(result: IndexerResult<T>, pick: (data: T) => U): IndexerResult<U> {
  return result.ok ? {ok: true, data: pick(result.data)} : result
}

/** A client that reports "no indexer configured" for everything. The default in development. */
export const nullIndexerClient = new IndexerClient({baseUrl: ''})

export function createIndexerClient(baseUrl: string, fetchImpl?: typeof fetch): IndexerClient {
  return new IndexerClient({baseUrl, ...(fetchImpl ? {fetchImpl} : {})})
}
