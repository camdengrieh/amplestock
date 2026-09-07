// SPDX-License-Identifier: MIT
import * as React from 'react'

import {cn} from '@/lib/utils'

/**
 * The amount field, as the design draws it: no box at all.
 *
 * A 52px Newsreader numeral with `letter-spacing:-0.03em`, sitting borderless inside a well that is
 * a 2px ink rule above and a 1px rule below (`AmountField`). The unit sits beside it in mono. It is
 * the largest thing on the screen because it is the number the person is deciding about.
 */
export const Input = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  function Input({className, type, ...props}, ref) {
    return (
      <input
        type={type}
        className={cn(
          'ledger-amount w-full min-w-0 flex-1 border-0 bg-transparent p-0 text-ink outline-none placeholder:text-dim disabled:cursor-not-allowed disabled:opacity-50',
          className,
        )}
        ref={ref}
        {...props}
      />
    )
  },
)

/** A small mono text field — the docs search, and nothing else in the design. */
export const TextField = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  function TextField({className, ...props}, ref) {
    return (
      <input
        className={cn(
          'w-full border border-rule bg-transparent px-[11px] py-[9px] font-mono text-[11px] tracking-[0.04em] text-ink outline-none placeholder:text-dim focus:border-ink',
          className,
        )}
        ref={ref}
        {...props}
      />
    )
  },
)
