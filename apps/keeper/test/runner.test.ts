// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'
import type {PublicClient} from 'viem'
import {Runner} from '../src/runner.js'
import {ChainReader, type Topology} from '../src/chain/reader.js'
import {DEFAULT_POLICY} from '../src/domain/policy.js'
import {GateState, type ChainSnapshot} from '../src/domain/types.js'
import {createLogger} from '../src/logger.js'
import {createMetrics} from '../src/metrics.js'
import type {Submission, Submitter, TxRequest} from '../src/chain/submitter.js'
import {WAD} from '../src/domain/bounty.js'
import {constituent, NOW, pool, snapshot as baseSnapshot, vault} from './helpers.js'

const AMPS = '0x00000000000000000000000000000000000000a1' as const
const VAULT = '0x00000000000000000000000000000000000000a0' as const

const TOPOLOGY: Topology = {
  amps: AMPS,
  vault: VAULT,
  registry: '0x00000000000000000000000000000000000000r0'.replace(/r/g, '1') as `0x${string}`,
  bonds: '0x00000000000000000000000000000000000000b1',
  staking: '0x00000000000000000000000000000000000000b2',
  bountyPot: '0x00000000000000000000000000000000000000b3',
  oracleGate: '0x00000000000000000000000000000000000000b4',
  hook: '0x00000000000000000000000000000000000000b5',
  poolManager: '0x00000000000000000000000000000000000000b6',
  feedRegistry: '0x00000000000000000000000000000000000000b7',
}

/** A reader that answers from a scripted queue of snapshots. */
function fakeReader(snapshots: ChainSnapshot[], topology: Topology = TOPOLOGY): ChainReader {
  let index = 0
  return {
    topology: async () => topology,
    poolIds: async () => (snapshots[Math.min(index, snapshots.length - 1)] as ChainSnapshot).pools.map((p) => p.poolId),
    seedLastPlacementAt: async () => new Map<string, number>(),
    // Faithful to `ChainReader.snapshot`: the runner's cooldown map is what fills `pool.lastPlacementAt`.
    snapshot: async (_t: Topology, lastPlacementAt: ReadonlyMap<string, number>) => {
      const next = snapshots[Math.min(index, snapshots.length - 1)] as ChainSnapshot
      index += 1
      return {
        ...next,
        pools: next.pools.map((p) => ({...p, lastPlacementAt: lastPlacementAt.get(p.poolId) ?? p.lastPlacementAt})),
      }
    },
  } as unknown as ChainReader
}

/** A client whose simulations are scripted per function name. */
function fakeClient(results: Record<string, unknown>, gas = 1_500_000n, throwFor: string[] = []): PublicClient {
  return {
    simulateContract: async ({functionName}: {functionName: string}) => {
      if (throwFor.includes(functionName)) throw new Error('execution reverted: 0xdeadbeef')
      return {result: results[functionName]}
    },
    estimateContractGas: async () => gas,
  } as unknown as PublicClient
}

function fakeSubmitter(): Submitter & {submitted: TxRequest[]} {
  const submitted: TxRequest[] = []
  return {
    kind: 'local',
    sender: '0x00000000000000000000000000000000000000e0',
    submitted,
    submit: async (request: TxRequest): Promise<Submission> => {
      submitted.push(request)
      return {id: `tx-${submitted.length}`, hash: `0x${String(submitted.length).padStart(64, '0')}` as `0x${string}`}
    },
    wait: async (submission: Submission) => ({
      hash: submission.hash as `0x${string}`,
      success: true,
      gasUsed: 1_400_000n,
    }),
  }
}

function build(snapshots: ChainSnapshot[], client: PublicClient, now = () => NOW * 1000) {
  const submitter = fakeSubmitter()
  const metrics = createMetrics()
  const runner = new Runner({
    client,
    reader: fakeReader(snapshots),
    submitter,
    policy: DEFAULT_POLICY,
    logger: createLogger({}, {sink: () => undefined}),
    metrics,
    amps: AMPS,
    vaultOverride: VAULT,
    ethUsd18: 2_500n * WAD,
    now,
  })
  return {runner, submitter, metrics}
}

describe('one scan', () => {
  it('sends a compound whose simulated fees clear chost', async () => {
    const client = fakeClient({compound: [10n * WAD, 0n], rollout: 0n, deployBonded: 0n, checkpoint: undefined})
    const {runner, submitter} = build([baseSnapshot({vault: vault({checkpointTimestamp: NOW - 2_000})})], client)

    const result = await runner.scan()
    const kinds = submitter.submitted.map((r) => r.jobKey.split(':')[0])
    expect(kinds).toContain('compound')
    expect(kinds).toContain('checkpoint')
    expect(result.verdicts.filter((v) => v.send).length).toBeGreaterThan(0)
  })

  it('sends nothing at all when the gate is DEGRADED', async () => {
    const client = fakeClient({compound: [10n * WAD, 0n]})
    const {runner, submitter, metrics} = build([baseSnapshot({globalGateState: GateState.DEGRADED})], client)
    await runner.scan()
    expect(submitter.submitted).toHaveLength(0)
    expect(metrics.skipped.get({job: 'compound', reason: 'gate-not-green'})).toBeGreaterThan(0)
  })

  it('sends nothing when the pool has diverged past 800 ticks', async () => {
    const client = fakeClient({compound: [10n * WAD, 0n]})
    const diverged = baseSnapshot({pools: [pool({poolTick: 1_200, fairTick: 0})], constituents: []})
    const {runner, submitter, metrics} = build([diverged], client)
    await runner.scan()
    expect(submitter.submitted.filter((r) => r.jobKey.startsWith('compound'))).toHaveLength(0)
    expect(metrics.skipped.get({job: 'compound', reason: 'diverged'})).toBe(1)
  })

  it('refuses a dust compound and counts it as a chost block', async () => {
    const client = fakeClient({compound: [WAD / 1_000n, 0n]})
    const {runner, submitter, metrics} = build(
      [baseSnapshot({constituents: [], vault: vault({checkpointTimestamp: NOW})})],
      client,
    )
    await runner.scan()
    expect(submitter.submitted.filter((r) => r.jobKey.startsWith('compound'))).toHaveLength(0)
    expect(metrics.chostBlocked.get({job: 'compound'})).toBe(2)
  })

  it('records a reverting simulation as a decision, not a crash', async () => {
    const client = fakeClient({}, 1_500_000n, ['compound', 'rollout', 'deployBonded', 'checkpoint', 'touch'])
    const {runner, submitter, metrics} = build([baseSnapshot()], client)
    await expect(runner.scan()).resolves.toBeDefined()
    expect(submitter.submitted).toHaveLength(0)
    expect(metrics.simulationReverts.get({job: 'compound', error: 'Unknown'})).toBe(2)
  })
})

describe('idempotence and resumption', () => {
  it('does not send the same job twice inside one cooldown window', async () => {
    // Scan 1 sends; scan 2 reads the same chain state but the runner has stamped its own cooldown, so the
    // second scan screens the pool out rather than simulating it again.
    const client = fakeClient({compound: [10n * WAD, 0n], checkpoint: undefined})
    const state = baseSnapshot({constituents: [], vault: vault({checkpointTimestamp: NOW})})
    const {runner, submitter} = build([state, state], client)

    await runner.scan()
    const first = submitter.submitted.length
    await runner.scan()
    expect(submitter.submitted.length).toBe(first)
  })

  it('rebuilds its whole decision from chain state after a 48-hour gap', async () => {
    // Two runners: one that has been running, one started cold two days later. Given the same chain state they
    // reach the same decision, because the keeper holds nothing it cannot re-read.
    const client = fakeClient({compound: [10n * WAD, 0n], checkpoint: undefined})
    const afterOutage = baseSnapshot({
      now: NOW + 48 * 3_600,
      constituents: [],
      vault: vault({checkpointTimestamp: NOW - 3_600}),
      pools: [pool({lastPlacementAt: NOW - 3_600})],
    })

    const warm = build([baseSnapshot({constituents: []}), afterOutage], client)
    await warm.runner.scan()
    const warmBefore = warm.submitter.submitted.length
    await warm.runner.scan()
    const warmSent = warm.submitter.submitted.slice(warmBefore).map((r) => r.jobKey)

    const cold = build([afterOutage], client)
    await cold.runner.scan()
    const coldSent = cold.submitter.submitted.map((r) => r.jobKey)

    expect(coldSent.sort()).toEqual(warmSent.sort())
    expect(coldSent).toContain('checkpoint:')
  })

  it('learns the exact ready time from a PlacementCooldown revert', async () => {
    const {encodeErrorResult} = await import('viem')
    const {KEEPER_ERROR_ABI} = await import('../src/jobs/index.js')
    const poolId = pool().poolId
    const data = encodeErrorResult({
      abi: KEEPER_ERROR_ABI,
      errorName: 'PlacementCooldown',
      args: [poolId, NOW + 45],
    })
    const client = {
      simulateContract: async ({functionName}: {functionName: string}) => {
        if (functionName === 'compound') throw new Error(`execution reverted: ${data}`)
        return {result: undefined}
      },
      estimateContractGas: async () => 1_500_000n,
    } as unknown as PublicClient

    const {runner} = build([baseSnapshot({constituents: [], pools: [pool()]})], client)
    await runner.scan()
    expect(runner.cooldowns().get(poolId)).toBe(NOW + 45 - DEFAULT_POLICY.placementCooldownSeconds)
  })

  it('clears its cooldown cache when the vault pointer moves', async () => {
    const client = fakeClient({compound: [10n * WAD, 0n], checkpoint: undefined})
    const state = baseSnapshot({constituents: [], vault: vault({checkpointTimestamp: NOW})})
    const moved: Topology = {...TOPOLOGY, vault: '0x00000000000000000000000000000000000000aa'}
    let topology = TOPOLOGY

    const submitter = fakeSubmitter()
    const runner = new Runner({
      client,
      reader: {
        topology: async () => topology,
        poolIds: async () => state.pools.map((p) => p.poolId),
        seedLastPlacementAt: async () => new Map<string, number>(),
        snapshot: async (_t: Topology, lastPlacementAt: ReadonlyMap<string, number>) => ({
          ...state,
          pools: state.pools.map((p) => ({
            ...p,
            lastPlacementAt: lastPlacementAt.get(p.poolId) ?? p.lastPlacementAt,
          })),
        }),
      } as unknown as ChainReader,
      policy: DEFAULT_POLICY,
      logger: createLogger({}, {sink: () => undefined}),
      metrics: createMetrics(),
      submitter,
      amps: AMPS,
      vaultOverride: null,
      ethUsd18: 2_500n * WAD,
      now: () => NOW * 1000,
    })

    await runner.scan()
    expect(runner.cooldowns().size).toBeGreaterThan(0)
    topology = moved
    await runner.scan()
    // The new vault's placement clock starts empty, so the pools are candidates again immediately.
    expect(submitter.submitted.filter((r) => r.jobKey.startsWith('compound')).length).toBeGreaterThan(1)
  })
})

describe('metrics the runbook alerts on', () => {
  it('advances the scan clock and records the gate, the pot and the gas series', async () => {
    const client = fakeClient({compound: [10n * WAD, 0n], checkpoint: undefined})
    const {runner, metrics} = build([baseSnapshot({constituents: []})], client, () => 1_700_000_000_000)
    await runner.scan()

    expect(metrics.scans.get({})).toBe(1)
    expect(metrics.lastScanTimestamp.get({})).toBe(1_700_000_000)
    expect(metrics.gateState.get({})).toBe(GateState.GREEN)
    expect(metrics.liveCells.get({})).toBe(328)
    expect(metrics.potBudgetLeft.get({})).toBe(25)
    const text = metrics.registry.render()
    expect(text).toContain('amps_keeper_gas_used_bucket{job="compound"')
    expect(text).toContain('amps_keeper_measured_gas_allowance_usd{job="compound"}')
  })

  it('counts a submit failure without letting it end the scan', async () => {
    const client = fakeClient({compound: [10n * WAD, 0n], checkpoint: undefined})
    const submitter = fakeSubmitter()
    submitter.submit = async () => {
      throw new Error('relayer down')
    }
    const metrics = createMetrics()
    const runner = new Runner({
      client,
      reader: fakeReader([baseSnapshot({constituents: []})]),
      submitter,
      policy: DEFAULT_POLICY,
      logger: createLogger({}, {sink: () => undefined}),
      metrics,
      amps: AMPS,
      vaultOverride: VAULT,
      ethUsd18: 2_500n * WAD,
      now: () => NOW * 1000,
    })

    await expect(runner.scan()).resolves.toBeDefined()
    expect(metrics.submitErrors.get({job: 'compound'})).toBeGreaterThan(0)
    expect(metrics.scanErrors.get({})).toBe(0)
  })
})

describe('nothing but the five jobs', () => {
  it('never encodes a call the vault does not expose as permissionless upkeep', async () => {
    const client = fakeClient({compound: [10n * WAD, 0n], rollout: 5n * WAD, deployBonded: 0n, checkpoint: undefined})
    const {runner, submitter} = build(
      [
        baseSnapshot({
          constituents: [constituent({idleCollateral: 100n * WAD, idleCollateralUsd18: 5_000n * WAD})],
          vault: vault({checkpointTimestamp: NOW - 2_000}),
        }),
      ],
      client,
    )
    await runner.scan()
    const kinds = new Set(submitter.submitted.map((r) => r.jobKey.split(':')[0]))
    for (const kind of kinds) {
      expect(['compound', 'rollout', 'deployBonded', 'checkpoint', 'touch']).toContain(kind)
    }
  })
})
