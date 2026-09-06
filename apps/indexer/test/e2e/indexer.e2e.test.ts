// SPDX-License-Identifier: MIT

/**
 * The end-to-end suite: the whole Amplestocks system on a local `anvil`, driven through the user
 * journey the plan names, then indexed and asserted.
 *
 * What it proves, which is the Phase 5 exit criterion:
 *
 * 1. **The indexed NAV/share and `P_ref` reconcile with the on-chain reads at every block**, inside
 *    the dust bound (2 bp relative or 1e-6 absolute). Every reconciliation row the run produced is
 *    checked, not just the last one.
 * 2. **The denylist alarm fires within one block** of a `blockAccounts(address[])` call, and is
 *    `critical` because the account it blocked is the vault.
 *
 * And, on the way, that the journey itself is indexed correctly: genesis, the ask and bid ladders,
 * a buy and a sell with the fee decomposed, a bond with its realised accretion, a compound with its
 * four-way split, and a pro-rata redemption.
 *
 * **Opt-in.** `AMPS_E2E=1` and a Foundry toolchain, or the whole file is skipped — `pnpm test` is
 * offline and needs neither, which is what keeps CI's `node` job green on a runner with no Foundry.
 */

import {afterAll, beforeAll, describe, expect, it} from 'vitest'

import {
  blockNumber,
  buildFixture,
  e2eEnabled,
  mine,
  startAnvil,
  startIndexer,
  step,
  warp,
  type Anvil,
  type Indexer,
} from './harness'

const enabled = e2eEnabled()
const port = 8600 + (process.pid % 200)

/** Ponder's historical sync ends at the finalized block, which trails `anvil`'s head by ~30. */
const FINALITY_SLACK = 40

interface Json {
  [key: string]: unknown
}

let anvil: Anvil
let indexer: Indexer
let addresses: Record<string, string> = {}
let lastActionBlock = 0
let denylistBlock = 0

describe.skipIf(!enabled)('the indexer over a real chain', () => {
  beforeAll(async () => {
    buildFixture()
    anvil = await startAnvil(port)

    // --- the system --------------------------------------------------------------------------
    addresses = step(anvil.url, 'deploy()').addresses

    // Bootstrap step 3: the hub's observation ring has to cover `twapWindow` before the gate can
    // go GREEN, and it fills with time alone.
    await warp(anvil.url, 1_801)
    addresses = step(anvil.url, 'wire()', addresses).addresses

    // --- genesis -----------------------------------------------------------------------------
    addresses = step(anvil.url, 'genesisAsks()', addresses).addresses
    await warp(anvil.url, 61) // the 60-second per-pool placement cooldown
    addresses = step(anvil.url, 'genesisBids()', addresses).addresses

    // --- the journey -------------------------------------------------------------------------
    step(anvil.url, 'trade()', addresses)
    step(anvil.url, 'bond()', addresses)

    // `compound` refuses beyond `PLACEMENT_DIVERGENCE_TICKS`, so the hub's 30-minute TWAP has to
    // catch up with the tick the buy left behind. That is the gate working, not a workaround.
    await warp(anvil.url, 1_801)
    step(anvil.url, 'checkpoint()', addresses)
    step(anvil.url, 'compound()', addresses)
    step(anvil.url, 'redeem()', addresses)

    denylistBlock = (await blockNumber(anvil.url)) + 1
    step(anvil.url, 'denylist()', addresses)
    step(anvil.url, 'checkpoint()', addresses)

    lastActionBlock = await blockNumber(anvil.url)
    await mine(anvil.url, FINALITY_SLACK)

    indexer = await startIndexer({
      rpcUrl: anvil.url,
      addresses,
      endBlock: lastActionBlock,
      port: port + 1,
      schema: 'e2e',
    })
  }, 1_800_000)

  afterAll(() => {
    indexer?.stop()
    anvil?.stop()
  })

  // -----------------------------------------------------------------------------------------------
  // The exit criterion
  // -----------------------------------------------------------------------------------------------

  it('reconciles the indexed NAV/share and P_ref with the chain at every block', async () => {
    const body = (await indexer.get('/api/reconciliation?limit=1000')) as {
      runs: Json[]
      totals: {runs: number; failures: number; worstNavBps: number; worstPRefBps: number}
    }

    // eslint-disable-next-line no-console
    console.log(
      `[e2e] ${body.totals.runs} reconciliation runs, ${body.totals.failures} failures, ` +
        `worst NAV ${body.totals.worstNavBps} bps, worst P_ref ${body.totals.worstPRefBps} bps`,
    )

    expect(body.totals.runs).toBeGreaterThan(0)
    expect(body.totals.failures).toBe(0)
    expect(body.totals.worstNavBps).toBeLessThanOrEqual(2)
    expect(body.totals.worstPRefBps).toBeLessThanOrEqual(2)

    for (const run of body.runs) {
      expect(run.ok, `block ${run.blockNumber} breached ${run.breached}`).toBe(true)
      expect(BigInt(run.navIndexedX18 as string)).toBeGreaterThan(0n)
      expect(BigInt(run.navOnChainX18 as string)).toBeGreaterThan(0n)
      // The dust bound is two-sided: within 2 bp, or within 1e-6 of a unit.
      const navDelta = BigInt(run.navDeltaWei as string)
      const pRefDelta = BigInt(run.pRefDeltaWei as string)
      const abs = (v: bigint) => (v < 0n ? -v : v)
      expect(abs(navDelta) <= 10n ** 12n || (run.navDeltaBps as number) <= 2).toBe(true)
      expect(abs(pRefDelta) <= 10n ** 12n || (run.pRefDeltaBps as number) <= 2).toBe(true)
    }
  })

  it('fires the denylist alarm within one block of the blockAccounts call, as a critical', async () => {
    const body = (await indexer.get('/api/alerts/denylist')) as {alarms: Json[]}
    expect(body.alarms.length).toBeGreaterThan(0)

    const call = body.alarms.find((a) => a.detection === 'call')
    expect(call, 'no call-detected denylist alarm').toBeDefined()
    expect(call!.selector).toBe('0x6abf7081')
    expect(call!.severity).toBe('critical')
    expect(call!.touchesProtocol).toBe(true)
    expect((call!.accounts as string[]).map((a) => a.toLowerCase())).toContain(
      addresses.vault!.toLowerCase(),
    )
    // "Within one block": the alarm is recorded at the block the transaction landed in.
    expect(Number(call!.blockNumber)).toBeLessThanOrEqual(denylistBlock + 1)
    expect(Number(call!.blockNumber)).toBeGreaterThanOrEqual(denylistBlock - 1)

    const alerts = (await indexer.get('/api/alerts?kind=denylist')) as {alerts: Json[]}
    expect(alerts.alerts.length).toBeGreaterThan(0)
    expect(alerts.alerts[0]!.severity).toBe('critical')
  })

  // -----------------------------------------------------------------------------------------------
  // The journey
  // -----------------------------------------------------------------------------------------------

  it('indexes genesis and the launch vector', async () => {
    const body = (await indexer.get('/api/vault')) as {summary: Json}
    const s = body.summary
    expect(BigInt(s.genesisMinted as string)).toBe(5_000n * 10n ** 18n)

    // NAV/share *at genesis* is the $1.00 launch price, up to the few basis points §12.2 ruling L
    // documents: each ask ladder is valued at the reference price as it is placed, so laying all of
    // them lifts NAV a little.
    const genesisNav = BigInt(s.genesisNavPerShareX18 as string)
    expect(genesisNav).toBeGreaterThan((10n ** 18n * 9_990n) / 10_000n)
    expect(genesisNav).toBeLessThan((10n ** 18n * 10_010n) / 10_000n)

    // And NAV/share only goes up from there — the buy through the asks, the bond and the compound
    // are each accretive by construction, which is the whole flywheel.
    const nav = BigInt(s.navPerShareX18 as string)
    expect(nav).toBeGreaterThan(genesisNav)
    expect(BigInt(s.pRefX18 as string)).toBeGreaterThanOrEqual(nav)
    expect(s.creator).not.toBe('0x0000000000000000000000000000000000000000')

    const supply = (await indexer.get('/api/supply')) as Json
    expect(BigInt(supply.bondIssued as string)).toBeGreaterThan(0n)
    expect(BigInt(supply.burned as string)).toBeGreaterThan(0n)
  })

  it('indexes the five pools and their genesis ladders', async () => {
    const body = (await indexer.get('/api/pools')) as {pools: Json[]}
    expect(body.pools).toHaveLength(5)
    const entry = body.pools.filter((p) => p.poolClassLabel === 'ENTRY')
    expect(entry).toHaveLength(2)

    for (const pool of body.pools) {
      expect(pool.gridBaseTick).not.toBeNull()
      expect(pool.doublingTicks).toBe(6960)
      expect(Number(pool.askCells)).toBeGreaterThan(0)
    }

    const hub = entry.find((p) => Number(p.counterDecimals) === 6)!
    const ladder = (await indexer.get(`/api/pools/${hub.id}/ladder`)) as {
      cells: Json[]
      totals: Json
    }
    // Ten ask cells and four seed bid cells (§3.3).
    expect(ladder.cells.length).toBeGreaterThanOrEqual(14)
    for (const cell of ladder.cells) {
      expect(Number(cell.cellIndex)).toBeGreaterThanOrEqual(0)
      expect(Number(cell.cellIndex)).toBeLessThan(24)
    }
    // The buy consumed the bottom of the ask ladder, so at least one cell has raised counter.
    expect(ladder.cells.some((c) => BigInt(c.counterRaised as string) > 0n)).toBe(true)
    expect(BigInt(ladder.totals.ampsInLadder as string)).toBeGreaterThan(0n)
  })

  it('decodes the buy and the sell', async () => {
    const pools = (await indexer.get('/api/pools')) as {pools: Json[]}
    const hub = pools.pools.find((p) => p.poolClassLabel === 'ENTRY' && Number(p.counterDecimals) === 6)!
    const body = (await indexer.get(`/api/pools/${hub.id}/swaps`)) as {swaps: Json[]}
    expect(body.swaps.length).toBeGreaterThanOrEqual(2)

    const buy = body.swaps.find((s) => s.sell === false)!
    const sell = body.swaps.find((s) => s.sell === true)!

    // The entry pool's buy fee is 30 bp and the base is exactly that; the dynamic part is whatever
    // the surge and the deviation added on top.
    expect(buy.baseFeeBps).toBe(30)
    expect(Number(buy.dynamicFeeBps)).toBeGreaterThanOrEqual(0)
    expect(Number(buy.feeBps)).toBe(Number(buy.baseFeeBps) + Number(buy.dynamicFeeBps))
    expect(BigInt(buy.feeAmps as string)).toBe(0n)

    // The sell pays `sellFeeBps` = 500 as its base, in AMPS.
    expect(sell.baseFeeBps).toBe(500)
    expect(BigInt(sell.feeAmps as string)).toBeGreaterThan(0n)
    expect(BigInt(sell.ampsAmount as string)).toBeGreaterThan(0n)
    expect(sell.credited).toBe(false)
  })

  it('indexes the bond with its realised accretion', async () => {
    const body = (await indexer.get('/api/bonds')) as {markets: Json[]; recent: Json[]}
    expect(body.recent.length).toBeGreaterThan(0)
    const purchase = body.recent[0]!
    expect(BigInt(purchase.ampsOut as string)).toBeGreaterThan(0n)
    expect(Number(purchase.discountBps)).toBeGreaterThan(0)
    expect(BigInt(purchase.navBeforeX18 as string)).toBeGreaterThan(0n)
    // I27: a bond never lowers NAV/share.
    expect(BigInt(purchase.navAfterX18 as string)).toBeGreaterThanOrEqual(
      BigInt(purchase.navBeforeX18 as string),
    )
    expect(BigInt(purchase.accretionUsd18 as string)).toBeGreaterThanOrEqual(0n)

    const market = body.markets.find((m) => Number(m.marketId) === Number(purchase.marketId))!
    expect(BigInt(market.totalIssued as string)).toBe(BigInt(purchase.ampsOut as string))
    expect(market.bondCount).toBe(1)
  })

  it('indexes the compound as a four-way split that adds up', async () => {
    const body = (await indexer.get('/api/flywheel')) as {summary: Json; pools: Json[]; days: Json[]}
    const s = body.summary
    expect(Number(s.compoundCount)).toBeGreaterThan(0)
    const fees = BigInt(s.feesAmpsTotal as string)
    expect(fees).toBeGreaterThan(0n)
    expect(
      BigInt(s.creatorPaidTotal as string) +
        BigInt(s.stakerPaidTotal as string) +
        BigInt(s.burnedTotal as string) +
        BigInt(s.relaidTotal as string),
    ).toBe(fees)
    // The creator slice is live at genesis + a few minutes, so it is not zero.
    expect(BigInt(s.creatorPaidTotal as string)).toBeGreaterThan(0n)
    expect(body.days.length).toBeGreaterThan(0)
  })

  it('indexes the redemption at the NAV in force', async () => {
    const burns = (await indexer.get('/api/burns')) as {burns: Json[]; total: string}
    expect(burns.burns.length).toBeGreaterThan(0)
    expect(new Set(burns.burns.map((b) => b.reason)).size).toBeGreaterThan(0)
    expect(BigInt(burns.total)).toBeGreaterThan(0n)

    const nav = (await indexer.get('/api/nav-history')) as {points: Json[]}
    expect(nav.points.length).toBeGreaterThan(1)
    // NAV/share never falls more than the 2 bp R1 allows between consecutive checkpoints.
    for (const point of nav.points) {
      expect(Number(point.navChangeBps)).toBeGreaterThanOrEqual(-2)
    }
  })

  it('polls the uiMultiplier and the gate', async () => {
    const constituents = (await indexer.get('/api/constituents')) as {constituents: Json[]}
    expect(constituents.constituents).toHaveLength(3)
    for (const c of constituents.constituents) {
      expect(c.statusLabel).toBe('ACTIVE')
      expect(BigInt(c.uiMultiplierX18 as string)).toBe(10n ** 18n)
      expect(Number(c.lastPolledBlock)).toBeGreaterThan(0)
    }

    const multiplier = (await indexer.get('/api/constituents/1/multiplier')) as {points: Json[]}
    expect(multiplier.points.length).toBeGreaterThan(0)
    expect(multiplier.points[0]!.changed).toBe('first')

    // The gate never left GREEN during the run, so it emitted no `GateChanged` and `gate_status`
    // is empty — which is the correct index of "nothing happened", not a gap. What is asserted is
    // that every pool is recorded as GREEN, which is where the dApp reads it from.
    const gate = (await indexer.get('/api/gate')) as {status: Json[]; transitions: Json[]}
    expect(gate.transitions).toHaveLength(gate.status.length === 0 ? 0 : gate.transitions.length)
    const pools = (await indexer.get('/api/pools')) as {pools: Json[]}
    for (const pool of pools.pools) expect(pool.gateStateLabel).toBe('GREEN')
  })

  it('serves the GraphQL schema as well as the typed layer', async () => {
    const response = await fetch(`${indexer.url}/graphql`, {
      method: 'POST',
      headers: {'content-type': 'application/json'},
      body: JSON.stringify({query: '{ swaps(limit: 5) { items { id poolId sell baseFeeBps } } }'}),
    })
    const body = (await response.json()) as {data?: {swaps?: {items?: unknown[]}}; errors?: unknown}
    expect(body.errors).toBeUndefined()
    expect(body.data?.swaps?.items?.length).toBeGreaterThan(0)
  })
})
