// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useAccount, useSimulateContract} from 'wagmi'
import type {Address} from 'viem'

import {FieldRow, Stat, StatGrid} from '@/components/common/stat'
import {IndexerUnavailable, NotDeployed, SurfaceHeading} from '@/components/common/states'
import {TxButton, TxError, TxSuccess} from '@/components/common/tx'
import {Value} from '@/components/common/value'
import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card'
import {Input} from '@/components/ui/input'
import {Label} from '@/components/ui/label'
import {Tabs, TabsContent, TabsList, TabsTrigger} from '@/components/ui/tabs'
import {useIndexerQuery} from '@/hooks/use-indexer'
import {useStaking} from '@/hooks/use-staking'
import {useTx} from '@/hooks/use-tx'
import {activeChainId} from '@/lib/chains'
import {abis, addressOf, contract} from '@/lib/contracts'
import {NOTES} from '@/lib/copy'
import {explorerTxUrl} from '@/lib/deployment'
import {formatAmount, formatBps, formatDuration, parseAmount} from '@/lib/format'

/**
 * xAMPS.
 *
 * The APR shown is realised: it is computed by the indexer from sell fees that have already been
 * collected and streamed over a past window. It is not a projection, and there is no emission of
 * any kind — the only thing that ever enters this contract is a share of fees the protocol has
 * actually earned.
 */
export function StakingStatsPanel({
  totalAssets,
  totalSupply,
  pendingRewards,
  streamSecondsRemaining,
  rewardStreamSeconds,
  realisedAprBps,
  aprUnavailable,
  aprReason,
}: {
  totalAssets?: bigint
  totalSupply?: bigint
  pendingRewards?: bigint
  streamSecondsRemaining?: number
  rewardStreamSeconds?: number
  realisedAprBps?: number
  aprUnavailable?: boolean
  aprReason?: string
}) {
  return (
    <StatGrid data-testid="staking-stats">
      <Stat label="Staked AMPS" value={totalAssets !== undefined ? formatAmount(totalAssets, 18) : undefined} unavailable={totalAssets === undefined} />
      <Stat label="xAMPS supply" value={totalSupply !== undefined ? formatAmount(totalSupply, 18) : undefined} unavailable={totalSupply === undefined} />
      <Stat
        label="Streaming now"
        value={pendingRewards !== undefined ? `${formatAmount(pendingRewards, 18)} AMPS` : undefined}
        unavailable={pendingRewards === undefined}
        hint={
          streamSecondsRemaining !== undefined && rewardStreamSeconds !== undefined
            ? `${formatDuration(streamSecondsRemaining)} left of a ${formatDuration(rewardStreamSeconds)} stream`
            : undefined
        }
      />
      <Stat
        label="Realised APR"
        value={realisedAprBps !== undefined ? formatBps(realisedAprBps) : undefined}
        unavailable={aprUnavailable || realisedAprBps === undefined}
        {...(aprReason ? {reason: aprReason} : {})}
        hint={NOTES.stakingApr}
      />
    </StatGrid>
  )
}

export function StakeSurface() {
  const {address, isConnected} = useAccount()
  const staking = contract('staking')
  const stakingAddress = addressOf('staking')
  const [mode, setMode] = React.useState<'deposit' | 'withdraw'>('deposit')
  const [amountText, setAmountText] = React.useState('')
  const amount = parseAmount(amountText, 18) ?? 0n

  const stats = useStaking()
  const apr = useIndexerQuery(['staking-stats'], (client) => client.stakingStats(), {refetchInterval: 60_000})

  const totalAssets = stats.data?.[0]?.result as bigint | undefined
  const totalSupply = stats.data?.[1]?.result as bigint | undefined
  const pendingRewards = stats.data?.[2]?.result as bigint | undefined
  const streamSecondsRemaining = stats.data?.[5]?.result as number | undefined
  const rewardStreamSeconds = stats.data?.[6]?.result as number | undefined
  const balance = stats.data?.[8]?.result as bigint | undefined

  const simulation = useSimulateContract({
    address: stakingAddress,
    abi: abis.staking,
    functionName: mode === 'deposit' ? 'deposit' : 'withdraw',
    args:
      stakingAddress && amount > 0n && address
        ? mode === 'deposit'
          ? [amount, address]
          : [amount, address, address]
        : undefined,
    query: {enabled: stakingAddress !== undefined && amount > 0n && isConnected},
  })

  const blockedReason = !isConnected ? 'Connect a wallet to simulate this.' : amount === 0n ? 'Enter an amount.' : undefined

  const tx = useTx({
    simulation: simulation.data,
    simulationError: simulation.error,
    isSimulating: simulation.isLoading,
    ...(blockedReason ? {blockedReason} : {}),
  })

  if (!staking) {
    return (
      <div className="space-y-6">
        <SurfaceHeading title="Stake" lede="xAMPS — a claim on realised sell fees." />
        <NotDeployed what="Stake" />
      </div>
    )
  }

  return (
    <div className="space-y-6" data-testid="stake-surface">
      <SurfaceHeading
        title="Stake"
        lede="Deposit AMPS, receive xAMPS. The contract pays out a share of sell fees that have already been collected, streamed linearly over 24 hours. Nothing is minted for stakers."
      />
      <Alert variant="info">
        <AlertTitle>Where the rewards come from</AlertTitle>
        <AlertDescription>
          <p>
            Every <code className="font-mono">compound()</code> splits the AMPS-side fees: the creator slice first
            (100 bp of sell volume decaying to exactly zero at day 30), then the staker slice, then a burn, then the
            remainder is re-laddered as ask inventory.
          </p>
          <p className="mt-2">{NOTES.stakingApr}</p>
        </AlertDescription>
      </Alert>

      <StakingStatsPanel
        {...(totalAssets !== undefined ? {totalAssets} : {})}
        {...(totalSupply !== undefined ? {totalSupply} : {})}
        {...(pendingRewards !== undefined ? {pendingRewards} : {})}
        {...(streamSecondsRemaining !== undefined ? {streamSecondsRemaining} : {})}
        {...(rewardStreamSeconds !== undefined ? {rewardStreamSeconds} : {})}
        {...(apr.value?.realisedAprBps !== undefined ? {realisedAprBps: apr.value.realisedAprBps} : {})}
        aprUnavailable={apr.unavailable || !apr.configured}
        aprReason={apr.configured ? apr.reason : 'No indexer configured'}
      />

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Deposit / withdraw</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <Tabs value={mode} onValueChange={(v) => setMode(v as 'deposit' | 'withdraw')}>
              <TabsList>
                <TabsTrigger value="deposit" data-testid="tab-deposit">
                  Deposit
                </TabsTrigger>
                <TabsTrigger value="withdraw" data-testid="tab-withdraw">
                  Withdraw
                </TabsTrigger>
              </TabsList>
              <TabsContent value={mode} />
            </Tabs>
            <div className="space-y-2">
              <Label htmlFor="stake-amount">{mode === 'deposit' ? 'AMPS to stake' : 'AMPS to withdraw'}</Label>
              <Input
                id="stake-amount"
                data-testid="stake-amount"
                inputMode="decimal"
                placeholder="0.0"
                value={amountText}
                onChange={(e) => setAmountText(e.target.value)}
              />
            </div>
            <TxButton
              phase={tx.phase}
              label={mode === 'deposit' ? 'Stake' : 'Withdraw'}
              {...(tx.blockedReason ? {blockedReason: tx.blockedReason} : {})}
              onClick={() => void tx.send()}
              data-testid="stake-submit"
            />
            <TxError error={tx.error} />
            {tx.hash ? <TxSuccess hash={tx.hash} explorerUrl={explorerTxUrl(activeChainId, tx.hash)} /> : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Your position</CardTitle>
          </CardHeader>
          <CardContent>
            <FieldRow label="xAMPS held">
              <Value unavailable={balance === undefined}>{balance !== undefined ? formatAmount(balance, 18) : null}</Value>
            </FieldRow>
            <FieldRow label="Reward stream length" hint="Linear, so a deposit sandwiched around a compound earns only its time-weighted share">
              <Value unavailable={rewardStreamSeconds === undefined}>
                {rewardStreamSeconds !== undefined ? formatDuration(rewardStreamSeconds) : null}
              </Value>
            </FieldRow>
            {!apr.configured || apr.unavailable ? <IndexerUnavailable what="The realised APR" {...(apr.reason ? {reason: apr.reason} : {})} /> : null}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
