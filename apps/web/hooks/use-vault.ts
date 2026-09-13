// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useReadContract, useReadContracts} from 'wagmi'
import type {Address} from 'viem'

import {contract} from '@/lib/contracts'

const NO_CONTRACT = {address: undefined as unknown as Address, abi: [] as never}

export interface Checkpoint {
  navPerShareX18: bigint
  pRefX18: bigint
  pMktX18: bigint
  timestamp: number
  blockNumber: number
}

/**
 * The vault, in one multicall, keyed by name.
 *
 * It used to hand back the raw `useReadContracts` array and let each surface index into it, which
 * meant adding a read renumbered every consumer. The reads are named here instead, and every
 * missing or failed one comes back `undefined` rather than zero — the same rule the quoter's
 * degraded bits enforce, applied to a plain contract read.
 *
 * `burnBps` and `stakerBps` are deliberately absent. Revision 6 removes the staker slice, and the
 * burn is no longer a governed share: the AMPS side of every fee is burned after the creator slice,
 * so there is no parameter to show.
 */
const VAULT_READS = [
  'checkpointData',
  'previewNavPerShareX18',
  'totalAssetsUsd18',
  'inventoryAmps',
  'redeemFeeBps',
  'REDEEM_FEE_BPS_MAX',
  'genesisTimestamp',
  'S0',
  'CREATOR_FEE_BPS',
  'CREATOR_DECAY_SECONDS',
  'liveCells',
  'initialized',
  'rolloutBpsPerDay',
  'ROLLOUT_BPS_PER_DAY_MAX',
  'entryFloorBps',
  'refUpRateBps',
  'refDivergenceBps',
  'twapWindow',
  'spokeSeedBps',
  'ladderDoublings',
  'ladderTiltX18',
  'assetCount',
  'creator',
  'timelock',
  'guardian',
  'deployThresholdUsd18',
] as const

type VaultRead = (typeof VAULT_READS)[number]

export function useVaultSnapshot() {
  const vault = contract('vault')
  const query = useReadContracts({
    contracts: vault ? VAULT_READS.map((functionName) => ({...vault, functionName})) : [],
    query: {enabled: vault !== undefined, refetchInterval: 30_000},
  })

  const value = React.useCallback(
    <T>(name: VaultRead): T | undefined => {
      const index = VAULT_READS.indexOf(name)
      const entry = query.data?.[index]
      if (!entry || entry.status !== 'success' || entry.result === undefined || entry.result === null) return undefined
      return entry.result as T
    },
    [query.data],
  )

  const num = React.useCallback(
    (name: VaultRead): number | undefined => {
      const raw = value<bigint | number>(name)
      return raw === undefined ? undefined : Number(raw)
    },
    [value],
  )

  return {
    ...query,
    enabled: vault !== undefined,
    checkpoint: value<Checkpoint>('checkpointData'),
    previewNavPerShareX18: value<bigint>('previewNavPerShareX18'),
    totalAssetsUsd18: value<bigint>('totalAssetsUsd18'),
    inventoryAmps: value<bigint>('inventoryAmps'),
    /** Live, always. The launch value moves and this interface never writes it down. */
    redeemFeeBps: num('redeemFeeBps'),
    /** The ceiling hardcoded in the vault; governance cannot widen it. */
    redeemFeeBpsMax: num('REDEEM_FEE_BPS_MAX'),
    genesisTimestamp: num('genesisTimestamp'),
    /**
     * `S0`, the whole genesis supply, from the vault's own bytecode.
     *
     * It is the denominator of NAV per share **at launch** and it never moves, which is what makes
     * it the right divisor for a settlement figure: `Amps.totalSupply()` grows with every bond, so
     * dividing the auction's raise by it would make the launch NAV drift downwards for ever after.
     */
    s0: value<bigint>('S0'),
    creatorFeeBps: num('CREATOR_FEE_BPS'),
    creatorDecaySeconds: num('CREATOR_DECAY_SECONDS'),
    liveCells: num('liveCells'),
    initialized: value<boolean>('initialized'),
    rolloutBpsPerDay: num('rolloutBpsPerDay'),
    rolloutBpsPerDayMax: num('ROLLOUT_BPS_PER_DAY_MAX'),
    entryFloorBps: num('entryFloorBps'),
    refUpRateBps: num('refUpRateBps'),
    refDivergenceBps: num('refDivergenceBps'),
    twapWindow: num('twapWindow'),
    spokeSeedBps: num('spokeSeedBps'),
    ladderDoublings: num('ladderDoublings'),
    ladderTiltX18: value<bigint>('ladderTiltX18'),
    assetCount: num('assetCount'),
    creator: value<Address>('creator'),
    timelock: value<Address>('timelock'),
    guardian: value<Address>('guardian'),
    deployThresholdUsd18: value<bigint>('deployThresholdUsd18'),
  }
}

/** `previewRedeem(shares)` — balances only, no oracle, no gate, never reverts for a live vault. */
export function usePreviewRedeem(shares: bigint | undefined) {
  const vault = contract('vault')
  return useReadContract({
    ...(vault ?? NO_CONTRACT),
    functionName: 'previewRedeem',
    args: shares !== undefined ? [shares] : undefined,
    query: {enabled: vault !== undefined && shares !== undefined && shares > 0n},
  })
}

/**
 * The creator fee in force now, from the vault's own schedule rather than from a mirror of it.
 *
 * The schedule is immutable — 1% of trade volume at genesis, decaying linearly to exactly zero at
 * day 30 — so this is a read of arithmetic, not of governed state. It is still read rather than
 * computed here so that the number on the page is the number the contract will use.
 */
export function useCreatorBps(timestamp: number) {
  const vault = contract('vault')
  const query = useReadContract({
    ...(vault ?? NO_CONTRACT),
    functionName: 'creatorBpsAt',
    args: [BigInt(timestamp)],
    query: {enabled: vault !== undefined},
  })
  const raw = query.data as bigint | number | undefined
  return {...query, creatorBps: raw === undefined ? undefined : Number(raw)}
}

/** Every asset the vault has ever registered, in its own order. The holdings list is built on it. */
export function useVaultAssets(count: number | undefined) {
  const vault = contract('vault')
  const enabled = vault !== undefined && count !== undefined && count > 0
  const query = useReadContracts({
    contracts: enabled
      ? Array.from({length: count}, (_, i) => ({...vault, functionName: 'assetAt' as const, args: [BigInt(i)] as const}))
      : [],
    query: {enabled, refetchInterval: 60_000},
  })
  const assets = React.useMemo<Address[]>(() => {
    if (!query.data) return []
    return query.data
      .filter((entry) => entry.status === 'success' && entry.result !== undefined)
      .map((entry) => entry.result as Address)
  }, [query.data])
  return {...query, assets, enabled}
}

/** The ladder, cell by cell, for one pool — the live half of the ladder-fill panel. */
export function useLadder(poolId: `0x${string}` | undefined, length: number | undefined) {
  const vault = contract('vault')
  const enabled = vault !== undefined && poolId !== undefined && length !== undefined && length > 0
  return useReadContracts({
    contracts: enabled
      ? Array.from({length}, (_, i) => ({...vault, functionName: 'ladderAt' as const, args: [poolId, BigInt(i)] as const}))
      : [],
    query: {enabled},
  })
}

/** `ladderLength(poolId)` for a set of pools, so the surface knows how many cells to ask for. */
export function useLadderLengths(poolIds: readonly `0x${string}`[]) {
  const vault = contract('vault')
  const enabled = vault !== undefined && poolIds.length > 0
  const query = useReadContracts({
    contracts: enabled
      ? poolIds.map((poolId) => ({...vault, functionName: 'ladderLength' as const, args: [poolId] as const}))
      : [],
    query: {enabled, refetchInterval: 60_000},
  })
  const lengths = React.useMemo(() => {
    const map = new Map<string, number>()
    query.data?.forEach((entry, i) => {
      const poolId = poolIds[i]
      if (!poolId || entry.status !== 'success' || entry.result === undefined) return
      map.set(poolId, Number(entry.result))
    })
    return map
  }, [query.data, poolIds])
  return {...query, lengths, enabled}
}
