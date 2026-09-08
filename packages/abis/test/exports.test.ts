// SPDX-License-Identifier: MIT
import {readFileSync} from 'node:fs'
import {dirname, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'
import {describe, expect, it} from 'vitest'
import {toFunctionSelector, toEventSelector, type AbiFunction, type AbiEvent} from 'viem'
import * as abis from '../src/index.js'
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
      'AmpsRouter',
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

describe('the revision-6 fee model', () => {
  /**
   * The hook charges `ampsFeeBps` on both directions of every pool, and the pass-through base fee applies only
   * to a hop `AmpsRouter.rotate` declares. A quote therefore has to say *which* of the two it is pricing, which
   * is the fifth argument. A consumer that builds `quoteFee` calldata without it is quoting the wrong fee.
   *
   * A four-argument overload is still on the hook while the contracts wave that removes it lands, so this pins
   * the arity that must exist rather than the arity that must not.
   */
  it('the hook quotes a fee that knows whether the hop is pass-through', () => {
    const overloads = (contractAbis.AmpsHook as readonly AbiFunction[]).filter(
      (item) => item.type === 'function' && item.name === 'quoteFee',
    )
    const five = overloads.find((item) => item.inputs.length === 5)
    expect(five, 'quoteFee(bytes32,bool,bool,uint256,bool)').toBeDefined()
    expect(five!.inputs.map((i) => `${i.type} ${i.name ?? ''}`)).toEqual([
      'bytes32 poolId',
      'bool zeroForOne',
      'bool exactInput',
      'uint256 amountIn',
      'bool passThrough',
    ])
    expect(five!.stateMutability).toBe('view')
  })

  /**
   * The pass-through exemption is bound to one contract rather than to a property of the swap, so the hook has
   * to name it, governance has to be able to move it, and the indexer has to be able to see it move.
   */
  it('the hook names the router, lets governance move it, and logs the move', () => {
    const router = abiItem(contractAbis.AmpsHook, 'router') as AbiFunction | undefined
    expect(router).toBeDefined()
    expect(router!.inputs).toEqual([])
    expect(router!.outputs.map((o) => o.type)).toEqual(['address'])
    expect(router!.stateMutability).toBe('view')

    const setRouter = abiItem(contractAbis.AmpsHook, 'setRouter') as AbiFunction | undefined
    expect(setRouter).toBeDefined()
    expect(setRouter!.inputs.map((i) => i.type)).toEqual(['address'])
    expect(setRouter!.stateMutability).toBe('nonpayable')

    const changed = eventAbi(contractAbis.AmpsHook).find((e) => e.name === 'RouterChanged')
    expect(changed?.inputs.map((i) => `${i.type} ${i.name ?? ''}`)).toEqual([
      'address previousRouter',
      'address newRouter',
    ])
  })

  /** The transient rotation credit, read per sender. `AmpsQuoter` simulates it; nothing else may guess at it. */
  it('the hook exposes the rotation credit by sender', () => {
    const credit = abiItem(contractAbis.AmpsHook, 'rotationCredit') as AbiFunction | undefined
    expect(credit).toBeDefined()
    expect(credit!.inputs.map((i) => i.type)).toEqual(['address'])
    expect(credit!.outputs.map((o) => o.type)).toEqual(['uint256'])
    expect(credit!.stateMutability).toBe('view')
  })

  /**
   * `Compound` is the whole revision-6 split in one log, and the indexer reconstructs the flywheel from it:
   * fees in both currencies, what the creator took in each, and the AMPS burned (the fee remainder plus the
   * buyback). There is no staker slice and no re-laid amount, because neither exists.
   */
  it('Compound carries both currencies, both creator payouts and the burn', () => {
    const compound = eventAbi(contractAbis.AmpsVault).find((e) => e.name === 'Compound')
    expect(compound?.inputs.map((i) => `${i.type} ${i.name ?? ''}`)).toEqual([
      'bytes32 poolId',
      'uint256 ampsFees',
      'uint256 counterFees',
      'uint256 creatorAmps',
      'uint256 creatorCounter',
      'uint256 burned',
    ])
    expect(compound?.inputs[0]?.indexed).toBe(true)
  })

  /** The router itself: the three trades, and the three logs the indexer indexes rotations from. */
  it('exports the router, with its trades and its logs', () => {
    expect(abis.ampsRouterAbi).toBeDefined()
    expect(contractAbis.AmpsRouter).toBe(abis.ampsRouterAbi)
    for (const name of ['buy', 'sell', 'rotate', 'poolManager', 'amps', 'registry', 'weth', 'ROTATE_FLAG']) {
      expect(abiItem(contractAbis.AmpsRouter, name), `AmpsRouter.${name}`).toBeDefined()
    }
    const rotate = abiItem(contractAbis.AmpsRouter, 'rotate') as AbiFunction
    expect(rotate.inputs.map((i) => i.type)).toEqual([
      'bytes32',
      'bytes32',
      'uint256',
      'uint256',
      'address',
      'bool',
      'uint256',
    ])
    expect(rotate.outputs.map((o) => o.name)).toEqual(['amountOut', 'ampsThrough'])

    const events = eventAbi(contractAbis.AmpsRouter).map((e) => e.name)
    expect(events).toEqual(expect.arrayContaining(['Bought', 'Sold', 'Rotated']))
    const rotated = eventAbi(contractAbis.AmpsRouter).find((e) => e.name === 'Rotated')
    expect(rotated?.inputs.map((i) => `${i.type} ${i.name ?? ''}`)).toEqual([
      'bytes32 hop1',
      'bytes32 hop2',
      'address to',
      'uint256 amountIn',
      'uint256 ampsThrough',
      'uint256 amountOut',
    ])
  })

  /**
   * Staking is gone, and an ABI that still carried it would let a consumer compile calldata for a contract that
   * is not deployed. This is the negative half of the export set: no `ampsStakingAbi`, no `AmpsStaking` entry,
   * and no `staking` pointer, `stakerBps` or `burnBps` on any exported contract.
   */
  it('carries no trace of staking on any exported contract', () => {
    expect(Object.keys(abis)).not.toContain('ampsStakingAbi')
    expect(contractNames).not.toContain('AmpsStaking' as never)
    expect(Object.keys(contractAbis)).not.toContain('AmpsStaking')

    for (const name of contractNames) {
      for (const forbidden of ['staking', 'stakerBps', 'burnBps']) {
        expect(abiItem(contractAbis[name], forbidden), `${name}.${forbidden}`).toBeUndefined()
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
    // The pre-audit slice's placement clock. The keeper reads it per pool every scan; before it existed the
    // clock had to be reconstructed from `ladderAt(...).placedAt` and corrected from a revert.
    'lastPlacementAt(bytes32)': 'AmpsVault',
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

    // The keeper decodes this one out of a simulated and a confirmed transaction, so its shape is load-bearing:
    // the work value the vault measured, what the pot paid, and which constraint bound it.
    const paid = eventAbi(contractAbis.BountyPot).find((e) => e.name === 'BountyPaid')
    expect(paid?.inputs.map((i) => `${i.type} ${i.name ?? ''}`)).toEqual([
      'address to',
      'uint256 workValueUsd18',
      'uint256 paidUsd18',
      'uint256 paidRaw',
      'bytes32 reason',
    ])
  })

  it('the vault events the keeper decodes off a receipt carry what it needs', () => {
    // `Placement` names exactly the pools the vault stamped `_lastPlacementAt` for, which is how the keeper
    // knows a `rollout` put the two entry pools on cooldown as well as its destination spoke.
    const placement = eventAbi(contractAbis.AmpsVault).find((e) => e.name === 'Placement')
    const names = placement?.inputs.map((i) => i.name)
    expect(names).toContain('poolId')
    expect(names).toContain('reason')
    expect(names).toContain('lowerTick')
    expect(names).toContain('upperTick')

    const rollout = eventAbi(contractAbis.AmpsVault).find((e) => e.name === 'Rollout')
    expect(rollout?.inputs.map((i) => i.name)).toEqual(['constituentId', 'poolId', 'movedAmps', 'placedAmps'])

    expect(eventAbi(contractAbis.PoolRegistry).map((e) => e.name)).toContain('PoolGridSet')
  })
})
