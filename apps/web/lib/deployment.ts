// SPDX-License-Identifier: MIT

/**
 * The address book the dApp reads.
 *
 * Two halves, and the split is deliberate:
 *
 * - **Reference addresses** — PoolManager, UniversalRouter, Permit2, WETH9, USDG, USDC, the Across
 *   SpokePool, the stock-token beacon — come from `@amplestocks/config`, which is the single source
 *   of truth for them and which Phase 0 re-verifies on chain. They are never written down here.
 * - **Deployment addresses** — the Amplestocks contracts themselves — come from the environment,
 *   because they do not exist yet: nothing has been deployed, `@amplestocks/config` has no slot for
 *   them, and inventing one would put a zero address in the repository that looks like data. When
 *   the Phase 6 scripts deploy, these become `.env` values (or a `packages/config` deployment
 *   record, if the orchestrator would rather they live there — that is a one-line change here).
 *
 * A missing deployment address is not an error and never a zero-address read: `isDeployed` is
 * false and the surface renders its "not deployed on this chain" state.
 */

import {AMPS_MAINNET_CHAIN_ID, addresses as referenceAddresses, chainById, type AmpsChainId} from '@amplestocks/config'
import {isAddress, type Address} from 'viem'

import {publicEnv} from './env'

export type AmpsContractKey =
  | 'amps'
  | 'vault'
  | 'quoter'
  | 'bonds'
  | 'bondsLens'
  | 'router'
  | 'registry'
  | 'registryLens'
  | 'hook'
  | 'oracleGate'
  | 'timelock'
  | 'genesis'

export type Deployment = Readonly<Partial<Record<AmpsContractKey, Address>>>

function parse(value: string): Address | undefined {
  return isAddress(value) ? (value as Address) : undefined
}

/** The deployment as configured. Keys with no valid address are simply absent. */
export function readDeployment(env = publicEnv.addresses): Deployment {
  const out: Partial<Record<AmpsContractKey, Address>> = {}
  for (const key of Object.keys(env) as AmpsContractKey[]) {
    const parsed = parse(env[key] ?? '')
    if (parsed) out[key] = parsed
  }
  return out
}

export const deployment: Deployment = readDeployment()

/**
 * The genesis auctions.
 *
 * Two Continuous Clearing Auctions sell the 10,000-AMPS auction tranche: one against USDG and one
 * against native ETH (`currency == address(0)`). They are kept out of {Deployment} because they are
 * not part of the running protocol *and have no ABI in `@amplestocks/abis`* — they are Uniswap's
 * contracts, deployed by a factory, and every surface other than `/auction` should be unable to
 * reach for them by accident. A key with no valid address is simply absent, and the surface renders
 * the same "not deployed on this chain" state every other address gets.
 *
 * `AmpsGenesis` is **not** here: it is ours, it is the vault's own `genesis` pointer, and it is
 * reached through {contract}(`'genesis'`) like every other Amplestocks contract. The adapter is
 * what turns these two auctions into a launch — it sweeps both legs, derives `P0` and calls
 * `AmpsVault.genesisPlace` — so the Settlement panel reads it rather than adding up the auctions.
 */
export type GenesisAuctionKey = 'usdg' | 'eth'
export type GenesisAuctions = Readonly<Partial<Record<GenesisAuctionKey, Address>>>

export function readGenesisAuctions(env = publicEnv.auctions): GenesisAuctions {
  const out: Partial<Record<GenesisAuctionKey, Address>> = {}
  for (const key of Object.keys(env) as GenesisAuctionKey[]) {
    const parsed = parse(env[key] ?? '')
    if (parsed) out[key] = parsed
  }
  return out
}

export const genesisAuctions: GenesisAuctions = readGenesisAuctions()

export function hasAnyGenesisAuction(from: GenesisAuctions = genesisAuctions): boolean {
  return Object.keys(from).length > 0
}

export function isDeployed(key: AmpsContractKey, from: Deployment = deployment): boolean {
  return from[key] !== undefined
}

/** Every contract a surface needs before it can read anything at all. */
export const requiredForReads: readonly AmpsContractKey[] = ['vault', 'quoter', 'registry']

export function deploymentReady(from: Deployment = deployment): boolean {
  return requiredForReads.every((key) => from[key] !== undefined)
}

/**
 * Reference addresses for a chain. `@amplestocks/config` deliberately holds a book for 4663 only —
 * a half-filled testnet book invites a deploy against the wrong PoolManager — so 46630 returns
 * `null` and every consumer has to handle it rather than silently borrowing mainnet's.
 */
export function referenceBook(chainId: AmpsChainId) {
  return chainId === AMPS_MAINNET_CHAIN_ID ? referenceAddresses[AMPS_MAINNET_CHAIN_ID] : null
}

export function explorerTxUrl(chainId: AmpsChainId, hash: string): string | null {
  const explorer = chainById[chainId]?.blockExplorers[0]
  return explorer ? `${explorer.url}/tx/${hash}` : null
}

export function explorerAddressUrl(chainId: AmpsChainId, address: string): string | null {
  const explorer = chainById[chainId]?.blockExplorers[0]
  return explorer ? `${explorer.url}/address/${address}` : null
}
