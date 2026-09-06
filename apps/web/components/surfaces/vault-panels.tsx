// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'

import {FieldRow, Stat, StatGrid} from '@/components/common/stat'
import {IndexerUnavailable} from '@/components/common/states'
import {Value} from '@/components/common/value'
import {Badge} from '@/components/ui/badge'
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'
import {Table, TableBody, TableCell, TableHead, TableHeader, TableRow} from '@/components/ui/table'
import {NOTES} from '@/lib/copy'
import {formatAmount, formatBps, formatDuration, formatPremiumX18, formatTimestamp, formatUsd18} from '@/lib/format'
import type {BurnEvent, LadderFill, NavPoint} from '@/lib/indexer/types'
import {gateStateName, sessionName} from '@/lib/quoter'
import {sessionLabels} from '@/lib/protocol'

export function VaultHeadline({
  navPerShareX18,
  pRefX18,
  pMktX18,
  premiumX18,
  totalAssetsUsd18,
  checkpointAgeSeconds,
  unavailable,
}: {
  navPerShareX18?: bigint
  pRefX18?: bigint
  pMktX18?: bigint
  premiumX18?: bigint
  totalAssetsUsd18?: bigint
  checkpointAgeSeconds?: number
  unavailable?: boolean
}) {
  return (
    <StatGrid data-testid="vault-headline">
      <Stat
        label="NAV per share"
        emphasis
        value={navPerShareX18 !== undefined ? formatUsd18(navPerShareX18, 4) : undefined}
        unavailable={unavailable || navPerShareX18 === undefined}
      />
      <Stat
        label="Reference price"
        emphasis
        value={pRefX18 !== undefined ? formatUsd18(pRefX18, 4) : undefined}
        unavailable={unavailable || pRefX18 === undefined}
        hint="Rate-limited upward, never below NAV per share"
      />
      <Stat
        label="Market price"
        emphasis
        value={pMktX18 !== undefined && pMktX18 !== 0n ? formatUsd18(pMktX18, 4) : undefined}
        unavailable={unavailable || pMktX18 === undefined || pMktX18 === 0n}
        reason="Not enough observation history yet"
        hint="30-minute truncated TWAP of the AMPS/USDG hub"
      />
      <Stat
        label="Premium to NAV"
        emphasis
        value={premiumX18 !== undefined ? formatPremiumX18(premiumX18) : undefined}
        unavailable={unavailable || premiumX18 === undefined}
        hint={NOTES.premium}
      />
      <Stat
        label="Total assets"
        value={totalAssetsUsd18 !== undefined ? formatUsd18(totalAssetsUsd18) : undefined}
        unavailable={unavailable || totalAssetsUsd18 === undefined}
      />
      <Stat
        label="Checkpoint age"
        value={checkpointAgeSeconds !== undefined ? formatDuration(checkpointAgeSeconds) : undefined}
        unavailable={checkpointAgeSeconds === undefined}
        hint={NOTES.checkpoint}
      />
    </StatGrid>
  )
}

/** Circulating vs inventory vs vesting vs staked. The four buckets `S0` and the bonds split into. */
export function SupplyBreakdown({
  totalSupply,
  inventory,
  vesting,
  staked,
}: {
  totalSupply?: bigint
  inventory?: bigint
  vesting?: bigint
  staked?: bigint
}) {
  const circulating =
    totalSupply !== undefined && inventory !== undefined && vesting !== undefined
      ? totalSupply - inventory - vesting
      : undefined
  return (
    <Card data-testid="supply-breakdown">
      <CardHeader>
        <CardTitle>Supply</CardTitle>
      </CardHeader>
      <CardContent>
        <FieldRow label="Total supply" hint="Bonded AMPS is in supply from purchase, not from claim">
          <Value unavailable={totalSupply === undefined}>{totalSupply !== undefined ? formatAmount(totalSupply, 18) : null}</Value>
        </FieldRow>
        <FieldRow label="Circulating" hint="Total less protocol inventory and unvested bond positions">
          <Value unavailable={circulating === undefined}>{circulating !== undefined ? formatAmount(circulating, 18) : null}</Value>
        </FieldRow>
        <FieldRow label="Protocol inventory" hint="Finite and never minted: the genesis tranche plus re-laddered fee AMPS, less sales">
          <Value unavailable={inventory === undefined}>{inventory !== undefined ? formatAmount(inventory, 18) : null}</Value>
        </FieldRow>
        <FieldRow label="Vesting in bonds">
          <Value unavailable={vesting === undefined}>{vesting !== undefined ? formatAmount(vesting, 18) : null}</Value>
        </FieldRow>
        <FieldRow label="Staked as xAMPS">
          <Value unavailable={staked === undefined}>{staked !== undefined ? formatAmount(staked, 18) : null}</Value>
        </FieldRow>
      </CardContent>
    </Card>
  )
}

/**
 * Ladder fill, per pool, with proceeds per cell.
 *
 * Ladders are static: a cell is placed once and only ever removed by redemption, rollout, the
 * high-water buyback burn or a migration. Nothing is re-centred or re-widened, so "fill" is a real
 * measure of what the market has bought rather than an artefact of a keeper moving ranges.
 */
export function LadderFillPanel({fills, unavailable, reason}: {fills?: readonly LadderFill[]; unavailable?: boolean; reason?: string}) {
  if (unavailable || !fills) {
    return <IndexerUnavailable what="Ladder fill" {...(reason ? {reason} : {})} />
  }
  return (
    <div className="space-y-4" data-testid="ladder-fill">
      {fills.map((fill) => (
        <Card key={fill.poolId}>
          <CardHeader>
            <CardTitle>AMPS / {fill.symbol}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <FieldRow label="Bid depth" hint={NOTES.polDepth}>
              <Value>{fill.bidDepth}</Value>
            </FieldRow>
            <FieldRow label="Unfilled ask inventory">
              <Value>{fill.askInventory}</Value>
            </FieldRow>
            <FieldRow label="Rollout weight">
              <Value>{formatBps(fill.rolloutWeightBps)}</Value>
            </FieldRow>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Cell</TableHead>
                  <TableHead>Ticks</TableHead>
                  <TableHead>Side</TableHead>
                  <TableHead>Placed</TableHead>
                  <TableHead>Filled</TableHead>
                  <TableHead>Proceeds</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {fill.cells.map((cell) => (
                  <TableRow key={cell.bucketIndex}>
                    <TableCell>{cell.bucketIndex}</TableCell>
                    <TableCell className="font-mono text-xs">
                      {cell.lowerTick} … {cell.upperTick}
                    </TableCell>
                    <TableCell>
                      <Badge variant={cell.above ? 'muted' : 'success'}>{cell.above ? 'Ask' : 'Bid'}</Badge>
                    </TableCell>
                    <TableCell>{cell.amount}</TableCell>
                    <TableCell>{Math.round(cell.filledFraction * 100)}%</TableCell>
                    <TableCell>{cell.proceeds}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      ))}
    </div>
  )
}

export interface GateRow {
  poolId: string
  symbol: string
  gateState: number
  session: number
  feedStale: boolean
  corporateFreeze: boolean
}

export function GateStatusTable({rows}: {rows: readonly GateRow[]}) {
  return (
    <Card data-testid="gate-status">
      <CardHeader>
        <CardTitle>Gate status, per pool</CardTitle>
      </CardHeader>
      <CardContent>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Pool</TableHead>
              <TableHead>Gate</TableHead>
              <TableHead>Session</TableHead>
              <TableHead>Feed</TableHead>
              <TableHead>Corporate action</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.poolId} data-testid={`gate-row-${row.symbol}`}>
                <TableCell className="font-medium">AMPS / {row.symbol}</TableCell>
                <TableCell>
                  <Badge variant={row.gateState === 0 ? 'success' : 'warning'}>{gateStateName(row.gateState)}</Badge>
                </TableCell>
                <TableCell>{sessionLabels[sessionName(row.session) as keyof typeof sessionLabels] ?? '—'}</TableCell>
                <TableCell>{row.feedStale ? <Badge variant="warning">Stale</Badge> : <Badge variant="muted">Fresh</Badge>}</TableCell>
                <TableCell>{row.corporateFreeze ? <Badge variant="danger">Frozen</Badge> : <span className="text-muted-foreground">—</span>}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
        <p className="mt-3 text-xs text-muted-foreground">
          No gate state stops a swap or a redemption. Degraded states pause placements and compounding, raise the
          dynamic fee floor, and widen the bond haircut.
        </p>
      </CardContent>
    </Card>
  )
}

export function BurnHistoryTable({burns, unavailable, reason}: {burns?: readonly BurnEvent[]; unavailable?: boolean; reason?: string}) {
  if (unavailable || !burns) return <IndexerUnavailable what="Burn history" {...(reason ? {reason} : {})} />
  return (
    <Card data-testid="burn-history">
      <CardHeader>
        <CardTitle>Burns</CardTitle>
      </CardHeader>
      <CardContent>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>When</TableHead>
              <TableHead>Amount</TableHead>
              <TableHead>Reason</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {burns.map((burn) => (
              <TableRow key={burn.txHash}>
                <TableCell>{formatTimestamp(burn.timestamp)}</TableCell>
                <TableCell>{burn.amount}</TableCell>
                <TableCell className="font-mono text-xs">{burn.reason}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </CardContent>
    </Card>
  )
}

/**
 * NAV per share over time, as an inline sparkline.
 *
 * No chart library: three series, one axis, and a shape that has to survive a build with no
 * network. The series is the indexer's; if the indexer is unavailable the panel says so rather
 * than drawing a flat line at zero.
 */
export function NavHistoryPanel({points, unavailable, reason}: {points?: readonly NavPoint[]; unavailable?: boolean; reason?: string}) {
  if (unavailable || !points || points.length === 0) {
    return <IndexerUnavailable what="NAV per share history" {...(reason ? {reason} : {})} />
  }
  const values = points.map((p) => Number(p.navPerShareX18) / 1e18)
  const min = Math.min(...values)
  const max = Math.max(...values)
  const span = max - min || 1
  const path = values
    .map((v, i) => {
      const x = (i / Math.max(values.length - 1, 1)) * 100
      const y = 30 - ((v - min) / span) * 28
      return `${i === 0 ? 'M' : 'L'}${x.toFixed(2)},${y.toFixed(2)}`
    })
    .join(' ')
  return (
    <Card data-testid="nav-history">
      <CardHeader>
        <CardTitle>NAV per share</CardTitle>
      </CardHeader>
      <CardContent className="space-y-2">
        <svg viewBox="0 0 100 32" preserveAspectRatio="none" className="h-24 w-full" role="img" aria-label="NAV per share over time">
          <path d={path} fill="none" stroke="currentColor" strokeWidth="0.6" className="text-primary" />
        </svg>
        <div className="flex justify-between text-xs text-muted-foreground">
          <span>{min.toFixed(4)}</span>
          <span>{max.toFixed(4)}</span>
        </div>
        <p className="text-xs text-muted-foreground">
          Monotone non-decreasing except for market moves in the assets held. Bonds and redemptions both raise it.
        </p>
      </CardContent>
    </Card>
  )
}
