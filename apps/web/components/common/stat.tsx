// SPDX-License-Identifier: MIT
import * as React from 'react'

import {DataRow, StatBand, StatCell} from '@/components/ledger/primitives'
import {cn} from '@/lib/utils'
import {Value} from './value'

/**
 * The three shapes every surface builds its numbers from, mapped onto the design's own blocks.
 *
 * `StatGrid` + `Stat` are the headline band: `repeat(auto-fit, minmax(200px,1fr))` with 1px hair
 * gaps showing through a shared ground, over a 2px ink rule. `FieldRow` is the `k / v / b` row.
 */
export interface StatProps {
  label: string
  value?: React.ReactNode
  unavailable?: boolean
  reason?: string
  hint?: string
  className?: string
  /** The 44px headline figure. Without it the cell uses the 38px landing size. */
  emphasis?: boolean
}

export function Stat({label, value, unavailable, reason, hint, className, emphasis = true}: StatProps) {
  return (
    <StatCell
      label={label}
      size={emphasis ? 'stat' : 'big'}
      {...(hint ? {note: hint} : {})}
      {...(className ? {className} : {})}
    >
      <Value unavailable={unavailable} reason={reason}>
        {value}
      </Value>
    </StatCell>
  )
}

export function StatGrid({
  children,
  className,
  min,
  ...rest
}: React.HTMLAttributes<HTMLDivElement> & {min?: number}) {
  return (
    <StatBand className={cn(className)} {...(min !== undefined ? {min} : {})} {...rest}>
      {children}
    </StatBand>
  )
}

export function FieldRow({
  label,
  children,
  hint,
}: {
  label: React.ReactNode
  children: React.ReactNode
  hint?: React.ReactNode
}) {
  return (
    <DataRow label={label} {...(hint ? {note: hint} : {})}>
      {children}
    </DataRow>
  )
}
