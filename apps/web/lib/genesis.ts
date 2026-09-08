// SPDX-License-Identifier: MIT

/**
 * The arithmetic and the vocabulary of genesis, as `AmpsGenesis` and `AmpsVault` define them.
 *
 * Revision 7 replaced "the founders put $5,000 in and declared the price" with "half the supply is
 * sold at auction and the market's price becomes the reference". Two consequences run through
 * everything below and neither is a judgement:
 *
 * 1. **NAV per share at launch is `raised / S0`**, fully diluted (decision 14) — the 9,000 AMPS of
 *    protocol inventory counts in `T` and is backed by nothing until it sells.
 * 2. **The launch premium is `P0 / NAV − 1`**, which at a full clear at the $1.00 floor is exactly
 *    100%. It is disclosed, never smoothed, and it shrinks as the ask ladders fill at or above
 *    `P0`. It is never a discount and NAV/share is never the auction price.
 *
 * Everything here is `bigint` and integral until the last step. Nothing invents a number: a figure
 * whose source has not answered is `undefined`, and `undefined` renders as unavailable.
 */

/** `IAmpsGenesis.Phase`, ordinals preserved — the enum is ABI and is only ever appended to. */
export const GenesisPhase = [
  /** Constructed, or created and the first issuance block has not arrived. */
  'created',
  /** At least one auction is open for bids. */
  'bidding',
  /** Every auction's end block has passed and `settle()` has not run. */
  'ended',
  /** `settle()` ran and at least one leg graduated: the vault holds the proceeds and `P0`. */
  'settled',
  /** `settle()` ran and no leg graduated: the tranche went back, bidders refund themselves. */
  'aborted',
] as const

export type GenesisPhaseName = (typeof GenesisPhase)[number]

export const GENESIS_PHASE_LABEL: Readonly<Record<GenesisPhaseName, string>> = {
  created: 'Not started',
  bidding: 'Bidding',
  ended: 'Ended — awaiting settlement',
  settled: 'Settled',
  aborted: 'Did not graduate',
}

export const GENESIS_PHASE_NOTE: Readonly<Record<GenesisPhaseName, string>> = {
  created:
    'The auctions exist and hold their tranche, but the first issuance block has not arrived. Nothing can be bid yet and nothing can be settled.',
  bidding:
    'At least one auction is taking bids. Settlement is impossible until every leg’s end block has passed, and the clearing price can still move.',
  ended:
    'Every leg has closed and nobody has settled yet. settle() is permissionless and one-shot: it sweeps both legs, wraps the ETH, derives P0 and opens the vault in one transaction.',
  settled:
    'The launch is live. P0 is the vault’s reference price, the proceeds are its backing, and the 32 pools were opened at P0 rather than at a price chosen in advance.',
  aborted:
    'No leg reached its graduation threshold, so nothing was sold. Bidders refund in full through the auctions themselves — not through Amplestocks — and the whole tranche went back to the vault. The launch then proceeds through the founders’ fallback seed, which is a governed call with a 7-day delay.',
}

/** Whether `settle()` is callable right now: every end block passed, and not yet settled. */
export function canSettle(params: {phase?: GenesisPhaseName; settled?: boolean}): boolean {
  return params.phase === 'ended' && params.settled === false
}

/**
 * Why `settle()` is not offered, in the words of the state that refuses it.
 *
 * Returns `undefined` when it *is* offered. The panel never disables the button silently: a
 * permissionless call that a reader cannot make is a call they are owed a reason for.
 */
export function settleBlockedReason(params: {
  address?: string
  phase?: GenesisPhaseName
  settled?: boolean
  connected: boolean
}): string | undefined {
  if (params.address === undefined) return 'No genesis adapter is configured on this chain.'
  if (params.phase === undefined) return 'The genesis adapter did not answer, so its state is unknown.'
  if (params.settled === true) return 'Genesis has already been settled. It is one-shot and there is no reset.'
  if (params.phase === 'created') return 'The auctions have not opened yet.'
  if (params.phase === 'bidding') return 'Bidding is still open. Settlement waits for every leg’s end block.'
  if (!params.connected) return 'Connect a wallet to simulate this. settle() is permissionless — anyone may send it.'
  return undefined
}

/**
 * NAV per share at launch: `raised / S0`, fully diluted.
 *
 * The divisor is the **whole** supply, inventory included, because that is what decision 14 makes
 * `T` and what `AmpsVault._checkpoint` divides by. Dividing by the tokens actually sold would be a
 * different accounting with a different redemption floor, and it is not the one implemented.
 */
export function launchNavPerShareX18(params: {raisedUsd18?: bigint; totalSupply?: bigint}): bigint | undefined {
  const {raisedUsd18, totalSupply} = params
  if (raisedUsd18 === undefined || totalSupply === undefined || totalSupply === 0n) return undefined
  return (raisedUsd18 * 10n ** 18n) / totalSupply
}

/**
 * The launch premium, in basis points: `P0 / NAV − 1`.
 *
 * Positive at every launch the auction can produce, because the auction sells half the supply and
 * the whole of it divides the raise. Signed anyway — a fallback launch seeds `P0 = $1.00` against
 * NAV of exactly $1.00 and the honest answer there is zero, not "about zero".
 */
export function launchPremiumBps(params: {p0X18?: bigint; navPerShareX18?: bigint}): number | undefined {
  const {p0X18, navPerShareX18} = params
  if (p0X18 === undefined || navPerShareX18 === undefined || navPerShareX18 === 0n || p0X18 === 0n) return undefined
  return Number((p0X18 * 10_000n) / navPerShareX18) - 10_000
}

/**
 * A Q96 floor price as whole currency per whole AMPS, at 18 decimals.
 *
 * The adapter publishes the floors it computed rather than the ones a proposal asked for, which is
 * the point: a mis-scaled floor is a total loss for bidders and it is the one parameter a launch
 * cannot take on trust.
 */
export function floorQ96ToWholeX18(params: {floorQ96?: bigint; currencyDecimals?: number}): bigint | undefined {
  const {floorQ96, currencyDecimals} = params
  if (floorQ96 === undefined || currencyDecimals === undefined) return undefined
  return (floorQ96 * 10n ** 18n * 10n ** 18n) / ((1n << 96n) * 10n ** BigInt(currencyDecimals))
}

/**
 * The two legs' proceeds in 18-decimal USD, from the adapter's own numbers.
 *
 * `raisedUsd18()` is the authoritative figure and this is only its decomposition, for the panel
 * that wants to show where the money came from. USDG is taken at par because the adapter takes it
 * at par — `P0` is derived from the USDG leg's clearing price without an oracle, which is exactly
 * why the USDG leg wins whenever it graduated.
 */
export function raisedLegsUsd18(params: {
  raisedUsdg?: bigint
  usdgDecimals?: number
  raisedWeth?: bigint
  ethUsdX18?: bigint
}): {usdg?: bigint; weth?: bigint} {
  const {raisedUsdg, usdgDecimals, raisedWeth, ethUsdX18} = params
  return {
    ...(raisedUsdg !== undefined && usdgDecimals !== undefined
      ? {usdg: (raisedUsdg * 10n ** 18n) / 10n ** BigInt(usdgDecimals)}
      : {}),
    ...(raisedWeth !== undefined && ethUsdX18 !== undefined ? {weth: (raisedWeth * ethUsdX18) / 10n ** 18n} : {}),
  }
}
