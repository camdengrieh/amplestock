// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useSimulateContract} from 'wagmi'
import type {Address, Hex} from 'viem'

import {PolDepthNote, RotationCreditNote, SwapQuoteView} from './swap-panels'
import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {TxButton, TxError, TxSuccess} from '@/components/common/tx'
import {AmountField} from '@/components/ledger/amount-field'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Button} from '@/components/ui/button'
import {Label} from '@/components/ui/label'
import {Select} from '@/components/ui/select'
import {Tabs, TabsList, TabsTrigger} from '@/components/ui/tabs'
import {useAmpsFee} from '@/hooks/use-hook-params'
import {usePoolDirectory} from '@/hooks/use-pools'
import {useExactInQuote, useWouldRevert} from '@/hooks/use-quotes'
import {useTx} from '@/hooks/use-tx'
import {activeChainId} from '@/lib/chains'
import {addressOf} from '@/lib/contracts'
import {explorerTxUrl, referenceBook} from '@/lib/deployment'
import {featureFlags} from '@/lib/flags'
import {parseAmount} from '@/lib/format'
import {isTradeable} from '@/lib/quoter'
import {
  deadlineFromNow,
  encodeSingleHop,
  minOutFromSlippage,
  poolKeyFromQuote,
  routeToRequest,
  universalRouterExecuteAbi,
} from '@/lib/route'

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
 * Revision 6 changed the fee and this surface says so on its face: the AMPS fee is charged in both
 * directions, and the pool's base fee is charged on top only for a pass-through. A single hop pays
 * the AMPS fee and nothing else, whichever way it is going.
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
  const fee = useAmpsFee()

  const selected = React.useMemo(
    () => entryPools.find((p) => p.poolId === poolId) ?? entryPools[0],
    [entryPools, poolId],
  )
  const hook = addressOf('hook')
  // One `quoteAll()` is enough to route: `PoolQuote` carries the pool's own `tickSpacing`, and the
  // other two `PathKey` fields are invariant across all 32 pools.
  const poolKey = selected && amps && hook ? poolKeyFromQuote(selected.quote, {amps, hooks: hook}) : null
  const isWethPool = selected?.symbol === 'WETH'
  const counterDecimals = selected?.symbol === 'USDG' ? 6 : 18
  const inputDecimals = side === 'buy' ? counterDecimals : 18
  const amount = parseAmount(amountText, inputDecimals)

  // AMPS is `currency0` in all 32 pools, so a sell is unconditionally `zeroForOne`.
  const zeroForOne = side === 'sell'
  const exactIn = useExactInQuote({
    ...(selected ? {poolId: selected.poolId} : {}),
    zeroForOne,
    ...(amount !== null && amount > 0n ? {amountIn: amount} : {}),
  })
  const rail = useWouldRevert({
    ...(selected ? {poolId: selected.poolId} : {}),
    zeroForOne,
    ...(amount !== null && amount > 0n ? {amountIn: amount} : {}),
  })
  const quotedOut = exactIn.exactIn?.amountOut
  const amountOutMinimum = quotedOut !== undefined ? minOutFromSlippage(quotedOut, DEFAULT_SLIPPAGE_BPS) : 0n

  const route = React.useMemo(() => {
    if (!selected || !amps || !poolKey || !book || amount === null || amount <= 0n) return null
    return encodeSingleHop({
      currencyIn: side === 'buy' ? selected.counter : amps,
      currencyOut: side === 'buy' ? amps : selected.counter,
      pool: poolKey,
      amountIn: amount,
      amountOutMinimum,
      recipient: (address ?? amps) as Address,
      wrapEthIn: side === 'buy' && isWethPool && useNativeEth,
      unwrapWethOut: side === 'sell' && isWethPool && useNativeEth,
    })
  }, [selected, amps, poolKey, book, amount, amountOutMinimum, side, address, isWethPool, useNativeEth])

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
          ? 'The quoter could not read this pool’s registry entry, so there is no route to build.'
          : quote && quote.degraded !== 0
            ? 'The quote is degraded. A quote with any flag raised is not permission to trade.'
            : !tradeable || rail.verdict?.refuse === true
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
      <div className="space-y-10">
        <SurfaceHeading
          kicker="Entry pools"
          title="Buy / Sell"
          lede="AMPS against WETH or USDG. Fees are exact and read from the hook; the output is a curve simulation at this instant."
        />
        <NotDeployed what="Buy / Sell" />
      </div>
    )
  }

  return (
    <div className="space-y-11" data-testid="buy-sell-surface">
      <SurfaceHeading
        kicker="Entry pools"
        title="Buy / Sell"
        lede="AMPS against WETH or USDG. Fees are exact and read from the hook; the output is a curve simulation at this instant."
      />

      <div className="grid gap-x-14 gap-y-12 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
        <div>
          <Tabs value={side} onValueChange={(v) => setSide(v as Side)}>
            <TabsList>
              <TabsTrigger value="buy" data-testid="tab-buy">
                Buy AMPS
              </TabsTrigger>
              <TabsTrigger value="sell" data-testid="tab-sell">
                Sell AMPS
              </TabsTrigger>
            </TabsList>
          </Tabs>

          <Label htmlFor="pool" className="mb-2 mt-[26px]">
            Pool
          </Label>
          <Select
            id="pool"
            data-testid="pool-select"
            value={selected?.poolId ?? ''}
            onChange={(e) => setPoolId(e.target.value as Hex)}
          >
            {isLoading ? <option>Loading…</option> : null}
            {entryPools.map((pool) => (
              <option key={pool.poolId} value={pool.poolId}>
                AMPS / {pool.symbol}
              </option>
            ))}
          </Select>

          <Label htmlFor="amount" className="mb-2 mt-[22px]">
            {side === 'buy' ? `Pay (${selected?.symbol ?? '—'})` : 'Sell (AMPS)'}
          </Label>
          <AmountField
            id="amount"
            data-testid="amount-input"
            value={amountText}
            onChange={setAmountText}
            unit={side === 'buy' ? (selected?.symbol ?? '') : 'AMPS'}
          />

          {isWethPool ? (
            <label className="mt-4 flex items-start gap-2.5 text-[14px] leading-[1.5] text-dim">
              <input
                type="checkbox"
                className="mt-[3px] h-4 w-4 shrink-0 accent-[var(--ink)]"
                checked={useNativeEth}
                onChange={(e) => setUseNativeEth(e.target.checked)}
                data-testid="native-eth-toggle"
              />
              <span>
                Use native ETH — the router wraps and unwraps around the WETH leg. The pool itself is AMPS/WETH.
              </span>
            </label>
          ) : null}

          <div className="mt-[26px]">
            <TxButton
              phase={tx.phase}
              label={side === 'buy' ? 'Buy AMPS' : 'Sell AMPS'}
              {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
              onClick={() => void tx.send()}
              data-testid="swap-submit"
            />
          </div>
          <div className="mt-5 space-y-6">
            <TxError error={tx.error} />
            {tx.hash ? <TxSuccess hash={tx.hash} explorerUrl={explorerTxUrl(activeChainId, tx.hash)} /> : null}
            <PolDepthNote symbol={selected?.symbol ?? ''} />
            <AcrossZapEntry />
          </div>
        </div>

        <div className="space-y-[26px]">
          <SwapQuoteView
            side={side}
            quote={quote}
            {...(quotedOut !== undefined ? {amountOut: quotedOut} : {})}
            {...(amountOutMinimum > 0n ? {amountOutMinimum} : {})}
            {...(rail.verdict ? {railVerdict: rail.verdict} : {})}
            amountOutDecimals={side === 'buy' ? 18 : counterDecimals}
            amountOutSymbol={side === 'buy' ? 'AMPS' : (selected?.symbol ?? '')}
            {...(fee.ampsFeeBps !== undefined ? {liveAmpsFeeBps: fee.ampsFeeBps} : {})}
            ampsFeeBand={fee.band}
          />
          <RotationCreditNote />
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
    <Alert data-testid="across-zap">
      <AlertTitle>Bridge USDC into USDG</AlertTitle>
      <AlertDescription>
        <p>
          The USD leg of this app settles in USDG. Bridged USDC can be swapped into USDG through Across before buying.
        </p>
        <p className="font-mono text-[13px]">
          Not implemented yet. The SpokePool this would call is{' '}
          {book?.acrossSpokePool ?? 'not configured for this chain'}.
        </p>
        <Button variant="outline" size="sm" disabled data-testid="across-zap-button">
          Zap USDC → USDG (not enabled)
        </Button>
      </AlertDescription>
    </Alert>
  )
}
