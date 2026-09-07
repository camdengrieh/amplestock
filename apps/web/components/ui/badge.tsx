// SPDX-License-Identifier: MIT
import {cva, type VariantProps} from 'class-variance-authority'
import * as React from 'react'

import {cn} from '@/lib/utils'

/**
 * A state, written rather than boxed.
 *
 * The design does not draw badges: a gate state is the bare word `OK` or `DEGRADED` in mono
 * `10px / 0.1em` in the table's last column, and a market's state is `Open` or `Closed` the same
 * way. So `muted` — the default shape here — is exactly that, and the bordered variants are kept
 * only for the few places this implementation needs a tone the design never had to show.
 */
const badgeVariants = cva('inline-flex items-center font-mono uppercase', {
  variants: {
    variant: {
      default: 'text-[10px] tracking-[0.1em] text-ink',
      muted: 'text-[10px] tracking-[0.1em] text-dim',
      outline: 'border border-rule px-1.5 py-0.5 text-[10px] tracking-[0.1em] text-ink',
      secondary: 'border border-rule px-1.5 py-0.5 text-[10px] tracking-[0.1em] text-dim',
      success: 'text-[10px] tracking-[0.1em] text-tone-ok',
      warning: 'text-[10px] tracking-[0.1em] text-tone-warn',
      danger: 'text-[10px] tracking-[0.1em] text-tone-bad',
    },
  },
  defaultVariants: {variant: 'default'},
})

export interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement>, VariantProps<typeof badgeVariants> {}

export function Badge({className, variant, ...props}: BadgeProps) {
  return <span className={cn(badgeVariants({variant}), className)} {...props} />
}

export {badgeVariants}
