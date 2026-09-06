// SPDX-License-Identifier: MIT

/**
 * A stand-in for Ponder's `ponder:api` virtual module. The API layer is exercised end to end
 * against a running indexer in `test/e2e`; this shim exists only so importing `src/api/index.ts`
 * from a unit test does not fail to resolve.
 */

export const db = null as unknown as never
export const publicClients = {} as Record<string, never>
