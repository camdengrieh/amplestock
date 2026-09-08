# 🔐 Security Review — amplestock (re-audit of the remediated tree `bc0e6bb`)

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | filename (the ten files changed by the first remediation wave) |
| **Files reviewed**               | `AmpsBonds.sol` · `AmpsHook.sol` · `FeedRegistry.sol`<br>`OracleGate.sol` · `PoolRegistry.sol` · `AmpsVault.sol`<br>`VaultNavLib.sol` · `VaultPlacementLib.sol` · `VaultRedeemLib.sol`<br>`VaultRolloutLib.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

Second run of the twelve-agent `solidity-auditor` review, over the tree after commit `3184813` (the fixes for the twenty findings of the first report, `amplestock-pashov-ai-audit-report-20260907-045500.md`). Every agent was told which fix it was re-checking and asked to verify the fix held before looking for residuals. Fixes verified as holding by at least two agents: 1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18 (for `AmpsVault` itself), 19, 20. Fix 3 was found incomplete, fix 9's shell leg inert, and the lead-fix for the rollout bounty introduced a regression (finding 6). Dispositions are in `fix-log.md` (second wave).

Completeness: 45 unique (Contract, function) in raw, 45 covered in final.

---

## Findings

[90] **1. Unbounded gas forwarded to an untrusted token on the redemption payout**

`VaultRedeemLib._payOut` · Confidence: 90 · [agents: 2, 3, 4, 6, 9, 12]

**Description**
`try pm.take(currency, to, claimPart)` and the idle leg's `_tryTransfer` forward all remaining gas, so a constituent whose `transfer` burns gas instead of reverting leaves the `catch` (and every asset after it, the inventory burn and the sweep) 1/64 of the frame: measured, one gas-burning token plus a 1-wei donation makes `redeemProRata` consume ~all of any budget and two such tokens revert it at 30M, which blocks the one path the design says can never be blocked.

**Fix**

```diff
- try pm.take(currency, to, claimPart) {} catch { pm.transfer(to, currency.toId(), claimPart); }
+ try pm.take{gas: Constants.STOCK_TOKEN_PROBE_GAS * 4}(currency, to, claimPart) {}
+ catch { pm.transfer(to, currency.toId(), claimPart); }
```
---

[90] **2. The NAV numerator reads a constituent balance with a bare typed call**

`VaultNavLib.totalAssetsUsd18` · Confidence: 90 · [agents: 3, 6, 9, 12]

**Description**
`IERC20(token).balanceOf(holder)` sits on the checkpoint path before the zero-balance skip, `_assets` is append-only and the vault immutable, so one issuer making `balanceOf` revert (or burn gas) permanently bricks `checkpoint`, `previewNavPerShareX18`, `depositBonded` (every bond), `genesis`, `place`, `compound`, `rollout`, `deployBonded` and `withdrawRetiredBids`, while `migrationPredicate` scores that token as a single failed probe and refuses the guardian; the same raw read recurs in `inventoryAmps`, `VaultPlacementLib._placeLadder` and `VaultRolloutLib.deployBonded`.

**Fix**

```diff
- uint256 idle = IERC20(token).balanceOf(holder);
+ (bool readable, uint256 idle) = _probeBalance(token, holder); // bounded hand-decoded staticcall
+ if (!readable) idle = 0;
```
---

[88] **3. The exit sweep runs an untrusted token call inside the vault's own PoolManager unlock**

`VaultRedeemLib._absorb` · Confidence: 88 · [agents: 2, 3, 5, 6, 9, 11, 12]

**Description**
Two coexisting mechanisms: (a) `_tryTransfer`'s `token.call` carries no stipend while the `sync` beside it is capped, so a gas-burning token starves everything after it in `sweepClean`, which runs at the exit of every entry point; (b) the transfer executes inside the vault's unlock, so a token whose `transfer` calls `PoolManager.mint`/`take` (both `onlyWhenUnlocked`, which checks *that* the manager is unlocked, not by whom) opens a foreign delta and the unlock reverts with `CurrencyNotSettled`, bricking every entry point including `redeemProRata` with `migrationPredicate` blind (`isBlocked` false, self-transfer fine outside an unlock).

**Fix (Option A — restructure)**

```diff
- // inside unlockCallback: sync -> token.transfer -> settle -> mint
+ // outer frame: sync (not onlyWhenUnlocked) and token.call{gas: STOCK_TOKEN_PROBE_GAS * 4}(transfer)
+ // inside a try-wrapped unlock: settle{gas: bounded}() and mint only for tokens whose transfer succeeded
```

**Fix (Option B — bound only)**

```diff
- (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
+ (bool ok, bytes memory ret) = token.call{gas: Constants.STOCK_TOKEN_PROBE_GAS * 4}(abi.encodeCall(IERC20.transfer, (to, amount)));
```
---

[85] **4. The dust forward in the bond shell decodes an untrusted answer with `abi.decode(bool)`**

`AmpsBonds._issue` · Confidence: 85 · [agents: 1, 3, 4, 6, 9, 12]

**Description**
The forward reads `balanceOf` with a typed call, sends the transfer with no gas cap and validates the return with `abi.decode(returned, (bool))`, so a collateral whose `transfer` answers a non-canonical word (or whose `balanceOf` reverts, or whose `transfer` burns gas) turns a 1-wei donation to the shell into a permanent revert of `bond()` for that market — the exact brick the forward was added to remove (PoC: `bond` reverts after `mint(bonds, 1)` on a token returning `2`).

**Fix**

```diff
- uint256 dust = IERC20(collateral).balanceOf(address(this));
- (bool ok, bytes memory returned) = collateral.call(abi.encodeCall(IERC20.transfer, (vault, dust)));
- if (ok && (returned.length == 0 || abi.decode(returned, (bool)))) emit CollateralForwarded(...);
+ (bool readable, uint256 dust) = _probeBalance(collateral); // bounded, hand-decoded; unreadable => skip
+ if (!readable || dust == 0) return;
+ (bool ok, bytes memory returned) = collateral.call{gas: Constants.STOCK_TOKEN_PROBE_GAS * 4}(abi.encodeCall(IERC20.transfer, (vault, dust)));
+ if (ok && (returned.length == 0 || (returned.length >= 32 && _firstWord(returned) != 0))) emit CollateralForwarded(...);
```
---

[82] **5. The evacuation's idle leg forwards all gas to the token it is fleeing**

`VaultNavLib._tryMoveIdle` · Confidence: 82 · [agents: 2, 3, 5, 6, 9, 12]

**Description**
`token.call(abi.encodeCall(IERC20.transfer, (to, idle)))` has no stipend while `_selfTransferProbe` in the same file bounds its own transfer, so a gas-burning constituent early in `_assets` starves the remaining claim moves and `VaultNavLib.handover` (measured: the migration needs 8M instead of 5M on a two-constituent fixture, 64x on the tail), leaving the estate on the old shell — the veto fix 8 was written to remove.

**Fix**

```diff
- (bool ok,) = token.call(abi.encodeCall(IERC20.transfer, (to, idle)));
+ (bool ok,) = token.call{gas: Constants.STOCK_TOKEN_PROBE_GAS * 4}(abi.encodeCall(IERC20.transfer, (to, idle)));
```
---

[80] **6. Rollout charges the daily window on what was placed, not on what left the entry pools**

`VaultRolloutLib.rollout` · Confidence: 80 · [agents: 2, 4, 5, 6, 7, 8, 10, 11, 12]

**Description**
The harvest removes `moved` AMPS from the entry pools' unfilled asks unconditionally, but `_addRolloutMoved` is charged with `placed`; with the live-cell budget full (`liveCells >= MAX_LIVE_CELLS`, an ordinary state — the launch shape is 448 of 512 before the first bid cell opens) `place(strictBudget=false)` places nothing, nothing is charged, `place` still writes the cooldown, and a permissionless caller drains the entry pools to `entryFloorBps` in minutes instead of the ~35 days `rolloutBpsPerDay` prices, with no NAV movement to trip R1 (an AMPS ask and idle AMPS are both worth zero in `A`); `_propose` reports `movedLast24h = 0` throughout.

**Fix**

```diff
- if (placed != 0) _addRolloutMoved(placed);
+ if (moved != 0) _addRolloutMoved(moved);   // what left the entry pools
+ // and re-place (or leave idle and emit) the unplaced remainder `moved - placed`
```
---

[75] **7. A held-back feed answer understates the NAV denominator every other bond market prices against**

`AmpsBonds._price` · Confidence: 75 · [agents: 3, 8, 11, 12]

**Description**
`FeedRegistry._read` reports `min(held, candidate)` with `unconfirmed = true` on a >10% single-round move, `VaultNavLib.answer` drops the flag, and `navPerShareX18` — understated by weight × gap (30% × 15% ≈ 4.3%) — is the denominator of `_qFloorX18`, so until the jump confirms, bonds on *any other* collateral (the gate only checks the bonded constituent) mint ~4% more AMPS per dollar than true NAV allows, bounded per event by the daily capacity. Chain: `FeedRegistry._read` (direction is conservative for the collateral numerator but loosens the NAV denominator) + `VaultNavLib.answer` (flag dropped) + `AmpsBonds._qFloorX18`.

---

[75] **8. `fresh` does not fold `unconfirmed`, so the shell's stale-feed haircut never fires on a held jump**

`FeedRegistry._read` · Confidence: 75 · [agents: 1, 3, 5, 9, 11, 12]

**Description**
`status.fresh` is computed from the timestamp alone and a held-back answer carries the candidate's `updatedAt`, so `AmpsBonds._haircutFor` (which reads `fresh`) and the entry-class markets (which have no gate layer) see a held jump as fresh; the gate's `feedStale = !fresh || unconfirmed` covers constituent markets only. Promoted from six converging leads.

---

[75] **9. The hook's gate probes are budgeted below what the remediated gate costs**

`AmpsHook._snapshotInto` · Confidence: 75 · [agents: 4, 7, 9, 10, 12]

**Description**
`GATE_PROBE_GAS` (400k) is unchanged while `snapshotByPool` gained the `feedStatusIn` leg (itself budgeted at `PROBE_GAS * 8` = 400k) and up to two `getRoundData` probes per read (measured 239–252k in-fixture, 330–390k estimated with real proxies, ~505k on the full 32-pool shape), and `_readGate` reads `closedHours` — a DST-table scan plus a 16-day holiday walk, ~45–50k by 2032 — under `POINTER_PROBE_GAS` = 60k; a refresh that runs out of budget pins every pool on the conservative substitute after `GATE_CACHE_MAX_AGE` with no way back, and a non-entry pool's `fairTick` stays at the opening tick because only `ENTRY` pools fall back to `twap30m`.

---

[75] **10. The high-water mark is reset from the rate-limited truncated tick but compared with raw ticks**

`VaultPlacementLib._burnback` · Confidence: 75 · [agents: 7, 8]

**Description**
`_placeLadder` resets the mark through `IAmpsHook.resetHighWater`, which writes `lastTruncatedTick`; after a fast fall that tick lags the pool by thousands of ticks, `compound` re-lays asks at the fallen reference under a mark still above them, and the next `compound` satisfies `upperTick <= highWater && tick <= lowerTick` for asks that were never sold and burns them (R1 is blind: position AMPS is worth zero in `A`).

---

[75] **11. One wei of counter-side fee counts as work, arming the maximum surge and resetting the mark**

`VaultPlacementLib.compound` · Confidence: 75 · [agents: 3, 5, 6, 11]

**Description**
Fix 5 gates the surge, the mark reset and the cooldown on `burned != 0 || split.relaid != 0 || counter != 0`, and `counter` is the raw `feesAccrued.amount1`, so a dust buy (5–30 bp of a dust notional) followed by a permissionless `compound` arms `SURGE_MAX_BPS`, resets the high-water mark and takes the pool's cooldown once every 60 s, for gas. Promoted from four converging leads.

---

[75] **12. `place` writes the cooldown even when nothing was placed**

`VaultPlacementLib.place` · Confidence: 75 · [agents: 2, 3, 8]

**Description**
The cooldown write is unconditional, and `rollout`/`deployBonded` reach `place(strictBudget=false)` permissionlessly, so a zero-work call denies a real `compound` or a governance `place` on that pool (and, through the rollout harvest, on both entry pools) for 60 s. Promoted from three converging leads.

---

[70] **13. Two parties settled by one contract in one transaction share a rotation credit**

`AmpsHook._credit` · Confidence: 70 · [agents: 2, 4, 8, 11, 12]

**Description**
The credit is keyed by the PoolManager `sender`, which is the unlocker (the Universal Router for every user, or a batching filler), so a filler that settles a victim's buy and its own sell in one transaction pays two buy fees on the matched size instead of the sell fee; the fix's regression test pranks two senders and its sibling asserts router sharing. Accepted as a design property (a batching settlement contract that pairs an entry with an exit is a rotation-equivalent flow); the NatSpec is corrected to say so.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | Unbounded gas forwarded to an untrusted token on the redemption payout |
| 2 | [90] | The NAV numerator reads a constituent balance with a bare typed call |
| 3 | [88] | The exit sweep runs an untrusted token call inside the vault's own PoolManager unlock |
| 4 | [85] | The dust forward in the bond shell decodes an untrusted answer with `abi.decode(bool)` |
| 5 | [82] | The evacuation's idle leg forwards all gas to the token it is fleeing |
| 6 | [80] | Rollout charges the daily window on what was placed, not on what left the entry pools |
| 7 | [75] | A held-back feed answer understates the NAV denominator every other bond market prices against |
| 8 | [75] | `fresh` does not fold `unconfirmed`, so the shell's stale-feed haircut never fires on a held jump |
| 9 | [75] | The hook's gate probes are budgeted below what the remediated gate costs |
| 10 | [75] | The high-water mark is reset from the rate-limited truncated tick but compared with raw ticks |
| 11 | [75] | One wei of counter-side fee counts as work, arming the maximum surge and resetting the mark |
| 12 | [75] | `place` writes the cooldown even when nothing was placed |
| 13 | [70] | Two parties settled by one contract in one transaction share a rotation credit |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Typed `try` on pointer-upgradeable targets survives fix 18 outside the vault** — `VaultNavLib.referenceOverridden` / `marketPrice` / `answer`, `VaultPlacementLib` (~1086, 1096, 1133, 1270, 1290), `VaultRolloutLib` (~507) — Code smells: `try` decoding a 13-word struct with two enums, `(uint256, uint32, bool)`, `int24` and a dynamic `uint256[]`; no gas stipends; several sites without a `code.length` screen — A gate, market reference, feed registry or ladder policy with code that answers short, out-of-range or dirty panics uncatchably on the checkpoint and placement paths for the 7-day pointer window; reachable only through a governance-installed pointer.
- **`_resetHighWater` may fail silently on an ask placement** — `VaultPlacementLib._resetHighWater` — Code smells: `try ... returns (int24) {} catch {}` on the burnback's load-bearing companion; nothing observes the failure — A failed reset (mis-pointed reference, malformed return) leaves a stale mark, and a fresh ask satisfies both burnback conditions from birth; not reachable against the real hook.
- **Merging into a cell with accrued fees nets them into the settlement without the split** — `VaultPlacementLib._executePlace` — Code smells: `callerDelta = principal + fees`; only `compound` collects first — `place`/`rollout` into an existing cell route AMPS-side fees past the creator/staker/burn split; the amount is bounded by fees accrued since the last compound.
- **Merging into an existing cell overwrites `record.above`** — `VaultPlacementLib._writeRecords` — Code smells: a filled ask merged by a bid flips to bid, `record.amount` mixes units — `_askInventory`/`_harvestAsks` skip it, `withdrawRetiredBids` removes it whole, `_hasBidDepth` counts it; consequence unquantified.
- **The placement anchor aligns down while the grid ceils** — `VaultPlacementLib._referenceTick` — Code smells: `fairTick` is a deviation reference, not a placement anchor — When the two roundings straddle a cell boundary the first ask cell can start up to `tickSpacing - 1` ticks below `P_ref` (I32 violated by ≤ 0.59% on ≤ 0.85% of one cell).
- **A fully crossed bid is burned as a buyback** — `VaultPlacementLib._burnback` — Code smells: predicate has no `record.above`; a bid crossed after a full-doubling fall is burned — The design says bought-back AMPS is burned and a crossed bid does hold bought-back AMPS, so the sign of harm is unverified.
- **The migration may not fit one transaction at a full constituent set** — `VaultNavLib.migrationPredicate` — Code smells: up to 64 × 3 × 50k of probes before `unwind` (~23.5M at 512 cells), `evacuate` and `handover` in the same transaction — Estimated, not measured on a 64-constituent fixture; part of the open constituent-cap decision.
- **`currentWeightBps` still returns the target weight** — `PoolRegistry.currentWeightBps` — Code smells: stub outlived the valuer it was waiting for — `AmpsBonds._deficitX18` and `RolloutPolicy`'s deficit are identically zero, so the `k_w` under-weight preference is a dead control; functional, not exploitable.
- **`config.marketId` is not refreshed after `removeCollateral` + `addCollateral`** — `PoolRegistry._setMarketOpen` — Code smells: stale id; `retireConstituent` then detaches silently and the live market stays open — Governance sequence, I37 fails for that constituent until `reconfigureConstituent`.
- **`retiredAt` is not cleared on reinstatement; `freezeUntil` is read but never written** — `PoolRegistry.reinstateConstituent` — Code smells: stale timestamps in the lifecycle record — Disclosure only unless a consumer keys on `retiredAt`.
- **The index weight sum is enforced only in `setIndexWeights`** — `PoolRegistry.retireConstituent` — Code smells: retiring zeroes a weight without renormalising — The sum drifts below 10,000 bp until the next weight proposal.
- **An unreadable deviation clears the layer-E sustain timer** — `OracleGate._updateDivergence` — Code smells: armed only on `ok`, cleared on `!ok` — Any dependency hiccup restarts the 60 s window, so a sustained divergence can be masked by an intermittently failing reference.
- **The jump rule is disarmed while no answer is latched** — `FeedRegistry._evaluate` — Code smells: `accepted.answerUsd8 == 0` early return skips the stateless previous-round path too — A feed whose `setFeed` probe failed has both halves of the rule off until an unpaid `refresh`; and a >10% print within one heartbeat of a fresh latch is held until a keeper refreshes (conservative).
- **The quote's overflow guard trips 1e18x earlier than `mulDiv` would** — `AmpsBonds._quote` — Code smells: `amountIn18 > max / qX18` — Unreachable amounts at any plausible supply; a `reason` instead of a price for very large quotes.
- **Typed `try` in the non-reverting quote surface** — `AmpsBonds._collect` / `_tryPointers` / `_haircutFor` / `_tryCurrentWeightBps` — Code smells: `_tryPointers` checks `!= address(0)`, not `code.length`; enum/struct decodes in a view that promises not to revert — A codeless or malformed governance pointer panics `quote()` instead of degrading.
- **The most powerful pointer has no code check** — `AmpsVault.setStandbyVault` — Code smells: no `code.length` screen; `Migrated` does not disclose a failed hook leg — 14-day timelock path; a codeless standby makes `emergencyMigrate` hand the estate to nothing.
- **`_requireWiringOpen` is defined and never called** — `AmpsVault._requireWiringOpen` — Code smells: dead guard; set-once enforcement lives only in `VaultNavLib.setPointer` — Documentation/bytecode drift.
- **The variance store's headroom claim is inverted** — `AmpsHook._updateVariance` — Code smells: NatSpec says three orders of magnitude of headroom; saturation is at ~1.84e7 ticks² against a theoretical single-swap d² of ~3.1e12 — The clamp is load-bearing and safe (`f_vol` caps first); the comment is wrong.
- **The credit is per sender, not per pool class** — `AmpsHook._quote` — Code smells: a hub buy followed by a spoke sell pays 35 bp, not 530 — Reads as the intended rotation-hub behaviour; recorded for the docs.
- **A degraded checkpoint read yields `premiumX18 == -1e18`** — `AmpsQuoter._quote` — Code smells: `pRefX18 == 0` divided through — Masked by the degraded bit in the dApp; a raw consumer could misread it.
- **An off-grid anchor reverts the whole placement** — `VaultPlacementLib._place` — Code smells: no snapping — Reachable only through a mis-configured `gridBaseTick`.
- **`_propose` reports the window as of the previous checkpoint** — `RolloutPolicy._propose` — Code smells: `movedLast24h` read from a stale slot — A keeper can under-estimate what it may still move; corrected by finding 6's fix.
- **The bounty over-counts a two-hop upkeep** — `BountyPot.payBounty` — Code smells: the reimbursement measures the whole outer call — Bounded by the 3x gas cap and the daily ceiling.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
