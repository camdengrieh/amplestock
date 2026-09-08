// SPDX-License-Identifier: MIT
import {render, screen} from '@testing-library/react'
import {describe, expect, it} from 'vitest'

import {RotationComparisonPanel, compareRotation} from '@/components/surfaces/rotate'
import {NOTES} from '@/lib/copy'
import {bpsToPips} from '@/lib/fees'

const WAD = 10n ** 18n

describe('compareRotation', () => {
  it('prices both hops of a rotation at the pools’ pass-through base', () => {
    const c = compareRotation({hop1BuyFeeBps: 5, hop2BuyFeeBps: 5, ampsFeeBps: 500, ampsFromHop1: WAD})
    expect(c.hop2BaseBpsRotated).toBe(5)
    expect(c.hop1FeePips).toBe(bpsToPips(5))
    expect(c.rotatedHop2FeePips).toBe(bpsToPips(5))
    expect(c.rotatedTotalPips).toBe(bpsToPips(10))
  })

  it('prices the same two swaps through any other router at the AMPS fee on **both** legs', () => {
    // Revision 6: buying AMPS and selling it are both taxed, so splitting a rotation costs two
    // AMPS fees, not one. Pricing hop 1 at the pass-through base in this column — which is what
    // revision 5's comparison did — understates the difference by a whole leg.
    const c = compareRotation({hop1BuyFeeBps: 5, hop2BuyFeeBps: 5, ampsFeeBps: 500, ampsFromHop1: WAD})
    expect(c.separateHop1FeePips).toBe(bpsToPips(500))
    expect(c.separateHop2FeePips).toBe(bpsToPips(500))
    expect(c.separateTotalPips).toBe(bpsToPips(1_000))
    expect(c.savedPips).toBe(bpsToPips(990))
  })

  it('never claims a saving larger than the two AMPS fees themselves', () => {
    const c = compareRotation({hop1BuyFeeBps: 30, hop2BuyFeeBps: 30, ampsFeeBps: 100, ampsFromHop1: WAD})
    expect(c.savedPips).toBe(bpsToPips(140))
    expect(c.savedPips).toBeLessThanOrEqual(bpsToPips(200))
  })

  it('prefers the quoter’s own fee legs over the fee law when it has answered', () => {
    // The quoter's legs carry the dynamic component; the law does not know it. When both are
    // available the quote wins, in both columns, so the difference stays the pass-through alone.
    const c = compareRotation({
      hop1BuyFeeBps: 5,
      hop2BuyFeeBps: 5,
      ampsFeeBps: 500,
      ampsFromHop1: WAD,
      hop1PassThroughFeePips: 800,
      hop2PassThroughFeePips: 900,
      hop1OrdinaryFeePips: 50_300,
      hop2OrdinaryFeePips: 50_400,
    })
    expect(c.rotatedTotalPips).toBe(1_700)
    expect(c.separateTotalPips).toBe(100_700)
    expect(c.savedPips).toBe(99_000)
  })
})

describe('RotationComparisonPanel', () => {
  const comparison = compareRotation({hop1BuyFeeBps: 5, hop2BuyFeeBps: 5, ampsFeeBps: 500, ampsFromHop1: WAD})

  it('puts the rotation and the same two swaps through any other router side by side', () => {
    render(<RotationComparisonPanel comparison={comparison} outSymbol="AAPL" degraded={0} />)
    expect(screen.getByText('One transaction, through AMPS')).toBeInTheDocument()
    expect(screen.getByText('The same two swaps through any other router')).toBeInTheDocument()
    // 990 bp of difference across both legs.
    expect(screen.getByText('9.90%')).toBeInTheDocument()
    // And both legs of the other-router column are the AMPS fee, not one of them.
    expect(screen.getAllByText('5.00%').length).toBeGreaterThanOrEqual(2)
  })

  it('is explicit that no external aggregator was consulted', () => {
    // The design puts that sentence under the submit button in the left column rather than inside
    // the comparison, so the claim is tested where it lives — and the panel itself is tested for
    // never implying more than the two pools it actually priced.
    expect(NOTES.noAggregator).toMatch(/not a claim about the whole market/i)
    const {container} = render(<RotationComparisonPanel comparison={comparison} outSymbol="AAPL" degraded={0} />)
    expect(container.textContent).not.toMatch(/best (price|route)|aggregat/i)
  })

  it('renders unavailable rather than zero before an amount is entered', () => {
    const {container} = render(<RotationComparisonPanel comparison={null} outSymbol="AAPL" degraded={0} />)
    expect(container.querySelectorAll('[data-unavailable="true"]').length).toBeGreaterThan(0)
  })

  it('surfaces a degraded quote', () => {
    render(<RotationComparisonPanel comparison={comparison} outSymbol="AAPL" degraded={0b1} />)
    expect(screen.getByTestId('degraded-notice')).toBeInTheDocument()
  })

  it('warns when the hook honours a different router than the one this page would call', () => {
    render(
      <RotationComparisonPanel
        comparison={comparison}
        outSymbol="AAPL"
        degraded={0}
        routerAddress="0x00000000000000000000000000000000000000A1"
        hookRouter="0x00000000000000000000000000000000000000B2"
      />,
    )
    expect(screen.getByTestId('router-mismatch')).toHaveTextContent(/does not honour this router/i)
  })

  it('does not warn when the pointer agrees, whatever the case of the two strings', () => {
    render(
      <RotationComparisonPanel
        comparison={comparison}
        outSymbol="AAPL"
        degraded={0}
        routerAddress="0x00000000000000000000000000000000000000a1"
        hookRouter="0x00000000000000000000000000000000000000A1"
      />,
    )
    expect(screen.queryByTestId('router-mismatch')).not.toBeInTheDocument()
  })

  it('says nothing about the pointer when it has not been read', () => {
    render(
      <RotationComparisonPanel
        comparison={comparison}
        outSymbol="AAPL"
        degraded={0}
        routerAddress="0x00000000000000000000000000000000000000A1"
      />,
    )
    expect(screen.queryByTestId('router-mismatch')).not.toBeInTheDocument()
  })
})
