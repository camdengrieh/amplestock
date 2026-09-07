// SPDX-License-Identifier: MIT
import {readFileSync, readdirSync, statSync} from 'node:fs'
import {dirname, join, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'
import {describe, expect, it} from 'vitest'

import {LEGAL_FOOTER, NOTES, RISK_DISCLOSURES} from '@/lib/copy'

/**
 * The language gate.
 *
 * Every one of these patterns is something the plan forbids the interface from saying: a promised
 * return, a creation/redemption channel with the token issuer, a premium dressed up as anything
 * other than a number. The patterns are deliberately narrow enough that the *negative* forms — "no
 * guarantee", "there is no authorised participant" — are still sayable, because the disclosures
 * have to be able to say them.
 */
const FORBIDDEN: readonly {pattern: RegExp; why: string}[] = [
  {pattern: /\bAP channel\b/i, why: 'bonds and redemption are never a channel to or from the issuer'},
  {pattern: /\bauthoris[sz]?ed[- ]participant\s+channel\b/i, why: 'there is no creation/redemption arrangement with the issuer'},
  {pattern: /\bguaranteed?\s+(returns?|profits?|yields?|income|price|value)\b/i, why: 'nothing here is guaranteed'},
  {pattern: /\brisk[- ]free\b/i, why: 'nothing here is risk-free'},
  {pattern: /\bAPY\b/, why: 'staking pays realised fees, not a compounding yield'},
  {pattern: /\bpassive income\b/i, why: 'fees already collected are not income'},
  {pattern: /\bprice target\b/i, why: 'no price forecasts'},
  {pattern: /\bwill (increase|rise|go up|appreciate|moon)\b/i, why: 'no price forecasts'},
  {pattern: /\bcan(?:not|'t| not) lose\b/i, why: 'no promises about outcomes'},
  {pattern: /\bassured (returns?|profits?|gains?)\b/i, why: 'nothing here is assured'},
  {pattern: /\bto the moon\b/i, why: 'no price forecasts'},
]

const SCANNED_DIRS = ['app', 'components', 'lib']
const SCANNED_EXTENSIONS = ['.ts', '.tsx', '.css']

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) {
      if (entry === 'node_modules' || entry.startsWith('.')) continue
      walk(full, out)
    } else if (SCANNED_EXTENSIONS.some((ext) => entry.endsWith(ext))) {
      out.push(full)
    }
  }
  return out
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..') + '/'
const files = SCANNED_DIRS.flatMap((dir) => walk(join(root, dir)))

describe('what the UI must never say', () => {
  it('scans a non-trivial number of source files', () => {
    expect(files.length).toBeGreaterThan(30)
  })

  it.each(FORBIDDEN)('never says $pattern — $why', ({pattern}) => {
    const offenders: string[] = []
    for (const file of files) {
      const contents = readFileSync(file, 'utf8')
      if (pattern.test(contents)) {
        const line = contents.split('\n').find((l) => pattern.test(l))
        offenders.push(`${file.replace(root, '')}: ${line?.trim()}`)
      }
    }
    expect(offenders).toEqual([])
  })
})

describe('the disclosures the plan requires', () => {
  const ids = RISK_DISCLOSURES.map((d) => d.id)

  it('covers POL-only bid depth', () => {
    expect(ids).toContain('pol-only')
    const body = RISK_DISCLOSURES.find((d) => d.id === 'pol-only')!.body.join(' ')
    expect(body).toMatch(/only entity placing liquidity|only bidder|protocol-owned/i)
  })

  it('covers redemption as the only floor', () => {
    expect(ids).toContain('redemption-floor')
    const body = RISK_DISCLOSURES.find((d) => d.id === 'redemption-floor')!.body.join(' ')
    expect(body).toMatch(/cannot be paused/i)
    expect(body).toMatch(/pays you the assets|pays in assets/i)
  })

  it('covers chain-level censorship', () => {
    expect(ids).toContain('censorship')
    expect(RISK_DISCLOSURES.find((d) => d.id === 'censorship')!.body.join(' ')).toMatch(/sequencer/i)
  })

  it('covers issuer denylist and pause risk', () => {
    expect(ids).toContain('issuer-denylist')
    const body = RISK_DISCLOSURES.find((d) => d.id === 'issuer-denylist')!.body.join(' ')
    expect(body).toMatch(/block an address/i)
    expect(body).toMatch(/multiplier/i)
  })

  it('states that there is no authorised participant', () => {
    expect(ids).toContain('no-ap')
    const body = RISK_DISCLOSURES.find((d) => d.id === 'no-ap')!.body.join(' ')
    expect(body).toMatch(/no authorised participant/i)
    expect(body).toMatch(/neither is a channel/i)
  })

  it('states that the premium is a number rather than a promise', () => {
    expect(ids).toContain('premium')
    expect(RISK_DISCLOSURES.find((d) => d.id === 'premium')!.title).toMatch(/number, not a promise/i)
    expect(NOTES.premium).toMatch(/disclosure only/i)
  })

  it('states the jurisdiction block', () => {
    const body = RISK_DISCLOSURES.find((d) => d.id === 'jurisdiction')!.body.join(' ')
    for (const place of ['United States', 'Canada', 'United Kingdom', 'Switzerland']) {
      expect(body).toContain(place)
    }
  })

  it('carries a legal footer that disclaims advice and names the restricted set', () => {
    expect(LEGAL_FOOTER).toMatch(/not investment advice/i)
    expect(LEGAL_FOOTER).toMatch(/United States/)
  })
})
