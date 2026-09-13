// SPDX-License-Identifier: MIT

/**
 * The shapes `apps/indexer` actually serves.
 *
 * These used to be the dApp's *stated requirement* — a list of the panels the front end wanted,
 * written before the indexer existed. That is no longer honest: the indexer is built, its
 * `/api/*` layer returns named envelopes rather than bare arrays, and a type that describes what
 * the app wishes it received is a type that compiles while every panel renders undefined. So this
 * file is a transcription of `apps/indexer/src/api/index.ts` and `apps/indexer/ponder.schema.ts`,
 * and the envelopes are named as envelopes.
 *
 * **There is no staking anywhere in it.** Revision 6 removed `AmpsStaking`, so there is no
 * `/api/staking`, no `staked` share class and no staker slice of a compound. An endpoint nothing
 * can consume is a claim that the thing it describes still exists.
 *
 * Two rules survive from the earlier draft, and both are load-bearing:
 *
 * - **every field is optional-tolerant at the boundary.** The client hands back what the indexer
 *   sent; a reader that finds a field missing renders that panel as *unavailable* rather than as
 *   zero, and an indexer that adds a field costs nothing.
 * - **nothing here is authority for a number a user can trade on.** Prices, NAV, fees, bond terms
 *   and capacity are read from the chain through `AmpsQuoter`, `AmpsVault` and `AmpsBonds`. The
 *   indexer supplies history and aggregates, which no `eth_call` can.
 */

import type {Address, Hex} from 'viem'

/** Every numeric field crossing the wire is a decimal string: JSON has no bigint. */
export type NumericString = string

// -----------------------------------------------------------------------------------------------
// `/api/vault`
// -----------------------------------------------------------------------------------------------

/**
 * The one-row vault summary, `vault_summary` in the schema.
 *
 * The cumulative fee fields are the revision-6 split: what was collected, what the creator took in
 * each currency, and what was burned. There is no `stakerPaidTotal` and no `relaidTotal`, because
 * the AMPS side is burned in full after the creator slice and the counter side never leaves the
 * pool that earned it.
 */
export interface VaultSummary {
  vault: Address
  amps: Address
  registry: Address
  creator: Address
  genesisAt: NumericString
  genesisBlock: NumericString
  genesisMinted: NumericString
  genesisNavPerShareX18: NumericString
  navPerShareX18: NumericString
  totalAssetsUsd18: NumericString
  totalSupply: NumericString
  pRefX18: NumericString
  pMktX18: NumericString
  premiumBps: number
  inventory: NumericString
  vesting: NumericString
  circulating: NumericString
  /** Cumulative AMPS collected as fees and split at `compound()`. */
  feesAmpsTotal: NumericString
  /** Cumulative counter asset collected as fees, in 18-decimal USD at the time of collection. */
  feesCounterUsd18: NumericString
  /** Cumulative AMPS paid to the creator, by transfer. */
  creatorPaidAmpsTotal: NumericString
  /** Cumulative counter asset paid to the creator in kind, in 18-decimal USD. */
  creatorPaidCounterUsd18: NumericString
  /** Cumulative AMPS burned at `compound()`: the fee remainder plus the buyback. */
  burnedTotal: NumericString
  /** Cumulative AMPS burned for any reason, redemption included. */
  burnedAllTotal: NumericString
  bondIssuedTotal: NumericString
  redeemedSharesTotal: NumericString
  vestingMintedTotal: NumericString
  /** `S0 + bondIssued + vestingMinted - burnedAll`. */
  netSupplyChange: NumericString
  compoundCount: number
  swapCount: number
  lastBlock: NumericString
  lastTimestamp: NumericString
}

/** `share_point`: supply by class at a block. No `staked` class exists any more. */
export interface SharePoint {
  blockNumber: NumericString
  timestamp: NumericString
  totalSupply: NumericString
  inventory: NumericString
  vesting: NumericString
  bondUnvested: NumericString
  circulating: NumericString
  source: string
}

export interface ReconciliationPoint {
  blockNumber: NumericString
  timestamp: NumericString
  navPerShareX18: NumericString
  chainNavPerShareX18: NumericString
  deltaBps: number
}

/** The `/api/vault` envelope. `shares` and `reconciliation` are `null` before the first sample. */
export interface VaultResponse {
  summary: VaultSummary
  shares: SharePoint | null
  reconciliation: ReconciliationPoint | null
}

// -----------------------------------------------------------------------------------------------
// `/api/genesis`
// -----------------------------------------------------------------------------------------------

/**
 * The launch, `genesis` in the schema: one row that is legible at every point in genesis.
 *
 * Genesis is two vault calls with a 72-hour auction between them, so four logs on two contracts fill
 * this row over three days and none of them waits for the others: the mint half from
 * `AmpsVault.GenesisMinted`, the auction half from `AmpsGenesis.AuctionsCreated`, and the settlement
 * from `AmpsGenesis.Settled` plus the vault's own `Genesis`. A row with tranches and no auctions, or
 * auctions and no settlement, is a correct row rather than a partial one.
 *
 * **`p0X18` of zero is not a price.** It is zero before settlement and zero for ever after a
 * settlement in which no leg graduated, so a reader consults `settledBlock` and `graduated` — never
 * the number. `phase` is not here at all: the adapter derives it from the block number and no log
 * carries it, so a live phase is a chain read (`hooks/use-genesis.ts`) and `settledPhase` is the
 * terminal answer a log does decide.
 */
export interface GenesisRecord {
  /** `AmpsGenesis`, and the vault it settles into. Zero until a genesis log names them. */
  adapter: Address
  vault: Address
  /** From `GenesisMinted`. */
  mintedBlock: NumericString
  mintedAt: NumericString
  creator: Address
  teamVestingWallet: Address
  teamShares: NumericString
  auctionShares: NumericString
  polShares: NumericString
  /** From `AuctionsCreated`: the two legs and the floors the adapter computed for them. */
  auctionsBlock: NumericString
  usdgAuction: Address
  ethAuction: Address
  floorUsdgQ96: NumericString
  floorEthQ96: NumericString
  startBlock: NumericString
  endBlock: NumericString
  /** From `Settled`. `settledBlock` of zero means settlement has not happened. */
  settledBlock: NumericString
  settledAt: NumericString
  /** `"settled"` once a leg graduated, `"aborted"` when none did, `""` before settlement. */
  settledPhase: string
  p0X18: NumericString
  raisedUsdg: NumericString
  raisedWeth: NumericString
  unsoldAmps: NumericString
  usdgGraduated: boolean
  ethGraduated: boolean
  /** True when at least one leg graduated: the only honest reading of "did the launch happen". */
  graduated: boolean
  /** From the vault's own `Genesis`: the launch as the vault recorded it. */
  launchBlock: NumericString
  launchAt: NumericString
  totalMinted: NumericString
  navPerShareX18: NumericString
  raisedUsd18: NumericString
  /** `p0X18 / navPerShareX18 - 1`, in bps. A disclosure, never a discount. */
  premiumBps: number
  /** From `ClearingPricesDiverged`: both legs graduated and their implied prices disagreed. */
  diverged: boolean
  divergedUsdgP0X18: NumericString
  divergedEthP0X18: NumericString
  divergenceToleranceBps: number
  lastBlock: NumericString
}

/**
 * One bid in one leg, `auction_bid` in the schema.
 *
 * Additive: the Auction surface reads the connected wallet's own bids straight off the auction's
 * `BidSubmitted` logs and keeps doing so, because that path works with no indexer at all. What this
 * adds is the whole book. `amountQ96` is stored as the auction stores it — dividing by 2^96 is a
 * display step that would throw away the low bits deciding which tick a bid sits on.
 */
export interface AuctionBidRow {
  auction: Address
  /** `"usdg"` or `"eth"`. */
  leg: string
  bidId: NumericString
  owner: Address
  maxPriceQ96: NumericString
  amountQ96: NumericString
  submittedBlock: NumericString
  submittedAt: NumericString
  txHash: Hex
  /** Non-zero once the bidder exited; the fill and the refund are then settled. */
  exitedBlock: NumericString
  tokensFilled: NumericString
  currencyRefunded: NumericString
  claimedBlock: NumericString
  claimedAmount: NumericString
}

/**
 * One checkpoint of one leg, `auction_checkpoint` in the schema — the clearing-price series.
 *
 * `checkpoint()` is a write, not a view, so the clearing price only moves when somebody pays to
 * advance it. That makes this the only record of what the auction actually charged over the window;
 * a `view` read gives one number and no history.
 */
export interface AuctionCheckpointRow {
  auction: Address
  leg: string
  blockNumber: NumericString
  timestamp: NumericString
  txHash: Hex
  logIndex: number
  clearingPriceQ96: NumericString
  /** Share of the tranche issued by this block, in milli-bips (`1e7` = 100%). */
  cumulativeMps: NumericString
}

/** The `/api/genesis` envelope. `checkpoints` is oldest first; `bids` is newest first. */
export interface GenesisResponse {
  genesis: GenesisRecord
  bids: readonly AuctionBidRow[]
  checkpoints: readonly AuctionCheckpointRow[]
}

// -----------------------------------------------------------------------------------------------
// `/api/nav-history`, `/api/premium-history`, `/api/share-history`
// -----------------------------------------------------------------------------------------------

/** `nav_checkpoint`, oldest first. */
export interface NavPoint {
  blockNumber: NumericString
  timestamp: NumericString
  navPerShareX18: NumericString
  totalAssetsUsd18: NumericString
  totalSupply: NumericString
  navChangeBps: number
}

/** `ref_checkpoint`, oldest first. */
export interface PremiumPoint {
  blockNumber: NumericString
  timestamp: NumericString
  pRefX18: NumericString
  pMktX18: NumericString
  navPerShareX18: NumericString
  premiumX18: NumericString
  premiumBps: number
  rateLimited: boolean
  navFloored: boolean
}

/** Every history endpoint answers `{points}`. */
export interface PointsResponse<T> {
  points: readonly T[]
}

// -----------------------------------------------------------------------------------------------
// `/api/burns`
// -----------------------------------------------------------------------------------------------

/**
 * One `Burn`. The vault emits exactly four reasons: `buyback` (a fully round-tripped ask cell the
 * protocol's own bids bought back), `compound` (the AMPS-side fee remainder, after the creator's
 * slice), `redeem` (the shares a redeemer burned) and `redeemInventory` (the vault's own AMPS
 * released alongside them).
 */
export interface BurnEvent {
  blockNumber: NumericString
  timestamp: NumericString
  txHash: Hex
  amount: NumericString
  /** The short string the vault packed, decoded by the indexer. */
  reason: string
  /** The raw `bytes32` it decoded, so a consumer can check the decode itself. */
  reasonRaw: Hex
  /** The pool the burn belongs to, when the transaction identifies one. */
  poolId: Hex | null
}

export interface BurnHistory {
  burns: readonly BurnEvent[]
  total: NumericString
  count: number
}

// -----------------------------------------------------------------------------------------------
// `/api/creator-fee`
// -----------------------------------------------------------------------------------------------

/**
 * The creator schedule and what it has actually paid, in each currency.
 *
 * Revision 6 pays the creator `creatorBps(t) / ampsFeeBps` of the fees collected in **every**
 * currency, in kind: AMPS by transfer, counter assets by transfer with an ERC-6909 claim fallback
 * so a gated token can never block a compound. So there are two paid totals, not one, and the
 * counter one is a USD aggregate across thirty-two different assets rather than an amount.
 */
export interface CreatorFeeStatus {
  creator: Address
  feeBpsAtGenesis: number
  decaySeconds: NumericString
  genesisAt: NumericString
  elapsedSeconds: NumericString
  remainingSeconds: NumericString
  /** The schedule in force now, in bps of trade volume. Zero from day 30. */
  currentBps: number
  /** AMPS wei transferred to the creator so far. */
  paidAmpsTotal: NumericString
  /** Counter assets paid in kind so far, in 18-decimal USD at the time of each payment. */
  paidCounterUsd18: NumericString
}

// -----------------------------------------------------------------------------------------------
// `/api/pools` and `/api/pools/:poolId/ladder`
// -----------------------------------------------------------------------------------------------

/** `pool`: one row per registered pool, with its live state and its ladder totals. */
export interface PoolRow {
  id: Hex
  counter: Address
  counterSymbol: string | null
  counterDecimals: number
  poolClass: number
  poolClassLabel: string
  constituentId: number
  tickSpacing: number
  gridBaseTick: number | null
  /** The pool's **pass-through** base fee in bps — not what an ordinary swap pays. */
  buyFeeBps: number
  tick: number
  liquidity: NumericString
  gateState: number
  gateStateLabel: string
  diverged: boolean
  divergenceBps: number
  sellVolumeAmps: NumericString
  buyVolumeAmps: NumericString
  /** AMPS collected as fees on sells through this pool. */
  sellFeeAmps: NumericString
  /** Counter asset collected as fees on buys through this pool, in its own decimals. */
  buyFeeCounter: NumericString
  /** AMPS covered by a rotation credit — i.e. that moved through on the router's path. */
  rotationCreditedAmps: NumericString
  swapCount: number
  askCells: number
  bidCells: number
  /** AMPS still sitting as unfilled asks. */
  ampsInLadder: NumericString
  /** The entire bid under AMPS in this pool: every pool is protocol-owned. */
  counterInLadder: NumericString
  ladderFillBps: number
  realisedLvrUsd18: NumericString
  feeRevenueUsd18: NumericString
}

export interface PoolsResponse {
  pools: readonly PoolRow[]
}

/** `ladder_cell`: one placed grid cell. */
export interface LadderCell {
  bucketIndex: number
  tickLower: number
  tickUpper: number
  above: boolean
  /** Token committed at placement: AMPS wei for an ask, counter raw units for a bid. */
  amount: NumericString
  /** Live position liquidity now. Zero once the cell has been fully consumed. */
  liquidity: NumericString
  /** What this cell has raised so far, in the other side's units. */
  proceeds: NumericString
  filledBps: number
  placedAt: NumericString
}

/** The `/api/pools/:poolId/ladder` envelope. */
export interface LadderDetail {
  pool: PoolRow
  cells: readonly LadderCell[]
  totals: {
    ampsInLadder: NumericString
    counterInLadder: NumericString
    askCells: number
    bidCells: number
    fillBps: number
  }
}

// -----------------------------------------------------------------------------------------------
// `/api/bonds`
// -----------------------------------------------------------------------------------------------

export interface BondMarketRow {
  marketId: number
  collateral: Address
  symbol: string | null
  decimals: number
  collateralClass: number
  open: boolean
  discountBps: number
  qX18: NumericString
  floorQX18: NumericString
  capacityLeft: NumericString
  capacityPerEpoch: NumericString
  epochStart: NumericString
  epochSeconds: number
  vestSeconds: number
  issuedThisEpoch: NumericString
  totalIssued: NumericString
  accretionUsd18: NumericString
}

export interface BondsResponse {
  markets: readonly BondMarketRow[]
  recent: readonly {
    blockNumber: NumericString
    timestamp: NumericString
    txHash: Hex
    owner: Address
    marketId: number
    collateralAmount: NumericString
    ampsOut: NumericString
    discountBps: number
  }[]
}

// -----------------------------------------------------------------------------------------------
// `/api/gate`
// -----------------------------------------------------------------------------------------------

export interface GateStatusRow {
  poolId: Hex
  constituentId: number
  symbol: string | null
  gateState: number
  gateStateLabel: string
  session: number
  feedStale: boolean
  corporateFreeze: boolean
  diverged: boolean
  observedAt: NumericString
}

export interface GateResponse {
  status: readonly GateStatusRow[]
  transitions: readonly {
    blockNumber: NumericString
    timestamp: NumericString
    poolId: Hex
    previousState: number
    newState: number
  }[]
}

// -----------------------------------------------------------------------------------------------
// `/api/flywheel`
// -----------------------------------------------------------------------------------------------

/** One day of protocol-wide flow. */
export interface FlywheelDay {
  day: number
  sellVolumeAmps: NumericString
  buyVolumeAmps: NumericString
  /** AMPS collected as fees that day. */
  feeAmps: NumericString
  /** Counter asset collected as fees that day, in 18-decimal USD. */
  feeCounterUsd18: NumericString
  bondIssuedAmps: NumericString
  bondAccretionUsd18: NumericString
  burnedAmps: NumericString
  creatorPaidAmps: NumericString
  creatorPaidCounterUsd18: NumericString
  netSupplyChange: NumericString
}

/**
 * The flywheel dashboard, in one response. `staking` is gone from it: there is no reward stream to
 * report an APR on, and the AMPS side of every fee is burned rather than distributed.
 */
export interface FlywheelResponse {
  summary: VaultSummary | null
  bonds: {issued: NumericString; accretionUsd18: NumericString; markets: number}
  pools: readonly Pick<
    PoolRow,
    | 'id'
    | 'counter'
    | 'counterSymbol'
    | 'poolClassLabel'
    | 'feeRevenueUsd18'
    | 'realisedLvrUsd18'
    | 'ampsInLadder'
    | 'counterInLadder'
    | 'swapCount'
    | 'ladderFillBps'
    | 'sellVolumeAmps'
    | 'buyVolumeAmps'
    | 'sellFeeAmps'
    | 'buyFeeCounter'
    | 'rotationCreditedAmps'
  >[]
  days: readonly FlywheelDay[]
}

// -----------------------------------------------------------------------------------------------
// `/health`
// -----------------------------------------------------------------------------------------------

export interface IndexerHealth {
  ok: boolean
  chainId: number
  latestBlock: NumericString
  lagSeconds: number
  /** The indexer's own reconciliation of indexed NAV against a chain read. */
  navReconciled: boolean
}
