// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import Link from 'next/link'

import {Button} from '@/components/ui/button'
import {Card, CardContent, CardDescription, CardHeader, CardTitle} from '@/components/ui/card'
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
    <div className="mx-auto flex min-h-[70vh] max-w-2xl items-center px-4" data-testid="terms-gate">
      <Card className="w-full">
        <CardHeader>
          <CardTitle>Before you continue</CardTitle>
          <CardDescription>
            Amplestocks is a set of public, immutable contracts. This interface is information about them. It is not
            investment advice, not an offer and not a solicitation.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <label className="flex items-start gap-3 text-sm">
            <input
              type="checkbox"
              className="mt-1"
              checked={notRestricted}
              onChange={(e) => setNotRestricted(e.target.checked)}
              data-testid="attest-jurisdiction"
            />
            <span>
              I am not a resident of, and am not accessing this interface from, {BLOCKED_JURISDICTIONS.slice(0, -1).join(', ')} or{' '}
              {BLOCKED_JURISDICTIONS[BLOCKED_JURISDICTIONS.length - 1]}.
            </span>
          </label>
          <label className="flex items-start gap-3 text-sm">
            <input
              type="checkbox"
              className="mt-1"
              checked={readRisk}
              onChange={(e) => setReadRisk(e.target.checked)}
              data-testid="attest-risk"
            />
            <span>
              I have read the{' '}
              <Link href="/risk" className="underline">
                risk disclosures
              </Link>
              , including that redemption is the only floor, that bid depth is the protocol’s own liquidity and nothing
              else, and that the premium to NAV is a number rather than a promise.
            </span>
          </label>
          <Button onClick={accept} disabled={!notRestricted || !readRisk} data-testid="accept-terms">
            Continue
          </Button>
          <p className="text-xs text-muted-foreground">
            Stored in this browser only. No account, no cookie sent anywhere, no record kept by anyone else. Terms
            version {TERMS_VERSION}.
          </p>
        </CardContent>
      </Card>
    </div>
  )
}
