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
 * Reown AppKit owns the picker when a project id is configured. With none — CI, tests, a local
 * checkout — `openWallet` reports `false` and this falls back to the first available connector,
 * which in a browser with a wallet extension is the injected one. The button never becomes a dead
 * control just because no Reown account exists.
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
      <Button variant="outline" size="sm" onClick={() => disconnect()} data-testid="wallet-disconnect">
        {shortAddress(address)}
      </Button>
    )
  }

  return (
    <Button size="sm" onClick={() => void onConnect()} disabled={isPending} data-testid="wallet-connect">
      {isPending ? 'Connecting…' : 'Connect wallet'}
    </Button>
  )
}
