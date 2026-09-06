// SPDX-License-Identifier: MIT
import {render, screen} from '@testing-library/react'
import {describe, expect, it} from 'vitest'

import {RotationCreditNote, SwapQuoteView} from '@/components/surfaces/swap-panels'
import {DegradedBit} from '@/lib/quoter'
import {poolQuote} from '../fixtures'

describe('SwapQuoteView', () => {
  it('shows the sell fee as a percentage', () => {
    render(<SwapQuoteView side="sell" quote={poolQuote()} amountOutDecimals={18} amountOutSymbol="WETH" />)
    expect(screen.getAllByText(/5\.00%/).length).toBeGreaterThan(0)
  })

  it('warns that the swap would revert when the hook refuses that direction', () => {
    render(<SwapQuoteView side="sell" quote={poolQuote({refuseSell: true})} amountOutDecimals={18} amountOutSymbol="WETH" />)
    const warning = screen.getByTestId('rail-warning')
    expect(warning).toHaveTextContent(/would revert/i)
    expect(warning).toHaveTextContent(/a smaller size does not help/i)
  })

  it('does not warn for the direction that improves the price', () => {
    render(<SwapQuoteView side="buy" quote={poolQuote({refuseSell: true})} amountOutDecimals={18} amountOutSymbol="AMPS" />)
    expect(screen.queryByTestId('rail-warning')).not.toBeInTheDocument()
  })

  it('suppresses the refusal warning when the hook read itself failed', () => {
    // `refuseBuy`/`refuseSell` are false whenever bit0 is set: the quoter fails open for display.
    render(
      <SwapQuoteView
        side="sell"
        quote={poolQuote({degraded: DegradedBit.HOOK, refuseSell: false})}
        amountOutDecimals={18}
        amountOutSymbol="WETH"
      />,
    )
    expect(screen.queryByTestId('rail-warning')).not.toBeInTheDocument()
    expect(screen.getByTestId('degraded-notice')).toBeInTheDocument()
  })

  it('renders a degraded market price as unavailable rather than as zero', () => {
    render(
      <SwapQuoteView
        side="buy"
        quote={poolQuote({degraded: DegradedBit.TWAP, pMktX18: 0n})}
        amountOutDecimals={18}
        amountOutSymbol="AMPS"
      />,
    )
    const unavailable = screen.getAllByLabelText(/Unavailable/)
    expect(unavailable.length).toBeGreaterThan(0)
    expect(screen.queryByText('$0.0000')).not.toBeInTheDocument()
  })

  it('renders the premium as a signed number with no adjective', () => {
    render(<SwapQuoteView side="buy" quote={poolQuote()} amountOutDecimals={18} amountOutSymbol="AMPS" />)
    expect(screen.getByText('+12.00%')).toBeInTheDocument()
  })

  it('shows the credit consumed when the sell is part of a rotation', () => {
    render(
      <SwapQuoteView
        side="sell"
        quote={poolQuote()}
        amountOutDecimals={18}
        amountOutSymbol="WETH"
        creditUsed={10n ** 18n}
        blendedBaseBps={30}
      />,
    )
    expect(screen.getByText(/Rotation credit used/)).toBeInTheDocument()
  })

  it('prompts for an amount before a quote exists', () => {
    render(<SwapQuoteView side="buy" quote={undefined} amountOutDecimals={18} amountOutSymbol="AMPS" />)
    expect(screen.getByText(/Enter an amount/)).toBeInTheDocument()
  })
})

describe('RotationCreditNote', () => {
  it('states the rule plainly, including that it never crosses a transaction', () => {
    render(<RotationCreditNote />)
    expect(screen.getByTestId('rotation-credit-note')).toHaveTextContent(/never carries across transactions/i)
    expect(screen.getByTestId('rotation-credit-note')).toHaveTextContent(/exact-output sell does not consume it/i)
  })
})
