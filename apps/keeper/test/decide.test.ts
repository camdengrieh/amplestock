// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'
import {
  qualify,
  screen,
  screenCheckpoint,
  screenCompound,
  screenDeployBonded,
  screenRollout,
  screenTouch,
} from '../src/domain/decide.js'
import {DEFAULT_POLICY} from '../src/domain/policy.js'
import {GateState, PoolClass, type Simulation} from '../src/domain/types.js'
import {WAD} from '../src/domain/bounty.js'
import {constituent, HUB_POOL, NOW, pool, pot, snapshot, vault, SPOKE_POOL} from './helpers.js'

const POLICY = DEFAULT_POLICY

function ok(result: unknown, gas = 1_500_000n): Simulation {
  return {ok: true, result, gasEstimate: gas}
}

function reverted(name: string, args: readonly unknown[] = []): Simulation {
  return {ok: false, gasEstimate: 0n, revert: {name, args, raw: '0x'}}
}

describe('compound screening — the placement gauntlet as far as a view can see it', () => {
  it('passes on a healthy pool off cooldown', () => {
    const s = snapshot()
    expect(screenCompound(pool(), s, POLICY).eligible).toBe(true)
  })

  it('refuses when the vault-wide gate is DEGRADED', () => {
    const s = snapshot({globalGateState: GateState.DEGRADED})
    const result = screenCompound(pool(), s, POLICY)
    expect(result.eligible).toBe(false)
    expect(result.reason).toBe('gate-not-green')
  })

  it.each([
    [GateState.DEGRADED, 'gate-not-green'],
    [GateState.DIVERGED, 'gate-not-green'],
    [GateState.SCHEDULED_FREEZE, 'gate-not-green'],
    [GateState.WATCHDOG, 'gate-not-green'],
    [GateState.REF_DIVERGED, 'gate-ref-diverged'],
  ])('refuses a pool whose own gate is %s', (state, reason) => {
    const result = screenCompound(pool({gateState: state}), snapshot(), POLICY)
    expect(result.eligible).toBe(false)
    expect(result.reason).toBe(reason)
  })

  it('accepts REF_DIVERGED only when the operator has opted in, matching the vault’s own tolerance', () => {
    const permissive = {...POLICY, allowRefDiverged: true}
    const s = snapshot({globalGateState: GateState.REF_DIVERGED})
    expect(screenCompound(pool({gateState: GateState.REF_DIVERGED}), s, permissive).eligible).toBe(true)
  })

  it('refuses while the guardian’s protocol freeze is live', () => {
    const s = snapshot({protocolFreezeUntil: NOW + 3_600})
    expect(screenCompound(pool(), s, POLICY).reason).toBe('protocol-frozen')
  })

  it('refuses when the gate says placements are not allowed for that pool', () => {
    expect(screenCompound(pool({placementAllowed: false}), snapshot(), POLICY).reason).toBe('placement-refused')
  })

  it('refuses beyond PLACEMENT_DIVERGENCE_TICKS, and accepts exactly at it', () => {
    expect(screenCompound(pool({poolTick: 801, fairTick: 0}), snapshot(), POLICY).reason).toBe('diverged')
    expect(screenCompound(pool({poolTick: -801, fairTick: 0}), snapshot(), POLICY).reason).toBe('diverged')
    expect(screenCompound(pool({poolTick: 800, fairTick: 0}), snapshot(), POLICY).eligible).toBe(true)
  })

  it('waits out the 60-second cooldown and says until when', () => {
    const recent = pool({lastPlacementAt: NOW - 10})
    const result = screenCompound(recent, snapshot(), POLICY)
    expect(result.eligible).toBe(false)
    expect(result.reason).toBe('cooldown')
    expect(result.readyAt).toBe(NOW - 10 + 60)

    const elapsed = pool({lastPlacementAt: NOW - 61})
    expect(screenCompound(elapsed, snapshot(), POLICY).eligible).toBe(true)
  })

  it('stops at the live-cell budget, where the bountied paths merge and idle', () => {
    const full = snapshot({vault: vault({liveCells: 512 - POLICY.liveCellHeadroom + 1})})
    const result = screenCompound(pool(), full, POLICY)
    expect(result.eligible).toBe(false)
    expect(result.reason).toBe('cell-budget')
  })
})

describe('deployBonded screening', () => {
  it('fires once idle bonded collateral clears deployThresholdUsd18', () => {
    const c = constituent({idleCollateral: 200n * WAD, idleCollateralUsd18: 150n * WAD})
    expect(screenDeployBonded(c, pool(), snapshot(), POLICY).eligible).toBe(true)
  })

  it('refuses below the threshold, exactly as the vault no-ops there without paying', () => {
    const c = constituent({idleCollateral: 10n * WAD, idleCollateralUsd18: 99n * WAD})
    const result = screenDeployBonded(c, pool(), snapshot(), POLICY)
    expect(result.eligible).toBe(false)
    expect(result.reason).toBe('below-deploy-threshold')
  })

  it('refuses with no collateral at all', () => {
    expect(screenDeployBonded(constituent(), pool(), snapshot(), POLICY).reason).toBe('no-work')
  })

  it('refuses a retired or frozen constituent', () => {
    const retired = constituent({status: 2, idleCollateral: 200n * WAD, idleCollateralUsd18: 150n * WAD})
    expect(screenDeployBonded(retired, pool(), snapshot(), POLICY).reason).toBe('not-due')
  })
})

describe('rollout screening', () => {
  it('fires for an ACTIVE constituent with a weight while rollout is enabled', () => {
    expect(screenRollout(constituent(), pool(), snapshot(), POLICY).eligible).toBe(true)
  })

  it('does not fire when governance has zeroed rolloutBpsPerDay', () => {
    const s = snapshot({vault: vault({rolloutBpsPerDay: 0})})
    expect(screenRollout(constituent(), pool(), s, POLICY).reason).toBe('not-due')
  })

  it('does not fire for a constituent with no rollout weight', () => {
    expect(screenRollout(constituent({rolloutWeightBps: 0}), pool(), snapshot(), POLICY).reason).toBe('not-due')
  })

  it('waits when an entry pool is on cooldown, because rollout harvests from both of them', () => {
    // `VaultRolloutLib.rollout` calls `_harvestAsks` on the hub and the WETH leg before it places into the
    // spoke, and each of those is a `place` in its own right. A rollout screened only against the destination
    // would simulate, revert `PlacementCooldown` for a pool it was not asking about, and burn a round trip.
    const s = snapshot({
      pools: [
        pool({poolId: HUB_POOL, poolClass: PoolClass.ENTRY, constituentId: 0, lastPlacementAt: NOW - 10}),
        pool(),
      ],
    })
    const result = screenRollout(constituent(), pool(), s, POLICY)
    expect(result.eligible).toBe(false)
    expect(result.reason).toBe('cooldown')
    expect(result.readyAt).toBe(NOW - 10 + 60)
  })
})

describe('checkpoint and touch', () => {
  it('refreshes the checkpoint before AmpsBonds would start refusing to price', () => {
    const fresh = snapshot({vault: vault({checkpointTimestamp: NOW - 100})})
    expect(screenCheckpoint(fresh, POLICY).reason).toBe('checkpoint-fresh')

    const ageing = snapshot({vault: vault({checkpointTimestamp: NOW - 1_201})})
    expect(screenCheckpoint(ageing, POLICY).eligible).toBe(true)
  })

  it('refreshes with margin left before CHECKPOINT_MAX_AGE', () => {
    expect(POLICY.checkpointRefreshAtSeconds).toBeLessThan(POLICY.checkpointMaxAgeSeconds)
  })

  it('touch fires on its cadence', () => {
    expect(screenTouch(snapshot(), POLICY, NOW - 10).reason).toBe('not-due')
    expect(screenTouch(snapshot(), POLICY, NOW - 901).eligible).toBe(true)
  })

  it('touch fires *because* the watchdog tripped — it is the call that clears it', () => {
    const tripped = snapshot({globalGateState: GateState.WATCHDOG, watchdogTripped: true})
    const result = screenTouch(tripped, POLICY, NOW)
    expect(result.eligible).toBe(true)
    expect(result.detail).toBe('watchdog tripped')
    // ...and nothing else runs while the gate is down.
    expect(screenCompound(pool(), tripped, POLICY).eligible).toBe(false)
    expect(screenCheckpoint(tripped, POLICY).eligible).toBe(false)
  })

  it('touch still refuses under a guardian protocol freeze', () => {
    const frozen = snapshot({protocolFreezeUntil: NOW + 60, watchdogTripped: true})
    expect(screenTouch(frozen, POLICY, 0).reason).toBe('protocol-frozen')
  })
})

describe('the whole scan', () => {
  it('produces one candidate per pool and two per constituent, plus the two upkeep jobs', () => {
    const s = snapshot()
    const screenings = screen(s, POLICY, 0)
    expect(screenings.filter((x) => x.candidate.kind === 'compound')).toHaveLength(s.pools.length)
    expect(screenings.filter((x) => x.candidate.kind === 'rollout')).toHaveLength(s.constituents.length)
    expect(screenings.filter((x) => x.candidate.kind === 'deployBonded')).toHaveLength(s.constituents.length)
    expect(screenings.filter((x) => x.candidate.kind === 'touch')).toHaveLength(1)
    expect(screenings.filter((x) => x.candidate.kind === 'checkpoint')).toHaveLength(1)
  })

  it('a DEGRADED gate refuses every job', () => {
    const degraded = snapshot({globalGateState: GateState.DEGRADED})
    for (const screening of screen(degraded, POLICY, 0)) {
      expect(screening.eligible, screening.candidate.key).toBe(false)
    }
  })
})

describe('qualification — the simulation half', () => {
  const eligible = screenCompound(pool(), snapshot(), POLICY)

  it('refuses a reverting simulation and names the error', () => {
    const verdict = qualify(eligible, reverted('NavBleedExceeded'), snapshot(), POLICY)
    expect(verdict.send).toBe(false)
    expect(verdict.reason).toBe('simulation-reverted')
    expect(verdict.detail).toBe('NavBleedExceeded')
  })

  it('sends a compound whose fees clear chost', () => {
    // 10 AMPS of fees at $1 is $10 of work, ten times the $1 dust guard.
    const verdict = qualify(eligible, ok([10n * WAD, 0n]), snapshot(), POLICY, undefined, pool())
    expect(verdict.send).toBe(true)
    expect(verdict.workValueUsd18).toBe(10n * WAD)
    expect(verdict.bountyUsd18).toBe(7n * 10n ** 16n)
  })

  it('blocks a dust compound the on-chain guard would have paid for', () => {
    const verdict = qualify(eligible, ok([WAD / 1_000n, 0n]), snapshot(), POLICY, undefined, pool())
    expect(verdict.send).toBe(false)
    expect(verdict.reason).toBe('below-chost')
  })

  it('blocks the empty compound entirely — zero fees is zero work', () => {
    const verdict = qualify(eligible, ok([0n, 0n]), snapshot(), POLICY, undefined, pool())
    expect(verdict.send).toBe(false)
    expect(verdict.reason).toBe('below-chost')
  })

  it('refuses when the bounty does not cover gas', () => {
    // 3M gas at 100 gwei against $2,500 ETH is $750 of gas for a $0.07 bounty.
    const expensive = snapshot({baseFeeWei: 100n * 10n ** 9n})
    const verdict = qualify(eligible, ok([10n * WAD, 0n], 3_000_000n), expensive, POLICY, undefined, pool())
    expect(verdict.send).toBe(false)
    expect(verdict.reason).toBe('unprofitable')
  })

  it('the launch tip stops covering a compound one order of magnitude above the floor basefee', () => {
    // A finding worth pinning: §12 measures `compound` at 1.0-3.3M gas. At the Orbit floor (0.01 gwei) a 3.3M
    // compound costs $0.0825 against a $0.07 bounty, so the flat tip is already marginal at launch and is
    // under water at 0.1 gwei. The keeper is right to refuse; the fix is a governance one (raise `tip`, or
    // give the entry points a gas-allowance argument so `chip` can price the work).
    const floor = snapshot()
    expect(qualify(eligible, ok([10n * WAD, 1_500_000n], 1_500_000n), floor, POLICY, undefined, pool()).send).toBe(
      true,
    )
    expect(qualify(eligible, ok([10n * WAD, 0n], 3_300_000n), floor, POLICY, undefined, pool()).reason).toBe(
      'unprofitable',
    )
    const tenTimes = snapshot({baseFeeWei: 100_000_000n})
    expect(qualify(eligible, ok([10n * WAD, 0n], 1_500_000n), tenTimes, POLICY, undefined, pool()).reason).toBe(
      'unprofitable',
    )
  })

  it('refuses when the rolling daily ceiling is exhausted', () => {
    const spent = snapshot({pot: pot({spentLast24hUsd18: 25n * WAD, budgetLeftUsd18: 0n})})
    const verdict = qualify(eligible, ok([10n * WAD, 0n]), spent, POLICY, undefined, pool())
    expect(verdict.send).toBe(false)
    expect(verdict.reason).toBe('daily-ceiling')
  })

  it('refuses when the pot is depleted, unless the operator asked for unpaid work', () => {
    const empty = snapshot({pot: pot({balanceRaw: 0n})})
    expect(qualify(eligible, ok([10n * WAD, 0n]), empty, POLICY, undefined, pool()).reason).toBe('pot-depleted')
    expect(
      qualify(eligible, ok([10n * WAD, 0n]), empty, {...POLICY, runUnpaid: true}, undefined, pool()).send,
    ).toBe(true)
  })

  it('sends the unpaid upkeep jobs without any bounty arithmetic at all', () => {
    const empty = snapshot({pot: pot({balanceRaw: 0n})})
    const checkpoint = screenCheckpoint(snapshot({vault: vault({checkpointTimestamp: NOW - 2_000})}), POLICY)
    const verdict = qualify(checkpoint, ok(undefined, 400_000n), empty, POLICY)
    expect(verdict.send).toBe(true)
    expect(verdict.bountyUsd18).toBe(0n)
  })
})

describe('the synthetic spam campaign', () => {
  it('is blocked 100% by the keeper-side chost guard', () => {
    // 500 consecutive `compound()` attempts on a pool with nothing but dust accrued: every one of them would be
    // paid by `BountyPot` (the vault reports a flat $1 work value, which equals the $1 chost), and the keeper
    // refuses all 500.
    const s = snapshot()
    const eligibleScreening = screenCompound(pool(), s, POLICY)
    let sent = 0
    for (let i = 0; i < 500; i += 1) {
      const dust = BigInt(i) * (WAD / 100_000n) // up to 0.005 AMPS, i.e. half a cent of work
      const verdict = qualify(eligibleScreening, ok([dust, 0n]), s, POLICY, undefined, pool())
      if (verdict.send) sent += 1
      expect(verdict.reason).toBe('below-chost')
    }
    expect(sent).toBe(0)
  })

  it('and the on-chain pot would have paid for every one of them', () => {
    // The other half of the finding: the same 500 calls, priced the way the vault prices them.
    const {quotedPayableRaw} = pot()
    expect(quotedPayableRaw).toBeGreaterThan(0n)
  })

  it('is also bounded on-chain by the 60-second per-pool cooldown', () => {
    // A campaigner who ignores the keeper still cannot do better than one paid call per pool per minute.
    const justPlaced = pool({poolId: SPOKE_POOL, lastPlacementAt: NOW})
    expect(screenCompound(justPlaced, snapshot(), POLICY).reason).toBe('cooldown')
  })
})
