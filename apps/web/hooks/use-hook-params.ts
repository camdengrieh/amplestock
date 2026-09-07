// SPDX-License-Identifier: MIT
'use client'

import {useReadContracts} from 'wagmi'

import {contract} from '@/lib/contracts'
import {AMPS_FEE_FUNCTION, AMPS_FEE_MAX_FUNCTION, AMPS_FEE_MIN_FUNCTION} from '@/lib/fees'

/**
 * The AMPS fee and its band, live from `AmpsHook`.
 *
 * The band is the point. `AMPS_FEE_BPS_MIN` / `AMPS_FEE_BPS_MAX` are `pure` functions on the hook —
 * they are the constants compiled into the bytecode, not governed state — so reading them is how
 * the interface can say "governance can move this, and only this far" without hardcoding the
 * numbers it is claiming are hardcoded.
 *
 * The three function names come from `lib/fees.ts` rather than being spelled here, because on chain
 * the fee is still called the sell fee. Revision 6 charges it in both directions and the rename is
 * pending; when it lands, three lines in `lib/fees.ts` change and this file does not.
 */
export function useAmpsFee() {
  const hook = contract('hook')
  const query = useReadContracts({
    contracts: hook
      ? ([
          {...hook, functionName: AMPS_FEE_FUNCTION},
          {...hook, functionName: AMPS_FEE_MIN_FUNCTION},
          {...hook, functionName: AMPS_FEE_MAX_FUNCTION},
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
