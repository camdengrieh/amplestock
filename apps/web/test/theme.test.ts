// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'

import {
  DEFAULT_THEME,
  THEME_ATTRIBUTE,
  THEME_BOOT_SCRIPT,
  THEME_STORAGE_KEY,
  THEMES,
  applyTheme,
  isTheme,
  otherTheme,
  readStoredTheme,
  resolveTheme,
  writeStoredTheme,
  type Theme,
  type ThemeStorage,
} from '@/lib/theme'

function memoryStorage(initial: Record<string, string> = {}): ThemeStorage & {map: Record<string, string>} {
  const map = {...initial}
  return {
    map,
    getItem: (key) => map[key] ?? null,
    setItem: (key, value) => {
      map[key] = value
    },
  }
}

function throwingStorage(): ThemeStorage {
  return {
    getItem() {
      throw new Error('storage disabled')
    },
    setItem() {
      throw new Error('storage disabled')
    },
  }
}

describe('the two themes', () => {
  it('is exactly paper and ink', () => {
    expect([...THEMES]).toEqual(['paper', 'ink'])
    expect(DEFAULT_THEME).toBe('paper')
  })

  it('toggles between them', () => {
    expect(otherTheme('paper')).toBe('ink')
    expect(otherTheme('ink')).toBe('paper')
  })

  it('refuses anything that is not one of them', () => {
    expect(isTheme('paper')).toBe(true)
    expect(isTheme('ink')).toBe(true)
    for (const bad of ['dark', 'light', '', 'INK', null, 7, {}]) {
      expect(isTheme(bad)).toBe(false)
    }
  })
})

describe('resolving the theme', () => {
  it('prefers an explicit stored choice over the system preference', () => {
    expect(resolveTheme({stored: 'paper', prefersDark: true})).toBe('paper')
    expect(resolveTheme({stored: 'ink', prefersDark: false})).toBe('ink')
  })

  it('falls back to prefers-color-scheme when nothing is stored', () => {
    expect(resolveTheme({stored: null, prefersDark: true})).toBe('ink')
    expect(resolveTheme({stored: null, prefersDark: false})).toBe('paper')
  })

  it('discards a stored value it does not recognise rather than trusting it', () => {
    // `localStorage` is user-writable, so a junk value must not become a theme.
    const storage = memoryStorage({[THEME_STORAGE_KEY]: 'solarized'})
    expect(readStoredTheme(storage)).toBeNull()
    expect(resolveTheme({stored: readStoredTheme(storage), prefersDark: false})).toBe('paper')
  })

  it('survives a browser with storage disabled', () => {
    expect(readStoredTheme(throwingStorage())).toBeNull()
    expect(() => writeStoredTheme(throwingStorage(), 'ink')).not.toThrow()
    expect(readStoredTheme(null)).toBeNull()
  })

  it('round-trips a choice', () => {
    const storage = memoryStorage()
    writeStoredTheme(storage, 'ink')
    expect(storage.map[THEME_STORAGE_KEY]).toBe('ink')
    expect(readStoredTheme(storage)).toBe('ink')
  })
})

describe('applying the theme', () => {
  it('writes one attribute and nothing else', () => {
    const written: [string, string][] = []
    const root = {
      setAttribute: (name: string, value: string) => {
        written.push([name, value])
      },
    }
    applyTheme(root, 'ink')
    expect(written).toEqual([[THEME_ATTRIBUTE, 'ink']])
  })

  it('does nothing at all with no root', () => {
    expect(() => applyTheme(null, 'paper')).not.toThrow()
  })
})

describe('the blocking head script', () => {
  /**
   * The script runs before hydration with no module system, so it cannot import `resolveTheme`.
   * This drives the real source against fake globals to prove it makes the same three decisions.
   */
  function runBootScript(params: {stored: string | null; prefersDark: boolean}): string | null {
    let attribute: string | null = null
    const fakeWindow = {
      matchMedia: (query: string) => ({matches: query.includes('dark') && params.prefersDark}),
    }
    const fakeDocument = {
      documentElement: {
        setAttribute: (name: string, value: string) => {
          if (name === THEME_ATTRIBUTE) attribute = value
        },
      },
    }
    const fakeStorage = {getItem: () => params.stored}
    // eslint-disable-next-line no-new-func
    new Function('window', 'document', 'localStorage', THEME_BOOT_SCRIPT)(fakeWindow, fakeDocument, fakeStorage)
    return attribute
  }

  it.each([
    {stored: 'ink', prefersDark: false, expected: 'ink'},
    {stored: 'paper', prefersDark: true, expected: 'paper'},
    {stored: null, prefersDark: true, expected: 'ink'},
    {stored: null, prefersDark: false, expected: 'paper'},
    {stored: 'nonsense', prefersDark: false, expected: 'paper'},
  ])('stamps $expected for stored=$stored prefersDark=$prefersDark', ({stored, prefersDark, expected}) => {
    expect(runBootScript({stored, prefersDark})).toBe(expected)
    // …and agrees with the function the React toggle uses.
    expect(resolveTheme({stored: isTheme(stored) ? (stored as Theme) : null, prefersDark})).toBe(expected)
  })
})
