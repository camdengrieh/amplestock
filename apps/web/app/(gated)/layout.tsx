// SPDX-License-Identifier: MIT
import * as React from 'react'

import {TermsGate} from '@/components/gates/terms-gate'

/**
 * Every trading surface sits behind the terms gate. `/risk` and `/blocked` deliberately do not:
 * somebody who has not accepted, or who has been geo-blocked, still needs to be able to read why.
 */
export default function GatedLayout({children}: {children: React.ReactNode}) {
  return <TermsGate>{children}</TermsGate>
}
