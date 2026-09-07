// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import Link from 'next/link'

import {Kicker, Rule} from '@/components/ledger/primitives'
import {Button} from '@/components/ui/button'
import {BLOCKED_JURISDICTIONS} from '@/lib/geo'
import {
  TERMS_VERSION,
  browserStorage,
  isCurrent,
  readAcceptance,
  writeAcceptance,
  type TermsAcceptance,
  type TermsStorage,
} from '@/lib/terms'

/**
 * The terms gate. Every surface sits behind it.
 *
 * Two boxes, both required, both the user's own statement: that they are not resident in a
 * restricted jurisdiction, and that they have read the risks. The record is stored per browser
 * with the version of the terms it accepted, so changing the disclosures re-prompts everybody.
 *
 * It renders `null` on the first paint rather than the gate, because the acceptance lives in
 * `localStorage` and a server render cannot know it: flashing the gate at somebody who already
 * accepted is worse than a frame of nothing.
 */
export function TermsGate({
  children,
  storage,
  now = () => Math.floor(Date.now() / 1000),
}: {
  children: React.ReactNode
  storage?: TermsStorage | null
  now?: () => number
}) {
  const store = React.useMemo(() => (storage === undefined ? browserStorage() : storage), [storage])
  const [record, setRecord] = React.useState<TermsAcceptance | null>(null)
  const [hydrated, setHydrated] = React.useState(false)
  const [notRestricted, setNotRestricted] = React.useState(false)
  const [readRisk, setReadRisk] = React.useState(false)

  React.useEffect(() => {
    setRecord(readAcceptance(store))
    setHydrated(true)
  }, [store])

  if (!hydrated) return null
  if (isCurrent(record)) return <>{children}</>

  const accept = () => {
    const next: TermsAcceptance = {
      version: TERMS_VERSION,
      acceptedAt: now(),
      attestedNotRestricted: notRestricted,
      acknowledgedRisk: readRisk,
    }
    writeAcceptance(store, next)
    setRecord(next)
  }

  return (
    <div className="mx-auto max-w-2xl py-8" data-testid="terms-gate">
      <div className="space-y-4">
        <Kicker>Before you continue</Kicker>
        <h1 className="ledger-title">Two statements, both yours</h1>
        <Rule weight="ink" />
        <p className="text-sm leading-relaxed text-dim">
          Amplestocks is a set of public, immutable contracts. This interface is information about them. It is not
          investment advice, not an offer and not a solicitation.
        </p>
      </div>

      <div className="mt-8 space-y-5 border-t border-hair pt-6">
        <label className="flex items-start gap-3 text-sm leading-relaxed">
          <input
            type="checkbox"
            className="mt-1 h-4 w-4 shrink-0 accent-[var(--ink)]"
            checked={notRestricted}
            onChange={(e) => setNotRestricted(e.target.checked)}
            data-testid="attest-jurisdiction"
          />
          <span>
            I am not a resident of, and am not accessing this interface from,{' '}
            {BLOCKED_JURISDICTIONS.slice(0, -1).join(', ')} or {BLOCKED_JURISDICTIONS[BLOCKED_JURISDICTIONS.length - 1]}.
          </span>
        </label>
        <label className="flex items-start gap-3 text-sm leading-relaxed">
          <input
            type="checkbox"
            className="mt-1 h-4 w-4 shrink-0 accent-[var(--ink)]"
            checked={readRisk}
            onChange={(e) => setReadRisk(e.target.checked)}
            data-testid="attest-risk"
          />
          <span>
            I have read the{' '}
            <Link href="/risk" className="underline decoration-rule underline-offset-4 hover:decoration-ink">
              risk disclosures
            </Link>
            , including that redemption is the only floor, that bid depth is the protocol’s own liquidity and nothing
            else, and that the premium to NAV is a number rather than a promise.
          </span>
        </label>
        <Button onClick={accept} disabled={!notRestricted || !readRisk} data-testid="accept-terms">
          Continue
        </Button>
        <p className="text-xs leading-relaxed text-dim">
          Stored in this browser only. No account, no cookie sent anywhere, no record kept by anyone else. Terms version{' '}
          {TERMS_VERSION}.
        </p>
      </div>
    </div>
  )
}
