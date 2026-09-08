// SPDX-License-Identifier: MIT

/**
 * `IContinuousClearingAuction` — Uniswap's Continuous Clearing Auction, v2.1.0, MIT.
 *
 * Transcribed from `src/interfaces/IContinuousClearingAuction.sol` and the storage interfaces it
 * inherits (`IAuctionStorage`, `IBidStorage`, `ICheckpointStorage`, `IStepStorage`, `ITickStorage`)
 * at github.com/Uniswap/continuous-clearing-auction. It is hand-written for the same reason
 * `router.ts` is: the contract is a third-party dependency with no artefact in this repository, so
 * there is nothing for `wagmi generate` to read. Only the entries this surface calls are here.
 *
 * **What a CCA is, in one paragraph.** Tokens are released on a fixed per-block schedule. Bidders
 * post a maximum price and an amount of the auction's currency; the contract keeps a tick book of
 * demand and raises the clearing price only as far as demand supports. Everyone who clears pays the
 * *same* final price, so bidding early is never punished — an early bid at a high maximum ends up
 * paying the clearing price like everyone else, with the difference refunded. Bids strictly above
 * the final clearing price fill in full; bids at it may fill partly; bids below it fill not at all
 * and are refunded in full. If the auction does not graduate, everything is refunded.
 *
 * Two details this surface depends on:
 *
 * - **Prices are Q96**, currency raw units per token raw unit, shifted left 96 bits. `lib/auction.ts`
 *   converts, and does it in `bigint` throughout — a float round trip at 2^96 loses the low bits.
 * - **`checkpoint()` is not a view.** Every read below is "as of the last checkpoint", which may be
 *   stale; the contract itself says so. The surface labels the clearing price with the block its
 *   checkpoint was taken at rather than implying it is live to the current block.
 */

/** `1e7` — the auction's unit of supply share. One MPS is a ten-millionth of the total supply. */
export const AUCTION_MPS = 10_000_000n

/** `2^96`. */
export const Q96 = 1n << 96n

/**
 * `CCALens`, the optional tick-reading helper, deployed at the same address on every chain that has
 * it. This surface does not call it: the three tick reads it wants — `floorPrice`, `tickSpacing`
 * and `nextActiveTickPrice` — are on the auction itself, and one fewer address to be wrong about is
 * worth more than a batched read. Recorded so nobody rediscovers it, and shown on the docs page.
 */
export const CCA_LENS_ADDRESS = '0xc3C65F5453A3674aDb693cbdA3C842545cD30f53' as const

export const ccaAbi = [
  // --- Identity and configuration -------------------------------------------------------------
  {type: 'function', name: 'currency', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'address'}]},
  {type: 'function', name: 'token', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'address'}]},
  {type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint128'}]},
  {type: 'function', name: 'fundsRecipient', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'address'}]},
  {type: 'function', name: 'tokensRecipient', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'address'}]},
  {type: 'function', name: 'validationHook', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'address'}]},
  {type: 'function', name: 'startBlock', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint64'}]},
  {type: 'function', name: 'endBlock', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint64'}]},
  {type: 'function', name: 'claimBlock', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint64'}]},

  // --- Price and demand -----------------------------------------------------------------------
  {type: 'function', name: 'clearingPrice', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint256'}]},
  {type: 'function', name: 'isGraduated', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'bool'}]},
  {
    type: 'function',
    name: 'requiredDemandQ96',
    stateMutability: 'view',
    inputs: [{name: '_priceQ96', type: 'uint256'}],
    outputs: [{name: '', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'requiredDemandQ96AtNextActiveTick',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: '', type: 'uint256'}],
  },
  {type: 'function', name: 'floorPrice', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint256'}]},
  {type: 'function', name: 'tickSpacing', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint256'}]},
  {
    type: 'function',
    name: 'nextActiveTickPrice',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: '', type: 'uint256'}],
  },
  {type: 'function', name: 'MAX_BID_PRICE', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint256'}]},

  // --- Raised and cleared ---------------------------------------------------------------------
  {type: 'function', name: 'currencyRaised', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint256'}]},
  {type: 'function', name: 'totalCleared', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint256'}]},
  {type: 'function', name: 'remainingSupply', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint256'}]},
  {
    type: 'function',
    name: 'sumCurrencyDemandAboveClearingQ96',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: '', type: 'uint256'}],
  },

  // --- Checkpoints and steps --------------------------------------------------------------------
  {
    type: 'function',
    name: 'latestCheckpoint',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      {
        name: '',
        type: 'tuple',
        components: [
          {name: 'clearingPrice', type: 'uint256'},
          {name: 'currencyRaisedAtClearingPriceQ96X7', type: 'uint256'},
          {name: 'cumulativeMpsPerPrice', type: 'uint256'},
          {name: 'cumulativeMps', type: 'uint24'},
          {name: 'prev', type: 'uint64'},
          {name: 'next', type: 'uint64'},
        ],
      },
    ],
  },
  {
    type: 'function',
    name: 'lastCheckpointedBlock',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: '', type: 'uint64'}],
  },
  {
    type: 'function',
    name: 'step',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      {
        name: '',
        type: 'tuple',
        components: [
          {name: 'mps', type: 'uint24'},
          {name: 'startBlock', type: 'uint64'},
          {name: 'endBlock', type: 'uint64'},
        ],
      },
    ],
  },

  // --- Bids -------------------------------------------------------------------------------------
  {type: 'function', name: 'nextBidId', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint256'}]},
  {
    type: 'function',
    name: 'bids',
    stateMutability: 'view',
    inputs: [{name: 'bidId', type: 'uint256'}],
    outputs: [
      {
        name: '',
        type: 'tuple',
        components: [
          {name: 'startBlock', type: 'uint64'},
          {name: 'startCumulativeMps', type: 'uint24'},
          {name: 'exitedBlock', type: 'uint64'},
          {name: 'maxPrice', type: 'uint256'},
          {name: 'owner', type: 'address'},
          {name: 'amountQ96', type: 'uint256'},
          {name: 'tokensFilled', type: 'uint256'},
        ],
      },
    ],
  },

  // --- Writes -------------------------------------------------------------------------------------
  {
    type: 'function',
    name: 'submitBid',
    stateMutability: 'payable',
    inputs: [
      {name: 'maxPriceQ96', type: 'uint256'},
      {name: 'amount', type: 'uint128'},
      {name: 'owner', type: 'address'},
      {name: 'prevTickPriceQ96', type: 'uint256'},
      {name: 'hookData', type: 'bytes'},
    ],
    outputs: [{name: 'bidId', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'submitBid',
    stateMutability: 'payable',
    inputs: [
      {name: 'maxPriceQ96', type: 'uint256'},
      {name: 'amount', type: 'uint128'},
      {name: 'owner', type: 'address'},
      {name: 'hookData', type: 'bytes'},
    ],
    outputs: [{name: 'bidId', type: 'uint256'}],
  },
  {type: 'function', name: 'exitBid', stateMutability: 'nonpayable', inputs: [{name: 'bidId', type: 'uint256'}], outputs: []},
  {
    type: 'function',
    name: 'exitPartiallyFilledBid',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'bidId', type: 'uint256'},
      {name: 'lastFullyFilledCheckpointBlock', type: 'uint64'},
      {name: 'outbidBlock', type: 'uint64'},
    ],
    outputs: [],
  },
  {type: 'function', name: 'claimTokens', stateMutability: 'nonpayable', inputs: [{name: 'bidId', type: 'uint256'}], outputs: []},
  {
    type: 'function',
    name: 'claimTokensBatch',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'owner', type: 'address'},
      {name: 'bidIds', type: 'uint256[]'},
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'checkpoint',
    stateMutability: 'nonpayable',
    inputs: [],
    outputs: [
      {
        name: '_checkpoint',
        type: 'tuple',
        components: [
          {name: 'clearingPrice', type: 'uint256'},
          {name: 'currencyRaisedAtClearingPriceQ96X7', type: 'uint256'},
          {name: 'cumulativeMpsPerPrice', type: 'uint256'},
          {name: 'cumulativeMps', type: 'uint24'},
          {name: 'prev', type: 'uint64'},
          {name: 'next', type: 'uint64'},
        ],
      },
    ],
  },

  // --- Events ---------------------------------------------------------------------------------
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

/** `AggregatorV3Interface.latestRoundData` — the one read that turns USDG into USD. */
export const chainlinkAggregatorAbi = [
  {type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{name: '', type: 'uint8'}]},
  {
    type: 'function',
    name: 'latestRoundData',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      {name: 'roundId', type: 'uint80'},
      {name: 'answer', type: 'int256'},
      {name: 'startedAt', type: 'uint256'},
      {name: 'updatedAt', type: 'uint256'},
      {name: 'answeredInRound', type: 'uint80'},
    ],
  },
] as const
