// SPDX-License-Identifier: MIT

/**
 * Paper / ink.
 *
 * Two themes and one attribute: `data-theme` on `<html>`. Everything else is CSS variables, so a
 * switch is one write and no component re-renders for it.
 *
 * The resolution order is deliberate and is the same in the blocking head script, in the React
 * toggle and in the tests: an explicit stored choice wins; failing that the operating system's
 * `prefers-color-scheme`; failing that, paper. A stored value the app does not recognise is
 * discarded rather than trusted — `localStorage` is user-writable.
 *
 * Pure functions, no `window` at module scope: the head script inlines {@link THEME_BOOT_SCRIPT}
 * and the component imports the same helpers, so there is one definition of "what theme is this".
 */

export const THEMES = ['paper', 'ink'] as const
export type Theme = (typeof THEMES)[number]

export const DEFAULT_THEME: Theme = 'paper'
export const THEME_STORAGE_KEY = 'amps.theme'
export const THEME_ATTRIBUTE = 'data-theme'

export function isTheme(value: unknown): value is Theme {
  return typeof value === 'string' && (THEMES as readonly string[]).includes(value)
}

/** The other one. There are exactly two, and that is the whole toggle. */
export function otherTheme(theme: Theme): Theme {
  return theme === 'paper' ? 'ink' : 'paper'
}

export interface ThemeStorage {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

export function readStoredTheme(storage: ThemeStorage | null): Theme | null {
  if (!storage) return null
  try {
    const raw = storage.getItem(THEME_STORAGE_KEY)
    return isTheme(raw) ? raw : null
  } catch {
    return null
  }
}

export function writeStoredTheme(storage: ThemeStorage | null, theme: Theme): void {
  if (!storage) return
  try {
    storage.setItem(THEME_STORAGE_KEY, theme)
  } catch {
    // A browser with storage disabled simply forgets the choice on reload. Honest fallback.
  }
}

/**
 * The stored choice, else the system preference, else paper.
 *
 * `prefersDark` is passed in rather than read here so the same function answers for the head
 * script, for a test and for a server render that has no `matchMedia` at all.
 */
export function resolveTheme(params: {stored: Theme | null; prefersDark: boolean}): Theme {
  if (params.stored) return params.stored
  return params.prefersDark ? 'ink' : DEFAULT_THEME
}

export function applyTheme(root: {setAttribute(name: string, value: string): void} | null, theme: Theme): void {
  root?.setAttribute(THEME_ATTRIBUTE, theme)
}

export function browserThemeStorage(): ThemeStorage | null {
  if (typeof window === 'undefined') return null
  try {
    return window.localStorage
  } catch {
    return null
  }
}

export function prefersDark(): boolean {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false
  try {
    return window.matchMedia('(prefers-color-scheme: dark)').matches
  } catch {
    return false
  }
}

/**
 * The blocking script the document head runs before first paint.
 *
 * It has to be a string: a React component cannot run before hydration, and a theme applied after
 * the first paint is a flash of the wrong ground. It is the same three steps as
 * {@link resolveTheme}, written out because it runs with no module system.
 */
export const THEME_BOOT_SCRIPT = `(function(){try{var t=localStorage.getItem(${JSON.stringify(
  THEME_STORAGE_KEY,
)});if(t!=='paper'&&t!=='ink'){t=window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches?'ink':'paper';}document.documentElement.setAttribute(${JSON.stringify(
  THEME_ATTRIBUTE,
)},t);}catch(e){document.documentElement.setAttribute(${JSON.stringify(THEME_ATTRIBUTE)},'paper');}})();`

export const THEME_LABEL: Readonly<Record<Theme, string>> = {paper: 'Paper', ink: 'Ink'}
