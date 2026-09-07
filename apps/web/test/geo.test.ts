// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'

import {
  ALWAYS_ALLOWED_PATHS,
  BLOCKED_COUNTRIES,
  createGeoProvider,
  decideGeo,
  isAlwaysAllowed,
  isBlockedCountry,
  normaliseCountry,
  parseBlockedCountries,
} from '@/lib/geo'

function headers(map: Record<string, string>) {
  return {get: (name: string) => map[name.toLowerCase()] ?? null}
}

describe('the blocked set', () => {
  it('covers the four jurisdictions the plan names, with both UK spellings', () => {
    expect(BLOCKED_COUNTRIES).toContain('US')
    expect(BLOCKED_COUNTRIES).toContain('CA')
    expect(BLOCKED_COUNTRIES).toContain('GB')
    expect(BLOCKED_COUNTRIES).toContain('UK')
    expect(BLOCKED_COUNTRIES).toContain('CH')
  })

  it('is case-insensitive', () => {
    expect(isBlockedCountry('us')).toBe(true)
    expect(isBlockedCountry('DE')).toBe(false)
    expect(isBlockedCountry(null)).toBe(false)
  })
})

describe('providers', () => {
  it('reads the Vercel header', () => {
    const provider = createGeoProvider('vercel')
    expect(provider.countryOf(headers({'x-vercel-ip-country': 'US'}))).toBe('US')
  })

  it('reads the Cloudflare header', () => {
    const provider = createGeoProvider('cloudflare')
    expect(provider.countryOf(headers({'cf-ipcountry': 'ch'}))).toBe('CH')
  })

  it('reads a named custom header', () => {
    const provider = createGeoProvider('header', 'x-my-country')
    expect(provider.countryOf(headers({'x-my-country': 'GB'}))).toBe('GB')
  })

  it('has no signal at all when none is configured — and says so rather than pretending', () => {
    const provider = createGeoProvider(undefined)
    expect(provider.name).toBe('none')
    expect(provider.countryOf(headers({'x-vercel-ip-country': 'US'}))).toBeNull()
  })

  it('treats unknown and Tor-exit markers as no signal', () => {
    expect(normaliseCountry('XX')).toBeNull()
    expect(normaliseCountry('T1')).toBeNull()
    expect(normaliseCountry('')).toBeNull()
    expect(normaliseCountry('USA')).toBeNull()
  })
})

describe('decideGeo', () => {
  it('blocks a restricted country', () => {
    const decision = decideGeo({headers: headers({'cf-ipcountry': 'US'}), provider: createGeoProvider('cloudflare')})
    expect(decision.blocked).toBe(true)
    expect(decision.country).toBe('US')
    expect(decision.unverified).toBe(false)
  })

  it('does not block an unrestricted country', () => {
    const decision = decideGeo({headers: headers({'cf-ipcountry': 'SG'}), provider: createGeoProvider('cloudflare')})
    expect(decision.blocked).toBe(false)
  })

  it('does not block when there is no signal, and marks the request unverified', () => {
    const decision = decideGeo({headers: headers({}), provider: createGeoProvider('none')})
    expect(decision.blocked).toBe(false)
    expect(decision.unverified).toBe(true)
  })

  it('honours a configured override list', () => {
    const decision = decideGeo({
      headers: headers({'cf-ipcountry': 'FR'}),
      provider: createGeoProvider('cloudflare'),
      blocked: parseBlockedCountries('FR,DE'),
    })
    expect(decision.blocked).toBe(true)
  })
})

describe('parseBlockedCountries', () => {
  it('falls back to the default set for empty or malformed input', () => {
    expect(parseBlockedCountries(undefined)).toEqual(BLOCKED_COUNTRIES)
    expect(parseBlockedCountries('')).toEqual(BLOCKED_COUNTRIES)
    expect(parseBlockedCountries('nonsense,,')).toEqual(BLOCKED_COUNTRIES)
  })

  it('parses and upper-cases a list', () => {
    expect(parseBlockedCountries('us, ca ,gb')).toEqual(['US', 'CA', 'GB'])
  })
})

describe('always-allowed paths', () => {
  it('keeps /risk and /blocked reachable from a blocked jurisdiction', () => {
    expect(ALWAYS_ALLOWED_PATHS).toContain('/risk')
    expect(ALWAYS_ALLOWED_PATHS).toContain('/blocked')
    expect(isAlwaysAllowed('/risk')).toBe(true)
    expect(isAlwaysAllowed('/risk#pol-only')).toBe(false)
    expect(isAlwaysAllowed('/blocked')).toBe(true)
    expect(isAlwaysAllowed('/buy')).toBe(false)
  })
})
