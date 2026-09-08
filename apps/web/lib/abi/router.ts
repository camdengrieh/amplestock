// SPDX-License-Identifier: MIT

/**
 * `AmpsRouter` — the protocol's own router, and the only address in the world whose rotation hops
 * the hook prices at the pass-through fee.
 *
 * **Why this ABI is hand-written.** `@amplestocks/abis` is generated from the Foundry artefacts and
 * committed, and it has not been regenerated since `AmpsRouter` landed, so there is no
 * `ampsRouterAbi` to import yet. This file is transcribed from
 * `contracts/src/interfaces/IAmpsRouter.sol` and `contracts/src/types/Errors.sol` and is checked
 * against them by `test/router-abi.test.ts`. When the package regenerates, the import in
 * `lib/contracts.ts` moves and this file goes away; a compile error is the worst that can happen.
 *
 * **Why a pass-through needs its own router.** The hook fixes a hop's fee in `beforeSwap`, before
 * the swap runs, so hop 1 of a route cannot know that a hop 2 follows: that is a fact about the
 * caller's intentions, not about the pool. Charging the cheap fee optimistically and refunding
 * would need the hook to hold value, which it never does; letting any caller flag any hop as
 * pass-through would make the AMPS fee voluntary. What is left is a declaration the hook can check
 * — `sender == AmpsHook.router()` **and** `hookData == Constants.ROUTER_ROTATE` — and {rotate} is
 * the only call in this contract that sets it. {buy} and {sell} pass empty `hookData` and pay
 * `ampsFeeBps` like any other swap through any other router: routing an exit through the
 * protocol's own front end must not make the exit cheaper.
 */
export const ampsRouterAbi = [
  // -------------------------------------------------------------------------------------------
  // Trades
  // -------------------------------------------------------------------------------------------

  /**
   * stock → AMPS → stock, or entry asset → AMPS → stock, in one call: the one shape that pays the
   * pass-through fee on both hops.
   *
   * `hop1` is the pool AMPS is bought in, `hop2` the pool it is sold in; `amountIn` is exact input
   * in `hop1`'s counter asset and `minOut` is denominated in `hop2`'s counter asset. `unwrap` pays
   * out native ether when `hop2`'s counter is the wrapped native token. Both hops run inside one
   * `unlock`, hop 2 sells exactly the AMPS hop 1 realised, and the router's AMPS delta is asserted
   * to be zero before anything settles — `ampsThrough` is that amount, returned so a caller can
   * reconcile the route it was quoted.
   */
  {
    type: 'function',
    name: 'rotate',
    stateMutability: 'payable',
    inputs: [
      {name: 'hop1', internalType: 'PoolId', type: 'bytes32'},
      {name: 'hop2', internalType: 'PoolId', type: 'bytes32'},
      {name: 'amountIn', internalType: 'uint256', type: 'uint256'},
      {name: 'minOut', internalType: 'uint256', type: 'uint256'},
      {name: 'to', internalType: 'address', type: 'address'},
      {name: 'unwrap', internalType: 'bool', type: 'bool'},
      {name: 'deadline', internalType: 'uint256', type: 'uint256'},
    ],
    outputs: [
      {name: 'amountOut', internalType: 'uint256', type: 'uint256'},
      {name: 'ampsThrough', internalType: 'uint256', type: 'uint256'},
    ],
  },
  /**
   * Counter asset → AMPS in one pool. Payable so the WETH leg can be paid in native ether.
   *
   * **Not pass-through.** It pays `AmpsHook.ampsFeeBps()` plus the dynamic component and earns no
   * rotation credit: buying AMPS is entering the index, and only {rotate} moves through it.
   */
  {
    type: 'function',
    name: 'buy',
    stateMutability: 'payable',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32'},
      {name: 'amountIn', internalType: 'uint256', type: 'uint256'},
      {name: 'minAmpsOut', internalType: 'uint256', type: 'uint256'},
      {name: 'to', internalType: 'address', type: 'address'},
      {name: 'deadline', internalType: 'uint256', type: 'uint256'},
    ],
    outputs: [{name: 'ampsOut', internalType: 'uint256', type: 'uint256'}],
  },
  /** AMPS → counter asset in one pool. `unwrap` pays native ether out of the WETH pool. */
  {
    type: 'function',
    name: 'sell',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32'},
      {name: 'ampsIn', internalType: 'uint256', type: 'uint256'},
      {name: 'minOut', internalType: 'uint256', type: 'uint256'},
      {name: 'to', internalType: 'address', type: 'address'},
      {name: 'unwrap', internalType: 'bool', type: 'bool'},
      {name: 'deadline', internalType: 'uint256', type: 'uint256'},
    ],
    outputs: [{name: 'amountOut', internalType: 'uint256', type: 'uint256'}],
  },

  // -------------------------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------------------------

  {type: 'function', name: 'poolManager', stateMutability: 'view', inputs: [], outputs: [{name: 'poolManagerAddress', type: 'address'}]},
  {type: 'function', name: 'amps', stateMutability: 'view', inputs: [], outputs: [{name: 'ampsAddress', type: 'address'}]},
  {type: 'function', name: 'registry', stateMutability: 'view', inputs: [], outputs: [{name: 'registryAddress', type: 'address'}]},
  {type: 'function', name: 'weth', stateMutability: 'view', inputs: [], outputs: [{name: 'wethAddress', type: 'address'}]},
  /**
   * `Constants.ROUTER_ROTATE` — the `hookData` this contract puts on both hops of a {rotate} and on
   * nothing else. Exposed so an integrator can check against `AmpsHook` what the exemption keys on
   * rather than taking a comment's word for it.
   */
  {type: 'function', name: 'ROTATE_FLAG', stateMutability: 'view', inputs: [], outputs: [{name: 'flag', type: 'bytes32'}]},

  // -------------------------------------------------------------------------------------------
  // Events
  // -------------------------------------------------------------------------------------------

  {
    type: 'event',
    name: 'Bought',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32', indexed: true},
      {name: 'payer', type: 'address', indexed: true},
      {name: 'to', type: 'address', indexed: true},
      {name: 'amountIn', type: 'uint256', indexed: false},
      {name: 'ampsOut', type: 'uint256', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'Sold',
    inputs: [
      {name: 'poolId', internalType: 'PoolId', type: 'bytes32', indexed: true},
      {name: 'payer', type: 'address', indexed: true},
      {name: 'to', type: 'address', indexed: true},
      {name: 'ampsIn', type: 'uint256', indexed: false},
      {name: 'amountOut', type: 'uint256', indexed: false},
    ],
  },
  {
    type: 'event',
    name: 'Rotated',
    inputs: [
      {name: 'hop1', internalType: 'PoolId', type: 'bytes32', indexed: true},
      {name: 'hop2', internalType: 'PoolId', type: 'bytes32', indexed: true},
      {name: 'to', type: 'address', indexed: true},
      {name: 'amountIn', type: 'uint256', indexed: false},
      {name: 'ampsThrough', type: 'uint256', indexed: false},
      {name: 'amountOut', type: 'uint256', indexed: false},
    ],
  },

  // -------------------------------------------------------------------------------------------
  // Errors — `contracts/src/types/Errors.sol`, the `AmpsRouter` section plus the shared ones it
  // reverts with. `lib/errors.ts` explains each of them.
  // -------------------------------------------------------------------------------------------

  {type: 'error', name: 'DeadlineExpired', inputs: [{name: 'deadline', type: 'uint256'}, {name: 'timestamp', type: 'uint256'}]},
  {type: 'error', name: 'SameHop', inputs: [{name: 'poolId', type: 'bytes32'}]},
  {type: 'error', name: 'AmpsResidual', inputs: [{name: 'delta', type: 'int256'}]},
  {type: 'error', name: 'UnexpectedValue', inputs: [{name: 'value', type: 'uint256'}]},
  {type: 'error', name: 'NativeTransferFailed', inputs: [{name: 'to', type: 'address'}, {name: 'amount', type: 'uint256'}]},
  {type: 'error', name: 'NotWrappedNative', inputs: [{name: 'counter', type: 'address'}]},
  {type: 'error', name: 'UnknownPool', inputs: [{name: 'poolId', type: 'bytes32'}]},
  {type: 'error', name: 'SlippageExceeded', inputs: [{name: 'received', type: 'uint256'}, {name: 'minimum', type: 'uint256'}]},
  {type: 'error', name: 'Reentrancy', inputs: []},
  {type: 'error', name: 'ZeroAddress', inputs: []},
  {type: 'error', name: 'ZeroAmount', inputs: []},
  {type: 'error', name: 'NotPoolManager', inputs: [{name: 'caller', type: 'address'}]},
] as const

/** A deadline `seconds` from now, in the router's units. */
export function routerDeadline(seconds = 600, now = Math.floor(Date.now() / 1000)): bigint {
  return BigInt(now + seconds)
}
