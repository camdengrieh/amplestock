// SPDX-License-Identifier: MIT
import * as React from 'react'

import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'

/** Shown when the surface's contracts have no address configured for this chain. */
export function NotDeployed({what = 'This surface'}: {what?: string}) {
  return (
    <Alert variant="info" data-testid="not-deployed">
      <AlertTitle>Not deployed on this chain</AlertTitle>
      <AlertDescription>
        {what} needs a deployed Amplestocks contract set and none is configured for the selected chain. Nothing is being
        read, and no number on this page is real. See <code className="font-mono">.env.example</code>.
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
        {what} is served by the indexer, which did not answer{reason ? ` (${reason})` : ''}. History is unavailable —
        it is not zero. Everything read directly from the chain on this page is unaffected.
      </AlertDescription>
    </Alert>
  )
}

export function EmptyState({title, children}: {title: string; children?: React.ReactNode}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent className="text-sm text-muted-foreground">{children}</CardContent>
    </Card>
  )
}

export function SurfaceHeading({title, lede}: {title: string; lede: string}) {
  return (
    <header className="space-y-1">
      <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
      <p className="max-w-3xl text-sm text-muted-foreground">{lede}</p>
    </header>
  )
}
