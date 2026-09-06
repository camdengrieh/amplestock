// SPDX-License-Identifier: MIT
import Link from 'next/link'
import * as React from 'react'

import {Nav} from './nav'
import {WalletButton} from './wallet-button'
import {Badge} from '@/components/ui/badge'
import {activeChain, isTestnet} from '@/lib/chains'
import {LEGAL_FOOTER} from '@/lib/copy'
import {featureFlags} from '@/lib/flags'

export function AppShell({children}: {children: React.ReactNode}) {
  return (
    <div className="flex min-h-screen flex-col">
      <header className="border-b border-border">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-4 px-4 py-3">
          <Link href="/" className="text-sm font-semibold tracking-tight">
            Amplestocks <span className="text-muted-foreground">$AMPS</span>
          </Link>
          <Nav />
          <div className="ml-auto flex items-center gap-2">
            {isTestnet() && featureFlags.testnetBanner ? (
              <Badge variant="warning" data-testid="testnet-badge">
                {activeChain.name}
              </Badge>
            ) : (
              <Badge variant="muted">{activeChain.name}</Badge>
            )}
            <WalletButton />
          </div>
        </div>
      </header>
      <main className="mx-auto w-full max-w-7xl flex-1 px-4 py-8">{children}</main>
      <footer className="border-t border-border">
        <div className="mx-auto max-w-7xl px-4 py-6 text-xs leading-relaxed text-muted-foreground">
          <p className="max-w-4xl">{LEGAL_FOOTER}</p>
          <p className="mt-2">
            <Link href="/risk" className="underline">
              Risk disclosures
            </Link>
          </p>
        </div>
      </footer>
    </div>
  )
}
