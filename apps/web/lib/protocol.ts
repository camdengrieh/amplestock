// SPDX-License-Identifier: MIT

/**
 * The protocol constants the UI has to reason about, mirrored from
 * `contracts/src/types/Constants.sol` and `contracts/src/types/Types.sol`.
 *
 * **These are display and arithmetic defaults, never authority.** Every one of them is governed
 * state on chain, and every surface that can read the live value reads it (`AmpsQuoter`,
 * `AmpsVault`, `AmpsBonds`, `AmpsHook`). What lives here is the enum ordinals — which are ABI, per
 * `Types.sol` — the hard bands, which are hardcoded in the consuming contract and therefore cannot
 * move without a migration, and the launch defaults used to render a band next to a live value.
 */

import {keccak256, toBytes} from 'viem'

// ---------------------------------------------------------------------------------------------
// Scales
// ---------------------------------------------------------------------------------------------

export const BPS = 10_000n
export const WAD = 10n ** 18n
export const USD_PRICE_SCALE = 10n ** 8n
export const PIPS_PER_BPS = 100n
export const MAX_LP_FEE = 1_000_000n

// ---------------------------------------------------------------------------------------------
// Enum ordinals — ABI, per `Types.sol`
// ---------------------------------------------------------------------------------------------

export const GateState = {
  GREEN: 0,
  DEGRADED: 1,
  DIVERGED: 2,
  REF_DIVERGED: 3,
  SCHEDULED_FREEZE: 4,
  WATCHDOG: 5,
} as const
export type GateStateName = keyof typeof GateState
export const gateStateNames: readonly GateStateName[] = [
  'GREEN',
  'DEGRADED',
  'DIVERGED',
  'REF_DIVERGED',
  'SCHEDULED_FREEZE',
  'WATCHDOG',
]

export const Session = {REGULAR: 0, PRE_POST: 1, OVERNIGHT: 2, CLOSED: 3} as const
export type SessionName = keyof typeof Session
export const sessionNames: readonly SessionName[] = ['REGULAR', 'PRE_POST', 'OVERNIGHT', 'CLOSED']
export const sessionLabels: Readonly<Record<SessionName, string>> = {
  REGULAR: 'Regular',
  PRE_POST: 'Pre / post',
  OVERNIGHT: 'Overnight',
  CLOSED: 'Closed',
}

export const ConstituentStatus = {NONE: 0, ACTIVE: 1, RETIRED: 2, FROZEN: 3} as const
export type ConstituentStatusName = keyof typeof ConstituentStatus
export const constituentStatusNames: readonly ConstituentStatusName[] = ['NONE', 'ACTIVE', 'RETIRED', 'FROZEN']

export const CollateralClass = {CONSTITUENT: 0, ENTRY: 1} as const

export const PoolClass = {NONE: 0, ENTRY: 1, SPOKE: 2, SPOKE_HIGH_VOL: 3} as const
export type PoolClassName = keyof typeof PoolClass
export const poolClassNames: readonly PoolClassName[] = ['NONE', 'ENTRY', 'SPOKE', 'SPOKE_HIGH_VOL']

// ---------------------------------------------------------------------------------------------
// Fee law (`docs/phase3-state-model.md` §1.4)
// ---------------------------------------------------------------------------------------------

export const F_MIN_BPS = 3
export const TOTAL_FEE_BPS_MAX = 2_600
export const FROZEN_FEE_FLOOR_BPS = 100
export const DYN_CAP_NORMAL_BPS = 300
export const DYN_CAP_DEGRADED_BPS = 1_000
export const DYN_CAP_ESCALATION_BPS = 2_000
export const F_WALL_BPS = 1_500
export const K_DEV_BPS = 25

/**
 * Launch defaults and hard bands. Governed; the live value is read from the hook or the vault, and
 * every surface that can read it does. These exist to render a band next to a live number.
 *
 * `AMPS_FEE_BPS_*` is the **AMPS fee**: `AmpsHook.ampsFeeBps()`, the base fee on *both* directions
 * of every pool. `BUY_FEE_BPS_*` is the **pass-through** base — `AmpsHook.buyFeeBps(poolId)`, the
 * price of moving through a pool — and it is charged only on a hop of `AmpsRouter.rotate`. They
 * are two different fees on two different paths, not a buy price and a sell price.
 */
export const AMPS_FEE_BPS_DEFAULT = 500
export const AMPS_FEE_BPS_BAND = {min: 100, max: 600} as const
export const BUY_FEE_BPS_ENTRY_DEFAULT = 30
export const BUY_FEE_BPS_ENTRY_BAND = {min: 5, max: 100} as const
export const BUY_FEE_BPS_SPOKE_DEFAULT = 5
export const BUY_FEE_BPS_SPOKE_HIGH_VOL_DEFAULT = 10
export const BUY_FEE_BPS_SPOKE_BAND = {min: 1, max: 50} as const
export const REDEEM_FEE_BPS_DEFAULT = 250
export const REDEEM_FEE_BPS_MAX = 500
/**
 * There is no `burnBps` and no `stakerBps` under revision 6. The AMPS side of every fee is burned
 * after the creator slice — a whole share rather than a governed fraction of one — and staking is
 * gone entirely, so neither constant exists to be mirrored.
 */
export const CREATOR_FEE_BPS = 100
export const CREATOR_DECAY_SECONDS = 30 * 86_400

/**
 * `Constants.ROUTER_ROTATE` — the `hookData` that, when it arrives from `AmpsHook.router()` and
 * from nobody else, buys a hop the pass-through price.
 *
 * **Derived, not transcribed.** It is `keccak256("amplestocks.router.ROTATE")` in the contracts, so
 * it is the same hash here, computed from the same string. A 32-byte literal copied by hand would
 * be a number in this repository that nothing checks; this cannot disagree with the contract
 * unless the string does. `AmpsRouter.ROTATE_FLAG()` returns it on chain for the same reason —
 * so an integrator can verify the exemption keys on what the comments say it does.
 */
export const ROUTER_ROTATE_STRING = 'amplestocks.router.ROTATE' as const
export const ROUTER_ROTATE = keccak256(toBytes(ROUTER_ROTATE_STRING))

// ---------------------------------------------------------------------------------------------
// Bonds, ladder, timing
// ---------------------------------------------------------------------------------------------

export const MIN_ACCRETION_BPS_DEFAULT = 50
export const BOND_VEST_SECONDS_DEFAULT = 12 * 3_600
export const BOND_EPOCH_SECONDS_DEFAULT = 6 * 3_600
export const H_SESSION_BPS_DEFAULT: readonly number[] = [0, 50, 150, 300]
export const GRID_CELLS = 24
export const GRID_MIN_M = -8
export const MAX_LIVE_CELLS = 512
export const MAX_CONSTITUENTS = 64
export const CHECKPOINT_MAX_AGE = 1_800
export const PLACEMENT_COOLDOWN_SECONDS = 60
export const TWAP_WINDOW_DEFAULT = 1_800

/** `fee == DYNAMIC_FEE_FLAG` in all 32 pools; the hook overrides per swap. */
export const DYNAMIC_FEE_FLAG = 0x800000

/** The zero address, used only as a placeholder argument for a read that is disabled anyway. */
export const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as const
