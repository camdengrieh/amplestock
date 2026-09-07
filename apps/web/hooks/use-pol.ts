// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useReadContract, useReadContracts} from 'wagmi'
import type {Address, Hex} from 'viem'

import {abis, contract} from '@/lib/contracts'

const NO_CONTRACT = {address: undefined as unknown as Address, abi: [] as never}

/**
 * The position valuer's address, from the vault rather than from configuration.
 *
 * `LadderPositionValuer` is a pointer the vault holds, so reading it is both fewer environment
 * variables and the only answer that cannot go stale: whatever the vault is valuing its positions
 * with is what the app reads them with.
 */
export function usePositionValuer(): Address | undefined {
  const vault = contract('vault')
  const query = useReadContract({
    ...(vault ?? NO_CONTRACT),
    functionName: 'positionValuer',
    query: {enabled: vault !== undefined},
  })
  const address = query.data as Address | undefined
  return address && address !== '0x0000000000000000000000000000000000000000' ? address : undefined
}

export interface PolAmounts {
  poolId: Hex
  /** AMPS wei the vault holds across the pool's grid cells: the unfilled ask inventory. */
  amps: bigint
  /** Counter asset held across them, in its own raw units: the entire bid under AMPS in this pool. */
  counter: bigint
}

/**
 * Per-pool protocol-owned liquidity, decomposed at the reference price.
 *
 * `LadderPositionValuer.amountsOf` uses the same decomposition, the same rounding and the same
 * price as the vault's own `A`, so `counter` is to the wei the term `A` credits this pool with and
 * `amps` is the inventory term NAV values at zero. It never reverts: an unregistered pool, a
 * missing checkpoint or a feed that cannot answer all come back `(0, 0)`.
 *
 * That last property is why this hook reports availability separately — a `(0, 0)` from a failed
 * read and a `(0, 0)` from a genuinely empty pool are the same bytes, so the caller is told which
 * pools answered rather than being handed zeros to render.
 */
export function usePolAmounts(poolIds: readonly Hex[]) {
  const valuer = usePositionValuer()
  const enabled = valuer !== undefined && poolIds.length > 0

  const query = useReadContracts({
    contracts: enabled
      ? poolIds.map((poolId) => ({
          address: valuer as Address,
          abi: abis.valuer,
          functionName: 'amountsOf' as const,
          args: [poolId] as const,
        }))
      : [],
    query: {enabled, refetchInterval: 30_000},
  })

  const amounts = React.useMemo(() => {
    const map = new Map<Hex, PolAmounts>()
    if (!query.data) return map
    query.data.forEach((entry, i) => {
      const poolId = poolIds[i]
      const result = entry.result as readonly [bigint, bigint] | undefined
      if (!poolId || entry.status !== 'success' || !result) return
      map.set(poolId, {poolId, amps: result[0], counter: result[1]})
    })
    return map
  }, [query.data, poolIds])

  return {...query, amounts, enabled, valuer}
}

/**
 * When each pool last placed, so the surface can say when the next placement becomes eligible.
 *
 * The vault refuses to place in a pool within `PLACEMENT_COOLDOWN_SECONDS` of its last placement,
 * which is what a `compound()` has to clear before it can re-ladder anything.
 */
export function useLastPlacementAt(poolIds: readonly Hex[]) {
  const vault = contract('vault')
  const enabled = vault !== undefined && poolIds.length > 0

  const query = useReadContracts({
    contracts: enabled ? poolIds.map((poolId) => ({...vault, functionName: 'lastPlacementAt' as const, args: [poolId] as const})) : [],
    query: {enabled, refetchInterval: 30_000},
  })

  const lastPlacement = React.useMemo(() => {
    const map = new Map<Hex, number>()
    if (!query.data) return map
    query.data.forEach((entry, i) => {
      const poolId = poolIds[i]
      if (!poolId || entry.status !== 'success' || entry.result === undefined) return
      map.set(poolId, Number(entry.result))
    })
    return map
  }, [query.data, poolIds])

  return {...query, lastPlacement, enabled}
}
