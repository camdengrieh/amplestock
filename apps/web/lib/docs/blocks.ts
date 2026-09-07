// SPDX-License-Identifier: MIT

/**
 * The block vocabulary the documentation is written in.
 *
 * Six kinds and no more: a heading, a paragraph, a note, a code sample, a list of rows and a table.
 * The two that carry figures — `rows` and `table` — cannot carry a literal number: a cell is either
 * prose or a {@link FigureId}, and an id is resolved from a live source at render time. That is the
 * whole reason the docs are data rather than JSX.
 */

import type {FigureId} from './figures'

export interface HeadingBlock {
  kind: 'h'
  /** 2 or 3. The page title is the `h1` and is not a block. */
  level: 2 | 3
  text: string
  /** Anchor for the on-this-page rail. Derived from `text` when absent. */
  id?: string
}

export interface ParagraphBlock {
  kind: 'p'
  text: string
}

export interface NoteBlock {
  kind: 'note'
  tone: 'default' | 'warning' | 'danger' | 'info'
  title: string
  text: string
}

export interface CodeBlock {
  kind: 'code'
  lang: 'solidity' | 'ts' | 'sh' | 'text'
  text: string
}

/** One label and one value. The value is a live figure, or prose that contains no number. */
export interface Row {
  label: string
  figure?: FigureId
  /** Prose alternative, for a row whose answer is a sentence rather than a number. */
  text?: string
  hint?: string
}

export interface RowsBlock {
  kind: 'rows'
  /** Printed above the rows as a mono label. */
  title?: string
  rows: readonly Row[]
}

/** A table cell: a live figure, or prose. Never a literal number. */
export interface Cell {
  figure?: FigureId
  text?: string
}

export interface TableBlock {
  kind: 'table'
  title?: string
  columns: readonly string[]
  rows: readonly (readonly Cell[])[]
  /** Printed under the table: where the figures came from. */
  footnote?: string
}

export type Block = HeadingBlock | ParagraphBlock | NoteBlock | CodeBlock | RowsBlock | TableBlock

/** The anchor a heading gets in the on-this-page rail. */
export function headingId(block: HeadingBlock): string {
  return (
    block.id ??
    block.text
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
  )
}

/** Every figure id a page references, in order, for the "where these come from" footer and tests. */
export function figuresIn(blocks: readonly Block[]): FigureId[] {
  const out: FigureId[] = []
  for (const block of blocks) {
    if (block.kind === 'rows') {
      for (const row of block.rows) if (row.figure) out.push(row.figure)
    } else if (block.kind === 'table') {
      for (const row of block.rows) for (const cell of row) if (cell.figure) out.push(cell.figure)
    }
  }
  return out
}
