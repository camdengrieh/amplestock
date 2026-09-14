// SPDX-License-Identifier: MIT

import * as React from 'react'

import {cn} from '@/lib/utils'

/** github.com/Uniswap/continuous-clearing-auction — the contract the genesis auctions are. */
export const CCA_REPOSITORY_URL = 'https://github.com/Uniswap/continuous-clearing-auction'

/** Uniswap's own documentation for the mechanism. */
export const CCA_DOCS_URL = 'https://docs.uniswap.org/contracts/cca/overview'

/** The version of the CCA the two genesis auctions are deployed from, and its licence. */
export const CCA_VERSION = 'v2.1.0'
export const CCA_LICENCE = 'MIT'

/** The one string, so the surface, the settlement panel, the docs page and the tests share it. */
export const POWERED_BY_UNISWAP_TEXT = `Powered by Uniswap Continuous Clearing Auction ${CCA_VERSION} · ${CCA_LICENCE}`

/**
 * The attribution mark for the genesis auction.
 *
 * Amplestocks does not implement the auction. Both legs are instances of Uniswap's Continuous
 * Clearing Auction, deployed by Uniswap's own factory, and every price, tick and refund on this
 * surface is that contract's arithmetic rather than ours. Saying so is not a courtesy: a reader
 * deciding whether to bid is entitled to know whose code holds the money, and to be able to go and
 * read it — so the mark carries the version, the licence and two links, the source and the docs.
 *
 * **Text only, deliberately.** There is no Uniswap wordmark or unicorn anywhere in this repository
 * and there will not be: the licence covers the code, not the marks, and shipping a third-party
 * logo to imply endorsement is exactly what a trademark exists to stop. `NOTICES.md` carries the
 * same credit in the same words.
 */
export function PoweredByUniswap({
  className,
  'data-testid': testId = 'powered-by-uniswap',
}: {
  className?: string
  'data-testid'?: string
}) {
  return (
    <p className={cn('ledger-micro whitespace-normal text-dim', className)} data-testid={testId}>
      <a
        href={CCA_REPOSITORY_URL}
        target="_blank"
        rel="noreferrer noopener"
        className="underline decoration-rule underline-offset-[3px] hover:text-ink hover:decoration-ink"
      >
        {POWERED_BY_UNISWAP_TEXT}
      </a>
      {' · '}
      <a
        href={CCA_DOCS_URL}
        target="_blank"
        rel="noreferrer noopener"
        className="underline decoration-rule underline-offset-[3px] hover:text-ink hover:decoration-ink"
      >
        Docs
      </a>
    </p>
  )
}
