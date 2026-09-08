// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useReadContract, useSimulateContract} from 'wagmi'
import type {Address} from 'viem'

import {
  BurnHistoryTable,
  CheckpointBar,
  CreatorSchedulePanel,
  FeeFlowPanel,
  GateStatusTable,
  HoldingsTable,
  LadderFillPanel,
  NavHistoryPanel,
  PolDepthTable,
  RolloutPanel,
  SupplyBreakdown,
  VaultHeadline,
  type GateRow,
  type HoldingRow,
  type PolRow,
} from './vault-panels'
import {FieldRow} from '@/components/common/stat'
import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {TxButton, TxError} from '@/components/common/tx'
import {Value} from '@/components/common/value'
import {Disclosure, DisclosureStack, SectionHead} from '@/components/ledger/primitives'
import {useIndexerQuery} from '@/hooks/use-indexer'
import {symbolForCounter, usePoolDirectory} from '@/hooks/use-pools'
import {useLastPlacementAt, usePolAmounts} from '@/hooks/use-pol'
import {useActiveConstituents, useConstituentRecords, useRegistrySummary} from '@/hooks/use-registry'
import {useTx} from '@/hooks/use-tx'
import {useCreatorBps, useLadderLengths, useVaultSnapshot} from '@/hooks/use-vault'
import {abis, addressOf, contract} from '@/lib/contracts'
import {NOTES} from '@/lib/copy'
import {formatBps, formatDuration} from '@/lib/format'

/**
 * The Vault surface is the design's disclosure page, in the design's order: the headline band, the
 * checkpoint bar, three numbered disclosures, then the tables that back the numbers.
 *
 * Everything the protocol knows about itself is here, including the parts that are unflattering:
 * bid depth per pool, ladder fill per cell, target weight against realised weight, the creator fee
 * still being paid, the gate state of every pool, and every burn.
 *
 * There is no staking row and no `Staked as xAMPS` bucket. Revision 6 removes it: the AMPS side of
 * every fee is burned after the creator slice, and the counter-asset side stays in the pool as bids.
 */
export function VaultSurface() {
  const {isConnected} = useAccount()
  const vault = contract('vault')
  const vaultAddress = addressOf('vault')
  const ampsToken = contract('amps')
  const now = Math.floor(Date.now() / 1000)
  const [open, setOpen] = React.useState({supply: true, params: false, pol: false, fees: false})
  const toggle = (key: keyof typeof open) => setOpen((state) => ({...state, [key]: !state[key]}))

  const snapshot = useVaultSnapshot()
  const creator = useCreatorBps(now)
  const {pools} = usePoolDirectory()
  const poolIds = React.useMemo(() => pools.map((pool) => pool.poolId), [pools])
  const pol = usePolAmounts(poolIds)
  const placements = useLastPlacementAt(poolIds)
  const ladderLengths = useLadderLengths(poolIds)

  const registry = useRegistrySummary()
  const active = useActiveConstituents()
  const constituentIds = React.useMemo(() => (active.ids ?? []).map((id) => Number(id)), [active.ids])
  const constituents = useConstituentRecords(constituentIds)

  const supply = useReadContract({
    ...(ampsToken ?? {address: undefined as unknown as Address, abi: [] as never}),
    functionName: 'totalSupply',
    query: {enabled: ampsToken !== undefined},
  })

  // AMPS held by the bond shell: minted at purchase, claimed as it vests. There is no dedicated
  // view for "unvested", and the balance is the honest upper bound on it — a claim that has vested
  // but has not been taken is still sitting here.
  const bondsAddress = addressOf('bonds')
  const vesting = useReadContract({
    ...(ampsToken ?? {address: undefined as unknown as Address, abi: [] as never}),
    functionName: 'balanceOf',
    args: bondsAddress ? [bondsAddress] : undefined,
    query: {enabled: ampsToken !== undefined && bondsAddress !== undefined},
  })

  const navHistory = useIndexerQuery(['nav-history'], (client) => client.navHistory({limit: 200}))
  // `/api/pools` carries every pool with its ladder totals and **not** its cells; the per-cell
  // detail is one call per pool at `/api/pools/:poolId/ladder`, issued only for the row the reader
  // has opened. The open row is state here rather than inside the panel precisely so that the
  // fetch can hang off it.
  const ladder = useIndexerQuery(['pools'], (client) => client.pools())
  const [openLadderPoolId, setOpenLadderPoolId] = React.useState<string | null>(null)
  const ladderDetail = useIndexerQuery(
    ['ladder', openLadderPoolId],
    (client) => client.ladderFill(openLadderPoolId as string),
    {enabled: openLadderPoolId !== null},
  )
  const burns = useIndexerQuery(['burns'], (client) => client.burnHistory())
  const creatorFee = useIndexerQuery(['creator-fee'], (client) => client.creatorFee(), {refetchInterval: 60_000})
  const vaultSummary = useIndexerQuery(['vault-summary'], (client) => client.vaultSummary(), {refetchInterval: 30_000})

  const checkpoint = snapshot.checkpoint
  const checkpointAge = checkpoint ? now - checkpoint.timestamp : undefined
  const premiumX18 =
    checkpoint && checkpoint.navPerShareX18 > 0n
      ? (checkpoint.pRefX18 * 10n ** 18n) / checkpoint.navPerShareX18 - 10n ** 18n
      : undefined

  const simulation = useSimulateContract({
    address: vaultAddress,
    abi: abis.vault,
    functionName: 'checkpoint',
    query: {enabled: vaultAddress !== undefined && isConnected},
  })
  const tx = useTx({
    simulation: simulation.data,
    simulationError: simulation.error,
    isSimulating: simulation.isLoading,
    ...(isConnected ? {} : {blockedReason: 'Connect a wallet to call checkpoint().'}),
  })

  const polRows: PolRow[] = pools.map((pool) => {
    const amounts = pol.amounts.get(pool.poolId)
    const lastPlacementAt = placements.lastPlacement.get(pool.poolId)
    const ladderCells = ladderLengths.lengths.get(pool.poolId)
    return {
      poolId: pool.poolId,
      symbol: pool.symbol,
      counterDecimals: pool.symbol === 'USDG' || pool.symbol === 'USDC' ? 6 : 18,
      ...(amounts ? {amps: amounts.amps, counter: amounts.counter} : {}),
      ...(lastPlacementAt ? {lastPlacementAt} : {}),
      ...(ladderCells !== undefined ? {ladderCells} : {}),
    }
  })

  const gateRows: GateRow[] = pools.map((pool) => ({
    poolId: pool.poolId,
    symbol: pool.symbol,
    gateState: pool.quote.gateState,
    session: pool.quote.session,
    feedStale: pool.quote.feedStale,
    corporateFreeze: pool.quote.corporateFreeze,
  }))

  // The design's holdings table carries a Cells column and a Gate column, both of which belong to
  // the constituent's *pool* rather than to the constituent. Joining on the symbol is the only key
  // the two directories share; a constituent with no pool yet keeps both columns unavailable rather
  // than borrowing another pool's state.
  const holdingRows: HoldingRow[] = constituents.records.map((record) => {
    const symbol = symbolForCounter(record.token)
    const pool = pools.find((entry) => entry.symbol === symbol)
    const cells = pool ? ladderLengths.lengths.get(pool.poolId) : undefined
    return {
      id: record.id,
      symbol,
      status: record.status,
      targetWeightBps: record.targetWeightBps,
      ...(record.currentWeightBps !== undefined ? {currentWeightBps: record.currentWeightBps} : {}),
      rolloutWeightBps: record.rolloutWeightBps,
      freezeUntil: record.freezeUntil,
      ...(cells !== undefined ? {ladderCells: cells} : {}),
      ...(pool ? {gateState: pool.quote.gateState} : {}),
    }
  })

  const rolledOutBps = holdingRows.length > 0 ? holdingRows.reduce((sum, row) => sum + row.rolloutWeightBps, 0) : undefined
  const targetBps = holdingRows.length > 0 ? holdingRows.reduce((sum, row) => sum + row.targetWeightBps, 0) : undefined

  if (!vault) {
    return (
      <div className="space-y-10">
        <SurfaceHeading
          kicker="Disclosure page"
          title="Vault"
          lede="What the protocol holds, and what it is doing with it."
        />
        <NotDeployed what="Vault" />
      </div>
    )
  }

  return (
    <div className="space-y-0" data-testid="vault-surface">
      <SurfaceHeading
        kicker="Disclosure page"
        title="Vault"
        rule="none"
        lede="Everything the protocol knows about itself. Headline first; the tables that back each number open underneath."
      />

      <div className="mt-8">
        <VaultHeadline
          {...(checkpoint
            ? {navPerShareX18: checkpoint.navPerShareX18, pRefX18: checkpoint.pRefX18, pMktX18: checkpoint.pMktX18}
            : {})}
          {...(premiumX18 !== undefined ? {premiumX18} : {})}
          {...(snapshot.totalAssetsUsd18 !== undefined ? {totalAssetsUsd18: snapshot.totalAssetsUsd18} : {})}
          {...(checkpointAge !== undefined ? {checkpointAgeSeconds: checkpointAge} : {})}
        />
      </div>

      <div className="mt-5">
        <CheckpointBar {...(checkpointAge !== undefined ? {ageSeconds: checkpointAge} : {})}>
          <TxButton
            phase={tx.phase}
            label="checkpoint()"
            {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
            onClick={() => void tx.send()}
            variant="outline"
            data-testid="checkpoint-button"
          />
        </CheckpointBar>
        <TxError error={tx.error} />
      </div>

      <DisclosureStack className="mt-11">
        <Disclosure
          n="01"
          title="Supply"
          note="Where every AMPS sits right now."
          open={open.supply}
          onToggle={() => toggle('supply')}
          id="vault-section-supply"
        >
          <SupplyBreakdown
            {...(supply.data !== undefined ? {totalSupply: supply.data as bigint} : {})}
            {...(snapshot.inventoryAmps !== undefined ? {inventory: snapshot.inventoryAmps} : {})}
            {...(vesting.data !== undefined ? {vesting: vesting.data as bigint} : {})}
          />
        </Disclosure>

        <Disclosure
          n="02"
          title="Parameters in force"
          note="Each one next to the cap hardcoded in the contract."
          open={open.params}
          onToggle={() => toggle('params')}
          id="vault-section-params"
        >
          <FieldRow label="Redemption fee" hint={NOTES.redemptionFee}>
            <Value unavailable={snapshot.redeemFeeBps === undefined}>
              {snapshot.redeemFeeBps !== undefined ? formatBps(snapshot.redeemFeeBps) : null}
            </Value>
          </FieldRow>
          <FieldRow label="Redemption fee hard cap" hint="Compiled into the vault. Governance cannot widen it.">
            <Value unavailable={snapshot.redeemFeeBpsMax === undefined}>
              {snapshot.redeemFeeBpsMax !== undefined ? formatBps(snapshot.redeemFeeBpsMax) : null}
            </Value>
          </FieldRow>
          <FieldRow
            label="Live ladder cells"
            hint="Hard-capped in the vault, which is what bounds the gas of a redemption."
          >
            <Value unavailable={snapshot.liveCells === undefined}>
              {snapshot.liveCells !== undefined ? String(snapshot.liveCells) : null}
            </Value>
          </FieldRow>
          <FieldRow label="Reference up-rate" hint="Maximum upward move of the reference price per hour.">
            <Value unavailable={snapshot.refUpRateBps === undefined}>
              {snapshot.refUpRateBps !== undefined ? `${formatBps(snapshot.refUpRateBps)} per hour` : null}
            </Value>
          </FieldRow>
          <FieldRow label="Reference divergence band" hint="How far the market may sit from the reference before the fee floor rises.">
            <Value unavailable={snapshot.refDivergenceBps === undefined}>
              {snapshot.refDivergenceBps !== undefined ? formatBps(snapshot.refDivergenceBps) : null}
            </Value>
          </FieldRow>
          <FieldRow label="TWAP window" hint="The observation window the market price is truncated over.">
            <Value unavailable={snapshot.twapWindow === undefined}>
              {snapshot.twapWindow !== undefined ? formatDuration(snapshot.twapWindow) : null}
            </Value>
          </FieldRow>
          <CreatorSchedulePanel
            now={now}
            {...(creator.creatorBps !== undefined ? {creatorBpsNow: creator.creatorBps} : {})}
            {...(snapshot.creatorFeeBps !== undefined ? {creatorFeeBps: snapshot.creatorFeeBps} : {})}
            {...(snapshot.creatorDecaySeconds !== undefined ? {decaySeconds: snapshot.creatorDecaySeconds} : {})}
            {...(snapshot.genesisTimestamp !== undefined ? {genesisTimestamp: snapshot.genesisTimestamp} : {})}
            {...(snapshot.creator ? {creator: snapshot.creator} : {})}
          />
          <RolloutPanel
            {...(snapshot.rolloutBpsPerDay !== undefined ? {bpsPerDay: snapshot.rolloutBpsPerDay} : {})}
            {...(snapshot.rolloutBpsPerDayMax !== undefined ? {bpsPerDayMax: snapshot.rolloutBpsPerDayMax} : {})}
            {...(snapshot.entryFloorBps !== undefined ? {entryFloorBps: snapshot.entryFloorBps} : {})}
            {...(rolledOutBps !== undefined ? {rolledOutBps} : {})}
            {...(targetBps !== undefined ? {targetBps} : {})}
          />
          <FieldRow
            label="Premium to NAV, last checkpoint"
            hint="From the indexer's own copy of the reference checkpoint, so it can be read against the history below. The live number is in the headline."
          >
            <Value
              unavailable={vaultSummary.value?.summary?.premiumBps === undefined}
              reason={vaultSummary.configured ? vaultSummary.reason : 'No indexer configured'}
            >
              {vaultSummary.value?.summary?.premiumBps !== undefined
                ? formatBps(vaultSummary.value.summary.premiumBps)
                : null}
            </Value>
          </FieldRow>
          <FieldRow
            label="Public LP tier"
            hint="And there will not be one. The vault is the only entity placing liquidity."
          >
            <span className="text-dim">None</span>
          </FieldRow>
        </Disclosure>

        <Disclosure
          n="03"
          title="Protocol-owned liquidity"
          note="The entire bid under AMPS, pool by pool."
          open={open.pol}
          onToggle={() => toggle('pol')}
          id="vault-section-pol"
        >
          <PolDepthTable rows={polRows} now={now} />
        </Disclosure>

        <Disclosure
          n="04"
          title="Where the fees went"
          note="Two currencies, treated differently on purpose: the AMPS side is burned, the counter side stays as bids."
          open={open.fees}
          onToggle={() => toggle('fees')}
          id="vault-section-fees"
        >
          <FeeFlowPanel
            {...(vaultSummary.value?.summary ? {summary: vaultSummary.value.summary} : {})}
            {...(creatorFee.value ? {creatorFee: creatorFee.value} : {})}
            unavailable={vaultSummary.unavailable || !vaultSummary.configured}
            {...(vaultSummary.reason ? {reason: vaultSummary.reason} : {})}
          />
        </Disclosure>
      </DisclosureStack>

      <div className="mt-[52px]">
        <HoldingsTable
          rows={holdingRows}
          {...(registry.indexCapBps !== undefined ? {capBps: registry.indexCapBps} : {})}
          {...(registry.indexFloorBps !== undefined ? {floorBps: registry.indexFloorBps} : {})}
          {...(snapshot.liveCells !== undefined ? {liveCells: snapshot.liveCells} : {})}
          {...(registry.poolCount !== undefined ? {poolCount: registry.poolCount} : {})}
        />
      </div>

      <section className="mt-[52px]">
        <SectionHead
          title="Liquidity ladder"
          note="The concentrated-liquidity cells that earn the fees NAV grows on."
          aside="Static grid, placed once"
        />
        <div className="mt-1">
          <LadderFillPanel
            {...(ladder.value ? {pools: ladder.value} : {})}
            {...(ladderDetail.value ? {detail: ladderDetail.value} : {})}
            openPoolId={openLadderPoolId}
            onToggle={setOpenLadderPoolId}
            unavailable={ladder.unavailable || !ladder.configured}
            {...(ladder.reason ? {reason: ladder.reason} : {})}
          />
        </div>
      </section>

      <div className="mt-[52px]">
        <GateStatusTable rows={gateRows} />
      </div>

      <section className="mt-[52px]">
        <SectionHead
          title="NAV per share, over time"
          note="Monotone except for market moves in the assets held."
          aside="Indexer series"
        />
        <div className="mt-5">
          <NavHistoryPanel
            {...(navHistory.value ? {points: navHistory.value} : {})}
            unavailable={navHistory.unavailable || !navHistory.configured}
            {...(navHistory.reason ? {reason: navHistory.reason} : {})}
          />
        </div>
      </section>

      <section className="mt-[52px]">
        <SectionHead title="Burns" note="Every AMPS the protocol has destroyed, and why." aside="Indexer series" />
        <div className="mt-5">
          <BurnHistoryTable
            {...(burns.value ? {history: burns.value} : {})}
            unavailable={burns.unavailable || !burns.configured}
            {...(burns.reason ? {reason: burns.reason} : {})}
          />
        </div>
      </section>
    </div>
  )
}
