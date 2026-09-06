// SPDX-License-Identifier: MIT
import * as React from 'react'

import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {NOTES} from '@/lib/copy'
import {degradedBitLabels, degradedBits} from '@/lib/quoter'

/**
 * The banner shown whenever a quote came back with any `degraded` bit raised.
 *
 * It names which sub-read failed, because the bitfield is *designed* to let a consumer keep using
 * the parts that did not fail. It also says the thing that matters most: a degraded quote is not
 * permission to trade, even when `refuseBuy`/`refuseSell` are `false` — those fail open for
 * display.
 */
export function DegradedNotice({degraded}: {degraded: number}) {
  if (degraded === 0) return null
  const bits = degradedBits(degraded)
  return (
    <Alert variant="warning" data-testid="degraded-notice">
      <AlertTitle>Some values are unavailable</AlertTitle>
      <AlertDescription>
        <p className="mb-2">{NOTES.degraded}</p>
        <ul className="list-disc space-y-1 pl-5">
          {bits.map((bit) => (
            <li key={bit}>{degradedBitLabels[bit]}</li>
          ))}
        </ul>
        <p className="mt-2">
          A quote with any flag raised is not permission to trade — the refusal flags fail open for display, not for
          execution.
        </p>
      </AlertDescription>
    </Alert>
  )
}
