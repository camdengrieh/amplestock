// SPDX-License-Identifier: MIT

/**
 * Row keys. Every one is text, lower-cased and zero-padded so lexical order is chain order — which
 * is what lets the GraphQL layer paginate by `id` without a second sort column.
 */

import type {Hex} from 'viem'

import {ONE_DAY} from './constants'

const pad = (value: bigint | number, width: number) => value.toString().padStart(width, '0')

/** `"<blockNumber>-<logIndex>"`, 12 and 6 digits. Unique for any log on any chain we index. */
export function eventId(blockNumber: bigint, logIndex: number): string {
  return `${pad(blockNumber, 12)}-${pad(logIndex, 6)}`
}

/** A key for a row that a block job writes: no log index exists, so the job name stands in. */
export function jobId(blockNumber: bigint, job: string, suffix?: string | number): string {
  return suffix === undefined
    ? `${pad(blockNumber, 12)}-${job}`
    : `${pad(blockNumber, 12)}-${job}-${suffix}`
}

/** The `PoolId`, lower-cased. Pool ids are the primary key of `pool` and a foreign key everywhere. */
export function poolKey(poolId: Hex): Hex {
  return poolId.toLowerCase() as Hex
}

/** `"<poolId>-<tickLower>"`: one ladder cell. `tickLower` is the merge key on-chain too (§3.4). */
export function cellKey(poolId: Hex, tickLower: number): string {
  return `${poolKey(poolId)}-${tickLower}`
}

/** `"<txHash>-<poolId>"`: a rotation credit parked for the `Swap` that follows it. */
export function creditKey(txHash: Hex, poolId: Hex): string {
  return `${txHash.toLowerCase()}-${poolKey(poolId)}`
}

/** `"<owner>-<positionId>"`: one bond position. Positions are per-owner arrays, not NFTs. */
export function positionKey(owner: Hex, positionId: bigint): string {
  return `${owner.toLowerCase()}-${positionId.toString()}`
}

/** The UTC midnight at or before `timestamp`. */
export function dayStart(timestamp: bigint): bigint {
  return (timestamp / ONE_DAY) * ONE_DAY
}

/** `"<id>-<dayStart>"` for the per-day rollups. */
export function dayKey(id: string | number, timestamp: bigint): string {
  return `${id}-${dayStart(timestamp).toString()}`
}

/** The one-row summary tables all use this key. */
export const SINGLETON = 'singleton'
