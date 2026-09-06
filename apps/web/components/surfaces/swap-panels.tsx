// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'

import {DegradedNotice} from '@/components/common/degraded'
import {FieldRow} from '@/components/common/stat'
import {Value} from '@/components/common/value'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Badge} from '@/components/ui/badge'
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'
import {NOTES} from '@/lib/copy'
import {formatAmount, formatBps, formatPremiumX18, formatUsd18} from '@/lib/format'
import {pipsToBps, pipsToPercent} from '@/lib/fees'
import {gateStateName, quoteAvailability, sessionName, type PoolQuote} from '@/lib/quoter'
import {sessionLabels} from '@/lib/protocol'

/**
 * The quote, exactly as the contracts describe it.
 *
 * Fee numbers come from `AmpsQuoter` and are exact. The output amount comes from `V4Quoter` and is
 * a curve simulation. When one is unavailable the other is still shown — that is what the degraded
 * bitfield is *for* — and neither is ever substituted for the other.
 */
export interface SwapQuoteViewProps {
  side: 'buy' | 'sell'
  quote: PoolQuote | undefined
  /** From `V4Quoter`. `undefined` while it has not answered. */
  amountOut?: bigint
  amountOutDecimals: number
  amountOutSymbol: string
  /** AMPS credit this sell would consume, when it is part of a rotation. Zero for a plain sell. */
  creditUsed?: bigint
  /** The base fee after the rotation blend, when a credit applies. */
  blendedBaseBps?: number
}

export function SwapQuoteView({
  side,
  quote,
  amountOut,
  amountOutDecimals,
  amountOutSymbol,
  creditUsed,
  blendedBaseBps,
}: SwapQuoteViewProps) {
  if (!quote) {
    return (
      <Card data-testid="swap-quote">
        <CardHeader>
          <CardTitle>Quote</CardTitle>
        </CardHeader>
        <CardContent className="text-sm text-muted-foreground">Enter an amount to see the fee and the rail state.</CardContent>
      </Card>
    )
  }

  const avail = quoteAvailability(quote.degraded)
  const feePips = side === 'buy' ? quote.buyFeePips : quote.sellFeePips
  const refused = side === 'buy' ? quote.refuseBuy : quote.refuseSell

  return (
    <div className="space-y-4" data-testid="swap-quote">
      <DegradedNotice degraded={quote.degraded} />
      {refused && avail.refusals ? (
        <Alert variant="danger" data-testid="rail-warning">
          <AlertTitle>This swap would revert</AlertTitle>
          <AlertDescription>
            The pool starts beyond its outer rail on the side this trade would push it further. The rail is a
            start-of-swap condition, so a smaller size does not help — only a trade in the other direction, or waiting
            for the pool to come back inside.
          </AlertDescription>
        </Alert>
      ) : null}
      <Card>
        <CardHeader>
          <CardTitle>Quote</CardTitle>
        </CardHeader>
        <CardContent>
          <FieldRow label="You receive" hint="From V4Quoter — a curve simulation, not a promise">
            <Value unavailable={amountOut === undefined}>
              {amountOut !== undefined ? `${formatAmount(amountOut, amountOutDecimals)} ${amountOutSymbol}` : null}
            </Value>
          </FieldRow>
          <FieldRow
            label={side === 'buy' ? 'Buy fee' : 'Sell fee'}
            hint={side === 'sell' ? NOTES.sellFee : 'Charged on the counter asset entering the pool'}
          >
            <Value unavailable={!avail.fees} reason="Hook read failed">
              {avail.fees ? `${pipsToPercent(feePips)} (${formatBps(pipsToBps(feePips))} total)` : null}
            </Value>
          </FieldRow>
          <FieldRow label="Base fee" hint={blendedBaseBps !== undefined ? 'After the rotation-credit blend' : 'Before the dynamic component'}>
            <Value unavailable={!avail.fees}>
              {avail.fees ? formatBps(blendedBaseBps ?? (side === 'buy' ? quote.buyFeeBps : quote.sellFeeBps)) : null}
            </Value>
          </FieldRow>
          <FieldRow label="Dynamic component" hint="Volatility, deviation, divergence, session and surge, capped by gate state">
            <Value unavailable={!avail.fees}>{avail.fees ? `${formatBps(quote.dynBps)} of ${formatBps(quote.dynCapBps)} cap` : null}</Value>
          </FieldRow>
          {creditUsed !== undefined && creditUsed > 0n ? (
            <FieldRow label="Rotation credit used" hint={NOTES.rotationCredit}>
              <Value>{formatAmount(creditUsed, 18)} AMPS</Value>
            </FieldRow>
          ) : null}
          <FieldRow label="Market price" hint="30-minute truncated TWAP, USD per AMPS">
            <Value unavailable={!avail.marketPrice} reason="Not enough observation history yet">
              {avail.marketPrice ? formatUsd18(quote.pMktX18, 4) : null}
            </Value>
          </FieldRow>
          <FieldRow label="Reference price" hint="Never below NAV per share">
            <Value unavailable={!avail.nav}>{avail.nav ? formatUsd18(quote.pRefX18, 4) : null}</Value>
          </FieldRow>
          <FieldRow label="NAV per share">
            <Value unavailable={!avail.nav}>{avail.nav ? formatUsd18(quote.navPerShareX18, 4) : null}</Value>
          </FieldRow>
          <FieldRow label="Premium to NAV" hint={NOTES.premium}>
            <Value unavailable={!avail.premium}>{avail.premium ? formatPremiumX18(quote.premiumX18) : null}</Value>
          </FieldRow>
          <FieldRow label="Gate" hint="Swaps are never refused for a gate reason; the fee floor rises instead">
            <Value unavailable={!avail.gate}>
              {avail.gate ? (
                <span className="flex items-center gap-2">
                  <Badge variant={quote.gateState === 0 ? 'success' : 'warning'}>{gateStateName(quote.gateState)}</Badge>
                  <span className="text-muted-foreground">{sessionLabels[sessionName(quote.session) as keyof typeof sessionLabels] ?? '—'}</span>
                </span>
              ) : null}
            </Value>
          </FieldRow>
        </CardContent>
      </Card>
    </div>
  )
}

/** The rotation-credit rule, stated in the surface rather than buried in a tooltip. */
export function RotationCreditNote() {
  return (
    <Alert variant="info" data-testid="rotation-credit-note">
      <AlertTitle>How the sell fee works</AlertTitle>
      <AlertDescription>
        <p>{NOTES.sellFee}</p>
        <p className="mt-2">{NOTES.rotationCredit}</p>
      </AlertDescription>
    </Alert>
  )
}

/** Protocol-owned liquidity disclosure, per pool. */
export function PolDepthNote({depth, symbol}: {depth?: bigint; symbol: string; }) {
  return (
    <Alert data-testid="pol-depth-note">
      <AlertTitle>Bid depth in this pool</AlertTitle>
      <AlertDescription>
        <p>{NOTES.polDepth}</p>
        <p className="mt-2">
          <Value unavailable={depth === undefined}>{depth !== undefined ? `${formatAmount(depth, 18)} ${symbol}` : null}</Value>
        </p>
      </AlertDescription>
    </Alert>
  )
}
