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
import {useAmpsFee, useHookRouter} from '@/hooks/use-hook-params'
import {usePoolDirectory} from '@/hooks/use-pools'
import {useRotationQuote} from '@/hooks/use-quotes'
import {useTx} from '@/hooks/use-tx'
import {ampsRouterAbi, routerDeadline} from '@/lib/abi/router'
import {activeChainId} from '@/lib/chains'
import {addressOf} from '@/lib/contracts'
import {NOTES} from '@/lib/copy'
import {explorerTxUrl} from '@/lib/deployment'
import {
  ampsFeeBpsOf,
  blendedAmpsFeeBps,
  bpsToPips,
  directFeePipsOf,
  passThroughFeePipsOf,
  pipsToPercent,
  poolBaseFeeBpsOf,
} from '@/lib/fees'
import {formatAmount, parseAmount, shortAddress} from '@/lib/format'
import {ROUTER_ROTATE} from '@/lib/protocol'
import {minOutFromSlippage} from '@/lib/route'

const DEFAULT_SLIPPAGE_BPS = 50

/**
 * The comparison the Rotate surface exists to show, and the one revision 6 changed.
 *
 * **Both hops move, not just the second.** Through `AmpsRouter.rotate` the hook prices hop 1 at the
 * source pool's pass-through base and hop 2 at the destination pool's — the second because the AMPS
 * it is selling is exactly what hop 1 bought, which the transient rotation credit proves. The same
 * two swaps built by hand through any other router pay `ampsFeeBps` **on both legs**: entering the
 * index and leaving it are what those two swaps are, seen one at a time. The saving is therefore
 * the whole difference between two AMPS fees and two pass-through fees, not one leg's worth of it.
 *
 * Both columns come from the quoter's own four fee legs where it has answered, so the dynamic
 * component is in both, and the difference is the pass-through and nothing else.
 */
export interface RotationComparison {
  /** Hop 1 through the protocol router: the source pool's pass-through base plus its dynamic part. */
  hop1FeePips: number
  /** Hop 2 through the protocol router, fully covered by the credit hop 1 created. */
  rotatedHop2FeePips: number
  /** Hop 1 through anything else: an ordinary buy, at `ampsFeeBps`. */
  separateHop1FeePips: number
  /** Hop 2 through anything else: an ordinary sell, at `ampsFeeBps`. */
  separateHop2FeePips: number
  hop2BaseBpsRotated: number
  hop2BaseBpsSeparate: number
  creditUsed: bigint
  /** The two legs together, one way against the other. */
  rotatedTotalPips: number
  separateTotalPips: number
  savedPips: number
}

/**
 * The comparison, from the two pools' quotes.
 *
 * `hop1PassThroughFeePips` / `hop2PassThroughFeePips` and their ordinary counterparts are the
 * quoter's legs when it has answered; when it has not, the caller passes the bases and this falls
 * back to the fee law, which is the same arithmetic in the same rounding direction.
 */
export function compareRotation(params: {
  hop1BuyFeeBps: number
  hop2BuyFeeBps: number
  ampsFeeBps: number
  ampsFromHop1: bigint
  /** From `PoolQuote.passThroughBuyFeePips` of hop 1, or `quoteRotation`'s `hop1FeePips`. */
  hop1PassThroughFeePips?: number
  /** From `PoolQuote.passThroughSellFeePips` of hop 2, or `quoteRotation`'s `hop2FeePips`. */
  hop2PassThroughFeePips?: number
  /** From `PoolQuote.buyFeePips` of hop 1 — what an ordinary buy in that pool costs. */
  hop1OrdinaryFeePips?: number
  /** From `PoolQuote.sellFeePips` of hop 2 — what an ordinary sell in that pool costs. */
  hop2OrdinaryFeePips?: number
}): RotationComparison {
  const rotatedBase = blendedAmpsFeeBps({
    ampsFeeBps: params.ampsFeeBps,
    buyFeeBps: params.hop2BuyFeeBps,
    amountIn: params.ampsFromHop1,
    credit: params.ampsFromHop1,
  })
  const hop1FeePips = params.hop1PassThroughFeePips ?? bpsToPips(params.hop1BuyFeeBps)
  const rotatedHop2FeePips = params.hop2PassThroughFeePips ?? bpsToPips(rotatedBase)
  const separateHop1FeePips = params.hop1OrdinaryFeePips ?? bpsToPips(params.ampsFeeBps)
  const separateHop2FeePips = params.hop2OrdinaryFeePips ?? bpsToPips(params.ampsFeeBps)
  const rotatedTotalPips = hop1FeePips + rotatedHop2FeePips
  const separateTotalPips = separateHop1FeePips + separateHop2FeePips
  return {
    hop1FeePips,
    rotatedHop2FeePips,
    separateHop1FeePips,
    separateHop2FeePips,
    hop2BaseBpsRotated: rotatedBase,
    hop2BaseBpsSeparate: params.ampsFeeBps,
    creditUsed: params.ampsFromHop1,
    rotatedTotalPips,
    separateTotalPips,
    savedPips: separateTotalPips - rotatedTotalPips,
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
  const hookRouter = useHookRouter()

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
    // The pass-through column prefers `quoteRotation`, which prices this exact amount; the pool
    // quotes' own pass-through legs are the amount-independent fallback. The ordinary column is
    // always the pool quotes' net-trade totals — what these two swaps cost through any other
    // router, in the direction each of them actually goes.
    return compareRotation({
      hop1BuyFeeBps: poolBaseFeeBpsOf(from.quote),
      hop2BuyFeeBps: poolBaseFeeBpsOf(to.quote),
      ampsFeeBps: fee.ampsFeeBps ?? ampsFeeBpsOf(to.quote),
      ampsFromHop1: credit,
      hop1PassThroughFeePips: rotation.rotation?.hop1FeePips ?? passThroughFeePipsOf(from.quote, 'buy'),
      hop2PassThroughFeePips: rotation.rotation?.hop2FeePips ?? passThroughFeePipsOf(to.quote, 'sell'),
      hop1OrdinaryFeePips: directFeePipsOf(from.quote, 'buy'),
      hop2OrdinaryFeePips: directFeePipsOf(to.quote, 'sell'),
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
          {...(hookRouter.router ? {hookRouter: hookRouter.router} : {})}
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
  hookRouter,
}: {
  comparison: RotationComparison | null
  amountOut?: bigint
  minOut?: bigint
  outSymbol: string
  degraded: number
  routerDeployed?: boolean
  routerAddress?: string
  /** `AmpsHook.router()`, live. The exemption is this address and no other. */
  hookRouter?: string
}) {
  // A mismatch is only a claim when both halves have been read. An unread pointer says nothing.
  const routerMismatch =
    routerAddress !== undefined &&
    hookRouter !== undefined &&
    routerAddress.toLowerCase() !== hookRouter.toLowerCase()
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
        <DataRow label="Hop 1 — buy AMPS, pass-through" labelClassName="text-[17px]">
          <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.hop1FeePips) : null}</Value>
        </DataRow>
        <DataRow label="Hop 2 — sell AMPS, credited" labelClassName="text-[17px]">
          <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.rotatedHop2FeePips) : null}</Value>
        </DataRow>
        <DataRow label="Both hops together" labelClassName="text-[17px]">
          <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.rotatedTotalPips) : null}</Value>
        </DataRow>
      </RowGroup>

      <RowGroup label="The same two swaps through any other router" rule="rule" className="pt-2">
        <DataRow label="Hop 1 — buy AMPS, at the AMPS fee" labelClassName="text-[17px] text-dim">
          <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.separateHop1FeePips) : null}</Value>
        </DataRow>
        <DataRow label="Hop 2 — sell AMPS, at the AMPS fee" labelClassName="text-[17px] text-dim">
          <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.separateHop2FeePips) : null}</Value>
        </DataRow>
        <DataRow label="Both hops together" labelClassName="text-[17px] text-dim">
          <Value unavailable={!comparison}>{comparison ? pipsToPercent(comparison.separateTotalPips) : null}</Value>
        </DataRow>
        <DataRow label="Difference" labelClassName="text-[17px] text-dim">
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
        <p className="mt-2 font-mono text-[12px] opacity-60">
          hookData {shortAddress(ROUTER_ROTATE)} · AmpsHook.router(){' '}
          {hookRouter !== undefined ? shortAddress(hookRouter) : '—'}
        </p>
      </Inverted>

      {routerMismatch ? (
        <Alert variant="warning" data-testid="router-mismatch">
          <AlertTitle>The hook does not honour this router</AlertTitle>
          <AlertDescription>
            <p>
              The pass-through price is granted to exactly one address, and{' '}
              <code className="font-mono">AmpsHook.router()</code> is not the address this page would call. Until the
              two agree, a rotation built here pays the AMPS fee on both hops — the right-hand column, not the left.
              Governance moves the pointer through <code className="font-mono">setRouter</code>, a seven-day timelock
              class.
            </p>
          </AlertDescription>
        </Alert>
      ) : null}

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
