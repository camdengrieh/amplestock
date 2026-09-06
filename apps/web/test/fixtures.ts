// SPDX-License-Identifier: MIT

/**
 * Fixtures shared by the component tests.
 *
 * The addresses are deliberately obvious placeholders rather than the real reference addresses:
 * a test that accidentally starts asserting against `@amplestocks/config` values is a test that
 * will fail for the wrong reason when Phase 0 re-verifies them.
 */
import type {Address, Hex} from 'viem'

import type {PoolQuote} from '@/lib/quoter'
import {PoolClass} from '@/lib/protocol'

export const AMPS: Address = '0x000000000000000000000000000000000000A115'
export const WETH: Address = '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73'
export const USDG: Address = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168'
export const NVDA: Address = '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC'
export const AAPL: Address = '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9'
export const HOOK: Address = '0x00000000000000000000000000000000000038C0'
export const POOL_WETH: Hex = `0x${'11'.repeat(32)}`
export const POOL_USDG: Hex = `0x${'22'.repeat(32)}`

export function poolQuote(overrides: Partial<PoolQuote> = {}): PoolQuote {
  return {
    poolId: POOL_WETH,
    poolClass: PoolClass.ENTRY,
    counter: WETH,
    pMktX18: 1_150_000_000_000_000_000n,
    pRefX18: 1_120_000_000_000_000_000n,
    navPerShareX18: 1_000_000_000_000_000_000n,
    premiumX18: 120_000_000_000_000_000n,
    poolTick: 120,
    fairTick: 100,
    innerBandTicks: 200,
    outerRailTicks: 2_000,
    buyFeeBps: 30,
    sellFeeBps: 500,
    buyFeePips: 3_000,
    sellFeePips: 50_000,
    dynBps: 0,
    dynCapBps: 300,
    refuseSell: false,
    refuseBuy: false,
    bondQX18: 0n,
    bondDiscountBps: 0,
    bondCapacityLeft: 0n,
    bondOpen: false,
    gateState: 0,
    session: 0,
    feedStale: false,
    corporateFreeze: false,
    observationCoverage: 1_800,
    checkpointAge: 30,
    degraded: 0,
    ...overrides,
  }
}
