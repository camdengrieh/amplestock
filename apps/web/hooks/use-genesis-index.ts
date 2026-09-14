// SPDX-License-Identifier: MIT
'use client'

import {useIndexerQuery} from '@/hooks/use-indexer'
import type {AuctionBidRow, AuctionCheckpointRow, GenesisResponse} from '@/lib/indexer/types'

/**
 * `/api/genesis`, as a hook: the public bid book and the per-leg clearing-price series.
 *
 * **History and disclosure only.** Everything a bidder can act on — the phase, the live clearing
 * price, their own bids, whether settlement is possible — is a chain read and stays one
 * (`use-auction.ts`, `use-genesis.ts`). What the indexer adds is the two things a chain read cannot
 * give: every *other* bidder's bid, and what the auction charged over the whole window rather than
 * only at its last checkpoint. `checkpoint()` is a write, not a view, so the series is the only
 * record there is of the price between checkpoints.
 *
 * An unreachable indexer is a normal state and costs exactly these two panels. Nothing here is ever
 * rendered as zero: `unavailable` is handed to `IndexerUnavailable`, and a launch that has not been
 * indexed yet answers 404, which is the correct answer rather than an error.
 */
export interface GenesisIndex {
  /** Every indexed bid in the requested leg (or both), newest first. */
  bids: readonly AuctionBidRow[]
  /** Every indexed checkpoint, oldest first — the clearing-price series. */
  checkpoints: readonly AuctionCheckpointRow[]
  /** The launch row itself, for the figures the adapter has already written. */
  genesis: GenesisResponse['genesis'] | undefined
  isLoading: boolean
  /** The indexer answered with a failure, or did not answer at all. */
  unavailable: boolean
  reason?: string
  /** False when no indexer URL is configured for this deployment at all. */
  configured: boolean
}

export function useGenesisIndex(params: {leg?: 'usdg' | 'eth'; bids?: number; checkpoints?: number} = {}): GenesisIndex {
  const {leg, bids = 50, checkpoints = 200} = params
  const query = useIndexerQuery(
    ['genesis', leg ?? 'both', bids, checkpoints],
    (client) => client.genesis({...(leg ? {leg} : {}), bids, checkpoints}),
    {refetchInterval: 30_000},
  )

  return {
    bids: query.value?.bids ?? [],
    checkpoints: query.value?.checkpoints ?? [],
    genesis: query.value?.genesis,
    isLoading: query.isLoading,
    unavailable: query.unavailable,
    ...(query.reason ? {reason: query.reason} : {}),
    configured: query.configured,
  }
}

/** The rows of one leg, when the caller asked for both. Keeps the two panels off two fetches. */
export function checkpointsOfLeg(
  rows: readonly AuctionCheckpointRow[],
  leg: 'usdg' | 'eth',
): readonly AuctionCheckpointRow[] {
  return rows.filter((row) => row.leg === leg)
}

export function bidsOfLeg(rows: readonly AuctionBidRow[], leg: 'usdg' | 'eth'): readonly AuctionBidRow[] {
  return rows.filter((row) => row.leg === leg)
}
