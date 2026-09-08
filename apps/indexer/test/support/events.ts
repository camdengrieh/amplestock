// SPDX-License-Identifier: MIT

/**
 * Synthetic logs and a synthetic indexing context.
 *
 * Everything a handler reads off an event — `event.args`, `event.log.logIndex`, `event.block`,
 * `event.transaction` — is built here from a small set of defaults, so a test names only the fields
 * it cares about. `makeContext` supplies the in-memory `db`, a scripted `client.readContract` and
 * the address book the handlers use to identify themselves.
 */

import {createFakeDb, type FakeDb, type Table} from './db'

export const ADDRESSES = {
  AmpsVault: '0x00000000000000000000000000000000000000a1',
  AmpsToken: '0x00000000000000000000000000000000000000a2',
  PoolRegistry: '0x00000000000000000000000000000000000000a3',
  AmpsHook: '0x00000000000000000000000000000000000038c0',
  AmpsBonds: '0x00000000000000000000000000000000000000a5',
  AmpsRouter: '0x00000000000000000000000000000000000000a6',
  BountyPot: '0x00000000000000000000000000000000000000a7',
  OracleGate: '0x00000000000000000000000000000000000000a8',
  FeedRegistry: '0x00000000000000000000000000000000000000a9',
  PoolManager: '0x00000000000000000000000000000000000000aa',
  LadderPositionValuer: '0x00000000000000000000000000000000000000ab',
  /** `AmpsGenesis`, and the two auctions it deploys through Uniswap's factory. */
  AmpsGenesis: '0x00000000000000000000000000000000000000ac',
  GenesisAuctionUsdg: '0x00000000000000000000000000000000000000ad',
  GenesisAuctionEth: '0x00000000000000000000000000000000000000ae',
} as const

/** The team's `VestingWallet`, and the `AmpsGenesis` adapter, as `GenesisMinted` names them. */
export const TEAM_VESTING = '0x00000000000000000000000000000000000000f1' as const
export const CREATOR = '0x00000000000000000000000000000000000000f2' as const
export const BIDDER = '0x00000000000000000000000000000000000000f3' as const

export const POOL_ID = '0x1111111111111111111111111111111111111111111111111111111111111111' as const
export const COUNTER = '0x00000000000000000000000000000000000000c1' as const
export const TOKEN = '0x00000000000000000000000000000000000000c2' as const
export const CALLER = '0x00000000000000000000000000000000000000d1' as const
/** A second vault, for the `setVault` migration handovers. */
export const NEW_VAULT = '0x00000000000000000000000000000000000000e1' as const

let logIndex = 0

export interface EventOptions {
  args: Record<string, unknown>
  blockNumber?: bigint
  timestamp?: bigint
  txHash?: `0x${string}`
  from?: `0x${string}`
  to?: `0x${string}` | null
  input?: `0x${string}`
  logIndex?: number
  address?: `0x${string}`
}

export function makeEvent(options: EventOptions) {
  const index = options.logIndex ?? logIndex++
  return {
    id: `${options.blockNumber ?? 1n}-${index}`,
    args: options.args as never,
    log: {logIndex: index, address: options.address ?? ADDRESSES.AmpsVault},
    block: {
      number: options.blockNumber ?? 100n,
      timestamp: options.timestamp ?? 1_788_962_400n,
    },
    transaction: {
      hash: options.txHash ?? ('0x' + 'ab'.repeat(32)),
      from: options.from ?? CALLER,
      to: options.to === undefined ? ADDRESSES.AmpsVault : options.to,
      input: options.input ?? '0x',
    },
  }
}

/** Reset the auto-incrementing log index between tests so ids stay predictable. */
export function resetLogIndex(): void {
  logIndex = 0
}

export type ReadStub = (args: {
  address: string
  functionName: string
  args?: readonly unknown[]
}) => Promise<unknown>

export interface TestContext {
  db: FakeDb
  client: {readContract: ReadStub}
  contracts: Record<string, {address: string}>
}

export function makeContext(reads: Record<string, unknown> = {}, db: FakeDb = createFakeDb()): TestContext {
  return {
    db,
    client: {
      // Ponder's own `readContract` returns a promise and the handlers `.catch()` it, so a stub
      // that threw synchronously would exercise a path that cannot happen in production.
      readContract: async ({functionName}) => {
        if (functionName in reads) {
          const value = reads[functionName]
          if (value instanceof Error) throw value
          return value
        }
        throw new Error(`[test] unstubbed read: ${functionName}`)
      },
    },
    contracts: Object.fromEntries(
      Object.entries(ADDRESSES).map(([name, address]) => [name, {address}]),
    ),
  }
}

// -----------------------------------------------------------------------------------------------
// Named fixtures
// -----------------------------------------------------------------------------------------------

/**
 * The events the audited contracts added, each as a builder that fills in the emitting address and
 * leaves the block, log index and arguments to the caller. They are named because every one of them
 * is a *disclosure* — a residue, a forwarded donation, a detached market, a repointed vault — and a
 * test that has to restate the emitter's address alongside the arguments reads as though the
 * address were part of the fact.
 */
type Overrides = Omit<EventOptions, 'args' | 'address'>

/** `AmpsVault.SweepResidue(token, balance)`: the exit sweep could not absorb an idle balance. */
export function sweepResidue(
  args: {token?: `0x${string}`; balance: bigint},
  overrides: Overrides = {},
) {
  return makeEvent({
    args: {token: args.token ?? TOKEN, balance: args.balance},
    address: ADDRESSES.AmpsVault,
    ...overrides,
  })
}

/** `AmpsBonds.CollateralForwarded(collateral, amount)`: donated dust pushed on to the vault. */
export function collateralForwarded(
  args: {collateral?: `0x${string}`; amount: bigint},
  overrides: Overrides = {},
) {
  return makeEvent({
    args: {collateral: args.collateral ?? TOKEN, amount: args.amount},
    address: ADDRESSES.AmpsBonds,
    ...overrides,
  })
}

/** `PoolRegistry.BondMarketDetached(constituentId, marketId)`: the market was gone from `AmpsBonds`. */
export function bondMarketDetached(
  args: {constituentId: number; marketId: number},
  overrides: Overrides = {},
) {
  return makeEvent({
    args: {constituentId: args.constituentId, marketId: args.marketId},
    address: ADDRESSES.PoolRegistry,
    ...overrides,
  })
}

/** `VaultChanged(previousVault, newVault)`, emitted by `PoolRegistry`, `AmpsHook` and the rest. */
export function vaultChanged(
  emitter: keyof typeof ADDRESSES,
  args: {previousVault?: `0x${string}`; newVault?: `0x${string}`} = {},
  overrides: Overrides = {},
) {
  return makeEvent({
    args: {
      previousVault: args.previousVault ?? ADDRESSES.AmpsVault,
      newVault: args.newVault ?? NEW_VAULT,
    },
    address: ADDRESSES[emitter],
    ...overrides,
  })
}

/** `await run('AmpsVault:NavCheckpoint', event, context)` — call a registered handler. */
export async function run(
  name: string,
  event: ReturnType<typeof makeEvent>,
  context: TestContext,
): Promise<void> {
  const {handlerFor} = await import('./registry')
  await handlerFor(name)({event, context})
}

export type {FakeDb, Table}
