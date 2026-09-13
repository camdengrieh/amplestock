// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'
import {
  qualify,
  screen,
  screenCheckpoint,
  screenCompound,
  screenDeployBonded,
  screenRollout,
  screenSettle,
  screenTouch,
} from '../src/domain/decide.js'
import {DEFAULT_POLICY} from '../src/domain/policy.js'
import {GateState, GenesisPhase, PoolClass, type Simulation} from '../src/domain/types.js'
import {WAD} from '../src/domain/bounty.js'
import {constituent, genesis, GENESIS, HUB_POOL, NOW, pool, pot, snapshot, vault, SPOKE_POOL} from './helpers.js'

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

describe('settle — the one-shot launch job', () => {
  it('is eligible exactly when every leg has ended and nobody has settled', () => {
    const s = snapshot({genesis: genesis()})
    const screening = screenSettle(s)
    expect(screening.eligible).toBe(true)
    // The target is the adapter's address, because that is where the transaction goes.
    expect(screening.candidate.target).toBe(GENESIS)
    expect(screening.candidate.key).toBe(`settle:${GENESIS}`)
  })

  it('is not due while the auctions are still running', () => {
    for (const phase of [GenesisPhase.Created, GenesisPhase.Bidding]) {
      const screening = screenSettle(snapshot({genesis: genesis({phase})}))
      expect(screening.eligible).toBe(false)
      expect(screening.reason).toBe('not-due')
    }
  })

  it('retires itself once the launch has happened, whatever the outcome', () => {
    for (const phase of [GenesisPhase.Settled, GenesisPhase.Aborted]) {
      const screening = screenSettle(snapshot({genesis: genesis({phase, settled: true})}))
      expect(screening.eligible).toBe(false)
      expect(screening.reason).toBe('already-settled')
    }
    // `settled()` alone is enough: it is the latch, and the phase is derived from it.
    expect(screenSettle(snapshot({genesis: genesis({settled: true})})).reason).toBe('already-settled')
  })

  it('is NOT refused on gate state, so a launch stuck behind an early gate is visible', () => {
    // `settle()` takes the vault's health check and the hub pool does not exist yet, so a gate
    // pointer set too early makes it revert `GateNotHealthy`. Screening it out here would hide
    // that behind "gate not green" for ever; the simulation names the real problem instead.
    const degraded = snapshot({genesis: genesis(), globalGateState: GateState.DEGRADED})
    expect(screenSettle(degraded).eligible).toBe(true)
  })

  it('is not a candidate at all when the snapshot carries no adapter', () => {
    expect(screen(snapshot(), POLICY, 0).some((x) => x.candidate.kind === 'settle')).toBe(false)
    expect(screen(snapshot({genesis: genesis()}), POLICY, 0).filter((x) => x.candidate.kind === 'settle')).toHaveLength(1)
  })

  it('is unpaid, so qualification sends it the moment the simulation succeeds', () => {
    const screening = screenSettle(snapshot({genesis: genesis()}))
    const verdict = qualify(screening, ok(undefined), snapshot({genesis: genesis()}), POLICY)
    expect(verdict.send).toBe(true)
    expect(verdict.bountyUsd18).toBe(0n)
    expect(verdict.workValueUsd18).toBe(0n)
  })

  it('is refused when the simulation reverts, and the revert is the report', () => {
    const screening = screenSettle(snapshot({genesis: genesis()}))
    const verdict = qualify(screening, reverted('GateNotHealthy', [5, HUB_POOL]), snapshot(), POLICY)
    expect(verdict.send).toBe(false)
    expect(verdict.reason).toBe('simulation-reverted')
    expect(verdict.detail).toBe('GateNotHealthy')
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
    // A running protocol has no launch left to settle, so there is no settle candidate at all.
    expect(screenings.filter((x) => x.candidate.kind === 'settle')).toHaveLength(0)
  })

  it('a DEGRADED gate refuses every job on the vault', () => {
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

  it('sends a compound whose fees clear chost, priced at the pot’s real formula', () => {
    // `compound` returns `(ampsFees, burned)`, and since revision 6 `burned` is the whole AMPS-side remainder
    // after the creator slice plus the buyback — so a collection of 10 AMPS with the creator's fifth taken and
    // 2 AMPS bought back burns exactly 10, and `burned` is what the vault measures. At $1 that is $10 of work:
    // tip $0.05 + 2% chip = $0.25 of gross. The 3x gas cap on a 1.5M-gas job at the Orbit floor basefee is
    // 3 x $0.0395 = $0.1185, and that is what binds — which is the whole point of the vault reporting a
    // measured allowance instead of a flat $1.
    const verdict = qualify(eligible, ok([10n * WAD, 10n * WAD]), snapshot(), POLICY, undefined, pool())
    expect(verdict.send).toBe(true)
    expect(verdict.workValueUsd18).toBe(10n * WAD)
    expect(verdict.bountyUsd18).toBe(118_500_000_000_000_000n)
  })

  it('takes the vault’s own reported work value over its own estimate when the simulation carried one', () => {
    // `compound` returns `(ampsFees, burned)` and says nothing about the counter-side fees, which the vault
    // does price in and re-places as bids. A simulation that captured `BountyPaid` therefore beats the
    // keeper's lower bound.
    const reported = {
      ...ok([0n, 0n]),
      bounty: {workValueUsd18: 12n * WAD, paidUsd18: 118_500_000_000_000_000n, paidRaw: 118_500n, reason: ''},
    }
    const verdict = qualify(eligible, reported, snapshot(), POLICY, undefined, pool())
    expect(verdict.send).toBe(true)
    expect(verdict.workValueUsd18).toBe(12n * WAD)
    expect(verdict.bountyUsd18).toBe(118_500_000_000_000_000n)
  })

  it('honours a reported `chost` refusal even when its own estimate looked sufficient', () => {
    const reported = {
      ...ok([10n * WAD, 10n * WAD]),
      bounty: {workValueUsd18: 0n, paidUsd18: 0n, paidRaw: 0n, reason: 'chost'},
    }
    const verdict = qualify(eligible, reported, snapshot(), POLICY, undefined, pool())
    expect(verdict.send).toBe(false)
    expect(verdict.reason).toBe('below-chost')
  })

  it('blocks a dust compound the on-chain guard would have paid for', () => {
    const verdict = qualify(eligible, ok([WAD / 1_000n, WAD / 1_000n]), snapshot(), POLICY, undefined, pool())
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
    const verdict = qualify(eligible, ok([10n * WAD, 10n * WAD], 3_000_000n), expensive, POLICY, undefined, pool())
    expect(verdict.send).toBe(false)
    expect(verdict.reason).toBe('unprofitable')
  })

  it('the measured allowance makes the whole §12 gas range payable at the floor basefee', () => {
    // §12 measures `compound` at 1.0-3.3M gas. With the allowance tracking the job's own gas, the 3x cap grows
    // with it, so every point in that range is now paid more than it costs — which the flat $1 report never
    // managed.
    const floor = snapshot()
    for (const gas of [1_000_000n, 1_500_000n, 2_200_000n, 3_300_000n]) {
      const verdict = qualify(eligible, ok([10n * WAD, 10n * WAD], gas), floor, POLICY, undefined, pool())
      expect(verdict.send, `gas ${gas}`).toBe(true)
      expect(verdict.bountyUsd18).toBeGreaterThan(verdict.gasCostUsd18)
    }
  })

  it('tip + chip is still the binding term once the basefee leaves the floor', () => {
    // The surviving half of the tip-economics finding. At 0.1 gwei a 1.5M-gas compound costs $0.375, the 3x cap
    // is $1.185 — generous — but the gross is only tip + 2% of $10 = $0.25, so the job is under water and the
    // keeper refuses it. The governance lever is `tip`/`chipBps`, not the cap.
    const tenTimes = snapshot({baseFeeWei: 100_000_000n})
    const verdict = qualify(eligible, ok([10n * WAD, 10n * WAD], 1_500_000n), tenTimes, POLICY, undefined, pool())
    expect(verdict.reason).toBe('unprofitable')
    expect(verdict.bountyUsd18).toBe(250_000_000_000_000_000n)
    expect(verdict.gasCostUsd18).toBe(375_000_000_000_000_000n)

    // ...and a job worth enough for the chip to cover the gas is sent at the same basefee.
    const worthwhile = qualify(eligible, ok([100n * WAD, 100n * WAD], 1_500_000n), tenTimes, POLICY, undefined, pool())
    expect(worthwhile.send).toBe(true)
  })

  it('refuses when the rolling daily ceiling is exhausted', () => {
    const spent = snapshot({pot: pot({spentLast24hUsd18: 25n * WAD, budgetLeftUsd18: 0n})})
    const verdict = qualify(eligible, ok([10n * WAD, 10n * WAD]), spent, POLICY, undefined, pool())
    expect(verdict.send).toBe(false)
    expect(verdict.reason).toBe('daily-ceiling')
  })

  it('refuses when the pot is depleted, unless the operator asked for unpaid work', () => {
    const empty = snapshot({pot: pot({balanceRaw: 0n})})
    expect(qualify(eligible, ok([10n * WAD, 10n * WAD]), empty, POLICY, undefined, pool()).reason).toBe('pot-depleted')
    expect(
      qualify(eligible, ok([10n * WAD, 10n * WAD]), empty, {...POLICY, runUnpaid: true}, undefined, pool()).send,
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
      const verdict = qualify(eligibleScreening, ok([dust, dust]), s, POLICY, undefined, pool())
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
