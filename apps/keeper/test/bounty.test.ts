// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'
import {
  budgetLeftUsd18,
  compoundWorkValueUsd18,
  gasCostUsd18,
  measuredGasAllowanceUsd18,
  meetsChost,
  quoteBounty,
  splitAmpsFees,
  VAULT_REPORTED_GAS_ALLOWANCE_USD18,
  VAULT_REPORTED_WORK_VALUE_USD18,
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

describe('the v1 gap: what the vault actually reports', () => {
  it('the flat $1 work value clears the $1 chost, so the on-chain dust guard never fires', () => {
    // This is the finding, asserted rather than described: `1e18 < 1e18` is false, so a `compound()` on a pool
    // with zero accrued fees is paid the full tip. On-chain, only the 60 s cooldown and the daily ceiling bound
    // a spam campaign; the guard that works is the keeper's own, over its measured work value.
    const launch = pot()
    const quote = quoteBounty(launch, VAULT_REPORTED_WORK_VALUE_USD18, VAULT_REPORTED_GAS_ALLOWANCE_USD18)
    expect(VAULT_REPORTED_WORK_VALUE_USD18).toBe(launch.chostUsd18)
    expect(quote.reason).toBe('')
    expect(quote.payableUsd18).toBeGreaterThan(0n)
  })

  it('the flat $1 gas allowance makes the 3x cap inert across a fuzzed gas series', () => {
    // The cap is `3 x $1 = $3`; the payout is `$0.05 + 2% x $1 = $0.07`. No gas price in a plausible range can
    // make the cap bind, which is why "the keeper reports measured gas" needs an entry-point argument that
    // `VaultPlacementLib` does not have.
    const launch = pot()
    for (let gas = 100_000n; gas <= 30_000_000n; gas += 373_337n) {
      for (const baseFee of [1n, 10n ** 6n, 10n ** 8n, 10n ** 9n, 50n * 10n ** 9n]) {
        const measured = measuredGasAllowanceUsd18(gas, baseFee, 2_500n * WAD)
        const quote = quoteBounty(launch, VAULT_REPORTED_WORK_VALUE_USD18, VAULT_REPORTED_GAS_ALLOWANCE_USD18)
        expect(quote.payableUsd18).toBe(7n * 10n ** 16n)
        // ...whereas quoting with the measured allowance does move, which is the point of measuring it.
        const honest = quoteBounty(launch, VAULT_REPORTED_WORK_VALUE_USD18, measured)
        expect(honest.payableUsd18).toBeLessThanOrEqual(quote.payableUsd18)
      }
    }
  })

  it('every bounty stays inside the daily ceiling and the 3x cap under a fuzzed gas series', () => {
    const launch = pot()
    let spent = 0n
    for (let i = 0; i < 1_000; i += 1) {
      const gas = 250_000n + BigInt(i) * 29_000n
      const gasCost = gasCostUsd18(gas, 100_000_000n, 2_500n * WAD)
      const quote = quoteBounty({...launch, spentLast24hUsd18: spent}, 10n * WAD, gasCost)
      expect(quote.payableUsd18).toBeLessThanOrEqual(3n * gasCost + 1n)
      spent += quote.payableUsd18
      expect(spent).toBeLessThanOrEqual(launch.dailyCeilingUsd18)
    }
  })
})

describe('splitAmpsFees mirrors section 3.6 step 5', () => {
  it('creator, then stakers, then burn, then re-ladder', () => {
    // 1,000 AMPS of sell fees at genesis: creator 100/500 = 20%, stakers 30% of the rest, burn 10% of that.
    const split = splitAmpsFees(1_000n * WAD, 100, 500, 3_000, 1_000)
    expect(split.creatorCut).toBe(200n * WAD)
    expect(split.stakerCut).toBe(240n * WAD)
    expect(split.burnCut).toBe(56n * WAD)
    expect(split.relaid).toBe(504n * WAD)
    expect(split.creatorCut + split.stakerCut + split.burnCut + split.relaid).toBe(1_000n * WAD)
  })

  it('pays the creator nothing once the 30-day schedule has expired', () => {
    const split = splitAmpsFees(1_000n * WAD, 0, 500, 3_000, 1_000)
    expect(split.creatorCut).toBe(0n)
    expect(split.stakerCut).toBe(300n * WAD)
  })

  it('caps the creator slice at the sell fee itself', () => {
    // creatorBps 100 against a 100 bp sell fee is the whole AMPS-side fee, and never more.
    const split = splitAmpsFees(1_000n * WAD, 100, 100, 3_000, 1_000)
    expect(split.creatorCut).toBe(1_000n * WAD)
    expect(split.relaid).toBe(0n)
  })

  it('is exact on zero fees', () => {
    expect(splitAmpsFees(0n, 100, 500, 3_000, 1_000)).toEqual({
      creatorCut: 0n,
      stakerCut: 0n,
      burnCut: 0n,
      relaid: 0n,
    })
  })
})

describe('compound work value', () => {
  it('counts the fees plus the bought-back inventory, at the reference price', () => {
    const ampsFees = 100n * WAD
    const split = splitAmpsFees(ampsFees, 100, 500, 3_000, 1_000)
    const boughtBack = 40n * WAD
    const value = compoundWorkValueUsd18(ampsFees, split.burnCut + boughtBack, split, 2n * WAD)
    expect(value).toBe(280n * WAD) // (100 + 40) AMPS x $2
  })

  it('never goes negative when `burned` is only the fee slice', () => {
    const ampsFees = 100n * WAD
    const split = splitAmpsFees(ampsFees, 100, 500, 3_000, 1_000)
    expect(compoundWorkValueUsd18(ampsFees, split.burnCut, split, WAD)).toBe(100n * WAD)
    expect(compoundWorkValueUsd18(0n, 0n, splitAmpsFees(0n, 100, 500, 3_000, 1_000), WAD)).toBe(0n)
  })
})

describe('the keeper-side dust guard', () => {
  it('is the comparison the contract would make, against a measured value', () => {
    expect(meetsChost(WAD, WAD)).toBe(true)
    expect(meetsChost(WAD - 1n, WAD)).toBe(false)
    expect(meetsChost(0n, WAD)).toBe(false)
  })
})
