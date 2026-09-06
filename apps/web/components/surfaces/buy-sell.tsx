// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useSimulateContract} from 'wagmi'
import type {Address, Hex} from 'viem'

import {PolDepthNote, RotationCreditNote, SwapQuoteView} from './swap-panels'
import {TxButton, TxError, TxSuccess} from '@/components/common/tx'
import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Button} from '@/components/ui/button'
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'
import {Input} from '@/components/ui/input'
import {Label} from '@/components/ui/label'
import {Tabs, TabsContent, TabsList, TabsTrigger} from '@/components/ui/tabs'
import {useTx} from '@/hooks/use-tx'
import {usePoolDirectory} from '@/hooks/use-pools'
import {usePoolKeys} from '@/hooks/use-pool-keys'
import {activeChainId} from '@/lib/chains'
import {explorerTxUrl, referenceBook} from '@/lib/deployment'
import {addressOf} from '@/lib/contracts'
import {featureFlags} from '@/lib/flags'
import {parseAmount} from '@/lib/format'
import {isTradeable} from '@/lib/quoter'
import {deadlineFromNow, encodeSingleHop, minOutFromSlippage, routeToRequest, universalRouterExecuteAbi} from '@/lib/route'

type Side = 'buy' | 'sell'

const DEFAULT_SLIPPAGE_BPS = 50

/**
 * Buy / Sell.
 *
 * `AMPS/WETH` is the default route — it is the pool next to the chain's deepest ETH liquidity, and
 * the router wraps native ETH into it because native ETH would be `address(0)` = `currency0` and
 * would break the AMPS-is-currency0 invariant every pool is built on. `AMPS/USDG` is the
 * settlement leg.
 *
 * The sell fee and the rotation-credit rule are stated on the surface, not hidden in a tooltip:
 * they are the two things a user is most likely to be surprised by.
 */
export function BuySellSurface() {
  const {address, isConnected} = useAccount()
  const {entryPools, enabled: directoryEnabled, isLoading} = usePoolDirectory()
  const [side, setSide] = React.useState<Side>('buy')
  const [poolId, setPoolId] = React.useState<Hex | undefined>(undefined)
  const [amountText, setAmountText] = React.useState('')
  const [useNativeEth, setUseNativeEth] = React.useState(true)

  const book = referenceBook(activeChainId)
  const amps = addressOf('amps')

  const selected = React.useMemo(
    () => entryPools.find((p) => p.poolId === poolId) ?? entryPools[0],
    [entryPools, poolId],
  )
  const entryPoolIds = React.useMemo(() => entryPools.map((p) => p.poolId), [entryPools])
  const {keys} = usePoolKeys(entryPoolIds)
  const poolKey = selected ? keys.get(selected.poolId) : undefined
  const isWethPool = selected?.symbol === 'WETH'
  const counterDecimals = selected?.symbol === 'USDG' ? 6 : 18
  const inputDecimals = side === 'buy' ? counterDecimals : 18
  const amount = parseAmount(amountText, inputDecimals)

  const route = React.useMemo(() => {
    if (!selected || !amps || !poolKey || !book || amount === null || amount <= 0n) return null
    const minOut = minOutFromSlippage(0n, DEFAULT_SLIPPAGE_BPS)
    return encodeSingleHop({
      currencyIn: side === 'buy' ? selected.counter : amps,
      currencyOut: side === 'buy' ? amps : selected.counter,
      pool: poolKey,
      amountIn: amount,
      amountOutMinimum: minOut,
      recipient: (address ?? amps) as Address,
      wrapEthIn: side === 'buy' && isWethPool && useNativeEth,
      unwrapWethOut: side === 'sell' && isWethPool && useNativeEth,
    })
  }, [selected, amps, poolKey, book, amount, side, address, isWethPool, useNativeEth])

  const request = React.useMemo(() => {
    if (!route || !book) return null
    return routeToRequest({
      router: book.universalRouter,
      route,
      deadline: deadlineFromNow(),
      value: side === 'buy' && isWethPool && useNativeEth ? (amount ?? 0n) : 0n,
    })
  }, [route, book, side, isWethPool, useNativeEth, amount])

  const simulation = useSimulateContract({
    address: request?.address,
    abi: universalRouterExecuteAbi,
    functionName: 'execute',
    args: request?.args,
    value: request?.value,
    query: {enabled: request !== null && isConnected},
  })

  const quote = selected?.quote
  const tradeable = quote ? isTradeable(quote, side) : false
  const blockedReason = !isConnected
    ? 'Connect a wallet to simulate this swap.'
    : !book
      ? 'No verified reference addresses for this chain, so no router to call.'
      : amount === null || amount <= 0n
        ? 'Enter an amount.'
        : !poolKey
          ? 'Waiting for the pool key from the registry.'
          : quote && quote.degraded !== 0
            ? 'The quote is degraded. A quote with any flag raised is not permission to trade.'
            : !tradeable
              ? 'The hook would refuse this swap at the current tick.'
              : undefined

  const tx = useTx({
    simulation: simulation.data,
    simulationError: simulation.error,
    isSimulating: simulation.isLoading,
    ...(blockedReason ? {blockedReason} : {}),
  })

  if (!directoryEnabled) {
    return (
      <div className="space-y-6">
        <SurfaceHeading
          title="Buy / Sell"
          lede="AMPS against WETH or USDG. The sell fee and the rotation-credit rule are stated here rather than discovered later."
        />
        <NotDeployed what="Buy / Sell" />
      </div>
    )
  }

  return (
    <div className="space-y-6" data-testid="buy-sell-surface">
      <SurfaceHeading
        title="Buy / Sell"
        lede="AMPS against WETH or USDG. Fees come from AmpsQuoter and are exact; the output comes from V4Quoter and is a curve simulation."
      />
      <RotationCreditNote />
      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Swap</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <Tabs value={side} onValueChange={(v) => setSide(v as Side)}>
              <TabsList>
                <TabsTrigger value="buy" data-testid="tab-buy">
                  Buy AMPS
                </TabsTrigger>
                <TabsTrigger value="sell" data-testid="tab-sell">
                  Sell AMPS
                </TabsTrigger>
              </TabsList>
              <TabsContent value={side} />
            </Tabs>

            <div className="space-y-2">
              <Label htmlFor="pool">Pool</Label>
              <select
                id="pool"
                data-testid="pool-select"
                className="h-10 w-full rounded-md border border-border bg-background px-3 text-sm"
                value={selected?.poolId ?? ''}
                onChange={(e) => setPoolId(e.target.value as Hex)}
              >
                {isLoading ? <option>Loading…</option> : null}
                {entryPools.map((pool) => (
                  <option key={pool.poolId} value={pool.poolId}>
                    AMPS / {pool.symbol}
                  </option>
                ))}
              </select>
            </div>

            {isWethPool ? (
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={useNativeEth}
                  onChange={(e) => setUseNativeEth(e.target.checked)}
                  data-testid="native-eth-toggle"
                />
                <span>
                  Use native ETH (the router wraps and unwraps around the WETH leg — the pool itself is AMPS/WETH)
                </span>
              </label>
            ) : null}

            <div className="space-y-2">
              <Label htmlFor="amount">{side === 'buy' ? `Pay (${selected?.symbol ?? '—'})` : 'Sell (AMPS)'}</Label>
              <Input
                id="amount"
                data-testid="amount-input"
                inputMode="decimal"
                placeholder="0.0"
                value={amountText}
                onChange={(e) => setAmountText(e.target.value)}
              />
            </div>

            <TxButton
              phase={tx.phase}
              label={side === 'buy' ? 'Buy AMPS' : 'Sell AMPS'}
              {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
              onClick={() => void tx.send()}
              data-testid="swap-submit"
            />
            <TxError error={tx.error} />
            {tx.hash ? <TxSuccess hash={tx.hash} explorerUrl={explorerTxUrl(activeChainId, tx.hash)} /> : null}
          </CardContent>
        </Card>

        <div className="space-y-4">
          <SwapQuoteView
            side={side}
            quote={quote}
            amountOutDecimals={side === 'buy' ? 18 : counterDecimals}
            amountOutSymbol={side === 'buy' ? 'AMPS' : (selected?.symbol ?? '')}
          />
          <PolDepthNote symbol={selected?.symbol ?? ''} />
          <AcrossZapEntry />
        </div>
      </div>
    </div>
  )
}

/**
 * The Across USDC -> USDG zap, behind a feature flag and deliberately inert.
 *
 * The entry point and the disclosure exist; the bridge call does not. A disabled control that says
 * why is honest. A control that looks live and does nothing is not.
 */
export function AcrossZapEntry({enabled = featureFlags.acrossZap}: {enabled?: boolean}) {
  const book = referenceBook(activeChainId)
  if (!enabled) return null
  return (
    <Alert variant="info" data-testid="across-zap">
      <AlertTitle>Bridge USDC into USDG</AlertTitle>
      <AlertDescription>
        <p>
          The USD leg of this app settles in USDG. Bridged USDC can be swapped into USDG through Across before buying.
        </p>
        <p className="mt-2 text-xs text-muted-foreground">
          Not implemented yet. The SpokePool this would call is{' '}
          <code className="font-mono">{book?.acrossSpokePool ?? 'not configured for this chain'}</code>.
        </p>
        <Button className="mt-3" variant="outline" size="sm" disabled data-testid="across-zap-button">
          Zap USDC → USDG (not enabled)
        </Button>
      </AlertDescription>
    </Alert>
  )
}
