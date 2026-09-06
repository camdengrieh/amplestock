// SPDX-License-Identifier: MIT

/**
 * Reown AppKit, mounted lazily and only in a browser.
 *
 * `createAppKit` registers custom elements and reads `window`, so calling it at module scope would
 * run it during prerender. It is called once, from an effect, and the returned modal is memoised.
 * Everything the UI needs about the *connection* comes from wagmi's own hooks; AppKit is only the
 * wallet picker.
 *
 * With no project id there is no modal. `openWallet` then reports `false` and the caller falls
 * back to the injected connector — a browser with a wallet extension still works with no Reown
 * account at all.
 */

import type {WagmiSetup} from './wagmi'

type AppKitModal = {open: (options?: {view?: string}) => Promise<void> | void; close: () => void}

let modal: AppKitModal | null = null
let booting: Promise<AppKitModal | null> | null = null

export const APPKIT_METADATA = {
  name: 'Amplestocks',
  description: 'NAV-floored index share on Robinhood Chain',
  url: 'https://amplestocks.invalid',
  icons: [] as string[],
}

export async function bootAppKit(setup: WagmiSetup): Promise<AppKitModal | null> {
  if (typeof window === 'undefined') return null
  if (modal) return modal
  if (setup.adapter === null || setup.projectId === '') return null
  booting ??= (async () => {
    const {createAppKit} = await import('@reown/appkit/react')
    const {activeChain} = await import('./chains')
    const created = createAppKit({
      adapters: [setup.adapter as never],
      networks: [
        {
          ...activeChain,
          chainNamespace: 'eip155',
          caipNetworkId: `eip155:${activeChain.id}`,
        } as never,
      ],
      projectId: setup.projectId,
      metadata: APPKIT_METADATA,
      features: {analytics: false, email: false, socials: false},
    }) as unknown as AppKitModal
    modal = created
    return created
  })()
  return booting
}

export function appKitModal(): AppKitModal | null {
  return modal
}

/** Opens the wallet picker. `false` means there is none and the caller should use the fallback. */
export async function openWallet(): Promise<boolean> {
  if (!modal) return false
  await modal.open()
  return true
}

/** Test seam. */
export function resetAppKit(): void {
  modal = null
  booting = null
}
