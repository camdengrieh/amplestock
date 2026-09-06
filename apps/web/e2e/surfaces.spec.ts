// SPDX-License-Identifier: MIT
import {acceptTerms, expect, test} from './harness'

/**
 * The smoke run: every surface loads, reads the mocked chain, and shows the thing it exists to
 * show. Not a functional test of the write paths — there is no wallet — but a guarantee that no
 * surface is a blank page or a crash.
 */
test.beforeEach(async ({page}) => {
  await acceptTerms(page)
})

test('the home page lists every surface', async ({page}) => {
  await page.goto('/')
  await expect(page.getByRole('heading', {name: 'Amplestocks', exact: true})).toBeVisible()
  for (const label of ['Buy / Sell', 'Rotate', 'Bond', 'Redeem', 'Stake', 'Vault', 'Governance', 'Risk']) {
    await expect(page.getByRole('link', {name: label}).first()).toBeVisible()
  }
})

test('Buy / Sell loads, quotes from the chain and states the fee rules', async ({page}) => {
  await page.goto('/buy')
  await expect(page.getByTestId('buy-sell-surface')).toBeVisible()
  await expect(page.getByTestId('rotation-credit-note')).toContainText('never carries across transactions')
  await expect(page.getByTestId('swap-quote')).toBeVisible()
  // The pool list came from `quoteAll()` on the mocked chain.
  await expect(page.getByTestId('pool-select')).toContainText('AMPS / WETH')
  await expect(page.getByTestId('pool-select')).toContainText('AMPS / USDG')
  // No wallet, so the write is blocked with a reason rather than offered.
  await expect(page.getByTestId('swap-submit')).toBeDisabled()
  await expect(page.getByTestId('tx-blocked-reason')).toContainText('Connect a wallet')
})

test('Buy / Sell offers the native-ETH wrap on the WETH pool and the Across zap behind its flag', async ({page}) => {
  await page.goto('/buy')
  await expect(page.getByTestId('native-eth-toggle')).toBeVisible()
  await expect(page.getByTestId('across-zap')).toContainText('Not implemented yet')
  await expect(page.getByTestId('across-zap-button')).toBeDisabled()
})

test('Rotate puts the credited and uncredited second hop side by side', async ({page}) => {
  await page.goto('/rotate')
  await expect(page.getByTestId('rotate-surface')).toBeVisible()
  await expect(page.getByTestId('rotation-comparison')).toBeVisible()
  await expect(page.getByText('One transaction, through AMPS')).toBeVisible()
  await expect(page.getByText('The same two swaps, separately')).toBeVisible()
  await expect(page.getByTestId('rotate-from')).toContainText('NVDA')
})

test('Bond shows the board, including the market that cannot be bonded', async ({page}) => {
  await page.goto('/bond')
  await expect(page.getByTestId('bond-surface')).toBeVisible()
  await expect(page.getByTestId('bond-board')).toBeVisible()
  await expect(page.getByTestId('bond-board')).toContainText('Open')
  await expect(page.getByTestId('bond-board')).toContainText('Closed')
  await expect(page.getByTestId('bond-positions')).toBeVisible()
  await expect(page.getByTestId('bond-surface')).toContainText('never the collateral taken')
})

test('Redeem previews the payout per asset at NAV minus the live fee', async ({page}) => {
  await page.goto('/redeem')
  await expect(page.getByTestId('redeem-surface')).toBeVisible()
  await expect(page.getByTestId('redeem-surface')).toContainText('1.00%')
  await page.getByTestId('redeem-amount').fill('1')
  await expect(page.getByTestId('redeem-preview')).toContainText('WETH')
  await expect(page.getByTestId('redeem-preview')).toContainText('Inventory AMPS burned alongside')
})

test('Stake reads the streaming rewards and says the APR is realised', async ({page}) => {
  await page.goto('/stake')
  await expect(page.getByTestId('stake-surface')).toBeVisible()
  await expect(page.getByTestId('staking-stats')).toContainText('Realised APR')
  // No indexer is configured, so the APR is unavailable rather than zero.
  await expect(page.getByTestId('indexer-unavailable')).toBeVisible()
  await expect(page.getByTestId('stake-surface')).toContainText('12')
})

test('Vault shows NAV, the premium as a number, the gate per pool and a free checkpoint', async ({page}) => {
  await page.goto('/vault')
  await expect(page.getByTestId('vault-surface')).toBeVisible()
  await expect(page.getByTestId('vault-headline')).toContainText('$1.0000')
  await expect(page.getByTestId('vault-headline')).toContainText('+12.00%')
  await expect(page.getByTestId('checkpoint-button')).toBeVisible()
  await expect(page.getByTestId('gate-status')).toContainText('GREEN')
  // Indexer-backed panels say so rather than drawing a flat line at zero.
  await expect(page.getByTestId('indexer-unavailable').first()).toContainText('it is not zero')
})

test('Vault renders a degraded pool’s market price as unavailable', async ({page}) => {
  await page.goto('/vault')
  await expect(page.getByTestId('gate-status')).toBeVisible()
  // The AAPL pool comes back with the TWAP-coverage bit raised and pMktX18 == 0.
  const unavailable = page.locator('[data-unavailable="true"]')
  await expect(unavailable.first()).toBeVisible()
})

test('Governance shows live parameters next to their hard bands', async ({page}) => {
  await page.goto('/governance')
  await expect(page.getByTestId('governance-surface')).toBeVisible()
  await expect(page.getByTestId('param-redeemFeeBps')).toContainText('1.00%')
  await expect(page.getByTestId('param-redeemFeeBps')).toContainText('5.00%')
  await expect(page.getByTestId('timelock-queue')).toContainText('Pending operations are not listed')
  await expect(page.getByTestId('governance-surface')).toContainText('It cannot block redemption')
})

test('Risk is static and reachable with no wallet and no chain', async ({page}) => {
  await page.goto('/risk')
  await expect(page.getByTestId('risk-page')).toBeVisible()
  for (const heading of [
    /bid depth is exactly the protocol/i,
    /redemption is the only floor/i,
    /premium is a number, not a promise/i,
    /no authorised participant/i,
    /chain-level censorship/i,
    /frozen or blocked by their issuer/i,
  ]) {
    await expect(page.getByRole('heading', {name: heading})).toBeVisible()
  }
})
