// SPDX-License-Identifier: MIT

/**
 * `jsonb` columns cannot hold a `bigint` — Postgres has no such JSON type and `JSON.stringify`
 * throws on one. Every value the handlers put in a `jsonb` column goes through this first, which
 * renders bigints as decimal strings and leaves everything else alone.
 *
 * Decimal strings rather than numbers, always: a `uint256` does not survive an IEEE-754 double, and
 * a reader that does `BigInt(value)` gets the exact number back. The HTTP layer renders bigint
 * *columns* the same way, so a consumer sees one convention across the whole API.
 */

export function jsonSafe<T>(value: T): unknown {
  if (typeof value === 'bigint') return value.toString()
  if (Array.isArray(value)) return value.map(jsonSafe)
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, jsonSafe(v)]),
    )
  }
  return value
}

/** The same, narrowed for the record shape every `jsonb` column in this schema holds. */
export const jsonRecord = (value: Record<string, unknown>): Record<string, unknown> =>
  jsonSafe(value) as Record<string, unknown>
