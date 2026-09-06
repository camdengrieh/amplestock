// SPDX-License-Identifier: MIT

/**
 * Ponder configuration for the Amplestocks indexer.
 *
 * Sources, and why each is shaped the way it is:
 *
 * - **The eight Amplestocks contracts** are ordinary single-address log sources. Their addresses
 *   are deployment state and arrive through `src/config/addresses.ts`; an unresolved one is the
 *   zero address, which is a live source that never matches rather than a missing handler.
 * - **The Uniswap v4 `PoolManager`** is one shared deployment carrying every pool on the chain, so
 *   `Swap`, `ModifyLiquidity` and `Initialize` are filtered to our own `PoolId`s. When the id set
 *   is known ahead of time (`AMPS_POOL_IDS`, or `AMPS_POOLS` pointing at the `pools.json` that
 *   `script/05_Registry.s.sol` writes) the filter is pushed into `eth_getLogs` as a topic filter.
 *   When it is not, the source is unfiltered and every handler drops ids the registry has not
 *   announced — the registry's own `PoolRegistered` / `PoolOpened` events remain the authority
 *   either way, so the two modes index identically and only the RPC cost differs.
 * - **The Stock Tokens** are watched as *accounts*, not contracts — they emit only ERC-20 events,
 *   which the indexer has no use for, and the beacon-level denylist
 *   (`blockAccounts(address[])`, `0x6abf7081`) emits nothing at all, so the alarm has to see the
 *   transaction. The registered tokens come from a factory over `PoolRegistry.ConstituentAdded`;
 *   the beacon and anything else Phase 0 identifies come from `AMPS_DENYLIST_WATCH`.
 * - **Chainlink aggregators** are a factory over `FeedRegistry.FeedSet`. See `handlers/feeds.ts`
 *   for the proxy-versus-aggregator caveat; `FeedRegistry.AnswerLatched` is the authoritative
 *   record of what the protocol actually priced against and is always indexed.
 * - **Two block sources** drive the polling jobs: `constituentPoll` runs the `uiMultiplier()` /
 *   `newUIMultiplier()` / `effectiveAt()` / `oraclePaused()` state diff and the `isBlocked` probe,
 *   `reconcile` runs NAV and inventory reconciliation against chain reads.
 */

import {
  ampsAbi,
  ampsBondsAbi,
  ampsHookAbi,
  ampsStakingAbi,
  ampsVaultAbi,
  bountyPotAbi,
  feedRegistryAbi,
  oracleGateAbi,
  poolManagerAbi,
  poolRegistryAbi,
} from '@amplestocks/abis'
import {createConfig, factory} from 'ponder'
import {getAbiItem} from 'viem'

import {chainlinkAggregatorAbi} from './src/abi/external'
import {resolveAddresses} from './src/config/addresses'
import {readEnv} from './src/config/env'
import {denylistWatchList, poolIdFilter} from './src/config/pools'

const env = readEnv()
const book = resolveAddresses({chainId: env.chainId})
const poolIds = poolIdFilter()
const denylistWatch = denylistWatchList(book)

const swapFilter =
  poolIds.length > 0
    ? [
        {event: 'Swap' as const, args: {id: poolIds}},
        {event: 'ModifyLiquidity' as const, args: {id: poolIds}},
        {event: 'Initialize' as const, args: {id: poolIds}},
      ]
    : undefined

const constituentAdded = getAbiItem({abi: poolRegistryAbi, name: 'ConstituentAdded'})
const feedSet = getAbiItem({abi: feedRegistryAbi, name: 'FeedSet'})

const chain = {
  id: env.chainId,
  rpc: env.rpcUrl,
  ...(env.wsUrl ? {ws: env.wsUrl} : {}),
  pollingInterval: env.pollingInterval,
}

const window = {startBlock: env.startBlock, endBlock: env.endBlock}

export default createConfig({
  database: env.databaseUrl
    ? {kind: 'postgres', connectionString: env.databaseUrl}
    : {kind: 'pglite', directory: env.pgliteDirectory},
  ordering: 'omnichain',
  chains: {amps: chain},
  contracts: {
    AmpsVault: {chain: 'amps', abi: ampsVaultAbi, address: book.vault, ...window},
    AmpsBonds: {chain: 'amps', abi: ampsBondsAbi, address: book.bonds, ...window},
    AmpsStaking: {chain: 'amps', abi: ampsStakingAbi, address: book.staking, ...window},
    AmpsToken: {chain: 'amps', abi: ampsAbi, address: book.amps, ...window},
    PoolRegistry: {chain: 'amps', abi: poolRegistryAbi, address: book.registry, ...window},
    OracleGate: {chain: 'amps', abi: oracleGateAbi, address: book.oracleGate, ...window},
    FeedRegistry: {chain: 'amps', abi: feedRegistryAbi, address: book.feedRegistry, ...window},
    AmpsHook: {chain: 'amps', abi: ampsHookAbi, address: book.hook, ...window},
    BountyPot: {chain: 'amps', abi: bountyPotAbi, address: book.bountyPot, ...window},
    PoolManager: {
      chain: 'amps',
      abi: poolManagerAbi,
      address: book.poolManager,
      ...(swapFilter ? {filter: swapFilter} : {}),
      ...window,
    },
    ChainlinkAggregator: {
      chain: 'amps',
      abi: chainlinkAggregatorAbi,
      address: factory({
        address: book.feedRegistry,
        event: feedSet,
        parameter: 'aggregator',
        startBlock: env.startBlock,
      }),
      ...window,
    },
  },
  accounts: {
    // Every transaction addressed at a registered Stock Token. The denylist alarm decodes the
    // selector; nothing else uses this source.
    StockTokenCalls: {
      chain: 'amps',
      address: factory({
        address: book.registry,
        event: constituentAdded,
        parameter: 'token',
        startBlock: env.startBlock,
      }),
      ...window,
    },
    // The beacon, its implementation, the issuer admin key and anything else Phase 0 names.
    DenylistWatch: {chain: 'amps', address: denylistWatch, ...window},
  },
  blocks: {
    constituentPoll: {
      chain: 'amps',
      interval: env.multiplierPollInterval,
      startBlock: env.startBlock,
      endBlock: env.endBlock,
    },
    reconcile: {
      chain: 'amps',
      interval: env.reconcilePollInterval,
      startBlock: env.startBlock,
      endBlock: env.endBlock,
    },
  },
})
