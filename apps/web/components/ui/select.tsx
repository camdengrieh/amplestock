// SPDX-License-Identifier: MIT
import * as React from 'react'

import {cn} from '@/lib/utils'

/**
 * The native select, exactly as the design draws it: a 46px box with a 1px rule, mono at 13px.
 *
 * Native rather than a custom listbox on purpose — it is the one picker that already works with
 * every screen reader, every keyboard and every mobile browser, and nothing about a token chooser
 * justifies re-implementing that.
 */
export const Select = React.forwardRef<HTMLSelectElement, React.SelectHTMLAttributes<HTMLSelectElement>>(
  function Select({className, children, ...props}, ref) {
    return (
      <select
        ref={ref}
        className={cn(
          'h-[46px] w-full cursor-pointer border border-rule bg-transparent px-3 font-mono text-[13px] text-ink outline-none hover:border-ink focus:border-ink disabled:cursor-not-allowed disabled:opacity-50',
          className,
        )}
        {...props}
      >
        {children}
      </select>
    )
  },
)
