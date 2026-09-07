# Invariant Map

> Amplestocks ($AMPS) | 53 guards | 33 inferred single-contract + 11 cross-contract + 7 economic | 8 not enforced on-chain

Protocol-authored invariant IDs from `docs/phase2-state-model.md` / `docs/phase3-state-model.md` are cited as `doc I3`, `doc I23`, `doc R1`, `ruling U` etc. so they are never confused with the `I-N` blocks below, which are derived from the code alone.

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (msg.sender != vault) revert NotVault(msg.sender);` · `src/token/Amps.sol:34` · The share token's only trust boundary: mint, burn and role hand-over belong to the vault alone (doc I3).

#### G-2
`if tload(REENTRANCY_LOCK) { revert Reentrancy() }` · `src/vault/AmpsVault.sol:289-301` · EIP-1153 lock on every vault entry point including `redeemProRata`; a lock, never a gate, so it cannot be held across transactions.

#### G-3
`if (msg.sender != _TIMELOCK) revert NotTimelock(msg.sender);` · `src/vault/AmpsVault.sol:306` · Governance setters and `genesis` are the timelock's alone.

#### G-4
`if (_initialized) revert GenesisAlreadyDone();` · `src/vault/AmpsVault.sol:904` · Genesis is a one-shot latch: S0 can only ever be minted once.

#### G-5
`if (params.teamShares != Constants.TEAM_SHARES || params.polShares != Constants.POL_SHARES) revert InvalidGenesisAllocation(...)` · `src/vault/AmpsVault.sol:906-908` · The 5 % / 95 % split of the 5,000 AMPS genesis supply is a constant, not a proposal choice.

#### G-6
`if (msg.sender != _bonds) revert NotBonds(msg.sender);` · `src/vault/AmpsVault.sol:851,888` · Only the bonds shell may deposit collateral or mint vesting AMPS: the sole post-genesis issuance path (doc I10).

#### G-7
`if (to != bonds_) revert ZeroAddress();` · `src/vault/AmpsVault.sol:889` · Vesting AMPS can only be minted to the shell itself, so it is in `totalSupply` but never in anyone's wallet until claimed (doc I30).

#### G-8
`if (collateral == _AMPS) revert ZeroAddress();` · `src/vault/AmpsVault.sol:855` · AMPS can never become a NAV asset (doc I5).

#### G-9
`if (msg.sender != _registry) revert NotRegistry(msg.sender);` · `src/vault/AmpsVault.sol:944,1018` · Only the registry opens pools and withdraws a retired spoke's bids, so pool set and vault pool list cannot diverge.

#### G-10
`if (msg.sender != _TIMELOCK && msg.sender != _registry) revert NotTimelock(msg.sender);` · `src/vault/AmpsVault.sol:973` · `place` is governance-driven (genesis ladders, registry seeding); the check sits in the body, not in a modifier.

#### G-11
`if (refuses) revert GateNotHealthy(uint8(gateState), bytes32(0));` · `src/vault/AmpsVault.sol:1433` · Two gate policies: management paths refuse `DEGRADED/DIVERGED/SCHEDULED_FREEZE/WATCHDOG`, bond paths refuse only `DIVERGED/SCHEDULED_FREEZE` (24/7 bonds, Decision 10).

#### G-12
`if (until > block.timestamp) revert GateNotHealthy(uint8(GateState.SCHEDULED_FREEZE), bytes32(0));` · `src/vault/AmpsVault.sol:1439` · The guardian's protocol freeze is honoured by every gated vault path (only reached when `state(0)` did not revert, see X-3).

#### G-13
`if (navAfter < floor) revert NavBleedExceeded(navBefore, navAfter, Constants.PLACEMENT_BLEED_BPS_MAX);` · `src/vault/AmpsVault.sol:1311` · R1: a placement or compound may not lower NAV/share by more than 2 bp, measured at the same reference price (doc I11).

#### G-14
`if (navAfter < floor) revert NavBleedExceeded(navBefore, navAfter, Constants.MIGRATION_BLEED_BPS_MAX);` · `src/vault/AmpsVault.sol:1225` · The relaxed 50 bp bleed bound applies only inside `emergencyMigrate`.

#### G-15
`if (balance != 0) revert SweepDirty(_assets[i], balance);` · `src/vault/AmpsVault.sol:1281`, `src/vault/VaultRedeemLib.sol:299` · sweepClean: no registered asset may rest as an ERC-20 balance on the vault at function exit, so the only denylistable custody address is the PoolManager (doc I12).

#### G-16
`if (msg.sender != _GUARDIAN) revert NotGuardian(msg.sender);` · `src/vault/AmpsVault.sol:1187` · Migration is triggered by the guardian without delay, because the incident it exists for is a denylist.

#### G-17
`if (standby == address(0) || standby != registered) revert NotStandbyVault(standby, registered);` · `src/vault/AmpsVault.sol:1189` · The destination is only ever the standby pre-registered under the 14-day timelock (G-3 via `setStandbyVault`).

#### G-18
`if (!VaultNavLib.migrationPredicate(_registry, address(this))) revert MigrationPredicateNotMet();` · `src/vault/AmpsVault.sol:1190` · Evacuation needs on-chain evidence (`isBlocked(vault)` or two failed 1-wei self-transfer probes), so the guardian cannot move funds on a whim.

#### G-19
`if (msg.sender != _POOL_MANAGER) revert NotPoolManager(msg.sender);` · `src/vault/AmpsVault.sol:1244` · `unlockCallback` is only entered by the PoolManager, and the action is read from transient storage the vault set itself.

#### G-20
`if (msg.sender != previous) revert NotCreator(msg.sender);` · `src/vault/AmpsVault.sol:1172` · Only the current creator can reassign the decaying creator fee.

#### G-21
`if (value < min || value > max) revert OutOfBand(name, value, min, max);` · `src/vault/AmpsVault.sol:1488` · Every governed vault number is checked against its `Constants` band in one place (`_band`), which every setter funnels through.

#### G-22
`if (setOnce && wiringFrozen) revert AlreadyInitialized();` · `src/vault/VaultNavLib.sol:316` · `registry`, `bonds`, `staking`, `bountyPot` pointers are frozen for good by `genesis`.

#### G-23
`if (answerUsd8 == 0) revert IFeedRegistry.FeedNotSet(token);` · `src/vault/VaultNavLib.sol:104` · NAV refuses to value a registered asset without a feed answer rather than silently valuing it at zero (fail-closed for every gated path; redemption never reads it).

#### G-24
`if (last != 0 && block.timestamp < uint256(last) + Constants.PLACEMENT_COOLDOWN_SECONDS) revert PlacementCooldown(...)` · `src/vault/VaultPlacementLib.sol:456`, `src/vault/VaultRolloutLib.sol:344` · 60-second per-pool cooldown bounds how often the placement engine can be driven.

#### G-25
`if (deviation > Constants.PLACEMENT_DIVERGENCE_TICKS) revert PlacementDiverged(...)` · `src/vault/VaultPlacementLib.sol:485-487`, `src/vault/VaultRolloutLib.sol:363-365` · No placement on a tick more than 800 ticks from the reference-implied fair tick (manipulated-tick defence).

#### G-26
`if (live >= Constants.MAX_LIVE_CELLS) { if (strictBudget) revert CellBudgetExceeded(...); continue; }` · `src/vault/VaultPlacementLib.sol:576` · Vault-wide live-cell budget bounds `redeemProRata` gas (ruling E); bountied merge paths skip instead of reverting.

#### G-27
`_requireSide(...)` → `revert WrongSide(poolId, above, bucketTick, boundTick)` · `src/vault/VaultPlacementLib.sol:715-722` · Asks strictly above and bids strictly below the live tick, in v4's own terms (doc I9).

#### G-28
`_requireOnGrid(...)` → `revert OffGrid(...)`; `if (n >= Constants.GRID_CELLS) revert OffGrid(...)` · `src/vault/VaultPlacementLib.sol:692-699,758` · Every record is a cell of the pool's canonical doubling grid, at most 24 per pool (doc I39).

#### G-29
`if (amount > available) revert InsufficientInventory(amount, available);` · `src/vault/VaultPlacementLib.sol:514` · A placement can only commit inventory the vault already holds; nothing is ever minted for a ladder.

#### G-30
`if (amount > budget) revert RolloutLimitExceeded("dailyBudget", ...)` / `if (amount > floorRoom) revert RolloutLimitExceeded("entryFloor", ...)` · `src/vault/VaultRolloutLib.sol:123,125` · The vault re-checks the rollout limits itself instead of trusting the policy's answer (doc I32).

#### G-31
`if (!stored.open || marketIdOf[stored.collateral] != marketId) revert MarketClosed(marketId);` · `src/bonds/AmpsBonds.sol:367` · Bonds only in an open market whose collateral is still the current one.

#### G-32
`if (age > Constants.CHECKPOINT_MAX_AGE) revert StaleCheckpoint(age, Constants.CHECKPOINT_MAX_AGE);` · `src/bonds/AmpsBonds.sol:465` · Bond pricing never uses a NAV older than 30 minutes (in practice same-block, see X-2).

#### G-33
`if (available == 0) revert CapacityExceeded(priced.ampsOut, 0);` / `if (ampsOut < minAmpsOut) revert SlippageExceeded(ampsOut, minAmpsOut);` · `src/bonds/AmpsBonds.sol:393,396` · Per-epoch and daily issuance capacity, and the bonder's own floor on what a capped issue may return (doc I28).

#### G-34
`if (msg.sender != _timelock()) revert NotTimelock(msg.sender);` / `_requireGovernance` accepts `registry` · `src/bonds/AmpsBonds.sol:1160-1171` · Bond parameters are timelock-only; the registry may open/close a market so lifecycle and market state move atomically (doc I37).

#### G-35
`if (msg.sender != vault) revert NotVault(msg.sender);` · `src/bonds/AmpsBonds.sol:723`, `src/staking/AmpsStaking.sol:91`, `src/keeper/BountyPot.sol:133` · Vault-only role rotation, reward notification and bounty payment: the vault is the one address that moves protocol value between satellites.

#### G-36
`if (held < pending) revert RewardNotFunded(pending, held);` · `src/staking/AmpsStaking.sol:225` · A reward stream can only be armed against AMPS already delivered to the staking contract.

#### G-37
`if (workValueUsd18 < chostUsd18) return (0, "chost");` · `src/keeper/BountyPot.sol:346` · Dust guard: no bounty for work worth less than the governed floor (non-revert, the job still completes).

#### G-38
`if (sender != vault) revert NotVault(sender);` · `src/hook/AmpsHook.sol:232,297` · POL-only pools: only the vault may initialise a pool or add liquidity behind the hook.

#### G-39
`if (Currency.unwrap(key.currency0) != amps) revert Currency0NotAmps();` · `src/hook/AmpsHook.sol:233` · AMPS is `currency0` in every pool, which fixes the sign of every fee direction and every one-sided placement.

#### G-40
`if (q.refuse) revert BeyondRail(...)` / `if (devAfter > rail) revert BeyondRail(...)` · `src/hook/AmpsHook.sol:330,411` · The one deliberate swap revert: a deviation-increasing swap that begins or ends beyond the outer rail (doc I15).

#### G-41
`if (msg.sender != timelock) revert NotTimelock(msg.sender);` · `src/hook/AmpsHook.sol:1250` · Every hook setter is the timelock's; the guardian can only freeze through the gate.

#### G-42
`if (value < Constants.AMPS_FEE_BPS_MIN || value > Constants.AMPS_FEE_BPS_MAX) revert OutOfBand("ampsFeeBps", ...)` · `src/hook/AmpsHook.sol:1175` · The sell fee stays inside [100, 600] bp (doc I16).

#### G-43
`if (s.cardinality != 0) revert AlreadyInitialized();` · `src/lib/TruncatedOracleLib.sol:213` · A pool's observation ring is seeded exactly once, at initialisation.

#### G-44
`if (gateState != GateState.GREEN && gateState != GateState.REF_DIVERGED) revert GateRefused(gateState, poolId);` · `src/oracle/OracleGate.sol:427-429` · `checkPlacement`: placements survive `REF_DIVERGED` (anchored at NAV) but nothing worse.

#### G-45
`if (gate.state == GateState.SCHEDULED_FREEZE || gate.state == GateState.DIVERGED) revert GateRefused(...)` · `src/oracle/OracleGate.sol:439-441` · `checkBond`: stale feeds and closed sessions widen the haircut instead of closing a market.

#### G-46
`if (value <= _gapSeconds) revert OutOfBand("graceSeconds", ...)` / `if (value >= _graceSeconds) revert OutOfBand("gapSeconds", ...)` · `src/oracle/OracleGate.sol:660,672` · Watchdog parameters stay ordered so the trip test `produced < elapsed / gap` stays meaningful.

#### G-47
`_requireFreezeWindow(until)` · `src/oracle/OracleGate.sol:624,637` · A guardian freeze is bounded by `GUARDIAN_FREEZE_MAX_SECONDS` (7 d) and expires by itself.

#### G-48
`if (!isStandardProxy[aggregator]) revert NotStandardProxy(aggregator);` · `src/oracle/FeedRegistry.sol:394,437` · SVR secondary proxies are excluded by allowlist since no on-chain flag exists.

#### G-49
`if (_pools[poolId].registered) revert AlreadyInitialized();` · `src/registry/PoolRegistry.sol:731` · One registration per pool id.

#### G-50
`if (count >= Constants.MAX_CONSTITUENTS) revert ConstituentSetFull(...)` · `src/registry/PoolRegistry.sol:257` · At most 64 constituents ever issued.

#### G-51
`if (config.status != ConstituentStatus.ACTIVE) revert InvalidStatusTransition(...)` / `!= RETIRED` · `src/registry/PoolRegistry.sol:330,350,475` · The constituent lifecycle only moves `ACTIVE → RETIRED → ACTIVE`, and retired bids are withdrawn only from a retired name.

#### G-52
`if (weight < floorBps_ || weight > capBps_) revert WeightOutOfRange(...)` / `if (sum != Constants.BPS) revert OutOfBand("indexWeightSum", ...)` · `src/registry/PoolRegistry.sol:455,466` · `setIndexWeights` only accepts a full, banded weight vector (see I-25 for the other write sites).

#### G-53
`if (address(key.hooks) != _hook) revert InvalidPoolKey("hooks");` · `src/registry/PoolRegistry.sol:713` · Every registered pool key names the one hook, so no pool can escape the fee wall or the POL-only rule.

---

## 2. Inferred Invariants (Single-Contract)

Inferred invariants are derived from structural analysis of the source code. Each block below cites one of five extraction methods in its `Derivation` field:

- **Δ-pair (delta-pair) analysis** — two or more storage variables in the same function body that change by equal-and-opposite amounts, implying a conservation law.
- **Guard lift** — a `require` / `if-revert` on a storage variable, promoted from a per-call precondition to a global property by checking that *every* other write site of that variable enforces an equivalent guard. If any write site lacks it, the lifted invariant is On-chain=**No**.
- **State-machine edge** — a storage variable that transitions through discrete values via `require(state == A); state = B`, with no reverse path.
- **Temporal predicate** — a check tied to `block.timestamp`, `block.number`, or a stored duration/deadline.
- **NatSpec-stated global property** — a developer-asserted invariant, then confirmed or contradicted by the structural scan.

Each block is classified by shape: `Conservation` · `Bound` · `Ratio` · `StateMachine` · `Temporal`.

---

#### I-1

`Conservation` · On-chain: **Yes**

> `Amps.totalSupply` changes only through `AmpsVault`: +S0 once at genesis, +`amount` per `mintVesting`, −shares and −inventory per redemption, −burnCut and −boughtBack per compound.

**Derivation** — guard-lift: G-1 (`Amps.sol:34`) + write sites `IAmps.mint` at `AmpsVault.sol:892,914,915`; `IAmps.burn` at `AmpsVault.sol:775,809`, `VaultPlacementLib.sol:340,952`. No other caller of `mint`/`burn` exists in `src/`.

**If violated** — supply could be created outside bonds, breaking the fully-diluted NAV denominator (doc I3, I6, I10).

---

#### I-2

`Bound` · On-chain: **Yes**

> After genesis, the only mint reachable from any selector is `mintVesting`, and it can only mint to the bonds shell.

**Derivation** — guard-lift: G-4 (`AmpsVault.sol:904`) closes the genesis mints at 914-915; G-6 + G-7 (`AmpsVault.sol:888-889`) bound the remaining write site at 892.

**If violated** — inventory could be minted rather than earned, so backing per AMPS could fall below the seed-plus-fees law (doc I10, I30).

---

#### I-3

`StateMachine` · On-chain: **Yes**

> `_initialized` and `_wiringFrozen` are one-shot latches, and once frozen the four custody pointers (`registry`, `bonds`, `staking`, `bountyPot`) never move again.

**Derivation** — edge: `_initialized false@904 → true@933`, `_wiringFrozen → true@934` (`AmpsVault.sol`); guard-lift G-22 (`VaultNavLib.sol:316`) on the only write site of slots 4-7 (`VaultNavLib.sol:319-321`).

**If violated** — governance could re-point the bonds shell or staking to a new contract and mint/receive fees through it.

---

#### I-4

`Ratio` · On-chain: **Yes**

> `navPerShareX18 == (A + 1) * 1e18 / (T + VIRTUAL_SHARES)` with `A` = Σ non-AMPS assets (claims + idle + positions at the previous reference price) and `T == Amps.totalSupply()`; the BountyPot balance is not in `A`.

**Derivation** — Δ-pair / ratio: `_checkpoint` (`AmpsVault.sol:1356-1378`) computes `nav` from `VaultNavLib.totalAssetsUsd18` (`VaultNavLib.sol:80-116`, walks `_assets` only) and `IAmps.totalSupply()`; `_assets` excludes AMPS (G-8, `_registerAsset` 1452-1456) and never contains the pot.

**If violated** — the redemption floor and every bond floor would be mis-priced (doc I5, I6, I21, I22).

---

#### I-5

`Bound` · On-chain: **Yes**

> `pRefX18 >= navPerShareX18` always; `pRefX18` rises by at most `refUpRateBps` per hour and falls to the TWAP or NAV immediately.

**Derivation** — guard-lift on the single write site `_pRefX18 :=` (`AmpsVault.sol:1375`): `VaultNavLib.referencePrice` (`VaultNavLib.sol:206-240`) returns `nav` when `overridden`, caps the upward candidate at 224-229, and floors at NAV at 238.

**If violated** — asks and bond floors could anchor below NAV or chase a pumped hub price (doc I24).

---

#### I-6

`Bound` · On-chain: **Yes**

> Every placement path (`place`, `compound`, `rollout`, `deployBonded`, `withdrawRetiredBids`) leaves `navPerShare >= navBefore * (1 − 2 bp)`, both measured at the same previous reference price; migration is bounded at 50 bp.

**Derivation** — guard-lift G-13 at `_afterPlacement` (`AmpsVault.sol:1308-1313`), called at 979, 990, 1000, 1011, 1022; G-14 at 1225 for `emergencyMigrate`. No other path writes ladder records without passing through one of these.

**If violated** — a placement could convert protocol assets into a NAV loss (doc R1 / I11).

---

#### I-7

`Bound` · On-chain: **Yes**

> Every governed numeric parameter in the vault, hook, bonds, gate, feed registry, staking and pot lies inside its hard band from `Constants`.

**Derivation** — guard-lift G-21 (`AmpsVault.sol:1488`) with all vault write sites routed through `_band` (`AmpsVault.sol:1030-1145`); G-42 and `OutOfBand` at `AmpsHook.sol:1175,1193,1207,1241`; `_checkBand` at `AmpsBonds.sol:651-652,682,690,698,706,1181-1189`; `OutOfBand` at `OracleGate.sol:655-767`, `FeedRegistry.sol:451-485`, `AmpsStaking.sol:245-249`, `BountyPot.sol:279-321`.

**If violated** — a compromised timelock could set a 100 % sell fee, a 0 s vest or a 50 % redeem fee.

---

#### I-8

`Conservation` · On-chain: **Yes**

> `issuedThisEpoch <= capBpsPerEpoch * T / BPS` per market and `_dailyIssued <= dailyCapBps * T / BPS` globally, with `T` the live supply at the time of each bond.

**Derivation** — Δ-pair `AmpsBonds.sol:400-403` (`issuedThisEpoch += issued`, `totalIssued += issued`, `_dailyIssued += issued`) behind `ampsOut <= available` (393-394) where `_capacity` (`AmpsBonds.sol:1013-1035`) derives `available` from both caps; epoch and day roll at 1053-1054 and 1061-1062.

**If violated** — bonds could dilute faster than the 2 % / day design bound (doc I28).

---

#### I-9

`Bound` · On-chain: **Yes**

> `VestingPosition.claimed` is monotone non-decreasing and never exceeds `principal`.

**Derivation** — guard-lift: the only write sites are `record.claimed = uint128(vested)` at `AmpsBonds.sol:504,522`, where `_vested` (1068-1074) is bounded by `principal` and `amount = vested − claimed` is required non-zero.

**If violated** — a bonder could claim more than purchased (doc I28).

---

#### I-10

`Temporal` · On-chain: **Yes**

> Vesting is linear from each position's own stored `start` and `vestSeconds`, frozen at purchase; a later `setVestSeconds` never changes an existing position.

**Derivation** — temporal: `_vested` (`AmpsBonds.sol:1068-1074`) reads `record.start`/`record.vestSeconds` only; `vestSeconds` storage is read once at issue (`_issue`, 423-455).

**If violated** — governance could stretch or shorten open vests (doc I38, ruling Z).

---

#### I-11

`Conservation` · On-chain: **Yes**

> `creatorPaid + stakerPaid + burnCut + relaid == ampsFees` at every compound; `creatorPaid <= ampsFees * creatorBps(t) / ampsFeeBps` with `creatorBps` clamped to `ampsFeeBps` and zero from genesis + 30 days.

**Derivation** — Δ-pair `VaultPlacementLib.sol:931-957` (`_split`): each slice is subtracted from the running remainder and `relaid` is the residue (956); `creatorBps` clamp at 933 and decay in `_creatorBps` (1044-1051).

**If violated** — fee AMPS could leave the protocol to a non-pool address beyond the creator schedule (doc I31).

---

#### I-12

`Bound` · On-chain: **Yes**

> Rollout moves at most `rolloutBpsPerDay` of the POL tranche per rolling 24 h window and never takes the entry pools below `entryFloorBps`.

**Derivation** — guard-lift G-30 (`VaultRolloutLib.sol:123,125`) + Δ `SLOT_ROLLOUT_WINDOW.moved += amount` (`_addRolloutMoved`, 424-428) and the window reset (`_rollWindow`, 409-417). The only writers of the window slot are these two private functions.

**If violated** — inventory could be dumped into a thin spoke in one step (doc I32).

---

#### I-13

`Bound` · On-chain: **Yes**

> The number of live ladder cells across all pools never exceeds `MAX_LIVE_CELLS` (512).

**Derivation** — guard-lift G-26 (`VaultPlacementLib.sol:576`): `place` reverts, bountied merges `continue` without opening a cell; `addLiveCells` (`VaultRedeemLib.sol:138`) is only called from `_writeRecords` (788) with the count of cells actually opened.

**If violated** — `redeemProRata`'s gas could exceed the block budget and the floor would be unreachable (ruling E).

---

#### I-14

`Bound` · On-chain: **Yes**

> Each pool holds at most 24 `PlacementRecord`s, every one at `lowerTick == gridBaseTick + m * D` for a unique `m ∈ [−8, 16)`.

**Derivation** — guard-lift G-28 (`VaultPlacementLib.sol:692-699,758`) on the only push site `_writeRecords` (760-785); merges reuse an existing record instead of pushing.

**If violated** — the valuer's fixed 24-cell enumeration would miss liquidity and understate NAV (doc I39).

---

#### I-15

`StateMachine` · On-chain: **Yes**

> A record's `liquidity` only decreases through the pro-rata unwind, the buyback burn, a rollout harvest or a retired-bid withdrawal, and only increases through `_writeRecords`.

**Derivation** — guard-lift by write-site enumeration: decreases at `VaultRedeemLib.sol:510`, `VaultPlacementLib.sol:878`, `VaultRolloutLib.sol:321,232`; increases at `VaultPlacementLib.sol:760-785`. No other writer of `ladderAt[...].liquidity` exists (the mapping is written only by the placement path).

**If violated** — liquidity could be withdrawn to an address other than the redeemer or the vault's own claims (doc I35).

---

#### I-16

`Conservation` · On-chain: **Yes**

> `LIVE_CELLS_SLOT == Σ records with liquidity != 0` across all pools.

**Derivation** — Δ-pair: `addLiveCells(opened)` at `VaultPlacementLib.sol:788` vs `subLiveCells(closed)` at `VaultPlacementLib.sol:883`, `VaultRedeemLib.sol:541`, `VaultRolloutLib.sol:236,326`; writers of the slot are only `_setLiveCells` (`VaultRedeemLib.sol:153`). Note the decrement saturates at zero (146-151), so the counter can only drift upward if a close is ever missed, never below the true count.

**If violated** — the cell budget (I-13) would refuse legitimate placements or admit too many.

---

#### I-17

`Bound` · On-chain: **Yes**

> The transient rotation credit is zero at every transaction start, never exceeds the AMPS actually received by swappers in this transaction, and a credited sell reduces it by exactly the credited amount.

**Derivation** — Δ-pair on `ROTATION_CREDIT_SLOT`: `_credit` adds `delta.amount0()` from the realised delta (`AmpsHook.sol:427-434`), `_beforeSwap` subtracts `creditConsumed <= min(amountIn, credit)` (332-336); EIP-1153 clears it at transaction end.

**If violated** — a 1-wei buy could unlock a discounted exit (doc I26).

---

#### I-18

`Bound` · On-chain: **Yes**

> Every quoted fee is `base + dyn` with `base ∈ {buyFee, blended, sellFee}`, `sellFee ∈ [100, 600]`, `dyn <= dynCap`, and the total in `[F_MIN_BPS, TOTAL_FEE_BPS_MAX]`.

**Derivation** — guard-lift G-42 + `FeePolicy.quoteFee` (`FeePolicy.sol:138-176`): cap at 153, floor at 159-162, ceiling at 163-171, `feePips = total * PIPS_PER_BPS` at 175; the hook applies `OVERRIDE_FEE_FLAG` to that value only (`AmpsHook.sol:307-345`).

**If violated** — a swap could be charged above the design ceiling of 26 % (doc I16).

---

#### I-19

`Bound` · On-chain: **Yes**

> The recorded truncated tick moves by at most `maxTickMovePerBlock` per block, so any TWAP moves by at most `maxTickMovePerBlock × blocksInWindow` regardless of swap sequence.

**Derivation** — temporal + guard: `_truncate` (`TruncatedOracleLib.sol:435-451`) clamps to `[blockAnchorTick ± maxMove]`; `blockAnchorTick` is only rewritten on a new block number (253-254); `maxTickMovePerBlock` banded by `AmpsHook.sol:1206-1213`.

**If violated** — a single-block pump could move `P_mkt` and every fair tick (doc I25).

---

#### I-20

`Bound` · On-chain: **Yes**

> `highWaterTick` is monotone non-decreasing between two `resetHighWater` calls and only the vault can reset it.

**Derivation** — guard-lift: writes at `TruncatedOracleLib.sol:308` (`max(old, truncatedTick)`) and 316 (reset to `lastTruncatedTick`), the latter only via `AmpsHook.resetHighWater` behind `NotVault` (`AmpsHook.sol:1141`).

**If violated** — the buyback burn (doc I33) could skip or double-count crossed cells.

---

#### I-21

`Bound` · On-chain: **Yes**

> `AmpsStaking.totalAssets() == balanceOf(this) − unreleased` where `unreleased` is piecewise-linear non-increasing between notifications, and `_pendingRewards <= balanceOf(this)` at every notification.

**Derivation** — guard-lift G-36 (`AmpsStaking.sol:225`) on the write site 230; `_unreleasedAt` (285-293) is non-increasing in time; `totalAssets` at 130-132.

**If violated** — a same-block stake/unstake around `compound` could capture the whole tranche (doc I36).

---

#### I-22

`Bound` · On-chain: **Yes**

> A bounty never exceeds `min(tip + chip·work, gasCapMultiple·gasCost, dailyCeiling − spent24h, balance)`, and `_spentWindowUsd18` accumulates every payment inside the rolling day.

**Derivation** — guard-lift `_quote` (`BountyPot.sol:342-371`) + Δ `_chargeWindow` (376-386) before the transfer at 238; the pot's only outflows are `pay` (vault-only, G-35) and `sweep` (timelock-only).

**If violated** — keeper griefing could drain the pot faster than the governed ceiling (doc I21).

---

#### I-23

`StateMachine` · On-chain: **Yes**

> A constituent moves `NONE → ACTIVE → RETIRED → ACTIVE …`; `_activeCount` tracks the number of non-retired names; a retired name always has `rolloutWeightBps == 0`.

**Derivation** — edges `NONE → ACTIVE@285`, `ACTIVE@330 → RETIRED@332`, `RETIRED@350 → ACTIVE@357` (`PoolRegistry.sol`); Δ-pairs `_activeCount` +1 at 280/360 and −1 at 336 in the same bodies; `rolloutWeightBps := 0` at 333 and the `RETIRED ⇒ weight == 0` check at 402-404 on the other write site (407).

**If violated** — a retired spoke could keep receiving rollout inventory (doc I37).

---

#### I-24

`Bound` · On-chain: **Yes**

> `_constituentCount <= MAX_CONSTITUENTS` (64) and `marketCount <= MAX_COLLATERALS` (66); ids are never reissued.

**Derivation** — guard-lift G-50 (`PoolRegistry.sol:257`) on the only increment (279); `AmpsBonds.sol:553` on the only increment (574). Neither counter has a decrement.

**If violated** — the fixed-size grids and lenses that assume `[1, 64]` would overrun.

---

#### I-25

`Bound` · On-chain: **No**

> The active index weight vector sums to `BPS` and every weight lies within `[floor_n, cap_n]` for the live `n`.

**Derivation** — guard-lift attempt: G-52 enforces both properties only inside `setIndexWeights` (`PoolRegistry.sol:445-470`). The other write sites of `targetWeightBps` — `addConstituent` (283-297, bounded individually but not re-summed), `reconfigureConstituent` (397), and the implicit change of `n` in `retireConstituent`/`reinstateConstituent` (332, 357) — carry no sum check, so the vector is only normalised between lifecycle actions and a re-normalising proposal.

**If violated** — `RolloutPolicy`'s deficit term and `BondPolicy`'s `k_w·deficit` read a vector whose sum is not 10,000 until governance re-normalises; rollout and discounts are then computed against stale targets.

---

#### I-26

`Temporal` · On-chain: **Yes**

> Every guardian freeze ends by itself no later than `GUARDIAN_FREEZE_MAX_SECONDS` after it was set, and the timelock can lift it earlier.

**Derivation** — temporal: `_requireFreezeWindow(until)` at `OracleGate.sol:624,637` on both write sites; readers compare `freezeUntil > block.timestamp` (`AmpsVault.sol:1438`, `PoolRegistry.sol:884-886`); `unfreeze*` are `onlyGuardianOrTimelock` (630, 643).

**If violated** — a disable-only role could become a permanent pause on placements and bonds.

---

#### I-27

`Temporal` · On-chain: **Yes**

> The layer-A watchdog trips only when more than `graceSeconds` have elapsed since the last stamp *and* fewer blocks than `elapsed / gapSeconds` were produced; any `poke` restamps it.

**Derivation** — temporal `OracleGate.sol:817-830` over `_lastBlock`/`_lastTimestamp`, written only by `_stamp` (798-808); parameter ordering by G-46.

**If violated** — placements and bonds would refuse during ordinary quiet periods, or fail to refuse during a sequencer outage.

---

#### I-28

`Temporal` · On-chain: **Yes**

> A Chainlink answer that jumps more than `ANSWER_JUMP_BPS` (10 %) within one heartbeat is held in `_pending` and not adopted until a later round agrees or `confirmSeconds` pass.

**Derivation** — temporal `FeedRegistry.sol:326-352` (`refresh`): the adopt path `_latch` (624-628) is reachable only when `!_isJump || _jumpConfirmed`; `_accepted` is otherwise written only by `setFeed` (415-422).

**If violated** — a single bad round would immediately reprice every bond floor and fair tick.

---

#### I-29

`Bound` · On-chain: **No**

> `marketReference` is set once before genesis and re-pointed exactly once more afterwards, to `AmpsHook`.

**Derivation** — NatSpec: `AmpsVault.sol:1149-1151` — *"`marketReference` is set-once before genesis and may be re-pointed afterwards exactly once more, to `AmpsHook`, under the 7-day timelock."* Structural scan: `VaultNavLib.setPointer` (`VaultNavLib.sol:290-322`) marks only slots 4-7 as `setOnce`; slot 8 (`marketReference`) is freely re-pointable at 303 with no counter or latch.

**If violated** — the source of `P_mkt` and every fee/rail fair tick can be swapped by any successful 7-day proposal, not just once; the documented "exactly once more" guarantee is not what the code enforces.

---

#### I-30

`Ratio` · On-chain: **Yes**

> One `redeemProRata(shares)` burns `shares`, removes `floor(L × shares / T)` from every record, pays `floor(b × shares / T) × (1 − redeemFeeBps / BPS)` of every non-AMPS asset, and burns `floor(inventory × shares / T) + releasedAmps` of the vault's own AMPS.

**Derivation** — ratio: `VaultRedeemLib.redemption` (`VaultRedeemLib.sol:356-406`, `inventoryBurned` at 389) and `_payout` (408-450); `unwind` removes `mulDiv(L, shares, supply)` per record (455-560); `supply` read once before the burn at `AmpsVault.sol:772`.

**If violated** — a redeemer could receive more or less than their pro-rata slice (doc I23).

---

#### I-31

`Ratio` · On-chain: **No**

> Redeeming `s` shares in one call pays the same as redeeming them across several calls (path independence of the floor).

**Derivation** — ratio, contradicted structurally: I-30's `inventoryBurned` lowers `T` by more than `shares` per call, so the next call's `shares / T` is larger; `docs/phase3-state-model.md` ruling U records the measured gap (+2.9 % over 60 slices vs one call on 300 AMPS) and marks the decision **open**.

**If violated** — as observed: the redemption floor is higher for a holder who slices than for one who exits at once, which transfers value between redeemers depending on ordering.

---

#### I-32

`Bound` · On-chain: **Yes**

> `AmpsHook` never holds ERC-20 or ERC-6909 balances, never calls `settle/take/mint/burn/donate/swap`, and has no `BEFORE_REMOVE_LIQUIDITY` or returns-delta permission bit.

**Derivation** — NatSpec: `AmpsHook.sol:38-39` — *"holds no ERC-20/ERC-6909, mirrors no PoolManager balance, never calls settle/take/mint/burn/donate/swap"*; structural scan: no such call site exists in `src/hook/`, `getHookPermissions` (206) returns exactly `0x38C0`, `beforeSwap` returns `ZERO_DELTA` (345) and `afterSwap` returns `0` (415).

**If violated** — the hook would become a custody contract with the incident history of VTSwapHook/Bunni (doc I13, I18).

---

#### I-33

`Bound` · On-chain: **Yes**

> At the exit of every external vault function, the vault's ERC-20 balance of every registered asset is zero (all custody is PoolManager claims).

**Derivation** — guard-lift G-15: `_sweepClean()` is called at the exit of every state-changing vault path (`AmpsVault.sol:820,828,837,880,894,940,...` via `_afterPlacement` 1312) and asserts zero at 1281; `VaultRedeemLib.sweepClean` (264-301) absorbs any idle balance first.

**If violated** — a denylisting issuer could freeze funds on the vault address rather than only on the PoolManager (doc I12).

---

**Categories:**
- **Conservation**: Two or more storage variables change by equal-and-opposite amounts in the same function body.
- **Bound**: A guard on a storage variable, lifted to a global property and enforced across every write site of that variable. On-chain=**No** if any write site lacks the equivalent guard.
- **Ratio**: A storage variable is defined as a formula of other storage variables.
- **StateMachine**: A storage variable transitions through discrete values with guards preventing reversal.
- **Temporal**: A condition depends on `block.timestamp`, `block.number`, or a duration/deadline variable.

---

## 3. Inferred Invariants (Cross-Contract)

Trust assumptions that span contract boundaries. Each block cites both caller-side and callee-side code.

---

#### X-1

On-chain: **Yes**

> `AmpsBonds` assumes `vault.depositBonded` settles exactly `amountIn` of collateral into the vault's claims.

**Caller side** — `src/bonds/AmpsBonds.sol:382-386` — `settled != amountIn` reverts `DepositMismatch`.

**Callee side** — `src/vault/VaultRedeemLib.sol:241-256` (`settleFrom`) — `sync → transferFrom(from, pm) → settle → mint`, returning what the PoolManager actually credited; a fee-on-transfer or rebasing collateral therefore reverts the bond instead of mis-accounting it.

**If violated** — a bond could be priced on more collateral than the vault received.

---

#### X-2

On-chain: **Yes**

> Bond pricing reads a NAV checkpoint taken in the same block as the deposit.

**Caller side** — `src/bonds/AmpsBonds.sol:457-466` (`_price`) — `checkpointData()` with G-32 staleness bound, called *after* `depositBonded`.

**Callee side** — `src/vault/AmpsVault.sol:861-869` (`depositBonded`) — `_registerAsset(collateral); _checkpoint();` before settling, so the checkpoint already includes the bonded collateral at the previous reference price.

**If violated** — the stale-checkpoint dilution found in Phase 2 (a bond priced on a NAV that predates the deposit) would return (doc I27).

---

#### X-3

On-chain: **No**

> The vault honours a guardian protocol freeze whenever one is set.

**Caller side** — `src/vault/AmpsVault.sol:1424-1441` (`_requireGate`) — `try IOracleGate(gate).state(0) … catch { return; }`; the `protocolFreezeUntil` read at 1437 is reached only when `state(0)` succeeded, and a zero gate pointer returns immediately (1426).

**Callee side** — `src/oracle/OracleGate.sol:636-641` (`freezeProtocol`) writes `_protocolFreezeUntil`; `state()` is a bounded-read view that can still revert on a replaced or broken pointer.

**If violated** — by design (fail-open, doc §7.1): a gate that reverts, or a gate pointer re-pointed to a non-gate, lets placements, compounds and bonds proceed through a guardian freeze; worth confirming this trade-off is intended for the protocol freeze as well as for gate state.

---

#### X-4

On-chain: **Yes**

> `PoolRegistry` assumes `vault.initializePool` opens exactly the key it registered and returns that id; the registry then mirrors the hook's `gridBaseTick`.

**Caller side** — `src/registry/PoolRegistry.sol:770-791` (`_openPool`) — `opened != poolId` reverts; `gridBaseTick` mirrored via `try IAmpsHook(_hook).gridBaseTick(poolId)`.

**Callee side** — `src/vault/AmpsVault.sol:942-970` — `poolManager.initialize(key, alignedOpeningPrice(...))`, returns `key.toId()`; `src/hook/AmpsHook.sol:247-287` (`_afterInitialize`) writes `_cfg[id]` (260) before returning, so the mirror read sees the final grid origin.

**If violated** — registry and vault would disagree on a pool's grid, and every `OffGrid` check (G-28) would fire or pass on the wrong origin.

---

#### X-5

On-chain: **Yes**

> The hook assumes a pool being initialised is already registered with the same counter and tick spacing.

**Caller side** — `src/hook/AmpsHook.sol:237-240` (`_beforeInitialize`) — `poolConfig(id).registered`, `counter`, `tickSpacing` must match the key.

**Callee side** — `src/registry/PoolRegistry.sol:722-750` (`_registerPool`) writes `_pools[poolId]` at 732-744 before `_openPool` is called at 311 / 234, so the hook's read sees the record.

**If violated** — a pool could open behind the hook without a registry entry, escaping the fee class and band tables.

---

#### X-6

On-chain: **No**

> The hook's `beforeSwap` rail and band decisions use the gate's *current* fair tick and session.

**Caller side** — `src/hook/AmpsHook.sol:307-330` — `_beforeSwap` reads `_dyn[id]` (`fairTick`, `innerBandTicks`, `outerRailTicks`, `dynCapBps`, `gateFlags`) and refuses on `q.refuse` (G-40) without touching the gate.

**Callee side** — `src/hook/AmpsHook.sol:637-650` (`_refreshGate`) — the only writer of those fields, run from `_afterSwap` at most once per `gateCacheSeconds` (390-393, default 60 s, `GATE_CACHE_MAX_AGE` 900 s) and forced by `armSurge` (1163); `src/oracle/OracleGate.sol:936-950` (`_resolveState`) recomputes the verdict every call.

**If violated** — bounded staleness only: between refreshes the rail is measured against a fair tick up to 15 minutes old, and the first swap after a Chainlink move is judged against the pre-move fair tick; worth tracing how a session change or an `effectiveAt` flip interacts with a quiet pool whose cache has aged past `GATE_CACHE_MAX_AGE` (the "conservative substitute" path).

---

#### X-7

On-chain: **Yes**

> The valuer decomposes positions at the vault's *previous* checkpointed reference price, never at `slot0`, and the vault reads the valuer before it writes the new reference.

**Caller side** — `src/vault/AmpsVault.sol:1356-1378` (`_checkpoint`) — `totalAssetsUsd18` at 1358 (positions valued through `VaultNavLib._referenceSqrtPrice`, `VaultNavLib.sol:446-458`, from `_pRefX18`) precedes the write of `_pRefX18` at 1375.

**Callee side** — `src/valuer/LadderPositionValuer.sol:102-127,145-195` — `valuePool(poolId, sqrtPriceX96)` uses the passed reference price and reads liquidity via one batched `extsload` of the 24 canonical cells; unregistered pool or zero price returns `(0, 0)`.

**If violated** — forcing `slot0` ±50 % would move `A`, and a positionValuer that reads `slot0` would make NAV manipulable within one block (doc I7).

---

#### X-8

On-chain: **Yes**

> `BountyPot.pay` trusts the vault's measured `workValueUsd18` and `gasStart`, and pays only within its own caps.

**Caller side** — `src/vault/VaultPlacementLib.sol:1102-1122` (`payBounty`) — `try IBountyPot.pay(msg.sender, workValueUsd18, gasCostUsd18)`; work value from `_counterValueUsd18`/`ampsValueUsd18` at feed prices, gas from `_gasUsed` (1124-1132, EIP-150 corrected, capped at `KEEPER_GAS_MAX`).

**Callee side** — `src/keeper/BountyPot.sol:224-242` — `onlyVault`, `_quote` caps (I-22), `_chargeWindow` before transfer.

**If violated** — a keeper could inflate its bounty by inflating the reported work; the caps bound the damage to the daily ceiling.

---

#### X-9

On-chain: **Yes**

> `AmpsStaking.notifyReward` is only called after the AMPS it announces has been transferred.

**Caller side** — `src/vault/VaultPlacementLib.sol:943-947` — `safeTransfer(staking, stakerPaid)` then `notifyReward(stakerPaid)`.

**Callee side** — `src/staking/AmpsStaking.sol:218-236` — G-36 (`held < pending` reverts) re-checks it.

**If violated** — the stream would promise AMPS the contract does not hold (doc I36).

---

#### X-10

On-chain: **Yes**

> A constituent's bond market opens and closes in the same transaction as its lifecycle action.

**Caller side** — `src/registry/PoolRegistry.sol:314-324,344,366` — `addCollateral(...)` inside `addConstituent`, `setMarketOpen(false/true)` inside `retire/reinstate`.

**Callee side** — `src/bonds/AmpsBonds.sol:1168-1171` (`_requireGovernance`) — accepts `msg.sender == registry` for exactly `addCollateral` and `setMarketOpen`; every other bond setter is timelock-only.

**If violated** — a retired name could keep an open market, or a new name could trade before its market exists (doc I37).

---

#### X-11

On-chain: **No**

> The four linked vault libraries address the vault's storage by the same slot numbers the vault declares.

**Caller side** — `src/vault/VaultPlacementLib.sol` `SLOT_*` constants and `_word`/`_setWord` (1262-1275); `src/vault/VaultRolloutLib.sol` `_word`/`_setWord` (465-476); `src/vault/VaultNavLib.sol:319-321` (`sstore(slot, newPointer)` with slots 4-13 chosen by name).

**Callee side** — `src/vault/AmpsVault.sol:200-260` (the documented slot layout, slots 0-20) — there is no on-chain check that a library constant matches a vault declaration; the correspondence is pinned by the storage-layout tests described in the NatSpec.

**If violated** — a future vault or library revision that shifts one slot would silently read fees, pointers or the rollout window from the wrong word; migration to a standby vault with a different layout is the realistic path.

---

## 4. Economic Invariants

Higher-order properties derived from combinations of §2 and §3 invariants. Every block traces back to concrete invariant IDs.

---

#### E-1

On-chain: **Yes**

> Every bond is accretive: `ampsOut × navPerShare × (1 + minAccretionBps) <= stockIn × P_i × (1 − h_session)`, so NAV/share after a bond is at least NAV/share before.

**Follows from** — `I-4` + `I-8` + `X-1` + `X-2`, with the floor `q <= qFloor` computed in `BondPolicy.qFloorX18` (`src/policy/BondPolicy.sol:121-132`) and re-derived by the shell (`src/bonds/AmpsBonds.sol:476-480`).

**If violated** — bonds would dilute holders (doc I27).

---

#### E-2

On-chain: **No**

> Cumulative NAV bleed from placements stays small over the protocol's life.

**Follows from** — `I-6` (≤ 2 bp per placement) + `G-24` (60 s per pool), which bound the *rate* (32 pools × 1,440 placements/day × 2 bp) but not the sum; the plan's "< 10 bp cumulative" is a Phase 6 exit KPI measured off-chain.

**If violated** — a keeper that can trigger compounds against tiny fee balances could grind NAV by up to the rate bound per day; worth checking what the bounty economics (`G-37`, `I-22`) leave as the cheapest legal grind.

---

#### E-3

On-chain: **No**

> The redemption floor is the same for every holder regardless of how their redemption is sliced or ordered.

**Follows from** — `I-30` + `I-31` + `I-4`: the inventory burn per call lifts NAV/share for the next call, so ordering and slicing move value between redeemers (ruling U, open).

**If violated** — as recorded in the state model: a sliced exit extracts up to ~2.9 % more than a one-shot exit at the launch shape.

---

#### E-4

On-chain: **Yes**

> Sell-fee AMPS never leaves the protocol except through the creator slice and the staker stream; the rest is burned or returned as asks, so each sell lowers supply or raises backing.

**Follows from** — `I-1` + `I-11` + `I-15` + `I-21`.

**If violated** — the volume-to-price flywheel the design relies on would leak (doc I31, I33).

---

#### E-5

On-chain: **Yes**

> Placement anchors and bond floors cannot be pumped faster than `refUpRateBps` per hour and never fall below NAV, while per-block TWAP movement is capped.

**Follows from** — `I-5` + `I-19` + `X-7`.

**If violated** — a hub pump would immediately re-anchor asks above the pump and re-price bonds at the pumped level (doc I24, I25); note that `P_mkt` used for fees and rails (`X-6`) is only bounded by `I-19`, not by the rate limit.

---

#### E-6

On-chain: **Yes**

> Keeper payouts are bounded per job, per day and by the pot balance, and a depleted pot degrades jobs to unpaid rather than blocking them.

**Follows from** — `I-22` + `X-8` + `G-37`.

**If violated** — placements would depend on pot funding, or the pot could be drained by spam (doc I21).

---

#### E-7

On-chain: **Yes**

> `redeemProRata` succeeds with every feed dead, the watchdog tripped, the guardian frozen and the timelock hostile: it references no gate, feed, registry or guardian state.

**Follows from** — `I-30` + `I-33` + `G-2` (the only guard on the path) and the absence of any gate/pointer read in `AmpsVault.sol:763-820` and `VaultRedeemLib.sol` (which imports no oracle/registry interface). The bytecode-level proof is off-chain (`scripts/selector-gate.py`, `GuardSymmetry.t.sol`), but the structural property holds in the source as written.

**If violated** — the floor the whole premium narrative rests on would be pausable (doc I14, I23).
