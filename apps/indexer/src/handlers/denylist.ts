// SPDX-License-Identifier: MIT

/**
 * The denylist alarm.
 *
 * `blockAccounts(address[])` (`0x6abf7081`) is an issuer-side power on the Stock Token beacon with
 * **no delay, no timelock and no event**. There is therefore nothing to subscribe to: the alarm has
 * to watch *transactions*. Ponder's `accounts` sources give exactly that — every transaction
 * addressed to a watched contract, with its calldata — so the alarm fires in the same block the
 * call lands in, which is what the Phase 5 exit criterion ("fires within one block") asks for.
 *
 * Two sources feed it:
 *
 * - `StockTokenCalls` — a factory over `PoolRegistry.ConstituentAdded`, so every registered Stock
 *   Token is watched from the block it was registered.
 * - `DenylistWatch` — the beacon from the address book plus anything `AMPS_DENYLIST_WATCH` adds
 *   (the implementation, the issuer admin key, the `ACCESS_CONTROLLED_REGISTRY` once Phase 0 has
 *   decompiled it).
 *
 * A second, independent detector lives in `polling.ts`: `isBlocked(vault)` probed per constituent.
 * That one catches a denylist applied through a path the call watch cannot see (a multicall, a Safe,
 * an upgrade that pre-seeds the list) at the cost of one poll interval of latency. Both write the
 * same table.
 *
 * **Severity.** `critical` when one of the blocked addresses is the vault, the PoolManager or any
 * protocol contract — that is the exact predicate the guardian's no-delay `emergencyMigrate` is
 * gated on. `warning` otherwise: the issuer blocking a third party is news, not our incident.
 */

import {ponder} from 'ponder:registry'
import schema from 'ponder:schema'

import {BLOCK_ACCOUNTS_SELECTOR, UNBLOCK_ACCOUNTS_SELECTOR} from '../abi/external'
import {selectorOf} from '../lib/actions'
import {eventId} from '../lib/ids'
import {raiseAlert, type Db} from '../lib/store'
import {jsonRecord, jsonSafe} from '../lib/json'

/** `blockAccounts(address[])` / `unblockAccounts(address[])`: one dynamic array, ABI-encoded. */
export function decodeAddressArray(input: `0x${string}`): `0x${string}`[] {
  // 4 selector + 32 offset + 32 length, then 32 per address.
  const body = input.slice(10)
  if (body.length < 128) return []
  const length = Number(BigInt(`0x${body.slice(64, 128)}`))
  if (!Number.isFinite(length) || length < 0 || length > 512) return []
  const out: `0x${string}`[] = []
  for (let i = 0; i < length; i++) {
    const word = body.slice(128 + i * 64, 128 + (i + 1) * 64)
    if (word.length < 64) break
    out.push(`0x${word.slice(24)}` as `0x${string}`)
  }
  return out
}

interface AlarmInput {
  db: Db
  blockNumber: bigint
  timestamp: bigint
  txHash: `0x${string}` | null
  detection: 'call' | 'probe'
  target: `0x${string}`
  caller: `0x${string}` | null
  selector: `0x${string}` | null
  accounts: `0x${string}`[]
  constituentId: number | null
  protocolAddresses: Set<string>
  logIndex: number
}

async function record(input: AlarmInput): Promise<void> {
  const touchesProtocol = input.accounts.some((a) => input.protocolAddresses.has(a.toLowerCase()))
  const severity = touchesProtocol ? 'critical' : 'warning'
  const id = eventId(input.blockNumber, input.logIndex)

  const result = await raiseAlert(input.db, input.logIndex, {
    kind: 'denylist',
    severity,
    subject: input.target,
    message:
      input.detection === 'call'
        ? `${input.selector === UNBLOCK_ACCOUNTS_SELECTOR ? 'unblockAccounts' : 'blockAccounts'} called on ${input.target} for ${input.accounts.length} address(es)`
        : `isBlocked returned true on ${input.target}`,
    blockNumber: input.blockNumber,
    timestamp: input.timestamp,
    detail: jsonRecord({
      target: input.target,
      caller: input.caller,
      selector: input.selector,
      accounts: input.accounts,
      touchesProtocol,
      constituentId: input.constituentId,
    }),
  })

  await input.db
    .insert(schema.denylistAlarm)
    .values({
      id,
      blockNumber: input.blockNumber,
      timestamp: input.timestamp,
      txHash: input.txHash,
      detection: input.detection,
      target: input.target,
      caller: input.caller,
      selector: input.selector,
      accounts: jsonSafe(input.accounts),
      touchesProtocol,
      constituentId: input.constituentId,
      severity,
      delivered: result.delivered,
    })
    .onConflictDoUpdate(() => ({delivered: result.delivered}))
}

/** The protocol addresses whose blocking is a `critical`, from the configured contract set. */
export function protocolAddressSet(contracts: Record<string, {address?: unknown}>): Set<string> {
  const out = new Set<string>()
  for (const entry of Object.values(contracts)) {
    const address = entry.address
    if (typeof address === 'string') out.add(address.toLowerCase())
  }
  out.delete('0x0000000000000000000000000000000000000000')
  return out
}

/** Shared by both account sources: decode, classify, record. */
export async function handleCall(
  context: {db: Db; contracts: Record<string, {address?: unknown}>},
  event: {
    block: {number: bigint; timestamp: bigint}
    transaction: {hash: `0x${string}`; from: `0x${string}`; to: `0x${string}` | null; input: `0x${string}`}
  },
): Promise<void> {
  const selector = selectorOf(event.transaction.input)
  if (selector !== BLOCK_ACCOUNTS_SELECTOR && selector !== UNBLOCK_ACCOUNTS_SELECTOR) return

  const target = (event.transaction.to ?? '0x0000000000000000000000000000000000000000') as `0x${string}`
  const accounts = decodeAddressArray(event.transaction.input)
  const index = await context.db.find(schema.tokenIndex, {
    id: target.toLowerCase() as `0x${string}`,
  })

  await record({
    db: context.db,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    detection: 'call',
    target,
    caller: event.transaction.from,
    selector,
    accounts,
    constituentId: index?.constituentId ?? null,
    protocolAddresses: protocolAddressSet(context.contracts),
    // Transactions carry no log index; the alarm slot is reserved high so it cannot collide with a
    // real log in the same block.
    logIndex: 999_000,
  })
}

/** Called by the constituent poll when `isBlocked` comes back true for one of our own addresses. */
export async function recordProbe(
  db: Db,
  contracts: Record<string, {address?: unknown}>,
  args: {
    blockNumber: bigint
    timestamp: bigint
    token: `0x${string}`
    account: `0x${string}`
    constituentId: number
    logIndex: number
  },
): Promise<void> {
  await record({
    db,
    blockNumber: args.blockNumber,
    timestamp: args.timestamp,
    txHash: null,
    detection: 'probe',
    target: args.token,
    caller: null,
    selector: null,
    accounts: [args.account],
    constituentId: args.constituentId,
    protocolAddresses: protocolAddressSet(contracts),
    logIndex: args.logIndex,
  })
}

ponder.on('StockTokenCalls:transaction:to', async ({event, context}) => {
  await handleCall(context, event)
})

ponder.on('DenylistWatch:transaction:to', async ({event, context}) => {
  await handleCall(context, event)
})
