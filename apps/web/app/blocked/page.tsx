// SPDX-License-Identifier: MIT
import Link from 'next/link'

import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'
import {BLOCKED_JURISDICTIONS} from '@/lib/geo'

export const metadata = {title: 'Not available in your jurisdiction — Amplestocks'}

export default function BlockedPage() {
  return (
    <div className="mx-auto max-w-2xl">
      <Card data-testid="geo-blocked">
        <CardHeader>
          <CardTitle>Not available in your jurisdiction</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4 text-sm text-muted-foreground">
          <p>
            This interface is not available to residents of {BLOCKED_JURISDICTIONS.join(', ')}, and your connection
            appears to originate from one of them.
          </p>
          <p>
            The underlying Robinhood Stock Tokens are Jersey-issued debt securities sold to non-US persons only, and
            carry their own jurisdictional restrictions. A permissionless claim on a managed portfolio of tokenized
            securities, issued at a discount, raises questions under the US Investment Company Act and under AIFMD that
            are not settled.
          </p>
          <p>
            This block is a front-end control. The contracts are public, permissionless and unaware of it — which is
            itself something to understand before interacting with them.{' '}
            <Link href="/risk" className="underline">
              The risk disclosures
            </Link>{' '}
            remain available here.
          </p>
        </CardContent>
      </Card>
    </div>
  )
}
