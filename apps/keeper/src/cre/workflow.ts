// SPDX-License-Identifier: MIT

/**
 * The Chainlink CRE mirror of the keeper's decision logic.
 *
 * **What it is.** A cron-triggered CRE workflow that reads the same `view`s the keeper reads, runs the same
 * screening function, and emits a report naming the jobs that are due. The on-chain consumer of that report
 * calls `AmpsVault.compound` / `rollout` / `deployBonded` — all three are permissionless, so the CRE path needs
 * no privilege the keeper does not already have, and running both at once is safe: the loser of the race hits
 * the 60-second cooldown and its transaction reverts without paying a bounty.
 *
 * **Why the decision function is imported rather than reimplemented.** `screen()` in `../domain/decide.ts` is
 * pure and takes a `ChainSnapshot`. The service builds that snapshot from viem; this workflow builds the same
 * snapshot from CRE's own EVM reads. Everything downstream is literally the same code, so the mirror cannot
 * silently drift — which is the only property that makes a mirror worth having.
 *
 * **What it cannot do here.** `@chainlink/cre-sdk` is not installed and no CRE node is reachable, so this file
 * is a compiled, typechecked artefact with unit tests over the decision function and a `README.md` describing
 * the deployment. The SDK arrives as a parameter (see `sdk.ts`), so swapping the real package in is one import.
 */

import {screen} from '../domain/decide.js'
import {DEFAULT_POLICY, type KeeperPolicy} from '../domain/policy.js'
import type {ChainSnapshot, JobCandidate, Screening} from '../domain/types.js'
import type {CreRuntime, CreSdk, WorkflowBinding} from './sdk.js'

/** What the workflow is configured with. Addresses and the chain selector are configuration, never literals. */
export interface CreWorkflowConfig {
  /** CCIP-style chain selector for Robinhood Chain testnet, from the CRE deployment. */
  readonly chainSelector: string
  /** The AMPS token; everything else is resolved from it exactly as the service does. */
  readonly amps: `0x${string}`
  /** Cron schedule. One minute is the shortest CRE allows on most deployments. */
  readonly schedule: string
  readonly policy?: KeeperPolicy
  /**
   * The `touch()` clock. CRE workflows are stateless between runs, so the mirror is given the last touch time
   * rather than remembering it; the consumer contract's own `lastTouchAt` is the natural source.
   */
  readonly lastTouchAt?: number
}

/** The report the workflow emits: the jobs that screened eligible, and why the rest did not. */
export interface CreDecisionReport {
  readonly at: number
  readonly due: readonly JobCandidate[]
  readonly refused: readonly {readonly key: string; readonly reason: string}[]
}

/**
 * The shared decision. **This is the mirror**: `apps/keeper`'s runner calls `screen()` directly, and so does
 * this, so there is exactly one implementation of "is this job due?".
 *
 * Screening is where the CRE mirror stops. The second half of the keeper's decision — the `chost` dust guard
 * and the bounty-versus-gas check — needs an `eth_call` return value and an `eth_estimateGas`, neither of which
 * a CRE workflow can produce; the consumer contract's own simulation is where that lands.
 */
export function decideJobs(
  snapshot: ChainSnapshot,
  policy: KeeperPolicy = DEFAULT_POLICY,
  lastTouchAt = 0,
): CreDecisionReport {
  const screenings: Screening[] = screen(snapshot, policy, lastTouchAt)
  return {
    at: snapshot.now,
    due: screenings.filter((s) => s.eligible).map((s) => s.candidate),
    refused: screenings
      .filter((s) => !s.eligible)
      .map((s) => ({key: s.candidate.key, reason: s.reason ?? 'not-due'})),
  }
}

/** Serialises a report for `runtime.report`. Deterministic, so two nodes produce identical bytes. */
export function encodeReport(report: CreDecisionReport): Uint8Array {
  const canonical = {
    at: report.at,
    due: [...report.due].map((c) => c.key).sort(),
    refused: [...report.refused].map((r) => `${r.key}=${r.reason}`).sort(),
  }
  return new TextEncoder().encode(JSON.stringify(canonical))
}

/**
 * Builds the workflow.
 *
 * `readSnapshot` is injected because CRE's EVM read surface differs between SDK versions and because the unit
 * tests drive the handler without a node. In production it is the ABI-encoded read sequence described in
 * `README.md`; here it is whatever the caller supplies.
 */
export function buildWorkflow(
  sdk: CreSdk,
  config: CreWorkflowConfig,
  readSnapshot: (runtime: CreRuntime, config: CreWorkflowConfig) => Promise<ChainSnapshot>,
): WorkflowBinding[] {
  const policy = config.policy ?? DEFAULT_POLICY
  const trigger = sdk.cron({schedule: config.schedule})

  const binding = sdk.handler(trigger, async (runtime: CreRuntime) => {
    const snapshot = await readSnapshot(runtime, config)
    const report = decideJobs(snapshot, policy, config.lastTouchAt ?? 0)
    runtime.logger.log(
      `amps-keeper-cre: ${report.due.length} due, ${report.refused.length} refused at ${report.at}`,
    )
    if (report.due.length > 0) await runtime.report(encodeReport(report))
    return report
  })

  return [binding]
}

/** Entry point a CRE deployment calls. Kept separate so `buildWorkflow` stays testable. */
export function runWorkflow(
  sdk: CreSdk,
  config: CreWorkflowConfig,
  readSnapshot: (runtime: CreRuntime, config: CreWorkflowConfig) => Promise<ChainSnapshot>,
): void {
  sdk.runner().run(() => buildWorkflow(sdk, config, readSnapshot))
}
