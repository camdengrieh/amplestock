// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Types.sol
//
// Every enum and packed struct shared by more than one Amplestocks contract. Nothing here has behaviour: the file
// exists so that the vault, the bonds shell, the registry, the gate, the policies and the hook all agree on the
// same bit layouts and the same ordinals. Declarations are file-level, so consumers import exactly what they use:
//
//     import {GateState, Session, Checkpoint} from "../types/Types.sol";
//
// PACKING DISCIPLINE. Every struct below documents the slot it occupies and the bit range of each field, because
// several of them are written on hot paths (`beforeSwap`, `bond`, `checkpoint`) where a second SSTORE is the
// difference between a viable and an unviable gas budget. Solidity packs struct fields in declaration order, low
// bits first, and starts a new slot when the next field does not fit. Do not reorder a field without re-deriving
// the layout comment: the layouts are asserted by `test/unit/Layout.t.sol` and by the gas baselines.
//
// ENUM ORDINALS ARE ABI. The indexer, the dApp and `packages/config` all depend on the numeric value of every enum
// member. Members are only ever appended, never reordered or removed; an obsolete member stays in place. `Session`
// doubles as an index into the four-element `h_session` and inner-band tables, so its ordering is also load-bearing
// in-contract: it is monotone non-decreasing in "closedness" (invariant I19).
//
// PHASE 3. `docs/phase3-state-model.md` §10 rulings 1, 4 and 14 add three things here and nothing else: `PoolConfig`
// gains `gridBaseTick` (the canonical doubling grid's origin, ruling 14); `HookPoolState` becomes the *memory view*
// `AmpsHook.poolState()` assembles from its three packed words rather than a storage layout, and gains the fields
// that view was missing (ruling 4); and the placement path gains `PlaceParams`, `Placed` and `GridCell`. No existing
// field moved: `PoolConfig`'s new field is appended (it starts a second slot, which is append-only for a struct held
// in a mapping), and `HookPoolState` is memory-only so its shape is free.

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// -----------------------------------------------------------------------------------------------------------------
// Enums
// -----------------------------------------------------------------------------------------------------------------

/// @notice The oracle/liveness gate's verdict for one pool or one constituent (layers A-F of the design).
/// @dev Ordering is *not* a severity ladder — several states can be true at once and the gate reports the most
///      restrictive one for the path being checked. What each state permits is fixed by the design:
///
///      | State             | swaps | placements / compound | bonds                  | redemption |
///      |-------------------|-------|-----------------------|------------------------|------------|
///      | GREEN             | yes   | yes                   | yes                    | yes        |
///      | DEGRADED          | yes   | no                    | yes, at `h_session`    | yes        |
///      | DIVERGED          | yes   | no                    | no (that pool only)    | yes        |
///      | REF_DIVERGED      | yes   | yes, anchored at NAV  | yes, priced at `q_floor` | yes      |
///      | SCHEDULED_FREEZE  | yes   | no                    | no (that constituent)  | yes        |
///      | WATCHDOG          | yes   | no                    | yes, at `h_session`    | yes        |
///
///      Redemption is `yes` in every row by construction, not by policy: `redeemProRata` never reads the gate.
enum GateState {
    /// @dev Everything fresh, in-session or safely stale, no divergence: all paths open.
    GREEN,
    /// @dev A feed is stale beyond its session-scaled `maxAge`, or the session is closed: placements and
    ///      compounding pause, bonds continue at the session haircut, the hook's dynamic cap rises to DEGRADED.
    DEGRADED,
    /// @dev Layer E: `|poolTick - fairTick|` beyond `divergenceBps` sustained for `divergenceSustainSeconds`.
    ///      Scoped to the one pool. Swaps continue and band widths are unchanged (I19).
    DIVERGED,
    /// @dev Layer F: the `AMPS/USDG` hub TWAP and `AMPS/WETH x ETH/USD` disagree by more than `refDivergenceBps`,
    ///      or the reference is otherwise untrustworthy. `P_ref` falls back to `navPerShare`; nothing else changes.
    REF_DIVERGED,
    /// @dev Layer D: `oraclePaused()` is true for a constituent, or its `effectiveAt` is within
    ///      `corporateActionWindow` of now. No placements, no compounding, no bonds for that constituent, and
    ///      never a tick shift.
    SCHEDULED_FREEZE,
    /// @dev Layer A: no block or no observation for longer than `GRACE`, i.e. the sequencer-uptime substitute has
    ///      tripped. Treated like DEGRADED plus a NAV-anchored reference.
    WATCHDOG
}

/// @notice The US equity trading session, derived from the on-chain 24/5 ET calendar (layer B).
/// @dev The ordinals index the four-element governed tables `h_session[4]` (bond haircuts) and the hook's inner
///      band widths, so the ordering must stay monotone non-decreasing in closedness: invariant I19 asserts that
///      band width never *narrows* as this value increases.
enum Session {
    /// @dev 09:30-16:00 ET on a trading day.
    REGULAR,
    /// @dev 04:00-09:30 and 16:00-20:00 ET on a trading day.
    PRE_POST,
    /// @dev 20:00-04:00 ET between two trading days.
    OVERNIGHT,
    /// @dev Weekends and holidays: the equity feeds hold Friday's close.
    CLOSED
}

/// @notice Lifecycle state of an index constituent inside `PoolRegistry` (Decision 19).
/// @dev `NONE` is the zero value, so an unwritten slot reads as "not a constituent". A pool is never deleted (v4
///      cannot), so `RETIRED` is terminal-until-reinstated rather than a removal. `FROZEN` is the guardian's
///      disable-only state and auto-expires at `freezeUntil`; a frozen constituent is still `ACTIVE` for the
///      purposes of NAV and redemption.
enum ConstituentStatus {
    /// @dev Never registered, or an out-of-range id.
    NONE,
    /// @dev Registered and live: bondable, rollout-eligible, placements allowed.
    ACTIVE,
    /// @dev Retired by the 7-day timelock: bond market closed, rollout weight zero, unfilled asks returned to the
    ///      entry pools, bids left in place as an exit market. NAV/share is unchanged by the action (I37).
    RETIRED,
    /// @dev Guardian-frozen until `ConstituentConfig.freezeUntil` (at most `GUARDIAN_FREEZE_MAX_SECONDS` ahead).
    ///      No bonds, no rollout, no placements. Swaps and redemption are unaffected.
    FROZEN
}

/// @notice What a bond collateral is and where its proceeds go (Decision 20).
enum CollateralClass {
    /// @dev A registered constituent Stock Token. Proceeds are settled into that spoke's ERC-6909 claim and become
    ///      the spoke's bid ladder at the next placement.
    CONSTITUENT,
    /// @dev WETH or USDG. Proceeds go to the entry pools' bids. Present in the bytecode from v1 but closed at
    ///      launch (`BondMarket.open == false`); opening it is a governance action, not a code change.
    ENTRY
}

/// @notice Fee bucket of a pool. Fixes which buy-fee band and which band-widening rules apply.
/// @dev Not named in the plan's enum list but required by `buyFeeBps[poolClass]` and by the hook's band rules
///      (entry pools have no session widening and a 2000-tick outer rail; spokes widen by session and use
///      `max(3 x innerBand, 800)`). `NONE` is the zero value so an unregistered pool cannot masquerade as an entry
///      pool.
enum PoolClass {
    /// @dev Not registered.
    NONE,
    /// @dev `AMPS/WETH` or `AMPS/USDG`: 24/7 legs, buy fee band [5, 100] bp, default 30 bp.
    ENTRY,
    /// @dev `AMPS/<stock>`: buy fee band [1, 50] bp, default 5 bp.
    SPOKE,
    /// @dev A spoke whose annualised volatility exceeds the high-sigma threshold: same band, default 10 bp.
    SPOKE_HIGH_VOL
}

// -----------------------------------------------------------------------------------------------------------------
// Packed structs
// -----------------------------------------------------------------------------------------------------------------

/// @notice `PoolRegistry`'s record for one of the 32 pools, keyed by `PoolId`. One slot.
/// @dev Bit layout (slot +0):
///      ```
///      [  0..159] address counter          currency1 of the pool (WETH9, USDG or a Stock Token)
///      [160..167] PoolClass poolClass      ENTRY | SPOKE | SPOKE_HIGH_VOL; NONE means unregistered
///      [168..175] uint8   counterDecimals  6 for USDG, 18 for WETH and Stock Tokens
///      [176..199] int24   tickSpacing      the pool's configured spacing
///      [200..215] uint16  buyFeeBps        base fee on AMPS-out swaps, inside the class's band
///      [216..231] uint16  constituentId    1-based index into the constituent array; 0 for the entry pools
///      [232..239] bool    registered       true once `beforeInitialize` has accepted the pool
///      [240..255] (free)
///
///      slot +1                                                                              Phase 3, ruling 14
///      [  0.. 23] int24   gridBaseTick     origin of the pool's canonical doubling grid
///      [ 24..255] (free)
///      ```
///      `gridBaseTick` is appended, not squeezed into slot +0's last 16 bits, because it is an `int24`. Appending
///      starts a second slot for the struct; every field above keeps its slot and its bit range, which is what the
///      append-only rule protects. It costs one extra cold SLOAD in {IPoolRegistry-poolConfig}, paid by
///      `AmpsHook.afterInitialize` (once per pool, ever) and by `LadderPositionValuer.valuePool` (once per pool per
///      NAV read) — never on a swap.
///
///      **What it is.** `docs/phase3-state-model.md` §3.2: every vault position in a pool lies on that pool's
///      canonical doubling grid, cell `m` covering `[gridBaseTick + m*D, gridBaseTick + (m+1)*D)` with
///      `D = LadderLib.doublingTicks(tickSpacing)` and `m` in `[Constants.GRID_MIN_M, Constants.GRID_MAX_M)`. The
///      grid is what makes placements merge by cell instead of accumulating, bounds `redeemProRata`'s work at
///      `GRID_CELLS` positions per pool, and lets `LadderPositionValuer` enumerate the vault's positions by
///      `extsload` without a ladder getter (invariant I39). The registry writes it when it opens the pool, from the
///      initial price: `PriceLib.alignTick(sqrtPriceX96ToTick(sqrtPriceX96), tickSpacing, true)`. The hook mirrors
///      the same value into its own CONFIG word at `afterInitialize`; the registry is the copy the valuer reads.
/// @param counter The pool's `currency1`. AMPS is `currency0` in all 32 pools by construction.
/// @param poolClass The fee bucket and band regime.
/// @param counterDecimals ERC-20 decimals of `counter`, cached so `PriceLib` calls need no external read.
/// @param tickSpacing The pool's tick spacing.
/// @param buyFeeBps Base fee charged on `zeroForOne == false` (AMPS out) swaps.
/// @param constituentId 1-based constituent id, or 0 for an entry pool.
/// @param registered Whether the pool has been initialised through the hook.
/// @param gridBaseTick Origin of the pool's canonical doubling grid, spacing-aligned upward from the opening tick.
struct PoolConfig {
    address counter;
    PoolClass poolClass;
    uint8 counterDecimals;
    int24 tickSpacing;
    uint16 buyFeeBps;
    uint16 constituentId;
    bool registered;
    int24 gridBaseTick;
}

/// @notice `PoolRegistry`'s per-constituent record, keyed by 1-based id. Two slots.
/// @dev Bit layout:
///      ```
///      slot +0
///      [  0..159] address           token                Stock Token address
///      [160..167] ConstituentStatus status               NONE | ACTIVE | RETIRED | FROZEN
///      [168..175] uint8             decimals             18 for every Stock Token seen so far
///      [176..191] uint16            targetWeightBps      index target weight, inside [floor_n, cap_n]
///      [192..207] uint16            rolloutWeightBps     share of `rolloutBpsPerDay` this name receives; 0 when retired
///      [208..223] uint16            hSessionOverrideBps  per-constituent bond haircut override
///      [224..231] bool              hSessionOverrideSet  false => use the global `h_session[session]`
///      [232..239] bool              caFreezeOverride     governance-forced corporate-action freeze
///      [240..255] uint16            marketId             1-based bond market id; 0 when no market exists
///
///      slot +1
///      [  0..159] address           feed                 Chainlink Standard (never SVR) proxy for `token`
///      [160..191] uint32            freezeUntil          guardian freeze expiry; 0 when not frozen
///      [192..223] uint32            addedAt              timestamp of `addConstituent`
///      [224..255] uint32            retiredAt            timestamp of the last `retireConstituent`; 0 if never
///      ```
/// @param token The Stock Token.
/// @param status Lifecycle state.
/// @param decimals ERC-20 decimals of `token`.
/// @param targetWeightBps The index target weight in bps of the whole index.
/// @param rolloutWeightBps The share of the daily rollout budget this constituent receives.
/// @param hSessionOverrideBps Per-constituent stale-feed haircut, used only when `hSessionOverrideSet`.
/// @param hSessionOverrideSet Whether `hSessionOverrideBps` replaces the global table.
/// @param caFreezeOverride Governance-forced corporate-action freeze, independent of `oraclePaused()`.
/// @param marketId The 1-based `AmpsBonds` market id for this constituent, or 0.
/// @param feed The Chainlink aggregator for `token`.
/// @param freezeUntil Guardian freeze expiry timestamp.
/// @param addedAt When the constituent was added.
/// @param retiredAt When the constituent was last retired.
struct ConstituentConfig {
    address token;
    ConstituentStatus status;
    uint8 decimals;
    uint16 targetWeightBps;
    uint16 rolloutWeightBps;
    uint16 hSessionOverrideBps;
    bool hSessionOverrideSet;
    bool caFreezeOverride;
    uint16 marketId;
    address feed;
    uint32 freezeUntil;
    uint32 addedAt;
    uint32 retiredAt;
}

/// @notice The inclusion-rule evidence recorded on-chain at `addConstituent`. One slot.
/// @dev The rule is `beta_i > 0.5 + sigma_u^2 / (2 sigma_I^2)` with a feed present and at least
///      `MIN_HISTORY_DAYS` of history. The inputs are recorded rather than recomputed: the numbers come from the
///      published quarterly rule, and storing them makes the decision auditable after the fact. A name that fails
///      the beta test may still be added — it gets a pool, the seed ladder and a bond market, but
///      `rolloutWeightBps == 0`.
///      ```
///      [  0.. 63] int64  betaX18            beta against the leave-one-out basket, 1e18 fixed point
///      [ 64..127] uint64 trackingErrorX18   sigma_u, annualised, 1e18
///      [128..191] uint64 indexVolX18        sigma_I, annualised, 1e18
///      [192..223] uint32 historyDays        days of price history behind the estimate
///      [224..255] uint32 recordedAt         timestamp of the registration that recorded this
///      ```
/// @param betaX18 Beta of the constituent against the basket excluding itself.
/// @param trackingErrorX18 Annualised idiosyncratic tracking error.
/// @param indexVolX18 Annualised index volatility.
/// @param historyDays Days of price history used.
/// @param recordedAt Registration timestamp.
struct InclusionRecord {
    int64 betaX18;
    uint64 trackingErrorX18;
    uint64 indexVolX18;
    uint32 historyDays;
    uint32 recordedAt;
}

/// @notice One `AmpsBonds` market: a collateral, its pricing parameters and its live capacity. Three slots.
/// @dev Bit layout:
///      ```
///      slot +0
///      [  0..159] address         collateral       the deposited token
///      [160..167] CollateralClass class            CONSTITUENT | ENTRY
///      [168..175] bool            open             governance switch; false closes the market to new bonds only
///      [176..183] uint8           decimals         ERC-20 decimals of `collateral`
///      [184..199] uint16          constituentId    1-based; 0 for ENTRY-class collateral
///      [200..215] uint16          dBaseBps         base discount
///      [216..231] uint16          dMinBps          discount floor
///      [232..247] uint16          dMaxBps          discount ceiling
///      [248..255] (free)
///
///      slot +1
///      [  0.. 15] uint16          capBpsPerEpoch   per-epoch capacity, in bps of `Amps.totalSupply()`
///      [ 16.. 79] uint64          kWeightX18       k_w: discount added per unit of index deficit
///      [ 80..143] uint64          kFillX18         k_c: discount removed per unit of epoch fill
///      [144..175] uint32          epochStart       start of the current capacity epoch
///      [176..207] uint32          lastBondAt       timestamp of the last accepted bond
///      [208..255] (free)
///
///      slot +2
///      [  0..127] uint128         issuedThisEpoch  AMPS wei issued by this market in the current epoch
///      [128..255] uint128         totalIssued      AMPS wei issued by this market since inception
///      ```
///      `issuedThisEpoch` and `totalIssued` are `uint128`: `Amps.totalSupply()` starts at 5,000e18 and grows only
///      through capped bonds, so 2^128 - 1 (~3.4e38 wei, i.e. 3.4e20 AMPS) is unreachable.
/// @param collateral The deposited token.
/// @param class Where the proceeds are routed.
/// @param open Whether new bonds are accepted. `claim()` ignores this entirely (I38).
/// @param decimals ERC-20 decimals of `collateral`.
/// @param constituentId The constituent whose spoke receives the proceeds, or 0 for ENTRY.
/// @param dBaseBps Base discount, inside `[DISCOUNT_BPS_MIN, DISCOUNT_BPS_MAX]`.
/// @param dMinBps Lower clamp of the discount.
/// @param dMaxBps Upper clamp of the discount.
/// @param capBpsPerEpoch Per-epoch capacity in bps of total supply.
/// @param kWeightX18 Coefficient on the index deficit term.
/// @param kFillX18 Coefficient on the epoch-fill term.
/// @param epochStart Start timestamp of the current epoch.
/// @param lastBondAt Timestamp of the last accepted bond.
/// @param issuedThisEpoch AMPS issued in the current epoch.
/// @param totalIssued AMPS issued since the market opened.
struct BondMarket {
    address collateral;
    CollateralClass class;
    bool open;
    uint8 decimals;
    uint16 constituentId;
    uint16 dBaseBps;
    uint16 dMinBps;
    uint16 dMaxBps;
    uint16 capBpsPerEpoch;
    uint64 kWeightX18;
    uint64 kFillX18;
    uint32 epochStart;
    uint32 lastBondAt;
    uint128 issuedThisEpoch;
    uint128 totalIssued;
}

/// @notice One bonder's vesting position. Two slots. Positions are plain structs in a per-user array: no NFT, no
///         transferability, so a position cannot be sold into a pool or used as collateral elsewhere.
/// @dev Bit layout:
///      ```
///      slot +0
///      [  0..127] uint128 principal    AMPS wei purchased, minted to `AmpsBonds` at purchase (I30)
///      [128..255] uint128 claimed      AMPS wei already claimed; `claimed <= principal` always
///
///      slot +1
///      [  0.. 31] uint32  start        purchase timestamp
///      [ 32.. 63] uint32  vestSeconds  the vest length in force at purchase, frozen for this position
///      [ 64.. 79] uint16  marketId     the market the position was bought from
///      [ 80..255] (free)
///      ```
///      `vestSeconds` is copied into the position rather than read from governance at claim time: a governance
///      change must never lengthen or shorten a vest already sold (I38).
/// @param principal Total AMPS purchased.
/// @param claimed AMPS already claimed.
/// @param start Purchase timestamp.
/// @param vestSeconds Vest length frozen at purchase.
/// @param marketId Originating market id.
struct VestingPosition {
    uint128 principal;
    uint128 claimed;
    uint32 start;
    uint32 vestSeconds;
    uint16 marketId;
}

/// @notice A single read of the oracle gate for one pool or constituent. One slot; returned by value, never stored
///         on a hot path.
/// @dev Bit layout:
///      ```
///      [  0..  7] GateState state           the most restrictive state that applies
///      [  8.. 15] Session   session         the equity session at `observedAt`
///      [ 16.. 23] bool      feedStale       answer older than the session-scaled `maxAge`
///      [ 24.. 31] bool      corporateFreeze `oraclePaused()` or a pending `effectiveAt` within the window
///      [ 32.. 39] bool      diverged        pool-vs-fair divergence sustained past the breaker
///      [ 40.. 47] bool      watchdogTripped no block or observation for longer than `GRACE`
///      [ 48.. 63] uint16    hSessionBps     the bond haircut in force
///      [ 64.. 79] uint16    dynCapBps       the hook's dynamic-fee cap in this state
///      [ 80..103] int24     poolTick        the pool's tick at observation
///      [104..127] int24     fairTick        `tickOf(P_mkt / P_i)`
///      [128..159] uint32    observedAt      when the snapshot was taken
///      [160..191] uint32    answerUpdatedAt `updatedAt` of the constituent's last Chainlink answer
///      [192..255] uint64    answerUsd8      that answer, 8 decimals; 0 when unavailable
///      ```
/// @param state The gate verdict.
/// @param session The equity session.
/// @param feedStale Whether the feed is beyond its session-scaled freshness bound.
/// @param corporateFreeze Whether a corporate action freeze applies.
/// @param diverged Whether the divergence breaker has tripped for this pool.
/// @param watchdogTripped Whether the block-cadence watchdog has tripped.
/// @param hSessionBps The bond haircut in force, in bps.
/// @param dynCapBps The hook's dynamic-fee cap, in bps.
/// @param poolTick The pool tick observed.
/// @param fairTick The fair tick the pool is measured against.
/// @param observedAt Snapshot timestamp.
/// @param answerUpdatedAt Chainlink `updatedAt` of the answer used.
/// @param answerUsd8 The Chainlink answer used, 8 decimals.
struct GateSnapshot {
    GateState state;
    Session session;
    bool feedStale;
    bool corporateFreeze;
    bool diverged;
    bool watchdogTripped;
    uint16 hSessionBps;
    uint16 dynCapBps;
    int24 poolTick;
    int24 fairTick;
    uint32 observedAt;
    uint32 answerUpdatedAt;
    uint64 answerUsd8;
}

/// @notice The vault's NAV/reference checkpoint: what the hook, `AmpsBonds` and `AmpsQuoter` read. Two slots.
/// @dev Bit layout:
///      ```
///      slot +0
///      [  0..127] uint128 navPerShareX18  (A + 1) * 1e18 / (T + VIRTUAL_SHARES), USD per AMPS
///      [128..255] uint128 pRefX18         max(navPerShareX18, rateLimited(pMktX18)), USD per AMPS
///
///      slot +1
///      [  0..127] uint128 pMktX18         30-minute truncated TWAP of the AMPS/USDG hub, USD per AMPS
///      [128..159] uint32  timestamp       when the checkpoint was written
///      [160..191] uint32  blockNumber     `uint32(block.number)`, for the layer-A watchdog
///      [192..255] (free)
///      ```
///      `uint128` for the three prices caps them at ~3.4e20 USD per AMPS, which no reachable state approaches, and
///      keeps the whole checkpoint to two slots so a `bond()` or a `redeemProRata()` pays at most two SSTOREs for
///      it. Consumers must treat `timestamp` as a staleness bound: reads older than `checkpointMaxAge` are refused
///      by every path except redemption.
/// @param navPerShareX18 NAV per share in USD, 18 decimals.
/// @param pRefX18 The reference price in USD, 18 decimals. Never below `navPerShareX18` (I24).
/// @param pMktX18 The market price in USD, 18 decimals, from the hub TWAP.
/// @param timestamp Checkpoint timestamp.
/// @param blockNumber Truncated block number at the checkpoint.
struct Checkpoint {
    uint128 navPerShareX18;
    uint128 pRefX18;
    uint128 pMktX18;
    uint32 timestamp;
    uint32 blockNumber;
}

/// @notice One placed ladder bucket, as the vault records it. Two slots per bucket per pool.
/// @dev Ladders are static: a record is written when the bucket is placed and is only ever *removed* by pro-rata
///      redemption, rollout of an unfilled entry-pool bucket, the high-water buyback burn, or migration (I35). It
///      is never re-centred, re-widened or moved up.
///      ```
///      slot +0
///      [  0.. 23] int24   lowerTick     bucket lower bound, spacing-aligned
///      [ 24.. 47] int24   upperTick     bucket upper bound, spacing-aligned
///      [ 48..175] uint128 liquidity     position liquidity added at placement
///      [176..183] uint8   bucketIndex   k, 0 nearest the anchor
///      [184..191] uint8   buckets       n, the ladder's bucket count at placement
///      [192..199] bool    above         true = ask (AMPS only, above the tick); false = bid (counter only, below)
///      [200..231] uint32  placedAt      placement timestamp
///      [232..255] (free)
///
///      slot +1
///      [  0..127] uint128 amount        AMPS wei (ask) or counter raw units (bid) committed at placement
///      [128..191] uint64  tiltX18       the `ladderTilt` in force at placement
///      [192..215] int24   anchorTick    the anchor the ladder was measured from
///      [216..255] (free)
///      ```
/// @param lowerTick Lower bound of the bucket.
/// @param upperTick Upper bound of the bucket.
/// @param liquidity Liquidity added.
/// @param bucketIndex The bucket's index within its ladder.
/// @param buckets The ladder's bucket count at placement time.
/// @param above True for an ask bucket, false for a bid bucket.
/// @param placedAt Placement timestamp.
/// @param amount The token amount committed at placement.
/// @param tiltX18 The tilt in force at placement.
/// @param anchorTick The ladder anchor.
struct PlacementRecord {
    int24 lowerTick;
    int24 upperTick;
    uint128 liquidity;
    uint8 bucketIndex;
    uint8 buckets;
    bool above;
    uint32 placedAt;
    uint128 amount;
    uint64 tiltX18;
    int24 anchorTick;
}

/// @notice One cell of a pool's canonical doubling grid, in the compact shape the placement path passes around.
///         Memory-only: the durable record of a cell the vault actually holds is {PlacementRecord}.
///
/// @dev **The grid** (`docs/phase3-state-model.md` §3.2, ruling 1). A v4 position is keyed by
///      `(owner, tickLower, tickUpper, salt)` and Amplestocks uses `salt == Constants.POSITION_SALT` (`bytes32(0)`)
///      everywhere (ruling 12), so two placements over the same range are **one** position at the PoolManager.
///      Confining every placement to a lattice is therefore not an optimisation, it is what makes the bookkeeping
///      correct: records merge by cell rather than accumulate, `redeemProRata`'s work is bounded at
///      `Constants.GRID_CELLS` positions per pool, and `LadderPositionValuer` can enumerate what the vault owns by
///      `extsload` without any getter on the vault.
///      ```
///      D      = LadderLib.doublingTicks(tickSpacing)             one doubling, rounded up to a whole spacing
///      cell m = [gridBaseTick + m*D, gridBaseTick + (m+1)*D)     m in [GRID_MIN_M, GRID_MAX_M)
///      index  = uint8(m - GRID_MIN_M)                            0 .. GRID_CELLS-1, the {PlacementRecord} key
///      ```
///      Genesis asks occupy `m = 0..9` and seed bids `m = -4..-1`; re-laddered fee asks, rolled-out asks and bonded
///      bids snap to the same lattice. Invariant I39: every record in pool `p` has
///      `lowerTick == gridBase_p + m*D_p` for some `m` in range, and no two records share an `m`.
/// @param index The cell index `m - GRID_MIN_M`, in `[0, GRID_CELLS)`. The merge key.
/// @param lowerTick The cell's lower bound, `gridBaseTick + m*D`.
/// @param upperTick The cell's upper bound, `lowerTick + D`.
/// @param liquidity Position liquidity in this cell: what is being added, removed or observed, depending on the
///        caller. Never a cumulative token amount — that is {PlacementRecord-amount}.
/// @param above True while the cell is an ask (AMPS above the tick), false once it has converted to a bid.
struct GridCell {
    uint8 index;
    int24 lowerTick;
    int24 upperTick;
    uint128 liquidity;
    bool above;
}

/// @notice Everything one placement needs, in the shape `AmpsVault` hands to `VaultPlacementLib`.
///
/// @dev **Chosen shape.** `docs/phase3-state-model.md` §3.1 fixes the *signature*
///      `placeLadder(mapping ladder, mapping cooldown, PlaceParams memory p) -> Placed memory` but not the fields;
///      these are chosen to be exactly the inputs §3.3 and §3.8 need and nothing else, so the library never has to
///      call back out to the registry or the checkpoint mid-placement. The vault fills every field before it takes
///      the lock, which is what lets the gauntlet run entirely on values captured at entry.
///
/// @dev **The gauntlet the vault runs around this** (§3.8, and it is the vault's job, never the policy's): the
///      transient lock and `_requireHealthy`; `IOracleGate.checkPlacement`; divergence at entry *and* exit;
///      sidedness (I9 — asks strictly above `alignUp(currentTick)`, bids strictly below `alignDown(currentTick)`);
///      grid membership (I39) and `sum(amounts) <= amount`; the 60-second cooldown; the R1 revert; `armSurge`
///      after; `_sweepClean` at exit. Every bucket a policy proposes is re-checked here, never trusted.
/// @param key The pool key. Carries `tickSpacing`, and is what `modifyLiquidity` needs inside the unlock.
/// @param poolClass The pool's fee bucket, for the class-dependent limits.
/// @param above True for an ask ladder (AMPS above the tick), false for a bid ladder (counter below it).
/// @param amount The inventory to place: AMPS wei for an ask, counter raw units for a bid. An upper bound — a
///        ladder may commit less when liquidity rounding leaves a residue, and the residue stays idle.
/// @param anchorTick The tick the ladder is measured from, already snapped to the grid.
/// @param currentTick `slot0.tick` captured at entry, the sidedness reference.
/// @param gridBaseTick The pool's grid origin, from {PoolConfig-gridBaseTick}.
/// @param buckets The ladder length: `ladderDoublings` for asks, `seedHalvings` or `bondBidHalvings` for bids.
/// @param tiltX18 The tilt in force, inside `[LADDER_TILT_X18_MIN, LADDER_TILT_X18_MAX]`.
/// @param reason A short identifier for the event and the surge that follows: `bytes32("genesis")`,
///        `bytes32("spokeSeed")`, `bytes32("compound")`, `bytes32("rollout")`, `bytes32("bonded")`.
struct PlaceParams {
    PoolKey key;
    PoolClass poolClass;
    bool above;
    uint256 amount;
    int24 anchorTick;
    int24 currentTick;
    int24 gridBaseTick;
    uint8 buckets;
    uint64 tiltX18;
    bytes32 reason;
}

/// @notice What a placement actually did, returned by `VaultPlacementLib` to the vault's forwarder.
/// @dev `amountPlaced <= PlaceParams.amount` always: what a bucket loses to liquidity rounding stays in the vault
///      as idle inventory rather than disappearing, and `cells == 0` with `amountPlaced == 0` is a legitimate
///      no-op (nothing was due) rather than a revert.
/// @param amountPlaced The token amount actually committed, in the placed side's units.
/// @param liquidityAdded The sum of the position liquidity added across the cells.
/// @param cells How many grid cells the placement wrote or merged into.
/// @param lowestTick The lowest `lowerTick` written, or 0 when `cells == 0`.
/// @param highestTick The highest `upperTick` written, or 0 when `cells == 0`.
struct Placed {
    uint256 amountPlaced;
    uint128 liquidityAdded;
    uint8 cells;
    int24 lowestTick;
    int24 highestTick;
}

/// @notice The hook's per-pool state as one flat **memory view**, excluding the observation ring.
///
/// @dev **This is a view, not a layout** (`docs/phase3-state-model.md` §10 ruling 4). It is what
///      `AmpsHook.poolState(poolId)` assembles and returns; it is never written to storage by anything. The hook's
///      real storage is three packed words plus the ring (§1.2 of that document):
///      ```
///      CONFIG _cfg                                DYNAMIC _dyn                        ARMED _arm
///      [  0.. 15] uint16 buyFeeBps                [  0.. 23] int24  lastTick          [  0.. 15] uint16 surgeBps
///      [ 16.. 31] uint16 constituentId            [ 24.. 55] uint32 lastUpdate        [ 16.. 47] uint32 surgeArmedAt
///      [ 32.. 39] uint8  poolClass                [ 56.. 79] int24  fairTick          [ 48.. 63] uint16 captureFeeBps
///      [ 40.. 63] int24  tickSpacing              [ 80..103] int24  innerBandTicks    [ 64.. 95] uint32 captureArmedAt
///      [ 64.. 87] int24  maxTickMovePerBlock      [104..127] int24  outerRailTicks    [ 96..159] uint64 uiMultiplierX18
///      [ 88.. 95] uint8  counterDecimals          [128..143] uint16 dynCapBps         [160..223] uint64 varianceX18
///      [ 96..119] int24  gridBaseTick             [144..151] uint8  session           [224..255] uint32 lastCorporate
///      [120..127] bool   initialized              [152..159] uint8  gateFlags                            Check
///                                                 [160..167] uint8  fVolBps
///                                                 [168..199] uint32 gateRefreshedAt
///      ```
///      so the field order below is presentation, not packing, and adding a field here costs no storage and moves
///      nothing. The ring lives beside those words in `mapping(PoolId => TruncatedOracleLib.State)`, which already
///      owns `index`, `cardinality`, `highWaterTick`, `lastTruncatedTick`, `blockAnchorTick` and `lastBlockNumber`;
///      none of those is duplicated here — read them through {IMarketReference} (ruling 4 is explicit that
///      `highWaterTick` stays there).
///
/// @dev **`lastTick` is the raw post-swap `slot0.tick`**, the deviation and EWMA input. The *truncated* tick, which
///      is what a TWAP and the high-water mark advance on, is `IMarketReference.lastTruncatedTick`. They differ
///      whenever `maxTickMovePerBlock` bound the last write, and that difference is the security property (I25).
///
/// @dev **`gateFlags` is a bitfield**: bit0 `degraded`, bit1 `corporateFreeze`, bit2 `refreshFailed`, bit3
///      `caArmed`. `refreshFailed` records that a bounded `staticcall` inside the last gate refresh failed and the
///      cached values were kept — `afterSwap` never reverts for a downstream failure, it raises this flag instead.
///
/// @param initialized Whether `afterInitialize` has run for this pool.
/// @param poolClass The pool's fee bucket.
/// @param constituentId The constituent id, or 0 for an entry pool.
/// @param buyFeeBps The base buy fee.
/// @param tickSpacing The pool's tick spacing.
/// @param maxTickMovePerBlock The oracle truncation cap.
/// @param uiMultiplierX18 Last observed Stock Token display multiplier.
/// @param varianceX18 EWMA realised variance driving `f_vol`.
/// @param lastSwapAt Timestamp of the last swap.
/// @param surgeBps Surge fee at arming time.
/// @param surgeArmedAt Surge arming timestamp.
/// @param captureFeeBps Dividend-step capture fee at arming time.
/// @param captureArmedAt Capture-fee arming timestamp.
/// @param innerBandTicks The inner band half-width in ticks.
/// @param outerRailTicks The outer rail half-width in ticks.
/// @param dynCapBps The dynamic-fee cap in force.
/// @param lastCorporateCheck Timestamp of the last corporate-action probe.
/// @param counterDecimals ERC-20 decimals of `currency1`, cached from the registry at initialisation.
/// @param gridBaseTick Origin of the pool's canonical doubling grid, mirrored from {PoolConfig-gridBaseTick}.
/// @param lastTick The raw `slot0.tick` after the last swap. Not the truncated tick.
/// @param fairTick The tick the deviation is measured against: `tickOf(P_mkt / P_i)` for a spoke, the pool's own
///        truncated TWAP for an entry pool. Refreshed with the gate cache, never on every swap.
/// @param session The equity session cached at the last gate refresh. Entry pools always report `REGULAR`.
/// @param gateFlags The bitfield above.
/// @param fVolBps The volatility component pre-computed by `afterSwap` from `varianceX18`, so `beforeSwap` needs no
///        `k_vol` multiply. Capped at `Constants.F_VOL_CAP_BPS` (100), which is why a `uint8` suffices.
/// @param gateRefreshedAt When the gate cache was last refreshed. Older than `Constants.GATE_CACHE_MAX_AGE` and
///        `beforeSwap` substitutes the most conservative values for the pool's class.
struct HookPoolState {
    bool initialized;
    PoolClass poolClass;
    uint16 constituentId;
    uint16 buyFeeBps;
    int24 tickSpacing;
    int24 maxTickMovePerBlock;
    uint64 uiMultiplierX18;
    uint64 varianceX18;
    uint32 lastSwapAt;
    uint16 surgeBps;
    uint32 surgeArmedAt;
    uint16 captureFeeBps;
    uint32 captureArmedAt;
    int24 innerBandTicks;
    int24 outerRailTicks;
    uint16 dynCapBps;
    uint32 lastCorporateCheck;
    uint8 counterDecimals;
    int24 gridBaseTick;
    int24 lastTick;
    int24 fairTick;
    Session session;
    uint8 gateFlags;
    uint8 fVolBps;
    uint32 gateRefreshedAt;
}

/// @notice `FeedRegistry`'s record for one Chainlink aggregator. Two slots.
/// @dev Bit layout:
///      ```
///      slot +0
///      [  0..159] address aggregator      the Standard (never SVR) proxy
///      [160..167] uint8   decimals        the feed's own decimals; 8 on every Robinhood Chain feed seen
///      [168..175] bool    set             false means "no feed configured"
///      [176..207] uint32  heartbeat       the RDD heartbeat in seconds (86,400 on the equity feeds)
///      [208..223] uint16  thresholdBps    the RDD deviation threshold, recorded for monitoring
///      [224..255] (free)
///
///      slot +1
///      [  0..127] uint128 minAnswerUsd8   per-ticker lower sanity bound, 8 decimals
///      [128..255] uint128 maxAnswerUsd8   per-ticker upper sanity bound, 8 decimals
///      ```
///      The freshness bound is not stored per feed: it is `heartbeat x freshnessMultiplier[session] / 100`, and the
///      multipliers are one governed global table (1.5x Regular, 3x Pre/Post, 6x Overnight, disabled when Closed).
/// @param aggregator The Chainlink proxy address.
/// @param decimals The feed's decimals.
/// @param set Whether a feed is configured.
/// @param heartbeat The feed heartbeat in seconds.
/// @param thresholdBps The feed's deviation threshold in bps.
/// @param minAnswerUsd8 Lower sanity bound on the answer.
/// @param maxAnswerUsd8 Upper sanity bound on the answer.
struct FeedConfig {
    address aggregator;
    uint8 decimals;
    bool set;
    uint32 heartbeat;
    uint16 thresholdBps;
    uint128 minAnswerUsd8;
    uint128 maxAnswerUsd8;
}

/// @notice Everything `IFeedRegistry.feedStatus` reports about one feed, in the shape `AmpsQuoter` renders and a
///         degraded dApp falls back to. Memory-only: nothing writes it to storage, so it carries no packing
///         discipline and is laid out for readability instead.
/// @dev The three answer fields are the *effective* answer, which is not always the aggregator's live round: while
///      the two-confirmation rule holds a jump back, `answerUsd8` is the accepted answer and `unconfirmed` is true.
///      `fresh` is `false` for an unconfigured token, and `live` says whether the aggregator answered this very
///      call with a valid, in-bounds round — which is how a caller tells "dead feed" from "held-back jump".
/// @param answerUsd8 The effective answer, 8 decimals; 0 when no usable answer exists at all.
/// @param updatedAt The effective answer's publication timestamp.
/// @param roundId The round the effective answer came from.
/// @param age The effective answer's age in seconds.
/// @param maxAgeSeconds The freshness bound in force; `type(uint32).max` when the session disables the check.
/// @param fresh Whether the answer is within that bound.
/// @param live Whether the aggregator answered this call with a valid, in-bounds round.
/// @param unconfirmed Whether a jump above `Constants.ANSWER_JUMP_BPS` is being held back right now.
/// @param configured Whether a feed is configured for the token at all.
struct FeedStatus {
    uint256 answerUsd8;
    uint32 updatedAt;
    uint80 roundId;
    uint32 age;
    uint32 maxAgeSeconds;
    bool fresh;
    bool live;
    bool unconfirmed;
    bool configured;
}
