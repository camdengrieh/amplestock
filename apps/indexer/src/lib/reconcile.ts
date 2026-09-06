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
