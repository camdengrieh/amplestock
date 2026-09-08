// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'

import {
  AUCTION_MPS,
  AuctionPhase,
  BidStatus,
  Q96,
  auctionPhase,
  bidAmountFromQ96,
  bidStatus,
  formatQ96Price,
  genesisPremiumBps,
  launchNavPerShareX18,
  q96PriceToWholeX18,
  secondsToBlock,
  snapToTick,
  toUsd18,
  wholeX18ToQ96Price,
} from '@/lib/auction'
import {UNAVAILABLE} from '@/lib/format'

const WAD = 10n ** 18n

describe('Q96 prices', () => {
  it('converts a raw Q96 price into whole currency per whole token', () => {
    // Token and currency both 18 decimals, so "one for one" is exactly 2^96 with nothing to round.
    expect(q96PriceToWholeX18({priceQ96: Q96, tokenDecimals: 18, currencyDecimals: 18})).toBe(WAD)
    expect(q96PriceToWholeX18({priceQ96: 2n * Q96, tokenDecimals: 18, currencyDecimals: 18})).toBe(2n * WAD)
    expect(q96PriceToWholeX18({priceQ96: Q96 / 2n, tokenDecimals: 18, currencyDecimals: 18})).toBe(WAD / 2n)
  })

  it('rescales for a 6-decimal currency', () => {
    // One USDG (6 decimals) per one AMPS (18 decimals). 2^96 x 1e6 / 1e18 is not an integer, so the
    // Q96 grid cannot express this price exactly and the answer lands a few wei under one — which
    // is the point: the arithmetic is integral and the residue is visible rather than hidden.
    const priceQ96 = (Q96 * 10n ** 6n) / WAD
    const x18 = q96PriceToWholeX18({priceQ96, tokenDecimals: 18, currencyDecimals: 6})
    expect(x18).toBeLessThanOrEqual(WAD)
    expect(WAD - x18).toBeLessThan(1_000n)
  })

  it('round-trips through the inverse, and never rounds a price up', () => {
    // Both directions truncate, so a round trip can only lose. What must never happen is a price
    // coming back *larger* than it went in — that would show a bidder a maximum above the one the
    // contract holds. The loss itself is bounded by the Q96 grid at the currency's own resolution.
    for (const currencyDecimals of [6, 18]) {
      for (const whole of [WAD, WAD / 2n, 3n * WAD, WAD / 1000n, 1234n * WAD]) {
        const q96 = wholeX18ToQ96Price({priceX18: whole, tokenDecimals: 18, currencyDecimals})
        const back = q96PriceToWholeX18({priceQ96: q96, tokenDecimals: 18, currencyDecimals})
        expect(back, `${whole} at ${currencyDecimals} decimals`).toBeLessThanOrEqual(whole)
        // Within a hundredth of a basis point of where it started.
        expect((whole - back) * 1_000_000n).toBeLessThanOrEqual(whole)
      }
    }
  })

  it('is exact at a whole unit when the grid can express it', () => {
    const q96 = wholeX18ToQ96Price({priceX18: WAD, tokenDecimals: 18, currencyDecimals: 18})
    expect(q96).toBe(Q96)
    expect(q96PriceToWholeX18({priceQ96: q96, tokenDecimals: 18, currencyDecimals: 18})).toBe(WAD)
  })

  it('formats a price with its symbol, and a dash when there is none', () => {
    const priceQ96 = (Q96 * 10n ** 6n) / WAD
    expect(formatQ96Price({priceQ96, tokenDecimals: 18, currencyDecimals: 6, symbol: 'USDG'})).toBe('1.000000 USDG')
    expect(formatQ96Price({priceQ96: Q96, tokenDecimals: 18, currencyDecimals: 18, symbol: 'ETH'})).toBe('1.000000 ETH')
    expect(formatQ96Price({priceQ96: undefined, tokenDecimals: 18, currencyDecimals: 6, symbol: 'USDG'})).toBe(
      UNAVAILABLE,
    )
  })
})

describe('snapping a bid onto the tick grid', () => {
  const floorPriceQ96 = 1_000n
  const tickSpacingQ96 = 100n

  it('leaves a price that is already on a boundary alone', () => {
    expect(snapToTick({priceQ96: 1_300n, floorPriceQ96, tickSpacingQ96})).toBe(1_300n)
  })

  it('rounds up, never down — a maximum is a ceiling the bidder chose', () => {
    expect(snapToTick({priceQ96: 1_301n, floorPriceQ96, tickSpacingQ96})).toBe(1_400n)
    expect(snapToTick({priceQ96: 1_399n, floorPriceQ96, tickSpacingQ96})).toBe(1_400n)
  })

  it('never goes below the floor', () => {
    expect(snapToTick({priceQ96: 1n, floorPriceQ96, tickSpacingQ96})).toBe(floorPriceQ96)
    expect(snapToTick({priceQ96: floorPriceQ96, floorPriceQ96, tickSpacingQ96})).toBe(floorPriceQ96)
  })

  it('is a no-op rather than a division by zero when the spacing could not be read', () => {
    expect(snapToTick({priceQ96: 1_234n, floorPriceQ96, tickSpacingQ96: 0n})).toBe(1_234n)
  })
})

describe('the auction phase', () => {
  const blocks = {startBlock: 100n, endBlock: 200n, claimBlock: 250n}

  it('walks upcoming, live, ended, claimable', () => {
    expect(auctionPhase({blockNumber: 50n, ...blocks})).toBe(AuctionPhase.Upcoming)
    expect(auctionPhase({blockNumber: 100n, ...blocks})).toBe(AuctionPhase.Live)
    expect(auctionPhase({blockNumber: 199n, ...blocks})).toBe(AuctionPhase.Live)
    expect(auctionPhase({blockNumber: 200n, ...blocks})).toBe(AuctionPhase.Ended)
    expect(auctionPhase({blockNumber: 249n, ...blocks})).toBe(AuctionPhase.Ended)
    expect(auctionPhase({blockNumber: 250n, ...blocks})).toBe(AuctionPhase.Claimable)
  })

  it('is unknown rather than guessed when a block could not be read', () => {
    expect(auctionPhase({...blocks})).toBe(AuctionPhase.Unknown)
    expect(auctionPhase({blockNumber: 150n, endBlock: 200n})).toBe(AuctionPhase.Unknown)
  })
})

describe('turning blocks into time', () => {
  it('uses the chain block time, signed either way', () => {
    expect(secondsToBlock({blockNumber: 100n, target: 200n, blockTimeSeconds: 0.1})).toBeCloseTo(10)
    expect(secondsToBlock({blockNumber: 200n, target: 100n, blockTimeSeconds: 0.1})).toBeCloseTo(-10)
  })

  it('refuses to guess when the chain publishes no block time', () => {
    expect(secondsToBlock({blockNumber: 100n, target: 200n})).toBeUndefined()
  })
})

describe('a bid’s status against the clearing price', () => {
  it('fills above, is marginal at, and is outbid below', () => {
    expect(bidStatus({maxPriceQ96: 200n, clearingPriceQ96: 100n, exitedBlock: 0n})).toBe(BidStatus.Filling)
    expect(bidStatus({maxPriceQ96: 100n, clearingPriceQ96: 100n, exitedBlock: 0n})).toBe(BidStatus.Marginal)
    expect(bidStatus({maxPriceQ96: 50n, clearingPriceQ96: 100n, exitedBlock: 0n})).toBe(BidStatus.Outbid)
  })

  it('is exited once it has been, whatever the price says', () => {
    expect(bidStatus({maxPriceQ96: 200n, clearingPriceQ96: 100n, exitedBlock: 7n})).toBe(BidStatus.Exited)
  })

  it('never claims a bid is outbid when the clearing price could not be read', () => {
    expect(bidStatus({maxPriceQ96: 50n, exitedBlock: 0n})).toBe(BidStatus.Marginal)
  })

  it('unscales a stored amount out of Q96', () => {
    expect(bidAmountFromQ96(5_000n * Q96)).toBe(5_000n)
  })
})

describe('settlement arithmetic', () => {
  it('divides the raise by the whole supply to get NAV per share', () => {
    expect(launchNavPerShareX18({raisedUsd18: 5_000n * WAD, tokensSold: 5_000n * WAD})).toBe(WAD)
    expect(launchNavPerShareX18({raisedUsd18: 5_000n * WAD, tokensSold: 0n})).toBeUndefined()
  })

  it('prices the genesis premium as supply over sold, less one', () => {
    // 5,000 AMPS in total, 3,325 sold through the auction: the entry-pool tranche.
    expect(genesisPremiumBps({totalSupply: 5_000n * WAD, tokensSold: 3_325n * WAD})).toBe(5037)
    expect(genesisPremiumBps({totalSupply: 5_000n * WAD, tokensSold: 5_000n * WAD})).toBe(0)
    expect(genesisPremiumBps({totalSupply: 5_000n * WAD, tokensSold: 0n})).toBeUndefined()
  })

  it('converts to USD through a feed answer, and refuses to without one', () => {
    // 1.0001 USD per USDG, 8-decimal Chainlink answer.
    expect(toUsd18({priceX18: WAD, answer: 100_010_000n, answerDecimals: 8})).toBe(1_000_100_000_000_000_000n)
    expect(toUsd18({priceX18: WAD, answer: undefined, answerDecimals: 8})).toBeUndefined()
    expect(toUsd18({priceX18: WAD, answer: 0n, answerDecimals: 8})).toBeUndefined()
    expect(toUsd18({priceX18: undefined, answer: 100_000_000n, answerDecimals: 8})).toBeUndefined()
  })
})

describe('the auction’s own units', () => {
  it('counts supply in ten-millionths', () => {
    expect(AUCTION_MPS).toBe(10_000_000n)
  })
})
