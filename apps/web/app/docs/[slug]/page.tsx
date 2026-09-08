// SPDX-License-Identifier: MIT
import {notFound} from 'next/navigation'

import {DocsShell} from '@/components/docs/shell'
import {PAGES, PAGES_BY_SLUG} from '@/lib/docs/pages'

/** Every page is known at build time, so all of them prerender. */
export function generateStaticParams() {
  return PAGES.map((page) => ({slug: page.slug}))
}

export async function generateMetadata({params}: {params: Promise<{slug: string}>}) {
  const {slug} = await params
  const page = PAGES_BY_SLUG[slug]
  if (!page) return {title: 'Documentation — Amplestocks'}
  return {title: `${page.title} — Amplestocks docs`, description: page.lede}
}

export default async function DocsPage({params}: {params: Promise<{slug: string}>}) {
  const {slug} = await params
  const page = PAGES_BY_SLUG[slug]
  if (!page) notFound()
  return <DocsShell page={page} />
}
