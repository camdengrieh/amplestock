// SPDX-License-Identifier: MIT

/**
 * `AmpsBonds` — the only post-genesis issuance path.
 *
 * **Realised accretion.** `depositBonded` writes a checkpoint immediately *before* it settles the
 * collateral (phase-2 §6), so the NAV/share the bond was priced against is the last `NavCheckpoint`
 * at the moment `Bond` is emitted, and the NAV/share the bond produced is the *next* one. The
 * handler therefore records the "before" straight away and leaves the "after" to be filled in by
 * the following checkpoint — the pending bond is parked in `indexerState` and closed out by
 * `settleAccretion`, which the `NavCheckpoint` handler calls through `onBondCheckpoint`.
 *
 * Realised accretion in USD is `(navAfter - navBefore) * totalSupply / 1e18`, which is the
 * uplift I27 guarantees is non-negative — a number that belongs to every holder, not to the bonder.
 */

import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {stockTokenAbi} from '../abi/external'
import {decodeBytes32String} from '../lib/bytes32'
import {collateralClassLabel} from '../lib/constants'
import {dayKey, dayStart, eventId, positionKey} from '../lib/ids'
import {changeBps, clampInt} from '../lib/math'
import {
  STATE,
  getState,
  markNavMoved,
  setState,
  updateFlywheelDay,
  updateSummary,
  type Db,
} from '../lib/store'
import {recordParameter} from '../lib/parameters'

const PENDING_BOND = 'bonds.pendingAccretionRow'

ponder.on('AmpsBonds:CollateralAdded', async ({event, context}) => {
  const id = event.args.marketId.toString()
  const [symbol, decimals] = await Promise.all([
    context.client
      .readContract({abi: stockTokenAbi, address: event.args.collateral, functionName: 'symbol'})
      .catch(() => null),
    context.client
      .readContract({abi: stockTokenAbi, address: event.args.collateral, functionName: 'decimals'})
      .catch(() => 18),
  ])

  await context.db
    .insert(schema.bondMarket)
    .values({
      id,
      marketId: event.args.marketId,
      collateral: event.args.collateral,
      collateralSymbol: symbol,
      collateralDecimals: Number(decimals),
      collateralClass: event.args.class,
      collateralClassLabel: collateralClassLabel(event.args.class),
      constituentId: event.args.constituentId,
      open: false,
      detached: false,
      dBaseBps: 0,
      dMinBps: 0,
      dMaxBps: 0,
      capBpsPerEpoch: 0,
      kWeightX18: 0n,
      kFillX18: 0n,
      epochStart: 0n,
      issuedThisEpoch: 0n,
      totalIssued: 0n,
      totalCollateral: 0n,
      accretionUsd18: 0n,
      bondCount: 0,
      lastBondAt: 0n,
      lastDiscountBps: 0,
      forwardedCollateral: 0n,
      createdAt: event.block.timestamp,
    })
    .onConflictDoUpdate(() => ({
      collateral: event.args.collateral,
      collateralSymbol: symbol,
      collateralDecimals: Number(decimals),
      collateralClass: event.args.class,
      collateralClassLabel: collateralClassLabel(event.args.class),
      constituentId: event.args.constituentId,
      // Re-adding the collateral re-attaches the market: `marketIdOf(collateral)` names it again.
      detached: false,
    }))

  // The reverse of `bondMarket.collateral`, and the mirror of `AmpsBonds.marketIdOf`.
  // `CollateralForwarded` names only the collateral, so this is how it finds its market.
  await context.db
    .insert(schema.collateralIndex)
    .values({
      id: event.args.collateral.toLowerCase() as `0x${string}`,
      marketId: event.args.marketId,
      constituentId: event.args.constituentId,
    })
    .onConflictDoUpdate(() => ({
      marketId: event.args.marketId,
      constituentId: event.args.constituentId,
    }))

  if (event.args.constituentId > 0) {
    const c = await context.db.find(schema.constituent, {id: event.args.constituentId.toString()})
    if (c !== null) {
      await context.db
        .update(schema.constituent, {id: c.id})
        .set({marketId: event.args.marketId})
    }
  }
})

/**
 * `removeCollateral` **detaches** the market rather than deleting it: `marketIdOf(collateral)` stops
 * naming it, and `setMarketOpen` refuses a detached market for the rest of the contract's life. The
 * row therefore stays — its issuance history is still true — and is flagged, which is the same
 * fact `PoolRegistry.BondMarketDetached` reports from the registry's side.
 */
ponder.on('AmpsBonds:CollateralRemoved', async ({event, context}) => {
  const id = event.args.marketId.toString()
  const market = await context.db.find(schema.bondMarket, {id})
  if (market !== null) {
    await context.db.update(schema.bondMarket, {id}).set({open: false, detached: true})
  }
  await context.db.delete(schema.collateralIndex, {
    id: event.args.collateral.toLowerCase() as `0x${string}`,
  })
})

/**
 * Residual collateral forwarded to the vault at the exit of `bond()`.
 *
 * The collateral moves bonder -> PoolManager inside the bond and never rests on the shell, so this
 * balance is zero in every honest flow — but "zero" is not enforceable, because anybody may
 * `transfer` a wei to the shell at any time. Asserting it turned a 1-wei donation into a permanent
 * denial of service on that market; forwarding is the same invariant with no such edge, and the
 * outcome is a log rather than a revert reason. A non-zero amount here therefore means somebody
 * donated to the bonds shell, nothing more, and it is recorded as the informational fact it is:
 * one `parameterChange` row for the history, the latest value in `parameterState`, and the running
 * total on the market itself.
 */
ponder.on('AmpsBonds:CollateralForwarded', async ({event, context}) => {
  const collateral = event.args.collateral.toLowerCase() as `0x${string}`
  const indexed = await context.db.find(schema.collateralIndex, {id: collateral})
  // `0` is the protocol's own sentinel for "no market" (`AmpsBonds.marketIdOf`), so an unindexed
  // collateral lands in its own bucket rather than being silently attributed to a real market.
  const marketId = indexed === null ? 0 : indexed.marketId

  await recordParameter(context, event, 'bonds', 'collateralForwarded', {
    newValue: event.args.amount,
    marketId,
  })

  if (marketId === 0) return
  const id = marketId.toString()
  const market = await context.db.find(schema.bondMarket, {id})
  if (market === null) return
  await context.db
    .update(schema.bondMarket, {id})
    .set({forwardedCollateral: market.forwardedCollateral + event.args.amount})
})

ponder.on('AmpsBonds:MarketOpenSet', async ({event, context}) => {
  const id = event.args.marketId.toString()
  const market = await context.db.find(schema.bondMarket, {id})
  if (market !== null) await context.db.update(schema.bondMarket, {id}).set({open: event.args.open})
  await recordParameter(context, event, 'bonds', 'open', {
    newValue: event.args.open ? 1n : 0n,
    marketId: event.args.marketId,
  })
})

ponder.on('AmpsBonds:EpochRolled', async ({event, context}) => {
  const id = event.args.marketId.toString()
  const market = await context.db.find(schema.bondMarket, {id})
  if (market !== null) {
    await context.db
      .update(schema.bondMarket, {id})
      .set({epochStart: BigInt(event.args.epochStart), issuedThisEpoch: 0n})
    const previous = `${event.args.marketId}-${market.epochStart.toString()}`
    const row = await context.db.find(schema.bondEpoch, {id: previous})
    if (row !== null) {
      await context.db.update(schema.bondEpoch, {id: previous}).set({epochEnd: BigInt(event.args.epochStart)})
    }
  }
})

ponder.on('AmpsBonds:Bond', async ({event, context}) => {
  // A bond adds collateral and mints against it, so the next checkpoint's NAV move is explained.
  await markNavMoved(context.db, event.block.number)
  const marketId = event.args.marketId
  const navBefore = (await getState(context.db, STATE.navPerShareX18)) ?? 0n
  const supply = (await getState(context.db, STATE.totalSupply)) ?? 0n
  const pRef = (await getState(context.db, STATE.pRefX18)) ?? 0n
  const id = eventId(event.block.number, event.log.logIndex)

  await context.db.insert(schema.bondPurchase).values({
    id,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    buyer: event.args.buyer,
    marketId,
    collateral: event.args.collateral,
    amountIn: event.args.amountIn,
    ampsOut: event.args.ampsOut,
    positionId: event.args.positionId,
    qX18: event.args.qX18,
    discountBps: event.args.discountBps,
    floorBinding: event.args.floorBinding,
    vestSeconds: Number(event.args.vestSeconds),
    navBeforeX18: navBefore,
    navAfterX18: 0n,
    accretionUsd18: 0n,
    accretionBps: 0,
  })

  // The `NavCheckpoint` that follows this transaction closes the accretion out.
  await setState(context.db, PENDING_BOND, event.block.number, event.block.number, id)
  await setState(context.db, `${PENDING_BOND}.supply`, supply, event.block.number)

  await context.db.insert(schema.bondPosition).values({
    id: positionKey(event.args.buyer, event.args.positionId),
    owner: event.args.buyer,
    positionId: event.args.positionId,
    marketId,
    collateral: event.args.collateral,
    principal: event.args.ampsOut,
    claimed: 0n,
    start: event.block.timestamp,
    // Frozen at purchase (I38) and now in the log, so a claim schedule is computable from the index
    // alone rather than from a lens read.
    vestSeconds: Number(event.args.vestSeconds),
    fullyClaimed: false,
    lastClaimAt: null,
  })

  const market = await context.db.find(schema.bondMarket, {id: marketId.toString()})
  const epochStart = market?.epochStart ?? 0n
  if (market !== null) {
    await context.db.update(schema.bondMarket, {id: marketId.toString()}).set((row) => ({
      totalIssued: row.totalIssued + event.args.ampsOut,
      issuedThisEpoch: row.issuedThisEpoch + event.args.ampsOut,
      totalCollateral: row.totalCollateral + event.args.amountIn,
      bondCount: row.bondCount + 1,
      lastBondAt: event.block.timestamp,
      lastDiscountBps: event.args.discountBps,
    }))
  }

  await context.db
    .insert(schema.bondEpoch)
    .values({
      id: `${marketId}-${epochStart.toString()}`,
      marketId,
      epochStart,
      epochEnd: null,
      issued: event.args.ampsOut,
      collateralIn: event.args.amountIn,
      accretionUsd18: 0n,
      bondCount: 1,
      minDiscountBps: event.args.discountBps,
      maxDiscountBps: event.args.discountBps,
      floorBindingCount: event.args.floorBinding ? 1 : 0,
    })
    .onConflictDoUpdate((row) => ({
      issued: row.issued + event.args.ampsOut,
      collateralIn: row.collateralIn + event.args.amountIn,
      bondCount: row.bondCount + 1,
      minDiscountBps: Math.min(row.minDiscountBps, event.args.discountBps),
      maxDiscountBps: Math.max(row.maxDiscountBps, event.args.discountBps),
      floorBindingCount: row.floorBindingCount + (event.args.floorBinding ? 1 : 0),
    }))

  await context.db
    .insert(schema.bondDay)
    .values({
      id: dayKey(marketId, event.block.timestamp),
      marketId,
      day: dayStart(event.block.timestamp),
      issued: event.args.ampsOut,
      collateralIn: event.args.amountIn,
      accretionUsd18: 0n,
      bondCount: 1,
      avgDiscountBps: event.args.discountBps,
    })
    .onConflictDoUpdate((row) => ({
      issued: row.issued + event.args.ampsOut,
      collateralIn: row.collateralIn + event.args.amountIn,
      bondCount: row.bondCount + 1,
      avgDiscountBps: Math.round(
        (row.avgDiscountBps * row.bondCount + event.args.discountBps) / (row.bondCount + 1),
      ),
    }))

  // `netSupplyChange` is not moved here: the AMPS a bond issues is minted to `AmpsBonds` through
  // `mintVesting` (I30), so the accompanying `VestingMinted` has already accounted for it.
  await updateSummary(context.db, event.block.number, event.block.timestamp, (row) => ({
    bondIssuedTotal: row.bondIssuedTotal + event.args.ampsOut,
  }))
  await updateFlywheelDay(context.db, event.block.timestamp, (row) => ({
    bondIssuedAmps: row.bondIssuedAmps + event.args.ampsOut,
  }))
  void pRef
})

ponder.on('AmpsBonds:Claim', async ({event, context}) => {
  await context.db.insert(schema.bondClaim).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    owner: event.args.owner,
    positionId: event.args.positionId,
    to: event.args.to,
    amount: event.args.amount,
  })
  const key = positionKey(event.args.owner, event.args.positionId)
  const position = await context.db.find(schema.bondPosition, {id: key})
  if (position === null) return
  const claimed = position.claimed + event.args.amount
  await context.db.update(schema.bondPosition, {id: key}).set({
    claimed,
    fullyClaimed: claimed >= position.principal,
    lastClaimAt: event.block.timestamp,
  })
})

ponder.on('AmpsBonds:BondParameterChanged', async ({event, context}) => {
  const name = decodeBytes32String(event.args.parameter)
  await recordParameter(context, event, 'bonds', name, {
    previousValue: event.args.previousValue,
    newValue: event.args.newValue,
    marketId: event.args.marketId,
  })

  const id = event.args.marketId.toString()
  const market = await context.db.find(schema.bondMarket, {id})
  if (market === null) return
  const value = clampInt(event.args.newValue)
  const patch: Record<string, number | bigint> = {}
  if (name === 'dBaseBps') patch.dBaseBps = value
  else if (name === 'dMinBps') patch.dMinBps = value
  else if (name === 'dMaxBps') patch.dMaxBps = value
  else if (name === 'capBpsPerEpoch') patch.capBpsPerEpoch = value
  else if (name === 'kWeightX18') patch.kWeightX18 = event.args.newValue
  else if (name === 'kFillX18') patch.kFillX18 = event.args.newValue
  if (Object.keys(patch).length > 0) await context.db.update(schema.bondMarket, {id}).set(patch)
})

ponder.on('AmpsBonds:PolicyChanged', async ({event, context}) => {
  await recordParameter(context, event, 'bonds.pointer', 'bondPolicy', {
    previousAddress: event.args.previousPolicy,
    newAddress: event.args.newPolicy,
  })
})

ponder.on('AmpsBonds:VaultChanged', async ({event, context}) => {
  await recordParameter(context, event, 'bonds.pointer', 'vault', {
    previousAddress: event.args.previousVault,
    newAddress: event.args.newVault,
  })
})

/**
 * Close out the accretion of the bond that priced against `navBefore`, now that the checkpoint
 * after it has been written. Called from the `NavCheckpoint` handler through
 * `src/handlers/checkpointHooks.ts`, so the ordering is the chain's, not a guess.
 */
export async function settleAccretion(
  db: Db,
  navAfter: bigint,
  blockNumber: bigint,
  timestamp: bigint,
): Promise<void> {
  const row = await db.find(schema.indexerState, {id: PENDING_BOND})
  if (row === null || row.text === null) return
  const purchase = await db.find(schema.bondPurchase, {id: row.text})
  if (purchase === null) {
    await db.delete(schema.indexerState, {id: PENDING_BOND})
    return
  }
  // Only the checkpoint that follows the bond closes it; a checkpoint in the same block but before
  // the `Bond` log cannot, and is ignored because the pending row is written after it.
  if (blockNumber < purchase.blockNumber) return

  const supplyRow = await db.find(schema.indexerState, {id: `${PENDING_BOND}.supply`})
  const supply = supplyRow?.value ?? 0n
  const accretionUsd18 = ((navAfter - purchase.navBeforeX18) * supply) / 10n ** 18n
  const accretionBps = changeBps(purchase.navBeforeX18, navAfter)

  await db.update(schema.bondPurchase, {id: purchase.id}).set({
    navAfterX18: navAfter,
    accretionUsd18,
    accretionBps,
  })

  const market = await db.find(schema.bondMarket, {id: purchase.marketId.toString()})
  if (market !== null) {
    await db
      .update(schema.bondMarket, {id: market.id})
      .set({accretionUsd18: market.accretionUsd18 + accretionUsd18})
    const epochId = `${purchase.marketId}-${market.epochStart.toString()}`
    const epoch = await db.find(schema.bondEpoch, {id: epochId})
    if (epoch !== null) {
      await db
        .update(schema.bondEpoch, {id: epochId})
        .set({accretionUsd18: epoch.accretionUsd18 + accretionUsd18})
    }
  }

  const dayId = dayKey(purchase.marketId, purchase.timestamp)
  const day = await db.find(schema.bondDay, {id: dayId})
  if (day !== null) {
    await db.update(schema.bondDay, {id: dayId}).set({accretionUsd18: day.accretionUsd18 + accretionUsd18})
  }

  await updateFlywheelDay(db, timestamp, (r) => ({
    bondAccretionUsd18: r.bondAccretionUsd18 + accretionUsd18,
  }))

  await db.delete(schema.indexerState, {id: PENDING_BOND})
  await db.delete(schema.indexerState, {id: `${PENDING_BOND}.supply`})
}
