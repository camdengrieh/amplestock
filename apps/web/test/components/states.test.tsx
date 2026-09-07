// SPDX-License-Identifier: MIT
import {render, screen} from '@testing-library/react'
import {describe, expect, it} from 'vitest'

import {IndexerUnavailable, NotDeployed} from '@/components/common/states'
import {TxButton, TxError} from '@/components/common/tx'
import {surfaceError} from '@/lib/errors'

describe('NotDeployed', () => {
  it('says nothing on the page is real rather than showing zeros', () => {
    render(<NotDeployed what="Buy / Sell" />)
    const alert = screen.getByTestId('not-deployed')
    expect(alert).toHaveTextContent(/Nothing is being read/i)
    expect(alert).toHaveTextContent(/no number on this page is real/i)
  })
})

describe('IndexerUnavailable', () => {
  it('says the chain reads are unaffected', () => {
    render(<IndexerUnavailable reason="timeout" />)
    expect(screen.getByTestId('indexer-unavailable')).toHaveTextContent(/read directly from the chain on this page is unaffected/i)
  })
})

describe('TxButton', () => {
  it('shows the simulation phase and disables itself while busy', () => {
    render(<TxButton phase="simulating" label="Buy AMPS" />)
    const button = screen.getByRole('button')
    expect(button).toBeDisabled()
    expect(button).toHaveTextContent('Simulating…')
  })

  it('is blocked with a reason when the write cannot be offered', () => {
    render(<TxButton phase="blocked" label="Buy AMPS" blockedReason="Connect a wallet to simulate this swap." />)
    expect(screen.getByRole('button')).toBeDisabled()
    expect(screen.getByTestId('tx-blocked-reason')).toHaveTextContent(/Connect a wallet/)
  })

  it('is enabled once the simulation succeeds', () => {
    render(<TxButton phase="ready" label="Buy AMPS" />)
    expect(screen.getByRole('button')).toBeEnabled()
  })

  it('asks the user to confirm in their wallet while signing', () => {
    render(<TxButton phase="signing" label="Buy AMPS" />)
    expect(screen.getByRole('button')).toHaveTextContent(/Confirm in your wallet/)
  })
})

describe('TxError', () => {
  it('renders a named contract error with its explanation and next step', () => {
    render(<TxError error={surfaceError(new Error('execution reverted: CapacityExceeded'))} />)
    const alert = screen.getByTestId('tx-error')
    expect(alert).toHaveTextContent(/Bond capacity exhausted/i)
    expect(alert).toHaveTextContent(/whole deposit for a capped issue/i)
    expect(alert).toHaveTextContent(/Wait for the epoch to roll/i)
  })

  it('renders nothing when there is no error', () => {
    const {container} = render(<TxError error={null} />)
    expect(container).toBeEmptyDOMElement()
  })
})
