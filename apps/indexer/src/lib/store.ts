// SPDX-License-Identifier: MIT

/**
 * The handful of writes every handler shares: the singleton vault summary, the per-day flywheel
 * rollup, the small key/value scratch the handlers keep between events, and the alert row.
 *
 * Everything is an upsert built from a complete default row, never a bare `db.update`: a handler
 * must work whether or not it is the first one to touch a row, and the first `Swap` can arrive
 * before the first `NavCheckpoint` on a chain the indexer starts mid-life.
 */

import type {Context} from 'ponder:registry'
import schema from 'ponder:schema'

import {deliver, type AlertPayload} from './alerts'
import {SINGLETON, dayStart, eventId} from './ids'
import {jsonRecord} from './json'

export type Db = Context['db']

type VaultSummary = typeof schema.vaultSummary.$inferSelect
type FlywheelDay = typeof schema.flywheelDay.$inferSelect

const ZERO = '0x0000000000000000000000000000000000000000' as const

export function emptySummary(blockNumber: bigint, timestamp: bigint): VaultSummary {
  return {
    id: SINGLETON,
    vault: ZERO,
    amps: ZERO,
    registry: ZERO,
    genesisAt: 0n,
    genesisBlock: 0n,
    creator: ZERO,
    teamVestingWallet: ZERO,
    genesisMinted: 0n,
    genesisNavPerShareX18: 0n,
    navPerShareX18: 0n,
    totalAssetsUsd18: 0n,
    totalSupply: 0n,
    pRefX18: 0n,
    pMktX18: 0n,
    premiumBps: 0,
    inventory: 0n,
    vesting: 0n,
    circulating: 0n,
    feesAmpsTotal: 0n,
    feesCounterUsd18: 0n,
    creatorPaidAmpsTotal: 0n,
    creatorPaidCounterUsd18: 0n,
    burnedTotal: 0n,
    burnedAllTotal: 0n,
    bondIssuedTotal: 0n,
    redeemedSharesTotal: 0n,
    vestingMintedTotal: 0n,
    netSupplyChange: 0n,
    compoundCount: 0,
    swapCount: 0,
    lastBlock: blockNumber,
    lastTimestamp: timestamp,
  }
}

/** Upsert the singleton summary: `patch` receives the current row and returns the fields to set. */
export async function updateSummary(
  db: Db,
  blockNumber: bigint,
  timestamp: bigint,
  patch: (row: VaultSummary) => Partial<VaultSummary>,
): Promise<void> {
  const base = emptySummary(blockNumber, timestamp)
  const seeded = {...base, ...patch(base)}
  await db
    .insert(schema.vaultSummary)
    .values(seeded)
    .onConflictDoUpdate((row) => ({
      ...patch(row),
      lastBlock: blockNumber > row.lastBlock ? blockNumber : row.lastBlock,
      lastTimestamp: timestamp > row.lastTimestamp ? timestamp : row.lastTimestamp,
    }))
}

export function emptyFlywheelDay(day: bigint): FlywheelDay {
  return {
    day,
    sellVolumeAmps: 0n,
    buyVolumeAmps: 0n,
    feeAmps: 0n,
    feeAmpsUsd18: 0n,
    feeCounterUsd18: 0n,
    bondIssuedAmps: 0n,
    bondAccretionUsd18: 0n,
    burnedAmps: 0n,
    creatorPaidAmps: 0n,
    creatorPaidCounterUsd18: 0n,
    redeemedShares: 0n,
    netSupplyChange: 0n,
    realisedLvrUsd18: 0n,
    navOpenX18: 0n,
    navCloseX18: 0n,
    premiumCloseBps: 0,
    swapCount: 0,
  }
}

/** Upsert the per-UTC-day flywheel rollup. */
export async function updateFlywheelDay(
  db: Db,
  timestamp: bigint,
  patch: (row: FlywheelDay) => Partial<FlywheelDay>,
): Promise<void> {
  const day = dayStart(timestamp)
  const base = emptyFlywheelDay(day)
  await db
    .insert(schema.flywheelDay)
    .values({...base, ...patch(base)})
    .onConflictDoUpdate((row) => patch(row))
}

/** A small durable scratch value, keyed by name. */
export async function setState(
  db: Db,
  key: string,
  value: bigint,
  blockNumber: bigint,
  text?: string,
): Promise<void> {
  await db
    .insert(schema.indexerState)
    .values({id: key, value, text: text ?? null, updatedBlock: blockNumber})
    .onConflictDoUpdate(() => ({value, text: text ?? null, updatedBlock: blockNumber}))
}

export async function getState(db: Db, key: string): Promise<bigint | undefined> {
  const row = await db.find(schema.indexerState, {id: key})
  return row?.value
}

export async function getStateText(db: Db, key: string): Promise<string | undefined> {
  const row = await db.find(schema.indexerState, {id: key})
  return row?.text ?? undefined
}

/** Keys used by more than one handler. */
export const STATE = {
  ampsFeeBps: 'hook.ampsFeeBps',
  navPerShareX18: 'vault.navPerShareX18',
  pRefX18: 'vault.pRefX18',
  pMktX18: 'vault.pMktX18',
  totalAssetsUsd18: 'vault.totalAssetsUsd18',
  totalSupply: 'amps.totalSupply',
  /**
   * The running supply the *events* imply, which is what reconciliation compares against
   * `Amps.totalSupply()`. Exact, and *only* from the mint and burn logs: `S0 + VestingMinted -
   * Burn`. Neither `Bond.ampsOut` nor `Redeem.shares` is applied on top — `AmpsBonds` receives its
   * AMPS through `mintVesting`, so a `Bond` always has a `VestingMinted(reason: "bond")` of the
   * same amount beside it, and `redeemProRata` emits `Burn(shares, "redeem")` for the redeemer's
   * shares. Revision 8 defers the vault's own slice: the released inventory is burned by the
   * **next** checkpoint as `Burn(amount, "redeemInventory")`, which this same running total
   * subtracts whenever that arrives.
   */
  supplyEvented: 'amps.supplyFromEvents',
  /**
   * Set to 1 by every event that is *allowed* to move NAV/share — `Bond`, `Redeem`, `Placement`,
   * `Compound`, a pool `Swap`, a feed `AnswerUpdated` — and cleared by each `NavCheckpoint`.
   *
   * It exists for exactly one check: `nav-drift`. A checkpoint whose NAV/share is below the
   * previous one while this flag is clear is the L-1 convergence step, and the flag is the only
   * way to tell that apart from the ordinary case of the assets having actually moved.
   */
  navMoved: 'vault.navMovedSinceCheckpoint',
  inventory: 'vault.inventoryAmps',
  genesisAt: 'vault.genesisAt',
  lastCheckpointBlock: 'vault.lastCheckpointBlock',
  /**
   * Every pool id the registry has announced, comma-joined in `text`, with the count in `value`.
   * `context.db` is a key-value store with no query side, so a job that has to walk *all* the pools
   * — the ladder cross-check — needs the key set written down as it is discovered.
   */
  poolIds: 'registry.poolIds',
} as const

/**
 * Note that something happened which is allowed to move NAV/share.
 *
 * Called from the handlers of every such event. It is deliberately a single flag rather than a
 * list: `nav-drift` only asks "did anything move the assets or their prices since the last
 * checkpoint", and a flag answers that without the indexer keeping a per-block ledger of causes.
 */
export async function markNavMoved(db: Db, blockNumber: bigint): Promise<void> {
  await setState(db, STATE.navMoved, 1n, blockNumber)
}

/**
 * Record an alert and hand it to the sink. Always writes the row first, so a delivery failure never
 * loses the alert; `delivered` and `deliveryError` say what the sink did.
 */
export async function raiseAlert(
  db: Db,
  logIndexOrSeq: number | string,
  alert: AlertPayload,
): Promise<{delivered: boolean; error?: string}> {
  const result = await deliver(alert)
  const id =
    typeof logIndexOrSeq === 'string'
      ? logIndexOrSeq
      : eventId(alert.blockNumber, logIndexOrSeq)
  await db
    .insert(schema.alert)
    .values({
      id,
      blockNumber: alert.blockNumber,
      timestamp: alert.timestamp,
      kind: alert.kind,
      severity: alert.severity,
      subject: alert.subject,
      message: alert.message,
      detail: jsonRecord(alert.detail),
      delivered: result.delivered,
      deliveryError: result.error ?? null,
    })
    .onConflictDoUpdate(() => ({
      delivered: result.delivered,
      deliveryError: result.error ?? null,
    }))
  return result
}
