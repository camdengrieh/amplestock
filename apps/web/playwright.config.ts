// SPDX-License-Identifier: MIT
import {defineConfig, devices} from '@playwright/test'

import {E2E, RPC_URL} from './e2e/addresses'

/**
 * The smoke run.
 *
 * Everything is offline. The app is served from a real production build, every chain read is
 * answered by `e2e/rpc-mock.ts` through a Playwright route, and there is no wallet — the surfaces
 * are asserted in their read-only state, which is the state a first-time visitor sees.
 *
 * Chromium is pre-installed in this environment at `/opt/pw-browsers`; the browser revision and
 * this Playwright version have to agree, which is why the version is pinned rather than floating.
 */
export default defineConfig({
  testDir: './e2e',
  testMatch: /.*\.spec\.ts/,
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  reporter: process.env.CI ? [['line']] : [['list']],
  use: {
    baseURL: 'http://127.0.0.1:3111',
    trace: 'off',
    screenshot: 'off',
    video: 'off',
  },
  projects: [{name: 'chromium', use: {...devices['Desktop Chrome']}}],
  webServer: {
    // `NEXT_PUBLIC_*` is inlined at build time, not read at start time, so the smoke run has to
    // build with the fixture deployment in the environment. It rebuilds `.next`; `pnpm build`
    // afterwards restores the ordinary bundle.
    command:
      'node node_modules/next/dist/bin/next build && node node_modules/next/dist/bin/next start --port 3111',
    url: 'http://127.0.0.1:3111/risk',
    reuseExistingServer: false,
    timeout: 300_000,
    env: {
      NEXT_TELEMETRY_DISABLED: '1',
      NEXT_PUBLIC_AMPS_CHAIN_ID: '4663',
      NEXT_PUBLIC_AMPS_RPC_URL: RPC_URL,
      NEXT_PUBLIC_REOWN_PROJECT_ID: '',
      NEXT_PUBLIC_AMPS_INDEXER_URL: '',
      NEXT_PUBLIC_FLAG_ACROSS_ZAP: '1',
      NEXT_PUBLIC_FLAG_TESTNET_BANNER: '1',
      NEXT_PUBLIC_AMPS_TOKEN: E2E.amps,
      NEXT_PUBLIC_AMPS_VAULT: E2E.vault,
      NEXT_PUBLIC_AMPS_QUOTER: E2E.quoter,
      NEXT_PUBLIC_AMPS_BONDS: E2E.bonds,
      NEXT_PUBLIC_AMPS_BONDS_LENS: E2E.bondsLens,
      NEXT_PUBLIC_AMPS_STAKING: E2E.staking,
      NEXT_PUBLIC_AMPS_REGISTRY: E2E.registry,
      NEXT_PUBLIC_AMPS_REGISTRY_LENS: E2E.registryLens,
      NEXT_PUBLIC_AMPS_HOOK: E2E.hook,
      NEXT_PUBLIC_AMPS_ORACLE_GATE: E2E.oracleGate,
      NEXT_PUBLIC_AMPS_TIMELOCK: E2E.timelock,
      // `header` so the smoke test can drive the geo gate from a request header rather than an IP.
      GEO_PROVIDER: 'header',
      GEO_COUNTRY_HEADER: 'x-geo-country',
    },
  },
})
