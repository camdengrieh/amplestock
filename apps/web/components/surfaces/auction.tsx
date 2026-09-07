// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useBlockNumber, useReadContract, useSimulateContract} from 'wagmi'
import type {Address} from 'viem'

import {
  AuctionBookPanel,
  AuctionExplainer,
  AuctionHeadline,
  AuctionSchedule,
  MyBidsTable,
  PhaseTag,
  SettlementPanel,
  type UsdRate,
} from './auction-panels'
import {FieldRow} from '@/components/common/stat'
import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {TxButton, TxError, TxSuccess} from '@/components/common/tx'
import {Value} from '@/components/common/value'
import {AmountField} from '@/components/ledger/amount-field'
import {Callout, Kicker, RowGroup, SectionHead} from '@/components/ledger/primitives'
import {Label} from '@/components/ui/label'
import {Tabs, TabsList, TabsTrigger} from '@/components/ui/tabs'
import {useAuction, useMyBids, useRequiredDemand, useUsdgUsd, type AuctionState} from '@/hooks/use-auction'
import {useTx} from '@/hooks/use-tx'
import {ccaAbi} from '@/lib/abi/cca'
import {PHASE_LABEL, formatQ96Price, snapToTick, wholeX18ToQ96Price} from '@/lib/auction'
import {activeChainId, blockTimeSeconds} from '@/lib/chains'
import {contract} from '@/lib/contracts'
import {explorerTxUrl, genesisAuctions, hasAnyGenesisAuction, type GenesisAuctionKey} from '@/lib/deployment'
import {formatAmount, parseAmount, shortAddress} from '@/lib/format'

const AUCTION_KEYS: readonly GenesisAuctionKey[] = ['usdg', 'eth']

const AUCTION_LABEL: Readonly<Record<GenesisAuctionKey, string>> = {
  usdg: 'AMPS / USDG',
  eth: 'AMPS / ETH',
}

/**
 * The genesis Continuous Clearing Auction.
 *
 * Amplestocks launches by selling its entry-pool AMPS tranche through Uniswap's CCA — one auction
 * against USDG and one against native ETH. Two things come out of it and both matter more than the
 * sale itself: the currency raised becomes the entry pools' bid liquidity, which is the first depth
 * under AMPS; and the final clearing price becomes the launch reference price the vault starts from.
 *
 * The surface reads everything and asserts nothing. Where a figure is only knowable through a
 * source that is absent — a USD conversion for the ETH leg, a graduation target the contract keeps
 * as an internal immutable — it renders the unavailable treatment with the reason, rather than
 * converting through an assumption or printing a target it cannot see.
 */
export function AuctionSurface() {
  const usdg = useAuction('usdg')
  const eth = useAuction('eth')
  const auctions = React.useMemo(() => [usdg, eth], [usdg, eth])
  const usdgRate = useUsdgUsd()
  const {data: blockNumber} = useBlockNumber({query: {refetchInterval: 12_000}})

  const ampsToken = contract('amps')
  const supply = useReadContract({
    ...(ampsToken ?? {address: undefined as unknown as Address, abi: [] as never}),
    functionName: 'totalSupply',
    query: {enabled: ampsToken !== undefined},
  })

  const configured = AUCTION_KEYS.filter((key) => genesisAuctions[key] !== undefined)

  if (!hasAnyGenesisAuction()) {
    return (
      <div className="space-y-10" data-testid="auction-surface">
        <SurfaceHeading
          kicker="Genesis"
          title="Auction"
          lede="The entry-pool AMPS tranche is sold through a Continuous Clearing Auction. The currency raised becomes the entry pools’ bid liquidity, and the final clearing price becomes the launch reference price."
        />
        <NotDeployed what="The genesis auction" />
        <AuctionExplainer />
      </div>
    )
  }

  return (
    <div className="space-y-14" data-testid="auction-surface">
      <SurfaceHeading
        kicker="Genesis"
        title="Auction"
        lede="The entry-pool AMPS tranche is sold through a Continuous Clearing Auction — one uniform clearing price, a fixed per-block issuance schedule, and a full refund if it does not graduate."
      />

      <Callout
        title="What this auction decides"
        lead="Two things, and neither of them is a valuation."
        data-testid="auction-outcome-note"
      >
        <p>
          The currency raised becomes the entry pools’ bid liquidity: the first depth under AMPS, placed by the vault as
          a static ladder and the only thing anyone can sell into. The final clearing price becomes the launch reference
          price the vault starts from.
        </p>
        <p>
          Everything on this page is read from the auction contract as of its last checkpoint.{' '}
          <code className="font-mono">checkpoint()</code> is a write rather than a view, so a price here is as fresh as
          the last block somebody paid to advance it to — the block is printed next to the price.
        </p>
      </Callout>

      {configured.map((key) => (
        <AuctionPanel
          key={key}
          auction={key === 'usdg' ? usdg : eth}
          label={AUCTION_LABEL[key]}
          {...(blockNumber !== undefined ? {blockNumber} : {})}
          usd={
            key === 'usdg'
              ? ({
                  ...(usdgRate.answer !== undefined ? {answer: usdgRate.answer} : {}),
                  ...(usdgRate.answerDecimals !== undefined ? {answerDecimals: usdgRate.answerDecimals} : {}),
                } satisfies UsdRate)
              : ({reason: 'No ETH/USD feed is configured for this chain, so this leg is priced in ether only'} satisfies UsdRate)
          }
        />
      ))}

      <SettlementPanel
        auctions={auctions.filter((a) => a.address !== undefined)}
        usdgRate={{
          ...(usdgRate.answer !== undefined ? {answer: usdgRate.answer} : {}),
          ...(usdgRate.answerDecimals !== undefined ? {answerDecimals: usdgRate.answerDecimals} : {}),
        }}
        {...(supply.data !== undefined ? {ampsTotalSupply: supply.data as bigint} : {})}
      />

      <AuctionExplainer />
    </div>
  )
}

type PendingAction =
  | {kind: 'bid'}
  | {kind: 'exit'; bidId: bigint}
  | {kind: 'exitPartial'; bidId: bigint}
  | {kind: 'claim'; bidId: bigint}

/** One auction: headline, schedule, book, the bid form, and this wallet's own bids. */
export function AuctionPanel({
  auction,
  label,
  blockNumber,
  usd,
}: {
  auction: AuctionState
  label: string
  blockNumber?: bigint
  usd: UsdRate
}) {
  const {address, isConnected} = useAccount()
  const bids = useMyBids(auction)
  const nextTickDemand = useRequiredDemand(auction, auction.nextActiveTickQ96)
  const blockSeconds = blockTimeSeconds()

  const [amountText, setAmountText] = React.useState('')
  const [maxPriceText, setMaxPriceText] = React.useState('')
  const [action, setAction] = React.useState<PendingAction>({kind: 'bid'})

  const amount = auction.currencyDecimals !== undefined ? parseAmount(amountText, auction.currencyDecimals) : null

  // The bidder types a price in whole currency per whole AMPS; the contract wants Q96 on its own
  // tick grid. Snapping rounds *up*: a maximum rounded down would be a bid at a price the bidder
  // never agreed to, and nobody is charged their maximum anyway.
  const rawPriceX18 = parseAmount(maxPriceText, 18)
  const maxPriceQ96 = React.useMemo(() => {
    if (rawPriceX18 === null || rawPriceX18 <= 0n || auction.currencyDecimals === undefined) return undefined
    const q96 = wholeX18ToQ96Price({
      priceX18: rawPriceX18,
      tokenDecimals: auction.tokenDecimals,
      currencyDecimals: auction.currencyDecimals,
    })
    if (auction.floorPriceQ96 === undefined || auction.tickSpacingQ96 === undefined) return undefined
    return snapToTick({
      priceQ96: q96,
      floorPriceQ96: auction.floorPriceQ96,
      tickSpacingQ96: auction.tickSpacingQ96,
    })
  }, [rawPriceX18, auction.currencyDecimals, auction.tokenDecimals, auction.floorPriceQ96, auction.tickSpacingQ96])

  const aboveMax =
    maxPriceQ96 !== undefined && auction.maxBidPriceQ96 !== undefined && maxPriceQ96 > auction.maxBidPriceQ96

  const bidReady =
    auction.address !== undefined &&
    address !== undefined &&
    amount !== null &&
    amount > 0n &&
    maxPriceQ96 !== undefined &&
    !aboveMax &&
    auction.phase === 'live'

  const simulation = useSimulateContract(
    action.kind === 'bid'
      ? {
          ...(auction.address ? {address: auction.address} : {}),
          abi: ccaAbi,
          functionName: 'submitBid',
          ...(bidReady
            ? {
                args: [
                  maxPriceQ96 as bigint,
                  amount as bigint,
                  address as Address,
                  // The previous-tick hint. The next active tick is the cheapest correct hint the
                  // surface can give without walking the book; the contract validates it and the
                  // four-argument overload exists for when it cannot be supplied at all.
                  auction.nextActiveTickQ96 ?? (auction.floorPriceQ96 as bigint),
                  '0x' as const,
                ] as const,
              }
            : {}),
          ...(auction.currencyIsNative && amount !== null ? {value: amount} : {}),
          query: {enabled: bidReady && isConnected},
        }
      : action.kind === 'claim'
        ? {
            ...(auction.address ? {address: auction.address} : {}),
            abi: ccaAbi,
            functionName: 'claimTokens',
            args: [action.bidId] as const,
            query: {enabled: auction.address !== undefined && isConnected},
          }
        : action.kind === 'exit'
          ? {
              ...(auction.address ? {address: auction.address} : {}),
              abi: ccaAbi,
              functionName: 'exitBid',
              args: [action.bidId] as const,
              query: {enabled: auction.address !== undefined && isConnected},
            }
          : {
              ...(auction.address ? {address: auction.address} : {}),
              abi: ccaAbi,
              functionName: 'exitPartiallyFilledBid',
              // The two hints are checkpoint blocks the caller is expected to supply. Zero asks the
              // contract to treat the bid as partially filled at the end of the auction, which is
              // the case this surface can identify without indexing every checkpoint.
              args: [action.bidId, 0n, 0n] as const,
              query: {enabled: auction.address !== undefined && isConnected},
            },
  )

  const blockedReason = !isConnected
    ? 'Connect a wallet to simulate this.'
    : auction.address === undefined
      ? 'This auction has no address on this chain.'
      : action.kind !== 'bid'
        ? undefined
        : auction.phase === 'upcoming'
          ? 'The auction has not started yet.'
          : auction.phase !== 'live'
            ? 'The auction has ended — bids are closed, exits are open.'
            : auction.currencyDecimals === undefined
              ? 'The auction currency could not be read, so an amount cannot be scaled.'
              : amount === null || amount <= 0n
                ? 'Enter an amount.'
                : maxPriceQ96 === undefined
                  ? 'Enter a maximum price. The tick grid could not be read, so it cannot be snapped yet.'
                  : aboveMax
                    ? 'That maximum is above the highest price this tranche can clear at.'
                    : undefined

  const tx = useTx({
    simulation: simulation.data,
    simulationError: simulation.error,
    isSimulating: simulation.isLoading,
    ...(blockedReason ? {blockedReason} : {}),
  })

  const snapped =
    maxPriceQ96 !== undefined && auction.currencyDecimals !== undefined
      ? formatQ96Price({
          priceQ96: maxPriceQ96,
          tokenDecimals: auction.tokenDecimals,
          currencyDecimals: auction.currencyDecimals,
          symbol: auction.currencySymbol ?? '',
        })
      : null

  return (
    <section data-testid={`auction-${auction.key}`}>
      <div className="flex flex-wrap items-end justify-between gap-x-8 gap-y-3">
        <div>
          <Kicker className="mb-2">Genesis auction</Kicker>
          <h2 className="ledger-section-title">{label}</h2>
        </div>
        <div className="flex items-baseline gap-4">
          <PhaseTag phase={auction.phase} />
          <span className="ledger-value text-dim">
            <Value unavailable={!auction.address} {...(auction.address ? {title: auction.address} : {})}>
              {auction.address ? shortAddress(auction.address) : null}
            </Value>
          </span>
        </div>
      </div>

      <div className="mt-8">
        <AuctionHeadline
          auction={auction}
          {...(blockNumber !== undefined ? {blockNumber} : {})}
          {...(blockSeconds !== undefined ? {blockTimeSeconds: blockSeconds} : {})}
          usd={usd}
        />
      </div>

      <div className="mt-12 grid gap-x-14 gap-y-12 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
        <div>
          <Tabs value={action.kind === 'bid' ? 'bid' : 'settle'} onValueChange={(v) => v === 'bid' && setAction({kind: 'bid'})}>
            <TabsList>
              <TabsTrigger value="bid" data-testid={`auction-tab-bid-${auction.key}`}>
                Bid
              </TabsTrigger>
              <TabsTrigger value="settle" disabled={action.kind === 'bid'} data-testid={`auction-tab-settle-${auction.key}`}>
                Settle
              </TabsTrigger>
            </TabsList>
          </Tabs>

          {action.kind === 'bid' ? (
            <>
              <Label htmlFor={`amount-${auction.key}`} className="mb-2 mt-[26px]">
                Amount to commit ({auction.currencySymbol ?? '—'})
              </Label>
              <AmountField
                id={`amount-${auction.key}`}
                data-testid={`auction-amount-${auction.key}`}
                value={amountText}
                onChange={setAmountText}
                unit={auction.currencySymbol ?? ''}
              />

              <Label htmlFor={`price-${auction.key}`} className="mb-2 mt-[26px]">
                Maximum price ({auction.currencySymbol ?? '—'} per AMPS)
              </Label>
              <AmountField
                id={`price-${auction.key}`}
                data-testid={`auction-price-${auction.key}`}
                value={maxPriceText}
                onChange={setMaxPriceText}
                unit={auction.currencySymbol ?? ''}
              />

              <div className="mt-6">
                <RowGroup label="What you would sign for" rule="rule">
                  <FieldRow
                    label="Snapped to the tick grid"
                    hint="Rounded up: a maximum is a ceiling, and nobody pays theirs."
                  >
                    <Value unavailable={snapped === null}>{snapped}</Value>
                  </FieldRow>
                  <FieldRow
                    label="How the currency is taken"
                    hint={
                      auction.currencyIsNative
                        ? 'Native ETH, sent as the call’s value rather than pulled through an approval.'
                        : 'An ERC-20, pulled from your wallet — it needs an allowance before the bid can be simulated.'
                    }
                  >
                    <span className="text-dim">{auction.currencyIsNative ? 'Call value' : 'Allowance'}</span>
                  </FieldRow>
                </RowGroup>
              </div>
            </>
          ) : (
            <div className="mt-[26px]">
              <Callout lead={`Settling bid #${action.bidId.toString()}.`}>
                <p>
                  Exiting settles the fill and the refund; claiming moves the filled AMPS to the bid owner and can be
                  called by anybody.
                </p>
              </Callout>
            </div>
          )}

          <div className="mt-[26px]">
            <TxButton
              phase={tx.phase}
              label={
                action.kind === 'bid'
                  ? 'Submit bid'
                  : action.kind === 'claim'
                    ? `Claim #${action.bidId.toString()}`
                    : `Exit #${action.bidId.toString()}`
              }
              {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
              onClick={() => void tx.send()}
              data-testid={`auction-submit-${auction.key}`}
            />
          </div>
          <div className="mt-5 space-y-6">
            {action.kind !== 'bid' ? (
              <button
                type="button"
                className="ledger-nav text-dim underline decoration-rule underline-offset-[3px] hover:text-ink hover:decoration-ink"
                onClick={() => setAction({kind: 'bid'})}
              >
                Back to bidding
              </button>
            ) : null}
            <TxError error={tx.error} />
            {tx.hash ? <TxSuccess hash={tx.hash} explorerUrl={explorerTxUrl(activeChainId, tx.hash)} /> : null}
          </div>
        </div>

        <div className="space-y-9">
          <AuctionSchedule
            auction={auction}
            {...(blockNumber !== undefined ? {blockNumber} : {})}
            {...(blockSeconds !== undefined ? {blockTimeSeconds: blockSeconds} : {})}
          />
          <AuctionBookPanel
            auction={auction}
            {...(nextTickDemand.requiredDemand !== undefined ? {requiredDemand: nextTickDemand.requiredDemand} : {})}
          />
        </div>
      </div>

      <div className="mt-[52px]">
        <SectionHead
          title="Your bids"
          note="A bid must be exited before its tokens can be claimed, and a bid at exactly the clearing price exits through the partial-fill path. A refund is settled by the exit, not by a separate call."
          aside={PHASE_LABEL[auction.phase]}
        />
        <div className="mt-5">
          <MyBidsTable
            auction={auction}
            bids={bids.bids}
            unavailable={bids.unavailable}
            {...(bids.reason ? {reason: bids.reason} : {})}
            hasAccount={bids.hasAccount}
            onExit={(bidId) => setAction({kind: 'exit', bidId})}
            onExitPartial={(bidId) => setAction({kind: 'exitPartial', bidId})}
            onClaim={(bidId) => setAction({kind: 'claim', bidId})}
          />
        </div>
      </div>

      <RowGroup label="Terms of this auction" className="mt-11">
        <FieldRow label="Total on offer in this auction" hint="AMPS transferred to the auction at deployment">
          <Value unavailable={auction.totalSupply === undefined}>
            {auction.totalSupply !== undefined ? `${formatAmount(auction.totalSupply, 18)} AMPS` : null}
          </Value>
        </FieldRow>
        <FieldRow label="Graduation target" hint="The minimum the auction must raise to sell anything at all">
          <Value
            unavailable
            reason="The auction keeps its required minimum as an internal immutable and exposes no getter for it — isGraduated() is the only on-chain answer"
          />
        </FieldRow>
        <FieldRow label="Funds recipient" hint="Where the raised currency goes when the auction is swept — the vault, so it becomes bid liquidity">
          <Value unavailable={!auction.fundsRecipient} {...(auction.fundsRecipient ? {title: auction.fundsRecipient} : {})}>
            {auction.fundsRecipient ? shortAddress(auction.fundsRecipient) : null}
          </Value>
        </FieldRow>
        <FieldRow label="Unsold tokens go to" hint="Any AMPS the auction does not sell is swept back here">
          <Value unavailable={!auction.tokensRecipient} {...(auction.tokensRecipient ? {title: auction.tokensRecipient} : {})}>
            {auction.tokensRecipient ? shortAddress(auction.tokensRecipient) : null}
          </Value>
        </FieldRow>
      </RowGroup>
    </section>
  )
}
