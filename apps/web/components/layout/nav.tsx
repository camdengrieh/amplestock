// SPDX-License-Identifier: MIT
'use client'

import Link from 'next/link'
import {usePathname} from 'next/navigation'
import * as React from 'react'

import {SURFACES} from '@/lib/surfaces'
import {cn} from '@/lib/utils'

/**
 * The app nav, as the design draws it: mono `10px / 0.14em` uppercase, `gap:20px`, idle links in
 * `--dim` and the current one marked by a `2px solid ink` underline with `padding-bottom:2px`.
 *
 * No pills, no fill. It is an ordinary list of links, so Tab walks it and a screen reader reads it
 * as navigation; `aria-current="page"` carries the state the underline shows.
 */
export function Nav({className}: {className?: string}) {
  const pathname = usePathname()
  return (
    <nav aria-label="Surfaces" className={cn('ledger-scroll min-w-0', className)}>
      <ul className="flex items-center gap-5">
        {SURFACES.map((surface) => {
          const active = pathname === surface.href || pathname.startsWith(`${surface.href}/`)
          return (
            <li key={surface.href}>
              <Link
                href={surface.href}
                aria-current={active ? 'page' : undefined}
                data-testid={`nav-${surface.href.slice(1)}`}
                className={cn(
                  'ledger-nav block whitespace-nowrap transition-colors',
                  active ? 'border-b-2 border-ink pb-0.5 text-ink' : 'text-dim hover:text-ink',
                )}
              >
                {surface.label}
              </Link>
            </li>
          )
        })}
      </ul>
    </nav>
  )
}

/**
 * The design's mobile tab bar: four tabs across the foot of the screen, `min-height:52px`, the
 * current one filled and the rest divided by hairlines.
 *
 * Four, not nine — the design picks the four a person on a phone actually reaches for and leaves the
 * rest to the Menu. `Buy` is the design's first tab; `Vault`, `Redeem` and `Docs` follow it.
 */
const TAB_HREFS = ['/buy', '/vault', '/redeem', '/docs'] as const

export function MobileTabBar() {
  const pathname = usePathname()
  const tabs = TAB_HREFS.map((href) => SURFACES.find((s) => s.href === href)).filter(
    (s): s is NonNullable<typeof s> => s !== undefined,
  )
  return (
    <nav
      aria-label="Primary"
      data-testid="mobile-tabs"
      className="fixed inset-x-0 bottom-0 z-40 grid grid-cols-4 border-t border-ink bg-paper md:hidden"
    >
      {tabs.map((tab) => {
        const active = pathname === tab.href || pathname.startsWith(`${tab.href}/`)
        return (
          <Link
            key={tab.href}
            href={tab.href}
            aria-current={active ? 'page' : undefined}
            className={cn(
              'flex min-h-[52px] items-center justify-center font-mono text-[9px] uppercase tracking-[0.14em]',
              active ? 'bg-fill text-onfill' : 'border-l border-hair text-dim first:border-l-0',
            )}
          >
            {tab.label}
          </Link>
        )
      })}
    </nav>
  )
}
