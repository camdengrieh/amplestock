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

test('the home page is the landing screen the design draws', async ({page}) => {
  await page.goto('/')
  await expect(page.getByTestId('landing-surface')).toBeVisible()
  await expect(page.getByRole('heading', {level: 1})).toContainText('A floor you can always take')
  // Its header navigates the page's own sections and offers one way in, as the design draws it.
  await expect(page.getByTestId('enter-app')).toBeVisible()
  for (const anchor of ['Holdings', 'The floor', 'How NAV grows', 'Numbers']) {
    await expect(page.getByRole('link', {name: anchor}).first()).toBeVisible()
  }
  // Revision 6 removed staking, so there is no such surface to link to.
  await expect(page.getByRole('link', {name: 'Stake'})).toHaveCount(0)
})

test('the app frame links every surface, and no staking one', async ({page}) => {
  await page.goto('/buy')
  for (const label of ['Auction', 'Buy / Sell', 'Rotate', 'Bond', 'Redeem', 'Vault', 'Governance', 'Docs', 'Risk']) {
    await expect(page.getByRole('link', {name: label}).first()).toBeVisible()
  }
  await expect(page.getByRole('link', {name: 'Stake'})).toHaveCount(0)
})

test('the theme toggle switches the whole page and remembers the choice', async ({page}) => {
  await page.goto('/')
  const html = page.locator('html')
  await page.getByTestId('theme-ink').click()
  await expect(html).toHaveAttribute('data-theme', 'ink')
  await page.reload()
  await expect(html).toHaveAttribute('data-theme', 'ink')
  await page.getByTestId('theme-paper').click()
  await expect(html).toHaveAttribute('data-theme', 'paper')
})

test('Buy / Sell loads, quotes from the chain and states the fee rules both ways', async ({page}) => {
  await page.goto('/buy')
  await expect(page.getByTestId('buy-sell-surface')).toBeVisible()
  await expect(page.getByTestId('rotation-credit-note')).toContainText('never carries across transactions')
  await expect(page.getByTestId('rotation-credit-note')).toContainText('buying it and selling it alike')
  await expect(page.getByTestId('swap-quote')).toBeVisible()
  // The AMPS fee and its band come from the hook, not from a constant in the bundle.
  await expect(page.getByTestId('fee-breakdown')).toContainText('AMPS fee — both ways')
  await expect(page.getByTestId('fee-breakdown')).toContainText('1.00% – 6.00%')
  // The pool list came from `quoteAll()` on the mocked chain.
  await expect(page.getByTestId('pool-select')).toContainText('AMPS / WETH')
  await expect(page.getByTestId('pool-select')).toContainText('AMPS / USDG')
  // No wallet, so the write is blocked with a reason rather than offered.
  await expect(page.getByTestId('swap-submit')).toBeDisabled()
  await expect(page.getByTestId('tx-blocked-reason')).toContainText('Connect a wallet')
})

test('Buy / Sell prices the amount on chain once one is entered', async ({page}) => {
  await page.goto('/buy')
  await page.getByTestId('amount-input').fill('1')
  // From AmpsQuoter.quoteExactIn on the mocked chain, with the signed minimum derived from it.
  await expect(page.getByTestId('swap-quote')).toContainText('95 AMPS')
  await expect(page.getByTestId('swap-quote')).toContainText('94.525 AMPS')
})

test('Buy / Sell offers the native-ETH wrap on the WETH pool and the Across zap behind its flag', async ({page}) => {
  await page.goto('/buy')
  await expect(page.getByTestId('native-eth-toggle')).toBeVisible()
  await expect(page.getByTestId('across-zap')).toContainText('Not implemented yet')
  await expect(page.getByTestId('across-zap-button')).toBeDisabled()
})

test('Rotate says why only the protocol’s router can prove a round trip', async ({page}) => {
  await page.goto('/rotate')
  await expect(page.getByTestId('rotate-surface')).toBeVisible()
  await expect(page.getByTestId('router-only-note')).toContainText('rotate(hop1, hop2, amountIn, minOut, to, unwrap, deadline)')
  await expect(page.getByTestId('router-only-note')).toContainText('Any other router pays the AMPS fee')
  await expect(page.getByTestId('rotation-comparison')).toBeVisible()
  await expect(page.getByText('One transaction, through AMPS')).toBeVisible()
  await expect(page.getByText('The same two swaps, separately')).toBeVisible()
  await expect(page.getByTestId('rotate-from')).toContainText('NVDA')
})

test('Auction reads both legs and explains the mechanism', async ({page}) => {
  await page.goto('/auction')
  await expect(page.getByTestId('auction-surface')).toBeVisible()
  await expect(page.getByTestId('auction-usdg')).toBeVisible()
  await expect(page.getByTestId('auction-eth')).toBeVisible()
  await expect(page.getByTestId('auction-explainer')).toContainText('One price for everybody')
  await expect(page.getByTestId('auction-explainer')).toContainText('everything is refunded')
  // The clearing price is the auction's own, in its own currency, off the Q96 grid.
  await expect(page.getByTestId('auction-headline-usdg')).toContainText('USDG')
  await expect(page.getByTestId('auction-headline-usdg')).toContainText('3,325 AMPS')
  // …and in dollars, through the Chainlink answer rather than by assuming USDG is a dollar.
  await expect(page.getByTestId('auction-headline-usdg')).toContainText('$1.0001')
  // There is no ETH/USD feed in the reference book, so the ETH leg's dollar column is a dash.
  await expect(page.getByTestId('auction-headline-eth').locator('[data-unavailable="true"]').first()).toBeVisible()
  // No wallet, so the bid list says so rather than claiming there are none.
  await expect(page.getByTestId('bids-usdg')).toContainText('Connect a wallet')
})

test('Bond shows the board, including the market that cannot be bonded and why', async ({page}) => {
  await page.goto('/bond')
  await expect(page.getByTestId('bond-surface')).toBeVisible()
  await expect(page.getByTestId('bond-board')).toBeVisible()
  await expect(page.getByTestId('bond-board')).toContainText('Open')
  await expect(page.getByTestId('bond-board')).toContainText('Closed')
  await expect(page.getByTestId('bond-positions')).toBeVisible()
  await expect(page.getByTestId('bond-surface')).toContainText('never the collateral taken')
  // The shell's own parameters, read rather than assumed.
  await expect(page.getByTestId('bond-parameters')).toContainText('12h 0m')
  // Exact unvested principal for the connected wallet — but there is no wallet, so it is
  // unavailable rather than zero.
  await expect(page.getByTestId('bond-surface')).toContainText('Still vesting')
})

test('Redeem previews the payout per asset at NAV minus the live fee', async ({page}) => {
  await page.goto('/redeem')
  await expect(page.getByTestId('redeem-surface')).toBeVisible()
  // 2.50% is the mocked vault's live `redeemFeeBps` — nothing in the bundle says it.
  await expect(page.getByTestId('redeem-surface')).toContainText('2.50%')
  await page.getByTestId('redeem-amount').fill('1')
  await expect(page.getByTestId('redeem-preview')).toContainText('WETH')
  await expect(page.getByTestId('redeem-preview')).toContainText('Inventory AMPS burned alongside')
})

test('Vault shows NAV, weights against targets, the gate per pool and a free checkpoint', async ({page}) => {
  await page.goto('/vault')
  await expect(page.getByTestId('vault-surface')).toBeVisible()
  await expect(page.getByTestId('vault-headline')).toContainText('$1.0000')
  await expect(page.getByTestId('vault-headline')).toContainText('+12.00%')
  await expect(page.getByTestId('checkpoint-button')).toBeVisible()
  await expect(page.getByTestId('gate-status')).toContainText('GREEN')
  // Target next to realised, from the registry rather than from one number called "the weight".
  await expect(page.getByTestId('holdings')).toContainText('Realised')
  await expect(page.getByTestId('holdings')).toContainText('Drift')
  // The creator schedule and the rollout, both live.
  await expect(page.getByTestId('creator-schedule')).toContainText('Creator fee, in force now')
  await expect(page.getByTestId('rollout')).toContainText('Entry-pool floor')
  // Per-pool POL depth comes from LadderPositionValuer.amountsOf, not from the indexer.
  await expect(page.getByTestId('pol-depth')).toContainText('2 WETH')
  await expect(page.getByTestId('pol-row-WETH')).toContainText('1,662')
  // Indexer-backed panels say so rather than drawing a flat line at zero.
  await expect(page.getByTestId('indexer-unavailable').first()).toContainText('it is not zero')
  // Staking is gone, and with it the whole vocabulary.
  await expect(page.getByTestId('vault-surface')).not.toContainText('xAMPS')
})

test('Vault renders a degraded pool’s market price as unavailable', async ({page}) => {
  await page.goto('/vault')
  await expect(page.getByTestId('gate-status')).toBeVisible()
  // The AAPL pool comes back with the TWAP-coverage bit raised and pMktX18 == 0.
  const unavailable = page.locator('[data-unavailable="true"]')
  await expect(unavailable.first()).toBeVisible()
})

test('Governance shows live parameters next to their hard bands, and no staking parameters', async ({page}) => {
  await page.goto('/governance')
  await expect(page.getByTestId('governance-surface')).toBeVisible()
  await expect(page.getByTestId('param-redeemFeeBps')).toContainText('2.50%')
  await expect(page.getByTestId('param-redeemFeeBps')).toContainText('5.00%')
  await expect(page.getByTestId('param-ampsFeeBps')).toContainText('5.00%')
  await expect(page.getByTestId('param-ampsFeeBps')).toContainText('1.00% – 6.00%')
  await expect(page.getByTestId('timelock-queue')).toContainText('Pending operations are not listed')
  await expect(page.getByTestId('governance-surface')).toContainText('It cannot block redemption')
  await expect(page.getByTestId('parameter-table')).not.toContainText('stakerBps')
})

test('Docs render from data, with every figure read from a source', async ({page}) => {
  await page.goto('/docs')
  await expect(page.getByRole('heading', {name: 'Documentation'})).toBeVisible()
  await page.getByRole('link', {name: 'Fees'}).click()

  await expect(page.getByTestId('docs-article')).toBeVisible()
  await expect(page.getByTestId('docs-sidebar')).toBeVisible()
  // The AMPS fee and its band come from the hook on the mocked chain.
  await expect(page.getByTestId('docs-article')).toContainText('5.00%')
  await expect(page.getByTestId('docs-article')).toContainText('1.00% – 6.00%')
  await expect(page.getByTestId('docs-article')).toContainText('Read from AmpsHook.ampsFeeBps()')
  // The pager walks the reading order.
  await expect(page.getByTestId('docs-pager')).toContainText('Previous')
  await expect(page.getByTestId('docs-pager')).toContainText('Next')
})

test('the docs auction page reads both auctions and refuses to invent the graduation target', async ({page}) => {
  await page.goto('/docs/auction')
  await expect(page.getByTestId('docs-article')).toContainText('One price for everybody')
  await expect(page.getByTestId('docs-article')).toContainText('The graduation target is not readable')
  await expect(page.getByTestId('docs-rail')).toContainText('The two auctions')
})

test('the docs sidebar collapses to a select on a narrow viewport', async ({page}) => {
  await page.setViewportSize({width: 390, height: 900})
  await page.goto('/docs/fees')
  await expect(page.getByTestId('docs-select')).toBeVisible()
  await expect(page.getByTestId('docs-sidebar')).toBeHidden()
  await expect(page.getByTestId('docs-rail')).toBeHidden()
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
    /charged in both directions/i,
  ]) {
    await expect(page.getByRole('heading', {name: heading})).toBeVisible()
  }
})
