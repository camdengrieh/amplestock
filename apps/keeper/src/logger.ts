// SPDX-License-Identifier: MIT

/**
 * Structured logging: one JSON object per line on stdout, which is what every log shipper wants and what the
 * `docker-compose.yml` sketch's Promtail/Loki step reads.
 *
 * `bigint` is serialised as a decimal string rather than throwing, because almost every interesting field the
 * keeper logs is one. Errors are flattened to `{name, message, stack}` so a thrown revert is greppable.
 */

export type Level = 'debug' | 'info' | 'warn' | 'error'

const ORDER: Record<Level, number> = {debug: 10, info: 20, warn: 30, error: 40}

export interface Logger {
  readonly level: Level
  child(bindings: Record<string, unknown>): Logger
  debug(message: string, fields?: Record<string, unknown>): void
  info(message: string, fields?: Record<string, unknown>): void
  warn(message: string, fields?: Record<string, unknown>): void
  error(message: string, fields?: Record<string, unknown>): void
}

function normalise(value: unknown): unknown {
  if (typeof value === 'bigint') return value.toString()
  if (value instanceof Error) {
    return {name: value.name, message: value.message, stack: value.stack}
  }
  if (Array.isArray(value)) return value.map(normalise)
  if (value !== null && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) out[k] = normalise(v)
    return out
  }
  return value
}

export interface LoggerOptions {
  readonly level?: Level
  /** Where a line goes. Defaults to `process.stdout.write`; the tests pass a collector. */
  readonly sink?: (line: string) => void
  readonly now?: () => number
}

export function createLogger(bindings: Record<string, unknown> = {}, options: LoggerOptions = {}): Logger {
  const level = options.level ?? 'info'
  const sink = options.sink ?? ((line: string) => process.stdout.write(`${line}\n`))
  const now = options.now ?? Date.now

  const emit = (at: Level, message: string, fields?: Record<string, unknown>): void => {
    if (ORDER[at] < ORDER[level]) return
    const record = {
      ts: new Date(now()).toISOString(),
      level: at,
      msg: message,
      ...(normalise(bindings) as Record<string, unknown>),
      ...(fields === undefined ? {} : (normalise(fields) as Record<string, unknown>)),
    }
    sink(JSON.stringify(record))
  }

  return {
    level,
    child: (extra) => createLogger({...bindings, ...extra}, options),
    debug: (m, f) => emit('debug', m, f),
    info: (m, f) => emit('info', m, f),
    warn: (m, f) => emit('warn', m, f),
    error: (m, f) => emit('error', m, f),
  }
}
