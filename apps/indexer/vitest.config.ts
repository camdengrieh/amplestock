// SPDX-License-Identifier: MIT

/**
 * Vitest, with the three Ponder virtual modules aliased to test doubles.
 *
 * `ponder:registry`, `ponder:schema` and `ponder:api` only exist inside Ponder's own vite pipeline.
 * Aliasing them here is what lets the indexing functions be imported — and therefore *called* —
 * from a plain test file with synthetic logs, instead of only being exercisable by running the
 * whole indexer against a chain.
 *
 * The end-to-end suite under `test/e2e` needs `anvil` and is opt-in: it is skipped unless
 * `AMPS_E2E=1`, so `pnpm test` is offline and toolchain-free everywhere else, CI included.
 */

import {dirname, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'

import {defineConfig} from 'vitest/config'

const here = dirname(fileURLToPath(import.meta.url))

export default defineConfig({
  resolve: {
    alias: {
      'ponder:registry': resolve(here, 'test/support/registry.ts'),
      'ponder:schema': resolve(here, 'test/support/schema.ts'),
      'ponder:api': resolve(here, 'test/support/api.ts'),
    },
  },
  test: {
    environment: 'node',
    include: ['test/**/*.test.ts'],
    testTimeout: process.env.AMPS_E2E === '1' ? 600_000 : 20_000,
    hookTimeout: process.env.AMPS_E2E === '1' ? 600_000 : 20_000,
    fileParallelism: false,
  },
})
