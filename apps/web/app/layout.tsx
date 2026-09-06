// SPDX-License-Identifier: MIT
import type {Metadata, Viewport} from 'next'
import * as React from 'react'

import './globals.css'
import {AppShell} from '@/components/layout/shell'
import {AppProviders} from '@/components/providers/app-providers'

export const metadata: Metadata = {
  title: 'Amplestocks — $AMPS',
  description:
    'A NAV-floored index share on Robinhood Chain. Buy, sell, rotate, bond, redeem and stake against a set of public, immutable contracts.',
  robots: {index: false, follow: false},
}

export const viewport: Viewport = {
  themeColor: '#111318',
  width: 'device-width',
  initialScale: 1,
}

export default function RootLayout({children}: {children: React.ReactNode}) {
  return (
    <html lang="en">
      <body>
        <AppProviders>
          <AppShell>{children}</AppShell>
        </AppProviders>
      </body>
    </html>
  )
}
