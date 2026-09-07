// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useReadContract, useSimulateContract} from 'wagmi'
import type {Address} from 'viem'

import {FieldRow, Stat, StatGrid} from '@/components/common/stat'
import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {TxButton, TxError, TxSuccess} from '@/components/common/tx'
import {Value} from '@/components/common/value'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'
import {Input} from '@/components/ui/input'
import {Label} from '@/components/ui/label'
import {Table, TableBody, TableCell, TableHead, TableHeader, TableRow} from '@/components/ui/table'
import {usePreviewRedeem, useVaultSnapshot} from '@/hooks/use-vault'
import {useTx} from '@/hooks/use-tx'
import {symbolForCounter} from '@/hooks/use-pools'
import {activeChainId} from '@/lib/chains'
import {abis, addressOf, contract} from '@/lib/contracts'
import {NOTES} from '@/lib/copy'
import {explorerTxUrl} from '@/lib/deployment'
import {formatAmount, formatBps, formatUsd18, parseAmount} from '@/lib/format'
import {buildRedeemPreview, redeemValueUsd18, redemptionShareBps, type RedeemPreview} from '@/lib/redeem'

/**
 * The pro-rata preview: one line per asset, at NAV minus the live fee.
 *
 * `previewRedeem` reads balances only — no oracle, no gate, no price — so this table is what the
 * vault would actually hand over, not a valuation of it. The fee is broken out per line rather
 * than folded invisibly into the payout.
 */
export function RedeemPreviewTable({preview}: {preview: RedeemPreview | null}) {
  if (!preview) {
    return (
      <Card data-testid="redeem-preview">
        <CardHeader>
          <CardTitle>What you would receive</CardTitle>
        </CardHeader>
        <CardContent className="text-sm text-muted-foreground">Enter an amount of AMPS to preview the payout.</CardContent>
      </Card>
    )
  }
  return (
    <Card data-testid="redeem-preview">
      <CardHeader>
        <CardTitle>What you would receive</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Asset</TableHead>
              <TableHead>Gross</TableHead>
              <TableHead>Fee ({formatBps(preview.redeemFeeBps)})</TableHead>
              <TableHead>You receive</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {preview.lines.map((line) => (
              <TableRow key={line.token} data-testid={`redeem-line-${line.symbol}`}>
                <TableCell className="font-medium">{line.symbol}</TableCell>
                <TableCell>{formatAmount(line.grossAmount, line.decimals)}</TableCell>
                <TableCell>{formatAmount(line.feeAmount, line.decimals)}</TableCell>
                <TableCell>{formatAmount(line.amount, line.decimals)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
        <FieldRow
          label="Inventory AMPS burned alongside"
          hint="Released protocol-owned inventory is burned too, so total supply falls by more than you redeem"
        >
          <Value>{formatAmount(preview.inventoryBurned, 18)} AMPS</Value>
        </FieldRow>
      </CardContent>
    </Card>
  )
}

export function RedeemSurface() {
  const {address, isConnected} = useAccount()
  const vault = contract('vault')
  const vaultAddress = addressOf('vault')
  const [amountText, setAmountText] = React.useState('')
  const shares = parseAmount(amountText, 18) ?? 0n

  const snapshot = useVaultSnapshot()
  const preview = usePreviewRedeem(shares > 0n ? shares : undefined)
  const ampsToken = contract('amps')
  const supplyQuery = useReadContract({
    ...(ampsToken ?? {address: undefined as unknown as Address, abi: [] as never}),
    functionName: 'totalSupply',
    query: {enabled: ampsToken !== undefined},
  })
  const totalSupply = supplyQuery.data as bigint | undefined

  const redeemFeeBps = Number((snapshot.data?.[4]?.result as number | undefined) ?? 0)
  const checkpoint = snapshot.data?.[0]?.result as {navPerShareX18: bigint} | undefined

  const previewModel = React.useMemo<RedeemPreview | null>(() => {
    const data = preview.data as readonly [readonly Address[], readonly bigint[], bigint] | undefined
    if (!data || shares === 0n) return null
    return buildRedeemPreview({
      shares,
      redeemFeeBps,
      inventoryBurned: data[2],
      tokens: data[0],
      amounts: data[1],
      meta: (token) => ({symbol: symbolForCounter(token), decimals: 18}),
    })
  }, [preview.data, shares, redeemFeeBps])

  const simulation = useSimulateContract({
    address: vaultAddress,
    abi: abis.vault,
    functionName: 'redeemProRata',
    args: vaultAddress && shares > 0n && address ? [shares, address] : undefined,
    query: {enabled: vaultAddress !== undefined && shares > 0n && isConnected},
  })

  const blockedReason = !isConnected
    ? 'Connect a wallet to simulate this redemption.'
    : shares === 0n
      ? 'Enter an amount of AMPS.'
      : undefined

  const tx = useTx({
    simulation: simulation.data,
    simulationError: simulation.error,
    isSimulating: simulation.isLoading,
    ...(blockedReason ? {blockedReason} : {}),
  })

  if (!vault) {
    return (
      <div className="space-y-6">
        <SurfaceHeading title="Redeem" lede="The floor: pro-rata in every asset the vault holds." />
        <NotDeployed what="Redeem" />
      </div>
    )
  }

  const floorUsd =
    checkpoint && shares > 0n
      ? redeemValueUsd18({shares, navPerShareX18: checkpoint.navPerShareX18, redeemFeeBps})
      : undefined

  return (
    <div className="space-y-6" data-testid="redeem-surface">
      <SurfaceHeading
        title="Redeem"
        lede="Burn AMPS, take a pro-rata slice of every asset the vault holds, less the redemption fee. This path reads no oracle and no gate, and no governance action can block it."
      />
      <Alert variant="info">
        <AlertTitle>What redemption pays</AlertTitle>
        <AlertDescription>
          <p>{NOTES.redemptionFloor}</p>
          <p className="mt-2">
            It pays assets, not cash. What they are worth is whatever they are worth when you sell them, which may be
            less than the NAV figure shown here.
          </p>
        </AlertDescription>
      </Alert>

      <StatGrid>
        <Stat
          label="NAV per share"
          value={checkpoint ? formatUsd18(checkpoint.navPerShareX18, 4) : undefined}
          unavailable={!checkpoint}
        />
        <Stat label="Redemption fee" value={formatBps(redeemFeeBps)} hint="Hard cap 5% in the contract" />
        <Stat
          label="Value at NAV, net of fee"
          value={floorUsd !== undefined ? formatUsd18(floorUsd) : undefined}
          unavailable={floorUsd === undefined}
          hint="Arithmetic on the vault’s own balances, not a price"
        />
        <Stat
          label="Share of total supply"
          value={totalSupply !== undefined && shares > 0n ? formatBps(redemptionShareBps(shares, totalSupply)) : undefined}
          unavailable={totalSupply === undefined || shares === 0n}
          hint="Total supply falls by more than this: the released inventory AMPS is burned too"
        />
      </StatGrid>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Redeem</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="redeem-amount">AMPS to redeem</Label>
              <Input
                id="redeem-amount"
                data-testid="redeem-amount"
                inputMode="decimal"
                placeholder="0.0"
                value={amountText}
                onChange={(e) => setAmountText(e.target.value)}
              />
            </div>
            <TxButton
              phase={tx.phase}
              label="Redeem"
              {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
              onClick={() => void tx.send()}
              data-testid="redeem-submit"
            />
            <TxError error={tx.error} />
            {tx.hash ? <TxSuccess hash={tx.hash} explorerUrl={explorerTxUrl(activeChainId, tx.hash)} /> : null}
          </CardContent>
        </Card>
        <RedeemPreviewTable preview={previewModel} />
      </div>
    </div>
  )
}
