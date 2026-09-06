// SPDX-License-Identifier: MIT

/**
 * The keeper-job ledger.
 *
 * One row per keeper-shaped transaction, keyed by the transaction hash so a job that emits several
 * events (a `compound` emits `Compound`, `Burn`, `Placement`, `NavCheckpoint`, `RefCheckpoint` and
 * `BountyPaid`) collapses into one row. `outcome` starts as `noop` and is raised to `ok` by
 * whichever handler recognises the job's own event, so a `rollout` that moved nothing and a
 * `rollout` that moved inventory are distinguishable — which is exactly what the Phase 4 exit
 * criterion ("zero missed triggers") needs to be measurable.
 */

import schema from 'ponder:schema'

import {isKeeperJob, type VaultAction} from './actions'
import {jsonRecord} from './json'
import type {Db} from './store'

export interface KeeperJobInput {
  db: Db
  txHash: `0x${string}`
  blockNumber: bigint
  timestamp: bigint
  caller: `0x${string}`
  job: VaultAction
  poolId?: `0x${string}`
  constituentId?: number
  outcome: 'ok' | 'noop' | 'unknown'
  detail?: Record<string, unknown>
}

export async function recordKeeperJob(input: KeeperJobInput): Promise<void> {
  if (!isKeeperJob(input.job)) return
  await input.db
    .insert(schema.keeperJob)
    .values({
      id: input.txHash,
      blockNumber: input.blockNumber,
      timestamp: input.timestamp,
      txHash: input.txHash,
      job: input.job,
      caller: input.caller,
      poolId: input.poolId ?? null,
      constituentId: input.constituentId ?? null,
      outcome: input.outcome,
      bountyPaidUsd18: 0n,
      detail: jsonRecord(input.detail ?? {}),
    })
    .onConflictDoUpdate((row) => ({
      job: input.job,
      poolId: input.poolId ?? row.poolId,
      constituentId: input.constituentId ?? row.constituentId,
      outcome: input.outcome === 'ok' ? 'ok' : row.outcome,
      detail: jsonRecord({...(row.detail as Record<string, unknown>), ...(input.detail ?? {})}),
    }))
}
