// SPDX-License-Identifier: MIT

/**
 * The reconciliation rule, as a pure function so it can be tested without a chain.
 *
 * **What is compared, and what is only recorded.** Six pairs are measured; three of them *breach*.
 *
 * | field | indexed | chain | breaches |
 * |---|---|---|---|
 * | NAV/share | the last `NavCheckpoint`'s `navPerShareX18` | `checkpointData().navPerShareX18` | yes |
 * | `P_ref` | the last `RefCheckpoint`'s `pRefX18` | `checkpointData().pRefX18` | yes |
 * | total supply | `S0 + VestingMinted - Burn - Redeem.shares`, from the events | `Amps.totalSupply()` | yes |
 * | NAV/share, live | — | `previewNavPerShareX18()` | no |
 * | `A` | the last checkpoint's `totalAssetsUsd18` | `vault.totalAssetsUsd18()` | no |
 * | inventory | the last sample | `vault.inventoryAmps()` | no |
 *
 * The three that do not breach are not slack, they are **not comparable**. A chain read is
 * end-of-block state and the checkpoint is what the vault last *wrote*, so
 * `previewNavPerShareX18()` and `totalAssetsUsd18()` — both live recomputations — differ from the
 * checkpoint whenever a price has moved since, which is the normal case and is exactly what
 * `previewDeltaBps` is *for*: it says how stale the displayed NAV is. `inventoryAmps()` has no
 * event-derived counterpart at all, so both sides of that pair are the same chain read and it can
 * only ever agree; it is carried because the number itself belongs on the dashboard.
 *
 * Total supply, by contrast, is a genuine two-sided check: the indexed side is accumulated from the
 * events alone and never from a chain read, so a disagreement means the indexer's own bookkeeping
 * has drifted from the chain — which is precisely the bug this job exists to catch.
 *
 * **The dust bound is two-sided and conjunctive.** A pair passes when it is within `dustBps` of
 * relative divergence *or* within `dustWei` of absolute divergence — small absolute drifts on tiny
 * numbers must not fail on a relative bound, and large relative drifts on large numbers must not
 * pass on an absolute one. Defaults: `dustBps = 2` (the same 2 bp R1 allows a single `compound` to
 * bleed, §3.6) and `dustWei = 1e12` (1e-6 AMPS, or 1e-6 USD at 18 decimals — three orders of
 * magnitude above the `+1`/`VIRTUAL_SHARES` rounding in the NAV formula and far below anything
 * economically visible).
 *
 * **`previewNavPerShareX18` is compared, not asserted.** `checkpointData()` is what the last
 * checkpoint *wrote*; `previewNavPerShareX18()` is what a checkpoint taken right now would write.
 * They differ legitimately whenever a price has moved since the last checkpoint, so the preview
 * divergence is recorded and never breaches on its own. It is the number that says how stale the
 * displayed NAV is.
 */

import {abs, divergenceBps} from './math'

export interface ReconcileBounds {
  dustBps: number
  dustWei: bigint
}

export interface ReconcileInput extends ReconcileBounds {
  /** What triggered the run. Recorded; it does not change which pairs are compared. */
  trigger: 'checkpoint' | 'interval'
  navIndexedX18: bigint
  navOnChainX18: bigint
  navPreviewX18: bigint
  pRefIndexedX18: bigint
  pRefOnChainX18: bigint
  supplyIndexed: bigint
  supplyOnChain: bigint
  inventoryIndexed: bigint
  inventoryOnChain: bigint
  assetsIndexedUsd18: bigint
  assetsOnChainUsd18: bigint
}

export interface ReconcileResult {
  navDeltaWei: bigint
  navDeltaBps: number
  previewDeltaBps: number
  pRefDeltaWei: bigint
  pRefDeltaBps: number
  supplyDeltaWei: bigint
  inventoryDeltaWei: bigint
  assetsDeltaBps: number
  ok: boolean
  /** The fields that breached, joined by `+`. Empty when `ok`. */
  breached: string
  breachedFields: string[]
}

/** Within the dust bound on either measure. */
export function withinDust(a: bigint, b: bigint, bounds: ReconcileBounds): boolean {
  if (abs(a - b) <= bounds.dustWei) return true
  return divergenceBps(a, b) <= bounds.dustBps
}

export function reconcile(input: ReconcileInput): ReconcileResult {
  const bounds = {dustBps: input.dustBps, dustWei: input.dustWei}
  const breachedFields: string[] = []

  if (!withinDust(input.navIndexedX18, input.navOnChainX18, bounds)) breachedFields.push('nav')
  if (!withinDust(input.pRefIndexedX18, input.pRefOnChainX18, bounds)) breachedFields.push('pRef')
  if (!withinDust(input.supplyIndexed, input.supplyOnChain, bounds)) breachedFields.push('supply')

  return {
    navDeltaWei: input.navIndexedX18 - input.navOnChainX18,
    navDeltaBps: divergenceBps(input.navIndexedX18, input.navOnChainX18),
    previewDeltaBps: divergenceBps(input.navOnChainX18, input.navPreviewX18),
    pRefDeltaWei: input.pRefIndexedX18 - input.pRefOnChainX18,
    pRefDeltaBps: divergenceBps(input.pRefIndexedX18, input.pRefOnChainX18),
    supplyDeltaWei: input.supplyIndexed - input.supplyOnChain,
    inventoryDeltaWei: input.inventoryIndexed - input.inventoryOnChain,
    assetsDeltaBps: divergenceBps(input.assetsIndexedUsd18, input.assetsOnChainUsd18),
    ok: breachedFields.length === 0,
    breached: breachedFields.join('+'),
    breachedFields,
  }
}

/** `critical` when NAV or `P_ref` moved, `warning` for a bookkeeping drift. */
export function reconcileSeverity(result: ReconcileResult): 'warning' | 'critical' {
  return result.breachedFields.some((f) => f === 'nav' || f === 'pRef') ? 'critical' : 'warning'
}

/**
 * The `redeem-gap` verdict (SP-14), as a pure function.
 *
 * `expectedUsd18` is the NAV basis net of the fee; `realisedUsd18` is what `previewRedeem` pays,
 * valued at the indexed feed answers. Only a **shortfall** counts: the vault rounds every position
 * slice down in its own favour, so the realised payout is expected to sit a hair under the basis,
 * and a payout that came out *above* it is a valuation artefact of the indexer's own feed snapshot
 * rather than something a redeemer can complain about. Thresholds are the accepted ones: `warning`
 * over 10 bp, `critical` over 25 bp, which is the ceiling the fuzz lead's slack was accepted at.
 */
export function redeemGapSeverity(gapBps: number): 'warning' | 'critical' | undefined {
  if (gapBps > REDEEM_GAP_CRITICAL_BPS) return 'critical'
  if (gapBps > REDEEM_GAP_WARNING_BPS) return 'warning'
  return undefined
}

export const REDEEM_GAP_WARNING_BPS = 10
export const REDEEM_GAP_CRITICAL_BPS = 25

/**
 * The shortfall of a realised payout against the NAV basis, in bps. Zero when the payout met or
 * beat the basis — an overshoot is not a gap.
 */
export function redeemGapBps(expectedUsd18: bigint, realisedUsd18: bigint): number {
  if (expectedUsd18 <= 0n || realisedUsd18 >= expectedUsd18) return 0
  return Number(((expectedUsd18 - realisedUsd18) * 10_000n) / expectedUsd18)
}

/** NAV/share fell by more than this between two checkpoints: the `nav-drift` trigger (L-1). */
export const NAV_DRIFT_BPS = 1

/**
 * Whether a checkpoint is a `nav-drift`: NAV/share below the previous one by more than 1 bp, with
 * nothing between the two that is allowed to move it.
 *
 * The "nothing between" half is the whole test. A `Bond`, `Redeem`, `Placement`, `Compound` or
 * `Swap` moves the assets; a feed `AnswerUpdated` moves their price. A fall with none of those is
 * the convergence step L-1 described, and it is the only case worth a page.
 */
export function isNavDrift(params: {
  previousNavX18: bigint
  navX18: bigint
  movedSincePrevious: boolean
}): boolean {
  if (params.movedSincePrevious) return false
  if (params.previousNavX18 <= 0n || params.navX18 >= params.previousNavX18) return false
  const fallBps = Number(((params.previousNavX18 - params.navX18) * 10_000n) / params.previousNavX18)
  return fallBps > NAV_DRIFT_BPS
}
