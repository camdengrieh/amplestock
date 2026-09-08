// SPDX-License-Identifier: MIT
'use client'

import {useReadContract, useReadContracts} from 'wagmi'

import {contract} from '@/lib/contracts'
import {ZERO_ADDRESS} from '@/lib/protocol'

/**
 * The AMPS fee and its band, live from `AmpsHook`.
 *
 * The band is the point. `AMPS_FEE_BPS_MIN` / `AMPS_FEE_BPS_MAX` are `pure` functions on the hook —
 * they are the constants compiled into the bytecode, not governed state — so reading them is how
 * the interface can say "governance can move this, and only this far" without hardcoding the
 * numbers it is claiming are hardcoded.
 *
 * `ampsFeeBps` is the base fee on **both** directions of every pool. There is no second getter for
 * the buy side, because there is no second fee: the pool's own `buyFeeBps` is the pass-through
 * base, which only `AmpsRouter.rotate` can reach.
 */
export function useAmpsFee() {
  const hook = contract('hook')
  const query = useReadContracts({
    contracts: hook
      ? ([
          {...hook, functionName: 'ampsFeeBps'},
          {...hook, functionName: 'AMPS_FEE_BPS_MIN'},
          {...hook, functionName: 'AMPS_FEE_BPS_MAX'},
          {...hook, functionName: 'TOTAL_FEE_BPS_MAX'},
        ] as const)
      : [],
    query: {enabled: hook !== undefined, refetchInterval: 30_000},
  })

  const at = (i: number): number | undefined => {
    const entry = query.data?.[i]
    if (!entry || entry.status !== 'success' || entry.result === undefined) return undefined
    return Number(entry.result as bigint | number)
  }

  const min = at(1)
  const max = at(2)

  return {
    ...query,
    enabled: hook !== undefined,
    /** The live AMPS fee in bps, charged on both sides of every pool. */
    ampsFeeBps: at(0),
    /** The band hardcoded in the hook. `null` when the hook could not be read — never a guess. */
    band: min !== undefined && max !== undefined ? {min, max} : null,
    /** The absolute ceiling on base + dynamic, also hardcoded. */
    totalFeeBpsMax: at(3),
  }
}

/** The pool-level base fee the registry stored, and the pool's own class. */
export function usePoolBaseFee(poolId: `0x${string}` | undefined) {
  const hook = contract('hook')
  const enabled = hook !== undefined && poolId !== undefined
  const query = useReadContracts({
    contracts: enabled ? ([{...hook, functionName: 'buyFeeBps', args: [poolId]}] as const) : [],
    query: {enabled},
  })
  const entry = query.data?.[0]
  const baseBps = entry?.status === 'success' && entry.result !== undefined ? Number(entry.result) : undefined
  return {...query, enabled, baseBps}
}

/**
 * The base-fee bands the registry enforces, per pool class.
 *
 * `pure` on `PoolRegistry`, so these are the compiled constants rather than a mirror of them.
 */
export function usePoolFeeBands() {
  const registry = contract('registry')
  const query = useReadContracts({
    contracts: registry
      ? ([
          {...registry, functionName: 'BUY_FEE_BPS_ENTRY_MIN'},
          {...registry, functionName: 'BUY_FEE_BPS_ENTRY_MAX'},
          {...registry, functionName: 'BUY_FEE_BPS_SPOKE_MIN'},
          {...registry, functionName: 'BUY_FEE_BPS_SPOKE_MAX'},
          {...registry, functionName: 'MAX_CONSTITUENTS'},
        ] as const)
      : [],
    query: {enabled: registry !== undefined},
  })
  const at = (i: number): number | undefined => {
    const entry = query.data?.[i]
    if (!entry || entry.status !== 'success' || entry.result === undefined) return undefined
    return Number(entry.result as bigint | number)
  }
  const entryMin = at(0)
  const entryMax = at(1)
  const spokeMin = at(2)
  const spokeMax = at(3)
  return {
    ...query,
    enabled: registry !== undefined,
    entryBand: entryMin !== undefined && entryMax !== undefined ? {min: entryMin, max: entryMax} : null,
    spokeBand: spokeMin !== undefined && spokeMax !== undefined ? {min: spokeMin, max: spokeMax} : null,
    maxConstituents: at(4),
  }
}

/**
 * The router pointer the hook honours, live.
 *
 * This is the whole of the pass-through exemption: a hop is priced at the pool's `buyFeeBps` only
 * when the PoolManager reports `sender == AmpsHook.router()` **and** the hop carries
 * `Constants.ROUTER_ROTATE`. The Rotate surface compares it against the address it is about to
 * call, so a router that has been replaced or withdrawn is visible before a transaction is signed
 * rather than after it has paid the AMPS fee twice.
 *
 * `setRouter` is a 7-day timelock class — the same class as the fee policy, because it moves the
 * same lever — and `address(0)` is a legitimate setting: it withdraws the exemption entirely and
 * every swap then pays `ampsFeeBps`.
 */
export function useHookRouter() {
  const hook = contract('hook')
  const query = useReadContract({
    ...(hook ?? {address: undefined as unknown as `0x${string}`, abi: [] as never}),
    functionName: 'router',
    query: {enabled: hook !== undefined, refetchInterval: 60_000},
  })
  const raw = query.data as `0x${string}` | undefined
  return {
    ...query,
    enabled: hook !== undefined,
    /** The address the hook honours, or `undefined` when the read failed. */
    router: raw,
    /** True when the hook honours no router at all, so nothing can be priced pass-through. */
    exemptionWithdrawn: raw !== undefined && raw.toLowerCase() === ZERO_ADDRESS,
  }
}
