// SPDX-License-Identifier: MIT

/**
 * `AmpsVault` — the custody boundary, so most of the index hangs off these fifteen events.
 *
 * The ordering the handlers rely on, all of it fixed by the contracts:
 *
 * - `compound()` writes its checkpoint *before* it emits `Compound` (§3.6 step 9), so the
 *   `NavCheckpoint` in the same transaction is the "after" value and the previous one is "before".
 * - `VaultPlacementLib` emits `Placement` *after* `_unlock` returns, so every `ModifyLiquidity` the
 *   placement produced has already been indexed. The cell count and the liquidity added are
 *   therefore accumulated in scratch by the `ModifyLiquidity` handler and consumed here.
 * - `depositBonded` checkpoints immediately before it settles (phase-2 §6), so a bond's "before"
 *   NAV is that checkpoint and its "after" is the next one.
 */

import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {actionFromReason, classifyAction} from '../lib/actions'
import {decodeBytes32String} from '../lib/bytes32'
import {
  CREATOR_DECAY_SECONDS,
  CREATOR_FEE_BPS,
  GATE_STATES,
  gateStateLabel,
} from '../lib/constants'
import {eventId, poolKey} from '../lib/ids'
import {changeBps, clampInt, creatorBpsAt, premiumBps, premiumX18, priceX18FromSqrt} from '../lib/math'
import {counterToUsd18} from '../lib/flywheel'
import {recordKeeperJob} from '../lib/keeper'
import {recordParameter} from '../lib/parameters'
import {jsonRecord} from '../lib/json'
import {
  STATE,
  getState,
  markNavMoved,
  raiseAlert,
  setState,
  updateFlywheelDay,
  updateSummary,
  type Db,
} from '../lib/store'
import {
  REDEEM_GAP_CRITICAL_BPS,
  REDEEM_GAP_WARNING_BPS,
  isNavDrift,
  redeemGapBps,
  redeemGapSeverity,
} from '../lib/reconcile'
import {ampsVaultAbi} from '@amplestocks/abis'
import {erc20Abi} from '../abi/external'
import {to18, usd8ToUsd18} from '../lib/math'
import {settleAccretion} from './bonds'
import {launchPremiumBps, updateGenesis} from './genesis'
import {read, reconcileAgain, runReconciliation, sampleShares, type JobContext} from './reconcile'

const PREV_NAV = 'vault.navPerSharePrevX18'
const PLACEMENT_LIQ = (tx: string, pool: string) => `placement.liquidity.${tx}.${pool}`

// -------------------------------------------------------------------------------------------------
// Genesis
// -------------------------------------------------------------------------------------------------

/**
 * `genesisMint` — step one of two, and the only one that mints.
 *
 * `S0` exists from this block and `A` is still zero, so the summary records the supply and the
 * addresses and touches **no** price: NAV/share is undefined until `genesisPlace` writes the first
 * checkpoint, and writing a zero here would make the reconciliation job compare a real
 * `Amps.totalSupply()` against a NAV that does not exist yet.
 *
 * `teamVestingWallet` moved here in revision 7. It is a fact about the *mint* — who received the
 * team tranche — and the launch log has no room for it beside the price it was renamed to carry.
 */
ponder.on('AmpsVault:GenesisMinted', async ({event, context}) => {
  const s0 = event.args.teamShares + event.args.auctionShares + event.args.polShares

  await updateSummary(context.db, event.block.number, event.block.timestamp, () => ({
    vault: context.contracts.AmpsVault.address as `0x${string}`,
    amps: context.contracts.AmpsToken.address as `0x${string}`,
    registry: context.contracts.PoolRegistry.address as `0x${string}`,
    creator: event.args.creator,
    teamVestingWallet: event.args.teamVestingWallet,
    genesisMinted: s0,
    totalSupply: s0,
  }))

  // The mint half of the launch row. It is the whole of it for the next 72 hours.
  await updateGenesis(context.db, event.block.number, () => ({
    vault: context.contracts.AmpsVault.address as `0x${string}`,
    adapter: event.args.genesis,
    mintedBlock: event.block.number,
    mintedAt: event.block.timestamp,
    creator: event.args.creator,
    teamVestingWallet: event.args.teamVestingWallet,
    teamShares: event.args.teamShares,
    auctionShares: event.args.auctionShares,
    polShares: event.args.polShares,
  }))

  await setState(context.db, STATE.totalSupply, s0, event.block.number)
  await setState(context.db, STATE.supplyEvented, s0, event.block.number)
})

/**
 * `genesisPlace` — step two, and the block the protocol opens in.
 *
 * Revision 7 changed the shape: `teamVestingWallet` left for `GenesisMinted` and `p0X18` and
 * `raisedUsd18` arrived, so the launch log now says what the auction decided rather than only that
 * a launch happened. `genesisAt` is stamped here rather than at the mint because the creator's own
 * decay clock starts here — the bidding window does not eat into it.
 */
ponder.on('AmpsVault:Genesis', async ({event, context}) => {
  await updateSummary(context.db, event.block.number, event.block.timestamp, () => ({
    vault: context.contracts.AmpsVault.address as `0x${string}`,
    amps: context.contracts.AmpsToken.address as `0x${string}`,
    registry: context.contracts.PoolRegistry.address as `0x${string}`,
    genesisAt: event.block.timestamp,
    genesisBlock: event.block.number,
    creator: event.args.creator,
    genesisMinted: event.args.totalMinted,
    genesisNavPerShareX18: event.args.navPerShareX18,
    navPerShareX18: event.args.navPerShareX18,
    totalAssetsUsd18: event.args.raisedUsd18,
    totalSupply: event.args.totalMinted,
    pRefX18: event.args.p0X18,
    premiumBps: launchPremiumBps(event.args.p0X18, event.args.navPerShareX18),
  }))

  // The other half of the launch row: what the vault measured, beside what the adapter swept. On
  // the fallback path this is the only settlement record there is — `settle()` emitted an aborted
  // `Settled` and the timelock opened the vault itself, hours or days later.
  await updateGenesis(context.db, event.block.number, () => ({
    vault: context.contracts.AmpsVault.address as `0x${string}`,
    creator: event.args.creator,
    launchBlock: event.block.number,
    launchAt: event.block.timestamp,
    totalMinted: event.args.totalMinted,
    navPerShareX18: event.args.navPerShareX18,
    raisedUsd18: event.args.raisedUsd18,
    premiumBps: launchPremiumBps(event.args.p0X18, event.args.navPerShareX18),
  }))

  await setState(context.db, STATE.genesisAt, event.block.timestamp, event.block.number)
  await setState(context.db, STATE.navPerShareX18, event.args.navPerShareX18, event.block.number)
  await setState(context.db, STATE.totalAssetsUsd18, event.args.raisedUsd18, event.block.number)
  await setState(context.db, STATE.pRefX18, event.args.p0X18, event.block.number)
  await setState(context.db, STATE.totalSupply, event.args.totalMinted, event.block.number)
  await setState(context.db, STATE.supplyEvented, event.args.totalMinted, event.block.number)
})

// -------------------------------------------------------------------------------------------------
// Checkpoints
// -------------------------------------------------------------------------------------------------

ponder.on('AmpsVault:NavCheckpoint', async ({event, context}) => {
  const previous = (await getState(context.db, STATE.navPerShareX18)) ?? 0n

  await context.db.insert(schema.navCheckpoint).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    navPerShareX18: event.args.navPerShareX18,
    totalAssetsUsd18: event.args.totalAssetsUsd18,
    totalSupply: event.args.totalSupply,
    navChangeBps: previous === 0n ? 0 : changeBps(previous, event.args.navPerShareX18),
  })

  // Seed the event-derived supply from the first checkpoint the indexer sees, so an indexer started
  // mid-life has a starting point; after that it moves only on `VestingMinted` and `Burn` and never
  // on a chain read, which is what makes the supply pair a real two-sided check.
  if ((await getState(context.db, STATE.supplyEvented)) === undefined) {
    await setState(context.db, STATE.supplyEvented, event.args.totalSupply, event.block.number)
  }

  // L-1, made visible. NAV/share falling with nothing between the two checkpoints that is allowed
  // to move it is the convergence step the fuzz lead described; the accepted disposition was to
  // document it and watch for it, which is this. Raised before the state is advanced, because the
  // predicate is about the *previous* checkpoint and what happened since.
  await checkNavDrift(context, event, previous)

  await setState(context.db, PREV_NAV, previous, event.block.number)
  await setState(context.db, STATE.navPerShareX18, event.args.navPerShareX18, event.block.number)
  await setState(context.db, STATE.totalAssetsUsd18, event.args.totalAssetsUsd18, event.block.number)
  await setState(context.db, STATE.totalSupply, event.args.totalSupply, event.block.number)
  await setState(context.db, STATE.lastCheckpointBlock, event.block.number, event.block.number)
  await setState(context.db, STATE.navMoved, 0n, event.block.number)

  await updateSummary(context.db, event.block.number, event.block.timestamp, (row) => ({
    navPerShareX18: event.args.navPerShareX18,
    totalAssetsUsd18: event.args.totalAssetsUsd18,
    totalSupply: event.args.totalSupply,
    premiumBps: row.pRefX18 === 0n ? 0 : premiumBps(event.args.navPerShareX18, row.pRefX18),
  }))

  await updateFlywheelDay(context.db, event.block.timestamp, (row) => ({
    navOpenX18: row.navOpenX18 === 0n ? event.args.navPerShareX18 : row.navOpenX18,
    navCloseX18: event.args.navPerShareX18,
  }))

  // A bond priced against the checkpoint *before* this one; this is the checkpoint that realises
  // its accretion (phase-2 §6). No-op when no bond is pending.
  await settleAccretion(context.db, event.args.navPerShareX18, event.block.number, event.block.timestamp)
})

ponder.on('AmpsVault:RefCheckpoint', async ({event, context}) => {
  const nav = (await getState(context.db, STATE.navPerShareX18)) ?? 0n
  const premium = premiumX18(nav, event.args.pRefX18)
  const bps = premiumBps(nav, event.args.pRefX18)

  await context.db.insert(schema.refCheckpoint).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    pRefX18: event.args.pRefX18,
    pMktX18: event.args.pMktX18,
    rateLimited: event.args.rateLimited,
    navFloored: event.args.navFloored,
    navPerShareX18: nav,
    premiumX18: premium,
    premiumBps: bps,
  })

  await setState(context.db, STATE.pRefX18, event.args.pRefX18, event.block.number)
  await setState(context.db, STATE.pMktX18, event.args.pMktX18, event.block.number)

  await updateSummary(context.db, event.block.number, event.block.timestamp, () => ({
    pRefX18: event.args.pRefX18,
    pMktX18: event.args.pMktX18,
    premiumBps: bps,
  }))
  await updateFlywheelDay(context.db, event.block.timestamp, () => ({premiumCloseBps: bps}))

  // Reconciliation runs *here*, not on `NavCheckpoint`: `_checkpoint()` emits `NavCheckpoint` and
  // then `RefCheckpoint`, so this is the first moment at which both halves of the checkpoint the
  // vault just wrote are in the index and comparable against `checkpointData()`.
  await sampleShares(context, event.block.number, event.block.timestamp, 'checkpoint')
  await runReconciliation(context, event.block.number, event.block.timestamp, 'checkpoint')
})

// -------------------------------------------------------------------------------------------------
// Supply movements
// -------------------------------------------------------------------------------------------------

ponder.on('AmpsVault:Redeem', async ({event, context}) => {
  const nav = (await getState(context.db, STATE.navPerShareX18)) ?? 0n
  const grossUsd18 = (event.args.shares * nav) / 10n ** 18n
  const feeUsd18 = (grossUsd18 * BigInt(event.args.feeBps)) / 10_000n
  const expectedUsd18 = grossUsd18 - feeUsd18

  // SP-14: what the redeemer was owed on the NAV basis, against what the vault actually pays.
  const gap = await measureRedeemGap(context as unknown as JobContext, event, expectedUsd18)

  await context.db.insert(schema.redemption).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    owner: event.args.owner,
    to: event.args.to,
    shares: event.args.shares,
    // Released, not burned: revision 8 queues the vault's own slice for the next checkpoint.
    inventoryReleased: event.args.inventoryReleased,
    feeBps: event.args.feeBps,
    navPerShareX18: nav,
    grossUsd18,
    feeUsd18,
    expectedUsd18,
    realisedUsd18: gap.realisedUsd18,
    gapBps: gap.gapBps,
    gapPriced: gap.priced,
  })

  const severity = gap.priced ? redeemGapSeverity(gap.gapBps) : undefined
  if (severity !== undefined) {
    await raiseAlert(context.db, event.log.logIndex, {
      kind: 'redeem-gap',
      severity,
      subject: event.args.owner,
      message:
        `a redemption of ${event.args.shares} shares paid ${gap.gapBps} bp under its NAV basis ` +
        `(warning above ${REDEEM_GAP_WARNING_BPS} bp, critical above ${REDEEM_GAP_CRITICAL_BPS} bp)`,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      detail: jsonRecord({
        owner: event.args.owner,
        to: event.args.to,
        shares: event.args.shares,
        feeBps: event.args.feeBps,
        navPerShareX18: nav,
        expectedUsd18,
        realisedUsd18: gap.realisedUsd18,
        gapBps: gap.gapBps,
        previewedAtBlock: event.block.number - 1n,
        txHash: event.transaction.hash,
      }),
    })
  }

  // The supply is *not* moved here. `redeemProRata` emits `Burn(shares, "redeem")` for the
  // redeemer's own shares, which the `Burn` handler already subtracts; doing it again here would
  // double-count the exit. The vault's released inventory is **not** burned in this transaction at
  // all — it drains on a 24-hour linear stream, and every settlement of that stream arrives as its
  // own `Burn(amount, "redeemInventory")`, which the same handler picks up whenever it happens.
  await markNavMoved(context.db, event.block.number)
  await updateSummary(context.db, event.block.number, event.block.timestamp, (row) => ({
    redeemedSharesTotal: row.redeemedSharesTotal + event.args.shares,
  }))
  await updateFlywheelDay(context.db, event.block.timestamp, (row) => ({
    redeemedShares: row.redeemedShares + event.args.shares,
  }))
})

/**
 * The `redeem-gap` measurement (SP-14).
 *
 * `Redeem` carries no per-asset payouts, so the realised side has to come from
 * `previewRedeem(shares)` — read at **`blockNumber - 1`**, because at the redemption's own block
 * the shares are burned and the positions unwound, and the preview would then describe a vault the
 * redeemer never had a claim on. The amounts are valued at the answers the indexer has already
 * accepted for each token, which is the same valuation every other USD figure in this index uses.
 *
 * A token the index cannot price makes the whole comparison meaningless rather than smaller, so the
 * result is marked unpriced and no alert is raised: an unpriceable payout is not a zero gap.
 */
async function measureRedeemGap(
  context: JobContext,
  event: {args: {shares: bigint}; block: {number: bigint}},
  expectedUsd18: bigint,
): Promise<{realisedUsd18: bigint; gapBps: number; priced: boolean}> {
  const vault = (context.contracts.AmpsVault?.address as `0x${string}` | undefined) ?? undefined
  if (vault === undefined || expectedUsd18 <= 0n) return {realisedUsd18: 0n, gapBps: 0, priced: false}

  const preview = await read<readonly [readonly `0x${string}`[], readonly bigint[], bigint]>(
    context,
    vault,
    ampsVaultAbi,
    'previewRedeem',
    [event.args.shares],
    event.block.number - 1n,
  )
  if (preview === undefined) return {realisedUsd18: 0n, gapBps: 0, priced: false}

  const [tokens, amounts] = preview
  let realisedUsd18 = 0n
  for (const [i, token] of tokens.entries()) {
    const amount = amounts[i] ?? 0n
    if (amount === 0n) continue
    const priced = await valueTokenUsd18(context, token, amount)
    if (priced === undefined) return {realisedUsd18: 0n, gapBps: 0, priced: false}
    realisedUsd18 += priced
  }

  return {realisedUsd18, gapBps: redeemGapBps(expectedUsd18, realisedUsd18), priced: true}
}

/**
 * One payout leg in 18-decimal USD, at the answer the protocol last accepted for that token.
 *
 * The decimals come from the `constituent` row where there is one and from a cached `decimals()`
 * read otherwise — the vault also pays out WETH and USDG, which are collateral rather than
 * constituents and have no row. The cache is a module-level map because a redemption can touch
 * every asset the vault holds and the answer never changes for a given token.
 */
const DECIMALS_CACHE = new Map<string, number>()

async function valueTokenUsd18(
  context: JobContext,
  token: `0x${string}`,
  amount: bigint,
): Promise<bigint | undefined> {
  const id = token.toLowerCase() as `0x${string}`
  const feed = await context.db.find(schema.feed, {id})
  if (feed === null || feed.answerUsd8 <= 0n) return undefined

  let decimals = DECIMALS_CACHE.get(id)
  if (decimals === undefined) {
    const index = await context.db.find(schema.tokenIndex, {id})
    const constituent =
      index === null ? null : await context.db.find(schema.constituent, {id: index.constituentId.toString()})
    const read18 =
      constituent?.decimals ?? (await read<number>(context, token, erc20Abi, 'decimals'))
    if (read18 === undefined) return undefined
    decimals = Number(read18)
    DECIMALS_CACHE.set(id, decimals)
  }

  return (to18(amount, decimals) * usd8ToUsd18(feed.answerUsd8)) / 10n ** 18n
}

/**
 * `nav-drift` (L-1): NAV/share fell with nothing between the two checkpoints allowed to move it.
 *
 * `STATE.navMoved` is set by every `Bond`, `Redeem`, `Placement`, `Compound`, pool `Swap` and feed
 * `AnswerUpdated`, and cleared by each checkpoint. If it is clear and NAV/share is more than 1 bp
 * down, the only thing left that can have moved the number is the vault's own convergence step —
 * which is the accepted lead, and the reason this alert exists rather than a fix.
 */
async function checkNavDrift(
  context: {db: Db},
  event: {args: {navPerShareX18: bigint}; block: {number: bigint; timestamp: bigint}; log: {logIndex: number}},
  previousNavX18: bigint,
): Promise<void> {
  const moved = ((await getState(context.db, STATE.navMoved)) ?? 0n) !== 0n
  if (!isNavDrift({previousNavX18, navX18: event.args.navPerShareX18, movedSincePrevious: moved})) return

  await raiseAlert(context.db, event.log.logIndex, {
    kind: 'nav-drift',
    severity: 'warning',
    subject: event.block.number.toString(),
    message:
      `NAV/share fell from ${previousNavX18} to ${event.args.navPerShareX18} with no bond, ` +
      'redemption, placement, compound, swap or feed update between the two checkpoints',
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    detail: jsonRecord({
      previousNavPerShareX18: previousNavX18,
      navPerShareX18: event.args.navPerShareX18,
      changeBps: changeBps(previousNavX18, event.args.navPerShareX18),
    }),
  })
}

ponder.on('AmpsVault:Burn', async ({event, context}) => {
  const reason = decodeBytes32String(event.args.reason)
  const supply = ((await getState(context.db, STATE.supplyEvented)) ?? 0n) - event.args.amount
  await setState(context.db, STATE.supplyEvented, supply, event.block.number)
  await context.db.insert(schema.burnEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    amount: event.args.amount,
    reasonRaw: event.args.reason,
    reason,
    poolId: null,
  })
  await updateSummary(context.db, event.block.number, event.block.timestamp, (row) => ({
    burnedAllTotal: row.burnedAllTotal + event.args.amount,
    netSupplyChange: row.netSupplyChange - event.args.amount,
  }))
  await updateFlywheelDay(context.db, event.block.timestamp, (row) => ({
    burnedAmps: row.burnedAmps + event.args.amount,
    netSupplyChange: row.netSupplyChange - event.args.amount,
  }))
  await reconcileAgain(context, event.block.number, event.block.timestamp)
})

ponder.on('AmpsVault:VestingMinted', async ({event, context}) => {
  // Every post-genesis mint comes through here, including the AMPS a bond issues: `AmpsBonds`
  // receives its principal by `mintVesting` (I30) and the log now says so with `reason == "bond"`,
  // so `Bond.ampsOut` describes this same mint and is never added on top.
  const supply = ((await getState(context.db, STATE.supplyEvented)) ?? 0n) + event.args.amount
  await setState(context.db, STATE.supplyEvented, supply, event.block.number)

  await context.db.insert(schema.vestingMint).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    to: event.args.to,
    amount: event.args.amount,
    reasonRaw: event.args.reason,
    reason: decodeBytes32String(event.args.reason),
  })
  await updateSummary(context.db, event.block.number, event.block.timestamp, (row) => ({
    vestingMintedTotal: row.vestingMintedTotal + event.args.amount,
    netSupplyChange: row.netSupplyChange + event.args.amount,
  }))
  await reconcileAgain(context, event.block.number, event.block.timestamp)
})

ponder.on('AmpsVault:BondedDeposit', async ({event, context}) => {
  await context.db.insert(schema.constituentEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    constituentId: event.args.constituentId,
    kind: 'bondedDeposit',
    field: event.args.collateral,
    previousValue: null,
    newValue: event.args.amount,
  })
})

// -------------------------------------------------------------------------------------------------
// Placement, compound
// -------------------------------------------------------------------------------------------------

ponder.on('AmpsVault:Placement', async ({event, context}) => {
  // A placement moves the assets, so a NAV fall after it is not the `nav-drift` case.
  await markNavMoved(context.db, event.block.number)
  const id = poolKey(event.args.poolId)
  const liqKey = PLACEMENT_LIQ(event.transaction.hash, id)
  const liquidity = (await getState(context.db, liqKey)) ?? 0n
  const reason = decodeBytes32String(event.args.reason)
  // The vault says why it placed, so the selector heuristic is only the fallback now.
  const action = actionFromReason(reason) ?? classifyAction(event.transaction.input)

  await context.db.insert(schema.placement).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    poolId: id,
    above: event.args.above,
    buckets: event.args.buckets,
    amount: event.args.amount,
    anchorTick: event.args.anchorTick,
    reasonRaw: event.args.reason,
    reason,
    action,
    caller: event.transaction.from,
    lowerTick: event.args.lowerTick,
    upperTick: event.args.upperTick,
    // `buckets` is the cell count the placement wrote — `VaultPlacementLib` emits `result.cells`
    // there — so the cells no longer have to be counted off the `ModifyLiquidity` logs.
    cells: event.args.buckets,
    liquidityAdded: liquidity,
  })

  await context.db.delete(schema.indexerState, {id: liqKey})

  const pool = await context.db.find(schema.pool, {id})
  await recordKeeperJob({
    db: context.db,
    txHash: event.transaction.hash,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    caller: event.transaction.from,
    job: action,
    poolId: id,
    constituentId: pool?.constituentId,
    outcome: event.args.amount > 0n ? 'ok' : 'noop',
    detail: {
      amount: event.args.amount.toString(),
      above: event.args.above,
      reason,
      lowerTick: event.args.lowerTick,
      upperTick: event.args.upperTick,
    },
  })
})

/**
 * `Rollout` is its own event now, carrying both halves: what left the entry pools and what the
 * destination spoke's ladder actually committed. Nothing is reconstructed from the placements and
 * the entry-pool withdrawals any more.
 */
ponder.on('AmpsVault:Rollout', async ({event, context}) => {
  await context.db.insert(schema.rolloutEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    constituentId: event.args.constituentId,
    caller: event.transaction.from,
    movedAmps: event.args.movedAmps,
    placedAmps: event.args.placedAmps,
    toPoolId: poolKey(event.args.poolId),
    bountyPaidUsd18: 0n,
  })

  await recordKeeperJob({
    db: context.db,
    txHash: event.transaction.hash,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    caller: event.transaction.from,
    job: 'rollout',
    poolId: poolKey(event.args.poolId),
    constituentId: event.args.constituentId,
    outcome: event.args.placedAmps > 0n ? 'ok' : 'noop',
    detail: {
      movedAmps: event.args.movedAmps.toString(),
      placedAmps: event.args.placedAmps.toString(),
    },
  })
})

/**
 * `Compound`, revision 6: `(poolId, ampsFees, counterFees, creatorAmps, creatorCounter, burned)`.
 *
 * The two currencies are kept apart on purpose all the way through the schema. The creator takes
 * `creatorBps(t) / ampsFeeBps` of **each** of them in kind — AMPS by transfer, the counter asset in
 * kind with an ERC-6909 claim fallback — the whole AMPS-side remainder is burned, and the counter
 * side is re-placed as bids in the pool that earned it. Adding the two into one figure would hide
 * exactly the distinction the revision exists to make, so the counter legs are carried both raw (in
 * the counter's own decimals, which only mean something per pool) and in 18-decimal USD (which is
 * the only way thirty-two assets can be summed).
 *
 * `burned` is the AMPS-side fee remainder **plus** the buyback burn, so it can exceed `ampsFees`;
 * the two `Burn` logs beside it (`"compound"` and `"buyback"`) are what separate them, and the
 * `Burn` handler indexes both with their reasons.
 */
ponder.on('AmpsVault:Compound', async ({event, context}) => {
  await markNavMoved(context.db, event.block.number)
  const id = poolKey(event.args.poolId)
  const navAfter = (await getState(context.db, STATE.navPerShareX18)) ?? 0n
  const navBefore = (await getState(context.db, PREV_NAV)) ?? navAfter
  const genesisAt = (await getState(context.db, STATE.genesisAt)) ?? 0n
  const pRef = (await getState(context.db, STATE.pRefX18)) ?? 0n

  // The counter legs are priced through the pool that produced them: its live price to reach AMPS,
  // then `P_ref` to reach USD. A pool the indexer has not seen open yet prices at zero rather than
  // guessing a decimals count.
  const poolRow = await context.db.find(schema.pool, {id})
  const counterDecimals = poolRow?.counterDecimals ?? 18
  const priceX18 =
    poolRow === null || poolRow.sqrtPriceX96 === 0n
      ? 0n
      : priceX18FromSqrt(poolRow.sqrtPriceX96, 18, counterDecimals)
  const counterFeesUsd18 = counterToUsd18(event.args.counterFees, counterDecimals, priceX18, pRef)
  const creatorCounterUsd18 = counterToUsd18(event.args.creatorCounter, counterDecimals, priceX18, pRef)

  await context.db.insert(schema.compoundEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    poolId: id,
    caller: event.transaction.from,
    ampsFees: event.args.ampsFees,
    counterFees: event.args.counterFees,
    creatorAmps: event.args.creatorAmps,
    creatorCounter: event.args.creatorCounter,
    burned: event.args.burned,
    counterFeesUsd18,
    creatorCounterUsd18,
    creatorBps: creatorBpsAt(event.block.timestamp, genesisAt, CREATOR_FEE_BPS, CREATOR_DECAY_SECONDS),
    navBeforeX18: navBefore,
    navAfterX18: navAfter,
    navChangeBps: changeBps(navBefore, navAfter),
    bountyPaidUsd18: 0n,
  })

  await updateSummary(context.db, event.block.number, event.block.timestamp, (row) => ({
    feesAmpsTotal: row.feesAmpsTotal + event.args.ampsFees,
    feesCounterUsd18: row.feesCounterUsd18 + counterFeesUsd18,
    creatorPaidAmpsTotal: row.creatorPaidAmpsTotal + event.args.creatorAmps,
    creatorPaidCounterUsd18: row.creatorPaidCounterUsd18 + creatorCounterUsd18,
    burnedTotal: row.burnedTotal + event.args.burned,
    compoundCount: row.compoundCount + 1,
  }))

  await updateFlywheelDay(context.db, event.block.timestamp, (row) => ({
    creatorPaidAmps: row.creatorPaidAmps + event.args.creatorAmps,
    creatorPaidCounterUsd18: row.creatorPaidCounterUsd18 + creatorCounterUsd18,
  }))

  await recordKeeperJob({
    db: context.db,
    txHash: event.transaction.hash,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    caller: event.transaction.from,
    job: 'compound',
    poolId: id,
    outcome: event.args.ampsFees > 0n || event.args.burned > 0n ? 'ok' : 'noop',
    detail: {ampsFees: event.args.ampsFees.toString(), burned: event.args.burned.toString()},
  })

  // R1 (§3.6 step 9): a `compound` may not bleed NAV/share by more than 2 bp. The contract reverts
  // on a breach, so a row here means the chain disagreed with the indexer's arithmetic, not that
  // the protocol lost money — either way it is worth paging on.
  if (navBefore > 0n && changeBps(navBefore, navAfter) < -2) {
    await raiseAlert(context.db, event.log.logIndex, {
      kind: 'nav-bleed',
      severity: 'critical',
      subject: id,
      message: `compound bled ${changeBps(navBefore, navAfter)} bps of NAV/share, past the 2 bp R1 bound`,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      detail: jsonRecord({poolId: id, navBefore, navAfter, txHash: event.transaction.hash}),
    })
  }
})

// -------------------------------------------------------------------------------------------------
// The exit sweep
// -------------------------------------------------------------------------------------------------

/**
 * `sweepClean` (I12) could not fold a registered token's idle balance into the vault's ERC-6909
 * claims, so the balance is still sitting on the vault at function exit.
 *
 * **This is the log that replaced the `SweepDirty` revert, and the difference matters to the
 * index.** Reverting on the residue handed anybody a one-transaction kill switch: donate one wei of
 * a Stock Token to the vault, have the issuer pause it or denylist the vault, and every entry point
 * — `redeemProRata` included, which §7 says can never be gated — reverts forever. The residue is
 * therefore disclosed rather than enforced: it stays part of the vault's holdings, is valued in `A`,
 * is paid out by redemption when the token allows a transfer again, and is absorbed by the next
 * sweep that succeeds. **Nothing about NAV or the supply moves here**, which is why this handler
 * writes no checkpoint, no summary patch and no share movement.
 *
 * What is left is an operational fact: a token the vault holds has stopped accepting a transfer
 * from it. That is one alert at `warning` — the same fact the denylist alarm would raise at
 * `critical` if it could see the issuer's call, which for a `blockAccounts` routed through a
 * multicall or a Safe it cannot.
 */
ponder.on('AmpsVault:SweepResidue', async ({event, context}) => {
  const token = event.args.token.toLowerCase() as `0x${string}`
  const indexed = await context.db.find(schema.tokenIndex, {id: token})

  await raiseAlert(context.db, event.log.logIndex, {
    kind: 'sweep-residue',
    severity: 'warning',
    subject: token,
    message: `sweepClean could not absorb ${event.args.balance.toString()} of ${token}; it is still on the vault`,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    detail: {
      token,
      balance: event.args.balance,
      constituentId: indexed === null ? null : indexed.constituentId,
      txHash: event.transaction.hash,
    },
  })
})

// -------------------------------------------------------------------------------------------------
// Gate, parameters, governance
// -------------------------------------------------------------------------------------------------

ponder.on('AmpsVault:GateChanged', async ({event, context}) => {
  const id = poolKey(event.args.poolId)
  await context.db.insert(schema.gateTransition).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    poolId: id,
    source: 'vault',
    previousState: event.args.previousState,
    newState: event.args.newState,
    previousLabel: gateStateLabel(event.args.previousState),
    newLabel: gateStateLabel(event.args.newState),
  })
  await context.db
    .insert(schema.gateStatus)
    .values({
      id,
      poolId: id,
      state: event.args.newState,
      stateLabel: gateStateLabel(event.args.newState),
      diverged: gateStateLabel(event.args.newState) === GATE_STATES[2],
      divergenceBps: 0,
      watchdogTripped: gateStateLabel(event.args.newState) === GATE_STATES[5],
      watchdogElapsed: 0,
      protocolFreezeUntil: 0n,
      updatedAt: event.block.timestamp,
      updatedBlock: event.block.number,
    })
    .onConflictDoUpdate(() => ({
      state: event.args.newState,
      stateLabel: gateStateLabel(event.args.newState),
      updatedAt: event.block.timestamp,
      updatedBlock: event.block.number,
    }))
  const poolRow = await context.db.find(schema.pool, {id})
  if (poolRow !== null) {
    await context.db.update(schema.pool, {id}).set({
      gateState: event.args.newState,
      gateStateLabel: gateStateLabel(event.args.newState),
      gateUpdatedAt: event.block.timestamp,
    })
  }
})

ponder.on('AmpsVault:VaultParameterChanged', async ({event, context}) => {
  await recordParameter(context, event, 'vault', decodeBytes32String(event.args.parameter), {
    previousValue: event.args.previousValue,
    newValue: event.args.newValue,
  })
})

ponder.on('AmpsVault:PolicyPointerChanged', async ({event, context}) => {
  await recordParameter(context, event, 'vault.pointer', decodeBytes32String(event.args.slot), {
    previousAddress: event.args.previousPointer,
    newAddress: event.args.newPointer,
  })
})

ponder.on('AmpsVault:CreatorChanged', async ({event, context}) => {
  await recordParameter(context, event, 'vault', 'creator', {
    previousAddress: event.args.previousCreator,
    newAddress: event.args.newCreator,
  })
  await updateSummary(context.db, event.block.number, event.block.timestamp, () => ({
    creator: event.args.newCreator,
  }))
})

ponder.on('AmpsVault:StandbyVaultRegistered', async ({event, context}) => {
  await recordParameter(context, event, 'vault', 'standbyVault', {newAddress: event.args.standby})
})

ponder.on('AmpsVault:Migrated', async ({event, context}) => {
  await recordParameter(context, event, 'vault', 'migrated', {newAddress: event.args.newVault})
  await raiseAlert(context.db, event.log.logIndex, {
    kind: 'gate',
    severity: 'critical',
    subject: event.args.newVault,
    message: 'the vault migrated to the standby',
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    detail: jsonRecord({
      newVault: event.args.newVault,
      navPerShareBefore: event.args.navPerShareBefore,
      navPerShareAfter: event.args.navPerShareAfter,
    }),
  })
})

// -------------------------------------------------------------------------------------------------
// Token
// -------------------------------------------------------------------------------------------------

ponder.on('AmpsToken:VaultChanged', async ({event, context}) => {
  await recordParameter(context, event, 'amps', 'vault', {
    previousAddress: event.args.previousVault,
    newAddress: event.args.newVault,
  })
})

/** Scratch keys the `ModifyLiquidity` handler writes and `Placement` consumes. */
export const placementScratch = {liquidity: PLACEMENT_LIQ, prevNav: PREV_NAV}
