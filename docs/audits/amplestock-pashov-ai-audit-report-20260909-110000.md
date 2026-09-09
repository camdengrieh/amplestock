# 🔐 Security Review — amplestock (re-audit of the revision-7 remediation, `aa95adf`)

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | filename — the twelve source files the 2026-09-08 remediation changed |
| **Files reviewed**               | `AmpsGenesis.sol` · `AmpsHook.sol` · `AmpsQuoter.sol`<br>`AmpsRouter.sol` · `Constants.sol` · `Errors.sol`<br>`Types.sol` · `AmpsVault.sol` · `VaultNavLib.sol`<br>`VaultPlacementLib.sol` · `VaultRedeemLib.sol` · `VaultRolloutLib.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

Twelve hacking agents (math precision, access control, economic security, execution trace, invariant, periphery, first principles, asymmetry, boundary, and the numerical-gap, trust-gap and flow-gap seam hunters) reported 23 findings and 83 leads; deduplicated by (contract, function) and gated per `judging.md` they resolve to the thirteen findings, one demoted lead and one accepted-by-design note below. Most are regressions at the seams of the 2026-09-08 fixes, which is what a re-audit is for.

Completeness: 47 unique (Contract, function) in raw, 47 covered in final.

---

## Findings

[85] **1. The post-swap rail is judged against a fair tick the swap was never quoted against**

`AmpsHook._afterSwap` · Confidence: 85 · [agents: 7]

**Description**
`quoted = _effective(c, d)` freezes the rail before `_refreshGate`, but step 9 measures `devAfter` against the *refreshed* `d.fairTick`, so any gate refresh that moves the fair tick further than the rail makes a swap `_beforeSwap` (and every `AmpsQuoter` surface) accepted revert `BeyondRail`, and the revert rolls the refresh back so the same swap fails again until an opposite-direction trade lands it.

**Fix**

```diff
         Effective memory quoted = _effective(c, d);
+        int24 quotedFair = d.fairTick;
         ...
-        int24 devAfter = _deviation(tick, d.fairTick);
-        if (devAfter > _deviation(previousTick, d.fairTick)) {
+        int24 devAfter = _deviation(tick, quotedFair);
+        if (devAfter > _deviation(previousTick, quotedFair)) {
             if (devAfter > quoted.railTicks) revert BeyondRail(id, devAfter, quoted.railTicks);
```
---

[85] **2. Merging a bid into a sold-ask cell erases the cell's ask flag and hides the buyback**

`VaultPlacementLib._writeRecords` · Confidence: 85 · [agents: 5]

**Description**
`compound`'s counter re-ladder always starts at the cell just below the tick, which after any rise is an ask cell already sold through; the merge branch rewrites `record.above = false` (and adds AMPS wei to counter units in `amount`), so when the price comes back `_burnback` skips the cell (`!record.above`), the bought-back AMPS is never burned and is re-sold, and rollout cannot see it either (I33/I10).

**Fix**

```diff
     // _executePlace: never merge across sides
+    if (record.liquidity != 0 && record.above != p.above) continue; // bucket stays unplaced
     ...
     // _writeRecords: describe a cell only when it is opened
-    record.above = p.above;
+    if (opened) record.above = p.above;
```
---

[85] **3. The creator divisor samples only the sell rate but is applied to the counter fees buys paid**

`VaultPlacementLib._creatorSlice / _chargedFeeBps` · Confidence: 85 · [agents: 2]

**Description**
`_chargedFeeBps` quotes `quoteFee(poolId, true, …)` — the sell direction — while `fees1` (counter) accrue at the buy rate including its dynamic component, so above the fair tick the creator's counter slice is `creatorBps / 500` of fees charged at up to 800 bp (or 2,600 bp under escalation): 1.6x to 4.33x `CREATOR_FEE_BPS` of buy volume, paid out of NAV.

**Fix**

```diff
-        uint256 pips = _probeWord(ctx.marketReference, abi.encodeCall(IAmpsHook.quoteFee, (poolId, true, true, 0, false)), 128);
-        return uint24(pips) / Constants.PIPS_PER_BPS;
+        uint256 sell = _probeWord(ctx.marketReference, abi.encodeCall(IAmpsHook.quoteFee, (poolId, true, true, 0, false)), 128);
+        uint256 buy = _probeWord(ctx.marketReference, abi.encodeCall(IAmpsHook.quoteFee, (poolId, false, true, 0, false)), 128);
+        return uint24(sell > buy ? sell : buy) / Constants.PIPS_PER_BPS;
```
---

[80] **4. A downward multiplier step tolls the losing side and leaves the arbitrage untolled**

`AmpsHook._detectMultiplierStep / _dynamicBps` · Confidence: 80 · [agents: 1]

**Description**
The 2026-09-08 detector arms `captureFeeBps` on `|Δ|` in both directions, but `captureDirectionTakesStock = ctx.sell && spoke` is a constant of the swap direction, so after a `-199 bp` step the AMPS→stock side pays +159 bp for forty minutes while the stock→AMPS side that harvests the mispricing pays nothing (5 bp as hop 1 of a rotation).

**Fix**

```diff
     // _detectMultiplierStep, when arming
+    _setFlag(d, FLAG_STEP_DOWN, current < previous);
     // _dynamicBps
-    captureDirectionTakesStock: ctx.sell && c.poolClass != PoolClass.ENTRY,
+    captureDirectionTakesStock: (hasFlag(d, FLAG_STEP_DOWN) ? !ctx.sell : ctx.sell) && c.poolClass != PoolClass.ENTRY,
```
---

[80] **5. One wei of fee lets anyone take the shared placement cooldown and arm the surge**

`VaultPlacementLib.compound` · Confidence: 80 · [agents: 3]

**Description**
`compound` is permissionless; one wei of AMPS fee makes `burned != 0` and takes the 60 s `cooldown[poolId]` that `place`, `rollout`, `deployBonded` and `withdrawRetiredBids` all honour, and one wei of counter fee makes `placed != 0`, which arms `SURGE_MAX_BPS`, so a dust swap plus a `compound` every minute pins a pool's placement path closed and its dynamic fee near the cap for a few dollars a day.

**Fix**

```diff
     // step 7: re-ladder the counter remainder only when it is worth a placement
-    placed = _placeLadder(ctx, poolId, false, counterRemainder, ...);
+    if (_valueUsd18(ctx, counter, counterRemainder) >= Constants.COMPOUND_PLACE_MIN_USD18) {
+        placed = _placeLadder(ctx, poolId, false, counterRemainder, ...);
+    }
     ...
-    if (placed != 0 || burned != 0) cooldown[poolId] = uint32(block.timestamp);
+    if (placed != 0 || boughtBack != 0) cooldown[poolId] = uint32(block.timestamp);
```
---

[80] **6. An unreadable `state()` skips the guardian's protocol-freeze check**

`AmpsVault._requireGate` · Confidence: 80 · [agents: 1]

**Description**
`_requireGate` returns as soon as the composite `state(0)` read fails (out of gas, short return, bad ordinal), and the cheap `protocolFreezeUntil()` refusal sits *after* that return, so a gated selector sent with a gas limit that starves the 330–390k `state()` read proceeds while the guardian's freeze is live.

**Fix**

```diff
     function _requireGate(uint8 policy) private view {
+        (bool fk, uint256 fw) = _gateRead(abi.encodeCall(IOracleGate.protocolFreezeUntil, ()));
+        if (fk && uint32(fw) > block.timestamp) revert GateNotHealthy(GateState.SCHEDULED_FREEZE);
         (bool known, uint256 word) = _gateRead(abi.encodeCall(IOracleGate.state, (0)));
         if (!known || word > uint256(type(GateState).max)) return;
```
---

[80] **7. The migration's bleed bound compares a reference valuation with realised proceeds**

`AmpsVault.emergencyMigrate` · Confidence: 80 · [agents: 2]

**Description**
`navBefore` is taken with positions valued at `sqrtPrice(P_ref / P_counter)` (I7) while `navAfter` on the standby is realised balances after the unwind at `slot0`, so a pool ~0.8% below the reference (one front-running sell) trips the 50 bp bound and reverts the guardian's evacuation in exactly the incident it exists for.

**Fix**

```diff
-        uint256 navBefore = this.assetsUsd18Of(address(this));   // with positions, at P_ref
         _unlock(ACTION_UNWIND, ...);                                // positions realised into claims
+        uint256 navBefore = this.assetsUsd18Of(address(this));   // realised balances only
         VaultNavLib.evacuate(...);
         uint256 navAfter = this.assetsUsd18Of(standby);
```
---

[80] **8. The redemption's claims-only fallback is starved by an undersized gas reserve**

`VaultRedeemLib.payout` · Confidence: 80 · [agents: 1]

**Description**
`REDEEM_PAYOUT_RESERVE_GAS = 700_000` is held back for the claims fallback, but a cold ERC-6909 transfer per asset costs ~27.5k (≈900k at 32 assets, ≈1.8M at 66), so when the ERC-20 attempt burns its allowance on a hostile constituent — the very case the fallback exists for — the fallback runs out of gas and the structurally ungated redemption reverts.

**Fix**

```diff
-        uint256 reserve = Constants.REDEEM_PAYOUT_RESERVE_GAS;
+        uint256 reserve = 32_000 * tokens.length + 60_000;
+        if (gasleft() < reserve + Constants.REDEEM_PAYOUT_ATTEMPT_GAS) { /* skip straight to claims */ }
```
---

[75] **9. The multiplier field saturates at 18.4467x and silences the detector for good**

`AmpsHook._detectMultiplierStep` · Confidence: 75

**Description**
`uiMultiplierX18` is stored as a `uint64` through a saturating cast, so once a constituent's display multiplier passes `type(uint64).max` (CRWD sits at 4.0x; one 5:1 split crosses it) every reading clips to the same value, `deltaBps` is permanently zero, the small-step branch clears the corporate-action flag and neither the capture toll, the surge nor the freeze ever arms again for that name.

---

[75] **10. Bid ladders anchored at the pool tick can straddle the reference price and trip R1**

`VaultPlacementLib.place (bid branch)` · Confidence: 75

**Description**
Asks anchor at `_referenceTick` but bids at `pool.tick`, so with the pool 1,000–2,600 ticks above the reference (rate-limited `P_ref`, or `REF_DIVERGED`) the top bid cell spans `sqrtPrice(P_ref / P_counter)`, the valuer writes its AMPS half off at zero (I5), `A` drops by up to a third of the placed collateral and the 2 bp R1 bound reverts `deployBonded` and governance bids on a valuation artefact.

---

[75] **11. `spokeWeightBps` answers zero for "unpriceable", which consumers read as the maximum deficit**

`VaultNavLib.spokeWeightBps` · Confidence: 75

**Description**
A dead feed, an absent valuer or an out-of-range reference all return a clean `0`, which `PoolRegistry.currentWeightBps` accepts as a legal weight (discarding its own `targetWeightBps` fail-safe) and `AmpsBonds`/`RolloutPolicy` turn into `deficit = 100%`: the bond discount widens to `dMax` and the rollout weight doubles for that name, the opposite of the direction the NatSpec claims.

---

[75] **12. The rollout window tumbles, so two daily allowances can leave the entry pools in a minute**

`VaultRolloutLib._rollWindow` · Confidence: 75 · [agents: 4, promoted by convergence]

**Description**
The "rolling 24-hour" budget resets `moved` to zero on a hard edge, so a rollout at the last second of one window and another at the first second of the next move `2 × allowance` inside one cooldown; no value leaves the vault, but the limit does not limit what it claims.

---

[75] **13. The entry-pool floor is measured over inventory the harvest refuses to move**

`VaultRolloutLib._askInventory` · Confidence: 75 · [agents: 4, promoted by convergence]

**Description**
`_harvestAsks` skips buyback-reserved cells (`upperTick <= highWater`) but `_askInventory` counts them, so the I32 entry floor and the policy's inventory input are inflated by the bought-back amount and the tradeable ask depth can sit below the governed floor.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [85] | The post-swap rail is judged against a fair tick the swap was never quoted against |
| 2 | [85] | Merging a bid into a sold-ask cell erases the cell's ask flag and hides the buyback |
| 3 | [85] | The creator divisor samples only the sell rate but is applied to the counter fees buys paid |
| 4 | [80] | A downward multiplier step tolls the losing side and leaves the arbitrage untolled |
| 5 | [80] | One wei of fee lets anyone take the shared placement cooldown and arm the surge |
| 6 | [80] | An unreadable `state()` skips the guardian's protocol-freeze check |
| 7 | [80] | The migration's bleed bound compares a reference valuation with realised proceeds |
| 8 | [80] | The redemption's claims-only fallback is starved by an undersized gas reserve |
| 9 | [75] | The multiplier field saturates at 18.4467x and silences the detector for good |
| 10 | [75] | Bid ladders anchored at the pool tick can straddle the reference price and trip R1 |
| 11 | [75] | `spokeWeightBps` answers zero for "unpriceable", which consumers read as the maximum deficit |
| 12 | [75] | The rollout window tumbles, so two daily allowances can leave the entry pools in a minute |
| 13 | [75] | The entry-pool floor is measured over inventory the harvest refuses to move |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **The pass-through claim counter is transaction-scoped while its comment names a block-scoped threat** — `AmpsHook._claimPassThrough` — Code smells: EIP-1153 `tstore` counter, NatSpec claiming it stops "a sandwich" — Seven agents traced the two-transaction hub↔spoke round trip at 70 bp (spoke↔spoke at 20 bp) against the 2,000 bp four `ampsFeeBps` hops would cost. **Gated as accepted by design, not as a finding**: a rotation with a stock leg priced at the pool fees is the fee model the protocol's owner directed (2026-09-07, reconfirmed 2026-09-08), so entering and leaving a constituent position through AMPS at 35 bp is the intended schedule and the round trip is its consequence; on a 100 ms-block chain with a first-come sequencer a per-block guard would only move the split to the next block. The counter bounds *atomic* washes and its NatSpec must say so; the residual (MEV against protocol-owned ladders at pool-fee cost, mitigated by the surge and the rails) is recorded in the fix log and left to the owner.
- **The quoter prices routes the router refuses** — `AmpsQuoter.quoteRotation` — Code smells: no `SameHop`/`NotARotation` mirror — A front end reading `quoteRotation` publishes an entry↔entry or same-pool route that always reverts; a failed transaction rather than a loss (demoted), fixed by returning zeros for those shapes.
- **Typed `try` reads left on pointer-upgradeable targets** — `VaultRolloutLib._answer`, `VaultPlacementLib._highWater`, `VaultPlacementLib._gauntletEntry` — Code smells: typed decode that panics past the `catch` on short or non-canonical returndata, no gas bound on the gate call — The sibling reads were hardened to bounded hand-decoded probes on 2026-09-07/08; a malformed pointer answer bricks placements instead of degrading.
- **The rotation credit is earned without the exact-input test it is spent with** — `AmpsHook._afterSwap` — Code smells: guard present in `_quote`, absent in the credit — Safe only because `AmpsRouter._swap` always builds exact-input hops.
- **`beforeSwap` panics on `amountSpecified == type(int256).min`** — `AmpsHook._beforeSwap` — Code smells: unchecked negation where every other boundary saturates.
- **`quoteSellWithCredit` blends differently from the hook at `ampsIn == 0`** — `AmpsQuoter.quoteSellWithCredit` — Code smells: `credit != 0 && ampsIn != 0` vs the hook's `uncredited == 0`; the dynamic component is sampled with `rotationCredit = 0` while the hook prices hop 2 with the live credit (matters only for a policy that reads that field).
- **`settle()` can run between `endBlock` and `claimBlock`** — `AmpsGenesis._harvest` — Code smells: only `block.number < endBlock` is refused — Whether the auction's `sweepUnsoldTokens` is safe before claiming opens is a property of external bytecode; a one-line `claimBlock` guard removes the question.
- **Unmetered factory-supplied nudge and a half-budget feed probe** — `AmpsGenesis._createLeg`, `AmpsGenesis._feedEthUsdX18` — Code smells: `onTokensReceived()` forwarded unbounded gas; `FEED_READ_GAS = 200_000` where every other consumer gives the registry 400k.
- **The `genesis` pointer's set-once latch fires at `genesisPlace`, not `genesisMint`** — `AmpsVault.setPolicyPointer` — Code smells: `_genesisMinted` exists but no set-once check uses it — Half of `S0` is minted to an adapter whose claim on `genesisPlace` stays revocable for the bidding window.
- **`_referenceSqrtPrice` does not implement the "zero on out-of-domain" contract its NatSpec states** — `VaultNavLib._referenceSqrtPrice` — Code smells: `PriceOutOfTickRange` unguarded — Arithmetically unreachable at launch decimals; a latent revert of the checkpoint.
- **`_placeLadder`'s inventory bound is one wei per cell too tight on the ask side** — `VaultPlacementLib._placeLadder` — Code smells: floor on `getLiquidityForAmount0`, ceiling on the PoolManager's `getAmount0Delta` — Reverts a placement when the vault holds no other idle AMPS.
- **A rollout can burn the daily budget without moving inventory** — `VaultRolloutLib.rollout` — Code smells: `_addRolloutMoved` charged on the harvest, before the destination placement's rollback.
- **`place` takes its cooldown on placement alone although its ask branch burns like `compound`** — `VaultPlacementLib.place` — Code smells: sibling entry points disagree on what counts as work.
- **Hardening asymmetries accepted with a reason**: the unbounded `IPositionValuer.valuePool` read in `VaultNavLib.totalAssetsUsd18` (deferred, needs a checkpoint word); `VaultNavLib.migrationPredicate`'s shape; `VaultNavLib.handover` reading `registry.hook()`; `VaultRedeemLib.sweepClean`'s aggregate gas; `VaultRedeemLib._absorb` re-sync (self-harm only); `VaultPlacementLib._settle`/`VaultRedeemLib.settleFrom` running a token transfer inside the vault's own unlock (a constituent can only block its own spoke); `AmpsVault.depositBonded`'s reliance on the bonds shell to bound the enumeration; `AmpsGenesis._deploy`'s second `create` on a short return (factory ABI verified in Phase 0); `settle()`'s block-timing discretion over the ETH/USD freshness fallback; the missing pre-genesis guard on `compound`/`rollout`/`deployBonded` (deferred earlier); `_weights`' degenerate vectors (unreachable); the `keepBps` factor omitted from the inventory burn (protocol-favourable; NatSpec to be corrected); `AmpsHook._readGate`'s self-referential spoke fallback (design); `_harvestAsks`' sentinel default (self-consistent); the dead `spokeSeedBps` parameter and the registry's unused `place` privilege (revision-7 genesis seeds the spokes; seeding a later-added constituent is a follow-up).

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
