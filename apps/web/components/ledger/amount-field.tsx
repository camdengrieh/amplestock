// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'

import {Input} from '@/components/ui/input'
import {cn} from '@/lib/utils'

/**
 * The design's amount well: a 2px ink rule above, a 1px rule below, and a 52px serif numeral
 * sitting in between with its unit beside it in mono.
 *
 * Underneath, when there is a balance to show, a mono `11px` line with a bordered `Max` chip. The
 * chip is `border-rule` until it is hovered and then `border-ink` — the design's smallest hover.
 */
export function AmountField({
  id,
  value,
  onChange,
  unit,
  balance,
  onMax,
  placeholder = '0.0',
  className,
  ...rest
}: {
  id: string
  value: string
  onChange: (next: string) => void
  unit?: string
  /** Already formatted. Omitted entirely when there is no wallet to read one from. */
  balance?: string
  onMax?: () => void
  placeholder?: string
  className?: string
} & Omit<React.InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange' | 'id' | 'placeholder'>) {
  return (
    <div className={cn('border-b border-rule border-t-2 border-t-ink pb-[18px] pt-4', className)}>
      <div className="flex items-baseline gap-3">
        <Input
          id={id}
          inputMode="decimal"
          autoComplete="off"
          spellCheck={false}
          placeholder={placeholder}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          {...rest}
        />
        {unit ? <span className="shrink-0 font-mono text-[13px] tracking-[0.1em]">{unit}</span> : null}
      </div>
      {balance !== undefined || onMax ? (
        <div className="mt-3.5 flex items-center gap-3.5 font-mono text-[11px] tracking-[0.06em] text-dim">
          {balance !== undefined ? <span>Balance {balance}</span> : null}
          {onMax ? (
            <button
              type="button"
              onClick={onMax}
              className="border border-rule px-2.5 py-1 text-dim transition-colors hover:border-ink hover:text-ink"
            >
              Max
            </button>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}
