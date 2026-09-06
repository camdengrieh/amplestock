// SPDX-License-Identifier: MIT
import {readFileSync} from 'node:fs'
import {dirname, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'
import {describe, expect, it} from 'vitest'
import {toFunctionSelector, toEventSelector, type AbiFunction, type AbiEvent} from 'viem'
import {abiItem, contractAbis, contractNames, eventAbi} from '../src/index.js'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(here, '..', '..', '..')

/**
 * The I14 classification tables, read straight out of `contracts/test/unit/GuardSymmetry.t.sol`.
 *
 * `docs/phase2-state-model.md` §7 makes that file the one place where every external state-changing selector of
 * `AmpsVault` and `AmpsBonds` is named and given a guard class, and `scripts/selector-gate.py` fails CI when the
 * compiled ABI carries a mutating selector the tables do not. This reads the same tables from the other side:
 * if a selector the enumeration classifies is missing from the ABI this package ships, the ABI is stale and
 * every consumer — indexer, dApp, keeper — is building calldata against a contract that no longer exists.
 */
function guardSymmetrySource(): string {
  return readFileSync(resolve(repoRoot, 'contracts/test/unit/GuardSymmetry.t.sol'), 'utf8')
}

/** `_add("<name>", ...)` inside `_buildSelectorTable`: the vault's table. */
function vaultClassifiedNames(source: string): string[] {
  return [...source.matchAll(/_add\(\s*"([A-Za-z_][A-Za-z0-9_]*)"/g)].map((m) => m[1] as string)
}

/** The `selector-gate:AmpsBonds:begin/end` marker block: the bonds tables. */
function bondsClassifiedNames(source: string): string[] {
  const block = /\/\/\s*selector-gate:AmpsBonds:begin([\s\S]*?)\/\/\s*selector-gate:AmpsBonds:end/.exec(source)
  if (block === null) throw new Error('the AmpsBonds selector-gate marker block moved')
  const body = block[1] as string
  // Identifier literals only, and only inside the three `string[N] internal BONDS_*` arrays.
  return [...body.matchAll(/BONDS_[A-Z]+\s*=\s*\[([\s\S]*?)\]/g)].flatMap((array) =>
    [...(array[1] as string).matchAll(/"([A-Za-z_][A-Za-z0-9_]*)"/g)].map((m) => m[1] as string),
  )
}

function functionNames(abi: readonly unknown[]): Set<string> {
  return new Set(
    (abi as AbiFunction[]).filter((item) => item.type === 'function').map((item) => item.name),
  )
}

function mutatingFunctionNames(abi: readonly unknown[]): Set<string> {
  return new Set(
    (abi as AbiFunction[])
      .filter((item) => item.type === 'function')
      .filter((item) => item.stateMutability !== 'view' && item.stateMutability !== 'pure')
      .map((item) => item.name),
  )
}

describe('exported surface', () => {
  it('exports every contract the workspace consumes, and nothing is empty', () => {
    expect(contractNames).toEqual([
      'Amps',
      'AmpsVault',
      'AmpsHook',
      'AmpsBonds',
      'AmpsStaking',
      'BountyPot',
      'PoolRegistry',
      'PoolRegistryLens',
      'AmpsBondsLens',
      'OracleGate',
      'FeedRegistry',
      'AmpsQuoter',
      'BondPolicy',
      'FeePolicy',
      'LadderPolicy',
      'RolloutPolicy',
      'LadderPositionValuer',
      'PoolManager',
    ])
    for (const name of contractNames) {
      expect(contractAbis[name].length, `${name} has a non-empty ABI`).toBeGreaterThan(0)
    }
  })

  it('every ABI item is well formed enough for viem to hash', () => {
    for (const name of contractNames) {
      for (const item of contractAbis[name]) {
        if (item.type === 'function') expect(toFunctionSelector(item as AbiFunction)).toMatch(/^0x[0-9a-f]{8}$/)
        if (item.type === 'event') expect(toEventSelector(item as AbiEvent)).toMatch(/^0x[0-9a-f]{64}$/)
      }
    }
  })
})

describe('I14 selector tables', () => {
  it('the vault ABI carries every selector the enumeration classifies', () => {
    const classified = vaultClassifiedNames(guardSymmetrySource())
    expect(classified.length).toBeGreaterThan(20)

    const exported = functionNames(contractAbis.AmpsVault)
    // `unlockCallback` is classified but is inherited from `IUnlockCallback`; it is still in the ABI.
    const missing = classified.filter((name) => !exported.has(name))
    expect(missing, 'classified vault selectors missing from the exported ABI').toEqual([])
  })

  it('the vault ABI carries no mutating selector the enumeration does not classify', () => {
    const classified = new Set(vaultClassifiedNames(guardSymmetrySource()))
    const unclassified = [...mutatingFunctionNames(contractAbis.AmpsVault)].filter((n) => !classified.has(n))
    expect(unclassified, 'unclassified mutating vault selectors — see scripts/selector-gate.py').toEqual([])
  })

  it('the bonds ABI carries every selector the enumeration classifies, and no other mutator', () => {
    const source = guardSymmetrySource()
    const classified = bondsClassifiedNames(source)
    expect(classified).toContain('bond')
    expect(classified).toContain('claim')
    expect(classified).toContain('setPolicy')

    const exported = functionNames(contractAbis.AmpsBonds)
    expect(classified.filter((name) => !exported.has(name))).toEqual([])

    const known = new Set(classified)
    expect([...mutatingFunctionNames(contractAbis.AmpsBonds)].filter((n) => !known.has(n))).toEqual([])
  })
})

describe('the selectors the keeper and the indexer build against', () => {
  /**
   * Selector table pinned by hand. If `AmpsVault`'s ABI ever moves under one of these names, the hash changes
   * and this fails — which is the point: `apps/keeper` encodes these four calls and nothing else, and a silent
   * signature change would make every keeper transaction revert on an unknown selector.
   */
  const KEEPER_CALLS = {
    'compound(bytes32)': 'AmpsVault',
    'rollout(uint16)': 'AmpsVault',
    'deployBonded(uint16)': 'AmpsVault',
    'checkpoint()': 'AmpsVault',
    'touch()': 'AmpsVault',
  } as const

  it('the five keeper jobs exist with the signatures the keeper encodes', () => {
    for (const [signature, contract] of Object.entries(KEEPER_CALLS)) {
      const name = signature.slice(0, signature.indexOf('('))
      const item = abiItem(contractAbis[contract], name) as AbiFunction | undefined
      expect(item, `${contract}.${name}`).toBeDefined()
      const rebuilt = `${item!.name}(${item!.inputs.map((i) => i.type).join(',')})`
      expect(rebuilt).toBe(signature)
    }
  })

  it('the bounty quote the keeper simulates has the shape BountyPot documents', () => {
    const quote = abiItem(contractAbis.BountyPot, 'quote') as AbiFunction | undefined
    expect(quote).toBeDefined()
    expect(quote!.inputs.map((i) => i.type)).toEqual(['uint256', 'uint256'])
    expect(quote!.outputs.map((o) => o.type)).toEqual(['uint256', 'bytes32'])
    expect(quote!.stateMutability).toBe('view')
  })

  it('the gate reads the keeper gates on are present and view', () => {
    for (const name of ['stateByPool', 'snapshotByPool', 'isPlacementAllowed', 'state']) {
      const item = abiItem(contractAbis.OracleGate, name) as AbiFunction | undefined
      expect(item, `OracleGate.${name}`).toBeDefined()
      expect(item!.stateMutability).toBe('view')
    }
    expect((abiItem(contractAbis.OracleGate, 'poke') as AbiFunction).stateMutability).toBe('nonpayable')
  })

  it('the hook exposes poolState and the RebalanceNeeded event the keeper listens for', () => {
    expect(abiItem(contractAbis.AmpsHook, 'poolState')).toBeDefined()
    const events = eventAbi(contractAbis.AmpsHook).map((e) => e.name)
    expect(events).toContain('RebalanceNeeded')
    expect(events).toContain('HighWaterAdvanced')
    expect(events).toContain('SurgeArmed')
  })

  it('the vault events the indexer subscribes to are all exported', () => {
    const events = eventAbi(contractAbis.AmpsVault).map((e) => e.name)
    for (const name of [
      'Genesis',
      'Redeem',
      'NavCheckpoint',
      'RefCheckpoint',
      'Placement',
      'Compound',
      'Burn',
      'GateChanged',
      'BondedDeposit',
      'VestingMinted',
    ]) {
      expect(events, `AmpsVault.${name}`).toContain(name)
    }
  })

  it('the v4 PoolManager events the indexer filters on are exported', () => {
    const events = eventAbi(contractAbis.PoolManager).map((e) => e.name)
    for (const name of ['Initialize', 'Swap', 'ModifyLiquidity', 'Donate']) {
      expect(events, `IPoolManager.${name}`).toContain(name)
    }
  })

  it('the registry lifecycle events the indexer subscribes to are all exported', () => {
    const events = eventAbi(contractAbis.PoolRegistry).map((e) => e.name)
    for (const name of [
      'ConstituentAdded',
      'ConstituentRetired',
      'ConstituentReinstated',
      'ConstituentReconfigured',
      'ConstituentFrozen',
      'PoolRegistered',
    ]) {
      expect(events, `PoolRegistry.${name}`).toContain(name)
    }
  })

  it('BountyPot emits the payout record the keeper reconciles its bounty against', () => {
    const events = eventAbi(contractAbis.BountyPot).map((e) => e.name)
    expect(events).toContain('BountyPaid')
    expect(events).toContain('PotFunded')
  })
})
