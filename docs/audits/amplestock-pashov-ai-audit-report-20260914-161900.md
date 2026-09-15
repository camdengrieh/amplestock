# 🔐 Security Review — Amplestocks, revision 8 (the redemption burn stream, the constituent cap and the auction parameters)

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | filename (the six logic files revision 8 changed, on `main` at `31ca10c`) |
| **Files reviewed**               | `src/vault/VaultRedeemLib.sol` · `src/vault/AmpsVault.sol` · `src/vault/VaultNavLib.sol`<br>`src/vault/VaultPlacementLib.sol` · `src/types/Constants.sol` · `script/06a_GenesisAuction.s.sol` |
| **Confidence threshold (1-100)** | 75                                                     |

Twelve specialised agents (math precision, access control, economic security, execution trace, invariants, periphery, first principles, asymmetry, boundary, numerical gap, trust gap, flow gap) read the same bundle; their raw output (11 findings, 52 leads before deduplication) was deduplicated by contract and function and gated per the four-gate procedure. Completeness: 34 unique (contract, function) pairs in the raw output, 34 covered below.

---

## Findings

[90] **1. The placement bleed bound is measured across the burn stream's settlement**

`AmpsVault._afterPlacement` · Confidence: 90 · [agents: 6]

**Description**
`navBefore` comes from `_previewNav()`, which divides by the live `totalSupply()`, while `navAfter` comes from `_checkpoint()`, whose first statement settles the redemption burn stream and burns AMPS; the two sides of the 2 bp R1 post-condition therefore divide by different supplies, and any pending stream (queued by any redemption) widens the admitted bleed by `burned / T` — 5.9× the bound one hour after a 5% redemption, 63× six hours after a 10% one, 251× at the end of the window — on all five placement entry points, three of them permissionless.

**Fix**

```diff
     function compound(PoolId poolId) external locked returns (uint256 placed) {
         _requirePlaceable();
+        VaultRedeemLib.settleBurnStream(_AMPS);   // both readings on the post-settlement supply
         uint256 navBefore = _previewNav();
```
(the same line at the top of `place`, `rollout`, `deployBonded` and `withdrawRetiredBids`; `_checkpoint`'s own settle then finds nothing due)
---

[85] **2. A dust redemption re-dates the whole inventory-burn window**

`VaultRedeemLib.queueInventoryBurn` · Confidence: 85 · [agents: 7]

**Description**
Every queue rewrites `burnStreamStart = block.timestamp` for the combined pending amount, and the only gate on the path is `inventoryReleased != 0`, which the floor division satisfies for a few tens of wei of shares (3 wei at the launch inventory, ~80 wei with 250 AMPS pending), so a holder can push the deadline of an arbitrarily large outstanding burn out by a full day once per block and turn the specified linear burn into an unbounded geometric tail (36.8% of the queue survives every advertised deadline; `T` stays ~1.6–1.8% above the design figure after a 10% redemption, every bond quote in that window issuing that much more AMPS per dollar of collateral).

**Fix (Option A — amount-weighted restart, recommended)**

```diff
     _setPendingInventoryBurn(pendingBefore + amount);
-    _setBurnStreamStart(block.timestamp);
+    _setBurnStreamStart(
+        pendingBefore == 0
+            ? block.timestamp
+            : FullMath.mulDiv(burnStreamStart(), pendingBefore, pendingBefore + amount)
+                + FullMath.mulDiv(block.timestamp, amount, pendingBefore + amount)
+    );
```

**Fix (Option B — open a window only when none exists)**

```diff
     _setPendingInventoryBurn(pendingInventoryBurn() + amount);
-    _setBurnStreamStart(block.timestamp);
+    if (pendingBefore == 0) _setBurnStreamStart(block.timestamp);
```
---

[85] **3. A settlement capped by the idle balance still re-dates the schedule**

`VaultRedeemLib.settleBurnStream` · Confidence: 85 · [agents: 4]

**Description**
`_setBurnStreamLastSettle(block.timestamp)` runs before the `burned == 0` return, so a settlement that the idle-balance cap truncated or zeroed (the steady state, since the POL lives inside ladders and `_placeLadder` does not exclude the queue) advances the clock without retiring its slice, re-slopes the remaining amount over the shorter remaining time, and a free permissionless `checkpoint()` per block suppresses the burn for the whole window (one call collapses the next settlement by 360×).

**Fix**

```diff
-    burned = burnStreamDue(amps);
-    _setBurnStreamLastSettle(block.timestamp);
-    if (burned == 0) return 0;
+    (uint256 due, uint256 burnable) = _burnStreamDue(amps);   // uncapped and idle-capped
+    if (burnable == due) _setBurnStreamLastSettle(block.timestamp);   // the clock moves only for time the stream was paid for
+    burned = burnable;
+    if (burned == 0) return 0;
```
---

[85] **4. The redemption's inventory base double-counts AMPS already promised to the stream**

`VaultRedeemLib.redemption` · Confidence: 85 · [agents: 6]

**Description**
`inventory = balanceOf(vault) + claim(vault)` is netted of `addedAmps` but never of `pendingInventoryBurn()`, so AMPS a previous redemption already queued is re-sliced by every later one inside the window (over-queue per redemption `= pending × shares / supply`; a 50% exit in slices queues `I·ln 2` = +38.6% over the pro-rata figure, and a cumulative exit past ~63% of supply makes `pending` exceed every wei the vault holds, after which each `checkpoint()` drains the entire idle AMPS inventory); the same function's NatSpec also bounds the split-exit fee residue at "a few basis points", which is false for large exits (+0.78% at a 50% exit, +1.90% at 90%) — a disclosure correction, not a defect.

**Fix**

```diff
     if (addedAmps != 0) inventory = inventory > addedAmps ? inventory - addedAmps : 0;
+    uint256 pending = pendingInventoryBurn();          // post-settlement; `preview` uses pendingInventoryBurn() - due
+    inventory = inventory > pending ? inventory - pending : 0;
     result.inventoryReleased = FullMath.mulDiv(inventory, shares, supply) + releasedAmps;
```
---

[85] **5. `compound`'s bid re-ladder still anchors at the live tick**

`VaultPlacementLib.compound` · Confidence: 85 · [agents: 2]

**Description**
The 2026-09-09 fix made `place` anchor both sides at `_referenceTick(ctx, pool)`, but `compound`'s step-7 bid re-ladder still passes `pool.tick`, so with the pool above a rate-limited or `REF_DIVERGED` reference the top bid cell straddles `sqrtPrice(P_ref / P_counter)`, the valuer writes the AMPS half off at zero (I5/I7), `A` drops by up to a third of the re-laddered counter and R1 reverts the permissionless upkeep path (fee collection, the AMPS burn and the buyback) in exactly the dislocated state it exists for.

**Fix**

```diff
-        placed = _placeLadder(ctx, poolId, pool, false, counter, pool.tick, ...);
+        placed = _placeLadder(ctx, poolId, pool, false, counter, _referenceTick(ctx, pool), ...);
```
---

[80] **6. A stranded idle balance lets the hostile issuer veto the migration it triggered**

`AmpsVault.emergencyMigrate` · Confidence: 80 · [agents: 1]

**Description**
`navBefore` (`assetsUsd18Of(address(this))`) counts idle ERC-20 balances, `evacuate` moves idle balances with a best-effort transfer the denylisting token refuses, and `navAfter` is measured on the standby alone, so an issuer who blocks the vault (the predicate that unlocks the migration) and holds 0.5% of `A` on it as an idle balance — which it can mint — makes the 50 bp bound revert the evacuation.

**Fix**

```diff
-        navAfter = _navPerShare(assetsUsd18Of(standby));
+        navAfter = _navPerShare(assetsUsd18Of(standby) + assetsUsd18Of(address(this)));   // what stayed behind has not leaked; it is disclosed by the residue event
```
---

[75] **7. The per-pool gate read is capped below what the probed token can burn**

`VaultPlacementLib._gauntletEntry` · Confidence: 75 · [agents: 2]

**Description**
`checkPlacement{gas: COMPOSITE_READ_GAS}` (400,000) is a typed, uncaught call whose per-pool snapshot runs four 50,000-gas probes inside the constituent's own Stock Token plus two feed reads and two TWAPs, so an upgraded token that burns its probes starves the read and `place`/`compound` revert for that pool; the protocol-wide read of the same gate is budgeted 1,500,000, and `VaultRolloutLib._gauntlet` makes the same call with no bound at all.

**Fix**

```diff
-        IOracleGate(ctx.oracleGate).checkPlacement{gas: Constants.COMPOSITE_READ_GAS}(poolId);
+        IOracleGate(ctx.oracleGate).checkPlacement{gas: Constants.GATE_READ_GAS}(poolId);
```
(and the same bound on `VaultRolloutLib._gauntlet`)
---

[75] **8. Bid cells the price falls through never close, so the live-cell budget ratchets**

`VaultPlacementLib._executePlace` · Confidence: 75 · [agents: 1] — promoted from a lead (reachable, unguarded path)

**Description**
Each `compound` bid re-ladder opens a new cell for every doubling of downward drift, a bid cell the price has fallen through holds bought-back AMPS with `record.above == false`, which `_burnback` and the rollout harvest both skip, so cells accumulate up to the 24-cell grid per pool against a 512-cell budget sized for 14 per pool, and once the budget is full the strict-budget `place` path (constituent seeding) reverts `CellBudgetExceeded` for good — while revision 6 specifies that AMPS bought back by bids is burned.

---

[75] **9. The placement forwarders lack the pre-genesis latch their siblings carry**

`AmpsVault.compound` · Confidence: 75 · [agents: 3] — multi-agent convergence

**Description**
`checkpoint()` and `touch()` refuse before genesis with `NotInitialized`, but `place`, `compound`, `rollout`, `deployBonded` and `withdrawRetiredBids` reach the same `_checkpoint()` through `_afterPlacement` without it, so with the gate pointer unset an unprivileged call stamps `checkpointTimestamp`/`checkpointBlock` before genesis and removes the `StaleCheckpoint` backstop `depositBonded` documents; unreachable only because the deploy script registers pools after `genesisPlace`.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | The placement bleed bound is measured across the burn stream's settlement |
| 2 | [85] | A dust redemption re-dates the whole inventory-burn window |
| 3 | [85] | A settlement capped by the idle balance still re-dates the schedule |
| 4 | [85] | The redemption's inventory base double-counts AMPS already promised to the stream |
| 5 | [85] | `compound`'s bid re-ladder still anchors at the live tick |
| 6 | [80] | A stranded idle balance lets the hostile issuer veto the migration it triggered |
| 7 | [75] | The per-pool gate read is capped below what the probed token can burn |
| 8 | [75] | Bid cells the price falls through never close, so the live-cell budget ratchets |
| 9 | [75] | The placement forwarders lack the pre-genesis latch their siblings carry |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Creator slice divided by the collection-time rate** — `VaultPlacementLib._creatorSlice` — Code smells: instantaneous `chargedFeeBps` divisor against fees accrued at a higher, decaying dynamic rate — A `compound` timed after the surge and deviation terms decay pays the creator up to 5× `CREATOR_FEE_BPS` of volume out of the burn and NAV; the beneficiary is the creator role, so demoted; the closing fix is a per-pool peak charged rate kept by the hook since the last collection.
- **Ladder-policy answer decoded inside a typed `try`** — `VaultPlacementLib._weights` — Code smells: dynamic-array decode of untrusted returndata in the caller's frame — A policy that answers with empty or malformed bytes reverts every placement instead of falling back to `LadderLib`; needs a bad 7-day pointer, so demoted; a bounded `staticcall` with a hand-decode closes it.
- **The standby vault's 14-day tier is enforced only by convention** — `AmpsVault.setStandbyVault` — Code smells: `TIMELOCK_STANDBY_SECONDS`/`TIMELOCK_SLOW_SECONDS` read by no contract; one timelock `minDelay` of 48 h — The address the no-delay guardian migration hands the estate to is reachable with 48 h of notice; stamping the registration and requiring the 14-day age in `emergencyMigrate` enforces the tier on chain.
- **The vault's gate policies read the protocol-wide snapshot** — `AmpsVault._requireGate` / `_requireBondsHealthy` — Code smells: `state(0)` skips layers C, D and E; the `DIVERGED` term is unreachable — The documented bond-side defence in depth covers no per-constituent freeze; correct the NatSpec or pass the constituent id through `depositBonded`.
- **The absorb's pre-unlock transfer can be intercepted or stranded** — `VaultRedeemLib._absorb` — Code smells: `sync` outside the unlock, transfer before it, `settle` silent on failure, residue event conditioned on a balance the failure erases — A hostile token can credit the moved balance to itself or leave it uncredited with no event; dust by I12; re-sync inside the unlock before `settle` and compare the credit with the amount moved.
- **The asset list has no on-chain cap** — `AmpsVault._registerAsset` / `VaultNavLib.genesisSettle` — Code smells: three writers, `params.tokens` unbounded, the redemption gas budget asserted against `MAX_COLLATERALS` — Enforce `MAX_COLLATERALS` in both `_registerAsset` implementations.
- **The index weight mixes a checkpointed NAV with the live supply** — `AmpsVault.spokeWeightBps` — Code smells: `A` reconstructed as `_navPerShareX18 × totalSupply()` — Burns and vesting mints between checkpoints bias every spoke weight (the bond discount's deficit term and the rollout schedule); any `checkpoint()` clears it; value `A` live or with the checkpoint's own supply.
- **The R10 `+ tickSpacing` term can re-admit a straddling top bid cell** — `VaultPlacementLib._cells` — Code smells: `fromAnchor` computed from the down-aligned anchor plus a spacing — For ~0.4% of reference positions the top bid cell's upper bound sits above the exact reference and a large bid placement (≳8% of `A`) reverts R1; derive the bound from the exact reference tick or drop the term.
- **Placement guards fail open when the counter feed cannot answer** — `VaultPlacementLib._referenceTick` / `_requireConverged` — Code smells: the same `answerUsd8 == 0` skips the divergence check and anchors asks at the live tick; the conversion uses the reverting `fairTick` form — Refuse ask placements on an unreadable answer and use the `OrZero` conversion; the gate's `DEGRADED` refusal should stand in front, out of this bundle.
- **`sweepClean` and the payout tail sit outside the redemption's gas reserve** — `VaultRedeemLib.payout` / `sweepClean` — Code smells: reserve sized for the claims-only unlock alone (and ~2.5k/asset short at the cap); the exit sweep has no `gasleft()` guard — A tight caller gas limit or many simultaneously hostile issuers can revert the floor; resize the reserve from a measurement and guard the sweep on the redemption path.
- **The idle payout leg is charged but not guaranteed** — `VaultRedeemLib.payout` — Code smells: `_tryTransfer` result discarded, leg skipped under `STOCK_TOKEN_PROBE_GAS × 8` — A paused or denylisting constituent's idle balance is not delivered and is re-absorbed for the remaining holders while `previewRedeem` reports it; dust by I12.
- **The valuer is the one unbounded, typed read in `A`** — `VaultNavLib.totalAssetsUsd18` — Code smells: `valuePool` called without a gas bound or hand-decode at three sites — A reverting, short-answering or looping valuer bricks `checkpoint`, bonds and placements until a 7-day pointer change; bound and hand-decode like every other pointer read.
- **A position that cannot be priced is counted as no position** — `VaultNavLib.totalAssetsUsd18` — Code smells: `_referenceSqrtPrice == 0` drops the term silently and `balance == 0` skips the `unconfirmed` flag — `A` can fall by a constituent's whole weight with the checkpoint reading as confirmed; set `unconfirmed`.
- **The reference price's rate limit compounds and self-references** — `VaultNavLib.referencePrice` — Code smells: simple-interest cap per checkpoint interval; the NAV branch has no rate limit and `A` is valued at the previous reference — `e^{rT}` instead of `1 + rT`, and a fixed-point walk bounded by `A_other/(T − askAmps)`; accepted design (I7, lead L-1) with the `nav-drift` alert.
- **The migration predicate's probe is a zero-value self-transfer** — `VaultNavLib.migrationPredicate` — Code smells: `amount = balance ≥ 1 ? 1 : 0` with a habitually zero balance, 50,000 gas — Two constituents that reject zero-value or self transfers, or exceed the cap, satisfy the predicate permanently; measure against the real Stock Tokens in Phase 0.
- **Two readers disagree on a well-formed feed answer** — `VaultNavLib.answer` — Code smells: `≥ 32` bytes accepted here, `≥ 96` on the placement path — A malformed registry is trusted by NAV and read as absent by placements; align both to the interface's 96 bytes.
- **The counter token is called inside the vault's unlock** — `VaultPlacementLib._settle` — Code smells: `sync → transfer → settle` with the return discarded — A hostile constituent can revert placements into its own pool from inside the unlock; a constituent can only block its own spoke (wave-4 disposition).
- **Grid clipping and tick-range refusal disagree at the extremes** — `VaultPlacementLib._placeCell` — Code smells: `_cells` clips to the grid while `_requireOnGrid` reverts at `MIN_TICK`/`MAX_TICK` — Unreachable at launch decimals.
- **The redemption realises positions at the pool price while `A` values them at the reference** — `VaultRedeemLib.redemption` — Code smells: I7 basis vs live unwind — NAV understates realised proceeds during a rate-limited rally; accepted (SP-14 lead, `redeem-gap` alert).
- **The redemption's AMPS fees become ask inventory** — `VaultRedeemLib.unwind` — Code smells: `fees0` minted as a claim and swept to idle, never routed through the creator slice and the burn — The only fee realisation outside the split; queue `fees0` into the burn stream on the ungated path.
- **`record.amount` is not pro-rated by the redemption** — `VaultRedeemLib.unwind` — Code smells: `Types.PlacementRecord.amount` NatSpec promises the pro-ration — `ladderAt` over-reports every touched cell to the indexer and dApp; pro-rate it.
- **`_armSurge` is a typed `try` on a `void` function** — `VaultPlacementLib._armSurge` — Code smells: compiler `extcodesize` screen before the `catch`, unlike its hardened sibling `_resetHighWater` — Consistency defect; use the bounded low-level call.
- **The vault never checks that `currency0` is AMPS** — `AmpsVault.initializePool` — Code smells: `unwind` and `_placeLadder` assume it; only the registry enforces it — One cheap revert on the invariant the vault rests on.
- **The ETH/USD read discards the registry's freshness flag** — `GenesisAuction._feedEthUsdX18` — Code smells: `(answer, , )` — A stale-but-non-zero answer prices the ETH auction floor and graduation bar; require `fresh` or the explicit override.
- **The inventory bound's rounding rationale is wrong in the safe direction** — `VaultPlacementLib._placeLadder` — Code smells: NatSpec claims a one-wei-per-cell overshoot that the floor/ceil pair cannot produce — Calibration only.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
