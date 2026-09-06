// SPDX-License-Identifier: MIT

/**
 * A minimal Prometheus registry and text-exposition renderer.
 *
 * Hand-rolled rather than `prom-client` for one reason worth the hundred lines: the keeper has to install and
 * run offline in CI alongside three other agents editing the same lockfile, and a metrics client is the least
 * interesting dependency to fight over. The exposition format is the stable one
 * (`# HELP` / `# TYPE` / `name{labels} value`), which is all Prometheus, Grafana Agent and `promtool` need.
 *
 * Labels are sorted so two scrapes of an unchanged registry are byte-identical, which is what lets the tests
 * assert on the output.
 */

export type Labels = Readonly<Record<string, string>>

type MetricType = 'counter' | 'gauge' | 'histogram'

interface Series {
  readonly labels: Labels
  value: number
  /** Histogram only. */
  buckets?: number[]
  sum?: number
  count?: number
}

function labelKey(labels: Labels): string {
  const keys = Object.keys(labels).sort()
  return keys.map((k) => `${k}=${labels[k] ?? ''}`).join(',')
}

function renderLabels(labels: Labels, extra?: Readonly<Record<string, string>>): string {
  const merged: Record<string, string> = {...labels, ...(extra ?? {})}
  const keys = Object.keys(merged).sort()
  if (keys.length === 0) return ''
  const body = keys
    .map((k) => `${k}="${String(merged[k]).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`)
    .join(',')
  return `{${body}}`
}

class Metric {
  readonly name: string
  readonly help: string
  readonly type: MetricType
  readonly bucketBounds: readonly number[]
  private readonly series = new Map<string, Series>()

  constructor(name: string, help: string, type: MetricType, bucketBounds: readonly number[] = []) {
    this.name = name
    this.help = help
    this.type = type
    this.bucketBounds = bucketBounds
  }

  private at(labels: Labels): Series {
    const key = labelKey(labels)
    let s = this.series.get(key)
    if (s === undefined) {
      s = {labels, value: 0}
      if (this.type === 'histogram') {
        s.buckets = new Array<number>(this.bucketBounds.length).fill(0)
        s.sum = 0
        s.count = 0
      }
      this.series.set(key, s)
    }
    return s
  }

  inc(labels: Labels = {}, by = 1): void {
    this.at(labels).value += by
  }

  set(labels: Labels, value: number): void {
    this.at(labels).value = value
  }

  observe(labels: Labels, value: number): void {
    const s = this.at(labels)
    s.sum = (s.sum ?? 0) + value
    s.count = (s.count ?? 0) + 1
    const buckets = s.buckets ?? []
    for (let i = 0; i < this.bucketBounds.length; i += 1) {
      if (value <= (this.bucketBounds[i] as number)) buckets[i] = (buckets[i] ?? 0) + 1
    }
  }

  /** The current value of one series, for tests and for the `/health` payload. */
  get(labels: Labels = {}): number {
    return this.series.get(labelKey(labels))?.value ?? 0
  }

  render(): string {
    const lines: string[] = [`# HELP ${this.name} ${this.help}`, `# TYPE ${this.name} ${this.type}`]
    const sorted = [...this.series.values()].sort((a, b) => labelKey(a.labels).localeCompare(labelKey(b.labels)))
    for (const s of sorted) {
      if (this.type === 'histogram') {
        let cumulative = 0
        for (let i = 0; i < this.bucketBounds.length; i += 1) {
          cumulative = (s.buckets?.[i] ?? 0)
          lines.push(`${this.name}_bucket${renderLabels(s.labels, {le: String(this.bucketBounds[i])})} ${cumulative}`)
        }
        lines.push(`${this.name}_bucket${renderLabels(s.labels, {le: '+Inf'})} ${s.count ?? 0}`)
        lines.push(`${this.name}_sum${renderLabels(s.labels)} ${s.sum ?? 0}`)
        lines.push(`${this.name}_count${renderLabels(s.labels)} ${s.count ?? 0}`)
      } else {
        lines.push(`${this.name}${renderLabels(s.labels)} ${s.value}`)
      }
    }
    return lines.join('\n')
  }
}

/** The registry: create metrics through it, render all of them at once. */
export class Registry {
  private readonly metrics: Metric[] = []

  counter(name: string, help: string): Metric {
    const m = new Metric(name, help, 'counter')
    this.metrics.push(m)
    return m
  }

  gauge(name: string, help: string): Metric {
    const m = new Metric(name, help, 'gauge')
    this.metrics.push(m)
    return m
  }

  histogram(name: string, help: string, bounds: readonly number[]): Metric {
    const m = new Metric(name, help, 'histogram', bounds)
    this.metrics.push(m)
    return m
  }

  render(): string {
    return `${this.metrics.map((m) => m.render()).join('\n')}\n`
  }
}

/**
 * The keeper's metric set.
 *
 * Every counter that can be attributed to a job carries `{job}`; every refusal carries `{job, reason}`, and the
 * reasons are the closed `SkipReason` union so a dashboard can enumerate them. `docs/keeper-runbook.md` maps
 * each one to an operator action.
 */
export function createMetrics(registry = new Registry()) {
  return {
    registry,

    // ---- liveness -------------------------------------------------------------------------------------------
    up: registry.gauge('amps_keeper_up', 'One while the keeper process is serving.'),
    buildInfo: registry.gauge('amps_keeper_build_info', 'Static labels describing this keeper build.'),
    scans: registry.counter('amps_keeper_scans_total', 'Completed scan cycles.'),
    scanErrors: registry.counter('amps_keeper_scan_errors_total', 'Scan cycles that ended in an error.'),
    scanDuration: registry.histogram(
      'amps_keeper_scan_duration_seconds',
      'Wall time of one scan cycle.',
      [0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60],
    ),
    lastScanTimestamp: registry.gauge(
      'amps_keeper_last_scan_timestamp_seconds',
      'Unix time of the last completed scan. Alert when it stops advancing.',
    ),
    blockNumber: registry.gauge('amps_keeper_block_number', 'Head block number the last scan read.'),

    // ---- the gate -------------------------------------------------------------------------------------------
    gateState: registry.gauge(
      'amps_keeper_gate_state',
      'OracleGate state ordinal: 0 GREEN, 1 DEGRADED, 2 DIVERGED, 3 REF_DIVERGED, 4 SCHEDULED_FREEZE, 5 WATCHDOG.',
    ),
    watchdogTripped: registry.gauge('amps_keeper_watchdog_tripped', 'One while the layer-A watchdog has tripped.'),
    protocolFrozenUntil: registry.gauge(
      'amps_keeper_protocol_freeze_until_seconds',
      'Guardian protocol freeze expiry, unix seconds. Zero when not frozen.',
    ),
    poolGateState: registry.gauge('amps_keeper_pool_gate_state', 'Per-pool gate state ordinal.'),
    poolDivergenceTicks: registry.gauge(
      'amps_keeper_pool_divergence_ticks',
      'abs(slot0.tick - fairTick) per pool. The placement guard trips above 800.',
    ),
    poolLadderCells: registry.gauge(
      'amps_keeper_pool_ladder_cells',
      'Grid cells this pool holds a position in, at most GRID_CELLS (24). Their sum is the live-cell budget.',
    ),
    poolSurgeBps: registry.gauge(
      'amps_keeper_pool_surge_bps',
      'AmpsHook surge in force per pool. Armed by every placement, so it spikes right after the keeper acts.',
    ),
    poolHighWaterTick: registry.gauge(
      'amps_keeper_pool_high_water_tick',
      'The hook high-water mark the next compound buyback burn consumes, per pool.',
    ),
    poolLastSwapAge: registry.gauge(
      'amps_keeper_pool_last_swap_age_seconds',
      'Seconds since the hook last saw a swap in this pool. A pool nobody trades earns no fees to compound.',
    ),

    // ---- the vault ------------------------------------------------------------------------------------------
    navPerShare: registry.gauge('amps_keeper_nav_per_share_usd', 'Checkpointed NAV per share, USD.'),
    checkpointAge: registry.gauge(
      'amps_keeper_checkpoint_age_seconds',
      'Age of the vault checkpoint. AmpsBonds refuses to price above 1800.',
    ),
    liveCells: registry.gauge('amps_keeper_live_cells', 'AmpsVault.liveCells(): the vault-wide redemption budget.'),
    liveCellBudget: registry.gauge('amps_keeper_live_cell_budget', 'Constants.MAX_LIVE_CELLS.'),

    // ---- the pot --------------------------------------------------------------------------------------------
    potBalance: registry.gauge('amps_keeper_pot_balance_raw', 'BountyPot balance in raw token units.'),
    potBudgetLeft: registry.gauge('amps_keeper_pot_budget_left_usd', 'Daily ceiling left, USD.'),
    potSpent24h: registry.gauge('amps_keeper_pot_spent_24h_usd', 'Paid inside the open rolling window, USD.'),
    potQuoteUsd: registry.gauge(
      'amps_keeper_pot_quote_usd',
      'What BountyPot.quote answers for the flat work value and gas allowance the vault reports.',
    ),
    potQuoteReason: registry.gauge(
      'amps_keeper_pot_quote_reason',
      'One for the constraint currently binding the pot quote, labelled by reason.',
    ),

    // ---- decisions ------------------------------------------------------------------------------------------
    candidates: registry.gauge('amps_keeper_candidates', 'Candidates produced by the last scan, by job.'),
    eligible: registry.gauge('amps_keeper_eligible', 'Candidates that passed screening in the last scan, by job.'),
    skipped: registry.counter('amps_keeper_skipped_total', 'Candidates refused, by job and reason.'),
    simulations: registry.counter('amps_keeper_simulations_total', 'eth_call simulations run, by job.'),
    simulationReverts: registry.counter(
      'amps_keeper_simulation_reverts_total',
      'Simulations that reverted, by job and decoded error.',
    ),

    // ---- sends ----------------------------------------------------------------------------------------------
    sent: registry.counter('amps_keeper_sent_total', 'Transactions submitted, by job.'),
    confirmed: registry.counter('amps_keeper_confirmed_total', 'Transactions confirmed successful, by job.'),
    failed: registry.counter('amps_keeper_failed_total', 'Transactions that reverted on chain, by job.'),
    submitErrors: registry.counter('amps_keeper_submit_errors_total', 'Submitter errors, by job.'),
    inFlight: registry.gauge('amps_keeper_in_flight', 'Transactions the keeper believes are still pending.'),

    // ---- the bounty, and the gas the pot cannot see -----------------------------------------------------------
    gasEstimate: registry.histogram(
      'amps_keeper_gas_estimate',
      'eth_estimateGas for a qualified job, by job.',
      [100_000, 250_000, 500_000, 1e6, 2e6, 3e6, 5e6, 10e6, 30e6],
    ),
    gasUsed: registry.histogram(
      'amps_keeper_gas_used',
      'Gas actually burned by a confirmed job, by job.',
      [100_000, 250_000, 500_000, 1e6, 2e6, 3e6, 5e6, 10e6, 30e6],
    ),
    measuredWorkValue: registry.gauge(
      'amps_keeper_measured_work_value_usd',
      'Work value the keeper measured for the last qualified job, by job. Compare against the reported value.',
    ),
    reportedWorkValue: registry.gauge(
      'amps_keeper_reported_work_value_usd',
      'Work value the VAULT reports to BountyPot: a hardcoded $1 in v1, whatever the keeper measured.',
    ),
    measuredGasAllowance: registry.gauge(
      'amps_keeper_measured_gas_allowance_usd',
      'Gas allowance the keeper would report if the entry points accepted one. The gap against the reported $1 ' +
        'is what makes BountyPot gasCapMultiple inert; see docs/keeper-runbook.md.',
    ),
    reportedGasAllowance: registry.gauge(
      'amps_keeper_reported_gas_allowance_usd',
      'Gas allowance the VAULT reports to BountyPot: a hardcoded $1 in v1.',
    ),
    bountyExpected: registry.gauge('amps_keeper_bounty_expected_usd', 'Bounty the pot quoted for the last send.'),
    bountyPaid: registry.counter('amps_keeper_bounty_paid_usd_total', 'Bounty actually paid, from BountyPaid.'),
    unprofitable: registry.counter(
      'amps_keeper_unprofitable_total',
      'Jobs refused because the bounty did not cover gas, by job.',
    ),
    chostBlocked: registry.counter(
      'amps_keeper_chost_blocked_total',
      'Jobs refused by the keeper-side chost dust guard, by job. The on-chain guard cannot fire in v1.',
    ),
  }
}

export type Metrics = ReturnType<typeof createMetrics>
