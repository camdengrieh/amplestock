// SPDX-License-Identifier: MIT

/**
 * The bounty arithmetic, mirrored from `contracts/src/keeper/BountyPot.sol` and `VaultPlacementLib`.
 *
 * Pure. No I/O, no viem. Two jobs:
 *
 *  1. **`quoteBounty`** reproduces `BountyPot._quote` exactly, so the keeper can predict a payout for any
 *     `(workValue, gasAllowance)` pair without an RPC round trip — including the pairs the vault does *not*
 *     currently pass, which is what makes the "report measured gas" analysis possible at all.
 *  2. **`splitAmpsFees`** reproduces §3.6 step 5 of `docs/phase3-state-model.md`, so `compound`'s single
 *     `ampsFees` return can be decomposed into the creator, staker, burn and re-ladder slices — and the
 *     buyback-burn component can be separated out of `burned`, which is what the work value is measured from.
 *
 * ## The v1 gap this file exists to make visible
 *
 * `VaultPlacementLib` and `VaultRolloutLib` both hard-code
 *
 * ```solidity
 * uint256 private constant WORK_VALUE_USD18   = 1e18;   // $1
 * uint256 private constant GAS_ALLOWANCE_USD18 = 1e18;  // $1
 * ```
 *
 * and pass them to `BountyPot.pay`. They are `private constant`s in a linked library, and neither `compound`,
 * `rollout` nor `deployBonded` takes an argument the caller could use to report anything else. So the keeper
 * **cannot** feed its measured gas into the on-chain cap, however carefully it measures: the plan's
 * "Phase 4's keeper should report measured gas to make the cap live" has no channel in the landed ABI.
 *
 * Two consequences the keeper is built around:
 *
 *  * The 3x gas cap is inert. `3 x $1 = $3` is far above the `$0.05 + 2% x $1 = $0.07` a job earns, so the cap
 *    never binds and a gas spike is not what stops a job — the keeper's own profitability check is.
 *  * **`chost` is inert too.** The guard is `workValueUsd18 < chostUsd18`, and `1e18 < 1e18` is false at the
 *    launch `chost` of $1, so a `compound()` on a pool with *zero* accrued fees is paid the full tip. On-chain,
 *    a spam campaign is bounded only by the 60-second per-pool cooldown and the $25 daily ceiling. The dust
 *    guard that actually works is the keeper's own, in {@link meetsChost}, applied to the work value the keeper
 *    measures rather than the flat $1 the vault reports.
 *
 * Both are reported to the operator as metrics rather than papered over: `amps_keeper_reported_work_value_usd`
 * versus `amps_keeper_measured_work_value_usd` is exactly the divergence governance needs to size `tip`, `chip`
 * and `gasCapMultiple`, and it is the input to the v2 change that would give the entry points a
 * `gasAllowanceUsd18` argument.
 */

/** Basis points denominator, `Constants.BPS`. */
export const BPS = 10_000n

/** 1e18. */
export const WAD = 10n ** 18n

/** `VaultPlacementLib.WORK_VALUE_USD18` / `VaultRolloutLib.WORK_VALUE_USD18`: flat $1 in v1. */
export const VAULT_REPORTED_WORK_VALUE_USD18 = WAD

/** `VaultPlacementLib.GAS_ALLOWANCE_USD18` / `VaultRolloutLib.GAS_ALLOWANCE_USD18`: flat $1 in v1. */
export const VAULT_REPORTED_GAS_ALLOWANCE_USD18 = WAD

/** The pot parameters {@link quoteBounty} needs. A subset of `PotSnapshot`, so the CRE mirror can build one. */
export interface BountyParameters {
  readonly tipUsd18: bigint
  readonly chipBps: number
  readonly chostUsd18: bigint
  readonly gasCapMultiple: number
  readonly dailyCeilingUsd18: bigint
  readonly spentLast24hUsd18: bigint
  readonly balanceRaw: bigint
  readonly usdScale: bigint
}

/** What the pot would pay, and which constraint bound it. `reason` is `''` when something was payable. */
export interface BountyQuote {
  readonly payableRaw: bigint
  readonly payableUsd18: bigint
  readonly reason: '' | 'chost' | 'gasCap' | 'dailyCeiling' | 'depleted'
}

function saturatingSub(a: bigint, b: bigint): bigint {
  return a > b ? a - b : 0n
}

function saturatingMul(a: bigint, b: bigint): bigint {
  const product = a * b
  const max = (1n << 256n) - 1n
  return product > max ? max : product
}

/**
 * `BountyPot._quote`, line for line.
 *
 * The order of the caps is the contract's: dust guard on the work value, then tip + chip, then the gas cap, then
 * the rolling daily ceiling, then the pot's own balance. `reason` names the binding constraint exactly as the
 * `BountyPaid` event does, including the contract's final rule that a payment which rounds to zero raw units
 * with no cap binding is reported as `depleted`.
 */
export function quoteBounty(
  parameters: BountyParameters,
  workValueUsd18: bigint,
  gasCostUsd18: bigint,
): BountyQuote {
  if (workValueUsd18 < parameters.chostUsd18) return {payableRaw: 0n, payableUsd18: 0n, reason: 'chost'}

  let gross = parameters.tipUsd18 + (workValueUsd18 * BigInt(parameters.chipBps)) / BPS
  let reason: BountyQuote['reason'] = ''

  const gasCap = saturatingMul(gasCostUsd18, BigInt(parameters.gasCapMultiple))
  if (gasCap < gross) {
    gross = gasCap
    reason = 'gasCap'
  }

  const budget = budgetLeftUsd18(parameters)
  if (budget < gross) {
    gross = budget
    reason = 'dailyCeiling'
  }

  let payableRaw = gross / parameters.usdScale
  if (parameters.balanceRaw < payableRaw) {
    payableRaw = parameters.balanceRaw
    reason = 'depleted'
  }

  if (payableRaw !== 0n) {
    return {payableRaw, payableUsd18: payableRaw * parameters.usdScale, reason: ''}
  }
  return {payableRaw: 0n, payableUsd18: 0n, reason: reason === '' ? 'depleted' : reason}
}

/** `BountyPot.budgetLeftUsd18()`. */
export function budgetLeftUsd18(parameters: BountyParameters): bigint {
  return saturatingSub(parameters.dailyCeilingUsd18, parameters.spentLast24hUsd18)
}

/**
 * The keeper's own dust guard.
 *
 * `BountyPot`'s guard is applied to the flat $1 the vault reports and therefore never fires; this one is applied
 * to the work the keeper actually measured, which is what makes a spam campaign of empty `compound()` calls
 * cost the campaigner gas and earn nothing from *this* keeper. It is deliberately the same comparison as the
 * contract's, so raising `chostUsd18` through governance tightens both at once.
 */
export function meetsChost(measuredWorkValueUsd18: bigint, chostUsd18: bigint): boolean {
  return measuredWorkValueUsd18 >= chostUsd18
}

/**
 * Gas cost in 18-decimal USD.
 *
 * `gas x baseFeeWei` is wei; dividing by `WAD` once turns it into ETH, and multiplying by an 18-decimal ETH/USD
 * price leaves an 18-decimal USD figure. A zero `ethUsd18` yields zero, which is how the profitability check is
 * disabled on a chain whose ETH/USD feed Phase 0 has not resolved yet.
 */
export function gasCostUsd18(gas: bigint, baseFeeWei: bigint, ethUsd18: bigint): bigint {
  return (gas * baseFeeWei * ethUsd18) / WAD
}

/**
 * The gas allowance the keeper *would* report if the entry points accepted one, in 18-decimal USD.
 *
 * Identical arithmetic to {@link gasCostUsd18}; it is a separate name because it is a distinct claim — this is
 * the number that would make `BountyPot`'s `gasCapMultiple` bind, and it is exported as a metric so governance
 * can see how far the flat $1 is from the truth.
 */
export function measuredGasAllowanceUsd18(gas: bigint, baseFeeWei: bigint, ethUsd18: bigint): bigint {
  return gasCostUsd18(gas, baseFeeWei, ethUsd18)
}

/** The AMPS-side split of `compound`, §3.6 step 5. */
export interface AmpsFeeSplit {
  readonly creatorCut: bigint
  readonly stakerCut: bigint
  readonly burnCut: bigint
  readonly relaid: bigint
}

/**
 * `VaultPlacementLib._split`, in the order the contract applies it.
 *
 * `creatorBps` is `AmpsVault.creatorBpsAt(now)` — 100 bp at genesis decaying linearly to exactly zero at
 * `genesis + 30 days` — and the creator slice is `min(creatorBps, sellFeeBps) / sellFeeBps` of the AMPS-side
 * fees, so it is a share of the sell fee rather than a share of volume. A zero `sellFeeBps` cannot happen (the
 * hard band floor is 100 bp) but is handled anyway: no sell fee, no creator slice.
 */
export function splitAmpsFees(
  ampsFees: bigint,
  creatorBps: number,
  sellFeeBps: number,
  stakerBps: number,
  burnBps: number,
): AmpsFeeSplit {
  if (ampsFees === 0n) return {creatorCut: 0n, stakerCut: 0n, burnCut: 0n, relaid: 0n}

  const creatorNumerator = BigInt(Math.min(creatorBps, sellFeeBps))
  const creatorCut = sellFeeBps === 0 ? 0n : (ampsFees * creatorNumerator) / BigInt(sellFeeBps)
  const afterCreator = ampsFees - creatorCut
  const stakerCut = (afterCreator * BigInt(stakerBps)) / BPS
  const afterStaker = afterCreator - stakerCut
  const burnCut = (afterStaker * BigInt(burnBps)) / BPS
  return {creatorCut, stakerCut, burnCut, relaid: afterStaker - burnCut}
}

/**
 * The USD value of the work a `compound(poolId)` would do.
 *
 * `compound` returns `(ampsFees, burned)`. `burned` is the buyback burn **plus** the `burnBps` slice of the
 * fees, so subtracting the slice recovers the bought-back inventory, which is real work the fee figure does not
 * contain. Counter-side fees are not returned by the call and are therefore not counted: the measure is a lower
 * bound on the work, which is the safe direction for a dust guard.
 */
export function compoundWorkValueUsd18(
  ampsFees: bigint,
  burned: bigint,
  split: AmpsFeeSplit,
  pRefX18: bigint,
): bigint {
  const boughtBack = saturatingSub(burned, split.burnCut)
  return ((ampsFees + boughtBack) * pRefX18) / WAD
}
