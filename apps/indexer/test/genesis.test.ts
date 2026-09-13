// SPDX-License-Identifier: MIT

/**
 * The launch, driven with synthetic logs.
 *
 * Genesis is four logs spread over 72 hours and two contracts, so what is pinned here is that the
 * one `genesis` row is legible at every point in that window — a mint with no auctions, auctions
 * with no settlement, a settlement that graduated and one that did not — and that no handler
 * invents a price out of a zero.
 */

import {beforeEach, describe, expect, it} from 'vitest'

import '../src/index'

import * as schema from '../ponder.schema'
import {SINGLETON} from '../src/lib/ids'
import {createFakeDb, type FakeDb} from './support/db'
import {
  ADDRESSES,
  BIDDER,
  CREATOR,
  TEAM_VESTING,
  makeContext,
  makeEvent,
  resetLogIndex,
  run,
  type TestContext,
} from './support/events'

const WAD = 10n ** 18n
const Q96 = 2n ** 96n
const TX = `0x${'ef'.repeat(32)}` as `0x${string}`

let db: FakeDb
let context: TestContext

beforeEach(() => {
  resetLogIndex()
  db = createFakeDb()
  context = makeContext({}, db)
})

/** `genesisMint`: `S0` exists, `A` is zero, and no price has been written anywhere. */
async function mint(blockNumber = 100n): Promise<void> {
  await run(
    'AmpsVault:GenesisMinted',
    makeEvent({
      blockNumber,
      args: {
        teamVestingWallet: TEAM_VESTING,
        creator: CREATOR,
        genesis: ADDRESSES.AmpsGenesis,
        teamShares: 1_000n * WAD,
        auctionShares: 10_000n * WAD,
        polShares: 9_000n * WAD,
      },
    }),
    context,
  )
}

async function createAuctions(blockNumber = 101n): Promise<void> {
  await run(
    'AmpsGenesis:AuctionsCreated',
    makeEvent({
      blockNumber,
      address: ADDRESSES.AmpsGenesis,
      args: {
        usdgAuction: ADDRESSES.GenesisAuctionUsdg,
        ethAuction: ADDRESSES.GenesisAuctionEth,
        floorUsdgQ96: (10n ** 6n * Q96) / WAD,
        floorEthQ96: (Q96 * WAD) / (2_500n * WAD),
        startBlock: 200n,
        endBlock: 2_592_200n,
      },
    }),
    context,
  )
}

/** `settle()`: both legs graduated at the floor, $10,000 raised, 0 unsold. */
async function settle(overrides: Record<string, unknown> = {}, blockNumber = 2_600_000n): Promise<void> {
  await run(
    'AmpsGenesis:Settled',
    makeEvent({
      blockNumber,
      address: ADDRESSES.AmpsGenesis,
      txHash: TX,
      args: {
        p0X18: WAD,
        usdgRaised: 5_000_000_000n,
        ethRaised: 2n * WAD,
        unsoldAmps: 0n,
        usdgGraduated: true,
        ethGraduated: true,
        ...overrides,
      },
    }),
    context,
  )
}

/** The vault's own `Genesis`, emitted from inside `genesisPlace` in the same transaction. */
async function launch(blockNumber = 2_600_000n): Promise<void> {
  await run(
    'AmpsVault:Genesis',
    makeEvent({
      blockNumber,
      txHash: TX,
      args: {
        creator: CREATOR,
        totalMinted: 20_000n * WAD,
        navPerShareX18: WAD / 2n,
        p0X18: WAD,
        raisedUsd18: 10_000n * WAD,
      },
    }),
    context,
  )
}

describe('the mint half', () => {
  it('records the three tranches and the supply, and writes no price', async () => {
    await mint()
    const row = await db.find(schema.genesis, {id: SINGLETON})
    expect(row).not.toBeNull()
    expect(row!.teamShares).toBe(1_000n * WAD)
    expect(row!.auctionShares).toBe(10_000n * WAD)
    expect(row!.polShares).toBe(9_000n * WAD)
    expect(row!.adapter).toBe(ADDRESSES.AmpsGenesis)
    expect(row!.teamVestingWallet).toBe(TEAM_VESTING)
    // `A` is zero until `genesisPlace`, so a NAV here would be a number the chain does not have.
    expect(row!.navPerShareX18).toBe(0n)
    expect(row!.p0X18).toBe(0n)
    expect(row!.settledBlock).toBe(0n)
    expect(row!.settledPhase).toBe('')
  })

  it('puts the supply in the summary but leaves NAV alone', async () => {
    await mint()
    const summary = await db.find(schema.vaultSummary, {id: SINGLETON})
    expect(summary!.totalSupply).toBe(20_000n * WAD)
    expect(summary!.genesisMinted).toBe(20_000n * WAD)
    expect(summary!.teamVestingWallet).toBe(TEAM_VESTING)
    expect(summary!.navPerShareX18).toBe(0n)
    // `genesisAt` is stamped at the *place*, not the mint: the creator's decay clock starts at
    // launch, so the bidding window does not eat into it.
    expect(summary!.genesisAt).toBe(0n)
  })
})

describe('the auctions', () => {
  it('records both legs and the floors the adapter computed', async () => {
    await mint()
    await createAuctions()
    const row = await db.find(schema.genesis, {id: SINGLETON})
    expect(row!.usdgAuction).toBe(ADDRESSES.GenesisAuctionUsdg)
    expect(row!.ethAuction).toBe(ADDRESSES.GenesisAuctionEth)
    expect(row!.floorUsdgQ96).toBe((10n ** 6n * Q96) / WAD)
    expect(row!.endBlock).toBe(2_592_200n)
    // The mint columns survive: each log fills its own half and clobbers nothing.
    expect(row!.teamShares).toBe(1_000n * WAD)
  })

  it('fills the auction half even when the mint was never indexed', async () => {
    // A process started mid-auction has an `AuctionsCreated` it saw and a mint it did not.
    await createAuctions()
    const row = await db.find(schema.genesis, {id: SINGLETON})
    expect(row!.usdgAuction).toBe(ADDRESSES.GenesisAuctionUsdg)
    expect(row!.teamShares).toBe(0n)
  })

  it('keeps a bid, its exit and its claim on one row, in the leg it was made in', async () => {
    await mint()
    await createAuctions()
    await run(
      'GenesisAuctionUsdg:BidSubmitted',
      makeEvent({
        blockNumber: 300n,
        address: ADDRESSES.GenesisAuctionUsdg,
        args: {id: 7n, owner: BIDDER, priceQ96: (10n ** 6n * Q96) / WAD, amount: 1_000_000_000n},
      }),
      context,
    )
    const key = `${ADDRESSES.GenesisAuctionUsdg.toLowerCase()}-7`
    let bid = await db.find(schema.auctionBid, {id: key})
    expect(bid!.leg).toBe('usdg')
    expect(bid!.owner).toBe(BIDDER)
    // Stored as the auction stores it: dividing by 2^96 would throw away the tick.
    expect(bid!.amountQ96).toBe(1_000_000_000n)
    expect(bid!.exitedBlock).toBe(0n)

    await run(
      'GenesisAuctionUsdg:BidExited',
      makeEvent({
        blockNumber: 2_600_001n,
        address: ADDRESSES.GenesisAuctionUsdg,
        args: {bidId: 7n, owner: BIDDER, tokensFilled: 1_000n * WAD, currencyRefunded: 0n},
      }),
      context,
    )
    await run(
      'GenesisAuctionUsdg:TokensClaimed',
      makeEvent({
        blockNumber: 2_600_002n,
        address: ADDRESSES.GenesisAuctionUsdg,
        args: {bidId: 7n, owner: BIDDER, tokensFilled: 1_000n * WAD},
      }),
      context,
    )
    bid = await db.find(schema.auctionBid, {id: key})
    expect(bid!.exitedBlock).toBe(2_600_001n)
    expect(bid!.tokensFilled).toBe(1_000n * WAD)
    expect(bid!.claimedBlock).toBe(2_600_002n)
  })

  it('does not crash on an exit whose bid it never saw submitted', async () => {
    await expect(
      run(
        'GenesisAuctionEth:BidExited',
        makeEvent({
          blockNumber: 2_600_001n,
          address: ADDRESSES.GenesisAuctionEth,
          args: {bidId: 99n, owner: BIDDER, tokensFilled: 0n, currencyRefunded: 1n},
        }),
        context,
      ),
    ).resolves.toBeUndefined()
  })

  it('records the clearing-price series, which no view can give', async () => {
    await run(
      'GenesisAuctionEth:CheckpointUpdated',
      makeEvent({
        blockNumber: 1_000n,
        address: ADDRESSES.GenesisAuctionEth,
        args: {blockNumber: 1_000n, clearingPriceQ96: Q96 / 2_500n, cumulativeMps: 2_500_000},
      }),
      context,
    )
    const rows = db.rows(schema.auctionCheckpoint)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.leg).toBe('eth')
    expect(rows[0]!.clearingPriceQ96).toBe(Q96 / 2_500n)
    expect(rows[0]!.cumulativeMps).toBe(2_500_000n)
  })
})

describe('settlement', () => {
  it('records the sweep and marks the launch settled', async () => {
    await mint()
    await createAuctions()
    await settle()
    const row = await db.find(schema.genesis, {id: SINGLETON})
    expect(row!.settledPhase).toBe('settled')
    expect(row!.graduated).toBe(true)
    expect(row!.p0X18).toBe(WAD)
    expect(row!.raisedUsdg).toBe(5_000_000_000n)
    expect(row!.raisedWeth).toBe(2n * WAD)
    expect(row!.unsoldAmps).toBe(0n)
  })

  it('takes the launch figures from the vault’s own log, and the premium with them', async () => {
    await mint()
    await createAuctions()
    await settle()
    await launch()
    const row = await db.find(schema.genesis, {id: SINGLETON})
    expect(row!.totalMinted).toBe(20_000n * WAD)
    expect(row!.navPerShareX18).toBe(WAD / 2n)
    expect(row!.raisedUsd18).toBe(10_000n * WAD)
    // $1.00 over $0.50, less one: a 100% premium, disclosed rather than smoothed.
    expect(row!.premiumBps).toBe(10_000)

    const summary = await db.find(schema.vaultSummary, {id: SINGLETON})
    expect(summary!.genesisAt).toBe(1_788_962_400n)
    expect(summary!.genesisNavPerShareX18).toBe(WAD / 2n)
    expect(summary!.totalAssetsUsd18).toBe(10_000n * WAD)
    expect(summary!.pRefX18).toBe(WAD)
    expect(summary!.premiumBps).toBe(10_000)
  })

  it('calls a non-graduating settlement aborted, and raises a critical alert', async () => {
    await mint()
    await createAuctions()
    await settle({usdgGraduated: false, ethGraduated: false, p0X18: 0n, usdgRaised: 0n, ethRaised: 0n, unsoldAmps: 10_000n * WAD})
    const row = await db.find(schema.genesis, {id: SINGLETON})
    expect(row!.settledPhase).toBe('aborted')
    expect(row!.graduated).toBe(false)
    // Zero here is "no leg graduated", never a price of zero — which is why `graduated` exists.
    expect(row!.p0X18).toBe(0n)
    expect(row!.unsoldAmps).toBe(10_000n * WAD)
    expect(row!.settledBlock).toBeGreaterThan(0n)

    const alerts = db.rows(schema.alert)
    expect(alerts).toHaveLength(1)
    expect(alerts[0]!.kind).toBe('genesis')
    expect(alerts[0]!.severity).toBe('critical')
    expect(String(alerts[0]!.message)).toMatch(/neither genesis auction graduated/)
  })

  it('records a divergence as disclosure, and keeps the USDG price', async () => {
    await mint()
    await createAuctions()
    await settle()
    await run(
      'AmpsGenesis:ClearingPricesDiverged',
      makeEvent({
        blockNumber: 2_600_000n,
        address: ADDRESSES.AmpsGenesis,
        args: {usdgP0X18: WAD, ethP0X18: (WAD * 12n) / 10n, toleranceBps: 500},
      }),
      context,
    )
    const row = await db.find(schema.genesis, {id: SINGLETON})
    expect(row!.diverged).toBe(true)
    expect(row!.divergedEthP0X18).toBe((WAD * 12n) / 10n)
    expect(row!.divergenceToleranceBps).toBe(500)
    // The USDG price is what settlement used, and the row still says so.
    expect(row!.p0X18).toBe(WAD)

    const alerts = db.rows(schema.alert)
    expect(alerts.some((a) => a.kind === 'genesis' && a.severity === 'warning')).toBe(true)
  })

  it('records the fallback launch: aborted settlement, then the timelock opens the vault at $1.00', async () => {
    await mint()
    await createAuctions()
    await settle({usdgGraduated: false, ethGraduated: false, p0X18: 0n, usdgRaised: 0n, ethRaised: 0n, unsoldAmps: 10_000n * WAD})
    // Hours later, out of a governed `genesisPlace` rather than out of `settle()`.
    await run(
      'AmpsVault:Genesis',
      makeEvent({
        blockNumber: 2_700_000n,
        args: {
          creator: CREATOR,
          totalMinted: 20_000n * WAD,
          navPerShareX18: WAD,
          p0X18: WAD,
          raisedUsd18: 20_000n * WAD,
        },
      }),
      context,
    )
    const row = await db.find(schema.genesis, {id: SINGLETON})
    // The settlement half still says nothing was sold; the launch half says the vault opened.
    expect(row!.settledPhase).toBe('aborted')
    expect(row!.graduated).toBe(false)
    expect(row!.launchBlock).toBe(2_700_000n)
    expect(row!.navPerShareX18).toBe(WAD)
    // $20,000 of founders' seed against S0 = 20,000 is exactly $1.00: no premium at all.
    expect(row!.premiumBps).toBe(0)
  })
})
