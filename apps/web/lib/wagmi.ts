// SPDX-License-Identifier: MIT

/**
 * The wagmi config, and the one decision that shapes it.
 *
 * Reown AppKit owns the wallet list when a project id is configured: `WagmiAdapter` *builds* the
 * wagmi config, and `createAppKit` is what makes the modal exist. Without a project id — CI, the
 * test run, a local checkout with no `.env` — there is no AppKit and no WalletConnect relay to
 * dial, and the app falls back to the injected connector. Both branches produce an ordinary
 * `Config`, so nothing downstream knows or cares which one it got.
 *
 * `createAppKit` itself is *not* called here. It registers custom elements and touches browser
 * globals, so it belongs in an effect on the client (`components/providers/AppKitBoot.tsx`); this
 * module stays safe to import during prerender.
 */

import {WagmiAdapter} from '@reown/appkit-adapter-wagmi'
import {cookieStorage, createConfig, createStorage, http, type Config} from 'wagmi'
import {injected} from 'wagmi/connectors'

import {activeChain, activeChainId, rpcUrlFor} from './chains'
import {publicEnv} from './env'

export interface WagmiSetup {
  config: Config
  /** The AppKit adapter, when one was built. `null` means injected-only. */
  adapter: WagmiAdapter | null
  projectId: string
}

let cached: WagmiSetup | null = null

export function createWagmiSetup(projectId = publicEnv.reownProjectId): WagmiSetup {
  const transports = {[activeChainId]: http(rpcUrlFor(activeChainId))}

  if (projectId === '') {
    return {
      config: createConfig({
        chains: [activeChain],
        transports,
        connectors: [injected({shimDisconnect: true})],
        ssr: true,
        storage: createStorage({storage: cookieStorage}),
      }),
      adapter: null,
      projectId,
    }
  }

  const adapter = new WagmiAdapter({
    networks: [toCaipNetwork(activeChainId)],
    projectId,
    ssr: true,
    storage: createStorage({storage: cookieStorage}),
    transports,
  })
  return {config: adapter.wagmiConfig, adapter, projectId}
}

/** One config per browser session. Recreating it drops every connection. */
export function wagmiSetup(): WagmiSetup {
  cached ??= createWagmiSetup()
  return cached
}

/** Test seam: drop the memoised config so a test can build a fresh one. */
export function resetWagmiSetup(): void {
  cached = null
}

/**
 * AppKit wants a CAIP network, viem wants a `Chain`. They carry the same data; this adds the two
 * CAIP fields rather than restating the chain.
 */
function toCaipNetwork(chainId: number) {
  return {
    ...activeChain,
    id: chainId,
    chainNamespace: 'eip155' as const,
    caipNetworkId: `eip155:${chainId}` as const,
  }
}
