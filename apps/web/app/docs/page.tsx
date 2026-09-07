// SPDX-License-Identifier: MIT
import {DocsIndex} from '@/components/docs/shell'

export const metadata = {
  title: 'Documentation — Amplestocks',
  description: 'How Amplestocks works, with every figure read from the chain rather than written down.',
}

/**
 * The docs index sits outside the terms gate, like `/risk`.
 *
 * Somebody deciding whether to accept the terms should be able to read what they are accepting
 * first. Nothing here is a trading surface and nothing here can sign anything.
 */
export default function DocsIndexPage() {
  return <DocsIndex />
}
