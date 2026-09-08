// SPDX-License-Identifier: MIT
import * as React from 'react'

import {cn} from '@/lib/utils'

/**
 * A ledger table, at the design's measurements.
 *
 * Head: mono `9px / 0.14em` uppercase in `--dim`, weight 400, over a 1px `--rule`. Body: mono 13px
 * tabular over 1px `--hair`, rows hovering to `--hair`. Padding is asymmetric on purpose — the first
 * column has no left pad and the last none on the right, so the table's own edges line up with the
 * rules above and below it rather than being inset from them.
 *
 * It always scrolls inside its own container, so a wide table on a phone moves sideways and the
 * page does not.
 */
export function Table({className, ...props}: React.HTMLAttributes<HTMLTableElement>) {
  return (
    <div className="ledger-scroll w-full">
      <table className={cn('w-full min-w-max border-collapse', className)} {...props} />
    </div>
  )
}

export function TableHeader({className, ...props}: React.HTMLAttributes<HTMLTableSectionElement>) {
  return <thead className={className} {...props} />
}

export function TableBody({className, ...props}: React.HTMLAttributes<HTMLTableSectionElement>) {
  return <tbody className={className} {...props} />
}

export function TableRow({className, ...props}: React.HTMLAttributes<HTMLTableRowElement>) {
  return <tr className={cn('hover:bg-hair', className)} {...props} />
}

export function TableHead({className, align, ...props}: React.ThHTMLAttributes<HTMLTableCellElement>) {
  return (
    <th
      className={cn(
        'ledger-micro whitespace-nowrap border-b border-rule px-3 py-3 text-left align-bottom first:pl-0 last:pr-0',
        align === 'right' && 'text-right',
        className,
      )}
      {...props}
    />
  )
}

export function TableCell({className, align, ...props}: React.TdHTMLAttributes<HTMLTableCellElement>) {
  return (
    <td
      className={cn(
        'ledger-cell border-b border-hair px-3 py-[11px] align-middle first:pl-0 last:pr-0',
        align === 'right' && 'text-right',
        className,
      )}
      {...props}
    />
  )
}
