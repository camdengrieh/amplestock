// SPDX-License-Identifier: MIT
'use client'

import {useReadContract} from 'wagmi'
import type {Address, Hex} from 'viem'

import {contract} from '@/lib/contracts'
import type {PoolQuote} from '@/lib/quoter'

const NO_CONTRACT = {address: undefined as unknown as Address, abi: [] as never}

/** Every registered pool's quote, in the registry's own order. Never reverts. */
export function useAllPoolQuotes() {
  const quoter = contract('quoter')
  const query = useReadContract({
    ...(quoter ?? NO_CONTRACT),
    functionName: 'quoteAll',
    query: {enabled: quoter !== undefined, refetchInterval: 12_000},
  })
  return {...query, quotes: (query.data as readonly PoolQuote[] | undefined) ?? undefined, enabled: quoter !== undefined}
}

/** One pool. An unregistered id comes back zeroed with `poolClass == NONE`, not as a revert. */
export function usePoolQuote(poolId: Hex | undefined) {
  const quoter = contract('quoter')
  const query = useReadContract({
    ...(quoter ?? NO_CONTRACT),
    functionName: 'quotePool',
    args: poolId ? [poolId] : undefined,
    query: {enabled: quoter !== undefined && poolId !== undefined, refetchInterval: 12_000},
  })
  return {...query, quote: query.data as PoolQuote | undefined, enabled: quoter !== undefined}
}

/**
 * The rotation quote, with the credit the caller's own hop 1 will create already applied.
 *
 * The quoter deliberately does not read `IAmpsHook.rotationCredit()`: it is transient storage and
 * always zero from a fresh `eth_call`, so consulting it would make every quote wrong in exactly
 * the direction that matters.
 */
export function useRotationQuote(params: {hop1?: Hex; hop2?: Hex; amountIn?: bigint}) {
  const quoter = contract('quoter')
  const enabled =
    quoter !== undefined && params.hop1 !== undefined && params.hop2 !== undefined && (params.amountIn ?? 0n) > 0n
  const query = useReadContract({
    ...(quoter ?? NO_CONTRACT),
    functionName: 'quoteRotation',
    args: enabled ? [params.hop1 as Hex, params.hop2 as Hex, params.amountIn as bigint] : undefined,
    query: {enabled},
  })
  const data = query.data as readonly [bigint, number, number, bigint] | undefined
  return {
    ...query,
    enabled,
    rotation: data
      ? {amountOut: data[0], hop1FeePips: data[1], hop2FeePips: data[2], creditUsed: data[3]}
      : undefined,
  }
}

/** One bond market's terms. Mirrors `AmpsBonds`' own `min(qMarket, qFloor)`. */
export function useBondQuote(marketId: number | undefined) {
  const quoter = contract('quoter')
  const enabled = quoter !== undefined && marketId !== undefined && marketId > 0
  const query = useReadContract({
    ...(quoter ?? NO_CONTRACT),
    functionName: 'bondQuote',
    args: enabled ? [marketId as number] : undefined,
    query: {enabled},
  })
  const data = query.data as readonly [bigint, number, bigint, boolean, number] | undefined
  return {
    ...query,
    enabled,
    terms: data
      ? {qX18: data[0], discountBps: data[1], capacityLeft: data[2], open: data[3], degraded: data[4]}
      : undefined,
  }
}

/**
 * `AmpsQuoter.quoteExactIn(poolId, zeroForOne, amountIn)` — the amount, on chain.
 *
 * `AmpsQuoter` used to be a fee-and-state view only, which left the output amount to `V4Quoter`
 * off chain. It now walks the curve itself under a bounded gas budget, so a surface can show one
 * number from one contract: the fee it will pay and the amount it will receive, with the same
 * `degraded` discipline over both. A refusal comes back as `refuse == true` with `amountOut == 0`,
 * never as a revert.
 */
export function useExactInQuote(params: {poolId?: Hex; zeroForOne: boolean; amountIn?: bigint}) {
  const quoter = contract('quoter')
  const enabled = quoter !== undefined && params.poolId !== undefined && (params.amountIn ?? 0n) > 0n
  const query = useReadContract({
    ...(quoter ?? NO_CONTRACT),
    functionName: 'quoteExactIn',
    args: enabled ? [params.poolId as Hex, params.zeroForOne, params.amountIn as bigint] : undefined,
    query: {enabled, refetchInterval: 12_000},
  })
  const data = query.data as readonly [bigint, number, boolean, number] | undefined
  return {
    ...query,
    enabled,
    exactIn: data ? {amountOut: data[0], feePips: data[1], refuse: data[2], degraded: data[3]} : undefined,
  }
}

/**
 * `AmpsQuoter.wouldRevert(poolId, zeroForOne, exactInput, amount)` — whether the hook would throw,
 * and why.
 *
 * The rail is the hook's answer rather than the quoter's, and the quoter fails **open**: a hook it
 * cannot read reports `refuse == false` with bit 0 raised. A display path must not invent a
 * refusal, and an execution path must never read a degraded answer as permission to trade.
 */
export function useWouldRevert(params: {poolId?: Hex; zeroForOne: boolean; amountIn?: bigint}) {
  const quoter = contract('quoter')
  const enabled = quoter !== undefined && params.poolId !== undefined
  const query = useReadContract({
    ...(quoter ?? NO_CONTRACT),
    functionName: 'wouldRevert',
    args: enabled ? [params.poolId as Hex, params.zeroForOne, true, params.amountIn ?? 0n] : undefined,
    query: {enabled, refetchInterval: 12_000},
  })
  const data = query.data as readonly [boolean, `0x${string}`, number] | undefined
  return {...query, enabled, verdict: data ? {refuse: data[0], reason: data[1], degraded: data[2]} : undefined}
}
