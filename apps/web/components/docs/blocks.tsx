// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'

import {Value} from '@/components/common/value'
import {DataRow} from '@/components/ledger/primitives'
import {Table, TableBody, TableCell, TableHead, TableHeader, TableRow} from '@/components/ui/table'
import {headingId, type Block} from '@/lib/docs/blocks'
import {FIGURES, type FigureId, type FigureValue} from '@/lib/docs/figures'

export type FigureMap = Record<FigureId, FigureValue>

/**
 * One figure, rendered.
 *
 * There is no path through this component that prints a number without a resolved source: a figure
 * that is unavailable becomes the same em dash the rest of the app uses, carrying the reason its
 * source gave. That is the only reason `rows` and `table` blocks are allowed to exist in a
 * documentation page at all.
 */
export function DocFigure({id, figures}: {id: FigureId; figures: FigureMap}) {
  const resolved = figures[id]
  const spec = FIGURES[id]
  if (!resolved || resolved.status !== 'value') {
    return (
      <Value unavailable reason={resolved?.status === 'unavailable' ? resolved.reason : 'Not resolved'} />
    )
  }
  return (
    <Value className="font-mono text-[14px]" title={spec.from}>
      {resolved.text}
    </Value>
  )
}

/**
 * The design's `rows` block: a `1px solid ink` top rule and a run of `k / b` on the left with the
 * figure in mono on the right, each row closed by a `--hair` line. No box, no ground.
 */
function BlockRows({block, figures}: {block: Extract<Block, {kind: 'rows'}>; figures: FigureMap}) {
  const cited = block.rows.flatMap((row) => (row.figure ? [row.figure] : []))
  return (
    <div className="my-[22px] max-w-[70ch]">
      {block.title ? <p className="ledger-label mb-2">{block.title}</p> : null}
      <div className="border-t border-ink">
        {block.rows.map((row) => (
          <DataRow
            key={row.label}
            label={row.label}
            labelClassName="text-[17px]"
            {...(row.hint ? {note: row.hint} : {})}
          >
            {row.figure ? (
              <DocFigure id={row.figure} figures={figures} />
            ) : (
              <span className="text-dim">{row.text ?? ''}</span>
            )}
          </DataRow>
        ))}
      </div>
      {cited.length > 0 ? <p className="mt-2.5 text-[13px] leading-normal text-dim">{sourceFootnote(cited)}</p> : null}
    </div>
  )
}

/** The design's `table` block: a `1px solid ink` head rule, mono cells, `--hair` between rows. */
function BlockTable({block, figures}: {block: Extract<Block, {kind: 'table'}>; figures: FigureMap}) {
  return (
    <div className="my-[22px] max-w-[70ch]">
      {block.title ? <p className="ledger-label mb-2">{block.title}</p> : null}
      <Table>
        <TableHeader>
          <TableRow>
            {block.columns.map((column) => (
              <TableHead key={column} className="border-ink">
                {column}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {block.rows.map((row, i) => (
            <TableRow key={i}>
              {row.map((cell, j) => (
                <TableCell key={j}>
                  {cell.figure ? (
                    <DocFigure id={cell.figure} figures={figures} />
                  ) : (
                    <span className={j === 0 ? undefined : 'text-dim'}>{cell.text ?? ''}</span>
                  )}
                </TableCell>
              ))}
            </TableRow>
          ))}
        </TableBody>
      </Table>
      {block.footnote ? (
        <p className="mt-2.5 text-[13px] leading-normal text-dim">{block.footnote}</p>
      ) : null}
    </div>
  )
}

/** "Read from AmpsHook.ampsFeeBps(), AmpsVault.redeemFeeBps(), …" — so a reader can check. */
function sourceFootnote(ids: readonly FigureId[]): string {
  const froms = Array.from(new Set(ids.map((id) => FIGURES[id].from)))
  return `Read from ${froms.join(', ')}.`
}

export function DocBlock({block, figures}: {block: Block; figures: FigureMap}) {
  switch (block.kind) {
    case 'h': {
      const id = headingId(block)
      return block.level === 2 ? (
        <h2
          id={id}
          className="mb-3.5 mt-11 max-w-[70ch] scroll-mt-28 text-[28px] font-normal leading-[1.15] tracking-[-0.022em]"
        >
          {block.text}
        </h2>
      ) : (
        <h3 id={id} className="mb-2 mt-8 max-w-[70ch] scroll-mt-28 text-[21px] leading-[1.25] tracking-[-0.02em]">
          {block.text}
        </h3>
      )
    }
    case 'p':
      return <p className="mb-4 max-w-[70ch] text-[18px] leading-[1.6]">{block.text}</p>
    // The design's note is the left-rule callout, not a coloured box: a 2px ink rule, a mono
    // uppercase title and a 17px line. `tone` survives only as the word the title carries — this
    // system has no alert colour, and a warning that reads as a warning does not need one.
    case 'note':
      return (
        <div className="my-6 max-w-[70ch] border-l-2 border-ink py-0.5 pl-5">
          <p className="ledger-label">{block.title}</p>
          <p className="mt-2 text-[17px] leading-[1.55]">{block.text}</p>
        </div>
      )
    case 'code':
      return (
        <pre className="ledger-scroll my-[22px] max-w-[70ch] border-b border-t border-b-rule border-t-ink py-4 font-mono text-[13px] leading-[1.7] text-ink">
          <code>{block.text}</code>
        </pre>
      )
    case 'rows':
      return <BlockRows block={block} figures={figures} />
    case 'table':
      return <BlockTable block={block} figures={figures} />
  }
}
