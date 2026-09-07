// SPDX-License-Identifier: MIT

/**
 * The shapes `apps/indexer` serves.
 *
 * `docs/indexer.md` did not exist when this was written, so these types are the dApp's *stated
 * requirement* rather than a transcription of a published contract: they name exactly the eight
 * endpoints the plan lists for the front end (vault summary, NAV history, ladder fill per pool,
 * bond board, staking APR, flywheel metrics, gate status, burn history) and nothing else.
 *
 * Two consequences, both deliberate:
 *
 * - every field is optional-tolerant at the boundary — `parse*` narrows and drops what it does not
 *   recognise, so an indexer that adds a field does not break the app and one that omits a field
 *   renders that panel as unavailable rather than as zero;
 * - **nothing here is authority for a number a user can trade on.** Prices, NAV, fees, bond terms
 *   and capacity are read from the chain through `AmpsQuoter`, `AmpsVault` and `AmpsBonds`. The
 *   indexer supplies history and aggregates, which no `eth_call` can.
 */

import type {Address, Hex} from 'viem'

/** Every numeric field crossing the wire is a decimal string: JSON has no bigint. */
export type NumericString = string

export interface VaultSummary {
  chainId: number
  blockNumber: NumericString
  timestamp: number
  navPerShareX18: NumericString
  pRefX18: NumericString
  pMktX18: NumericString
  premiumX18: NumericString
  totalAssetsUsd18: NumericString
  totalSupply: NumericString
  circulating: NumericString
  inventory: NumericString
  vesting: NumericString
  staked: NumericString
  redeemFeeBps: number
  liveCells: number
  creatorBpsNow: number
  creatorFeeSecondsRemaining: number
  pegDevBp: number
}

export interface NavPoint {
  timestamp: number
  navPerShareX18: NumericString
  pRefX18: NumericString
  pMktX18: NumericString
  totalSupply: NumericString
}

export interface LadderCell {
  bucketIndex: number
  lowerTick: number
  upperTick: number
  above: boolean
  /** Token committed at placement: AMPS wei for an ask, counter raw units for a bid. */
  amount: NumericString
  /** Live position liquidity now. Zero once the cell has been fully consumed. */
  liquidity: NumericString
  /** Counter-asset raised by this cell so far — the "proceeds per cell" the plan asks for. */
  proceeds: NumericString
  filledFraction: number
  placedAt: number
}

export interface LadderFill {
  poolId: Hex
  counter: Address
  symbol: string
  poolClass: number
  cells: readonly LadderCell[]
  /** Counter-asset the vault holds as bids in this pool: the entire bid depth under AMPS. */
  bidDepth: NumericString
  /** AMPS still sitting as unfilled asks. */
  askInventory: NumericString
  rolloutWeightBps: number
  rolloutMovedToday: NumericString
}

export interface BondBoardRow {
  marketId: number
  collateral: Address
  symbol: string
  decimals: number
  class: number
  open: boolean
  discountBps: number
  qX18: NumericString
  floorQX18: NumericString
  floorBinding: boolean
  capacityLeft: NumericString
  capacityPerEpoch: NumericString
  epochStart: number
  epochSeconds: number
  vestSeconds: number
  issuedThisEpoch: NumericString
  totalIssued: NumericString
  hSessionBps: number
}

export interface StakingStats {
  totalAssets: NumericString
  totalSupply: NumericString
  sharePriceX18: NumericString
  pendingRewards: NumericString
  streamEnd: number
  rewardStreamSeconds: number
  /** Realised: fees actually collected and streamed over the trailing window. Not a projection. */
  realisedAprBps: number
  windowSeconds: number
  windowRewards: NumericString
}

export interface FlywheelMetrics {
  windowSeconds: number
  sellFeeAmps: NumericString
  buyFeeUsd18: NumericString
  bondIssuedAmps: NumericString
  bondAccretionUsd18: NumericString
  burnedAmps: NumericString
  creatorPaidAmps: NumericString
  stakerPaidAmps: NumericString
  netSupplyChange: NumericString
  perPool: readonly {poolId: Hex; symbol: string; feeAprBps: number; realisedLvrBps: number}[]
}

export interface GateStatusRow {
  poolId: Hex
  constituentId: number
  symbol: string
  gateState: number
  session: number
  feedStale: boolean
  corporateFreeze: boolean
  diverged: boolean
  watchdogTripped: boolean
  hSessionBps: number
  answerUpdatedAt: number
  observedAt: number
}

export interface BurnEvent {
  blockNumber: NumericString
  timestamp: number
  amount: NumericString
  /** `bytes32` reason from the `Burn` event: buyback, redemption release, fee sink. */
  reason: Hex
  txHash: Hex
}

export interface IndexerHealth {
  ok: boolean
  chainId: number
  latestBlock: NumericString
  lagSeconds: number
  /** The indexer's own reconciliation of indexed NAV against a chain read. */
  navReconciled: boolean
}
