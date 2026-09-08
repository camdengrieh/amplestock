// SPDX-License-Identifier: MIT
import Link from 'next/link'

import {SurfaceHeading} from '@/components/common/states'
import {Kicker} from '@/components/ledger/primitives'
import {RISK_DISCLOSURES} from '@/lib/copy'

export const metadata = {
  title: 'Risk — Amplestocks',
  description: 'What can go wrong with $AMPS, stated plainly.',
}

/**
 * Static. No wallet, no chain read, no gate: this page has to render for somebody who has accepted
 * nothing and been blocked by everything.
 *
 * In the Ledger vocabulary it is the design's numbered-step block turned into a document: a mono
 * ordinal in its own column, a 28px heading, and the prose at a reading measure — the same shape
 * the landing page uses for the floor and the growth loop, because this is the same kind of
 * argument and deserves the same weight.
 */
export default function RiskPage() {
  return (
    <div className="space-y-11" data-testid="risk-page">
      <SurfaceHeading
        kicker="Read this first"
        title="Risk"
        lede="Every one of these is a real property of the system rather than boilerplate. Read them before you use any other page."
      />

      <nav aria-label="On this page" className="flex flex-wrap gap-x-7 gap-y-2 border-b border-rule pb-5">
        {RISK_DISCLOSURES.map((disclosure, index) => (
          <a
            key={disclosure.id}
            href={`#${disclosure.id}`}
            className="ledger-nav text-dim transition-colors hover:text-ink"
          >
            <span className="mr-2 opacity-60">{String(index + 1).padStart(2, '0')}</span>
            {disclosure.title}
          </a>
        ))}
      </nav>

      <div>
        {RISK_DISCLOSURES.map((disclosure, index) => (
          <section
            key={disclosure.id}
            id={disclosure.id}
            className="grid scroll-mt-28 grid-cols-1 gap-x-5 gap-y-3 border-t border-ink py-9 sm:grid-cols-[44px_minmax(0,1fr)]"
          >
            <span className="pt-2 font-mono text-[11px] tracking-[0.08em] text-dim">
              {String(index + 1).padStart(2, '0')}
            </span>
            <div className="min-w-0">
              <h2 className="ledger-heading">{disclosure.title}</h2>
              <div className="mt-3 max-w-[70ch] space-y-3.5 text-[17px] leading-[1.55] text-dim">
                {disclosure.body.map((paragraph, i) => (
                  <p key={i}>{paragraph}</p>
                ))}
              </div>
            </div>
          </section>
        ))}
        <div role="presentation" className="border-t border-ink" />
      </div>

      <div className="flex flex-wrap items-baseline gap-x-7 gap-y-2 pt-2">
        <Kicker>Keep reading</Kicker>
        <Link href="/docs" className="ledger-nav text-dim transition-colors hover:text-ink">
          Documentation
        </Link>
        <Link href="/docs/addresses" className="ledger-nav text-dim transition-colors hover:text-ink">
          Contracts
        </Link>
        <Link href="/governance" className="ledger-nav text-dim transition-colors hover:text-ink">
          Parameters
        </Link>
      </div>
    </div>
  )
}
