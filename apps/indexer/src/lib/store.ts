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
    staked: 0n,
    circulating: 0n,
    feesAmpsTotal: 0n,
    creatorPaidTotal: 0n,
    stakerPaidTotal: 0n,
    burnedTotal: 0n,
    relaidTotal: 0n,
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
    sellFeeAmps: 0n,
    sellFeeUsd18: 0n,
    buyFeeUsd18: 0n,
    bondIssued: 0n,
    bondAccretionUsd18: 0n,
    burned: 0n,
    stakerPaid: 0n,
    creatorPaid: 0n,
    relaid: 0n,
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
  sellFeeBps: 'hook.sellFeeBps',
  navPerShareX18: 'vault.navPerShareX18',
  pRefX18: 'vault.pRefX18',
  pMktX18: 'vault.pMktX18',
  totalAssetsUsd18: 'vault.totalAssetsUsd18',
  totalSupply: 'amps.totalSupply',
  /**
   * The running supply the *events* imply, which is what reconciliation compares against
   * `Amps.totalSupply()`. Exact: `S0 + VestingMinted - Burn - Redeem.shares`. Bond issuance is not
   * added separately — `AmpsBonds` receives its AMPS through `mintVesting`, so a `Bond` is always
   * accompanied by a `VestingMinted` of the same amount, and `Redeem.inventoryBurned` is not
   * subtracted separately either, because the vault emits `Burn(amount, "redeemInventory")` for it.
   */
  supplyEvented: 'amps.supplyFromEvents',
  inventory: 'vault.inventoryAmps',
  genesisAt: 'vault.genesisAt',
  lastCheckpointBlock: 'vault.lastCheckpointBlock',
} as const

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
