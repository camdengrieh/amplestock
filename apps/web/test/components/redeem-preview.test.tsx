// SPDX-License-Identifier: MIT
import {render, screen} from '@testing-library/react'
import {describe, expect, it} from 'vitest'

import {RedeemPreviewTable} from '@/components/surfaces/redeem'
import {buildRedeemPreview} from '@/lib/redeem'
import {NVDA, USDG, WETH} from '../fixtures'

const WAD = 10n ** 18n

function preview() {
  return buildRedeemPreview({
    shares: WAD,
    redeemFeeBps: 100,
    inventoryBurned: 2n * WAD,
    tokens: [WETH, USDG, NVDA],
    amounts: [990_000_000_000_000_000n, 1_980_000_000_000_000_000n, 2_970_000_000_000_000_000n],
    meta: (token) => ({symbol: token === WETH ? 'WETH' : token === USDG ? 'USDG' : 'NVDA', decimals: 18}),
  })
}

describe('RedeemPreviewTable', () => {
  it('shows one line per asset — pro rata in everything, with no netting', () => {
    render(<RedeemPreviewTable preview={preview()} />)
    expect(screen.getByTestId('redeem-line-WETH')).toBeInTheDocument()
    expect(screen.getByTestId('redeem-line-USDG')).toBeInTheDocument()
    expect(screen.getByTestId('redeem-line-NVDA')).toBeInTheDocument()
  })

  it('breaks the fee out rather than folding it invisibly into the payout', () => {
    render(<RedeemPreviewTable preview={preview()} />)
    const line = screen.getByTestId('redeem-line-WETH')
    expect(line).toHaveTextContent('1') // gross
    expect(line).toHaveTextContent('0.99') // net
    expect(screen.getByText(/Fee \(1\.00%\)/)).toBeInTheDocument()
  })

  it('discloses the inventory AMPS burned alongside, and why supply falls by more', () => {
    render(<RedeemPreviewTable preview={preview()} />)
    expect(screen.getByText(/Inventory AMPS burned alongside/)).toBeInTheDocument()
    expect(screen.getByText(/total supply falls by more than you redeem/i)).toBeInTheDocument()
  })

  it('prompts rather than rendering an empty table', () => {
    render(<RedeemPreviewTable preview={null} />)
    expect(screen.getByText(/Enter an amount of AMPS/)).toBeInTheDocument()
  })
})
