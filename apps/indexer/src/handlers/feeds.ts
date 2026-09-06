// SPDX-License-Identifier: MIT

/**
 * Chainlink feeds, from two sides.
 *
 * - **`FeedRegistry`** is authoritative and always indexed. `AnswerLatched` is the answer the
 *   protocol *accepted* — after the two-confirmation rule, the sanity bounds and the freshness
 *   check — and is therefore the number NAV was actually computed from. `AnswerJumpPending` is the
 *   jump that rule held back.
 * - **`AnswerUpdated`** is the raw aggregator round. The addresses come from a factory over
 *   `FeedSet`, which stores the *proxy*; on Robinhood Chain mainnet a Chainlink proxy does not emit
 *   `AnswerUpdated` — the underlying `AccessControlledOffchainAggregator` behind it does — so on
 *   4663 this source stays empty until Phase 0 records the aggregator addresses behind each proxy
 *   and they are added through `AMPS_DENYLIST_WATCH`'s sibling setting. On a local or testnet
 *   deployment, where the registered address *is* the aggregator, it populates normally. Either
 *   way nothing depends on it: `feed.answerUsd8` is written from `AnswerLatched`.
 */

import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {decodeBytes32String} from '../lib/bytes32'
import {eventId} from '../lib/ids'
import {changeBps} from '../lib/math'
import {recordParameter} from '../lib/parameters'

const tokenKey = (token: `0x${string}`) => token.toLowerCase() as `0x${string}`

ponder.on('FeedRegistry:FeedSet', async ({event, context}) => {
  const id = tokenKey(event.args.token)
  await context.db
    .insert(schema.feed)
    .values({
      id,
      token: event.args.token,
      aggregator: event.args.aggregator,
      previousAggregator: event.args.previousAggregator,
      heartbeat: 0,
      thresholdBps: 0,
      minAnswerUsd8: 0n,
      maxAnswerUsd8: 0n,
      answerUsd8: 0n,
      updatedAt: 0n,
      roundId: 0n,
      standardProxy: false,
      lastBlock: event.block.number,
    })
    .onConflictDoUpdate(() => ({
      aggregator: event.args.aggregator,
      previousAggregator: event.args.previousAggregator,
      lastBlock: event.block.number,
    }))
})

ponder.on('FeedRegistry:FeedConfigured', async ({event, context}) => {
  const id = tokenKey(event.args.token)
  const row = await context.db.find(schema.feed, {id})
  if (row === null) return
  await context.db.update(schema.feed, {id}).set({
    heartbeat: Number(event.args.heartbeat),
    thresholdBps: event.args.thresholdBps,
    minAnswerUsd8: event.args.minAnswerUsd8,
    maxAnswerUsd8: event.args.maxAnswerUsd8,
    lastBlock: event.block.number,
  })
})

ponder.on('FeedRegistry:AnswerLatched', async ({event, context}) => {
  const id = tokenKey(event.args.token)
  const row = await context.db.find(schema.feed, {id})
  const previous = row?.answerUsd8 ?? 0n

  await context.db.insert(schema.feedAnswer).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    token: event.args.token,
    aggregator: row?.aggregator ?? null,
    answerUsd8: event.args.answerUsd8,
    updatedAt: BigInt(event.args.updatedAt),
    roundId: event.args.roundId,
    source: 'latched',
    changeBps: changeBps(previous, event.args.answerUsd8),
  })

  if (row !== null) {
    await context.db.update(schema.feed, {id}).set({
      answerUsd8: event.args.answerUsd8,
      updatedAt: BigInt(event.args.updatedAt),
      roundId: event.args.roundId,
      lastBlock: event.block.number,
    })
  }

  // Mirror onto whichever constituent this token is, so the dApp's constituent list is complete.
  const constituentId = await constituentIdOf(context, event.args.token)
  if (constituentId !== null) {
    await context.db.update(schema.constituent, {id: constituentId}).set({
      answerUsd8: event.args.answerUsd8,
      answerUpdatedAt: BigInt(event.args.updatedAt),
      feed: row?.aggregator ?? null,
    })
  }
})

ponder.on('FeedRegistry:AnswerJumpPending', async ({event, context}) => {
  await context.db.insert(schema.feedJump).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    token: event.args.token,
    previousAnswerUsd8: event.args.previousAnswerUsd8,
    pendingAnswerUsd8: event.args.pendingAnswerUsd8,
    roundId: event.args.roundId,
    jumpBps: changeBps(event.args.previousAnswerUsd8, event.args.pendingAnswerUsd8),
  })
})

ponder.on('FeedRegistry:StandardProxySet', async ({event, context}) => {
  await recordParameter(context, event, 'feeds', 'standardProxy', {
    newValue: event.args.standard ? 1n : 0n,
    newAddress: event.args.aggregator,
  })
})

ponder.on('FeedRegistry:FreshnessMultiplierSet', async ({event, context}) => {
  await recordParameter(context, event, 'feeds', `freshnessMultiplier.${event.args.session}`, {
    newValue: BigInt(event.args.multiplier),
  })
})

ponder.on('FeedRegistry:FeedRegistryParameterChanged', async ({event, context}) => {
  await recordParameter(context, event, 'feeds', decodeBytes32String(event.args.parameter), {
    previousValue: event.args.previousValue,
    newValue: event.args.newValue,
  })
})

ponder.on('ChainlinkAggregator:AnswerUpdated', async ({event, context}) => {
  await context.db.insert(schema.feedAnswer).values({
    id: eventId(event.block.number, event.log.logIndex),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    token: null,
    aggregator: event.log.address,
    answerUsd8: event.args.current < 0n ? 0n : event.args.current,
    updatedAt: event.args.updatedAt,
    roundId: event.args.roundId,
    source: 'aggregator',
    changeBps: 0,
  })
})

// -------------------------------------------------------------------------------------------------

/** Which constituent a token is, if any, from the materialised reverse index. */
async function constituentIdOf(
  context: {db: import('../lib/store').Db},
  token: `0x${string}`,
): Promise<string | null> {
  const row = await context.db.find(schema.tokenIndex, {id: token.toLowerCase() as `0x${string}`})
  return row === null ? null : row.constituentId.toString()
}
