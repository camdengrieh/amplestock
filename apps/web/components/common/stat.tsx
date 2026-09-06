// SPDX-License-Identifier: MIT
import * as React from 'react'

import {cn} from '@/lib/utils'
import {Value} from './value'

export interface StatProps {
  label: string
  value?: React.ReactNode
  unavailable?: boolean
  reason?: string
  hint?: string
  className?: string
  emphasis?: boolean
}

export function Stat({label, value, unavailable, reason, hint, className, emphasis}: StatProps) {
  return (
    <div className={cn('flex flex-col gap-1', className)}>
      <dt className="text-xs uppercase tracking-wide text-muted-foreground">{label}</dt>
      <dd className={cn('font-medium', emphasis ? 'text-2xl' : 'text-base')}>
        <Value unavailable={unavailable} reason={reason}>
          {value}
        </Value>
      </dd>
      {hint ? <p className="text-xs leading-snug text-muted-foreground">{hint}</p> : null}
    </div>
  )
}

export function StatGrid({children, className, ...rest}: React.HTMLAttributes<HTMLDListElement>) {
  return (
    <dl className={cn('grid grid-cols-2 gap-5 md:grid-cols-4', className)} {...rest}>
      {children}
    </dl>
  )
}

export function FieldRow({
  label,
  children,
  hint,
}: {
  label: string
  children: React.ReactNode
  hint?: string
}) {
  return (
    <div className="flex items-start justify-between gap-4 border-b border-border/60 py-2 last:border-0">
      <div className="min-w-0">
        <div className="text-sm text-muted-foreground">{label}</div>
        {hint ? <div className="text-xs text-muted-foreground/80">{hint}</div> : null}
      </div>
      <div className="shrink-0 text-sm font-medium">{children}</div>
    </div>
  )
}
