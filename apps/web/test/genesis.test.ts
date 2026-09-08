// SPDX-License-Identifier: MIT
import {launchParameters} from '@amplestocks/config'
import {describe, expect, it} from 'vitest'

import {
  GENESIS_PHASE_LABEL,
  GENESIS_PHASE_NOTE,
  GenesisPhase,
  canSettle,
  floorQ96ToWholeX18,
  launchNavPerShareX18,
  launchPremiumBps,
  raisedLegsUsd18,
  settleBlockedReason,
} from '@/lib/genesis'

const WAD = 10n ** 18n
const Q96 = 1n << 96n

describe('the adapter’s phase enum', () => {
  it('keeps the ordinals `IAmpsGenesis.Phase` declares', () => {
    // The enum is ABI and is only ever appended to, so the ordinals are the contract.
    expect(GenesisPhase[0]).toBe('created')
    expect(GenesisPhase[1]).toBe('bidding')
    expect(GenesisPhase[2]).toBe('ended')
    expect(GenesisPhase[3]).toBe('settled')
    expect(GenesisPhase[4]).toBe('aborted')
    expect(GenesisPhase).toHaveLength(5)
  })

  it('gives every phase a label and a note', () => {
    for (const phase of GenesisPhase) {
      expect(GENESIS_PHASE_LABEL[phase]).toBeTruthy()
      expect(GENESIS_PHASE_NOTE[phase].length).toBeGreaterThan(40)
    }
  })

  it('says who refunds when nothing graduated, and that it is not Amplestocks', () => {
    expect(GENESIS_PHASE_NOTE.aborted).toMatch(/refund in full through the auctions themselves/)
    expect(GENESIS_PHASE_NOTE.aborted).toMatch(/not through Amplestocks/)
  })
})

describe('when settle() may be called', () => {
  it('is exactly “every leg ended, and not yet settled”', () => {
    expect(canSettle({phase: 'ended', settled: false})).toBe(true)
    expect(canSettle({phase: 'bidding', settled: false})).toBe(false)
    expect(canSettle({phase: 'created', settled: false})).toBe(false)
    expect(canSettle({phase: 'settled', settled: true})).toBe(false)
    expect(canSettle({phase: 'aborted', settled: true})).toBe(false)
    expect(canSettle({})).toBe(false)
  })

  it('names the state that refuses it rather than disabling the button silently', () => {
    expect(settleBlockedReason({connected: true})).toMatch(/No genesis adapter/)
    expect(settleBlockedReason({address: '0xabc', connected: true})).toMatch(/did not answer/)
    expect(settleBlockedReason({address: '0xabc', phase: 'created', settled: false, connected: true})).toMatch(
      /have not opened/,
    )
    expect(settleBlockedReason({address: '0xabc', phase: 'bidding', settled: false, connected: true})).toMatch(
      /Bidding is still open/,
    )
    expect(settleBlockedReason({address: '0xabc', phase: 'settled', settled: true, connected: true})).toMatch(
      /already been settled/,
    )
    // Permissionless, and the copy has to say so: a reader who cannot send it is owed the reason.
    expect(settleBlockedReason({address: '0xabc', phase: 'ended', settled: false, connected: false})).toMatch(
      /permissionless/,
    )
    expect(settleBlockedReason({address: '0xabc', phase: 'ended', settled: false, connected: true})).toBeUndefined()
  })
})

describe('launch arithmetic', () => {
  it('divides the raise by the WHOLE supply, inventory included', () => {
    // The launch parameters' own worked example: a full clear at the $1.00 floor raises $10,000
    // against S0 = 20,000, so NAV/share opens at $0.50.
    const s0 = launchParameters.supply.s0
    const raised = BigInt(launchParameters.auction.raisedAtFloorUsd) * WAD
    expect(launchNavPerShareX18({raisedUsd18: raised, totalSupply: s0})).toBe(WAD / 2n)
    expect(launchNavPerShareX18({raisedUsd18: raised, totalSupply: 0n})).toBeUndefined()
    expect(launchNavPerShareX18({totalSupply: s0})).toBeUndefined()
  })

  it('prices the premium as P₀ over NAV, less one', () => {
    // $1.00 against $0.50 is 100%, which is what `premiumAtFloorBps` records.
    expect(launchPremiumBps({p0X18: WAD, navPerShareX18: WAD / 2n})).toBe(launchParameters.auction.premiumAtFloorBps)
    // The fallback launch seeds P0 = $1.00 against NAV of exactly $1.00: zero, not "about zero".
    expect(launchPremiumBps({p0X18: WAD, navPerShareX18: WAD})).toBe(0)
    // A zero P0 is "not settled" or "nothing graduated", not a price of zero.
    expect(launchPremiumBps({p0X18: 0n, navPerShareX18: WAD})).toBeUndefined()
    expect(launchPremiumBps({p0X18: WAD, navPerShareX18: 0n})).toBeUndefined()
    expect(launchPremiumBps({p0X18: WAD})).toBeUndefined()
  })

  it('agrees with the supply-ratio form the surface uses before settlement', () => {
    // P0 = raised/sold and NAV = raised/S0, so P0/NAV is exactly S0/sold. Half the supply sold.
    const sold = launchParameters.auction.totalWei
    const s0 = launchParameters.supply.s0
    const supplyRatioBps = Number((s0 * 10_000n) / sold) - 10_000
    expect(launchPremiumBps({p0X18: WAD, navPerShareX18: WAD / 2n})).toBe(supplyRatioBps)
  })

  it('unscales a Q96 floor into whole currency per whole AMPS', () => {
    // $1.00 per AMPS in USDG (6 decimals): 1e6 * 2^96 / 1e18, straight out of the adapter.
    //
    // It comes back eight wei under a dollar, and that is the truth rather than a rounding bug in
    // this function: a Q96 price of USDG raw units per AMPS wei cannot represent $1.00 exactly, so
    // the floor the auction actually enforces is 0.999999999999999992. The contracts' own anvil
    // rehearsal settles at exactly that number. Rounding it up here would print a floor the
    // auction does not have.
    const floorUsdgQ96 = (10n ** 6n * Q96) / WAD
    expect(floorQ96ToWholeX18({floorQ96: floorUsdgQ96, currencyDecimals: 6})).toBe(999_999_999_999_999_992n)
    // The same $1.00 in ether at $2,500: 2^96 * 1e18 / 2500e18, nominally 0.0004 ETH per AMPS, and
    // one wei under it for the same reason.
    const floorEthQ96 = (Q96 * WAD) / (2_500n * WAD)
    expect(floorQ96ToWholeX18({floorQ96: floorEthQ96, currencyDecimals: 18})).toBe(4n * 10n ** 14n - 1n)
    expect(floorQ96ToWholeX18({currencyDecimals: 6})).toBeUndefined()
    expect(floorQ96ToWholeX18({floorQ96: floorUsdgQ96})).toBeUndefined()
  })

  it('decomposes the raise per leg, and takes USDG at par because the adapter does', () => {
    const legs = raisedLegsUsd18({
      raisedUsdg: 5_000_000_000n,
      usdgDecimals: 6,
      raisedWeth: 2n * WAD,
      ethUsdX18: 2_500n * WAD,
    })
    expect(legs.usdg).toBe(5_000n * WAD)
    expect(legs.weth).toBe(5_000n * WAD)
    // A leg with no ETH/USD price is absent, not zero: an unpriced leg is not an empty one.
    expect(raisedLegsUsd18({raisedWeth: 2n * WAD}).weth).toBeUndefined()
    expect(raisedLegsUsd18({raisedUsdg: 1n}).usdg).toBeUndefined()
  })
})
