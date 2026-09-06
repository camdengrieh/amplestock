// SPDX-License-Identifier: MIT
import {cva, type VariantProps} from 'class-variance-authority'
import * as React from 'react'

import {cn} from '@/lib/utils'

const alertVariants = cva('relative w-full rounded-lg border p-4 text-sm', {
  variants: {
    variant: {
      default: 'border-border bg-card text-card-foreground',
      warning: 'border-amber-500/40 bg-amber-500/10 text-amber-200',
      danger: 'border-red-500/40 bg-red-500/10 text-red-200',
      info: 'border-sky-500/40 bg-sky-500/10 text-sky-200',
    },
  },
  defaultVariants: {variant: 'default'},
})

export interface AlertProps extends React.HTMLAttributes<HTMLDivElement>, VariantProps<typeof alertVariants> {}

export function Alert({className, variant, ...props}: AlertProps) {
  return <div role="alert" className={cn(alertVariants({variant}), className)} {...props} />
}

export function AlertTitle({className, ...props}: React.HTMLAttributes<HTMLHeadingElement>) {
  return <h5 className={cn('mb-1 font-medium leading-none tracking-tight', className)} {...props} />
}

export function AlertDescription({className, ...props}: React.HTMLAttributes<HTMLParagraphElement>) {
  return <div className={cn('text-sm opacity-90 [&_p]:leading-relaxed', className)} {...props} />
}
