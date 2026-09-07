// SPDX-License-Identifier: MIT

/**
 * Redemption preview.
 *
 * `redeemProRata(shares, to)` is the floor and the only unconditional exit: it burns first, then
 * removes exactly `floor(L_p x shares / T)` from every position and pays
 * `floor(b x shares / T) x (1 - redeemFeeBps/1e4)` of **every** non-AMPS balance and position
 * amount. No netting, no substitution, no oracle read, and no gate — the path contains no
 * `_requireHealthy`, no guardian and no pause reference, so it survives every feed dead, the
 * watchdog tripped, the guardian frozen and the timelock hostile. Chain-level censorship is the
 * only thing left, and `/risk` says so.
 *
 * The released inventory AMPS is burned too, so `T` falls by more than `shares`: the redemption is
 * accretive to everyone who stays.
 *
 * The authority for the numbers a user sees is `AmpsVault.previewRedeem`, which reads balances
 * only and never reverts for a live vault. Everything here formats that answer; it does not
 * recompute it.
 */

import type {Address} from 'viem'

import {BPS} from './protocol'

export interface RedeemLine {
  token: Address
  symbol: string
  decimals: number
  /** Raw amount, already net of `redeemFeeBps`, exactly as `previewRedeem` returns it. */
  amount: bigint
  /** The gross amount before the fee, derived for disclosure. */
  grossAmount: bigint
  /** The fee taken on this line, in the asset's own units. */
  feeAmount: bigint
}

export interface RedeemPreview {
  shares: bigint
  redeemFeeBps: number
  lines: readonly RedeemLine[]
  /** Additional AMPS burned from released POL inventory — why `T` falls by more than `shares`. */
  inventoryBurned: bigint
}

/**
 * Reverses the `(1 - fee)` the vault has already applied, so the fee can be shown as its own line
 * instead of being invisible inside the payout.
 *
 * Rounded so that `gross - fee >= net`: the disclosure is never more generous than the payment.
 */
export function grossFromNet(net: bigint, redeemFeeBps: number): bigint {
  const denom = BPS - BigInt(redeemFeeBps)
  if (denom <= 0n) return net
  const product = net * BPS
  return product % denom === 0n ? product / denom : product / denom + 1n
}

export function buildRedeemPreview(params: {
  shares: bigint
  redeemFeeBps: number
  inventoryBurned: bigint
  tokens: readonly Address[]
  amounts: readonly bigint[]
  meta: (token: Address) => {symbol: string; decimals: number}
}): RedeemPreview {
  if (params.tokens.length !== params.amounts.length) {
    throw new Error('buildRedeemPreview: previewRedeem returned mismatched tokens and amounts')
  }
  const lines = params.tokens.map((token, i) => {
    const amount = params.amounts[i] ?? 0n
    const gross = grossFromNet(amount, params.redeemFeeBps)
    const {symbol, decimals} = params.meta(token)
    return {token, symbol, decimals, amount, grossAmount: gross, feeAmount: gross - amount}
  })
  return {
    shares: params.shares,
    redeemFeeBps: params.redeemFeeBps,
    lines,
    inventoryBurned: params.inventoryBurned,
  }
}

/**
 * The share of the vault a redemption takes, in bps of total supply, for the "you are taking x of
 * everything" line. Uses the supply the caller read; it is not an estimate of anything else.
 */
export function redemptionShareBps(shares: bigint, totalSupply: bigint): number {
  if (totalSupply === 0n) return 0
  return Number((shares * BPS) / totalSupply)
}

/**
 * The USD value of a redemption *at the vault's own NAV/share*, net of the fee.
 *
 * This is the floor, stated as arithmetic: `shares x navPerShare x (1 - redeemFeeBps)`. It is not
 * a price, not a quote and not a promise — it is what the vault's balances divide to right now,
 * and it moves with them.
 */
export function redeemValueUsd18(params: {shares: bigint; navPerShareX18: bigint; redeemFeeBps: number}): bigint {
  const gross = (params.shares * params.navPerShareX18) / 10n ** 18n
  return (gross * (BPS - BigInt(params.redeemFeeBps))) / BPS
}
