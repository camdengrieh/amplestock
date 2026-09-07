// SPDX-License-Identifier: MIT
'use client'

import * as TabsPrimitive from '@radix-ui/react-tabs'
import * as React from 'react'

import {cn} from '@/lib/utils'

/**
 * The design's segmented control: one 1px ink box split by a 1px ink rule, the selected half filled.
 *
 * Not underlined tabs — that treatment belongs to the nav. A control that chooses between two
 * directions of the same trade is a switch, and the design draws it as one.
 */
export const Tabs = TabsPrimitive.Root

export const TabsList = React.forwardRef<
  React.ComponentRef<typeof TabsPrimitive.List>,
  React.ComponentPropsWithoutRef<typeof TabsPrimitive.List>
>(function TabsList({className, ...props}, ref) {
  return <TabsPrimitive.List ref={ref} className={cn('flex border border-ink', className)} {...props} />
})

export const TabsTrigger = React.forwardRef<
  React.ComponentRef<typeof TabsPrimitive.Trigger>,
  React.ComponentPropsWithoutRef<typeof TabsPrimitive.Trigger>
>(function TabsTrigger({className, ...props}, ref) {
  return (
    <TabsPrimitive.Trigger
      ref={ref}
      className={cn(
        'flex-1 whitespace-nowrap border-l border-ink py-[13px] font-mono text-[10px] uppercase tracking-[0.16em] text-dim transition-colors first:border-l-0 hover:text-ink disabled:pointer-events-none disabled:opacity-50 data-[state=active]:bg-fill data-[state=active]:text-onfill',
        className,
      )}
      {...props}
    />
  )
})

export const TabsContent = React.forwardRef<
  React.ComponentRef<typeof TabsPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof TabsPrimitive.Content>
>(function TabsContent({className, ...props}, ref) {
  return <TabsPrimitive.Content ref={ref} className={cn('mt-4', className)} {...props} />
})
