// SPDX-License-Identifier: MIT
'use client'

import Link from 'next/link'
import {usePathname} from 'next/navigation'
import * as React from 'react'

import {MobileTabBar, Nav} from './nav'
import {ThemeToggle} from './theme-toggle'
import {WalletButton} from './wallet-button'
import {activeChain, isTestnet} from '@/lib/chains'
import {LEGAL_FOOTER} from '@/lib/copy'
import {featureFlags} from '@/lib/flags'
import {SURFACES} from '@/lib/surfaces'
import {cn} from '@/lib/utils'

/**
 * Three frames, because the design draws three.
 *
 * The **landing** header is 19px wordmark, a `$AMPS · Robinhood Chain` kicker, an anchor nav to the
 * page's own sections, the theme toggle and an `Enter app` fill button — and it is sticky. The
 * **app** header is a 15px wordmark, the surface nav underlined at the current page, and the chain
 * and wallet on the right. The **docs** header is the wordmark, a `Documentation` kicker, and the
 * toggle plus `Enter app` again.
 *
 * All three sit on a `1px solid var(--ink)` rule — not `--rule`. That single heavier line is what
 * separates the chrome from the page in a design with no other chrome.
 *
 * Width: the design's app and landing screens are `max-width:1200px; padding:0 28px`; the docs are
 * `1400px`. Those are not the same page and this does not average them.
 */
const APP_MAX = 'mx-auto w-full max-w-[1200px] px-5 sm:px-7'
const DOCS_MAX = 'mx-auto w-full max-w-[1400px] px-5 sm:px-7'

export function AppShell({children}: {children: React.ReactNode}) {
  const pathname = usePathname()
  if (pathname === '/') return <LandingFrame>{children}</LandingFrame>
  if (pathname === '/docs' || pathname.startsWith('/docs/')) return <DocsFrame>{children}</DocsFrame>
  return <AppFrame>{children}</AppFrame>
}

function SkipLink() {
  return (
    <a
      href="#main"
      className="ledger-nav sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:border focus:border-ink focus:bg-paper focus:px-3 focus:py-2 focus:text-ink"
    >
      Skip to content
    </a>
  )
}

function Wordmark({size = 'app'}: {size?: 'app' | 'landing'}) {
  return (
    <Link href="/" className={cn('ledger-wordmark shrink-0', size === 'landing' && 'text-[19px]')} data-testid="wordmark">
      Amplestocks
    </Link>
  )
}

/** The chain and the wallet, right-aligned. The design's `Robinhood Chain · 0x4a2f…9c31`. */
function ChainAndWallet() {
  const testnet = isTestnet()
  return (
    <div className="ml-auto flex shrink-0 items-center gap-3">
      <span
        className={cn(
          'hidden font-mono text-[10px] uppercase tracking-[0.12em] sm:inline',
          testnet && featureFlags.testnetBanner ? 'text-tone-warn' : 'text-dim',
        )}
        data-testid={testnet && featureFlags.testnetBanner ? 'testnet-badge' : 'chain-badge'}
      >
        {activeChain.name}
      </span>
      <span className="hidden md:inline">
        <ThemeToggle />
      </span>
      <WalletButton />
    </div>
  )
}

/**
 * The app frame. Below 768px the surface nav collapses behind a `Menu` disclosure and the four-tab
 * bar the design draws takes over the foot of the screen, so the page keeps a 44pt reach to
 * everything a phone actually needs.
 */
function AppFrame({children}: {children: React.ReactNode}) {
  const [menuOpen, setMenuOpen] = React.useState(false)
  const pathname = usePathname()

  React.useEffect(() => {
    setMenuOpen(false)
  }, [pathname])

  return (
    <div className="flex min-h-screen flex-col bg-paper pb-[52px] md:pb-0">
      <SkipLink />
      <header className="border-b border-ink bg-paper">
        <div className={cn(APP_MAX, 'flex flex-wrap items-center gap-x-[26px] gap-y-2.5 py-3')}>
          <Wordmark />
          <Nav className="hidden md:block" />
          <button
            type="button"
            className="ledger-nav text-dim hover:text-ink md:hidden"
            aria-expanded={menuOpen}
            aria-controls="mobile-menu"
            onClick={() => setMenuOpen((open) => !open)}
            data-testid="mobile-menu-button"
          >
            {menuOpen ? 'Close' : 'Menu'}
          </button>
          <ChainAndWallet />
        </div>
        {menuOpen ? (
          <div id="mobile-menu" className="border-t border-hair md:hidden" data-testid="mobile-menu">
            <div className={cn(APP_MAX, 'py-2')}>
              {SURFACES.map((surface) => (
                <Link
                  key={surface.href}
                  href={surface.href}
                  className="ledger-nav flex min-h-[44px] items-center border-b border-hair text-dim hover:text-ink"
                >
                  {surface.label}
                </Link>
              ))}
              <div className="flex min-h-[44px] items-center justify-between gap-4 py-2">
                <span className="ledger-micro">{activeChain.name}</span>
                <ThemeToggle />
              </div>
            </div>
          </div>
        ) : null}
      </header>

      <main id="main" className={cn(APP_MAX, 'flex-1 pb-[72px] pt-11')}>
        {children}
      </main>

      <AppFooter />
      <MobileTabBar />
    </div>
  )
}

/** The design's app footer: one sentence, and mono links right-aligned. */
function AppFooter() {
  return (
    <footer className="border-t border-ink">
      <div className={cn(APP_MAX, 'flex flex-wrap justify-between gap-x-9 gap-y-5 pb-10 pt-[30px]')}>
        <p className="max-w-[76ch] text-[13px] leading-[1.65] text-dim">
          Nothing here can move funds: this interface holds no keys and signs nothing on your behalf — it reads a set of
          public, immutable contracts and builds calldata you approve yourself. {LEGAL_FOOTER}
        </p>
        <div className="ledger-nav flex gap-[26px]">
          <Link href="/docs" className="text-dim hover:text-ink">
            Documentation
          </Link>
          <Link href="/risk" className="text-dim hover:text-ink">
            Risk
          </Link>
          <Link href="/governance" className="text-dim hover:text-ink">
            Parameters
          </Link>
        </div>
      </div>
    </footer>
  )
}

const LANDING_ANCHORS = [
  {href: '#holdings', label: 'Holdings'},
  {href: '#floor', label: 'The floor'},
  {href: '#growth', label: 'How NAV grows'},
  {href: '#numbers', label: 'Numbers'},
] as const

/**
 * The landing frame: a sticky header whose nav points at the page's own sections rather than at the
 * app, and an `Enter app` fill button that does what it says.
 */
function LandingFrame({children}: {children: React.ReactNode}) {
  return (
    <div className="flex min-h-screen flex-col bg-paper">
      <SkipLink />
      <header className="sticky top-0 z-20 border-b border-ink bg-paper">
        <div className={cn(APP_MAX, 'flex flex-wrap items-baseline gap-x-7 gap-y-3 py-3.5')}>
          <Wordmark size="landing" />
          <span className="hidden font-mono text-[10px] uppercase tracking-[0.16em] text-dim sm:inline">
            $AMPS · {activeChain.name}
          </span>
          <nav aria-label="On this page" className="ledger-scroll ml-auto hidden items-baseline gap-[22px] lg:flex">
            {LANDING_ANCHORS.map((anchor) => (
              <a key={anchor.href} href={anchor.href} className="ledger-nav whitespace-nowrap text-dim hover:text-ink">
                {anchor.label}
              </a>
            ))}
          </nav>
          <div className="ml-auto flex items-center gap-3.5 lg:ml-0">
            <ThemeToggle />
            <Link
              href="/buy"
              className="ledger-nav flex min-h-[40px] items-center border border-ink bg-fill px-4 text-onfill transition-opacity hover:opacity-[0.82]"
              data-testid="enter-app"
            >
              Enter app
            </Link>
          </div>
        </div>
      </header>

      <main id="main" className="flex-1">
        {children}
      </main>

      <footer className="border-t border-ink">
        <div className={cn(APP_MAX, 'grid items-start gap-x-12 gap-y-6 pb-11 pt-[34px] lg:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)]')}>
          <p className="max-w-[78ch] text-[13px] leading-[1.65] text-dim">
            Thirty Uniswap v4 positions, thirty-two protocol-owned pools, and a redemption path with no oracle and no
            pause. Every contract is public and verifiable on the explorer. {LEGAL_FOOTER}
          </p>
          <div className="ledger-nav flex gap-[26px] lg:justify-end">
            <Link href="/docs" className="underline decoration-rule underline-offset-[3px] hover:decoration-ink">
              Documentation
            </Link>
            <Link href="/docs/addresses" className="text-dim hover:text-ink">
              Contracts
            </Link>
            <Link href="/risk" className="text-dim hover:text-ink">
              Risk
            </Link>
          </div>
        </div>
      </footer>
    </div>
  )
}

/**
 * The docs frame: 1400px, the wordmark and a `Documentation` kicker, the toggle and `Enter app`.
 * The three-column grid itself belongs to the page, because the sidebar has to know which page is
 * current and the rail has to know its headings.
 */
function DocsFrame({children}: {children: React.ReactNode}) {
  return (
    <div className="flex min-h-screen flex-col bg-paper">
      <SkipLink />
      <header className="sticky top-0 z-20 border-b border-ink bg-paper">
        <div className={cn(DOCS_MAX, 'flex flex-wrap items-center gap-x-[26px] gap-y-2.5 py-3')}>
          <Wordmark />
          <span className="font-mono text-[10px] uppercase tracking-[0.16em] text-dim">Documentation</span>
          <div className="ml-auto flex items-center gap-3.5">
            <ThemeToggle />
            <Link
              href="/buy"
              className="ledger-nav border border-ink bg-fill px-4 py-2 text-onfill transition-opacity hover:opacity-[0.82]"
              data-testid="enter-app"
            >
              Enter app
            </Link>
          </div>
        </div>
      </header>

      <main id="main" className="flex-1">
        {children}
      </main>

      <footer className="border-t border-ink">
        <div className={cn(DOCS_MAX, 'flex flex-wrap justify-between gap-x-10 gap-y-5 pb-10 pt-[30px]')}>
          <p className="max-w-[76ch] text-[13px] leading-[1.65] text-dim">
            Every contract referenced in these pages is public, immutable and verifiable on the explorer. This interface
            reads them and builds calldata you approve yourself. {LEGAL_FOOTER}
          </p>
          <div className="ledger-nav flex gap-[26px]">
            <Link href="/docs/addresses" className="text-dim hover:text-ink">
              Contracts
            </Link>
            <Link href="/risk" className="text-dim hover:text-ink">
              Risk
            </Link>
          </div>
        </div>
      </footer>
    </div>
  )
}
