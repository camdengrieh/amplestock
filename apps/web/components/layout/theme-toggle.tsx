// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'

import {
  THEME_LABEL,
  THEMES,
  applyTheme,
  browserThemeStorage,
  prefersDark,
  readStoredTheme,
  resolveTheme,
  writeStoredTheme,
  type Theme,
  type ThemeStorage,
} from '@/lib/theme'
import {cn} from '@/lib/utils'

/**
 * Paper / Ink, drawn as the design draws it: one `1px solid --rule` box split into two mono
 * `9px / 0.14em` buttons, the selected one filled with `--fill` / `--onfill`.
 *
 * A two-option radio group rather than a switch, because the two states have names and a switch
 * with a name on it is a lie about which way is "on". Arrow keys move between them, Space and Enter
 * select, and the choice is stored per browser.
 *
 * The head script has already stamped `data-theme` before first paint, so this component's first
 * render must not fight it: it reads the attribute back rather than assuming a default, and only
 * writes on an actual choice.
 */
export function ThemeToggle({storage, initial}: {storage?: ThemeStorage | null; initial?: Theme}) {
  const store = React.useMemo(() => (storage === undefined ? browserThemeStorage() : storage), [storage])
  const [theme, setTheme] = React.useState<Theme>(initial ?? 'paper')
  const [hydrated, setHydrated] = React.useState(initial !== undefined)

  React.useEffect(() => {
    const resolved = resolveTheme({stored: readStoredTheme(store), prefersDark: prefersDark()})
    setTheme(resolved)
    setHydrated(true)
    if (typeof document !== 'undefined') applyTheme(document.documentElement, resolved)
  }, [store])

  const choose = React.useCallback(
    (next: Theme) => {
      setTheme(next)
      writeStoredTheme(store, next)
      if (typeof document !== 'undefined') applyTheme(document.documentElement, next)
    },
    [store],
  )

  const onKeyDown = React.useCallback(
    (event: React.KeyboardEvent<HTMLDivElement>) => {
      if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight' && event.key !== 'ArrowUp' && event.key !== 'ArrowDown') {
        return
      }
      event.preventDefault()
      const index = THEMES.indexOf(theme)
      const delta = event.key === 'ArrowRight' || event.key === 'ArrowDown' ? 1 : -1
      const next = THEMES[(index + delta + THEMES.length) % THEMES.length]
      if (next) choose(next)
    },
    [choose, theme],
  )

  return (
    <div
      role="radiogroup"
      aria-label="Theme"
      onKeyDown={onKeyDown}
      className="inline-flex items-stretch border border-rule"
      data-testid="theme-toggle"
      data-theme-state={hydrated ? theme : undefined}
    >
      {THEMES.map((option) => {
        const selected = theme === option
        return (
          <button
            key={option}
            type="button"
            role="radio"
            aria-checked={selected}
            tabIndex={selected ? 0 : -1}
            onClick={() => choose(option)}
            data-testid={`theme-${option}`}
            className={cn(
              'px-[9px] py-[5px] font-mono text-[9px] uppercase tracking-[0.14em] transition-colors',
              selected ? 'bg-fill text-onfill' : 'text-dim hover:text-ink',
            )}
          >
            {THEME_LABEL[option]}
          </button>
        )
      })}
    </div>
  )
}
