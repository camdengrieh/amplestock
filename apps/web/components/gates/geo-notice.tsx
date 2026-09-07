// SPDX-License-Identifier: MIT
import * as React from 'react'

import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {BLOCKED_JURISDICTIONS} from '@/lib/geo'

/**
 * Shown when the edge has no country signal at all. The self-attestation is then the only gate,
 * and saying so is more honest than implying an IP check happened.
 */
export function GeoUnverifiedNotice({unverified}: {unverified: boolean}) {
  if (!unverified) return null
  return (
    <Alert variant="info" data-testid="geo-unverified">
      <AlertTitle>No location check on this deployment</AlertTitle>
      <AlertDescription>
        This host provides no IP country signal, so your own attestation is the only jurisdiction check. This interface
        is not available to residents of {BLOCKED_JURISDICTIONS.join(', ')}.
      </AlertDescription>
    </Alert>
  )
}
