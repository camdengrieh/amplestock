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
import {
  BOUNTIED_JOBS,
  GateState,
  type ChainSnapshot,
  type JobKind,
  type PoolSnapshot,
  type Screening,
  type Verdict,
} from './domain/types.js'
import {vaultGasAllowanceUsd18} from './domain/bounty.js'
import type {KeeperPolicy} from './domain/policy.js'
import {ChainReader, type Topology} from './chain/reader.js'
import {
  cooldownFrom,
  encodeJob,
  placedPools,
  readBountyReport,
  revertLabel,
  simulateBounty,
  simulateJob,
} from './jobs/index.js'
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
  /**
   * Placements this scan has made or learned about, layered over the snapshot for the rest of the cycle.
   *
   * `AmpsVault.lastPlacementAt(poolId)` is the authority and is re-read every scan, so this is **not** a cache
   * that survives anything: it is cleared at the top of every cycle. It exists because the snapshot is taken
   * once and a job sent early in a scan stamps pools that later candidates in the same scan would otherwise
   * still see as free — a `compound` on the hub, then a `rollout` that harvests from it. Without the overlay
   * that rollout costs one simulation to learn what the keeper already knew.
   */
  private readonly placedThisScan = new Map<string, number>()
  private readonly inFlight = new Map<string, InFlight>()
  private topologyCache: Topology | null = null
  /**
   * Whether this node answers `eth_simulateV1` with the logs a job would emit.
   *
   * Latched to false the first time a bountied job simulates cleanly but produces no `BountyPaid`, because a
   * node that cannot do it will not start being able to; from then on the keeper decides from its own estimate
   * of the work value and its mirror of the vault's gas allowance.
   */
  private bountySimulation = true
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
        }
      }
    }
    this.topologyCache = next
    return next
  }

  /** Placements this scan has made or learned about. Exposed for the tests; cleared every cycle. */
  cooldowns(): ReadonlyMap<string, number> {
    return this.placedThisScan
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

    this.placedThisScan.clear()
    const read = await reader.snapshot(topology, this.options.ethUsd18)
    const snapshot: ChainSnapshot = {
      ...read,
      pools: read.pools.map((pool) => this.withOverlay(pool)),
    }
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
      const base = await simulateJob(this.options.client, topology.vault, this.options.submitter.sender, job)
      const reported =
        base.ok && this.bountySimulation
          ? await simulateBounty(
              this.options.client,
              topology.vault,
              topology.bountyPot,
              this.options.submitter.sender,
              job,
            )
          : undefined
      // One probe: a node without `eth_simulateV1` is not asked again, and the keeper runs on its own estimate.
      if (base.ok && this.bountySimulation && reported === undefined && BOUNTIED_JOBS.includes(job.kind)) {
        this.bountySimulation = false
        logger.info('eth_simulateV1 did not yield a BountyPaid; falling back to the keeper estimate', {job: job.key})
      }
      const simulation = reported === undefined ? base : {...base, bounty: reported}

      if (!simulation.ok) {
        metrics.simulationReverts.inc({job: job.kind, error: revertLabel(simulation)})
        // A cooldown revert names the pool it is about, which for a `rollout` is an entry pool rather than the
        // constituent the job was addressed to. Recording it saves the rest of this scan a wasted round trip.
        const cooldown = cooldownFrom(base)
        if (cooldown !== null) {
          this.placedThisScan.set(cooldown.poolId, cooldown.readyAt - policy.placementCooldownSeconds)
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

      const outcome = await this.send(topology, verdict, snapshot)
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

  /** The snapshot's view of a pool, with anything this scan has since learned about its placement clock. */
  private withOverlay(pool: PoolSnapshot): PoolSnapshot {
    const overlay = this.placedThisScan.get(pool.poolId) ?? 0
    return overlay > pool.lastPlacementAt ? {...pool, lastPlacementAt: overlay} : pool
  }

  private async send(
    topology: Topology,
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
    metrics.measuredGasAllowance.set(
      {job: job.kind},
      Number(vaultGasAllowanceUsd18(verdict.gasEstimate, snapshot.baseFeeWei, snapshot.ethUsd18)) / 1e18,
    )

    try {
      const submission = await submitter.submit({
        to: topology.vault,
        data: encodeJob(job),
        gasLimit,
        jobKey: job.key,
      })
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
        // What the vault actually reported and the pot actually paid, from the receipt's own `BountyPaid`. This
        // is the other half of the measured-versus-reported comparison: `reported_*` is the chain's number,
        // `measured_*` is the keeper's, and a persistent gap means they disagree about what a job is worth.
        const paid = readBountyReport(receipt.logs, topology.bountyPot)
        if (paid !== undefined) {
          metrics.reportedWorkValue.set({job: job.kind}, Number(paid.workValueUsd18) / 1e18)
          metrics.bountyPaid.inc({job: job.kind}, Number(paid.paidUsd18) / 1e18)
          if (paid.reason !== '') metrics.bountyReason.set({job: job.kind, reason: paid.reason}, 1)
        }
        metrics.reportedGasAllowance.set(
          {job: job.kind},
          Number(vaultGasAllowanceUsd18(receipt.gasUsed, snapshot.baseFeeWei, snapshot.ethUsd18)) / 1e18,
        )
        if (job.kind === 'touch') this.lastTouchAt = snapshot.now

        // Exactly the pools the vault stamped, from the `Placement` logs the job emitted. A `rollout` is
        // addressed by constituent but places into the destination spoke and whichever entry pools it
        // harvested, and only the receipt knows which.
        const placed = placedPools(receipt.logs, topology.vault)
        for (const record of placed) this.placedThisScan.set(record.poolId, snapshot.now)
        if (placed.length === 0) this.markConstituentPools(job.kind, job.target, snapshot)
        else logger.debug('placements landed', {job: job.key, pools: placed.map((r) => r.reason)})
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
   * The fallback when a confirmed job emitted no `Placement` at all.
   *
   * `compound` on a pool with nothing to re-ladder is the real case: it still stamps the vault's own
   * `_lastPlacementAt`, so the pool is on cooldown even though nothing was placed. A `rollout` or
   * `deployBonded` that moved nothing returns early without stamping anything, which the conservative guess
   * here over-reports by one scan at worst — the next scan reads the chain and corrects it.
   */
  private markConstituentPools(kind: JobKind, target: string, snapshot: ChainSnapshot): void {
    const at = snapshot.now
    if (target.startsWith('0x')) {
      this.placedThisScan.set(target, at)
      return
    }
    const constituent = snapshot.constituents.find((c) => c.constituentId === Number(target))
    if (constituent !== undefined) this.placedThisScan.set(constituent.poolId, at)
    if (kind !== 'rollout') return
    for (const pool of snapshot.pools) if (pool.constituentId === 0) this.placedThisScan.set(pool.poolId, at)
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
