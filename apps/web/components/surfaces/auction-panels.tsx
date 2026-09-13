// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'

import {FieldRow, Stat, StatGrid} from '@/components/common/stat'
import {IndexerUnavailable} from '@/components/common/states'
import {Value} from '@/components/common/value'
import {RowGroup, SectionHead} from '@/components/ledger/primitives'
import {PoweredByUniswap} from '@/components/ledger/powered-by-uniswap'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Badge} from '@/components/ui/badge'
import {Button} from '@/components/ui/button'
import {Table, TableBody, TableCell, TableHead, TableHeader, TableRow} from '@/components/ui/table'
import {TxButton, TxError, TxSuccess, type TxPhase} from '@/components/common/tx'
import type {AuctionState, BidRow} from '@/hooks/use-auction'
import type {GenesisState} from '@/hooks/use-genesis'
import type {AuctionBidRow, AuctionCheckpointRow} from '@/lib/indexer/types'
import {
  AUCTION_MPS,
  BID_STATUS_LABEL,
  BID_STATUS_NOTE,
  PHASE_LABEL,
  formatQ96Price,
  q96PriceToWholeX18,
  secondsToBlock,
  toUsd18,
} from '@/lib/auction'
import {
  GENESIS_PHASE_LABEL,
  GENESIS_PHASE_NOTE,
  floorQ96ToWholeX18,
  launchNavPerShareX18,
  launchPremiumBps,
  raisedLegsUsd18,
} from '@/lib/genesis'
import {AUCTION_COPY} from '@/lib/copy'
import type {SurfacedError} from '@/lib/errors'
import {shortAddress} from '@/lib/format'
import {formatAmount, formatBps, formatDuration, formatPercent, formatPremiumBps, formatUsd18} from '@/lib/format'

export interface UsdRate {
  answer?: bigint
  answerDecimals?: number
  /** Why there is no rate, when there is none. Shown in place of the USD figure. */
  reason?: string
}

/** How Ledger prints an auction's phase: a tag, not a colour-coded pill. */
export function PhaseTag({phase}: {phase: AuctionState['phase']}) {
  const variant =
    phase === 'live' ? 'outline' : phase === 'claimable' ? 'secondary' : phase === 'unknown' ? 'muted' : 'secondary'
  return <Badge variant={variant}>{PHASE_LABEL[phase]}</Badge>
}

/**
 * One auction's headline: what is on offer, what it is clearing at, and how far through it is.
 *
 * The clearing price is printed twice — once in the auction's own currency, which is exact, and
 * once in dollars, which is a conversion and is only shown when there is a feed to convert with.
 * The ETH auction has no ETH/USD feed in the reference book, so its dollar column is unavailable
 * rather than converted through an assumption about what ether is worth.
 */
export function AuctionHeadline({
  auction,
  blockNumber,
  blockTimeSeconds,
  usd,
}: {
  auction: AuctionState
  blockNumber?: bigint
  blockTimeSeconds?: number
  usd: UsdRate
}) {
  const priceX18 =
    auction.clearingPriceQ96 !== undefined && auction.currencyDecimals !== undefined
      ? q96PriceToWholeX18({
          priceQ96: auction.clearingPriceQ96,
          tokenDecimals: auction.tokenDecimals,
          currencyDecimals: auction.currencyDecimals,
        })
      : undefined
  const priceUsd = toUsd18({priceX18, answer: usd.answer, answerDecimals: usd.answerDecimals})

  const secondsToEnd = secondsToBlock({
    ...(blockNumber !== undefined ? {blockNumber} : {}),
    ...(auction.endBlock !== undefined ? {target: auction.endBlock} : {}),
    ...(blockTimeSeconds !== undefined ? {blockTimeSeconds} : {}),
  })
  const secondsToStart = secondsToBlock({
    ...(blockNumber !== undefined ? {blockNumber} : {}),
    ...(auction.startBlock !== undefined ? {target: auction.startBlock} : {}),
    ...(blockTimeSeconds !== undefined ? {blockTimeSeconds} : {}),
  })

  const soldFraction =
    auction.totalCleared !== undefined && auction.totalSupply !== undefined && auction.totalSupply > 0n
      ? Number((auction.totalCleared * 10_000n) / auction.totalSupply) / 10_000
      : undefined

  return (
    <StatGrid data-testid={`auction-headline-${auction.key}`}>
      <Stat
        label="Clearing price"
        value={
          auction.clearingPriceQ96 !== undefined && auction.currencyDecimals !== undefined
            ? formatQ96Price({
                priceQ96: auction.clearingPriceQ96,
                tokenDecimals: auction.tokenDecimals,
                currencyDecimals: auction.currencyDecimals,
                symbol: auction.currencySymbol ?? '',
              })
            : undefined
        }
        unavailable={auction.clearingPriceQ96 === undefined || auction.currencyDecimals === undefined}
        hint="Uniform: everyone who clears pays this, whatever maximum they bid."
      />
      <Stat
        label="Clearing price, in USD"
        value={priceUsd !== undefined ? formatUsd18(priceUsd, 6) : undefined}
        unavailable={priceUsd === undefined}
        reason={usd.reason ?? 'No price feed for this currency on this chain'}
        hint="Converted through a Chainlink answer for the auction currency, not assumed."
      />
      <Stat
        label="Raised"
        value={
          auction.currencyRaised !== undefined && auction.currencyDecimals !== undefined
            ? `${formatAmount(auction.currencyRaised, auction.currencyDecimals)} ${auction.currencySymbol ?? ''}`
            : undefined
        }
        unavailable={auction.currencyRaised === undefined}
        hint="Becomes the entry pools’ bid liquidity when the auction settles."
      />
      <Stat
        label="Graduated"
        value={auction.isGraduated === undefined ? undefined : auction.isGraduated ? 'Yes' : 'Not yet'}
        unavailable={auction.isGraduated === undefined}
        hint="The auction graduates once the currency raised reaches its required minimum. If it never does, every bid is refunded in full."
      />
      <Stat
        label="On offer"
        value={auction.totalSupply !== undefined ? `${formatAmount(auction.totalSupply, 18)} AMPS` : undefined}
        unavailable={auction.totalSupply === undefined}
      />
      <Stat
        label="Sold so far"
        value={
          auction.totalCleared !== undefined
            ? `${formatAmount(auction.totalCleared, 18)} AMPS${soldFraction !== undefined ? ` (${formatPercent(soldFraction)})` : ''}`
            : undefined
        }
        unavailable={auction.totalCleared === undefined}
      />
      <Stat
        label={auction.phase === 'upcoming' ? 'Starts in' : 'Ends in'}
        value={
          auction.phase === 'upcoming'
            ? secondsToStart !== undefined && secondsToStart > 0
              ? formatDuration(secondsToStart)
              : undefined
            : secondsToEnd !== undefined && secondsToEnd > 0
              ? formatDuration(secondsToEnd)
              : auction.phase === 'ended' || auction.phase === 'claimable'
                ? 'Finished'
                : undefined
        }
        unavailable={secondsToEnd === undefined && secondsToStart === undefined}
        reason="This chain publishes no block time, so blocks cannot be turned into a duration"
        hint={
          auction.endBlock !== undefined ? `End block ${auction.endBlock.toString()}` : 'End block could not be read'
        }
      />
      <Stat
        label="Priced as of block"
        value={auction.lastCheckpointedBlock !== undefined ? auction.lastCheckpointedBlock.toString() : undefined}
        unavailable={auction.lastCheckpointedBlock === undefined}
        hint="checkpoint() is a write, not a view, so every read here is as of this block. Advancing it is free apart from gas."
      />
      <Stat
        label="Issued so far"
        value={auction.cumulativeMps !== undefined ? formatPercent(auction.cumulativeMps / Number(AUCTION_MPS)) : undefined}
        unavailable={auction.cumulativeMps === undefined}
        hint="Of the tranche on offer, on the auction’s fixed per-block schedule."
      />
    </StatGrid>
  )
}

/** Start, end and claim, as blocks and — where the chain publishes a block time — as durations. */
export function AuctionSchedule({
  auction,
  blockNumber,
  blockTimeSeconds,
}: {
  auction: AuctionState
  blockNumber?: bigint
  blockTimeSeconds?: number
}) {
  const row = (label: string, target: bigint | undefined, hint: string) => {
    const seconds = secondsToBlock({
      ...(blockNumber !== undefined ? {blockNumber} : {}),
      ...(target !== undefined ? {target} : {}),
      ...(blockTimeSeconds !== undefined ? {blockTimeSeconds} : {}),
    })
    return (
      <FieldRow key={label} label={label} hint={hint}>
        <Value unavailable={target === undefined}>
          {target !== undefined
            ? `block ${target.toString()}${
                seconds === undefined ? '' : seconds > 0 ? ` · in ${formatDuration(seconds)}` : ` · ${formatDuration(-seconds)} ago`
              }`
            : null}
        </Value>
      </FieldRow>
    )
  }
  return (
    <RowGroup label="Schedule" data-testid={`auction-schedule-${auction.key}`}>
        {row('Starts', auction.startBlock, 'The first block of the issuance schedule')}
        {row('Ends', auction.endBlock, 'No bids after this block; exits open')}
        {row('Claimable', auction.claimBlock, 'Tokens can be claimed from this block. A bid must be exited first.')}
        <FieldRow label="Issuance now" hint="Share of the tranche released per block during the current step">
          <Value unavailable={auction.step === undefined}>
            {auction.step ? `${formatBps((auction.step.mps * 10_000) / Number(AUCTION_MPS))} per block` : null}
          </Value>
        </FieldRow>
        <FieldRow label="Current step" hint="The schedule is fixed at deployment and cannot be changed">
          <Value unavailable={auction.step === undefined}>
            {auction.step ? `blocks ${auction.step.startBlock.toString()} – ${auction.step.endBlock.toString()}` : null}
          </Value>
        </FieldRow>
        <FieldRow label="Remaining supply" hint="Of the tranche on offer in this auction">
          <Value unavailable={auction.remainingSupply === undefined}>
            {auction.remainingSupply !== undefined ? `${formatAmount(auction.remainingSupply, 18)} AMPS` : null}
          </Value>
        </FieldRow>
    </RowGroup>
  )
}

/** The tick book's shape: where the floor is, what the grid is, and what the next tick would cost. */
export function AuctionBookPanel({auction, requiredDemand}: {auction: AuctionState; requiredDemand?: bigint}) {
  const price = (q: bigint | undefined) =>
    q !== undefined && auction.currencyDecimals !== undefined
      ? formatQ96Price({
          priceQ96: q,
          tokenDecimals: auction.tokenDecimals,
          currencyDecimals: auction.currencyDecimals,
          symbol: auction.currencySymbol ?? '',
        })
      : null
  return (
    <RowGroup label="The book" data-testid={`auction-book-${auction.key}`}>
        <FieldRow label="Floor price" hint="The lowest price a bid may be submitted at">
          <Value unavailable={price(auction.floorPriceQ96) === null}>{price(auction.floorPriceQ96)}</Value>
        </FieldRow>
        <FieldRow label="Tick spacing" hint="Bid prices must sit on this grid; the form snaps upward to the next tick">
          <Value unavailable={price(auction.tickSpacingQ96) === null}>{price(auction.tickSpacingQ96)}</Value>
        </FieldRow>
        <FieldRow label="Next active tick" hint="The next price with demand already resting on it">
          <Value unavailable={price(auction.nextActiveTickQ96) === null}>{price(auction.nextActiveTickQ96)}</Value>
        </FieldRow>
        <FieldRow
          label="Demand to reach it"
          hint="What it would take, in the auction currency, to move the clearing price to the next active tick"
        >
          <Value unavailable={requiredDemand === undefined || auction.currencyDecimals === undefined}>
            {requiredDemand !== undefined && auction.currencyDecimals !== undefined
              ? `${formatAmount(requiredDemand, auction.currencyDecimals)} ${auction.currencySymbol ?? ''}`
              : null}
          </Value>
        </FieldRow>
        <FieldRow label="Maximum bid price" hint="Bounded by the tranche size; a higher maximum cannot clear">
          <Value unavailable={price(auction.maxBidPriceQ96) === null}>{price(auction.maxBidPriceQ96)}</Value>
        </FieldRow>
    </RowGroup>
  )
}

/** The mechanism, in the docs tone, shown before the auction opens and kept afterwards. */
export function AuctionExplainer() {
  return (
    <section data-testid="auction-explainer">
      <SectionHead
        title="How the auction works"
        note="A continuous clearing auction: one uniform price, a fixed per-block issuance schedule, and a full refund if it does not graduate."
        aside="Uniswap CCA v2.1.0"
      />
      <div className="grid gap-x-12 gap-y-0 md:grid-cols-2">
        {AUCTION_COPY.map((item, index) => (
          <div key={item.title} className="grid grid-cols-[44px_minmax(0,1fr)] gap-5 border-b border-hair py-5">
            <span className="pt-1.5 font-mono text-[11px] tracking-[0.08em] text-dim">
              {String(index + 1).padStart(2, '0')}
            </span>
            <div>
              <div className="text-[21px] leading-[1.25]">{item.title}</div>
              <div className="mt-1 max-w-[52ch] text-[15px] leading-normal text-dim">{item.body}</div>
            </div>
          </div>
        ))}
      </div>
    </section>
  )
}

/**
 * The clearing price over the bidding window, as an inline sparkline.
 *
 * The auction's own `clearingPrice()` is one number: whatever the last checkpoint wrote.
 * `checkpoint()` is a write rather than a view, so between two checkpoints there is no on-chain
 * record of the price at all — this series exists only because the indexer keeps every
 * `CheckpointUpdated` and `ClearingPriceUpdated` log. It is therefore **history**, not a live
 * figure: the headline above stays a chain read and this panel never overrides it.
 *
 * No charting library. One series, one axis, drawn as an SVG path in the Ledger's own hairlines,
 * which is a shape that survives a build with no network.
 */
export function ClearingPriceHistory({
  auction,
  checkpoints,
  unavailable,
  configured = true,
  reason,
}: {
  auction: AuctionState
  checkpoints?: readonly AuctionCheckpointRow[]
  unavailable?: boolean
  /** False when no indexer is configured for this deployment at all. */
  configured?: boolean
  reason?: string
}) {
  if (unavailable || !configured || !checkpoints || checkpoints.length === 0) {
    return (
      <IndexerUnavailable
        what={`The ${auction.key.toUpperCase()} leg’s clearing-price history`}
        {...(reason ? {reason} : {})}
      />
    )
  }

  const priceAt = (row: AuctionCheckpointRow): number | undefined => {
    if (auction.currencyDecimals === undefined) return undefined
    const x18 = q96PriceToWholeX18({
      priceQ96: BigInt(row.clearingPriceQ96),
      tokenDecimals: auction.tokenDecimals,
      currencyDecimals: auction.currencyDecimals,
    })
    return Number(x18) / 1e18
  }
  const values = checkpoints.map(priceAt).filter((v): v is number => v !== undefined)
  if (values.length === 0) {
    return (
      <IndexerUnavailable
        what={`The ${auction.key.toUpperCase()} leg’s clearing-price history`}
        reason="the auction currency’s decimals could not be read, so a Q96 price cannot be scaled"
      />
    )
  }
  const min = Math.min(...values)
  const max = Math.max(...values)
  const span = max - min || 1
  const path = values
    .map((v, i) => {
      const x = (i / Math.max(values.length - 1, 1)) * 100
      const y = 30 - ((v - min) / span) * 28
      return `${i === 0 ? 'M' : 'L'}${x.toFixed(2)},${y.toFixed(2)}`
    })
    .join(' ')
  const symbol = auction.currencySymbol ?? ''
  const digits = symbol === 'USDG' ? 4 : 8
  return (
    <div className="space-y-3" data-testid={`clearing-history-${auction.key}`}>
      <svg
        viewBox="0 0 100 32"
        preserveAspectRatio="none"
        className="h-24 w-full border-b border-rule text-ink"
        role="img"
        aria-label={`Clearing price over the bidding window, ${symbol} per AMPS`}
      >
        <path d={path} fill="none" stroke="currentColor" strokeWidth="0.5" vectorEffect="non-scaling-stroke" />
      </svg>
      <div className="ledger-label flex justify-between">
        <span>
          {min.toFixed(digits)} {symbol}
        </span>
        <span>
          {values.length} checkpoint{values.length === 1 ? '' : 's'}
        </span>
        <span>
          {max.toFixed(digits)} {symbol}
        </span>
      </div>
      <p className="max-w-[88ch] text-[13px] leading-[1.55] text-dim">
        Non-decreasing by construction: the clearing price rises only as far as resting demand supports and never
        falls. Every point is a block somebody paid to advance the auction to, which is why the line is a series of
        steps rather than a continuous curve.
      </p>
    </div>
  )
}

/**
 * The public bid book: every bid the indexer has seen in this leg, not only the reader's own.
 *
 * The reader's own bids are on the table above and come straight off `BidSubmitted` logs, which
 * works with no indexer at all. This is the other side of that — what everybody else committed,
 * and at what maximum — and it is genuinely public information: the auction emits it and anyone can
 * read it. It is disclosure only, and no figure here is used to price anything.
 *
 * `amountQ96` is stored as the auction stores it, so it is shifted down by 2^96 for display and
 * nowhere else.
 */
export function PublicBidBook({
  auction,
  bids,
  unavailable,
  configured = true,
  reason,
  limit = 12,
}: {
  auction: AuctionState
  bids?: readonly AuctionBidRow[]
  unavailable?: boolean
  configured?: boolean
  reason?: string
  limit?: number
}) {
  if (unavailable || !configured || bids === undefined) {
    return <IndexerUnavailable what={`The ${auction.key.toUpperCase()} leg’s public bid book`} {...(reason ? {reason} : {})} />
  }
  if (bids.length === 0) {
    return (
      <p className="text-sm text-dim" data-testid={`bid-book-${auction.key}`}>
        The indexer has seen no bids in this leg yet. That is a statement about the index, not about the auction.
      </p>
    )
  }
  const decimals = auction.currencyDecimals
  const rows = bids.slice(0, limit)
  return (
    <Table data-testid={`bid-book-${auction.key}`}>
      <TableHeader>
        <TableRow>
          <TableHead>Bid</TableHead>
          <TableHead>Bidder</TableHead>
          <TableHead align="right">Maximum</TableHead>
          <TableHead align="right">Committed</TableHead>
          <TableHead align="right">Block</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((bid) => (
          <TableRow key={`${bid.auction}-${bid.bidId}`}>
            <TableCell>#{bid.bidId}</TableCell>
            <TableCell className="font-mono text-[12px] text-dim" title={bid.owner}>
              {shortAddress(bid.owner)}
            </TableCell>
            <TableCell align="right">
              <Value unavailable={decimals === undefined}>
                {decimals !== undefined
                  ? formatQ96Price({
                      priceQ96: BigInt(bid.maxPriceQ96),
                      tokenDecimals: auction.tokenDecimals,
                      currencyDecimals: decimals,
                      symbol: auction.currencySymbol ?? '',
                    })
                  : null}
              </Value>
            </TableCell>
            <TableCell align="right">
              <Value unavailable={decimals === undefined}>
                {decimals !== undefined
                  ? `${formatAmount(BigInt(bid.amountQ96) >> 96n, decimals)} ${auction.currencySymbol ?? ''}`
                  : null}
              </Value>
            </TableCell>
            <TableCell align="right" className="text-dim">
              {bid.submittedBlock}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}

export function MyBidsTable({
  auction,
  bids,
  unavailable,
  reason,
  hasAccount,
  onExit,
  onExitPartial,
  onClaim,
}: {
  auction: AuctionState
  bids: readonly BidRow[]
  unavailable?: boolean
  reason?: string
  hasAccount: boolean
  onExit?: (bidId: bigint) => void
  onExitPartial?: (bidId: bigint) => void
  onClaim?: (bidId: bigint) => void
}) {
  if (!hasAccount) {
    return (
      <p className="text-sm text-dim" data-testid={`bids-${auction.key}`}>
        Connect a wallet to see your own bids in this auction.
      </p>
    )
  }
  if (unavailable) {
    return (
      <Alert variant="warning" data-testid={`bids-${auction.key}`}>
        <AlertTitle>Your bids could not be listed</AlertTitle>
        <AlertDescription>
          <p>
            The bid list comes from the auction’s <code className="font-mono">BidSubmitted</code> logs, and the node did
            not answer{reason ? ` (${reason})` : ''}. This is not the same as having no bids, and nothing on this page
            should be read as saying you have none.
          </p>
        </AlertDescription>
      </Alert>
    )
  }
  if (bids.length === 0) {
    return (
      <p className="text-sm text-dim" data-testid={`bids-${auction.key}`}>
        No bids from this wallet in this auction.
      </p>
    )
  }
  const canExit = auction.phase === 'ended' || auction.phase === 'claimable'
  const canClaim = auction.phase === 'claimable'
  return (
    <Table data-testid={`bids-${auction.key}`}>
      <TableHeader>
        <TableRow>
          <TableHead>Bid</TableHead>
          <TableHead align="right">Your maximum</TableHead>
          <TableHead align="right">Committed</TableHead>
          <TableHead align="right">Filled</TableHead>
          <TableHead align="right">Status</TableHead>
          <TableHead align="right">Action</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {bids.map((bid) => (
          <TableRow key={bid.bidId.toString()} data-testid={`bid-${bid.bidId.toString()}`}>
            <TableCell>#{bid.bidId.toString()}</TableCell>
            <TableCell align="right">
              <Value unavailable={auction.currencyDecimals === undefined}>
                {auction.currencyDecimals !== undefined
                  ? formatQ96Price({
                      priceQ96: bid.maxPriceQ96,
                      tokenDecimals: auction.tokenDecimals,
                      currencyDecimals: auction.currencyDecimals,
                      symbol: auction.currencySymbol ?? '',
                    })
                  : null}
              </Value>
            </TableCell>
            <TableCell align="right">
              <Value unavailable={auction.currencyDecimals === undefined}>
                {auction.currencyDecimals !== undefined
                  ? `${formatAmount(bid.amount, auction.currencyDecimals)} ${auction.currencySymbol ?? ''}`
                  : null}
              </Value>
            </TableCell>
            <TableCell align="right">
              <Value unavailable={bid.tokensFilled === 0n && bid.exitedBlock === 0n} reason="Not settled until the bid is exited">
                {bid.tokensFilled > 0n ? `${formatAmount(bid.tokensFilled, 18)} AMPS` : null}
              </Value>
            </TableCell>
            <TableCell align="right">
              <span title={BID_STATUS_NOTE[bid.status]}>
                <Badge
                  variant={
                    bid.status === 'filling'
                      ? 'success'
                      : bid.status === 'outbid'
                        ? 'danger'
                        : bid.status === 'exited'
                          ? 'muted'
                          : 'warning'
                  }
                >
                  {BID_STATUS_LABEL[bid.status]}
                </Badge>
              </span>
            </TableCell>
            <TableCell align="right">
              {bid.exitedBlock > 0n ? (
                <Button
                  variant="outline"
                  size="sm"
                  disabled={!canClaim}
                  onClick={() => onClaim?.(bid.bidId)}
                  data-testid={`claim-bid-${bid.bidId.toString()}`}
                >
                  Claim
                </Button>
              ) : (
                <Button
                  variant="outline"
                  size="sm"
                  disabled={!canExit}
                  onClick={() => (bid.status === 'marginal' ? onExitPartial?.(bid.bidId) : onExit?.(bid.bidId))}
                  data-testid={`exit-bid-${bid.bidId.toString()}`}
                >
                  {bid.status === 'marginal' ? 'Exit (partial)' : 'Exit'}
                </Button>
              )}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}

/**
 * Settlement: what the launch decided, read from the adapter that decided it.
 *
 * `AmpsGenesis` is the only contract that knows the answer. Each auction knows its own clearing
 * price in its own currency; the adapter converts them to 18-decimal USD, **measures** the factory's
 * protocol fee rather than predicting it, chooses which leg's price becomes `P0` — the USDG leg
 * whenever it graduated, because it is the only one denominated in the unit `P_ref` is quoted in —
 * and hands the proceeds, the unsold AMPS and `P0` to `AmpsVault.genesisPlace` in one transaction.
 * So nothing here is added up client-side: every figure is a read of the adapter or of the vault.
 *
 * Three states the panel must not blur into one another:
 *
 * - **`Ended`** — every leg has closed and nobody has settled. `settle()` is offered here, and only
 *   here. It is permissionless and one-shot.
 * - **`Settled`** — the launch is live. `P0`, NAV/share and the premium are facts, and the premium
 *   is a disclosure: `P0 / NAV − 1`, never presented as a discount, and NAV/share is never quoted
 *   as the auction price.
 * - **`Aborted`** — no leg graduated, so nothing was sold. Bidders refund through the auctions
 *   themselves. There is no launch to show and the panel says so instead of showing one.
 */
export function SettlementPanel({
  genesis,
  auctions,
  usdgDecimals,
  genesisSupply,
  pRefX18,
  liveCells,
  poolCount,
  vaultInitialized,
  settle,
}: {
  genesis: GenesisState
  auctions: readonly AuctionState[]
  usdgDecimals?: number
  /**
   * `AmpsVault.S0()` — the whole genesis supply, and the denominator of NAV per share at launch.
   *
   * Not `Amps.totalSupply()`: that grows with every bond, so dividing the auction's raise by it
   * would make the launch NAV drift downwards for ever after. `S0` is in the bytecode and never
   * moves, so this figure is as true a year later as it was in the settlement block.
   */
  genesisSupply?: bigint
  /** `AmpsVault.checkpointData().pRefX18` — `max(P0, NAV)`, so it should equal `P0` at launch. */
  pRefX18?: bigint
  liveCells?: number
  poolCount?: number
  vaultInitialized?: boolean
  settle?: SettleAction
}) {
  // Nothing to settle and nothing settled: the panel is for the end of the auction, not the middle
  // of it. `Created` and `Bidding` are the headline's business.
  if (genesis.address === undefined && auctions.every((a) => a.phase !== 'ended' && a.phase !== 'claimable')) {
    return null
  }
  const phase = genesis.phase
  if (phase === 'created' || phase === 'bidding') return null

  const aborted = phase === 'aborted'
  const settled = phase === 'settled'

  // NAV per share at launch: the adapter's raise over `S0`, which is what the vault's own `Genesis`
  // log records. It is deliberately *not* the vault's live checkpoint — that number moves with
  // every fee, bond and burn, and "NAV per share at launch" is a fact about one block.
  const navX18 = launchNavPerShareX18({
    ...(genesis.raisedUsd18 !== undefined ? {raisedUsd18: genesis.raisedUsd18} : {}),
    ...(genesisSupply !== undefined ? {totalSupply: genesisSupply} : {}),
  })
  const premiumBps = launchPremiumBps({
    ...(genesis.p0X18 !== undefined ? {p0X18: genesis.p0X18} : {}),
    ...(navX18 !== undefined ? {navPerShareX18: navX18} : {}),
  })
  const legs = raisedLegsUsd18({
    ...(genesis.raisedUsdg !== undefined ? {raisedUsdg: genesis.raisedUsdg} : {}),
    ...(usdgDecimals !== undefined ? {usdgDecimals} : {}),
    ...(genesis.raisedWeth !== undefined ? {raisedWeth: genesis.raisedWeth} : {}),
    ...(genesis.ethUsdX18 !== undefined ? {ethUsdX18: genesis.ethUsdX18} : {}),
  })
  const refMatchesP0 =
    pRefX18 !== undefined && genesis.p0X18 !== undefined && genesis.p0X18 > 0n ? pRefX18 === genesis.p0X18 : undefined

  return (
    <section data-testid="auction-settlement">
      <SectionHead
        title="Settlement"
        note="The two auctions do not open the protocol; the genesis adapter does. It sweeps both legs, wraps the ETH, measures what actually arrived, derives P0 from the clearing price and calls AmpsVault.genesisPlace — which takes the proceeds as backing, takes the unsold AMPS back as inventory and seeds the reference price. One transaction, and anybody may send it."
        aside={phase ? GENESIS_PHASE_LABEL[phase] : 'Adapter not configured'}
      />

      {phase ? (
        <Alert
          variant={aborted ? 'warning' : settled ? 'default' : 'info'}
          className="mt-7"
          data-testid="genesis-phase-note"
        >
          <AlertTitle>{GENESIS_PHASE_LABEL[phase]}</AlertTitle>
          <AlertDescription>
            <p>{GENESIS_PHASE_NOTE[phase]}</p>
          </AlertDescription>
        </Alert>
      ) : genesis.unavailable ? (
        <Alert variant="warning" className="mt-7" data-testid="genesis-phase-note">
          <AlertTitle>The genesis adapter did not answer</AlertTitle>
          <AlertDescription>
            <p>
              An address is configured for <code className="font-mono">AmpsGenesis</code> but{' '}
              <code className="font-mono">phase()</code> could not be read. Nothing below is settlement state, and
              nothing on this page should be read as saying the launch has or has not happened.
            </p>
          </AlertDescription>
        </Alert>
      ) : null}

      {aborted ? null : (
        <StatGrid className="mt-7">
          <Stat
            label="Launch reference price P₀"
            value={genesis.p0X18 !== undefined && genesis.p0X18 > 0n ? formatUsd18(genesis.p0X18, 6) : undefined}
            unavailable={genesis.p0X18 === undefined || genesis.p0X18 === 0n}
            reason="P₀ is written by settle(); it is zero until then and zero for ever if no leg graduated"
            hint="The clearing price, in 18-decimal USD per AMPS. All 32 pools were opened at it rather than at a price chosen in advance."
          />
          <Stat
            label="Raised"
            value={genesis.raisedUsd18 !== undefined ? formatUsd18(genesis.raisedUsd18) : undefined}
            unavailable={genesis.raisedUsd18 === undefined}
            hint="Both legs, net of the factory's protocol fee, priced in USD by the adapter. This is the A the vault started with."
          />
          <Stat
            label="NAV per share at launch"
            value={navX18 !== undefined ? formatUsd18(navX18, 4) : undefined}
            unavailable={navX18 === undefined}
            hint="The raise divided by S₀, the whole genesis supply — inventory included, which is what fully diluted means. It is a fact about the settlement block and does not move afterwards; the vault's live NAV is on the Vault surface."
          />
          <Stat
            label="Launch premium"
            value={premiumBps !== undefined ? formatPremiumBps(premiumBps) : undefined}
            unavailable={premiumBps === undefined}
            hint="P₀ over NAV per share, less one. The vault keeps 45% of the supply as inventory backed by nothing until it sells, so a buyer's price exceeds NAV by exactly that. Disclosed, never smoothed: it shrinks as the ask ladders fill at or above P₀."
          />
        </StatGrid>
      )}

      <div className="mt-11 grid gap-x-14 gap-y-11 lg:grid-cols-2">
        <RowGroup label="What settlement moved" data-testid="genesis-proceeds">
          <FieldRow label="USDG swept" hint="From the USDG leg, net of the protocol fee. Taken at par: P₀ needs no oracle to come out of this leg.">
            <Value unavailable={genesis.raisedUsdg === undefined || usdgDecimals === undefined}>
              {genesis.raisedUsdg !== undefined && usdgDecimals !== undefined
                ? `${formatAmount(genesis.raisedUsdg, usdgDecimals)} USDG${legs.usdg !== undefined ? ` · ${formatUsd18(legs.usdg)}` : ''}`
                : null}
            </Value>
          </FieldRow>
          <FieldRow label="WETH swept" hint="The ETH leg's proceeds, wrapped into WETH9 inside settle() so the vault never holds native ether.">
            <Value unavailable={genesis.raisedWeth === undefined}>
              {genesis.raisedWeth !== undefined
                ? `${formatAmount(genesis.raisedWeth, 18)} WETH${legs.weth !== undefined ? ` · ${formatUsd18(legs.weth)}` : ''}`
                : null}
            </Value>
          </FieldRow>
          <FieldRow
            label="Unsold AMPS returned"
            hint="The part of the auction tranche that never cleared. It is pulled back as the vault's own inventory — neither minted nor counted in A, because every AMPS leg is valued at zero."
          >
            <Value unavailable={genesis.unsoldAmps === undefined}>
              {genesis.unsoldAmps !== undefined ? `${formatAmount(genesis.unsoldAmps, 18)} AMPS` : null}
            </Value>
          </FieldRow>
          <FieldRow label="ETH/USD the adapter used" hint="Refreshed from the vault's feed registry at settlement where that read succeeded, otherwise the price recorded at creation.">
            <Value unavailable={genesis.ethUsdX18 === undefined || genesis.ethUsdX18 === 0n}>
              {genesis.ethUsdX18 !== undefined && genesis.ethUsdX18 > 0n ? formatUsd18(genesis.ethUsdX18, 2) : null}
            </Value>
          </FieldRow>
        </RowGroup>

        <RowGroup label="Where the launch got to" data-testid="genesis-placement">
          <FieldRow label="Vault opened" hint="AmpsVault.initialized() — set by genesisPlace, one-way. Before it, nothing can be checkpointed, bonded or redeemed.">
            <Value unavailable={vaultInitialized === undefined}>
              {vaultInitialized === undefined ? null : vaultInitialized ? 'Yes' : 'Not yet'}
            </Value>
          </FieldRow>
          <FieldRow
            label="Reference price seeded at P₀"
            hint="genesisPlace writes P_ref = max(P0, NAV/share) after the checkpoint, so the two agree unless the NAV floor bound it."
          >
            <Value unavailable={refMatchesP0 === undefined}>
              {refMatchesP0 === undefined
                ? null
                : refMatchesP0
                  ? `Yes · ${pRefX18 !== undefined ? formatUsd18(pRefX18, 6) : ''}`
                  : `P_ref ${pRefX18 !== undefined ? formatUsd18(pRefX18, 6) : ''} — floored at NAV`}
            </Value>
          </FieldRow>
          <FieldRow label="Pools opened at P₀" hint="Registration runs after settlement, and PoolRegistry anchors every pool at the vault's pRefX18().">
            <Value unavailable={poolCount === undefined}>{poolCount === undefined ? null : String(poolCount)}</Value>
          </FieldRow>
          <FieldRow
            label="Ladder cells placed"
            hint="AmpsVault.liveCells(): ten ask cells in each of the 32 pools plus four seed bids in each entry pool once both placement phases have run."
          >
            <Value unavailable={liveCells === undefined}>{liveCells === undefined ? null : String(liveCells)}</Value>
          </FieldRow>
        </RowGroup>
      </div>

      {settle ? (
        <div className="mt-11" data-testid="genesis-settle">
          <SectionHead
            title="Settle genesis"
            note="Permissionless and one-shot. It checkpoints both auctions, sweeps the currency from every graduated leg and the unsold tokens from every leg, wraps the ether, derives P₀ and calls AmpsVault.genesisPlace — all in the transaction you send. There is no reward for sending it and no way to send it twice."
            aside={settle.blockedReason ? 'Not callable' : 'Callable now'}
          />
          <div className="mt-6 max-w-[46rem] space-y-6">
            <TxButton
              phase={settle.phase}
              label="Settle genesis"
              {...(settle.blockedReason ? {blockedReason: settle.blockedReason} : {})}
              onClick={settle.onClick}
              data-testid="genesis-settle-button"
            />
            <TxError error={settle.error} />
            {settle.hash ? <TxSuccess hash={settle.hash} explorerUrl={settle.explorerUrl ?? null} /> : null}
          </div>
        </div>
      ) : null}

      <RowGroup label="The adapter" className="mt-11" data-testid="genesis-wiring">
        <FieldRow label="AmpsGenesis" hint="Immutable and ownerless. Six immutables, one governed call, one permissionless call, no rescue function.">
          <Value unavailable={!genesis.address} {...(genesis.address ? {title: genesis.address} : {})}>
            {genesis.address ? shortAddress(genesis.address) : null}
          </Value>
        </FieldRow>
        <FieldRow label="Settles into" hint="The vault's genesis pointer names this adapter, and the adapter names the vault. Both are set once.">
          <Value unavailable={!genesis.vault} {...(genesis.vault ? {title: genesis.vault} : {})}>
            {genesis.vault ? shortAddress(genesis.vault) : null}
          </Value>
        </FieldRow>
        <FieldRow label="USDG floor" hint="$1.00 per AMPS, computed by the adapter from the currency's decimals rather than taken from the proposal.">
          <Value unavailable={floorQ96ToWholeX18({...(genesis.floorUsdgQ96 !== undefined ? {floorQ96: genesis.floorUsdgQ96} : {}), ...(usdgDecimals !== undefined ? {currencyDecimals: usdgDecimals} : {})}) === undefined}>
            {(() => {
              const x18 = floorQ96ToWholeX18({
                ...(genesis.floorUsdgQ96 !== undefined ? {floorQ96: genesis.floorUsdgQ96} : {}),
                ...(usdgDecimals !== undefined ? {currencyDecimals: usdgDecimals} : {}),
              })
              return x18 === undefined ? null : `${formatUsd18(x18, 6)} per AMPS`
            })()}
          </Value>
        </FieldRow>
        <FieldRow label="ETH floor" hint="The same $1.00, expressed in wei per AMPS wei at the ETH/USD price the proposal carried and the feed registry cross-checked.">
          <Value unavailable={floorQ96ToWholeX18({...(genesis.floorEthQ96 !== undefined ? {floorQ96: genesis.floorEthQ96} : {}), currencyDecimals: 18}) === undefined}>
            {(() => {
              const x18 = floorQ96ToWholeX18({
                ...(genesis.floorEthQ96 !== undefined ? {floorQ96: genesis.floorEthQ96} : {}),
                currencyDecimals: 18,
              })
              return x18 === undefined ? null : `${Number(x18) / 1e18} ETH per AMPS`
            })()}
          </Value>
        </FieldRow>
      </RowGroup>

      {/* The auctions this panel settles are not ours; the footer says whose they are. */}
      <PoweredByUniswap className="mt-6" data-testid="powered-by-uniswap-settlement" />
    </section>
  )
}

/** Everything the settle button needs, lifted so this file holds no wagmi and no transaction state. */
export interface SettleAction {
  phase: TxPhase
  blockedReason?: string
  error: SurfacedError | null
  hash?: `0x${string}`
  explorerUrl?: string | null
  onClick: () => void
}
