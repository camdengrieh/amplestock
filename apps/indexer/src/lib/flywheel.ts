// SPDX-License-Identifier: MIT

/**
 * The flywheel arithmetic: the numbers the dashboard puts next to each other.
 *
 * **Realised LVR, per swap.** Loss-versus-rebalancing for a *static* position is measurable
 * directly from a swap: mark the trade against the price the pool is left at. Take a sell (AMPS in,
 * counter out) and let `P1` be the post-swap price of AMPS in counter units. The pool received
 * `A_in` AMPS, worth `A_in` at `P1` by definition, and paid out `C_out` counter, worth `C_out / P1`
 * AMPS. The arbitrageur's profit — the pool's loss against having rebalanced at `P1` — is
 *
 * ```
 * lvrAmps = C_out / P1 - A_in            (sell:  AMPS in, counter out)
 * lvrAmps = A_out - C_in / P1            (buy:   counter in, AMPS out)
 * ```
 *
 * measured on the *net* input (fees stay with the LP and are reported separately, so LVR here is
 * gross of fees, which is what makes "fee revenue vs realised LVR" a comparison rather than a
 * tautology). A price-improving trade gives a negative number and is summed as it stands rather
 * than clamped: over a day the sum is the quantity the plan's KPI asks about ("sell-fee + bond
 * accretion >= modelled LVR"), and hiding the favourable trades would flatter it.
 *
 * The AMPS leg is then priced at `P_ref` to reach 18-decimal USD, which is the same price NAV uses,
 * so the LVR line and the NAV line are in the same units.
 *
 * **Fee APR.** `feeUsd18 / inventoryUsd18` annualised over the sample window. The denominator is
 * the pool's own AMPS-side ladder valued at `P_ref` plus the counter it has raised — the capital
 * actually at risk in that pool, not the whole vault.
 *
 * **There is no staking APR.** Revision 6 removed `AmpsStaking`, so there is no reward stream to
 * annualise: what the creator does not take of a compound's AMPS-side fees is burned, and the
 * counter side is re-placed as bids in the pool that earned it.
 */

import {BPS, ONE_DAY, WAD} from './constants'
import {clampInt, to18} from './math'

export interface LvrInput {
  sell: boolean
  /** Gross input in the input currency's own units. */
  amountIn: bigint
  amountOut: bigint
  /** The fee the pool kept, in the input currency's units. */
  feeAmount: bigint
  counterDecimals: number
  /** Post-swap price of AMPS in counter units, 18-decimal. */
  priceX18: bigint
}

/** The pool's realised loss against rebalancing at the post-swap price, in AMPS wei. Signed. */
export function realisedLvrAmps(input: LvrInput): bigint {
  if (input.priceX18 === 0n) return 0n
  if (input.sell) {
    const ampsIn = input.amountIn - input.feeAmount
    const counterOut18 = to18(input.amountOut, input.counterDecimals)
    return (counterOut18 * WAD) / input.priceX18 - ampsIn
  }
  const counterIn18 = to18(input.amountIn - input.feeAmount, input.counterDecimals)
  return input.amountOut - (counterIn18 * WAD) / input.priceX18
}

/** An AMPS wei amount as 18-decimal USD at `P_ref`. */
export const ampsToUsd18 = (amps: bigint, pRefX18: bigint): bigint => (amps * pRefX18) / WAD

/**
 * An annualised rate in bps from a realised amount over a window.
 * Returns 0 when the denominator or the window is zero, never `Infinity`.
 */
export function annualisedBps(earned: bigint, capital: bigint, windowSeconds: bigint): number {
  if (capital <= 0n || windowSeconds <= 0n) return 0
  const perYear = (earned * 365n * ONE_DAY) / windowSeconds
  return clampInt((perYear * BPS) / capital)
}

/**
 * A counter-asset amount as 18-decimal USD, through the pool's own price and `P_ref`.
 *
 * The counter side of a fee is thirty-two different assets with different decimals, so it can only
 * be aggregated in USD. The chain of prices is deliberately the same one `realisedLvrAmps` and
 * {@link ampsToUsd18} already use — the pool's live price to get to AMPS, `P_ref` to get to USD —
 * so the counter-side fee line and the AMPS-side fee line are comparable and neither introduces a
 * price the rest of the index does not already trust. A pool with no price yet values at zero.
 *
 * @param raw the amount in the counter's own decimals
 * @param counterDecimals the counter token's decimals
 * @param priceX18 post-swap price of AMPS in counter units, 18-decimal
 * @param pRefX18 the reference price of AMPS in USD, 18-decimal
 */
export function counterToUsd18(
  raw: bigint,
  counterDecimals: number,
  priceX18: bigint,
  pRefX18: bigint,
): bigint {
  if (raw === 0n || priceX18 === 0n || pRefX18 === 0n) return 0n
  return ampsToUsd18((to18(raw, counterDecimals) * WAD) / priceX18, pRefX18)
}
