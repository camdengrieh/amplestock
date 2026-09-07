// SPDX-License-Identifier: MIT
import {describe, expect, it, vi} from 'vitest'
import {buildWorkflow, decideJobs, encodeReport, runWorkflow, type CreWorkflowConfig} from '../src/cre/workflow.js'
import type {CreRuntime, CreSdk, CronTrigger, WorkflowBinding} from '../src/cre/sdk.js'
import {screen} from '../src/domain/decide.js'
import {DEFAULT_POLICY} from '../src/domain/policy.js'
import {GateState} from '../src/domain/types.js'
import {constituent, NOW, pool, snapshot, vault} from './helpers.js'
import {WAD} from '../src/domain/bounty.js'

const CONFIG: CreWorkflowConfig = {
  chainSelector: '4663-selector',
  amps: '0x00000000000000000000000000000000000000a1',
  schedule: '*/1 * * * *',
}

/** A fake SDK matching `CreSdk`, which is what the real `@chainlink/cre-sdk` also matches. */
function fakeSdk(): CreSdk & {bindings: WorkflowBinding[]} {
  const bindings: WorkflowBinding[] = []
  return {
    bindings,
    cron: (config) => ({type: 'cron', config}) as CronTrigger,
    handler: (trigger, fn) => {
      const binding = {trigger, handler: fn} as WorkflowBinding
      bindings.push(binding)
      return binding
    },
    runner: () => ({
      run: (initialise) => {
        for (const binding of initialise()) bindings.push(binding)
      },
    }),
  }
}

function fakeRuntime(): CreRuntime & {reports: Uint8Array[]; lines: string[]} {
  const reports: Uint8Array[] = []
  const lines: string[] = []
  return {
    reports,
    lines,
    logger: {log: (m) => lines.push(m)},
    evm: () => ({call: async () => '0x'}),
    report: async (payload) => {
      reports.push(payload)
    },
  }
}

describe('the mirror is the same function, not a copy of it', () => {
  it('decideJobs agrees with screen() on every candidate', () => {
    const s = snapshot({
      constituents: [constituent({idleCollateral: 500n * WAD, idleCollateralUsd18: 500n * WAD})],
    })
    const screened = screen(s, DEFAULT_POLICY, 0)
    const report = decideJobs(s, DEFAULT_POLICY, 0)

    expect(report.due.map((c) => c.key).sort()).toEqual(
      screened.filter((x) => x.eligible).map((x) => x.candidate.key).sort(),
    )
    expect(report.refused).toHaveLength(screened.filter((x) => !x.eligible).length)
  })

  it('refuses everything when the gate is not GREEN, exactly as the service does', () => {
    for (const state of [GateState.DEGRADED, GateState.DIVERGED, GateState.SCHEDULED_FREEZE]) {
      const report = decideJobs(snapshot({globalGateState: state}), DEFAULT_POLICY, 0)
      expect(report.due).toHaveLength(0)
    }
  })

  it('lets `touch` through when the watchdog has tripped, exactly as the service does', () => {
    const report = decideJobs(
      snapshot({globalGateState: GateState.WATCHDOG, watchdogTripped: true}),
      DEFAULT_POLICY,
      NOW,
    )
    expect(report.due.map((c) => c.kind)).toEqual(['touch'])
  })

  it('waits out a cooldown', () => {
    const s = snapshot({pools: [pool({lastPlacementAt: NOW - 10})]})
    const report = decideJobs(s, DEFAULT_POLICY, NOW)
    expect(report.due.map((c) => c.kind)).not.toContain('compound')
    expect(report.refused.find((r) => r.key.startsWith('compound'))?.reason).toBe('cooldown')
  })

  it('proposes deployBonded once the threshold is cleared and not before', () => {
    const below = snapshot({
      constituents: [constituent({idleCollateral: 1n * WAD, idleCollateralUsd18: 50n * WAD})],
    })
    expect(decideJobs(below, DEFAULT_POLICY, NOW).due.map((c) => c.kind)).not.toContain('deployBonded')

    const above = snapshot({
      constituents: [constituent({idleCollateral: 10n * WAD, idleCollateralUsd18: 500n * WAD})],
    })
    expect(decideJobs(above, DEFAULT_POLICY, NOW).due.map((c) => c.kind)).toContain('deployBonded')
  })
})

describe('the report', () => {
  it('is deterministic, so two CRE nodes produce identical bytes', () => {
    const report = decideJobs(snapshot(), DEFAULT_POLICY, 0)
    const a = encodeReport(report)
    const b = encodeReport({...report, due: [...report.due].reverse(), refused: [...report.refused].reverse()})
    expect(new TextDecoder().decode(a)).toBe(new TextDecoder().decode(b))
  })

  it('names the jobs by their keys', () => {
    const report = decideJobs(snapshot(), DEFAULT_POLICY, 0)
    const decoded = JSON.parse(new TextDecoder().decode(encodeReport(report))) as {due: string[]}
    expect(decoded.due.some((k) => k.startsWith('compound:'))).toBe(true)
  })
})

describe('the workflow shell', () => {
  it('registers a single cron-triggered handler', () => {
    const sdk = fakeSdk()
    const bindings = buildWorkflow(sdk, CONFIG, async () => snapshot())
    expect(bindings).toHaveLength(1)
    expect(bindings[0]?.trigger.type).toBe('cron')
    expect(bindings[0]?.trigger.config.schedule).toBe('*/1 * * * *')
  })

  it('emits a report when something is due, and stays silent when nothing is', async () => {
    const sdk = fakeSdk()
    const runtime = fakeRuntime()

    const due = buildWorkflow(sdk, CONFIG, async () => snapshot())[0]!
    await due.handler(runtime, {})
    expect(runtime.reports).toHaveLength(1)
    expect(runtime.lines[0]).toMatch(/^amps-keeper-cre: \d+ due/)

    const quiet = buildWorkflow(
      sdk,
      CONFIG,
      async () => snapshot({globalGateState: GateState.DEGRADED, vault: vault({checkpointTimestamp: NOW})}),
    )[0]!
    await quiet.handler(runtime, {})
    expect(runtime.reports).toHaveLength(1)
  })

  it('runWorkflow hands the bindings to the SDK runner', () => {
    const sdk = fakeSdk()
    const run = vi.spyOn(sdk, 'runner')
    runWorkflow(sdk, CONFIG, async () => snapshot())
    expect(run).toHaveBeenCalledOnce()
    expect(sdk.bindings.length).toBeGreaterThan(0)
  })
})
