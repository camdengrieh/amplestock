// SPDX-License-Identifier: MIT
import {render, screen} from '@testing-library/react'
import {describe, expect, it} from 'vitest'

import {
  BurnHistoryTable,
  FeeFlowPanel,
  GateStatusTable,
  LadderFillPanel,
  NavHistoryPanel,
  PolDepthTable,
  SupplyBreakdown,
  VaultHeadline,
  burnReasonLabel,
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
    render(<SupplyBreakdown totalSupply={100n * WAD} inventory={40n * WAD} vesting={10n * WAD} />)
    expect(screen.getByText('50')).toBeInTheDocument()
  })

  it('has no staked bucket at all — revision 6 removed staking', () => {
    const {container} = render(<SupplyBreakdown totalSupply={100n * WAD} inventory={40n * WAD} vesting={10n * WAD} />)
    expect(container.textContent).not.toMatch(/xAMPS|staked/i)
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
          {
            blockNumber: '1',
            timestamp: '1',
            navPerShareX18: '1000000000000000000',
            totalAssetsUsd18: '1',
            totalSupply: '1',
            navChangeBps: 0,
          },
          {
            blockNumber: '2',
            timestamp: '2',
            navPerShareX18: '1010000000000000000',
            totalAssetsUsd18: '1',
            totalSupply: '1',
            navChangeBps: 100,
          },
        ]}
      />,
    )
    expect(screen.getByTestId('nav-history')).toBeInTheDocument()
    expect(screen.getByRole('img', {name: /NAV per share over time/i})).toBeInTheDocument()
  })

  it('render the pool rows from /api/pools, which carries totals and not cells', () => {
    render(<LadderFillPanel pools={[poolRow()]} />)
    const panel = screen.getByTestId('ladder-fill')
    // Bid depth and ask inventory come from the pool's own ladder totals…
    expect(panel).toHaveTextContent('2500')
    expect(panel).toHaveTextContent('1662')
    // …and the fill is the indexer's `ladderFillBps`, not a mean over an array this route omits.
    expect(panel).toHaveTextContent('25%')
    expect(screen.getByText(/entire bid under AMPS in this pool/i)).toBeInTheDocument()
  })

  it('render the open pool’s cells from the ladder detail, and say so while it loads', () => {
    const {rerender} = render(<LadderFillPanel pools={[poolRow()]} openPoolId={'0x01'} />)
    expect(screen.getByTestId('ladder-fill')).toHaveTextContent(/Loading this pool’s cells/i)
    rerender(
      <LadderFillPanel
        pools={[poolRow()]}
        openPoolId={'0x01'}
        detail={{
          pool: poolRow(),
          cells: [
            {
              bucketIndex: 0,
              tickLower: 0,
              tickUpper: 60,
              above: true,
              amount: '100',
              liquidity: '5',
              proceeds: '12',
              filledBps: 2_500,
              placedAt: '1',
            },
          ],
          totals: {ampsInLadder: '1662.5', counterInLadder: '2500', askCells: 1, bidCells: 0, fillBps: 2_500},
        }}
      />,
    )
    expect(screen.getByTestId('ladder-fill')).toHaveTextContent('12')
  })

  it('put the burn total and count under the table rather than only the rows', () => {
    render(
      <BurnHistoryTable
        history={{
          burns: [
            {
              blockNumber: '1',
              timestamp: '1800000000',
              txHash: '0xdead',
              amount: '5',
              reason: 'compound',
              reasonRaw: '0x00',
              poolId: null,
            },
          ],
          total: '5',
          count: 1,
        }}
      />,
    )
    const table = screen.getByTestId('burn-history')
    expect(table).toHaveTextContent('Fee burn')
    expect(table).toHaveTextContent('1 burns, 5 AMPS in total')
  })
})

describe('burnReasonLabel', () => {
  it('names the four reasons the vault actually emits', () => {
    expect(burnReasonLabel('buyback')).toMatch(/buyback/i)
    expect(burnReasonLabel('compound')).toBe('Fee burn')
    expect(burnReasonLabel('redeem')).toBe('Redemption')
    expect(burnReasonLabel('redeemInventory')).toMatch(/released inventory/i)
  })

  it('accepts the raw bytes32 as well as the decoded string', () => {
    const raw = `0x${Buffer.from('compound').toString('hex').padEnd(64, '0')}`
    expect(burnReasonLabel(raw)).toBe('Fee burn')
  })

  it('does not invent a label for a reason it has never seen', () => {
    expect(burnReasonLabel('somethingElse')).toBe('somethingElse')
  })
})

describe('FeeFlowPanel', () => {
  const summary = {
    feesAmpsTotal: '1000',
    feesCounterUsd18: (25n * 10n ** 18n).toString(),
    creatorPaidAmpsTotal: '10',
    creatorPaidCounterUsd18: (1n * 10n ** 18n).toString(),
    burnedTotal: '990',
  } as never

  it('keeps the two currencies apart instead of adding them into one number', () => {
    render(<FeeFlowPanel summary={summary} creatorFee={{currentBps: 50} as never} />)
    const panel = screen.getByTestId('fee-flow')
    expect(panel).toHaveTextContent('1000')
    expect(panel).toHaveTextContent('990')
    expect(panel).toHaveTextContent('$25.00')
    expect(panel).toHaveTextContent('0.50%')
  })

  it('says there is no staker slice at all', () => {
    render(<FeeFlowPanel summary={summary} />)
    expect(screen.getByTestId('fee-flow')).toHaveTextContent(/no staking/i)
  })

  it('is unavailable rather than zero when the indexer did not answer', () => {
    render(<FeeFlowPanel unavailable reason="ECONNREFUSED" />)
    expect(screen.getByTestId('indexer-unavailable')).toBeInTheDocument()
  })
})

/** A `/api/pools` row: ladder totals, no cells. */
function poolRow() {
  return {
    id: '0x01',
    counter: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73',
    counterSymbol: 'WETH',
    counterDecimals: 18,
    poolClass: 1,
    poolClassLabel: 'ENTRY',
    constituentId: 0,
    tickSpacing: 60,
    gridBaseTick: 0,
    buyFeeBps: 30,
    tick: 0,
    liquidity: '1',
    gateState: 0,
    gateStateLabel: 'GREEN',
    diverged: false,
    divergenceBps: 0,
    sellVolumeAmps: '0',
    buyVolumeAmps: '0',
    sellFeeAmps: '0',
    buyFeeCounter: '0',
    rotationCreditedAmps: '0',
    swapCount: 0,
    askCells: 1,
    bidCells: 0,
    ampsInLadder: '1662.5',
    counterInLadder: '2500',
    ladderFillBps: 2_500,
    realisedLvrUsd18: '0',
    feeRevenueUsd18: '0',
  } as const
}

describe('PolDepthTable — the number the plan says must be published', () => {
  const rows = [
    {
      poolId: '0x01',
      symbol: 'WETH',
      counterDecimals: 18,
      amps: 1_662n * WAD,
      counter: 2n * WAD,
      lastPlacementAt: 1_800_000_000,
    },
    {poolId: '0x02', symbol: 'NVDA', counterDecimals: 18},
  ]

  it('shows bid depth and ask inventory per pool, from the chain', () => {
    render(<PolDepthTable rows={rows} now={1_800_000_000} />)
    const weth = screen.getByTestId('pol-row-WETH')
    expect(weth).toHaveTextContent('2 WETH')
    expect(weth).toHaveTextContent('1,662')
    expect(screen.getByText(/entire bid under AMPS in this pool/i)).toBeInTheDocument()
  })

  it('renders a pool the valuer could not price as unavailable, not as zero', () => {
    // `amountsOf` returns (0, 0) both for an empty pool and for one it could not price; those are
    // different facts and only one of them is a number.
    render(<PolDepthTable rows={rows} now={1_800_000_000} />)
    const nvda = screen.getByTestId('pol-row-NVDA')
    expect(nvda.querySelectorAll('[data-unavailable="true"]').length).toBeGreaterThan(0)
    expect(nvda).not.toHaveTextContent('0 NVDA')
  })

  it('turns the last placement into a next-eligible hint through the cooldown', () => {
    const {rerender} = render(<PolDepthTable rows={rows} now={1_800_000_000 + 10} />)
    expect(screen.getByTestId('pol-row-WETH')).toHaveTextContent('in 50s')
    rerender(<PolDepthTable rows={rows} now={1_800_000_000 + 120} />)
    expect(screen.getByTestId('pol-row-WETH')).toHaveTextContent('now')
  })
})

describe('burnReasonLabel', () => {
  it('reads the redemption burn the vault now emits', () => {
    const redeem = `0x${Buffer.from('redeem').toString('hex').padEnd(64, '0')}`
    expect(burnReasonLabel(redeem)).toBe('Redemption')
  })

  it('reads the other reasons, and passes an unknown one through', () => {
    const buyback = `0x${Buffer.from('buyback').toString('hex').padEnd(64, '0')}`
    const other = `0x${Buffer.from('something').toString('hex').padEnd(64, '0')}`
    expect(burnReasonLabel(buyback)).toBe('High-water buyback')
    expect(burnReasonLabel(other)).toBe('something')
  })

  it('falls back to the raw prefix for an unreadable reason', () => {
    expect(burnReasonLabel(`0x${'00'.repeat(32)}`)).toBe('0x00000000')
  })
})
