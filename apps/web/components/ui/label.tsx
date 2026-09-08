// SPDX-License-Identifier: MIT
'use client'

import * as LabelPrimitive from '@radix-ui/react-label'
import * as React from 'react'

import {cn} from '@/lib/utils'

/** The mono `10px / 0.16em` label the design puts above every control. */
export const Label = React.forwardRef<
  React.ComponentRef<typeof LabelPrimitive.Root>,
  React.ComponentPropsWithoutRef<typeof LabelPrimitive.Root>
>(function Label({className, ...props}, ref) {
  return <LabelPrimitive.Root ref={ref} className={cn('ledger-label block', className)} {...props} />
})
