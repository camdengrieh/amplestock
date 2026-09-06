// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useSimulateContract} from 'wagmi'
import type {Address, Hex} from 'viem'

import {DegradedNotice} from '@/components/common/degraded'
import {FieldRow} from '@/components/common/stat'
import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {TxButton, TxError, TxSuccess} from '@/components/common/tx'
import {Value} from '@/components/common/value'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'
import {Input} from '@/components/ui/input'
import {Label} from '@/components/ui/label'
import {usePoolDirectory} from '@/hooks/use-pools'
import {usePoolKeys} from '@/hooks/use-pool-keys'
import {useRotationQuote} from '@/hooks/use-quotes'
import {useTx} from '@/hooks/use-tx'
import {activeChainId} from '@/lib/chains'
import {addressOf} from '@/lib/contracts'
import {NOTES} from '@/lib/copy'
import {explorerTxUrl, referenceBook} from '@/lib/deployment'
import {blendedSellFeeBps, bpsToPips, pipsToPercent} from '@/lib/fees'
import {formatAmount, parseAmount} from '@/lib/format'
import {deadlineFromNow, encodeRotation, minOutFromSlippage, routeToRequest, universalRouterExecuteAbi} from '@/lib/route'

const DEFAULT_SLIPPAGE_BPS = 50

/**
 * The comparison the Rotate surface exists to show.
 *
 * A rotation is one `SWAP_EXACT_IN` with two `PathKey`s inside one `V4_SWAP`. The AMPS that hop 1
 * buys is the credit hop 2 consumes, so hop 2's base fee blends from the sell fee down toward the
 * pool's buy fee. Doing the same two swaps as two transactions throws that away entirely: the
 * credit lives in transient storage and cannot cross a transaction boundary.
 *
 * Both columns are computed from the same fee law, so the difference is the credit and nothing else.
 */
export interface RotationComparison {
  hop1FeePips: number
  rotatedHop2FeePips: number
  separateHop2FeePips: number
  hop2BaseBpsRotated: number
  hop2BaseBpsSeparate: number
  creditUsed: bigint
  savedPips: number
}

export function compareRotation(params: {
  hop1BuyFeeBps: number
  hop2BuyFeeBps: number
  sellFeeBps: number
  ampsFromHop1: bigint
}): RotationComparison {
  const rotatedBase = blendedSellFeeBps({
    sellFeeBps: params.sellFeeBps,
    buyFeeBps: params.hop2BuyFeeBps,
    amountIn: params.ampsFromHop1,
    credit: params.ampsFromHop1,
  })
  return {
    hop1FeePips: bpsToPips(params.hop1BuyFeeBps),
    rotatedHop2FeePips: bpsToPips(rotatedBase),
    separateHop2FeePips: bpsToPips(params.sellFeeBps),
    hop2BaseBpsRotated: rotatedBase,
    hop2BaseBpsSeparate: params.sellFeeBps,
    creditUsed: params.ampsFromHop1,
    savedPips: bpsToPips(params.sellFeeBps - rotatedBase),
  }
}

export function RotateSurface() {
  const {address, isConnected} = useAccount()
  const {spokes, enabled: directoryEnabled} = usePoolDirectory()
  const [fromPoolId, setFromPoolId] = React.useState<Hex | undefined>(undefined)
  const [toPoolId, setToPoolId] = React.useState<Hex | undefined>(undefined)
  const [amountText, setAmountText] = React.useState('')

  const amps = addressOf('amps')
  const book = referenceBook(activeChainId)

  const from = React.useMemo(() => spokes.find((p) => p.poolId === fromPoolId) ?? spokes[0], [spokes, fromPoolId])
  const to = React.useMemo(() => spokes.find((p) => p.poolId === toPoolId) ?? spokes[1] ?? spokes[0], [spokes, toPoolId])
  const amount = parseAmount(amountText, 18)
  const spokeIds = React.useMemo(() => spokes.map((p) => p.poolId), [spokes])
  const {keys} = usePoolKeys(spokeIds)
  const fromKey = from ? keys.get(from.poolId) : undefined
  const toKey = to ? keys.get(to.poolId) : undefined

  const rotation = useRotationQuote({
    ...(from ? {hop1: from.poolId} : {}),
    ...(to ? {hop2: to.poolId} : {}),
    ...(amount !== null && amount > 0n ? {amountIn: amount} : {}),
  })

  const comparison = React.useMemo(() => {
    if (!from || !to) return null
    // With no on-chain answer yet, the credit equals the AMPS hop 1 buys; the fee law is the same
    // either way, so the comparison is exact in the fee dimension even before V4Quoter answers.
    const credit = rotation.rotation?.creditUsed ?? (amount ?? 0n)
    if (credit <= 0n) return null
    return compareRotation({
      hop1BuyFeeBps: from.quote.buyFeeBps,
      hop2BuyFeeBps: to.quote.buyFeeBps,
      sellFeeBps: to.quote.sellFeeBps,
      ampsFromHop1: credit,
    })
  }, [from, to, rotation.rotation, amount])

  const route = React.useMemo(() => {
    if (!from || !to || !amps || !fromKey || !toKey || amount === null || amount <= 0n) return null
    return encodeRotation({
      tokenIn: from.counter,
      amps,
      tokenOut: to.counter,
      hop1: fromKey,
      hop2: toKey,
      amountIn: amount,
      amountOutMinimum: minOutFromSlippage(rotation.rotation?.amountOut ?? 0n, DEFAULT_SLIPPAGE_BPS),
    })
  }, [from, to, amps, fromKey, toKey, amount, rotation.rotation])

  const request = React.useMemo(() => {
    if (!route || !book) return null
    return routeToRequest({router: book.universalRouter, route, deadline: deadlineFromNow()})
  }, [route, book])

  const simulation = useSimulateContract({
    address: request?.address,
    abi: universalRouterExecuteAbi,
    functionName: 'execute',
    args: request?.args,
    query: {enabled: request !== null && isConnected && address !== undefined},
  })

  const blockedReason = !isConnected
    ? 'Connect a wallet to simulate this rotation.'
    : !book
      ? 'No verified reference addresses for this chain, so no router to call.'
      : amount === null || amount <= 0n
        ? 'Enter an amount.'
        : from?.poolId === to?.poolId
          ? 'Pick two different spokes.'
          : !fromKey || !toKey
            ? 'Waiting for the pool keys from the registry.'
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
        <SurfaceHeading title="Rotate" lede="Stock to stock through AMPS, in one transaction." />
        <NotDeployed what="Rotate" />
      </div>
    )
  }

  return (
    <div className="space-y-6" data-testid="rotate-surface">
      <SurfaceHeading
        title="Rotate"
        lede="One transaction, one V4_SWAP, one SWAP_EXACT_IN with two PathKeys. The AMPS the first hop buys is the credit the second hop spends."
      />
      <Alert variant="info">
        <AlertTitle>Why it has to be one transaction</AlertTitle>
        <AlertDescription>{NOTES.rotationCredit}</AlertDescription>
      </Alert>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Rotate</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="from">Sell</Label>
              <select
                id="from"
                data-testid="rotate-from"
                className="h-10 w-full rounded-md border border-border bg-background px-3 text-sm"
                value={from?.poolId ?? ''}
                onChange={(e) => setFromPoolId(e.target.value as Hex)}
              >
                {spokes.map((pool) => (
                  <option key={pool.poolId} value={pool.poolId}>
                    {pool.symbol}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="to">Buy</Label>
              <select
                id="to"
                data-testid="rotate-to"
                className="h-10 w-full rounded-md border border-border bg-background px-3 text-sm"
                value={to?.poolId ?? ''}
                onChange={(e) => setToPoolId(e.target.value as Hex)}
              >
                {spokes.map((pool) => (
                  <option key={pool.poolId} value={pool.poolId}>
                    {pool.symbol}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="rotate-amount">Amount ({from?.symbol ?? '—'})</Label>
              <Input
                id="rotate-amount"
                data-testid="rotate-amount"
                inputMode="decimal"
                placeholder="0.0"
                value={amountText}
                onChange={(e) => setAmountText(e.target.value)}
              />
            </div>
            <TxButton
              phase={tx.phase}
              label="Rotate"
              {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
              onClick={() => void tx.send()}
              data-testid="rotate-submit"
            />
            <TxError error={tx.error} />
            {tx.hash ? <TxSuccess hash={tx.hash} explorerUrl={explorerTxUrl(activeChainId, tx.hash)} /> : null}
          </CardContent>
        </Card>

        <RotationComparisonPanel
          comparison={comparison}
          amountOut={rotation.rotation?.amountOut}
          outSymbol={to?.symbol ?? ''}
          degraded={from?.quote.degraded ?? 0}
        />
      </div>
    </div>
  )
}

export function RotationComparisonPanel({
  comparison,
  amountOut,
  outSymbol,
  degraded,
}: {
  comparison: RotationComparison | null
  amountOut?: bigint
  outSymbol: string
  degraded: number
}) {
  return (
    <div className="space-y-4" data-testid="rotation-comparison">
      <DegradedNotice degraded={degraded} />
      <Card>
        <CardHeader>
          <CardTitle>One transaction, through AMPS</CardTitle>
        </CardHeader>
        <CardContent>
          <FieldRow label="You receive" hint="From AmpsQuoter.quoteRotation, credit applied">
            <Value unavailable={amountOut === undefined}>
              {amountOut !== undefined ? `${formatAmount(amountOut, 18)} ${outSymbol}` : null}
            </Value>
          </FieldRow>
          <FieldRow label="Hop 1 — buy AMPS">
            <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.hop1FeePips) : null}</Value>
          </FieldRow>
          <FieldRow label="Hop 2 — sell AMPS, credited" hint="Blends down to the destination pool’s buy fee">
            <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.rotatedHop2FeePips) : null}</Value>
          </FieldRow>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>The same two swaps, separately</CardTitle>
        </CardHeader>
        <CardContent>
          <FieldRow label="Hop 1 — buy AMPS">
            <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.hop1FeePips) : null}</Value>
          </FieldRow>
          <FieldRow label="Hop 2 — sell AMPS, uncredited" hint="No credit survives a transaction boundary">
            <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.separateHop2FeePips) : null}</Value>
          </FieldRow>
          <FieldRow label="Difference on the second hop">
            <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.savedPips) : null}</Value>
          </FieldRow>
        </CardContent>
      </Card>

      <Alert>
        <AlertTitle>External routes</AlertTitle>
        <AlertDescription>
          No external aggregator is configured, so no third-party route is quoted here. The comparison above is between
          the same two pools priced with and without the rotation credit — it is not a claim about the whole market.
        </AlertDescription>
      </Alert>
    </div>
  )
}
