// SPDX-License-Identifier: MIT

/**
 * The arithmetic the genesis auction surface has to be able to reproduce exactly.
 *
 * All of it is `bigint`. A Q96 price is currency raw units per token raw unit shifted left 96 bits;
 * taking it through a JavaScript `number` to divide by 2^96 loses the low bits, and the low bits are
 * the ones that decide which tick a bid lands on. Every conversion below stays integral until the
 * last step, where a display string is produced at a stated precision.
 *
 * The auction is Uniswap's Continuous Clearing Auction (v2.1.0, MIT). Amplestocks sells its
 * entry-pool AMPS tranche through it: the currency raised becomes the entry pools' bid liquidity,
 * and the final clearing price becomes the launch reference price. Nothing here decides those
 * things — it reads and formats them.
 */

import {AUCTION_MPS, Q96} from './abi/cca'
import {UNAVAILABLE} from './format'

export {AUCTION_MPS, Q96}

/**
 * A Q96 price as whole currency per whole token, scaled to 18 decimals.
 *
 * ```
 * priceRaw    = priceQ96 / 2^96                     (currency raw per token raw)
 * priceWhole  = priceRaw * 10^tokenDec / 10^curDec  (currency whole per token whole)
 * ```
 *
 * Returned at 18 decimals so it composes with `formatUsd18` and with the vault's own X18 prices
 * without a second scale to get wrong.
 */
export function q96PriceToWholeX18(params: {
  priceQ96: bigint
  tokenDecimals: number
  currencyDecimals: number
}): bigint {
  const {priceQ96, tokenDecimals, currencyDecimals} = params
  // priceQ96 * 10^tokenDec * 10^18 / (2^96 * 10^curDec)
  const numerator = priceQ96 * 10n ** BigInt(tokenDecimals) * 10n ** 18n
  const denominator = Q96 * 10n ** BigInt(currencyDecimals)
  if (denominator === 0n) return 0n
  return numerator / denominator
}

/** The inverse: whole currency per whole token, at 18 decimals, back to the auction's Q96 grid. */
export function wholeX18ToQ96Price(params: {
  priceX18: bigint
  tokenDecimals: number
  currencyDecimals: number
}): bigint {
  const {priceX18, tokenDecimals, currencyDecimals} = params
  const numerator = priceX18 * Q96 * 10n ** BigInt(currencyDecimals)
  const denominator = 10n ** BigInt(tokenDecimals) * 10n ** 18n
  if (denominator === 0n) return 0n
  return numerator / denominator
}

/**
 * Snap a Q96 price onto the auction's tick grid.
 *
 * `TickStorage` requires a bid price at a boundary of `floorPrice + k * tickSpacing`, and reverts
 * with `TickPriceNotAtBoundary` otherwise. Rounding **up** is the only safe direction: rounding a
 * bidder's maximum down would submit a bid at a price they did not agree to pay up to, which is a
 * worse failure than a slightly higher maximum they may never be charged (everyone pays the final
 * clearing price, not their own maximum).
 */
export function snapToTick(params: {priceQ96: bigint; floorPriceQ96: bigint; tickSpacingQ96: bigint}): bigint {
  const {priceQ96, floorPriceQ96, tickSpacingQ96} = params
  if (tickSpacingQ96 <= 0n) return priceQ96
  if (priceQ96 <= floorPriceQ96) return floorPriceQ96
  const above = priceQ96 - floorPriceQ96
  const steps = above % tickSpacingQ96 === 0n ? above / tickSpacingQ96 : above / tickSpacingQ96 + 1n
  return floorPriceQ96 + steps * tickSpacingQ96
}

export const AuctionPhase = {
  /** No address configured for this auction on this chain. */
  Unknown: 'unknown',
  /** Before `startBlock`. */
  Upcoming: 'upcoming',
  /** Between `startBlock` and `endBlock`: bids accepted. */
  Live: 'live',
  /** After `endBlock`, before `claimBlock`: exits, no new bids. */
  Ended: 'ended',
  /** At or after `claimBlock`: tokens claimable. */
  Claimable: 'claimable',
} as const
export type AuctionPhaseName = (typeof AuctionPhase)[keyof typeof AuctionPhase]

export const PHASE_LABEL: Readonly<Record<AuctionPhaseName, string>> = {
  unknown: 'Not deployed',
  upcoming: 'Not started',
  live: 'Live',
  ended: 'Ended — exit your bid',
  claimable: 'Claimable',
}

export function auctionPhase(params: {
  blockNumber?: bigint
  startBlock?: bigint
  endBlock?: bigint
  claimBlock?: bigint
}): AuctionPhaseName {
  const {blockNumber, startBlock, endBlock, claimBlock} = params
  if (blockNumber === undefined || startBlock === undefined || endBlock === undefined) return AuctionPhase.Unknown
  if (blockNumber < startBlock) return AuctionPhase.Upcoming
  if (blockNumber < endBlock) return AuctionPhase.Live
  if (claimBlock !== undefined && blockNumber >= claimBlock) return AuctionPhase.Claimable
  return AuctionPhase.Ended
}

/**
 * Seconds between now and a target block.
 *
 * Signed: negative means the block is behind us. `blockTimeSeconds` comes from the chain metadata
 * and is `undefined` on a chain that does not publish one — in which case the caller shows the
 * block number and says the time is unavailable, rather than guessing at twelve seconds.
 */
export function secondsToBlock(params: {
  blockNumber?: bigint
  target?: bigint
  blockTimeSeconds?: number
}): number | undefined {
  const {blockNumber, target, blockTimeSeconds} = params
  if (blockNumber === undefined || target === undefined || blockTimeSeconds === undefined) return undefined
  return Number(target - blockNumber) * blockTimeSeconds
}

export const BidStatus = {
  /** `maxPrice` is above the clearing price: filling, and will fill in full if it stays there. */
  Filling: 'filling',
  /** `maxPrice` equals the clearing price: at the margin, may fill only partly. */
  Marginal: 'marginal',
  /** `maxPrice` is below the clearing price: not filling, refundable. */
  Outbid: 'outbid',
  /** Already exited — the currency has been settled. */
  Exited: 'exited',
} as const
export type BidStatusName = (typeof BidStatus)[keyof typeof BidStatus]

export const BID_STATUS_LABEL: Readonly<Record<BidStatusName, string>> = {
  filling: 'Filling',
  marginal: 'At the clearing price',
  outbid: 'Outbid',
  exited: 'Exited',
}

export const BID_STATUS_NOTE: Readonly<Record<BidStatusName, string>> = {
  filling:
    'Your maximum is above the clearing price, so this bid fills in full at the final clearing price — not at your maximum. The difference is refunded.',
  marginal:
    'Your maximum is exactly the clearing price, so this bid is at the margin and may fill only partly. Exit it with the partial-fill path once the auction ends.',
  outbid:
    'The clearing price has risen above your maximum, so this bid is not filling. Exit it to take the currency back in full.',
  exited: 'This bid has been exited: the fill and the refund have been settled.',
}

export function bidStatus(params: {
  maxPriceQ96: bigint
  clearingPriceQ96?: bigint
  exitedBlock: bigint
}): BidStatusName {
  if (params.exitedBlock > 0n) return BidStatus.Exited
  if (params.clearingPriceQ96 === undefined) return BidStatus.Marginal
  if (params.maxPriceQ96 > params.clearingPriceQ96) return BidStatus.Filling
  if (params.maxPriceQ96 === params.clearingPriceQ96) return BidStatus.Marginal
  return BidStatus.Outbid
}

/** A bid's currency amount, out of its stored `amountQ96`. */
export function bidAmountFromQ96(amountQ96: bigint): bigint {
  return amountQ96 / Q96
}

/**
 * The genesis premium as a *supply ratio*: `S0 / sold − 1`, in basis points.
 *
 * The auction sells half the supply, so a buyer's clearing price exceeds NAV per share by exactly
 * the ratio of total supply to tokens sold. This is the form the surface can compute **while the
 * auctions are still running**, from the two auctions' `totalCleared` alone and before there is a
 * `P0` or a NAV to divide.
 *
 * Once `AmpsGenesis.settle()` has run, `lib/genesis.ts`'s `launchPremiumBps` is the figure to show:
 * `P0 / NAV − 1`, from the numbers the contracts actually wrote. The two agree by construction —
 * `P0 = raised / sold` and `NAV = raised / S0` — and the settled form is preferred because it needs
 * no assumption about what cleared.
 */
export function genesisPremiumBps(params: {totalSupply: bigint; tokensSold: bigint}): number | undefined {
  if (params.tokensSold === 0n) return undefined
  return Number((params.totalSupply * 10_000n) / params.tokensSold) - 10_000
}

/** A Q96 price as a display string in whole currency per whole token. */
export function formatQ96Price(params: {
  priceQ96: bigint | undefined
  tokenDecimals: number
  currencyDecimals: number
  symbol: string
  fractionDigits?: number
}): string {
  if (params.priceQ96 === undefined) return UNAVAILABLE
  const x18 = q96PriceToWholeX18(params as {priceQ96: bigint; tokenDecimals: number; currencyDecimals: number})
  const n = Number(x18) / 1e18
  if (!Number.isFinite(n)) return UNAVAILABLE
  return `${n.toLocaleString('en-US', {
    minimumFractionDigits: params.fractionDigits ?? 6,
    maximumFractionDigits: params.fractionDigits ?? 6,
  })} ${params.symbol}`
}

/**
 * A price in one currency, converted to USD by a Chainlink answer for that currency.
 *
 * Returns `undefined` when there is no answer — the caller then renders the USD column as
 * unavailable rather than assuming a stablecoin is worth exactly one dollar.
 */
export function toUsd18(params: {
  priceX18: bigint | undefined
  answer: bigint | undefined
  answerDecimals: number | undefined
}): bigint | undefined {
  const {priceX18, answer, answerDecimals} = params
  if (priceX18 === undefined || answer === undefined || answerDecimals === undefined || answer <= 0n) return undefined
  return (priceX18 * answer) / 10n ** BigInt(answerDecimals)
}
