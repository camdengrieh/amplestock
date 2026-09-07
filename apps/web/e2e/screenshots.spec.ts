// SPDX-License-Identifier: MIT
import {mkdirSync} from 'node:fs'
import {dirname, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'

import {acceptTerms, expect, test} from './harness'
import {THEME_ATTRIBUTE, THEME_STORAGE_KEY, type Theme} from '../lib/theme'

/**
 * Every surface, in both themes, at both widths.
 *
 * Not an assertion run: it is how the design directory gets its record of what the redesign
 * actually renders as, against the same offline mocked chain the smoke run uses. It writes into
 * `design/ledger/screenshots/` and asserts only that each page reached a state worth photographing.
 *
 * The theme is seeded through `localStorage` before the first paint rather than clicked, so the
 * capture never contains the toggle mid-transition.
 */
const OUT = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'design', 'ledger', 'screenshots')

const VIEWPORTS = [
  {name: 'desktop', width: 1400, height: 1200},
  {name: 'mobile', width: 390, height: 900},
] as const

const THEMES: readonly Theme[] = ['paper', 'ink']

const PAGES = [
  {name: 'home', path: '/', ready: 'wordmark'},
  {name: 'auction', path: '/auction', ready: 'auction-surface'},
  {name: 'buy', path: '/buy', ready: 'buy-sell-surface'},
  {name: 'rotate', path: '/rotate', ready: 'rotate-surface'},
  {name: 'bond', path: '/bond', ready: 'bond-surface'},
  {name: 'redeem', path: '/redeem', ready: 'redeem-surface'},
  {name: 'vault', path: '/vault', ready: 'vault-surface'},
  {name: 'governance', path: '/governance', ready: 'governance-surface'},
  {name: 'docs-index', path: '/docs', ready: null},
  {name: 'docs-fees', path: '/docs/fees', ready: 'docs-article'},
  {name: 'docs-auction', path: '/docs/auction', ready: 'docs-article'},
  {name: 'risk', path: '/risk', ready: 'risk-page'},
] as const

test.beforeAll(() => {
  mkdirSync(OUT, {recursive: true})
})

for (const theme of THEMES) {
  for (const viewport of VIEWPORTS) {
    test.describe(`${theme} · ${viewport.name}`, () => {
      test(`captures every surface`, async ({page}) => {
        // Thirteen full-page captures against a cold production server, each waiting for the mocked
        // chain reads to settle. The default timeout is a smoke-test timeout and this is not one.
        test.slow()
        await page.setViewportSize({width: viewport.width, height: viewport.height})
        await page.addInitScript(
          ([key, value]) => {
            window.localStorage.setItem(key as string, value as string)
          },
          [THEME_STORAGE_KEY, theme],
        )

        // The gate itself, first, while this browser has accepted nothing.
        await page.goto('/buy')
        await expect(page.getByTestId('terms-gate')).toBeVisible({timeout: 20_000})
        await page.screenshot({path: `${OUT}/terms-gate-${theme}-${viewport.width}.png`, fullPage: true})

        // `addInitScript` is additive, so the acceptance is installed once and then every page in
        // the list is behind it.
        await acceptTerms(page)

        for (const entry of PAGES) {
          await page.goto(entry.path)
          if (entry.ready) await expect(page.getByTestId(entry.ready)).toBeVisible({timeout: 20_000})
          await expect(page.locator('html')).toHaveAttribute(THEME_ATTRIBUTE, theme)
          // Let the chain reads settle so the capture is of a resolved page, not a loading one.
          //
          // Best-effort, and explicitly bounded: several hooks poll on an interval, so a page that
          // has finished loading may never reach `networkidle` at all. Without a timeout of its own
          // this call inherits the test's whole budget and starves the captures that follow it.
          await page.waitForLoadState('networkidle', {timeout: 3_000}).catch(() => undefined)
          await page.screenshot({
            path: `${OUT}/${entry.name}-${theme}-${viewport.width}.png`,
            fullPage: true,
          })
        }
      })
    })
  }
}
