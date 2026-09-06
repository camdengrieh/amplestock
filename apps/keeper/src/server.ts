// SPDX-License-Identifier: MIT

/**
 * The scrape and health surface: `GET /metrics` (Prometheus text exposition), `GET /healthz` (liveness) and
 * `GET /readyz` (has a scan completed recently?). Nothing else, and no write endpoints at all — a keeper is a
 * permissionless process and its HTTP surface is telemetry only.
 */

import {createServer, type Server} from 'node:http'
import type {Logger} from './logger.js'
import type {Metrics} from './metrics.js'

export interface MetricsServerOptions {
  readonly host: string
  readonly port: number
  readonly metrics: Metrics
  readonly logger: Logger
  /** A scan older than this makes `/readyz` fail. */
  readonly stalenessSeconds: number
}

export function startMetricsServer(options: MetricsServerOptions): Server {
  const server = createServer((request, response) => {
    const url = request.url ?? '/'
    if (url.startsWith('/metrics')) {
      const body = options.metrics.registry.render()
      response.writeHead(200, {'content-type': 'text/plain; version=0.0.4; charset=utf-8'})
      response.end(body)
      return
    }
    if (url.startsWith('/healthz')) {
      response.writeHead(200, {'content-type': 'application/json'})
      response.end(JSON.stringify({ok: true}))
      return
    }
    if (url.startsWith('/readyz')) {
      const last = options.metrics.lastScanTimestamp.get({})
      const age = Math.floor(Date.now() / 1000) - last
      const ready = last > 0 && age <= options.stalenessSeconds
      response.writeHead(ready ? 200 : 503, {'content-type': 'application/json'})
      response.end(JSON.stringify({ready, lastScanAgeSeconds: age}))
      return
    }
    response.writeHead(404, {'content-type': 'text/plain'})
    response.end('not found\n')
  })

  server.listen(options.port, options.host, () => {
    options.logger.info('metrics server listening', {host: options.host, port: options.port})
  })
  return server
}
