// SPDX-License-Identifier: MIT
'use client'

import {useReadContract, useReadContracts} from 'wagmi'
import type {Address} from 'viem'

import {contract} from '@/lib/contracts'

/**
 * The vault's checkpoint and the parameters every surface quotes from it.
 *
 * `checkpointData()` is the two-slot NAV/reference snapshot the hook, `AmpsBonds` and `AmpsQuoter`
 * all read. `timestamp` is a staleness bound: a checkpoint older than `CHECKPOINT_MAX_AGE` is
 * refused by every path except redemption, and the Vault surface offers the free `checkpoint()`
 * that refreshes it.
 */
export function useVaultSnapshot() {
  const vault = contract('vault')
  const query = useReadContracts({
    contracts: vault
      ? ([
          {...vault, functionName: 'checkpointData'},
          {...vault, functionName: 'previewNavPerShareX18'},
          {...vault, functionName: 'totalAssetsUsd18'},
          {...vault, functionName: 'inventoryAmps'},
          {...vault, functionName: 'redeemFeeBps'},
          {...vault, functionName: 'burnBps'},
          {...vault, functionName: 'stakerBps'},
          {...vault, functionName: 'genesisTimestamp'},
          {...vault, functionName: 'liveCells'},
          {...vault, functionName: 'initialized'},
        ] as const)
      : [],
    query: {enabled: vault !== undefined},
  })

  return {
    ...query,
    enabled: vault !== undefined,
  }
}

/** `previewRedeem(shares)` — balances only, no oracle, no gate, never reverts for a live vault. */
export function usePreviewRedeem(shares: bigint | undefined) {
  const vault = contract('vault')
  return useReadContract({
    ...(vault ?? {address: undefined as unknown as Address, abi: [] as never}),
    functionName: 'previewRedeem',
    args: shares !== undefined ? [shares] : undefined,
    query: {enabled: vault !== undefined && shares !== undefined && shares > 0n},
  })
}

/** The creator fee in force now: 100 bp decaying linearly to exactly zero at day 30. */
export function useCreatorBps(timestamp: number) {
  const vault = contract('vault')
  return useReadContract({
    ...(vault ?? {address: undefined as unknown as Address, abi: [] as never}),
    functionName: 'creatorBpsAt',
    args: [BigInt(timestamp)],
    query: {enabled: vault !== undefined},
  })
}
