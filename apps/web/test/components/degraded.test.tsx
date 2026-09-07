// SPDX-License-Identifier: MIT
import {render, screen} from '@testing-library/react'
import {describe, expect, it} from 'vitest'

import {DegradedNotice} from '@/components/common/degraded'
import {Value} from '@/components/common/value'
import {DegradedBit} from '@/lib/quoter'
import {UNAVAILABLE} from '@/lib/format'

describe('a degraded field is rendered as unavailable, never as zero', () => {
  it('renders the dash and the reason when a value is unavailable', () => {
    render(<Value unavailable reason="Vault checkpoint read failed">0</Value>)
    const node = screen.getByLabelText('Unavailable: Vault checkpoint read failed')
    expect(node).toHaveTextContent(UNAVAILABLE)
    expect(node).not.toHaveTextContent('0')
    expect(node.dataset.unavailable).toBe('true')
  })

  it('renders a genuine zero when the field is available', () => {
    render(<Value>0</Value>)
    expect(screen.getByText('0')).toHaveAttribute('data-unavailable', 'false')
  })

  it('treats undefined, null and empty as unavailable', () => {
    const {container} = render(
      <>
        <Value>{undefined}</Value>
        <Value>{null}</Value>
        <Value>{''}</Value>
      </>,
    )
    expect(container.querySelectorAll('[data-unavailable="true"]')).toHaveLength(3)
  })
})

describe('DegradedNotice', () => {
  it('renders nothing when the quote is clean', () => {
    const {container} = render(<DegradedNotice degraded={0} />)
    expect(container).toBeEmptyDOMElement()
  })

  it('names each failed sub-read', () => {
    render(<DegradedNotice degraded={DegradedBit.CHECKPOINT | DegradedBit.TWAP} />)
    expect(screen.getByTestId('degraded-notice')).toBeInTheDocument()
    expect(screen.getByText(/Vault checkpoint read failed/)).toBeInTheDocument()
    expect(screen.getByText(/Not enough observation history yet/)).toBeInTheDocument()
    expect(screen.queryByText(/Hook read failed/)).not.toBeInTheDocument()
  })

  it('says a degraded quote is not permission to trade', () => {
    render(<DegradedNotice degraded={DegradedBit.HOOK} />)
    expect(screen.getByText(/not permission to trade/i)).toBeInTheDocument()
    expect(screen.getByText(/fail open for display, not for execution/i)).toBeInTheDocument()
  })
})
