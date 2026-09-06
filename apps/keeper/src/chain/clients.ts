// SPDX-License-Identifier: MIT

/**
 * viem clients, and the chain definition they use.
 *
 * `viem/chains` ships `robinhood` for 4663; the testnet and any local chain are built from
 * `@amplestocks/config`, so no endpoint is ever a literal in a code path.
 */

import {createPublicClient, defineChain, http, type Chain, type PublicClient} from 'viem'
import {chainById} from '@amplestocks/config'
import type {KeeperConfig} from '../config.js'

/** Builds a viem `Chain` for whatever the keeper is pointed at, including a local anvil. */
export function resolveChain(config: KeeperConfig): Chain {
  const known = (chainById as Record<number, {name: string; nativeCurrency: {name: string; symbol: string; decimals: number}; blockExplorers: readonly {name: string; url: string}[]} | undefined>)[
    config.chainId
  ]
  return defineChain({
    id: config.chainId,
    name: known?.name ?? `chain-${config.chainId}`,
    nativeCurrency: known?.nativeCurrency ?? {name: 'Ether', symbol: 'ETH', decimals: 18},
    rpcUrls: {default: {http: [config.rpcUrl]}},
    ...(known?.blockExplorers?.[0] === undefined
      ? {}
      : {blockExplorers: {default: {name: known.blockExplorers[0].name, url: known.blockExplorers[0].url}}}),
  })
}

/**
 * The read client.
 *
 * JSON-RPC batching is on and multicall is off: `Multicall3` is canonical on 4663 but is not guaranteed on a
 * fixture chain, and one batched HTTP request per scan is the same round-trip saving without the dependency.
 */
export function createReadClient(config: KeeperConfig): PublicClient {
  return createPublicClient({
    chain: resolveChain(config),
    transport: http(config.rpcUrl, {batch: {wait: 8}, retryCount: 3, retryDelay: 250}),
    batch: {multicall: false},
  }) as PublicClient
}
