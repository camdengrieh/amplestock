// SPDX-License-Identifier: MIT

/**
 * `AmpsRouter` — the protocol's own front end, and the only contract in the world whose swaps the
 * hook will price at the pass-through fee.
 *
 * **Why the router needs a handler of its own when every one of its trades is also a v4 `Swap`.**
 * Revision 6 charges `AmpsHook.ampsFeeBps()` on both directions of every pool, and the cheaper
 * pass-through base (`pool.buyFeeBps`) applies to exactly one shape: the two hops of an
 * `AmpsRouter.rotate`, which the hook recognises by
 * `sender == AmpsHook.router()` **and** the rotate flag in the hop's `hookData`. Neither half of
 * that condition survives into the `Swap` log — the flag is calldata, and `buy` and `sell` have the
 * same `sender` while paying the full AMPS fee — so a rotation is only ever identifiable from
 * `Rotated`, and it arrives *after* both `Swap`s of the same transaction.
 *
 * That ordering is what `pending_hop` is for. `handlers/poolManager.ts` stashes every swap the
 * router unlocked under `"<txHash>-<poolId>"`; the handlers below read the two rows `Rotated` names,
 * record what the hops actually paid, and correct hop 1's fee decomposition in place — its
 * `baseFeeBps` was decoded at the default `ampsFeeBps`, because at the time it was written nothing
 * yet said it was a rotation. Hop 2 needs no correction: it emitted `RotationCreditConsumed`, whose
 * `blendedFeeBps` the swap handler already took as the base.
 *
 * `Bought` and `Sold` are indexed for what they are — a trade through the protocol's own front end,
 * priced exactly as the same swap through any other router — and are marked `passThrough: false` so
 * the distinction is a column rather than a convention.
 */

import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {creditKey, eventId, poolKey} from '../lib/ids'
import type {Db} from '../lib/store'

interface HopFacts {
  swapId: string
  feeAmount: bigint
  feeBps: number
  baseFeeBps: number
  feeUsd18: bigint
  sell: boolean
}

/** Read and consume the stashed swap for one hop, or `null` when the router did not produce one. */
async function takeHop(db: Db, txHash: `0x${string}`, poolId: `0x${string}`): Promise<HopFacts | null> {
  const key = creditKey(txHash, poolId)
  const row = await db.find(schema.pendingHop, {id: key})
  if (row === null) return null
  await db.delete(schema.pendingHop, {id: key})
  return {
    swapId: row.swapId,
    feeAmount: row.feeAmount,
    feeBps: row.feeBps,
    baseFeeBps: row.baseFeeBps,
    feeUsd18: row.feeUsd18,
    sell: row.sell,
  }
}

interface TradeInput {
  db: Db
  id: string
  blockNumber: bigint
  timestamp: bigint
  txHash: `0x${string}`
  logIndex: number
  kind: 'buy' | 'sell' | 'rotate'
  poolId: `0x${string}`
  hop2PoolId: `0x${string}` | null
  payer: `0x${string}`
  to: `0x${string}`
  amountIn: bigint
  amountOut: bigint
  ampsAmount: bigint
  passThrough: boolean
  feeCounter: bigint
  feeAmps: bigint
  feeUsd18: bigint
  hop1BaseFeeBps: number
  hop2BaseFeeBps: number
}

async function recordTrade(input: TradeInput): Promise<void> {
  const {db, ...row} = input
  await db.insert(schema.routerTrade).values(row)
}

ponder.on('AmpsRouter:Bought', async ({event, context}) => {
  const poolId = poolKey(event.args.poolId)
  const hop = await takeHop(context.db, event.transaction.hash, event.args.poolId)
  await recordTrade({
    db: context.db,
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    kind: 'buy',
    poolId,
    hop2PoolId: null,
    payer: event.args.payer,
    to: event.args.to,
    amountIn: event.args.amountIn,
    amountOut: event.args.ampsOut,
    ampsAmount: event.args.ampsOut,
    // Buying AMPS is entering the index, not moving through it. It pays `ampsFeeBps`.
    passThrough: false,
    feeCounter: hop?.feeAmount ?? 0n,
    feeAmps: 0n,
    feeUsd18: hop?.feeUsd18 ?? 0n,
    hop1BaseFeeBps: 0,
    hop2BaseFeeBps: 0,
  })
})

ponder.on('AmpsRouter:Sold', async ({event, context}) => {
  const poolId = poolKey(event.args.poolId)
  const hop = await takeHop(context.db, event.transaction.hash, event.args.poolId)
  await recordTrade({
    db: context.db,
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    kind: 'sell',
    poolId,
    hop2PoolId: null,
    payer: event.args.payer,
    to: event.args.to,
    amountIn: event.args.ampsIn,
    amountOut: event.args.amountOut,
    ampsAmount: event.args.ampsIn,
    // Selling AMPS is leaving the index. Routing the exit through the protocol's own front end
    // must not make the exit cheaper, so this pays `ampsFeeBps` too, and spends no credit.
    passThrough: false,
    feeCounter: 0n,
    feeAmps: hop?.feeAmount ?? 0n,
    feeUsd18: hop?.feeUsd18 ?? 0n,
    hop1BaseFeeBps: 0,
    hop2BaseFeeBps: 0,
  })
})

ponder.on('AmpsRouter:Rotated', async ({event, context}) => {
  const hop1Id = poolKey(event.args.hop1)
  const hop2Id = poolKey(event.args.hop2)
  const hop1 = await takeHop(context.db, event.transaction.hash, event.args.hop1)
  const hop2 = await takeHop(context.db, event.transaction.hash, event.args.hop2)

  // Hop 1 was decoded at the default base, because nothing before this log said it was a rotation.
  // The pass-through base is the pool's own `buyFeeBps`; the residual over it is the dynamic part,
  // which is unchanged — only the split between the two moves.
  if (hop1 !== null) {
    const pool = await context.db.find(schema.pool, {id: hop1Id})
    const base = pool?.buyFeeBps ?? hop1.baseFeeBps
    hop1.baseFeeBps = base
    await context.db.update(schema.swap, {id: hop1.swapId}).set({
      baseFeeBps: base,
      dynamicFeeBps: Math.max(0, hop1.feeBps - base),
    })
  }

  await recordTrade({
    db: context.db,
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    kind: 'rotate',
    poolId: hop1Id,
    hop2PoolId: hop2Id,
    // `Rotated` names the recipient, not the payer: a rotation's input is pulled from the caller.
    payer: event.transaction.from,
    to: event.args.to,
    amountIn: event.args.amountIn,
    amountOut: event.args.amountOut,
    ampsAmount: event.args.ampsThrough,
    passThrough: true,
    // Hop 1 pays in hop 1's counter asset, hop 2 in AMPS. Both are what the pools actually charged,
    // read back off the swap rows rather than implied from a rate.
    feeCounter: (hop1?.feeAmount ?? 0n) + (hop2?.sell === false ? hop2.feeAmount : 0n),
    feeAmps: hop2?.sell === true ? hop2.feeAmount : 0n,
    feeUsd18: (hop1?.feeUsd18 ?? 0n) + (hop2?.feeUsd18 ?? 0n),
    hop1BaseFeeBps: hop1?.baseFeeBps ?? 0,
    hop2BaseFeeBps: hop2?.baseFeeBps ?? 0,
  })
})
