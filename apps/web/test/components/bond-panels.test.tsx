// SPDX-License-Identifier: MIT
import {render, screen} from '@testing-library/react'
import {describe, expect, it} from 'vitest'

import {BondBoard, BondPositions, BondQuotePanel, type BoardRow} from '@/components/surfaces/bond'
import type {BondQuote} from '@/lib/bonds'
import {NVDA} from '../fixtures'

const WAD = 10n ** 18n
const OK = `0x${'0'.repeat(64)}` as const

function quote(overrides: Partial<BondQuote> = {}): BondQuote {
  return {ampsOut: 8n * WAD, qX18: 8n * WAD, discountBps: 1_250, floorBinding: false, capacityLeft: 50n * WAD, reason: OK, ...overrides}
}

const row: BoardRow = {
  marketId: 3,
  symbol: 'NVDA',
  collateral: NVDA,
  decimals: 18,
  open: true,
  discountBps: 1_250,
  qX18: 8n * WAD,
  floorBinding: false,
  capacityLeft: 50n * WAD,
  ampsOut: 8n * WAD,
  reason: OK,
  vestSeconds: 12 * 3_600,
}

describe('BondQuotePanel', () => {
  it('shows minAmpsOut as exactly the quoted amount', () => {
    render(<BondQuotePanel quote={quote()} amountIn={WAD} decimals={18} symbol="NVDA" />)
    const cells = screen.getAllByText('8 AMPS')
    // "You receive" and "minAmpsOut" are the same number, and that is the point.
    expect(cells.length).toBeGreaterThanOrEqual(2)
  })

  it('explains why there is no slippage setting', () => {
    render(<BondQuotePanel quote={quote()} amountIn={WAD} decimals={18} symbol="NVDA" />)
    expect(screen.getByText(/reduces the AMPS issued, never the collateral taken/i)).toBeInTheDocument()
  })

  it('makes a capacity clamp loud, because the collateral is taken in full either way', () => {
    render(<BondQuotePanel quote={quote({ampsOut: 3n * WAD})} amountIn={WAD} decimals={18} symbol="NVDA" />)
    const alert = screen.getByTestId('capacity-clamp')
    expect(alert).toHaveTextContent(/exceeds the market’s remaining capacity/i)
    expect(alert).toHaveTextContent(/settles the whole deposit/i)
    expect(alert).toHaveTextContent(/8 AMPS/)
  })

  it('does not cry clamp when the whole deposit prices through', () => {
    render(<BondQuotePanel quote={quote()} amountIn={WAD} decimals={18} symbol="NVDA" />)
    expect(screen.queryByTestId('capacity-clamp')).not.toBeInTheDocument()
  })

  it('says whether the price came from the market discount or from the NAV floor', () => {
    const {rerender} = render(<BondQuotePanel quote={quote()} amountIn={WAD} decimals={18} symbol="NVDA" />)
    expect(screen.getByText('Market discount')).toBeInTheDocument()
    rerender(<BondQuotePanel quote={quote({floorBinding: true})} amountIn={WAD} decimals={18} symbol="NVDA" />)
    expect(screen.getByText('NAV floor')).toBeInTheDocument()
  })
})

describe('BondBoard', () => {
  it('shows a closed market rather than hiding it', () => {
    render(<BondBoard rows={[row, {...row, marketId: 4, symbol: 'AAPL', open: false, qX18: 0n, ampsOut: 0n}]} />)
    expect(screen.getByTestId('bond-row-NVDA')).toHaveTextContent('Open')
    expect(screen.getByTestId('bond-row-AAPL')).toHaveTextContent('Closed')
  })

  it('renders an unpriceable market’s price as unavailable rather than as zero', () => {
    render(<BondBoard rows={[{...row, qX18: 0n, open: false, ampsOut: 0n, discountBps: 0}]} />)
    const cells = screen.getByTestId('bond-row-NVDA').querySelectorAll('[data-unavailable="true"]')
    expect(cells.length).toBeGreaterThan(0)
  })
})

describe('BondPositions', () => {
  it('computes claimable from the linear vest', () => {
    render(
      <BondPositions
        now={1_000 + 6 * 3_600}
        positions={[{positionId: 0, marketId: 3, symbol: 'NVDA', principal: 12n * WAD, claimed: 0n, start: 1_000, vestSeconds: 12 * 3_600}]}
      />,
    )
    const row0 = screen.getByTestId('position-0')
    expect(row0).toHaveTextContent('12')
    expect(row0).toHaveTextContent('6')
    expect(row0).toHaveTextContent('50%')
    expect(screen.getByTestId('claim-0')).toBeEnabled()
  })

  it('disables claim when nothing has vested yet', () => {
    render(
      <BondPositions
        now={1_000}
        positions={[{positionId: 0, marketId: 3, symbol: 'NVDA', principal: 12n * WAD, claimed: 0n, start: 1_000, vestSeconds: 12 * 3_600}]}
      />,
    )
    expect(screen.getByTestId('claim-0')).toBeDisabled()
  })

  it('says so when there is nothing to show', () => {
    render(<BondPositions now={0} positions={[]} />)
    expect(screen.getByText('No bond positions.')).toBeInTheDocument()
  })
})
