// SPDX-License-Identifier: MIT

/**
 * `AmpsStaking` (xAMPS).
 *
 * The APR here is **realised, not projected**: the numerator is `RewardNotified` amounts that have
 * already been paid in out of `stakerBps` of the AMPS-side sell fees at `compound()`, and the
 * denominator is the vault's assets at the moment of notification. Nothing extrapolates from a
 * pending stream or from expected volume — there is no emission schedule to extrapolate from, which
 * is the whole point of Decision 17.
 */

import {ampsStakingAbi} from '@amplestocks/abis'
import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {ONE_DAY, WAD} from '../lib/constants'
import {SINGLETON, eventId} from '../lib/ids'
import {recordParameter} from '../lib/parameters'
import {stakingAprBps} from '../lib/flywheel'

ponder.on('AmpsStaking:RewardNotified', async ({event, context}) => {
  const staking = context.contracts.AmpsStaking.address as `0x${string}`

  const [totalAssets, totalSupply, sharePrice] = await Promise.all([
    context.client
      .readContract({abi: ampsStakingAbi, address: staking, functionName: 'totalAssets'})
      .catch(() => 0n),
    context.client
      .readContract({abi: ampsStakingAbi, address: staking, functionName: 'totalSupply'})
      .catch(() => 0n),
    context.client
      .readContract({
        abi: ampsStakingAbi,
        address: staking,
        functionName: 'convertToAssets',
        args: [WAD],
      })
      .catch(() => 0n),
  ])

  await context.db.insert(schema.stakingReward).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    amount: event.args.amount,
    streamEnd: BigInt(event.args.streamEnd),
    totalAssets,
  })

  const previous = await context.db.find(schema.stakingState, {id: SINGLETON})
  const windowStart = event.block.timestamp - ONE_DAY
  // A 24 h trailing sum without a query: the previous window, decayed to the part of it that is
  // still inside the window, plus this notification. Exact when notifications are 24 h apart or
  // closer, which the keeper's cadence guarantees, and never over-counts.
  const carried =
    previous !== null && previous.updatedAt > windowStart ? previous.rewards24h : 0n
  const rewards24h = carried + event.args.amount

  await context.db
    .insert(schema.stakingState)
    .values({
      id: SINGLETON,
      staking,
      totalAssets,
      totalSupply,
      sharePriceX18: sharePrice,
      rewardStreamSeconds: 0,
      streamEnd: BigInt(event.args.streamEnd),
      rewardsTotal: event.args.amount,
      rewards24h,
      aprBps: stakingAprBps(rewards24h, totalAssets, ONE_DAY),
      updatedAt: event.block.timestamp,
      updatedBlock: event.block.number,
    })
    .onConflictDoUpdate((row) => ({
      totalAssets,
      totalSupply,
      sharePriceX18: sharePrice,
      streamEnd: BigInt(event.args.streamEnd),
      rewardsTotal: row.rewardsTotal + event.args.amount,
      rewards24h,
      aprBps: stakingAprBps(rewards24h, totalAssets, ONE_DAY),
      updatedAt: event.block.timestamp,
      updatedBlock: event.block.number,
    }))
})

ponder.on('AmpsStaking:RewardStreamSecondsChanged', async ({event, context}) => {
  await recordParameter(context, event, 'staking', 'rewardStreamSeconds', {
    previousValue: BigInt(event.args.previousValue),
    newValue: BigInt(event.args.newValue),
  })
  const row = await context.db.find(schema.stakingState, {id: SINGLETON})
  if (row !== null) {
    await context.db
      .update(schema.stakingState, {id: SINGLETON})
      .set({rewardStreamSeconds: Number(event.args.newValue)})
  }
})

ponder.on('AmpsStaking:VaultChanged', async ({event, context}) => {
  await recordParameter(context, event, 'staking.pointer', 'vault', {
    previousAddress: event.args.previousVault,
    newAddress: event.args.newVault,
  })
})
