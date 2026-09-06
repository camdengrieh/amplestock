// SPDX-License-Identifier: MIT

/**
 * An in-memory stand-in for Ponder's `context.db`.
 *
 * It implements the four methods the indexing functions use — `find`, `insert().values()` with
 * `.onConflictDoNothing()` / `.onConflictDoUpdate()`, `update().set()` and `delete()` — over plain
 * `Map`s, with the primary key read off the drizzle table definition so the tests never have to
 * restate it. That is enough to run every handler in this repository against a synthetic log and
 * then assert on the rows it wrote.
 *
 * It is deliberately *not* a database: no SQL, no types beyond what the handlers touch, no
 * constraint checking except the primary key. Anything that needs real SQL is covered by the
 * end-to-end suite against a real Ponder process.
 */

/** Drizzle tables are ordinary objects; identity is enough to key the store, and the name is only
 *  ever used in an error message. Nothing here imports `drizzle-orm`: it is a transitive dependency
 *  of Ponder, and pinning a second copy of it in this workspace would be a version to keep in step
 *  for no benefit. */
export type Table = object

type Row = Record<string, unknown>

const NAME = Symbol.for('drizzle:Name')

const tableName = (table: Table): string =>
  String((table as Record<symbol, unknown>)[NAME] ?? 'table')

const pkColumns = (table: Table): string[] => {
  const columns = Object.entries(table as unknown as Record<string, unknown>)
    .filter(([, v]) => typeof v === 'object' && v !== null && 'name' in (v as Row) && 'columnType' in (v as Row))
    .map(([k, v]) => [k, v as Row] as const)
  const primary = columns.filter(([, v]) => v.primary === true).map(([k]) => k)
  if (primary.length > 0) return primary
  // Composite keys declared through `primaryKey({columns: [...]})` do not set `primary` on the
  // column, so fall back to the two shapes this schema actually uses.
  if (columns.some(([k]) => k === 'day')) return ['day']
  if (columns.some(([k]) => k === 'id')) return ['id']
  throw new Error(`[test] no primary key found for table ${tableName(table)}`)
}

const keyOf = (table: Table, row: Row): string =>
  pkColumns(table)
    .map((c) => String(row[c]))
    .join('|')

export interface FakeDb {
  find(table: Table, key: Row): Promise<Row | null>
  insert(table: Table): {
    values(values: Row): Promise<Row> & {
      onConflictDoNothing(): Promise<Row | null>
      onConflictDoUpdate(patch: Row | ((row: Row) => Row)): Promise<Row>
    }
  }
  update(table: Table, key: Row): {set(patch: Row | ((row: Row) => Row)): Promise<Row>}
  delete(table: Table, key: Row): Promise<boolean>
  /** Every row of a table, for assertions. */
  rows(table: Table): Row[]
  /** Row count, for assertions. */
  count(table: Table): number
  /** Wipe everything. */
  reset(): void
}

export function createFakeDb(): FakeDb {
  const store = new Map<Table, Map<string, Row>>()

  const tableMap = (table: Table): Map<string, Row> => {
    const name = table
    let map = store.get(name)
    if (map === undefined) {
      map = new Map()
      store.set(name, map)
    }
    return map
  }

  const apply = (row: Row, patch: Row | ((row: Row) => Row)): Row => ({
    ...row,
    ...(typeof patch === 'function' ? patch(row) : patch),
  })

  return {
    async find(table, key) {
      return tableMap(table).get(keyOf(table, key)) ?? null
    },
    insert(table) {
      return {
        values(values: Row) {
          const map = tableMap(table)
          const id = keyOf(table, values)
          const existing = map.get(id)
          const write = () => {
            if (existing !== undefined) {
              throw new Error(`[test] duplicate primary key in ${tableName(table)}: ${id}`)
            }
            map.set(id, {...values})
            return {...values}
          }
          // A *thenable*, not a Promise: the plain insert must not run — and must not reject —
          // unless the caller actually awaits it without a conflict clause, which is exactly how
          // Ponder's own builder behaves.
          const thenable = {
            then(
              onFulfilled?: ((value: Row) => unknown) | null,
              onRejected?: ((reason: unknown) => unknown) | null,
            ) {
              return Promise.resolve()
                .then(write)
                .then(onFulfilled ?? undefined, onRejected ?? undefined)
            },
            async onConflictDoNothing() {
              if (existing !== undefined) return existing
              map.set(id, {...values})
              return {...values}
            },
            async onConflictDoUpdate(patch: Row | ((row: Row) => Row)) {
              if (existing === undefined) {
                map.set(id, {...values})
                return {...values}
              }
              const next = apply(existing, patch)
              map.set(id, next)
              return next
            },
          }
          return thenable as unknown as Promise<Row> & {
            onConflictDoNothing(): Promise<Row | null>
            onConflictDoUpdate(patch: Row | ((row: Row) => Row)): Promise<Row>
          }
        },
      }
    },
    update(table, key) {
      return {
        async set(patch) {
          const map = tableMap(table)
          const id = keyOf(table, key)
          const existing = map.get(id)
          if (existing === undefined) {
            throw new Error(`[test] update of a missing row in ${tableName(table)}: ${id}`)
          }
          const next = apply(existing, patch)
          map.set(id, next)
          return next
        },
      }
    },
    async delete(table, key) {
      return tableMap(table).delete(keyOf(table, key))
    },
    rows(table) {
      return [...tableMap(table).values()]
    },
    count(table) {
      return tableMap(table).size
    },
    reset() {
      store.clear()
    },
  }
}
