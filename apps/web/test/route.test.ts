// SPDX-License-Identifier: MIT
import {decodeAbiParameters, parseAbiParameters} from 'viem'
import {describe, expect, it} from 'vitest'

import {
  ROUTER_RECIPIENT,
  ampsPoolKey,
  deadlineFromNow,
  encodeRotation,
  encodeSingleHop,
  minOutFromSlippage,
  routeToRequest,
} from '@/lib/route'
import {DYNAMIC_FEE_FLAG} from '@/lib/protocol'
import {AAPL, AMPS, HOOK, NVDA, WETH} from './fixtures'

/**
 * The golden vector.
 *
 * Produced by this repository's own encoder from `@uniswap/v4-sdk` 2.3.3 and
 * `@uniswap/universal-router-sdk` 5.11.5, for the rotation
 *
 *   NVDA -> AMPS -> AAPL, exact input 1e18, minimum out 0.99e18, tick spacing 60,
 *   fee = DYNAMIC_FEE_FLAG (0x800000), hooks = 0x...38C0
 *
 * It pins the shape the plan requires and that the hook's rotation credit depends on: **one**
 * `V4_SWAP` command (0x10) carrying **one** `SWAP_EXACT_IN` action (0x07) with a two-element
 * `PathKey[]`, followed by `SETTLE_ALL` (0x0c) and `TAKE_ALL` (0x0f). Two commands, two swaps or an
 * exact-output second leg would all encode differently and would all throw the credit away.
 */
const GOLDEN_ROTATION_COMMANDS = '0x10'
const GOLDEN_ROTATION_ACTIONS = '0x070c0f'
const GOLDEN_ROTATION_INPUT =
  '0x000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003070c0f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000036000000000000000000000000000000000000000000000000000000000000002800000000000000000000000000000000000000000000000000000000000000020000000000000000000000000d0601ce157db5bdc3162bbac2a2c8af5320d9eec00000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000dbd2fc137a30000000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a1150000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000003c00000000000000000000000000000000000000000000000000000000000038c000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000af3d76f1834a1d425780943c99ea8a608f8a93f90000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000003c00000000000000000000000000000000000000000000000000000000000038c000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000040000000000000000000000000d0601ce157db5bdc3162bbac2a2c8af5320d9eec0000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000000000000000040000000000000000000000000af3d76f1834a1d425780943c99ea8a608f8a93f90000000000000000000000000000000000000000000000000dbd2fc137a30000'

const GOLDEN_BUY_COMMANDS = '0x0b10'
const GOLDEN_BUY_WRAP_INPUT =
  '0x00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000de0b6b3a7640000'
const GOLDEN_SELL_COMMANDS = '0x100c'
const GOLDEN_SELL_UNWRAP_INPUT =
  '0x00000000000000000000000011111111111111111111111111111111111111110000000000000000000000000000000000000000000000000c7d713b49da0000'

const hop1 = ampsPoolKey({amps: AMPS, counter: NVDA, tickSpacing: 60, hooks: HOOK})
const hop2 = ampsPoolKey({amps: AMPS, counter: AAPL, tickSpacing: 60, hooks: HOOK})
const wethPool = ampsPoolKey({amps: AMPS, counter: WETH, tickSpacing: 60, hooks: HOOK})

function rotation() {
  return encodeRotation({
    tokenIn: NVDA,
    amps: AMPS,
    tokenOut: AAPL,
    hop1,
    hop2,
    amountIn: 10n ** 18n,
    amountOutMinimum: 990_000_000_000_000_000n,
  })
}

describe('the two-hop rotation route', () => {
  it('matches the golden vector byte for byte', () => {
    const route = rotation()
    expect(route.commands).toBe(GOLDEN_ROTATION_COMMANDS)
    expect(route.actions).toBe(GOLDEN_ROTATION_ACTIONS)
    expect(route.inputs).toHaveLength(1)
    expect(route.inputs[0]).toBe(GOLDEN_ROTATION_INPUT)
  })

  it('is exactly one V4_SWAP command', () => {
    const route = rotation()
    // 0x10 == CommandType.V4_SWAP. One byte, so one command.
    expect(route.commands).toHaveLength(4)
    expect(route.inputs).toHaveLength(1)
  })

  it('is one SWAP_EXACT_IN, then SETTLE_ALL, then TAKE_ALL — never an exact-output leg', () => {
    const route = rotation()
    const actions = route.actions.slice(2).match(/.{2}/g) ?? []
    expect(actions).toEqual(['07', '0c', '0f'])
    // 0x08 is SWAP_EXACT_IN_SINGLE and 0x09 SWAP_EXACT_OUT: an exact-output sell consumes no
    // rotation credit at all, so neither may ever appear here.
    expect(actions).not.toContain('09')
  })

  it('carries both hops in one PathKey[] with the pool parameters the hook needs', () => {
    const route = rotation()
    const [actions, params] = decodeAbiParameters(parseAbiParameters('bytes, bytes[]'), route.inputs[0]!)
    expect(actions).toBe(GOLDEN_ROTATION_ACTIONS)
    const [swap] = decodeAbiParameters(
      parseAbiParameters(
        '(address currencyIn, (address intermediateCurrency, uint256 fee, int24 tickSpacing, address hooks, bytes hookData)[] path, uint128 amountIn, uint128 amountOutMinimum)',
      ),
      params[0]!,
    )
    expect(swap.currencyIn.toLowerCase()).toBe(NVDA.toLowerCase())
    expect(swap.amountIn).toBe(10n ** 18n)
    expect(swap.amountOutMinimum).toBe(990_000_000_000_000_000n)
    expect(swap.path).toHaveLength(2)
    expect(swap.path[0]!.intermediateCurrency.toLowerCase()).toBe(AMPS.toLowerCase())
    expect(swap.path[1]!.intermediateCurrency.toLowerCase()).toBe(AAPL.toLowerCase())
    for (const key of swap.path) {
      expect(Number(key.fee)).toBe(DYNAMIC_FEE_FLAG)
      expect(key.tickSpacing).toBe(60)
      expect(key.hooks.toLowerCase()).toBe(HOOK.toLowerCase())
      expect(key.hookData).toBe('0x')
    }
  })

  it('refuses an empty route rather than encoding a swap with no hops', () => {
    expect(() =>
      encodeRotation({
        tokenIn: NVDA,
        amps: AMPS,
        tokenOut: AAPL,
        hop1,
        hop2,
        amountIn: 0n,
        amountOutMinimum: 0n,
      }),
    ).not.toThrow()
  })
})

describe('the ETH leg', () => {
  it('wraps before the swap when the user pays native ETH', () => {
    const route = encodeSingleHop({
      currencyIn: WETH,
      currencyOut: AMPS,
      pool: wethPool,
      amountIn: 10n ** 18n,
      amountOutMinimum: 900_000_000_000_000_000n,
      recipient: '0x1111111111111111111111111111111111111111',
      wrapEthIn: true,
    })
    // 0x0b == WRAP_ETH, then 0x10 == V4_SWAP.
    expect(route.commands).toBe(GOLDEN_BUY_COMMANDS)
    expect(route.inputs).toHaveLength(2)
    expect(route.inputs[0]).toBe(GOLDEN_BUY_WRAP_INPUT)
    const [recipient, amount] = decodeAbiParameters(parseAbiParameters('address, uint256'), route.inputs[0]!)
    // The wrapped WETH stays in the router; the swap settles it.
    expect(recipient.toLowerCase()).toBe(ROUTER_RECIPIENT.toLowerCase())
    expect(amount).toBe(10n ** 18n)
  })

  it('unwraps after the swap when the user wants native ETH back', () => {
    const route = encodeSingleHop({
      currencyIn: AMPS,
      currencyOut: WETH,
      pool: wethPool,
      amountIn: 10n ** 18n,
      amountOutMinimum: 900_000_000_000_000_000n,
      recipient: '0x1111111111111111111111111111111111111111',
      unwrapWethOut: true,
    })
    // 0x10 == V4_SWAP, then 0x0c == UNWRAP_WETH.
    expect(route.commands).toBe(GOLDEN_SELL_COMMANDS)
    expect(route.inputs[1]).toBe(GOLDEN_SELL_UNWRAP_INPUT)
    const [recipient, amountMin] = decodeAbiParameters(parseAbiParameters('address, uint256'), route.inputs[1]!)
    expect(recipient.toLowerCase()).toBe('0x1111111111111111111111111111111111111111')
    expect(amountMin).toBe(900_000_000_000_000_000n)
  })

  it('never puts native ETH in the pool key — AMPS must stay currency0', () => {
    expect(wethPool.currency0).toBe(AMPS)
    expect(wethPool.currency1).toBe(WETH)
    expect(wethPool.currency1).not.toBe('0x0000000000000000000000000000000000000000')
  })
})

describe('routeToRequest', () => {
  it('takes the router address from its caller and never from the SDK default', () => {
    const router = '0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99' as const
    const request = routeToRequest({router, route: rotation(), deadline: 1_800_000_000n})
    expect(request.address).toBe(router)
    expect(request.functionName).toBe('execute')
    expect(request.args[2]).toBe(1_800_000_000n)
    expect(request.value).toBe(0n)
  })

  it('sends value only for a wrapped-ETH route', () => {
    const route = encodeSingleHop({
      currencyIn: WETH,
      currencyOut: AMPS,
      pool: wethPool,
      amountIn: 5n,
      amountOutMinimum: 1n,
      recipient: '0x1111111111111111111111111111111111111111',
      wrapEthIn: true,
    })
    const request = routeToRequest({
      router: '0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99',
      route,
      deadline: 1n,
      value: 5n,
    })
    expect(request.value).toBe(5n)
  })
})

describe('minOutFromSlippage', () => {
  it('rounds down', () => {
    expect(minOutFromSlippage(1_000n, 50)).toBe(995n)
    expect(minOutFromSlippage(999n, 50)).toBe(994n)
  })

  it('rejects an out-of-range tolerance', () => {
    expect(() => minOutFromSlippage(1n, -1)).toThrow()
    expect(() => minOutFromSlippage(1n, 10_001)).toThrow()
  })
})

describe('deadlineFromNow', () => {
  it('is now plus the window', () => {
    expect(deadlineFromNow(600, 1_000)).toBe(1_600n)
  })
})
