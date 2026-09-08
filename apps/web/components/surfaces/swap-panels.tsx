// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {hexToString} from 'viem'

import {DegradedNotice} from '@/components/common/degraded'
import {Value} from '@/components/common/value'
import {Callout, DataRow, RowGroup} from '@/components/ledger/primitives'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {NOTES} from '@/lib/copy'
import {
  ampsFeeBpsOf,
  directFeePipsOf,
  passThroughFeePipsOf,
  pipsToBps,
  pipsToPercent,
  poolBaseFeeBpsOf,
} from '@/lib/fees'
import {formatAmount, formatBps, formatPremiumX18, formatUsd18} from '@/lib/format'
import {sessionLabels} from '@/lib/protocol'
import {gateStateName, quoteAvailability, sessionName, type PoolQuote} from '@/lib/quoter'

/** `bytes32("rail")` / `bytes32("uninitialized")` / `bytes32(0)` as a string. */
function decodeReason(reason: `0x${string}`): string | null {
  if (/^0x0*$/.test(reason)) return null
  try {
    return hexToString(reason, {size: 32}).replace(/\0+$/, '')
  } catch {
    return null
  }
}

/**
 * The quote, in the design's shape: one `Quote` label, a 2px ink rule, and a run of `k / v / b` rows
 * — a serif label, a dim gloss under it, and the figure in mono on the right. No panels, no boxes.
 *
 * The design shows nine rows and this shows twelve, because revision 6 has two prices per direction
 * rather than one: the AMPS fee, charged both ways, is what this swap pays; the pool's base fee is
 * the pass-through price, reachable only through `AmpsRouter.rotate`, and is shown beside it with
 * what this same hop would cost inside one. The hook's own band sits under the first. Everything
 * else is the design's row order: what you receive, what you sign for, the fee, the prices, the
 * gate.
 */
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
  /** The hook-wide AMPS fee, when it has been read. Falls back to the quote's own field. */
  liveAmpsFeeBps?: number
  /** The band hardcoded in the hook, when it has been read. `null` means it has not. */
  ampsFeeBand?: {min: number; max: number} | null
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
  liveAmpsFeeBps,
  ampsFeeBand,
}: SwapQuoteViewProps) {
  if (!quote) {
    return (
      <div data-testid="swap-quote">
        <p className="ledger-label mb-2">Quote</p>
        <div className="border-t-2 border-ink pt-4 text-[15px] text-dim">
          Enter an amount to see the fee and the rail state.
        </div>
      </div>
    )
  }

  const avail = quoteAvailability(quote.degraded)
  const feePips = directFeePipsOf(quote, side)
  const ampsFeeBps = liveAmpsFeeBps ?? ampsFeeBpsOf(quote)
  const baseBps = poolBaseFeeBpsOf(quote)
  // `wouldRevert` is the hook's own verdict and carries a reason; the quote's refusal flags are the
  // same answer without one. Prefer the verdict when it is there, and never invent a refusal from a
  // degraded read — both sources fail open for display.
  const refused = railVerdict ? railVerdict.refuse : side === 'buy' ? quote.refuseBuy : quote.refuseSell
  const railReason = railVerdict ? decodeReason(railVerdict.reason) : null

  return (
    <div className="space-y-7" data-testid="swap-quote">
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

      <RowGroup label="Quote" data-testid="fee-breakdown">
        <DataRow
          label="You receive"
          note="From AmpsQuoter.quoteExactIn — a curve simulation at this instant, not a promise."
        >
          <Value unavailable={amountOut === undefined}>
            {amountOut !== undefined ? `${formatAmount(amountOut, amountOutDecimals)} ${amountOutSymbol}` : null}
          </Value>
        </DataRow>
        <DataRow
          label="Minimum received"
          note="What the transaction signs for. Below this it reverts and nothing moves."
        >
          <Value unavailable={amountOutMinimum === undefined}>
            {amountOutMinimum !== undefined
              ? `${formatAmount(amountOutMinimum, amountOutDecimals)} ${amountOutSymbol}`
              : null}
          </Value>
        </DataRow>
        <DataRow
          label={side === 'buy' ? 'Total fee on this buy' : 'Total fee on this sell'}
          note="What AmpsQuoter says the hook will charge, dynamic component included. This is the authority."
        >
          <Value unavailable={!avail.fees} reason="Hook read failed">
            {avail.fees ? `${pipsToPercent(feePips)} (${formatBps(pipsToBps(feePips))} total)` : null}
          </Value>
        </DataRow>
        <DataRow label="AMPS fee — both ways" note={NOTES.ampsFee}>
          <Value unavailable={!avail.fees} reason="Hook read failed">
            {avail.fees ? formatBps(ampsFeeBps) : null}
          </Value>
        </DataRow>
        <DataRow label="Band hardcoded in the hook" note="Governance can move the fee inside this and no further.">
          <Value unavailable={!ampsFeeBand} reason="The hook’s band could not be read">
            {ampsFeeBand ? `${formatBps(ampsFeeBand.min)} – ${formatBps(ampsFeeBand.max)}` : null}
          </Value>
        </DataRow>
        <DataRow label="Pool base fee — pass-through only" note={NOTES.poolBaseFee}>
          <Value unavailable={!avail.fees}>{avail.fees ? formatBps(blendedBaseBps ?? baseBps) : null}</Value>
        </DataRow>
        <DataRow
          label="The same hop inside a rotation"
          note="What this hop would cost as one leg of an AmpsRouter.rotate — the pass-through base plus this direction’s dynamic part. It is not available for the swap on this page: only the protocol router’s rotation hops are priced at it."
        >
          <Value unavailable={!avail.fees} reason="Hook read failed">
            {avail.fees ? pipsToPercent(passThroughFeePipsOf(quote, side)) : null}
          </Value>
        </DataRow>
        <DataRow
          label="Dynamic component"
          note="Volatility, deviation, divergence, session and surge, capped by gate state."
        >
          <Value unavailable={!avail.fees}>
            {avail.fees ? `${formatBps(quote.dynBps)} of ${formatBps(quote.dynCapBps)} cap` : null}
          </Value>
        </DataRow>
        {creditUsed !== undefined && creditUsed > 0n ? (
          <DataRow label="Rotation credit used" note={NOTES.rotationCredit}>
            <Value>{formatAmount(creditUsed, 18)} AMPS</Value>
          </DataRow>
        ) : null}
        <DataRow label="Market price" note="30-minute truncated TWAP, USD per AMPS.">
          <Value unavailable={!avail.marketPrice} reason="Not enough observation history yet">
            {avail.marketPrice ? formatUsd18(quote.pMktX18, 4) : null}
          </Value>
        </DataRow>
        <DataRow label="Reference price" note="Rate-limited upward. Never below NAV per share.">
          <Value unavailable={!avail.nav}>{avail.nav ? formatUsd18(quote.pRefX18, 4) : null}</Value>
        </DataRow>
        <DataRow label="NAV per share">
          <Value unavailable={!avail.nav}>{avail.nav ? formatUsd18(quote.navPerShareX18, 4) : null}</Value>
        </DataRow>
        <DataRow label="Premium to NAV" note={NOTES.premium}>
          <Value unavailable={!avail.premium}>{avail.premium ? formatPremiumX18(quote.premiumX18) : null}</Value>
        </DataRow>
        <DataRow label="Gate" note="Swaps are never refused for a gate reason; the fee floor rises instead.">
          <Value unavailable={!avail.gate}>
            {avail.gate
              ? `${gateStateName(quote.gateState)} · ${
                  sessionLabels[sessionName(quote.session) as keyof typeof sessionLabels] ?? '—'
                }`
              : null}
          </Value>
        </DataRow>
      </RowGroup>
    </div>
  )
}

/**
 * The fee rule, in the design's left-rule callout: a 17px lead sentence and a 15px dim follow.
 *
 * The design's lead says the sell fee is charged on AMPS-in swaps. Revision 6 charges it in both
 * directions, so the lead says that instead; the follow keeps the design's rotation-credit
 * explanation and adds the sentence about why the protocol's own router is the only route.
 */
export function RotationCreditNote() {
  return (
    <Callout
      lead="The AMPS fee is charged on every swap that touches AMPS — buying it and selling it alike."
      data-testid="rotation-credit-note"
    >
      <p>{NOTES.rotationCredit}</p>
      <p>{NOTES.routerOnly}</p>
    </Callout>
  )
}

/** Protocol-owned liquidity disclosure, per pool. */
export function PolDepthNote({depth, symbol}: {depth?: bigint; symbol: string}) {
  return (
    <Callout lead={NOTES.polDepth} data-testid="pol-depth-note">
      <p className="font-mono tabular-nums">
        <Value unavailable={depth === undefined} reason="Read on the Vault surface, pool by pool">
          {depth !== undefined ? `${formatAmount(depth, 18)} ${symbol}` : null}
        </Value>
      </p>
    </Callout>
  )
}
