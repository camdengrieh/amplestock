// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'
import {
  budgetLeftUsd18,
  clampBaseFee,
  compoundWork,
  meetsChost,
  quoteBounty,
  splitAmpsFees,
  vaultGasAllowanceUsd18,
  vaultGasUsed,
  KEEPER_BASEFEE_CAP_WEI,
  KEEPER_BASEFEE_FLOOR_WEI,
  KEEPER_GAS_MAX,
  KEEPER_GAS_OVERHEAD,
  WAD,
} from '../src/domain/bounty.js'
import {pot} from './helpers.js'

describe('quoteBounty mirrors BountyPot._quote', () => {
  it('pays tip + chip at the launch parameters', () => {
    // $0.05 + 2% of $10 = $0.25, well inside the 3 x $1 gas cap and the $25 ceiling.
    const quote = quoteBounty(pot(), 10n * WAD, WAD)
    expect(quote.payableUsd18).toBe(250n * 10n ** 15n)
    expect(quote.reason).toBe('')
  })

  it('refuses below chost, and names it', () => {
    const quote = quoteBounty(pot(), WAD - 1n, WAD)
    expect(quote.payableRaw).toBe(0n)
    expect(quote.reason).toBe('chost')
  })

  it('binds on the 3x gas cap when the gas allowance is small', () => {
    // A $0.01 gas allowance caps the payout at $0.03 however much work was done.
    const quote = quoteBounty(pot(), 100n * WAD, WAD / 100n)
    expect(quote.payableUsd18).toBe(3n * WAD / 100n)
  })

  it('binds on the rolling daily ceiling', () => {
    const nearlySpent = pot({spentLast24hUsd18: 25n * WAD - WAD / 100n})
    const quote = quoteBounty(nearlySpent, 10n * WAD, WAD)
    expect(quote.payableUsd18).toBe(WAD / 100n)
    expect(budgetLeftUsd18(nearlySpent)).toBe(WAD / 100n)
  })

  it('reports an exhausted ceiling as dailyCeiling, not as depleted', () => {
    const quote = quoteBounty(pot({spentLast24hUsd18: 25n * WAD}), 10n * WAD, WAD)
    expect(quote.payableRaw).toBe(0n)
    expect(quote.reason).toBe('dailyCeiling')
  })

  it('degrades to unpaid when the pot is empty, and never reverts', () => {
    const quote = quoteBounty(pot({balanceRaw: 0n}), 10n * WAD, WAD)
    expect(quote.payableRaw).toBe(0n)
    expect(quote.reason).toBe('depleted')
  })

  it('truncates to the token’s raw units, USDG being 6 decimals', () => {
    // $0.05 + 2% of $1 = $0.07 exactly; 70,000 raw USDG units.
    const quote = quoteBounty(pot(), WAD, WAD)
    expect(quote.payableRaw).toBe(70_000n)
    expect(quote.payableUsd18).toBe(7n * 10n ** 16n)
  })
})

describe('the measured reporting the vault does now', () => {
  it('gas used is the delta plus the fixed overhead, under the hard ceiling', () => {
    expect(vaultGasUsed(1_500_000n)).toBe(1_500_000n + KEEPER_GAS_OVERHEAD)
    expect(vaultGasUsed(0n)).toBe(KEEPER_GAS_OVERHEAD)
    // No measurement of any shape may report more gas than the worst job can plausibly burn.
    expect(vaultGasUsed(KEEPER_GAS_MAX)).toBe(KEEPER_GAS_MAX)
    expect(vaultGasUsed(50_000_000n)).toBe(KEEPER_GAS_MAX)
  })

  it('the basefee is clamped at both ends: a free block is not free and a spike is not the pot’s to fund', () => {
    expect(clampBaseFee(0n)).toBe(KEEPER_BASEFEE_FLOOR_WEI)
    expect(clampBaseFee(1n)).toBe(KEEPER_BASEFEE_FLOOR_WEI)
    expect(clampBaseFee(50n * 10n ** 9n)).toBe(KEEPER_BASEFEE_CAP_WEI)
    expect(clampBaseFee(10n ** 8n)).toBe(10n ** 8n)
  })

  it('a 1.5M-gas compound at the Orbit floor and $2,500 ETH is ~$0.0395 of allowance and a ~$0.119 cap', () => {
    // This is the number the whole Phase 4 economics turns on, so it is pinned rather than described:
    // (1,500,000 + 80,000) x 0.01 gwei x $2,500 = $0.0395, and BountyPot's 3x cap is $0.1185.
    const allowance = vaultGasAllowanceUsd18(1_500_000n, KEEPER_BASEFEE_FLOOR_WEI, 2_500n * WAD)
    expect(allowance).toBe(39_500_000_000_000_000n)
    expect(allowance * 3n).toBe(118_500_000_000_000_000n)
  })

  it('the 3x gas cap now binds — it is the usual constraint at the floor basefee', () => {
    // $10 of work earns tip + chip = $0.05 + $0.20 = $0.25, but the cap on a 1.5M-gas job is $0.1185.
    const allowance = vaultGasAllowanceUsd18(1_500_000n, KEEPER_BASEFEE_FLOOR_WEI, 2_500n * WAD)
    const quote = quoteBounty(pot(), 10n * WAD, allowance)
    expect(quote.payableUsd18).toBe(118_500_000_000_000_000n)
    expect(quote.reason).toBe('')
  })

  it('an empty job reports a zero work value, so `chost` refuses it on chain', () => {
    // The v1 gap this replaces: the vault used to report a flat $1 whatever the job did, and `1e18 < 1e18` is
    // false, so an empty `compound()` was paid the full tip. A measured zero is unambiguously below the guard.
    const quote = quoteBounty(pot(), 0n, vaultGasAllowanceUsd18(1_500_000n, KEEPER_BASEFEE_FLOOR_WEI, 2_500n * WAD))
    expect(quote.payableRaw).toBe(0n)
    expect(quote.reason).toBe('chost')
  })

  it('an unpriceable ETH feed leaves the allowance at zero, which makes the job unpaid rather than free money', () => {
    expect(vaultGasAllowanceUsd18(1_500_000n, KEEPER_BASEFEE_FLOOR_WEI, 0n)).toBe(0n)
    const quote = quoteBounty(pot(), 100n * WAD, 0n)
    expect(quote.payableRaw).toBe(0n)
    expect(quote.reason).toBe('gasCap')
  })

  it('every bounty stays inside the daily ceiling and the 3x cap under a fuzzed gas series', () => {
    const launch = pot()
    let spent = 0n
    for (let i = 0; i < 1_000; i += 1) {
      const gas = 250_000n + BigInt(i) * 29_000n
      for (const baseFee of [0n, KEEPER_BASEFEE_FLOOR_WEI, 10n ** 8n, KEEPER_BASEFEE_CAP_WEI, 50n * 10n ** 9n]) {
        const allowance = vaultGasAllowanceUsd18(gas, baseFee, 2_500n * WAD)
        const quote = quoteBounty({...launch, spentLast24hUsd18: spent}, 10n * WAD, allowance)
        expect(quote.payableUsd18).toBeLessThanOrEqual(3n * allowance)
        expect(quote.payableUsd18).toBeLessThanOrEqual(budgetLeftUsd18({...launch, spentLast24hUsd18: spent}))
      }
      spent += quoteBounty(
        {...launch, spentLast24hUsd18: spent},
        10n * WAD,
        vaultGasAllowanceUsd18(gas, KEEPER_BASEFEE_FLOOR_WEI, 2_500n * WAD),
      ).payableUsd18
      expect(spent).toBeLessThanOrEqual(launch.dailyCeilingUsd18)
    }
  })
})

describe('splitAmpsFees mirrors section 3.6 step 5', () => {
  it('pays the creator its share of the volume and burns every wei of the rest', () => {
    // 1,000 AMPS of fees at genesis. The hook charged 500 bp of volume to collect them and the
    // creator's schedule is 100 bp of that same volume, so the slice is 100/500 = one fifth.
    const split = splitAmpsFees(1_000n * WAD, 100, 500)
    expect(split.creatorCut).toBe(200n * WAD)
    expect(split.burnCut).toBe(800n * WAD)
    // Nothing is streamed and nothing is re-laddered: the two add to the whole.
    expect(split.creatorCut + split.burnCut).toBe(1_000n * WAD)
  })

  it('burns the whole collection once the 30-day schedule has expired', () => {
    const split = splitAmpsFees(1_000n * WAD, 0, 500)
    expect(split.creatorCut).toBe(0n)
    expect(split.burnCut).toBe(1_000n * WAD)
  })

  it('follows a governed fee change, so the payout stays the same share of volume', () => {
    // Cut the fee to 300 bp and the same 100 bp schedule is a third of a smaller collection: 100 bp
    // of volume either way, which is the identity the divisor exists to preserve.
    const split = splitAmpsFees(600n * WAD, 100, 300)
    expect(split.creatorCut).toBe(200n * WAD)
    expect(split.burnCut).toBe(400n * WAD)
  })

  it('caps the creator slice at the whole of the AMPS-side fees', () => {
    // `creatorBps` 100 against a 100 bp fee is everything the AMPS side collected, and never more.
    const split = splitAmpsFees(1_000n * WAD, 100, 100)
    expect(split.creatorCut).toBe(1_000n * WAD)
    expect(split.burnCut).toBe(0n)
  })

  it('is exact on zero fees', () => {
    expect(splitAmpsFees(0n, 100, 500)).toEqual({creatorCut: 0n, burnCut: 0n})
  })
})

describe('compound work value', () => {
  it('values what `compound` burned, at the reference price', () => {
    // 100 AMPS of fees: 20 to the creator, 80 burned, plus 40 bought back and burned on top.
    const work = compoundWork(100n * WAD, 120n * WAD, 100, 500, 2n * WAD)
    expect(work.creatorCut).toBe(20n * WAD)
    expect(work.feeBurn).toBe(80n * WAD)
    expect(work.boughtBack).toBe(40n * WAD)
    // (80 + 40) AMPS x $2. The creator's 20 left the protocol and is not work the keeper created;
    // counting `ampsFees + boughtBack` instead would bill it as if it had.
    expect(work.workValueUsd18).toBe(240n * WAD)
  })

  it('reports no buyback when `burned` is only the fee slice, and never goes negative', () => {
    const work = compoundWork(100n * WAD, 80n * WAD, 100, 500, WAD)
    expect(work.boughtBack).toBe(0n)
    expect(work.workValueUsd18).toBe(80n * WAD)

    // A `creatorBps` read one block off the execution can leave `burned` under the modelled burn.
    expect(compoundWork(100n * WAD, 70n * WAD, 100, 500, WAD).boughtBack).toBe(0n)
    expect(compoundWork(0n, 0n, 100, 500, WAD).workValueUsd18).toBe(0n)
  })
})

describe('the keeper-side dust guard', () => {
  it('is the comparison the contract would make, against a measured value', () => {
    expect(meetsChost(WAD, WAD)).toBe(true)
    expect(meetsChost(WAD - 1n, WAD)).toBe(false)
    expect(meetsChost(0n, WAD)).toBe(false)
  })
})
