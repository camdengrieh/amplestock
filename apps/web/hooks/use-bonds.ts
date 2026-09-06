// SPDX-License-Identifier: MIT
'use client'

import {useAccount, useReadContract} from 'wagmi'
import type {Address} from 'viem'

import {addressOf, contract} from '@/lib/contracts'

const NO_CONTRACT = {address: undefined as unknown as Address, abi: [] as never}

/**
 * The whole bond board in one call, quoted at a hypothetical deposit.
 *
 * `AmpsBondsLens.board` never reverts: a closed, gated or full market comes back with
 * `ampsOut == 0` and a `reason`, which is what lets the board render every market including the
 * ones that cannot be bonded right now.
 */
export function useBondBoard(amountIn: bigint) {
  const lens = contract('bondsLens')
  const bonds = addressOf('bonds')
  const enabled = lens !== undefined && bonds !== undefined
  return useReadContract({
    ...(lens ?? NO_CONTRACT),
    functionName: 'board',
    args: enabled ? [bonds as Address, amountIn] : undefined,
    query: {enabled, refetchInterval: 15_000},
  })
}

/** One market's live quote, direct from the shell. */
export function useBondMarketQuote(marketId: number | undefined, amountIn: bigint) {
  const bonds = contract('bonds')
  const enabled = bonds !== undefined && marketId !== undefined && marketId > 0 && amountIn > 0n
  const query = useReadContract({
    ...(bonds ?? NO_CONTRACT),
    functionName: 'quote',
    args: enabled ? [marketId as number, amountIn] : undefined,
    query: {enabled},
  })
  const data = query.data as readonly [bigint, bigint, number, boolean, bigint, `0x${string}`] | undefined
  return {
    ...query,
    enabled,
    quote: data
      ? {
          ampsOut: data[0],
          qX18: data[1],
          discountBps: data[2],
          floorBinding: data[3],
          capacityLeft: data[4],
          reason: data[5],
        }
      : undefined,
  }
}

/** Every vesting position the connected account holds. */
export function useBondPositions() {
  const lens = contract('bondsLens')
  const bonds = addressOf('bonds')
  const {address} = useAccount()
  const enabled = lens !== undefined && bonds !== undefined && address !== undefined
  return useReadContract({
    ...(lens ?? NO_CONTRACT),
    functionName: 'positionsOf',
    args: enabled ? [bonds as Address, address as Address] : undefined,
    query: {enabled, refetchInterval: 15_000},
  })
}

/** Totals across every position: purchased, claimed, claimable right now. */
export function useBondTotals() {
  const lens = contract('bondsLens')
  const bonds = addressOf('bonds')
  const {address} = useAccount()
  const enabled = lens !== undefined && bonds !== undefined && address !== undefined
  const query = useReadContract({
    ...(lens ?? NO_CONTRACT),
    functionName: 'positionTotals',
    args: enabled ? [bonds as Address, address as Address] : undefined,
    query: {enabled, refetchInterval: 15_000},
  })
  const data = query.data as readonly [bigint, bigint, bigint] | undefined
  return {...query, totals: data ? {principal: data[0], claimed: data[1], claimableNow: data[2]} : undefined}
}

/** The rolling daily issuance against the global cap. */
export function useDailyIssuance() {
  const bonds = contract('bonds')
  const query = useReadContract({
    ...(bonds ?? NO_CONTRACT),
    functionName: 'dailyIssuance',
    query: {enabled: bonds !== undefined, refetchInterval: 30_000},
  })
  const data = query.data as readonly [bigint, bigint] | undefined
  return {...query, issuance: data ? {issued: data[0], capacity: data[1]} : undefined}
}
