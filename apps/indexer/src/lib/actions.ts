// SPDX-License-Identifier: MIT

/**
 * What a transaction was *doing*.
 *
 * `AmpsVault.Placement` records that a ladder was written but not why — `PlaceParams.reason`
 * (`"genesis"`, `"spokeSeed"`, `"compound"`, `"rollout"`, `"bonded"`) exists in memory and is used
 * to arm the surge, but is not a field of the event. Rather than guess from the shape of the
 * transaction, the indexer reads the four-byte selector of the transaction that produced the log:
 * every keeper and governance path into the vault is a direct external call, so the selector is the
 * reason, exactly.
 *
 * A transaction that reaches the vault through a router, a multicall or a Safe has a selector we do
 * not recognise; those fall back to a shape heuristic over the events the transaction produced,
 * and, failing that, to `unknown`. Nothing downstream treats `unknown` as an error — it is a
 * classification, not a validation.
 *
 * This is also what `keeperJob` is keyed on, so "did the keeper's `compound` actually compound"
 * is answerable from the index alone.
 */

import {ampsBondsAbi, ampsVaultAbi} from '@amplestocks/abis'
import {toFunctionSelector, type Abi, type Hex} from 'viem'

export type VaultAction =
  | 'genesis'
  | 'spokeSeed'
  | 'compound'
  | 'rollout'
  | 'bonded'
  | 'place'
  | 'redeem'
  | 'checkpoint'
  | 'touch'
  | 'withdrawRetiredBids'
  | 'migrate'
  | 'bond'
  | 'claim'
  | 'unknown'

const selectorsOf = (abi: Abi): Map<Hex, string> => {
  const out = new Map<Hex, string>()
  for (const item of abi) {
    if (item.type !== 'function') continue
    const signature = `${item.name}(${item.inputs.map((i) => i.type).join(',')})`
    out.set(toFunctionSelector(signature), item.name)
  }
  return out
}

const VAULT_SELECTORS = selectorsOf(ampsVaultAbi as unknown as Abi)
const BONDS_SELECTORS = selectorsOf(ampsBondsAbi as unknown as Abi)

const VAULT_ACTION_BY_FUNCTION: Readonly<Record<string, VaultAction>> = {
  genesis: 'genesis',
  compound: 'compound',
  rollout: 'rollout',
  deployBonded: 'bonded',
  place: 'place',
  redeemProRata: 'redeem',
  checkpoint: 'checkpoint',
  touch: 'touch',
  withdrawRetiredBids: 'withdrawRetiredBids',
  emergencyMigrate: 'migrate',
  depositBonded: 'bond',
  initializePool: 'spokeSeed',
}

const BONDS_ACTION_BY_FUNCTION: Readonly<Record<string, VaultAction>> = {
  bond: 'bond',
  claim: 'claim',
  claimAll: 'claim',
}

/** The four-byte selector of a transaction's calldata, or `undefined` for a bare transfer. */
export function selectorOf(input: Hex | undefined): Hex | undefined {
  if (input === undefined || input.length < 10) return undefined
  return input.slice(0, 10).toLowerCase() as Hex
}

/** The function name behind a selector, if it is one of ours. */
export function functionNameOf(input: Hex | undefined): string | undefined {
  const selector = selectorOf(input)
  if (selector === undefined) return undefined
  return VAULT_SELECTORS.get(selector) ?? BONDS_SELECTORS.get(selector)
}

export interface ActionShape {
  /** Events the transaction produced, used only when the selector is not one of ours. */
  hasGenesis?: boolean
  hasCompound?: boolean
  hasRedeem?: boolean
  hasBond?: boolean
  hasConstituentAdded?: boolean
  hasEntryWithdrawal?: boolean
  hasSpokeAskPlacement?: boolean
  hasBidPlacement?: boolean
}

/**
 * Classify a transaction. The selector wins whenever it is one of ours; otherwise the shape of the
 * events it produced decides, in the order the plan's call graph makes them distinguishable.
 */
export function classifyAction(input: Hex | undefined, shape: ActionShape = {}): VaultAction {
  const fn = functionNameOf(input)
  if (fn !== undefined) {
    const mapped = VAULT_ACTION_BY_FUNCTION[fn] ?? BONDS_ACTION_BY_FUNCTION[fn]
    if (mapped !== undefined) return mapped
  }
  if (shape.hasGenesis) return 'genesis'
  if (shape.hasCompound) return 'compound'
  if (shape.hasRedeem) return 'redeem'
  if (shape.hasConstituentAdded) return 'spokeSeed'
  if (shape.hasBond) return 'bond'
  if (shape.hasEntryWithdrawal && shape.hasSpokeAskPlacement) return 'rollout'
  if (shape.hasBidPlacement) return 'bonded'
  return 'unknown'
}

/** The keeper-shaped subset: the jobs `apps/keeper` runs and `keeperJob` records the outcome of. */
export const KEEPER_JOBS: readonly VaultAction[] = [
  'compound',
  'rollout',
  'bonded',
  'touch',
  'checkpoint',
  'withdrawRetiredBids',
  'place',
]

export const isKeeperJob = (action: VaultAction): boolean => KEEPER_JOBS.includes(action)
