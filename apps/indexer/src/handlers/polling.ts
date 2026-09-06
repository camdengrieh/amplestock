// SPDX-License-Identifier: MIT

/**
 * The two block-interval jobs.
 *
 * **`constituentPoll`** — the `uiMultiplier()` state diff. The Stock Token's display multiplier can
 * move without any announcement: a dividend reinvestment is an immediate, unannounced +0.1–1% step,
 * and `newUIMultiplier()`/`effectiveAt()` are only set for the *scheduled* changes. There is no
 * event for either, so the only way to see it is to read it and compare. The job reads
 * `uiMultiplier`, `newUIMultiplier`, `effectiveAt`, `oraclePaused` and `paused` for every ACTIVE
 * constituent, and writes a `multiplierPoint` **only when something changed** — a poll that finds
 * the same state writes nothing but the cursor.
 *
 * Every read is a bounded probe that swallows its own failure, exactly as the contracts treat these
 * views: the implementation sits behind a beacon under a codeless admin key and can revert or
 * return garbage at any block. A failed probe leaves the cached value and is not a change.
 *
 * The same job probes `isBlocked(vault)` and `isBlocked(poolManager)` per constituent — the second,
 * slower detector behind the denylist alarm (`denylist.ts` has the fast one).
 *
 * **`reconcile`** — the NAV/inventory heartbeat, so a quiet chain still produces reconciliation
 * rows between checkpoints. The checkpoint-triggered run is in `reconcile.ts` and is the one the
 * exit criterion is about.
 */

import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {stockTokenAbi} from '../abi/external'
import {CONSTITUENT_STATUS} from '../lib/constants'
import {jobId} from '../lib/ids'
import {changeBps} from '../lib/math'
import type {Db} from '../lib/store'
import {recordProbe} from './denylist'
import {runReconciliation, sampleShares, type JobContext} from './reconcile'

const ZERO = '0x0000000000000000000000000000000000000000'

interface Probe {
  multiplier?: bigint
  newMultiplier?: bigint
  effectiveAt?: bigint
  oraclePaused?: boolean
  paused?: boolean
  vaultBlocked?: boolean
}

async function probeToken(
  context: JobContext,
  token: `0x${string}`,
  vault: `0x${string}`,
): Promise<Probe> {
  const call = async <T>(functionName: string, args: unknown[] = []): Promise<T | undefined> => {
    try {
      return (await context.client.readContract({
        abi: stockTokenAbi,
        address: token,
        functionName,
        args,
      })) as T
    } catch {
      return undefined
    }
  }
  const [multiplier, newMultiplier, effectiveAt, oraclePaused, paused, vaultBlocked] =
    await Promise.all([
      call<bigint>('uiMultiplier'),
      call<bigint>('newUIMultiplier'),
      call<bigint>('effectiveAt'),
      call<boolean>('oraclePaused'),
      call<boolean>('paused'),
      vault === ZERO ? Promise.resolve(undefined) : call<boolean>('isBlocked', [vault]),
    ])
  return {multiplier, newMultiplier, effectiveAt, oraclePaused, paused, vaultBlocked}
}

ponder.on('constituentPoll:block', async ({event, context}) => {
  const vault = (context.contracts.AmpsVault.address as `0x${string}` | undefined) ?? (ZERO as `0x${string}`)
  const blockNumber = event.block.number
  const timestamp = event.block.timestamp

  // `MAX_CONSTITUENTS` is 64 and ids are 1-based and dense, so a bounded walk is the whole set.
  for (let i = 1; i <= 64; i++) {
    const id = i.toString()
    const row = await context.db.find(schema.constituent, {id})
    if (row === null) continue
    if (row.statusLabel === CONSTITUENT_STATUS[0]) continue

    const probe = await probeToken(context as unknown as JobContext, row.token, vault)
    const multiplier = probe.multiplier ?? row.uiMultiplierX18
    const newMultiplier = probe.newMultiplier ?? row.newUiMultiplierX18
    const effectiveAt = probe.effectiveAt ?? row.effectiveAt
    const oraclePaused = probe.oraclePaused ?? row.oraclePaused
    const paused = probe.paused ?? row.tokenPaused
    const vaultBlocked = probe.vaultBlocked ?? row.vaultBlocked

    const changed: string[] = []
    if (multiplier !== row.uiMultiplierX18) changed.push('multiplier')
    if (newMultiplier !== row.newUiMultiplierX18 || effectiveAt !== row.effectiveAt) {
      changed.push('scheduled')
    }
    if (oraclePaused !== row.oraclePaused) changed.push('oraclePaused')
    if (paused !== row.tokenPaused) changed.push('paused')
    if (vaultBlocked !== row.vaultBlocked) changed.push('isBlocked')

    await context.db.update(schema.constituent, {id}).set({
      uiMultiplierX18: multiplier,
      newUiMultiplierX18: newMultiplier,
      effectiveAt,
      oraclePaused,
      tokenPaused: paused,
      vaultBlocked,
      lastPolledBlock: blockNumber,
    })

    // A first observation is a change only in the sense that the row was empty; record it once so
    // the series has a starting point, then stay silent until something actually moves.
    const first = row.lastPolledBlock === 0n
    if (changed.length === 0 && !first) continue

    await context.db
      .insert(schema.multiplierPoint)
      .values({
        id: jobId(blockNumber, 'multiplier', i),
        blockNumber,
        timestamp,
        constituentId: i,
        token: row.token,
        previousMultiplierX18: row.uiMultiplierX18,
        multiplierX18: multiplier,
        newMultiplierX18: newMultiplier,
        effectiveAt,
        oraclePaused,
        tokenPaused: paused,
        deltaBps: changeBps(row.uiMultiplierX18, multiplier),
        source: 'poll',
        // The first observation is labelled as such rather than as a change from the zero the row
        // was created with, which is not a change the issuer made.
        changed: first ? 'first' : changed.join('+'),
      })
      .onConflictDoNothing()

    if (vaultBlocked && !row.vaultBlocked) {
      await recordProbe(context.db as Db, context.contracts, {
        blockNumber,
        timestamp,
        token: row.token,
        account: vault,
        constituentId: i,
        logIndex: 998_000 + i,
      })
    }
  }
})

ponder.on('reconcile:block', async ({event, context}) => {
  const job = context as unknown as JobContext
  await sampleShares(job, event.block.number, event.block.timestamp, 'interval')
  await runReconciliation(job, event.block.number, event.block.timestamp, 'interval')
})
