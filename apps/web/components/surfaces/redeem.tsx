// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useReadContract, useSimulateContract} from 'wagmi'
import type {Address} from 'viem'

import {NotDeployed, SurfaceHeading} from '@/components/common/states'
import {TxButton, TxError, TxSuccess} from '@/components/common/tx'
import {Value} from '@/components/common/value'
import {AmountField} from '@/components/ledger/amount-field'
import {AssetMark, DataRow, RowGroup} from '@/components/ledger/primitives'
import {Label} from '@/components/ui/label'
import {symbolForCounter} from '@/hooks/use-pools'
import {useTx} from '@/hooks/use-tx'
import {usePreviewRedeem, useVaultSnapshot} from '@/hooks/use-vault'
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
 * than folded invisibly into the payout, and the percentage in the column head is the live
 * `redeemFeeBps` rather than a number written down anywhere in this app.
 */
export function RedeemPreviewTable({preview}: {preview: RedeemPreview | null}) {
  if (!preview) {
    return (
      <div data-testid="redeem-preview">
        <RowGroup label="You receive, pro rata" aside="One transaction">
          <p className="py-4 text-[15px] text-dim">Enter an amount of AMPS to preview the payout.</p>
        </RowGroup>
      </div>
    )
  }
  return (
    <div data-testid="redeem-preview">
      <RowGroup
        label="You receive, pro rata"
        aside={`${preview.lines.length} lines · 1 tx · Fee (${formatBps(preview.redeemFeeBps)})`}
      >
        {preview.lines.map((line) => (
          <div
            key={line.token}
            className="grid grid-cols-[24px_minmax(0,1fr)_auto] items-center gap-3.5 border-b border-hair py-3"
            data-testid={`redeem-line-${line.symbol}`}
          >
            <AssetMark symbol={line.symbol} size={24} />
            <span className="flex min-w-0 items-baseline gap-2.5">
              <span className="font-mono text-[13px] tracking-[0.05em]">{line.symbol}</span>
              <span className="truncate text-[15px] text-dim">
                gross {formatAmount(line.grossAmount, line.decimals)} · fee{' '}
                {formatAmount(line.feeAmount, line.decimals)}
              </span>
            </span>
            <span className="ledger-value">{formatAmount(line.amount, line.decimals)}</span>
          </div>
        ))}
        <DataRow
          label="Inventory AMPS released, burned over 24 hours"
          note="Protocol-owned AMPS the unwind crosses is released rather than burned in this transaction, and it then leaves the supply on a 24-hour linear stream that every checkpoint and every redemption settles. Total supply falls by exactly what you redeem now, and by this over the day that follows."
        >
          <Value>{formatAmount(preview.inventoryReleased, 18)} AMPS</Value>
        </DataRow>
      </RowGroup>
    </div>
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

  // Live, every load. The launch value moves and this interface never writes a percentage down.
  const redeemFeeBps = snapshot.redeemFeeBps
  const redeemFeeBpsMax = snapshot.redeemFeeBpsMax
  const checkpoint = snapshot.checkpoint

  const previewModel = React.useMemo<RedeemPreview | null>(() => {
    const data = preview.data as readonly [readonly Address[], readonly bigint[], bigint] | undefined
    if (!data || shares === 0n || redeemFeeBps === undefined) return null
    return buildRedeemPreview({
      shares,
      redeemFeeBps,
      inventoryReleased: data[2],
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
      <div className="space-y-10">
        <SurfaceHeading
          kicker="The floor"
          title="Redeem"
          lede="The floor: pro-rata in every asset the vault holds."
        />
        <NotDeployed what="Redeem" />
      </div>
    )
  }

  const floorUsd =
    checkpoint && shares > 0n && redeemFeeBps !== undefined
      ? redeemValueUsd18({shares, navPerShareX18: checkpoint.navPerShareX18, redeemFeeBps})
      : undefined

  return (
    <div className="space-y-11" data-testid="redeem-surface">
      <SurfaceHeading
        kicker="The floor, as a transaction"
        title="Redeem"
        lede="Burn AMPS, receive a slice of every asset the vault holds, less the redemption fee. No oracle, no gate, no pause."
      />

      <div className="grid gap-x-14 gap-y-12 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
        <div>
          <Label htmlFor="redeem-amount" className="mb-3.5">
            You burn
          </Label>
          <AmountField
            id="redeem-amount"
            data-testid="redeem-amount"
            value={amountText}
            onChange={setAmountText}
            unit="AMPS"
          />

          <div className="mt-1.5">
            <DataRow
              label={`Redemption fee${redeemFeeBps !== undefined ? ` (${formatBps(redeemFeeBps)})` : ''}`}
              labelClassName="text-[15px] text-dim"
              note={NOTES.redemptionFee}
            >
              <Value unavailable={redeemFeeBps === undefined} reason="The vault could not be read">
                {redeemFeeBps !== undefined ? formatBps(redeemFeeBps) : null}
              </Value>
            </DataRow>
            <DataRow
              label="Ceiling hardcoded in the vault"
              labelClassName="text-[15px] text-dim"
              note="Governance can move the fee inside this and no further."
            >
              <Value unavailable={redeemFeeBpsMax === undefined} reason="The vault could not be read">
                {redeemFeeBpsMax !== undefined ? formatBps(redeemFeeBpsMax) : null}
              </Value>
            </DataRow>
            <DataRow label="NAV per share" labelClassName="text-[15px] text-dim">
              <Value unavailable={!checkpoint} reason="The vault checkpoint could not be read">
                {checkpoint ? formatUsd18(checkpoint.navPerShareX18, 4) : null}
              </Value>
            </DataRow>
            <DataRow
              label="Your share of the vault"
              labelClassName="text-[15px] text-dim"
              note="Total supply falls by exactly this. The inventory AMPS the unwind releases is burned separately, on a 24-hour stream."
            >
              <Value unavailable={totalSupply === undefined || shares === 0n}>
                {totalSupply !== undefined && shares > 0n ? formatBps(redemptionShareBps(shares, totalSupply)) : null}
              </Value>
            </DataRow>
            <DataRow
              label="Value at NAV, net of fee"
              labelClassName="text-[15px] text-dim"
              note="Arithmetic on the vault’s own balances, not a price."
            >
              <Value unavailable={floorUsd === undefined}>
                {floorUsd !== undefined ? formatUsd18(floorUsd) : null}
              </Value>
            </DataRow>
          </div>

          <div className="mt-[26px]">
            <TxButton
              phase={tx.phase}
              label={shares > 0n ? `Burn ${amountText} AMPS` : 'Burn AMPS'}
              {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
              onClick={() => void tx.send()}
              data-testid="redeem-submit"
            />
          </div>
          <p className="mt-4 max-w-[52ch] text-[14px] leading-[1.55] text-dim">
            This path is structurally ungated. It still has to be included in a block — if the sequencer refuses your
            transaction, no property of the contract helps you.
          </p>
          <div className="mt-6 space-y-6">
            <TxError error={tx.error} />
            {tx.hash ? <TxSuccess hash={tx.hash} explorerUrl={explorerTxUrl(activeChainId, tx.hash)} /> : null}
          </div>
        </div>

        <RedeemPreviewTable preview={previewModel} />
      </div>
    </div>
  )
}
