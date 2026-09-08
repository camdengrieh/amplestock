// SPDX-License-Identifier: MIT

/**
 * Uniswap v4 `PoolManager`, filtered to our own pools.
 *
 * The `PoolManager` is one shared deployment carrying every pool on the chain, so **every handler
 * here begins by looking the `PoolId` up in `pool`** and returns when it is not there. That table
 * is written only by `PoolRegistry.PoolRegistered`, so the registry's allowlist is the filter, and
 * it holds whether or not the topic filter in `ponder.config.ts` could be narrowed at start-up.
 *
 * Three things happen on a `Swap`:
 *
 * 1. **The fee is decomposed** per `src/lib/fee.ts` — direction from the sign of `amount0`, base
 *    from `ampsFeeBps`/`buyFeeBps` or from the `RotationCreditConsumed` the hook emitted earlier in
 *    the same transaction, dynamic as the residual against what v4 actually charged.
 * 2. **The pool's ladder is re-decomposed** at the new price. A v4 position converts in place as
 *    the price crosses it (§3.4), so each cell's split into AMPS-still-there and counter-raised
 *    *is* its fill and its proceeds; there is no separate fill event to index, and none is needed.
 * 3. **Realised LVR** is marked against the post-swap price (`src/lib/flywheel.ts`) so the
 *    dashboard's "fee APR vs realised LVR" is a comparison of two measured numbers.
 */

import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {classifyAction} from '../lib/actions'
import {ZERO_ADDRESS} from '../config/addresses'
import {GRID_MIN_M, POSITION_SALT, cellIndexOf, doublingIndexOf} from '../lib/constants'
import {ampsToUsd18, realisedLvrAmps} from '../lib/flywheel'
import {decodeSwapFee} from '../lib/fee'
import {cellKey, creditKey, dayKey, dayStart, eventId, poolKey} from '../lib/ids'
import {amountsForLiquidity, clampInt, priceX18FromSqrt, to18} from '../lib/math'
import {STATE, getState, updateFlywheelDay, updateSummary, type Db} from '../lib/store'
import {jsonRecord} from '../lib/json'

/** `ampsFeeBps` at launch (`Constants.AMPS_FEE_BPS_DEFAULT`), used until the hook tells us otherwise. */
const AMPS_FEE_BPS_DEFAULT = 500

/**
 * Scratch the `Placement` handler consumes. Only the liquidity is carried now: the cell count and
 * the tick range are in `Placement` itself, and a `Rollout` is its own event, so nothing else has to
 * be reconstructed from these logs.
 */
const PLACEMENT_LIQ = (tx: string, pool: string) => `placement.liquidity.${tx}.${pool}`

// -------------------------------------------------------------------------------------------------
// Initialize
// -------------------------------------------------------------------------------------------------

ponder.on('PoolManager:Initialize', async ({event, context}) => {
  // The registry has not registered the pool yet at this point in the transaction — the vault
  // initialises it and the registry emits `PoolRegistered`/`PoolOpened` afterwards — so the only
  // filter available here is the hook address, which is exactly the "our pool" predicate v4 itself
  // enforces on `beforeInitialize`.
  if (event.args.hooks.toLowerCase() !== context.contracts.AmpsHook.address?.toLowerCase()) return

  await context.db.insert(schema.hookEvent).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    poolId: poolKey(event.args.id),
    kind: 'initialize',
    data: jsonRecord({
      currency0: event.args.currency0,
      currency1: event.args.currency1,
      fee: event.args.fee,
      tickSpacing: event.args.tickSpacing,
      sqrtPriceX96: event.args.sqrtPriceX96.toString(),
      tick: event.args.tick,
    }),
  })
})

// -------------------------------------------------------------------------------------------------
// ModifyLiquidity — the ladder
// -------------------------------------------------------------------------------------------------

ponder.on('PoolManager:ModifyLiquidity', async ({event, context}) => {
  const id = poolKey(event.args.id)
  const pool = await context.db.find(schema.pool, {id})
  if (pool === null) return

  const action = classifyAction(event.transaction.input)
  const tickLower = Number(event.args.tickLower)
  const tickUpper = Number(event.args.tickUpper)
  const delta = event.args.liquidityDelta

  await context.db.insert(schema.liquidityChange).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    poolId: id,
    sender: event.args.sender,
    tickLower,
    tickUpper,
    liquidityDelta: delta,
    salt: event.args.salt,
    action,
  })

  // `modifyLiquidity(…, 0, …)` is how `compound` realises accrued fees (§3.6 step 3). It is not a
  // ladder move and must not disturb the cell's committed `amount` or its placement denominator.
  if (delta === 0n) return
  if (event.args.salt !== POSITION_SALT) return

  const key = cellKey(event.args.id, tickLower)
  const existing = await context.db.find(schema.ladderCell, {id: key})
  const sqrtPrice = pool.sqrtPriceX96 === 0n ? (pool.openSqrtPriceX96 ?? 0n) : pool.sqrtPriceX96
  const added = delta > 0n ? delta : 0n
  const addedAmounts = amountsForLiquidity(sqrtPrice, tickLower, tickUpper, added)
  const liquidity = (existing?.liquidity ?? 0n) + delta
  const gridBase = pool.gridBaseTick
  const m = gridBase === null ? 0 : doublingIndexOf(tickLower, gridBase, pool.tickSpacing)
  const bucketIndex = gridBase === null ? -1 : cellIndexOf(tickLower, gridBase, pool.tickSpacing)

  const nowAmounts = amountsForLiquidity(sqrtPrice, tickLower, tickUpper, liquidity)
  const ampsAtPlacement = (existing?.ampsAtPlacement ?? 0n) + addedAmounts.amount0
  const amount =
    (existing?.amount ?? 0n) + (addedAmounts.amount0 > 0n ? addedAmounts.amount0 : addedAmounts.amount1)

  await context.db
    .insert(schema.ladderCell)
    .values({
      id: key,
      poolId: id,
      bucketIndex,
      m: gridBase === null ? GRID_MIN_M - 1 : m,
      tickLower,
      tickUpper,
      liquidity,
      above: addedAmounts.amount0 > 0n,
      amount,
      ampsRemaining: nowAmounts.amount0,
      proceeds: nowAmounts.amount1,
      filledBps: filledBpsOf(ampsAtPlacement, nowAmounts.amount0),
      ampsAtPlacement,
      placedAt: event.block.timestamp,
      updatedAt: event.block.timestamp,
      removedAt: liquidity === 0n ? event.block.timestamp : null,
      lastAction: action,
    })
    .onConflictDoUpdate(() => ({
      liquidity,
      amount,
      ampsRemaining: nowAmounts.amount0,
      proceeds: nowAmounts.amount1,
      ampsAtPlacement,
      filledBps: filledBpsOf(ampsAtPlacement, nowAmounts.amount0),
      updatedAt: event.block.timestamp,
      removedAt: liquidity === 0n ? event.block.timestamp : null,
      lastAction: action,
    }))

  const cellTicks = new Set<number>((pool.cellTicks as number[] | null) ?? [])
  cellTicks.add(tickLower)
  await context.db.update(schema.pool, {id}).set({cellTicks: [...cellTicks].sort((a, b) => a - b)})

  if (delta > 0n) {
    const liqKey = PLACEMENT_LIQ(event.transaction.hash, id)
    const liq = ((await getState(context.db, liqKey)) ?? 0n) + delta
    await context.db
      .insert(schema.indexerState)
      .values({id: liqKey, value: liq, text: null, updatedBlock: event.block.number})
      .onConflictDoUpdate(() => ({value: liq, updatedBlock: event.block.number}))
  }

  await refreshLadder(context.db, id)
})

// -------------------------------------------------------------------------------------------------
// Swap
// -------------------------------------------------------------------------------------------------

ponder.on('PoolManager:Swap', async ({event, context}) => {
  const id = poolKey(event.args.id)
  const pool = await context.db.find(schema.pool, {id})
  if (pool === null) return

  const ampsFeeBps = clampInt((await getState(context.db, STATE.ampsFeeBps)) ?? BigInt(AMPS_FEE_BPS_DEFAULT))
  const pRefX18 = (await getState(context.db, STATE.pRefX18)) ?? 0n

  const ck = creditKey(event.transaction.hash, event.args.id)
  const pending = await context.db.find(schema.pendingCredit, {id: ck})
  const credit =
    pending !== null && pending.logIndex < event.log.logIndex
      ? {consumed: pending.consumed, blendedFeeBps: pending.blendedFeeBps}
      : undefined
  if (pending !== null) await context.db.delete(schema.pendingCredit, {id: ck})

  const fee = decodeSwapFee({
    amount0: event.args.amount0,
    amount1: event.args.amount1,
    feePips: Number(event.args.fee),
    ampsFeeBps,
    buyFeeBps: pool.buyFeeBps,
    credit,
  })

  const priceX18 = priceX18FromSqrt(event.args.sqrtPriceX96, 18, pool.counterDecimals)
  const notionalUsd18 = ampsToUsd18(fee.ampsAmount, pRefX18)
  const feeUsd18 = fee.sell
    ? ampsToUsd18(fee.feeAmps, pRefX18)
    : (notionalUsd18 * BigInt(fee.feeBps)) / 10_000n
  const lvrAmps = realisedLvrAmps({
    sell: fee.sell,
    amountIn: fee.amountIn,
    amountOut: fee.amountOut,
    feeAmount: fee.feeAmount,
    counterDecimals: pool.counterDecimals,
    priceX18,
  })
  const lvrUsd18 = ampsToUsd18(lvrAmps, pRefX18)

  const swapId = eventId(event.block.number, event.log.logIndex)
  await context.db.insert(schema.swap).values({
    id: swapId,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    poolId: id,
    sender: event.args.sender,
    origin: event.transaction.from,
    sell: fee.sell,
    amount0: event.args.amount0,
    amount1: event.args.amount1,
    amountIn: fee.amountIn,
    amountOut: fee.amountOut,
    ampsAmount: fee.ampsAmount,
    counterAmount: fee.counterAmount,
    sqrtPriceX96: event.args.sqrtPriceX96,
    tick: Number(event.args.tick),
    liquidity: event.args.liquidity,
    feePips: fee.feePips,
    feeBps: fee.feeBps,
    baseFeeBps: fee.baseFeeBps,
    dynamicFeeBps: fee.dynamicFeeBps,
    creditedAmount: fee.creditedAmount,
    credited: fee.credited,
    feeAmount: fee.feeAmount,
    feeAmps: fee.feeAmps,
    notionalUsd18,
    feeUsd18,
  })

  // A swap the protocol's own router unlocked is the only one that *can* be a rotation hop, and
  // the hook prices a hop at the pass-through fee on a fact that is nowhere in this log: the rotate
  // flag lives in `hookData`, and `AmpsRouter.buy` / `.sell` share the router's `sender` while
  // paying `ampsFeeBps` like everybody else. So the fee is decoded here at the default base and the
  // row is left for `handlers/router.ts`, which sees `Rotated` later in the same transaction and
  // knows which two hops it named. Only router swaps are stashed, so the table stays tiny.
  const router = context.contracts.AmpsRouter.address as `0x${string}`
  if (router !== ZERO_ADDRESS && event.args.sender.toLowerCase() === router.toLowerCase()) {
    const hk = creditKey(event.transaction.hash, event.args.id)
    await context.db
      .insert(schema.pendingHop)
      .values({
        id: hk,
        swapId,
        sell: fee.sell,
        amountIn: fee.amountIn,
        feeAmount: fee.feeAmount,
        feeBps: fee.feeBps,
        baseFeeBps: fee.baseFeeBps,
        feeUsd18,
        ampsAmount: fee.ampsAmount,
        logIndex: event.log.logIndex,
        blockNumber: event.block.number,
      })
      .onConflictDoUpdate(() => ({
        swapId,
        sell: fee.sell,
        amountIn: fee.amountIn,
        feeAmount: fee.feeAmount,
        feeBps: fee.feeBps,
        baseFeeBps: fee.baseFeeBps,
        feeUsd18,
        ampsAmount: fee.ampsAmount,
        logIndex: event.log.logIndex,
        blockNumber: event.block.number,
      }))
  }

  await context.db.update(schema.pool, {id}).set((row) => ({
    sqrtPriceX96: event.args.sqrtPriceX96,
    tick: Number(event.args.tick),
    liquidity: event.args.liquidity,
    lastSwapAt: event.block.timestamp,
    swapCount: row.swapCount + 1,
    sellVolumeAmps: row.sellVolumeAmps + (fee.sell ? fee.ampsAmount : 0n),
    buyVolumeAmps: row.buyVolumeAmps + (fee.sell ? 0n : fee.ampsAmount),
    sellFeeAmps: row.sellFeeAmps + fee.feeAmps,
    buyFeeCounter: row.buyFeeCounter + (fee.sell ? 0n : fee.feeAmount),
    rotationCreditedAmps: row.rotationCreditedAmps + fee.creditedAmount,
    realisedLvrUsd18: row.realisedLvrUsd18 + lvrUsd18,
    feeRevenueUsd18: row.feeRevenueUsd18 + feeUsd18,
  }))

  const dk = dayKey(id, event.block.timestamp)
  await context.db
    .insert(schema.poolDay)
    .values({
      id: dk,
      poolId: id,
      day: dayStart(event.block.timestamp),
      sellVolumeAmps: fee.sell ? fee.ampsAmount : 0n,
      buyVolumeAmps: fee.sell ? 0n : fee.ampsAmount,
      volumeUsd18: notionalUsd18,
      feeAmps: fee.feeAmps,
      feeUsd18,
      creditedAmps: fee.creditedAmount,
      swapCount: 1,
      realisedLvrUsd18: lvrUsd18,
      inventoryUsd18: ampsToUsd18(pool.ampsInLadder, pRefX18),
      openTick: Number(event.args.tick),
      closeTick: Number(event.args.tick),
    })
    .onConflictDoUpdate((row) => ({
      sellVolumeAmps: row.sellVolumeAmps + (fee.sell ? fee.ampsAmount : 0n),
      buyVolumeAmps: row.buyVolumeAmps + (fee.sell ? 0n : fee.ampsAmount),
      volumeUsd18: row.volumeUsd18 + notionalUsd18,
      feeAmps: row.feeAmps + fee.feeAmps,
      feeUsd18: row.feeUsd18 + feeUsd18,
      creditedAmps: row.creditedAmps + fee.creditedAmount,
      swapCount: row.swapCount + 1,
      realisedLvrUsd18: row.realisedLvrUsd18 + lvrUsd18,
      inventoryUsd18: ampsToUsd18(pool.ampsInLadder, pRefX18),
      closeTick: Number(event.args.tick),
    }))

  // The fee is always taken in the swap's input currency, so a sell pays in AMPS (the side that is
  // burned at `compound`) and a buy pays in the counter asset (the side that is re-placed as bids).
  // The split here is therefore by *currency*, which since revision 6 is the distinction that
  // matters — both directions pay the same `ampsFeeBps` rate.
  await updateFlywheelDay(context.db, event.block.timestamp, (row) => ({
    sellVolumeAmps: row.sellVolumeAmps + (fee.sell ? fee.ampsAmount : 0n),
    buyVolumeAmps: row.buyVolumeAmps + (fee.sell ? 0n : fee.ampsAmount),
    feeAmps: row.feeAmps + fee.feeAmps,
    feeAmpsUsd18: row.feeAmpsUsd18 + (fee.sell ? feeUsd18 : 0n),
    feeCounterUsd18: row.feeCounterUsd18 + (fee.sell ? 0n : feeUsd18),
    realisedLvrUsd18: row.realisedLvrUsd18 + lvrUsd18,
    swapCount: row.swapCount + 1,
  }))

  await updateSummary(context.db, event.block.number, event.block.timestamp, (row) => ({
    swapCount: row.swapCount + 1,
  }))

  await refreshLadder(context.db, id)
})

// -------------------------------------------------------------------------------------------------
// Ladder decomposition
// -------------------------------------------------------------------------------------------------

const filledBpsOf = (atPlacement: bigint, remaining: bigint): number => {
  if (atPlacement <= 0n) return 0
  if (remaining >= atPlacement) return 0
  return clampInt(((atPlacement - remaining) * 10_000n) / atPlacement)
}

/**
 * Re-price every live cell of one pool at its current `sqrtPriceX96` and roll the totals up onto
 * the `pool` row. Bounded by `GRID_CELLS` (24) reads by construction (I39), and in practice by the
 * fourteen cells the launch shape places.
 */
export async function refreshLadder(db: Db, id: `0x${string}`): Promise<void> {
  const pool = await db.find(schema.pool, {id})
  if (pool === null) return
  const ticks = ((pool.cellTicks as number[] | null) ?? []).slice(0, 64)
  if (ticks.length === 0) return

  let amps = 0n
  let counter = 0n
  let placed = 0n
  let asks = 0
  let bids = 0

  for (const tickLower of ticks) {
    const key = cellKey(id, tickLower)
    const cell = await db.find(schema.ladderCell, {id: key})
    if (cell === null || cell.liquidity <= 0n) continue
    const amounts = amountsForLiquidity(pool.sqrtPriceX96, cell.tickLower, cell.tickUpper, cell.liquidity)
    const above = amounts.amount0 > 0n
    await db.update(schema.ladderCell, {id: key}).set({
      ampsRemaining: amounts.amount0,
      proceeds: amounts.amount1,
      above,
      filledBps: filledBpsOf(cell.ampsAtPlacement, amounts.amount0),
    })
    amps += amounts.amount0
    counter += amounts.amount1
    placed += cell.ampsAtPlacement
    if (above) asks += 1
    else bids += 1
  }

  await db.update(schema.pool, {id}).set({
    ampsInLadder: amps,
    counterInLadder: counter,
    askCells: asks,
    bidCells: bids,
    ladderFillBps: filledBpsOf(placed, amps),
  })
}

/** Exported for the block jobs, which price the counter side in USD. */
export const counterUsd18 = (raw: bigint, decimals: number, priceUsd18: bigint): bigint =>
  (to18(raw, decimals) * priceUsd18) / 10n ** 18n
