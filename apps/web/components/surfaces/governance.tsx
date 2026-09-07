// SPDX-License-Identifier: MIT
'use client'

import {launchParameters} from '@amplestocks/config'
import * as React from 'react'

import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {Value} from '@/components/common/value'
import {AssetMark, Callout, SectionHead} from '@/components/ledger/primitives'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Badge} from '@/components/ui/badge'
import {Table, TableBody, TableCell, TableHead, TableHeader, TableRow} from '@/components/ui/table'
import {useBondParameters} from '@/hooks/use-bonds'
import {useAmpsFee, usePoolFeeBands} from '@/hooks/use-hook-params'
import {symbolForCounter} from '@/hooks/use-pools'
import {useActiveConstituents, useConstituentRecords, useRegistrySummary, useTimelockAddress} from '@/hooks/use-registry'
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
 *
 * Both halves are read from the chain where the contract exposes them. Where a band is only
 * available as a launch parameter — a delay held by the timelock rather than by a `pure` getter —
 * it comes from `@amplestocks/config` and the row says so in its note.
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
    <section data-testid="parameter-table">
      <SectionHead
        title="Live parameters and their hard bands"
        note="Governance can move a parameter inside its band and can never move it outside. Widening a band means a new vault and a migration."
        aside={`${rows.length} parameters`}
      />
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Parameter</TableHead>
            <TableHead align="right">Live</TableHead>
            <TableHead align="right">Hard band</TableHead>
            <TableHead align="right">Delay</TableHead>
            <TableHead>Note</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row) => (
            <TableRow key={row.name} data-testid={`param-${row.name}`}>
              <TableCell className="whitespace-nowrap tracking-[0.05em]">{row.name}</TableCell>
              <TableCell align="right">
                <Value unavailable={row.live === undefined}>{row.live !== undefined ? row.format(row.live) : null}</Value>
              </TableCell>
              <TableCell align="right" className="text-dim">
                <Value unavailable={row.band === null} reason="The contract’s own band could not be read">
                  {row.band ? `${row.format(row.band.min)} – ${row.format(row.band.max)}` : null}
                </Value>
              </TableCell>
              <TableCell align="right" className="text-dim">{row.delay}</TableCell>
              <TableCell className="max-w-[52ch] whitespace-normal text-[13px] leading-[1.5] text-dim">
                {row.note}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </section>
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

export function ConstituentTable({
  rows,
  capBps,
  floorBps,
}: {
  rows: readonly ConstituentRow[]
  capBps?: number
  floorBps?: number
}) {
  return (
    <section data-testid="constituent-table">
      <SectionHead
        title="Constituents"
        note="The index set the registry holds, each name with the weight it is asked to carry and the weight the rollout has moved so far."
        aside={`${rows.length} names`}
      />
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead align="right">Id</TableHead>
            <TableHead>Constituent</TableHead>
            <TableHead align="right">Status</TableHead>
            <TableHead align="right">Target weight</TableHead>
            <TableHead align="right">Rollout weight</TableHead>
            <TableHead align="right">Frozen until</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row) => (
            <TableRow key={row.id} data-testid={`constituent-${row.id}`}>
              <TableCell align="right" className="text-dim">
                {row.id}
              </TableCell>
              <TableCell>
                <span className="flex items-center gap-3">
                  <AssetMark symbol={row.symbol} />
                  <span className="whitespace-nowrap tracking-[0.05em]">{row.symbol}</span>
                </span>
              </TableCell>
              <TableCell align="right">
                <Badge variant={row.status === 1 ? 'default' : row.status === 3 ? 'warning' : 'muted'}>
                  {constituentStatusNames[row.status] ?? 'UNKNOWN'}
                </Badge>
              </TableCell>
              <TableCell align="right">{formatBps(row.targetWeightBps)}</TableCell>
              <TableCell align="right" className="text-dim">
                {formatBps(row.rolloutWeightBps)}
              </TableCell>
              <TableCell align="right" className="text-dim">
                <Value unavailable={row.freezeUntil === 0}>
                  {row.freezeUntil > 0 ? String(row.freezeUntil) : null}
                </Value>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
      <p className="mt-4 max-w-[88ch] text-[13px] leading-[1.55] text-dim">
        Index weight bounds at the live count: floor{' '}
        <Value unavailable={floorBps === undefined}>{floorBps !== undefined ? formatBps(floorBps) : null}</Value>, cap{' '}
        <Value unavailable={capBps === undefined}>{capBps !== undefined ? formatBps(capBps) : null}</Value>. A frozen
        name is still an index member; a retired one is not, and its pool stays as an exit market.
      </p>
    </section>
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
export function TimelockQueue({
  address,
  operations,
}: {
  address?: string
  operations?: readonly {id: string; readyAt: number}[]
}) {
  return (
    <section data-testid="timelock-queue">
      <SectionHead
        title="Timelock queue"
        note="Safe 3/5 proposes, the timelock executes with an open executor role, and a guardian Safe 2/4 can cancel and can impose a disable-only freeze that expires by itself. No governance path can block redemption."
        aside={
          <Value unavailable={!address} {...(address ? {title: address} : {})}>
            {address ? shortAddress(address) : null}
          </Value>
        }
      />
      <div className="h-5" />
      {operations === undefined ? (
        <Alert variant="warning">
          <AlertTitle>Pending operations are not listed</AlertTitle>
          <AlertDescription>
            <p>
              The timelock does not enumerate its queue on chain — it answers only for an operation id you already hold.
              Listing what is pending needs the <code className="font-mono">CallScheduled</code> log stream from the
              indexer, which is not serving it yet. An empty list here would be a claim this page cannot make.
            </p>
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
    </section>
  )
}

export function GovernanceSurface() {
  const registryContract = contract('registry')
  const registry = useRegistrySummary()
  const active = useActiveConstituents()
  const constituentIds = React.useMemo(() => (active.ids ?? []).map((id) => Number(id)), [active.ids])
  const constituents = useConstituentRecords(constituentIds)
  const snapshot = useVaultSnapshot()
  const fee = useAmpsFee()
  const feeBands = usePoolFeeBands()
  const bonds = useBondParameters()
  const timelock = useTimelockAddress()

  const rows: ParameterRow[] = [
    {
      name: 'ampsFeeBps',
      ...(fee.ampsFeeBps !== undefined ? {live: fee.ampsFeeBps} : {}),
      format: formatBps,
      band: fee.band,
      delay: formatDuration(launchParameters.governance.timelockFastSeconds),
      note: 'The protocol’s own fee, charged on every swap that touches AMPS — buying it and selling it alike. Read live from AmpsHook; the band is the hook’s own compiled constant. (On chain the getter is still named ampsFeeBps.)',
    },
    {
      name: 'redeemFeeBps',
      ...(snapshot.redeemFeeBps !== undefined ? {live: snapshot.redeemFeeBps} : {}),
      format: formatBps,
      band:
        snapshot.redeemFeeBpsMax !== undefined ? {min: 0, max: snapshot.redeemFeeBpsMax} : null,
      delay: formatDuration(launchParameters.governance.timelockFastSeconds),
      note: 'Taken on redemption and kept by the vault. Redemption itself cannot be paused. Both the live value and the ceiling are read from the vault.',
    },
    {
      name: 'buyFeeBps (entry pools)',
      format: formatBps,
      band: feeBands.entryBand,
      delay: formatDuration(launchParameters.governance.timelockFastSeconds),
      note: 'AMPS/WETH and AMPS/USDG. Charged on top of the AMPS fee only when the swap is one leg of a pass-through. The live value is per pool and is shown on Buy / Sell.',
    },
    {
      name: 'buyFeeBps (spokes)',
      format: formatBps,
      band: feeBands.spokeBand,
      delay: formatDuration(launchParameters.governance.timelockFastSeconds),
      note: 'AMPS/<stock>. High-volatility names default higher inside the same band.',
    },
    {
      name: 'bond discount d',
      format: formatBps,
      band: bonds.discountBand,
      delay: formatDuration(launchParameters.governance.timelockFastSeconds),
      note: 'Clamped per market between dMin and dMax. A discount only exists while the premium exceeds it.',
    },
    {
      name: 'minAccretionBps',
      ...(bonds.minAccretionBps !== undefined ? {live: bonds.minAccretionBps} : {}),
      format: formatBps,
      band: bonds.minAccretionBpsMax !== undefined ? {min: 0, max: bonds.minAccretionBpsMax} : null,
      delay: formatDuration(launchParameters.governance.timelockFastSeconds),
      note: 'A bond that would accrete less than this to NAV per share is refused by the shell itself, whatever the pricing policy says.',
    },
    {
      name: 'dailyCapBps',
      ...(bonds.dailyCapBps !== undefined ? {live: bonds.dailyCapBps} : {}),
      format: formatBps,
      band: bonds.dailyCapBpsMax !== undefined ? {min: 0, max: bonds.dailyCapBpsMax} : null,
      delay: formatDuration(launchParameters.governance.timelockFastSeconds),
      note: 'Global bond issuance per day, in basis points of total supply.',
    },
    {
      name: 'vestSeconds',
      ...(bonds.vestSeconds !== undefined ? {live: bonds.vestSeconds} : {}),
      format: (v) => formatDuration(v),
      band: bonds.vestBand,
      delay: formatDuration(launchParameters.governance.timelockFastSeconds),
      note: 'How long a bond vests, linearly, from purchase. The AMPS is in total supply from purchase either way.',
    },
    {
      name: 'rolloutBpsPerDay',
      ...(snapshot.rolloutBpsPerDay !== undefined ? {live: snapshot.rolloutBpsPerDay} : {}),
      format: formatBps,
      band: snapshot.rolloutBpsPerDayMax !== undefined ? {min: 0, max: snapshot.rolloutBpsPerDayMax} : null,
      delay: formatDuration(launchParameters.governance.timelockFastSeconds),
      note: 'Rate at which unfilled entry-pool inventory migrates into the spokes.',
    },
    {
      name: 'refUpRateBps',
      ...(snapshot.refUpRateBps !== undefined ? {live: snapshot.refUpRateBps} : {}),
      format: formatBps,
      band: launchParameters.reference.refUpRateBpsBand,
      delay: formatDuration(launchParameters.governance.timelockFastSeconds),
      note: 'Maximum upward move of the reference price per hour. The reference is never below NAV per share. The band is a launch parameter; the vault does not expose it as a getter.',
    },
    {
      name: 'creator schedule',
      ...(snapshot.creatorFeeBps !== undefined ? {live: snapshot.creatorFeeBps} : {}),
      format: formatBps,
      band: null,
      delay: 'Immutable',
      note: 'One per cent of trade volume at genesis, decaying linearly to exactly zero at day 30. There is no setter and no governance path to it; the remaining schedule is on the Vault page.',
    },
  ]

  const constituentRows: ConstituentRow[] = constituents.records.map((record) => ({
    id: record.id,
    symbol: symbolForCounter(record.token),
    status: record.status,
    targetWeightBps: record.targetWeightBps,
    rolloutWeightBps: record.rolloutWeightBps,
    freezeUntil: record.freezeUntil,
  }))

  if (!registryContract) {
    return (
      <div className="space-y-10">
        <SurfaceHeading
          kicker="Read-only"
          title="Governance"
          lede="Read-only: what can change, by whom, and how fast."
        />
        <NotDeployed what="Governance" />
      </div>
    )
  }

  return (
    <div className="space-y-14" data-testid="governance-surface">
      <SurfaceHeading
        kicker="Read-only"
        title="Governance"
        lede="Every parameter here is state a Safe can move through a timelock, inside a band that is hardcoded in the contract consuming it and that cannot be widened without a migration."
      />

      <Callout
        title="What governance cannot do"
        lead="It cannot block redemption: the path contains no gate, no guardian and no pause reference."
      >
        <p>
          It cannot widen a hard band. It cannot move funds through a policy pointer. It cannot mint AMPS by any route
          other than the bond shell. It cannot touch the creator schedule, which has no setter.
        </p>
        <p>
          Delays: {formatDuration(launchParameters.governance.timelockFastSeconds)} for parameters,{' '}
          {formatDuration(launchParameters.governance.timelockSlowSeconds)} for the constituent set and policy pointers,{' '}
          {formatDuration(launchParameters.governance.timelockStandbySeconds)} for a standby vault.
        </p>
        <p>
          There is no <code className="font-mono">burnBps</code> and no <code className="font-mono">stakerBps</code>.
          Revision 6 removes staking, and the burn is no longer a governed share: the AMPS side of every fee is burned
          after the creator slice.
        </p>
      </Callout>

      <ParameterTable rows={rows} />
      <ConstituentTable
        rows={constituentRows}
        {...(registry.indexCapBps !== undefined ? {capBps: registry.indexCapBps} : {})}
        {...(registry.indexFloorBps !== undefined ? {floorBps: registry.indexFloorBps} : {})}
      />
      <TimelockQueue {...(timelock ? {address: timelock} : {})} />
    </div>
  )
}
