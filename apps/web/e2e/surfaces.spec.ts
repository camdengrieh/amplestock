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
  // An ordinary buy pays the AMPS fee; the pass-through price is disclosed beside it and is not
  // available on this page. 500 bp against 30 bp on the entry pool.
  await expect(page.getByTestId('fee-breakdown')).toContainText('5.00%')
  await expect(page.getByTestId('fee-breakdown')).toContainText('The same hop inside a rotation')
  await expect(page.getByTestId('fee-breakdown')).toContainText('0.30%')
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
  // The exemption is an address plus a flag, and the page prints both rather than describing them.
  await expect(page.getByTestId('router-only-note')).toContainText('AmpsHook.router()')
  await expect(page.getByTestId('rotation-comparison')).toBeVisible()
  await expect(page.getByText('One transaction, through AMPS')).toBeVisible()
  await expect(page.getByText('The same two swaps through any other router')).toBeVisible()
  await expect(page.getByTestId('rotate-from')).toContainText('NVDA')
  // The hook's pointer matches the configured router on the mocked chain, so no mismatch warning.
  await expect(page.getByTestId('router-mismatch')).toHaveCount(0)
})

test('Rotate prices both legs of the other-router route at the AMPS fee', async ({page}) => {
  await page.goto('/rotate')
  await page.getByTestId('rotate-amount').fill('1')
  const comparison = page.getByTestId('rotation-comparison')
  // Two pass-through hops at 5 bp against two AMPS fees at 500 bp: 0.10% against 10.00%.
  await expect(comparison).toContainText('0.10%')
  await expect(comparison).toContainText('10.00%')
  await expect(comparison).toContainText('9.90%')
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
  // Each leg sells 5,000 AMPS: half the 10,000-AMPS auction tranche, which is half of S₀.
  await expect(page.getByTestId('auction-headline-usdg')).toContainText('5,000 AMPS')
  // …and in dollars, through the Chainlink answer rather than by assuming USDG is a dollar.
  await expect(page.getByTestId('auction-headline-usdg')).toContainText('$1.0001')
  // There is no ETH/USD feed in the reference book, so the ETH leg's dollar column is a dash.
  await expect(page.getByTestId('auction-headline-eth').locator('[data-unavailable="true"]').first()).toBeVisible()
  // No wallet, so the bid list says so rather than claiming there are none.
  await expect(page.getByTestId('bids-usdg')).toContainText('Connect a wallet')
})

test('Auction says whose auction it is, in the heading and at the settlement', async ({page}) => {
  await page.goto('/auction')
  const mark = page.getByTestId('powered-by-uniswap').first()
  await expect(mark).toContainText('Powered by Uniswap Continuous Clearing Auction v2.1.0 · MIT')
  await expect(mark.getByRole('link', {name: /Continuous Clearing Auction/})).toHaveAttribute(
    'href',
    'https://github.com/Uniswap/continuous-clearing-auction',
  )
  // The settlement panel carries it too: the auctions it settles are not ours either.
  await expect(page.getByTestId('powered-by-uniswap-settlement')).toBeVisible()
  // …and the explainer keeps the version aside it already had.
  await expect(page.getByTestId('auction-explainer')).toContainText('Uniswap CCA v2.1.0')
  await expect(page.getByTestId('auction-explainer')).toContainText('Amplestocks did not write this auction')
  // Text only — no third-party logo asset is shipped, and the trademark is not ours to use.
  await expect(page.getByTestId('powered-by-uniswap').first().locator('img, svg')).toHaveCount(0)
})

test('Auction offers the approval the USDG leg needs and the checkpoint that refreshes the price', async ({page}) => {
  await page.goto('/auction')
  // The ERC-20 leg has an allowance row and an approve button; with no wallet both say why.
  const approve = page.getByTestId('auction-approve-usdg')
  await expect(approve).toBeVisible()
  await expect(page.getByTestId('auction-approve-button-usdg')).toBeVisible()
  await expect(approve).toContainText('Connect a wallet')
  // The native leg needs no approval at all and must not grow one.
  await expect(page.getByTestId('auction-approve-eth')).toHaveCount(0)
  // `checkpoint()` is a write, so the price is as of a block and the surface offers to advance it.
  const refresh = page.getByTestId('auction-refresh-usdg')
  await expect(refresh).toContainText('Priced as of block 12340')
  await expect(page.getByTestId('auction-checkpoint-usdg')).toBeVisible()
  await expect(refresh).toContainText('Connect a wallet')
})

test('Auction renders the indexed history and the public book, and degrades the rest', async ({page}) => {
  await page.goto('/auction')
  // The clearing-price series comes from `auction_checkpoint` — three USDG points, rising.
  const history = page.getByTestId('clearing-history-usdg')
  await expect(history).toBeVisible()
  await expect(history).toContainText('3 checkpoints')
  await expect(history).toContainText('USDG')
  // The ETH leg has its own two points and is not the USDG leg's series.
  await expect(page.getByTestId('clearing-history-eth')).toContainText('2 checkpoints')
  // The public book is everybody's bids, not only the reader's.
  const book = page.getByTestId('bid-book-usdg')
  await expect(book).toBeVisible()
  await expect(book).toContainText('#2')
  await expect(book).toContainText('#1')
  await expect(book).toContainText('2,500 USDG')
  // Bids from the other leg do not leak into this one.
  await expect(book).not.toContainText('#3')
  await expect(page.getByTestId('bid-book-eth')).toContainText('2 ETH')
})

test('Auction settlement reads the genesis adapter and discloses the premium', async ({page}) => {
  await page.goto('/auction')
  const settlement = page.getByTestId('auction-settlement')
  await expect(settlement).toBeVisible()
  // The phase comes from the adapter, not from adding the two auctions up.
  await expect(page.getByTestId('genesis-phase-note')).toContainText('Settled')
  // $10,000 raised against S₀ = 20,000 is NAV/share $0.50 at a P₀ of $1.00: a 100% premium, and it
  // is printed as a premium rather than smoothed away or called a discount. Decision 14 stands.
  await expect(settlement).toContainText('$1.000000')
  await expect(settlement).toContainText('$10,000')
  await expect(settlement).toContainText('$0.5000')
  await expect(settlement).toContainText('+100.00%')
  await expect(settlement).not.toContainText('discount')
  // Where the money came from, in each currency, and what came back unsold. Each leg is shown in its
  // own units *and* in USD, because 5,000 USDG and 2 WETH are the same $5,000 and neither figure is
  // derivable from the other without the ETH/USD price the adapter used.
  await expect(page.getByTestId('genesis-proceeds')).toContainText('5,000 USDG · $5,000.00')
  await expect(page.getByTestId('genesis-proceeds')).toContainText('2 WETH · $5,000.00')
  await expect(page.getByTestId('genesis-proceeds')).toContainText('2,000 AMPS')
  // settle() is one-shot, so the button is refused with the reason rather than silently disabled.
  await expect(page.getByTestId('genesis-settle')).toContainText('already been settled')
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
  // Revision 8 releases the inventory rather than burning it in the redemption, and it then leaves
  // the supply on a 24-hour linear stream. The copy must not go on saying supply falls by more
  // than the amount redeemed in this transaction.
  await expect(page.getByTestId('redeem-preview')).toContainText('Inventory AMPS released, burned over 24 hours')
  await expect(page.getByTestId('redeem-preview')).toContainText('24-hour linear stream')
  await expect(page.getByTestId('redeem-preview')).not.toContainText('burned alongside')
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
  // The fee-flow disclosure exists and opens; with no indexer it says so rather than showing zeros.
  await page.getByRole('button', {name: /Where the fees went/i}).click()
  await expect(page.getByTestId('vault-section-fees')).toContainText(/unavailable|not configured/i)
})

test('Vault renders a degraded pool’s market price as unavailable', async ({page}) => {
  await page.goto('/vault')
  await expect(page.getByTestId('gate-status')).toBeVisible()
  // The AAPL pool comes back with the TWAP-coverage bit raised and pMktX18 == 0.
  const unavailable = page.locator('[data-unavailable="true"]')
  await expect(unavailable.first()).toBeVisible()
})

test('Governance names the router pointer and its seven-day class', async ({page}) => {
  await page.goto('/governance')
  const pointers = page.getByTestId('pointer-table')
  await expect(pointers).toBeVisible()
  await expect(page.getByTestId('pointer-AmpsHook.router')).toContainText('7d')
  await expect(page.getByTestId('pointer-AmpsHook.router')).toContainText(/pass-through exemption/i)
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
  // The two-step genesis, and the premium as a disclosure rather than a discount.
  await expect(page.getByTestId('docs-article')).toContainText('Genesis is two calls')
  await expect(page.getByTestId('docs-article')).toContainText('The premium is a disclosure, not a discount')
  // Live settlement figures, resolved from the adapter — none of them typed into the page.
  await expect(page.getByTestId('docs-article')).toContainText('$0.5000')
  await expect(page.getByTestId('docs-article')).toContainText('2,000 AMPS')
  // And the page says whose auction it is, in its header.
  await expect(page.getByTestId('docs-article')).toContainText(
    'Powered by Uniswap Continuous Clearing Auction v2.1.0 · MIT',
  )
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
