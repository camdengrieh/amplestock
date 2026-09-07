// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {launchParameters} from '@amplestocks/config'

import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {Value} from '@/components/common/value'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Badge} from '@/components/ui/badge'
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'
import {Table, TableBody, TableCell, TableHead, TableHeader, TableRow} from '@/components/ui/table'
import {useActiveConstituents, useIndexWeights, useRegistrySummary, useTimelockAddress} from '@/hooks/use-registry'
import {useVaultSnapshot} from '@/hooks/use-vault'
import {contract} from '@/lib/contracts'
import {formatBps, formatDuration, shortAddress} from '@/lib/format'
import {constituentStatusNames} from '@/lib/protocol'

/**
 * A parameter, its live value, and the band hardcoded in the contract that consumes it.
 *
 * The band is the point. Governance can move a parameter inside it and can never move it outside;
 * widening a band means a new vault and a migration. Showing the band next to the value is what
 * turns "governance can change the fee" into a bounded statement.
 */
export interface ParameterRow {
  name: string
  live?: number
  format: (value: number) => string
  band: {min: number; max: number} | null
  delay: string
  note: string
}

export function ParameterTable({rows}: {rows: readonly ParameterRow[]}) {
  return (
    <Card data-testid="parameter-table">
      <CardHeader>
        <CardTitle>Live parameters and their hard bands</CardTitle>
      </CardHeader>
      <CardContent>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Parameter</TableHead>
              <TableHead>Live</TableHead>
              <TableHead>Hard band</TableHead>
              <TableHead>Delay</TableHead>
              <TableHead>Note</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.name} data-testid={`param-${row.name}`}>
                <TableCell className="font-mono text-xs">{row.name}</TableCell>
                <TableCell>
                  <Value unavailable={row.live === undefined}>{row.live !== undefined ? row.format(row.live) : null}</Value>
                </TableCell>
                <TableCell className="text-muted-foreground">
                  {row.band ? `${row.format(row.band.min)} – ${row.format(row.band.max)}` : '—'}
                </TableCell>
                <TableCell className="text-muted-foreground">{row.delay}</TableCell>
                <TableCell className="max-w-sm text-xs text-muted-foreground">{row.note}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </CardContent>
    </Card>
  )
}

export interface ConstituentRow {
  id: number
  symbol: string
  status: number
  targetWeightBps: number
  rolloutWeightBps: number
  freezeUntil: number
}

export function ConstituentTable({rows, capBps, floorBps}: {rows: readonly ConstituentRow[]; capBps?: number; floorBps?: number}) {
  return (
    <Card data-testid="constituent-table">
      <CardHeader>
        <CardTitle>Constituents</CardTitle>
      </CardHeader>
      <CardContent>
        <p className="mb-3 text-xs text-muted-foreground">
          Index weight bounds at the live count: floor{' '}
          <Value unavailable={floorBps === undefined}>{floorBps !== undefined ? formatBps(floorBps) : null}</Value>, cap{' '}
          <Value unavailable={capBps === undefined}>{capBps !== undefined ? formatBps(capBps) : null}</Value>. A frozen
          name is still an index member; a retired one is not, and its pool stays as an exit market.
        </p>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Id</TableHead>
              <TableHead>Symbol</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>Target weight</TableHead>
              <TableHead>Rollout weight</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.id} data-testid={`constituent-${row.id}`}>
                <TableCell>{row.id}</TableCell>
                <TableCell className="font-medium">{row.symbol}</TableCell>
                <TableCell>
                  <Badge variant={row.status === 1 ? 'success' : row.status === 3 ? 'warning' : 'muted'}>
                    {constituentStatusNames[row.status] ?? 'UNKNOWN'}
                  </Badge>
                </TableCell>
                <TableCell>{formatBps(row.targetWeightBps)}</TableCell>
                <TableCell>{formatBps(row.rolloutWeightBps)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </CardContent>
    </Card>
  )
}

/**
 * The timelock queue.
 *
 * Read-only, and honest about what it can see: `TimelockController` exposes `getTimestamp(id)` for
 * an operation id you already have, not an enumeration. Listing pending operations needs the
 * `CallScheduled` log stream, which is the indexer's job. Until it serves them, this panel says so
 * rather than implying the queue is empty.
 */
export function TimelockQueue({address, operations}: {address?: string; operations?: readonly {id: string; readyAt: number}[]}) {
  return (
    <Card data-testid="timelock-queue">
      <CardHeader>
        <CardTitle>Timelock queue</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <p className="text-sm text-muted-foreground">
          Safe 3/5 proposes, the timelock executes with an open executor role, and a guardian Safe 2/4 can cancel and can
          impose a disable-only freeze that expires by itself. No governance path can block redemption.
        </p>
        <p className="text-sm">
          Timelock: <Value unavailable={!address}>{address ? shortAddress(address) : null}</Value>
        </p>
        {operations === undefined ? (
          <Alert variant="warning">
            <AlertTitle>Pending operations are not listed</AlertTitle>
            <AlertDescription>
              The timelock does not enumerate its queue on chain — it answers only for an operation id you already hold.
              Listing what is pending needs the <code className="font-mono">CallScheduled</code> log stream from the
              indexer, which is not serving it yet. An empty list here would be a claim this page cannot make.
            </AlertDescription>
          </Alert>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Operation</TableHead>
                <TableHead>Executable from</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {operations.map((op) => (
                <TableRow key={op.id}>
                  <TableCell className="font-mono text-xs">{op.id}</TableCell>
                  <TableCell>{new Date(op.readyAt * 1000).toISOString()}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  )
}

export function GovernanceSurface() {
  const registry = contract('registry')
  const summary = useRegistrySummary()
  const weights = useIndexWeights()
  const active = useActiveConstituents()
  const snapshot = useVaultSnapshot()
  const timelock = useTimelockAddress()

  const capBps = summary.data?.[3]?.result as number | undefined
  const floorBps = summary.data?.[4]?.result as number | undefined

  const rows: ParameterRow[] = [
    {
      name: 'redeemFeeBps',
      ...(snapshot.data?.[4]?.result !== undefined ? {live: Number(snapshot.data[4].result)} : {}),
      format: formatBps,
      band: {min: 0, max: launchParameters.fees.redeemFeeBpsCap},
      delay: '48 h',
      note: 'Taken on redemption and kept by the vault. Redemption itself cannot be paused.',
    },
    {
      name: 'burnBps',
      ...(snapshot.data?.[5]?.result !== undefined ? {live: Number(snapshot.data[5].result)} : {}),
      format: formatBps,
      band: {min: 0, max: launchParameters.fees.burnBpsCap},
      delay: '48 h',
      note: 'Share of AMPS-side fees burned at every compound, after the creator and staker slices.',
    },
    {
      name: 'stakerBps',
      ...(snapshot.data?.[6]?.result !== undefined ? {live: Number(snapshot.data[6].result)} : {}),
      format: formatBps,
      band: {min: 0, max: launchParameters.staking.stakerBpsCap},
      delay: '48 h',
      note: 'Share of AMPS-side fees streamed to xAMPS.',
    },
    {
      name: 'sellFeeBps',
      format: formatBps,
      band: launchParameters.fees.sellFeeBpsBand,
      delay: '48 h',
      note: 'Charged on every AMPS-in swap unless a rotation credit covers it. Read live from the hook per pool.',
    },
    {
      name: 'buyFeeBps (entry pools)',
      format: formatBps,
      band: launchParameters.fees.buyFeeBpsEntryBand,
      delay: '48 h',
      note: 'AMPS/WETH and AMPS/USDG.',
    },
    {
      name: 'buyFeeBps (spokes)',
      format: formatBps,
      band: launchParameters.fees.buyFeeBpsSpokeBand,
      delay: '48 h',
      note: 'AMPS/<stock>. High-volatility names default higher inside the same band.',
    },
    {
      name: 'bond discount d',
      format: formatBps,
      band: launchParameters.bonds.discountBandBps,
      delay: '48 h',
      note: 'Clamped per market between dMin and dMax. A discount only exists while the premium exceeds it.',
    },
    {
      name: 'bond capacity per epoch',
      format: formatBps,
      band: {min: 0, max: launchParameters.bonds.capBpsPerEpochCap},
      delay: '48 h',
      note: 'In basis points of total supply, per market, per epoch.',
    },
    {
      name: 'rolloutBpsPerDay',
      format: formatBps,
      band: {min: 0, max: launchParameters.rollout.rolloutBpsPerDayCap},
      delay: '48 h',
      note: 'Rate at which unfilled entry-pool inventory migrates into the spokes.',
    },
    {
      name: 'refUpRateBps',
      format: formatBps,
      band: launchParameters.reference.refUpRateBpsBand,
      delay: '48 h',
      note: 'Maximum upward move of the reference price per hour. The reference is never below NAV per share.',
    },
  ]

  const constituentRows: ConstituentRow[] = ((active.data as readonly number[] | undefined) ?? []).map((id, i) => ({
    id,
    symbol: `#${id}`,
    status: 1,
    targetWeightBps: Number(weights.weights?.weightsBps[i] ?? 0),
    rolloutWeightBps: 0,
    freezeUntil: 0,
  }))

  if (!registry) {
    return (
      <div className="space-y-6">
        <SurfaceHeading title="Governance" lede="Read-only: what can change, by whom, and how fast." />
        <NotDeployed what="Governance" />
      </div>
    )
  }

  return (
    <div className="space-y-8" data-testid="governance-surface">
      <SurfaceHeading
        title="Governance"
        lede="Read-only. Every parameter here is state a Safe can move through a timelock, inside a band that is hardcoded in the contract consuming it and that cannot be widened without a migration."
      />
      <Alert variant="info">
        <AlertTitle>What governance cannot do</AlertTitle>
        <AlertDescription>
          <p>
            It cannot block redemption: the path contains no gate, no guardian and no pause reference. It cannot widen a
            hard band. It cannot move funds through a policy pointer. It cannot mint AMPS by any route other than the
            bond shell.
          </p>
          <p className="mt-2">
            Delays: {formatDuration(launchParameters.governance.timelockFastSeconds)} for parameters,{' '}
            {formatDuration(launchParameters.governance.timelockSlowSeconds)} for the constituent set and policy
            pointers, {formatDuration(launchParameters.governance.timelockStandbySeconds)} for a standby vault.
          </p>
        </AlertDescription>
      </Alert>

      <ParameterTable rows={rows} />
      <ConstituentTable
        rows={constituentRows}
        {...(capBps !== undefined ? {capBps} : {})}
        {...(floorBps !== undefined ? {floorBps} : {})}
      />
      <TimelockQueue {...(timelock ? {address: timelock} : {})} />
    </div>
  )
}
