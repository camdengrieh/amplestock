// SPDX-License-Identifier: MIT
import * as React from 'react'

import {Kicker} from '@/components/ledger/primitives'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {cn} from '@/lib/utils'

/** Shown when the surface's contracts have no address configured for this chain. */
export function NotDeployed({what = 'This surface'}: {what?: string}) {
  return (
    <Alert variant="warning" data-testid="not-deployed">
      <AlertTitle>Not deployed on this chain</AlertTitle>
      <AlertDescription>
        <p>
          {what} needs a deployed Amplestocks contract set and none is configured for the selected chain. Nothing is
          being read, and no number on this page is real.
        </p>
        <p>
          See <code className="font-mono text-[13px]">.env.example</code>.
        </p>
      </AlertDescription>
    </Alert>
  )
}

/** Shown when the indexer is unreachable. Never a zeroed chart. */
export function IndexerUnavailable({what = 'This panel', reason}: {what?: string; reason?: string}) {
  return (
    <Alert variant="warning" data-testid="indexer-unavailable">
      <AlertTitle>Indexer unavailable</AlertTitle>
      <AlertDescription>
        <p>
          {what} is served by the indexer, which did not answer{reason ? ` (${reason})` : ''}. History is unavailable —
          it is not zero.
        </p>
        <p>Everything read directly from the chain on this page is unaffected.</p>
      </AlertDescription>
    </Alert>
  )
}

/** Nothing to show, and why. A rule and a sentence, never a blank region. */
export function EmptyState({title, children}: {title: string; children?: React.ReactNode}) {
  return (
    <div className="border-t border-rule py-5" data-testid="empty-state">
      <p className="ledger-label">{title}</p>
      {children ? <div className="mt-2 max-w-[64ch] text-[15px] leading-normal text-dim">{children}</div> : null}
    </div>
  )
}

/**
 * The page head, exactly as the design draws it on every app screen: a kicker and a 52px title on
 * the left, the lede on the right, and — on the surfaces whose next block does not bring its own
 * rule — a 2px ink rule underneath.
 *
 * `rule="none"` is the Vault and Stake case: those pages open on a stat band that already carries a
 * `border-top:2px solid ink`, and a second rule directly above it would double the line.
 */
export function SurfaceHeading({
  title,
  lede,
  kicker,
  rule = 'below',
  className,
}: {
  title: string
  lede: string
  kicker?: string
  rule?: 'below' | 'none'
  className?: string
}) {
  return (
    <header
      className={cn(
        'flex flex-wrap items-end justify-between gap-x-8 gap-y-4',
        rule === 'below' && 'border-b-2 border-ink pb-[18px]',
        className,
      )}
      data-testid="surface-heading"
    >
      <div className="min-w-0">
        {kicker ? <Kicker className="mb-2">{kicker}</Kicker> : null}
        <h1 className="ledger-title">{title}</h1>
      </div>
      <p className="max-w-[52ch] text-[16px] leading-normal text-dim">{lede}</p>
    </header>
  )
}
