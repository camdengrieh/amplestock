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
import {hexToString} from 'viem'
import {sessionLabels} from '@/lib/protocol'

/**
 * The quote, exactly as the contracts describe it.
 *
 * Fee numbers come from `AmpsQuoter` and are exact. The output amount comes from `V4Quoter` and is
 * a curve simulation. When one is unavailable the other is still shown — that is what the degraded
 * bitfield is *for* — and neither is ever substituted for the other.
 */
/** `bytes32("rail")` / `bytes32("uninitialized")` / `bytes32(0)` as a string. */
function decodeReason(reason: `0x${string}`): string | null {
  if (/^0x0*$/.test(reason)) return null
  try {
    return hexToString(reason, {size: 32}).replace(/\0+$/, '')
  } catch {
    return null
  }
}

export interface SwapQuoteViewProps {
  side: 'buy' | 'sell'
  quote: PoolQuote | undefined
  /** From `AmpsQuoter.quoteExactIn`. `undefined` while it has not answered. */
  amountOut?: bigint
  /** What the route will sign for: the quote less the slippage tolerance. */
  amountOutMinimum?: bigint
  /** From `AmpsQuoter.wouldRevert` — the hook's own answer, with its reason. */
  railVerdict?: {refuse: boolean; reason: `0x${string}`; degraded: number}
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
  amountOutMinimum,
  railVerdict,
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
  // `wouldRevert` is the hook's own verdict and carries a reason; the quote's refusal flags are the
  // same answer without one. Prefer the verdict when it is there, and never invent a refusal from a
  // degraded read — both sources fail open for display.
  const refused = railVerdict ? railVerdict.refuse : side === 'buy' ? quote.refuseBuy : quote.refuseSell
  const railReason = railVerdict ? decodeReason(railVerdict.reason) : null

  return (
    <div className="space-y-4" data-testid="swap-quote">
      <DegradedNotice degraded={quote.degraded} />
      {refused && (avail.refusals || railVerdict) ? (
        <Alert variant="danger" data-testid="rail-warning">
          <AlertTitle>This swap would revert</AlertTitle>
          <AlertDescription>
            {railReason === 'uninitialized' ? (
              <p>This pool has not been initialised, so there is nothing to swap against.</p>
            ) : (
              <p>
                The pool starts beyond its outer rail on the side this trade would push it further. The rail is a
                start-of-swap condition, so a smaller size does not help — only a trade in the other direction, or
                waiting for the pool to come back inside.
              </p>
            )}
          </AlertDescription>
        </Alert>
      ) : null}
      <Card>
        <CardHeader>
          <CardTitle>Quote</CardTitle>
        </CardHeader>
        <CardContent>
          <FieldRow label="You receive" hint="From AmpsQuoter.quoteExactIn — a curve simulation at this instant, not a promise">
            <Value unavailable={amountOut === undefined}>
              {amountOut !== undefined ? `${formatAmount(amountOut, amountOutDecimals)} ${amountOutSymbol}` : null}
            </Value>
          </FieldRow>
          <FieldRow label="Minimum received" hint="What the transaction signs for; below this it reverts and nothing moves">
            <Value unavailable={amountOutMinimum === undefined}>
              {amountOutMinimum !== undefined
                ? `${formatAmount(amountOutMinimum, amountOutDecimals)} ${amountOutSymbol}`
                : null}
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
