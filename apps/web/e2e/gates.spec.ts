// SPDX-License-Identifier: MIT
import {expect, test} from './harness'

test('the terms gate hides every surface until both attestations are made', async ({page}) => {
  await page.goto('/buy')
  await expect(page.getByTestId('terms-gate')).toBeVisible()
  await expect(page.getByTestId('buy-sell-surface')).toHaveCount(0)

  await expect(page.getByTestId('accept-terms')).toBeDisabled()
  await page.getByTestId('attest-jurisdiction').check()
  await expect(page.getByTestId('accept-terms')).toBeDisabled()
  await page.getByTestId('attest-risk').check()
  await page.getByTestId('accept-terms').click()

  await expect(page.getByTestId('buy-sell-surface')).toBeVisible()

  // It is remembered per browser, so a reload does not re-prompt.
  await page.reload()
  await expect(page.getByTestId('buy-sell-surface')).toBeVisible()
})

test('/risk is reachable without accepting anything', async ({page}) => {
  await page.goto('/risk')
  await expect(page.getByTestId('risk-page')).toBeVisible()
  await expect(page.getByTestId('terms-gate')).toHaveCount(0)
})

test.describe('the geo gate', () => {
  test.use({extraHTTPHeaders: {'x-geo-country': 'US'}})

  test('a restricted country is sent to the blocked page', async ({page}) => {
    await page.goto('/buy')
    await expect(page.getByTestId('geo-blocked')).toBeVisible()
    await expect(page.getByTestId('geo-blocked')).toContainText('United States')
    await expect(page.getByTestId('buy-sell-surface')).toHaveCount(0)
  })

  test('the risk disclosures stay reachable from a blocked jurisdiction', async ({page}) => {
    await page.goto('/risk')
    await expect(page.getByTestId('risk-page')).toBeVisible()
  })
})

test.describe('an unrestricted country', () => {
  test.use({extraHTTPHeaders: {'x-geo-country': 'SG'}})

  test('is let through to the terms gate', async ({page}) => {
    await page.goto('/buy')
    await expect(page.getByTestId('terms-gate')).toBeVisible()
  })
})
