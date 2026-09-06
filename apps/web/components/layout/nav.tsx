// SPDX-License-Identifier: MIT
'use client'

import Link from 'next/link'
import {usePathname} from 'next/navigation'
import * as React from 'react'

import {SURFACES} from '@/lib/surfaces'
import {cn} from '@/lib/utils'

export function Nav() {
  const pathname = usePathname()
  return (
    <nav aria-label="Surfaces" className="flex flex-wrap items-center gap-1">
      {SURFACES.map((surface) => {
        const active = pathname === surface.href || pathname.startsWith(`${surface.href}/`)
        return (
          <Link
            key={surface.href}
            href={surface.href}
            aria-current={active ? 'page' : undefined}
            className={cn(
              'rounded-md px-3 py-1.5 text-sm transition-colors',
              active ? 'bg-muted font-medium text-foreground' : 'text-muted-foreground hover:text-foreground',
            )}
          >
            {surface.label}
          </Link>
        )
      })}
    </nav>
  )
}
