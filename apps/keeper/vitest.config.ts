// SPDX-License-Identifier: MIT
import {defineConfig} from 'vitest/config'

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    environment: 'node',
    // The chain suite brings up anvil and runs the whole Phase 3 deployment through `forge script`; it needs a
    // few minutes on a cold Foundry cache. The unit suites are milliseconds.
    testTimeout: 900_000,
    hookTimeout: 900_000,
    // One anvil per file at a time: the chain fixture binds a port and drives `forge script` against it.
    fileParallelism: false,
  },
})
