// SPDX-License-Identifier: MIT
import {cva, type VariantProps} from 'class-variance-authority'
import * as React from 'react'

import {cn} from '@/lib/utils'

/**
 * The design's note: a 2px left rule, a mono uppercase title, and 17px text. No fill, no icon, no
 * tinted background — the body stays the same colour as the page so it is as readable as everything
 * around it, and the tone lives in the rule and the title alone.
 *
 * The design is monochrome and has one note treatment. The three tone variants are this
 * implementation's addition, for states the design never had to draw: a degraded quote, a refused
 * swap, a contract with no address. See `design/ledger/ledger.md` §3.
 */
const alertVariants = cva('relative w-full border-l-2 py-0.5 pl-5', {
  variants: {
    variant: {
      default: 'border-ink',
      info: 'border-ink',
      warning: 'border-tone-warn',
      danger: 'border-tone-bad',
    },
  },
  defaultVariants: {variant: 'default'},
})

const titleVariants = cva('ledger-label', {
  variants: {
    variant: {
      default: 'text-dim',
      info: 'text-dim',
      warning: 'text-tone-warn',
      danger: 'text-tone-bad',
    },
  },
  defaultVariants: {variant: 'default'},
})

export interface AlertProps extends React.HTMLAttributes<HTMLDivElement>, VariantProps<typeof alertVariants> {}

const AlertVariantContext = React.createContext<VariantProps<typeof alertVariants>['variant']>('default')

export function Alert({className, variant, ...props}: AlertProps) {
  return (
    <AlertVariantContext.Provider value={variant ?? 'default'}>
      <div role="alert" className={cn(alertVariants({variant}), className)} {...props} />
    </AlertVariantContext.Provider>
  )
}

export function AlertTitle({className, ...props}: React.HTMLAttributes<HTMLHeadingElement>) {
  const variant = React.useContext(AlertVariantContext)
  return <h5 className={cn(titleVariants({variant}), className)} {...props} />
}

/** The body. The first paragraph is the design's 17px lead; the rest drop to 15px in `--dim`. */
export function AlertDescription({className, ...props}: React.HTMLAttributes<HTMLParagraphElement>) {
  return (
    <div
      className={cn(
        'mt-2 max-w-[68ch] space-y-2.5 text-[15px] leading-normal text-dim [&>p:first-child]:text-[17px] [&>p:first-child]:leading-[1.45] [&>p:first-child]:text-ink',
        className,
      )}
      {...props}
    />
  )
}
