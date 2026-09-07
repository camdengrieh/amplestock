// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useReadContract, useReadContracts} from 'wagmi'
import type {Address} from 'viem'

import {addressOf, contract} from '@/lib/contracts'

const NO_CONTRACT = {address: undefined as unknown as Address, abi: [] as never}

/** Counts, the index cap/floor rule at the live `n`, and the two entry pools. */
export function useRegistrySummary() {
  const registry = contract('registry')
  const query = useReadContracts({
    contracts: registry
      ? ([
          {...registry, functionName: 'constituentCount'},
          {...registry, functionName: 'activeConstituentCount'},
          {...registry, functionName: 'poolCount'},
          {...registry, functionName: 'indexCapBps'},
          {...registry, functionName: 'indexFloorBps'},
          {...registry, functionName: 'hubPoolId'},
          {...registry, functionName: 'wethPoolId'},
        ] as const)
      : [],
    query: {enabled: registry !== undefined},
  })
  const at = (i: number): number | undefined => {
    const entry = query.data?.[i]
    if (!entry || entry.status !== 'success' || entry.result === undefined) return undefined
    return Number(entry.result as bigint | number)
  }
  const hex = (i: number): `0x${string}` | undefined => {
    const entry = query.data?.[i]
    if (!entry || entry.status !== 'success' || entry.result === undefined) return undefined
    return entry.result as `0x${string}`
  }
  return {
    ...query,
    enabled: registry !== undefined,
    constituentCount: at(0),
    activeConstituentCount: at(1),
    poolCount: at(2),
    indexCapBps: at(3),
    indexFloorBps: at(4),
    hubPoolId: hex(5),
    wethPoolId: hex(6),
  }
}

/** One constituent's record: status, weights, feed, freeze, market id. */
export function useConstituent(constituentId: number | undefined) {
  const registry = contract('registry')
  const enabled = registry !== undefined && constituentId !== undefined && constituentId > 0
  return useReadContract({
    ...(registry ?? NO_CONTRACT),
    functionName: 'constituent',
    args: enabled ? [constituentId as number] : undefined,
    query: {enabled},
  })
}

/** The index target-weight vector, and the sum the quarterly rule holds at 10,000 bps. */
export function useIndexWeights() {
  const lens = contract('registryLens')
  const query = useReadContract({
    ...(lens ?? NO_CONTRACT),
    functionName: 'indexWeights',
    query: {enabled: lens !== undefined},
  })
  const data = query.data as readonly [readonly number[], readonly number[], bigint] | undefined
  return {...query, weights: data ? {ids: data[0], weightsBps: data[1], totalBps: data[2]} : undefined}
}

/** Ids of every constituent that is not retired — a frozen name is still an index member. */
export function useActiveConstituents() {
  const lens = contract('registryLens')
  const query = useReadContract({
    ...(lens ?? NO_CONTRACT),
    functionName: 'activeConstituents',
    query: {enabled: lens !== undefined},
  })
  return {...query, ids: (query.data as readonly number[] | undefined) ?? undefined, enabled: lens !== undefined}
}

/** The weight floor and cap the registry's rule produces at a given count. `pure` on the lens. */
export function useWeightBounds(n: number | undefined) {
  const lens = contract('registryLens')
  const enabled = lens !== undefined && n !== undefined && n > 0
  const query = useReadContract({
    ...(lens ?? NO_CONTRACT),
    functionName: 'weightBoundsFor',
    args: enabled ? [n as number] : undefined,
    query: {enabled},
  })
  const data = query.data as readonly [number, number] | undefined
  return {...query, bounds: data ? {floorBps: Number(data[0]), capBps: Number(data[1])} : undefined}
}

export interface ConstituentRecord {
  id: number
  token: Address
  status: number
  decimals: number
  /** What the registry says the index should hold. */
  targetWeightBps: number
  /** What the rollout has actually migrated so far. */
  rolloutWeightBps: number
  marketId: number
  feed: Address
  freezeUntil: number
  addedAt: number
  retiredAt: number
  /** What the vault holds right now, priced at the reference. `undefined` when the read failed. */
  currentWeightBps?: number
  /** `poolIdOf(id)`, so the row can be joined to a quote. */
  poolId?: `0x${string}`
}

/**
 * The constituent set, with **target and realised weights side by side**.
 *
 * The target is `ConstituentConfig.targetWeightBps` — governance's statement of what the index
 * should hold. The realised figure is `PoolRegistry.currentWeightBps(id)`, which is what the vault
 * holds right now valued at the reference price. They differ because the rollout moves inventory
 * on a daily cap and because the market moves the assets in between; the Vault surface shows both
 * rather than picking one and calling it "the weight".
 *
 * Each of the three reads per constituent can fail independently, and a failure leaves that field
 * `undefined` rather than zero — a constituent whose weight could not be read is not a constituent
 * with no weight.
 */
export function useConstituentRecords(ids: readonly number[]) {
  const registry = contract('registry')
  const enabled = registry !== undefined && ids.length > 0

  const query = useReadContracts({
    contracts: enabled
      ? ids.flatMap((id) => [
          {...registry, functionName: 'constituent' as const, args: [id] as const},
          {...registry, functionName: 'currentWeightBps' as const, args: [id] as const},
          {...registry, functionName: 'poolIdOf' as const, args: [id] as const},
        ])
      : [],
    query: {enabled, refetchInterval: 60_000},
  })

  const records = React.useMemo<ConstituentRecord[]>(() => {
    if (!query.data) return []
    const out: ConstituentRecord[] = []
    ids.forEach((id, i) => {
      const configEntry = query.data?.[i * 3]
      const weightEntry = query.data?.[i * 3 + 1]
      const poolEntry = query.data?.[i * 3 + 2]
      if (!configEntry || configEntry.status !== 'success' || !configEntry.result) return
      const config = configEntry.result as {
        token: Address
        status: number
        decimals: number
        targetWeightBps: number
        rolloutWeightBps: number
        marketId: number
        feed: Address
        freezeUntil: number
        addedAt: number
        retiredAt: number
      }
      const currentWeightBps =
        weightEntry?.status === 'success' && weightEntry.result !== undefined ? Number(weightEntry.result) : undefined
      const poolId =
        poolEntry?.status === 'success' && poolEntry.result !== undefined
          ? (poolEntry.result as `0x${string}`)
          : undefined
      out.push({
        id,
        token: config.token,
        status: Number(config.status),
        decimals: Number(config.decimals),
        targetWeightBps: Number(config.targetWeightBps),
        rolloutWeightBps: Number(config.rolloutWeightBps),
        marketId: Number(config.marketId),
        feed: config.feed,
        freezeUntil: Number(config.freezeUntil),
        addedAt: Number(config.addedAt),
        retiredAt: Number(config.retiredAt),
        ...(currentWeightBps !== undefined ? {currentWeightBps} : {}),
        ...(poolId ? {poolId} : {}),
      })
    })
    return out
  }, [query.data, ids])

  return {...query, records, enabled}
}

/** The gate snapshot for one pool: state, session, staleness, freeze, divergence, watchdog. */
export function useGateSnapshot(poolId: `0x${string}` | undefined) {
  const gate = contract('oracleGate')
  const enabled = gate !== undefined && poolId !== undefined
  return useReadContract({
    ...(gate ?? NO_CONTRACT),
    functionName: 'snapshotByPool',
    args: enabled ? [poolId as `0x${string}`] : undefined,
    query: {enabled, refetchInterval: 20_000},
  })
}

export function useTimelockAddress() {
  return addressOf('timelock')
}
