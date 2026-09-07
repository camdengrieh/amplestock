// SPDX-License-Identifier: MIT

/**
 * Snapshot builders for the unit suites. One healthy baseline, and small overrides on top of it, so a test
 * reads as "this is the launch state except X" rather than as forty lines of literals.
 */

import {
  GateState,
  PoolClass,
  Session,
  type ChainSnapshot,
  type ConstituentSnapshot,
  type PoolSnapshot,
  type PotSnapshot,
  type VaultSnapshot,
} from '../src/domain/types.js'

export const WAD = 10n ** 18n
export const NOW = 1_788_962_400 // 2026-09-09 14:00:00 UTC, a Wednesday inside REGULAR

export const HUB_POOL = '0x1111111111111111111111111111111111111111111111111111111111111111' as const
export const SPOKE_POOL = '0x2222222222222222222222222222222222222222222222222222222222222222' as const

/** `BountyPot`'s launch parameters, from `Constants.sol`: $0.05 tip, 2% chip, $1 chost, 3x gas cap, $25/day. */
export function pot(overrides: Partial<PotSnapshot> = {}): PotSnapshot {
  return {
    address: '0x00000000000000000000000000000000000000b0',
    tipUsd18: 5n * 10n ** 16n,
    chipBps: 200,
    chostUsd18: WAD,
    gasCapMultiple: 3,
    dailyCeilingUsd18: 25n * WAD,
    spentLast24hUsd18: 0n,
    budgetLeftUsd18: 25n * WAD,
    balanceRaw: 1_000_000_000n, // 1,000 USDG at 6 decimals
    usdScale: 10n ** 12n,
    quotedPayableRaw: 70_000n, // $0.07
    quotedReason: '',
    ...overrides,
  }
}

export function vault(overrides: Partial<VaultSnapshot> = {}): VaultSnapshot {
  return {
    address: '0x00000000000000000000000000000000000000a0',
    navPerShareX18: WAD,
    pRefX18: WAD,
    pMktX18: WAD,
    checkpointTimestamp: NOW - 60,
    liveCells: 328,
    burnBps: 1_000,
    stakerBps: 3_000,
    creatorBps: 100,
    deployThresholdUsd18: 100n * WAD,
    rolloutBpsPerDay: 200,
    entryFloorBps: 3_000,
    ...overrides,
  }
}

export function pool(overrides: Partial<PoolSnapshot> = {}): PoolSnapshot {
  return {
    poolId: SPOKE_POOL,
    poolClass: PoolClass.SPOKE,
    constituentId: 1,
    counter: '0x00000000000000000000000000000000000000c1',
    gateState: GateState.GREEN,
    placementAllowed: true,
    anchorAtNav: false,
    poolTick: 0,
    fairTick: 0,
    ladderCells: 10,
    lastPlacementAt: NOW - 3_600,
    highWaterTick: 0,
    surgeBps: 0,
    lastSwapAt: NOW - 30,
    hookInitialized: true,
    session: Session.REGULAR,
    feedStale: false,
    corporateFreeze: false,
    pRefX18: WAD,
    navPerShareX18: WAD,
    sellFeeBps: 500,
    ...overrides,
  }
}

export function constituent(overrides: Partial<ConstituentSnapshot> = {}): ConstituentSnapshot {
  return {
    constituentId: 1,
    token: '0x00000000000000000000000000000000000000c1',
    poolId: SPOKE_POOL,
    decimals: 18,
    status: 1,
    idleCollateral: 0n,
    idleCollateralUsd18: 0n,
    rolloutWeightBps: 500,
    ...overrides,
  }
}

export function snapshot(overrides: Partial<ChainSnapshot> = {}): ChainSnapshot {
  return {
    now: NOW,
    blockNumber: 20_000_000n,
    globalGateState: GateState.GREEN,
    protocolFreezeUntil: 0,
    watchdogTripped: false,
    vault: vault(),
    pot: pot(),
    pools: [pool({poolId: HUB_POOL, poolClass: PoolClass.ENTRY, constituentId: 0}), pool()],
    constituents: [constituent()],
    // 0.01 gwei: the Arbitrum Orbit floor basefee, which is what Robinhood Chain sits at when it is not
    // congested. At 1.5M gas that is $0.0375 of gas against a $0.07 bounty — the launch tip covers a compound
    // only while the basefee stays at or near the floor. See `decide.test.ts`'s profitability cases.
    baseFeeWei: 10_000_000n,
    ethUsd18: 2_500n * WAD,
    ...overrides,
  }
}
