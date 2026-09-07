// SPDX-License-Identifier: MIT

/**
 * The geo gate.
 *
 * Robinhood Stock Tokens are Jersey-issued debt securities sold to non-US persons only, and are
 * additionally restricted in CA, the UK and CH. A permissionless claim on a managed portfolio of
 * tokenized securities, sold at a discount through bonds, is very likely a security, an investment
 * company under the ICA 1940 and an AIF under AIFMD. The front end therefore blocks those
 * jurisdictions. This is a front-end control and nothing more — the contracts are permissionless
 * and `redeemProRata` cannot be blocked by anybody, which `/risk` states plainly.
 *
 * Two independent checks, and both must pass:
 *
 * 1. **IP**, from whatever edge provider is in front of the app. The provider is pluggable because
 *    the header differs per host and because some deployments have no IP signal at all.
 * 2. **Self-attestation**, stored per browser with the terms acceptance. An IP check is trivially
 *    evaded; the attestation is what makes the answer the user's own.
 */

export const BLOCKED_COUNTRIES: readonly string[] = ['US', 'CA', 'GB', 'UK', 'CH']

export const BLOCKED_COUNTRY_LABELS: Readonly<Record<string, string>> = {
  US: 'United States',
  CA: 'Canada',
  GB: 'United Kingdom',
  UK: 'United Kingdom',
  CH: 'Switzerland',
}

/** The four jurisdictions as a person reads them, de-duplicated (GB and UK are one place). */
export const BLOCKED_JURISDICTIONS: readonly string[] = ['United States', 'Canada', 'United Kingdom', 'Switzerland']

export type GeoProviderName = 'vercel' | 'cloudflare' | 'header' | 'none'

export interface GeoProvider {
  readonly name: GeoProviderName
  /** The country code for a request, or `null` when this provider has no signal. */
  countryOf(headers: {get(name: string): string | null}): string | null
}

const PROVIDER_HEADERS: Readonly<Record<Exclude<GeoProviderName, 'none' | 'header'>, string>> = {
  vercel: 'x-vercel-ip-country',
  cloudflare: 'cf-ipcountry',
}

/**
 * Builds the provider named by `GEO_PROVIDER`. `none` is the development default and yields no
 * signal at all — which means the self-attestation is the only gate, and the middleware says so in
 * a response header rather than pretending it checked.
 */
export function createGeoProvider(name: string | undefined, customHeader = 'x-geo-country'): GeoProvider {
  const provider = (name ?? 'none').trim().toLowerCase() as GeoProviderName
  switch (provider) {
    case 'vercel':
    case 'cloudflare':
      return {
        name: provider,
        countryOf: (headers) => normaliseCountry(headers.get(PROVIDER_HEADERS[provider])),
      }
    case 'header':
      return {name: 'header', countryOf: (headers) => normaliseCountry(headers.get(customHeader))}
    default:
      return {name: 'none', countryOf: () => null}
  }
}

export function normaliseCountry(raw: string | null | undefined): string | null {
  if (!raw) return null
  const code = raw.trim().toUpperCase()
  if (code.length !== 2) return null
  if (code === 'XX' || code === 'T1') return null // unknown / Tor exit, per the usual edge conventions
  return code
}

export function parseBlockedCountries(raw: string | undefined): readonly string[] {
  if (!raw || raw.trim() === '') return BLOCKED_COUNTRIES
  const parsed = raw
    .split(',')
    .map((c) => c.trim().toUpperCase())
    .filter((c) => c.length === 2)
  return parsed.length > 0 ? parsed : BLOCKED_COUNTRIES
}

export function isBlockedCountry(country: string | null, blocked: readonly string[] = BLOCKED_COUNTRIES): boolean {
  if (!country) return false
  return blocked.includes(country.toUpperCase())
}

export interface GeoDecision {
  /** `true` when the request must be sent to `/blocked`. */
  blocked: boolean
  country: string | null
  provider: GeoProviderName
  /** `true` when no provider signal was available, so only the attestation stands between the user and the app. */
  unverified: boolean
}

export function decideGeo(params: {
  headers: {get(name: string): string | null}
  provider: GeoProvider
  blocked?: readonly string[]
}): GeoDecision {
  const country = params.provider.countryOf(params.headers)
  return {
    blocked: isBlockedCountry(country, params.blocked ?? BLOCKED_COUNTRIES),
    country,
    provider: params.provider.name,
    unverified: country === null,
  }
}

/** Paths that must stay reachable from a blocked jurisdiction. */
export const ALWAYS_ALLOWED_PATHS: readonly string[] = ['/blocked', '/risk']

export function isAlwaysAllowed(pathname: string): boolean {
  return ALWAYS_ALLOWED_PATHS.some((p) => pathname === p || pathname.startsWith(`${p}/`))
}
