// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useSimulateContract} from 'wagmi'
import type {Address} from 'viem'

import {FieldRow} from '@/components/common/stat'
import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {TxButton, TxError, TxSuccess} from '@/components/common/tx'
import {Value} from '@/components/common/value'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Badge} from '@/components/ui/badge'
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'
import {Input} from '@/components/ui/input'
import {Label} from '@/components/ui/label'
import {Table, TableBody, TableCell, TableHead, TableHeader, TableRow} from '@/components/ui/table'
import {useBondBoard, useBondMarketQuote, useBondPositions, useBondTotals, useDailyIssuance} from '@/hooks/use-bonds'
import {useTx} from '@/hooks/use-tx'
import {activeChainId} from '@/lib/chains'
import {abis, addressOf, contract} from '@/lib/contracts'
import {NOTES} from '@/lib/copy'
import {explorerTxUrl} from '@/lib/deployment'
import {formatAmount, formatBps, formatDuration, parseAmount} from '@/lib/format'
import {assertBondMinAmpsOut, bondMinAmpsOut, claimableOf, isCapacityClamped, toAmount18, uncappedAmpsOut, vestProgress, type BondQuote} from '@/lib/bonds'

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
 * a corporate action, full for the epoch, or pinned to the floor is more informative visible than
 * hidden.
 *
 * `q` vs the floor is the column that matters. A discount only exists while the market premium
 * exceeds it; below that the market issues at the NAV floor, which is still accretive by
 * `minAccretionBps`.
 */
export function BondBoard({rows, onSelect, selectedMarketId}: {rows: readonly BoardRow[]; onSelect?: (id: number) => void; selectedMarketId?: number}) {
  return (
    <Card data-testid="bond-board">
      <CardHeader>
        <CardTitle>Markets</CardTitle>
      </CardHeader>
      <CardContent>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Collateral</TableHead>
              <TableHead>Discount</TableHead>
              <TableHead>Price q</TableHead>
              <TableHead>Priced at</TableHead>
              <TableHead>Capacity left</TableHead>
              <TableHead>Vest</TableHead>
              <TableHead>State</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow
                key={row.marketId}
                onClick={() => onSelect?.(row.marketId)}
                className={selectedMarketId === row.marketId ? 'bg-muted/50' : undefined}
                data-testid={`bond-row-${row.symbol}`}
              >
                <TableCell className="font-medium">{row.symbol}</TableCell>
                <TableCell>
                  <Value unavailable={!row.open && row.discountBps === 0}>{formatBps(row.discountBps)}</Value>
                </TableCell>
                <TableCell>
                  <Value unavailable={row.qX18 === 0n}>{row.qX18 !== 0n ? `${formatAmount(row.qX18, 18)} AMPS` : null}</Value>
                </TableCell>
                <TableCell>
                  <Badge variant={row.floorBinding ? 'warning' : 'muted'}>{row.floorBinding ? 'NAV floor' : 'Market'}</Badge>
                </TableCell>
                <TableCell>
                  <Value unavailable={row.capacityLeft === 0n && !row.open}>{formatAmount(row.capacityLeft, 18)} AMPS</Value>
                </TableCell>
                <TableCell>{formatDuration(row.vestSeconds)}</TableCell>
                <TableCell>
                  {row.open ? <Badge variant="success">Open</Badge> : <Badge variant="danger">Closed</Badge>}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </CardContent>
    </Card>
  )
}

/**
 * The quote for the deposit the user typed, and the `minAmpsOut` rule made visible.
 *
 * `minAmpsOut` is the quoted amount, always. The capacity clamp reduces the AMPS issued and never
 * the collateral taken, so a lower bound is not slippage tolerance — it is consent to hand over
 * the whole deposit for a capped issue.
 */
export function BondQuotePanel({quote, amountIn, decimals, symbol}: {quote: BondQuote | undefined; amountIn: bigint; decimals: number; symbol: string}) {
  if (!quote) {
    return (
      <Card data-testid="bond-quote">
        <CardHeader>
          <CardTitle>Quote</CardTitle>
        </CardHeader>
        <CardContent className="text-sm text-muted-foreground">Enter a deposit to price this market.</CardContent>
      </Card>
    )
  }
  const amountIn18 = toAmount18(amountIn, decimals)
  const clamped = isCapacityClamped({quote, amountIn18})
  return (
    <div className="space-y-4" data-testid="bond-quote">
      {clamped ? (
        <Alert variant="warning" data-testid="capacity-clamp">
          <AlertTitle>This deposit exceeds the market’s remaining capacity</AlertTitle>
          <AlertDescription>
            <p>
              The clamp reduces the AMPS issued, not the collateral taken: the shell settles the whole deposit and
              issues the capped amount. The minimum below is the capped figure, so the transaction reverts rather than
              handing over {formatAmount(amountIn, decimals)} {symbol} for less than it prices.
            </p>
            <p className="mt-2">
              Price alone would have issued {formatAmount(uncappedAmpsOut({qX18: quote.qX18, amountIn18}), 18)} AMPS.
            </p>
          </AlertDescription>
        </Alert>
      ) : null}
      <Card>
        <CardHeader>
          <CardTitle>Quote</CardTitle>
        </CardHeader>
        <CardContent>
          <FieldRow label="You receive" hint="Minted at purchase, vesting linearly">
            <Value unavailable={quote.ampsOut === 0n}>{formatAmount(quote.ampsOut, 18)} AMPS</Value>
          </FieldRow>
          <FieldRow label="Price q" hint="AMPS per unit of collateral">
            <Value unavailable={quote.qX18 === 0n}>{formatAmount(quote.qX18, 18)}</Value>
          </FieldRow>
          <FieldRow label="Discount">
            <Value>{formatBps(quote.discountBps)}</Value>
          </FieldRow>
          <FieldRow label="Priced at" hint="The floor is NAV plus the minimum accretion, haircut by session">
            <Badge variant={quote.floorBinding ? 'warning' : 'muted'}>{quote.floorBinding ? 'NAV floor' : 'Market discount'}</Badge>
          </FieldRow>
          <FieldRow label="Capacity left this epoch">
            <Value>{formatAmount(quote.capacityLeft, 18)} AMPS</Value>
          </FieldRow>
          <FieldRow label="minAmpsOut" hint={NOTES.bondMinAmpsOut}>
            <Value data-testid="bond-min-amps-out">{formatAmount(bondMinAmpsOut(quote), 18)} AMPS</Value>
          </FieldRow>
        </CardContent>
      </Card>
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

export function BondPositions({positions, now, onClaim}: {positions: readonly PositionRow[]; now: number; onClaim?: (id: number) => void}) {
  return (
    <Card data-testid="bond-positions">
      <CardHeader>
        <CardTitle>Your positions</CardTitle>
      </CardHeader>
      <CardContent>
        {positions.length === 0 ? (
          <p className="text-sm text-muted-foreground">No bond positions.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Market</TableHead>
                <TableHead>Purchased</TableHead>
                <TableHead>Claimed</TableHead>
                <TableHead>Claimable</TableHead>
                <TableHead>Vest</TableHead>
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
                    <TableCell>{formatAmount(position.principal, 18)}</TableCell>
                    <TableCell>{formatAmount(position.claimed, 18)}</TableCell>
                    <TableCell>{formatAmount(claimable, 18)}</TableCell>
                    <TableCell>{Math.round(progress * 100)}%</TableCell>
                    <TableCell>
                      <button
                        type="button"
                        className="text-sm underline disabled:opacity-40"
                        disabled={claimable === 0n}
                        onClick={() => onClaim?.(position.positionId)}
                        data-testid={`claim-${position.positionId}`}
                      >
                        Claim
                      </button>
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
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

  const rows = React.useMemo<BoardRow[]>(() => {
    const data = board.data as readonly {
      marketId: number
      record: {collateral: Address; open: boolean; decimals: number}
      ampsOut: bigint
      qX18: bigint
      discountBps: number
      floorBinding: boolean
      capacityLeft: bigint
      reason: `0x${string}`
    }[] | undefined
    if (!data) return []
    return data.map((row) => ({
      marketId: row.marketId,
      symbol: `#${row.marketId}`,
      collateral: row.record.collateral,
      decimals: row.record.decimals,
      open: row.record.open,
      discountBps: row.discountBps,
      qX18: row.qX18,
      floorBinding: row.floorBinding,
      capacityLeft: row.capacityLeft,
      ampsOut: row.ampsOut,
      reason: row.reason,
      vestSeconds: 12 * 3_600,
    }))
  }, [board.data])

  const quote = marketQuote.quote
  const minOut = quote ? bondMinAmpsOut(quote) : 0n
  if (quote) assertBondMinAmpsOut(minOut, quote.ampsOut)

  const simulation = useSimulateContract({
    address: bondsAddress,
    abi: abis.bonds,
    functionName: 'bond',
    args:
      bondsAddress && marketId !== undefined && amount > 0n && address
        ? [marketId, amount, minOut, address]
        : undefined,
    query: {enabled: bondsAddress !== undefined && marketId !== undefined && amount > 0n && isConnected},
  })

  const blockedReason = !isConnected
    ? 'Connect a wallet to simulate this bond.'
    : marketId === undefined
      ? 'Pick a market.'
      : amount === 0n
        ? 'Enter a deposit.'
        : quote && quote.ampsOut === 0n
          ? 'This market cannot price a bond right now.'
          : undefined

  const tx = useTx({
    simulation: simulation.data,
    simulationError: simulation.error,
    isSimulating: simulation.isLoading,
    ...(blockedReason ? {blockedReason} : {}),
  })

  if (!bonds) {
    return (
      <div className="space-y-6">
        <SurfaceHeading title="Bond" lede="Discounted issuance against a stock token." />
        <NotDeployed what="Bond" />
      </div>
    )
  }

  const issuance = daily.issuance

  return (
    <div className="space-y-6" data-testid="bond-surface">
      <SurfaceHeading
        title="Bond"
        lede="Deposit a stock token, receive AMPS at a discount, vesting linearly. The price is the lower of the market discount and the NAV floor, and the collateral is always taken in full."
      />
      <Alert variant="info">
        <AlertTitle>What a bond is, and what it is not</AlertTitle>
        <AlertDescription>
          <p>
            A bond mints AMPS at purchase — it is in total supply immediately, so NAV per share reflects the issuance
            at once and cannot be gamed by claim timing. It is not income and not a channel to or from the token issuer.
          </p>
          <p className="mt-2">{NOTES.bondMinAmpsOut}</p>
        </AlertDescription>
      </Alert>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Bond</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="market">Market</Label>
              <select
                id="market"
                data-testid="bond-market-select"
                className="h-10 w-full rounded-md border border-border bg-background px-3 text-sm"
                value={marketId ?? ''}
                onChange={(e) => setMarketId(Number(e.target.value))}
              >
                <option value="">Select a market</option>
                {rows.map((row) => (
                  <option key={row.marketId} value={row.marketId}>
                    {row.symbol} {row.open ? '' : '(closed)'}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="bond-amount">Deposit</Label>
              <Input
                id="bond-amount"
                data-testid="bond-amount"
                inputMode="decimal"
                placeholder="0.0"
                value={amountText}
                onChange={(e) => setAmountText(e.target.value)}
              />
            </div>
            <TxButton
              phase={tx.phase}
              label="Bond"
              {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
              onClick={() => void tx.send()}
              data-testid="bond-submit"
            />
            <TxError error={tx.error} />
            {tx.hash ? <TxSuccess hash={tx.hash} explorerUrl={explorerTxUrl(activeChainId, tx.hash)} /> : null}
            <div className="pt-2">
              <FieldRow label="Protocol daily issuance" hint="Across every market, against the global cap">
                <Value unavailable={!issuance}>
                  {issuance ? `${formatAmount(issuance.issued, 18)} / ${formatAmount(issuance.capacity, 18)} AMPS` : null}
                </Value>
              </FieldRow>
              <FieldRow label="Your vesting total">
                <Value unavailable={!totals.totals}>
                  {totals.totals ? `${formatAmount(totals.totals.principal, 18)} AMPS` : null}
                </Value>
              </FieldRow>
              <FieldRow label="Claimable now">
                <Value unavailable={!totals.totals}>
                  {totals.totals ? `${formatAmount(totals.totals.claimableNow, 18)} AMPS` : null}
                </Value>
              </FieldRow>
            </div>
          </CardContent>
        </Card>

        <BondQuotePanel quote={quote} amountIn={amount} decimals={decimals} symbol="collateral" />
      </div>

      <BondBoard rows={rows} onSelect={setMarketId} {...(marketId !== undefined ? {selectedMarketId: marketId} : {})} />
      <BondPositions
        positions={((positions.data as readonly {principal: bigint; claimed: bigint; start: number; vestSeconds: number; marketId: number}[] | undefined) ?? []).map(
          (p, i) => ({
            positionId: i,
            marketId: p.marketId,
            symbol: `#${p.marketId}`,
            principal: p.principal,
            claimed: p.claimed,
            start: p.start,
            vestSeconds: p.vestSeconds,
          }),
        )}
        now={Math.floor(Date.now() / 1000)}
      />
      <p className="text-xs text-muted-foreground">
        The shell recomputes the NAV floor itself and refuses any price above it, so a hostile or buggy pricing policy
        can decline to quote but can never issue a dilutive bond.
      </p>
    </div>
  )
}
