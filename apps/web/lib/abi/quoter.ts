// SPDX-License-Identifier: MIT

/**
 * `AmpsQuoter` — the one read surface that prices a pool without simulating a swap.
 *
 * **Why this ABI is hand-written.** `@amplestocks/abis` has not been regenerated since revision 6
 * appended `passThroughBuyFeePips` and `passThroughSellFeePips` to `PoolQuote`. A struct is decoded
 * positionally, so decoding a revision-6 `quoteAll()` against the revision-5 tuple does not fail —
 * it silently shifts every field after `sellFeePips`, which would put a fee where a boolean belongs
 * and render the gate state as a tick. This file is transcribed from
 * `contracts/src/interfaces/IAmpsQuoter.sol` and `contracts/src/periphery/AmpsQuoter.sol`; when the
 * package regenerates, the import in `lib/contracts.ts` moves and this file goes away.
 *
 * **Four fee legs, because revision 6 has two prices per direction.** `buyFeePips` and
 * `sellFeePips` are what an ordinary trade pays — base `ampsFeeBps` on *both* sides — and are the
 * numbers to show someone buying or selling AMPS. `passThroughBuyFeePips` and
 * `passThroughSellFeePips` are the two hops of an `AmpsRouter.rotate`, based on the pool's
 * `buyFeeBps`, and are unreachable through any other path.
 *
 * **It never reverts.** Every external read it makes is a bounded `try`/`staticcall`; a failure
 * leaves that read's fields at zero and raises its bit in `degraded`. A zeroed field is not a zero
 * value, and `refuseBuy`/`refuseSell` come back `false` when bit 0 is set — it fails **open for
 * display**, and no execution path may read a degraded quote as permission to trade.
 */

/** `IAmpsQuoter.PoolQuote`, field for field and in order. Shared by `quotePool` and `quoteAll`. */
const poolQuoteComponents = [
  {name: 'poolId', internalType: 'PoolId', type: 'bytes32'},
  {name: 'poolClass', internalType: 'enum PoolClass', type: 'uint8'},
  {name: 'counter', internalType: 'address', type: 'address'},
  {name: 'pMktX18', internalType: 'uint256', type: 'uint256'},
  {name: 'pRefX18', internalType: 'uint256', type: 'uint256'},
  {name: 'navPerShareX18', internalType: 'uint256', type: 'uint256'},
  {name: 'premiumX18', internalType: 'int256', type: 'int256'},
  {name: 'poolTick', internalType: 'int24', type: 'int24'},
  {name: 'fairTick', internalType: 'int24', type: 'int24'},
  {name: 'innerBandTicks', internalType: 'int24', type: 'int24'},
  {name: 'outerRailTicks', internalType: 'int24', type: 'int24'},
  /** The **pass-through** base fee: what one hop of a protocol-router rotation costs. */
  {name: 'buyFeeBps', internalType: 'uint16', type: 'uint16'},
  /** The base fee on **both** directions of this pool for everybody else. */
  {name: 'ampsFeeBps', internalType: 'uint16', type: 'uint16'},
  /** Net-trade total for an ordinary buy, dynamic component included. */
  {name: 'buyFeePips', internalType: 'uint24', type: 'uint24'},
  /** Net-trade total for an ordinary sell. */
  {name: 'sellFeePips', internalType: 'uint24', type: 'uint24'},
  /** Hop 1 of an `AmpsRouter.rotate` through this pool. Appended, revision 6. */
  {name: 'passThroughBuyFeePips', internalType: 'uint24', type: 'uint24'},
  /** Hop 2 of an `AmpsRouter.rotate`, fully covered by the credit hop 1 created. Appended, revision 6. */
  {name: 'passThroughSellFeePips', internalType: 'uint24', type: 'uint24'},
  {name: 'dynBps', internalType: 'uint16', type: 'uint16'},
  {name: 'dynCapBps', internalType: 'uint16', type: 'uint16'},
  {name: 'refuseSell', internalType: 'bool', type: 'bool'},
  {name: 'refuseBuy', internalType: 'bool', type: 'bool'},
  {name: 'bondQX18', internalType: 'uint256', type: 'uint256'},
  {name: 'bondDiscountBps', internalType: 'uint16', type: 'uint16'},
  {name: 'bondCapacityLeft', internalType: 'uint256', type: 'uint256'},
  {name: 'bondOpen', internalType: 'bool', type: 'bool'},
  {name: 'gateState', internalType: 'uint8', type: 'uint8'},
  {name: 'session', internalType: 'uint8', type: 'uint8'},
  {name: 'feedStale', internalType: 'bool', type: 'bool'},
  {name: 'corporateFreeze', internalType: 'bool', type: 'bool'},
  {name: 'observationCoverage', internalType: 'uint32', type: 'uint32'},
  {name: 'checkpointAge', internalType: 'uint32', type: 'uint32'},
  {name: 'degraded', internalType: 'uint8', type: 'uint8'},
  {name: 'tickSpacing', internalType: 'int24', type: 'int24'},
] as const

export const ampsQuoterAbi = [
  {
    type: 'function',
    name: 'quotePool',
    stateMutability: 'view',
    inputs: [{name: 'poolId', internalType: 'PoolId', type: 'bytes32'}],
    outputs: [{name: 'quote', internalType: 'struct IAmpsQuoter.PoolQuote', type: 'tuple', components: poolQuoteComponents}],
  },
  {
    type: 'function',
    name: 'quoteAll',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: 'quotes', internalType: 'struct IAmpsQuoter.PoolQuote[]', type: 'tuple[]', components: poolQuoteComponents}],
  },
  /**
   * Prices the `AmpsRouter.rotate` path and nothing else: both hops as pass-through, with the
   * credit hop 1 creates modelled rather than read. The same two swaps built by hand through any
   * other router each pay `ampsFeeBps` — that is two `quoteExactIn` calls, not this one.
   */
  {
    type: 'function',
    name: 'quoteRotation',
    stateMutability: 'view',
    inputs: [
      {name: 'hop1', internalType: 'PoolId', type: 'bytes32'},
      {name: 'hop2', internalType: 'PoolId', type: 'bytes32'},
      {name: 'amountIn', internalType: 'uint256', type: 'uint256'},
    ],
    outputs: [
      {name: 'amountOut', internalType: 'uint256', type: 'uint256'},
      {name: 'hop1FeePips', internalType: 'uint24', type: 'uint24'},
      {name: 'hop2FeePips', internalType: 'uint24', type: 'uint24'},
      {name: 'creditUsed', internalType: 'uint256', type: 'uint256'},
    ],
  },
  /**
   * The amount and the fee for an ordinary swap, priced at `ampsFeeBps` — what everything that is
   * not `AmpsRouter.rotate` pays. A refusal comes back as `refuse == true` with `amountOut == 0`,
   * never as a revert.
   */
  {
    type: 'function',
    name: 'quoteExactIn',
    stateMutability: 'view',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32'},
      {name: 'zeroForOne', internalType: 'bool', type: 'bool'},
      {name: 'amountIn', internalType: 'uint256', type: 'uint256'},
    ],
    outputs: [
      {name: 'amountOut', internalType: 'uint256', type: 'uint256'},
      {name: 'feePips', internalType: 'uint24', type: 'uint24'},
      {name: 'refuse', internalType: 'bool', type: 'bool'},
      {name: 'degraded', internalType: 'uint8', type: 'uint8'},
    ],
  },
  /**
   * Hop 2 of a rotation in the general case, where the sell is larger than the buy that funds it.
   * `credit == 0` is the honest argument for every caller that is not `AmpsRouter.rotate`, and it
   * prices the sell at `ampsFeeBps` exactly as `quoteExactIn` does.
   */
  {
    type: 'function',
    name: 'quoteSellWithCredit',
    stateMutability: 'view',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32'},
      {name: 'ampsIn', internalType: 'uint256', type: 'uint256'},
      {name: 'credit', internalType: 'uint256', type: 'uint256'},
    ],
    outputs: [
      {name: 'amountOut', internalType: 'uint256', type: 'uint256'},
      {name: 'feePips', internalType: 'uint24', type: 'uint24'},
      {name: 'refuse', internalType: 'bool', type: 'bool'},
      {name: 'degraded', internalType: 'uint8', type: 'uint8'},
    ],
  },
  /** The hook's own refusal verdict, with a reason: `0`, `"rail"` or `"uninitialized"`. */
  {
    type: 'function',
    name: 'wouldRevert',
    stateMutability: 'view',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32'},
      {name: 'zeroForOne', internalType: 'bool', type: 'bool'},
      {name: 'exactInput', internalType: 'bool', type: 'bool'},
      {name: 'amount', internalType: 'uint256', type: 'uint256'},
    ],
    outputs: [
      {name: 'refuse', internalType: 'bool', type: 'bool'},
      {name: 'reason', internalType: 'bytes32', type: 'bytes32'},
      {name: 'degraded', internalType: 'uint8', type: 'uint8'},
    ],
  },
  /** The redemption floor in the pool's own ticks. Disclosure: nothing on chain enforces it. */
  {
    type: 'function',
    name: 'navRail',
    stateMutability: 'view',
    inputs: [{name: 'poolId', internalType: 'PoolId', type: 'bytes32'}],
    outputs: [
      {name: 'navTick', internalType: 'int24', type: 'int24'},
      {name: 'railTick', internalType: 'int24', type: 'int24'},
      {name: 'belowRail', internalType: 'bool', type: 'bool'},
      {name: 'navPerShareX18', internalType: 'uint256', type: 'uint256'},
      {name: 'degraded', internalType: 'uint8', type: 'uint8'},
    ],
  },
  {
    type: 'function',
    name: 'bondQuote',
    stateMutability: 'view',
    inputs: [{name: 'marketId', internalType: 'uint16', type: 'uint16'}],
    outputs: [
      {name: 'qX18', internalType: 'uint256', type: 'uint256'},
      {name: 'discountBps', internalType: 'uint16', type: 'uint16'},
      {name: 'capacityLeft', internalType: 'uint256', type: 'uint256'},
      {name: 'open', internalType: 'bool', type: 'bool'},
      {name: 'degraded', internalType: 'uint8', type: 'uint8'},
    ],
  },
  {
    type: 'function',
    name: 'poolIds',
    stateMutability: 'view',
    inputs: [],
    outputs: [{name: 'ids', internalType: 'PoolId[]', type: 'bytes32[]'}],
  },

  // -------------------------------------------------------------------------------------------
  // Pointers
  // -------------------------------------------------------------------------------------------

  {type: 'function', name: 'vault', stateMutability: 'view', inputs: [], outputs: [{name: 'vaultAddress', type: 'address'}]},
  {type: 'function', name: 'registry', stateMutability: 'view', inputs: [], outputs: [{name: 'registryAddress', type: 'address'}]},
  {type: 'function', name: 'hook', stateMutability: 'view', inputs: [], outputs: [{name: 'hookAddress', type: 'address'}]},
  {type: 'function', name: 'bonds', stateMutability: 'view', inputs: [], outputs: [{name: 'bondsAddress', type: 'address'}]},
  {type: 'function', name: 'poolManager', stateMutability: 'view', inputs: [], outputs: [{name: 'poolManagerAddress', type: 'address'}]},
  {type: 'function', name: 'oracleGate', stateMutability: 'view', inputs: [], outputs: [{name: 'gateAddress', type: 'address'}]},
  {type: 'function', name: 'feedRegistry', stateMutability: 'view', inputs: [], outputs: [{name: 'feedRegistryAddress', type: 'address'}]},
  {type: 'function', name: 'version', stateMutability: 'pure', inputs: [], outputs: [{name: 'id', type: 'bytes32'}]},
] as const
