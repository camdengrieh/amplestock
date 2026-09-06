// SPDX-License-Identifier: MIT

/**
 * `OracleGate` — the six-layer safety gate, indexed so the dApp can say *why* a path is closed.
 *
 * `GateChanged` is emitted by both the gate and the vault (the vault mirrors the state it observed
 * into its own event so a consumer reading only vault logs still sees it). Both are recorded, with
 * a `source` column, and `gateStatus` takes whichever came last — they cannot disagree, because
 * the vault is quoting the gate.
 */

import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {decodeBytes32String} from '../lib/bytes32'
import {GATE_STATES, gateStateLabel} from '../lib/constants'
import {eventId, poolKey} from '../lib/ids'
import {recordParameter} from '../lib/parameters'
import {raiseAlert} from '../lib/store'
import {jsonRecord} from '../lib/json'

const PROTOCOL = 'protocol'

ponder.on('OracleGate:GateChanged', async ({event, context}) => {
  const id = poolKey(event.args.poolId)
  await context.db.insert(schema.gateTransition).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    poolId: id,
    source: 'gate',
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
      diverged: event.args.newState === 2,
      divergenceBps: 0,
      watchdogTripped: event.args.newState === 5,
      watchdogElapsed: 0,
      protocolFreezeUntil: 0n,
      updatedAt: event.block.timestamp,
      updatedBlock: event.block.number,
    })
    .onConflictDoUpdate(() => ({
      state: event.args.newState,
      stateLabel: gateStateLabel(event.args.newState),
      diverged: event.args.newState === 2,
      watchdogTripped: event.args.newState === 5,
      updatedAt: event.block.timestamp,
      updatedBlock: event.block.number,
    }))

  const pool = await context.db.find(schema.pool, {id})
  if (pool !== null) {
    await context.db.update(schema.pool, {id}).set({
      gateState: event.args.newState,
      gateStateLabel: gateStateLabel(event.args.newState),
      gateUpdatedAt: event.block.timestamp,
      diverged: event.args.newState === 2,
    })
  }

  // Anything other than GREEN closes at least one management path; WATCHDOG closes the reference.
  if (event.args.newState !== 0) {
    await raiseAlert(context.db, event.log.logIndex, {
      kind: 'gate',
      severity: event.args.newState === 5 ? 'critical' : 'warning',
      subject: id,
      message: `gate moved to ${gateStateLabel(event.args.newState)}`,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      detail: {
        poolId: id,
        previous: GATE_STATES[event.args.previousState] ?? event.args.previousState,
        next: GATE_STATES[event.args.newState] ?? event.args.newState,
      },
    })
  }
})

ponder.on('OracleGate:DivergenceLatched', async ({event, context}) => {
  const id = poolKey(event.args.poolId)
  await gateEvent(context, event, 'divergenceLatched', {
    poolId: id,
    devBps: event.args.devBps,
    diverged: event.args.diverged,
  })
  const pool = await context.db.find(schema.pool, {id})
  if (pool !== null) {
    await context.db
      .update(schema.pool, {id})
      .set({diverged: event.args.diverged, divergenceBps: event.args.devBps})
  }
  const status = await context.db.find(schema.gateStatus, {id})
  if (status !== null) {
    await context.db
      .update(schema.gateStatus, {id})
      .set({diverged: event.args.diverged, divergenceBps: event.args.devBps})
  }
})

ponder.on('OracleGate:WatchdogTripped', async ({event, context}) => {
  await gateEvent(context, event, 'watchdogTripped', {
    tripped: event.args.tripped,
    elapsed: event.args.elapsed,
  })
  await upsertProtocolStatus(context, event, {
    watchdogTripped: event.args.tripped,
    watchdogElapsed: Number(event.args.elapsed),
  })
  if (event.args.tripped) {
    await raiseAlert(context.db, event.log.logIndex, {
      kind: 'gate',
      severity: 'critical',
      subject: PROTOCOL,
      message: `layer-A watchdog tripped after ${event.args.elapsed}s without an observation`,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      detail: {elapsed: event.args.elapsed},
    })
  }
})

ponder.on('OracleGate:WatchdogStamped', async ({event, context}) => {
  await gateEvent(context, event, 'watchdogStamped', {
    blockNumber: event.args.blockNumber,
    timestamp: event.args.timestamp,
  })
})

ponder.on('OracleGate:CorporateActionFreeze', async ({event, context}) => {
  await gateEvent(context, event, 'corporateActionFreeze', {
    constituentId: event.args.constituentId,
    frozen: event.args.frozen,
    effectiveAt: event.args.effectiveAt,
  })
  if (event.args.frozen) {
    await raiseAlert(context.db, event.log.logIndex, {
      kind: 'corporate-action',
      severity: 'warning',
      subject: event.args.constituentId.toString(),
      message: `constituent ${event.args.constituentId} frozen for a corporate action effective at ${event.args.effectiveAt}`,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      detail: {constituentId: event.args.constituentId, effectiveAt: event.args.effectiveAt},
    })
  }
})

ponder.on('OracleGate:ConstituentFreezeSet', async ({event, context}) => {
  await gateEvent(context, event, 'constituentFreezeSet', {
    constituentId: event.args.constituentId,
    until: event.args.until,
  })
  const id = event.args.constituentId.toString()
  const row = await context.db.find(schema.constituent, {id})
  if (row !== null) {
    await context.db.update(schema.constituent, {id}).set({freezeUntil: BigInt(event.args.until)})
  }
})

ponder.on('OracleGate:ProtocolFreezeSet', async ({event, context}) => {
  await gateEvent(context, event, 'protocolFreezeSet', {until: event.args.until})
  await upsertProtocolStatus(context, event, {protocolFreezeUntil: BigInt(event.args.until)})
  await raiseAlert(context.db, event.log.logIndex, {
    kind: 'gate',
    severity: event.args.until > 0 ? 'critical' : 'info',
    subject: PROTOCOL,
    message: event.args.until > 0 ? `protocol frozen until ${event.args.until}` : 'protocol freeze lifted',
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    detail: {until: event.args.until},
  })
})

ponder.on('OracleGate:GateParameterChanged', async ({event, context}) => {
  await recordParameter(context, event, 'gate', decodeBytes32String(event.args.parameter), {
    previousValue: event.args.previousValue,
    newValue: event.args.newValue,
  })
})

ponder.on('OracleGate:HolidayBitmapSet', async ({event, context}) => {
  await gateEvent(context, event, 'holidayBitmapSet', {
    year: event.args.year,
    bitmap: event.args.bitmap.map((v) => v.toString()),
  })
})

ponder.on('OracleGate:DstTableSet', async ({event, context}) => {
  await gateEvent(context, event, 'dstTableSet', {windows: event.args.windows.toString()})
})

// -------------------------------------------------------------------------------------------------

type GateEventShape = {
  block: {number: bigint; timestamp: bigint}
  transaction: {hash: `0x${string}`}
  log: {logIndex: number}
}

async function gateEvent(
  context: {db: import('../lib/store').Db},
  event: GateEventShape,
  kind: string,
  data: Record<string, unknown>,
): Promise<void> {
  await context.db.insert(schema.gateEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    kind,
    poolId: (data.poolId as `0x${string}` | undefined) ?? null,
    constituentId: (data.constituentId as number | undefined) ?? null,
    data: jsonRecord(data),
  })
}

async function upsertProtocolStatus(
  context: {db: import('../lib/store').Db},
  event: GateEventShape,
  patch: Record<string, unknown>,
): Promise<void> {
  await context.db
    .insert(schema.gateStatus)
    .values({
      id: PROTOCOL,
      poolId: null,
      state: 0,
      stateLabel: GATE_STATES[0],
      diverged: false,
      divergenceBps: 0,
      watchdogTripped: false,
      watchdogElapsed: 0,
      protocolFreezeUntil: 0n,
      updatedAt: event.block.timestamp,
      updatedBlock: event.block.number,
      ...patch,
    })
    .onConflictDoUpdate(() => ({
      ...patch,
      updatedAt: event.block.timestamp,
      updatedBlock: event.block.number,
    }))
}
