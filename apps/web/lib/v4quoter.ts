// SPDX-License-Identifier: MIT

/**
 * `V4Quoter`, the curve half of a quote.
 *
 * `AmpsQuoter` is a fee-and-state view: it says what a swap costs in fees and whether it would be
 * refused, not how much comes out. The amount comes from Uniswap's own `V4Quoter`, whose address
 * is in `@amplestocks/config`. The two are reconciled in the UI — the fee the app displays is
 * `AmpsQuoter`'s, the output is `V4Quoter`'s, and a disagreement is shown rather than averaged.
 *
 * `V4Quoter`'s functions are `nonpayable` by design (they revert with the answer and unwind), so
 * they are read with `eth_call` through a simulation rather than a plain `view` read.
 */

export const v4QuoterAbi = [
  {
    type: 'function',
    name: 'quoteExactInput',
    stateMutability: 'nonpayable',
    inputs: [
      {
        name: 'params',
        type: 'tuple',
        components: [
          {name: 'exactCurrency', type: 'address'},
          {
            name: 'path',
            type: 'tuple[]',
            components: [
              {name: 'intermediateCurrency', type: 'address'},
              {name: 'fee', type: 'uint24'},
              {name: 'tickSpacing', type: 'int24'},
              {name: 'hooks', type: 'address'},
              {name: 'hookData', type: 'bytes'},
            ],
          },
          {name: 'exactAmount', type: 'uint128'},
        ],
      },
    ],
    outputs: [
      {name: 'amountOut', type: 'uint256'},
      {name: 'gasEstimate', type: 'uint256'},
    ],
  },
  {
    type: 'function',
    name: 'quoteExactInputSingle',
    stateMutability: 'nonpayable',
    inputs: [
      {
        name: 'params',
        type: 'tuple',
        components: [
          {
            name: 'poolKey',
            type: 'tuple',
            components: [
              {name: 'currency0', type: 'address'},
              {name: 'currency1', type: 'address'},
              {name: 'fee', type: 'uint24'},
              {name: 'tickSpacing', type: 'int24'},
              {name: 'hooks', type: 'address'},
            ],
          },
          {name: 'zeroForOne', type: 'bool'},
          {name: 'exactAmount', type: 'uint128'},
          {name: 'hookData', type: 'bytes'},
        ],
      },
    ],
    outputs: [
      {name: 'amountOut', type: 'uint256'},
      {name: 'gasEstimate', type: 'uint256'},
    ],
  },
] as const
