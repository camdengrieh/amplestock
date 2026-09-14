// SPDX-License-Identifier: MIT
import {launchParameters} from '@amplestocks/config'
import {render, screen} from '@testing-library/react'
import {describe, expect, it} from 'vitest'

import {
  AuctionExplainer,
  AuctionHeadline,
  ClearingPriceHistory,
  MyBidsTable,
  PhaseTag,
  PublicBidBook,
  SettlementPanel,
} from '@/components/surfaces/auction-panels'
import type {AuctionState, BidRow} from '@/hooks/use-auction'
import type {GenesisState} from '@/hooks/use-genesis'
import type {AuctionBidRow, AuctionCheckpointRow} from '@/lib/indexer/types'
import {AMPS, USDG} from '../fixtures'

const WAD = 10n ** 18n
const Q96 = 1n << 96n

/** $1.00 per AMPS on the Q96 grid, at USDG's own 6 decimals — the auction's own scaling. */
const ONE_USDG_Q96 = (Q96 * 10n ** 6n) / WAD

function auction(overrides: Partial<AuctionState> = {}): AuctionState {
  return {
    key: 'usdg',
    address: '0x00000000000000000000000000000000000a000c',
    currency: USDG,
    currencyIsNative: false,
    currencySymbol: 'USDG',
    currencyDecimals: 6,
    token: AMPS,
    tokenDecimals: 18,
    totalSupply: 5_000n * WAD,
    startBlock: 12_000n,
    endBlock: 20_000n,
    claimBlock: 20_000n,
    clearingPriceQ96: ONE_USDG_Q96,
    floorPriceQ96: ONE_USDG_Q96,
    tickSpacingQ96: ONE_USDG_Q96 / 100n,
    currencyRaised: 5_000_000_000n,
    totalCleared: 5_000n * WAD,
    remainingSupply: 0n,
    isGraduated: true,
    lastCheckpointedBlock: 12_340n,
    cumulativeMps: 7_500_000,
    phase: 'live',
    isLoading: false,
    ...overrides,
  }
}

function checkpoint(block: string, priceQ96: bigint, leg = 'usdg'): AuctionCheckpointRow {
  return {
    auction: '0x00000000000000000000000000000000000a000c',
    leg,
    blockNumber: block,
    timestamp: '1800000000',
    txHash: `0x${'44'.repeat(32)}`,
    logIndex: 0,
    clearingPriceQ96: priceQ96.toString(),
    cumulativeMps: '2500000',
  }
}

function bid(overrides: Partial<AuctionBidRow> = {}): AuctionBidRow {
  return {
    auction: '0x00000000000000000000000000000000000a000c',
    leg: 'usdg',
    bidId: '7',
    owner: '0x00000000000000000000000000000000000b0001',
    maxPriceQ96: ((Q96 * 11n * 10n ** 5n) / WAD).toString(),
    amountQ96: ((2_500n * 10n ** 6n) << 96n).toString(),
    submittedBlock: '12100',
    submittedAt: '1800000000',
    txHash: `0x${'11'.repeat(32)}`,
    exitedBlock: '0',
    tokensFilled: '0',
    currencyRefunded: '0',
    claimedBlock: '0',
    claimedAmount: '0',
    ...overrides,
  }
}

describe('PhaseTag', () => {
  it('names every phase the auction can be in, rather than colouring it', () => {
    for (const [phase, label] of [
      ['upcoming', 'Not started'],
      ['live', 'Live'],
      ['ended', 'Ended — exit your bid'],
      ['claimable', 'Claimable'],
    ] as const) {
      const {unmount} = render(<PhaseTag phase={phase} />)
      expect(screen.getByText(label)).toBeInTheDocument()
      unmount()
    }
  })

  it('renders an undeployed auction as such rather than guessing a phase', () => {
    render(<PhaseTag phase="unknown" />)
    expect(screen.getByText('Not deployed')).toBeInTheDocument()
  })
})

describe('AuctionHeadline', () => {
  it('prints the clearing price in the auction’s own currency, off the Q96 grid', () => {
    render(<AuctionHeadline auction={auction()} usd={{}} />)
    const headline = screen.getByTestId('auction-headline-usdg')
    expect(headline).toHaveTextContent('USDG')
    expect(headline).toHaveTextContent('5,000 AMPS')
  })

  it('leaves the dollar column unavailable when there is no feed to convert with', () => {
    render(<AuctionHeadline auction={auction()} usd={{reason: 'No ETH/USD feed is configured'}} />)
    const headline = screen.getByTestId('auction-headline-usdg')
    expect(headline.querySelectorAll('[data-unavailable="true"]').length).toBeGreaterThan(0)
    expect(screen.getByLabelText(/No ETH\/USD feed is configured/)).toBeInTheDocument()
  })

  it('prints the block the price was checkpointed at rather than implying it is live', () => {
    render(<AuctionHeadline auction={auction()} usd={{}} />)
    expect(screen.getByTestId('auction-headline-usdg')).toHaveTextContent('12340')
  })

  it('says nothing about a price it could not read', () => {
    render(<AuctionHeadline auction={auction({clearingPriceQ96: undefined})} usd={{}} />)
    const headline = screen.getByTestId('auction-headline-usdg')
    expect(headline.querySelectorAll('[data-unavailable="true"]').length).toBeGreaterThan(0)
    expect(headline).not.toHaveTextContent('0.00 USDG')
  })
})

describe('AuctionExplainer', () => {
  it('credits Uniswap for the mechanism, because Amplestocks did not write it', () => {
    render(<AuctionExplainer />)
    const explainer = screen.getByTestId('auction-explainer')
    expect(explainer).toHaveTextContent('Uniswap CCA v2.1.0')
    expect(explainer).toHaveTextContent('Amplestocks did not write this auction')
    expect(explainer).toHaveTextContent('MIT-licensed')
  })

  it('states the four properties a bidder has to know before committing', () => {
    render(<AuctionExplainer />)
    const explainer = screen.getByTestId('auction-explainer')
    expect(explainer).toHaveTextContent('One price for everybody')
    expect(explainer).toHaveTextContent('Bidding early costs nothing')
    expect(explainer).toHaveTextContent('Above the clearing price, you fill in full')
    expect(explainer).toHaveTextContent('If it does not graduate, everything is refunded')
  })
})

describe('MyBidsTable', () => {
  const rows: readonly BidRow[] = [
    {bidId: 1n, maxPriceQ96: ONE_USDG_Q96, amount: 1_000_000_000n, startBlock: 12_050n, exitedBlock: 0n, tokensFilled: 0n, status: 'filling'},
    {bidId: 2n, maxPriceQ96: ONE_USDG_Q96, amount: 500_000_000n, startBlock: 12_060n, exitedBlock: 0n, tokensFilled: 0n, status: 'marginal'},
    {bidId: 3n, maxPriceQ96: ONE_USDG_Q96, amount: 250_000_000n, startBlock: 12_070n, exitedBlock: 12_900n, tokensFilled: 250n * WAD, status: 'exited'},
  ]

  it('asks for a wallet rather than claiming the wallet has no bids', () => {
    render(<MyBidsTable auction={auction()} bids={[]} hasAccount={false} />)
    expect(screen.getByTestId('bids-usdg')).toHaveTextContent('Connect a wallet')
  })

  it('distinguishes “the node did not answer” from “you have no bids”', () => {
    render(<MyBidsTable auction={auction()} bids={[]} hasAccount unavailable reason="timeout" />)
    const panel = screen.getByTestId('bids-usdg')
    expect(panel).toHaveTextContent('could not be listed')
    expect(panel).toHaveTextContent('timeout')
    expect(panel).toHaveTextContent('not the same as having no bids')
  })

  it('offers Exit while bidding is open only as a disabled control, never silently', () => {
    render(<MyBidsTable auction={auction({phase: 'live'})} bids={rows} hasAccount />)
    expect(screen.getByTestId('exit-bid-1')).toBeDisabled()
    // A bid at exactly the clearing price exits through the partial-fill path, and says so.
    expect(screen.getByTestId('exit-bid-2')).toHaveTextContent('Exit (partial)')
    // An exited bid is claimed, not exited again.
    expect(screen.getByTestId('claim-bid-3')).toBeInTheDocument()
  })

  it('enables the exit once the auction has ended, and the claim only once claimable', () => {
    const {unmount} = render(<MyBidsTable auction={auction({phase: 'ended'})} bids={rows} hasAccount />)
    expect(screen.getByTestId('exit-bid-1')).toBeEnabled()
    expect(screen.getByTestId('claim-bid-3')).toBeDisabled()
    unmount()
    render(<MyBidsTable auction={auction({phase: 'claimable'})} bids={rows} hasAccount />)
    expect(screen.getByTestId('claim-bid-3')).toBeEnabled()
  })
})

describe('ClearingPriceHistory', () => {
  it('draws the series the indexer served, and counts it', () => {
    render(
      <ClearingPriceHistory
        auction={auction()}
        checkpoints={[
          checkpoint('12100', (ONE_USDG_Q96 * 9n) / 10n),
          checkpoint('12200', (ONE_USDG_Q96 * 95n) / 100n),
          checkpoint('12340', ONE_USDG_Q96),
        ]}
      />,
    )
    const panel = screen.getByTestId('clearing-history-usdg')
    expect(panel).toHaveTextContent('3 checkpoints')
    expect(panel.querySelector('path')?.getAttribute('d')).toMatch(/^M0\.00,/)
    expect(panel).toHaveTextContent('USDG')
  })

  it('says the indexer is unavailable rather than drawing a flat line at zero', () => {
    render(<ClearingPriceHistory auction={auction()} unavailable reason="timeout" />)
    expect(screen.getByTestId('indexer-unavailable')).toHaveTextContent('it is not zero')
  })

  it('degrades the same way when no indexer is configured at all', () => {
    render(<ClearingPriceHistory auction={auction()} checkpoints={[checkpoint('1', ONE_USDG_Q96)]} configured={false} />)
    expect(screen.getByTestId('indexer-unavailable')).toBeInTheDocument()
  })
})

describe('PublicBidBook', () => {
  it('shows everybody’s bids, with the committed amount un-shifted from Q96', () => {
    render(<PublicBidBook auction={auction()} bids={[bid(), bid({bidId: '8', amountQ96: ((1_000n * 10n ** 6n) << 96n).toString()})]} />)
    const book = screen.getByTestId('bid-book-usdg')
    expect(book).toHaveTextContent('#7')
    expect(book).toHaveTextContent('2,500 USDG')
    expect(book).toHaveTextContent('1,000 USDG')
  })

  it('says the index has seen nothing, which is not the same as the auction having nothing', () => {
    render(<PublicBidBook auction={auction()} bids={[]} />)
    expect(screen.getByTestId('bid-book-usdg')).toHaveTextContent('a statement about the index')
  })

  it('degrades rather than showing an empty book when the indexer did not answer', () => {
    render(<PublicBidBook auction={auction()} unavailable reason="timeout" />)
    expect(screen.getByTestId('indexer-unavailable')).toBeInTheDocument()
  })
})

describe('SettlementPanel', () => {
  const settledGenesis: GenesisState = {
    address: '0x00000000000000000000000000000000000a000e',
    phase: 'settled',
    settled: true,
    p0X18: WAD,
    raisedUsd18: 10_000n * WAD,
    raisedUsdg: 5_000_000_000n,
    raisedWeth: 2n * WAD,
    unsoldAmps: 2_000n * WAD,
    ethUsdX18: 2_500n * WAD,
    isLoading: false,
    unavailable: false,
  }

  it('divides the raise by S₀, the whole genesis supply', () => {
    render(
      <SettlementPanel
        genesis={settledGenesis}
        auctions={[auction({phase: 'claimable'})]}
        usdgDecimals={6}
        genesisSupply={launchParameters.supply.s0}
      />,
    )
    const panel = screen.getByTestId('auction-settlement')
    // $10,000 over S₀ = 20,000, and the 100% premium that follows from it. Decision 14 stands.
    expect(panel).toHaveTextContent('$0.5000')
    expect(panel).toHaveTextContent('+100.00%')
    // …and it is a premium, never a discount.
    expect(panel).not.toHaveTextContent('discount')
  })

  it('credits Uniswap in the footer: the auctions it settles are not ours', () => {
    render(
      <SettlementPanel
        genesis={settledGenesis}
        auctions={[auction({phase: 'claimable'})]}
        genesisSupply={launchParameters.supply.s0}
      />,
    )
    expect(screen.getByTestId('powered-by-uniswap-settlement')).toHaveTextContent(
      'Powered by Uniswap Continuous Clearing Auction v2.1.0 · MIT',
    )
  })

  it('shows no launch at all when no leg graduated', () => {
    render(
      <SettlementPanel
        genesis={{...settledGenesis, phase: 'aborted', p0X18: 0n}}
        auctions={[auction({phase: 'ended'})]}
        genesisSupply={launchParameters.supply.s0}
      />,
    )
    const panel = screen.getByTestId('auction-settlement')
    expect(screen.getByTestId('genesis-phase-note')).toHaveTextContent('Did not graduate')
    expect(panel).toHaveTextContent('founders’ fallback seed')
    // No NAV, no premium, no P₀: there was no launch to report.
    expect(panel).not.toHaveTextContent('+100.00%')
  })

  it('leaves the launch figures unavailable rather than zero before settlement reads', () => {
    render(<SettlementPanel genesis={{...settledGenesis, raisedUsd18: undefined}} auctions={[auction({phase: 'ended'})]} />)
    const panel = screen.getByTestId('auction-settlement')
    expect(panel.querySelectorAll('[data-unavailable="true"]').length).toBeGreaterThan(0)
    expect(panel).not.toHaveTextContent('$0.0000')
  })
})
