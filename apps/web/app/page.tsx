// SPDX-License-Identifier: MIT
import Link from 'next/link'

import {Card, CardContent, CardDescription, CardHeader, CardTitle} from '@/components/ui/card'
import {SURFACES} from '@/lib/surfaces'

export default function HomePage() {
  return (
    <div className="space-y-8">
      <header className="max-w-3xl space-y-3">
        <h1 className="text-3xl font-semibold tracking-tight">Amplestocks</h1>
        <p className="text-muted-foreground">
          $AMPS is a share in a vault that holds tokenized equities on Robinhood Chain. Its floor is redemption: burn
          your AMPS and take a pro-rata slice of everything the vault holds, less a fee, through a code path that reads
          no oracle and that no governance action can block.
        </p>
        <p className="text-muted-foreground">
          Everything above that floor is a market. The pools are protocol-owned, so the bid under AMPS is exactly the
          liquidity the protocol has earned — published per pool, not hidden.
        </p>
      </header>
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        {SURFACES.map((surface) => (
          <Link key={surface.href} href={surface.href} className="block">
            <Card className="h-full transition-colors hover:border-primary/50">
              <CardHeader>
                <CardTitle>{surface.label}</CardTitle>
                <CardDescription>{surface.blurb}</CardDescription>
              </CardHeader>
            </Card>
          </Link>
        ))}
      </div>
      <Card>
        <CardHeader>
          <CardTitle>What this interface will not tell you</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm text-muted-foreground">
          <p>Where the price is going. It shows the market price, the reference price and NAV per share, and the premium between them as a number.</p>
          <p>That a return is available. Staking distributes fees that have already been collected; bonds are a discounted issuance with finite capacity, not income.</p>
          <p>That redemption pays cash. It pays assets, pro rata, in whatever the vault holds at that moment.</p>
        </CardContent>
      </Card>
    </div>
  )
}
