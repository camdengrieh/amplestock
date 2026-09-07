// SPDX-License-Identifier: MIT

/**
 * The constants the indexer must agree with the contracts on.
 *
 * Everything here is either an ABI-stable enum ordinal (`types/Types.sol`: "members are only ever
 * appended, never reordered or removed"), a scale, or a grid parameter from `types/Constants.sol`
 * and `lib/LadderLib.sol`. `test/constants.test.ts` pins the ones that would silently mis-index if
 * they drifted.
 */

export const BPS = 10_000n
export const WAD = 10n ** 18n
/** Chainlink's answer scale on Robinhood Chain. */
export const USD_PRICE_SCALE = 10n ** 8n
/** Uniswap v4 charges LP fees in hundredths of a basis point. */
export const PIPS_PER_BPS = 100n
export const PIPS_DENOMINATOR = 1_000_000n

export const ONE_HOUR = 3_600n
export const ONE_DAY = 86_400n

/** `(A + 1) * 1e18 / (T + VIRTUAL_SHARES)`. */
export const VIRTUAL_SHARES = 1_000n

/** `Constants.S0`: the whole genesis supply, minted once. */
export const S0 = 5_000n * WAD

/** `Constants.CREATOR_FEE_BPS` and its immutable decay. */
export const CREATOR_FEE_BPS = 100n
export const CREATOR_DECAY_SECONDS = 30n * ONE_DAY

/** `LadderLib.TICKS_PER_DOUBLING`: `ln(2)/ln(1.0001)` rounded up. */
export const TICKS_PER_DOUBLING = 6_932

/** `Constants.GRID_MIN_M` / `GRID_MAX_M` / `GRID_CELLS`. */
export const GRID_MIN_M = -8
export const GRID_MAX_M = 16
export const GRID_CELLS = GRID_MAX_M - GRID_MIN_M

/** `Constants.POSITION_SALT`: every Amplestocks position uses salt zero. */
export const POSITION_SALT = '0x0000000000000000000000000000000000000000000000000000000000000000' as const

/** `Constants.MAX_LIVE_CELLS` (§12 ruling E). */
export const MAX_LIVE_CELLS = 512

/** `GateState`, in ordinal order. */
export const GATE_STATES = [
  'GREEN',
  'DEGRADED',
  'DIVERGED',
  'REF_DIVERGED',
  'SCHEDULED_FREEZE',
  'WATCHDOG',
] as const
export type GateStateLabel = (typeof GATE_STATES)[number]

/** `Session`, in ordinal order. Monotone non-decreasing in closedness (I19). */
export const SESSIONS = ['REGULAR', 'PRE_POST', 'OVERNIGHT', 'CLOSED'] as const

/** `ConstituentStatus`, in ordinal order. */
export const CONSTITUENT_STATUS = ['NONE', 'ACTIVE', 'RETIRED', 'FROZEN'] as const

/** `CollateralClass`, in ordinal order. */
export const COLLATERAL_CLASSES = ['CONSTITUENT', 'ENTRY'] as const

/** `PoolClass`, in ordinal order. */
export const POOL_CLASSES = ['NONE', 'ENTRY', 'SPOKE', 'SPOKE_HIGH_VOL'] as const

const label = <T extends readonly string[]>(table: T, ordinal: number): T[number] | 'UNKNOWN' =>
  (table[ordinal] as T[number] | undefined) ?? 'UNKNOWN'

export const gateStateLabel = (o: number) => label(GATE_STATES, o)
export const sessionLabel = (o: number) => label(SESSIONS, o)
export const constituentStatusLabel = (o: number) => label(CONSTITUENT_STATUS, o)
export const collateralClassLabel = (o: number) => label(COLLATERAL_CLASSES, o)
export const poolClassLabel = (o: number) => label(POOL_CLASSES, o)

/**
 * `LadderLib.doublingTicks`: one price doubling, rounded up to a whole tick spacing.
 * A cell is `[gridBaseTick + m*D, gridBaseTick + (m+1)*D)`.
 */
export function doublingTicks(tickSpacing: number): number {
  if (tickSpacing <= 0) throw new Error(`[indexer] invalid tick spacing: ${tickSpacing}`)
  return Math.ceil(TICKS_PER_DOUBLING / tickSpacing) * tickSpacing
}

/** The grid cell index of a tick, or `-1` when the tick is off the grid or out of range. */
export function cellIndexOf(tickLower: number, gridBaseTick: number, tickSpacing: number): number {
  const d = doublingTicks(tickSpacing)
  const offset = tickLower - gridBaseTick
  if (offset % d !== 0) return -1
  const m = offset / d
  if (m < GRID_MIN_M || m >= GRID_MAX_M) return -1
  return m - GRID_MIN_M
}

/** `m`, the signed doubling index. Defined even when the cell is off the `[MIN_M, MAX_M)` window. */
export function doublingIndexOf(tickLower: number, gridBaseTick: number, tickSpacing: number): number {
  const d = doublingTicks(tickSpacing)
  return Math.floor((tickLower - gridBaseTick) / d)
}
