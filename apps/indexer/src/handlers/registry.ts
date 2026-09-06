// SPDX-License-Identifier: MIT

/**
 * `PoolRegistry` — the allowlist. **This is what makes the v4 sources safe to index**: the
 * `PoolManager` carries every pool on the chain, and a pool is ours if and only if the registry
 * announced it here. `PoolRegistered` creates the `pool` row and `poolManager.ts` drops any
 * `Swap`, `ModifyLiquidity` or `Initialize` whose id has no row.
 *
 * `PoolRegistered` carries the counter, the class and the constituent id but not the tick spacing,
 * the counter decimals or the buy fee, and `PoolOpened` carries the price the pool actually opened
 * at (§12.1 ruling J) but not the grid origin. Those five are read from the registry and the hook
 * at the registration block — one `multicall`, once per pool, and never again. See
 * `docs/indexer.md` for the (small) contract-side change that would remove the read.
 */

import {ampsHookAbi, poolRegistryAbi} from '@amplestocks/abis'
import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {stockTokenAbi} from '../abi/external'
import {
  CONSTITUENT_STATUS,
  constituentStatusLabel,
  doublingTicks,
  poolClassLabel,
} from '../lib/constants'
import {eventId, poolKey} from '../lib/ids'
import {clampInt} from '../lib/math'
import {recordParameter} from '../lib/parameters'
import {jsonSafe} from '../lib/json'

const tickFromSqrtPrice = (sqrtPriceX96: bigint): number => {
  if (sqrtPriceX96 <= 0n) return 0
  // log_1.0001(price) with price = (sqrt/2^96)^2. Float is ample: the value is only used to seed
  // `gridBaseTick`, and every consumer re-derives cell membership from the exact tick bounds the
  // `ModifyLiquidity` logs carry.
  const ratio = Number(sqrtPriceX96) / 2 ** 96
  return Math.round(Math.log(ratio * ratio) / Math.log(1.0001))
}

ponder.on('PoolRegistry:PoolRegistered', async ({event, context}) => {
  const id = poolKey(event.args.poolId)

  const [config, buyFee] = await Promise.all([
    context.client
      .readContract({
        abi: poolRegistryAbi,
        address: context.contracts.PoolRegistry.address as `0x${string}`,
        functionName: 'poolConfig',
        args: [event.args.poolId],
      })
      .catch(() => undefined),
    context.client
      .readContract({
        abi: ampsHookAbi,
        address: context.contracts.AmpsHook.address as `0x${string}`,
        functionName: 'buyFeeBps',
        args: [event.args.poolId],
      })
      .catch(() => undefined),
  ])

  const tickSpacing = config ? Number(config.tickSpacing) : 60
  const counterDecimals = config ? Number(config.counterDecimals) : 18
  const gridBaseTick = config ? Number(config.gridBaseTick) : null

  await context.db
    .insert(schema.pool)
    .values({
      id,
      counter: event.args.counter,
      counterSymbol: null,
      counterDecimals,
      poolClass: event.args.poolClass,
      poolClassLabel: poolClassLabel(event.args.poolClass),
      constituentId: event.args.constituentId,
      tickSpacing,
      doublingTicks: doublingTicks(tickSpacing),
      gridBaseTick,
      buyFeeBps: buyFee !== undefined ? Number(buyFee) : config ? Number(config.buyFeeBps) : 0,
      feed: null,
      registeredAt: event.block.timestamp,
      registeredBlock: event.block.number,
      openedAt: null,
      openSqrtPriceX96: null,
      openTick: null,
      sqrtPriceX96: 0n,
      tick: 0,
      liquidity: 0n,
      lastSwapAt: 0n,
      gateState: 0,
      gateStateLabel: 'GREEN',
      gateUpdatedAt: event.block.timestamp,
      diverged: false,
      divergenceBps: 0,
      sellVolumeAmps: 0n,
      buyVolumeAmps: 0n,
      sellFeeAmps: 0n,
      buyFeeCounter: 0n,
      rotationCreditedAmps: 0n,
      swapCount: 0,
      askCells: 0,
      bidCells: 0,
      ampsInLadder: 0n,
      counterInLadder: 0n,
      ladderFillBps: 0,
      cellTicks: [],
      realisedLvrUsd18: 0n,
      feeRevenueUsd18: 0n,
    })
    .onConflictDoUpdate(() => ({
      counter: event.args.counter,
      counterDecimals,
      poolClass: event.args.poolClass,
      poolClassLabel: poolClassLabel(event.args.poolClass),
      constituentId: event.args.constituentId,
      tickSpacing,
      doublingTicks: doublingTicks(tickSpacing),
      gridBaseTick,
    }))
})

ponder.on('PoolRegistry:PoolOpened', async ({event, context}) => {
  const id = poolKey(event.args.poolId)
  const tick = tickFromSqrtPrice(event.args.sqrtPriceX96)
  const existing = await context.db.find(schema.pool, {id})
  if (existing === null) return
  await context.db.update(schema.pool, {id}).set({
    feed: event.args.feed,
    openedAt: event.block.timestamp,
    openSqrtPriceX96: event.args.sqrtPriceX96,
    openTick: tick,
    sqrtPriceX96: existing.sqrtPriceX96 === 0n ? event.args.sqrtPriceX96 : existing.sqrtPriceX96,
    tick: existing.sqrtPriceX96 === 0n ? tick : existing.tick,
    // Ruling C: the pool opens exactly on the grid origin, so the opening tick *is* `gridBaseTick`
    // whenever the registry did not already hand one over.
    gridBaseTick: existing.gridBaseTick ?? tick,
  })
})

ponder.on('PoolRegistry:ConstituentAdded', async ({event, context}) => {
  const symbol = await context.client
    .readContract({abi: stockTokenAbi, address: event.args.token, functionName: 'symbol'})
    .catch(() => null)
  const decimals = await context.client
    .readContract({abi: stockTokenAbi, address: event.args.token, functionName: 'decimals'})
    .catch(() => 18)

  await context.db
    .insert(schema.constituent)
    .values({
      id: event.args.constituentId.toString(),
      constituentId: event.args.constituentId,
      token: event.args.token,
      symbol,
      decimals: Number(decimals),
      poolId: poolKey(event.args.poolId),
      status: 1,
      statusLabel: CONSTITUENT_STATUS[1],
      targetWeightBps: event.args.targetWeightBps,
      rolloutWeightBps: 0,
      marketId: 0,
      feed: null,
      addedAt: event.block.timestamp,
      addedBlock: event.block.number,
      retiredAt: null,
      reinstatedAt: null,
      freezeUntil: 0n,
      uiMultiplierX18: 0n,
      newUiMultiplierX18: 0n,
      effectiveAt: 0n,
      oraclePaused: false,
      tokenPaused: false,
      vaultBlocked: false,
      lastPolledBlock: 0n,
      answerUsd8: 0n,
      answerUpdatedAt: 0n,
    })
    .onConflictDoUpdate(() => ({
      token: event.args.token,
      poolId: poolKey(event.args.poolId),
      status: 1,
      statusLabel: CONSTITUENT_STATUS[1],
      targetWeightBps: event.args.targetWeightBps,
      reinstatedAt: event.block.timestamp,
    }))

  await context.db
    .insert(schema.tokenIndex)
    .values({
      id: event.args.token.toLowerCase() as `0x${string}`,
      constituentId: event.args.constituentId,
      poolId: poolKey(event.args.poolId),
    })
    .onConflictDoUpdate(() => ({
      constituentId: event.args.constituentId,
      poolId: poolKey(event.args.poolId),
    }))

  await context.db.insert(schema.constituentEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    constituentId: event.args.constituentId,
    kind: 'added',
    field: 'targetWeightBps',
    previousValue: null,
    newValue: BigInt(event.args.targetWeightBps),
  })
})

ponder.on('PoolRegistry:ConstituentRetired', async ({event, context}) => {
  await setStatus(context, event, event.args.constituentId, 2, 'retired', {
    retiredAt: event.block.timestamp,
    rolloutWeightBps: 0,
  })
})

ponder.on('PoolRegistry:ConstituentReinstated', async ({event, context}) => {
  await setStatus(context, event, event.args.constituentId, 1, 'reinstated', {
    reinstatedAt: event.block.timestamp,
    rolloutWeightBps: event.args.rolloutWeightBps,
  })
})

ponder.on('PoolRegistry:ConstituentFrozen', async ({event, context}) => {
  await setStatus(context, event, event.args.constituentId, 3, 'frozen', {
    freezeUntil: BigInt(event.args.until),
  })
})

ponder.on('PoolRegistry:ConstituentReconfigured', async ({event, context}) => {
  const field = Buffer.from(event.args.field.slice(2), 'hex')
    .toString('utf8')
    .replace(/\0+$/, '')

  await context.db.insert(schema.constituentEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    constituentId: event.args.constituentId,
    kind: 'reconfigured',
    field,
    previousValue: event.args.previousValue,
    newValue: event.args.newValue,
  })

  await recordParameter(context, event, 'constituent', field, {
    previousValue: event.args.previousValue,
    newValue: event.args.newValue,
    marketId: event.args.constituentId,
  })

  const row = await context.db.find(schema.constituent, {id: event.args.constituentId.toString()})
  if (row === null) return
  if (field === 'targetWeightBps') {
    await context.db
      .update(schema.constituent, {id: row.id})
      .set({targetWeightBps: clampInt(event.args.newValue)})
  } else if (field === 'rolloutWeightBps') {
    await context.db
      .update(schema.constituent, {id: row.id})
      .set({rolloutWeightBps: clampInt(event.args.newValue)})
  } else if (field === 'buyFeeBps') {
    const poolRow = await context.db.find(schema.pool, {id: row.poolId})
    if (poolRow !== null) {
      await context.db
        .update(schema.pool, {id: row.poolId})
        .set({buyFeeBps: clampInt(event.args.newValue)})
    }
  }
})

ponder.on('PoolRegistry:IndexWeightsSet', async ({event, context}) => {
  await context.db.insert(schema.indexWeights).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    ids: jsonSafe([...event.args.ids]),
    weightsBps: jsonSafe([...event.args.weightsBps]),
  })
  for (let i = 0; i < event.args.ids.length; i++) {
    const id = event.args.ids[i]!.toString()
    const row = await context.db.find(schema.constituent, {id})
    if (row === null) continue
    await context.db
      .update(schema.constituent, {id})
      .set({targetWeightBps: event.args.weightsBps[i]!})
  }
})

ponder.on('PoolRegistry:RetiredBidsWithdrawn', async ({event, context}) => {
  await context.db.insert(schema.constituentEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    constituentId: event.args.constituentId,
    kind: 'retiredBidsWithdrawn',
    field: null,
    previousValue: null,
    newValue: event.args.moved,
  })
})

// -------------------------------------------------------------------------------------------------

type SetStatusEvent = {
  block: {number: bigint; timestamp: bigint}
  transaction: {hash: `0x${string}`}
  log: {logIndex: number}
}

async function setStatus(
  context: {db: import('../lib/store').Db},
  event: SetStatusEvent,
  constituentId: number,
  status: number,
  kind: string,
  extra: Record<string, unknown>,
): Promise<void> {
  const id = constituentId.toString()
  const row = await context.db.find(schema.constituent, {id})
  if (row !== null) {
    await context.db
      .update(schema.constituent, {id})
      .set({status, statusLabel: constituentStatusLabel(status), ...extra})
  }
  await context.db.insert(schema.constituentEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    constituentId,
    kind,
    field: 'status',
    previousValue: row === null ? null : BigInt(row.status),
    newValue: BigInt(status),
  })
}
