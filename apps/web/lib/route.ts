// SPDX-License-Identifier: MIT

/**
 * Universal Router calldata for every swap this dApp signs.
 *
 * **The rule that shapes all of it** (plan, "Routing and distribution"): a rotation is *one*
 * `SWAP_EXACT_IN` carrying a `PathKey[]` inside *one* `V4_SWAP` command. Not two swaps, not two
 * commands — one, because the hook's rotation credit lives in EIP-1153 transient storage and is
 * only worth anything to a sell that happens in the same transaction as the buy that created it,
 * and because an exact-**output** sell consumes no credit at all. So: exact input, always, and one
 * command.
 *
 * The router address is `@amplestocks/config`'s `universalRouter` for the connected chain — the
 * one that is actually live on 4663, which is *not* the address the SDK's own `UNIVERSAL_ROUTER_ADDRESS`
 * would hand back. It is passed in by the caller and never hardcoded here.
 *
 * The ETH leg wraps: `AMPS/WETH` is the pool, native ETH would be `address(0)` = `currency0` and
 * would break the AMPS-is-currency0 invariant, so `WRAP_ETH` precedes the swap and `UNWRAP_WETH`
 * follows it.
 */

import {Actions, V4Planner} from '@uniswap/v4-sdk'
import {CommandType, ROUTER_AS_RECIPIENT, RoutePlanner} from '@uniswap/universal-router-sdk'
import type {Address, Hex} from 'viem'

import {DYNAMIC_FEE_FLAG} from './protocol'

/** The subset of a v4 `PoolKey` a route needs. All 32 Amplestocks pools have `currency0 == AMPS`. */
export interface PoolKeyLike {
  currency0: Address
  currency1: Address
  /** `DYNAMIC_FEE_FLAG` in every Amplestocks pool; the hook overrides per swap. */
  fee: number
  tickSpacing: number
  hooks: Address
  hookData?: Hex
}

export interface EncodedRoute {
  /** The `commands` byte string, one byte per command. */
  commands: Hex
  /** One input per command, in order. */
  inputs: readonly Hex[]
  /** The `V4_SWAP` action byte string, for assertions and for display. */
  actions: Hex
}

/** `address(2)` — "leave it in the router, a later command will move it". */
export const ROUTER_RECIPIENT = ROUTER_AS_RECIPIENT as Address

/** The v4 pool key for an Amplestocks pool, AMPS first. */
export function ampsPoolKey(params: {amps: Address; counter: Address; tickSpacing: number; hooks: Address}): PoolKeyLike {
  return {
    currency0: params.amps,
    currency1: params.counter,
    fee: DYNAMIC_FEE_FLAG,
    tickSpacing: params.tickSpacing,
    hooks: params.hooks,
  }
}

function pathKey(pool: PoolKeyLike, intermediateCurrency: Address) {
  return {
    intermediateCurrency,
    fee: pool.fee,
    tickSpacing: pool.tickSpacing,
    hooks: pool.hooks,
    hookData: pool.hookData ?? '0x',
  }
}

/**
 * One hop, exact input: `SWAP_EXACT_IN` with a single-element `PathKey[]`.
 *
 * Deliberately not `SWAP_EXACT_IN_SINGLE`. The single-pool action takes a `PoolKey` plus a
 * `zeroForOne` flag; the path form takes the currency in and the pool to route through, and it is
 * the same shape the two-hop route uses. One encoder, one set of golden vectors, one thing to be
 * wrong.
 */
export function planSwapExactIn(params: {
  currencyIn: Address
  hops: readonly {pool: PoolKeyLike; currencyOut: Address}[]
  amountIn: bigint
  amountOutMinimum: bigint
}): {planner: V4Planner; currencyOut: Address} {
  if (params.hops.length === 0) throw new Error('planSwapExactIn: a route needs at least one hop')
  const last = params.hops[params.hops.length - 1]
  if (last === undefined) throw new Error('planSwapExactIn: unreachable empty hop list')
  const currencyOut = last.currencyOut

  const planner = new V4Planner()
  planner.addAction(Actions.SWAP_EXACT_IN, [
    {
      currencyIn: params.currencyIn,
      path: params.hops.map((hop) => pathKey(hop.pool, hop.currencyOut)),
      amountIn: params.amountIn.toString(),
      amountOutMinimum: params.amountOutMinimum.toString(),
    },
  ])
  planner.addAction(Actions.SETTLE_ALL, [params.currencyIn, params.amountIn.toString()])
  planner.addAction(Actions.TAKE_ALL, [currencyOut, params.amountOutMinimum.toString()])
  return {planner, currencyOut}
}

/**
 * stock -> AMPS -> stock, or any two-hop path through an Amplestocks pool.
 *
 * One `V4_SWAP`, one `SWAP_EXACT_IN`, two `PathKey`s. Hop 1 is a buy, and the AMPS it yields is
 * exactly the credit hop 2 consumes; splitting this into two commands, two transactions or an
 * exact-output second leg throws the credit away and pays the full sell fee.
 */
export function encodeRotation(params: {
  tokenIn: Address
  amps: Address
  tokenOut: Address
  hop1: PoolKeyLike
  hop2: PoolKeyLike
  amountIn: bigint
  amountOutMinimum: bigint
}): EncodedRoute {
  const {planner} = planSwapExactIn({
    currencyIn: params.tokenIn,
    hops: [
      {pool: params.hop1, currencyOut: params.amps},
      {pool: params.hop2, currencyOut: params.tokenOut},
    ],
    amountIn: params.amountIn,
    amountOutMinimum: params.amountOutMinimum,
  })
  const route = new RoutePlanner()
  route.addCommand(CommandType.V4_SWAP, [planner.finalize()])
  return {commands: route.commands as Hex, inputs: route.inputs as Hex[], actions: planner.actions as Hex}
}

/**
 * One hop, exact input, with the ETH wrap/unwrap around the WETH leg where the user asked for
 * native ETH.
 *
 * `wrapEthIn`: the user pays ETH. `WRAP_ETH` moves `amountIn` into WETH held by the router, then
 * the swap settles WETH.
 * `unwrapWethOut`: the user wants ETH. The swap takes WETH to the router, then `UNWRAP_WETH`
 * pays the recipient at least `amountOutMinimum`.
 */
export function encodeSingleHop(params: {
  currencyIn: Address
  currencyOut: Address
  pool: PoolKeyLike
  amountIn: bigint
  amountOutMinimum: bigint
  recipient: Address
  wrapEthIn?: boolean
  unwrapWethOut?: boolean
}): EncodedRoute {
  const route = new RoutePlanner()
  if (params.wrapEthIn) {
    route.addCommand(CommandType.WRAP_ETH, [ROUTER_RECIPIENT, params.amountIn.toString()])
  }
  const {planner} = planSwapExactIn({
    currencyIn: params.currencyIn,
    hops: [{pool: params.pool, currencyOut: params.currencyOut}],
    amountIn: params.amountIn,
    amountOutMinimum: params.amountOutMinimum,
  })
  route.addCommand(CommandType.V4_SWAP, [planner.finalize()])
  if (params.unwrapWethOut) {
    route.addCommand(CommandType.UNWRAP_WETH, [params.recipient, params.amountOutMinimum.toString()])
  }
  return {commands: route.commands as Hex, inputs: route.inputs as Hex[], actions: planner.actions as Hex}
}

/** `UniversalRouter.execute(bytes commands, bytes[] inputs, uint256 deadline)`. */
export const universalRouterExecuteAbi = [
  {
    type: 'function',
    name: 'execute',
    stateMutability: 'payable',
    inputs: [
      {name: 'commands', type: 'bytes'},
      {name: 'inputs', type: 'bytes[]'},
      {name: 'deadline', type: 'uint256'},
    ],
    outputs: [],
  },
] as const

/** Everything `writeContract` needs for a route, with the router address supplied by config. */
export function routeToRequest(params: {
  router: Address
  route: EncodedRoute
  deadline: bigint
  /** Native ETH sent with the call — non-zero only when the route starts with `WRAP_ETH`. */
  value?: bigint
}) {
  return {
    address: params.router,
    abi: universalRouterExecuteAbi,
    functionName: 'execute' as const,
    args: [params.route.commands, params.route.inputs as Hex[], params.deadline] as const,
    value: params.value ?? 0n,
  }
}

/** A deadline `seconds` from now, as the router expects it. */
export function deadlineFromNow(seconds = 600, now = Math.floor(Date.now() / 1000)): bigint {
  return BigInt(now + seconds)
}

/**
 * `amountOutMinimum` from a quote and a slippage tolerance in bps, rounded **down**.
 *
 * Note what this is *not* used for: a bond's `minAmpsOut` is never a slippage-reduced number.
 * See `lib/bonds.ts`.
 */
export function minOutFromSlippage(quotedOut: bigint, slippageBps: number): bigint {
  if (slippageBps < 0 || slippageBps > 10_000) throw new Error('minOutFromSlippage: slippageBps out of range')
  return (quotedOut * BigInt(10_000 - slippageBps)) / 10_000n
}
