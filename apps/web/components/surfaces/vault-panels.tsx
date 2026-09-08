// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {hexToString} from 'viem'

import {FieldRow, Stat, StatGrid} from '@/components/common/stat'
import {EmptyState, IndexerUnavailable} from '@/components/common/states'
import {Value} from '@/components/common/value'
import {AssetMark, DataRow, SectionHead} from '@/components/ledger/primitives'
import {Badge} from '@/components/ui/badge'
import {Button} from '@/components/ui/button'
import {Table, TableBody, TableCell, TableHead, TableHeader, TableRow} from '@/components/ui/table'
import {NOTES} from '@/lib/copy'
import {
  formatAmount,
  formatBps,
  formatDuration,
  formatPremiumX18,
  formatTimestamp,
  formatUsd18,
  shortAddress,
} from '@/lib/format'
import type {
  BurnHistory,
  CreatorFeeStatus,
  LadderDetail,
  NavPoint,
  PoolRow,
  VaultSummary,
} from '@/lib/indexer/types'
import {PLACEMENT_COOLDOWN_SECONDS, constituentStatusNames, sessionLabels} from '@/lib/protocol'
import {gateStateName, sessionName} from '@/lib/quoter'

/**
 * The headline band the design opens Vault with: `repeat(auto-fit, minmax(200px,1fr))` over a 2px
 * ink rule, each cell a mono label, a 44px figure and a 13px gloss.
 *
 * The design prints four cells; this prints six, because the two it leaves out — total assets and
 * the age of the checkpoint the other four were read at — are the provenance of the first four and
 * the page is a disclosure page.
 */
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
    <StatGrid min={180} data-testid="vault-headline">
      <Stat
        label="NAV per share"
        value={navPerShareX18 !== undefined ? formatUsd18(navPerShareX18, 4) : undefined}
        unavailable={unavailable || navPerShareX18 === undefined}
        hint="Live balances at the reference price, per share."
      />
      <Stat
        label="Reference price"
        value={pRefX18 !== undefined ? formatUsd18(pRefX18, 4) : undefined}
        unavailable={unavailable || pRefX18 === undefined}
        hint="Rate-limited upward. Never below NAV per share."
      />
      <Stat
        label="Market price"
        value={pMktX18 !== undefined && pMktX18 !== 0n ? formatUsd18(pMktX18, 4) : undefined}
        unavailable={unavailable || pMktX18 === undefined || pMktX18 === 0n}
        reason="Not enough observation history yet"
        hint="30-minute truncated TWAP of the AMPS/USDG hub."
      />
      <Stat
        label="Premium to NAV"
        value={premiumX18 !== undefined ? formatPremiumX18(premiumX18) : undefined}
        unavailable={unavailable || premiumX18 === undefined}
        hint={NOTES.premium}
      />
      <Stat
        label="Total assets"
        value={totalAssetsUsd18 !== undefined ? formatUsd18(totalAssetsUsd18) : undefined}
        unavailable={unavailable || totalAssetsUsd18 === undefined}
        hint="Marked from live balances at the reference price."
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

/**
 * The design's checkpoint bar: `Last checkpoint 12m 4s ago` in mono on the left, the outline
 * `checkpoint()` button pushed right, both sitting on a single `--rule` hairline.
 *
 * It is one row rather than a section because that is what it is — a fact and the button that
 * changes it. The button is deliberately the outline variant: the fill is reserved for the thing a
 * surface exists to do, and Vault exists to disclose, not to checkpoint.
 */
export function CheckpointBar({
  ageSeconds,
  children,
}: {
  ageSeconds?: number
  /** The `TxButton`, wired by the surface. */
  children: React.ReactNode
}) {
  return (
    <div
      className="flex flex-wrap items-center gap-4 border-b border-rule py-3.5"
      data-testid="checkpoint-bar"
    >
      <span className="font-mono text-[12px] text-dim">
        {ageSeconds === undefined ? 'Checkpoint age unavailable' : `Last checkpoint ${formatDuration(ageSeconds)} ago`}
      </span>
      <span className="max-w-[62ch] text-[13px] leading-normal text-dim">{NOTES.checkpoint}</span>
      <div className="ml-auto">{children}</div>
    </div>
  )
}

/**
 * Disclosure 01 — Supply. Three buckets, not four: revision 6 removes staking, so there is no
 * staked balance to subtract and no xAMPS to name.
 */
export function SupplyBreakdown({
  totalSupply,
  inventory,
  vesting,
}: {
  totalSupply?: bigint
  inventory?: bigint
  vesting?: bigint
}) {
  const circulating =
    totalSupply !== undefined && inventory !== undefined && vesting !== undefined
      ? totalSupply - inventory - vesting
      : undefined
  return (
    <div data-testid="supply-breakdown">
      <FieldRow label="Total supply" hint="Bonded AMPS counts from purchase, not from claim.">
        <Value unavailable={totalSupply === undefined}>
          {totalSupply !== undefined ? formatAmount(totalSupply, 18) : null}
        </Value>
      </FieldRow>
      <FieldRow label="Circulating" hint="Total, less protocol inventory and unvested bond positions.">
        <Value unavailable={circulating === undefined}>
          {circulating !== undefined ? formatAmount(circulating, 18) : null}
        </Value>
      </FieldRow>
      <FieldRow
        label="Protocol inventory"
        hint="Finite and never minted. Genesis tranche plus re-laddered fee AMPS, less sales."
      >
        <Value unavailable={inventory === undefined}>
          {inventory !== undefined ? formatAmount(inventory, 18) : null}
        </Value>
      </FieldRow>
      <FieldRow
        label="Vesting in bonds"
        hint="An upper bound: AmpsBonds cannot enumerate its own positions, so vested-but-unclaimed AMPS is still counted here."
      >
        <Value unavailable={vesting === undefined}>{vesting !== undefined ? formatAmount(vesting, 18) : null}</Value>
      </FieldRow>
      <FieldRow
        label="Minting routes"
        hint="AMPS is minted by the bond shell and by nothing else. There is no staking contract and no public LP tier."
      >
        <span className="text-dim">Bond shell only</span>
      </FieldRow>
    </div>
  )
}

export interface HoldingRow {
  id: number
  symbol: string
  status: number
  /** What the registry says the index should hold. */
  targetWeightBps: number
  /** What the vault holds now, priced at the reference. `undefined` when the read failed. */
  currentWeightBps?: number
  /** How much of the target the rollout has migrated so far. */
  rolloutWeightBps: number
  freezeUntil: number
  /** Grid cells live in this constituent's pool, from `AmpsVault.ladderLength`. */
  ladderCells?: number
  /** The pool's gate state, from `AmpsQuoter`. `undefined` when there is no pool for it yet. */
  gateState?: number
}

/**
 * "Holdings, position by position" — the design's seven-column table, over the design's section
 * head, with the design's eight-row default and its "show all" toggle.
 *
 * The design's columns are Value / Stock side / AMPS side / Cells / Fees 30d / Gate. Four of those
 * are kept as drawn; two are replaced by the pair that actually governs this index — the target
 * weight the registry sets and the realised weight the vault holds — because publishing one number
 * and calling it "the weight" would hide the thing that is interesting: the rollout moves inventory
 * on a daily cap and the market moves the assets in between.
 */
export function HoldingsTable({
  rows,
  capBps,
  floorBps,
  liveCells,
  poolCount,
}: {
  rows: readonly HoldingRow[]
  capBps?: number
  floorBps?: number
  liveCells?: number
  poolCount?: number
}) {
  const [all, setAll] = React.useState(false)
  const shown = all ? rows : rows.slice(0, 8)
  return (
    <section className="space-y-0" data-testid="holdings">
      <SectionHead
        title="Holdings, position by position"
        note="Each row is one Uniswap v4 concentrated-liquidity position in that stock’s own AMPS pool, shown against the weight the registry asks it to carry."
        aside={
          <>
            <Value unavailable={liveCells === undefined}>{liveCells !== undefined ? liveCells : null}</Value> live cells
            ·{' '}
            <Value unavailable={poolCount === undefined}>{poolCount !== undefined ? poolCount : null}</Value> pools
          </>
        }
      />
      {rows.length === 0 ? (
        <EmptyState title="No constituents">
          The registry has no active constituent to read. Nothing is being hidden — there is nothing there yet.
        </EmptyState>
      ) : (
        <>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Position</TableHead>
                <TableHead align="right">Target</TableHead>
                <TableHead align="right">Realised</TableHead>
                <TableHead align="right">Drift</TableHead>
                <TableHead align="right">Rolled out</TableHead>
                <TableHead align="right">Cells</TableHead>
                <TableHead align="right">Gate</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {shown.map((row) => {
                const drift =
                  row.currentWeightBps !== undefined ? row.currentWeightBps - row.targetWeightBps : undefined
                return (
                  <TableRow key={row.id} data-testid={`holding-${row.symbol}`}>
                    <TableCell>
                      <span className="flex items-center gap-3">
                        <AssetMark symbol={row.symbol} />
                        <span className="whitespace-nowrap font-mono text-[13px] tracking-[0.05em]">
                          AMPS / {row.symbol}
                        </span>
                        <span className="text-[15px] text-dim">
                          {constituentStatusNames[row.status] ?? 'UNKNOWN'}
                          {row.freezeUntil > 0 ? ` · frozen until ${formatTimestamp(row.freezeUntil)}` : ''}
                        </span>
                      </span>
                    </TableCell>
                    <TableCell align="right">{formatBps(row.targetWeightBps)}</TableCell>
                    <TableCell align="right">
                      <Value
                        unavailable={row.currentWeightBps === undefined}
                        reason="The registry could not price this constituent"
                      >
                        {row.currentWeightBps !== undefined ? formatBps(row.currentWeightBps) : null}
                      </Value>
                    </TableCell>
                    <TableCell align="right" className="text-dim">
                      <Value unavailable={drift === undefined}>
                        {drift !== undefined ? `${drift > 0 ? '+' : ''}${(drift / 100).toFixed(2)}%` : null}
                      </Value>
                    </TableCell>
                    <TableCell align="right" className="text-dim">
                      {formatBps(row.rolloutWeightBps)}
                    </TableCell>
                    <TableCell align="right" className="text-dim">
                      <Value unavailable={row.ladderCells === undefined}>
                        {row.ladderCells !== undefined ? String(row.ladderCells) : null}
                      </Value>
                    </TableCell>
                    <TableCell align="right" className="text-[10px] tracking-[0.1em]">
                      <Value unavailable={row.gateState === undefined} reason="No pool registered for this constituent">
                        {row.gateState !== undefined ? gateStateName(row.gateState) : null}
                      </Value>
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
          {rows.length > 8 ? (
            <Button variant="outline" className="mt-4" onClick={() => setAll((v) => !v)} data-testid="holdings-toggle">
              {all ? 'Show only the top eight' : `Show all ${rows.length} constituents`}
            </Button>
          ) : null}
        </>
      )}
      <p className="mt-4 max-w-[88ch] text-[13px] leading-[1.55] text-dim">
        {NOTES.targetVsRealised} Index weight bounds at the live count: floor{' '}
        <Value unavailable={floorBps === undefined}>{floorBps !== undefined ? formatBps(floorBps) : null}</Value>, cap{' '}
        <Value unavailable={capBps === undefined}>{capBps !== undefined ? formatBps(capBps) : null}</Value>. A position
        the valuer could not price is shown as unavailable, never as zero.
      </p>
    </section>
  )
}

/**
 * Disclosure 02, rollout half. Flat rows, not a card: the design's Vault has exactly one card-like
 * container on the whole page and it is the stat band.
 */
export function RolloutPanel({
  bpsPerDay,
  bpsPerDayMax,
  entryFloorBps,
  rolledOutBps,
  targetBps,
}: {
  bpsPerDay?: number
  bpsPerDayMax?: number
  entryFloorBps?: number
  /** Sum of `rolloutWeightBps` over the constituent set. */
  rolledOutBps?: number
  /** Sum of `targetWeightBps` over the same set. */
  targetBps?: number
}) {
  const progress =
    rolledOutBps !== undefined && targetBps !== undefined && targetBps > 0
      ? Math.min(1, rolledOutBps / targetBps)
      : undefined
  return (
    <div data-testid="rollout">
      <FieldRow label="Rollout rate" hint="Unfilled entry-pool inventory migrating into the spokes, capped per day.">
        <Value unavailable={bpsPerDay === undefined}>
          {bpsPerDay !== undefined ? `${formatBps(bpsPerDay)} per day` : null}
        </Value>
      </FieldRow>
      <FieldRow label="Rollout hard cap" hint="Hardcoded in the vault. Governance cannot widen it.">
        <Value unavailable={bpsPerDayMax === undefined}>
          {bpsPerDayMax !== undefined ? `${formatBps(bpsPerDayMax)} per day` : null}
        </Value>
      </FieldRow>
      <FieldRow label="Entry-pool floor" hint="Rollout never drains the entry pools below this share.">
        <Value unavailable={entryFloorBps === undefined}>
          {entryFloorBps !== undefined ? formatBps(entryFloorBps) : null}
        </Value>
      </FieldRow>
      <FieldRow label="Migrated so far" hint="Sum of rolloutWeightBps against the sum of the target weights.">
        <Value unavailable={progress === undefined} reason="The registry could not be read">
          {progress !== undefined ? `${(progress * 100).toFixed(1)}%` : null}
        </Value>
      </FieldRow>
    </div>
  )
}

/**
 * Disclosure 02, creator half: 1% of trade volume at genesis, decaying linearly to exactly zero at
 * day 30.
 *
 * Immutable — there is no setter and no governance path to it — so these rows are a countdown
 * rather than parameters. The live figure is `AmpsVault.creatorBpsAt(now)`, read rather than
 * recomputed, so the number here is the number the contract will use.
 */
export function CreatorSchedulePanel({
  creatorBpsNow,
  creatorFeeBps,
  decaySeconds,
  genesisTimestamp,
  now,
  creator,
}: {
  creatorBpsNow?: number
  creatorFeeBps?: number
  decaySeconds?: number
  genesisTimestamp?: number
  now: number
  creator?: string
}) {
  const secondsLeft =
    genesisTimestamp !== undefined && decaySeconds !== undefined
      ? Math.max(0, genesisTimestamp + decaySeconds - now)
      : undefined
  return (
    <div data-testid="creator-schedule">
      <FieldRow label="Creator fee, in force now" hint={NOTES.creatorSchedule}>
        <Value unavailable={creatorBpsNow === undefined}>
          {creatorBpsNow !== undefined ? formatBps(creatorBpsNow) : null}
        </Value>
      </FieldRow>
      <FieldRow label="Creator fee at genesis" hint="The constant compiled into the vault.">
        <Value unavailable={creatorFeeBps === undefined}>
          {creatorFeeBps !== undefined ? formatBps(creatorFeeBps) : null}
        </Value>
      </FieldRow>
      <FieldRow label="Creator schedule length" hint="Decays linearly to exactly zero.">
        <Value unavailable={decaySeconds === undefined}>
          {decaySeconds !== undefined ? formatDuration(decaySeconds) : null}
        </Value>
      </FieldRow>
      <FieldRow label="Creator schedule remaining">
        <Value unavailable={secondsLeft === undefined}>
          {secondsLeft !== undefined ? formatDuration(secondsLeft) : null}
        </Value>
      </FieldRow>
      <FieldRow label="Creator fee paid to" hint="AmpsVault.creator()">
        <Value unavailable={!creator} className="text-[13px]" {...(creator ? {title: creator} : {})}>
          {creator ? shortAddress(creator) : null}
        </Value>
      </FieldRow>
    </div>
  )
}

export interface PolRow {
  poolId: string
  symbol: string
  counterDecimals: number
  /** AMPS wei across the pool's grid cells — the unfilled ask inventory. */
  amps?: bigint
  /** Counter asset across them — the entire bid under AMPS in this pool. */
  counter?: bigint
  /** When the pool last placed, from `AmpsVault.lastPlacementAt`. */
  lastPlacementAt?: number
  /** How many grid cells this pool currently has live, from `AmpsVault.ladderLength`. */
  ladderCells?: number
}

/**
 * Disclosure 03 — protocol-owned liquidity, pool by pool, exactly as the design lists it: one
 * `label / hint / value` row per pool, the counter asset as the figure and the placement state as
 * the gloss, closed by an all-pools ask-inventory total.
 *
 * The plan requires this number to be published rather than hidden: the pools are POL-only, so the
 * bid under AMPS in a pool is exactly the counter asset the protocol has earned and is holding
 * there — nothing else is bidding. A pool the valuer could not answer for is shown as unavailable,
 * not as zero: `amountsOf` returns `(0, 0)` both for an empty pool and for one it could not price,
 * and those are different facts.
 */
export function PolDepthTable({rows, now}: {rows: readonly PolRow[]; now: number}) {
  const totalAsk = rows.every((row) => row.amps !== undefined)
    ? rows.reduce((sum, row) => sum + (row.amps ?? 0n), 0n)
    : undefined
  return (
    <div data-testid="pol-depth">
      {rows.length === 0 ? (
        <EmptyState title="No pools registered">
          The pool registry is empty on this chain, so there is no protocol-owned liquidity to decompose.
        </EmptyState>
      ) : null}
      {rows.map((row) => {
        const readyAt = row.lastPlacementAt ? row.lastPlacementAt + PLACEMENT_COOLDOWN_SECONDS : undefined
        const placement =
          readyAt === undefined
            ? 'No placement recorded.'
            : readyAt > now
              ? `Next placement eligible in ${formatDuration(readyAt - now)}.`
              : 'Eligible to place now.'
        const ask =
          row.amps !== undefined
            ? `Ask inventory ${formatAmount(row.amps, 18)} AMPS`
            : 'Ask inventory unavailable'
        const cells = row.ladderCells !== undefined ? ` · ${row.ladderCells} cells` : ''
        return (
          <DataRow
            key={row.poolId}
            data-testid={`pol-row-${row.symbol}`}
            label={`AMPS / ${row.symbol}`}
            note={
              row.counter === undefined
                ? 'The valuer could not price this pool — unavailable, not zero.'
                : `${ask}${cells}. ${placement}`
            }
          >
            <Value unavailable={row.counter === undefined} reason="The valuer could not price this pool">
              {row.counter !== undefined ? `${formatAmount(row.counter, row.counterDecimals)} ${row.symbol}` : null}
            </Value>
          </DataRow>
        )
      })}
      {rows.length > 0 ? (
        <DataRow
          label="Unfilled ask inventory, all pools"
          note="Never minted. AMPS bought back by the protocol’s own bids is burned, not re-placed."
        >
          <Value unavailable={totalAsk === undefined} reason="At least one pool could not be priced">
            {totalAsk !== undefined ? `${formatAmount(totalAsk, 18)} AMPS` : null}
          </Value>
        </DataRow>
      ) : null}
      <p className="mt-4 max-w-[88ch] text-[13px] leading-[1.55] text-dim">
        {NOTES.polDepth} A placement is refused within {formatDuration(PLACEMENT_COOLDOWN_SECONDS)} of the previous one
        in the same pool, which is the cooldown a <code className="font-mono">compound()</code> has to clear before it
        can re-ladder anything.
      </p>
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

/**
 * Gate status, pool by pool. The design carries the gate as one column of the holdings table and
 * has nowhere for the three facts behind it, so this keeps the design's section head and table
 * treatment and spends a block on them.
 */
export function GateStatusTable({rows}: {rows: readonly GateRow[]}) {
  return (
    <section data-testid="gate-status">
      <SectionHead
        title="Gate status, pool by pool"
        note="What the hook thinks of each market right now, and why."
        aside={`${rows.length} pools`}
      />
      {rows.length === 0 ? (
        <EmptyState title="No pools registered">There is no pool on this chain to report a gate for.</EmptyState>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Pool</TableHead>
              <TableHead align="right">Gate</TableHead>
              <TableHead align="right">Session</TableHead>
              <TableHead align="right">Feed</TableHead>
              <TableHead align="right">Corporate action</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.poolId} data-testid={`gate-row-${row.symbol}`}>
                <TableCell>
                  <span className="flex items-center gap-3">
                    <AssetMark symbol={row.symbol} />
                    <span className="whitespace-nowrap font-mono text-[13px] tracking-[0.05em]">
                      AMPS / {row.symbol}
                    </span>
                  </span>
                </TableCell>
                <TableCell align="right">
                  <Badge variant={row.gateState === 0 ? 'default' : 'warning'}>{gateStateName(row.gateState)}</Badge>
                </TableCell>
                <TableCell align="right" className="text-dim">
                  {sessionLabels[sessionName(row.session) as keyof typeof sessionLabels] ?? '—'}
                </TableCell>
                <TableCell align="right">
                  <Badge variant={row.feedStale ? 'warning' : 'muted'}>{row.feedStale ? 'Stale' : 'Fresh'}</Badge>
                </TableCell>
                <TableCell align="right">
                  {row.corporateFreeze ? <Badge variant="danger">Frozen</Badge> : <span className="text-dim">—</span>}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
      <p className="mt-4 max-w-[88ch] text-[13px] leading-[1.55] text-dim">
        No gate state stops a swap or a redemption. Degraded states pause placements and compounding, raise the dynamic
        fee floor, and widen the bond haircut.
      </p>
    </section>
  )
}

/**
 * The pool's fill, as the design's `Filled` column.
 *
 * The indexer maintains it per pool (`ladderFillBps`) rather than leaving it to be averaged from
 * the cells, and that matters: `/api/pools` carries the totals and not the cells, so a mean taken
 * over `cells` here would have been a mean over an array that route never sends.
 */
function poolFill(pool: PoolRow): number | undefined {
  return pool.ladderFillBps === undefined ? undefined : pool.ladderFillBps / 10_000
}

/**
 * The design's "Liquidity ladder": a seven-column grid header, one clickable row per pool, and the
 * cell table opening underneath the row it belongs to. Six pools by default, with the design's
 * "show all" toggle.
 *
 * The *live* numbers — bid depth and ask inventory right now — come from the chain and are listed
 * in disclosure 03. This is the history around them: which cell was placed when, how much of it the
 * market has taken, and what it raised.
 *
 * Ladders are static: a cell is placed once and only ever removed by redemption, rollout, the
 * high-water buyback burn or a migration. Nothing is re-centred or re-widened, so "filled" is a
 * real measure of what the market has bought rather than an artefact of a keeper moving ranges.
 */
export function LadderFillPanel({
  pools,
  detail,
  openPoolId,
  onToggle,
  unavailable,
  reason,
}: {
  /** `/api/pools`: one row per pool, with its ladder totals. It carries no cells. */
  pools?: readonly PoolRow[]
  /** `/api/pools/:poolId/ladder` for the open pool, fetched by the parent when a row opens. */
  detail?: LadderDetail
  openPoolId?: string | null
  onToggle?: (poolId: string | null) => void
  unavailable?: boolean
  reason?: string
}) {
  const [all, setAll] = React.useState(false)
  if (unavailable || !pools) {
    return <IndexerUnavailable what="Ladder fill" {...(reason ? {reason} : {})} />
  }
  const shown = all ? pools : pools.slice(0, 6)
  return (
    <div data-testid="ladder-fill">
      <div className="ledger-micro hidden gap-3.5 border-b border-rule pb-2.5 pt-3 lg:grid lg:grid-cols-[minmax(0,1fr)_104px_92px_60px_88px_60px_66px]">
        <span>Pool</span>
        <span className="text-right">Bid depth</span>
        <span className="text-right">Ask inventory</span>
        <span className="text-right">Cells</span>
        <span className="text-right">Swaps</span>
        <span className="text-right">Filled</span>
        <span />
      </div>
      {shown.map((pool) => {
        const isOpen = openPoolId === pool.id
        const fill = poolFill(pool)
        const symbol = pool.counterSymbol ?? shortAddress(pool.counter)
        return (
          <div key={pool.id} className="border-b border-hair">
            <button
              type="button"
              onClick={() => onToggle?.(isOpen ? null : pool.id)}
              aria-expanded={isOpen}
              aria-controls={`ladder-${pool.id}`}
              className="grid w-full grid-cols-2 items-center gap-x-3.5 gap-y-1 py-3 text-left hover:bg-hair lg:grid-cols-[minmax(0,1fr)_104px_92px_60px_88px_60px_66px]"
            >
              <span className="col-span-2 flex min-w-0 items-center gap-3 lg:col-span-1">
                <AssetMark symbol={symbol} />
                <span className="whitespace-nowrap font-mono text-[13px] tracking-[0.05em]">AMPS / {symbol}</span>
              </span>
              <span className="ledger-cell text-right">
                <span className="ledger-micro mr-2 lg:hidden">Bid</span>
                {pool.counterInLadder}
              </span>
              <span className="ledger-cell text-right text-dim">
                <span className="ledger-micro mr-2 lg:hidden">Ask</span>
                {pool.ampsInLadder}
              </span>
              <span className="ledger-cell text-right text-dim">
                <span className="ledger-micro mr-2 lg:hidden">Cells</span>
                {pool.askCells + pool.bidCells}
              </span>
              <span className="ledger-cell text-right text-dim">
                <span className="ledger-micro mr-2 lg:hidden">Swaps</span>
                {pool.swapCount}
              </span>
              <span className="ledger-cell text-right">
                <span className="ledger-micro mr-2 lg:hidden">Filled</span>
                <Value unavailable={fill === undefined}>
                  {fill !== undefined ? `${Math.round(fill * 100)}%` : null}
                </Value>
              </span>
              <span className="ledger-micro text-right">{isOpen ? 'Close' : 'Cells'}</span>
            </button>
            <div id={`ladder-${pool.id}`} hidden={!isOpen} className="pb-[26px]">
              {detail && detail.pool?.id === pool.id ? (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Cell</TableHead>
                      <TableHead>Tick range</TableHead>
                      <TableHead>Side</TableHead>
                      <TableHead align="right">Placed</TableHead>
                      <TableHead align="right">Filled</TableHead>
                      <TableHead align="right">Proceeds</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {detail.cells.map((cell) => (
                      <TableRow key={cell.bucketIndex}>
                        <TableCell>{cell.bucketIndex}</TableCell>
                        <TableCell className="text-dim">
                          {cell.tickLower} … {cell.tickUpper}
                        </TableCell>
                        <TableCell className="text-[10px] tracking-[0.12em] uppercase">
                          {cell.above ? 'Ask' : 'Bid'}
                        </TableCell>
                        <TableCell align="right">{cell.amount}</TableCell>
                        <TableCell align="right">{Math.round(cell.filledBps / 100)}%</TableCell>
                        <TableCell align="right">{cell.proceeds}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              ) : (
                <p className="pt-3 text-[13px] leading-[1.55] text-dim">Loading this pool’s cells…</p>
              )}
            </div>
          </div>
        )
      })}
      {pools.length > 6 ? (
        <Button variant="outline" className="mt-[18px]" onClick={() => setAll((v) => !v)} data-testid="ladder-toggle">
          {all ? 'Collapse to the six largest pools' : `Show all ${pools.length} pools`}
        </Button>
      ) : null}
      <p className="mt-4 max-w-[88ch] text-[13px] leading-[1.55] text-dim">
        Ladders are static. A cell is placed once and only ever removed by a redemption, the daily rollout, a high-water
        buyback burn or a migration — nothing is re-centred or re-widened, so <em>filled</em> is a real measure of what
        the market bought. Bid depth is the entire bid under AMPS in this pool, because every pool is protocol-owned,
        and it only grows: the counter-asset side of every fee is placed back here as bids.
      </p>
    </div>
  )
}

/**
 * The `Burn` event's `bytes32` reason, as a person reads it.
 *
 * `redeemProRata` emits `Burn(shares, "redeem")`, so a redemption is a first-class row in this feed
 * rather than an inference from a supply delta. `compound` emits the fee burn — under revision 6
 * that is the whole AMPS side of the fee after the creator slice, not a governed share of it.
 */
export function burnReasonLabel(reason: string): string {
  // The four the vault emits, and no others: `VaultPlacementLib` burns `buyback` and `compound`,
  // `AmpsVault.redeemProRata` burns `redeem` and `redeemInventory`.
  const LABELS: Readonly<Record<string, string>> = {
    buyback: 'High-water buyback',
    compound: 'Fee burn',
    redeem: 'Redemption',
    redeemInventory: 'Redemption — released inventory',
  }
  // The indexer decodes the `bytes32` and serves the short string; a raw `bytes32` is accepted too,
  // because a consumer reading the log directly has one and the label should not depend on which.
  const decoded = reason.startsWith('0x') ? decodeBytes32(reason) : reason
  if (decoded === '') return reason.slice(0, 10)
  return LABELS[decoded] ?? decoded
}

function decodeBytes32(value: string): string {
  try {
    return hexToString(value as `0x${string}`, {size: 32}).replace(/\0+$/, '')
  } catch {
    return ''
  }
}

export function BurnHistoryTable({
  history,
  unavailable,
  reason,
}: {
  /** `/api/burns`: the rows, the running total and the count behind it. */
  history?: BurnHistory
  unavailable?: boolean
  reason?: string
}) {
  if (unavailable || !history) return <IndexerUnavailable what="Burn history" {...(reason ? {reason} : {})} />
  const burns = history.burns ?? []
  return (
    <div data-testid="burn-history">
      {burns.length === 0 ? (
        <EmptyState title="No burns yet">
          Nothing has been burned on this chain so far. The sink exists and has not been used.
        </EmptyState>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>When</TableHead>
              <TableHead align="right">Amount</TableHead>
              <TableHead align="right">Reason</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {burns.map((burn) => (
              <TableRow key={burn.txHash}>
                <TableCell className="text-dim">{formatTimestamp(Number(burn.timestamp))}</TableCell>
                <TableCell align="right">{burn.amount}</TableCell>
                <TableCell align="right">
                  <Badge variant="muted">{burnReasonLabel(burn.reason)}</Badge>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
      <p className="mt-4 max-w-[88ch] text-[13px] leading-[1.55] text-dim">
        {history.count} burns, {history.total} AMPS in total. {NOTES.burnSink}
      </p>
    </div>
  )
}

/**
 * Where a compound's fees actually went, in each currency.
 *
 * This is the disclosure revision 6 made necessary. Before it, one number — AMPS — covered the
 * whole split. Now a compound touches two currencies and treats them differently on purpose: the
 * creator's slice is taken from **each** of them in kind, the AMPS-side remainder is burned in
 * full, and the counter-asset remainder is placed straight back into the pool that earned it as
 * bids. Adding the two into one figure would hide exactly the distinction that matters.
 *
 * The AMPS figures are amounts. The counter figure is a USD aggregate across up to thirty-two
 * different assets with different decimals, and is labelled as such rather than being printed as
 * though it were a quantity of something.
 */
export function FeeFlowPanel({
  summary,
  creatorFee,
  unavailable,
  reason,
}: {
  summary?: VaultSummary
  creatorFee?: CreatorFeeStatus
  unavailable?: boolean
  reason?: string
}) {
  if (unavailable || !summary) {
    return <IndexerUnavailable what="Fee flow" {...(reason ? {reason} : {})} />
  }
  return (
    <div className="space-y-1" data-testid="fee-flow">
      <FieldRow
        label="Collected in AMPS"
        hint="The sell side of every fee, cumulative. It is the only side that is ever burned."
      >
        <Value unavailable={summary.feesAmpsTotal === undefined}>{summary.feesAmpsTotal ?? null}</Value>
      </FieldRow>
      <FieldRow
        label="Collected in counter assets"
        hint="The buy side, valued in USD at the time of each collection. Thirty-two assets with different decimals cannot be added as amounts."
      >
        <Value unavailable={summary.feesCounterUsd18 === undefined}>
          {summary.feesCounterUsd18 !== undefined ? formatUsd18(BigInt(summary.feesCounterUsd18)) : null}
        </Value>
      </FieldRow>
      <FieldRow label="Creator — paid in AMPS" hint={NOTES.creatorSchedule}>
        <Value unavailable={summary.creatorPaidAmpsTotal === undefined}>
          {summary.creatorPaidAmpsTotal ?? null}
        </Value>
      </FieldRow>
      <FieldRow
        label="Creator — paid in counter assets"
        hint="In kind, per currency, by transfer with an ERC-6909 claim fallback so a gated token can never block a compound."
      >
        <Value unavailable={summary.creatorPaidCounterUsd18 === undefined}>
          {summary.creatorPaidCounterUsd18 !== undefined
            ? formatUsd18(BigInt(summary.creatorPaidCounterUsd18))
            : null}
        </Value>
      </FieldRow>
      <FieldRow
        label="Creator schedule in force"
        hint="Immutable. There is no setter, and it reaches exactly zero at day 30."
      >
        <Value unavailable={creatorFee?.currentBps === undefined}>
          {creatorFee?.currentBps !== undefined ? formatBps(creatorFee.currentBps) : null}
        </Value>
      </FieldRow>
      <FieldRow
        label="Burned at compound"
        hint="The whole AMPS-side remainder after the creator slice, plus whatever the pool’s own bids bought back."
      >
        <Value unavailable={summary.burnedTotal === undefined}>{summary.burnedTotal ?? null}</Value>
      </FieldRow>
      <FieldRow
        label="Counter side, re-placed as bids"
        hint="Never moved to another pool and never distributed: it stays as depth in the pool that earned it, which is the floor you can sell into."
      >
        <span className="text-dim">Everything not paid to the creator</span>
      </FieldRow>
      <FieldRow label="Stakers" hint="There is no staking, no xAMPS and no reward stream.">
        <span className="text-dim">None</span>
      </FieldRow>
    </div>
  )
}

/**
 * NAV per share over time, as an inline sparkline.
 *
 * No chart library: one series, one axis, and a shape that has to survive a build with no network.
 * The series is the indexer's; if the indexer is unavailable the panel says so rather than drawing
 * a flat line at zero.
 */
export function NavHistoryPanel({
  points,
  unavailable,
  reason,
}: {
  points?: readonly NavPoint[]
  unavailable?: boolean
  reason?: string
}) {
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
    <div className="space-y-3" data-testid="nav-history">
      <svg
        viewBox="0 0 100 32"
        preserveAspectRatio="none"
        className="h-28 w-full border-b border-rule text-ink"
        role="img"
        aria-label="NAV per share over time"
      >
        <path d={path} fill="none" stroke="currentColor" strokeWidth="0.5" vectorEffect="non-scaling-stroke" />
      </svg>
      <div className="ledger-label flex justify-between">
        <span>{min.toFixed(4)}</span>
        <span>{max.toFixed(4)}</span>
      </div>
      <p className="max-w-[88ch] text-[13px] leading-[1.55] text-dim">
        Monotone non-decreasing except for market moves in the assets held. Bonds and redemptions both raise it.
      </p>
    </div>
  )
}
