// SPDX-License-Identifier: MIT
import * as React from 'react'

import {UNAVAILABLE} from '@/lib/format'
import {cn} from '@/lib/utils'

export interface ValueProps {
  /** The formatted value. Pass `null`/`undefined` for "not available". */
  children?: React.ReactNode
  /**
   * When true the value is unavailable and is rendered as a dash with a reason, never as zero.
   * This is the whole point of the component: `AmpsQuoter` zeroes the fields of a read that
   * failed, and a zero rendered as data is something a user can trade on.
   */
  unavailable?: boolean
  reason?: string
  className?: string
  title?: string
}

export function Value({children, unavailable, reason, className, title}: ValueProps) {
  if (unavailable || children === null || children === undefined || children === '') {
    return (
      <span
        className={cn('text-muted-foreground', className)}
        title={reason ?? 'Unavailable'}
        data-unavailable="true"
        aria-label={reason ? `Unavailable: ${reason}` : 'Unavailable'}
      >
        {UNAVAILABLE}
      </span>
    )
  }
  return (
    <span className={cn('tabular-nums', className)} title={title} data-unavailable="false">
      {children}
    </span>
  )
}
