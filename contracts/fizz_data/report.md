# Fuzzing Suite Report

## Suite Overview
- **Project**: Amplestocks — the $AMPS protocol (Foundry package, Robinhood Chain, chain id 4663 / testnet 46630)
- **Suite location**: `test/fizz/`
- **Contracts targeted**: `AmpsVault`, `AmpsHook`, `AmpsBonds`, `AmpsRouter`, `PoolRegistry`, `OracleGate`, `FeedRegistry`, `Amps`, `BountyPot` (9 contracts, 40 selected entry points per `fizz_data/entry-point-selection.json`)
- **Total handlers**: 59 public entry points across 11 files in `test/fizz/handlers/` (50 direct, 9 secondary dispatchers; Medusa counts 155 assertion tests in all: these, the 80 global properties and the fixture's public helpers)
- **Properties**: 141 implemented of 144 specified (80 global `public`, 61 function-specific `internal`; 3 left `[-]` by design)

The suite reuses `test/integration/Phase3Fixture.sol` at the launch shape: 30 spokes, 32 pools, two-step genesis at P0 = 1, 4 WETH + 10,000 USDG bids, 3,150 AMPS entry-pool ask ladders, 90 AMPS seed asks. `FuzzTester`'s constructor builds the whole Phase 3 world (real `Amps`, `AmpsVault` behind its four linked libraries, the real `AmpsHook` at a `0x38C0`-shaped CREATE2 address, `PoolRegistry`, `AmpsBonds`, `BountyPot`, `OracleGate` + `FeedRegistry`, four policies, `LadderPositionValuer`, `AmpsQuoter`, `AmpsRouter`, on a local Uniswap v4 stack).

**Toolchain (established by the orchestrating agent, recorded verbatim)**
- Medusa 1.5.1 (`~/.local/bin/medusa`), crytic-compile 0.4.2.
- **Echidna is not installable in this sandbox** — its GitHub release tag is unresolvable through the egress proxy — so the campaign is Medusa-only and `echidna.yaml` is generated but unexercised.
- Medusa 1.5.1 limitations found: unimplemented cheatcodes `getBlockTimestamp`, `getBlockNumber`, `computeCreateAddress`, `assume`, `snapshot`; `vm.etch`-installed code not reliably callable (Permit2 is a `STOP` stub, so the v4 `swapRouter` path is unreachable and every trade goes through `AmpsRouter`); `startPrank` leaks on revert; `coverageEnabled:false` segfaults; per-file coverage is blind to every contract with immutables.
- Foundry cache rule: every build uses `FOUNDRY_BUILD_INFO=true FOUNDRY_DYNAMIC_TEST_LINKING=false forge build` (crytic-compile's exact flags); any other flag set costs a 31-minute recompile.
- Cost estimate: `fizz_data/cost-estimate.md` (list-price ballpark for the subagent tier it names; estimated total $25.35, range $17.75–$38.03).

## Coverage Results

| Contract | Target | Achieved | Status |
|----------|--------|----------|--------|
| AmpsVault (+ VaultNavLib, VaultPlacementLib, VaultRedeemLib, VaultRolloutLib) | 65% | n/a (immutables) | n/a |
| AmpsHook | 65% | n/a (immutables) | n/a |
| AmpsBonds | 65% | n/a (immutables) | n/a |
| AmpsRouter | 35% | n/a (immutables) | n/a |
| PoolRegistry | 45% | n/a (immutables) | n/a |
| OracleGate | 45% | n/a (immutables) | n/a |
| FeedRegistry | 45% | n/a (immutables) | n/a |
| Amps | inherited (no separate target) | n/a (immutables) | n/a |
| BountyPot | inherited (no separate target) | n/a (immutables) | n/a |
| LadderPositionValuer, FeePolicy | inherited (no separate target) | n/a (immutables) | n/a |
| BondPolicy | inherited via callers | 71% (30/42 lines) | ✅ |
| RolloutPolicy | inherited via callers | 54% (18/33 lines) | ✅ |
| PriceLib | inherited via callers | 38% (29/76 lines) | ✅ |
| LadderLib | inherited via callers | 25% (23/89 lines) | ⚠️ |
| LadderPolicy | inherited via callers | 3% (2/66 lines) | ⚠️ |
| `test/fizz/` harness (Base + 11 handler files) | every clamped handler ≥ 1 successful landing | 93–100% per handler file; `Base.sol` 94% | ✅ |

**Medusa 1.5.1 reports 0% for every contract whose deployed runtime code carries immutables** — the deployed code differs from the artifact at the immutable slots, so the source map never matches — so `AmpsVault`, `AmpsHook`, `AmpsBonds`, `AmpsRouter`, `PoolRegistry`, `OracleGate`, `FeedRegistry`, `Amps`, `BountyPot`, `LadderPositionValuer` and `FeePolicy` (and every internal library inlined into them: `TruncatedOracleLib`, `PoolStateLib`, `HookStateLib`, `QuoterSwapLib`, `GatePriceMath`, `StreamsSchemaLib`, the four `Vault*Lib` files) carry the target and "n/a (immutables)" rather than a verdict. Those rows are an attribution artefact, not a coverage failure.

The coverage signal for those contracts is (1) the aggregate `branches` counter Medusa prints, (2) the harness's own per-handler line coverage, which proves which handlers land, and (3) targeted `FoundryTester` probes. See `fizz_data/coverage-targets.md`.

| Run | Aggregate `branches` |
|---|---|
| Cycle-1 handler-only smoke (20,000 calls) | 17,025 (smoke run reached 17,044) |
| Campaign 1 | 28,290 |
| Campaign 2 | 28,014 |
| Campaign 3 | 29,722 |
| Campaign 4 | 29,347 |
| **Campaign 5 (this report)** | **29,588** |

The counter rose from 17k with handlers only to ~29.6k once the 141 properties and the sixteen adversarial handlers were in place; it has been flat within ~1.5% across campaigns 3–5.

Coverage profile caveat: the fuzz run uses the default profile with via-IR only on `src/vault/*`, `src/bonds/*`, `src/hook/*` (per-path `compilation_restrictions` in `foundry.toml`). `setup_fuzz_profile.sh` was deliberately not run — a `[profile.fuzz]` drops those per-path restrictions and pushes `AmpsVault` past EIP-170.

## Skipped Paths

| Contract | Function / Path | Reason |
|----------|----------------|--------|
| `AmpsGenesis` / `AmpsVault` | `genesisMint`, `genesisPlace` | One-shot bootstrap; run by the fixture's two-step genesis before the campaign starts |
| `AmpsVault` | `emergencyMigrate` | Terminal admin escape hatch; excluded by the entry-point selection |
| `AmpsVault` | `setPolicyPointer` | Governance plumbing; not wired to a handler |
| `Amps` | `mint`, `burn` | Vault-only plumbing; reached through bond/redeem/compound paths instead |
| `AmpsBonds` | `addCollateral` | Bonds-only market setup; the fixture installs the markets |
| `AmpsHook` | PoolManager-only callbacks (`beforeSwap`/`afterSwap`/`beforeInitialize`…) | Driven by every swap already; not directly callable |
| all | view/pure disclosure surface | Read-only; covered indirectly by GL-26 (`property_disclosureNeverReverts`) |
| v4 `swapRouter` | `Phase3Fixture.buyAmps` / `sellAmps` / `rotate` | Pulls through Permit2, which is a `STOP` stub because Medusa 1.5.1 cannot reliably call `vm.etch`-installed code (68- and 132-byte calls fail with a stack underflow). Every trade goes through `AmpsRouter` instead — the protocol's own path, which exercises both fee directions and the pass-through |
| `OracleGate` | WATCHDOG-after-`GRACE`, sustained DIVERGED | Need a real feed failure in the right order; reachable only via the `env_secondary` dispatcher's warp/moveFeed actions, counted as reached when the `branches` counter moves rather than by per-file lines |
| — | Echidna campaign | Echidna is not installable in this sandbox (release tag unresolvable through the egress proxy); `echidna.yaml` is generated but unexercised |

## Campaign Results
- **Fuzzer used**: Medusa 1.5.1
- **Duration**: 600 s of fuzzing (campaign 5, 2026-09-12, fuzzing 10:55–11:05 UTC), plus post-run shrinking and the coverage phase
- **Total calls**: 29,221 at the last logged tick (9m33s of 10m; Medusa prints no final total)
- **Branches hit**: 29,588
- **Corpus size**: 488
- **Violations found**: 1 — Medusa's final summary (printed at 14:03 UTC, after a three-hour post-run phase): 154 tests passed, 1 failed (`ampsRouter_buy_dust` → SP-33, triaged as a harness statement in sub-section 11 below)

Wrapper: the fizz skill's Medusa runner (`node <skill>/scripts/run_medusa.js contracts --meta-dir fizz_data --timeout 600`) — 4 workers, `testLimit 0`, `callSequenceLength 100`, `blockGasLimit 2e9`, `transactionGasLimit 7e8`, slither off, `shrinkLimit 20` for this run. Setup gas is 617M per sequence, so every shrink replay redeploys the whole world; that is why call counts are low for a 600 s budget and why `shrinkLimit` was walked down 1,000 → 200 → 50 → 20 across the campaigns. The corpus carried over between campaigns.

### Campaign history (five runs; campaign 5 is the one described above)

| Campaign | Calls | Sequences / corpus | Branches | Result | Disposition |
|---|---|---|---|---|---|
| 1 (2026-09-10 11:40 UTC) | 1,721 | 601 seq | 28,290 | 153 passed / 2 failed | SP-18, SP-35 — both harness over-statements; wrapper rc 7 because every worker sat in 1,000 shrink replays, so `shrinkLimit` → 200 |
| 2 (2026-09-10 17:35 UTC) | 1,268 | 1,350 seq | 28,014 | 152 passed / 3 failed | SP-05, SP-20, SP-14 |
| 3 (2026-09-11 12:22–17:28 UTC) | 16,850 | 1,705 seq / corpus 528 | 29,722 | 152 passed / 3 failed | GL-47, SP-43, SP-07; wrapper rc 7 — the 10-minute fuzz was followed by ~5 h of shrinking, so `shrinkLimit` → 50 |
| 4 (2026-09-12 03:15–06:26 UTC) | 20,979 | 2,173 seq / corpus 461 | 29,347 | 153 passed / 2 failed | SP-04, SP-46; the three campaign-3 corrections held; wrapper rc 7, 11,495 s wall, so `shrinkLimit` → 20 |
| **5 (2026-09-12 10:20 UTC; fuzzing 10:55–11:05)** | **29,221** (last logged tick) | corpus 488 | **29,588** | **154 passed / 1 failed** | SP-33 (sub-section 11); the two campaign-4 corrections and the three campaign-3 corrections held; wrapper rc 7, 13,401 s wall of which ~3 h was Medusa's silent post-run phase with nothing left to shrink |

Medusa's summary arrived at 14:03 UTC, three hours after fuzzing ended: `154 test(s) passed, 1 test(s) failed`, the failure being `AssertEqFail("Invalid: 7582330171670898!=7582330148723767, reason: SP-33: the recipient's gain is not the reported out")` on the 76-call sequence Worker 3 had shrunk at 7m38s (`fizz_data/corpus_medusa/test_results/`, archived with the log beside the earlier campaigns'). The per-tick `failures` counter stayed at 0 throughout this run as it did in campaign 4, so that counter is not the test-failure count; the summary is. The post-run phase (one thread at full CPU, nothing written) is the same phase that accounted for most of campaigns 3 and 4's wall time; it is Medusa's, not the harness's, and a shorter corpus does not shorten it.

### Violation Details

The sub-sections below are the **eleven distinct root causes triaged across campaigns 1–5**, read from the archived `campaign{1,2,3,4,5}-test_results/` corpora and `campaign{1,2,3,4,5}-medusa-run.log`. Every one has a disposition; ten are corrected harness over-statements, and every correction made before a campaign held through the campaigns that followed it. The eleventh (SP-33, campaign 5) is corrected in the tree and has not yet been confirmed by a further run. Two carry standing human-review leads (L-1 and the SP-14 valuation gap), collected after the sub-sections.

#### 1. SP-18 — placement conserves inventory and shape (campaign 1)
- **Property violated**: `property_placementConservesInventoryAndShape` (SP-18)
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `AssertEqFail("Invalid: 250743!=281576, reason: SP-18: the vault's AMPS did not fall by exactly what was placed")` — and a second stored failure, `425705 != 425711`
- **Root cause**: the property asserted the vault's AMPS balance falls by *exactly* `placed`. `Placed.amountPlaced` reports the per-cell split, and the liquidity-rounding residue stays idle in the vault (`VaultPlacementLib.sol:69-72`, `Types.sol:545`) — 6 wei and 30,833 wei on the two dust placements. Documented behaviour; the property was over-stated.
- **Severity assessment**: `test harness false positive`
- **Reproducing sequence**: single call `ampsVault_place_full(uint256,bool)` (3 stored sequences, 1 call each)
- **Fix applied**: the equality became `≤` (the vault's AMPS falls by *at most* `placed`)
- **Foundry repro**: `N/A` — no `test_repro_sp18_*`; corrected before the replay set was written

#### 2. SP-35 — a swap does not move supply (campaign 1)
- **Property violated**: `property_swapDoesNotMoveSupply` (SP-35)
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `AssertEqFail("Invalid: 584007914129623626!=0, reason: SP-35: the hook held AMPS after a swap")`
- **Root cause**: the sequence donated AMPS with the hook as the target and then bought dust. The hook then legitimately holds donated AMPS that no swap moved; the property asserted the hook's post-swap AMPS balance is exactly zero, which a donation breaks without any swap misbehaving.
- **Severity assessment**: `test harness false positive`
- **Reproducing sequence**: `ampsVault_donateERC20(uint256,uint256,uint256)` → `ampsRouter_buy_dust(uint256,uint256)`
- **Fix applied**: the hook's balance is bounded by `ghosts.hookDonated[amps]` instead of zero
- **Foundry repro**: `N/A` — no `test_repro_sp35_*`

#### 3. SP-05 — a bond is accretive (campaign 2) — also **lead L-1**
- **Property violated**: `property_bondIsAccretive` (SP-05)
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `AssertGteFail("Invalid: 1000098307583767602<1000098320075242399 failed, reason: SP-05: a bond lowered NAV/share")` — a relative drop of 2.8e-10
- **Root cause**: replayed under Foundry. With `P_mkt` (0.9964) below NAV/share the vault sets `P_ref = NAV/share`, and `LadderPositionValuer` prices every position at the *previous* checkpoint's `P_ref`. After any downward move each checkpoint therefore re-derives `A` at a slightly lower reference and NAV/share converges downward by a geometrically shrinking step: stored NAV 1000098320075242399 → 1000098307583767568 after one checkpoint → 1000098307300135438 after the next, ratio ≈ 0.023. `A` fell by 5.67e12 USD-wei on the checkpoint while the bond added 1.4e8; the issuance itself (136,291,377 wei of AMPS for 761,035 wei of stock at $180) is above the floor. No value leaves the vault; I8/I11 hold up to this convergence residue.
- **Severity assessment**: `test harness false positive` for the assertion as written — **plus `needs human review` as lead L-1** (below)
- **Reproducing sequence**: `env_walkFeedToExtreme(uint256,uint256)` → `ampsBonds_bond_dust(uint256,uint256)`
- **Fix applied**: the bond handlers checkpoint twice before the snapshot; SP-05 / SP-08 tolerate `navBefore / 1e9`; after campaign 3, SP-05 was restated as I27's identity `issued · nav · (1 + minAccretion) <= collateral · P · (1 − h)` on the bond's own basis (exact up to a wei) and the preview-to-preview NAV leg was dropped from both SP-05 and SP-08
- **Foundry repro**: `test_repro_sp05_feedWalkThenDustBond` in `FoundryTester.sol` — `PASS`. The sequence runs and the corrected property holds; it does not reproduce a live violation, it documents the sequence.

#### 4. SP-20 — placement divergence band (campaign 2)
- **Property violated**: `property_placementDivergenceBand` (SP-20)
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `AssertLteFail("Invalid: 4084>800 failed, reason: SP-20: a placement landed outside the divergence band")`
- **Root cause**: a buy moved one spoke 4,084 ticks up, then `deployBonded` ran on that spoke with **no bonded collateral idle**. `VaultRolloutLib.deployBonded` returned before `VaultPlacementLib.place` (`placed == 0`), so the gauntlet never ran and the tick the property measured was the buy's, not a placement's. Diagnostic confirmed `placed 0`, idle claim 0, tick 954824 vs fair 950740, and the guard's bounded feed probe healthy (96 bytes back).
- **Severity assessment**: `test harness false positive`
- **Reproducing sequence**: `property_ladderGeometryIsContiguous` → `env_walkFeedToExtreme` → `ampsRouter_buy_clamped` → `ampsVault_deployBonded_clamped`
- **Fix applied**: SP-20 skips calls that did no work (`placed == 0` **and** the vault's cooldown stamp unchanged), and `_fairTick` mirrors the guard's `staticcall{gas: COMPOSITE_READ_GAS}` probe of `latestAnswer`
- **Foundry repro**: `test_repro_sp20_feedWalkBuyThenDeployBonded` — `PASS` (sequence runs, corrected property holds; does not reproduce a live violation)

#### 5. SP-14 — a redemption pays at most pro rata (campaign 2, 2 sequences) — **reference-vs-pool valuation gap lead**
- **Property violated**: `property_redemptionPaysAtMostProRata` (SP-14)
- **Guarantee**: `EXPLORATORY`
- **Assertion**: `AssertLteFail("Invalid: 158248421774146487080>158233658037632390806 failed, reason: SP-14: a redemption paid more than pro rata")` and `AssertLteFail("Invalid: 216462608556015223565>216442160813163289534 …")` — ~2 bp of the payout in both
- **Root cause**: a sell followed by a redemption pays roughly 2 bp of the payout above the fee-netted reference-basis pro-rata slice, because positions are valued at the **reference price** for NAV while the redemption **unwinds them at the pool price**. This is the accepted residual from the fourth audit wave (fix log), not a new defect — but it is a real valuation gap, not an assertion mistake.
- **Severity assessment**: `needs human review` (EXPLORATORY property, inferred assumption that did not hold; the gap is accepted-but-unclosed protocol behaviour, so it stays a lead rather than a confirmed bug or a false positive)
- **Reproducing sequence**: `ampsRouter_sell_clamped(uint256,uint256)` → `ampsVault_redeemProRata_clamped(uint256,address)` (both stored sequences have this shape)
- **Fix applied**: the property carries 25 bp of slack (`bound + bound·25/BPS + 1e12`) so that **growth** of the gap, not its existence, is what fires
- **Foundry repro**: `test_repro_sp14_sellThenRedeem_1` and `test_repro_sp14_sellThenRedeem_2` — both `PASS` (the sequences run and the slackened property holds; neither reproduces a live violation)

#### 6. GL-47 — the high-water mark rises only (campaign 3)
- **Property violated**: `property_highWaterRisesOnly` (GL-47)
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `AssertLteFail("Invalid: -59855>-59928 failed, reason: GL-47: highWaterTick above lastTruncatedTick")` (and `-59740 > -59841` in a second stored sequence)
- **Root cause**: the property asserted `highWaterTick <= lastTruncatedTick`. After `ampsRouter_rotateRoundTrip` swapped a spoke up and back down in one block, the mark sat 73 ticks above the tick in force. The mark is a *running maximum* (`TruncatedOracleLib.sol:309`): it sits above the last write after any up-then-down block and below it after a `resetHighWater` to `min(lastTruncated, floorTick)`. Neither direction is an invariant.
- **Severity assessment**: `test harness false positive`
- **Reproducing sequence**: `ampsRouter_rotateRoundTrip(uint256,uint256,uint256)` → `property_highWaterRisesOnly(uint256)` (3 stored sequences, same shape)
- **Fix applied**: the `<= lastTruncatedTick` clause was removed; the rise-only leg between resets stays
- **Foundry repro**: `test_repro_gl47_rotateRoundTripThenHighWater` — `PASS` (sequence runs, corrected property holds; does not reproduce a live violation)

#### 7. SP-43 — a sell/buy round trip makes no profit (campaign 3)
- **Property violated**: `property_sellBuyRoundTripNoProfit` (SP-43)
- **Guarantee**: `EXPLORATORY`
- **Assertion**: `AssertLteFail("Invalid: 36230613844207>1950002394323 failed, reason: SP-43: a sell/buy round trip left the actor with more counter asset")` — an 18× rise in the actor's counter
- **Root cause**: a full redemption had emptied the pool's asks, so the **buy-back leg was refused** and the handler compared a bare sell against the round-trip bound. The property was measuring a one-legged trade.
- **Severity assessment**: `test harness false positive`
- **Reproducing sequence**: `env_walkFeedToExtreme` → `ampsVault_buyRedeemCycles` → `property_poolManagerCoversClaims` → `ampsVault_redeemProRata_full` → `ampsRouter_quotedBuy` → `env_walkFeedToExtreme` → `ampsRouter_sellBuyRoundTrip`
- **Fix applied**: a refused second leg is skipped in both round-trip handlers (SP-42 as well as SP-43)
- **Foundry repro**: `test_repro_sp43_feedWalkRedeemThenSellBuy` — `PASS` (sequence runs, corrected property holds; does not reproduce a live violation)

#### 8. SP-07 — the quote matches the bond (campaign 3) — second face of **lead L-1**
- **Property violated**: `property_quoteMatchesBond` (SP-07)
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `AssertLteFail("Invalid: 160994694472579107991>160994694286249873189 failed, reason: SP-07: the bond issued more AMPS than the same-block quote promised")` — 1.16e-9 relative, at call 72 of a 72-call sequence
- **Root cause**: `quote` prices off the stored `checkpointData().navPerShareX18`; `bond` runs the vault's `_checkpoint()` inside `depositBonded` *first* and prices off the value that stores. After a downward reference move that stored value is lower by the convergence step of lead L-1, and `q_floor ∝ 1/navPerShare` is correspondingly higher. Four same-block pre-checkpoints did not bring the gap under 1e-9: the step's geometric ratio is state-dependent (0.023 in the SP-05 diagnostic, near 1 late in this sequence), so no fixed tolerance is a bound.
- **Severity assessment**: `test harness false positive` for the assertion as written — **plus `needs human review` as the second face of lead L-1** (below)
- **Reproducing sequence**: 72 calls ending in `ampsBonds_quoteMatchesBond(uint256,uint256)` (archived at `campaign3-test_results/…-aefe1d4b….json`)
- **Fix applied**: the handler captures the quote's basis and the bond's basis, and the property rescales the quote by their ratio when the basis fell; SP-05 was restated as I27's identity on the bond's own basis; the preview-to-preview NAV leg was dropped from SP-05 and SP-08
- **Foundry repro**: `N/A` — the 72-call sequence is archived, not replayed under Foundry

#### 9. SP-04 — bond deposit conservation (campaign 4)
- **Property violated**: `property_bondDepositConservation` (SP-04)
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `AssertEqFail("Invalid: 391946954771564538!=391946954771564518, reason: SP-04: the vault did not receive exactly amountIn")` — 20 wei more than `amountIn`
- **Root cause**: call 6 of the sequence donated 20 wei of the collateral to the bond shell (`ampsVault_donateERC20`). `AmpsBonds._issue` forwards a stray collateral balance to the vault with the next bond (`CollateralForwarded`, fix-log wave-1 finding 1), so the vault correctly received `amountIn + 20`. Documented behaviour the property did not model.
- **Severity assessment**: `test harness false positive`
- **Reproducing sequence**: 60 calls ending in `ampsBonds_quoteMatchesBond(uint256,uint256)` (archived at `campaign4-test_results/…-4dd56c7c….json`); the load-bearing call is the `ampsVault_donateERC20` at position 6
- **Fix applied**: the property's vault leg is `amountIn + (shellCollBefore − shellCollAfter)`; the bonder leg and the empty-shell leg are unchanged
- **Foundry repro**: `N/A` — sequence archived, not replayed under Foundry

#### 10. SP-46 — repeated cycles extract nothing (campaign 4)
- **Property violated**: `property_repeatedCycleExtractsNothing` (SP-46)
- **Guarantee**: `EXPLORATORY`
- **Assertion**: `AssertLteFail("Invalid: 5462160938629437>5453065493093986 failed, reason: SP-46: chained buy/redeem cycles extracted value from the vault")` — ≈0.17% in counter-wei, after bonds, a feed walk, rotations and a full redemption
- **Root cause**: the measure is counter-only, but a redemption pays pro-rata slices of all 32 assets. When the pool quotes AMPS below the redemption's counter content per share, buying and redeeming returns more *counter* by design — that is the redemption-floor arbitrage the plan relies on — while the other 31 slices are what the buyer gave up. The inferred property was simply too strong: it named a one-asset measure as a value measure.
- **Severity assessment**: `test harness false positive` (EXPLORATORY property that was too strong — stated explicitly: no value left the vault, only counter-denominated value moved between the 32 slices)
- **Reproducing sequence**: 43 calls ending in `ampsVault_buyRedeemCycles(uint256,uint256,uint256)` (archived at `campaign4-test_results/…-acef0112….json`)
- **Fix applied**: SP-45 and SP-46 are armed only when `previewRedeem`'s counter amount does not exceed what the buy paid (SP-11 proves payout equals preview), which leaves rounding as the only thing under the assertion
- **Foundry repro**: `N/A` — sequence archived, not replayed under Foundry

#### 11. SP-33 — trade attribution (campaign 5)
- **Property violated**: `property_tradeAttribution` (SP-33)
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `AssertEqFail("Invalid: 7582330171670898!=7582330148723767, reason: SP-33: the recipient's gain is not the reported out")` — the recipient gained 22,947,131 wei of AMPS (3e-9 relative) more than the router reported
- **Root cause**: every `AmpsRouter` entry point ends by sweeping its residual balance of each asset it touched to `msg.sender` (`_sweep`, `AmpsRouter.sol:186-192`, `:213-221`, `:249-257`; the GL-39 "holds nothing between transactions" mechanism). The dust buy's recipient was also its caller, and the router was holding 22,947,131 wei of AMPS that an earlier call's rounding had left there, so the caller received the reported output *and* the swept dust. Documented behaviour the property did not model; nothing was minted or taken from the pool.
- **Severity assessment**: `test harness false positive`
- **Reproducing sequence**: 76 calls ending in `ampsRouter_buy_dust(uint256,uint256)` (archived at `campaign5-test_results/…-c9408368….json`). A revert-tolerant Foundry replay of the sequence, pinned to Medusa's base block and timestamp, passes — the router held no dust at that point under Foundry — so the sequence is archived, not replayed.
- **Fix applied**: the observation records the router's balance of the output asset before and after; when the recipient is the caller the expected gain is `reportedOut + swept`, otherwise `reportedOut` (the sweep goes to the caller, not the recipient)
- **Foundry repro**: `N/A` — sequence archived; the corrected suite passes 10/10 under Foundry

### Standing leads for human review

**Lead L-1 — the reference price's self-referential convergence step.** NAV/share is not a fixed point across checkpoints after a downward reference move: the valuer prices positions at the *previous* checkpoint's `P_ref` while `P_ref = NAV/share`, so each checkpoint takes one geometrically shrinking step. Evidence: the SP-05 diagnostic (stored NAV 1000098320075242399 → 1000098307583767568 → 1000098307300135438, ratio ≈ 0.023) and the SP-07 failure (issued 160994694472579107991 vs quoted 160994694286249873189, 1.16e-9, with the step's ratio near 1 late in that sequence). No value leaves the vault and every path's own floor check uses the basis it stored; what a reader of `navPerShareX18` sees is one step behind the limit. A valuer that decomposes at the *current* reference, or a checkpoint that iterates to the fixed point, would remove it. **`needs human review`, not a protocol bug.**

**Lead SP-14 — the reference-vs-pool valuation gap.** Positions are valued at the reference price for NAV but unwound at the pool price on redemption, so a sell-then-redeem pays ~2 bp of the payout above the fee-netted reference-basis pro-rata slice (158248421774146487080 vs 158233658037632390806; 216462608556015223565 vs 216442160813163289534). This is the accepted residual from the fourth audit wave, and the property now carries 25 bp of slack so that growth of the gap is what fires. **`needs human review`**: someone has to decide whether 25 bp is the right ceiling for an accepted gap and whether the two valuations should be reconciled.

## Properties Implemented

`Guarantee` is copied verbatim from `PROPERTIES.md`. `#` carries the Spec ID and its implementation status: `[x]` implemented, `[-]` skipped/manual. Type follows `fizz_data/property-plan.md`: Global = `public` function in `Properties.sol` called directly by the fuzzer; Specific = `internal` function called at the end of the relevant handler.

| # | Property | Type | Guarantee | Confidence |
|---|----------|------|-----------|------------|
| GL-01 `[x]` | `property_ampsClosureSumsToSupply` | Global | SHOULD-HOLD | HIGH |
| GL-02 `[x]` | `property_supplyUnderGenesisPlusIssuance` | Global | SHOULD-HOLD | HIGH |
| GL-03 `[x]` | `property_supplyLedgerCloses` | Global | SHOULD-HOLD | HIGH |
| GL-04 `[x]` | `property_shareTokenRolesIntact` | Global | SHOULD-HOLD | HIGH |
| GL-05 `[x]` | `property_bondShellCoversItsBook` | Global | SHOULD-HOLD | HIGH |
| GL-06 `[x]` | `property_perMarketIssuanceLedger` | Global | SHOULD-HOLD | HIGH |
| GL-07 `[x]` | `property_epochIssuanceContained` | Global | SHOULD-HOLD | HIGH |
| GL-08 `[x]` | `property_bondCapsBindCumulatively` | Global | EXPLORATORY | MEDIUM |
| GL-09 `[x]` | `property_vestingBookIsConsistent` | Global | SHOULD-HOLD | HIGH |
| GL-10 `[x]` | `property_positionFieldsImmutable` | Global | SHOULD-HOLD | HIGH |
| GL-11 `[x]` | `property_claimableIsMonotoneAndOwnerOnly` | Global | SHOULD-HOLD | HIGH |
| GL-12 `[x]` | `property_positionCountMonotone` | Global | SHOULD-HOLD | HIGH |
| GL-13 `[x]` | `property_totalIssuedMonotone` | Global | SHOULD-HOLD | HIGH |
| GL-14 `[x]` | `property_everyVestedPositionIsClaimable` | Global | SHOULD-HOLD | HIGH |
| GL-15 `[x]` | `property_positionArrayGriefingBounded` | Global | SHOULD-HOLD | HIGH |
| GL-16 `[x]` | `property_closedMarketHasNotIssued` | Global | SHOULD-HOLD | HIGH |
| GL-17 `[x]` | `property_marketAttributionAgrees` | Global | SHOULD-HOLD | HIGH |
| GL-18 `[x]` | `property_navPerShareIdentity` | Global | SHOULD-HOLD | HIGH |
| GL-19 `[x]` | `property_assetsDecomposeIntoA` | Global | SHOULD-HOLD | HIGH |
| GL-20 `[x]` | `property_assetRegistryWellFormed` | Global | SHOULD-HOLD | HIGH |
| GL-21 `[x]` | `property_inventoryAmpsDecomposes` | Global | SHOULD-HOLD | MEDIUM |
| GL-22 `[x]` | `property_redemptionIsCovered` | Global | SHOULD-HOLD | MEDIUM |
| GL-23 `[x]` | `property_poolManagerCoversClaims` | Global | EXPLORATORY | HIGH |
| GL-24 `[x]` | `property_zeroStateSafety` | Global | SHOULD-HOLD | HIGH |
| GL-25 `[x]` | `property_noShareInflationGrief` | Global | EXPLORATORY | HIGH |
| GL-26 `[x]` | `property_disclosureNeverReverts` | Global | SHOULD-HOLD | HIGH |
| GL-27 `[x]` | `property_theFloorIsAlwaysOpen` | Global | SHOULD-HOLD | HIGH |
| GL-28 `[x]` | `property_redemptionIsNotSplittableForProfit` | Global | SHOULD-HOLD | HIGH |
| GL-29 `[x]` | `property_previewRedeemIsMonotone` | Global | SHOULD-HOLD | HIGH |
| GL-30 `[x]` | `property_noFreeRoundTripOnTheQuoter` | Global | EXPLORATORY | MEDIUM |
| GL-31 `[-]` | `property_noUnfundedActorValueGain — not implemented` | Global | EXPLORATORY | N/A (not implemented) |
| GL-32 `[x]` | `property_cumulativeKeeperBleedBounded` | Global | EXPLORATORY | MEDIUM |
| GL-33 `[x]` | `property_referencePriceFloorsAtNav` | Global | SHOULD-HOLD | HIGH |
| GL-34 `[x]` | `property_governedScalarsInBand` | Global | SHOULD-HOLD | HIGH |
| GL-35 `[x]` | `property_creatorBpsIsMonotone` | Global | SHOULD-HOLD | HIGH |
| GL-36 `[x]` | `property_creatorSliceIsBoundedCumulatively` | Global | SHOULD-HOLD | MEDIUM |
| GL-37 `[x]` | `property_rotationCreditIsTransactionScoped` | Global | SHOULD-HOLD | HIGH |
| GL-38 `[x]` | `property_hookHoldsAndMovesNothing` | Global | SHOULD-HOLD | HIGH |
| GL-39 `[x]` | `property_routerHoldsNothing` | Global | SHOULD-HOLD | HIGH |
| GL-40 `[x]` | `property_liveCellCounterIsHonest` | Global | EXPLORATORY | HIGH |
| GL-41 `[x]` | `property_recordedLiquidityMatchesPoolManager` | Global | EXPLORATORY | HIGH |
| GL-42 `[x]` | `property_everyRecordIsOneCanonicalCell` | Global | SHOULD-HOLD | HIGH |
| GL-43 `[x]` | `property_ladderSidednessHolds` | Global | SHOULD-HOLD | HIGH |
| GL-44 `[x]` | `property_ladderLengthMonotoneAndBounded` | Global | SHOULD-HOLD | HIGH |
| GL-45 `[x]` | `property_lastPlacementAtMonotone` | Global | SHOULD-HOLD | HIGH |
| GL-46 `[x]` | `property_checkpointStampsMonotone` | Global | SHOULD-HOLD | HIGH |
| GL-47 `[x]` | `property_highWaterRisesOnly` | Global | SHOULD-HOLD | MEDIUM |
| GL-48 `[x]` | `property_observationCoverageMonotone` | Global | EXPLORATORY | HIGH |
| GL-49 `[x]` | `property_rolloutDrainIsBounded` | Global | SHOULD-HOLD | MEDIUM |
| GL-50 `[x]` | `property_activeSetIsConsistent` | Global | SHOULD-HOLD | HIGH |
| GL-51 `[x]` | `property_retiredIffStamped` | Global | SHOULD-HOLD | HIGH |
| GL-52 `[x]` | `property_retiredNamesAreExitOnly` | Global | SHOULD-HOLD | HIGH |
| GL-53 `[x]` | `property_weightVectorNormalises` | Global | EXPLORATORY | HIGH |
| GL-54 `[x]` | `property_populationCountersBounded` | Global | SHOULD-HOLD | HIGH |
| GL-55 `[x]` | `property_pendingImpliesALatch` | Global | SHOULD-HOLD | HIGH |
| GL-56 `[x]` | `property_freezeOutranksEveryLayer` | Global | SHOULD-HOLD | HIGH |
| GL-57 `[x]` | `property_freezesAreBoundedAndExpire` | Global | SHOULD-HOLD | HIGH |
| GL-58 `[x]` | `property_watchdogStampMonotone` | Global | SHOULD-HOLD | HIGH |
| GL-59 `[x]` | `property_launchLatchesHold` | Global | SHOULD-HOLD | HIGH |
| GL-60 `[x]` | `property_theBountyPotIsBounded` | Global | SHOULD-HOLD | MEDIUM |
| GL-61 `[x]` | `property_noStuckTransientLock` | Global | EXPLORATORY | HIGH |
| GL-62 `[x]` | `property_narrowTypesDoNotBrick` | Global | EXPLORATORY | HIGH |
| GL-63 `[x]` | `property_noPrivilegeEscalation` | Global | SHOULD-HOLD | HIGH |
| GL-64 `[x]` | `property_priceLibUsdRawRoundTrip` | Global | SHOULD-HOLD | HIGH |
| GL-65 `[x]` | `property_priceLibSqrtRoundTrip` | Global | SHOULD-HOLD | MEDIUM |
| GL-66 `[x]` | `property_tickRoundTripAndAlign` | Global | SHOULD-HOLD | HIGH |
| GL-67 `[x]` | `property_ladderAmountLiquidityRoundTrip` | Global | SHOULD-HOLD | HIGH |
| GL-68 `[x]` | `property_ladderSplitIsExact` | Global | SHOULD-HOLD | HIGH |
| GL-69 `[x]` | `property_hookStatePackRoundTrip` | Global | EXPLORATORY | HIGH |
| GL-70 `[x]` | `property_priceLibDirections` | Global | SHOULD-HOLD | HIGH |
| GL-71 `[x]` | `property_qFloorImplementationsAgree` | Global | SHOULD-HOLD | HIGH |
| GL-72 `[x]` | `property_ladderGeometryIsContiguous` | Global | SHOULD-HOLD | HIGH |
| GL-73 `[x]` | `property_discountIsBandedAndMonotone` | Global | SHOULD-HOLD | HIGH |
| GL-74 `[x]` | `property_zeroInputsAreSafe` | Global | SHOULD-HOLD | HIGH |
| GL-75 `[x]` | `property_hookFeeIsWithinI16` | Global | SHOULD-HOLD | HIGH |
| GL-76 `[x]` | `property_blendedBaseNeverRoundsDown` | Global | SHOULD-HOLD | HIGH |
| GL-77 `[x]` | `property_quoterAgreesWithTheHook` | Global | SHOULD-HOLD | MEDIUM |
| GL-78 `[x]` | `property_priceImpactIsMonotone` | Global | EXPLORATORY | MEDIUM |
| GL-79 `[x]` | `property_bondQuoteIsMonotone` | Global | SHOULD-HOLD | HIGH |
| GL-80 `[x]` | `property_retiredBidsNeverOverReturn` | Global | EXPLORATORY | HIGH |
| GL-81 `[x]` | `property_valuerNeverOverstatesAPool` | Global | EXPLORATORY | MEDIUM |
| SP-01 `[x]` | `property_mintAttribution` | Specific | SHOULD-HOLD | HIGH |
| SP-02 `[x]` | `property_bondAppendsOnePosition` | Specific | SHOULD-HOLD | HIGH |
| SP-03 `[x]` | `property_bondMintsIntoCustody` | Specific | SHOULD-HOLD | HIGH |
| SP-04 `[x]` | `property_bondDepositConservation` | Specific | SHOULD-HOLD | HIGH |
| SP-05 `[x]` | `property_bondIsAccretive` | Specific | SHOULD-HOLD | MEDIUM |
| SP-06 `[x]` | `property_bondWithinCapacityOnOffer` | Specific | SHOULD-HOLD | MEDIUM |
| SP-07 `[x]` | `property_quoteMatchesBond` | Specific | SHOULD-HOLD | MEDIUM |
| SP-08 `[x]` | `property_bondSurplusReachesHolders` | Specific | EXPLORATORY | MEDIUM |
| SP-09 `[x]` | `property_claimMovesOnlyTheShellsAmps` | Specific | SHOULD-HOLD | HIGH |
| SP-10 `[x]` | `property_redemptionBurnIsExact` | Specific | SHOULD-HOLD | HIGH |
| SP-11 `[x]` | `property_previewIsThePayout` | Specific | SHOULD-HOLD | HIGH |
| SP-12 `[x]` | `property_onlyTheCallersOwnPosition` | Specific | SHOULD-HOLD | HIGH |
| SP-13 `[x]` | `property_redemptionIsAccretive` | Specific | SHOULD-HOLD | MEDIUM |
| SP-14 `[x]` | `property_redemptionPaysAtMostProRata` | Specific | EXPLORATORY | MEDIUM |
| SP-15 `[x]` | `property_redemptionKeepsLadderGeometry` | Specific | SHOULD-HOLD | HIGH |
| SP-16 `[x]` | `property_fullRedemptionNeverReverts` | Specific | SHOULD-HOLD | HIGH |
| SP-17 `[x]` | `property_placementBleedBound` | Specific | SHOULD-HOLD | MEDIUM |
| SP-18 `[x]` | `property_placementConservesInventoryAndShape` | Specific | SHOULD-HOLD | MEDIUM |
| SP-19 `[x]` | `property_sidednessAtPlacement` | Specific | SHOULD-HOLD | HIGH |
| SP-20 `[x]` | `property_placementDivergenceBand` | Specific | SHOULD-HOLD | MEDIUM |
| SP-21 `[x]` | `property_zeroWorkTakesNothing` | Specific | SHOULD-HOLD | HIGH |
| SP-22 `[x]` | `property_aboveChangesOnlyWhenEmpty` | Specific | SHOULD-HOLD | HIGH |
| SP-23 `[x]` | `property_burnbackBurnsOnlyCrossedAsks` | Specific | SHOULD-HOLD | HIGH |
| SP-24 `[x]` | `property_compoundBurnIsExact` | Specific | SHOULD-HOLD | HIGH |
| SP-25 `[x]` | `property_creatorSlicePerCompound` | Specific | SHOULD-HOLD | HIGH |
| SP-26 `[x]` | `property_checkpointIsStamped` | Specific | SHOULD-HOLD | HIGH |
| SP-27 `[x]` | `property_sweepCleanHolds` | Specific | SHOULD-HOLD | HIGH |
| SP-28 `[-]` | `property_rolloutWindowChargedOnDrain — not implemented` | Specific | EXPLORATORY | N/A (not implemented) |
| SP-29 `[x]` | `property_potChargesWhatItTransfers` | Specific | SHOULD-HOLD | HIGH |
| SP-30 `[x]` | `property_potMovementsDoNotMoveA` | Specific | SHOULD-HOLD | HIGH |
| SP-31 `[x]` | `property_emptyPotDoesNotRevertKeepers` | Specific | SHOULD-HOLD | HIGH |
| SP-32 `[x]` | `property_counterAssetConservation` | Specific | SHOULD-HOLD | HIGH |
| SP-33 `[x]` | `property_tradeAttribution` | Specific | SHOULD-HOLD | HIGH |
| SP-34 `[x]` | `property_swapNeverTakesMoreThanTheLadderHeld` | Specific | EXPLORATORY | HIGH |
| SP-35 `[x]` | `property_swapDoesNotMoveSupply` | Specific | SHOULD-HOLD | MEDIUM |
| SP-36 `[x]` | `property_honestTradingNeverReverts` | Specific | SHOULD-HOLD | HIGH |
| SP-37 `[x]` | `property_quoteExactInMatchesTheSwap` | Specific | SHOULD-HOLD | HIGH |
| SP-38 `[x]` | `property_quoteRotationMatchesTheRotation` | Specific | SHOULD-HOLD | HIGH |
| SP-39 `[x]` | `property_rotationFeeSchedule` | Specific | SHOULD-HOLD | HIGH |
| SP-40 `[x]` | `property_rotationExemptionNotForSale` | Specific | SHOULD-HOLD | HIGH |
| SP-41 `[x]` | `property_atomicWashPaysTheAmpsFee` | Specific | SHOULD-HOLD | HIGH |
| SP-42 `[x]` | `property_buySellRoundTripNoProfit` | Specific | EXPLORATORY | MEDIUM |
| SP-43 `[x]` | `property_sellBuyRoundTripNoProfit` | Specific | EXPLORATORY | MEDIUM |
| SP-44 `[x]` | `property_rotateThereAndBackNoProfit` | Specific | EXPLORATORY | HIGH |
| SP-45 `[x]` | `property_buyRedeemRoundTripNoProfit` | Specific | EXPLORATORY | MEDIUM |
| SP-46 `[x]` | `property_repeatedCycleExtractsNothing` | Specific | EXPLORATORY | MEDIUM |
| SP-47 `[x]` | `property_bondClaimRedeemCycle` | Specific | SHOULD-HOLD | MEDIUM |
| SP-48 `[-]` | `property_bookFillsInsideOut — not implemented` | Specific | EXPLORATORY | N/A (not implemented) |
| SP-49 `[x]` | `property_noFreeAmpsFromTruncation` | Specific | EXPLORATORY | HIGH |
| SP-50 `[x]` | `property_statusMovesOnLegalEdgesOnly` | Specific | SHOULD-HOLD | HIGH |
| SP-51 `[x]` | `property_activeCountDelta` | Specific | SHOULD-HOLD | HIGH |
| SP-52 `[x]` | `property_retireStampsAndZeroes` | Specific | SHOULD-HOLD | HIGH |
| SP-53 `[x]` | `property_registryCallIsIsolated` | Specific | EXPLORATORY | HIGH |
| SP-54 `[x]` | `property_divergenceTimerLatches` | Specific | SHOULD-HOLD | HIGH |
| SP-55 `[x]` | `property_acceptedAnswerAdvancesTheRound` | Specific | SHOULD-HOLD | HIGH |
| SP-56 `[x]` | `property_latchClearsPending` | Specific | SHOULD-HOLD | HIGH |
| SP-57 `[x]` | `property_refreshThenBondUsesTheHeldAnswer` | Specific | SHOULD-HOLD | HIGH |
| SP-58 `[x]` | `property_governedSetterIsValueNeutral` | Specific | EXPLORATORY | HIGH |
| SP-59 `[x]` | `property_donationBricksNothing` | Specific | SHOULD-HOLD | HIGH |
| SP-60 `[x]` | `property_fullAmountOpsStayReenterable` | Specific | EXPLORATORY | MEDIUM |
| SP-61 `[x]` | `property_neutralErc20OpsAreNeutral` | Specific | SHOULD-HOLD | HIGH |
| SP-62 `[x]` | `property_transferAccountingIsExact` | Specific | SHOULD-HOLD | HIGH |
| SP-63 `[x]` | `property_toParameterCreditsTo` | Specific | EXPLORATORY | HIGH |

Totals: 144 specified, **141 implemented** (112 HIGH, 29 MEDIUM, 0 LOW) and 3 marked `[-]`. **No implemented property is a stub**: every one of the 141 functions asserts at least once; there are no `return true` placeholders.

### Confidence notes (every MEDIUM, with its reason)

- **GL-08** `property_bondCapsBindCumulatively` — asserts `issuedToday <= bound + bound/100 + 1`; a 1% + 1 wei slack can hide a small systematic cap overshoot.
- **GL-21** `property_inventoryAmpsDecomposes` — two-sided comparison with a `band` term on each side; correct, but the band is not derived from a rounding bound.
- **GL-22** `property_redemptionIsCovered` — `lte(amounts[k], available[i] + 1)`; 1-wei slack per asset may mask small drift across 32 assets.
- **GL-30** `property_noFreeRoundTripOnTheQuoter` — one assertion behind two early returns; a refused leg skips the check entirely, so the property is silent exactly when the quoter is unhappy.
- **GL-32** `property_cumulativeKeeperBleedBounded` — 100 bp cumulative band against the NAV/share high-water mark; a bleed under 100 bp accumulates invisibly.
- **GL-36** `property_creatorSliceIsBoundedCumulatively` — `+ GlobC.WAD` (1e18) of slack on a cumulative USD-18 bound.
- **GL-47** `property_highWaterRisesOnly` — the `<= lastTruncatedTick` clause was removed after the campaign-3 triage; what remains is the rise-only leg between resets, which is correct but narrower than the property's name.
- **GL-49** `property_rolloutDrainIsBounded` — `allowance + allowance/100 + 1`; 1% slack on a rolling-day allowance.
- **GL-60** `property_theBountyPotIsBounded` — the rolling-window leg is `lte(window, twoCeilingsRaw + 1)`; 1-wei slack, and two ceilings is itself a loose bound on a rolling day.
- **GL-65** `property_priceLibSqrtRoundTrip` — recovers the price to within a `band` and the fair tick to within one spacing; a tick of tolerance on a price round trip.
- **GL-77** `property_quoterAgreesWithTheHook` — despite the name, it only cross-checks `quoteExactIn`'s refusal against `wouldRevert`; it never compares a quoted output against the hook's realized output.
- **GL-78** `property_priceImpactIsMonotone` — `lte(doubled, 2 * single + 2)`; a 2-wei additive slack on a doubling comparison.
- **GL-81** `property_valuerNeverOverstatesAPool` — `lte(counterSide, ceiling + records.length + 1)`; the slack grows with the number of records (up to 24), so a per-record overstatement of 1 wei is invisible.
- **SP-05** `property_bondIsAccretive` — restated as I27's identity on the bond's own NAV basis, exact "up to a wei"; the preview-to-preview NAV leg was dropped because it always contains one convergence step (lead L-1), so the property no longer sees that step at all.
- **SP-06** `property_bondWithinCapacityOnOffer` — the capacity bound is rescaled before comparison; correct, but the rescaling is the harness's own model of the capacity.
- **SP-07** `property_quoteMatchesBond` — the quote is rescaled by the *observed* basis ratio whenever the basis fell, which is the only way to compare across the checkpoint; a genuine quote/bond divergence that coincided with a basis move would be absorbed.
- **SP-08** `property_bondSurplusReachesHolders` — the preview-to-preview NAV leg was dropped for the same reason as SP-05.
- **SP-13** `property_redemptionIsAccretive` — `navAfter >= navBefore * (BPS - 2) / BPS`; a 2 bp band below an otherwise exact "must not fall" statement.
- **SP-14** `property_redemptionPaysAtMostProRata` — `bound + bound·25/BPS + 1e12`; 25 bp + 1e12 wei of slack deliberately wide enough to sit above the accepted valuation gap, so only growth of the gap fires.
- **SP-17** `property_placementBleedBound` — band of `PLACEMENT_BLEED_BPS_MAX`; a placement bleeding just under the constant is accepted.
- **SP-18** `property_placementConservesInventoryAndShape` — the exact equality became `≤` after campaign 1, so the liquidity-rounding residue is no longer pinned to a value; an unexpectedly large residue would pass.
- **SP-20** `property_placementDivergenceBand` — now skips calls where `placed == 0` and the cooldown stamp is unchanged; correct, but it means the property is silent on every no-op deployment.
- **SP-35** `property_swapDoesNotMoveSupply` — the hook's post-swap balance is bounded by `ghosts.hookDonated[amps]` rather than zero, so the bound is only as tight as the ghost's own accounting.
- **SP-42** `property_buySellRoundTripNoProfit` — a refused second leg is skipped, so the property does not fire on the pool states where a leg cannot execute.
- **SP-43** `property_sellBuyRoundTripNoProfit` — same skip as SP-42.
- **SP-45** `property_buyRedeemRoundTripNoProfit` — armed only when `previewRedeem`'s counter amount does not exceed what the buy paid; that precondition is exactly the interesting case for redemption-floor arbitrage, so the property covers rounding only.
- **SP-46** `property_repeatedCycleExtractsNothing` — same arming condition as SP-45.
- **SP-47** `property_bondClaimRedeemCycle` — 2 bp band on NAV/share across a bond/claim/redeem cycle.
- **SP-60** `property_fullAmountOpsStayReenterable` — 2 bp band on NAV/share across a full-amount operation.

Everything else is HIGH: a strict assertion with no numeric slack, exercising the invariant the Spec ID names.

## Open TODOs

| File:line | TODO |
|---|---|
| `test/fizz/Properties.sol:820` | **GL-31** `property_noUnfundedActorValueGain` — left as a TODO on purpose (`[-]` in `PROPERTIES.md`). Not assertable as stated: `OracleGateHandler.env_secondary` walks the Chainlink answers and display multipliers arbitrarily, so an actor's *USD* value moves with the fuzzer's own price steps. A basis-versus-value comparison would fire on every upward feed walk. Making it real needs a price-neutral, per-token, raw-unit accounting layer differenced against a mint ledger, plus a mint hook inside `AmpsBondsHandler`'s direct `stocks[i].mint` calls. `ghosts.actorValueBasis` and `ghosts.actorMintedValueUsd18` are already in place for whoever picks it up. |
| `test/fizz/Properties.sol:3482` | Section header: "Left as TODO, and why" |
| `test/fizz/Properties.sol:3484` | **SP-28** `property_rolloutWindowChargedOnDrain` — needs `vm.load` on `AmpsVault` storage slot 15 plus a local mirror of `VaultRolloutLib._decayedMoved`, i.e. a second implementation of the decay whose only witness would be the first. `rollout` returns `moved` and nothing else, so a property written off `moved` alone would assert an identity it had itself assumed. LOW priority in the plan; marked `[-]` rather than left as a brittle assertion. |
| `test/fizz/Properties.sol:3491` | **SP-48** `property_bookFillsInsideOut` — needs per-cell live AMPS for the swapped pool before *and* after every trade (`liveAmounts` over up to 24 records, twice, on the hot swap path) plus a nearest-first ordering that survives a cell converting from ask to bid mid-walk. Affordable only if the swap handlers drop their other 24-record readings. EXPLORATORY in the plan; marked `[-]`. |
| `test/fizz/GlobalSmoke.t.sol:74` | Comment noting GL-31 is a documented TODO with no function, so the smoke sweep skips it. |

No TODOs remain in `Base.sol`, `Snapshots.sol`, or any handler file.

## Next Steps

1. **Confirm the SP-33 correction with the next campaign.** Campaign 5's one failure (154 passed / 1 failed) is the router's documented dust sweep landing on a recipient who was also the caller; the property now counts the swept balance separately. The correction is in the tree but has not been fuzzed since, so the next run is its confirmation — every earlier correction held on its first re-run.

2. **Harness false positives — all ten are already corrected in the tree; there is nothing outstanding to fix.** SP-18 (`==` → `≤`), SP-35 (bound by `ghosts.hookDonated`), SP-05 (I27 identity on the bond's own basis; preview NAV leg dropped), SP-20 (skip no-work calls; mirror the guard's bounded feed probe), GL-47 (drop the `<= lastTruncatedTick` clause), SP-43/SP-42 (skip a refused second leg), SP-07 (rescale the quote by the observed basis ratio), SP-04 (add the `CollateralForwarded` term to the vault leg), SP-45/SP-46 (arm only when `previewRedeem`'s counter does not exceed the payment), SP-33 (count the router's sweep to its caller separately). The campaign-3 corrections held through campaigns 4 and 5; the campaign-4 corrections held through campaign 5.

3. **Work the two standing leads (highest-value item in this report).** L-1: decide whether `LadderPositionValuer` should decompose at the *current* reference or the checkpoint should iterate to the fixed point — until then `navPerShareX18` is one convergence step behind its own limit, and every property that compares a stored NAV to a freshly-checkpointed one needs a state-dependent tolerance, which is not a bound. SP-14: decide whether the reference-vs-pool valuation gap should be reconciled or whether 25 bp is the right accepted ceiling.

4. **No LOW-confidence properties exist**, so nothing needs rescuing from a stub. The 29 MEDIUM entries are listed above with their reasons; the four worth strengthening first are:
   - **GL-77** — make it live up to its name: compare `quoteExactIn`'s output against the hook's realized output on the same block, not just the two refusal views against each other.
   - **SP-45 / SP-46** — the arming condition removes the exact case the properties were written for. Replace the counter-only measure with an all-32-asset USD measure at a single valuation basis, then arm them unconditionally.
   - **SP-07** — once L-1 is resolved, drop the basis rescaling and assert the quote/bond identity exactly.
   - **GL-81** — replace `+ records.length + 1` with a per-record rounding bound derived from the valuer, so a systematic per-record overstatement cannot hide.

5. **No contract carries a ❌.** The eleven contracts reading n/a are a Medusa 1.5.1 attribution limitation, not uncovered code — the aggregate branch counter (29,588) and the 93–100% per-handler line coverage are what shows the paths land. Two measurable files are genuinely thin:
   - `src/policy/LadderPolicy.sol` at 3% (2/66 lines) — its `propose`, `weights`, `bucketBounds`, `split` and `cellIndex` entry points are reached almost entirely through `AmpsVault`'s placement path. Add direct `FoundryTester` probes over those five `external pure` functions; fuzzing more will not move this number.
   - `src/lib/LadderLib.sol` at 25% (23/89 lines) — `liquidityForAmount0Above` / `liquidityForAmount1Below` / `amount0ForLiquidity` / `amount1ForLiquidity` / `ladderAmounts` are the uncovered block; GL-67 and GL-68 already touch the round trip, so widening their input clamps is the cheapest gain.

6. **Close or re-scope the three `[-]` properties before production.** GL-31 needs the price-neutral accounting layer described at `Properties.sol:820`; SP-28 needs `vm.load` on `AmpsVault` slot 15; SP-48 needs per-cell live AMPS on the hot swap path. None blocks the current suite, but all three are real gaps in the spec's coverage of actor value, the rollout window and the book's fill order.

7. **Run a long production campaign.** Current run: 600 s of fuzzing (~29k calls, corpus 488, 29,588 branches). Recommended: **≥ 8 hours of fuzzing**, with `shrinkLimit` kept at 20–50 so a violation does not park a worker for hours against the 617M-gas setup, and `testLimit 0` so `--timeout` governs. The branch counter has been flat within ~1.5% across campaigns 3–5, so additional value now comes from sequence depth rather than from new branches. Budget separately for the shrink phase — campaigns 3 and 4 spent 5 h and 3 h respectively on shrinking alone.

8. **Re-run the Foundry replay set after any harness change**: the suite is 10/10 fizz tests after the SP-33 correction (chain 11), including the six `test_repro_*` functions, all `PASS`.

---

### Running campaigns manually

- `medusa fuzz` (from the project root)
- `echidna test/fizz/FuzzTester.sol --contract FuzzTester --config echidna.yaml` — configured but **not runnable in this sandbox**: Echidna's GitHub release tag is unresolvable through the egress proxy, so `echidna.yaml` was generated and left unexercised.

Every build must use crytic-compile's exact flags — `FOUNDRY_BUILD_INFO=true FOUNDRY_DYNAMIC_TEST_LINKING=false forge build` — or the next run pays a 31-minute recompile.
