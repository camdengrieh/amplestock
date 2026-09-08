// SPDX-License-Identifier: MIT

/**
 * The ABIs the indexer needs that Amplestocks does **not** author, so they are not in
 * `@amplestocks/abis` (which is codegen over `contracts/out` and therefore only ever contains our
 * own contracts).
 *
 * Two surfaces live here:
 *
 * - **The Robinhood Stock Token.** `contracts/src/interfaces/IStockToken.sol` is the read surface
 *   the protocol depends on and is mirrored here fragment for fragment (`test/abi.test.ts` asserts
 *   that mirror against the compiled `IStockToken` artefact whenever a Foundry build is present).
 *   The issuer-side *write* surface is not in that interface at all — it belongs to the beacon
 *   implementation, not to us — so `blockAccounts` / `unblockAccounts` are declared here from the
 *   selectors the Phase 0 sweep recovered.
 * - **Chainlink's `AnswerUpdated`.** Emitted by the underlying `AccessControlledOffchainAggregator`,
 *   never by the proxy that `FeedRegistry` stores. See `handlers/feeds.ts` for what that means for
 *   the addresses this ABI is subscribed at.
 */

/**
 * `blockAccounts(address[])` — selector `0x6abf7081`, the beacon-level denylist. There is no delay,
 * no timelock and no event; the alarm therefore watches *calls*, not logs.
 */
export const stockTokenDenylistAbi = [
  {
    type: 'function',
    name: 'blockAccounts',
    stateMutability: 'nonpayable',
    inputs: [{name: 'accounts', type: 'address[]'}],
    outputs: [],
  },
  {
    type: 'function',
    name: 'unblockAccounts',
    stateMutability: 'nonpayable',
    inputs: [{name: 'accounts', type: 'address[]'}],
    outputs: [],
  },
] as const

/** The selector the plan names as go/no-go #1's alarm trigger. */
export const BLOCK_ACCOUNTS_SELECTOR = '0x6abf7081' as const

/** `unblockAccounts(address[])`. Recorded so a de-listing shows up next to the listing. */
export const UNBLOCK_ACCOUNTS_SELECTOR = '0xfaed47fd' as const

/**
 * The Stock Token read surface, mirroring `IStockToken` plus the ERC-20 metadata the dApp renders.
 * Every one of these is probed, never trusted: the implementation sits behind a beacon under a
 * codeless admin key, so a call can revert or return garbage at any block.
 */
export const stockTokenAbi = [
  {
    type: 'function',
    name: 'uiMultiplier',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: 'multiplier', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'newUIMultiplier',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: 'multiplier', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'effectiveAt',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: 'timestamp', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'oraclePaused',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: 'paused', type: 'bool'}],
  },
  {
    type: 'function',
    name: 'paused',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: 'isPaused', type: 'bool'}],
  },
  {
    type: 'function',
    name: 'isBlocked',
    stateMutability: 'view',
    inputs: [{name: 'account', type: 'address'}],
    outputs: [{name: 'blocked', type: 'bool'}],
  },
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [{name: 'account', type: 'address'}],
    outputs: [{name: '', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'decimals',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: '', type: 'uint8'}],
  },
  {
    type: 'function',
    name: 'symbol',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: '', type: 'string'}],
  },
] as const

/**
 * Chainlink's aggregator event. `current` is the answer in the feed's own decimals (8 on every
 * Robinhood Chain feed seen), `roundId` is the aggregator round, not the proxy round.
 */
export const chainlinkAggregatorAbi = [
  {
    type: 'event',
    name: 'AnswerUpdated',
    inputs: [
      {name: 'current', type: 'int256', indexed: true},
      {name: 'roundId', type: 'uint256', indexed: true},
      {name: 'updatedAt', type: 'uint256', indexed: false},
    ],
    anonymous: false,
  },
] as const

/** Minimal ERC-20 reads for counter assets (WETH9, USDG and the Stock Tokens). */
export const erc20Abi = [
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [{name: 'account', type: 'address'}],
    outputs: [{name: '', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'decimals',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: '', type: 'uint8'}],
  },
  {
    type: 'function',
    name: 'symbol',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: '', type: 'string'}],
  },
] as const

/**
 * Uniswap's `ContinuousClearingAuction`, events only.
 *
 * The two genesis auctions are deployed by Uniswap's factory, not by us, so their ABI is not in
 * `@amplestocks/abis` and never will be. Only the five events are declared here: the indexer
 * subscribes to the auctions as a **factory** over `AmpsGenesis.AuctionsCreated`, so it needs the
 * topics and nothing else — every read the dApp makes of an auction it makes directly.
 *
 * `apps/web/lib/abi/cca.ts` carries the same five fragments plus the read and write surface the
 * bidding UI needs. The two are transcriptions of the same upstream contract (CCA v2.1.0, MIT) and
 * must agree; `test/abi.test.ts` has no artefact to check them against, because there is no
 * Solidity source for them in this repository.
 *
 * `CheckpointUpdated` is the one that matters most: `checkpoint()` is a write rather than a view,
 * so the clearing price only moves when somebody pays to advance it, and this log is the only
 * record of what the auction actually charged over the bidding window.
 */
export const continuousClearingAuctionAbi = [
  {
    type: 'event',
    name: 'BidSubmitted',
    inputs: [
      {name: 'id', type: 'uint256', indexed: true},
      {name: 'owner', type: 'address', indexed: true},
      {name: 'priceQ96', type: 'uint256', indexed: false},
      {name: 'amount', type: 'uint128', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'CheckpointUpdated',
    inputs: [
      {name: 'blockNumber', type: 'uint256', indexed: false},
      {name: 'clearingPriceQ96', type: 'uint256', indexed: false},
      {name: 'cumulativeMps', type: 'uint24', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'ClearingPriceUpdated',
    inputs: [
      {name: 'blockNumber', type: 'uint256', indexed: false},
      {name: 'clearingPriceQ96', type: 'uint256', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'BidExited',
    inputs: [
      {name: 'bidId', type: 'uint256', indexed: true},
      {name: 'owner', type: 'address', indexed: true},
      {name: 'tokensFilled', type: 'uint256', indexed: false},
      {name: 'currencyRefunded', type: 'uint256', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'TokensClaimed',
    inputs: [
      {name: 'bidId', type: 'uint256', indexed: true},
      {name: 'owner', type: 'address', indexed: true},
      {name: 'tokensFilled', type: 'uint256', indexed: false},
    ],
  },
] as const
