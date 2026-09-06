// SPDX-License-Identifier: MIT

/**
 * `@amplestocks/keeper` — the permissionless bountied upkeep service.
 *
 * It runs five calls and no others: `compound(poolId)`, `rollout(constituentId)`,
 * `deployBonded(constituentId)`, `checkpoint()` and `touch()`. It **never re-centres and never re-widens** a
 * ladder — there is no such entry point in the vault and there never will be; `AmpsHook`'s `RebalanceNeeded`
 * event is a notification that the fee schedule reacted, and the keeper's answer to it is a `compound`.
 *
 * Nothing here is trusted. Every job is permissionless, so if this process stops, anyone else's keeper does the
 * same work and collects the same tip; the protocol's only loss from a keeper outage is time.
 *
 * See `docs/keeper-runbook.md` for operations, alerts and what to do in each gate state.
 */

import {resolve} from 'node:path'
import {fileURLToPath} from 'node:url'

import {loadConfig} from './config.js'
import {createLogger} from './logger.js'
import {createMetrics} from './metrics.js'
import {createReadClient} from './chain/clients.js'
import {ChainReader} from './chain/reader.js'
import {createSubmitter} from './chain/submitter.js'
import {Runner} from './runner.js'
import {startMetricsServer} from './server.js'

export {loadConfig, ConfigError} from './config.js'
export {createLogger} from './logger.js'
export {createMetrics, Registry} from './metrics.js'
export {ChainReader} from './chain/reader.js'
export {createReadClient, resolveChain} from './chain/clients.js'
export {createSubmitter, LocalSignerSubmitter, RelayerSubmitter} from './chain/submitter.js'
export {Runner} from './runner.js'
export * from './domain/types.js'
export * from './domain/bounty.js'
export * from './domain/decide.js'
export * from './domain/policy.js'
export {encodeJob, simulateJob, decodeRevert, retryAfter, KEEPER_ERROR_ABI} from './jobs/index.js'
export {decideJobs} from './cre/workflow.js'

export async function main(): Promise<void> {
  const config = loadConfig()
  const logger = createLogger({service: 'amps-keeper', chainId: config.chainId}, {level: config.logLevel})
  const metrics = createMetrics()
  metrics.buildInfo.set({submitter: config.submitter, chain: String(config.chainId)}, 1)

  const client = createReadClient(config)
  const reader = new ChainReader(client, logger)
  const submitter = createSubmitter(config, client, logger)

  logger.info('starting', {
    rpcUrl: config.rpcUrl,
    submitter: config.submitter,
    sender: submitter.sender,
    amps: config.ampsAddress,
    once: config.once,
  })

  const runner = new Runner({
    client,
    reader,
    submitter,
    policy: config.policy,
    logger,
    metrics,
    amps: config.ampsAddress,
    vaultOverride: config.vaultOverride,
    ethUsd18: config.ethUsd18,
  })

  const server = startMetricsServer({
    host: config.metricsHost,
    port: config.metricsPort,
    metrics,
    logger,
    stalenessSeconds: config.policy.scanIntervalSeconds * 4,
  })

  const shutdown = (signal: string): void => {
    logger.info('shutting down', {signal})
    runner.stop()
    server.close()
  }
  process.on('SIGINT', () => shutdown('SIGINT'))
  process.on('SIGTERM', () => shutdown('SIGTERM'))

  if (config.once) {
    metrics.up.set({}, 1)
    await runner.scan()
    server.close()
    return
  }
  await runner.run()
}

// Run `main` only when this file *is* the process entry, so importing it from a test does not start a service.
const entry = process.argv[1]
if (entry !== undefined && fileURLToPath(import.meta.url) === resolve(entry)) {
  main().catch((error: unknown) => {
    process.stderr.write(`${JSON.stringify({level: 'error', msg: 'fatal', error: String(error)})}\n`)
    process.exitCode = 1
  })
}
