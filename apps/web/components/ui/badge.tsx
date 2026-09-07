// SPDX-License-Identifier: MIT
import {cva, type VariantProps} from 'class-variance-authority'
import * as React from 'react'

import {cn} from '@/lib/utils'

const badgeVariants = cva(
  'inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-medium transition-colors',
  {
    variants: {
      variant: {
        default: 'border-transparent bg-primary text-primary-foreground',
        secondary: 'border-transparent bg-secondary text-secondary-foreground',
        outline: 'border-border text-foreground',
        success: 'border-transparent bg-emerald-500/15 text-emerald-300',
        warning: 'border-transparent bg-amber-500/15 text-amber-300',
        danger: 'border-transparent bg-red-500/15 text-red-300',
        muted: 'border-transparent bg-muted text-muted-foreground',
      },
    },
    defaultVariants: {variant: 'default'},
  },
)

export interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement>, VariantProps<typeof badgeVariants> {}

export function Badge({className, variant, ...props}: BadgeProps) {
  return <span className={cn(badgeVariants({variant}), className)} {...props} />
}

export {badgeVariants}
