// SPDX-License-Identifier: MIT
import {render, screen} from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import {describe, expect, it} from 'vitest'

import {TermsGate} from '@/components/gates/terms-gate'
import {TERMS_STORAGE_KEY, TERMS_VERSION, type TermsStorage} from '@/lib/terms'

function memoryStorage(initial: Record<string, string> = {}): TermsStorage & {map: Record<string, string>} {
  const map = {...initial}
  return {
    map,
    getItem: (key) => map[key] ?? null,
    setItem: (key, value) => {
      map[key] = value
    },
    removeItem: (key) => {
      delete map[key]
    },
  }
}

const CURRENT = JSON.stringify({
  version: TERMS_VERSION,
  acceptedAt: 1,
  attestedNotRestricted: true,
  acknowledgedRisk: true,
})

describe('the terms gate', () => {
  it('hides the surface until both attestations are made', async () => {
    const storage = memoryStorage()
    render(
      <TermsGate storage={storage}>
        <div data-testid="surface">Buy</div>
      </TermsGate>,
    )
    expect(await screen.findByTestId('terms-gate')).toBeInTheDocument()
    expect(screen.queryByTestId('surface')).not.toBeInTheDocument()
    expect(screen.getByTestId('accept-terms')).toBeDisabled()
  })

  it('requires both boxes, not either', async () => {
    const user = userEvent.setup()
    render(
      <TermsGate storage={memoryStorage()}>
        <div data-testid="surface">Buy</div>
      </TermsGate>,
    )
    await screen.findByTestId('terms-gate')
    await user.click(screen.getByTestId('attest-jurisdiction'))
    expect(screen.getByTestId('accept-terms')).toBeDisabled()
    await user.click(screen.getByTestId('attest-risk'))
    expect(screen.getByTestId('accept-terms')).toBeEnabled()
  })

  it('reveals the surface and records the acceptance per browser', async () => {
    const user = userEvent.setup()
    const storage = memoryStorage()
    render(
      <TermsGate storage={storage} now={() => 1_800_000_000}>
        <div data-testid="surface">Buy</div>
      </TermsGate>,
    )
    await screen.findByTestId('terms-gate')
    await user.click(screen.getByTestId('attest-jurisdiction'))
    await user.click(screen.getByTestId('attest-risk'))
    await user.click(screen.getByTestId('accept-terms'))
    expect(screen.getByTestId('surface')).toBeInTheDocument()
    const stored = JSON.parse(storage.map[TERMS_STORAGE_KEY]!)
    expect(stored).toEqual({
      version: TERMS_VERSION,
      acceptedAt: 1_800_000_000,
      attestedNotRestricted: true,
      acknowledgedRisk: true,
    })
  })

  it('lets a returning browser straight through', async () => {
    render(
      <TermsGate storage={memoryStorage({[TERMS_STORAGE_KEY]: CURRENT})}>
        <div data-testid="surface">Buy</div>
      </TermsGate>,
    )
    expect(await screen.findByTestId('surface')).toBeInTheDocument()
    expect(screen.queryByTestId('terms-gate')).not.toBeInTheDocument()
  })

  it('re-prompts when the terms version has moved on', async () => {
    const stale = JSON.stringify({
      version: '1999-01-01',
      acceptedAt: 1,
      attestedNotRestricted: true,
      acknowledgedRisk: true,
    })
    render(
      <TermsGate storage={memoryStorage({[TERMS_STORAGE_KEY]: stale})}>
        <div data-testid="surface">Buy</div>
      </TermsGate>,
    )
    expect(await screen.findByTestId('terms-gate')).toBeInTheDocument()
  })

  it('names the four restricted jurisdictions in the attestation', async () => {
    render(
      <TermsGate storage={memoryStorage()}>
        <div />
      </TermsGate>,
    )
    const gate = await screen.findByTestId('terms-gate')
    for (const place of ['United States', 'Canada', 'United Kingdom', 'Switzerland']) {
      expect(gate).toHaveTextContent(place)
    }
  })
})
