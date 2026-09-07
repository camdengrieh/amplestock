// SPDX-License-Identifier: MIT

/**
 * Chains.
 *
 * viem ships `robinhood` (4663) and `robinhoodTestnet` (46630) as built-in chains, so the app uses
 * those rather than defining its own — one fewer place for an RPC URL or a chain id to drift.
 * `@amplestocks/config` remains the authority for everything *about* the chain that viem does not
 * carry: the ArbOS version, the websocket endpoint, the faucet, and the fact that EIP-7702 is live
 * (so `tx.origin` is not an EOA check) and EIP-1153 transient storage is available (which is what
 * the rotation credit is built on).
 */

import {AMPS_MAINNET_CHAIN_ID, AMPS_TESTNET_CHAIN_ID, chainById, type AmpsChainId} from '@amplestocks/config'
import {robinhood, robinhoodTestnet} from 'viem/chains'
import type {Chain} from 'viem'

import {configuredChainId, publicEnv} from './env'

export const viemChains: Readonly<Record<AmpsChainId, Chain>> = {
  [AMPS_MAINNET_CHAIN_ID]: robinhood,
  [AMPS_TESTNET_CHAIN_ID]: robinhoodTestnet,
}

export const activeChainId: AmpsChainId = configuredChainId()

export function chainFor(chainId: AmpsChainId): Chain {
  return viemChains[chainId]
}

export const activeChain: Chain = chainFor(activeChainId)

/** The RPC the app dials: an explicit override, else the chain's own public endpoint. */
export function rpcUrlFor(chainId: AmpsChainId, override = publicEnv.rpcUrl): string {
  if (override !== '') return override
  const fromConfig = chainById[chainId]?.rpcUrls.http[0]
  return fromConfig ?? viemChains[chainId].rpcUrls.default.http[0] ?? ''
}

export function isTestnet(chainId: AmpsChainId = activeChainId): boolean {
  return chainId === AMPS_TESTNET_CHAIN_ID
}

export const chainMeta = chainById

/**
 * Seconds per block, for turning an auction's start/end/claim block into a time.
 *
 * viem carries this on the chain object and `@amplestocks/config` does not — the split this module
 * already documents, applied to one more field. A chain that publishes no block time returns
 * `undefined`, and the surface shows block numbers with the time marked unavailable rather than
 * assuming a rate.
 */
export function blockTimeSeconds(chainId: AmpsChainId = activeChainId): number | undefined {
  const ms = viemChains[chainId].blockTime
  return typeof ms === 'number' && ms > 0 ? ms / 1000 : undefined
}
