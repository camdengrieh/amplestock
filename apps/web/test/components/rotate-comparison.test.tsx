// SPDX-License-Identifier: MIT
import {render, screen} from '@testing-library/react'
import {describe, expect, it} from 'vitest'

import {RotationComparisonPanel, compareRotation} from '@/components/surfaces/rotate'
import {bpsToPips} from '@/lib/fees'

const WAD = 10n ** 18n

describe('compareRotation', () => {
  it('prices hop 2 at the destination pool’s buy fee when the credit covers it', () => {
    const c = compareRotation({hop1BuyFeeBps: 5, hop2BuyFeeBps: 5, sellFeeBps: 500, ampsFromHop1: WAD})
    expect(c.hop2BaseBpsRotated).toBe(5)
    expect(c.hop2BaseBpsSeparate).toBe(500)
    expect(c.savedPips).toBe(bpsToPips(495))
  })

  it('never claims a saving larger than the sell fee itself', () => {
    const c = compareRotation({hop1BuyFeeBps: 30, hop2BuyFeeBps: 30, sellFeeBps: 100, ampsFromHop1: WAD})
    expect(c.savedPips).toBe(bpsToPips(70))
    expect(c.savedPips).toBeLessThanOrEqual(bpsToPips(100))
  })
})

describe('RotationComparisonPanel', () => {
  const comparison = compareRotation({hop1BuyFeeBps: 5, hop2BuyFeeBps: 5, sellFeeBps: 500, ampsFromHop1: WAD})

  it('puts the credited and uncredited second hop side by side', () => {
    render(<RotationComparisonPanel comparison={comparison} outSymbol="AAPL" degraded={0} />)
    expect(screen.getByText('One transaction, through AMPS')).toBeInTheDocument()
    expect(screen.getByText('The same two swaps, separately')).toBeInTheDocument()
    expect(screen.getByText('4.95%')).toBeInTheDocument()
  })

  it('is explicit that no external aggregator was consulted', () => {
    render(<RotationComparisonPanel comparison={comparison} outSymbol="AAPL" degraded={0} />)
    expect(screen.getByText(/not a claim about the whole market/i)).toBeInTheDocument()
  })

  it('renders unavailable rather than zero before an amount is entered', () => {
    const {container} = render(<RotationComparisonPanel comparison={null} outSymbol="AAPL" degraded={0} />)
    expect(container.querySelectorAll('[data-unavailable="true"]').length).toBeGreaterThan(0)
  })

  it('surfaces a degraded quote', () => {
    render(<RotationComparisonPanel comparison={comparison} outSymbol="AAPL" degraded={0b1} />)
    expect(screen.getByTestId('degraded-notice')).toBeInTheDocument()
  })
})
