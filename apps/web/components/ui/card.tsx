// SPDX-License-Identifier: MIT
import * as React from 'react'

import {cn} from '@/lib/utils'

/**
 * A group of rows under a label.
 *
 * The design has no card: what looks like one is a mono label, a 2px ink rule, and rows separated by
 * hairlines with nothing around them. These exports keep the shadcn names the surfaces already
 * speak, but they draw the design's shape — `Card` is a bare block, `CardHeader` is the label, and
 * `CardTitle` is the mono label itself.
 */
export function Card({className, ...props}: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('min-w-0', className)} {...props} />
}

export function CardHeader({className, ...props}: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('mb-2 flex flex-col gap-1', className)} {...props} />
}

export function CardTitle({className, ...props}: React.HTMLAttributes<HTMLHeadingElement>) {
  return <h3 className={cn('ledger-label', className)} {...props} />
}

export function CardDescription({className, ...props}: React.HTMLAttributes<HTMLParagraphElement>) {
  return <p className={cn('max-w-[62ch] text-[15px] leading-normal text-dim', className)} {...props} />
}

export function CardContent({className, ...props}: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('border-t-2 border-ink', className)} {...props} />
}

export function CardFooter({className, ...props}: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('flex items-center pt-3', className)} {...props} />
}
