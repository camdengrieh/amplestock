// SPDX-License-Identifier: MIT
'use client'

import {useAccount, useReadContracts} from 'wagmi'

import {contract} from '@/lib/contracts'
import {ZERO_ADDRESS} from '@/lib/protocol'

/**
 * xAMPS.
 *
 * ERC-4626 over AMPS with a decimals offset of 3, `notifyReward` callable only by the vault, and
 * rewards streamed linearly over `rewardStreamSeconds`. There is no lock and there is no emission:
 * the only thing that ever enters is a share of sell fees that have already been collected.
 */
export function useStaking() {
  const staking = contract('staking')
  const {address} = useAccount()
  const query = useReadContracts({
    contracts: staking
      ? [
          {...staking, functionName: 'totalAssets'},
          {...staking, functionName: 'totalSupply'},
          {...staking, functionName: 'pendingRewards'},
          {...staking, functionName: 'releasedRewards'},
          {...staking, functionName: 'streamEnd'},
          {...staking, functionName: 'streamSecondsRemaining'},
          {...staking, functionName: 'rewardStreamSeconds'},
          {...staking, functionName: 'totalNotified'},
          {...staking, functionName: 'balanceOf', args: [address ?? ZERO_ADDRESS]},
        ]
      : [],
    query: {enabled: staking !== undefined, refetchInterval: 20_000},
  })
  return {...query, enabled: staking !== undefined, hasAccount: address !== undefined}
}
