// SPDX-License-Identifier: MIT
'use client'

import Link from 'next/link'
import {useRouter} from 'next/navigation'
import * as React from 'react'

import {DocBlock} from './blocks'
import {Kicker} from '@/components/ledger/primitives'
import {Select} from '@/components/ui/select'
import {useDocsFigures} from '@/hooks/use-docs-figures'
import {headingId} from '@/lib/docs/blocks'
import {GROUPS, PAGES, READING_ORDER, neighbours, pagesInGroup, type DocsPage} from '@/lib/docs/pages'
import {cn} from '@/lib/utils'

/**
 * The docs frame, at the design's own measurements: a `252px / 1fr / 208px` grid inside 1400px, a
 * sidebar ruled on its right, an article at `48px 56px 90px`, and a rail ruled on its left.
 *
 * Below 1280px the rail goes: it is navigation for a page you can already see, so it is the first
 * thing that can go. Below 768px the sidebar collapses to a native `<select>` rather than a drawer
 * behind a hamburger — one tap, no overlay, and it works with every screen reader without any of
 * the focus-trapping a drawer would need.
 *
 * The sidebar's search input is the design's; it filters the page list in place. There is no search
 * index and this does not pretend to have one: it matches titles and ledes, and says so when
 * nothing matches.
 */
export function DocsShell({page}: {page: DocsPage}) {
  const figures = useDocsFigures()
  const router = useRouter()
  const {prev, next} = neighbours(page.slug)
  const headings = page.blocks.filter((block) => block.kind === 'h' && block.level === 2)

  return (
    <div className="mx-auto grid w-full max-w-[1400px] grid-cols-1 md:grid-cols-[252px_minmax(0,1fr)] xl:grid-cols-[252px_minmax(0,1fr)_208px]">
      <div className="px-5 pb-2 pt-8 sm:px-7 md:hidden">
        <label htmlFor="docs-jump" className="ledger-label mb-2 block">
          Documentation
        </label>
        <Select
          id="docs-jump"
          data-testid="docs-select"
          value={page.slug}
          onChange={(e) => router.push(`/docs/${e.target.value}`)}
        >
          {GROUPS.map((group) => (
            <optgroup key={group.id} label={group.label}>
              {pagesInGroup(group.id).map((entry) => (
                <option key={entry.slug} value={entry.slug}>
                  {entry.title}
                </option>
              ))}
            </optgroup>
          ))}
        </Select>
      </div>

      <DocsSidebar current={page.slug} />

      <article className="min-w-0 px-5 pb-[90px] pt-12 sm:px-7 md:px-14" data-testid="docs-article">
        <Kicker className="mb-3.5">{page.kicker}</Kicker>
        <h1 className="text-[clamp(34px,4vw,56px)] font-light leading-none tracking-[-0.035em]">{page.title}</h1>
        <p className="mt-5 max-w-[62ch] text-[20px] leading-[1.5] text-dim">{page.lede}</p>
        <div role="presentation" className="mb-2 mt-9 h-0.5 bg-ink" />

        {page.blocks.map((block, i) => (
          <DocBlock key={i} block={block} figures={figures} />
        ))}

        <nav
          aria-label="Pager"
          className="mt-16 flex flex-wrap gap-px border-t border-ink bg-hair"
          data-testid="docs-pager"
        >
          {prev ? (
            <Link
              href={`/docs/${prev.slug}`}
              className="min-w-[220px] flex-1 bg-paper px-6 py-[22px] text-left transition-colors hover:bg-hair"
            >
              <span className="ledger-micro block">Previous</span>
              <span className="mt-1.5 block text-[21px] tracking-[-0.02em]">{prev.title}</span>
            </Link>
          ) : null}
          {next ? (
            <Link
              href={`/docs/${next.slug}`}
              className="min-w-[220px] flex-1 bg-paper px-6 py-[22px] text-right transition-colors hover:bg-hair"
            >
              <span className="ledger-micro block">Next</span>
              <span className="mt-1.5 block text-[21px] tracking-[-0.02em]">{next.title}</span>
            </Link>
          ) : null}
        </nav>
      </article>

      <aside
        className="hidden border-l border-rule px-7 pb-[60px] pl-[22px] pt-12 xl:block"
        data-testid="docs-rail"
      >
        <div className="sticky top-24">
          {headings.length > 0 ? (
            <>
              <p className="ledger-micro mb-3">On this page</p>
              <nav aria-label="On this page">
                {headings.map((block) =>
                  block.kind === 'h' ? (
                    <a
                      key={headingId(block)}
                      href={`#${headingId(block)}`}
                      className="block py-[5px] text-[15px] leading-[1.4] text-dim transition-colors hover:text-ink"
                    >
                      {block.text}
                    </a>
                  ) : null,
                )}
              </nav>
              <div role="presentation" className="my-6 h-px bg-hair" />
            </>
          ) : null}
          <p className="ledger-micro mb-1.5">Source</p>
          <p className="whitespace-pre-line font-mono text-[12px] leading-[1.7] text-dim" data-testid="docs-source">
            {page.source}
          </p>
        </div>
      </aside>
    </div>
  )
}

/**
 * The design's sidebar: a mono search field, then a group label and a run of items each hung off a
 * `border-left` — 1px `--rule` and dim when idle, 2px ink and full contrast when current.
 */
function DocsSidebar({current}: {current: string}) {
  const [query, setQuery] = React.useState('')
  const needle = query.trim().toLowerCase()
  const matches = React.useCallback(
    (page: DocsPage) =>
      needle === '' ||
      page.title.toLowerCase().includes(needle) ||
      page.lede.toLowerCase().includes(needle) ||
      page.slug.includes(needle),
    [needle],
  )
  const anyMatch = PAGES.some(matches)

  return (
    <nav
      aria-label="Documentation"
      className="hidden border-r border-rule pb-[60px] pl-7 pr-6 pt-8 md:block"
      data-testid="docs-sidebar"
    >
      <div className="sticky top-24">
        <label htmlFor="docs-search" className="sr-only">
          Search the docs
        </label>
        <input
          id="docs-search"
          type="search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search the docs"
          data-testid="docs-search"
          className="mb-[26px] w-full border border-rule bg-transparent px-[11px] py-[9px] font-mono text-[11px] tracking-[0.04em] text-ink outline-none placeholder:text-dim focus-visible:border-ink"
        />
        {anyMatch ? (
          GROUPS.map((group) => {
            const items = pagesInGroup(group.id).filter(matches)
            if (items.length === 0) return null
            return (
              <div key={group.id} className="mb-[26px]">
                <p className="ledger-micro mb-2.5">{group.label}</p>
                {items.map((entry) => {
                  const active = entry.slug === current
                  return (
                    <Link
                      key={entry.slug}
                      href={`/docs/${entry.slug}`}
                      aria-current={active ? 'page' : undefined}
                      className={cn(
                        'block py-1.5 text-[16px] transition-colors',
                        active
                          ? 'border-l-2 border-ink pl-3 text-ink'
                          : 'border-l border-rule pl-[13px] text-dim hover:border-ink hover:text-ink',
                      )}
                    >
                      {entry.title}
                    </Link>
                  )
                })}
              </div>
            )
          })
        ) : (
          <p className="text-[15px] leading-normal text-dim" data-testid="docs-search-empty">
            No page matches “{query}”. The search reads titles and ledes only — there is no search index behind it.
          </p>
        )}
      </div>
    </nav>
  )
}

/** The `/docs` index: the same three groups, as a list of rules. */
export function DocsIndex() {
  return (
    <div className="mx-auto w-full max-w-[1400px] px-5 pb-[90px] pt-12 sm:px-7">
      <Kicker className="mb-3.5">Reference</Kicker>
      <h1 className="text-[clamp(34px,4vw,56px)] font-light leading-none tracking-[-0.035em]">Documentation</h1>
      <p className="mt-5 max-w-[62ch] text-[20px] leading-[1.5] text-dim">
        How the protocol works, written against plan revision 6. Every figure on these pages is read from the chain,
        from the deployment record or from the launch parameters when you load it — none of them is typed into the
        page, and a source that cannot answer renders a dash with its reason.
      </p>
      <div role="presentation" className="mb-2 mt-9 h-0.5 bg-ink" />

      {GROUPS.map((group) => (
        <section key={group.id} className="mt-11">
          <p className="ledger-label border-b border-rule pb-2">{group.label}</p>
          {pagesInGroup(group.id).map((page) => (
            <Link
              key={page.slug}
              href={`/docs/${page.slug}`}
              className="grid gap-x-8 gap-y-1.5 border-b border-hair py-5 transition-colors hover:bg-hair sm:grid-cols-[18rem_minmax(0,1fr)]"
            >
              <span className="text-[21px] leading-tight tracking-[-0.02em]">{page.title}</span>
              <span className="max-w-[70ch] text-[15px] leading-normal text-dim">{page.lede}</span>
            </Link>
          ))}
        </section>
      ))}

      <p className="ledger-micro mt-9">
        {PAGES.length} pages · reading order starts at {READING_ORDER[0]?.title ?? '—'}
      </p>
    </div>
  )
}
