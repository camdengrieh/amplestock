// SPDX-License-Identifier: MIT

/**
 * Two pieces of *optional* start-up knowledge that only change how much the RPC is asked for, never
 * what ends up in the database:
 *
 * - the 32 `PoolId`s, so the `PoolManager` log filter can be a topic filter rather than "every v4
 *   swap on the chain, dropped in the handler";
 * - the extra addresses the denylist alarm watches beyond the registered Stock Tokens.
 *
 * The pool ids come from `AMPS_POOL_IDS` (comma-separated) or from `AMPS_POOLS`, a path to the
 * `script/config/pools.json` that `script/05_Registry.s.sol` writes out of the `PoolOpened` events.
 * Neither is required, and an empty list is a supported configuration.
 */

import {readFileSync} from 'node:fs'

import {getAddress, isAddress, isHex, type Address, type Hex} from 'viem'

import {ZERO_ADDRESS, type AmpsAddressBook} from './addresses'

interface PoolsFile {
  chainId?: number
  registry?: string
  hook?: string
  poolCount?: number
  pools?: {poolId?: string; id?: string}[]
}

const asPoolId = (value: string, where: string): Hex => {
  const trimmed = value.trim()
  if (!isHex(trimmed) || trimmed.length !== 66) {
    throw new Error(`[indexer] ${where} is not a 32-byte pool id: ${trimmed}`)
  }
  return trimmed.toLowerCase() as Hex
}

/** The pool ids to push into the `PoolManager` topic filter, or `[]` for "filter in the handler". */
export function poolIdFilter(env: NodeJS.ProcessEnv = process.env): Hex[] {
  const ids: Hex[] = []
  const inline = env.AMPS_POOL_IDS?.trim()
  if (inline) {
    for (const part of inline.split(',')) {
      if (part.trim() !== '') ids.push(asPoolId(part, 'AMPS_POOL_IDS'))
    }
  }
  const path = env.AMPS_POOLS?.trim()
  if (path) {
    let file: PoolsFile
    try {
      file = JSON.parse(readFileSync(path, 'utf8')) as PoolsFile
    } catch (cause) {
      throw new Error(`[indexer] AMPS_POOLS could not be read: ${path}`, {cause})
    }
    for (const pool of file.pools ?? []) {
      const raw = pool.poolId ?? pool.id
      if (raw) ids.push(asPoolId(raw, 'AMPS_POOLS'))
    }
  }
  return [...new Set(ids)]
}

/**
 * Addresses the denylist alarm watches on top of the registered constituents: the Stock Token
 * beacon from the address book, plus whatever `AMPS_DENYLIST_WATCH` adds (the implementation, the
 * issuer admin key, and the `ACCESS_CONTROLLED_REGISTRY` once Phase 0 has decompiled it).
 *
 * Never empty: Ponder needs at least one address for the source to build, and the zero address is
 * a live source that simply never matches.
 */
export function denylistWatchList(
  book: AmpsAddressBook,
  env: NodeJS.ProcessEnv = process.env,
): Address[] {
  const out = new Set<Address>()
  if (book.stockTokenBeacon !== ZERO_ADDRESS) out.add(book.stockTokenBeacon)
  for (const part of (env.AMPS_DENYLIST_WATCH ?? '').split(',')) {
    const trimmed = part.trim()
    if (trimmed === '') continue
    if (!isAddress(trimmed)) throw new Error(`[indexer] AMPS_DENYLIST_WATCH is not an address: ${trimmed}`)
    out.add(getAddress(trimmed))
  }
  return out.size > 0 ? [...out] : [ZERO_ADDRESS]
}
