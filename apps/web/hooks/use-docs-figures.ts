// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useReadContract} from 'wagmi'
import type {Address} from 'viem'

import {useAuction} from './use-auction'
import {useBondParameters, useDailyIssuance} from './use-bonds'
import {useAmpsFee, usePoolFeeBands} from './use-hook-params'
import {useRegistrySummary} from './use-registry'
import {useCreatorBps, useVaultSnapshot} from './use-vault'
import {activeChainId} from '@/lib/chains'
import {contract} from '@/lib/contracts'
import {deployment, genesisAuctions} from '@/lib/deployment'
import {PHASE_LABEL, q96PriceToWholeX18} from '@/lib/auction'
import {resolveDocFigures, type DocsAuctionRead, type DocsChainReads} from '@/lib/docs/resolve'
import type {FigureId, FigureValue} from '@/lib/docs/figures'

/**
 * Every documentation figure, resolved.
 *
 * This hook does exactly one thing that the pure resolver cannot: gather the live reads. It holds
 * no formatting, no fallbacks and no "if this is missing use that" logic — all of that is in
 * `lib/docs/resolve.ts`, where a test can drive it with every source absent and assert that the
 * page prints dashes rather than zeros.
 *
 * Everything it reads is already read by a surface, so the queries are shared through TanStack
 * Query's cache rather than issued twice.
 */
export function useDocsFigures(): Record<FigureId, FigureValue> {
  const now = Math.floor(Date.now() / 1000)

  const fee = useAmpsFee()
  const feeBands = usePoolFeeBands()
  const vault = useVaultSnapshot()
  const creator = useCreatorBps(now)
  const bonds = useBondParameters()
  const issuance = useDailyIssuance()
  const registry = useRegistrySummary()
  const auctionUsdg = useAuction('usdg')
  const auctionEth = useAuction('eth')

  const ampsToken = contract('amps')
  const supply = useReadContract({
    ...(ampsToken ?? {address: undefined as unknown as Address, abi: [] as never}),
    functionName: 'totalSupply',
    query: {enabled: ampsToken !== undefined},
  })

  const auctions = React.useMemo<Partial<Record<'usdg' | 'eth', DocsAuctionRead>>>(() => {
    const one = (a: typeof auctionUsdg): DocsAuctionRead => ({
      phase: PHASE_LABEL[a.phase],
      ...(a.clearingPriceQ96 !== undefined && a.currencyDecimals !== undefined
        ? {
            clearingPriceX18: q96PriceToWholeX18({
              priceQ96: a.clearingPriceQ96,
              tokenDecimals: a.tokenDecimals,
              currencyDecimals: a.currencyDecimals,
            }),
          }
        : {}),
      ...(a.currencySymbol ? {currencySymbol: a.currencySymbol} : {}),
      ...(a.currencyRaised !== undefined ? {raised: a.currencyRaised} : {}),
      ...(a.currencyDecimals !== undefined ? {currencyDecimals: a.currencyDecimals} : {}),
      ...(a.totalSupply !== undefined ? {trancheSupply: a.totalSupply} : {}),
      ...(a.isGraduated !== undefined ? {isGraduated: a.isGraduated} : {}),
    })
    return {
      ...(auctionUsdg.address ? {usdg: one(auctionUsdg)} : {}),
      ...(auctionEth.address ? {eth: one(auctionEth)} : {}),
    }
  }, [auctionUsdg, auctionEth])

  const reads = React.useMemo<DocsChainReads>(
    () => ({
      ...(fee.ampsFeeBps !== undefined ? {ampsFeeBps: fee.ampsFeeBps} : {}),
      ampsFeeBand: fee.band,
      ...(fee.totalFeeBpsMax !== undefined ? {totalFeeBpsMax: fee.totalFeeBpsMax} : {}),
      entryBaseFeeBand: feeBands.entryBand,
      spokeBaseFeeBand: feeBands.spokeBand,
      ...(feeBands.maxConstituents !== undefined ? {maxConstituents: feeBands.maxConstituents} : {}),

      ...(vault.redeemFeeBps !== undefined ? {redeemFeeBps: vault.redeemFeeBps} : {}),
      ...(vault.redeemFeeBpsMax !== undefined ? {redeemFeeBpsMax: vault.redeemFeeBpsMax} : {}),
      ...(vault.creatorFeeBps !== undefined ? {creatorFeeBps: vault.creatorFeeBps} : {}),
      ...(vault.creatorDecaySeconds !== undefined ? {creatorDecaySeconds: vault.creatorDecaySeconds} : {}),
      ...(creator.creatorBps !== undefined ? {creatorBpsNow: creator.creatorBps} : {}),

      ...(vault.checkpoint
        ? {
            navPerShareX18: vault.checkpoint.navPerShareX18,
            pRefX18: vault.checkpoint.pRefX18,
            pMktX18: vault.checkpoint.pMktX18,
          }
        : {}),
      ...(vault.totalAssetsUsd18 !== undefined ? {totalAssetsUsd18: vault.totalAssetsUsd18} : {}),
      ...(vault.inventoryAmps !== undefined ? {inventoryAmps: vault.inventoryAmps} : {}),
      ...(supply.data !== undefined ? {totalSupply: supply.data as bigint} : {}),
      ...(vault.liveCells !== undefined ? {liveCells: vault.liveCells} : {}),
      ...(vault.assetCount !== undefined ? {assetCount: vault.assetCount} : {}),
      ...(vault.initialized !== undefined ? {initialized: vault.initialized} : {}),
      ...(vault.rolloutBpsPerDay !== undefined ? {rolloutBpsPerDay: vault.rolloutBpsPerDay} : {}),
      ...(vault.rolloutBpsPerDayMax !== undefined ? {rolloutBpsPerDayMax: vault.rolloutBpsPerDayMax} : {}),
      ...(vault.entryFloorBps !== undefined ? {entryFloorBps: vault.entryFloorBps} : {}),
      ...(vault.refUpRateBps !== undefined ? {refUpRateBps: vault.refUpRateBps} : {}),
      ...(vault.refDivergenceBps !== undefined ? {refDivergenceBps: vault.refDivergenceBps} : {}),
      ...(vault.twapWindow !== undefined ? {twapWindow: vault.twapWindow} : {}),
      ...(vault.ladderDoublings !== undefined ? {ladderDoublings: vault.ladderDoublings} : {}),
      ...(vault.ladderTiltX18 !== undefined ? {ladderTiltX18: vault.ladderTiltX18} : {}),
      ...(vault.spokeSeedBps !== undefined ? {spokeSeedBps: vault.spokeSeedBps} : {}),

      ...(bonds.vestSeconds !== undefined ? {bondVestSeconds: bonds.vestSeconds} : {}),
      bondVestBand: bonds.vestBand,
      ...(bonds.epochSeconds !== undefined ? {bondEpochSeconds: bonds.epochSeconds} : {}),
      ...(bonds.minAccretionBps !== undefined ? {bondMinAccretionBps: bonds.minAccretionBps} : {}),
      ...(bonds.dailyCapBps !== undefined ? {bondDailyCapBps: bonds.dailyCapBps} : {}),
      bondDiscountBand: bonds.discountBand,
      ...(bonds.marketCount !== undefined ? {bondMarketCount: bonds.marketCount} : {}),
      ...(issuance.issuance ? {bondIssuedToday: issuance.issuance} : {}),

      ...(registry.poolCount !== undefined ? {poolCount: registry.poolCount} : {}),
      ...(registry.constituentCount !== undefined ? {constituentCount: registry.constituentCount} : {}),
      ...(registry.activeConstituentCount !== undefined
        ? {activeConstituentCount: registry.activeConstituentCount}
        : {}),
      ...(registry.indexCapBps !== undefined ? {indexCapBps: registry.indexCapBps} : {}),
      ...(registry.indexFloorBps !== undefined ? {indexFloorBps: registry.indexFloorBps} : {}),
      auctions,
    }),
    [
      fee.ampsFeeBps,
      fee.band,
      fee.totalFeeBpsMax,
      feeBands.entryBand,
      feeBands.spokeBand,
      feeBands.maxConstituents,
      vault.redeemFeeBps,
      vault.redeemFeeBpsMax,
      vault.creatorFeeBps,
      vault.creatorDecaySeconds,
      creator.creatorBps,
      vault.checkpoint,
      vault.totalAssetsUsd18,
      vault.inventoryAmps,
      supply.data,
      vault.liveCells,
      vault.assetCount,
      vault.initialized,
      vault.rolloutBpsPerDay,
      vault.rolloutBpsPerDayMax,
      vault.entryFloorBps,
      vault.refUpRateBps,
      vault.refDivergenceBps,
      vault.twapWindow,
      vault.ladderDoublings,
      vault.ladderTiltX18,
      vault.spokeSeedBps,
      bonds.vestSeconds,
      bonds.vestBand,
      bonds.epochSeconds,
      bonds.minAccretionBps,
      bonds.dailyCapBps,
      bonds.discountBand,
      bonds.marketCount,
      issuance.issuance,
      registry.poolCount,
      registry.constituentCount,
      registry.activeConstituentCount,
      registry.indexCapBps,
      registry.indexFloorBps,
      auctions,
    ],
  )

  return React.useMemo(
    () => resolveDocFigures({chainId: activeChainId, deployment, auctions: genesisAuctions, reads}),
    [reads],
  )
}
