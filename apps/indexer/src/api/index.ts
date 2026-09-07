// SPDX-License-Identifier: MIT

/**
 * The HTTP surface.
 *
 * Two layers, deliberately:
 *
 * - **`/graphql`** — Ponder's generated GraphQL over the whole schema. Anything the dApp wants that
 *   is not one of the endpoints below is one query away, and no endpoint has to be added to unblock
 *   a new chart.
 * - **`/api/*`** — a small typed layer for the shapes the dApp asks for repeatedly, where a
 *   hand-written SQL aggregate beats a client-side join over GraphQL pages: the vault summary, the
 *   NAV/share and premium history, the ladder per pool with its fill and proceeds, the bond board,
 *   the staking APR, the flywheel dashboard, gate status, burn history and the creator-fee
 *   remainder.
 *
 * Everything here is **read-only**. `db` from `ponder:api` is a `ReadonlyDrizzle`; there is no
 * write path in this process at all, which is what makes it safe to expose.
 *
 * `bigint` does not survive `JSON.stringify`, so every response goes through `json()` below, which
 * renders bigints as decimal strings. A consumer reading `"1000000000000000000"` and calling
 * `BigInt()` on it gets the exact value back; nothing is ever narrowed to a float on the way out.
 */

import {db} from 'ponder:api'
import schema from 'ponder:schema'
import {Hono, type Context as HonoContext} from 'hono'
import type {ContentfulStatusCode} from 'hono/utils/http-status'
import {and, desc, eq, graphql, gte, sql} from 'ponder'

import {SINGLETON} from '../lib/ids'

const app = new Hono()

/** JSON with bigints as decimal strings. */
const encode = (value: unknown): unknown => {
  if (typeof value === 'bigint') return value.toString()
  if (Array.isArray(value)) return value.map(encode)
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, encode(v)]))
  }
  return value
}

const json = (c: HonoContext, body: unknown, status: ContentfulStatusCode = 200) =>
  c.body(JSON.stringify(encode(body)), status, {'content-type': 'application/json'})

const limitOf = (raw: string | undefined, fallback = 200, max = 1000): number => {
  const n = Number(raw ?? fallback)
  if (!Number.isFinite(n) || n <= 0) return fallback
  return Math.min(Math.floor(n), max)
}

const sinceOf = (raw: string | undefined): bigint => {
  if (raw === undefined || raw.trim() === '') return 0n
  try {
    return BigInt(raw)
  } catch {
    return 0n
  }
}

// -------------------------------------------------------------------------------------------------
// GraphQL + liveness
// -------------------------------------------------------------------------------------------------

app.use('/graphql', graphql({db, schema}))
app.use('/', graphql({db, schema}))

// -------------------------------------------------------------------------------------------------
// Vault
// -------------------------------------------------------------------------------------------------

/** The Vault page's headline: NAV, `P_ref`, `P_mkt`, premium, shares by class, cumulative flows. */
app.get('/api/vault', async (c) => {
  const [summary] = await db.select().from(schema.vaultSummary).where(eq(schema.vaultSummary.id, SINGLETON))
  if (summary === undefined) return json(c, {error: 'not indexed yet'}, 404)
  const [shares] = await db
    .select()
    .from(schema.sharePoint)
    .orderBy(desc(schema.sharePoint.blockNumber))
    .limit(1)
  const [reconciliation] = await db
    .select()
    .from(schema.reconciliation)
    .orderBy(desc(schema.reconciliation.blockNumber))
    .limit(1)
  return json(c, {summary, shares: shares ?? null, reconciliation: reconciliation ?? null})
})

/** NAV/share, `A`, `T` over time. `?since=<block>&limit=<n>`. */
app.get('/api/nav-history', async (c) => {
  const rows = await db
    .select()
    .from(schema.navCheckpoint)
    .where(gte(schema.navCheckpoint.blockNumber, sinceOf(c.req.query('since'))))
    .orderBy(desc(schema.navCheckpoint.blockNumber))
    .limit(limitOf(c.req.query('limit')))
  return json(c, {points: rows.reverse()})
})

/** `P_ref`, `P_mkt` and the premium over time. */
app.get('/api/premium-history', async (c) => {
  const rows = await db
    .select()
    .from(schema.refCheckpoint)
    .where(gte(schema.refCheckpoint.blockNumber, sinceOf(c.req.query('since'))))
    .orderBy(desc(schema.refCheckpoint.blockNumber))
    .limit(limitOf(c.req.query('limit')))
  return json(c, {points: rows.reverse()})
})

/** Shares by class over time: circulating, inventory, vesting, staked, bond-unvested. */
app.get('/api/share-history', async (c) => {
  const rows = await db
    .select()
    .from(schema.sharePoint)
    .where(gte(schema.sharePoint.blockNumber, sinceOf(c.req.query('since'))))
    .orderBy(desc(schema.sharePoint.blockNumber))
    .limit(limitOf(c.req.query('limit')))
  return json(c, {points: rows.reverse()})
})

/** Net supply change since genesis, decomposed into the four things that move it. */
app.get('/api/supply', async (c) => {
  const [summary] = await db.select().from(schema.vaultSummary).where(eq(schema.vaultSummary.id, SINGLETON))
  if (summary === undefined) return json(c, {error: 'not indexed yet'}, 404)
  return json(c, {
    genesisMinted: summary.genesisMinted,
    bondIssued: summary.bondIssuedTotal,
    vestingMinted: summary.vestingMintedTotal,
    burned: summary.burnedAllTotal,
    netSupplyChange: summary.netSupplyChange,
    totalSupply: summary.totalSupply,
  })
})

/** Burn history, by reason. `?reason=compound`. */
app.get('/api/burns', async (c) => {
  const reason = c.req.query('reason')
  const base = db.select().from(schema.burnEvent)
  const rows = await (reason === undefined ? base : base.where(eq(schema.burnEvent.reason, reason)))
    .orderBy(desc(schema.burnEvent.blockNumber))
    .limit(limitOf(c.req.query('limit')))
  const [totals] = await db
    .select({
      total: sql<string>`coalesce(sum(${schema.burnEvent.amount}), 0)`,
      count: sql<number>`count(*)`,
    })
    .from(schema.burnEvent)
  return json(c, {burns: rows, total: totals?.total ?? '0', count: Number(totals?.count ?? 0)})
})

/**
 * The creator fee: the immutable 100 bp schedule decaying to zero 30 days after genesis, what has
 * been paid so far, and what is left of the *schedule* (not of a budget — there is no budget; the
 * fee is a rate carved out of the sell fee).
 */
app.get('/api/creator-fee', async (c) => {
  const [summary] = await db.select().from(schema.vaultSummary).where(eq(schema.vaultSummary.id, SINGLETON))
  if (summary === undefined) return json(c, {error: 'not indexed yet'}, 404)
  const decaySeconds = 30n * 86_400n
  const now = summary.lastTimestamp
  const elapsed = summary.genesisAt === 0n ? 0n : now - summary.genesisAt
  const remaining = elapsed >= decaySeconds ? 0n : decaySeconds - elapsed
  return json(c, {
    creator: summary.creator,
    feeBpsAtGenesis: 100,
    decaySeconds,
    genesisAt: summary.genesisAt,
    elapsedSeconds: elapsed,
    remainingSeconds: remaining,
    currentBps: Number((100n * remaining) / decaySeconds),
    paidTotal: summary.creatorPaidTotal,
  })
})

// -------------------------------------------------------------------------------------------------
// Pools and the ladder
// -------------------------------------------------------------------------------------------------

/** Every registered pool with its live state, ladder totals and gate. */
app.get('/api/pools', async (c) => {
  const rows = await db.select().from(schema.pool).orderBy(desc(schema.pool.registeredBlock))
  return json(c, {pools: rows})
})

/** One pool's ladder, cell by cell: side, liquidity, principal, fill and what it has raised. */
app.get('/api/pools/:poolId/ladder', async (c) => {
  const poolId = c.req.param('poolId').toLowerCase() as `0x${string}`
  const [pool] = await db.select().from(schema.pool).where(eq(schema.pool.id, poolId))
  if (pool === undefined) return json(c, {error: 'unknown pool'}, 404)
  const cells = await db
    .select()
    .from(schema.ladderCell)
    .where(eq(schema.ladderCell.poolId, poolId))
    .orderBy(schema.ladderCell.tickLower)
  return json(c, {
    pool,
    cells,
    totals: {
      ampsInLadder: pool.ampsInLadder,
      counterInLadder: pool.counterInLadder,
      askCells: pool.askCells,
      bidCells: pool.bidCells,
      fillBps: pool.ladderFillBps,
    },
  })
})

/** One pool's placements, in reverse chronological order, with the action that produced each. */
app.get('/api/pools/:poolId/placements', async (c) => {
  const poolId = c.req.param('poolId').toLowerCase() as `0x${string}`
  const rows = await db
    .select()
    .from(schema.placement)
    .where(eq(schema.placement.poolId, poolId))
    .orderBy(desc(schema.placement.blockNumber))
    .limit(limitOf(c.req.query('limit')))
  return json(c, {placements: rows})
})

/** One pool's swaps, with the fee decomposition. */
app.get('/api/pools/:poolId/swaps', async (c) => {
  const poolId = c.req.param('poolId').toLowerCase() as `0x${string}`
  const rows = await db
    .select()
    .from(schema.swap)
    .where(
      and(
        eq(schema.swap.poolId, poolId),
        gte(schema.swap.blockNumber, sinceOf(c.req.query('since'))),
      ),
    )
    .orderBy(desc(schema.swap.blockNumber))
    .limit(limitOf(c.req.query('limit')))
  return json(c, {swaps: rows})
})

/** Per-pool gate status, one row per pool plus the protocol-wide row. */
app.get('/api/gate', async (c) => {
  const rows = await db.select().from(schema.gateStatus)
  const transitions = await db
    .select()
    .from(schema.gateTransition)
    .orderBy(desc(schema.gateTransition.blockNumber))
    .limit(limitOf(c.req.query('limit'), 50))
  return json(c, {status: rows, transitions})
})

// -------------------------------------------------------------------------------------------------
// Bonds and staking
// -------------------------------------------------------------------------------------------------

/** The bond board: every market with its discount, capacity, issuance and realised accretion. */
app.get('/api/bonds', async (c) => {
  const markets = await db.select().from(schema.bondMarket).orderBy(schema.bondMarket.marketId)
  const recent = await db
    .select()
    .from(schema.bondPurchase)
    .orderBy(desc(schema.bondPurchase.blockNumber))
    .limit(limitOf(c.req.query('limit'), 50))
  return json(c, {markets, recent})
})

/** One address's bond positions and their claims. */
app.get('/api/bonds/positions/:owner', async (c) => {
  const owner = c.req.param('owner').toLowerCase() as `0x${string}`
  const positions = await db
    .select()
    .from(schema.bondPosition)
    .where(eq(schema.bondPosition.owner, owner))
    .orderBy(desc(schema.bondPosition.start))
  const claims = await db
    .select()
    .from(schema.bondClaim)
    .where(eq(schema.bondClaim.owner, owner))
    .orderBy(desc(schema.bondClaim.blockNumber))
    .limit(200)
  return json(c, {positions, claims})
})

/** xAMPS: share price, assets, and the APR realised sell fees have actually paid. */
app.get('/api/staking', async (c) => {
  const [state] = await db.select().from(schema.stakingState).where(eq(schema.stakingState.id, SINGLETON))
  const rewards = await db
    .select()
    .from(schema.stakingReward)
    .orderBy(desc(schema.stakingReward.blockNumber))
    .limit(limitOf(c.req.query('limit'), 50))
  return json(c, {state: state ?? null, rewards})
})

// -------------------------------------------------------------------------------------------------
// The flywheel dashboard
// -------------------------------------------------------------------------------------------------

/**
 * Everything the plan's flywheel dashboard names, in one response: sell-fee revenue, bond issuance
 * and realised accretion, fee APR against realised LVR per pool, premium history, NAV/share and net
 * supply change.
 */
app.get('/api/flywheel', async (c) => {
  const days = await db
    .select()
    .from(schema.flywheelDay)
    .orderBy(desc(schema.flywheelDay.day))
    .limit(limitOf(c.req.query('days'), 90, 365))

  const pools = await db
    .select({
      poolId: schema.pool.id,
      counter: schema.pool.counter,
      counterSymbol: schema.pool.counterSymbol,
      poolClassLabel: schema.pool.poolClassLabel,
      feeRevenueUsd18: schema.pool.feeRevenueUsd18,
      realisedLvrUsd18: schema.pool.realisedLvrUsd18,
      ampsInLadder: schema.pool.ampsInLadder,
      counterInLadder: schema.pool.counterInLadder,
      swapCount: schema.pool.swapCount,
      ladderFillBps: schema.pool.ladderFillBps,
      sellVolumeAmps: schema.pool.sellVolumeAmps,
      buyVolumeAmps: schema.pool.buyVolumeAmps,
      sellFeeAmps: schema.pool.sellFeeAmps,
      rotationCreditedAmps: schema.pool.rotationCreditedAmps,
    })
    .from(schema.pool)

  const [summary] = await db.select().from(schema.vaultSummary).where(eq(schema.vaultSummary.id, SINGLETON))
  const [staking] = await db.select().from(schema.stakingState).where(eq(schema.stakingState.id, SINGLETON))

  const [bondTotals] = await db
    .select({
      issued: sql<string>`coalesce(sum(${schema.bondMarket.totalIssued}), 0)`,
      accretion: sql<string>`coalesce(sum(${schema.bondMarket.accretionUsd18}), 0)`,
      markets: sql<number>`count(*)`,
    })
    .from(schema.bondMarket)

  return json(c, {
    summary: summary ?? null,
    staking: staking ?? null,
    bonds: {
      issued: bondTotals?.issued ?? '0',
      accretionUsd18: bondTotals?.accretion ?? '0',
      markets: Number(bondTotals?.markets ?? 0),
    },
    pools,
    days: days.reverse(),
  })
})

/** Per-pool, per-day series: volume, fees, realised LVR and the tick range. */
app.get('/api/pools/:poolId/days', async (c) => {
  const poolId = c.req.param('poolId').toLowerCase() as `0x${string}`
  const rows = await db
    .select()
    .from(schema.poolDay)
    .where(eq(schema.poolDay.poolId, poolId))
    .orderBy(desc(schema.poolDay.day))
    .limit(limitOf(c.req.query('limit'), 90, 365))
  return json(c, {days: rows.reverse()})
})

// -------------------------------------------------------------------------------------------------
// Constituents, alerts, reconciliation
// -------------------------------------------------------------------------------------------------

/** The constituent set with status, weights, feed answer and the polled issuer state. */
app.get('/api/constituents', async (c) => {
  const rows = await db.select().from(schema.constituent).orderBy(schema.constituent.constituentId)
  return json(c, {constituents: rows})
})

/** The `uiMultiplier` state-diff series for one constituent. */
app.get('/api/constituents/:id/multiplier', async (c) => {
  const id = Number(c.req.param('id'))
  const rows = await db
    .select()
    .from(schema.multiplierPoint)
    .where(eq(schema.multiplierPoint.constituentId, id))
    .orderBy(desc(schema.multiplierPoint.blockNumber))
    .limit(limitOf(c.req.query('limit'), 200))
  return json(c, {points: rows.reverse()})
})

/** Every alert, newest first. `?kind=denylist&severity=critical`. */
app.get('/api/alerts', async (c) => {
  const kind = c.req.query('kind')
  const severity = c.req.query('severity')
  const filters = []
  if (kind !== undefined) filters.push(eq(schema.alert.kind, kind))
  if (severity !== undefined) filters.push(eq(schema.alert.severity, severity))
  const base = db.select().from(schema.alert)
  const rows = await (filters.length === 0 ? base : base.where(and(...filters)))
    .orderBy(desc(schema.alert.blockNumber))
    .limit(limitOf(c.req.query('limit'), 100))
  return json(c, {alerts: rows})
})

/** The denylist alarm's own table, with the calls and the probes that raised it. */
app.get('/api/alerts/denylist', async (c) => {
  const rows = await db
    .select()
    .from(schema.denylistAlarm)
    .orderBy(desc(schema.denylistAlarm.blockNumber))
    .limit(limitOf(c.req.query('limit'), 100))
  return json(c, {alarms: rows})
})

/** Reconciliation runs. `?failing=1` for the breaches only. */
app.get('/api/reconciliation', async (c) => {
  const failing = c.req.query('failing') === '1'
  const base = db.select().from(schema.reconciliation)
  const rows = await (failing ? base.where(eq(schema.reconciliation.ok, false)) : base)
    .orderBy(desc(schema.reconciliation.blockNumber))
    .limit(limitOf(c.req.query('limit'), 100))
  const [totals] = await db
    .select({
      runs: sql<number>`count(*)`,
      failures: sql<number>`count(*) filter (where ${schema.reconciliation.ok} = false)`,
      worstNavBps: sql<number>`coalesce(max(${schema.reconciliation.navDeltaBps}), 0)`,
      worstPRefBps: sql<number>`coalesce(max(${schema.reconciliation.pRefDeltaBps}), 0)`,
    })
    .from(schema.reconciliation)
  return json(c, {
    runs: rows,
    totals: {
      runs: Number(totals?.runs ?? 0),
      failures: Number(totals?.failures ?? 0),
      worstNavBps: Number(totals?.worstNavBps ?? 0),
      worstPRefBps: Number(totals?.worstPRefBps ?? 0),
    },
  })
})

/** The keeper's ledger: one row per keeper-shaped transaction and what it produced. */
app.get('/api/keeper', async (c) => {
  const rows = await db
    .select()
    .from(schema.keeperJob)
    .orderBy(desc(schema.keeperJob.blockNumber))
    .limit(limitOf(c.req.query('limit'), 100))
  const payments = await db
    .select()
    .from(schema.bountyPayment)
    .orderBy(desc(schema.bountyPayment.blockNumber))
    .limit(limitOf(c.req.query('limit'), 100))
  return json(c, {jobs: rows, payments})
})

/** Governed parameters, latest value each. */
app.get('/api/parameters', async (c) => {
  const rows = await db.select().from(schema.parameterState).orderBy(schema.parameterState.id)
  return json(c, {parameters: rows})
})

export default app
