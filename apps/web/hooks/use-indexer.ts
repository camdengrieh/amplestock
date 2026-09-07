// SPDX-License-Identifier: MIT
'use client'

import {useQuery} from '@tanstack/react-query'
import * as React from 'react'

import {publicEnv} from '@/lib/env'
import {IndexerClient, createIndexerClient, type IndexerResult} from '@/lib/indexer/client'

/**
 * The indexer client, as a hook.
 *
 * Never throws and never retries hard: an unreachable indexer is a normal state, and the panels it
 * feeds render "unavailable" rather than zero. Nothing a user can trade on comes from here.
 */
export function useIndexerClient(baseUrl = publicEnv.indexerUrl): IndexerClient {
  return React.useMemo(() => createIndexerClient(baseUrl), [baseUrl])
}

export function useIndexerQuery<T>(key: readonly unknown[], fetcher: (client: IndexerClient) => Promise<IndexerResult<T>>, options?: {enabled?: boolean; refetchInterval?: number}) {
  const client = useIndexerClient()
  const query = useQuery({
    queryKey: ['indexer', client.baseUrl, ...key],
    queryFn: () => fetcher(client),
    enabled: options?.enabled ?? true,
    refetchInterval: options?.refetchInterval ?? false,
    retry: 0,
  })
  const result = query.data
  return {
    ...query,
    value: result?.ok ? result.data : undefined,
    unavailable: result !== undefined && !result.ok,
    reason: result !== undefined && !result.ok ? result.error : undefined,
    configured: client.baseUrl !== '',
  }
}
