// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useReadContracts} from 'wagmi'
import type {Address, Hex} from 'viem'

import {contract} from '@/lib/contracts'
import type {PoolKeyLike} from '@/lib/route'

/**
 * The real `PoolKey` of each pool, from the registry.
 *
 * A Universal Router `PathKey` carries the pool's `fee`, `tickSpacing` and `hooks`, and getting any
 * of them wrong produces a `PoolId` that does not exist — a revert at best. `PoolRegistry.poolKey`
 * stores exactly what the pool was initialised with, so the route is built from that rather than
 * from a default this app would have had to guess.
 */
export function usePoolKeys(poolIds: readonly Hex[]) {
  const registry = contract('registry')
  const enabled = registry !== undefined && poolIds.length > 0

  const query = useReadContracts({
    contracts: enabled ? poolIds.map((poolId) => ({...registry, functionName: 'poolKey' as const, args: [poolId] as const})) : [],
    query: {enabled},
  })

  const keys = React.useMemo(() => {
    const map = new Map<Hex, PoolKeyLike>()
    if (!query.data) return map
    query.data.forEach((entry, i) => {
      const poolId = poolIds[i]
      const key = entry.result as
        | {currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address}
        | undefined
      if (!poolId || !key || key.currency0 === undefined) return
      map.set(poolId, {
        currency0: key.currency0,
        currency1: key.currency1,
        fee: Number(key.fee),
        tickSpacing: Number(key.tickSpacing),
        hooks: key.hooks,
      })
    })
    return map
  }, [query.data, poolIds])

  return {...query, keys, enabled}
}
