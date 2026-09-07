// SPDX-License-Identifier: MIT

/**
 * `AmpsRouter` — the protocol's own router, and the only way a pass-through can exist.
 *
 * **Why this ABI is hand-written and the others are not.** Every other ABI in this app comes out of
 * `@amplestocks/abis`, which is generated from the Foundry artefacts and committed, so it cannot
 * drift from the contracts. `AmpsRouter` is being written now and has no artefact yet, so this file
 * is the signature the surface is built against. It is deliberately *only* the three external
 * entry points — no events, no errors, no views — so that when the artefact lands, replacing this
 * import with the generated one is a one-line change and a compile error is the worst that can
 * happen.
 *
 * **Why a pass-through needs its own router.** The hook fixes a hop's fee in `beforeSwap`, before
 * the swap runs. A rotation's second hop is only cheap if the AMPS it is selling was bought by the
 * first hop in the same transaction, and the only thing that can prove that to the hook is the
 * rotation credit in EIP-1153 transient storage — which exists for the duration of one transaction
 * and is keyed by the caller. A third-party router calling the PoolManager twice creates no credit
 * the hook will honour on its own terms, so its AMPS-buying leg pays the AMPS fee like any other
 * buy. That is not a policy choice; it is what "the fee is fixed before the swap runs" means.
 */
export const ampsRouterAbi = [
  /**
   * stock -> AMPS -> stock, or entry asset -> AMPS -> stock, in one call.
   *
   * `hop1` is the pool AMPS is bought in, `hop2` the pool it is sold in; `amountIn` is exact input
   * in `hop1`'s counter asset, and `minOut` is denominated in `hop2`'s counter asset. `unwrap`
   * pays out native ETH when `hop2`'s counter is WETH9.
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
    outputs: [{name: 'amountOut', internalType: 'uint256', type: 'uint256'}],
  },
  /** Counter asset -> AMPS in one pool. Payable so the WETH leg can be paid in native ETH. */
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
  /** AMPS -> counter asset in one pool. `unwrap` pays native ETH out of the WETH pool. */
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
] as const

/** A deadline `seconds` from now, in the router's units. */
export function routerDeadline(seconds = 600, now = Math.floor(Date.now() / 1000)): bigint {
  return BigInt(now + seconds)
}
