// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useSimulateContract} from 'wagmi'
import type {Address} from 'viem'

import {Stat, StatGrid} from '@/components/common/stat'
import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {TxButton, TxError, TxSuccess} from '@/components/common/tx'
import {Value} from '@/components/common/value'
import {AmountField} from '@/components/ledger/amount-field'
import {AssetMark, Callout, DataRow, RowGroup, SectionHead} from '@/components/ledger/primitives'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Badge} from '@/components/ui/badge'
import {Button} from '@/components/ui/button'
import {Label} from '@/components/ui/label'
import {Select} from '@/components/ui/select'
import {Table, TableBody, TableCell, TableHead, TableHeader, TableRow} from '@/components/ui/table'
import {
  useBondBoard,
  useBondMarketQuote,
  useBondParameters,
  useBondPositions,
  useBondTotals,
  useDailyIssuance,
  useUnvested,
} from '@/hooks/use-bonds'
import {symbolForCounter} from '@/hooks/use-pools'
import {useTx} from '@/hooks/use-tx'
import {
  assertBondMinAmpsOut,
  bondMinAmpsOut,
  bondReasonLabel,
  claimableOf,
  isCapacityClamped,
  toAmount18,
  uncappedAmpsOut,
  vestProgress,
  type BondQuote,
} from '@/lib/bonds'
import {activeChainId} from '@/lib/chains'
import {abis, addressOf, contract} from '@/lib/contracts'
import {NOTES} from '@/lib/copy'
import {explorerTxUrl} from '@/lib/deployment'
import {formatAmount, formatBps, formatDuration, parseAmount} from '@/lib/format'

/** One row of the board, as `AmpsBondsLens.MarketQuote` gives it. */
export interface BoardRow {
  marketId: number
  symbol: string
  collateral: Address
  decimals: number
  open: boolean
  discountBps: number
  qX18: bigint
  floorBinding: boolean
  capacityLeft: bigint
  ampsOut: bigint
  reason: `0x${string}`
  vestSeconds: number
}

/**
 * The market board.
 *
 * Every market is shown, including the ones that cannot be bonded right now: `quote()` never
 * reverts for a known market, it returns `ampsOut == 0` with a reason. A market that is closed for
 * a corporate action, full for the epoch, or waiting on an unconfirmed NAV answer is more
 * informative visible, with its reason spelled out, than hidden.
 *
 * `q` vs the floor is the column that matters. A discount only exists while the market premium
 * exceeds it; below that the market issues at the NAV floor, which is still accretive by
 * `minAccretionBps`.
 */
export function BondBoard({
  rows,
  onSelect,
  selectedMarketId,
}: {
  rows: readonly BoardRow[]
  onSelect?: (id: number) => void
  selectedMarketId?: number
}) {
  return (
    <div className="space-y-1" data-testid="bond-board">
      <SectionHead
        title="Markets"
        aside={<span>{rows.length} markets</span>}
      />
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Collateral</TableHead>
            <TableHead align="right">Discount</TableHead>
            <TableHead align="right">Price q</TableHead>
            <TableHead>Priced at</TableHead>
            <TableHead align="right">Capacity left</TableHead>
            <TableHead align="right">Vest</TableHead>
            <TableHead align="right">State</TableHead>
            <TableHead>Why not</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row) => {
            const why = bondReasonLabel(row.reason)
            return (
              <TableRow
                key={row.marketId}
                onClick={() => onSelect?.(row.marketId)}
                className={selectedMarketId === row.marketId ? 'bg-hair' : undefined}
                data-testid={`bond-row-${row.symbol}`}
              >
                <TableCell>
                  <span className="flex items-center gap-3">
                    <AssetMark symbol={row.symbol} />
                    <span className="tracking-[0.05em]">{row.symbol}</span>
                  </span>
                </TableCell>
                <TableCell align="right">
                  <Value unavailable={!row.open && row.discountBps === 0}>{formatBps(row.discountBps)}</Value>
                </TableCell>
                <TableCell align="right">
                  <Value unavailable={row.qX18 === 0n}>
                    {row.qX18 !== 0n ? formatAmount(row.qX18, 18) : null}
                  </Value>
                </TableCell>
                <TableCell className="font-serif text-[14px] text-dim">
                  {row.floorBinding ? 'NAV floor' : 'Market discount'}
                </TableCell>
                <TableCell align="right">
                  <Value unavailable={row.capacityLeft === 0n && !row.open}>
                    {formatAmount(row.capacityLeft, 18)}
                  </Value>
                </TableCell>
                <TableCell align="right">
                  <Value unavailable={row.vestSeconds === 0}>
                    {row.vestSeconds > 0 ? formatDuration(row.vestSeconds) : null}
                  </Value>
                </TableCell>
                <TableCell align="right" className="text-[10px] tracking-[0.12em]">
                  <Badge variant={row.open ? 'default' : 'muted'}>{row.open ? 'Open' : 'Closed'}</Badge>
                </TableCell>
                <TableCell className="max-w-[26rem] whitespace-normal font-serif text-[14px] leading-snug text-dim">
                  <Value unavailable={why === null}>{why}</Value>
                </TableCell>
              </TableRow>
            )
          })}
        </TableBody>
      </Table>
      <p className="max-w-[82ch] pt-3.5 text-[13px] leading-[1.55] text-dim">
        Every market is shown, including the ones that cannot price right now — a market that is closed for a corporate
        action, full for the epoch, or waiting on an unconfirmed feed answer is more informative visible than hidden.
      </p>
    </div>
  )
}

/**
 * The quote for the deposit the user typed, and the `minAmpsOut` rule made visible.
 *
 * `minAmpsOut` is the quoted amount, always. The capacity clamp reduces the AMPS issued and never
 * the collateral taken, so a lower bound is not slippage tolerance — it is consent to hand over
 * the whole deposit for a capped issue.
 */
export function BondQuotePanel({
  quote,
  amountIn,
  decimals,
  symbol,
}: {
  quote: BondQuote | undefined
  amountIn: bigint
  decimals: number
  symbol: string
}) {
  if (!quote) {
    return (
      <div data-testid="bond-quote">
        <RowGroup label="Quote">
          <p className="py-4 text-[15px] text-dim">Enter a deposit to price this market.</p>
        </RowGroup>
      </div>
    )
  }
  const amountIn18 = toAmount18(amountIn, decimals)
  const clamped = isCapacityClamped({quote, amountIn18})
  const why = bondReasonLabel(quote.reason)
  return (
    <div className="space-y-[26px]" data-testid="bond-quote">
      {why ? (
        <Alert variant="warning" data-testid="bond-reason">
          <AlertTitle>This market cannot price a bond right now</AlertTitle>
          <AlertDescription>
            <p>{why}</p>
          </AlertDescription>
        </Alert>
      ) : null}
      {clamped ? (
        <Alert variant="warning" data-testid="capacity-clamp">
          <AlertTitle>This deposit exceeds the market’s remaining capacity</AlertTitle>
          <AlertDescription>
            <p>
              The clamp reduces the AMPS issued, not the collateral taken: the shell settles the whole deposit and
              issues the capped amount. The minimum below is the capped figure, so the transaction reverts rather than
              handing over {formatAmount(amountIn, decimals)} {symbol} for less than it prices.
            </p>
            <p>
              Price alone would have issued {formatAmount(uncappedAmpsOut({qX18: quote.qX18, amountIn18}), 18)} AMPS.
            </p>
          </AlertDescription>
        </Alert>
      ) : null}

      <RowGroup label="Quote">
        <DataRow label="You receive" note="Minted at purchase, vesting linearly.">
          <Value unavailable={quote.ampsOut === 0n}>{formatAmount(quote.ampsOut, 18)} AMPS</Value>
        </DataRow>
        <DataRow label="Price q" note="AMPS per unit of collateral.">
          <Value unavailable={quote.qX18 === 0n}>{formatAmount(quote.qX18, 18)}</Value>
        </DataRow>
        <DataRow label="Discount">
          <Value>{formatBps(quote.discountBps)}</Value>
        </DataRow>
        <DataRow label="Priced at" note="The floor is NAV plus the minimum accretion, haircut by session.">
          <span className="font-serif text-[15px]">{quote.floorBinding ? 'NAV floor' : 'Market discount'}</span>
        </DataRow>
        <DataRow label="Capacity left this epoch">
          <Value>{formatAmount(quote.capacityLeft, 18)} AMPS</Value>
        </DataRow>
        <DataRow label="minAmpsOut" note={NOTES.bondMinAmpsOut}>
          <Value data-testid="bond-min-amps-out">{formatAmount(bondMinAmpsOut(quote), 18)} AMPS</Value>
        </DataRow>
      </RowGroup>

      <p className="max-w-[62ch] text-[14px] leading-[1.55] text-dim">
        The shell recomputes the NAV floor itself and refuses any price above it, so a hostile or buggy pricing policy
        can decline to quote but can never issue a dilutive bond.
      </p>
    </div>
  )
}

export interface PositionRow {
  positionId: number
  marketId: number
  symbol: string
  principal: bigint
  claimed: bigint
  start: number
  vestSeconds: number
}

export function BondPositions({
  positions,
  now,
  onClaim,
}: {
  positions: readonly PositionRow[]
  now: number
  onClaim?: (id: number) => void
}) {
  return (
    <div className="space-y-1" data-testid="bond-positions">
      <SectionHead title="Your positions" />
      {positions.length === 0 ? (
        <p className="pt-4 text-[15px] text-dim">No bond positions.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Market</TableHead>
              <TableHead align="right">Purchased</TableHead>
              <TableHead align="right">Claimed</TableHead>
              <TableHead align="right">Claimable</TableHead>
              <TableHead align="right">Vested</TableHead>
              <TableHead />
            </TableRow>
          </TableHeader>
          <TableBody>
            {positions.map((position) => {
              const claimable = claimableOf({...position, now})
              const progress = vestProgress({start: position.start, vestSeconds: position.vestSeconds, now})
              return (
                <TableRow key={position.positionId} data-testid={`position-${position.positionId}`}>
                  <TableCell>{position.symbol}</TableCell>
                  <TableCell align="right">{formatAmount(position.principal, 18)}</TableCell>
                  <TableCell align="right">{formatAmount(position.claimed, 18)}</TableCell>
                  <TableCell align="right">{formatAmount(claimable, 18)}</TableCell>
                  <TableCell align="right">{Math.round(progress * 100)}%</TableCell>
                  <TableCell align="right">
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={claimable === 0n}
                      onClick={() => onClaim?.(position.positionId)}
                      data-testid={`claim-${position.positionId}`}
                    >
                      Claim
                    </Button>
                  </TableCell>
                </TableRow>
              )
            })}
          </TableBody>
        </Table>
      )}
    </div>
  )
}

export function BondSurface() {
  const {address, isConnected} = useAccount()
  const bonds = contract('bonds')
  const bondsAddress = addressOf('bonds')
  const [marketId, setMarketId] = React.useState<number | undefined>(undefined)
  const [amountText, setAmountText] = React.useState('')
  const decimals = 18
  const amount = parseAmount(amountText, decimals) ?? 0n

  const board = useBondBoard(10n ** 18n)
  const marketQuote = useBondMarketQuote(marketId, amount)
  const positions = useBondPositions()
  const totals = useBondTotals()
  const daily = useDailyIssuance()
  const unvested = useUnvested()
  const params = useBondParameters()

  const rows = React.useMemo<BoardRow[]>(() => {
    const data = board.data as
      | readonly {
          marketId: number
          record: {collateral: Address; open: boolean; decimals: number}
          ampsOut: bigint
          qX18: bigint
          discountBps: number
          floorBinding: boolean
          capacityLeft: bigint
          reason: `0x${string}`
        }[]
      | undefined
    if (!data) return []
    return data.map((row) => ({
      marketId: row.marketId,
      symbol: symbolForCounter(row.record.collateral),
      collateral: row.record.collateral,
      decimals: row.record.decimals,
      open: row.record.open,
      discountBps: row.discountBps,
      qX18: row.qX18,
      floorBinding: row.floorBinding,
      capacityLeft: row.capacityLeft,
      ampsOut: row.ampsOut,
      reason: row.reason,
      // The vest length is one global parameter on the shell, read live rather than assumed.
      vestSeconds: params.vestSeconds ?? 0,
    }))
  }, [board.data, params.vestSeconds])

  const quote = marketQuote.quote
  const minOut = quote ? bondMinAmpsOut(quote) : 0n
  if (quote) assertBondMinAmpsOut(minOut, quote.ampsOut)

  const selectedRow = rows.find((row) => row.marketId === marketId)

  const simulation = useSimulateContract({
    address: bondsAddress,
    abi: abis.bonds,
    functionName: 'bond',
    args:
      bondsAddress && marketId !== undefined && amount > 0n && address ? [marketId, amount, minOut, address] : undefined,
    query: {enabled: bondsAddress !== undefined && marketId !== undefined && amount > 0n && isConnected},
  })

  const blockedReason = !isConnected
    ? 'Connect a wallet to simulate this bond.'
    : marketId === undefined
      ? 'Pick a market.'
      : amount === 0n
        ? 'Enter a deposit.'
        : quote && quote.ampsOut === 0n
          ? (bondReasonLabel(quote.reason) ?? 'This market cannot price a bond right now.')
          : undefined

  const tx = useTx({
    simulation: simulation.data,
    simulationError: simulation.error,
    isSimulating: simulation.isLoading,
    ...(blockedReason ? {blockedReason} : {}),
  })

  if (!bonds) {
    return (
      <div className="space-y-10">
        <SurfaceHeading kicker="Issuance" title="Bond" lede="Discounted issuance against a stock token." />
        <NotDeployed what="Bond" />
      </div>
    )
  }

  const issuance = daily.issuance

  return (
    <div className="space-y-14" data-testid="bond-surface">
      <SurfaceHeading
        kicker="Discounted issuance"
        title="Bond"
        lede="Deposit a stock token, receive AMPS at a discount, vesting linearly. The price is the lower of the market discount and the NAV floor, and the collateral is always taken in full."
      />

      <StatGrid data-testid="bond-parameters">
        <Stat
          label="Vest"
          emphasis={false}
          value={params.vestSeconds !== undefined ? formatDuration(params.vestSeconds) : undefined}
          unavailable={params.vestSeconds === undefined}
          hint="Linear from purchase. Read from AmpsBonds.vestSeconds()."
        />
        <Stat
          label="Epoch"
          emphasis={false}
          value={params.epochSeconds !== undefined ? formatDuration(params.epochSeconds) : undefined}
          unavailable={params.epochSeconds === undefined}
          hint="Capacity is allotted per market per epoch and refills when the epoch rolls."
        />
        <Stat
          label="Minimum accretion"
          emphasis={false}
          value={params.minAccretionBps !== undefined ? formatBps(params.minAccretionBps) : undefined}
          unavailable={params.minAccretionBps === undefined}
          hint="A bond that would accrete less than this to NAV per share is refused by the shell itself."
        />
        <Stat
          label="Daily cap"
          emphasis={false}
          value={params.dailyCapBps !== undefined ? formatBps(params.dailyCapBps) : undefined}
          unavailable={params.dailyCapBps === undefined}
          hint="Across every market, in basis points of total supply."
        />
        <Stat
          label="Issued today"
          emphasis={false}
          value={issuance ? `${formatAmount(issuance.issued, 18)} / ${formatAmount(issuance.capacity, 18)}` : undefined}
          unavailable={!issuance}
          hint="AMPS issued today against the cap."
        />
        <Stat
          label="Markets"
          emphasis={false}
          value={params.marketCount !== undefined ? String(params.marketCount) : undefined}
          unavailable={params.marketCount === undefined}
          hint="One per collateral the shell accepts. Entry collateral exists but is closed at launch."
        />
      </StatGrid>

      <div className="grid gap-x-14 gap-y-12 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
        <div>
          <Label htmlFor="market" className="mb-2">
            Market
          </Label>
          <Select
            id="market"
            data-testid="bond-market-select"
            value={marketId ?? ''}
            onChange={(e) => setMarketId(Number(e.target.value))}
          >
            <option value="">Select a market</option>
            {rows.map((row) => (
              <option key={row.marketId} value={row.marketId}>
                {row.symbol} {row.open ? '' : '(closed)'}
              </option>
            ))}
          </Select>

          <Label htmlFor="bond-amount" className="mb-2 mt-[22px]">
            Deposit
          </Label>
          <AmountField
            id="bond-amount"
            data-testid="bond-amount"
            value={amountText}
            onChange={setAmountText}
            unit={selectedRow?.symbol ?? ''}
          />

          <div className="mt-6">
            <TxButton
              phase={tx.phase}
              label={selectedRow && amount > 0n ? `Bond ${amountText} ${selectedRow.symbol}` : 'Bond'}
              {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
              onClick={() => void tx.send()}
              data-testid="bond-submit"
            />
          </div>

          <div className="mt-[26px] space-y-6">
            <TxError error={tx.error} />
            {tx.hash ? <TxSuccess hash={tx.hash} explorerUrl={explorerTxUrl(activeChainId, tx.hash)} /> : null}
            <Callout lead="A bond mints AMPS at purchase.">
              <p>
                It is in total supply immediately, so NAV per share reflects the issuance at once and cannot be gamed by
                claim timing. It is not income, and not a channel to or from the token issuer.
              </p>
              <p>{NOTES.bondMinAmpsOut}</p>
            </Callout>
            <RowGroup label="Your bonds" rule="rule">
              <DataRow
                label="Bonded total"
                labelClassName="text-[15px] text-dim"
                note="Principal across every position you hold, vested or not."
              >
                <Value unavailable={!totals.totals}>
                  {totals.totals ? `${formatAmount(totals.totals.principal, 18)} AMPS` : null}
                </Value>
              </DataRow>
              <DataRow
                label="Still vesting"
                labelClassName="text-[15px] text-dim"
                note="Exact, from AmpsBondsLens.unvested over your address — not an upper bound."
              >
                <Value unavailable={!unvested.unvested} data-testid="bond-unvested">
                  {unvested.unvested ? `${formatAmount(unvested.unvested.unvestedAmps, 18)} AMPS` : null}
                </Value>
              </DataRow>
              <DataRow label="Claimable now" labelClassName="text-[15px] text-dim">
                <Value unavailable={!unvested.unvested}>
                  {unvested.unvested ? `${formatAmount(unvested.unvested.claimableAmps, 18)} AMPS` : null}
                </Value>
              </DataRow>
            </RowGroup>
          </div>
        </div>

        <BondQuotePanel
          quote={quote}
          amountIn={amount}
          decimals={selectedRow?.decimals ?? decimals}
          symbol={selectedRow?.symbol ?? 'collateral'}
        />
      </div>

      <BondBoard rows={rows} onSelect={setMarketId} {...(marketId !== undefined ? {selectedMarketId: marketId} : {})} />

      <BondPositions
        positions={(
          (positions.data as
            | readonly {principal: bigint; claimed: bigint; start: number; vestSeconds: number; marketId: number}[]
            | undefined) ?? []
        ).map((p, i) => ({
          positionId: i,
          marketId: p.marketId,
          symbol: rows.find((row) => row.marketId === p.marketId)?.symbol ?? `#${p.marketId}`,
          principal: p.principal,
          claimed: p.claimed,
          start: p.start,
          vestSeconds: p.vestSeconds,
        }))}
        now={Math.floor(Date.now() / 1000)}
      />
    </div>
  )
}
