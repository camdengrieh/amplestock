// SPDX-License-Identifier: MIT

/**
 * The bounty arithmetic, mirrored from `contracts/src/keeper/BountyPot.sol` and `VaultPlacementLib`.
 *
 * Pure. No I/O, no viem. Three jobs:
 *
 *  1. **`quoteBounty`** reproduces `BountyPot._quote` exactly, so the keeper can predict a payout without an RPC
 *     round trip.
 *  2. **`vaultGasAllowanceUsd18`** reproduces `VaultPlacementLib._gasUsed` and `_gasCostUsd18`: the gas the job
 *     burned plus `KEEPER_GAS_OVERHEAD`, capped at `KEEPER_GAS_MAX`, priced at `block.basefee` clamped into
 *     `[KEEPER_BASEFEE_FLOOR_WEI, KEEPER_BASEFEE_CAP_WEI]` and at the ETH/USD answer the feed registry holds for
 *     the `AMPS/WETH` counter. This is what makes the pot's 3x cap predictable from the keeper's side.
 *  3. **`splitAmpsFees`** reproduces §3.6 step 5, so `compound`'s single `ampsFees` return can be decomposed and
 *     the buyback-burn component separated out of `burned`.
 *
 * ## What changed, and what the keeper still has to do itself
 *
 * The pre-audit slice made the vault **measure** what it reports. `compound` accumulates the counter-side fees
 * at their feed price plus `ampsFees + boughtBack` at `P_ref`; `rollout` reports the AMPS actually moved at
 * `P_ref`; `deployBonded` reports the collateral placed at the same feed price its threshold was tested
 * against. The gas allowance is a real `gasleft()` delta with the EIP-150 63/64 correction. Three consequences:
 *
 *  * **`chost` fires.** An empty `compound` reports a zero work value and is paid exactly nothing, so the
 *    on-chain dust guard now does the work the keeper's own guard used to have to do alone.
 *  * **The 3x gas cap binds**, and at the Orbit floor basefee it is usually *the* binding constraint: a 1.5M-gas
 *    compound has an allowance of about $0.066 and a cap of about $0.20, well under the tip-plus-chip a
 *    meaningful fee collection earns.
 *  * **`BountyPot.quote` answers the real payout**, so a simulation that captures the `BountyPaid` log tells the
 *    keeper exactly what it will be paid before it sends.
 *
 * The keeper keeps its own guard anyway, for one reason: its estimate of `compound`'s work value from the return
 * value alone is a **lower bound** (the counter-side fees are not returned by the call), so a keeper that only
 * ever trusted its own estimate would skip jobs the vault would pay for. {@link meetsChost} against that lower
 * bound is therefore a *floor* on what it will attempt, and the authoritative number is the one the vault
 * reports — which `src/jobs/index.ts` reads out of the simulated `BountyPaid` event where the node supports it.
 */

/** Basis points denominator, `Constants.BPS`. */
export const BPS = 10_000n

/** 1e18. */
export const WAD = 10n ** 18n

/** `Constants.KEEPER_GAS_OVERHEAD`: the intrinsic cost and the payment itself, added to the measured delta. */
export const KEEPER_GAS_OVERHEAD = 80_000n

/** `Constants.KEEPER_GAS_MAX`: no measurement of any shape may report more gas than the worst job can burn. */
export const KEEPER_GAS_MAX = 8_000_000n

/** `Constants.KEEPER_BASEFEE_FLOOR_WEI`: 0.01 gwei, the Arbitrum Orbit floor. */
export const KEEPER_BASEFEE_FLOOR_WEI = 10_000_000n

/** `Constants.KEEPER_BASEFEE_CAP_WEI`: 1 gwei. A spike beyond it is not the pot's to fund. */
export const KEEPER_BASEFEE_CAP_WEI = 1_000_000_000n

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

/** `VaultPlacementLib._gasUsed`: the measured delta plus the overhead, under the hard ceiling. */
export function vaultGasUsed(measured: bigint): bigint {
  const total = measured + KEEPER_GAS_OVERHEAD
  return total > KEEPER_GAS_MAX ? KEEPER_GAS_MAX : total
}

/** `VaultPlacementLib._gasCostUsd18`'s basefee clamp: the pot funds neither a free block nor a spike. */
export function clampBaseFee(baseFeeWei: bigint): bigint {
  if (baseFeeWei < KEEPER_BASEFEE_FLOOR_WEI) return KEEPER_BASEFEE_FLOOR_WEI
  if (baseFeeWei > KEEPER_BASEFEE_CAP_WEI) return KEEPER_BASEFEE_CAP_WEI
  return baseFeeWei
}

/**
 * The gas allowance the **vault** reports to `BountyPot`, reproduced from the keeper's side.
 *
 * `VaultPlacementLib._gasUsed` measures `gasStart - gasleft()` with the EIP-150 `gasleft()/63` correction, adds
 * `KEEPER_GAS_OVERHEAD` and clamps at `KEEPER_GAS_MAX`; `_gasCostUsd18` prices it at the clamped basefee and the
 * ETH/USD answer. Feeding this an `eth_estimateGas` result reproduces it within the intrinsic-cost and
 * EIP-150 residual terms, which is what `amps_keeper_measured_gas_allowance_usd` against
 * `amps_keeper_reported_gas_allowance_usd` is for: a persistent divergence means the vault and the keeper
 * disagree about what a job costs, and the 3x cap is the thing that binds.
 *
 * A zero `ethUsd18` yields zero, exactly as the vault yields zero when the feed registry cannot price ETH — and
 * a zero allowance makes the 3x cap bind at zero and the job unpaid.
 */
export function vaultGasAllowanceUsd18(measuredGas: bigint, baseFeeWei: bigint, ethUsd18: bigint): bigint {
  return gasCostUsd18(vaultGasUsed(measuredGas), clampBaseFee(baseFeeWei), ethUsd18)
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
 * `genesis + 30 days` — and the creator slice is `min(creatorBps, ampsFeeBps) / ampsFeeBps` of the AMPS-side
 * fees, so it is a share of the sell fee rather than a share of volume. A zero `ampsFeeBps` cannot happen (the
 * hard band floor is 100 bp) but is handled anyway: no sell fee, no creator slice.
 */
export function splitAmpsFees(
  ampsFees: bigint,
  creatorBps: number,
  ampsFeeBps: number,
  stakerBps: number,
  burnBps: number,
): AmpsFeeSplit {
  if (ampsFees === 0n) return {creatorCut: 0n, stakerCut: 0n, burnCut: 0n, relaid: 0n}

  const creatorNumerator = BigInt(Math.min(creatorBps, ampsFeeBps))
  const creatorCut = ampsFeeBps === 0 ? 0n : (ampsFees * creatorNumerator) / BigInt(ampsFeeBps)
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
