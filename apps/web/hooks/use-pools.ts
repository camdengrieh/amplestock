// SPDX-License-Identifier: MIT
'use client'

import {addresses, AMPS_MAINNET_CHAIN_ID, launchConstituents} from '@amplestocks/config'
import * as React from 'react'
import type {Address, Hex} from 'viem'
import {getAddress} from 'viem'

import {PoolClass} from '@/lib/protocol'
import type {PoolQuote} from '@/lib/quoter'
import {useAllPoolQuotes} from './use-quotes'

export interface PoolEntry {
  poolId: Hex
  counter: Address
  symbol: string
  poolClass: number
  quote: PoolQuote
}

/**
 * `symbol` for a counter asset, from `@amplestocks/config` — never hardcoded here.
 *
 * The launch constituent list carries the 30 stock tokens; the address book carries WETH9, USDG
 * and bridged USDC. An address in neither renders as its own short form rather than a made-up
 * ticker.
 */
export function symbolForCounter(counter: Address): string {
  const book = addresses[AMPS_MAINNET_CHAIN_ID]
  const normalised = safeChecksum(counter)
  if (normalised === safeChecksum(book.weth9)) return 'WETH'
  if (normalised === safeChecksum(book.usdg)) return 'USDG'
  if (normalised === safeChecksum(book.usdc)) return 'USDC'
  for (const constituent of launchConstituents) {
    if (constituent.token && safeChecksum(constituent.token) === normalised) return constituent.symbol
  }
  return `${counter.slice(0, 6)}…${counter.slice(-4)}`
}

function safeChecksum(value: string): string {
  try {
    return getAddress(value)
  } catch {
    return value.toLowerCase()
  }
}

/** Every registered pool, from one `quoteAll()`. */
export function usePoolDirectory() {
  const {quotes, isLoading, isError, enabled, refetch} = useAllPoolQuotes()

  const pools = React.useMemo<PoolEntry[]>(() => {
    if (!quotes) return []
    return quotes
      .filter((quote) => quote.poolClass !== PoolClass.NONE)
      .map((quote) => ({
        poolId: quote.poolId,
        counter: quote.counter,
        symbol: symbolForCounter(quote.counter),
        poolClass: quote.poolClass,
        quote,
      }))
  }, [quotes])

  const entryPools = React.useMemo(() => pools.filter((p) => p.poolClass === PoolClass.ENTRY), [pools])
  const spokes = React.useMemo(
    () => pools.filter((p) => p.poolClass === PoolClass.SPOKE || p.poolClass === PoolClass.SPOKE_HIGH_VOL),
    [pools],
  )

  return {pools, entryPools, spokes, isLoading, isError, enabled, refetch}
}
