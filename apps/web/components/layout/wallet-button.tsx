// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useConnect, useDisconnect} from 'wagmi'

import {Button} from '@/components/ui/button'
import {openWallet} from '@/lib/appkit'
import {shortAddress} from '@/lib/format'

/**
 * Connect / disconnect.
 *
 * The design's app header shows a connected wallet as a bare address in a `1px solid --rule` box —
 * mono `10px / 0.12em`, `padding:6px 12px` — and its landing and docs headers show the fill
 * `Enter app` button. This is both: the box when there is an address, the fill button when there is
 * not.
 *
 * Reown AppKit owns the picker when a project id is configured. With none — CI, tests, a local
 * checkout — `openWallet` reports `false` and this falls back to the first available connector,
 * which in a browser with a wallet extension is the injected one.
 */
export function WalletButton() {
  const {address, isConnected} = useAccount()
  const {connect, connectors, isPending} = useConnect()
  const {disconnect} = useDisconnect()

  const onConnect = React.useCallback(async () => {
    const opened = await openWallet()
    if (opened) return
    const connector = connectors[0]
    if (connector) connect({connector})
  }, [connect, connectors])

  if (isConnected && address) {
    return (
      <button
        type="button"
        onClick={() => disconnect()}
        title="Disconnect"
        data-testid="wallet-disconnect"
        className="border border-rule px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.12em] text-ink transition-colors hover:border-ink"
      >
        {shortAddress(address)}
      </button>
    )
  }

  return (
    <Button size="sm" onClick={() => void onConnect()} disabled={isPending} data-testid="wallet-connect">
      {isPending ? 'Connecting…' : 'Connect'}
    </Button>
  )
}
