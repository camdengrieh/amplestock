// SPDX-License-Identifier: MIT

/**
 * The indexer's address book.
 *
 * **Nothing here is hard-coded.** Every protocol address is *deployment state*, so it arrives from
 * one of three places, in this order:
 *
 * 1. an environment variable (the names are exactly the ones
 *    `contracts/script/config/deployments.json` lists under `envOverrides`, so the same shell that
 *    drives a `forge script` run drives the indexer);
 * 2. `AMPS_DEPLOYMENTS`, a path to a `deployments.json` written by the deploy scripts;
 * 3. `@amplestocks/config`, but only for the *reference* addresses that are chain infrastructure
 *    rather than deployment output — the Uniswap v4 PoolManager, WETH9 and USDG on 4663.
 *
 * Anything still unresolved is the zero address, which is a live, safe value: Ponder subscribes to
 * a contract that never emits and the corresponding tables stay empty, instead of the source being
 * dropped and its handlers silently disappearing from the build.
 */

import {readFileSync} from 'node:fs'

import {AMPS_MAINNET_CHAIN_ID, addresses as referenceAddresses} from '@amplestocks/config'
import {getAddress, isAddress, type Address} from 'viem'

export const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as const

/** The contracts the indexer subscribes to, and the env var that overrides each. */
export const ENV_OVERRIDES = {
  timelock: 'AMPS_TIMELOCK',
  guardian: 'AMPS_GUARDIAN',
  creator: 'AMPS_CREATOR',
  teamVestingWallet: 'AMPS_TEAM_VESTING',
  poolManager: 'AMPS_POOL_MANAGER',
  amps: 'AMPS_TOKEN',
  vault: 'AMPS_VAULT',
  registry: 'AMPS_REGISTRY',
  hook: 'AMPS_HOOK',
  bonds: 'AMPS_BONDS',
  staking: 'AMPS_STAKING',
  bountyPot: 'AMPS_BOUNTY_POT',
  feedRegistry: 'AMPS_FEED_REGISTRY',
  oracleGate: 'AMPS_ORACLE_GATE',
  positionValuer: 'AMPS_POSITION_VALUER',
  ladderPolicy: 'AMPS_LADDER_POLICY',
  rolloutPolicy: 'AMPS_ROLLOUT_POLICY',
  feePolicy: 'AMPS_FEE_POLICY',
  bondPolicy: 'AMPS_BOND_POLICY',
  weth9: 'AMPS_WETH9',
  usdg: 'AMPS_USDG',
  stockTokenBeacon: 'AMPS_STOCK_TOKEN_BEACON',
} as const

export type ContractKey = keyof typeof ENV_OVERRIDES

export type AmpsAddressBook = Readonly<Record<ContractKey, Address>>

const normalise = (value: string | undefined, where: string): Address | undefined => {
  if (value === undefined) return undefined
  const trimmed = value.trim()
  if (trimmed === '') return undefined
  if (!isAddress(trimmed)) throw new Error(`[indexer] ${where} is not an address: ${trimmed}`)
  return getAddress(trimmed)
}

/** The shape `contracts/script/config/deployments.json` is written in. */
interface DeploymentsFile {
  chainId?: number
  network?: string
  core?: Partial<Record<ContractKey, string>>
}

const readDeploymentsFile = (path: string | undefined): DeploymentsFile => {
  if (path === undefined || path.trim() === '') return {}
  try {
    return JSON.parse(readFileSync(path, 'utf8')) as DeploymentsFile
  } catch (cause) {
    throw new Error(`[indexer] AMPS_DEPLOYMENTS could not be read: ${path}`, {cause})
  }
}

/**
 * The reference addresses that are *not* deployment output. Only chain 4663 has any; on a testnet
 * or a local anvil every one of them is a fresh deployment and must come from the environment or
 * the deployments file.
 */
const referenceFor = (chainId: number): Partial<Record<ContractKey, Address>> =>
  chainId === AMPS_MAINNET_CHAIN_ID
    ? {
        poolManager: getAddress(referenceAddresses[AMPS_MAINNET_CHAIN_ID].poolManager),
        weth9: getAddress(referenceAddresses[AMPS_MAINNET_CHAIN_ID].weth9),
        usdg: getAddress(referenceAddresses[AMPS_MAINNET_CHAIN_ID].usdg),
        stockTokenBeacon: getAddress(referenceAddresses[AMPS_MAINNET_CHAIN_ID].stockTokenBeacon),
      }
    : {}

export interface ResolveAddressesOptions {
  chainId: number
  env?: NodeJS.ProcessEnv
  /** Injected in tests; production reads `AMPS_DEPLOYMENTS` from `env`. */
  deployments?: DeploymentsFile
}

/** Resolve the whole address book. Never throws on a missing address — that is the zero address. */
export function resolveAddresses(options: ResolveAddressesOptions): AmpsAddressBook {
  const env = options.env ?? process.env
  const file = options.deployments ?? readDeploymentsFile(env.AMPS_DEPLOYMENTS)
  if (file.chainId !== undefined && file.chainId !== 0 && file.chainId !== options.chainId) {
    throw new Error(
      `[indexer] AMPS_DEPLOYMENTS is for chain ${file.chainId} but AMPS_CHAIN_ID is ${options.chainId}`,
    )
  }
  const reference = referenceFor(options.chainId)
  const entries = (Object.keys(ENV_OVERRIDES) as ContractKey[]).map((key) => {
    const fromEnv = normalise(env[ENV_OVERRIDES[key]], ENV_OVERRIDES[key])
    const fromFile = normalise(file.core?.[key], `${key} in AMPS_DEPLOYMENTS`)
    const resolved =
      fromEnv ??
      (fromFile !== undefined && fromFile !== ZERO_ADDRESS ? fromFile : undefined) ??
      reference[key] ??
      ZERO_ADDRESS
    return [key, resolved] as const
  })
  return Object.fromEntries(entries) as AmpsAddressBook
}

/** The contracts that must be known before the indexer can do anything useful. */
export const REQUIRED_FOR_INDEXING: readonly ContractKey[] = [
  'poolManager',
  'amps',
  'vault',
  'registry',
  'hook',
]

/** The keys that are still the zero address, in declaration order. */
export function unresolved(book: AmpsAddressBook): ContractKey[] {
  return (Object.keys(ENV_OVERRIDES) as ContractKey[]).filter((k) => book[k] === ZERO_ADDRESS)
}
