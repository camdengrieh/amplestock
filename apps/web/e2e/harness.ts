// SPDX-License-Identifier: MIT
import {test as base, type Page} from '@playwright/test'

import {E2E, INDEXER_URL, RPC_URL} from './addresses'
import {respondToBody} from './rpc-mock'
import {TERMS_STORAGE_KEY, TERMS_VERSION} from '../lib/terms'

/**
 * `/api/genesis`, as the indexer would serve it after a full clear at the floor.
 *
 * Only the fields the two auction panels read are filled in; every numeric field crosses the wire
 * as a decimal string, because `bigint` does not survive `JSON.stringify` and the client's types
 * say so. The checkpoint series rises and never falls, which is the property the panel's copy
 * claims: a continuous clearing auction raises the price only as far as demand supports it.
 */
const GENESIS_INDEX = {
  genesis: {
    adapter: E2E.genesis,
    vault: E2E.vault,
    settledPhase: 'settled',
    p0X18: '1000000000000000000',
    graduated: true,
  },
  bids: [
    {
      auction: E2E.auctionUsdg,
      leg: 'usdg',
      bidId: '2',
      owner: '0x00000000000000000000000000000000000b0002',
      // 1.10 USDG per AMPS on the Q96 grid, at USDG's own 6 decimals.
      maxPriceQ96: ((1n << 96n) * 11n * 10n ** 5n) / 10n ** 18n,
      // 2,500 USDG, Q96-shifted, exactly as the auction stores it.
      amountQ96: (2_500n * 10n ** 6n) << 96n,
      submittedBlock: '12100',
      submittedAt: '1800000000',
      txHash: `0x${'11'.repeat(32)}`,
      exitedBlock: '0',
      tokensFilled: '0',
      currencyRefunded: '0',
      claimedBlock: '0',
      claimedAmount: '0',
    },
    {
      auction: E2E.auctionUsdg,
      leg: 'usdg',
      bidId: '1',
      owner: '0x00000000000000000000000000000000000b0001',
      maxPriceQ96: ((1n << 96n) * 10n ** 6n) / 10n ** 18n,
      amountQ96: (1_000n * 10n ** 6n) << 96n,
      submittedBlock: '12050',
      submittedAt: '1799999000',
      txHash: `0x${'22'.repeat(32)}`,
      exitedBlock: '0',
      tokensFilled: '0',
      currencyRefunded: '0',
      claimedBlock: '0',
      claimedAmount: '0',
    },
    {
      auction: E2E.auctionEth,
      leg: 'eth',
      bidId: '1',
      owner: '0x00000000000000000000000000000000000b0003',
      maxPriceQ96: (1n << 96n) / 2_000n,
      amountQ96: (2n * 10n ** 18n) << 96n,
      submittedBlock: '12080',
      submittedAt: '1799999500',
      txHash: `0x${'33'.repeat(32)}`,
      exitedBlock: '0',
      tokensFilled: '0',
      currencyRefunded: '0',
      claimedBlock: '0',
      claimedAmount: '0',
    },
  ],
  checkpoints: [
    {auction: E2E.auctionUsdg, leg: 'usdg', blockNumber: '12100', clearingPriceQ96: ((1n << 96n) * 9n * 10n ** 5n) / 10n ** 18n, cumulativeMps: '2500000'},
    {auction: E2E.auctionUsdg, leg: 'usdg', blockNumber: '12200', clearingPriceQ96: ((1n << 96n) * 95n * 10n ** 4n) / 10n ** 18n, cumulativeMps: '5000000'},
    {auction: E2E.auctionUsdg, leg: 'usdg', blockNumber: '12340', clearingPriceQ96: ((1n << 96n) * 10n ** 6n) / 10n ** 18n, cumulativeMps: '7500000'},
    {auction: E2E.auctionEth, leg: 'eth', blockNumber: '12100', clearingPriceQ96: (1n << 96n) / 3_000n, cumulativeMps: '2500000'},
    {auction: E2E.auctionEth, leg: 'eth', blockNumber: '12340', clearingPriceQ96: (1n << 96n) / 2_500n, cumulativeMps: '7500000'},
  ].map((row, i) => ({
    ...row,
    clearingPriceQ96: row.clearingPriceQ96.toString(),
    timestamp: String(1_799_990_000 + i * 100),
    txHash: `0x${'44'.repeat(32)}`,
    logIndex: i,
  })),
}

/** Every numeric field as a decimal string, which is what the HTTP layer actually answers. */
const genesisIndexBody = JSON.stringify(GENESIS_INDEX, (_key, value) =>
  typeof value === 'bigint' ? value.toString() : value,
)

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
    // The one indexer route the run answers. Everything else on that origin is left to fail, so
    // the degraded treatment is exercised in the same pass as the indexed panels.
    await page.route(`${INDEXER_URL}/api/genesis**`, async (route) => {
      await route.fulfill({contentType: 'application/json', body: genesisIndexBody})
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
