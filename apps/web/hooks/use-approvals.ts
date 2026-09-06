// SPDX-License-Identifier: MIT
'use client'

import {useAccount, useReadContracts} from 'wagmi'
import type {Address} from 'viem'

import {MAX_UINT160, erc20Abi, permit2Abi} from '@/lib/contracts'

/**
 * The two approvals a Universal Router swap needs, and which one is missing.
 *
 * The router pulls the input token through Permit2, so: the ERC-20 must approve Permit2, and
 * Permit2 must approve the router. The second can be a signature; the transaction form is offered
 * because it works with every wallet, including the ones that do not implement EIP-712 typed data
 * the way Permit2 expects.
 */
export function useSwapApprovals(params: {
  token?: Address
  owner?: Address
  permit2?: Address
  router?: Address
  amount: bigint
  /** Native ETH needs no approval at all — the router wraps it. */
  isNative?: boolean
}) {
  const {address} = useAccount()
  const owner = params.owner ?? address
  const enabled =
    !params.isNative &&
    params.token !== undefined &&
    owner !== undefined &&
    params.permit2 !== undefined &&
    params.router !== undefined

  const query = useReadContracts({
    contracts: enabled
      ? ([
          {
            address: params.token as Address,
            abi: erc20Abi,
            functionName: 'allowance',
            args: [owner as Address, params.permit2 as Address],
          },
          {
            address: params.permit2 as Address,
            abi: permit2Abi,
            functionName: 'allowance',
            args: [owner as Address, params.token as Address, params.router as Address],
          },
        ] as const)
      : [],
    query: {enabled},
  })

  const erc20Allowance = query.data?.[0]?.result as bigint | undefined
  const permit2Entry = query.data?.[1]?.result as readonly [bigint, number, number] | undefined
  const permit2Allowance = permit2Entry?.[0]
  const permit2Expiration = permit2Entry?.[1]
  const now = Math.floor(Date.now() / 1000)

  const needsErc20 = enabled && (erc20Allowance ?? 0n) < params.amount
  const needsPermit2 =
    enabled &&
    ((permit2Allowance ?? 0n) < params.amount || (permit2Expiration !== undefined && permit2Expiration <= now))

  return {
    ...query,
    enabled,
    needsErc20,
    needsPermit2,
    erc20Allowance,
    permit2Allowance,
    permit2Expiration,
    /** The approval amount used for both legs: Permit2's own `type(uint160).max`. */
    maxApproval: MAX_UINT160,
  }
}

/** The `approve` call that gives Permit2 the ERC-20 allowance it needs. */
export function erc20ApproveRequest(token: Address, permit2: Address, amount: bigint) {
  return {address: token, abi: erc20Abi, functionName: 'approve' as const, args: [permit2, amount] as const}
}

/** The Permit2 `approve` that lets the Universal Router pull the token. */
export function permit2ApproveRequest(permit2: Address, token: Address, router: Address, amount: bigint, expiration: bigint) {
  return {
    address: permit2,
    abi: permit2Abi,
    functionName: 'approve' as const,
    args: [token, router, amount, Number(expiration)] as const,
  }
}
