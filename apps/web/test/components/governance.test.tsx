// SPDX-License-Identifier: MIT
import {render, screen} from '@testing-library/react'
import {describe, expect, it} from 'vitest'

import {
  ConstituentTable,
  ParameterTable,
  PointerTable,
  TimelockQueue,
  type ParameterRow,
  type PointerRow,
} from '@/components/surfaces/governance'
import {formatBps} from '@/lib/format'

const rows: ParameterRow[] = [
  {name: 'redeemFeeBps', live: 100, format: formatBps, band: {min: 0, max: 500}, delay: '48 h', note: 'Kept by the vault.'},
  {name: 'ampsFeeBps', format: formatBps, band: {min: 100, max: 600}, delay: '48 h', note: 'Read live from the hook.'},
]

describe('ParameterTable', () => {
  it('puts the live value next to the band that bounds it', () => {
    render(<ParameterTable rows={rows} />)
    const row = screen.getByTestId('param-redeemFeeBps')
    expect(row).toHaveTextContent('1.00%')
    expect(row).toHaveTextContent('0.00% – 5.00%')
    expect(row).toHaveTextContent('48 h')
  })

  it('renders an unread value as unavailable rather than as zero', () => {
    render(<ParameterTable rows={rows} />)
    const row = screen.getByTestId('param-ampsFeeBps')
    expect(row.querySelector('[data-unavailable="true"]')).not.toBeNull()
  })
})

const pointers: PointerRow[] = [
  {
    name: 'AmpsHook.router',
    address: '0x00000000000000000000000000000000000000A1',
    delay: '7 d',
    note: 'The whole of the pass-through exemption. The zero address withdraws it.',
  },
  {name: 'AmpsHook.feePolicy', delay: '7 d', note: 'The dynamic component. It cannot move funds.'},
]

describe('PointerTable', () => {
  it('names the router pointer, its address and its seven-day class', () => {
    render(<PointerTable rows={pointers} />)
    const row = screen.getByTestId('pointer-AmpsHook.router')
    expect(row).toHaveTextContent('7 d')
    expect(row).toHaveTextContent(/pass-through exemption/i)
  })

  it('renders an unread pointer as unavailable rather than as the zero address', () => {
    render(<PointerTable rows={pointers} />)
    const row = screen.getByTestId('pointer-AmpsHook.feePolicy')
    expect(row.querySelector('[data-unavailable="true"]')).not.toBeNull()
    expect(row).not.toHaveTextContent('0x0000')
  })
})

describe('ConstituentTable', () => {
  it('shows the lifecycle status of each name', () => {
    render(
      <ConstituentTable
        capBps={3_000}
        floorBps={166}
        rows={[
          {id: 1, symbol: 'AAPL', status: 1, targetWeightBps: 500, rolloutWeightBps: 200, freezeUntil: 0},
          {id: 2, symbol: 'GME', status: 2, targetWeightBps: 0, rolloutWeightBps: 0, freezeUntil: 0},
          {id: 3, symbol: 'TSLA', status: 3, targetWeightBps: 400, rolloutWeightBps: 0, freezeUntil: 99},
        ]}
      />,
    )
    expect(screen.getByTestId('constituent-1')).toHaveTextContent('ACTIVE')
    expect(screen.getByTestId('constituent-2')).toHaveTextContent('RETIRED')
    expect(screen.getByTestId('constituent-3')).toHaveTextContent('FROZEN')
  })

  it('says a frozen name is still an index member and a retired one is not', () => {
    render(<ConstituentTable rows={[]} />)
    expect(screen.getByText(/frozen name is still an index member/i)).toBeInTheDocument()
    expect(screen.getByText(/exit market/i)).toBeInTheDocument()
  })
})

describe('TimelockQueue', () => {
  it('refuses to imply the queue is empty when it cannot see it', () => {
    render(<TimelockQueue address="0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99" />)
    expect(screen.getByText(/Pending operations are not listed/i)).toBeInTheDocument()
    expect(screen.getByText(/would be a claim this page cannot make/i)).toBeInTheDocument()
  })

  it('lists operations when it has them', () => {
    render(<TimelockQueue address="0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99" operations={[{id: '0xabc', readyAt: 1_800_000_000}]} />)
    expect(screen.getByText('0xabc')).toBeInTheDocument()
    expect(screen.queryByText(/Pending operations are not listed/i)).not.toBeInTheDocument()
  })

  it('states what governance cannot do to redemption', () => {
    render(<TimelockQueue />)
    expect(screen.getByText(/No governance path can block redemption/i)).toBeInTheDocument()
  })
})
