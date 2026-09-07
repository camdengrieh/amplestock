// SPDX-License-Identifier: MIT
import * as React from 'react'

import {cn} from '@/lib/utils'

/** A rule where a figure will be. Never a grey block: Ledger has no blocks. */
export function Skeleton({className, ...props}: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('h-px w-full animate-pulse bg-rule', className)} {...props} />
}
