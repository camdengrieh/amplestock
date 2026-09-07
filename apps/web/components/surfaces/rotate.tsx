// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useSimulateContract} from 'wagmi'
import type {Hex} from 'viem'

import {DegradedNotice} from '@/components/common/degraded'
import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {TxButton, TxError, TxSuccess} from '@/components/common/tx'
import {Value} from '@/components/common/value'
import {AmountField} from '@/components/ledger/amount-field'
import {DataRow, Inverted, RowGroup} from '@/components/ledger/primitives'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Label} from '@/components/ui/label'
import {Select} from '@/components/ui/select'
import {useAmpsFee} from '@/hooks/use-hook-params'
import {usePoolDirectory} from '@/hooks/use-pools'
import {useRotationQuote} from '@/hooks/use-quotes'
import {useTx} from '@/hooks/use-tx'
import {ampsRouterAbi, routerDeadline} from '@/lib/abi/router'
import {activeChainId} from '@/lib/chains'
import {addressOf} from '@/lib/contracts'
import {NOTES} from '@/lib/copy'
import {explorerTxUrl} from '@/lib/deployment'
import {ampsFeeBpsOf, blendedAmpsFeeBps, bpsToPips, pipsToPercent, poolBaseFeeBpsOf} from '@/lib/fees'
import {formatAmount, parseAmount, shortAddress} from '@/lib/format'
import {minOutFromSlippage} from '@/lib/route'

const DEFAULT_SLIPPAGE_BPS = 50

/**
 * The comparison the Rotate surface exists to show.
 *
 * A pass-through's second hop pays the destination pool's base fee instead of the AMPS fee, because
 * the AMPS it is selling was bought by the first hop in the same transaction and the hook credits
 * exactly that. Doing the same two swaps as two transactions throws it away: the credit lives in
 * EIP-1153 transient storage and cannot cross a transaction boundary.
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
  ampsFeeBps: number
  ampsFromHop1: bigint
}): RotationComparison {
  const rotatedBase = blendedAmpsFeeBps({
    ampsFeeBps: params.ampsFeeBps,
    buyFeeBps: params.hop2BuyFeeBps,
    amountIn: params.ampsFromHop1,
    credit: params.ampsFromHop1,
  })
  return {
    hop1FeePips: bpsToPips(params.hop1BuyFeeBps),
    rotatedHop2FeePips: bpsToPips(rotatedBase),
    separateHop2FeePips: bpsToPips(params.ampsFeeBps),
    hop2BaseBpsRotated: rotatedBase,
    hop2BaseBpsSeparate: params.ampsFeeBps,
    creditUsed: params.ampsFromHop1,
    savedPips: bpsToPips(params.ampsFeeBps - rotatedBase),
  }
}

/**
 * Rotate.
 *
 * The write goes through `AmpsRouter.rotate` and nowhere else. That is not a convenience: the hook
 * fixes each hop's fee in `beforeSwap`, before that hop runs, so the only thing that can prove the
 * round trip is the credit the protocol's own router creates and spends inside one transaction. A
 * third-party router calling the PoolManager twice pays the AMPS fee on its AMPS-buying leg, and
 * the surface says so rather than offering a route that quietly costs more.
 *
 * When the router has no address on this chain the surface renders the ordinary "not deployed"
 * state — it does not fall back to a two-transaction route that would be dearer.
 */
export function RotateSurface() {
  const {address, isConnected} = useAccount()
  const {spokes, enabled: directoryEnabled} = usePoolDirectory()
  const [fromPoolId, setFromPoolId] = React.useState<Hex | undefined>(undefined)
  const [toPoolId, setToPoolId] = React.useState<Hex | undefined>(undefined)
  const [amountText, setAmountText] = React.useState('')

  const routerAddress = addressOf('router')
  const fee = useAmpsFee()

  const from = React.useMemo(() => spokes.find((p) => p.poolId === fromPoolId) ?? spokes[0], [spokes, fromPoolId])
  const to = React.useMemo(() => spokes.find((p) => p.poolId === toPoolId) ?? spokes[1] ?? spokes[0], [spokes, toPoolId])
  const amount = parseAmount(amountText, 18)

  const rotation = useRotationQuote({
    ...(from ? {hop1: from.poolId} : {}),
    ...(to ? {hop2: to.poolId} : {}),
    ...(amount !== null && amount > 0n ? {amountIn: amount} : {}),
  })

  const comparison = React.useMemo(() => {
    if (!from || !to) return null
    // With no on-chain answer yet, the credit equals the AMPS hop 1 buys; the fee law is the same
    // either way, so the comparison is exact in the fee dimension even before the quoter answers.
    const credit = rotation.rotation?.creditUsed ?? (amount ?? 0n)
    if (credit <= 0n) return null
    return compareRotation({
      hop1BuyFeeBps: poolBaseFeeBpsOf(from.quote),
      hop2BuyFeeBps: poolBaseFeeBpsOf(to.quote),
      ampsFeeBps: fee.ampsFeeBps ?? ampsFeeBpsOf(to.quote),
      ampsFromHop1: credit,
    })
  }, [from, to, rotation.rotation, amount, fee.ampsFeeBps])

  const minOut = minOutFromSlippage(rotation.rotation?.amountOut ?? 0n, DEFAULT_SLIPPAGE_BPS)

  const args = React.useMemo(() => {
    if (!from || !to || !address || amount === null || amount <= 0n || from.poolId === to.poolId) return undefined
    return [from.poolId, to.poolId, amount, minOut, address, false, routerDeadline()] as const
  }, [from, to, address, amount, minOut])

  const simulation = useSimulateContract({
    ...(routerAddress ? {address: routerAddress} : {}),
    abi: ampsRouterAbi,
    functionName: 'rotate',
    ...(args ? {args} : {}),
    query: {enabled: routerAddress !== undefined && args !== undefined && isConnected},
  })

  const blockedReason = !isConnected
    ? 'Connect a wallet to simulate this rotation.'
    : !routerAddress
      ? 'AmpsRouter is not deployed on this chain, and a pass-through has no other route.'
      : amount === null || amount <= 0n
        ? 'Enter an amount.'
        : from?.poolId === to?.poolId
          ? 'Pick two different spokes.'
          : from && from.quote.degraded !== 0
            ? 'The first hop’s quote is degraded. A quote with any flag raised is not permission to trade.'
            : to && to.quote.degraded !== 0
              ? 'The second hop’s quote is degraded. A quote with any flag raised is not permission to trade.'
              : rotation.rotation === undefined
                ? 'The quoter has not priced this rotation yet.'
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
          kicker="Pass-through"
          title="Rotate"
          lede="Stock to stock through AMPS, in one transaction, through the protocol’s own router."
        />
        <NotDeployed what="Rotate" />
      </div>
    )
  }

  return (
    <div className="space-y-11" data-testid="rotate-surface">
      <SurfaceHeading
        kicker="Stock to stock, one transaction"
        title="Rotate"
        lede="One call with two hops through AMPS. The AMPS the first hop buys is the credit the second hop spends — so the second hop pays the destination pool’s base fee instead of the AMPS fee."
      />

      <div className="grid gap-x-14 gap-y-12 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
        <div>
          <Label htmlFor="from" className="mb-2">
            Sell
          </Label>
          <Select
            id="from"
            data-testid="rotate-from"
            value={from?.poolId ?? ''}
            onChange={(e) => setFromPoolId(e.target.value as Hex)}
          >
            {spokes.map((pool) => (
              <option key={pool.poolId} value={pool.poolId}>
                {pool.symbol}
              </option>
            ))}
          </Select>

          <Label htmlFor="to" className="mb-2 mt-[22px]">
            Buy
          </Label>
          <Select
            id="to"
            data-testid="rotate-to"
            value={to?.poolId ?? ''}
            onChange={(e) => setToPoolId(e.target.value as Hex)}
          >
            {spokes.map((pool) => (
              <option key={pool.poolId} value={pool.poolId}>
                {pool.symbol}
              </option>
            ))}
          </Select>

          <Label htmlFor="rotate-amount" className="mb-2 mt-[22px]">
            Amount ({from?.symbol ?? '—'})
          </Label>
          <AmountField
            id="rotate-amount"
            data-testid="rotate-amount"
            value={amountText}
            onChange={setAmountText}
            unit={from?.symbol ?? ''}
          />

          <div className="mt-[26px]">
            <TxButton
              phase={tx.phase}
              label={from && to ? `Rotate ${from.symbol} → ${to.symbol}` : 'Rotate'}
              {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
              onClick={() => void tx.send()}
              data-testid="rotate-submit"
            />
          </div>
          <p className="mt-4 max-w-[52ch] text-[14px] leading-[1.55] text-dim" data-testid="no-aggregator-note">
            {NOTES.noAggregator}
          </p>
          <div className="mt-6 space-y-6">
            <TxError error={tx.error} />
            {tx.hash ? <TxSuccess hash={tx.hash} explorerUrl={explorerTxUrl(activeChainId, tx.hash)} /> : null}
          </div>
        </div>

        <RotationComparisonPanel
          comparison={comparison}
          {...(rotation.rotation?.amountOut !== undefined ? {amountOut: rotation.rotation.amountOut} : {})}
          {...(minOut > 0n ? {minOut} : {})}
          outSymbol={to?.symbol ?? ''}
          degraded={(from?.quote.degraded ?? 0) | (to?.quote.degraded ?? 0)}
          routerDeployed={routerAddress !== undefined}
          {...(routerAddress ? {routerAddress} : {})}
        />
      </div>
    </div>
  )
}

export function RotationComparisonPanel({
  comparison,
  amountOut,
  minOut,
  outSymbol,
  degraded,
  routerDeployed = true,
  routerAddress,
}: {
  comparison: RotationComparison | null
  amountOut?: bigint
  minOut?: bigint
  outSymbol: string
  degraded: number
  routerDeployed?: boolean
  routerAddress?: string
}) {
  return (
    <div className="space-y-[26px]" data-testid="rotation-comparison">
      <DegradedNotice degraded={degraded} />

      <RowGroup label="One transaction, through AMPS">
        <DataRow label="You receive" labelClassName="text-[17px]">
          <Value unavailable={amountOut === undefined}>
            {amountOut !== undefined ? `${formatAmount(amountOut, 18)} ${outSymbol}` : null}
          </Value>
        </DataRow>
        <DataRow label="Minimum received" labelClassName="text-[17px]">
          <Value unavailable={minOut === undefined}>
            {minOut !== undefined ? `${formatAmount(minOut, 18)} ${outSymbol}` : null}
          </Value>
        </DataRow>
        <DataRow label="Hop 1 — buy AMPS" labelClassName="text-[17px]">
          <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.hop1FeePips) : null}</Value>
        </DataRow>
        <DataRow label="Hop 2 — sell AMPS, credited" labelClassName="text-[17px]">
          <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.rotatedHop2FeePips) : null}</Value>
        </DataRow>
      </RowGroup>

      <RowGroup label="The same two swaps, separately" rule="rule" className="pt-2">
        <DataRow label="Hop 1 — buy AMPS" labelClassName="text-[17px] text-dim">
          <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.hop1FeePips) : null}</Value>
        </DataRow>
        <DataRow label="Hop 2 — sell AMPS, uncredited" labelClassName="text-[17px] text-dim">
          <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.separateHop2FeePips) : null}</Value>
        </DataRow>
        <DataRow label="Difference on the second hop" labelClassName="text-[17px] text-dim">
          <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.savedPips) : null}</Value>
        </DataRow>
      </RowGroup>

      <Inverted className="px-[26px] py-6" data-testid="router-only-note">
        <p className="font-mono text-[10px] uppercase tracking-[0.16em] opacity-60">
          Why it has to be one transaction, through one router
        </p>
        <p className="mt-3 text-[18px] leading-[1.45]">{NOTES.rotationCredit}</p>
        <p className="mt-3 text-[16px] leading-[1.5] opacity-70">{NOTES.routerOnly}</p>
        <p className="mt-4 font-mono text-[12px] opacity-60">
          AmpsRouter {routerAddress ? shortAddress(routerAddress) : 'not deployed on this chain'} ·
          rotate(hop1, hop2, amountIn, minOut, to, unwrap, deadline)
        </p>
      </Inverted>

      {routerDeployed ? null : (
        <Alert variant="warning" data-testid="router-missing">
          <AlertTitle>AmpsRouter has no address on this chain</AlertTitle>
          <AlertDescription>
            <p>
              The comparison above is the fee law, which is readable without the router. The rotation itself is not
              offered: there is no second route to fall back to, and a two-transaction version would pay the AMPS fee on
              its AMPS-buying leg.
            </p>
          </AlertDescription>
        </Alert>
      )}
    </div>
  )
}
