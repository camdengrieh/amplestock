// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'

import {
  TERMS_STORAGE_KEY,
  TERMS_VERSION,
  clearAcceptance,
  isCurrent,
  parseAcceptance,
  readAcceptance,
  writeAcceptance,
  type TermsStorage,
} from '@/lib/terms'

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

const accepted = {
  version: TERMS_VERSION,
  acceptedAt: 1_800_000_000,
  attestedNotRestricted: true,
  acknowledgedRisk: true,
}

describe('acceptance', () => {
  it('is current only with both attestations at the current version', () => {
    expect(isCurrent(accepted)).toBe(true)
    expect(isCurrent({...accepted, attestedNotRestricted: false})).toBe(false)
    expect(isCurrent({...accepted, acknowledgedRisk: false})).toBe(false)
    expect(isCurrent({...accepted, version: '1999-01-01'})).toBe(false)
    expect(isCurrent(null)).toBe(false)
  })

  it('re-prompts everybody when the disclosures change', () => {
    expect(isCurrent(accepted, 'a-new-version')).toBe(false)
  })
})

describe('storage', () => {
  it('round-trips through a browser store', () => {
    const storage = memoryStorage()
    writeAcceptance(storage, accepted)
    expect(readAcceptance(storage)).toEqual(accepted)
    expect(storage.map[TERMS_STORAGE_KEY]).toBeDefined()
  })

  it('clears', () => {
    const storage = memoryStorage()
    writeAcceptance(storage, accepted)
    clearAcceptance(storage)
    expect(readAcceptance(storage)).toBeNull()
  })

  it('treats an absent store as "not accepted" rather than throwing', () => {
    expect(readAcceptance(null)).toBeNull()
    expect(() => writeAcceptance(null, accepted)).not.toThrow()
    expect(() => clearAcceptance(null)).not.toThrow()
  })

  it('survives a store that throws — a browser with storage disabled just re-prompts', () => {
    const hostile: TermsStorage = {
      getItem: () => {
        throw new Error('blocked')
      },
      setItem: () => {
        throw new Error('blocked')
      },
      removeItem: () => {
        throw new Error('blocked')
      },
    }
    expect(readAcceptance(hostile)).toBeNull()
    expect(() => writeAcceptance(hostile, accepted)).not.toThrow()
  })
})

describe('parseAcceptance', () => {
  it('rejects junk rather than half-trusting it', () => {
    expect(parseAcceptance(null)).toBeNull()
    expect(parseAcceptance('not json')).toBeNull()
    expect(parseAcceptance('null')).toBeNull()
    expect(parseAcceptance('123')).toBeNull()
    expect(parseAcceptance('{}')).toBeNull()
  })

  it('coerces missing attestations to false rather than to true', () => {
    const parsed = parseAcceptance(JSON.stringify({version: TERMS_VERSION}))
    expect(parsed).not.toBeNull()
    expect(parsed?.attestedNotRestricted).toBe(false)
    expect(parsed?.acknowledgedRisk).toBe(false)
    expect(isCurrent(parsed)).toBe(false)
  })
})
