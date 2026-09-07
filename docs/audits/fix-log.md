# Fix log — 2026-09-07 review

Disposition of every finding and lead in [`amplestock-pashov-ai-audit-report-20260907-045500.md`](amplestock-pashov-ai-audit-report-20260907-045500.md). "Fixed" means the change is in the remediation slice on this branch with the named regression test; the state-model rulings AC–AP in `docs/phase3-state-model.md` §12.5 record the behavioural consequences.

## Findings

| # | Conf. | Finding | Disposition | Where | Test |
|---|---|---|---|---|---|
| 1 | 92 | `AmpsBonds._issue` donation bricks a market | **Fixed** — dust is forwarded to the vault best-effort, never asserted; `CollateralForwarded` | `AmpsBonds._issue` | `AmpsBonds.t.sol::test_collateralDonationCannotBrickTheMarket` |
| 2 | 90 | `_payOut` blocked by one paused/denylisting token | **Fixed** — `try take` → fallback `pm.transfer` of the ERC-6909 claim; idle leg best-effort | `VaultRedeemLib._payOut`, `_payout` | `VaultRedeem.t.sol::test_aPausedConstituentDoesNotStopTheFloor`, `…DenylistsTheVault…`, `…BalanceOfReverts…` |
| 3 | 88 | `sweepClean` unguarded calls on the ungated path | **Fixed** — bounded balance probes, per-token best-effort absorb, `SweepResidue` instead of `SweepDirty`; `_assertSweepZero` removed | `VaultRedeemLib.sweepClean`, `_absorb`, `AmpsVault` | `VaultRedeem.t.sol::test_aDonatedWeiOfAFrozenTokenDoesNotBrickTheOtherEntryPoints`, `VaultAttacks.t.sol::test_aReentrantStockTokenCannotStopTheFloorAndGainsNothing` |
| 4 | 85 | `_burnback` liquidates bid cells | **Fixed** — burn only `upperTick <= highWater && tick <= lowerTick`; mark reset after every ask placement | `VaultPlacementLib._burnback`, `_placeLadder` | `VaultCompound.t.sol::test_i33_bidsLaidByCompoundSurviveASmallDowntick`, `…anAskFullySoldAndFullyBoughtBackIsBurned`, `…LeavesAPartiallyBoughtBackCellAlone`, `…aRolloutPlacedAskUnderAStaleMarkIsNotBurned` |
| 5 | 85 | Zero-work `compound` side effects | **Fixed** — surge, mark reset and cooldown gated on work done | `VaultPlacementLib.compound` | `VaultCompound.t.sol::test_aZeroWorkCompoundLeavesTheSurgeTheMarkAndTheCooldownAlone`, `…CannotDenyTheNextPlacement` |
| 6 | 85 | Creator slice divides realised fees by the base sell fee | **Fixed (bounded)** — divisor floored at `SELL_FEE_BPS_DEFAULT` (≤ 1/5 of fees); the ≤ 1.6x dynamic-fee over-statement is documented and accepted | `VaultPlacementLib._split` | `VaultCompound.t.sol::test_theCreatorSliceIsCappedWhenTheSellFeeIsCutToItsFloor` |
| 7 | 85 | Pre-genesis `checkpoint()` writes `P_ref = 1e15` | **Fixed** — `checkpoint`/`touch` revert `NotInitialized` pre-genesis; `_navPerShare` is 0 at zero supply | `AmpsVault` | `VaultGateResilience.t.sol::VaultPreGenesisTest` (5 tests) |
| 8 | 82 | `evacuate` idle leg / sweep assert brick migration | **Fixed** — best-effort idle transfer, no sweep assertion on the migration path | `VaultNavLib.evacuate`, `AmpsVault.emergencyMigrate` | `VaultMigration.t.sol::test_aBlockedTokenWithAnIdleWeiDoesNotStopTheEvacuation`, `…PausedToken…`, `…BalanceOfReverts…` |
| 9 | 80 | Bonds price a held-back/stale answer with a calendar haircut | **Fixed** — registry reports `min(held, candidate)` while held; gate treats `unconfirmed` as stale and floors the haircut at `CLOSED`; the shell consumes `fresh` | `FeedRegistry._read`, `OracleGate._snapshot/checkBond`, `AmpsBonds._price/_collect` | `AmpsBonds.t.sol::test_heldBackJumpPricesAtTheMinimumWithTheWiderHaircut`, `…staleFeedIsNeverPricedAtAZeroHaircut`, `OracleGate.t.sol::test_degraded_unconfirmedAnswerIsTreatedAsStale` |
| 10 | 80 | `deployBonded` ignores constituent status | **Fixed** — `status != ACTIVE ⇒ return 0` | `VaultRolloutLib.deployBonded` | `VaultRollout.t.sol::test_deployBondedRefusesARetiredConstituent`, `…Frozen…` |
| 11 | 78 | `migrationPredicate` decodes a dirty bool | **Fixed** — hand-decoded word in both probes | `VaultNavLib.migrationPredicate`, `_selfTransferProbe` | `VaultMigration.t.sol::test_theMigrationPredicateSurvivesANonCanonicalBool` |
| 12 | 78 | `emergencyMigrate` skips the hook and registry roles | **Fixed** — `PoolRegistry.setVault`, `AmpsHook.setVault` (storage `vault`), `VaultNavLib.handover` moves six roles | `AmpsVault`, `VaultNavLib`, `PoolRegistry`, `AmpsHook` | `VaultMigration.t.sol::test_theHandoverMovesAllSixRoles`, `AmpsHook.t.sol::test_setVaultMovesEveryVaultOnlyEntryPoint`, `DenylistMigration.t.sol` |
| 13 | 78 | Expired pending jump confirms any candidate | **Fixed** — both branches require agreement with the pending level | `FeedRegistry._jumpConfirmed` | `FeedRegistry.t.sol::test_jump_agedPendingDoesNotConfirmAnUnrelatedRound` |
| 14 | 75 | Jump rule disarms on a stale latch | **Fixed** — stateless previous-round evaluation (`getRoundData(roundId-1/2)`) when the latch is older than a heartbeat | `FeedRegistry._evaluate`, `_probeRound` | `FeedRegistry.t.sol::test_jump_statelessPath*` (5 tests) |
| 15 | 75 | Shell mints the policy's `ampsOut` | **Fixed** — `ampsOut` recomputed from `q` in `_price` and `_quote` | `AmpsBonds._price`, `_quote` | `AmpsBonds.t.sol::test_policyCannotInflateAmpsOutBehindABoundedPrice` |
| 16 | 75 | `compound` re-lays asks at the live tick | **Fixed** — reference anchor, like every other placement | `VaultPlacementLib.compound` | `VaultCompound.t.sol::test_i32_compoundAnchorsTheRelaidAskLadderAtTheReferenceNotTheTick` |
| 17 | 75 | Rotation credit shared across senders | **Fixed** — credit keyed by `sender`; `rotationCredit(address)` | `AmpsHook`, `IAmpsHook` | `RotationCredit.t.sol::test_oneSendersBuyDoesNotDiscountAnothersSell`, `…TheCreditIsBookedToTheRouterBothHopsShare` |
| 18 | 72 | Typed `try` on the gate does not fail open | **Fixed** — bounded hand-decoded reads in `_requireGate`/`_poke` and in `VaultNavLib`'s checkpoint reads; `setPolicyPointer` refuses codeless targets | `AmpsVault`, `VaultNavLib` | `VaultGateResilience.t.sol::VaultGateResilienceTest` (10 tests) |
| 19 | 70 | Saturated multiplier cache vs full-width probe | **Fixed** — compare saturated with saturated | `AmpsHook._detectMultiplierStep` | `AmpsHookObservations.t.sol::test_aMultiplierBeyondUint64ArmsItsStepOnceAndResolves`, `…ArmsNothingOnAnyRefresh` |
| 20 | 70 | `Placed.highestTick` unseeded | **Fixed** | `VaultPlacementLib._executePlace` | `VaultPlacement.t.sol::test_thePlacementLogCarriesTheLaddersRealTopAndBottom` |

## Leads

| Lead | Disposition |
|---|---|
| Watchdog restamped before it is read (`checkpoint`/`poke`) | Accepted as designed (a checkpoint clears a passed outage); a post-outage cool-down is a candidate for v1.5 |
| Management gate follows the equity calendar (`CLOSED ⇒ DEGRADED`) | Accepted: placements pause when equities are closed; the timelock keeps the gate's own setters and can batch `unfreezeProtocol` + `setPolicyPointer`; recorded as a user decision item |
| Third-party growth of a bonder's position array | Accepted (griefing of `claimAll`/lens only; per-id `claim` unaffected; ~5M gas per grief) |
| Unpriceable registered asset + dust reverts NAV | Deploy-order property (`_installFeed` precedes `addConstituent`); left as a runbook check |
| Reference-basis valuation of straddled cells | Bounded to one cell by fix 16's anchor; disclosed through `premium`; accepted |
| Stale high-water mark / valuation-basis bleed inside `_burnback` | Fixed by the mark reset on every ask placement and the fully-crossed rule (fix 4) |
| Bid re-ladder can straddle the reference and fail R1 | Open; observed only in geometry, not in a test; monitor on testnet |
| `spokeHasDepth` hard-coded false | Fixed — derived from the spoke's bid records (`VaultRollout.t.sol::test_aSpokeWithBidDepthGetsTheUndiscountedShare`) |
| Rollout charged/paid on `moved` not `placed` | Fixed — window and bounty on `placed`; remainder idle and reported (`…test_theWindowAndTheBountyAreChargedOnWhatWasPlacedNotOnWhatMoved`) |
| `STAGE_SLOT` literal not its stated hash | Fixed — `Constants.PLACEMENT_STAGE_SLOT`, pinned by `VaultPlacement.t.sol::test_theStagingBufferSlotIsTheHashItClaimsToBe` |
| Keeper gas allowance overpays on a near-zero-basefee chain | Accepted (bounded by the daily ceiling and `chost`); revisit in Phase 4 tuning |
| Bond capacity self-inflates / reset window | Accepted (~0.5 % of the cap) |
| Full collateral settled before the capacity clamp | Accepted; the dApp always passes the quoted amount as `minAmpsOut` (ruling Q) |
| `quote` vs `bond` diverge on weekends | Accepted for now (the view refuses on a stale checkpoint); candidate for a recomputed-NAV quote in v1.5 |
| `removeCollateral` then `reinstateConstituent` reverts | Fixed — `_setMarketOpen` skips a detached market (`PoolRegistry.t.sol::test_reinstate_survivesARemovedCollateral`) |
| `quote` panics on a huge `amountIn` | Fixed — `reason = "amountTooLarge"` (`AmpsBonds.t.sol::test_quoteRefusesAnAmountItCannotNormalise`) |
| Divergence breaker unincentivised / clearable | Accepted; the keeper runbook adds a `pokePool` and `refreshMany` timer; `qFloor` and `_requireConverged` hold independently |
| Layer F implemented twice with different overflow behaviour | Accepted (every caller wraps the gate's version) |
| Entry-class bonds skip the freshness layer | Accepted while both entry markets are closed; must be revisited before opening them (v2) |
| Guardian freeze blocks governance's escape | Accepted (timelock batch) |
| Zero-amount self-transfer probes | Accepted; out-of-scope token behaviour |
| `marketReference` "exactly once more" unenforced | Accepted; NatSpec to be corrected with the next interface change |
| Downward `P_ref` asymmetry loosens the bond floor | Accepted (cost of the hub push under the truncation cap and the fee wall) |
| Registry writes the hook never reads (`poolClass`/`buyFeeBps`) | Accepted; `AmpsHook.setBuyFeeBps` is the live setter; a `setPoolClass` is a candidate for the next hook revision |
| `spokeSeedBps` / registry `place` privilege dead | Accepted; a new constituent receives depth through rollout |
| One `minDelay` for three timelock classes | Accepted; tiers are signing policy (runbooks) |
| One-sided multiplier-step detector | Accepted; the gate's own `oraclePaused`/`effectiveAt` probes cover the downward case |
| Gate probe gas budget | To be measured on 46630 before launch |
| `-amountSpecified` panic, stream step release, `setFeed` delete-before-probe, re-entrant `sync`, batched `extsload` length, groundwork-library gaps | Accepted (unreachable at launch parameters or covered elsewhere) |
