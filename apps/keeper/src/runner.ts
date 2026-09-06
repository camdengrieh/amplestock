// SPDX-License-Identifier: MIT

/**
 * The scan loop: read → screen → simulate → qualify → send, once every `scanIntervalSeconds`.
 *
 * ## Idempotence and the 48-hour outage
 *
 * The keeper holds **no state it cannot rebuild from the chain**. Every scan starts from a block read; the
 * cooldown map is a cache seeded from the ladder records and corrected by the `PlacementCooldown` revert; the
 * bounty budget, the checkpoint age and the gate all come from `view`s. Kill the process for two days, delete
 * its state file, start it on a different host — the first scan produces the same decisions as a process that
 * never stopped, because both are functions of the same chain state.
 *
 * What that buys, concretely, is the plan's Phase 4 exit line: *a 48-hour keeper outage degrades gracefully*.
 * Ladders are static, so trading is unaffected; bonds and redemption never touch the keeper; fee AMPS and
 * bonded stock simply queue in the pool and in the vault's claims. On resumption every queued pool is one
 * `compound` behind and the cooldown is long expired, so the backlog drains at one job per pool per scan with
 * no duplicate sends: a job is sent at most once per `(pool, cooldown window)` because the vault stamps
 * `_lastPlacementAt` and the next simulation reverts `PlacementCooldown` for the following 60 seconds.
 *
 * The one piece of volatile state is the in-flight map — the transactions this process has submitted and not
 * yet seen mined. It is a de-duplication convenience, not a correctness requirement: losing it causes at worst
 * one extra simulation, which then reverts on the cooldown.
 */

import type {Address, PublicClient} from 'viem'
import {qualify, screen} from './domain/decide.js'
import {GateState, type ChainSnapshot, type JobKind, type Screening, type Verdict} from './domain/types.js'
import {
  measuredGasAllowanceUsd18,
  VAULT_REPORTED_GAS_ALLOWANCE_USD18,
  VAULT_REPORTED_WORK_VALUE_USD18,
} from './domain/bounty.js'
import type {KeeperPolicy} from './domain/policy.js'
import {ChainReader, type Topology} from './chain/reader.js'
import {cooldownFrom, encodeJob, revertLabel, simulateJob} from './jobs/index.js'
import type {Submitter} from './chain/submitter.js'
import type {Logger} from './logger.js'
import type {Metrics} from './metrics.js'
import {BPS} from './domain/bounty.js'

/** A transaction this process submitted and has not yet seen mined. */
interface InFlight {
  readonly key: string
  readonly submittedAt: number
  readonly id: string
}

export interface RunnerOptions {
  readonly client: PublicClient
  readonly reader: ChainReader
  readonly submitter: Submitter
  readonly policy: KeeperPolicy
  readonly logger: Logger
  readonly metrics: Metrics
  readonly amps: Address
  readonly vaultOverride: Address | null
  readonly ethUsd18: bigint
  /** Injected in tests; defaults to the wall clock. */
  readonly now?: () => number
}

/** One cycle's outcome, returned so the chain suite can assert on it without scraping logs. */
export interface ScanResult {
  readonly snapshot: ChainSnapshot
  readonly screenings: readonly Screening[]
  readonly verdicts: readonly Verdict[]
  readonly sent: readonly {key: string; hash: string | null; success?: boolean; gasUsed?: bigint}[]
}

export class Runner {
  private readonly options: RunnerOptions
  private readonly lastPlacementAt = new Map<string, number>()
  private readonly inFlight = new Map<string, InFlight>()
  private topologyCache: Topology | null = null
  private seeded = false
  private lastTouchAt = 0
  private stopped = false

  constructor(options: RunnerOptions) {
    this.options = options
  }

  /** The address graph, re-resolved every scan so a governance pointer move is followed without a restart. */
  async topology(): Promise<Topology> {
    const next = await this.options.reader.topology(this.options.amps, this.options.vaultOverride)
    const previous = this.topologyCache
    if (previous !== null) {
      for (const key of Object.keys(next) as (keyof Topology)[]) {
        if (previous[key] !== next[key]) {
          this.options.logger.warn('topology pointer moved', {pointer: key, from: previous[key], to: next[key]})
          // A vault move invalidates every cooldown: the new vault's `_lastPlacementAt` starts empty.
          if (key === 'vault') this.lastPlacementAt.clear()
        }
      }
    }
    this.topologyCache = next
    return next
  }

  /** Cooldowns this process knows about. Exposed for the chain suite. */
  cooldowns(): ReadonlyMap<string, number> {
    return this.lastPlacementAt
  }

  stop(): void {
    this.stopped = true
  }

  private nowMs(): number {
    return (this.options.now ?? Date.now)()
  }

  /** One scan. Never throws for a chain-side reason: a failed cycle is a metric and the next one retries. */
  async scan(): Promise<ScanResult> {
    const {reader, policy, logger, metrics} = this.options
    const started = this.nowMs()
    const topology = await this.topology()

    if (!this.seeded) {
      const ids = await reader.poolIds(topology)
      const seed = await reader.seedLastPlacementAt(topology, ids)
      for (const [poolId, at] of seed) if (at > 0) this.lastPlacementAt.set(poolId, at)
      this.seeded = true
      logger.info('cooldown clock seeded from ladder records', {pools: ids.length, known: this.lastPlacementAt.size})
    }

    const snapshot = await reader.snapshot(topology, this.lastPlacementAt, this.options.ethUsd18)
    this.recordSnapshotMetrics(snapshot)

    const screenings = screen(snapshot, policy, this.lastTouchAt)
    const verdicts: Verdict[] = []
    const sent: {key: string; hash: string | null; success?: boolean; gasUsed?: bigint}[] = []

    const perJobCandidates = new Map<string, number>()
    const perJobEligible = new Map<string, number>()

    for (const screening of screenings) {
      const job = screening.candidate
      perJobCandidates.set(job.kind, (perJobCandidates.get(job.kind) ?? 0) + 1)

      if (!screening.eligible) {
        metrics.skipped.inc({job: job.kind, reason: screening.reason ?? 'not-due'})
        logger.debug('screened out', {job: job.key, reason: screening.reason, detail: screening.detail})
        if (screening.reason === 'cooldown' && screening.readyAt !== undefined) {
          this.rememberReadyAt(job.target, screening.readyAt)
        }
        continue
      }
      perJobEligible.set(job.kind, (perJobEligible.get(job.kind) ?? 0) + 1)

      const pending = this.inFlight.get(job.key)
      if (pending !== undefined) {
        if (started - pending.submittedAt < policy.inFlightTimeoutSeconds * 1000) {
          metrics.skipped.inc({job: job.kind, reason: 'in-flight'})
          continue
        }
        logger.warn('in-flight transaction timed out; re-deciding', {job: job.key, id: pending.id})
        this.inFlight.delete(job.key)
      }

      metrics.simulations.inc({job: job.kind})
      const simulation = await simulateJob(this.options.client, topology.vault, this.options.submitter.sender, job)

      if (!simulation.ok) {
        metrics.simulationReverts.inc({job: job.kind, error: revertLabel(simulation)})
        const cooldown = cooldownFrom(simulation)
        if (cooldown !== null) {
          this.rememberReadyAt(cooldown.poolId, cooldown.readyAt - policy.placementCooldownSeconds)
        }
        logger.debug('simulation reverted', {job: job.key, error: simulation.revert})
      }

      const constituent =
        job.kind === 'rollout' || job.kind === 'deployBonded'
          ? snapshot.constituents.find((c) => c.constituentId === Number(job.target))
          : undefined
      const pool =
        job.kind === 'compound'
          ? snapshot.pools.find((p) => p.poolId === job.target)
          : constituent === undefined
            ? undefined
            : snapshot.pools.find((p) => p.poolId === constituent.poolId)

      const verdict = qualify(screening, simulation, snapshot, policy, constituent, pool)
      verdicts.push(verdict)

      if (!verdict.send) {
        metrics.skipped.inc({job: job.kind, reason: verdict.reason ?? 'not-due'})
        if (verdict.reason === 'below-chost') metrics.chostBlocked.inc({job: job.kind})
        if (verdict.reason === 'unprofitable') metrics.unprofitable.inc({job: job.kind})
        logger.info('job refused', {
          job: job.key,
          reason: verdict.reason,
          detail: verdict.detail,
          workValueUsd18: verdict.workValueUsd18,
          bountyUsd18: verdict.bountyUsd18,
          gasCostUsd18: verdict.gasCostUsd18,
        })
        continue
      }

      const outcome = await this.send(topology.vault, verdict, snapshot)
      if (outcome !== null) sent.push(outcome)
    }

    for (const [kind, count] of perJobCandidates) metrics.candidates.set({job: kind}, count)
    for (const kind of perJobCandidates.keys()) metrics.eligible.set({job: kind}, perJobEligible.get(kind) ?? 0)
    metrics.inFlight.set({}, this.inFlight.size)
    metrics.scans.inc()
    metrics.lastScanTimestamp.set({}, Math.floor(this.nowMs() / 1000))
    metrics.scanDuration.observe({}, (this.nowMs() - started) / 1000)

    return {snapshot, screenings, verdicts, sent}
  }

  private rememberReadyAt(poolId: string, lastPlacement: number): void {
    if (!poolId.startsWith('0x')) return
    const known = this.lastPlacementAt.get(poolId) ?? 0
    if (lastPlacement > known) this.lastPlacementAt.set(poolId, lastPlacement)
  }

  private async send(
    vault: Address,
    verdict: Verdict,
    snapshot: ChainSnapshot,
  ): Promise<{key: string; hash: string | null; success?: boolean; gasUsed?: bigint} | null> {
    const {logger, metrics, policy, submitter} = this.options
    const job = verdict.candidate
    const buffered = (verdict.gasEstimate * (BPS + BigInt(policy.gasLimitBufferBps))) / BPS
    const gasLimit = buffered > policy.gasLimitCeiling ? policy.gasLimitCeiling : buffered

    metrics.gasEstimate.observe({job: job.kind}, Number(verdict.gasEstimate))
    metrics.bountyExpected.set({job: job.kind}, Number(verdict.bountyUsd18) / 1e18)
    metrics.measuredWorkValue.set({job: job.kind}, Number(verdict.workValueUsd18) / 1e18)
    metrics.reportedWorkValue.set({job: job.kind}, Number(VAULT_REPORTED_WORK_VALUE_USD18) / 1e18)
    metrics.measuredGasAllowance.set(
      {job: job.kind},
      Number(measuredGasAllowanceUsd18(verdict.gasEstimate, snapshot.baseFeeWei, snapshot.ethUsd18)) / 1e18,
    )
    metrics.reportedGasAllowance.set({job: job.kind}, Number(VAULT_REPORTED_GAS_ALLOWANCE_USD18) / 1e18)

    try {
      const submission = await submitter.submit({to: vault, data: encodeJob(job), gasLimit, jobKey: job.key})
      metrics.sent.inc({job: job.kind})
      this.inFlight.set(job.key, {key: job.key, submittedAt: this.nowMs(), id: submission.id})
      logger.info('submitted', {
        job: job.key,
        id: submission.id,
        hash: submission.hash,
        gasLimit,
        bountyUsd18: verdict.bountyUsd18,
        workValueUsd18: verdict.workValueUsd18,
      })

      const receipt = await submitter.wait(submission)
      this.inFlight.delete(job.key)
      if (receipt.success) {
        metrics.confirmed.inc({job: job.kind})
        metrics.gasUsed.observe({job: job.kind}, Number(receipt.gasUsed))
        if (job.kind === 'touch') this.lastTouchAt = snapshot.now
        if (job.target.startsWith('0x')) this.lastPlacementAt.set(job.target, Math.floor(this.nowMs() / 1000))
        else this.markConstituentPools(job.kind, job.target, snapshot)
        logger.info('confirmed', {job: job.key, hash: receipt.hash, gasUsed: receipt.gasUsed})
      } else {
        metrics.failed.inc({job: job.kind})
        logger.warn('reverted on chain', {job: job.key, hash: receipt.hash})
      }
      return {key: job.key, hash: receipt.hash, success: receipt.success, gasUsed: receipt.gasUsed}
    } catch (error) {
      this.inFlight.delete(job.key)
      metrics.submitErrors.inc({job: job.kind})
      logger.error('submit failed', {job: job.key, error})
      return {key: job.key, hash: null, success: false}
    }
  }

  /**
   * Stamps the cooldowns a constituent-addressed job just consumed.
   *
   * `deployBonded` places into the spoke and nothing else. `rollout` harvests unfilled asks out of **both**
   * entry pools before it places, and each of those is a `place` in its own right, so all three pools are on
   * cooldown afterwards.
   */
  private markConstituentPools(kind: JobKind, target: string, snapshot: ChainSnapshot): void {
    const at = Math.floor(this.nowMs() / 1000)
    const constituent = snapshot.constituents.find((c) => c.constituentId === Number(target))
    if (constituent !== undefined) this.lastPlacementAt.set(constituent.poolId, at)
    if (kind !== 'rollout') return
    for (const pool of snapshot.pools) if (pool.constituentId === 0) this.lastPlacementAt.set(pool.poolId, at)
  }

  private recordSnapshotMetrics(snapshot: ChainSnapshot): void {
    const {metrics, policy} = this.options
    metrics.blockNumber.set({}, Number(snapshot.blockNumber))
    metrics.gateState.set({}, snapshot.globalGateState)
    metrics.watchdogTripped.set({}, snapshot.watchdogTripped ? 1 : 0)
    metrics.protocolFrozenUntil.set({}, snapshot.protocolFreezeUntil)
    metrics.navPerShare.set({}, Number(snapshot.vault.navPerShareX18) / 1e18)
    metrics.checkpointAge.set({}, snapshot.now - snapshot.vault.checkpointTimestamp)
    metrics.liveCells.set({}, snapshot.vault.liveCells)
    metrics.liveCellBudget.set({}, policy.maxLiveCells)
    metrics.potBalance.set({}, Number(snapshot.pot.balanceRaw))
    metrics.potBudgetLeft.set({}, Number(snapshot.pot.budgetLeftUsd18) / 1e18)
    metrics.potSpent24h.set({}, Number(snapshot.pot.spentLast24hUsd18) / 1e18)
    metrics.potQuoteUsd.set({}, Number(snapshot.pot.quotedPayableRaw * snapshot.pot.usdScale) / 1e18)
    metrics.potQuoteReason.set({reason: snapshot.pot.quotedReason === '' ? 'payable' : snapshot.pot.quotedReason}, 1)

    for (const pool of snapshot.pools) {
      metrics.poolGateState.set({pool: pool.poolId}, pool.gateState)
      metrics.poolDivergenceTicks.set({pool: pool.poolId}, Math.abs(pool.poolTick - pool.fairTick))
      metrics.poolLadderCells.set({pool: pool.poolId}, pool.ladderCells)
      metrics.poolSurgeBps.set({pool: pool.poolId}, pool.surgeBps)
      metrics.poolHighWaterTick.set({pool: pool.poolId}, pool.highWaterTick)
      metrics.poolLastSwapAge.set({pool: pool.poolId}, pool.lastSwapAt === 0 ? -1 : snapshot.now - pool.lastSwapAt)
    }
  }

  /** The service loop. Returns when {@link stop} is called. */
  async run(): Promise<void> {
    const {logger, metrics, policy} = this.options
    metrics.up.set({}, 1)
    while (!this.stopped) {
      try {
        const result = await this.scan()
        if (result.snapshot.globalGateState !== GateState.GREEN) {
          logger.warn('gate is not green', {
            state: GateState[result.snapshot.globalGateState],
            watchdogTripped: result.snapshot.watchdogTripped,
          })
        }
      } catch (error) {
        metrics.scanErrors.inc()
        logger.error('scan failed', {error})
      }
      if (this.stopped) break
      await new Promise((resolve) => setTimeout(resolve, policy.scanIntervalSeconds * 1000))
    }
    metrics.up.set({}, 0)
  }
}
