// SPDX-License-Identifier: MIT

/**
 * `AmpsHook`.
 *
 * The one load-bearing handler is `RotationCreditConsumed`: it is emitted from `beforeSwap`, which
 * v4 calls *before* it swaps and emits `Swap`, so parking the credit here and consuming it in the
 * `PoolManager:Swap` handler is exactly the §1.4 blend, taken from the hook's own arithmetic rather
 * than recomputed. The row is keyed by `(txHash, poolId)` and deleted on consumption; a credit that
 * is never consumed (a `beforeSwap` whose swap reverted) leaves a row that the next swap in the
 * same pool and transaction would wrongly pick up, which is why the consumer also checks the log
 * index ordering.
 *
 * Everything else here is the explanation of a swap's dynamic fee — the surge that was armed, the
 * dividend step that armed a capture fee, the gate cache the fee was quoted against — recorded so
 * that `swap.dynamicFeeBps` has something to be read next to.
 */

import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {decodeBytes32String} from '../lib/bytes32'
import {sessionLabel} from '../lib/constants'
import {creditKey, eventId, poolKey} from '../lib/ids'
import {changeBps, clampInt} from '../lib/math'
import {STATE, raiseAlert, setState} from '../lib/store'
import {recordParameter} from '../lib/parameters'
import {jsonRecord} from '../lib/json'

ponder.on('AmpsHook:RotationCreditConsumed', async ({event, context}) => {
  await context.db
    .insert(schema.pendingCredit)
    .values({
      id: creditKey(event.transaction.hash, event.args.poolId),
      consumed: event.args.consumed,
      blendedFeeBps: event.args.blendedFeeBps,
      logIndex: event.log.logIndex,
      blockNumber: event.block.number,
    })
    .onConflictDoUpdate(() => ({
      consumed: event.args.consumed,
      blendedFeeBps: event.args.blendedFeeBps,
      logIndex: event.log.logIndex,
      blockNumber: event.block.number,
    }))
})

ponder.on('AmpsHook:RebalanceNeeded', async ({event, context}) => {
  await context.db.insert(schema.rebalanceSignal).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    poolId: poolKey(event.args.poolId),
    tick: Number(event.args.tick),
    fairTick: Number(event.args.fairTick),
    deviationTicks: Math.abs(Number(event.args.tick) - Number(event.args.fairTick)),
  })
})

ponder.on('AmpsHook:SurgeArmed', async ({event, context}) => {
  await hookEvent(context, event, 'surgeArmed', {
    surgeBps: event.args.surgeBps,
    reason: decodeBytes32String(event.args.reason),
  })
})

ponder.on('AmpsHook:HighWaterAdvanced', async ({event, context}) => {
  await hookEvent(context, event, 'highWaterAdvanced', {highWaterTick: Number(event.args.highWaterTick)})
})

ponder.on('AmpsHook:HighWaterReset', async ({event, context}) => {
  await hookEvent(context, event, 'highWaterReset', {
    previousHighWaterTick: Number(event.args.previousHighWaterTick),
    newHighWaterTick: Number(event.args.newHighWaterTick),
  })
})

ponder.on('AmpsHook:GateCacheRefreshed', async ({event, context}) => {
  await hookEvent(context, event, 'gateCacheRefreshed', {
    gateFlags: event.args.gateFlags,
    session: event.args.session,
    sessionLabel: sessionLabel(event.args.session),
    dynCapBps: event.args.dynCapBps,
    innerBandTicks: Number(event.args.innerBandTicks),
    outerRailTicks: Number(event.args.outerRailTicks),
    fairTick: Number(event.args.fairTick),
  })
})

/**
 * The corporate-action detector firing in `afterSwap`. A step inside
 * `[0, DIVIDEND_STEP_BPS_MAX]` is a dividend reinvestment and arms a capture fee; anything larger
 * escalates the pool's dynamic cap and is worth an alert, because an unannounced multiplier move
 * that large is a split the issuer did not schedule.
 */
ponder.on('AmpsHook:MultiplierStepDetected', async ({event, context}) => {
  const id = poolKey(event.args.poolId)
  const deltaBps = changeBps(event.args.previousMultiplierX18, event.args.newMultiplierX18)

  await hookEvent(context, event, 'multiplierStep', {
    previousMultiplierX18: event.args.previousMultiplierX18.toString(),
    newMultiplierX18: event.args.newMultiplierX18.toString(),
    captureFeeBps: event.args.captureFeeBps,
    deltaBps,
  })

  const pool = await context.db.find(schema.pool, {id})
  const constituentId = pool?.constituentId ?? 0
  const constituent =
    constituentId > 0 ? await context.db.find(schema.constituent, {id: constituentId.toString()}) : null

  await context.db.insert(schema.multiplierPoint).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    constituentId,
    token: constituent?.token ?? '0x0000000000000000000000000000000000000000',
    previousMultiplierX18: event.args.previousMultiplierX18,
    multiplierX18: event.args.newMultiplierX18,
    newMultiplierX18: 0n,
    effectiveAt: 0n,
    oraclePaused: constituent?.oraclePaused ?? false,
    tokenPaused: constituent?.tokenPaused ?? false,
    deltaBps,
    source: 'hook',
    changed: 'multiplier',
  })

  if (constituent !== null) {
    await context.db
      .update(schema.constituent, {id: constituent.id})
      .set({uiMultiplierX18: event.args.newMultiplierX18, lastPolledBlock: event.block.number})
  }

  if (deltaBps > 200) {
    await raiseAlert(context.db, event.log.logIndex, {
      kind: 'corporate-action',
      severity: 'warning',
      subject: id,
      message: `unannounced uiMultiplier step of ${deltaBps} bps — beyond DIVIDEND_STEP_BPS_MAX`,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      detail: {
        poolId: id,
        constituentId,
        previousMultiplierX18: event.args.previousMultiplierX18,
        newMultiplierX18: event.args.newMultiplierX18,
      },
    })
  }
})

/**
 * `sellFeeBps` is hook-wide (`poolId == 0`); `buyFeeBps` is per pool. Both are the base fee the
 * swap decoder needs, so both are mirrored out of the parameter table into the place the decoder
 * reads: `indexerState` for the former, the `pool` row for the latter.
 */
ponder.on('AmpsHook:HookParameterChanged', async ({event, context}) => {
  const name = decodeBytes32String(event.args.parameter)
  const id = poolKey(event.args.poolId)
  const scoped = id !== '0x0000000000000000000000000000000000000000000000000000000000000000'

  await recordParameter(context, event, 'hook', name, {
    previousValue: event.args.previousValue,
    newValue: event.args.newValue,
    poolId: scoped ? id : undefined,
  })

  if (name === 'sellFeeBps') {
    await setState(context.db, STATE.sellFeeBps, event.args.newValue, event.block.number)
  } else if (name === 'buyFeeBps' && scoped) {
    const pool = await context.db.find(schema.pool, {id})
    if (pool !== null) {
      await context.db.update(schema.pool, {id}).set({buyFeeBps: clampInt(event.args.newValue)})
    }
  }
})

ponder.on('AmpsHook:FeePolicyChanged', async ({event, context}) => {
  await recordParameter(context, event, 'hook.pointer', 'feePolicy', {
    previousAddress: event.args.previousPolicy,
    newAddress: event.args.newPolicy,
  })
})

// -------------------------------------------------------------------------------------------------

type HookEventShape = {
  block: {number: bigint; timestamp: bigint}
  transaction: {hash: `0x${string}`}
  log: {logIndex: number}
  args: {poolId: `0x${string}`}
}

async function hookEvent(
  context: {db: import('../lib/store').Db},
  event: HookEventShape,
  kind: string,
  data: Record<string, unknown>,
): Promise<void> {
  await context.db.insert(schema.hookEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    poolId: poolKey(event.args.poolId),
    kind,
    data: jsonRecord(data),
  })
}
