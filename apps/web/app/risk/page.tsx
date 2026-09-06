// SPDX-License-Identifier: MIT
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'
import {RISK_DISCLOSURES} from '@/lib/copy'

export const metadata = {
  title: 'Risk — Amplestocks',
  description: 'What can go wrong with $AMPS, stated plainly.',
}

/**
 * Static. No wallet, no chain read, no gate: this page has to render for somebody who has accepted
 * nothing and been blocked by everything.
 */
export default function RiskPage() {
  return (
    <div className="mx-auto max-w-3xl space-y-6" data-testid="risk-page">
      <header className="space-y-2">
        <h1 className="text-3xl font-semibold tracking-tight">Risk</h1>
        <p className="text-muted-foreground">
          Every one of these is a real property of the system rather than boilerplate. Read them before you use any
          other page.
        </p>
      </header>
      {RISK_DISCLOSURES.map((disclosure) => (
        <Card key={disclosure.id} id={disclosure.id}>
          <CardHeader>
            <CardTitle>{disclosure.title}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm leading-relaxed text-muted-foreground">
            {disclosure.body.map((paragraph, i) => (
              <p key={i}>{paragraph}</p>
            ))}
          </CardContent>
        </Card>
      ))}
    </div>
  )
}
