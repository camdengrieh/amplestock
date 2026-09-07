// SPDX-License-Identifier: MIT

/**
 * Alert semantics.
 *
 * Two things raise an alert, and only two:
 *
 * 1. **The denylist alarm.** Any observation of the beacon-level denylist — a transaction carrying
 *    `blockAccounts(address[])` (`0x6abf7081`) to a watched contract, or an `isBlocked` probe that
 *    comes back true for one of our own addresses. `critical` when the accounts touch the vault,
 *    the PoolManager or any protocol contract (that is the predicate that unlocks
 *    `AmpsVault.emergencyMigrate`); `warning` otherwise, because the issuer blocking a third party
 *    is news but not our incident.
 * 2. **Reconciliation divergence.** The indexed NAV/share, `P_ref`, supply or inventory disagreeing
 *    with the chain read at the same block by more than the dust bound. `critical` on NAV or
 *    `P_ref`, `warning` on the rest — a supply or inventory drift is a bug in the indexer, a NAV
 *    drift means the number the dApp is showing is wrong.
 *
 * **The sink is a no-op by default.** Every alert is always written to the `alert` table, which is
 * the durable record and what the HTTP layer serves. Delivery on top of that is a single webhook:
 * set `AMPS_ALERT_WEBHOOK` and each alert is POSTed as JSON. Nothing is retried inside the
 * indexing function — a failed POST records `deliveryError` and the row stays queryable, because a
 * paging outage must never wedge the indexer.
 */

export type AlertSeverity = 'info' | 'warning' | 'critical'

export interface AlertPayload {
  kind: 'denylist' | 'reconciliation' | 'gate' | 'nav-bleed' | 'corporate-action'
  severity: AlertSeverity
  /** What the alert is about: a pool id, a token, a block. */
  subject: string
  message: string
  blockNumber: bigint
  timestamp: bigint
  detail: Record<string, unknown>
}

export interface AlertResult {
  delivered: boolean
  error?: string
}

export interface AlertSink {
  (alert: AlertPayload): Promise<AlertResult>
}

/** JSON with bigints rendered as decimal strings, so a webhook consumer gets something readable. */
export function serialiseAlert(alert: AlertPayload): string {
  return JSON.stringify(alert, (_key, value) =>
    typeof value === 'bigint' ? value.toString() : value,
  )
}

/** The default: record it, deliver nothing. */
export const noopSink: AlertSink = async () => ({delivered: false})

/** POST the alert as JSON. Never throws; a failure is reported, not raised. */
export function webhookSink(url: string, timeoutMs: number): AlertSink {
  return async (alert) => {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), timeoutMs)
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: serialiseAlert(alert),
        signal: controller.signal,
      })
      if (!response.ok) return {delivered: false, error: `HTTP ${response.status}`}
      return {delivered: true}
    } catch (error) {
      return {delivered: false, error: error instanceof Error ? error.message : String(error)}
    } finally {
      clearTimeout(timer)
    }
  }
}

let sink: AlertSink = noopSink

/** Install the sink the environment asks for. Called once, from `src/index.ts`. */
export function configureAlerts(url: string | undefined, timeoutMs: number): void {
  sink = url === undefined ? noopSink : webhookSink(url, timeoutMs)
}

/** Swap the sink out. Tests use this; nothing else should. */
export function setAlertSink(next: AlertSink): AlertSink {
  const previous = sink
  sink = next
  return previous
}

export function currentAlertSink(): AlertSink {
  return sink
}

/** Deliver through the installed sink. Always resolves. */
export async function deliver(alert: AlertPayload): Promise<AlertResult> {
  try {
    return await sink(alert)
  } catch (error) {
    return {delivered: false, error: error instanceof Error ? error.message : String(error)}
  }
}
