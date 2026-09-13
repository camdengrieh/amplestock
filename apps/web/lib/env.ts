// SPDX-License-Identifier: MIT

/**
 * Environment reading, in one place, with no `process.env` access anywhere else in the client
 * bundle.
 *
 * Next inlines `process.env.NEXT_PUBLIC_*` at build time only when the property is written out in
 * full, so every read below is spelled literally rather than indexed.
 */

import {AMPS_MAINNET_CHAIN_ID, AMPS_TESTNET_CHAIN_ID, type AmpsChainId} from '@amplestocks/config'

function str(value: string | undefined): string {
  return (value ?? '').trim()
}

function flag(value: string | undefined): boolean {
  const v = str(value).toLowerCase()
  return v === '1' || v === 'true' || v === 'yes' || v === 'on'
}

export const publicEnv = {
  chainId: str(process.env.NEXT_PUBLIC_AMPS_CHAIN_ID),
  rpcUrl: str(process.env.NEXT_PUBLIC_AMPS_RPC_URL),
  reownProjectId: str(process.env.NEXT_PUBLIC_REOWN_PROJECT_ID),
  indexerUrl: str(process.env.NEXT_PUBLIC_AMPS_INDEXER_URL),
  addresses: {
    amps: str(process.env.NEXT_PUBLIC_AMPS_TOKEN),
    vault: str(process.env.NEXT_PUBLIC_AMPS_VAULT),
    quoter: str(process.env.NEXT_PUBLIC_AMPS_QUOTER),
    bonds: str(process.env.NEXT_PUBLIC_AMPS_BONDS),
    bondsLens: str(process.env.NEXT_PUBLIC_AMPS_BONDS_LENS),
    router: str(process.env.NEXT_PUBLIC_AMPS_ROUTER),
    registry: str(process.env.NEXT_PUBLIC_AMPS_REGISTRY),
    registryLens: str(process.env.NEXT_PUBLIC_AMPS_REGISTRY_LENS),
    hook: str(process.env.NEXT_PUBLIC_AMPS_HOOK),
    oracleGate: str(process.env.NEXT_PUBLIC_AMPS_ORACLE_GATE),
    timelock: str(process.env.NEXT_PUBLIC_AMPS_TIMELOCK),
    /**
     * `AmpsGenesis`, the genesis adapter. It sits with the protocol contracts rather than with the
     * auctions below because it is the vault's own set-once `genesis` pointer, it has a generated
     * ABI, and its errors belong in the decoder — but it is one-shot like the auctions, and once
     * `settled()` is true nothing on the site reads it except the Auction surface's record of what
     * the launch decided.
     */
    genesis: str(process.env.NEXT_PUBLIC_AMPS_GENESIS),
  },
  /**
   * The genesis Continuous Clearing Auctions. Separate from `addresses` because they are not part
   * of the running protocol: they exist once, sell the 10,000-AMPS auction tranche, and are then finished.
   */
  auctions: {
    usdg: str(process.env.NEXT_PUBLIC_AMPS_AUCTION_USDG),
    eth: str(process.env.NEXT_PUBLIC_AMPS_AUCTION_ETH),
  },
  flags: {
    acrossZap: flag(process.env.NEXT_PUBLIC_FLAG_ACROSS_ZAP),
    testnetBanner: flag(process.env.NEXT_PUBLIC_FLAG_TESTNET_BANNER),
  },
} as const

/** The chain the app is configured for. Testnet is the default: mainnet is not deployed. */
export function configuredChainId(raw: string = publicEnv.chainId): AmpsChainId {
  const parsed = Number(raw)
  return parsed === AMPS_MAINNET_CHAIN_ID ? AMPS_MAINNET_CHAIN_ID : AMPS_TESTNET_CHAIN_ID
}
