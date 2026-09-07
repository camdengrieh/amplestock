// SPDX-License-Identifier: MIT
'use client'

import * as SwitchPrimitives from '@radix-ui/react-switch'
import * as React from 'react'

import {cn} from '@/lib/utils'

export const Switch = React.forwardRef<
  React.ComponentRef<typeof SwitchPrimitives.Root>,
  React.ComponentPropsWithoutRef<typeof SwitchPrimitives.Root>
>(function Switch({className, ...props}, ref) {
  return (
    <SwitchPrimitives.Root
      className={cn(
        'peer inline-flex h-5 w-9 shrink-0 cursor-pointer items-center border border-rule transition-colors disabled:cursor-not-allowed disabled:opacity-50 data-[state=checked]:border-ink data-[state=checked]:bg-ink',
        className,
      )}
      {...props}
      ref={ref}
    >
      <SwitchPrimitives.Thumb className="pointer-events-none block h-3.5 w-3.5 bg-ink transition-transform data-[state=checked]:translate-x-[1.15rem] data-[state=checked]:bg-paper data-[state=unchecked]:translate-x-[2px]" />
    </SwitchPrimitives.Root>
  )
})
