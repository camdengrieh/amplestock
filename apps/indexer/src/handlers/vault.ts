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

import {classifyAction} from '../lib/actions'
import {decodeBytes32String} from '../lib/bytes32'
import {
  CREATOR_DECAY_SECONDS,
  CREATOR_FEE_BPS,
  GATE_STATES,
  gateStateLabel,
} from '../lib/constants'
import {eventId, poolKey} from '../lib/ids'
import {changeBps, clampInt, creatorBpsAt, premiumBps, premiumX18} from '../lib/math'
import {recordKeeperJob} from '../lib/keeper'
import {recordParameter} from '../lib/parameters'
import {jsonRecord} from '../lib/json'
import {
  STATE,
  getState,
  raiseAlert,
  setState,
  updateFlywheelDay,
  updateSummary,
} from '../lib/store'
import {settleAccretion} from './bonds'
import {reconcileAgain, runReconciliation, sampleShares} from './reconcile'

const PREV_NAV = 'vault.navPerSharePrevX18'
const PLACEMENT_CELLS = (tx: string, pool: string) => `placement.cells.${tx}.${pool}`
const PLACEMENT_LIQ = (tx: string, pool: string) => `placement.liquidity.${tx}.${pool}`

// -------------------------------------------------------------------------------------------------
// Genesis
// -------------------------------------------------------------------------------------------------

ponder.on('AmpsVault:Genesis', async ({event, context}) => {
  await updateSummary(context.db, event.block.number, event.block.timestamp, () => ({
    vault: context.contracts.AmpsVault.address as `0x${string}`,
    amps: context.contracts.AmpsToken.address as `0x${string}`,
    registry: context.contracts.PoolRegistry.address as `0x${string}`,
    genesisAt: event.block.timestamp,
    genesisBlock: event.block.number,
    creator: event.args.creator,
    teamVestingWallet: event.args.teamVestingWallet,
    genesisMinted: event.args.totalMinted,
    genesisNavPerShareX18: event.args.navPerShareX18,
    navPerShareX18: event.args.navPerShareX18,
    totalSupply: event.args.totalMinted,
  }))
  await setState(context.db, STATE.genesisAt, event.block.timestamp, event.block.number)
  await setState(context.db, STATE.navPerShareX18, event.args.navPerShareX18, event.block.number)
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
  // mid-life has a starting point; after that it moves only on `VestingMinted`, `Burn` and `Redeem`
  // and never on a chain read, which is what makes the supply pair a real two-sided check.
  if ((await getState(context.db, STATE.supplyEvented)) === undefined) {
    await setState(context.db, STATE.supplyEvented, event.args.totalSupply, event.block.number)
  }

  await setState(context.db, PREV_NAV, previous, event.block.number)
  await setState(context.db, STATE.navPerShareX18, event.args.navPerShareX18, event.block.number)
  await setState(context.db, STATE.totalAssetsUsd18, event.args.totalAssetsUsd18, event.block.number)
  await setState(context.db, STATE.totalSupply, event.args.totalSupply, event.block.number)
  await setState(context.db, STATE.lastCheckpointBlock, event.block.number, event.block.number)

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

  await context.db.insert(schema.redemption).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    owner: event.args.owner,
    to: event.args.to,
    shares: event.args.shares,
    inventoryBurned: event.args.inventoryBurned,
    feeBps: event.args.feeBps,
    navPerShareX18: nav,
    grossUsd18,
    feeUsd18,
  })

  // The redeemer's own `shares` are burned here; the vault's `inventoryBurned` slice arrives as its
  // own `Burn(amount, "redeemInventory")`, so subtracting both would double-count it.
  const supply = ((await getState(context.db, STATE.supplyEvented)) ?? 0n) - event.args.shares
  await setState(context.db, STATE.supplyEvented, supply, event.block.number)

  await updateSummary(context.db, event.block.number, event.block.timestamp, (row) => ({
    redeemedSharesTotal: row.redeemedSharesTotal + event.args.shares,
    netSupplyChange: row.netSupplyChange - event.args.shares,
  }))
  await updateFlywheelDay(context.db, event.block.timestamp, (row) => ({
    redeemedShares: row.redeemedShares + event.args.shares,
    netSupplyChange: row.netSupplyChange - event.args.shares,
  }))
  await reconcileAgain(context, event.block.number, event.block.timestamp)
})

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
    burned: row.burned + event.args.amount,
    netSupplyChange: row.netSupplyChange - event.args.amount,
  }))
  await reconcileAgain(context, event.block.number, event.block.timestamp)
})

ponder.on('AmpsVault:VestingMinted', async ({event, context}) => {
  // Every post-genesis mint comes through here, including the AMPS a bond issues: `AmpsBonds`
  // receives its principal by `mintVesting` (I30), so `Bond.ampsOut` is never added on top.
  const supply = ((await getState(context.db, STATE.supplyEvented)) ?? 0n) + event.args.amount
  await setState(context.db, STATE.supplyEvented, supply, event.block.number)

  await context.db.insert(schema.vestingMint).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    to: event.args.to,
    amount: event.args.amount,
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
  const id = poolKey(event.args.poolId)
  const cellsKey = PLACEMENT_CELLS(event.transaction.hash, id)
  const liqKey = PLACEMENT_LIQ(event.transaction.hash, id)
  const cells = (await getState(context.db, cellsKey)) ?? 0n
  const liquidity = (await getState(context.db, liqKey)) ?? 0n
  const action = classifyAction(event.transaction.input)

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
    action,
    caller: event.transaction.from,
    cells: clampInt(cells),
    liquidityAdded: liquidity,
  })

  await context.db.delete(schema.indexerState, {id: cellsKey})
  await context.db.delete(schema.indexerState, {id: liqKey})

  const pool = await context.db.find(schema.pool, {id})
  if (action === 'rollout' && event.args.above) {
    const withdrawnKey = `rollout.withdrawn.${event.transaction.hash}`
    const withdrawn = (await getState(context.db, withdrawnKey)) ?? 0n
    await context.db
      .insert(schema.rolloutEvent)
      .values({
        id: eventId(event.block.number, event.log.logIndex),
        blockNumber: event.block.number,
        timestamp: event.block.timestamp,
        txHash: event.transaction.hash,
        constituentId: pool?.constituentId ?? 0,
        caller: event.transaction.from,
        moved: event.args.amount,
        withdrawn,
        toPoolId: id,
        fromPoolIds: [],
        bountyPaidUsd18: 0n,
      })
      .onConflictDoNothing()
    await context.db.delete(schema.indexerState, {id: withdrawnKey})
  }

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
    detail: {amount: event.args.amount.toString(), above: event.args.above, cells: clampInt(cells)},
  })
})

ponder.on('AmpsVault:Compound', async ({event, context}) => {
  const id = poolKey(event.args.poolId)
  const navAfter = (await getState(context.db, STATE.navPerShareX18)) ?? 0n
  const navBefore = (await getState(context.db, PREV_NAV)) ?? navAfter
  const genesisAt = (await getState(context.db, STATE.genesisAt)) ?? 0n
  const pRef = (await getState(context.db, STATE.pRefX18)) ?? 0n

  await context.db.insert(schema.compoundEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    poolId: id,
    caller: event.transaction.from,
    ampsFees: event.args.ampsFees,
    creatorPaid: event.args.creatorPaid,
    stakerPaid: event.args.stakerPaid,
    burned: event.args.burned,
    relaid: event.args.relaid,
    creatorBps: creatorBpsAt(event.block.timestamp, genesisAt, CREATOR_FEE_BPS, CREATOR_DECAY_SECONDS),
    navBeforeX18: navBefore,
    navAfterX18: navAfter,
    navChangeBps: changeBps(navBefore, navAfter),
    bountyPaidUsd18: 0n,
  })

  await updateSummary(context.db, event.block.number, event.block.timestamp, (row) => ({
    feesAmpsTotal: row.feesAmpsTotal + event.args.ampsFees,
    creatorPaidTotal: row.creatorPaidTotal + event.args.creatorPaid,
    stakerPaidTotal: row.stakerPaidTotal + event.args.stakerPaid,
    burnedTotal: row.burnedTotal + event.args.burned,
    relaidTotal: row.relaidTotal + event.args.relaid,
    compoundCount: row.compoundCount + 1,
  }))

  await updateFlywheelDay(context.db, event.block.timestamp, (row) => ({
    stakerPaid: row.stakerPaid + event.args.stakerPaid,
    creatorPaid: row.creatorPaid + event.args.creatorPaid,
    relaid: row.relaid + event.args.relaid,
    sellFeeAmps: row.sellFeeAmps + event.args.ampsFees,
    sellFeeUsd18: row.sellFeeUsd18 + (event.args.ampsFees * pRef) / 10n ** 18n,
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
export const placementScratch = {cells: PLACEMENT_CELLS, liquidity: PLACEMENT_LIQ, prevNav: PREV_NAV}
