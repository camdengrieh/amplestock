// SPDX-License-Identifier: MIT
import * as React from 'react'

import {cn} from '@/lib/utils'

/**
 * The Ledger vocabulary, transcribed block by block from the design.
 *
 * Each export below is one repeated structure in `design/ledger/Redesign A - Ledger.dc.html`, kept
 * at the design's own measurements rather than at the nearest Tailwind step — a 44px figure is 44px
 * and a 0.18em kicker is 0.18em, because the whole system is type and rules and there is nothing
 * else for an approximation to hide behind.
 */

/** Mono, uppercase, `0.18em`. The word above a title. */
export function Kicker({children, className, ...rest}: React.HTMLAttributes<HTMLParagraphElement>) {
  return (
    <p className={cn('ledger-kicker', className)} {...rest}>
      {children}
    </p>
  )
}

/** A hairline. `ink` is the 2px rule under a page title; `rule` and `hair` are the two hairlines. */
export function Rule({weight = 'hair', className}: {weight?: 'hair' | 'rule' | 'ink' | 'ink-1'; className?: string}) {
  return (
    <div
      role="presentation"
      className={cn(
        'w-full',
        weight === 'ink'
          ? 'h-0.5 bg-ink'
          : weight === 'ink-1'
            ? 'h-px bg-ink'
            : weight === 'rule'
              ? 'h-px bg-rule'
              : 'h-px bg-hair',
        className,
      )}
    />
  )
}

/**
 * A section head: a heading on the left, a sentence on the right, over a 2px ink rule.
 *
 * The design uses this shape for every block that owns a table underneath it — Holdings, the
 * ladder, Markets, Your positions — and the right-hand sentence is where the caveat goes.
 */
export function SectionHead({
  title,
  note,
  kicker,
  aside,
  id,
  className,
}: {
  title: string
  note?: string
  kicker?: string
  /** Mono, uppercase, right-aligned: a count or a state, not a sentence. */
  aside?: React.ReactNode
  id?: string
  className?: string
}) {
  return (
    <div
      {...(id ? {id} : {})}
      className={cn('flex flex-wrap items-end justify-between gap-x-6 gap-y-3 border-b-2 border-ink pb-3.5', className)}
    >
      <div className="min-w-0">
        {kicker ? <Kicker className="mb-2">{kicker}</Kicker> : null}
        <h2 className="ledger-heading">{title}</h2>
        {note ? <p className="mt-1.5 max-w-[62ch] text-[15px] leading-normal text-dim">{note}</p> : null}
      </div>
      {aside ? <div className="ledger-micro whitespace-nowrap">{aside}</div> : null}
    </div>
  )
}

/**
 * A band of figures: `repeat(auto-fit, minmax(200px,1fr))` with 1px hair gaps showing through, over
 * a 2px ink rule. The design's headline treatment on Vault and Stake, and its "by the numbers".
 */
export function StatBand({
  children,
  rule = 'ink',
  min = 200,
  className,
  ...rest
}: React.HTMLAttributes<HTMLDivElement> & {rule?: 'ink' | 'none'; min?: number}) {
  return (
    <div
      className={cn('ledger-band', rule === 'ink' && 'border-t-2 border-ink', className)}
      style={{['--band-min' as string]: `${min}px`} as React.CSSProperties}
      {...rest}
    >
      {children}
    </div>
  )
}

/** One cell of a {@link StatBand}: mono label, 44px figure, 13px note. */
export function StatCell({
  label,
  children,
  note,
  size = 'stat',
  className,
}: {
  label: string
  children: React.ReactNode
  note?: string
  /** `stat` is the 44px headline; `big` is the 38px number in a landing band. */
  size?: 'stat' | 'big'
  className?: string
}) {
  return (
    <div className={cn('bg-paper px-4 py-[18px] sm:px-[22px] sm:pb-[22px] sm:pt-6', className)}>
      <p className="ledger-label mb-2 sm:mb-3">{label}</p>
      <p className={size === 'stat' ? 'ledger-stat' : 'ledger-big'}>{children}</p>
      {note ? <p className="mt-3 max-w-[38ch] text-[13px] leading-normal text-dim">{note}</p> : null}
    </div>
  )
}

/**
 * The inverted panel: `--fill` ground, `--onfill` type, and its own pair of rules.
 *
 * The design uses it twice — for the landing page's floor section and for the "why it has to be one
 * transaction" note on Rotate — and both times for a sentence the page exists to make.
 */
export function Inverted({children, className, ...rest}: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div className={cn('bg-fill text-onfill', className)} {...rest}>
      {children}
    </div>
  )
}

/**
 * The left-rule callout: `border-left:2px solid ink; padding-left:20px`, a 17px lead and a 15px
 * follow. The design's way of saying something important without a box or a colour.
 */
export function Callout({
  lead,
  children,
  title,
  className,
  ...rest
}: {lead?: React.ReactNode; children?: React.ReactNode; title?: string} & React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div className={cn('border-l-2 border-ink py-0.5 pl-5', className)} {...rest}>
      {title ? <p className="ledger-label">{title}</p> : null}
      {lead ? <p className={cn('text-[17px] leading-[1.45]', title && 'mt-2')}>{lead}</p> : null}
      {children ? <div className="mt-2.5 space-y-2 text-[15px] leading-normal text-dim">{children}</div> : null}
    </div>
  )
}

/**
 * A numbered step: a mono ordinal in a 44px column, a 21–22px line, and a dim gloss under it.
 * `tone="onfill"` is the same block inside an {@link Inverted} panel.
 */
export function Step({
  n,
  head,
  body,
  tone = 'paper',
}: {
  n: string
  head: React.ReactNode
  body?: React.ReactNode
  tone?: 'paper' | 'onfill'
}) {
  return (
    <div
      className={cn(
        'grid grid-cols-[44px_minmax(0,1fr)] gap-5 border-b py-5',
        tone === 'onfill' ? 'border-onfill-hair' : 'border-hair',
      )}
    >
      <span
        className={cn(
          'pt-1.5 font-mono text-[11px] tracking-[0.08em]',
          tone === 'onfill' ? 'opacity-55' : 'text-dim',
        )}
      >
        {n}
      </span>
      <div>
        <div className="text-[21px] leading-[1.25]">{head}</div>
        {body ? (
          <div className={cn('mt-1 text-[15px] leading-normal', tone === 'onfill' ? 'opacity-60' : 'text-dim')}>
            {body}
          </div>
        ) : null}
      </div>
    </div>
  )
}

/**
 * A `k / v / b` row: a serif label, a mono tabular figure, and an optional gloss underneath.
 *
 * This is the design's workhorse and it appears on every screen. Note what it is *not*: the label is
 * serif at reading size, not a mono uppercase micro-label. Ledger reserves mono for figures and for
 * the labels *above* a group, never for the label beside a number.
 */
export function DataRow({
  label,
  children,
  note,
  labelClassName,
  className,
  ...rest
}: {
  label: React.ReactNode
  children: React.ReactNode
  note?: React.ReactNode
  labelClassName?: string
} & Omit<React.HTMLAttributes<HTMLDivElement>, 'children'>) {
  return (
    <div className={cn('flex items-start justify-between gap-5 border-b border-hair py-3', className)} {...rest}>
      <div className="min-w-0">
        <div className={cn('text-[16px] leading-snug', labelClassName)}>{label}</div>
        {note ? <div className="max-w-[56ch] text-[13px] leading-[1.45] text-dim">{note}</div> : null}
      </div>
      <div className="ledger-value shrink-0 text-right">{children}</div>
    </div>
  )
}

/** The label above a group of {@link DataRow}s, and the 2px or 1px rule under it. */
export function RowGroup({
  label,
  rule = 'ink',
  children,
  aside,
  className,
  ...rest
}: {
  label?: string
  rule?: 'ink' | 'rule' | 'none'
  children: React.ReactNode
  aside?: React.ReactNode
} & Omit<React.HTMLAttributes<HTMLDivElement>, 'children'>) {
  return (
    <div className={className} {...rest}>
      {label || aside ? (
        <div className="mb-2 flex items-baseline justify-between gap-4">
          {label ? <p className="ledger-label">{label}</p> : <span />}
          {aside ? <p className="ledger-micro">{aside}</p> : null}
        </div>
      ) : null}
      <div className={rule === 'ink' ? 'border-t-2 border-ink' : rule === 'rule' ? 'border-t border-rule' : undefined}>
        {children}
      </div>
    </div>
  )
}

/** The narrow measure body copy is set to. Ledger never runs prose the full width. */
export function Prose({children, className}: {children: React.ReactNode; className?: string}) {
  return <div className={cn('max-w-[70ch] space-y-4 leading-relaxed', className)}>{children}</div>
}

/**
 * The design's asset mark: a `size × size` box ruled in `--rule` with the symbol's first two
 * letters in mono, dim.
 *
 * The design's own `mark()` helper tries a remote logo first and falls back to exactly this
 * monogram. This interface only ever draws the fallback: there is no logo source in
 * `@amplestocks/config`, a remote image would be a third-party read on every page, and a broken
 * `img` is a worse mark than a good monogram. The measurements are the design's — 30px on the
 * landing grid, 24px in a redemption list, 20px in a table row.
 */
export function AssetMark({symbol, size = 20}: {symbol: string; size?: number}) {
  return (
    <span
      aria-hidden="true"
      className="flex shrink-0 items-center justify-center border border-rule font-mono tracking-[0.04em] text-dim"
      style={{width: size, height: size, fontSize: size >= 28 ? 10 : 8}}
    >
      {symbol.slice(0, 2)}
    </span>
  )
}

/**
 * The design's numbered disclosure: an ordinal in a 32px mono column, a 28px title, a dim gloss,
 * and a mono verb pinned right — all of it one button on a `1px solid ink` top rule, with the open
 * body indented to 52px so the rows hang under the title rather than under the number.
 *
 * The Vault screen stacks three of these (Supply, Parameters, Protocol-owned liquidity) and closes
 * the stack with a fourth rule, which is what {@link DisclosureStack} adds.
 */
export function Disclosure({
  n,
  title,
  note,
  open,
  onToggle,
  children,
  id,
}: {
  n: string
  title: string
  note?: string
  open: boolean
  onToggle: () => void
  children: React.ReactNode
  id?: string
}) {
  const panelId = `${id ?? title.toLowerCase().replace(/\W+/g, '-')}-panel`
  return (
    <div className="border-t border-ink" {...(id ? {'data-testid': id} : {})}>
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={open}
        aria-controls={panelId}
        className="flex min-h-[44px] w-full flex-wrap items-baseline gap-x-3 gap-y-1.5 py-4 text-left sm:gap-x-5 sm:py-[22px]"
      >
        <span className="w-8 shrink-0 font-mono text-[9px] tracking-[0.12em] text-dim sm:text-[10px] sm:tracking-[0.14em]">
          {n}
        </span>
        <span className="text-[20px] tracking-[-0.02em] sm:text-[28px] sm:leading-[1.15]">{title}</span>
        {note ? <span className="hidden max-w-[40ch] text-[15px] text-dim sm:ml-4 sm:inline">{note}</span> : null}
        <span className="ml-auto font-mono text-[11px] uppercase tracking-[0.14em] text-dim">
          {open ? 'Close' : 'Open'}
        </span>
      </button>
      <div id={panelId} hidden={!open} className="pb-[34px] sm:pl-[52px]">
        {children}
      </div>
    </div>
  )
}

/** A run of {@link Disclosure}s, closed off by the rule the design draws under the last one. */
export function DisclosureStack({children, className}: {children: React.ReactNode; className?: string}) {
  return (
    <div className={className}>
      {children}
      <div role="presentation" className="border-t border-ink" />
    </div>
  )
}
