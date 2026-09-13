// SPDX-License-Identifier: MIT
'use client'

import {useReadContracts} from 'wagmi'
import type {Address} from 'viem'

import {contract} from '@/lib/contracts'
import {GenesisPhase, type GenesisPhaseName} from '@/lib/genesis'

/**
 * `AmpsGenesis`, read whole.
 *
 * The adapter is the only contract that knows what the launch decided. The two auctions each know
 * their own clearing price in their own currency; the adapter is what converts them to 18-decimal
 * USD, measures the protocol fee rather than predicting it, picks which leg's price becomes `P0`,
 * and hands the whole lot to `AmpsVault.genesisPlace`. So every settlement figure on the Auction
 * surface comes from here and nothing is added up client-side.
 *
 * A read that fails leaves its field `undefined`, never zero — `p0X18()` is zero both before
 * settlement and after a settlement in which nothing graduated, and neither of those is a price, so
 * the panel decides from {@link GenesisState.phase} rather than from the number.
 */
export interface GenesisState {
  address?: Address
  phase?: GenesisPhaseName
  settled?: boolean
  p0X18?: bigint
  raisedUsdg?: bigint
  raisedWeth?: bigint
  raisedUsd18?: bigint
  unsoldAmps?: bigint
  ethUsdX18?: bigint
  floorUsdgQ96?: bigint
  floorEthQ96?: bigint
  usdgAuction?: Address
  ethAuction?: Address
  vault?: Address
  isLoading: boolean
  /** True when an address is configured but no read came back — a bad pointer, not an empty launch. */
  unavailable: boolean
}

const READS = [
  'phase',
  'settled',
  'p0X18',
  'raisedUsdg',
  'raisedWeth',
  'raisedUsd18',
  'unsoldAmps',
  'ethUsdX18',
  'floorUsdgQ96',
  'floorEthQ96',
  'usdgAuction',
  'ethAuction',
  'vault',
] as const

export function useGenesis(): GenesisState {
  const handle = contract('genesis')

  const query = useReadContracts({
    contracts: handle ? READS.map((functionName) => ({...handle, functionName})) : [],
    query: {enabled: handle !== undefined, refetchInterval: 12_000},
  })

  const at = <T,>(name: (typeof READS)[number]): T | undefined => {
    const entry = query.data?.[READS.indexOf(name)]
    if (!entry || entry.status !== 'success' || entry.result === undefined || entry.result === null) return undefined
    return entry.result as T
  }

  const phaseOrdinal = at<number>('phase')
  const phase = phaseOrdinal === undefined ? undefined : genesisPhaseOf(phaseOrdinal)

  return {
    ...(handle ? {address: handle.address} : {}),
    ...(phase ? {phase} : {}),
    ...(at<boolean>('settled') !== undefined ? {settled: at<boolean>('settled')} : {}),
    ...(at<bigint>('p0X18') !== undefined ? {p0X18: at<bigint>('p0X18')} : {}),
    ...(at<bigint>('raisedUsdg') !== undefined ? {raisedUsdg: at<bigint>('raisedUsdg')} : {}),
    ...(at<bigint>('raisedWeth') !== undefined ? {raisedWeth: at<bigint>('raisedWeth')} : {}),
    ...(at<bigint>('raisedUsd18') !== undefined ? {raisedUsd18: at<bigint>('raisedUsd18')} : {}),
    ...(at<bigint>('unsoldAmps') !== undefined ? {unsoldAmps: at<bigint>('unsoldAmps')} : {}),
    ...(at<bigint>('ethUsdX18') !== undefined ? {ethUsdX18: at<bigint>('ethUsdX18')} : {}),
    ...(at<bigint>('floorUsdgQ96') !== undefined ? {floorUsdgQ96: at<bigint>('floorUsdgQ96')} : {}),
    ...(at<bigint>('floorEthQ96') !== undefined ? {floorEthQ96: at<bigint>('floorEthQ96')} : {}),
    ...(at<Address>('usdgAuction') ? {usdgAuction: at<Address>('usdgAuction')} : {}),
    ...(at<Address>('ethAuction') ? {ethAuction: at<Address>('ethAuction')} : {}),
    ...(at<Address>('vault') ? {vault: at<Address>('vault')} : {}),
    isLoading: query.isLoading,
    unavailable: handle !== undefined && !query.isLoading && phase === undefined,
  }
}

/** The adapter's `Phase` enum, by ordinal. Anything outside it is not a phase and is dropped. */
function genesisPhaseOf(ordinal: number): GenesisPhaseName | undefined {
  return GenesisPhase[ordinal]
}
