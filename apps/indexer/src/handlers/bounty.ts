// SPDX-License-Identifier: MIT

/**
 * `BountyPot`, and the keeper-job ledger it anchors.
 *
 * A keeper job is a transaction, not an event: `compound`, `rollout`, `deployBonded`, `touch` and
 * `checkpoint` are permissionless calls whose *outcome* is whatever events they produced. The
 * classification comes from the transaction's selector (`src/lib/actions.ts`), so
 * "did the keeper's `rollout` actually move anything" is answerable from the index.
 *
 * `BountyPaid` is the payment side and is written first, because it is the one event every bountied
 * job emits; the row it creates is then completed by whichever handler recognises the job.
 */

import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {classifyAction, isKeeperJob} from '../lib/actions'
import {decodeBytes32String} from '../lib/bytes32'
import {eventId} from '../lib/ids'
import {recordParameter} from '../lib/parameters'

ponder.on('BountyPot:BountyPaid', async ({event, context}) => {
  const reason = decodeBytes32String(event.args.reason)
  await context.db.insert(schema.bountyPayment).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    kind: 'paid',
    to: event.args.to,
    workValueUsd18: event.args.workValueUsd18,
    paidUsd18: event.args.paidUsd18,
    paidRaw: event.args.paidRaw,
    reasonRaw: event.args.reason,
    reason,
  })

  const job = classifyAction(event.transaction.input)
  await context.db
    .insert(schema.keeperJob)
    .values({
      id: event.transaction.hash,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
      job: isKeeperJob(job) ? job : reason || job,
      caller: event.transaction.from,
      poolId: null,
      constituentId: null,
      outcome: 'ok',
      bountyPaidUsd18: event.args.paidUsd18,
      detail: {reason, paidRaw: event.args.paidRaw.toString(), to: event.args.to},
    })
    .onConflictDoUpdate((row) => ({
      bountyPaidUsd18: row.bountyPaidUsd18 + event.args.paidUsd18,
      outcome: 'ok',
    }))

  // Attribute the payment to the compound it paid for, when there is one in the same transaction.
  const compound = await context.db.find(schema.compoundEvent, {
    id: eventId(event.block.number, event.log.logIndex - 1),
  })
  if (compound !== null && compound.txHash === event.transaction.hash) {
    await context.db
      .update(schema.compoundEvent, {id: compound.id})
      .set({bountyPaidUsd18: event.args.paidUsd18})
  }
})

ponder.on('BountyPot:PotFunded', async ({event, context}) => {
  await context.db.insert(schema.bountyPayment).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    kind: 'funded',
    to: event.args.from,
    workValueUsd18: 0n,
    paidUsd18: 0n,
    paidRaw: event.args.amountRaw,
    reasonRaw: '0x0000000000000000000000000000000000000000000000000000000000000000',
    reason: 'funded',
  })
})

ponder.on('BountyPot:PotSwept', async ({event, context}) => {
  await context.db.insert(schema.bountyPayment).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    kind: 'swept',
    to: event.args.to,
    workValueUsd18: 0n,
    paidUsd18: 0n,
    paidRaw: event.args.amountRaw,
    reasonRaw: '0x0000000000000000000000000000000000000000000000000000000000000000',
    reason: 'swept',
  })
})

ponder.on('BountyPot:BountyParameterChanged', async ({event, context}) => {
  await recordParameter(context, event, 'bounty', decodeBytes32String(event.args.parameter), {
    previousValue: event.args.previousValue,
    newValue: event.args.newValue,
  })
})

ponder.on('BountyPot:VaultChanged', async ({event, context}) => {
  await recordParameter(context, event, 'bounty.pointer', 'vault', {
    previousAddress: event.args.previousVault,
    newAddress: event.args.newVault,
  })
})
