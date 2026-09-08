// SPDX-License-Identifier: MIT
import {render, screen, waitFor} from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import {describe, expect, it} from 'vitest'

import {ThemeToggle} from '@/components/layout/theme-toggle'
import {THEME_ATTRIBUTE, THEME_STORAGE_KEY, type ThemeStorage} from '@/lib/theme'

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

function currentTheme(): string | null {
  return document.documentElement.getAttribute(THEME_ATTRIBUTE)
}

describe('the paper / ink toggle', () => {
  it('is a radio group with the two themes as its options', async () => {
    render(<ThemeToggle storage={memoryStorage()} />)
    const group = await screen.findByRole('radiogroup', {name: 'Theme'})
    expect(group).toBeInTheDocument()
    expect(screen.getByRole('radio', {name: 'Paper'})).toBeInTheDocument()
    expect(screen.getByRole('radio', {name: 'Ink'})).toBeInTheDocument()
  })

  it('starts on the stored choice rather than on a default', async () => {
    render(<ThemeToggle storage={memoryStorage({[THEME_STORAGE_KEY]: 'ink'})} />)
    await waitFor(() => expect(screen.getByRole('radio', {name: 'Ink'})).toHaveAttribute('aria-checked', 'true'))
    expect(screen.getByRole('radio', {name: 'Paper'})).toHaveAttribute('aria-checked', 'false')
  })

  it('writes the attribute the whole stylesheet keys off, and remembers the choice', async () => {
    const user = userEvent.setup()
    const storage = memoryStorage()
    render(<ThemeToggle storage={storage} />)
    await user.click(await screen.findByRole('radio', {name: 'Ink'}))
    expect(currentTheme()).toBe('ink')
    expect(storage.map[THEME_STORAGE_KEY]).toBe('ink')

    await user.click(screen.getByRole('radio', {name: 'Paper'}))
    expect(currentTheme()).toBe('paper')
    expect(storage.map[THEME_STORAGE_KEY]).toBe('paper')
  })

  it('moves between the options with the arrow keys, as a radio group should', async () => {
    const user = userEvent.setup()
    const storage = memoryStorage({[THEME_STORAGE_KEY]: 'paper'})
    render(<ThemeToggle storage={storage} />)
    const paper = await screen.findByRole('radio', {name: 'Paper'})
    await waitFor(() => expect(paper).toHaveAttribute('aria-checked', 'true'))

    paper.focus()
    await user.keyboard('{ArrowRight}')
    expect(screen.getByRole('radio', {name: 'Ink'})).toHaveAttribute('aria-checked', 'true')
    expect(currentTheme()).toBe('ink')

    await user.keyboard('{ArrowLeft}')
    expect(screen.getByRole('radio', {name: 'Paper'})).toHaveAttribute('aria-checked', 'true')
  })

  it('keeps exactly one option in the tab order', async () => {
    render(<ThemeToggle storage={memoryStorage({[THEME_STORAGE_KEY]: 'ink'})} />)
    await waitFor(() => expect(screen.getByRole('radio', {name: 'Ink'})).toHaveAttribute('tabindex', '0'))
    expect(screen.getByRole('radio', {name: 'Paper'})).toHaveAttribute('tabindex', '-1')
  })

  it('does not throw when storage is unavailable', async () => {
    const user = userEvent.setup()
    render(<ThemeToggle storage={null} />)
    await user.click(await screen.findByRole('radio', {name: 'Ink'}))
    expect(currentTheme()).toBe('ink')
  })
})
