// SPDX-License-Identifier: MIT

/**
 * The arithmetic the indexer has to do for itself.
 *
 * Two families:
 *
 * - **Basis points and fixed point**, matching the contracts' rounding where the contracts round.
 *   Anything the indexer computes for disclosure (a premium, a change in bps) rounds toward zero,
 *   which is neither favourable nor unfavourable and is what a reader expects of a reported delta.
 * - **Uniswap v3/v4 tick and liquidity maths**, ported to `bigint` from `TickMath` and
 *   `LiquidityAmounts`. This is what turns a `ModifyLiquidity` log plus the pool's live
 *   `sqrtPriceX96` into "how much of this ask bucket is left and what has it raised" — a v4
 *   position converts in place as the price crosses it (§3.4), so the decomposition *is* the fill
 *   and the proceeds. The port is exact for the tick range Amplestocks uses and is checked against
 *   the on-chain values in `test/math.test.ts`.
 */

import {BPS, WAD} from './constants'

export const Q96 = 2n ** 96n
export const MIN_TICK = -887272
export const MAX_TICK = 887272

export const abs = (v: bigint): bigint => (v < 0n ? -v : v)

/** `x * y / d`, truncating. Mirrors `FullMath.mulDiv`. */
export const mulDiv = (x: bigint, y: bigint, d: bigint): bigint => (x * y) / d

/** `ceil(x * y / d)`. Mirrors `FullMath.mulDivRoundingUp`. */
export const mulDivUp = (x: bigint, y: bigint, d: bigint): bigint => {
  const n = x * y
  return n === 0n ? 0n : (n - 1n) / d + 1n
}

/**
 * The signed change from `from` to `to`, in basis points, truncated toward zero. Returns 0 when
 * `from` is zero, because "infinite bps" is not a number any dashboard wants.
 */
export function changeBps(from: bigint, to: bigint): number {
  if (from === 0n) return 0
  const delta = ((to - from) * BPS) / from
  return clampInt(delta)
}

/** The unsigned |a - b| / max(|a|,|b|) in bps: the divergence measure reconciliation uses. */
export function divergenceBps(a: bigint, b: bigint): number {
  const scale = a > b ? abs(a) : abs(b)
  if (scale === 0n) return 0
  return clampInt((abs(a - b) * BPS) / scale)
}

/** Narrow a bigint into the 32-bit range Postgres `integer` columns hold. Saturates. */
export function clampInt(value: bigint): number {
  if (value > 2_147_483_647n) return 2_147_483_647
  if (value < -2_147_483_648n) return -2_147_483_648
  return Number(value)
}

/** `pRef / nav - 1`, in 1e18 fixed point. Zero when `nav` is zero. */
export function premiumX18(navPerShareX18: bigint, pRefX18: bigint): bigint {
  if (navPerShareX18 === 0n) return 0n
  return (pRefX18 * WAD) / navPerShareX18 - WAD
}

/** The same premium in basis points, truncated toward zero. */
export function premiumBps(navPerShareX18: bigint, pRefX18: bigint): number {
  if (navPerShareX18 === 0n) return 0
  return clampInt((premiumX18(navPerShareX18, pRefX18) * BPS) / WAD)
}

/** The creator slice in force at `timestamp`: `CREATOR_FEE_BPS * max(0, 1 - elapsed/decay)`. */
export function creatorBpsAt(
  timestamp: bigint,
  genesisAt: bigint,
  feeBps: bigint,
  decaySeconds: bigint,
): number {
  if (genesisAt === 0n || timestamp <= genesisAt) return Number(feeBps)
  const elapsed = timestamp - genesisAt
  if (elapsed >= decaySeconds) return 0
  return clampInt((feeBps * (decaySeconds - elapsed)) / decaySeconds)
}

// -----------------------------------------------------------------------------------------------
// Tick maths
// -----------------------------------------------------------------------------------------------

const RATIOS: readonly [bigint, bigint][] = [
  [0x1n, 0xfffcb933bd6fad37aa2d162d1a594001n],
  [0x2n, 0xfff97272373d413259a46990580e213an],
  [0x4n, 0xfff2e50f5f656932ef12357cf3c7fdccn],
  [0x8n, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
  [0x10n, 0xffcb9843d60f6159c9db58835c926644n],
  [0x20n, 0xff973b41fa98c081472e6896dfb254c0n],
  [0x40n, 0xff2ea16466c96a3843ec78b326b52861n],
  [0x80n, 0xfe5dee046a99a2a811c461f1969c3053n],
  [0x100n, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
  [0x200n, 0xf987a7253ac413176f2b074cf7815e54n],
  [0x400n, 0xf3392b0822b70005940c7a398e4b70f3n],
  [0x800n, 0xe7159475a2c29b7443b29c7fa6e889d9n],
  [0x1000n, 0xd097f3bdfd2022b8845ad8f792aa5825n],
  [0x2000n, 0xa9f746462d870fdf8a65dc1f90e061e5n],
  [0x4000n, 0x70d869a156d2a1b890bb3df62baf32f7n],
  [0x8000n, 0x31be135f97d08fd981231505542fcfa6n],
  [0x10000n, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
  [0x20000n, 0x5d6af8dedb81196699c329225ee604n],
  [0x40000n, 0x2216e584f5fa1ea926041bedfe98n],
  [0x80000n, 0x48a170391f7dc42444e8fa2n],
]

/**
 * `TickMath.getSqrtRatioAtTick`, ported exactly. Reverts above `MAX_TICK` rather than clamping,
 * because a tick out of range in an indexed log means the log was not from a pool we understand.
 */
export function sqrtPriceX96AtTick(tick: number): bigint {
  const absTick = BigInt(Math.abs(tick))
  if (absTick > BigInt(MAX_TICK)) throw new Error(`[indexer] tick out of range: ${tick}`)

  let ratio = (absTick & 0x1n) !== 0n ? RATIOS[0]![1] : 0x100000000000000000000000000000000n
  for (const [bit, value] of RATIOS.slice(1)) {
    if ((absTick & bit) !== 0n) ratio = (ratio * value) >> 128n
  }
  if (tick > 0) ratio = (2n ** 256n - 1n) / ratio
  // Round up, exactly as the Solidity does with its `+ (ratio % (1 << 32) == 0 ? 0 : 1)`.
  return (ratio >> 32n) + (ratio % 2n ** 32n === 0n ? 0n : 1n)
}

/** `LiquidityAmounts.getAmount0ForLiquidity`. */
export function amount0For(sqrtA: bigint, sqrtB: bigint, liquidity: bigint): bigint {
  const [lo, hi] = sqrtA <= sqrtB ? [sqrtA, sqrtB] : [sqrtB, sqrtA]
  if (lo === 0n) return 0n
  return ((liquidity << 96n) * (hi - lo)) / hi / lo
}

/** `LiquidityAmounts.getAmount1ForLiquidity`. */
export function amount1For(sqrtA: bigint, sqrtB: bigint, liquidity: bigint): bigint {
  const [lo, hi] = sqrtA <= sqrtB ? [sqrtA, sqrtB] : [sqrtB, sqrtA]
  return (liquidity * (hi - lo)) / Q96
}

/**
 * The two token amounts a position of `liquidity` over `[tickLower, tickUpper)` holds at
 * `sqrtPriceX96`. Below the range it is all of currency0 (AMPS: an unfilled ask); above it, all of
 * currency1 (the counter: a fully raised ask); inside, the mix that says how far it has filled.
 */
export function amountsForLiquidity(
  sqrtPriceX96: bigint,
  tickLower: number,
  tickUpper: number,
  liquidity: bigint,
): {amount0: bigint; amount1: bigint} {
  if (liquidity <= 0n) return {amount0: 0n, amount1: 0n}
  const lower = sqrtPriceX96AtTick(tickLower)
  const upper = sqrtPriceX96AtTick(tickUpper)
  if (sqrtPriceX96 <= lower) return {amount0: amount0For(lower, upper, liquidity), amount1: 0n}
  if (sqrtPriceX96 >= upper) return {amount0: 0n, amount1: amount1For(lower, upper, liquidity)}
  return {
    amount0: amount0For(sqrtPriceX96, upper, liquidity),
    amount1: amount1For(lower, sqrtPriceX96, liquidity),
  }
}

/**
 * The price of currency0 in currency1, 18-decimal, from a sqrt price and the two decimals.
 * `PriceLib` does the same thing on-chain; this is the disclosure copy.
 */
export function priceX18FromSqrt(
  sqrtPriceX96: bigint,
  decimals0: number,
  decimals1: number,
): bigint {
  if (sqrtPriceX96 === 0n) return 0n
  const numerator = sqrtPriceX96 * sqrtPriceX96 * WAD * 10n ** BigInt(decimals0)
  return numerator / (Q96 * Q96 * 10n ** BigInt(decimals1))
}

/** Scale a raw token amount to 18 decimals. */
export function to18(amount: bigint, decimals: number): bigint {
  if (decimals === 18) return amount
  return decimals < 18 ? amount * 10n ** BigInt(18 - decimals) : amount / 10n ** BigInt(decimals - 18)
}

/** A Chainlink 8-decimal answer as 18-decimal USD. */
export const usd8ToUsd18 = (answerUsd8: bigint): bigint => answerUsd8 * 10n ** 10n
