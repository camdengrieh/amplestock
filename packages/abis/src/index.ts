// SPDX-License-Identifier: MIT

/**
 * `@amplestocks/abis` — the typed ABI surface of the Amplestocks contracts.
 *
 * **Entry point.** `packages/abis/src/index.ts`, re-exported as the package's `"."` export. There is no build
 * step: `package.json` points `main`/`types` straight at this file and consumers import it as TypeScript.
 *
 * Everything under `./generated.js` is written by `pnpm --filter @amplestocks/abis generate` and committed. This
 * file adds only what codegen cannot: the name→ABI table, the exported-name union, and the two event helpers the
 * indexer and the keeper both want.
 *
 * ```ts
 * import {ampsVaultAbi, contractAbis, eventAbi} from '@amplestocks/abis'
 * ```
 */
export * from './generated.js'

import {
  ampsAbi,
  ampsBondsAbi,
  ampsBondsLensAbi,
  ampsHookAbi,
  ampsQuoterAbi,
  ampsStakingAbi,
  ampsVaultAbi,
  bondPolicyAbi,
  bountyPotAbi,
  feePolicyAbi,
  feedRegistryAbi,
  ladderPolicyAbi,
  ladderPositionValuerAbi,
  oracleGateAbi,
  poolManagerAbi,
  poolRegistryAbi,
  poolRegistryLensAbi,
  rolloutPolicyAbi,
} from './generated.js'

/**
 * Every contract this package exports, keyed by its Solidity name.
 *
 * `PoolManager` is the odd one out: the ABI is Uniswap v4-core's `IPoolManager`, because nothing in this
 * repository deploys a PoolManager — the indexer subscribes to `Initialize`, `Swap`, `ModifyLiquidity` and
 * `Donate` on the canonical deployment named in `@amplestocks/config`.
 */
export const contractAbis = {
  Amps: ampsAbi,
  AmpsVault: ampsVaultAbi,
  AmpsHook: ampsHookAbi,
  AmpsBonds: ampsBondsAbi,
  AmpsStaking: ampsStakingAbi,
  BountyPot: bountyPotAbi,
  PoolRegistry: poolRegistryAbi,
  PoolRegistryLens: poolRegistryLensAbi,
  AmpsBondsLens: ampsBondsLensAbi,
  OracleGate: oracleGateAbi,
  FeedRegistry: feedRegistryAbi,
  AmpsQuoter: ampsQuoterAbi,
  BondPolicy: bondPolicyAbi,
  FeePolicy: feePolicyAbi,
  LadderPolicy: ladderPolicyAbi,
  RolloutPolicy: rolloutPolicyAbi,
  LadderPositionValuer: ladderPositionValuerAbi,
  PoolManager: poolManagerAbi,
} as const

/** The name of an exported contract. */
export type AmpsContractName = keyof typeof contractAbis

/** Every exported contract name, in the order {@link contractAbis} declares them. */
export const contractNames = Object.keys(contractAbis) as readonly AmpsContractName[]

/**
 * The event entries of an ABI, as their own ABI.
 *
 * viem's `parseEventLogs` and Ponder's event handlers both want an ABI narrowed to events; doing it here keeps
 * the widening to `Abi` in one place instead of one per consumer.
 */
export function eventAbi<const T extends readonly {readonly type: string}[]>(
  abi: T,
): Extract<T[number], {type: 'event'}>[] {
  return abi.filter((item): item is Extract<T[number], {type: 'event'}> => item.type === 'event')
}

/**
 * One ABI item by name, or `undefined`.
 *
 * Deliberately untyped in its return: this is for runtime lookups (metrics labels, log decoding by name), not for
 * building a typed contract call. Use viem's `getAbiItem` when the narrow type matters.
 */
export function abiItem(
  abi: readonly {readonly type: string; readonly name?: string}[],
  name: string,
): {readonly type: string; readonly name?: string} | undefined {
  return abi.find((item) => item.name === name)
}
