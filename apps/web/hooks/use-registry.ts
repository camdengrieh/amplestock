// SPDX-License-Identifier: MIT
'use client'

import {useReadContract, useReadContracts} from 'wagmi'
import type {Address} from 'viem'

import {addressOf, contract} from '@/lib/contracts'

const NO_CONTRACT = {address: undefined as unknown as Address, abi: [] as never}

/** Counts, the index cap/floor rule at the live `n`, and the two entry pools. */
export function useRegistrySummary() {
  const registry = contract('registry')
  return useReadContracts({
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
  return useReadContract({
    ...(lens ?? NO_CONTRACT),
    functionName: 'activeConstituents',
    query: {enabled: lens !== undefined},
  })
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
