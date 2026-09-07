// SPDX-License-Identifier: MIT
'use client'

import {QueryClient, QueryClientProvider} from '@tanstack/react-query'
import * as React from 'react'
import {WagmiProvider} from 'wagmi'

import {bootAppKit} from '@/lib/appkit'
import {wagmiSetup} from '@/lib/wagmi'

/**
 * One `QueryClient` per browser session, created lazily so the server render and the client render
 * do not share a cache. Chain reads are cheap and change every block; the defaults reflect that
 * rather than the usual "cache for five minutes" web defaults.
 */
function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 10_000,
        gcTime: 5 * 60_000,
        retry: 1,
        refetchOnWindowFocus: false,
      },
    },
  })
}

export function AppProviders({children}: {children: React.ReactNode}) {
  const [queryClient] = React.useState(makeQueryClient)
  const [setup] = React.useState(wagmiSetup)

  React.useEffect(() => {
    // AppKit registers custom elements and reads `window`; it can only run here.
    void bootAppKit(setup)
  }, [setup])

  return (
    <WagmiProvider config={setup.config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  )
}
