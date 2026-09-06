// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useReadContract, useSimulateContract} from 'wagmi'
import type {Address} from 'viem'

import {
  BurnHistoryTable,
  GateStatusTable,
  LadderFillPanel,
  NavHistoryPanel,
  SupplyBreakdown,
  VaultHeadline,
  type GateRow,
} from './vault-panels'
import {FieldRow, Stat, StatGrid} from '@/components/common/stat'
import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {TxButton, TxError} from '@/components/common/tx'
import {Value} from '@/components/common/value'
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'
import {useIndexerQuery} from '@/hooks/use-indexer'
import {usePoolDirectory} from '@/hooks/use-pools'
import {useStaking} from '@/hooks/use-staking'
import {useTx} from '@/hooks/use-tx'
import {useVaultSnapshot} from '@/hooks/use-vault'
import {abis, addressOf, contract} from '@/lib/contracts'
import {NOTES} from '@/lib/copy'
import {creatorBpsAt} from '@/lib/fees'
import {formatAmount, formatBps, formatDuration} from '@/lib/format'
import {CREATOR_DECAY_SECONDS} from '@/lib/protocol'

/**
 * The Vault surface is the disclosure page: everything the protocol knows about itself, including
 * the parts that are unflattering. Bid depth per pool, ladder fill per cell, the creator fee still
 * being paid, the gate state of every pool, and every burn.
 */
export function VaultSurface() {
  const {isConnected} = useAccount()
  const vault = contract('vault')
  const vaultAddress = addressOf('vault')
  const ampsToken = contract('amps')
  const now = Math.floor(Date.now() / 1000)

  const snapshot = useVaultSnapshot()
  const staking = useStaking()
  const {pools} = usePoolDirectory()

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
  // `/api/pools` carries every pool with its ladder totals; the per-cell detail is one call per
  // pool at `/api/pools/:poolId/ladder`, which the pool drill-down uses.
  const ladder = useIndexerQuery(['pools'], (client) => client.pools())
  const burns = useIndexerQuery(['burns'], (client) => client.burnHistory())
  const vaultSummary = useIndexerQuery(['vault-summary'], (client) => client.vaultSummary(), {refetchInterval: 30_000})

  const checkpoint = snapshot.data?.[0]?.result as
    | {navPerShareX18: bigint; pRefX18: bigint; pMktX18: bigint; timestamp: number; blockNumber: number}
    | undefined
  const totalAssets = snapshot.data?.[2]?.result as bigint | undefined
  const inventory = snapshot.data?.[3]?.result as bigint | undefined
  const redeemFeeBps = snapshot.data?.[4]?.result as number | undefined
  const burnBps = snapshot.data?.[5]?.result as number | undefined
  const stakerBps = snapshot.data?.[6]?.result as number | undefined
  const genesisTimestamp = snapshot.data?.[7]?.result as number | undefined
  const liveCells = snapshot.data?.[8]?.result as number | undefined

  const premiumX18 =
    checkpoint && checkpoint.navPerShareX18 > 0n
      ? (checkpoint.pRefX18 * 10n ** 18n) / checkpoint.navPerShareX18 - 10n ** 18n
      : undefined

  const creatorBps = genesisTimestamp ? creatorBpsAt({genesisTimestamp, timestamp: now}) : undefined
  const creatorSecondsLeft = genesisTimestamp ? Math.max(0, genesisTimestamp + CREATOR_DECAY_SECONDS - now) : undefined

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

  const gateRows: GateRow[] = pools.map((pool) => ({
    poolId: pool.poolId,
    symbol: pool.symbol,
    gateState: pool.quote.gateState,
    session: pool.quote.session,
    feedStale: pool.quote.feedStale,
    corporateFreeze: pool.quote.corporateFreeze,
  }))

  if (!vault) {
    return (
      <div className="space-y-6">
        <SurfaceHeading title="Vault" lede="What the protocol holds, and what it is doing with it." />
        <NotDeployed what="Vault" />
      </div>
    )
  }

  return (
    <div className="space-y-8" data-testid="vault-surface">
      <SurfaceHeading
        title="Vault"
        lede="Everything the protocol knows about itself: NAV, the reference price, holdings, ladder fill per cell, the gate state of every pool, and every burn."
      />

      <VaultHeadline
        {...(checkpoint ? {navPerShareX18: checkpoint.navPerShareX18, pRefX18: checkpoint.pRefX18, pMktX18: checkpoint.pMktX18} : {})}
        {...(premiumX18 !== undefined ? {premiumX18} : {})}
        {...(totalAssets !== undefined ? {totalAssetsUsd18: totalAssets} : {})}
        {...(checkpoint ? {checkpointAgeSeconds: now - checkpoint.timestamp} : {})}
      />

      <Card>
        <CardHeader>
          <CardTitle>Checkpoint</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <p className="text-sm text-muted-foreground">{NOTES.checkpoint}</p>
          <TxButton
            phase={tx.phase}
            label="checkpoint()"
            {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
            onClick={() => void tx.send()}
            variant="outline"
            data-testid="checkpoint-button"
          />
          <TxError error={tx.error} />
        </CardContent>
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <SupplyBreakdown
          {...(supply.data !== undefined ? {totalSupply: supply.data as bigint} : {})}
          {...(inventory !== undefined ? {inventory} : {})}
          {...(vesting.data !== undefined ? {vesting: vesting.data as bigint} : {})}
          {...(staking.data?.[0]?.result !== undefined ? {staked: staking.data[0].result as bigint} : {})}
        />
        <Card>
          <CardHeader>
            <CardTitle>Parameters in force</CardTitle>
          </CardHeader>
          <CardContent>
            <FieldRow label="Redemption fee" hint="Hard cap 5%">
              <Value unavailable={redeemFeeBps === undefined}>{redeemFeeBps !== undefined ? formatBps(redeemFeeBps) : null}</Value>
            </FieldRow>
            <FieldRow label="Burn share of AMPS-side fees" hint="Hard cap 25%">
              <Value unavailable={burnBps === undefined}>{burnBps !== undefined ? formatBps(burnBps) : null}</Value>
            </FieldRow>
            <FieldRow label="Staker share of AMPS-side fees" hint="Hard cap 50%">
              <Value unavailable={stakerBps === undefined}>{stakerBps !== undefined ? formatBps(stakerBps) : null}</Value>
            </FieldRow>
            <FieldRow label="Creator fee now" hint="Immutable schedule: 100 bp of sell volume decaying to exactly zero at day 30">
              <Value unavailable={creatorBps === undefined}>{creatorBps !== undefined ? formatBps(creatorBps) : null}</Value>
            </FieldRow>
            <FieldRow label="Creator schedule remaining">
              <Value unavailable={creatorSecondsLeft === undefined}>
                {creatorSecondsLeft !== undefined ? formatDuration(creatorSecondsLeft) : null}
              </Value>
            </FieldRow>
            <FieldRow label="Live ladder cells" hint="Bounded, which is what bounds the gas of a redemption">
              <Value unavailable={liveCells === undefined}>{liveCells !== undefined ? String(liveCells) : null}</Value>
            </FieldRow>
          </CardContent>
        </Card>
      </div>

      <StatGrid>
        <Stat
          label="peg_dev_bp"
          value={vaultSummary.value?.pegDevBp !== undefined ? formatBps(vaultSummary.value.pegDevBp) : undefined}
          unavailable={vaultSummary.value?.pegDevBp === undefined}
          reason={vaultSummary.configured ? vaultSummary.reason : 'No indexer configured'}
          hint="Intraday pool-versus-NAV deviation. A monitoring metric; it is never substituted for the beta inclusion rule."
        />
        <Stat
          label="Rollout moved today"
          value={undefined}
          unavailable
          reason={vaultSummary.configured ? 'Not served yet' : 'No indexer configured'}
          hint="Unfilled entry-pool inventory migrating into the spokes, capped per day"
        />
        <Stat
          label="Pools registered"
          value={pools.length > 0 ? String(pools.length) : undefined}
          unavailable={pools.length === 0}
        />
        <Stat
          label="Inventory AMPS"
          value={inventory !== undefined ? formatAmount(inventory, 18) : undefined}
          unavailable={inventory === undefined}
          hint="Finite. Never minted; sales are burned rather than re-placed."
        />
      </StatGrid>

      <NavHistoryPanel
        {...(navHistory.value ? {points: navHistory.value} : {})}
        unavailable={navHistory.unavailable || !navHistory.configured}
        {...(navHistory.reason ? {reason: navHistory.reason} : {})}
      />

      <GateStatusTable rows={gateRows} />

      <LadderFillPanel
        {...(ladder.value ? {fills: ladder.value} : {})}
        unavailable={ladder.unavailable || !ladder.configured}
        {...(ladder.reason ? {reason: ladder.reason} : {})}
      />

      <BurnHistoryTable
        {...(burns.value ? {burns: burns.value} : {})}
        unavailable={burns.unavailable || !burns.configured}
        {...(burns.reason ? {reason: burns.reason} : {})}
      />
    </div>
  )
}
