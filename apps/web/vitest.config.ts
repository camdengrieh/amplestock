// SPDX-License-Identifier: MIT
import react from '@vitejs/plugin-react'
import {fileURLToPath} from 'node:url'
import {defineConfig} from 'vitest/config'

/**
 * Everything here runs offline. No RPC, no indexer, no wallet: the maths modules are pure, and the
 * components are rendered with fixtures rather than with live reads.
 */
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {'@': fileURLToPath(new URL('./', import.meta.url))},
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./test/setup.ts'],
    include: ['test/**/*.test.ts', 'test/**/*.test.tsx'],
    exclude: ['e2e/**', 'node_modules/**', '.next/**'],
    restoreMocks: true,
  },
})
