// SPDX-License-Identifier: MIT
import {render, screen} from '@testing-library/react'
import {describe, expect, it} from 'vitest'

import {
  BurnHistoryTable,
  GateStatusTable,
  LadderFillPanel,
  NavHistoryPanel,
  SupplyBreakdown,
  VaultHeadline,
} from '@/components/surfaces/vault-panels'

const WAD = 10n ** 18n

describe('VaultHeadline', () => {
  it('shows NAV, reference, market price and the premium as numbers', () => {
    render(
      <VaultHeadline
        navPerShareX18={WAD}
        pRefX18={1_120_000_000_000_000_000n}
        pMktX18={1_150_000_000_000_000_000n}
        premiumX18={120_000_000_000_000_000n}
        totalAssetsUsd18={5_000n * WAD}
        checkpointAgeSeconds={30}
      />,
    )
    expect(screen.getByText('$1.0000')).toBeInTheDocument()
    expect(screen.getByText('+12.00%')).toBeInTheDocument()
    expect(screen.getByText(/Disclosure only/i)).toBeInTheDocument()
  })

  it('renders a market price of zero as "not enough history yet", not as zero', () => {
    render(<VaultHeadline navPerShareX18={WAD} pMktX18={0n} />)
    expect(screen.getByLabelText(/Not enough observation history yet/)).toBeInTheDocument()
  })
})

describe('SupplyBreakdown', () => {
  it('derives circulating from total less inventory and vesting', () => {
    render(<SupplyBreakdown totalSupply={100n * WAD} inventory={40n * WAD} vesting={10n * WAD} staked={5n * WAD} />)
    expect(screen.getByText('50')).toBeInTheDocument()
  })

  it('leaves circulating unavailable when a component is missing', () => {
    const {container} = render(<SupplyBreakdown totalSupply={100n * WAD} />)
    expect(container.querySelectorAll('[data-unavailable="true"]').length).toBeGreaterThan(0)
  })
})

describe('GateStatusTable', () => {
  it('shows the gate and session per pool, and says no gate stops a swap or a redemption', () => {
    render(
      <GateStatusTable
        rows={[
          {poolId: '0x01', symbol: 'WETH', gateState: 0, session: 0, feedStale: false, corporateFreeze: false},
          {poolId: '0x02', symbol: 'NVDA', gateState: 1, session: 3, feedStale: true, corporateFreeze: true},
        ]}
      />,
    )
    expect(screen.getByTestId('gate-row-WETH')).toHaveTextContent('GREEN')
    const nvda = screen.getByTestId('gate-row-NVDA')
    expect(nvda).toHaveTextContent('DEGRADED')
    expect(nvda).toHaveTextContent('Closed')
    expect(nvda).toHaveTextContent('Stale')
    expect(nvda).toHaveTextContent('Frozen')
    expect(screen.getByText(/No gate state stops a swap or a redemption/i)).toBeInTheDocument()
  })
})

describe('indexer-backed panels', () => {
  it('say the indexer is unavailable rather than drawing a flat line at zero', () => {
    render(<NavHistoryPanel unavailable reason="ECONNREFUSED" />)
    expect(screen.getByTestId('indexer-unavailable')).toHaveTextContent(/it is not zero/i)
  })

  it('do the same for the ladder and the burn history', () => {
    const {rerender} = render(<LadderFillPanel unavailable />)
    expect(screen.getByTestId('indexer-unavailable')).toBeInTheDocument()
    rerender(<BurnHistoryTable unavailable />)
    expect(screen.getByTestId('indexer-unavailable')).toBeInTheDocument()
  })

  it('draw a sparkline when the series is there', () => {
    render(
      <NavHistoryPanel
        points={[
          {timestamp: 1, navPerShareX18: '1000000000000000000', pRefX18: '1', pMktX18: '1', totalSupply: '1'},
          {timestamp: 2, navPerShareX18: '1010000000000000000', pRefX18: '1', pMktX18: '1', totalSupply: '1'},
        ]}
      />,
    )
    expect(screen.getByTestId('nav-history')).toBeInTheDocument()
    expect(screen.getByRole('img', {name: /NAV per share over time/i})).toBeInTheDocument()
  })

  it('render ladder cells with their proceeds', () => {
    render(
      <LadderFillPanel
        fills={[
          {
            poolId: '0x01',
            counter: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73',
            symbol: 'WETH',
            poolClass: 1,
            bidDepth: '2500',
            askInventory: '1662.5',
            rolloutWeightBps: 200,
            rolloutMovedToday: '0',
            cells: [
              {bucketIndex: 0, lowerTick: 0, upperTick: 60, above: true, amount: '100', liquidity: '5', proceeds: '12', filledFraction: 0.25, placedAt: 1},
            ],
          },
        ]}
      />,
    )
    expect(screen.getByTestId('ladder-fill')).toHaveTextContent('12')
    expect(screen.getByTestId('ladder-fill')).toHaveTextContent('25%')
    expect(screen.getByText(/entire bid under AMPS in this pool/i)).toBeInTheDocument()
  })
})
