// SPDX-License-Identifier: MIT

/**
 * The keeper's vocabulary: the chain snapshot it decides from, the jobs it can run, and the verdicts it can
 * reach. Nothing in this file imports viem, node, or anything else with an I/O surface — it is the contract
 * between `chain/` (which reads) and `domain/decide.ts` (which thinks), and the same contract the Chainlink CRE
 * mirror in `src/cre/` is written against.
 */

/** `Types.sol`'s `GateState`, ordinals preserved. */
export enum GateState {
  GREEN = 0,
  DEGRADED = 1,
  DIVERGED = 2,
  REF_DIVERGED = 3,
  SCHEDULED_FREEZE = 4,
  WATCHDOG = 5,
}

/** `Types.sol`'s `Session`, ordinals preserved. */
export enum Session {
  REGULAR = 0,
  PRE_POST = 1,
  OVERNIGHT = 2,
  CLOSED = 3,
}

/** `Types.sol`'s `PoolClass`, ordinals preserved. */
export enum PoolClass {
  NONE = 0,
  ENTRY = 1,
  SPOKE = 2,
  SPOKE_HIGH_VOL = 3,
}

/**
 * The permissionless jobs. Nothing else is ever sent — no re-centring, no re-widening (I35).
 *
 * `settle` is the odd one out and the only one that is not a call on the vault: it is
 * `AmpsGenesis.settle()`, it runs **once in the protocol's life**, and it retires itself the moment
 * it succeeds. It is here rather than in a separate process because it is the same shape as every
 * other job — read the chain, screen it, simulate it, send it — and because the failure a keeper
 * must not have at launch is "nobody was watching for the end block".
 */
export type JobKind = 'compound' | 'rollout' | 'deployBonded' | 'checkpoint' | 'touch' | 'settle'

/** Every job is bountied except the upkeep calls and `settle`, which are unpaid by design. */
export const BOUNTIED_JOBS: readonly JobKind[] = ['compound', 'rollout', 'deployBonded']

/**
 * Why a candidate was not sent. Every value is a metric label, so they are short, stable and closed —
 * `apps/keeper`'s dashboards group on them and the runbook lists them one by one.
 */
export type SkipReason =
  | 'gate-not-green'
  | 'gate-ref-diverged'
  | 'protocol-frozen'
  | 'placement-refused'
  | 'diverged'
  | 'cooldown'
  | 'cell-budget'
  | 'below-chost'
  | 'no-work'
  | 'unprofitable'
  | 'daily-ceiling'
  | 'pot-depleted'
  | 'checkpoint-fresh'
  | 'below-deploy-threshold'
  | 'not-due'
  | 'simulation-reverted'
  | 'in-flight'
  /** `settle`: the launch is already settled, or the adapter reports no auction at all. */
  | 'already-settled'

/** A job the keeper may run, before simulation. */
export interface JobCandidate {
  readonly kind: JobKind
  /**
   * `poolId` for `compound`, the decimal constituent id for `rollout`/`deployBonded`, `''` for the
   * two upkeep calls, and the adapter's address for `settle` — which is also the address the
   * transaction goes **to**, and the only job for which that is not the vault.
   */
  readonly target: string
  /** Stable identity for de-duplication and metrics: `<kind>:<target>`. */
  readonly key: string
}

/** Screening verdict: eligible, or not, with the reason and (for `cooldown`) when to try again. */
export interface Screening {
  readonly candidate: JobCandidate
  readonly eligible: boolean
  readonly reason?: SkipReason
  /** Unix seconds after which this candidate is worth screening again. */
  readonly readyAt?: number
  /** Human-readable detail for the log line. Never used for control flow. */
  readonly detail?: string
}

/** What one pool looks like to the keeper. Every field comes from a `view` that cannot revert. */
export interface PoolSnapshot {
  readonly poolId: `0x${string}`
  readonly poolClass: PoolClass
  readonly constituentId: number
  readonly counter: `0x${string}`
  readonly gateState: GateState
  /** `OracleGate.isPlacementAllowed(poolId).allowed`. */
  readonly placementAllowed: boolean
  /** `OracleGate.isPlacementAllowed(poolId).anchorAtNav` — true under `REF_DIVERGED`. */
  readonly anchorAtNav: boolean
  readonly poolTick: number
  readonly fairTick: number
  /** `AmpsVault.ladderLength(poolId)`: grid cells this pool's ladder occupies, at most `GRID_CELLS` (24). */
  readonly ladderCells: number
  /** The newest `placedAt` across the pool's ladder, the keeper's lower bound on the cooldown clock. */
  readonly lastPlacementAt: number
  /** `AmpsHook.highWaterTick(poolId)`: the mark the next `compound`'s buyback burn consumes. */
  readonly highWaterTick: number
  /** `AmpsHook.poolState(poolId).surgeBps`: the surge armed by the last placement or session open. */
  readonly surgeBps: number
  /** `AmpsHook.poolState(poolId).lastSwapAt`. Zero on a pool nobody has traded yet. */
  readonly lastSwapAt: number
  /** `AmpsHook.poolState(poolId).initialized`. False means the hook has never seen this pool. */
  readonly hookInitialized: boolean
  readonly session: Session
  readonly feedStale: boolean
  readonly corporateFreeze: boolean
  readonly pRefX18: bigint
  readonly navPerShareX18: bigint
  readonly ampsFeeBps: number
}

/** What one constituent looks like: the rollout and bonded-deployment targets. */
export interface ConstituentSnapshot {
  readonly constituentId: number
  readonly token: `0x${string}`
  readonly poolId: `0x${string}`
  readonly decimals: number
  /** `ConstituentStatus`: 1 = ACTIVE. Only ACTIVE constituents are ever targeted. */
  readonly status: number
  /** Idle bonded collateral, raw units: the vault's ERC-20 balance plus its ERC-6909 claim. */
  readonly idleCollateral: bigint
  /** {@link idleCollateral} valued at the feed, 18-decimal USD. Zero when the feed is unreadable. */
  readonly idleCollateralUsd18: bigint
  readonly rolloutWeightBps: number
}

/**
 * `AmpsGenesis`, as the keeper sees it.
 *
 * `phase` is the whole decision. The adapter derives it from the block number and its own state, so
 * `Ended` means precisely "every created leg's end block has passed and `settle()` has not run" —
 * which is precisely when `settle()` is callable. Reading the two auctions' end blocks separately
 * would reconstruct the same answer out of more reads and a comparison the contract already makes.
 */
export interface GenesisSnapshot {
  readonly address: `0x${string}`
  readonly phase: GenesisPhase
  readonly settled: boolean
  /** Disclosure only: which legs exist. `settle()` needs neither. */
  readonly usdgAuction: `0x${string}`
  readonly ethAuction: `0x${string}`
}

/** `IAmpsGenesis.Phase`, ordinals preserved. */
export enum GenesisPhase {
  Created = 0,
  Bidding = 1,
  Ended = 2,
  Settled = 3,
  Aborted = 4,
}

/** The bounty pot, as the keeper sees it. */
export interface PotSnapshot {
  readonly address: `0x${string}`
  readonly tipUsd18: bigint
  readonly chipBps: number
  readonly chostUsd18: bigint
  readonly gasCapMultiple: number
  readonly dailyCeilingUsd18: bigint
  readonly spentLast24hUsd18: bigint
  readonly budgetLeftUsd18: bigint
  /** Raw token units held by the pot. */
  readonly balanceRaw: bigint
  /** `10 ** (18 - token.decimals())`. */
  readonly usdScale: bigint
  /**
   * What `BountyPot.quote` answers for the arguments the **vault** passes, which in v1 are the flat
   * `WORK_VALUE_USD18 = 1e18` and `GAS_ALLOWANCE_USD18 = 1e18` hardcoded in `VaultPlacementLib` and
   * `VaultRolloutLib`. This is the payment a bountied job actually produces, whatever the keeper measures.
   */
  readonly quotedPayableRaw: bigint
  readonly quotedReason: string
}

/** The vault's governed parameters and its checkpoint, as the keeper sees them. */
export interface VaultSnapshot {
  readonly address: `0x${string}`
  readonly navPerShareX18: bigint
  readonly pRefX18: bigint
  readonly pMktX18: bigint
  readonly checkpointTimestamp: number
  readonly liveCells: number
  /** `AmpsVault.creatorBpsAt(now)`: 100 bp at genesis, decaying linearly to zero at genesis + 30 days.
   *  There is no `burnBps` or `stakerBps` beside it — the AMPS-side remainder is burned unconditionally. */
  readonly creatorBps: number
  readonly deployThresholdUsd18: bigint
  readonly rolloutBpsPerDay: number
  readonly entryFloorBps: number
}

/** Everything one scan reads, and the only thing {@link screen} is allowed to look at. */
export interface ChainSnapshot {
  /** Unix seconds of the block the snapshot was taken at. */
  readonly now: number
  readonly blockNumber: bigint
  /** `OracleGate.state(0)`: the vault-wide gate `_requireHealthy` reads. */
  readonly globalGateState: GateState
  readonly protocolFreezeUntil: number
  readonly watchdogTripped: boolean
  readonly vault: VaultSnapshot
  readonly pot: PotSnapshot
  readonly pools: readonly PoolSnapshot[]
  readonly constituents: readonly ConstituentSnapshot[]
  /**
   * The genesis adapter, while there is one to watch.
   *
   * Absent means "no settle job": either no adapter is configured, or `settled()` came back true
   * once and the reader latched the reads off for the life of the process. A launch is settled
   * exactly once and never un-settles, so continuing to read it would be four RPC calls a scan
   * for an answer that cannot change.
   */
  readonly genesis?: GenesisSnapshot
  /** `block.baseFeePerGas`, wei. Used for the profitability check. */
  readonly baseFeeWei: bigint
  /** ETH price in 18-decimal USD, from configuration or a feed. Zero disables the profitability check. */
  readonly ethUsd18: bigint
}

/**
 * What the vault reported to `BountyPot`, read out of a simulated or confirmed `BountyPaid` log.
 *
 * This is the authoritative answer to both questions the keeper asks about a bountied job: what the vault
 * measured the work to be worth, and what the pot actually paid for it. `reason` is `BountyPot`'s own
 * enumeration — `''` when something was payable, otherwise `chost`, `gasCap`, `dailyCeiling` or `depleted`.
 */
export interface BountyReport {
  readonly workValueUsd18: bigint
  readonly paidUsd18: bigint
  readonly paidRaw: bigint
  readonly reason: string
}

/** The result of `eth_call`-ing a job, plus the gas `eth_estimateGas` measured for it. */
export interface Simulation {
  readonly ok: boolean
  /** Decoded return value, job-specific. `undefined` when the call reverted. */
  readonly result?: unknown
  readonly gasEstimate: bigint
  /** Decoded revert, when `ok` is false. */
  readonly revert?: {readonly name: string; readonly args: readonly unknown[]; readonly raw: string}
  /**
   * The `BountyPaid` the job would emit, when the node supports `eth_simulateV1` and the job is bountied.
   *
   * Absent on a node without it — Arbitrum Nitro does not guarantee the method — in which case the keeper falls
   * back to its own lower-bound estimate of the work value and to {@link quoteBounty} for the payout.
   */
  readonly bounty?: BountyReport
}

/** The final verdict on one candidate, after simulation. */
export interface Verdict {
  readonly candidate: JobCandidate
  readonly send: boolean
  readonly reason?: SkipReason
  /** 18-decimal USD value of the work the job would do, as the keeper measures it. */
  readonly workValueUsd18: bigint
  /** 18-decimal USD cost of the gas the job would burn, at the snapshot's basefee. */
  readonly gasCostUsd18: bigint
  /** 18-decimal USD the pot would actually pay for it. */
  readonly bountyUsd18: bigint
  readonly gasEstimate: bigint
  /**
   * True when the bounty figures came from the vault's own `BountyPaid`, false when they are the keeper's
   * estimate. The distinction is the difference between knowing the payout and predicting it.
   */
  readonly reportedBounty: boolean
  readonly detail?: string
}
