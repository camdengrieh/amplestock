// SPDX-License-Identifier: MIT
'use client'

import {useQuery} from '@tanstack/react-query'
import * as React from 'react'
import {useAccount, useBlockNumber, usePublicClient, useReadContract, useReadContracts} from 'wagmi'
import type {Address} from 'viem'

import {ccaAbi, chainlinkAggregatorAbi} from '@/lib/abi/cca'
import {activeChainId} from '@/lib/chains'
import {erc20Abi} from '@/lib/contracts'
import {genesisAuctions, referenceBook, type GenesisAuctionKey} from '@/lib/deployment'
import {auctionPhase, bidStatus, type AuctionPhaseName, type BidStatusName} from '@/lib/auction'

const NATIVE = '0x0000000000000000000000000000000000000000'

export interface AuctionState {
  key: GenesisAuctionKey
  address?: Address
  /** The auction currency. `address(0)` is native ETH. */
  currency?: Address
  currencyIsNative: boolean
  currencySymbol?: string
  currencyDecimals?: number
  token?: Address
  tokenDecimals: number
  totalSupply?: bigint
  startBlock?: bigint
  endBlock?: bigint
  claimBlock?: bigint
  clearingPriceQ96?: bigint
  floorPriceQ96?: bigint
  tickSpacingQ96?: bigint
  nextActiveTickQ96?: bigint
  maxBidPriceQ96?: bigint
  currencyRaised?: bigint
  totalCleared?: bigint
  remainingSupply?: bigint
  isGraduated?: boolean
  lastCheckpointedBlock?: bigint
  /** `{mps, startBlock, endBlock}` — the issuance step in force now. */
  step?: {mps: number; startBlock: bigint; endBlock: bigint}
  cumulativeMps?: number
  fundsRecipient?: Address
  tokensRecipient?: Address
  validationHook?: Address
  phase: AuctionPhaseName
  isLoading: boolean
}

const READS = [
  'currency',
  'token',
  'totalSupply',
  'startBlock',
  'endBlock',
  'claimBlock',
  'clearingPrice',
  'floorPrice',
  'tickSpacing',
  'nextActiveTickPrice',
  'MAX_BID_PRICE',
  'currencyRaised',
  'totalCleared',
  'remainingSupply',
  'isGraduated',
  'lastCheckpointedBlock',
  'step',
  'latestCheckpoint',
  'fundsRecipient',
  'tokensRecipient',
  'validationHook',
] as const

/**
 * One auction, read whole.
 *
 * Everything here is "as of the last checkpoint", which the contract itself warns may be stale —
 * `checkpoint()` is a write, not a view, so a read can only ever be as fresh as the last time
 * somebody paid to advance it. The surface therefore prints `lastCheckpointedBlock` next to the
 * clearing price rather than implying the price is live to the current block, and offers the
 * `checkpoint()` call so a reader can advance it themselves.
 *
 * A read that fails leaves its field `undefined`, never zero. A clearing price of zero and a
 * clearing price that could not be read are different facts, and only one of them is a price.
 */
export function useAuction(key: GenesisAuctionKey): AuctionState {
  const address = genesisAuctions[key]
  const {data: blockNumber} = useBlockNumber({watch: false, query: {refetchInterval: 12_000}})

  const query = useReadContracts({
    contracts: address ? READS.map((functionName) => ({address, abi: ccaAbi, functionName})) : [],
    query: {enabled: address !== undefined, refetchInterval: 12_000},
  })

  const at = <T,>(name: (typeof READS)[number]): T | undefined => {
    const entry = query.data?.[READS.indexOf(name)]
    if (!entry || entry.status !== 'success' || entry.result === undefined || entry.result === null) return undefined
    return entry.result as T
  }

  const currency = at<Address>('currency')
  const currencyIsNative = currency !== undefined && currency.toLowerCase() === NATIVE

  // Native ETH has no ERC-20 to ask, so its symbol and decimals come from the chain metadata the
  // wagmi config already carries rather than from a read that would revert.
  const meta = useReadContracts({
    contracts:
      currency && !currencyIsNative
        ? ([
            {address: currency, abi: erc20Abi, functionName: 'symbol'},
            {address: currency, abi: erc20Abi, functionName: 'decimals'},
          ] as const)
        : [],
    query: {enabled: currency !== undefined && !currencyIsNative},
  })

  const currencySymbol = currencyIsNative
    ? 'ETH'
    : meta.data?.[0]?.status === 'success'
      ? (meta.data[0].result as string)
      : undefined
  const currencyDecimals = currencyIsNative
    ? 18
    : meta.data?.[1]?.status === 'success'
      ? Number(meta.data[1].result)
      : undefined

  const stepRaw = at<{mps: number | bigint; startBlock: bigint; endBlock: bigint}>('step')
  const checkpoint = at<{clearingPrice: bigint; cumulativeMps: number | bigint}>('latestCheckpoint')

  const startBlock = at<bigint>('startBlock')
  const endBlock = at<bigint>('endBlock')
  const claimBlock = at<bigint>('claimBlock')

  return {
    key,
    ...(address ? {address} : {}),
    ...(currency ? {currency} : {}),
    currencyIsNative,
    ...(currencySymbol ? {currencySymbol} : {}),
    ...(currencyDecimals !== undefined ? {currencyDecimals} : {}),
    ...(at<Address>('token') ? {token: at<Address>('token')} : {}),
    tokenDecimals: 18,
    ...(at<bigint>('totalSupply') !== undefined ? {totalSupply: at<bigint>('totalSupply')} : {}),
    ...(startBlock !== undefined ? {startBlock} : {}),
    ...(endBlock !== undefined ? {endBlock} : {}),
    ...(claimBlock !== undefined ? {claimBlock} : {}),
    ...(at<bigint>('clearingPrice') !== undefined ? {clearingPriceQ96: at<bigint>('clearingPrice')} : {}),
    ...(at<bigint>('floorPrice') !== undefined ? {floorPriceQ96: at<bigint>('floorPrice')} : {}),
    ...(at<bigint>('tickSpacing') !== undefined ? {tickSpacingQ96: at<bigint>('tickSpacing')} : {}),
    ...(at<bigint>('nextActiveTickPrice') !== undefined ? {nextActiveTickQ96: at<bigint>('nextActiveTickPrice')} : {}),
    ...(at<bigint>('MAX_BID_PRICE') !== undefined ? {maxBidPriceQ96: at<bigint>('MAX_BID_PRICE')} : {}),
    ...(at<bigint>('currencyRaised') !== undefined ? {currencyRaised: at<bigint>('currencyRaised')} : {}),
    ...(at<bigint>('totalCleared') !== undefined ? {totalCleared: at<bigint>('totalCleared')} : {}),
    ...(at<bigint>('remainingSupply') !== undefined ? {remainingSupply: at<bigint>('remainingSupply')} : {}),
    ...(at<boolean>('isGraduated') !== undefined ? {isGraduated: at<boolean>('isGraduated')} : {}),
    ...(at<bigint>('lastCheckpointedBlock') !== undefined
      ? {lastCheckpointedBlock: at<bigint>('lastCheckpointedBlock')}
      : {}),
    ...(stepRaw
      ? {step: {mps: Number(stepRaw.mps), startBlock: stepRaw.startBlock, endBlock: stepRaw.endBlock}}
      : {}),
    ...(checkpoint ? {cumulativeMps: Number(checkpoint.cumulativeMps)} : {}),
    ...(at<Address>('fundsRecipient') ? {fundsRecipient: at<Address>('fundsRecipient')} : {}),
    ...(at<Address>('tokensRecipient') ? {tokensRecipient: at<Address>('tokensRecipient')} : {}),
    ...(at<Address>('validationHook') ? {validationHook: at<Address>('validationHook')} : {}),
    phase: auctionPhase({
      ...(blockNumber !== undefined ? {blockNumber} : {}),
      ...(startBlock !== undefined ? {startBlock} : {}),
      ...(endBlock !== undefined ? {endBlock} : {}),
      ...(claimBlock !== undefined ? {claimBlock} : {}),
    }),
    isLoading: query.isLoading,
  }
}

export interface BidRow {
  bidId: bigint
  maxPriceQ96: bigint
  /** The currency the bidder committed, in raw units. */
  amount: bigint
  startBlock: bigint
  exitedBlock: bigint
  tokensFilled: bigint
  status: BidStatusName
}

/**
 * The connected wallet's own bids in one auction.
 *
 * `BidSubmitted` is indexed by owner, so the ids come from a filtered log query rather than by
 * walking `nextBidId` and reading every bid in the book — which would be O(everyone's bids) to
 * answer a question about one wallet. Each id is then read back from `bids(id)`, because the event
 * carries the bid as submitted and the storage carries it as it stands now.
 *
 * The log query is bounded by the auction's own `startBlock`: there are no bids before it, and an
 * unbounded `fromBlock: 0` on an Orbit chain with sub-second blocks is a request no public RPC will
 * answer.
 */
export function useMyBids(auction: AuctionState) {
  const {address: owner} = useAccount()
  const client = usePublicClient()

  const logs = useQuery({
    queryKey: ['cca-bids', auction.address, owner, auction.startBlock?.toString()],
    enabled: client !== undefined && auction.address !== undefined && owner !== undefined,
    retry: 0,
    refetchInterval: 20_000,
    queryFn: async (): Promise<bigint[]> => {
      if (!client || !auction.address || !owner) return []
      const events = await client.getContractEvents({
        address: auction.address,
        abi: ccaAbi,
        eventName: 'BidSubmitted',
        args: {owner},
        ...(auction.startBlock !== undefined ? {fromBlock: auction.startBlock} : {}),
        toBlock: 'latest',
      })
      const ids = events
        .map((event) => (event.args as {id?: bigint}).id)
        .filter((id): id is bigint => id !== undefined)
      return Array.from(new Set(ids.map((id) => id.toString()))).map((id) => BigInt(id))
    },
  })

  const ids = logs.data ?? []

  const details = useReadContracts({
    contracts:
      auction.address && ids.length > 0
        ? ids.map((bidId) => ({address: auction.address as Address, abi: ccaAbi, functionName: 'bids' as const, args: [bidId] as const}))
        : [],
    query: {enabled: auction.address !== undefined && ids.length > 0, refetchInterval: 20_000},
  })

  const bids = React.useMemo<BidRow[]>(() => {
    if (!details.data) return []
    const out: BidRow[] = []
    ids.forEach((bidId, i) => {
      const entry = details.data?.[i]
      if (!entry || entry.status !== 'success' || !entry.result) return
      const bid = entry.result as {
        startBlock: bigint
        exitedBlock: bigint
        maxPrice: bigint
        amountQ96: bigint
        tokensFilled: bigint
      }
      out.push({
        bidId,
        maxPriceQ96: bid.maxPrice,
        amount: bid.amountQ96 / (1n << 96n),
        startBlock: bid.startBlock,
        exitedBlock: bid.exitedBlock,
        tokensFilled: bid.tokensFilled,
        status: bidStatus({
          maxPriceQ96: bid.maxPrice,
          ...(auction.clearingPriceQ96 !== undefined ? {clearingPriceQ96: auction.clearingPriceQ96} : {}),
          exitedBlock: bid.exitedBlock,
        }),
      })
    })
    return out.sort((a, b) => Number(a.bidId - b.bidId))
  }, [details.data, ids, auction.clearingPriceQ96])

  return {
    bids,
    /** True when the log query itself failed — the surface says so rather than showing "no bids". */
    unavailable: logs.isError,
    reason: logs.error instanceof Error ? logs.error.message : undefined,
    isLoading: logs.isLoading || details.isLoading,
    hasAccount: owner !== undefined,
    refetch: logs.refetch,
  }
}

/**
 * USDG in dollars, from the Chainlink feed `@amplestocks/config` names.
 *
 * A stablecoin is not a dollar, so the auction's USD column is a real conversion or it is
 * unavailable. There is no ETH/USD feed in the reference book, which is why the ETH auction's USD
 * column is unavailable rather than converted through an assumption.
 */
export function useUsdgUsd() {
  const feed = referenceBook(activeChainId)?.chainlinkUsdgUsd
  const query = useReadContracts({
    contracts: feed
      ? ([
          {address: feed, abi: chainlinkAggregatorAbi, functionName: 'latestRoundData'},
          {address: feed, abi: chainlinkAggregatorAbi, functionName: 'decimals'},
        ] as const)
      : [],
    query: {enabled: feed !== undefined, refetchInterval: 60_000},
  })
  const round = query.data?.[0]?.status === 'success' ? (query.data[0].result as readonly [bigint, bigint, bigint, bigint, bigint]) : undefined
  const decimals = query.data?.[1]?.status === 'success' ? Number(query.data[1].result) : undefined
  const answer = round && round[1] > 0n ? round[1] : undefined
  return {
    ...query,
    feed,
    ...(answer !== undefined ? {answer} : {}),
    ...(decimals !== undefined ? {answerDecimals: decimals} : {}),
    ...(round ? {updatedAt: Number(round[3])} : {}),
  }
}

/** `requiredDemandQ96(price)` — how much more demand it would take to move the clearing price. */
export function useRequiredDemand(auction: AuctionState, priceQ96: bigint | undefined) {
  const enabled = auction.address !== undefined && priceQ96 !== undefined && priceQ96 > 0n
  const query = useReadContract({
    ...(auction.address ? {address: auction.address} : {}),
    abi: ccaAbi,
    functionName: 'requiredDemandQ96',
    ...(enabled ? {args: [priceQ96 as bigint] as const} : {}),
    query: {enabled},
  })
  const raw = query.data as bigint | undefined
  return {...query, enabled, requiredDemand: raw === undefined ? undefined : raw / (1n << 96n)}
}
