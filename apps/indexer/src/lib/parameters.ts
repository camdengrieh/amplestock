// SPDX-License-Identifier: MIT

/**
 * Governed-parameter bookkeeping, shared by every contract that has a setter.
 *
 * `AmpsVault`, `AmpsHook`, `AmpsBonds`, `OracleGate`, `FeedRegistry`, `BountyPot` and
 * `PoolRegistry` each emit their own `*ParameterChanged` / `*PointerChanged` shape. They all land
 * in the same two tables here — an append-only `parameterChange` history and a `parameterState`
 * latest-value row keyed `"<scope>:<name>"` (plus the pool id or market id when the parameter is
 * scoped to one) — so the dApp's Governance page reads one table rather than seven.
 */

import schema from 'ponder:schema'

import {eventId} from './ids'
import type {Db} from './store'

export interface ParameterValues {
  previousValue?: bigint
  newValue?: bigint
  previousAddress?: `0x${string}`
  newAddress?: `0x${string}`
  poolId?: `0x${string}`
  marketId?: number
}

/**
 * One row in `parameterChange` and an upsert into `parameterState`. Every governed parameter in the
 * system funnels through here, whichever contract emitted it, so the dApp's Governance page has a
 * single table to read.
 */
export async function recordParameter(
  context: {db: Db},
  event: {
    block: {number: bigint; timestamp: bigint}
    transaction: {hash: `0x${string}`}
    log: {logIndex: number}
  },
  scope: string,
  name: string,
  values: ParameterValues,
): Promise<void> {
  const key =
    values.poolId !== undefined
      ? `${scope}:${name}:${values.poolId}`
      : values.marketId !== undefined
        ? `${scope}:${name}:${values.marketId}`
        : `${scope}:${name}`

  await context.db.insert(schema.parameterChange).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    scope,
    name,
    poolId: values.poolId ?? null,
    marketId: values.marketId ?? null,
    previousValue: values.previousValue ?? null,
    newValue: values.newValue ?? null,
    previousAddress: values.previousAddress ?? null,
    newAddress: values.newAddress ?? null,
  })

  await context.db
    .insert(schema.parameterState)
    .values({
      id: key,
      scope,
      name,
      poolId: values.poolId ?? null,
      marketId: values.marketId ?? null,
      value: values.newValue ?? null,
      addressValue: values.newAddress ?? null,
      previousValue: values.previousValue ?? null,
      previousAddress: values.previousAddress ?? null,
      updatedAt: event.block.timestamp,
      updatedBlock: event.block.number,
      txHash: event.transaction.hash,
    })
    .onConflictDoUpdate(() => ({
      value: values.newValue ?? null,
      addressValue: values.newAddress ?? null,
      previousValue: values.previousValue ?? null,
      previousAddress: values.previousAddress ?? null,
      updatedAt: event.block.timestamp,
      updatedBlock: event.block.number,
      txHash: event.transaction.hash,
    }))
}
