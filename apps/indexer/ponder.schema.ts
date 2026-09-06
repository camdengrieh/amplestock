// SPDX-License-Identifier: MIT

/**
 * The Amplestocks index.
 *
 * Conventions, applied everywhere:
 *
 * - **Event-log rows** are keyed `"<blockNumber>-<logIndex>"`, zero-padded so the text ordering is
 *   the chain ordering. `eventId()` in `src/lib/ids.ts` builds them; nothing constructs one inline.
 * - **Entity rows** (pools, constituents, markets, positions, cells) are keyed by their on-chain
 *   identity, lower-cased: a `PoolId` is the 32-byte hex, a constituent is its 1-based id as text,
 *   a ladder cell is `"<poolId>-<tickLower>"`.
 * - **Money.** AMPS is 18-decimal wei; USD is 18-decimal (`Usd18`) exactly as the vault's `A` is;
 *   Chainlink answers stay in the feed's own 8 decimals (`Usd8`); prices are `X18`. A raw counter
 *   amount keeps the counter's own decimals and is always paired with a `decimals` column or a
 *   pool row that carries one. Nothing is ever stored as a float except explicitly derived
 *   rates (`*Pct`, `*Apr`), which are disclosure only.
 * - **Enums** are stored as their on-chain ordinal *and* a decoded label, because
 *   `types/Types.sol` guarantees ordinals are ABI and only ever appended.
 * - **Nothing is derived twice.** Where a number can be read from chain, the reconciliation job
 *   reads it and records the divergence rather than the handlers pretending to recompute it.
 */

import {index, onchainTable, primaryKey} from 'ponder'

// -----------------------------------------------------------------------------------------------
// Vault — NAV, reference, supply
// -----------------------------------------------------------------------------------------------

/** One row per `NavCheckpoint`: `A`, `T` and NAV/share as the vault wrote them. */
export const navCheckpoint = onchainTable(
  'nav_checkpoint',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
    /** `(A + 1) * 1e18 / (T + VIRTUAL_SHARES)`, USD per AMPS. */
    navPerShareX18: t.bigint().notNull(),
    /** `A`, 18-decimal USD. */
    totalAssetsUsd18: t.bigint().notNull(),
    /** `T = Amps.totalSupply()`, fully diluted. */
    totalSupply: t.bigint().notNull(),
    /** Change in NAV/share since the previous checkpoint, in bps. Negative is a bleed. */
    navChangeBps: t.integer().notNull(),
  }),
  (table) => ({
    byBlock: index().on(table.blockNumber),
  }),
)

/** One row per `RefCheckpoint`: `P_ref`, `P_mkt` and the premium that follows from them. */
export const refCheckpoint = onchainTable(
  'ref_checkpoint',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
    pRefX18: t.bigint().notNull(),
    pMktX18: t.bigint().notNull(),
    /** The up-move was clipped by `refUpRateBps`. */
    rateLimited: t.boolean().notNull(),
    /** `P_ref` fell back to `navPerShareX18` (I24, or one of the three gate overrides). */
    navFloored: t.boolean().notNull(),
    /** NAV/share in force when this reference was written, from the preceding `NavCheckpoint`. */
    navPerShareX18: t.bigint().notNull(),
    /** `pRef * 1e18 / nav - 1e18`. Disclosure only; can be negative only through rounding. */
    premiumX18: t.bigint().notNull(),
    premiumBps: t.integer().notNull(),
  }),
  (table) => ({
    byBlock: index().on(table.blockNumber),
  }),
)

/** Shares by class, sampled at every checkpoint and at every reconciliation. */
export const sharePoint = onchainTable(
  'share_point',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    /** `Amps.totalSupply()`. */
    totalSupply: t.bigint().notNull(),
    /** `vault.inventoryAmps()`: protocol-owned AMPS, ERC-20 plus the ERC-6909 claim. */
    inventory: t.bigint().notNull(),
    /** AMPS still held by the team `VestingWallet`. */
    vesting: t.bigint().notNull(),
    /** AMPS held by `AmpsStaking` (the xAMPS assets). */
    staked: t.bigint().notNull(),
    /** AMPS held by `AmpsBonds` against unvested positions. */
    bondUnvested: t.bigint().notNull(),
    /** `totalSupply - inventory - vesting - staked - bondUnvested`. */
    circulating: t.bigint().notNull(),
    source: t.text().notNull(),
  }),
  (table) => ({
    byBlock: index().on(table.blockNumber),
  }),
)

/** The one-row vault summary the dApp's Vault page reads. */
export const vaultSummary = onchainTable('vault_summary', (t) => ({
  id: t.text().primaryKey(),
  vault: t.hex().notNull(),
  amps: t.hex().notNull(),
  registry: t.hex().notNull(),
  genesisAt: t.bigint().notNull(),
  genesisBlock: t.bigint().notNull(),
  creator: t.hex().notNull(),
  teamVestingWallet: t.hex().notNull(),
  genesisMinted: t.bigint().notNull(),
  genesisNavPerShareX18: t.bigint().notNull(),
  navPerShareX18: t.bigint().notNull(),
  totalAssetsUsd18: t.bigint().notNull(),
  totalSupply: t.bigint().notNull(),
  pRefX18: t.bigint().notNull(),
  pMktX18: t.bigint().notNull(),
  premiumBps: t.integer().notNull(),
  inventory: t.bigint().notNull(),
  vesting: t.bigint().notNull(),
  staked: t.bigint().notNull(),
  circulating: t.bigint().notNull(),
  /** Cumulative AMPS collected as fees and split at `compound()`. */
  feesAmpsTotal: t.bigint().notNull(),
  creatorPaidTotal: t.bigint().notNull(),
  stakerPaidTotal: t.bigint().notNull(),
  burnedTotal: t.bigint().notNull(),
  relaidTotal: t.bigint().notNull(),
  /** Cumulative AMPS burned, by any reason, including redemption inventory. */
  burnedAllTotal: t.bigint().notNull(),
  bondIssuedTotal: t.bigint().notNull(),
  redeemedSharesTotal: t.bigint().notNull(),
  vestingMintedTotal: t.bigint().notNull(),
  /** `S0 + bondIssued + vestingMinted - burnedAll`, i.e. net supply change since genesis. */
  netSupplyChange: t.bigint().notNull(),
  compoundCount: t.integer().notNull(),
  swapCount: t.integer().notNull(),
  lastBlock: t.bigint().notNull(),
  lastTimestamp: t.bigint().notNull(),
}))

/** Every `Redeem`: the floor exit. */
export const redemption = onchainTable(
  'redemption',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    owner: t.hex().notNull(),
    to: t.hex().notNull(),
    shares: t.bigint().notNull(),
    /** The vault's own AMPS (ERC-20 plus claim) burned alongside, ruling F. */
    inventoryBurned: t.bigint().notNull(),
    feeBps: t.integer().notNull(),
    /** NAV/share in force at the redemption block. */
    navPerShareX18: t.bigint().notNull(),
    /** `shares * nav * (BPS - feeBps) / BPS`, 18-decimal USD. Disclosure only. */
    grossUsd18: t.bigint().notNull(),
    feeUsd18: t.bigint().notNull(),
  }),
  (table) => ({byOwner: index().on(table.owner), byBlock: index().on(table.blockNumber)}),
)

/** Every `Burn`, with the `bytes32` reason decoded. */
export const burnEvent = onchainTable(
  'burn_event',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    amount: t.bigint().notNull(),
    reasonRaw: t.hex().notNull(),
    /** `"compound"`, `"buyback"`, `"redeem"`, … — the short string the vault packed. */
    reason: t.text().notNull(),
    /** The pool the burn belongs to, when the transaction identifies one. */
    poolId: t.hex(),
  }),
  (table) => ({byReason: index().on(table.reason), byBlock: index().on(table.blockNumber)}),
)

/** Every `VestingMinted`: the only non-bond mint after genesis. */
export const vestingMint = onchainTable('vesting_mint', (t) => ({
  id: t.text().primaryKey(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  txHash: t.hex().notNull(),
  to: t.hex().notNull(),
  amount: t.bigint().notNull(),
}))

// -----------------------------------------------------------------------------------------------
// Placements, ladder cells, compounds, rollouts
// -----------------------------------------------------------------------------------------------

/** One row per `Placement`, classified by what the transaction was doing. */
export const placement = onchainTable(
  'placement',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    poolId: t.hex().notNull(),
    /** True for an ask ladder (AMPS above the tick), false for a bid ladder. */
    above: t.boolean().notNull(),
    buckets: t.integer().notNull(),
    /** Token amount committed: AMPS wei for an ask, counter raw units for a bid. */
    amount: t.bigint().notNull(),
    anchorTick: t.integer().notNull(),
    /** `genesis` | `spokeSeed` | `compound` | `rollout` | `bonded` | `place` | `redeem` | `unknown`. */
    action: t.text().notNull(),
    /** The caller, from the transaction. */
    caller: t.hex().notNull(),
    /** Cells the matching `ModifyLiquidity` logs wrote in this transaction, for this pool. */
    cells: t.integer().notNull(),
    liquidityAdded: t.bigint().notNull(),
  }),
  (table) => ({byPool: index().on(table.poolId), byAction: index().on(table.action)}),
)

/**
 * One row per live grid cell per pool: the durable ladder record, rebuilt from the vault's own
 * `ModifyLiquidity` logs because `Placement` carries no per-cell data.
 *
 * `fillFraction`, `ampsRemaining` and `counterRaised` are recomputed from `liquidity`, the cell
 * bounds and the pool's live `sqrtPriceX96` at every swap that touches the pool — a v4 position
 * converts in place as the price crosses it (§3.4), so this *is* the fill and the proceeds.
 */
export const ladderCell = onchainTable(
  'ladder_cell',
  (t) => ({
    /** `"<poolId>-<tickLower>"`. */
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    /** `m - GRID_MIN_M`, in `[0, GRID_CELLS)`. `-1` when the pool's grid origin is not yet known. */
    cellIndex: t.integer().notNull(),
    /** `m`, the signed doubling index off the grid origin. */
    m: t.integer().notNull(),
    tickLower: t.integer().notNull(),
    tickUpper: t.integer().notNull(),
    /** Live position liquidity, tracked from the signed `ModifyLiquidity` deltas. */
    liquidity: t.bigint().notNull(),
    /** True while the cell is an ask; false once the price has converted it to a bid. */
    above: t.boolean().notNull(),
    /** Cumulative token added over the cell's life, in the placed side's units. Disclosure only. */
    principal: t.bigint().notNull(),
    /** AMPS still sitting in the cell at the pool's live price. */
    ampsRemaining: t.bigint().notNull(),
    /** Counter units the cell holds at the live price: what the ask has raised so far. */
    counterRaised: t.bigint().notNull(),
    /** `1 - ampsRemaining / ampsAtPlacement`, in bps. 10,000 = fully consumed. */
    fillBps: t.integer().notNull(),
    /** The AMPS the cell held when it was last (re-)placed, the denominator of `fillBps`. */
    ampsAtPlacement: t.bigint().notNull(),
    placedAt: t.bigint().notNull(),
    updatedAt: t.bigint().notNull(),
    removedAt: t.bigint(),
    /** The last action that wrote this cell. */
    lastAction: t.text().notNull(),
  }),
  (table) => ({byPool: index().on(table.poolId)}),
)

/** Every `ModifyLiquidity` by the vault on one of our pools. The audit trail behind `ladderCell`. */
export const liquidityChange = onchainTable(
  'liquidity_change',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    poolId: t.hex().notNull(),
    sender: t.hex().notNull(),
    tickLower: t.integer().notNull(),
    tickUpper: t.integer().notNull(),
    liquidityDelta: t.bigint().notNull(),
    salt: t.hex().notNull(),
    action: t.text().notNull(),
  }),
  (table) => ({byPool: index().on(table.poolId)}),
)

/** Every `Compound`: the four-way split of the AMPS-side fees. */
export const compoundEvent = onchainTable(
  'compound_event',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    poolId: t.hex().notNull(),
    caller: t.hex().notNull(),
    /** AMPS-side fees realised by this compound. */
    ampsFees: t.bigint().notNull(),
    creatorPaid: t.bigint().notNull(),
    stakerPaid: t.bigint().notNull(),
    burned: t.bigint().notNull(),
    relaid: t.bigint().notNull(),
    /** The creator slice in force, `CREATOR_FEE_BPS * max(0, 1 - (t - genesis)/decay)`. */
    creatorBps: t.integer().notNull(),
    /** NAV/share before and after, from the checkpoints either side. R1 allows a 2 bp bleed. */
    navBeforeX18: t.bigint().notNull(),
    navAfterX18: t.bigint().notNull(),
    navChangeBps: t.integer().notNull(),
    bountyPaidUsd18: t.bigint().notNull(),
  }),
  (table) => ({byPool: index().on(table.poolId), byBlock: index().on(table.blockNumber)}),
)

/** Every `rollout(constituentId)`: inventory moving from the entry pools into a spoke. */
export const rolloutEvent = onchainTable(
  'rollout_event',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    constituentId: t.integer().notNull(),
    caller: t.hex().notNull(),
    /** AMPS actually placed into the destination spoke. */
    moved: t.bigint().notNull(),
    /** AMPS withdrawn from the entry pools in the same transaction. */
    withdrawn: t.bigint().notNull(),
    toPoolId: t.hex().notNull(),
    fromPoolIds: t.jsonb().notNull(),
    bountyPaidUsd18: t.bigint().notNull(),
  }),
  (table) => ({byConstituent: index().on(table.constituentId)}),
)

// -----------------------------------------------------------------------------------------------
// Pools, swaps, per-pool aggregates
// -----------------------------------------------------------------------------------------------

/** One row per registered pool. The `PoolId` is the primary key everywhere in this schema. */
export const pool = onchainTable(
  'pool',
  (t) => ({
    id: t.hex().primaryKey(),
    counter: t.hex().notNull(),
    counterSymbol: t.text(),
    counterDecimals: t.integer().notNull(),
    /** `PoolClass` ordinal: 0 NONE, 1 ENTRY, 2 SPOKE, 3 SPOKE_HIGH_VOL. */
    poolClass: t.integer().notNull(),
    poolClassLabel: t.text().notNull(),
    constituentId: t.integer().notNull(),
    tickSpacing: t.integer().notNull(),
    /** `LadderLib.doublingTicks(tickSpacing)`. */
    doublingTicks: t.integer().notNull(),
    /** Origin of the canonical grid, from the price the pool actually opened at (ruling J). */
    gridBaseTick: t.integer(),
    buyFeeBps: t.integer().notNull(),
    feed: t.hex(),
    registeredAt: t.bigint().notNull(),
    registeredBlock: t.bigint().notNull(),
    openedAt: t.bigint(),
    openSqrtPriceX96: t.bigint(),
    openTick: t.integer(),
    /** Live pool state, refreshed on every indexed swap. */
    sqrtPriceX96: t.bigint().notNull(),
    tick: t.integer().notNull(),
    liquidity: t.bigint().notNull(),
    lastSwapAt: t.bigint().notNull(),
    /** `GateState` ordinal for this pool, from `OracleGate` / the vault. */
    gateState: t.integer().notNull(),
    gateStateLabel: t.text().notNull(),
    gateUpdatedAt: t.bigint().notNull(),
    diverged: t.boolean().notNull(),
    divergenceBps: t.integer().notNull(),
    /** Cumulative flow. AMPS legs in wei, counter legs in the counter's own decimals. */
    sellVolumeAmps: t.bigint().notNull(),
    buyVolumeAmps: t.bigint().notNull(),
    sellFeeAmps: t.bigint().notNull(),
    buyFeeCounter: t.bigint().notNull(),
    rotationCreditedAmps: t.bigint().notNull(),
    swapCount: t.integer().notNull(),
    /** Ladder totals, maintained from `ladderCell`. */
    askCells: t.integer().notNull(),
    bidCells: t.integer().notNull(),
    ampsInLadder: t.bigint().notNull(),
    counterInLadder: t.bigint().notNull(),
    ladderFillBps: t.integer().notNull(),
    /** The `tickLower` of every cell the vault has ever opened here, so the fill can be recomputed
     *  without a query. At most `GRID_CELLS` entries by construction (I39). */
    cellTicks: t.jsonb().notNull(),
    /** Realised LVR proxy in 18-decimal USD: see `src/lib/flywheel.ts`. */
    realisedLvrUsd18: t.bigint().notNull(),
    feeRevenueUsd18: t.bigint().notNull(),
  }),
  (table) => ({byClass: index().on(table.poolClass), byConstituent: index().on(table.constituentId)}),
)

/** Every v4 `Swap` on one of our pools, with the fee decomposed per §1.4. */
export const swap = onchainTable(
  'swap',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
    poolId: t.hex().notNull(),
    /** The `PoolManager`'s caller — the router, not the trader. */
    sender: t.hex().notNull(),
    /** The transaction's `from`. */
    origin: t.hex().notNull(),
    /** AMPS is `currency0` in all 32 pools, so `zeroForOne == true` is unconditionally a sell. */
    sell: t.boolean().notNull(),
    /** The swapper's deltas, exactly as v4 emitted them. */
    amount0: t.bigint().notNull(),
    amount1: t.bigint().notNull(),
    /** Positive input amount in the input currency's units. */
    amountIn: t.bigint().notNull(),
    amountOut: t.bigint().notNull(),
    /** AMPS moved by this swap, wei, whichever side it was on. */
    ampsAmount: t.bigint().notNull(),
    counterAmount: t.bigint().notNull(),
    sqrtPriceX96: t.bigint().notNull(),
    tick: t.integer().notNull(),
    liquidity: t.bigint().notNull(),
    /** The fee v4 actually charged, in hundredths of a bp, and the same number in bps. */
    feePips: t.integer().notNull(),
    feeBps: t.integer().notNull(),
    /** `sellFeeBps` or the pool's `buyFeeBps`, blended when a rotation credit applied. */
    baseFeeBps: t.integer().notNull(),
    /** `feeBps - baseFeeBps`, floored at zero: `f_vol + f_dev + f_div + f_session + surge`. */
    dynamicFeeBps: t.integer().notNull(),
    /** AMPS covered by the same-transaction rotation credit, from `RotationCreditConsumed`. */
    creditedAmount: t.bigint().notNull(),
    /** True when the base fee was blended down by a credit. */
    credited: t.boolean().notNull(),
    /** `amountIn * feePips / 1e6`, in the input currency's units. */
    feeAmount: t.bigint().notNull(),
    /** The fee in AMPS wei when this was a sell, else zero: the flywheel's revenue line. */
    feeAmps: t.bigint().notNull(),
    /** Notional in 18-decimal USD, priced at the checkpoint's `P_ref` for the AMPS leg. */
    notionalUsd18: t.bigint().notNull(),
    feeUsd18: t.bigint().notNull(),
  }),
  (table) => ({
    byPool: index().on(table.poolId),
    byBlock: index().on(table.blockNumber),
    byOrigin: index().on(table.origin),
  }),
)

/** Per-pool, per-UTC-day rollup. The flywheel dashboard's grain. */
export const poolDay = onchainTable(
  'pool_day',
  (t) => ({
    /** `"<poolId>-<dayStartUnix>"`. */
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    day: t.bigint().notNull(),
    sellVolumeAmps: t.bigint().notNull(),
    buyVolumeAmps: t.bigint().notNull(),
    volumeUsd18: t.bigint().notNull(),
    feeAmps: t.bigint().notNull(),
    feeUsd18: t.bigint().notNull(),
    creditedAmps: t.bigint().notNull(),
    swapCount: t.integer().notNull(),
    /** Sum of `|tick move| x liquidity`-implied LVR over the day, 18-decimal USD. */
    realisedLvrUsd18: t.bigint().notNull(),
    /** Average AMPS-side inventory value over the day, the APR denominator. */
    inventoryUsd18: t.bigint().notNull(),
    openTick: t.integer().notNull(),
    closeTick: t.integer().notNull(),
  }),
  (table) => ({byPool: index().on(table.poolId), byDay: index().on(table.day)}),
)

/** `RebalanceNeeded`: the hook's advisory that the pool has drifted past half the inner band. */
export const rebalanceSignal = onchainTable(
  'rebalance_signal',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    poolId: t.hex().notNull(),
    tick: t.integer().notNull(),
    fairTick: t.integer().notNull(),
    deviationTicks: t.integer().notNull(),
  }),
  (table) => ({byPool: index().on(table.poolId)}),
)

/** `SurgeArmed`, `MultiplierStepDetected`, `HighWaterAdvanced/Reset`, `GateCacheRefreshed`. */
export const hookEvent = onchainTable(
  'hook_event',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    poolId: t.hex().notNull(),
    kind: t.text().notNull(),
    data: t.jsonb().notNull(),
  }),
  (table) => ({byPool: index().on(table.poolId), byKind: index().on(table.kind)}),
)

// -----------------------------------------------------------------------------------------------
// Registry — constituents and index weights
// -----------------------------------------------------------------------------------------------

export const constituent = onchainTable(
  'constituent',
  (t) => ({
    /** The 1-based constituent id, as text. */
    id: t.text().primaryKey(),
    constituentId: t.integer().notNull(),
    token: t.hex().notNull(),
    symbol: t.text(),
    decimals: t.integer().notNull(),
    poolId: t.hex().notNull(),
    /** `ConstituentStatus` ordinal: 0 NONE, 1 ACTIVE, 2 RETIRED, 3 FROZEN. */
    status: t.integer().notNull(),
    statusLabel: t.text().notNull(),
    targetWeightBps: t.integer().notNull(),
    rolloutWeightBps: t.integer().notNull(),
    marketId: t.integer().notNull(),
    feed: t.hex(),
    addedAt: t.bigint().notNull(),
    addedBlock: t.bigint().notNull(),
    retiredAt: t.bigint(),
    reinstatedAt: t.bigint(),
    freezeUntil: t.bigint().notNull(),
    /** Latest polled issuer state. */
    uiMultiplierX18: t.bigint().notNull(),
    newUiMultiplierX18: t.bigint().notNull(),
    effectiveAt: t.bigint().notNull(),
    oraclePaused: t.boolean().notNull(),
    tokenPaused: t.boolean().notNull(),
    vaultBlocked: t.boolean().notNull(),
    lastPolledBlock: t.bigint().notNull(),
    /** Latest Chainlink answer the protocol accepted for this token, 8 decimals. */
    answerUsd8: t.bigint().notNull(),
    answerUpdatedAt: t.bigint().notNull(),
  }),
  (table) => ({byToken: index().on(table.token), byStatus: index().on(table.status)}),
)

/** Token address -> constituent id. Ponder's write API has `find` but no query, so the reverse
 *  lookup every feed and multiplier handler needs is materialised here rather than scanned. */
export const tokenIndex = onchainTable('token_index', (t) => ({
  /** The token address, lower-cased. */
  id: t.hex().primaryKey(),
  constituentId: t.integer().notNull(),
  poolId: t.hex().notNull(),
}))

/** The lifecycle log: added / retired / reinstated / reconfigured / frozen. */
export const constituentEvent = onchainTable(
  'constituent_event',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    constituentId: t.integer().notNull(),
    kind: t.text().notNull(),
    field: t.text(),
    previousValue: t.bigint(),
    newValue: t.bigint(),
  }),
  (table) => ({byConstituent: index().on(table.constituentId)}),
)

/** Every `setIndexWeights` call, as one row per vector. */
export const indexWeights = onchainTable('index_weights', (t) => ({
  id: t.text().primaryKey(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  txHash: t.hex().notNull(),
  ids: t.jsonb().notNull(),
  weightsBps: t.jsonb().notNull(),
}))

// -----------------------------------------------------------------------------------------------
// Gate and feeds
// -----------------------------------------------------------------------------------------------

/** Per-pool gate state, plus the protocol-wide watchdog and freeze flags. */
export const gateStatus = onchainTable('gate_status', (t) => ({
  /** The `PoolId`, or `"protocol"` for the process-wide row. */
  id: t.text().primaryKey(),
  poolId: t.hex(),
  state: t.integer().notNull(),
  stateLabel: t.text().notNull(),
  diverged: t.boolean().notNull(),
  divergenceBps: t.integer().notNull(),
  watchdogTripped: t.boolean().notNull(),
  watchdogElapsed: t.integer().notNull(),
  protocolFreezeUntil: t.bigint().notNull(),
  updatedAt: t.bigint().notNull(),
  updatedBlock: t.bigint().notNull(),
}))

/** Every gate transition, from both `OracleGate.GateChanged` and `AmpsVault.GateChanged`. */
export const gateTransition = onchainTable(
  'gate_transition',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    poolId: t.hex().notNull(),
    source: t.text().notNull(),
    previousState: t.integer().notNull(),
    newState: t.integer().notNull(),
    previousLabel: t.text().notNull(),
    newLabel: t.text().notNull(),
  }),
  (table) => ({byPool: index().on(table.poolId)}),
)

/** Watchdog stamps/trips, divergence latches, corporate-action and guardian freezes. */
export const gateEvent = onchainTable(
  'gate_event',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    kind: t.text().notNull(),
    poolId: t.hex(),
    constituentId: t.integer(),
    data: t.jsonb().notNull(),
  }),
  (table) => ({byKind: index().on(table.kind)}),
)

/** One row per configured feed. */
export const feed = onchainTable('feed', (t) => ({
  /** The *token* the feed prices, lower-cased. */
  id: t.hex().primaryKey(),
  token: t.hex().notNull(),
  aggregator: t.hex().notNull(),
  previousAggregator: t.hex(),
  heartbeat: t.integer().notNull(),
  thresholdBps: t.integer().notNull(),
  minAnswerUsd8: t.bigint().notNull(),
  maxAnswerUsd8: t.bigint().notNull(),
  answerUsd8: t.bigint().notNull(),
  updatedAt: t.bigint().notNull(),
  roundId: t.bigint().notNull(),
  standardProxy: t.boolean().notNull(),
  lastBlock: t.bigint().notNull(),
}))

/** Every accepted answer, from `FeedRegistry.AnswerLatched` and (where visible) `AnswerUpdated`. */
export const feedAnswer = onchainTable(
  'feed_answer',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    token: t.hex(),
    aggregator: t.hex(),
    answerUsd8: t.bigint().notNull(),
    updatedAt: t.bigint().notNull(),
    roundId: t.bigint().notNull(),
    /** `latched` (the protocol accepted it) or `aggregator` (the raw Chainlink round). */
    source: t.text().notNull(),
    /** Move from the previous accepted answer, in bps. */
    changeBps: t.integer().notNull(),
  }),
  (table) => ({byToken: index().on(table.token), byBlock: index().on(table.blockNumber)}),
)

/** `AnswerJumpPending`: a jump above `ANSWER_JUMP_BPS` held back by the two-confirmation rule. */
export const feedJump = onchainTable('feed_jump', (t) => ({
  id: t.text().primaryKey(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  txHash: t.hex().notNull(),
  token: t.hex().notNull(),
  previousAnswerUsd8: t.bigint().notNull(),
  pendingAnswerUsd8: t.bigint().notNull(),
  roundId: t.bigint().notNull(),
  jumpBps: t.integer().notNull(),
}))

/** The `uiMultiplier()` state-diff series: one row per *change*, never one per poll. */
export const multiplierPoint = onchainTable(
  'multiplier_point',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    constituentId: t.integer().notNull(),
    token: t.hex().notNull(),
    previousMultiplierX18: t.bigint().notNull(),
    multiplierX18: t.bigint().notNull(),
    newMultiplierX18: t.bigint().notNull(),
    effectiveAt: t.bigint().notNull(),
    oraclePaused: t.boolean().notNull(),
    tokenPaused: t.boolean().notNull(),
    /** `(m - prev) * 10_000 / prev`, signed. A dividend reinvestment is +10 to +100. */
    deltaBps: t.integer().notNull(),
    /** `poll` (the block job) or `hook` (`MultiplierStepDetected` seen in `afterSwap`). */
    source: t.text().notNull(),
    /** What changed: any of `multiplier`, `scheduled`, `oraclePaused`, `paused`, joined by `+`. */
    changed: t.text().notNull(),
  }),
  (table) => ({byConstituent: index().on(table.constituentId)}),
)

// -----------------------------------------------------------------------------------------------
// Bonds
// -----------------------------------------------------------------------------------------------

export const bondMarket = onchainTable(
  'bond_market',
  (t) => ({
    /** The market id, as text. */
    id: t.text().primaryKey(),
    marketId: t.integer().notNull(),
    collateral: t.hex().notNull(),
    collateralSymbol: t.text(),
    collateralDecimals: t.integer().notNull(),
    /** `CollateralClass` ordinal: 0 CONSTITUENT, 1 ENTRY. */
    collateralClass: t.integer().notNull(),
    collateralClassLabel: t.text().notNull(),
    constituentId: t.integer().notNull(),
    open: t.boolean().notNull(),
    dBaseBps: t.integer().notNull(),
    dMinBps: t.integer().notNull(),
    dMaxBps: t.integer().notNull(),
    capBpsPerEpoch: t.integer().notNull(),
    kWeightX18: t.bigint().notNull(),
    kFillX18: t.bigint().notNull(),
    epochStart: t.bigint().notNull(),
    issuedThisEpoch: t.bigint().notNull(),
    totalIssued: t.bigint().notNull(),
    totalCollateral: t.bigint().notNull(),
    /** Cumulative NAV/share uplift attributable to this market, 18-decimal USD. */
    accretionUsd18: t.bigint().notNull(),
    bondCount: t.integer().notNull(),
    lastBondAt: t.bigint().notNull(),
    lastDiscountBps: t.integer().notNull(),
    createdAt: t.bigint().notNull(),
  }),
  (table) => ({byConstituent: index().on(table.constituentId), byOpen: index().on(table.open)}),
)

export const bondPurchase = onchainTable(
  'bond_purchase',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    buyer: t.hex().notNull(),
    marketId: t.integer().notNull(),
    collateral: t.hex().notNull(),
    /** Raw collateral units, in the collateral's own decimals. */
    amountIn: t.bigint().notNull(),
    ampsOut: t.bigint().notNull(),
    positionId: t.bigint().notNull(),
    /** AMPS wei per 1e18 of collateral, as priced. */
    qX18: t.bigint().notNull(),
    discountBps: t.integer().notNull(),
    /** True when `qFloor` bound rather than `qMarket`: the NAV floor did the pricing. */
    floorBinding: t.boolean().notNull(),
    navBeforeX18: t.bigint().notNull(),
    navAfterX18: t.bigint().notNull(),
    /** `(navAfter - navBefore) * totalSupply / 1e18`, 18-decimal USD. I27 makes this `>= 0`. */
    accretionUsd18: t.bigint().notNull(),
    accretionBps: t.integer().notNull(),
  }),
  (table) => ({byMarket: index().on(table.marketId), byBuyer: index().on(table.buyer)}),
)

export const bondPosition = onchainTable(
  'bond_position',
  (t) => ({
    /** `"<owner>-<positionId>"`. */
    id: t.text().primaryKey(),
    owner: t.hex().notNull(),
    positionId: t.bigint().notNull(),
    marketId: t.integer().notNull(),
    collateral: t.hex().notNull(),
    principal: t.bigint().notNull(),
    claimed: t.bigint().notNull(),
    start: t.bigint().notNull(),
    vestSeconds: t.integer().notNull(),
    fullyClaimed: t.boolean().notNull(),
    lastClaimAt: t.bigint(),
  }),
  (table) => ({byOwner: index().on(table.owner), byMarket: index().on(table.marketId)}),
)

export const bondClaim = onchainTable(
  'bond_claim',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    owner: t.hex().notNull(),
    positionId: t.bigint().notNull(),
    to: t.hex().notNull(),
    amount: t.bigint().notNull(),
  }),
  (table) => ({byOwner: index().on(table.owner)}),
)

/** Issuance and realised accretion per market per epoch. */
export const bondEpoch = onchainTable(
  'bond_epoch',
  (t) => ({
    /** `"<marketId>-<epochStart>"`. */
    id: t.text().primaryKey(),
    marketId: t.integer().notNull(),
    epochStart: t.bigint().notNull(),
    epochEnd: t.bigint(),
    issued: t.bigint().notNull(),
    collateralIn: t.bigint().notNull(),
    accretionUsd18: t.bigint().notNull(),
    bondCount: t.integer().notNull(),
    minDiscountBps: t.integer().notNull(),
    maxDiscountBps: t.integer().notNull(),
    floorBindingCount: t.integer().notNull(),
  }),
  (table) => ({byMarket: index().on(table.marketId)}),
)

/** Issuance and realised accretion per market per UTC day. */
export const bondDay = onchainTable(
  'bond_day',
  (t) => ({
    /** `"<marketId>-<dayStartUnix>"`. */
    id: t.text().primaryKey(),
    marketId: t.integer().notNull(),
    day: t.bigint().notNull(),
    issued: t.bigint().notNull(),
    collateralIn: t.bigint().notNull(),
    accretionUsd18: t.bigint().notNull(),
    bondCount: t.integer().notNull(),
    avgDiscountBps: t.integer().notNull(),
  }),
  (table) => ({byMarket: index().on(table.marketId), byDay: index().on(table.day)}),
)

// -----------------------------------------------------------------------------------------------
// Staking
// -----------------------------------------------------------------------------------------------

export const stakingState = onchainTable('staking_state', (t) => ({
  id: t.text().primaryKey(),
  staking: t.hex().notNull(),
  totalAssets: t.bigint().notNull(),
  totalSupply: t.bigint().notNull(),
  /** `convertToAssets(1e18)`: xAMPS share price. */
  sharePriceX18: t.bigint().notNull(),
  rewardStreamSeconds: t.integer().notNull(),
  streamEnd: t.bigint().notNull(),
  rewardsTotal: t.bigint().notNull(),
  /** Rewards notified in the trailing 24 h and the APR that implies. */
  rewards24h: t.bigint().notNull(),
  aprBps: t.integer().notNull(),
  updatedAt: t.bigint().notNull(),
  updatedBlock: t.bigint().notNull(),
}))

export const stakingReward = onchainTable(
  'staking_reward',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    amount: t.bigint().notNull(),
    streamEnd: t.bigint().notNull(),
    /** xAMPS assets at the moment of notification, the APR denominator. */
    totalAssets: t.bigint().notNull(),
  }),
  (table) => ({byBlock: index().on(table.blockNumber)}),
)

// -----------------------------------------------------------------------------------------------
// Keeper, bounty
// -----------------------------------------------------------------------------------------------

/** Every `BountyPaid`, plus the pot's funding and sweeps. */
export const bountyPayment = onchainTable(
  'bounty_payment',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    kind: t.text().notNull(),
    to: t.hex().notNull(),
    workValueUsd18: t.bigint().notNull(),
    paidUsd18: t.bigint().notNull(),
    paidRaw: t.bigint().notNull(),
    reasonRaw: t.hex().notNull(),
    reason: t.text().notNull(),
  }),
  (table) => ({byTo: index().on(table.to), byKind: index().on(table.kind)}),
)

/**
 * One row per keeper-shaped transaction: `compound`, `rollout`, `deployBonded`, `touch`,
 * `checkpoint`, `withdrawRetiredBids`, `place`. Classified from the transaction's selector against
 * the vault, with the events it produced as the outcome.
 */
export const keeperJob = onchainTable(
  'keeper_job',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    job: t.text().notNull(),
    caller: t.hex().notNull(),
    poolId: t.hex(),
    constituentId: t.integer(),
    /** `ok` when the job produced the events it should have, `noop` when it produced none. */
    outcome: t.text().notNull(),
    bountyPaidUsd18: t.bigint().notNull(),
    detail: t.jsonb().notNull(),
  }),
  (table) => ({byJob: index().on(table.job), byBlock: index().on(table.blockNumber)}),
)

// -----------------------------------------------------------------------------------------------
// Governance parameters
// -----------------------------------------------------------------------------------------------

/** Latest value of every governed parameter, keyed `"<scope>:<name>"` (+ pool id where scoped). */
export const parameterState = onchainTable(
  'parameter_state',
  (t) => ({
    id: t.text().primaryKey(),
    scope: t.text().notNull(),
    name: t.text().notNull(),
    poolId: t.hex(),
    marketId: t.integer(),
    value: t.bigint(),
    addressValue: t.hex(),
    previousValue: t.bigint(),
    previousAddress: t.hex(),
    updatedAt: t.bigint().notNull(),
    updatedBlock: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({byScope: index().on(table.scope)}),
)

/** The append-only history behind `parameterState`. */
export const parameterChange = onchainTable(
  'parameter_change',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    scope: t.text().notNull(),
    name: t.text().notNull(),
    poolId: t.hex(),
    marketId: t.integer(),
    previousValue: t.bigint(),
    newValue: t.bigint(),
    previousAddress: t.hex(),
    newAddress: t.hex(),
  }),
  (table) => ({byScope: index().on(table.scope)}),
)

// -----------------------------------------------------------------------------------------------
// Alarms and reconciliation
// -----------------------------------------------------------------------------------------------

/**
 * The denylist alarm. A row exists for every observation of the beacon-level denylist: a
 * `blockAccounts(address[])` (`0x6abf7081`) transaction, its `unblockAccounts` counterpart, and any
 * `isBlocked(vault) == true` the constituent poll finds.
 */
export const denylistAlarm = onchainTable(
  'denylist_alarm',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex(),
    /** `call` (a transaction carrying the selector) or `probe` (the poll found `isBlocked`). */
    detection: t.text().notNull(),
    /** The contract the call was addressed to, or the token that answered `isBlocked`. */
    target: t.hex().notNull(),
    caller: t.hex(),
    selector: t.hex(),
    /** The decoded `address[]` argument, or the probed account. */
    accounts: t.jsonb().notNull(),
    /** True when one of the addresses is the vault, the PoolManager or a protocol contract. */
    touchesProtocol: t.boolean().notNull(),
    constituentId: t.integer(),
    severity: t.text().notNull(),
    /** True once the alert sink accepted it. */
    delivered: t.boolean().notNull(),
  }),
  (table) => ({byBlock: index().on(table.blockNumber), byTarget: index().on(table.target)}),
)

/**
 * One row per reconciliation run: the indexed value, the chain read at the same block, and the
 * divergence. `ok` is false as soon as any divergence exceeds the dust bound.
 */
export const reconciliation = onchainTable(
  'reconciliation',
  (t) => ({
    /** `"<blockNumber>"` — at most one run per block. */
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    trigger: t.text().notNull(),
    navIndexedX18: t.bigint().notNull(),
    navOnChainX18: t.bigint().notNull(),
    navDeltaWei: t.bigint().notNull(),
    navDeltaBps: t.integer().notNull(),
    /** `previewNavPerShareX18()`: NAV/share if a checkpoint were taken right now. */
    navPreviewX18: t.bigint().notNull(),
    previewDeltaBps: t.integer().notNull(),
    pRefIndexedX18: t.bigint().notNull(),
    pRefOnChainX18: t.bigint().notNull(),
    pRefDeltaWei: t.bigint().notNull(),
    pRefDeltaBps: t.integer().notNull(),
    supplyIndexed: t.bigint().notNull(),
    supplyOnChain: t.bigint().notNull(),
    supplyDeltaWei: t.bigint().notNull(),
    inventoryIndexed: t.bigint().notNull(),
    inventoryOnChain: t.bigint().notNull(),
    inventoryDeltaWei: t.bigint().notNull(),
    assetsIndexedUsd18: t.bigint().notNull(),
    assetsOnChainUsd18: t.bigint().notNull(),
    assetsDeltaBps: t.integer().notNull(),
    dustBps: t.integer().notNull(),
    dustWei: t.bigint().notNull(),
    ok: t.boolean().notNull(),
    /** Which fields breached, joined by `+`; empty when `ok`. */
    breached: t.text().notNull(),
  }),
  (table) => ({byBlock: index().on(table.blockNumber), byOk: index().on(table.ok)}),
)

/** Every alert the indexer raised, whatever the sink did with it. */
export const alert = onchainTable(
  'alert',
  (t) => ({
    id: t.text().primaryKey(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    /** `denylist` | `reconciliation` | `gate` | `nav-bleed` | `corporate-action`. */
    kind: t.text().notNull(),
    severity: t.text().notNull(),
    subject: t.text().notNull(),
    message: t.text().notNull(),
    detail: t.jsonb().notNull(),
    delivered: t.boolean().notNull(),
    deliveryError: t.text(),
  }),
  (table) => ({byKind: index().on(table.kind), bySeverity: index().on(table.severity)}),
)

// -----------------------------------------------------------------------------------------------
// Internal scratch
// -----------------------------------------------------------------------------------------------

/**
 * Rotation credits consumed in `beforeSwap`, parked until the `Swap` log that follows them in the
 * same transaction picks them up. The hook's log always precedes the `PoolManager`'s, because v4
 * calls `beforeSwap` before it swaps and emits.
 */
export const pendingCredit = onchainTable('pending_credit', (t) => ({
  /** `"<txHash>-<poolId>"`. */
  id: t.text().primaryKey(),
  consumed: t.bigint().notNull(),
  blendedFeeBps: t.integer().notNull(),
  logIndex: t.integer().notNull(),
  blockNumber: t.bigint().notNull(),
}))

/**
 * Whatever a handler needs to remember across events without a natural home: the last
 * `NavCheckpoint` values, the last observed `sellFeeBps`, the reconciliation cursor.
 */
export const indexerState = onchainTable('indexer_state', (t) => ({
  id: t.text().primaryKey(),
  value: t.bigint().notNull(),
  text: t.text(),
  updatedBlock: t.bigint().notNull(),
}))

/** Composite-keyed daily rollup of the whole flywheel, for the dashboard's headline series. */
export const flywheelDay = onchainTable(
  'flywheel_day',
  (t) => ({
    day: t.bigint().notNull(),
    /** Sell-fee revenue in AMPS wei and in 18-decimal USD. */
    sellFeeAmps: t.bigint().notNull(),
    sellFeeUsd18: t.bigint().notNull(),
    buyFeeUsd18: t.bigint().notNull(),
    bondIssued: t.bigint().notNull(),
    bondAccretionUsd18: t.bigint().notNull(),
    burned: t.bigint().notNull(),
    stakerPaid: t.bigint().notNull(),
    creatorPaid: t.bigint().notNull(),
    relaid: t.bigint().notNull(),
    redeemedShares: t.bigint().notNull(),
    netSupplyChange: t.bigint().notNull(),
    realisedLvrUsd18: t.bigint().notNull(),
    navOpenX18: t.bigint().notNull(),
    navCloseX18: t.bigint().notNull(),
    premiumCloseBps: t.integer().notNull(),
    swapCount: t.integer().notNull(),
  }),
  (table) => ({pk: primaryKey({columns: [table.day]})}),
)
