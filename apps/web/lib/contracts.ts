// SPDX-License-Identifier: MIT

/**
 * Typed contract handles: an ABI from `@amplestocks/abis` bound to an address from the deployment
 * record.
 *
 * The import is the package's `./generated` subpath rather than its root. The root re-exports with
 * `export * from './generated.js'`, an extension TypeScript rewrites and the bundler does not, so
 * the root entry resolves to an empty module under Turbopack. The subpath is declared in the
 * package's own `exports` map and points straight at the file.
 *
 * `@amplestocks/abis` is generated from the Foundry artefacts and committed, so this file needs no
 * hand-written ABI and cannot drift from the contracts. Every helper returns `undefined` rather
 * than a zero address when the contract is not deployed, which is what stops a surface from
 * issuing reads against `0x0` and rendering the answers as data.
 */

import {
  ampsAbi,
  ampsBondsAbi,
  ampsBondsLensAbi,
  ampsHookAbi,
  ampsQuoterAbi,
  ampsStakingAbi,
  ampsVaultAbi,
  oracleGateAbi,
  poolRegistryAbi,
  poolRegistryLensAbi,
} from '@amplestocks/abis/generated'
import type {Abi, Address} from 'viem'

import {deployment, type AmpsContractKey, type Deployment} from './deployment'

export const abis = {
  amps: ampsAbi,
  vault: ampsVaultAbi,
  quoter: ampsQuoterAbi,
  bonds: ampsBondsAbi,
  bondsLens: ampsBondsLensAbi,
  staking: ampsStakingAbi,
  registry: poolRegistryAbi,
  registryLens: poolRegistryLensAbi,
  hook: ampsHookAbi,
  oracleGate: oracleGateAbi,
} as const satisfies Partial<Record<AmpsContractKey, Abi>>

export type AbiKey = keyof typeof abis

/** Every ABI the error decoder should try, so a revert from any of them is named. */
export const allAbis: readonly Abi[] = Object.values(abis) as unknown as readonly Abi[]

export interface ContractHandle<K extends AbiKey> {
  address: Address
  abi: (typeof abis)[K]
}

/** The handle for a contract, or `undefined` when it is not deployed on this chain. */
export function contract<K extends AbiKey>(key: K, from: Deployment = deployment): ContractHandle<K> | undefined {
  const address = from[key]
  if (!address) return undefined
  return {address, abi: abis[key]}
}

/** The address of a deployed contract, or `undefined`. Never the zero address. */
export function addressOf(key: AmpsContractKey, from: Deployment = deployment): Address | undefined {
  return from[key]
}

/** Minimal ERC-20 surface for balances, allowances and metadata of assets we do not deploy. */
export const erc20Abi = [
  {type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{name: 'account', type: 'address'}], outputs: [{name: '', type: 'uint256'}]},
  {type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint8'}]},
  {type: 'function', name: 'symbol', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'string'}]},
  {type: 'function', name: 'name', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'string'}]},
  {type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint256'}]},
  {
    type: 'function',
    name: 'allowance',
    stateMutability: 'view',
    inputs: [
      {name: 'owner', type: 'address'},
      {name: 'spender', type: 'address'},
    ],
    outputs: [{name: '', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'spender', type: 'address'},
      {name: 'amount', type: 'uint256'},
    ],
    outputs: [{name: '', type: 'bool'}],
  },
] as const

/**
 * Permit2's `allowance` and `approve`.
 *
 * The Universal Router pulls the input token through Permit2, so a swap needs two approvals the
 * first time: the ERC-20 to Permit2, then Permit2 to the router. The second can be a signature
 * instead of a transaction; the UI offers the transaction form because it is the one that works
 * with every wallet, and says which of the two is missing rather than asking twice blindly.
 */
export const permit2Abi = [
  {
    type: 'function',
    name: 'allowance',
    stateMutability: 'view',
    inputs: [
      {name: 'user', type: 'address'},
      {name: 'token', type: 'address'},
      {name: 'spender', type: 'address'},
    ],
    outputs: [
      {name: 'amount', type: 'uint160'},
      {name: 'expiration', type: 'uint48'},
      {name: 'nonce', type: 'uint48'},
    ],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'token', type: 'address'},
      {name: 'spender', type: 'address'},
      {name: 'amount', type: 'uint160'},
      {name: 'expiration', type: 'uint48'},
    ],
    outputs: [],
  },
] as const

/** `type(uint160).max` — the "approve once" amount Permit2 uses. */
export const MAX_UINT160 = (1n << 160n) - 1n
/** `type(uint48).max` — Permit2's "no expiry". */
export const MAX_UINT48 = (1n << 48n) - 1n
export const MAX_UINT256 = (1n << 256n) - 1n
