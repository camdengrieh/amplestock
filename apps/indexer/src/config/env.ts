// SPDX-License-Identifier: MIT

/**
 * Everything the indexer reads out of the environment, in one place, with the defaults that make
 * `pnpm --filter @amplestocks/indexer dev` work against a local anvil with nothing exported.
 *
 * The database follows Ponder's own rule and this repository's: **PGlite for local and CI**, and
 * Postgres as soon as `DATABASE_URL` (or `DATABASE_PRIVATE_URL`) is present. Nothing else switches
 * it, so a production process cannot silently fall back to an ephemeral store.
 */

import {AMPS_MAINNET_CHAIN_ID, chainById, type AmpsChainId} from '@amplestocks/config'

const num = (value: string | undefined, fallback: number): number => {
  if (value === undefined || value.trim() === '') return fallback
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) throw new Error(`[indexer] not a number: ${value}`)
  return parsed
}

const bool = (value: string | undefined, fallback: boolean): boolean => {
  if (value === undefined || value.trim() === '') return fallback
  return ['1', 'true', 'yes', 'on'].includes(value.trim().toLowerCase())
}

export interface IndexerEnv {
  chainId: number
  /** Ponder's chain key. Kept stable so table contents survive a chain-id change on a devnet. */
  chainName: 'amps'
  rpcUrl: string
  wsUrl: string | undefined
  /** First block to index. The block the vault was deployed in, on a real deployment. */
  startBlock: number
  /** Last block to index, or `undefined` for "follow the head". */
  endBlock: number | undefined
  pollingInterval: number
  /** Block cadence of the `uiMultiplier()` / `oraclePaused()` state-diff poll. */
  multiplierPollInterval: number
  /** Block cadence of the NAV + inventory reconciliation job. */
  reconcilePollInterval: number
  /** Reconciliation is also run at every block that carries a `NavCheckpoint`. */
  reconcileOnCheckpoint: boolean
  /** Absolute divergence budget for NAV/share and `P_ref`, in basis points. */
  dustBps: number
  /** Absolute divergence budget in wei, applied in parallel with `dustBps`. */
  dustWei: bigint
  /** POST target for alerts. Unset means the no-op sink (log only). */
  alertWebhookUrl: string | undefined
  alertWebhookTimeoutMs: number
  /** Postgres when set, PGlite otherwise. */
  databaseUrl: string | undefined
  pgliteDirectory: string
}

export function readEnv(env: NodeJS.ProcessEnv = process.env): IndexerEnv {
  const chainId = num(env.AMPS_CHAIN_ID, AMPS_MAINNET_CHAIN_ID)
  const known = chainById[chainId as AmpsChainId] as {rpcUrls: {http: readonly string[]; webSocket: readonly string[]}} | undefined
  const rpcUrl = env.AMPS_RPC_URL?.trim() || known?.rpcUrls.http[0] || 'http://127.0.0.1:8545'
  const wsUrl = env.AMPS_WS_URL?.trim() || undefined
  const endBlockRaw = env.AMPS_END_BLOCK?.trim()

  return {
    chainId,
    chainName: 'amps',
    rpcUrl,
    wsUrl,
    startBlock: num(env.AMPS_START_BLOCK, 0),
    endBlock: endBlockRaw === undefined || endBlockRaw === '' ? undefined : num(endBlockRaw, 0),
    pollingInterval: num(env.AMPS_POLLING_INTERVAL_MS, 1_000),
    multiplierPollInterval: num(env.AMPS_MULTIPLIER_POLL_BLOCKS, 300),
    reconcilePollInterval: num(env.AMPS_RECONCILE_POLL_BLOCKS, 300),
    reconcileOnCheckpoint: bool(env.AMPS_RECONCILE_ON_CHECKPOINT, true),
    dustBps: num(env.AMPS_DUST_BPS, 2),
    dustWei: BigInt(env.AMPS_DUST_WEI?.trim() || '1000000000000'),
    alertWebhookUrl: env.AMPS_ALERT_WEBHOOK?.trim() || undefined,
    alertWebhookTimeoutMs: num(env.AMPS_ALERT_WEBHOOK_TIMEOUT_MS, 5_000),
    databaseUrl: env.DATABASE_PRIVATE_URL?.trim() || env.DATABASE_URL?.trim() || undefined,
    pgliteDirectory: env.AMPS_PGLITE_DIR?.trim() || '.ponder/pglite',
  }
}
