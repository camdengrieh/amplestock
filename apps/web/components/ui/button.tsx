// SPDX-License-Identifier: MIT
'use client'

import {Slot} from '@radix-ui/react-slot'
import {cva, type VariantProps} from 'class-variance-authority'
import * as React from 'react'

import {cn} from '@/lib/utils'

/**
 * Two buttons, taken from the design and no others.
 *
 * **Fill** (`default`) — `1px solid ink`, `--fill` ground, `--onfill` type, mono uppercase. It means
 * "do the thing", and the design fades it to `opacity:0.82` on hover rather than changing colour.
 * **Rule** (`outline`) — the same box with a transparent ground, which *inverts* on hover. That
 * inversion is the design's only hover flourish and it is worth keeping exactly.
 *
 * `size="block"` is the full-width `padding:18px`, `11px / 0.18em` submit at the foot of every form.
 * `size="default"` is the `10px / 0.14em` secondary at `padding:10px 20px`.
 */
const buttonVariants = cva(
  'inline-flex items-center justify-center gap-2 whitespace-nowrap border font-mono uppercase transition-[background-color,color,opacity] disabled:cursor-not-allowed disabled:opacity-45',
  {
    variants: {
      variant: {
        default: 'border-ink bg-fill text-onfill hover:opacity-[0.82]',
        destructive: 'border-tone-bad bg-tone-bad text-paper hover:opacity-[0.82]',
        outline: 'border-ink bg-transparent text-ink hover:bg-fill hover:text-onfill',
        secondary: 'border-rule bg-transparent text-dim hover:border-ink hover:text-ink',
        ghost: 'border-transparent bg-transparent text-dim hover:text-ink',
        link: 'border-transparent bg-transparent text-ink underline decoration-rule underline-offset-4 hover:decoration-ink',
      },
      size: {
        default: 'px-5 py-2.5 text-[10px] tracking-[0.14em]',
        sm: 'px-3.5 py-1.5 text-[10px] tracking-[0.14em]',
        block: 'w-full px-6 py-[18px] text-[11px] tracking-[0.18em]',
        chip: 'px-2.5 py-1 text-[11px] tracking-[0.06em] normal-case',
        icon: 'h-9 w-9 px-0 text-[10px] tracking-[0.14em]',
      },
    },
    defaultVariants: {variant: 'default', size: 'default'},
  },
)

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean
}

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  {className, variant, size, asChild = false, ...props},
  ref,
) {
  const Comp = asChild ? Slot : 'button'
  return <Comp className={cn(buttonVariants({variant, size, className}))} ref={ref} {...props} />
})

export {buttonVariants}
