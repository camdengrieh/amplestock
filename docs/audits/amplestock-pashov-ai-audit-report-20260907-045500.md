# 🔐 Security Review — Amplestocks ($AMPS) contracts

Pre-fix review of the working tree at `89e451d` on `claude/amplestocks-rwa-token-xhtnn5` (Phase 6 polish included), produced with the Pashov `solidity-auditor` skill: twelve specialised hacking agents (math precision, access control, economic security, execution trace, invariant, periphery, first principles, asymmetry, boundary, numerical gap, trust gap, flow gap) ran independently over the bundled source, and the orchestrator deduplicated, gated (attack execution → reachability → trigger → impact) and scored the result. The companion x-ray report lives in [`x-ray/x-ray.md`](x-ray/x-ray.md). Fix status per finding is recorded in [`fix-log.md`](fix-log.md) once the remediation slice lands.

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | `contracts/src` (default exclude pattern; `src/lib/*` protocol libraries included, `interfaces/` excluded) |
| **Files reviewed**               | `Amps.sol` · `AmpsVault.sol` · `VaultNavLib.sol`<br>`VaultPlacementLib.sol` · `VaultRedeemLib.sol` · `VaultRolloutLib.sol`<br>`LadderPositionValuer.sol` · `ZeroPositionValuer.sol` · `AmpsHook.sol`<br>`HookStateLib.sol` · `PriceLib.sol` · `LadderLib.sol`<br>`TruncatedOracleLib.sol` · `PoolStateLib.sol` · `AmpsBonds.sol`<br>`AmpsBondsLens.sol` · `BondPolicy.sol` · `LadderPolicy.sol`<br>`FeePolicy.sol` · `RolloutPolicy.sol` · `OracleGate.sol`<br>`FeedRegistry.sol` · `GatePriceMath.sol` · `StreamsSchemaLib.sol`<br>`PoolRegistry.sol` · `PoolRegistryLens.sol` · `AmpsStaking.sol`<br>`BountyPot.sol` · `AmpsQuoter.sol` · `QuoterSwapLib.sol`<br>`Types.sol` · `Constants.sol` · `Errors.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

Completeness: 54 unique (Contract, function) in raw, 54 covered in final.

Chains: `[3] + [8]` — one wei of a denylisting Stock Token donated to the vault after the issuer blocks it stops both the redemption floor (sweep absorb reverts) and the escape hatch (`evacuate` reverts), conf 82. `[13] + [9]` — an aged pending jump lets any later round through unconfirmed, and a held-back or unconfirmed round is priced by the bond floor with a calendar-only haircut, conf 78.

---

## Findings

[92] **1. A one-wei donation permanently bricks a bond market**

`AmpsBonds._issue` · Confidence: 92 · [agents: 3]

**Description**
`_issue` ends with `if (IERC20(collateral).balanceOf(address(this)) != 0) revert SweepDirty(...)`, an assert with no absorb step and no rescue function on an immutable shell whose vault pointer is set-once, so anyone can close any collateral's market forever by transferring one wei of it to `AmpsBonds` (~34 wei closes the protocol's only post-genesis issuance path; `removeCollateral`+`addCollateral` re-reads the same balance).

**Fix**

```diff
-        uint256 dust = IERC20(collateral).balanceOf(address(this));
-        if (dust != 0) revert SweepDirty(collateral, dust);
+        uint256 dust = IERC20(collateral).balanceOf(address(this));
+        if (dust != 0) {
+            // Forward, never assert: the vault's sweep absorbs it as a claim. Best effort so a token that
+            // refuses to move cannot close the market either.
+            (bool ok,) = collateral.call(abi.encodeCall(IERC20.transfer, (vault, dust)));
+            emit CollateralForwarded(collateral, dust, ok);
+        }
```
---

[90] **2. One paused or denylisting constituent blocks every redemption**

`VaultRedeemLib._payOut` · Confidence: 90 · [agents: 2]

**Description**
The redemption payout is an all-or-nothing loop that calls `pm.take(currency, to, claimPart)` (a real ERC-20 transfer) for every registered asset, so a single issuer pausing one of the 30 Stock Tokens, or blocking the redeemer, makes `redeemProRata` revert for every holder while the documented floor is "structurally unpausable"; `emergencyMigrate` inherits the same payout.

**Fix**

```diff
-                pm.burn(address(this), currency.toId(), claimPart);
-                pm.take(currency, to, claimPart);
+                try pm.take(currency, to, claimPart) {
+                    pm.burn(address(this), currency.toId(), claimPart);
+                } catch {
+                    // The token refused the transfer: hand the redeemer the ERC-6909 claim instead, which no
+                    // ERC-20 pause or denylist can block; they `take` it once the issuer relents.
+                    pm.transfer(to, currency.toId(), claimPart);
+                }
             }
             uint256 idlePart = fromIdle[i];
-            if (idlePart != 0) IERC20(tokens[i]).safeTransfer(to, idlePart);
+            if (idlePart != 0) tokens[i].call(abi.encodeCall(IERC20.transfer, (to, idlePart)));
```
---

[88] **3. The exit sweep makes unguarded calls into every registered token on the ungated path**

`VaultRedeemLib.sweepClean` · Confidence: 88 · [agents: 2]

**Description**
`sweepClean` runs at the end of `redeemProRata` (and every other vault entry point), calls `balanceOf` unguarded on every registered asset, absorbs any idle balance with a reverting `safeTransfer` to the PoolManager and then reverts `SweepDirty` on residue, so a one-wei donation of a paused or denylisting Stock Token (or a token whose `balanceOf` reverts) bricks redemption for everyone and every gated path with it.

**Fix**

```diff
-            uint256 balance = IERC20(token).balanceOf(address(this));
+            (bool ok, uint256 balance) = _boundedBalance(token); // gas-capped staticcall, hand-decoded
+            if (!ok) continue;
 ...
-        for (uint256 i; i < count; ++i) {
-            uint256 balance = IERC20(dirty[i]).balanceOf(address(this));
-            if (balance != 0) revert SweepDirty(dirty[i], balance);
-        }
+        for (uint256 i; i < count; ++i) {
+            (, uint256 balance) = _boundedBalance(dirty[i]);
+            if (balance != 0) emit SweepResidue(dirty[i], balance); // never revert on the ungated path
+        }
```
(and inside `ACTION_ABSORB`: `sync` → low-level `transfer` to the PoolManager with SafeERC20-style return handling → `settle`+`mint` only when the transfer succeeded, skipping the token otherwise.)
---

[85] **4. Bid cells are treated as bought-back inventory and re-laid a doubling lower on every compound**

`VaultPlacementLib._burnback` · Confidence: 85 · [agents: 4]

**Description**
The buyback predicate `liquidity != 0 && upperTick <= highWater && pool.tick < upperTick` has no side term and `compound` places bids (step 7) before resetting the high-water mark to the current tick (step 8), so every bid cell qualifies from birth and a one-tick move into the top bid cell lets the next permissionless `compound` withdraw it whole, burn the AMPS it bought and re-lay its counter one full doubling lower — a one-way ratchet of the bid ladder every 61 s.

**Fix**

```diff
-            if (record.liquidity == 0 || record.upperTick > highWater || pool.tick >= record.upperTick) continue;
+            // Only a cell the price has fully crossed back through holds nothing but bought-back AMPS.
+            if (record.liquidity == 0 || record.upperTick > highWater || pool.tick >= record.lowerTick) continue;
```
(and reset the high-water mark after every ask placement, not only inside `compound`, so a fresh ask can never satisfy `upperTick <= highWater`.)
---

[85] **5. A zero-work compound arms the maximum surge, wipes the high-water mark and takes the pool's cooldown**

`VaultPlacementLib.compound` · Confidence: 85 · [agents: 1]

**Description**
`_resetHighWater`, `_armSurge(SURGE_MAX_BPS)` and `cooldown[poolId] = now` run unconditionally even when nothing was collected, burned or placed, so anyone can pin a pool's dynamic fee at its cap (buy fee 5 bp → 255–305 bp on a spoke) for the cost of one call per 60 s, suppress the buyback burn indefinitely and race the vault's own `place`/`rollout`/`deployBonded` out of the pool.

**Fix**

```diff
-        _resetHighWater(ctx, poolId);
-        _armSurge(ctx, poolId, "compound");
-        _requireConverged(ctx, poolManager, poolId, pool.config);
-        cooldown[poolId] = uint32(block.timestamp);
+        bool worked = burned != 0 || split.relaid != 0 || counter != 0;
+        if (burned != 0 || split.relaid != 0) _resetHighWater(ctx, poolId);
+        if (worked) {
+            _armSurge(ctx, poolId, "compound");
+            cooldown[poolId] = uint32(block.timestamp);
+        }
+        _requireConverged(ctx, poolManager, poolId, pool.config);
```
---

[85] **6. The creator slice divides realised fees by the base sell fee**

`VaultPlacementLib._split` · Confidence: 85 · [agents: 5]

**Description**
`creatorPaid = ampsFees × creatorBps / ampsFeeBps` assumes fees were collected at exactly `ampsFeeBps`, but the hook charges `base + dyn`, so the creator is over-paid by `(base + dyn) / base` (+20 % every weekend under the 100 bp degraded floor, +60 % inside the surge `compound` itself arms, 5× at the escalation cap) out of the staker, burn and re-ladder slices, and because `AMPS_FEE_BPS_MIN == CREATOR_FEE_BPS == 100` an in-band `setAmpsFeeBps(100)` makes the ratio exactly 1 and routes 100 % of accrued AMPS-side fees to the creator.

**Fix (Option A — cap the divisor)**

```diff
-        uint256 ampsFeeBps = _ampsFeeBps(ctx);
+        uint256 ampsFeeBps = _ampsFeeBps(ctx);
+        // The slice is defined against the launch base rate: a fee cut can never enlarge it (ratio <= 1/5).
+        if (ampsFeeBps < Constants.AMPS_FEE_BPS_DEFAULT) ampsFeeBps = Constants.AMPS_FEE_BPS_DEFAULT;
```

**Fix (Option B — track volume)**

```diff
+        // In AmpsHook._afterSwap: accumulate per-pool AMPS sell volume; compound reads and clears it and pays
+        // creatorPaid = sellVolume x creatorBps / BPS, the schedule as documented.
```
---

[85] **7. A permissionless pre-genesis checkpoint opens every pool a thousand times too low**

`AmpsVault.checkpoint` · Confidence: 85 · [agents: 1]

**Description**
`checkpoint()` has no genesis guard and the gate pointer is deliberately unset during pool registration, so with `totalSupply() == 0` `_navPerShare` writes `pRefX18 = (0 + 1) × 1e18 / (0 + 1000) = 1e15`, `PoolRegistry._referencePriceUsd18` only falls back to $1 when the reference is zero, and every pool registered afterwards opens at $0.001 on a grid that cannot be re-initialised (a one-unit USDG donation after the hub registers pushes it to $1e9 instead).

**Fix**

```diff
     function checkpoint() external locked returns (Checkpoint memory snapshot) {
+        if (!_initialized) revert NotInitialized();
 ...
     function _navPerShare(uint256 assetsUsd18) private view returns (uint256) {
-        return FullMath.mulDiv(assetsUsd18 + 1, Constants.WAD, IAmps(_AMPS).totalSupply() + Constants.VIRTUAL_SHARES);
+        uint256 supply = IAmps(_AMPS).totalSupply();
+        if (supply == 0) return 0;
+        return FullMath.mulDiv(assetsUsd18 + 1, Constants.WAD, supply + Constants.VIRTUAL_SHARES);
```
---

[82] **8. The evacuation reverts on an idle balance of the very token that triggered it**

`VaultNavLib.evacuate` · Confidence: 82 · [agents: 3]

**Description**
The idle-ERC-20 leg of `evacuate` is a reverting `safeTransfer` (the NatSpec calls it best effort) and `emergencyMigrate` ends with `_assertSweepZero()`, so a one-wei idle balance of a token whose issuer has denylisted the vault — which `sweepClean` can no longer absorb — makes the guardian's only migration path revert.

**Fix**

```diff
-            uint256 idle = IERC20(token).balanceOf(address(this));
-            if (idle != 0) IERC20(token).safeTransfer(standby, idle);
+            uint256 idle = IERC20(token).balanceOf(address(this));
+            if (idle != 0) token.call(abi.encodeCall(IERC20.transfer, (standby, idle))); // best effort
 ...
-        _assertSweepZero();
+        // No sweep assertion on the migration path: residue that cannot move must not stop the evacuation.
```
---

[80] **9. Bonds price a held-back or stale collateral answer with a calendar-only haircut**

`AmpsBonds._price` · Confidence: 80 · [agents: 2]

**Description**
`_collateralPriceUsd18` discards `latestAnswer`'s `fresh` flag, the registry reports a held-back jump as the pre-jump answer with the pre-jump timestamp (so `fresh` stays true for up to a heartbeat), and `checkBond` returns `hSessionBps(session)` — a calendar table — so after a >10 % single-round drop a bonder can buy the crashed token at market and bond it at the pre-crash floor with a 0 bp haircut (~16 % of the bonded notional per event, bounded by epoch and daily capacity); entry-class markets skip the freshness layer entirely.

**Fix**

```diff
-        (uint256 answerUsd8,,) = IFeedRegistry(...).latestAnswer(record.collateral);
+        (uint256 answerUsd8,, bool fresh) = IFeedRegistry(...).latestAnswer(record.collateral);
+        if (!fresh && haircutBps < _closedHaircutBps()) haircutBps = _closedHaircutBps();
```
(and in `FeedRegistry._read`, report `min(held, candidate)` with `unconfirmed = true` while a jump is held, and in `OracleGate._snapshot` treat `unconfirmed` as `feedStale`.)
---

[80] **10. `deployBonded` never checks the constituent's status**

`VaultRolloutLib.deployBonded` · Confidence: 80 · [agents: 1]

**Description**
The function tests only `constituent.token != address(0)`, so 61 seconds after the timelock's `withdrawRetiredBids` moves a retired spoke's bids into claims, any keeper can `deployBonded(retiredId)` and re-make the whole market as bids in the retired pool for a bounty, indefinitely, and can burn the vault-wide live-cell budget so the governance `place` path reverts `CellBudgetExceeded`.

**Fix**

```diff
         ConstituentConfig memory constituent = IPoolRegistry(registry).constituent(constituentId);
         if (constituent.token == address(0)) revert UnknownConstituent(constituentId);
+        if (constituent.status != ConstituentStatus.ACTIVE) return 0;
```
---

[78] **11. The migration predicate decodes untrusted returndata with `abi.decode(..., (bool))`**

`VaultNavLib.migrationPredicate` · Confidence: 78 · [agents: 2]

**Description**
`isBlocked(vault)` and the self-transfer probe are gas-bounded raw calls whose 32-byte result is then `abi.decode`d as `bool`, which panics in the vault's frame on any word other than 0 or 1, so a Stock Token upgraded to return `2` bricks `emergencyMigrate` — the escape hatch built for exactly that issuer (verified with a solc 0.8.30 PoC).
---

[78] **12. `emergencyMigrate` hands over four vault roles but not the hook's or the registry's**

`AmpsVault.emergencyMigrate` · Confidence: 78 · [agents: 1]

**Description**
`AmpsHook.vault` is immutable and `PoolRegistry._vault` has no setter, so after an evacuation the standby can never initialise a pool, add liquidity or arm a surge (`NotVault`), while the registry keeps opening pools and registering assets into the abandoned vault.
---

[78] **13. An expired pending jump confirms any later candidate**

`FeedRegistry._jumpConfirmed` · Confidence: 78 · [agents: 4]

**Description**
The `confirmSeconds` escape returns `true` before comparing the candidate to the pending level, so one permissionless `refresh` that plants a pending record disarms the two-confirmation rule for that token: after the window, a later single-round move of any size (a $180 → $9,000 round in the trace) is adopted on sight by every consumer.
---

[75] **14. The jump rule disarms once the latch is a heartbeat old, and nothing in production advances the latch**

`FeedRegistry._isJump` · Confidence: 75 · [agents: 3]

**Description**
`_isJump` returns false when the candidate is more than one heartbeat newer than the accepted latch, the latch advances only through the unpaid `refresh`/`refreshMany` (called by no contract and not by the keeper), and every consumer reads through the `view` `_read`, so in the default deployment the >10 % guard is off after one heartbeat and, in the opposite direction, a move that does get held is held indefinitely rather than for `confirmSeconds`.
---

[75] **15. The shell validates the policy's price but mints the policy's quantity**

`AmpsBonds._price` · Confidence: 75 · [agents: 4]

**Description**
`_price` (and the view `_quote`) checks `output.qX18 > floorX18` and then copies `output.ampsOut` verbatim without deriving it from `qX18`, so the documented "a hostile or buggy policy can refuse to price but never issue a dilutive bond" holds only for the number that is not minted; a policy returning `qX18 = 0, ampsOut = huge` mints the full epoch/daily capacity against one wei (privileged precondition: a replaced or buggy `BondPolicy`).
---

[75] **16. `compound` re-lays asks at the live tick instead of the reference anchor**

`VaultPlacementLib.compound` · Confidence: 75 · [agents: 4]

**Description**
`place`, `rollout` and `deployBonded` anchor ask ladders at `tickOf(P_ref / P_counter)` ("no ask below P_ref", I32) but `compound` passes `pool.tick`, so after a drawdown fee AMPS is offered below the reference and the first re-laid cell can straddle the reference price, where `LadderPositionValuer` credits its AMPS half to `A` as counter asset it does not hold — an overstatement that feeds `P_ref` and grows with each compound.
---

[75] **17. The rotation credit is one transaction-global slot shared by every sender and pool**

`AmpsHook._credit` · Confidence: 75 · [agents: 2]

**Description**
`_credit` adds any buyer's realised AMPS to `ROTATION_CREDIT_SLOT` and `_beforeSwap` spends it for any exact-input sell in the same transaction, ignoring the `sender` both callbacks receive, so a filler settling a victim's buy alongside its own sell pays the buy fee instead of the sell fee (470 bp of the size), and credit earned in the deep hub discounts a sell into a thin spoke fourteen-fold.
---

[72] **18. The fail-open gate read does not fail open for a codeless or malformed gate**

`AmpsVault._requireGate` · Confidence: 72 · [agents: 1]

**Description**
A typed `try IOracleGate(gate).state(0)` does not catch a codeless target (the call succeeds with empty returndata and the decode reverts in the caller), an out-of-range enum or short returndata, and the void `try poke()` reverts on the compiler's extcodesize check; `setPolicyPointer` accepts a codeless address and calls `_requireHealthy` first, so one mistyped pointer permanently bricks every gated path including the one that would fix it (verified with a solc 0.8.30 PoC).
---

[70] **19. The multiplier-step detector compares a saturated cache with a full-width probe**

`AmpsHook._detectMultiplierStep` · Confidence: 70 · [agents: 1]

**Description**
`a.uiMultiplierX18 = _toUint64(m)` saturates at `type(uint64).max` (~18.45e18) while `deltaBps` is computed from the un-saturated `m`, so once a Stock Token's cumulative display multiplier passes that bound the same phantom step is recomputed at every gate refresh and `FLAG_CA_ARMED` (or a permanent surge/capture fee) latches with no path back.
---

[70] **20. `Placed.highestTick` is never seeded**

`VaultPlacementLib._executePlace` · Confidence: 70 · [agents: 3]

**Description**
`lowestTick` is seeded on the first cell but `highestTick` starts at 0 and is only raised, and every Amplestocks pool sits at deeply negative ticks (AMPS is `currency0` against a dearer counter), so the `Placement` event reports an upper bound of 0 for every ladder ever placed (event-only; no on-chain consumer).
---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [92] | A one-wei donation permanently bricks a bond market |
| 2 | [90] | One paused or denylisting constituent blocks every redemption |
| 3 | [88] | The exit sweep makes unguarded calls into every registered token on the ungated path |
| 4 | [85] | Bid cells are treated as bought-back inventory and re-laid a doubling lower on every compound |
| 5 | [85] | A zero-work compound arms the maximum surge, wipes the high-water mark and takes the pool's cooldown |
| 6 | [85] | The creator slice divides realised fees by the base sell fee |
| 7 | [85] | A permissionless pre-genesis checkpoint opens every pool a thousand times too low |
| 8 | [82] | The evacuation reverts on an idle balance of the very token that triggered it |
| 9 | [80] | Bonds price a held-back or stale collateral answer with a calendar-only haircut |
| 10 | [80] | `deployBonded` never checks the constituent's status |
| 11 | [78] | The migration predicate decodes untrusted returndata with `abi.decode(..., (bool))` |
| 12 | [78] | `emergencyMigrate` hands over four vault roles but not the hook's or the registry's |
| 13 | [78] | An expired pending jump confirms any later candidate |
| 14 | [75] | The jump rule disarms once the latch is a heartbeat old, and nothing advances the latch |
| 15 | [75] | The shell validates the policy's price but mints the policy's quantity |
| 16 | [75] | `compound` re-lays asks at the live tick instead of the reference anchor |
| 17 | [75] | The rotation credit is one transaction-global slot shared by every sender and pool |
| 18 | [72] | The fail-open gate read does not fail open for a codeless or malformed gate |
| 19 | [70] | The multiplier-step detector compares a saturated cache with a full-width probe |
| 20 | [70] | `Placed.highestTick` is never seeded |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Watchdog stamped before it is read** — `AmpsVault.checkpoint` / `OracleGate.poke` — Code smells: `_poke()` precedes `_requireHealthy()`; `poke()` is permissionless and unconditionally restamps layer A — After a chain stall the first transaction clears `WATCHDOG` with no cool-down, so the first checkpoint can track a hub TWAP frozen through the outage; the state model documents the ordering as intended, the post-outage window is what remains unaddressed.
- **The management gate follows the US equity calendar** — `AmpsVault._requireGate` — Code smells: `state(0)` with no constituent collapses to `session == CLOSED ⇒ DEGRADED`; `setPolicyPointer`, every `_band` setter, `checkpoint`, `compound`, `rollout` and `setStandbyVault` all refuse for ~48–62 h a week and under a guardian freeze; the fail-open escape covers a reverting gate, not a refusing one — Whether weekend suspension of upkeep and of governance's own pointer replacement is intended is a design decision, not a code fact (5 agents).
- **Third-party growth of a bonder's position array** — `AmpsBonds.bond` — Code smells: `_positions[to].push` for a caller-chosen `to`, never compacted; `claimAll`, `claimableTotal`, `unvestedOf` and the lens loop it unbounded; a one-wei USDG bond appends a slip — Per-id `claim` still works and each grief costs the attacker a full `_checkpoint()` (~5M gas), so this is griefing of the convenience surface rather than extraction (4 agents).
- **An unpriceable registered asset with any balance reverts NAV** — `VaultNavLib.totalAssetsUsd18` — Code smells: `if (answerUsd8 == 0) revert FeedNotSet` guarded by balance, not by registration; `initializePool` registers `currency1` unconditionally while `FeedRegistry.setFeed` is a separate proposal; `setFeed` deletes the accepted answer before probing — A one-wei donation in the window between `addConstituent` and `setFeed`, or a dead round at `setFeed` execution, takes every gated path down until `refresh`; the deploy scripts happen to order the two correctly and nothing on-chain enforces it (3 agents).
- **Reference-basis valuation of straddled cells feeds back into `P_ref`** — `LadderPositionValuer.valuePool` / `VaultNavLib.totalAssetsUsd18` — Code smells: cells decomposed at `sqrt(P_ref/P_counter)` from the previous checkpoint while sidedness is enforced at `slot0`; a pool trading under NAV books the pool-to-reference slice of a straddled cell as counter it does not hold; `checkpoint` is permissionless — The fixed point and magnitude at realistic ladder shapes were not bounded; the genesis-only "~10 bp" note covers a single tick spacing, not a whole cell (2 agents; overlaps finding 16).
- **Stale high-water mark and valuation basis inside `_burnback`** — `VaultPlacementLib._burnback` — Code smells: the mark is reset only inside `compound`, so asks placed by `rollout`/`place` below an earlier excursion can be burned as bought-back; a crossed cell is valued at `P_ref` in `A` but realised at `slot0`, and the difference can trip the 2 bp `NavBleedExceeded` and stall `compound` on a depressed pool — Concrete price paths were not constructed (3 agents; addressed together with finding 4 by resetting the mark on every ask placement).
- **Bid re-ladder can straddle the reference and fail its own bleed check** — `VaultPlacementLib._placeLadder` — Code smells: sidedness at `slot0`, valuation at `sqrt(P_ref)`, `PLACEMENT_DIVERGENCE_TICKS` (800) is far smaller than a cell (~6,932 ticks); a straddled top bid cell writes its AMPS half to zero (~4 % of the placement) ≫ 2 bp — `compound`'s bid leg and `deployBonded` may revert until the tick drifts; not run against a live pool.
- **`spokeHasDepth` is a hard-coded `false`** — `VaultRolloutLib._propose` — Code smells: `RolloutPolicy` always takes the `DEPTHLESS_DISCOUNT_X18` arm, so every rollout runs at half the scheduled rate and the other branch is unreachable — A depth signal is available from the spoke's own bid records.
- **Rollout charges and pays on harvested, not placed, inventory** — `VaultRolloutLib.rollout` — Code smells: `_addRolloutMoved(moved)` and `payBounty(moved)` while `place(strictBudget = false)` can place zero under a full cell budget; harvested asks then sit idle; harvest returns principal plus accrued fees against a budget checked on principal — Bounded by the daily budget, the entry floor and the pot ceiling (2 agents).
- **`STAGE_SLOT` is not the hash its comment states** — `VaultPlacementLib` — Code smells: the literal `0x1f0c2fd9…a190` is not `keccak256("amplestocks.vault.PLACEMENT_STAGE")` (`0xc6581d99…d8d7`, verified); every other named transient slot in the codebase matches its preimage and is pinned by a test — No collision with the other transient slots today; nothing pins it.
- **Keeper gas allowance overpays on a near-zero-basefee chain** — `VaultPlacementLib._gasCostUsd18` / `_gasUsed` — Code smells: basefee floored at 0.01 gwei, a flat 80k overhead, one 64th corrected on two-hop paths, `boughtBack` counted as keeper work — Bounded by the $25/day ceiling and the `chost` floor (3 agents).
- **Bond capacity is a reset window recomputed on the supply it governs** — `AmpsBonds._capacity` / `_rollDay` — Code smells: `X = cS/(1−c)` overshoot, two full caps across a window boundary — ~0.5 % of the launch cap; no attack beats waiting (2 agents).
- **Full collateral is settled before the capacity clamp** — `AmpsBonds.bond` — Code smells: a partial clamp is silent and only `minAmpsOut` protects the bonder; a front-runner can consume shared capacity — Retained value accrues to the protocol; a correct `minAmpsOut` bounds the loss.
- **`quote` and `bond` diverge on weekends** — `AmpsBonds._quote` — Code smells: the view refuses on `staleCheckpoint` because `checkpoint()` is gate-refused under `CLOSED`, while `bond()` checkpoints itself — The advertised 24/7 bond board goes dark exactly when bonds are the only thing running.
- **`removeCollateral` then `reinstateConstituent` reverts forever** — `AmpsBonds.removeCollateral` / `PoolRegistry.reinstateConstituent` — Code smells: the registry keeps a stale `marketId` with no setter and `setMarketOpen(true)` refuses a removed collateral; `marketCount` never decrements (66 one-way slots) — Governance-only lifecycle brick.
- **`quote` panics on a huge `amountIn`** — `AmpsBonds._amountIn18` — Code smells: unchecked-by-construction scale multiply on the never-reverts view; off-chain callers only.
- **The divergence breaker has no liveness driver and a permissionless clear** — `OracleGate.pokePool` / `_updateDivergence` — Code smells: `_divergedSince` is written only by the unpaid pool pokes (the vault's `_poke` calls the argument-less `poke()`), and is deleted whenever the deviation is momentarily inside the band or unreadable — Layer E may be unreachable in practice; `qFloor` and `_requireConverged` still hold independently (3 agents).
- **Layer F is implemented twice with different overflow behaviour** — `OracleGate._referenceIntegrity` vs `VaultNavLib.referenceOverridden` — Code smells: plain 256-bit multiply vs `FullMath.mulDiv` on prices that can reach ~1e77 at extreme ticks — Every caller wraps the gate's version.
- **Entry-class bonds skip the freshness layer** — `OracleGate._snapshot` — Code smells: `constituentId == 0` skips layers C/D/E, so WETH/USDG collateral is priced with an equity-calendar haircut and no staleness signal — Both entry markets are closed at launch.
- **A guardian freeze blocks governance's own escape hatch** — `OracleGate.freezeProtocol` — Code smells: `setPolicyPointer` and every setter call `_requireHealthy`, a renewable 7-day freeze refuses them all — The timelock can batch `unfreezeProtocol` + `setPolicyPointer`.
- **The migration predicate's probes are zero-amount in steady state** — `VaultNavLib._selfTransferProbe` — Code smells: `amount = balance >= 1 ? 1 : 0` and I12 keeps the balance at zero, so two tokens that reject zero-value transfers or exceed the 50k gas cap satisfy the predicate — Real Stock Token behaviour is out of scope.
- **`marketReference` "exactly once more" is not enforced** — `VaultNavLib.setPointer` — Code smells: NatSpec claims a one-shot re-point; slot 8 carries no `setOnce` flag or counter (2 agents).
- **Downward reference moves are unlimited and loosen the bond floor** — `VaultNavLib.referencePrice` — Code smells: a lower `P_ref` reclassifies straddled cells as AMPS (valued zero) → lower NAV → higher `qFloor` — Cost of sustaining the hub push under the truncation cap and the fee wall was not modelled.
- **Registry writes the hook never reads** — `PoolRegistry.reconfigureConstituent` — Code smells: `PoolConfig.buyFeeBps/poolClass` are read once at `afterInitialize`; the hook has `setBuyFeeBps` but no `poolClass` setter; the weight-vector sum is enforced only in `setIndexWeights` (2 agents).
- **`spokeSeedBps` and the registry's `place` privilege are dead** — `AmpsVault.place` — Code smells: `_spokeSeedBps` is never read; `PoolRegistry` never calls `place`; a new constituent opens with no seed ask (2 agents).
- **One `minDelay` for three documented timelock classes** — `AmpsVault.onlyTimelock` — Code smells: `TIMELOCK_FAST/SLOW/STANDBY_SECONDS` are declared and read by nothing; tiering is signing policy.
- **The multiplier-step detector is one-sided** — `AmpsHook._detectMultiplierStep` — Code smells: `deltaBps` only for `m > previous`; a reverse split arms nothing and takes the clearing branch (2 agents).
- **The gate probe budget may be below the gate's real cost** — `AmpsHook._snapshotInto` — Code smells: `GATE_PROBE_GAS = 400_000` against a `snapshotByPool` that runs the calendar, two reference legs, a constituent read and four token probes — A refresh that always fails pins the pool on the conservative substitute.
- **`-params.amountSpecified` can panic** — `AmpsHook._beforeSwap` — Code smells: negation before v4's own magnitude check; `type(int256).min` reverts with a Panic instead of `BeyondRail` — The swap fails in `Pool.swap` anyway.
- **Stream residue releases as a step** — `AmpsStaking._unreleasedAt` — Code smells: floor-division rate, remainder released at `streamEnd` — one second of stream at launch parameters.
- **`setFeed` deletes before it probes** — `FeedRegistry.setFeed` — Code smells: a dead round at execution leaves `answerUsd8 == 0` and `totalAssetsUsd18` reverting until `refresh`.
- **Re-entrant `sync` hijack during settlement** — `VaultRedeemLib.settleFrom` — Code smells: `PoolManager.sync` is permissionless and un-gated; a token with a transfer hook could re-sync another currency between `sync` and `settle` — Reverts cleanly on the bond path; unverified against a real Stock Token.
- **Batched `extsload` length unchecked** — `PoolStateLib.positionLiquidityAtSlots` — defence in depth against an immutable PoolManager.
- **Groundwork libraries with contract gaps** — `StreamsSchemaLib.schemaVersionOf` (uint16 vs uint8 consumers), `LadderPolicy.cellIndex` (documented never-revert reverts on `tickSpacing == 0`), `VaultPlacementLib._requireOnGrid` (a pool near the tick extremes could revert its own `compound`), `PlacementRecord.amount` (cumulative, never zeroed) — unwired or unreachable at launch geometry.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
