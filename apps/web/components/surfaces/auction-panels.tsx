// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'

import {FieldRow, Stat, StatGrid} from '@/components/common/stat'
import {Value} from '@/components/common/value'
import {RowGroup, SectionHead} from '@/components/ledger/primitives'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Badge} from '@/components/ui/badge'
import {Button} from '@/components/ui/button'
import {Table, TableBody, TableCell, TableHead, TableHeader, TableRow} from '@/components/ui/table'
import type {AuctionState, BidRow} from '@/hooks/use-auction'
import {
  AUCTION_MPS,
  BID_STATUS_LABEL,
  BID_STATUS_NOTE,
  PHASE_LABEL,
  formatQ96Price,
  genesisPremiumBps,
  launchNavPerShareX18,
  q96PriceToWholeX18,
  secondsToBlock,
  toUsd18,
} from '@/lib/auction'
import {AUCTION_COPY} from '@/lib/copy'
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
 * Settlement: what the auction decided, and what it means for the protocol that follows it.
 *
 * Every figure is arithmetic on two numbers the auctions publish. The genesis premium in particular
 * is not a judgement: the auction sells only the entry-pool tranche, so NAV per share divides the
 * raised currency by the whole supply while a buyer paid the clearing price for one share, and the
 * ratio between them is exactly the ratio of total supply to tokens sold.
 */
export function SettlementPanel({
  auctions,
  usdgRate,
  ampsTotalSupply,
}: {
  auctions: readonly AuctionState[]
  usdgRate: UsdRate
  ampsTotalSupply?: bigint
}) {
  const settled = auctions.filter((a) => a.phase === 'ended' || a.phase === 'claimable')
  if (settled.length === 0 || settled.length !== auctions.length) return null

  const tokensSold = auctions.reduce<bigint | undefined>(
    (sum, a) => (sum === undefined || a.totalCleared === undefined ? undefined : sum + a.totalCleared),
    0n,
  )

  // Only the USDG auction can be valued in dollars: there is no ETH/USD feed in the reference book.
  const usdgAuction = auctions.find((a) => a.key === 'usdg')
  const raisedUsd18 =
    usdgAuction?.currencyRaised !== undefined && usdgAuction.currencyDecimals !== undefined
      ? toUsd18({
          priceX18: (usdgAuction.currencyRaised * 10n ** 18n) / 10n ** BigInt(usdgAuction.currencyDecimals),
          answer: usdgRate.answer,
          answerDecimals: usdgRate.answerDecimals,
        })
      : undefined

  const navX18 =
    raisedUsd18 !== undefined && ampsTotalSupply !== undefined
      ? launchNavPerShareX18({raisedUsd18, tokensSold: ampsTotalSupply})
      : undefined
  const premiumBps =
    ampsTotalSupply !== undefined && tokensSold !== undefined
      ? genesisPremiumBps({totalSupply: ampsTotalSupply, tokensSold})
      : undefined

  return (
    <section data-testid="auction-settlement">
      <SectionHead
        title="Settlement"
        note="Both auctions have ended. The final clearing price becomes the launch reference price, and the currency raised becomes the entry pools’ bid liquidity — the first depth under AMPS, placed by the vault as a ladder."
        aside="Both legs closed"
      />
      <StatGrid className="mt-7">
        <Stat
          label="Tokens sold"
          value={tokensSold !== undefined ? `${formatAmount(tokensSold, 18)} AMPS` : undefined}
          unavailable={tokensSold === undefined}
          hint="Across both auctions. The rest of the supply is protocol inventory and the team tranche."
        />
        <Stat
          label="Raised, in USD"
          value={raisedUsd18 !== undefined ? formatUsd18(raisedUsd18) : undefined}
          unavailable={raisedUsd18 === undefined}
          reason="Only the USDG leg has a price feed on this chain; the ETH leg is shown in ether"
          hint="The USDG leg, converted through its Chainlink answer. The ETH leg is not converted."
        />
        <Stat
          label="NAV per share at launch"
          value={navX18 !== undefined ? formatUsd18(navX18, 4) : undefined}
          unavailable={navX18 === undefined}
          hint="Raised divided by total supply. Arithmetic on the vault’s own balances, not a price."
        />
        <Stat
          label="Genesis premium"
          value={premiumBps !== undefined ? formatPremiumBps(premiumBps) : undefined}
          unavailable={premiumBps === undefined}
          hint="Total supply over tokens sold, less one. The auction sold the entry-pool tranche, not the whole supply, so a buyer’s price exceeds NAV per share by exactly this ratio."
        />
      </StatGrid>
    </section>
  )
}
