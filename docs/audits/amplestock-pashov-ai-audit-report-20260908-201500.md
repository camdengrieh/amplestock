# 🔐 Security Review — Amplestocks, revision 6 and 7 contracts (`495d54a`)

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | filename                                               |
| **Files reviewed**               | `AmpsHook.sol` · `AmpsRouter.sol` · `AmpsQuoter.sol`<br>`FeePolicy.sol` · `AmpsVault.sol` · `VaultNavLib.sol`<br>`VaultPlacementLib.sol` · `AmpsGenesis.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

Twelve hacking agents (math precision, access control, economic security, execution trace, invariants, periphery, first principles, asymmetry, boundary, numerical gap, trust gap, flow gap) over the revision-6 fee model (hook, router, quoter, fee policy, vault fee split) and the revision-7 genesis (two-step genesis, `AmpsGenesis`). Completeness: 40 unique (Contract, function) in raw, 40 covered in final.

---

## Findings

[90] **1. `compound` arms the maximum surge and resets the buyback mark on a dust AMPS-side fee, with no cooldown**

`VaultPlacementLib.compound` · Confidence: 90 · [agents: 4]

**Description**
Step 8 fires `_resetHighWater` and `_armSurge(SURGE_MAX_BPS)` on `burned != 0`, which a pure fee burn from a dust AMPS sell satisfies, while the 60-second cooldown is written only on `placed != 0`, so an unprivileged caller can pin any pool's dynamic fee at its cap and erase the pending buyback window every block for the price of a dust swap (the bounty pays nothing, so nothing bounds the repetition); a second mechanism renews the cooldown itself with a one-wei bid so governance's `place` and the bountied jobs stay locked out.

**Fix (Option A — rate-limit every effect)**

```diff
-        if (placed != 0) cooldown[poolId] = uint32(block.timestamp);
+        if (placed != 0 || burned != 0) cooldown[poolId] = uint32(block.timestamp);
```

**Fix (Option B — gate the mark on the buyback, not the fee burn)**

```diff
-        if (burned != 0) {
-            _resetHighWater(ctx, poolId);
-            _armSurge(ctx, poolId, "compound");
-        }
+        if (boughtBack != 0) {
+            _resetHighWater(ctx, poolId);
+            _armSurge(ctx, poolId, "compound");
+        }
```
---

[90] **2. `_placeLadder` arms the surge unconditionally and wipes the high-water mark before the buyback ran**

`VaultPlacementLib._placeLadder` · Confidence: 90 · [agents: 4]

**Description**
The tail of `_placeLadder` calls `_armSurge` whenever one cell was committed, so `compound`'s step-7 bid re-ladder of a single wei of counter fee re-arms `SURGE_MAX_BPS` (the exact hole step 8's `burned != 0` gate was written to close); on the ask side it resets the high-water mark unconditionally, so a permissionless `rollout` or `deployBonded` that lands before `compound` permanently erases the buyback window of every cell the price has not yet fully re-crossed (I33); bids also carry no NAV ceiling, so the ladder can buy the protocol's own share above NAV/share and burn it.

**Fix (Option A — arm only for asks of material size)**

```diff
-        if (above && !_resetHighWater(ctx, pool.key.toId())) revert HighWaterResetFailed(pool.key.toId());
-        _armSurge(ctx, pool.key.toId(), reason);
+        if (above) {
+            if (!_resetHighWater(ctx, pool.key.toId())) revert HighWaterResetFailed(pool.key.toId());
+            _armSurge(ctx, pool.key.toId(), reason);
+        }
```

**Fix (Option B — settle the buyback before the mark is reset)**

```diff
+        // an ask placement may only discard a window that has already been settled
+        if (above) _burnback(ctx, pool, records, ...);   // or revert PendingBuyback when a burnable cell exists
         if (above && !_resetHighWater(ctx, pool.key.toId())) revert HighWaterResetFailed(pool.key.toId());
```
---

[85] **3. `rotate` grants the pass-through fee to entry-to-entry routes and to two-call round trips**

`AmpsRouter.rotate` · Confidence: 85 · [agents: 2]

**Description**
`rotate` checks only that the two pools differ and are registered, so `rotate(hub, wethPool)` is a 60 bp USDG↔WETH swap against protocol-owned liquidity where the design charges 1,000 bp (and the entry pools' fair tick is their own TWAP, so `f_dev` is structurally zero), and `rotate(A, B)` followed by `rotate(B, A)` in one transaction reconstructs the round trip `SameHop` refuses at four pass-through fees instead of four AMPS fees, which lowers the sandwich profitability threshold against the vault's ladders about fifty-fold.

**Fix (Option A — require a constituent leg)**

```diff
+        if (registry.poolConfig(hop1).constituentId == 0 && registry.poolConfig(hop2).constituentId == 0) {
+            revert NotARotation(hop1, hop2);
+        }
```

**Fix (Option B — one pass-through hop per pool per transaction)**

```diff
+        // AmpsHook._isPassThrough: a pool already priced pass-through in this transaction pays ampsFeeBps
+        bytes32 slot = keccak256(abi.encode(PASS_THROUGH_TOUCHED, sender, poolId));
+        if (tload(slot) != 0) return false;
+        tstore(slot, 1);
```
---

[85] **4. The creator's slice is divided by the live base fee, not by the fee the volume actually paid**

`VaultPlacementLib._creatorSlice` · Confidence: 85 · [agents: 3]

**Description**
`creatorBps / ampsFeeBps` is applied to fees that accrued earlier and at `base + dyn`, so a governed fee cut retroactively multiplies the creator's share of in-flight fees by `oldFee / newFee` (100% of both currencies at the band floor, and the counter leg leaves NAV rather than being burned), and a raised dynamic fee inflates the payout to 1.6× (GREEN), 3× (degraded) or 5× (escalation cap) of the immutable `CREATOR_FEE_BPS` schedule, all taken out of the unconditional burn.

**Fix (Option A — restore the divisor floor)**

```diff
-        feeBps = _ampsFeeBps(ctx);
+        feeBps = _ampsFeeBps(ctx);
+        if (feeBps < Constants.AMPS_FEE_BPS_DEFAULT) feeBps = Constants.AMPS_FEE_BPS_DEFAULT;
```

**Fix (Option B — divide by the rate actually charged)**

```diff
-        feeBps = _ampsFeeBps(ctx);
+        (uint24 feePips,,) = IAmpsHook(hook).quoteFee(poolId, true, true, 0, false);
+        feeBps = feePips / PIPS_PER_BPS;   // base + dyn at collect time, a conservative bound on the accrued rate
```
---

[85] **5. `_executeHarvest` folds uncollected fees into the harvested principal**

`VaultPlacementLib._executeHarvest` · Confidence: 85 · [agents: 2]

**Description**
`modifyLiquidity` returns `principal + feesAccrued` and `_executeHarvest` keeps only the sum, so `rollout` (via `VaultRolloutLib._harvestAsks`, which never collects) and `withdrawRetiredBids` re-ladder the pool's AMPS-side fees as fresh asks and mint the counter-side fees as claims, bypassing the creator slice and the mandatory burn that `_collectAndSplit` enforces on the `place` path, and `moved` exceeds the rollout allowance the code claims it cannot.

**Fix**

```diff
-        (BalanceDelta callerDelta,) = pm.modifyLiquidity(...);
+        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = pm.modifyLiquidity(...);
+        fees0 += feesAccrued.amount0(); fees1 += feesAccrued.amount1();
+        // return (principal0, principal1, fees0, fees1) and route fees through _split
```
---

[85] **6. `_afterSwap` judges the swap against the rail its own gate refresh just installed**

`AmpsHook._afterSwap` · Confidence: 85 · [agents: 1]

**Description**
`_refreshGate` runs before the post-swap rail check, so at a session close the first swap after the cache expires is priced against the 800-tick REGULAR rail in `beforeSwap` but judged against the 2,310–4,500-tick CLOSED or stale rail in `afterSwap`, letting one swap push a spoke 2.9–5.6× further from fair than the bound in force when it was quoted (the mirror at the open reverts quoted swaps until a deviation-decreasing swap lands).

**Fix**

```diff
-        if (_elapsed(d.gateAttemptedAt) >= _gateCache) { ... _refreshGate(...); }
+        Effective memory e = _effective(c, d);           // the rail the swap was quoted against
+        if (_elapsed(d.gateAttemptedAt) >= _gateCache) { ... _refreshGate(...); }
         ...
-            int24 rail = _effective(c, d).railTicks;
+            int24 rail = e.railTicks;
```
---

[85] **7. `_gasUsed` gives back one EIP-150 reserve on two-hop bounty paths**

`VaultPlacementLib._gasUsed` · Confidence: 85 · [agents: 1]

**Description**
`rollout`, `deployBonded` and `withdrawRetiredBids` reach `payBounty` through two live `DELEGATECALL` frames but the correction returns a single `remaining / 63`, so the reported gas is overstated by about `txGasLimit / 64`, a caller-chosen term that lifts the 3× gas cap (from $7.03 to $11.12 at a 30M limit, and past the daily ceiling at larger limits).

**Fix**

```diff
-        reserved = remaining / 63;
+        reserved = hops == 1 ? remaining / 63 : remaining * 127 / 3969;   // (64^h - 63^h) / 63^h
```
---

[85] **8. The creator's in-kind payout hands a hostile token execution inside the vault's unlock**

`VaultPlacementLib._executeCollect` · Confidence: 85 · [agents: 1]

**Description**
`try pm.take(currency1, creator, creatorCounter)` runs the Stock Token's `transfer` inside the vault's own `unlock`, where a transfer that returns normally but opens its own PoolManager delta makes the unlock fail with `CurrencyNotSettled` beyond the reach of the `catch`, permanently reverting `compound`, `place`, `rollout` and `deployBonded` for that pool during the 30-day creator window; every other unlock-internal token touch in the vault avoids exactly this.

**Fix**

```diff
-        try pm.take{gas: STOCK_TOKEN_PROBE_GAS * 4}(key.currency1, creator, creatorCounter) {} catch { ...claims... }
+        pm.mint(vault, id, counterFees);
+        pm.transfer(creator, id, creatorCounter);   // ERC-6909 only; no token code runs inside the unlock
```
---

[80] **9. The management gate treats the trading calendar's DEGRADED as a refusal**

`AmpsVault._requireHealthy` · Confidence: 80 · [agents: 2]

**Description**
`_requireGate(false)` refuses every state but GREEN and REF_DIVERGED, and `OracleGate.state(0)` is DEGRADED whenever the equity session is CLOSED, so every governed setter, `setStandbyVault`, `setPolicyPointer` (the only way to replace a wrong-but-readable gate), `initializePool`, both genesis steps, `checkpoint()` and `touch()` revert for about 48 hours every week plus holidays with no on-chain remedy for the timelock or the guardian.

**Fix**

```diff
-        bool refuses = gateState != GateState.GREEN && gateState != GateState.REF_DIVERGED;
+        bool refuses = gateState == GateState.DIVERGED || gateState == GateState.SCHEDULED_FREEZE
+            || gateState == GateState.WATCHDOG;   // management paths; placements keep refusing DEGRADED
```
---

[80] **10. `emergencyMigrate` compares a stale checkpoint against a live valuation**

`AmpsVault.emergencyMigrate` · Confidence: 80 · [agents: 2]

**Description**
`navBefore` is the stored `_navPerShareX18`, which cannot be refreshed in the gate states that make a migration necessary because `checkpoint()` is `_requireHealthy`-gated, while `navAfter` is measured live, so ordinary drift of the 24/7 assets (a 2.5% ETH move over a weekend) trips the 0.5% bleed bound and rolls back the whole evacuation; the `NAV_BEFORE` transient word written here is read by nothing.

**Fix**

```diff
-        uint256 navBefore = _navPerShareX18;
+        uint256 navBefore = _navPerShare(_liveAssetsUsd18OrSkip());   // same instant as navAfter; skip the bound if unpriceable
```
---

[75] **11. The multiplier-step detector only fires on upward steps and a 1 bp step erases an armed toll**

`AmpsHook._detectMultiplierStep` · Confidence: 75 · [agents: 5]

**Description**
`deltaBps` is computed only when `current > previous`, so a downward `uiMultiplier()` step of any size arms no capture fee, no surge and no corporate-action flag and can clear a standing flag, while a subsequent 1 bp upward step overwrites an armed 160 bp capture fee with zero inside its own decay window.

---

[75] **12. `createAuctions` bricks on a one-wei donation**

`AmpsGenesis.createAuctions` · Confidence: 75 · [agents: 4]

**Description**
The tranche check is `held != AUCTION_SHARES` on a balance any AMPS holder can raise, and the ownerless adapter has no other exit, so one wei sent between `genesisMint` and `createAuctions` strands half of `S0` forever and halves NAV/share; reachability needs an AMPS holder in that window (the team vesting wallet releases linearly from genesis).

---

[75] **13. The stale-gate substitute widens the refusal rail 5.6×**

`AmpsHook._effective` · Confidence: 75 · [agents: 2]

**Description**
After 15 minutes without a gate read the substitute picks the widest band and derives the rail from it (4,500 ticks against 800 in a healthy REGULAR spoke) while the fair tick falls back to the pool's own TWAP, so the one circuit breaker in the system loosens precisely when its anchor is self-referential.

---

[75] **14. The quoter models only the pre-swap half of the rail check**

`AmpsQuoter.quoteExactIn` · Confidence: 75 · [agents: 2]

**Description**
`refuse`, `wouldRevert` and `quoteRotation` reproduce `beforeSwap`'s start-of-swap test but not `afterSwap`'s post-swap test, and `simulateExactIn` discards the post-swap tick it computed, so a swap that starts inside the rail and ends beyond it quotes as executable and then reverts on chain.

---

[75] **15. Rollout's ask harvest ignores the high-water mark and bid cells satisfy the buyback predicate**

`VaultPlacementLib._burnback` · Confidence: 75 · [agents: 3]

**Description**
`VaultRolloutLib._harvestAsks` selects on the same geometry as `_burnback` minus the high-water clause, so a rollout ordered before `compound` moves bought-back AMPS into a spoke's ask ladder to be re-sold instead of burned; the predicate also admits filled bid cells, whose burn can be NAV-dilutive above NAV/share and, valued counterfactually at the checkpoint's reference, can trip the 2 bp R1 bound and revert `compound`.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | `compound` arms the maximum surge and resets the buyback mark on a dust AMPS-side fee, with no cooldown |
| 2 | [90] | `_placeLadder` arms the surge unconditionally and wipes the high-water mark before the buyback ran |
| 3 | [85] | `rotate` grants the pass-through fee to entry-to-entry routes and to two-call round trips |
| 4 | [85] | The creator's slice is divided by the live base fee, not by the fee the volume actually paid |
| 5 | [85] | `_executeHarvest` folds uncollected fees into the harvested principal |
| 6 | [85] | `_afterSwap` judges the swap against the rail its own gate refresh just installed |
| 7 | [85] | `_gasUsed` gives back one EIP-150 reserve on two-hop bounty paths |
| 8 | [85] | The creator's in-kind payout hands a hostile token execution inside the vault's unlock |
| 9 | [80] | The management gate treats the trading calendar's DEGRADED as a refusal |
| 10 | [80] | `emergencyMigrate` compares a stale checkpoint against a live valuation |
| 11 | [75] | The multiplier-step detector only fires on upward steps and a 1 bp step erases an armed toll |
| 12 | [75] | `createAuctions` bricks on a one-wei donation |
| 13 | [75] | The stale-gate substitute widens the refusal rail 5.6× |
| 14 | [75] | The quoter models only the pre-swap half of the rail check |
| 15 | [75] | Rollout's ask harvest ignores the high-water mark and bid cells satisfy the buyback predicate |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Stale NAV, live supply** — `AmpsVault.spokeWeightBps` — Code smells: checkpointed `navPerShare × live totalSupply` — `mintVesting` and `redeemProRata` move supply without a checkpoint, inflating the deficit term that prices bonds; the bond path re-checkpoints first, other readers may not.
- **Caller-asserted pass-through quote** — `AmpsHook.quoteFee` — Code smells: `passThrough` is a caller flag; the view models a credit on a pass-through buy the hot path never has — publishes a 30 bp figure only the router can obtain; a policy that reads `rotationCredit` would desynchronise the quoter.
- **Permissive enum clamps** — `AmpsQuoter._fillGate` — Code smells: out-of-range ordinals clamp to GREEN/REGULAR with no degraded bit, the opposite of `AmpsHook._snapshotInto` — a malformed gate answer renders as a healthy market. [agents: 3]
- **Pre-genesis checkpoint through placement paths** — `AmpsVault.compound` — Code smells: `compound`/`rollout`/`deployBonded` reach `_checkpoint()` without the `_initialized` guard `checkpoint()`/`touch()` carry — unreachable today only because the scripts open no pool before settlement. [agents: 2]
- **Exact-equality funding on a predictable address** — `AmpsGenesis._createLeg` — Code smells: `held != spec.shares` after a top-up; the CREATE2 address is derivable from the proposal's salt — a pre-donation reverts `createAuctions` until re-proposed with a new salt. [agents: 2]
- **Write-only `PlacementRecord.amount`** — `VaultPlacementLib._writeRecords` — Code smells: gross placements accumulate, removals never decrement, asks and bids sum in different units — off-chain readers over-report inventory. [agents: 2]
- **Two gate policies write the same checkpoint** — `AmpsVault.depositBonded` — Code smells: the bond gate permits DEGRADED where `checkpoint()` refuses; over a weekend the first bond moves `P_ref` with 48 hours of accumulated rate-limit allowance.
- **Migration predicate satisfied by expensive tokens** — `VaultNavLib.migrationPredicate` / `VaultNavLib._selfTransferProbe` — Code smells: a 50k-gas self-transfer probe counts any failure as a denylist — two merely expensive honest tokens authorise the ungated evacuation. [agents: 2]
- **Missing set-once latch on `marketReference`** — `VaultNavLib.setPointer` — Code smells: NatSpec promises "set-once, then exactly once more", code has no latch or counter — the pointer behind the high-water mark and `P_mkt` is freely re-pointable by the timelock. [agents: 2]
- **The NAV walk's one unbounded call and two silent zeros** — `VaultNavLib.totalAssetsUsd18` — Code smells: `IPositionValuer.valuePool` is a plain typed call with no gas cap; an unreadable idle balance counts as zero with no `unconfirmed` flag; a registered asset with no feed reverts — one bad pointer or feed halts checkpoints, bonds and placements. [agents: 4]
- **Freshness flag ignored at settlement** — `AmpsGenesis._launchPrice` / `AmpsGenesis._feedEthUsdX18` — Code smells: reads word 0 of `latestAnswerUsd18` and discards `fresh`/`updatedAt` — a stale ETH/USD sets `P0` on an ETH-only graduation. [agents: 2]
- **Fee-on-transfer counter** — `VaultPlacementLib._settle` — Code smells: `sync → transfer → settle` credits the measured delta — a fee-on-transfer or rebasing counter reverts every placement and router trade in its pool.
- **Cell budget charged for skipped cells, and a global budget** — `VaultPlacementLib._executePlace` — Code smells: `++live` before `_placeCell` returns zero liquidity; one 512-cell budget across up to 66 pools — a strict governance placement can revert with headroom left, or be pinned by cell-walking. [agents: 2]
- **Zero-amount pass-through sell disagreement** — `AmpsQuoter.quoteSellWithCredit` — Code smells: `ampsIn == 0` falls to the AMPS fee where the hook answers the pass-through base.
- **Policy coupling** — `AmpsQuoter._blendedSellFeePips` — Code smells: `dynBps` taken with `passThrough == false` on the assumption the policy ignores `rotationCredit`.
- **Half the revert model** — `AmpsQuoter.wouldRevert` — Code smells: only `beforeSwap`'s refusal is modelled (see finding 14).
- **Requested, not realised, input settled** — `AmpsRouter._buyAction` / `AmpsRouter._settle` — Code smells: `_settle(currency, amountIn)` after a swap that can partially fill at the extreme price limit — an oversized trade reverts with v4's `CurrencyNotSettled` instead of `SlippageExceeded`. [agents: 4]
- **Documented guard absent** — `VaultNavLib._referenceSqrtPrice` — Code smells: NatSpec promises zero for inputs `PriceLib` rejects, the body screens two of four revert sites; its twin in the valuer is `try`-wrapped. [agents: 2]
- **Reverting downcast on `pMkt`** — `AmpsVault._checkpoint` — Code smells: `_toUint128(pMkt)` reverts where the sibling saturates; `pMkt` is the one unbounded checkpoint word.
- **Rate limit dissolves with elapsed time** — `VaultNavLib.referencePrice` — Code smells: `refUpRateBps × elapsed` uncapped — a long quiet period lets the first checkpoint adopt `P_mkt` outright.
- **Sum outside the try/catch** — `VaultPlacementLib._weights` — Code smells: checked `sum += proposed[i]` in the success body — an overflowing policy vector reverts every placement instead of falling back to `LadderLib`.
- **Returndata copy cost** — `VaultNavLib._idleBalance` — Code smells: `bytes memory` return from gas-capped probes — the caller pays quadratic memory expansion across the append-only asset list (about 20 hostile tokens exceed a block).
- **Fee decomposition breaks at the floor** — `AmpsHook._quote` — Code smells: `dynBps` written before the `F_MIN_BPS` clamp adjusts `total` — `fee != base + dyn` when a governed buy fee sits under 3 bp.
- **Typed try/catch on pointer reads** — `VaultPlacementLib._answer` — Code smells: `_answer`, `_answerAt`, `_ampsFeeBps`, `_highWater` decode with typed `try` — a dirty bool or short returndata panics past the `catch`.
- **Same gate, other name** — `AmpsVault._requireGate` — Code smells: the callee of finding 9; the refusal set change belongs here.
- **Dead transient write** — `AmpsVault.emergencyMigrate` (`NAV_BEFORE`) — Code smells: written and cleared, read by nothing, despite NatSpec naming it the relaxed bound's channel. [agents: 2]

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
