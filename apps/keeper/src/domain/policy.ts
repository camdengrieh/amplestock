// SPDX-License-Identifier: MIT

import {WAD} from './bounty.js'

/**
 * The keeper's thresholds, all of them derived from `contracts/src/types/Constants.sol` or from the plan's
 * keeper row, and every one of them overridable from the environment (see `src/config.ts`).
 *
 * Nothing here is a chain address or an endpoint: those are configuration, never constants, per the plan's
 * "Verified reference data" rule.
 */
export interface KeeperPolicy {
  /** `Constants.PLACEMENT_COOLDOWN_SECONDS`. */
  readonly placementCooldownSeconds: number
  /** `Constants.PLACEMENT_DIVERGENCE_TICKS`. */
  readonly placementDivergenceTicks: number
  /** `Constants.MAX_LIVE_CELLS` — the vault-wide budget of §12 ruling E. */
  readonly maxLiveCells: number
  /**
   * How many live cells must be free before a bountied placement is considered worth sending.
   *
   * At the budget the bountied paths **merge and idle** rather than revert (§12 ruling E), so the call still
   * succeeds, still stamps the cooldown and still pays the tip while doing a fraction of the work. That is the
   * definition of a call not worth making, so the keeper stops before the vault does.
   */
  readonly liveCellHeadroom: number
  /** `Constants.CHECKPOINT_MAX_AGE`: the age at which `AmpsBonds` refuses to price. */
  readonly checkpointMaxAgeSeconds: number
  /** Refresh the checkpoint once it is this old, leaving margin before bonds start reverting. */
  readonly checkpointRefreshAtSeconds: number
  /** Minimum gap between two `touch()` calls. The watchdog's `GRACE` is 3,600 s; this is well inside it. */
  readonly touchIntervalSeconds: number
  /**
   * Treat `REF_DIVERGED` as green. The vault permits it (`_requireGate` accepts `GREEN` and `REF_DIVERGED`, and
   * §3.8 step 2 permits it with the NAV anchor forced), so this is a policy choice rather than a safety one.
   * Off by default: the plan's Phase 4 line is "refuses to send when the gate is not GREEN".
   */
  readonly allowRefDiverged: boolean
  /** Client-side dust guard, 18-decimal USD. Defaults to whatever `BountyPot.chostUsd18()` reports. */
  readonly chostOverrideUsd18: bigint | null
  /** Require `bounty >= gasCost x (1 + margin)` before sending a bountied job. */
  readonly bountyMarginBps: number
  /** Run bountied jobs even when the pot cannot pay for them. Off by default. */
  readonly runUnpaid: boolean
  /** Multiply `eth_estimateGas` by this before submitting, in bps of the estimate. */
  readonly gasLimitBufferBps: number
  /** Never submit a transaction with a gas limit above this. */
  readonly gasLimitCeiling: bigint
  /** Seconds between scans. */
  readonly scanIntervalSeconds: number
  /** Give up on an in-flight transaction after this long and let the next scan re-decide. */
  readonly inFlightTimeoutSeconds: number
}

/** The launch policy: `Constants.sol` values, and the plan's keeper row. */
export const DEFAULT_POLICY: KeeperPolicy = {
  placementCooldownSeconds: 60,
  placementDivergenceTicks: 800,
  maxLiveCells: 512,
  liveCellHeadroom: 24,
  checkpointMaxAgeSeconds: 1800,
  checkpointRefreshAtSeconds: 1200,
  touchIntervalSeconds: 900,
  allowRefDiverged: false,
  chostOverrideUsd18: null,
  bountyMarginBps: 0,
  runUnpaid: false,
  gasLimitBufferBps: 2500,
  gasLimitCeiling: 30_000_000n,
  scanIntervalSeconds: 15,
  inFlightTimeoutSeconds: 300,
}

/** $1, the launch `chost`. Exported so tests and the CRE mirror do not re-derive it. */
export const LAUNCH_CHOST_USD18 = WAD
