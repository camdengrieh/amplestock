// SPDX-License-Identifier: MIT
import {test as base, type Page} from '@playwright/test'

import {RPC_URL} from './addresses'
import {respondToBody} from './rpc-mock'
import {TERMS_STORAGE_KEY, TERMS_VERSION} from '../lib/terms'

/**
 * Every test gets the mocked chain and, unless it says otherwise, a browser that has already
 * accepted the terms — the gate has its own test and does not need to be clicked through eight
 * more times.
 */
export const test = base.extend<{page: Page}>({
  page: async ({page}, use) => {
    await page.route(`${RPC_URL}/**`, async (route) => {
      const body = route.request().postDataJSON() as unknown
      await route.fulfill({contentType: 'application/json', body: JSON.stringify(respondToBody(body))})
    })
    await page.route(RPC_URL, async (route) => {
      const body = route.request().postDataJSON() as unknown
      await route.fulfill({contentType: 'application/json', body: JSON.stringify(respondToBody(body))})
    })
    // Nothing else may leave the browser: an offline run that quietly reaches the internet is not
    // an offline run.
    await page.route(/^https?:\/\/(?!127\.0\.0\.1)/, (route) => route.abort())
    await use(page)
  },
})

export const {expect} = base

export async function acceptTerms(page: Page): Promise<void> {
  await page.addInitScript(
    ([key, version]) => {
      window.localStorage.setItem(
        key as string,
        JSON.stringify({version, acceptedAt: 1, attestedNotRestricted: true, acknowledgedRisk: true}),
      )
    },
    [TERMS_STORAGE_KEY, TERMS_VERSION],
  )
}
