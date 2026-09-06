// SPDX-License-Identifier: MIT

/**
 * Configuration. **Every endpoint and every address is configuration** — the plan's "Verified reference data"
 * table is a starting point that Phase 0 re-verifies on chain, so nothing here is a literal in a code path.
 * The RPC defaults come from `@amplestocks/config`'s chain records, which is the one place the 4663 and 46630
 * endpoints are written down.
 *
 * The only address the keeper needs given to it is **AMPS**. Everything else is resolved from the chain:
 * `Amps.vault()` names the live vault (so an `emergencyMigrate` is followed without a redeploy), and the vault
 * names the registry, the bonds, the staking contract, the bounty pot, the oracle gate and the hook. That is
 * what "tolerates reverting pointers gracefully" means in practice: the topology is a read, not a config file.
 */

import {chains, chainById, type AmpsChainId} from '@amplestocks/config'
import {DEFAULT_POLICY, type KeeperPolicy} from './domain/policy.js'
import type {Level} from './logger.js'

export type SubmitterKind = 'relayer' | 'local'

export interface RelayerConfig {
  /** Base URL of the self-hosted openzeppelin-relayer, e.g. `http://relayer:8080`. */
  readonly url: string
  /** The relayer id the keeper submits through. */
  readonly relayerId: string
  /** Bearer token. Read from the environment; never logged. */
  readonly apiKey: string
  /** `speed` hint passed with every transaction. */
  readonly speed: 'safeLow' | 'average' | 'fast' | 'fastest'
  readonly timeoutMs: number
}

export interface KeeperConfig {
  readonly chainId: number
  readonly rpcUrl: string
  readonly wsUrl: string | null
  /** The AMPS token. The single address the keeper is told; everything else is derived. */
  readonly ampsAddress: `0x${string}`
  /** Optional: skip `Amps.vault()` and pin the vault. Useful on a fixture chain. */
  readonly vaultOverride: `0x${string}` | null
  /** Optional: `AmpsQuoter`, which answers the whole per-pool scan in one call when present. */
  readonly quoterAddress: `0x${string}` | null
  /** The address the keeper's transactions come from, for simulation. */
  readonly senderAddress: `0x${string}`
  readonly submitter: SubmitterKind
  readonly relayer: RelayerConfig | null
  /** Local-signer fallback (anvil, and only anvil). */
  readonly privateKey: `0x${string}` | null
  readonly metricsPort: number
  readonly metricsHost: string
  readonly logLevel: Level
  readonly policy: KeeperPolicy
  /**
   * ETH price in 18-decimal USD for the profitability check. Zero disables it, which is the honest setting
   * until Phase 0 resolves the ETH/USD feed on 4663 (the plan lists it as "to be confirmed from the RDD").
   */
  readonly ethUsd18: bigint
  /** Where the best-effort pending-transaction cache lives. Deleting it must never change behaviour. */
  readonly stateFile: string | null
  /** Run one scan and exit. What the chain suite drives. */
  readonly once: boolean
}

class ConfigError extends Error {}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name]
  if (value === undefined || value === '') throw new ConfigError(`${name} is required`)
  return value
}

function address(env: NodeJS.ProcessEnv, name: string, fallback?: `0x${string}`): `0x${string}` {
  const raw = env[name]
  if (raw === undefined || raw === '') {
    if (fallback !== undefined) return fallback
    throw new ConfigError(`${name} is required`)
  }
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) throw new ConfigError(`${name} is not an address: ${raw}`)
  return raw as `0x${string}`
}

function optionalAddress(env: NodeJS.ProcessEnv, name: string): `0x${string}` | null {
  const raw = env[name]
  if (raw === undefined || raw === '') return null
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) throw new ConfigError(`${name} is not an address: ${raw}`)
  return raw as `0x${string}`
}

function num(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name]
  if (raw === undefined || raw === '') return fallback
  const parsed = Number(raw)
  if (!Number.isFinite(parsed)) throw new ConfigError(`${name} is not a number: ${raw}`)
  return parsed
}

function big(env: NodeJS.ProcessEnv, name: string, fallback: bigint): bigint {
  const raw = env[name]
  if (raw === undefined || raw === '') return fallback
  try {
    return BigInt(raw)
  } catch {
    throw new ConfigError(`${name} is not an integer: ${raw}`)
  }
}

function bool(env: NodeJS.ProcessEnv, name: string, fallback: boolean): boolean {
  const raw = env[name]
  if (raw === undefined || raw === '') return fallback
  return raw === '1' || raw.toLowerCase() === 'true'
}

/** The default RPC for a chain the workspace knows, or `null` for anything else (anvil, a fork). */
export function defaultRpcUrl(chainId: number): string | null {
  const known = (chainById as Record<number, {rpcUrls: {http: readonly string[]}} | undefined>)[chainId]
  return known?.rpcUrls.http[0] ?? null
}

/** The default websocket for a chain the workspace knows. */
export function defaultWsUrl(chainId: number): string | null {
  const known = (chainById as Record<number, {rpcUrls: {webSocket: readonly string[]}} | undefined>)[chainId]
  return known?.rpcUrls.webSocket[0] ?? null
}

/** The chain ids the address book covers. Exported so the runbook and the tests agree on them. */
export const KNOWN_CHAIN_IDS: readonly AmpsChainId[] = [chains.mainnet.id, chains.testnet.id]

/**
 * Builds the configuration from an environment. Throws {@link ConfigError} with the offending variable named,
 * because a keeper that starts against the wrong chain is worse than one that refuses to start.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): KeeperConfig {
  const chainId = num(env, 'AMPS_CHAIN_ID', chains.testnet.id)
  const rpcUrl = env.AMPS_RPC_URL ?? defaultRpcUrl(chainId)
  if (rpcUrl === undefined || rpcUrl === null || rpcUrl === '') {
    throw new ConfigError(`AMPS_RPC_URL is required for chain ${chainId} (no default in @amplestocks/config)`)
  }

  const submitter = (env.AMPS_SUBMITTER ?? 'relayer') as SubmitterKind
  if (submitter !== 'relayer' && submitter !== 'local') {
    throw new ConfigError(`AMPS_SUBMITTER must be "relayer" or "local", got ${submitter}`)
  }

  const relayer: RelayerConfig | null =
    submitter === 'relayer'
      ? {
          url: required(env, 'AMPS_RELAYER_URL'),
          relayerId: required(env, 'AMPS_RELAYER_ID'),
          apiKey: required(env, 'AMPS_RELAYER_API_KEY'),
          speed: (env.AMPS_RELAYER_SPEED ?? 'fast') as RelayerConfig['speed'],
          timeoutMs: num(env, 'AMPS_RELAYER_TIMEOUT_MS', 30_000),
        }
      : null

  const privateKeyRaw = env.AMPS_PRIVATE_KEY
  if (submitter === 'local' && (privateKeyRaw === undefined || privateKeyRaw === '')) {
    throw new ConfigError('AMPS_PRIVATE_KEY is required when AMPS_SUBMITTER=local')
  }

  const policy: KeeperPolicy = {
    ...DEFAULT_POLICY,
    placementCooldownSeconds: num(env, 'AMPS_PLACEMENT_COOLDOWN_SECONDS', DEFAULT_POLICY.placementCooldownSeconds),
    placementDivergenceTicks: num(env, 'AMPS_PLACEMENT_DIVERGENCE_TICKS', DEFAULT_POLICY.placementDivergenceTicks),
    maxLiveCells: num(env, 'AMPS_MAX_LIVE_CELLS', DEFAULT_POLICY.maxLiveCells),
    liveCellHeadroom: num(env, 'AMPS_LIVE_CELL_HEADROOM', DEFAULT_POLICY.liveCellHeadroom),
    checkpointRefreshAtSeconds: num(
      env,
      'AMPS_CHECKPOINT_REFRESH_SECONDS',
      DEFAULT_POLICY.checkpointRefreshAtSeconds,
    ),
    touchIntervalSeconds: num(env, 'AMPS_TOUCH_INTERVAL_SECONDS', DEFAULT_POLICY.touchIntervalSeconds),
    allowRefDiverged: bool(env, 'AMPS_ALLOW_REF_DIVERGED', DEFAULT_POLICY.allowRefDiverged),
    chostOverrideUsd18: env.AMPS_CHOST_USD18 === undefined ? null : big(env, 'AMPS_CHOST_USD18', 0n),
    bountyMarginBps: num(env, 'AMPS_BOUNTY_MARGIN_BPS', DEFAULT_POLICY.bountyMarginBps),
    runUnpaid: bool(env, 'AMPS_RUN_UNPAID', DEFAULT_POLICY.runUnpaid),
    gasLimitBufferBps: num(env, 'AMPS_GAS_LIMIT_BUFFER_BPS', DEFAULT_POLICY.gasLimitBufferBps),
    gasLimitCeiling: big(env, 'AMPS_GAS_LIMIT_CEILING', DEFAULT_POLICY.gasLimitCeiling),
    scanIntervalSeconds: num(env, 'AMPS_SCAN_INTERVAL_SECONDS', DEFAULT_POLICY.scanIntervalSeconds),
    inFlightTimeoutSeconds: num(env, 'AMPS_IN_FLIGHT_TIMEOUT_SECONDS', DEFAULT_POLICY.inFlightTimeoutSeconds),
  }

  return {
    chainId,
    rpcUrl,
    wsUrl: env.AMPS_WS_URL ?? defaultWsUrl(chainId),
    ampsAddress: address(env, 'AMPS_TOKEN_ADDRESS'),
    vaultOverride: optionalAddress(env, 'AMPS_VAULT_ADDRESS'),
    quoterAddress: optionalAddress(env, 'AMPS_QUOTER_ADDRESS'),
    senderAddress: address(env, 'AMPS_SENDER_ADDRESS'),
    submitter,
    relayer,
    privateKey: privateKeyRaw === undefined || privateKeyRaw === '' ? null : (privateKeyRaw as `0x${string}`),
    metricsPort: num(env, 'AMPS_METRICS_PORT', 9464),
    metricsHost: env.AMPS_METRICS_HOST ?? '0.0.0.0',
    logLevel: (env.AMPS_LOG_LEVEL ?? 'info') as Level,
    policy,
    ethUsd18: big(env, 'AMPS_ETH_USD18', 0n),
    stateFile: env.AMPS_STATE_FILE ?? null,
    once: bool(env, 'AMPS_ONCE', false),
  }
}

export {ConfigError}
