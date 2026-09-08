// SPDX-License-Identifier: MIT
import type {Metadata, Viewport} from 'next'
import * as React from 'react'

import './globals.css'
import {AppShell} from '@/components/layout/shell'
import {AppProviders} from '@/components/providers/app-providers'
import {DEFAULT_THEME, THEME_ATTRIBUTE, THEME_BOOT_SCRIPT} from '@/lib/theme'

export const metadata: Metadata = {
  title: 'Amplestocks — $AMPS',
  description:
    'A NAV-floored index share on Robinhood Chain. Buy, sell, rotate, bond and redeem against a set of public, immutable contracts.',
  robots: {index: false, follow: false},
}

export const viewport: Viewport = {
  themeColor: [
    {media: '(prefers-color-scheme: light)', color: '#fdfdfb'},
    {media: '(prefers-color-scheme: dark)', color: '#0d0d0c'},
  ],
  width: 'device-width',
  initialScale: 1,
}

/**
 * The document.
 *
 * Two things happen in the head and nowhere else. The theme is stamped onto `<html>` by a blocking
 * script before first paint, so nobody sees a flash of the wrong ground; and the two Ledger faces
 * are linked from Google Fonts at *runtime* rather than pulled in by `next/font/google`, which
 * fetches during the build and the build has to succeed with no network. Both faces have a real
 * fallback stack in `globals.css`, so a blocked or slow font costs the page nothing but its voice.
 */
export default function RootLayout({children}: {children: React.ReactNode}) {
  return (
    <html lang="en" {...{[THEME_ATTRIBUTE]: DEFAULT_THEME}} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{__html: THEME_BOOT_SCRIPT}} />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=Newsreader:opsz,wght@6..72,200;6..72,300;6..72,400;6..72,500&display=swap"
        />
      </head>
      <body>
        <AppProviders>
          <AppShell>{children}</AppShell>
        </AppProviders>
      </body>
    </html>
  )
}
