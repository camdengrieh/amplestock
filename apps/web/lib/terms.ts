// SPDX-License-Identifier: MIT

/**
 * The terms gate: acceptance and the jurisdiction self-attestation, stored per browser.
 *
 * `localStorage`, deliberately. There is no account, no server-side record and no cookie sent to
 * anyone: the gate exists to make the disclosures unavoidable and the attestation the user's own
 * statement, not to build a profile. Clearing site data clears it, which is the correct behaviour.
 *
 * The stored record carries the version of the terms it accepted, so changing the disclosures
 * re-prompts everybody instead of silently inheriting an old consent.
 */

export const TERMS_VERSION = '2026-09-06'
export const TERMS_STORAGE_KEY = 'amps.terms.v1'

export interface TermsAcceptance {
  version: string
  acceptedAt: number
  /** The user's own statement that they are not resident in a restricted jurisdiction. */
  attestedNotRestricted: boolean
  /** The user's own statement that they have read `/risk`. */
  acknowledgedRisk: boolean
}

export function isCurrent(record: TermsAcceptance | null, version = TERMS_VERSION): boolean {
  if (!record) return false
  return record.version === version && record.attestedNotRestricted && record.acknowledgedRisk
}

export function parseAcceptance(raw: string | null): TermsAcceptance | null {
  if (!raw) return null
  try {
    const parsed: unknown = JSON.parse(raw)
    if (typeof parsed !== 'object' || parsed === null) return null
    const record = parsed as Partial<TermsAcceptance>
    if (typeof record.version !== 'string') return null
    return {
      version: record.version,
      acceptedAt: typeof record.acceptedAt === 'number' ? record.acceptedAt : 0,
      attestedNotRestricted: record.attestedNotRestricted === true,
      acknowledgedRisk: record.acknowledgedRisk === true,
    }
  } catch {
    return null
  }
}

export interface TermsStorage {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
  removeItem(key: string): void
}

export function readAcceptance(storage: TermsStorage | null): TermsAcceptance | null {
  if (!storage) return null
  try {
    return parseAcceptance(storage.getItem(TERMS_STORAGE_KEY))
  } catch {
    return null
  }
}

export function writeAcceptance(storage: TermsStorage | null, record: TermsAcceptance): void {
  if (!storage) return
  try {
    storage.setItem(TERMS_STORAGE_KEY, JSON.stringify(record))
  } catch {
    // A browser with storage disabled simply re-prompts every load. That is the honest fallback.
  }
}

export function clearAcceptance(storage: TermsStorage | null): void {
  if (!storage) return
  try {
    storage.removeItem(TERMS_STORAGE_KEY)
  } catch {
    // ignore
  }
}

export function browserStorage(): TermsStorage | null {
  if (typeof window === 'undefined') return null
  try {
    return window.localStorage
  } catch {
    return null
  }
}
