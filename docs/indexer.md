<!-- SPDX-License-Identifier: MIT -->

# `apps/indexer` — the Amplestocks indexer

Ponder 0.17 over Robinhood Chain, indexing every Amplestocks event, the v4 `PoolManager` filtered to
our own pools, the `uiMultiplier()` state diff per constituent, the beacon-level denylist alarm, and
NAV/inventory reconciliation against chain reads. It serves Ponder's generated GraphQL plus a small
typed HTTP layer for the dApp.

This document is the schema overview, the run book, the reconciliation rules and the alert
semantics. The code is the authority on everything it does not say; the module headers carry the
reasoning that is too fine-grained for here.

---

## 1. What it indexes, and why the shape is what it is

| Source | Kind | Filter | What it is for |
|---|---|---|---|
| `AmpsVault` | logs | its address | NAV and reference checkpoints, redemption, burns, placements, compounds, gate mirrors, the exit sweep's residue disclosures, every governed parameter |
| `AmpsBonds` | logs | its address | markets, purchases, positions, claims, per-epoch and per-day issuance and accretion, forwarded collateral, the vault pointer |
| `AmpsStaking` | logs | its address | the reward stream, the xAMPS share price, the realised APR |
| `Amps` | logs | its address | the token's vault pointer |
| `PoolRegistry` | logs | its address | **the allowlist**: which pools and constituents are ours; bond-market detachments and the vault pointer |
| `OracleGate` | logs | its address | gate state per pool, watchdog, divergence, freezes |
| `FeedRegistry` | logs | its address | the answers the protocol accepted, and the jumps it held back |
| `AmpsHook` | logs | its address | rotation credits, surges, dividend steps, high-water marks, `RebalanceNeeded`, the vault pointer |
| `BountyPot` | logs | its address | bounty payments, and the keeper-job ledger they anchor |
| `PoolManager` | logs | our `PoolId`s | `Swap`, `ModifyLiquidity`, `Initialize` |
| `LadderPositionValuer` | **reads only** | its address | `amountsOf` and `referenceSqrtPriceX96` for the ladder cross-check (§4). It emits nothing; it is configured so `context.contracts` carries its address and ABI |
| `ChainlinkAggregator` | logs | factory over `FeedSet` | `AnswerUpdated`, where the registered address is the aggregator |
| `StockTokenCalls` | **transactions** | factory over `ConstituentAdded` | the denylist alarm |
| `DenylistWatch` | **transactions** | the beacon + `AMPS_DENYLIST_WATCH` | the denylist alarm |
| `constituentPoll` | block interval | `AMPS_MULTIPLIER_POLL_BLOCKS` | `uiMultiplier` / `newUIMultiplier` / `effectiveAt` / `oraclePaused` state diff, `isBlocked` probe |
| `reconcile` | block interval | `AMPS_RECONCILE_POLL_BLOCKS` | NAV and supply reconciliation heartbeat, and the ladder cross-check against `LadderPositionValuer` |

The Stock Tokens themselves are deliberately *not* a log source: they emit only ERC-20 events, which
the index has no use for. What is watched is their **transactions**, for the reason below.

Three of these deserve their reasoning stated:

**The `PoolManager` is shared.** It carries every v4 pool on the chain, so a pool is ours if and only
if `PoolRegistry.PoolRegistered` announced it. That row is the filter, in the handler, always. When
the 32 ids are known at start-up (`AMPS_POOL_IDS`, or `AMPS_POOLS` pointing at the `pools.json`
`script/05_Registry.s.sol` writes) they are additionally pushed into `eth_getLogs` as a topic
filter. The two modes index identically; only the RPC bill differs.

**The denylist has no event.** `blockAccounts(address[])` (`0x6abf7081`) is an issuer power on the
Stock Token beacon with no delay, no timelock and nothing emitted. The alarm therefore watches
*transactions* addressed at the watched contracts and decodes the selector, which is what lets it
fire in the same block the call lands in. A second, slower detector probes `isBlocked(vault)` in the
constituent poll, so a denylist applied through a multicall, a Safe or an upgrade is still caught,
one poll interval late.

**`AnswerUpdated` comes from the aggregator, not the proxy.** `FeedRegistry` stores the Chainlink
*proxy*; on 4663 the underlying `AccessControlledOffchainAggregator` is what emits `AnswerUpdated`,
so the factory-derived source stays empty on mainnet until Phase 0 records the aggregator behind
each proxy. Nothing depends on it: `FeedRegistry.AnswerLatched` is the authoritative record of what
the protocol actually priced against, and is what `feed.answerUsd8` and `constituent.answerUsd8`
are written from.

---

## 2. Schema

47 tables. Conventions: event rows are keyed `"<blockNumber>-<logIndex>"` zero-padded so text order
is chain order; entity rows are keyed by on-chain identity, lower-cased; AMPS is 18-decimal wei, USD
is 18-decimal (`Usd18`), Chainlink answers stay in their own 8 decimals (`Usd8`), prices are `X18`;
enums are stored as the on-chain ordinal *and* a decoded label.

### Vault, NAV and supply

| Table | Key | What it holds |
|---|---|---|
| `nav_checkpoint` | event | `navPerShareX18`, `A`, `T`, and the change in bps since the previous checkpoint |
| `ref_checkpoint` | event | `pRefX18`, `pMktX18`, `rateLimited`, `navFloored`, the NAV in force, the premium |
| `share_point` | block | shares by class: `totalSupply`, `inventory`, `vesting`, `staked`, `bondUnvested`, `circulating` |
| `vault_summary` | singleton | the Vault page in one row: live NAV/`P_ref`/`P_mkt`/premium, shares by class, cumulative fees, creator/staker/burn/re-ladder totals, bond issuance, redemptions, net supply change |
| `redemption` | event | `owner`, `to`, `shares`, `inventoryBurned`, `feeBps`, the NAV it paid at, gross and fee in USD |
| `burn_event` | event | `amount`, the raw `bytes32` reason and its decoded label |
| `vesting_mint` | event | the team `VestingWallet` draws |

### Placements, the ladder, compounds, rollouts

| Table | Key | What it holds |
|---|---|---|
| `placement` | event | `poolId`, `above`, `buckets`, `amount`, `anchorTick`, the vault's own `reason` (raw and decoded) and the `action` it maps to, the caller, the `lowerTick`/`upperTick` range written, the cell count, and the liquidity the same transaction added |
| `ladder_cell` | `"<poolId>-<tickLower>"` | the durable ladder record: `cellIndex` (`m - GRID_MIN_M`), `m`, the tick bounds, live `liquidity`, `above`, cumulative `principal`, and — recomputed at the pool's live price — `ampsRemaining`, `counterRaised` and `fillBps` |
| `liquidity_change` | event | every `ModifyLiquidity` on our pools: the audit trail behind `ladder_cell` |
| `compound_event` | event | the four-way split (`creatorPaid`, `stakerPaid`, `burned`, `relaid`), the creator bps in force, NAV either side and the change in bps, the bounty paid |
| `rollout_event` | event | `AmpsVault.Rollout`: `constituentId`, the destination `toPoolId`, `movedAmps` taken out of the entry pools' unfilled asks and `placedAmps` the destination ladder committed, the caller |

### Pools and swaps

| Table | Key | What it holds |
|---|---|---|
| `pool` | `PoolId` | counter and its decimals, class, constituent, tick spacing, `doublingTicks`, `gridBaseTick`, `buyFeeBps`, feed, the price it opened at, live `sqrtPriceX96`/`tick`/`liquidity`, gate state, cumulative volume and fees by direction, rotation credit, ladder totals, the valuer cross-check (`valuerAmps`, `valuerCounter`, `valuerDeltaBps`, `valuerCheckedBlock`, §4), realised LVR and fee revenue in USD |
| `swap` | event | direction, both deltas, `amountIn`/`amountOut`, the AMPS and counter legs, the post-swap price and tick, `feePips`/`feeBps`, **`baseFeeBps`**, **`dynamicFeeBps`**, **`creditedAmount`**, the fee amount in the input currency and in AMPS, notional and fee in USD |
| `pool_day` | `"<poolId>-<day>"` | per-pool per-UTC-day volume, fees, credited AMPS, swap count, realised LVR, the day's tick range |
| `rebalance_signal` | event | `RebalanceNeeded`: tick, fair tick, deviation |
| `hook_event` | event | `SurgeArmed`, `MultiplierStepDetected`, `HighWaterAdvanced/Reset`, `GateCacheRefreshed`, `Initialize` |

### Registry, gate, feeds, constituents

| Table | Key | What it holds |
|---|---|---|
| `constituent` | id | token, symbol, pool, status, target and rollout weights, market id, feed, freeze, and the polled issuer state (`uiMultiplierX18`, `newUiMultiplierX18`, `effectiveAt`, `oraclePaused`, `tokenPaused`, `vaultBlocked`) plus the latest accepted answer |
| `constituent_event` | event | the lifecycle log: added / retired / reinstated / reconfigured / frozen / bonded deposits / retired bids withdrawn / `bondMarketDetached` |
| `token_index` | token | token → constituent id, the reverse lookup Ponder's write API cannot query for |
| `index_weights` | event | every `setIndexWeights` vector |
| `gate_status` | `PoolId` or `"protocol"` | current state and label, divergence, watchdog, protocol freeze |
| `gate_transition` | event | every `GateChanged`, from the gate and from the vault, with a `source` column |
| `gate_event` | event | watchdog stamps and trips, divergence latches, corporate-action and guardian freezes, calendar installs |
| `feed` | token | aggregator, heartbeat, threshold, sanity bounds, latest accepted answer |
| `feed_answer` | event | the accepted-answer series (`source = latched`) and the raw aggregator rounds (`source = aggregator`) |
| `feed_jump` | event | `AnswerJumpPending`: a jump the two-confirmation rule held back |
| `multiplier_point` | job or event | the `uiMultiplier` state-diff series — **one row per change, never one per poll** |

### Bonds and staking

| Table | Key | What it holds |
|---|---|---|
| `bond_market` | market id | collateral and class, open flag, **`detached`** (`AmpsBonds` no longer attributes the market to that collateral, so `setMarketOpen` refuses it forever), discount parameters, capacity, epoch, cumulative issuance, collateral and realised accretion, and **`forwardedCollateral`** — the running total `bond()` pushed on to the vault |
| `collateral_index` | collateral | collateral → market id, the mirror of `AmpsBonds.marketIdOf` and the lookup `CollateralForwarded` needs; deleted by `CollateralRemoved` |
| `bond_purchase` | event | `amountIn`, `ampsOut`, `qX18`, `discountBps`, `floorBinding`, NAV either side, realised accretion in USD and bps |
| `bond_position` | `"<owner>-<positionId>"` | principal, claimed, start, vest length, fully-claimed |
| `bond_claim` | event | every claim |
| `bond_epoch` | `"<marketId>-<epochStart>"` | issuance, collateral, accretion, bond count, the discount range, how often the floor bound |
| `bond_day` | `"<marketId>-<day>"` | the same per UTC day |
| `staking_state` | singleton | xAMPS assets and supply, share price, stream end, cumulative and trailing-24 h rewards, the realised APR |
| `staking_reward` | event | every `RewardNotified` with the assets it was paid into |

### Keeper, governance, alarms

| Table | Key | What it holds |
|---|---|---|
| `bounty_payment` | event | `BountyPaid`, `PotFunded`, `PotSwept` |
| `keeper_job` | tx hash | one row per keeper-shaped transaction: the job, the caller, the pool or constituent, `ok` or `noop`, the bounty paid |
| `parameter_state` | `"<scope>:<name>"` | the latest value of every governed parameter, from all seven emitting contracts |
| `parameter_change` | event | the append-only history behind it |
| `denylist_alarm` | event/job | every observation of the denylist: `detection` (`call` or `probe`), target, caller, selector, the decoded accounts, whether it touches a protocol address, severity |
| `reconciliation` | block | indexed versus chain for NAV, `P_ref`, supply, inventory and `A`, with the deltas, the bounds in force, `ok` and the breached fields |
| `alert` | event/job | every alert raised, its severity and detail, and what the sink did with it |
| `flywheel_day` | day | the dashboard's headline series: sell-fee revenue, bond issuance and accretion, burns, staker and creator payments, re-laddered AMPS, redemptions, net supply change, realised LVR, NAV open/close, closing premium, swap count |
| `pending_credit` | `"<tx>-<poolId>"` | internal: a rotation credit parked for the `Swap` that follows it |
| `indexer_state` | key | internal: the small scratch the handlers keep between events |

---

## 3. Fee decoding

`docs/phase3-state-model.md` §1.4, implemented in `src/lib/fee.ts` and pinned by `test/fee.test.ts`.

**Direction.** AMPS is `currency0` in all 32 pools by construction, so `zeroForOne == true` is
unconditionally "AMPS in", i.e. a sell. v4's `Swap` carries the *swapper's* deltas, so the swapper
paying currency0 (`amount0 < 0`) is exactly that sell. Nothing infers direction from the sender, the
router or the tick move.

**Base fee.** `base = sell ? ampsFeeBps : pool.buyFeeBps`. `ampsFeeBps` is hook-wide and is tracked
from `HookParameterChanged("ampsFeeBps", 0, …)`; `buyFeeBps` is per pool, carried by
`PoolRegistered` itself and moved by `HookParameterChanged("buyFeeBps", poolId, …)` or
`ConstituentReconfigured(id, "buyFeeBps", …)`. Neither is ever read from the chain.

**Rotation credit.** An exact-input sell covered by a same-transaction credit pays

```
c    = min(credit, amountIn)
base = buyFeeBps + ceil((ampsFeeBps - buyFeeBps) * (amountIn - c) / amountIn)
```

The hook computes that itself in `beforeSwap` and emits
`RotationCreditConsumed(poolId, consumed, blendedFeeBps)`. v4 calls `beforeSwap` *before* it swaps
and emits, so the hook's log always has the smaller log index in the same transaction: the indexer
parks the credit keyed `(txHash, poolId)` and the `Swap` handler consumes it, taking `blendedFeeBps`
as the base and `consumed` as the credited amount. The formula above is only ever evaluated in a
test. Exact-output sells consume no credit and pay `ampsFeeBps` in full; a credit on a buy is
ignored, because only AMPS-in swaps consume one.

**Dynamic part.** v4's `Swap.fee` is the total actually charged after the hook's override, so
`dynamic = fee/100 - base`, floored at zero. That residual is
`f_vol + f_dev + f_div + f_session + surge`, clamped in-contract to `[F_MIN_BPS, base + dynCapBps]`.
The components are not separable from the log alone; `SurgeArmed`, `MultiplierStepDetected` and
`GateCacheRefreshed` record the arming events that explain them and are indexed alongside in
`hook_event`.

**Fee amount.** `feeAmount = ceil(grossIn * feePips / 1e6)` in the input currency's units — v4 takes
the LP fee on the input. It can differ from the pool's own accounting by one wei on a swap that did
not consume its whole remaining input; it is a disclosure column, and `compound_event.ampsFees` is
the number that is actually realised.

**Ladder fill and proceeds.** A v4 position converts in place as the price crosses it (§3.4), so a
cell's decomposition into AMPS-still-there and counter-raised *is* its fill and its proceeds. Every
swap and every `ModifyLiquidity` re-prices the pool's cells from `liquidity`, the cell bounds and
the live `sqrtPriceX96` (`amountsForLiquidity`, a `bigint` port of `LiquidityAmounts`), and
`fillBps = 1 - ampsRemaining / ampsAtPlacement`.

**Realised LVR.** Marked against the price the swap left the pool at:

```
lvrAmps = counterOut / P1 - ampsInNet     (sell)
lvrAmps = ampsOut - counterIn / P1        (buy)
```

on the net input, so it is gross of fees and "fee revenue vs realised LVR" is a comparison rather
than a tautology. A price-improving trade gives a negative number and is summed as it stands.

---

## 4. Reconciliation

`src/lib/reconcile.ts`, driven by `src/handlers/reconcile.ts`, pinned by `test/reconcile.test.ts`.

**When.** At every block that carried a checkpoint — every block in which a number the dApp displays
could have moved — and additionally every `AMPS_RECONCILE_POLL_BLOCKS` blocks as a heartbeat. Both
write `reconciliation`, distinguished by `trigger`.

The checkpoint-triggered run hangs off **`RefCheckpoint`, not `NavCheckpoint`**. `_checkpoint()`
emits the two in that order, so `RefCheckpoint` is the first moment at which both halves of the
checkpoint the vault just wrote are in the index and comparable. A block can carry several
checkpoints — a `compound` writes one at entry and one at exit — and the row is keyed by the block,
so the last run in the block rewrites it in full.

**What.** Six pairs are measured, every chain read taken **at that same block**, never at head.
Three of them breach:

| field | indexed | chain | breaches |
|---|---|---|---|
| NAV/share | the last `NavCheckpoint`'s `navPerShareX18` | `checkpointData().navPerShareX18` | yes |
| `P_ref` | the last `RefCheckpoint`'s `pRefX18` | `checkpointData().pRefX18` | yes |
| total supply | `S0 + VestingMinted - Burn`, from the events alone | `Amps.totalSupply()` | yes |
| NAV/share, live | — | `previewNavPerShareX18()` | no |
| `A` | the last checkpoint's `totalAssetsUsd18` | `vault.totalAssetsUsd18()` | no |
| inventory | the last sample | `vault.inventoryAmps()` | no |

The three that do not breach are not slack, they are **not comparable**. A chain read is
end-of-block state and a checkpoint is what the vault last *wrote*, so `previewNavPerShareX18()`
and `totalAssetsUsd18()` — both live recomputations — differ from the checkpoint whenever a price
has moved since. That is the normal case, and `previewDeltaBps` is exactly what it is for: it says
how stale the displayed NAV is. `inventoryAmps()` has no event-derived counterpart at all, so both
sides of that pair are the same chain read and it can only ever agree; it is carried because the
number itself belongs on the dashboard.

Total supply *is* a real two-sided check, and it is exact. The indexed side never touches a chain
read: it is seeded from the first checkpoint the indexer sees and then moved by exactly two events.

- **`VestingMinted`** is how **every** post-genesis mint arrives, bond issuance included — I30 mints
  a bond's principal to `AmpsBonds` through `mintVesting`, and the log now says so with
  `reason == "bond"`. `Bond.ampsOut` describes that same mint and is never added on top.
- **`Burn`** is every burn, and since the polish slice that is *all* of them: `redeemProRata` emits
  `Burn(shares, "redeem")` for the redeemer's own shares as well as
  `Burn(inventoryBurned, "redeemInventory")` for the vault's slice, so `Redeem` moves no supply at
  all. Both are real burns of different AMPS and both are counted.

A disagreement therefore means the indexer's bookkeeping has drifted from the chain — which is the
bug this job exists to catch.

**The dust bound.** A pair passes when it is within `AMPS_DUST_BPS` of *relative* divergence **or**
within `AMPS_DUST_WEI` of *absolute* divergence. Two bounds because one is not enough in both
directions: a small absolute drift on a tiny number must not fail a relative bound, and a large
relative drift on a large number must not pass an absolute one.

Defaults:

- `AMPS_DUST_BPS = 2` — the same 2 bp budget R1 allows a single `compound` to bleed (§3.6 step 9),
  so the indexer's tolerance is exactly the protocol's own.
- `AMPS_DUST_WEI = 1e12` — 1e-6 AMPS, or 1e-6 USD at 18 decimals. Three orders of magnitude above
  the `+1` and `VIRTUAL_SHARES` rounding in `navPerShare = (A + 1) / (T + 1e3)`, and far below
  anything economically visible.

**Before the first checkpoint** the index has nothing to compare, so a run is skipped until both a
`NavCheckpoint` and a `RefCheckpoint` have been seen. `_checkpoint()` writes both in one call, one
log index apart, so the gap is a single handler invocation and not a window.

**A breach** writes `ok = false` with `breached` naming the fields, and raises an alert: `critical`
for `nav` or `pRef` (the dApp is showing a wrong number), `warning` for `supply` (the indexer's
bookkeeping drifted).

`/api/reconciliation` serves the runs and the totals; `?failing=1` gives only the breaches.

**The ladder cross-check.** On the `AMPS_RECONCILE_POLL_BLOCKS` heartbeat — the interval trigger
only, not the per-checkpoint one — `checkLadders` re-derives each pool's AMPS side
from the indexer's own cell table and compares it with `LadderPositionValuer.amountsOf(poolId)`.
Both sides are taken at `referenceSqrtPriceX96(poolId)`, not at `slot0`: `A` is valued at the
reference price precisely so it does not move when the pool price does (I7), and comparing at the
live price would measure the wrong thing. The result lands on the `pool` row as `valuerAmps`,
`valuerCounter`, `valuerDeltaBps` and `valuerCheckedBlock`.

This is the check on the riskiest code in the indexer: the `bigint` port of `TickMath` and
`LiquidityAmounts` in `src/lib/math.ts`, which every ladder number — cell principal, fill,
proceeds — is derived from and which nothing else would notice had drifted. It is deliberately
**not** a breach: a pool whose cells the indexer has not seen in full (an indexer started mid-life,
past the genesis placements) would diverge for a reason that is not a fault. It is asserted in the
end-to-end suite instead, where the index does start from block zero — and there the agreement is
exact, 0 bp across all five pools.

The pools it walks come from the key set `PoolRegistry:PoolRegistered` writes into `indexer_state`
under `registry.poolIds`. `context.db` is a key-value store with no query side, so a job that has to
reach *every* pool needs the id set written down as it is discovered; walking the constituents
instead would silently skip the two entry pools, which have no constituent id and carry the largest
ladders there are.

---

## 5. Alerts

`src/lib/alerts.ts`. Everything raised is written to `alert` first and handed to the sink second, so
a delivery failure never loses an alert; `delivered` and `deliveryError` record what happened.
**The sink is a no-op by default** — set `AMPS_ALERT_WEBHOOK` to POST each alert as JSON (bigints as
decimal strings). Nothing is retried inside an indexing function: a paging outage must not wedge the
indexer.

| kind | severity | raised when |
|---|---|---|
| `denylist` | `critical` | a `blockAccounts` / `unblockAccounts` call, or an `isBlocked` probe, naming the vault, the PoolManager or any protocol contract — the predicate that unlocks `emergencyMigrate` |
| `denylist` | `warning` | the same, naming only third parties |
| `reconciliation` | `critical` | NAV/share or `P_ref` diverged from the chain past the dust bound |
| `reconciliation` | `warning` | the event-derived supply diverged from `Amps.totalSupply()` |
| `nav-bleed` | `critical` | a `compound` whose NAV/share fell more than 2 bp — the chain should have reverted it (I11) |
| `gate` | `critical` | the watchdog tripped, a protocol freeze was set, or the vault migrated |
| `gate` | `warning` | any pool gate left `GREEN` |
| `corporate-action` | `warning` | a `uiMultiplier` step past `DIVIDEND_STEP_BPS_MAX`, or a constituent frozen for a corporate action |
| `sweep-residue` | `warning` | `AmpsVault.SweepResidue`: the exit sweep could not fold a token's idle balance into the vault's ERC-6909 claims, so the token is paused, denylisting the vault or unreadable. Disclosure, not a breach — the residue stays part of the vault's holdings, is valued in `A` and is paid out by redemption — so it pages one step below the denylist alarm that would raise the same fact if it could see the issuer's call |

The denylist alarm also has its own table, `denylist_alarm`, served at `/api/alerts/denylist`, which
records the detection method, the decoded account list and whether it touched a protocol address.

---

## 6. Running it

### Locally, against an existing deployment

```sh
cp apps/indexer/.env.example apps/indexer/.env.local   # then fill in the addresses
pnpm --filter @amplestocks/indexer dev
```

PGlite under `.ponder/pglite`, GraphQL at `http://localhost:42069/graphql`, the typed layer under
`/api/*`. `pnpm --filter @amplestocks/indexer start` is the production form; it uses Postgres as
soon as `DATABASE_URL` (or `DATABASE_PRIVATE_URL`) is set, and PGlite otherwise.

### Against a local anvil

The end-to-end suite does exactly this and is the shortest path to a working local system:

```sh
AMPS_E2E=1 pnpm --filter @amplestocks/indexer test:e2e
```

It starts `anvil`, deploys the whole system through the Phase 3 scripts, drives genesis, a swap, a
bond, a compound, a redemption and a real `blockAccounts` call, then runs the indexer against the
resulting chain and asserts, in order: the reconciliation at every block, the denylist alarm, the
journey itself (genesis, the ladders, the fee decomposition, the bond's accretion, the compound's
four-way split, the redemption), the placement reasons and tick ranges, the ladder cross-check
against `LadderPositionValuer`, the bond's vesting term, the measured keeper work value, and the
GraphQL layer. It needs Foundry on `PATH` (or at `/root/.foundry/bin`) and is skipped without
`AMPS_E2E=1`, so `pnpm test` stays offline and toolchain-free — which is what keeps CI's `node` job
green on a runner with no Foundry.

The last full run: **13 reconciliation runs, 0 failures, worst NAV 0 bp and worst `P_ref` 0 bp**;
the valuer cross-check **0 bp across all five pools**; the denylist alarm `critical` in the same
block as the call.

### Tests

```sh
pnpm --filter @amplestocks/indexer test        # offline: pure units + handlers on synthetic logs
pnpm --filter @amplestocks/indexer typecheck
```

The handler tests import the *real* indexing functions (through `src/index.ts`, which is what
registers them) and call them with synthetic events against an in-memory `context.db`. The three
Ponder virtual modules are aliased to test doubles in `vitest.config.ts`.

**Counts.** 121 offline tests across five files — 78 over the pure libraries (`lib` 33, `math` 18,
`fee` 15, `reconcile` 12) and 43 handler tests on synthetic logs — plus 14 end-to-end tests behind
`AMPS_E2E=1`.
The offline suite runs in about four seconds and touches no network; the end-to-end suite takes
about 75 seconds including the Foundry build.

---

## 7. The HTTP layer

`/graphql` is Ponder's generated GraphQL over the whole schema — anything not listed below is one
query away. The typed layer is for the shapes the dApp asks for repeatedly:

| Route | Serves |
|---|---|
| `GET /api/vault` | the summary row, the latest share sample, the latest reconciliation |
| `GET /api/nav-history?since=&limit=` | NAV/share, `A`, `T` over time |
| `GET /api/premium-history` | `P_ref`, `P_mkt`, premium over time |
| `GET /api/share-history` | shares by class over time |
| `GET /api/supply` | net supply change, decomposed |
| `GET /api/burns?reason=` | burn history by reason, with the total |
| `GET /api/creator-fee` | the decaying creator schedule and what it has paid |
| `GET /api/pools` | every registered pool with live state and ladder totals |
| `GET /api/pools/:poolId/ladder` | the ladder cell by cell: side, liquidity, principal, fill, proceeds |
| `GET /api/pools/:poolId/placements` | placements with the action that produced each |
| `GET /api/pools/:poolId/swaps` | swaps with the fee decomposition |
| `GET /api/pools/:poolId/days` | per-day volume, fees, realised LVR, tick range |
| `GET /api/gate` | gate status per pool plus recent transitions |
| `GET /api/bonds` | the bond board and recent purchases |
| `GET /api/bonds/positions/:owner` | one address's positions and claims |
| `GET /api/staking` | xAMPS state and the realised APR |
| `GET /api/flywheel?days=` | the dashboard: sell-fee revenue, bond issuance and accretion, fee revenue vs realised LVR per pool, NAV, premium, net supply change |
| `GET /api/constituents` | the constituent set with status, weights, feed and polled issuer state |
| `GET /api/constituents/:id/multiplier` | the `uiMultiplier` state-diff series |
| `GET /api/alerts?kind=&severity=` | every alert |
| `GET /api/alerts/denylist` | the denylist alarm's own table |
| `GET /api/reconciliation?failing=1` | reconciliation runs and totals |
| `GET /api/keeper` | the keeper-job ledger and bounty payments |
| `GET /api/parameters` | every governed parameter's latest value |

`bigint` does not survive `JSON.stringify`, so every response renders them as decimal strings.
`BigInt(value)` on the way back in is exact; nothing is narrowed to a float.

---

## 8. Known gaps on the contract side

The pre-audit polish slice closed six of the seven gaps this section listed. What follows records
what each was and what the indexer now does instead, because the *shape* of the workaround is what
a reader of the handlers would otherwise still expect to find.

### Closed

1. **`AmpsVault.Placement` now carries `reason`, `lowerTick` and `upperTick`.** ✅ The placement's
   own word — `place` (governance and genesis alike), `spokeSeed`, `compound`, `rollout`, `bonded`
   or `migrate` — decides `placement.action`. The four-byte selector heuristic survives only as the
   fallback for a `reason` the indexer does not recognise, so a placement routed through a multicall
   or a Safe is now classified exactly. `buckets` is the cell count the placement actually wrote
   (`VaultPlacementLib` emits `result.cells`), and the tick range is the range it wrote into, so
   `placement.cells`, `lowerTick` and `upperTick` come straight off the log.
2. **`AmpsVault.Rollout(constituentId, poolId, movedAmps, placedAmps)` exists.** ✅ `rollout_event`
   is the log, not a reconstruction: what left the entry pools and what the destination spoke's
   ladder committed are both stated, and the difference is the residue that stayed idle. The keeper
   ledger takes its `ok`/`noop` outcome from `placedAmps > 0` rather than from the presence of a
   destination `Placement`.
3. **`PoolRegistry.PoolRegistered` now carries `tickSpacing`, `counterDecimals` and `buyFeeBps`,
   and `PoolGridSet(poolId, gridBaseTick)` fires beside `PoolOpened`.** ✅ Registering a pool costs
   **no chain read at all**; `poolConfig(poolId)` and `AmpsHook.buyFeeBps(poolId)` are gone from the
   handlers. `PoolGridSet` lands at a higher log index than `PoolOpened`, so the mirrored grid
   origin correctly overwrites the opening-tick fallback `PoolOpened` seeds for a pool the registry
   could not mirror.
4. **`AmpsBonds.Bond` now carries `vestSeconds`.** ✅ `bond_purchase.vestSeconds` and
   `bond_position.vestSeconds` are log-derived at purchase, so a claim schedule is drawable from the
   index without a lens read. (`AmpsBonds.unvestedOf` and `AmpsBondsLens.unvested`/`unvestedOf` also
   exist now; the reconciliation's share-class sample uses the former for the bond-unvested class.)
5. **`AmpsVault.VestingMinted` now carries `reason`.** ✅ A bond's mint says `"bond"`, so it is
   legible as such without cross-referencing the `Bond` in the same transaction. The accounting rule
   is unchanged and is the one that matters: **`VestingMinted` is the only mint the supply follows**,
   and `Bond.ampsOut` describes that same mint rather than a second one.
6. **`redeemProRata` now emits `Burn(shares, "redeem")`** beside
   `Burn(inventoryBurned, "redeemInventory")`. ✅ Summing the `Burn` events *is* the supply
   reduction, and `AmpsVault:Redeem` no longer moves the supply at all — it records the redemption
   and its NAV pricing only. Both burns are real and both are counted; the redeemer's shares and the
   vault's inventory slice are different AMPS.

The event-derived supply is therefore exactly `S0 + Σ VestingMinted − Σ Burn`, with nothing
inferred, and that is the number the reconciliation compares against `Amps.totalSupply()`.

### Still open

7. **`Placement` carries no per-cell data.** `buckets`, `lowerTick` and `upperTick` bound the write
   but do not say which cells took what liquidity. The ladder is therefore still rebuilt from the
   vault's own `ModifyLiquidity` logs, which is exact and needs no change; the note is only that
   `PlacementRecord` is not directly observable. §4's valuer cross-check is what proves the rebuild
   is right.
8. **The mock aggregators do not emit `AnswerUpdated`.** `contracts/test/mocks/MockAggregator.sol`
   implements the read surface only, so on a local or testnet deployment the raw-round series is
   empty and only `AnswerLatched` populates `feed_answer`. This is a test-fixture gap, not a
   production one.

### Newly available, and used

- **`LadderPositionValuer.amountsOf(poolId)` and `referenceSqrtPriceX96(poolId)`** are what §4's
  ladder cross-check reads. See §4.
- **`BountyPot` measures the work.** `BountyPaid` carries `workValueUsd18` as well as `paidUsd18`
  and `paidRaw`, so `keeper_job.workValueUsd18` and `bounty_payment.workValueUsd18` are the assessed
  value of the job and not a flat allowance. The two are independent: the pot emits `BountyPaid`
  whether or not it can pay, and a zero payment carries the refusal in `reason` (`chost`, `gasCap`,
  `dailyCeiling`, `depleted`). On the end-to-end fixture, which runs `anvil --base-fee 0`, the gas
  allowance is zero and every payment is therefore `gasCap`-refused at a real, non-zero work value —
  which is exactly the pair the tables are meant to distinguish.
- **`AmpsQuoter.PoolQuote` gained a trailing `tickSpacing`.** The indexer does not read the quoter
  (it decomposes the ladder itself), so this is noted only because it moves the struct's shape for
  anything that does.
- **Three reverts became logs, and every one of them is indexed.** The audit's answer to donation
  griefing was the same in each place: a fact a hostile or frozen counterparty could turn into a
  permanent revert is emitted instead, so nothing bricks and the index can see it.
  - `AmpsVault.SweepResidue(token, balance)` replaces the `SweepDirty` revert at the exit of every
    entry point. One `alert` row per residue, kind `sweep-residue`, severity `warning` (§5).
    `SweepDirty` survives as a declaration in `Errors.sol` and the keeper still restates it, so a
    revert from a vault deployed before the change is still named rather than printed as a selector;
    nothing in the audited contracts raises it any more.
  - `AmpsBonds.CollateralForwarded(collateral, amount)` — residual collateral pushed on to the
    vault at the end of `bond()`. It is a donation to the bonds shell and nothing else, so it is
    recorded as one `parameter_change` row (`bonds:collateralForwarded:<marketId>`) and a running
    `bond_market.forwardedCollateral`, and moves no issuance figure. The market is resolved through
    `collateral_index`, because the log names only the collateral.
  - `PoolRegistry.BondMarketDetached(constituentId, marketId)` — `retireConstituent` /
    `reinstateConstituent` found the market gone from `AmpsBonds` and said so rather than reverting,
    which is what stops a removed collateral from making a constituent unretirable forever. It
    writes a `constituent_event` of kind `bondMarketDetached` and sets `bond_market.detached`, the
    same flag `AmpsBonds.CollateralRemoved` sets from the other side.
- **The hook and the registry gained a vault pointer.** `AmpsHook.vault` is storage rather than an
  immutable now, with a `setVault`, and `PoolRegistry` gained the same handover; both announce it
  with `VaultChanged(previousVault, newVault)`. They land in `parameter_state` as
  `hook.pointer:vault` and `registry.pointer:vault`, beside the pointers `AmpsBonds`, `AmpsStaking`,
  `BountyPot` and `Amps` already emit, so a migration is legible from one table.
- **`AmpsHook.rotationCredit()` is now `rotationCredit(address sender)`.** Nothing off-chain reads
  it: the indexer takes the credit from `RotationCreditConsumed` (§3) and the dApp takes it from the
  quoter's simulation, so the signature change touches no handler.

## 9. Licence

MIT, as everything in this repository. See the root `LICENSE`.
