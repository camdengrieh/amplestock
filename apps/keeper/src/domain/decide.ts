// SPDX-License-Identifier: MIT

/**
 * The keeper's decision logic. **Pure**: no viem, no node, no clock — every input arrives in the
 * {@link ChainSnapshot}, so the same function runs inside the service, inside the vitest suites, and inside the
 * Chainlink CRE workflow in `src/cre/`.
 *
 * Two stages, because the two questions have different costs:
 *
 *  * {@link screen} — from `view` reads alone: is this job *allowed* right now? Gate, divergence, cooldown,
 *    cell budget, staleness, deploy threshold. Cheap, and it is what the CRE mirror evaluates.
 *  * {@link qualify} — after an `eth_call` and an `eth_estimateGas`: is this job *worth* sending? Work value
 *    against `chost`, bounty against gas. Needs a simulation, so it is a second stage.
 *
 * Nothing here re-centres or re-widens anything. The five jobs are the five permissionless entry points and
 * there is no sixth: `RebalanceNeeded` from the hook is a *notification that the fee schedule reacted*, and the
 * keeper's answer to it is `compound`, never a range move (`IAmpsHook`'s own note on the event says so).
 */

import {
  BOUNTIED_JOBS,
  GateState,
  type ChainSnapshot,
  type ConstituentSnapshot,
  type JobCandidate,
  type JobKind,
  type PoolSnapshot,
  type Screening,
  type Simulation,
  type Verdict,
} from './types.js'
import {
  compoundWorkValueUsd18,
  gasCostUsd18,
  meetsChost,
  quoteBounty,
  splitAmpsFees,
  BPS,
  WAD,
  VAULT_REPORTED_GAS_ALLOWANCE_USD18,
  VAULT_REPORTED_WORK_VALUE_USD18,
} from './bounty.js'
import type {KeeperPolicy} from './policy.js'

/** `<kind>:<target>`, the identity used for de-duplication, metrics labels and the in-flight map. */
export function jobKey(kind: JobKind, target: string): string {
  return `${kind}:${target}`
}

function candidate(kind: JobKind, target: string): JobCandidate {
  return {kind, target, key: jobKey(kind, target)}
}

function abs(n: number): number {
  return n < 0 ? -n : n
}

// ---------------------------------------------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------------------------------------------

/**
 * Whether the vault-wide gate `AmpsVault._requireHealthy` reads would let *any* mutating call through.
 *
 * The vault accepts `GREEN` and `REF_DIVERGED`; the keeper defaults to `GREEN` only, because `REF_DIVERGED`
 * means the reference has fallen back to NAV and a placement made under it anchors differently from one made a
 * minute earlier — correct, but not something an unattended process should choose to do. `allowRefDiverged`
 * turns the contract's own tolerance back on.
 */
export function gateAdmits(state: GateState, policy: KeeperPolicy): boolean {
  if (state === GateState.GREEN) return true
  if (state === GateState.REF_DIVERGED) return policy.allowRefDiverged
  return false
}

/** The vault-wide refusal, shared by every job: gate state and the guardian's protocol freeze. */
function globalRefusal(snapshot: ChainSnapshot, policy: KeeperPolicy): Screening['reason'] | undefined {
  if (snapshot.protocolFreezeUntil > snapshot.now) return 'protocol-frozen'
  if (!gateAdmits(snapshot.globalGateState, policy)) {
    return snapshot.globalGateState === GateState.REF_DIVERGED ? 'gate-ref-diverged' : 'gate-not-green'
  }
  return undefined
}

// ---------------------------------------------------------------------------------------------------------------
// Per-job screening
// ---------------------------------------------------------------------------------------------------------------

/**
 * The placement gauntlet of `docs/phase3-state-model.md` §3.8, as far as a `view` can see it.
 *
 * Steps 1 (the transient lock) and 7 (the R1 post-condition) are not observable before the call; the simulation
 * in {@link qualify} is what covers them, because a placement that would violate R1 reverts and the `eth_call`
 * reverts with it.
 */
function screenPlacement(
  pool: PoolSnapshot,
  snapshot: ChainSnapshot,
  policy: KeeperPolicy,
): {reason?: Screening['reason']; readyAt?: number; detail?: string} {
  // 2. The per-pool gate. `isPlacementAllowed` is the non-reverting form of `checkPlacement`.
  if (!gateAdmits(pool.gateState, policy)) {
    return {
      reason: pool.gateState === GateState.REF_DIVERGED ? 'gate-ref-diverged' : 'gate-not-green',
      detail: GateState[pool.gateState],
    }
  }
  if (!pool.placementAllowed) return {reason: 'placement-refused', detail: GateState[pool.gateState]}

  // 3. Divergence at entry. The vault re-checks it at exit too, which only the simulation can see.
  const divergence = abs(pool.poolTick - pool.fairTick)
  if (divergence > policy.placementDivergenceTicks) {
    return {reason: 'diverged', detail: `${divergence} ticks > ${policy.placementDivergenceTicks}`}
  }

  // 6. The 60-second per-pool cooldown.
  const readyAt = pool.lastPlacementAt === 0 ? 0 : pool.lastPlacementAt + policy.placementCooldownSeconds
  if (snapshot.now < readyAt) return {reason: 'cooldown', readyAt}

  // §12 ruling E: at the budget the bountied paths merge and idle, so the call is worth less than its gas.
  if (snapshot.vault.liveCells + policy.liveCellHeadroom > policy.maxLiveCells) {
    return {reason: 'cell-budget', detail: `${snapshot.vault.liveCells}/${policy.maxLiveCells} live cells`}
  }

  return {}
}

/** `compound(poolId)` — one per registered pool. */
export function screenCompound(pool: PoolSnapshot, snapshot: ChainSnapshot, policy: KeeperPolicy): Screening {
  const job = candidate('compound', pool.poolId)
  const global = globalRefusal(snapshot, policy)
  if (global !== undefined) return {candidate: job, eligible: false, reason: global}

  const placement = screenPlacement(pool, snapshot, policy)
  if (placement.reason !== undefined) {
    return {
      candidate: job,
      eligible: false,
      reason: placement.reason,
      ...(placement.readyAt === undefined ? {} : {readyAt: placement.readyAt}),
      ...(placement.detail === undefined ? {} : {detail: placement.detail}),
    }
  }
  return {candidate: job, eligible: true}
}

/**
 * `rollout(constituentId)` — one per ACTIVE constituent with a non-zero rollout weight.
 *
 * Both the source (an entry pool) and the destination spoke pay the full gauntlet inside the vault, so the
 * screen checks the destination and lets the simulation catch a refusal on either entry pool. A zero
 * `rolloutBpsPerDay` is governance switching rollout off, and is not a candidate at all.
 */
export function screenRollout(
  constituent: ConstituentSnapshot,
  pool: PoolSnapshot | undefined,
  snapshot: ChainSnapshot,
  policy: KeeperPolicy,
): Screening {
  const job = candidate('rollout', String(constituent.constituentId))
  const global = globalRefusal(snapshot, policy)
  if (global !== undefined) return {candidate: job, eligible: false, reason: global}

  if (constituent.status !== 1) return {candidate: job, eligible: false, reason: 'not-due', detail: 'not ACTIVE'}
  if (constituent.rolloutWeightBps === 0) {
    return {candidate: job, eligible: false, reason: 'not-due', detail: 'zero rollout weight'}
  }
  if (snapshot.vault.rolloutBpsPerDay === 0) {
    return {candidate: job, eligible: false, reason: 'not-due', detail: 'rollout disabled'}
  }
  if (pool === undefined) return {candidate: job, eligible: false, reason: 'not-due', detail: 'no pool'}

  // The destination spoke, and then the two entry pools rollout harvests from: `_harvestAsks` calls `place` on
  // each of them, so their cooldowns bind this job as much as the spoke's does.
  for (const target of [pool, ...snapshot.pools.filter((p) => p.constituentId === 0)]) {
    const placement = screenPlacement(target, snapshot, policy)
    if (placement.reason !== undefined) {
      return {
        candidate: job,
        eligible: false,
        reason: placement.reason,
        ...(placement.readyAt === undefined ? {} : {readyAt: placement.readyAt}),
        ...(placement.detail === undefined ? {} : {detail: `${placement.detail ?? ''} (${target.poolId.slice(0, 10)})`}),
      }
    }
  }
  return {candidate: job, eligible: true}
}

/**
 * `deployBonded(constituentId)` — one per ACTIVE constituent whose idle bonded collateral is worth at least
 * `deployThresholdUsd18`.
 *
 * The threshold check is the vault's own (§10 ruling 15): below it `deployBonded` returns zero *without paying
 * a bounty*, so a keeper that sent it anyway would be donating gas. Screening it out is the same decision the
 * contract makes, one round trip earlier.
 */
export function screenDeployBonded(
  constituent: ConstituentSnapshot,
  pool: PoolSnapshot | undefined,
  snapshot: ChainSnapshot,
  policy: KeeperPolicy,
): Screening {
  const job = candidate('deployBonded', String(constituent.constituentId))
  const global = globalRefusal(snapshot, policy)
  if (global !== undefined) return {candidate: job, eligible: false, reason: global}

  if (constituent.status !== 1) return {candidate: job, eligible: false, reason: 'not-due', detail: 'not ACTIVE'}
  if (constituent.idleCollateral === 0n) {
    return {candidate: job, eligible: false, reason: 'no-work', detail: 'no idle collateral'}
  }
  if (constituent.idleCollateralUsd18 < snapshot.vault.deployThresholdUsd18) {
    return {
      candidate: job,
      eligible: false,
      reason: 'below-deploy-threshold',
      detail: `${constituent.idleCollateralUsd18} < ${snapshot.vault.deployThresholdUsd18}`,
    }
  }
  if (pool === undefined) return {candidate: job, eligible: false, reason: 'not-due', detail: 'no pool'}

  const placement = screenPlacement(pool, snapshot, policy)
  if (placement.reason !== undefined) {
    return {
      candidate: job,
      eligible: false,
      reason: placement.reason,
      ...(placement.readyAt === undefined ? {} : {readyAt: placement.readyAt}),
      ...(placement.detail === undefined ? {} : {detail: placement.detail}),
    }
  }
  return {candidate: job, eligible: true}
}

/**
 * `checkpoint()` — unpaid, permissionless, and the one job whose whole purpose is to keep *another* path alive.
 *
 * `AmpsBonds` refuses to price against a checkpoint older than `Constants.CHECKPOINT_MAX_AGE` (1,800 s), so the
 * keeper refreshes at `checkpointRefreshAtSeconds` and leaves the rest of the window as margin for a missed
 * scan. `depositBonded` writes a fresh checkpoint of its own, so an active bond market keeps itself warm and
 * this fires only in the quiet.
 */
export function screenCheckpoint(snapshot: ChainSnapshot, policy: KeeperPolicy): Screening {
  const job = candidate('checkpoint', '')
  const global = globalRefusal(snapshot, policy)
  if (global !== undefined) return {candidate: job, eligible: false, reason: global}

  const age = snapshot.now - snapshot.vault.checkpointTimestamp
  if (snapshot.vault.checkpointTimestamp !== 0 && age < policy.checkpointRefreshAtSeconds) {
    return {
      candidate: job,
      eligible: false,
      reason: 'checkpoint-fresh',
      readyAt: snapshot.vault.checkpointTimestamp + policy.checkpointRefreshAtSeconds,
      detail: `age ${age}s`,
    }
  }
  return {candidate: job, eligible: true, detail: `age ${age}s`}
}

/**
 * `touch()` — unpaid, permissionless, and the layer-A watchdog's heartbeat.
 *
 * `AmpsVault.touch` pokes `OracleGate` **before** it checks the gate, and `OracleGate.poke()` stamps the
 * watchdog, so a `touch()` sent while the watchdog has tripped clears it inside the same transaction and then
 * passes the health check. That is what makes the keeper self-healing after an outage, and it is why `touch` is
 * screened against `WATCHDOG` rather than refused by it.
 */
export function screenTouch(snapshot: ChainSnapshot, policy: KeeperPolicy, lastTouchAt: number): Screening {
  const job = candidate('touch', '')
  if (snapshot.protocolFreezeUntil > snapshot.now) {
    return {candidate: job, eligible: false, reason: 'protocol-frozen'}
  }

  // The watchdog is the one gate state `touch` exists to clear, so it is not a refusal here.
  const healable = snapshot.globalGateState === GateState.WATCHDOG || snapshot.watchdogTripped
  if (!healable && !gateAdmits(snapshot.globalGateState, policy)) {
    return {candidate: job, eligible: false, reason: 'gate-not-green', detail: GateState[snapshot.globalGateState]}
  }
  if (healable) return {candidate: job, eligible: true, detail: 'watchdog tripped'}

  const readyAt = lastTouchAt + policy.touchIntervalSeconds
  if (snapshot.now < readyAt) return {candidate: job, eligible: false, reason: 'not-due', readyAt}
  return {candidate: job, eligible: true}
}

// ---------------------------------------------------------------------------------------------------------------
// The whole scan
// ---------------------------------------------------------------------------------------------------------------

/**
 * Screens every job the snapshot can produce, in a stable order: upkeep first (unpaid and cheap, and `touch`
 * is what un-trips the watchdog everything else is blocked by), then `compound` per pool, then `deployBonded`
 * and `rollout` per constituent.
 *
 * Returns **every** candidate, eligible or not, because the ineligible ones are the metrics: the operator wants
 * to see "30 pools, 28 on cooldown, 2 below chost", not silence.
 */
export function screen(snapshot: ChainSnapshot, policy: KeeperPolicy, lastTouchAt: number): Screening[] {
  const out: Screening[] = [screenTouch(snapshot, policy, lastTouchAt), screenCheckpoint(snapshot, policy)]

  for (const pool of snapshot.pools) out.push(screenCompound(pool, snapshot, policy))

  const poolById = new Map(snapshot.pools.map((p) => [p.poolId, p]))
  for (const constituent of snapshot.constituents) {
    const pool = poolById.get(constituent.poolId)
    out.push(screenDeployBonded(constituent, pool, snapshot, policy))
    out.push(screenRollout(constituent, pool, snapshot, policy))
  }
  return out
}

// ---------------------------------------------------------------------------------------------------------------
// Qualification: the simulation half
// ---------------------------------------------------------------------------------------------------------------

/** The work value the keeper measures for a job, from its simulated return value. */
export function measureWorkValueUsd18(
  kind: JobKind,
  result: unknown,
  snapshot: ChainSnapshot,
  constituent?: ConstituentSnapshot,
  pool?: PoolSnapshot,
): bigint {
  switch (kind) {
    case 'compound': {
      const [ampsFees, burned] = result as [bigint, bigint]
      const split = splitAmpsFees(
        ampsFees,
        snapshot.vault.creatorBps,
        pool?.sellFeeBps ?? 500,
        snapshot.vault.stakerBps,
        snapshot.vault.burnBps,
      )
      return compoundWorkValueUsd18(ampsFees, burned, split, pool?.pRefX18 ?? snapshot.vault.pRefX18)
    }
    case 'rollout': {
      const moved = result as bigint
      return (moved * snapshot.vault.pRefX18) / WAD
    }
    case 'deployBonded': {
      const placed = result as bigint
      if (constituent === undefined || constituent.idleCollateral === 0n) return 0n
      // Value the placed slice at the same rate the whole idle balance was valued at.
      return (constituent.idleCollateralUsd18 * placed) / constituent.idleCollateral
    }
    default:
      return 0n
  }
}

/**
 * The second half of the decision: given a simulation, is the job worth sending?
 *
 * The order is deliberate and matches the order a reader of `BountyPot` would expect:
 *
 *  1. the simulation must have succeeded (this is where R1, the exit divergence check and the transient lock
 *     land, none of which a `view` can see);
 *  2. unpaid jobs — `checkpoint` and `touch` — stop here: they have no bounty and are sent whenever they are
 *     due, which is what "unpaid by design, so it can never be griefed for profit" means;
 *  3. the keeper's own `chost` dust guard, against the work it **measured** rather than the flat $1 the vault
 *     reports (see `domain/bounty.ts` for why the on-chain guard cannot fire);
 *  4. the daily ceiling and the pot's balance, read straight out of the pot's own quote;
 *  5. profitability: the bounty the pot will actually pay against `gasEstimate x basefee`, with an optional
 *     margin. `ethUsd18 == 0` disables the check (a chain with no ETH/USD feed resolved — Phase 0's open item).
 */
export function qualify(
  screening: Screening,
  simulation: Simulation,
  snapshot: ChainSnapshot,
  policy: KeeperPolicy,
  constituent?: ConstituentSnapshot,
  pool?: PoolSnapshot,
): Verdict {
  const {candidate: job} = screening
  const base = {candidate: job, gasEstimate: simulation.gasEstimate}

  if (!simulation.ok) {
    return {
      ...base,
      send: false,
      reason: 'simulation-reverted',
      workValueUsd18: 0n,
      gasCostUsd18: 0n,
      bountyUsd18: 0n,
      detail: simulation.revert?.name ?? simulation.revert?.raw ?? 'revert',
    }
  }

  const gasCost = gasCostUsd18(simulation.gasEstimate, snapshot.baseFeeWei, snapshot.ethUsd18)

  if (!BOUNTIED_JOBS.includes(job.kind)) {
    return {...base, send: true, workValueUsd18: 0n, gasCostUsd18: gasCost, bountyUsd18: 0n}
  }

  const workValue = measureWorkValueUsd18(job.kind, simulation.result, snapshot, constituent, pool)
  const chost = policy.chostOverrideUsd18 ?? snapshot.pot.chostUsd18
  if (!meetsChost(workValue, chost)) {
    return {
      ...base,
      send: false,
      reason: 'below-chost',
      workValueUsd18: workValue,
      gasCostUsd18: gasCost,
      bountyUsd18: 0n,
      detail: `work ${workValue} < chost ${chost}`,
    }
  }

  // What the pot will actually pay: the vault reports flat $1/$1, whatever the keeper measured.
  const quote = quoteBounty(snapshot.pot, VAULT_REPORTED_WORK_VALUE_USD18, VAULT_REPORTED_GAS_ALLOWANCE_USD18)
  const bounty = quote.payableUsd18

  if (quote.reason === 'dailyCeiling') {
    return {
      ...base,
      send: false,
      reason: 'daily-ceiling',
      workValueUsd18: workValue,
      gasCostUsd18: gasCost,
      bountyUsd18: bounty,
      detail: 'the pot\'s rolling 24 h ceiling is exhausted',
    }
  }
  if (bounty === 0n && !policy.runUnpaid) {
    return {
      ...base,
      send: false,
      reason: quote.reason === 'chost' ? 'below-chost' : 'pot-depleted',
      workValueUsd18: workValue,
      gasCostUsd18: gasCost,
      bountyUsd18: 0n,
      detail: quote.reason,
    }
  }

  const required = gasCost + (gasCost * BigInt(policy.bountyMarginBps)) / BPS
  if (snapshot.ethUsd18 > 0n && !policy.runUnpaid && bounty < required) {
    return {
      ...base,
      send: false,
      reason: 'unprofitable',
      workValueUsd18: workValue,
      gasCostUsd18: gasCost,
      bountyUsd18: bounty,
      detail: `bounty ${bounty} < gas ${required}`,
    }
  }

  return {...base, send: true, workValueUsd18: workValue, gasCostUsd18: gasCost, bountyUsd18: bounty}
}
