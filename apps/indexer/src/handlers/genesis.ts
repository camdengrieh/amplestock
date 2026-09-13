// SPDX-License-Identifier: MIT

/**
 * The launch: `AmpsGenesis`, the two Continuous Clearing Auctions it deploys, and the two halves of
 * the vault's own genesis.
 *
 * Revision 7 split genesis in two and put a 72-hour auction between the halves, which is why this
 * is its own handler rather than three more cases in `vault.ts`. The ordering the rows rely on is
 * fixed by the contracts and by nothing else:
 *
 * - `AmpsVault.GenesisMinted` comes first, out of `genesisMint`. `S0` exists from that block, `A`
 *   is still zero, and `initialized` is still false — so the `genesis` row exists with a mint and
 *   nothing else for the whole bidding window, which is exactly the state the protocol is in.
 * - `AmpsGenesis.AuctionsCreated` follows in the same transaction as the mint on the normal path
 *   (`06a_GenesisAuction` does both), but it is not required to: the row fills either column
 *   independently.
 * - `AmpsGenesis.Settled` and the vault's `Genesis` come out of the *same* `settle()` call, the
 *   adapter's first and the vault's second — `settle()` calls `genesisPlace`, which emits `Genesis`
 *   from inside it. Both are handled, because they carry different halves of the answer:
 *   `Settled` has the sweep (what arrived, per currency, net of the protocol fee) and `Genesis` has
 *   the launch (NAV/share and `A` as the checkpoint measured them).
 * - On the **fallback** path there is no `Settled` with a graduation and the vault's `Genesis`
 *   arrives from a timelock call much later. `settledPhase` is `aborted` and `p0X18` is `1e18`,
 *   which is the honest record: nothing was sold, and the founders opened the vault at $1.00.
 *
 * **Zero is never read as a price here.** `p0X18` is zero before settlement and zero for ever after
 * an aborted one, so `settledBlock` and `graduated` are what a consumer must read.
 */

import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {jsonRecord} from '../lib/json'
import {premiumBps} from '../lib/math'
import {SINGLETON} from '../lib/ids'
import {getState, raiseAlert, setState} from '../lib/store'

const ZERO = '0x0000000000000000000000000000000000000000' as const

type GenesisRow = typeof schema.genesis.$inferSelect

/**
 * The empty launch row.
 *
 * Every column is written from a default rather than left absent, because the four logs that fill
 * it arrive over 72 hours and any of them may be the first one this indexer sees — a process
 * started mid-auction has a mint it never indexed and an `AuctionsCreated` it did.
 */
function emptyGenesis(blockNumber: bigint): GenesisRow {
  return {
    id: SINGLETON,
    adapter: ZERO,
    vault: ZERO,
    mintedBlock: 0n,
    mintedAt: 0n,
    creator: ZERO,
    teamVestingWallet: ZERO,
    teamShares: 0n,
    auctionShares: 0n,
    polShares: 0n,
    auctionsBlock: 0n,
    usdgAuction: ZERO,
    ethAuction: ZERO,
    floorUsdgQ96: 0n,
    floorEthQ96: 0n,
    startBlock: 0n,
    endBlock: 0n,
    settledBlock: 0n,
    settledAt: 0n,
    settledPhase: '',
    p0X18: 0n,
    raisedUsdg: 0n,
    raisedWeth: 0n,
    unsoldAmps: 0n,
    usdgGraduated: false,
    ethGraduated: false,
    graduated: false,
    launchBlock: 0n,
    launchAt: 0n,
    totalMinted: 0n,
    navPerShareX18: 0n,
    raisedUsd18: 0n,
    premiumBps: 0,
    diverged: false,
    divergedUsdgP0X18: 0n,
    divergedEthP0X18: 0n,
    divergenceToleranceBps: 0,
    lastBlock: blockNumber,
  }
}

/** Upsert the singleton launch row, merging one log's columns into whatever is already there. */
export async function updateGenesis(
  db: {insert: (t: typeof schema.genesis) => {values: (v: GenesisRow) => {onConflictDoUpdate: (f: (row: GenesisRow) => Partial<GenesisRow>) => Promise<unknown>}}},
  blockNumber: bigint,
  patch: (row: GenesisRow) => Partial<GenesisRow>,
): Promise<void> {
  const base = emptyGenesis(blockNumber)
  await db
    .insert(schema.genesis)
    .values({...base, ...patch(base), lastBlock: blockNumber})
    .onConflictDoUpdate((row) => ({...patch(row), lastBlock: blockNumber}))
}

// The vault's two halves — `GenesisMinted` and `Genesis` — are handled in `vault.ts` and call
// {updateGenesis} from there: one event, one handler, and the summary write and the launch-row
// write in the same place rather than split across two registrations of the same name.

// -------------------------------------------------------------------------------------------------
// The adapter
// -------------------------------------------------------------------------------------------------

ponder.on('AmpsGenesis:AuctionsCreated', async ({event, context}) => {
  await updateGenesis(context.db, event.block.number, () => ({
    adapter: event.log.address,
    auctionsBlock: event.block.number,
    usdgAuction: event.args.usdgAuction,
    ethAuction: event.args.ethAuction,
    floorUsdgQ96: event.args.floorUsdgQ96,
    floorEthQ96: event.args.floorEthQ96,
    startBlock: BigInt(event.args.startBlock),
    endBlock: BigInt(event.args.endBlock),
  }))
})

ponder.on('AmpsGenesis:Settled', async ({event, context}) => {
  const graduated = event.args.usdgGraduated || event.args.ethGraduated

  await updateGenesis(context.db, event.block.number, () => ({
    adapter: event.log.address,
    settledBlock: event.block.number,
    settledAt: event.block.timestamp,
    // The adapter's own terminal phase, and the only one a log decides. `created` and `bidding` are
    // block-number facts with no event behind them, so they are never written here.
    settledPhase: graduated ? 'settled' : 'aborted',
    p0X18: event.args.p0X18,
    raisedUsdg: event.args.usdgRaised,
    raisedWeth: event.args.ethRaised,
    unsoldAmps: event.args.unsoldAmps,
    usdgGraduated: event.args.usdgGraduated,
    ethGraduated: event.args.ethGraduated,
    graduated,
  }))

  // A launch that did not happen is not an error, but it is the single most consequential thing
  // this indexer can observe: the vault stays shut, every bidder has money to reclaim from the
  // auctions themselves, and the fallback needs a governance proposal with a seven-day delay.
  if (!graduated) {
    await raiseAlert(context.db, event.log.logIndex, {
      kind: 'genesis',
      severity: 'critical',
      subject: event.log.address,
      message:
        'neither genesis auction graduated: nothing was sold, the whole tranche went back to the vault and the launch did not happen',
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      detail: jsonRecord({
        adapter: event.log.address,
        usdgRaised: event.args.usdgRaised,
        ethRaised: event.args.ethRaised,
        unsoldAmps: event.args.unsoldAmps,
        txHash: event.transaction.hash,
      }),
    })
  }
})

ponder.on('AmpsGenesis:ClearingPricesDiverged', async ({event, context}) => {
  await updateGenesis(context.db, event.block.number, () => ({
    diverged: true,
    divergedUsdgP0X18: event.args.usdgP0X18,
    divergedEthP0X18: event.args.ethP0X18,
    divergenceToleranceBps: Number(event.args.toleranceBps),
  }))

  // The USDG price is used regardless — it is the one denominated in the unit `P_ref` is quoted in
  // — so this is disclosure, not a failure. It still deserves an alert: the two legs disagreeing by
  // more than the vault's own divergence tolerance means the ETH/USD price the proposal carried and
  // the market's own ETH bid do not tell the same story about what AMPS is worth.
  await raiseAlert(context.db, event.log.logIndex, {
    kind: 'genesis',
    severity: 'warning',
    subject: event.log.address,
    message: `the two auction legs cleared further apart than the vault's ${event.args.toleranceBps} bp tolerance; the USDG price was used`,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    detail: jsonRecord({
      usdgP0X18: event.args.usdgP0X18,
      ethP0X18: event.args.ethP0X18,
      toleranceBps: event.args.toleranceBps,
      txHash: event.transaction.hash,
    }),
  })
})

// -------------------------------------------------------------------------------------------------
// The auctions
// -------------------------------------------------------------------------------------------------

const bidKey = (auction: `0x${string}`, bidId: bigint) => `${auction.toLowerCase()}-${bidId.toString()}`

/**
 * One leg's bid and checkpoint handlers.
 *
 * The two auctions are separate Ponder sources — Ponder's `factory` reads one parameter and
 * `AuctionsCreated` announces both legs in one log — so the handlers are built once and registered
 * twice, with the leg name closed over. That is what puts `usdg` or `eth` on a row without a read.
 */
function registerLeg(source: 'GenesisAuctionUsdg' | 'GenesisAuctionEth', leg: 'usdg' | 'eth'): void {
  ponder.on(`${source}:BidSubmitted`, async ({event, context}) => {
    await context.db.insert(schema.auctionBid).values({
      id: bidKey(event.log.address, event.args.id),
      auction: event.log.address,
      leg,
      bidId: event.args.id,
      owner: event.args.owner,
      maxPriceQ96: event.args.priceQ96,
      // Stored as the auction stores it. Dividing by 2^96 is a display step and throws away the low
      // bits that decide which tick a bid sits on.
      amountQ96: event.args.amount,
      submittedBlock: event.block.number,
      submittedAt: event.block.timestamp,
      txHash: event.transaction.hash,
      exitedBlock: 0n,
      tokensFilled: 0n,
      currencyRefunded: 0n,
      claimedBlock: 0n,
      claimedAmount: 0n,
    })
  })

  ponder.on(`${source}:BidExited`, async ({event, context}) => {
    await context.db
      .update(schema.auctionBid, {id: bidKey(event.log.address, event.args.bidId)})
      .set({
        exitedBlock: event.block.number,
        tokensFilled: event.args.tokensFilled,
        currencyRefunded: event.args.currencyRefunded,
      })
      // A bid this indexer never saw submitted — it started mid-auction — is a row that does not
      // exist, and an update that finds nothing is a no-op rather than a crash.
      .catch(() => undefined)
  })

  ponder.on(`${source}:TokensClaimed`, async ({event, context}) => {
    await context.db
      .update(schema.auctionBid, {id: bidKey(event.log.address, event.args.bidId)})
      .set({claimedBlock: event.block.number, claimedAmount: event.args.tokensFilled})
      .catch(() => undefined)
  })

  ponder.on(`${source}:CheckpointUpdated`, async ({event, context}) => {
    await context.db.insert(schema.auctionCheckpoint).values({
      id: checkpointKey(event.block.number, event.log.logIndex),
      auction: event.log.address,
      leg,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
      logIndex: event.log.logIndex,
      clearingPriceQ96: event.args.clearingPriceQ96,
      cumulativeMps: BigInt(event.args.cumulativeMps),
    })
    // Remembered so a price-only `ClearingPriceUpdated` row inherits it rather than claiming zero.
    await setState(context.db, cumulativeMpsKey(leg), BigInt(event.args.cumulativeMps), event.block.number)
  })

  /**
   * `ClearingPriceUpdated` — the same series, from the other side.
   *
   * The auction writes a full checkpoint only when somebody pays for one, but it emits this
   * whenever the clearing price itself moves, which is strictly more often. Subscribing to both is
   * what makes the price series *dense* rather than one point per paid checkpoint: without it the
   * dApp's clearing-price panel draws a straight line across every window nobody checkpointed.
   *
   * It carries no `cumulativeMps` — issuance is a property of the schedule and of the block, not of
   * the price — so a row written from this log inherits the last issuance figure the leg recorded
   * rather than claiming zero, and a `CheckpointUpdated` in the same block wins: it is the complete
   * record, and `insert` would otherwise collide on the id.
   */
  ponder.on(`${source}:ClearingPriceUpdated`, async ({event, context}) => {
    const id = checkpointKey(event.block.number, event.log.logIndex)
    const cumulativeMps = (await getState(context.db, cumulativeMpsKey(leg))) ?? 0n
    await context.db
      .insert(schema.auctionCheckpoint)
      .values({
        id,
        auction: event.log.address,
        leg,
        blockNumber: event.block.number,
        timestamp: event.block.timestamp,
        txHash: event.transaction.hash,
        logIndex: event.log.logIndex,
        clearingPriceQ96: event.args.clearingPriceQ96,
        cumulativeMps,
      })
      .onConflictDoUpdate(() => ({clearingPriceQ96: event.args.clearingPriceQ96}))
  })
}

/** `"<block>-<logIndex>"`, zero-padded so the id sorts in block order as text. */
const checkpointKey = (blockNumber: bigint, logIndex: number) =>
  `${blockNumber.toString().padStart(12, '0')}-${logIndex.toString().padStart(6, '0')}`

/** The last issuance figure a leg recorded, so a price-only log does not claim zero. */
const cumulativeMpsKey = (leg: 'usdg' | 'eth') => `auction.${leg}.cumulativeMps`

registerLeg('GenesisAuctionUsdg', 'usdg')
registerLeg('GenesisAuctionEth', 'eth')

/**
 * The premium the launch opened at, in bps: `p0X18 / navPerShareX18 - 1`.
 *
 * Exported so the vault's own `Genesis` handler can fill it in on the same row without importing
 * the whole of this module's shape, and so `test/handlers.test.ts` can drive it directly.
 */
export function launchPremiumBps(p0X18: bigint, navPerShareX18: bigint): number {
  if (p0X18 === 0n || navPerShareX18 === 0n) return 0
  return premiumBps(navPerShareX18, p0X18)
}
