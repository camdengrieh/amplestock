# Invariant Map

> Amplestocks ($AMPS) | 45 guards | 37 inferred | 14 not enforced on-chain

Scope: `contracts/src/**` at `ccffe6c` (`claude/amplestocks-rwa-token-xhtnn5`). Interfaces and mocks excluded.

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (!_initialized) revert NotInitialized();` · `AmpsVault.sol:840` · Closes the window between `genesisMint` (supply exists) and `genesisPlace` (`A` still zero) on the one path that would otherwise burn shares against nothing.

#### G-2
`if tload(lockSlot) { ... revert Reentrancy() }` · `AmpsVault.sol:358` · The EIP-1153 lock every vault entry point takes, including the ungated redemption; it is a lock nobody else can hold, not a gate.

#### G-3
`if (msg.sender != _TIMELOCK) revert NotTimelock(msg.sender);` · `AmpsVault.sol:372` · The single governance root for every vault parameter; the address is immutable, so a compromised timelock cannot be replaced from inside the vault.

#### G-4
`if (msg.sender != _bonds) revert NotBonds(msg.sender);` · `AmpsVault.sol:939` · Confines the collateral-settlement path to the one shell allowed to mint against a deposit.

#### G-5
`if (collateral == _AMPS) revert ZeroAddress();` · `AmpsVault.sol:943` · Keeps the share out of its own backing; AMPS legs are valued at zero in `A`, so bonding AMPS would issue against nothing.

#### G-6
`if (to != bonds_) revert ZeroAddress();` · `AmpsVault.sol:978` · Forces every vesting mint into the bonds shell's own custody so `totalSupply` and the position array cannot diverge.

#### G-7
`if (_genesisMinted) revert GenesisAlreadyDone();` · `AmpsVault.sol:998` · One-shot latch on the `S0` allocation; without it the tranches could be re-minted.

#### G-8
`if (msg.sender != _genesis && msg.sender != _TIMELOCK) revert NotTimelock(msg.sender);` · `AmpsVault.sol:1023` · Restricts the launch to the registered auction adapter or the timelock's founders'-seed fallback.

#### G-9
`if (_initialized) revert GenesisAlreadyDone();` · `AmpsVault.sol:1025` · One-shot latch on the protocol opening; it is also what freezes the set-once wiring.

#### G-10
`if (msg.sender != _registry) revert NotRegistry(msg.sender);` · `AmpsVault.sol:1057` · Only the registry may open a pool, which is what keeps the pool set and the vault's own `PoolKey[]` in step.

#### G-11
`if (msg.sender != _TIMELOCK && msg.sender != _registry) revert NotTimelock(msg.sender);` · `AmpsVault.sol:1086` · Hand-directed placement is governance's; the registry's leg exists so a new spoke's seed ask is atomic with its registration.

#### G-12
`if (newPointer.code.length == 0) revert ZeroAddress();` · `AmpsVault.sol:1271` · A codeless pointer answers a `staticcall` with success and no data; refusing one is what stops a typo from silently disabling a dependency.

#### G-13
`if (slot == bytes32("genesis") && _genesisMinted) revert AlreadyInitialized();` · `AmpsVault.sol:1278` · Latches the auction adapter at the mint rather than at the placement, closing the bidding-window re-point.

#### G-14
`if (standby.code.length == 0) revert ZeroAddress();` · `AmpsVault.sol:1291` · The standby receives five `onlyVault` roles with no way back; an EOA there is unrecoverable.

#### G-15
`if (msg.sender != previous) revert NotCreator(msg.sender);` · `AmpsVault.sol:1300` · The creator fee recipient is self-sovereign; governance cannot redirect it.

#### G-16
`if (msg.sender != _GUARDIAN) revert NotGuardian(msg.sender);` · `AmpsVault.sol:1320` · The evacuation trigger; the guardian's only vault power and the only ungated privileged call.

#### G-17
`if (standby == address(0) || standby != registered) revert NotStandbyVault(standby, registered);` · `AmpsVault.sol:1322` · Binds the evacuation to the address governance pre-registered under the 14-day tier, so an urgent call cannot invent a destination.

#### G-18
`if (!VaultNavLib.migrationPredicate(_registry, address(this))) revert MigrationPredicateNotMet();` · `AmpsVault.sol:1323` · The on-chain denylist evidence standard that replaces a timelock on the migration path.

#### G-19
`if (msg.sender != _POOL_MANAGER) revert NotPoolManager(msg.sender);` · `AmpsVault.sol:1402` · Together with the transient discriminator, makes an unsolicited callback into the vault's action dispatcher impossible.

#### G-20
`if (navAfter < floor) revert NavBleedExceeded(navBefore, navAfter, Constants.PLACEMENT_BLEED_BPS_MAX);` · `AmpsVault.sol:1459` · The R1 post-condition: a placement may cost holders at most 2 bp of NAV/share, measured on the same basis before and after.

#### G-21
`if (navAfter < floor) revert NavBleedExceeded(navBefore, navAfter, Constants.MIGRATION_BLEED_BPS_MAX);` · `AmpsVault.sol:1384` · The relaxed 50 bp bound on the evacuation, applied only when both sides can be priced.

#### G-22
`if (frozenKnown && uint32(frozenUntil) > block.timestamp) revert GateNotHealthy(uint8(GateState.SCHEDULED_FREEZE), bytes32(0));` · `AmpsVault.sol:1636` · The guardian's protocol freeze, read first so it cannot be starved by a gas-limited call that only exhausts the expensive `state()` read.

#### G-23
`if (refuses) revert GateNotHealthy(uint8(gateState), bytes32(0));` · `AmpsVault.sol:1649` · Applies whichever of the three refusal sets the calling selector belongs to; a gate that cannot be read refuses nothing.

#### G-24
`if (value < min || value > max) revert OutOfBand(name, value, min, max);` · `AmpsVault.sol:1702` · The single band site every governed vault scalar funnels through, with the bound read from `Constants` rather than restated.

#### G-25
`if (last != 0 && block.timestamp < uint256(last) + Constants.PLACEMENT_COOLDOWN_SECONDS) revert PlacementCooldown(PoolId.unwrap(poolId), last + Constants.PLACEMENT_COOLDOWN_SECONDS);` · `VaultPlacementLib.sol:544` · The 60-second per-pool rate limit shared by every placement path.

#### G-26
`if (deviation > Constants.PLACEMENT_DIVERGENCE_TICKS) revert PlacementDiverged(PoolId.unwrap(poolId), tick, fair, Constants.PLACEMENT_DIVERGENCE_TICKS);` · `VaultPlacementLib.sol:574` · Checked at entry and exit so a placement cannot be sandwiched into a manipulated tick.

#### G-27
`if (amount > available) revert InsufficientInventory(amount, available);` · `VaultPlacementLib.sol:620` · Bounds a ladder by what the vault actually holds as claims plus readable idle balance.

#### G-28
`revert CellBudgetExceeded(PoolId.unwrap(p.key.toId()), live, Constants.MAX_LIVE_CELLS);` · `VaultPlacementLib.sol:706` · The 512-cell ceiling that bounds the gas of the one path that must never be gated; strict only on the governance leg.

#### G-29
`revert OffGrid(PoolId.unwrap(p.key.toId()), lower, p.gridBaseTick, width);` · `VaultPlacementLib.sol:855` · Every bucket must be exactly one cell of the pool's canonical doubling grid, which is what the position valuer enumerates.

#### G-30
`if (sqrtPriceX96 > TickMath.getSqrtPriceAtTick(lower)) revert WrongSide(PoolId.unwrap(p.key.toId()), true, lower, p.currentTick);` · `VaultPlacementLib.sol:873` · Sidedness in v4's own terms: an ask holds only AMPS, a bid only the counter, so no cell is straddled at placement.

#### G-31
`if (!_resetHighWater(ctx, pool.key.toId())) revert HighWaterResetFailed(PoolId.unwrap(pool.key.toId()));` · `VaultPlacementLib.sol:655` · Hard on the ask side: an ask laid under a stale mark would be burned as inventory it was never sold as.

#### G-32
`if (amount > budget) revert RolloutLimitExceeded(bytes32("dailyBudget"), amount, budget);` · `VaultRolloutLib.sol:135` · The vault re-checks the schedule's proposal rather than trusting the pointer-upgradeable policy.

#### G-33
`if (amount > floorRoom) revert RolloutLimitExceeded(bytes32("entryFloor"), amount, floorRoom);` · `VaultRolloutLib.sol:137` · Keeps entry-pool depth above the governed floor so rollout cannot empty the way in and out of the index.

#### G-34
`if (!stored.open || marketIdOf[stored.collateral] != marketId) revert MarketClosed(marketId);` · `AmpsBonds.sol:371` · Both halves are needed: a removed collateral leaves its record readable, so `open` alone would keep a detached market quoting.

#### G-35
`if (settled != amountIn) revert DepositMismatch(settled, amountIn);` · `AmpsBonds.sol:388` · The quote is priced on `amountIn`, so fee-on-transfer collateral is rejected rather than mispriced.

#### G-36
`if (age > Constants.CHECKPOINT_MAX_AGE) revert StaleCheckpoint(age, Constants.CHECKPOINT_MAX_AGE);` · `AmpsBonds.sol:524` · Bonds may only price against a NAV the vault refreshed inside 30 minutes.

#### G-37
`if (_navUnconfirmed(vaultAddress)) revert UnconfirmedNav();` · `AmpsBonds.sol:526` · A NAV built from a held-back or stale feed answer understates the floor's denominator, so no collateral may be bonded against it.

#### G-38
`if (output.qX18 > floorX18) revert AccretionFloorViolated(output.qX18, floorX18);` · `AmpsBonds.sol:542` · The shell recomputes the accretion floor independently, so a hostile policy pointer can refuse to price but never issue dilutively.

#### G-39
`if (ampsOut < minAmpsOut) revert SlippageExceeded(ampsOut, minAmpsOut);` · `AmpsBonds.sol:401` · The bonder's protection against handing over a whole deposit for a capacity-clamped issue.

#### G-40
`if (msg.sender != vault) revert NotVault(msg.sender);` · `Amps.sol:34` · The whole of the share token's trust model: `totalSupply` moves only where the vault moves it.

#### G-41
`if (sum != Constants.BPS) revert OutOfBand("indexWeightSum", sum, Constants.BPS, Constants.BPS);` · `PoolRegistry.sol:479` · The only site that checks the index weight vector sums to 100%; per-name band checks elsewhere do not.

#### G-42
`if (weight < floorBps_ || weight > capBps_) revert WeightOutOfRange(weight, floorBps_, capBps_);` · `PoolRegistry.sol:468` · The per-name cap and floor, recomputed from the live active count so the band tracks index size.

#### G-43
`if (until < floorTs || until > ceilTs) revert OutOfBand("freezeUntil", until, floorTs, ceilTs);` · `OracleGate.sol:994` · Guardian freezes must end, and within 7 days, which is what makes a delay-free guardian power acceptable.

#### G-44
`if (!isStandardProxy[aggregator]) revert NotStandardProxy(aggregator);` · `FeedRegistry.sol:427` · Confines every feed to the governance-recorded Chainlink Standard proxy; there is no override.

#### G-45
`if (q.refuse) revert BeyondRail(PoolId.unwrap(id), q.devTicks, q.railTicks);` · `AmpsHook.sol:449` · The one deliberate swap refusal in the protocol: deviation-increasing and beyond the outer rail, checked again on the post-swap tick at `AmpsHook.sol:599`.

---

## 2. Inferred Invariants (Single-Contract)

Inferred invariants are derived from structural analysis of the source code. Each block below cites one of five extraction methods in its `Derivation` field:

- **Δ-pair (delta-pair) analysis** — two or more storage variables in the same function body that change by equal-and-opposite amounts, implying a conservation law.
- **Guard lift** — a `require` / `if-revert` on a storage variable, promoted to a global property by checking that *every* other write site of that variable enforces an equivalent guard.
- **State-machine edge** — a storage variable that transitions through discrete values with no reverse path.
- **Temporal predicate** — a check tied to `block.timestamp`, `block.number`, or a stored duration/deadline variable.
- **NatSpec-stated global property** — a developer-asserted invariant, routed here and then confirmed or contradicted by the structural scan.

Each block is classified into one of five **categories** by shape: `Conservation` · `Bound` · `Ratio` · `StateMachine` · `Temporal`. Category definitions at the end of §2.

---

#### I-1

`Bound` · On-chain: **Yes**

> `_redeemFeeBps ∈ [0, REDEEM_FEE_BPS_MAX]` (0–500 bp) at every block.

**Derivation** — guard-lift: `if (value < min || value > max) revert OutOfBand(...)` (`AmpsVault.sol:1702`) reached from `setRedeemFeeBps` (`AmpsVault.sol:1145`). Write sites enumerated: `AmpsVault.sol:335` (constructor, `REDEEM_FEE_BPS_DEFAULT = 250`) and `AmpsVault.sol:1145`. Both inside the band.

**If violated** — a redemption fee above the ceiling would let governance confiscate an arbitrary share of every exit.

---

#### I-2

`Bound` · On-chain: **Yes**

> `AmpsHook._ampsFee ∈ [AMPS_FEE_BPS_MIN, AMPS_FEE_BPS_MAX]` (100–600 bp) at every block.

**Derivation** — guard-lift: `if (value < Constants.AMPS_FEE_BPS_MIN || value > Constants.AMPS_FEE_BPS_MAX) revert OutOfBand(...)` (`AmpsHook.sol:1627`). Write sites enumerated: `AmpsHook.sol:289` (constructor, `AMPS_FEE_BPS_DEFAULT = 500`) and `AmpsHook.sol:1631`. Both inside the band.

**If violated** — the protocol-wide swap fee is the base of every quote; an unbounded value would make a swap arbitrarily expensive.

---

#### I-3

`Bound` · On-chain: **No**

> Every `ACTIVE` constituent's `targetWeightBps` sums to exactly `BPS` across the index.

**Derivation** — guard-lift: the sum is checked at `PoolRegistry.sol:479` (`setIndexWeights`) alone. Write sites of `targetWeightBps` enumerated: `PoolRegistry.sol:298` (`addConstituent`, band only, `_requireWeight` at `:275`), `PoolRegistry.sol:410` (`reconfigureConstituent`, band only, `_requireWeight` at `:408`), `PoolRegistry.sol:469` (`setIndexWeights`, band **and** sum). The active set also changes without touching any weight: `retireConstituent` decrements `_activeCount` (`PoolRegistry.sol:347`) and `reinstateConstituent` increments it (`:374`).

**If violated** — the index weight vector no longer normalises, so every `deficit = (target − current) / target` consumer — the bond discount and the rollout schedule — prices against a denominator the set does not add up to.

---

#### I-4

`Bound` · On-chain: **No**

> `VaultRedeemLib.liveCellCount() ≤ Constants.MAX_LIVE_CELLS` (512), and equals the number of ladder cells actually holding liquidity.

**Derivation** — guard-lift: `if (opensCell && live >= Constants.MAX_LIVE_CELLS) { if (strictBudget) revert CellBudgetExceeded(...); continue; }` (`VaultPlacementLib.sol:704-708`). Write sites of the counter enumerated: `addLiveCells` (`VaultRedeemLib.sol:148`, called from `VaultPlacementLib.sol:954`) and `subLiveCells` (`VaultRedeemLib.sol:156`, called from `VaultPlacementLib.sol:1161`, `VaultRolloutLib.sol:315`, `VaultRolloutLib.sol:437`, `VaultRedeemLib.sol:795`). The ceiling binds only when `strictBudget` is true — the permissionless `compound`, `rollout` and `deployBonded` paths reach `place(..., strictBudget = false)` and skip the bucket instead — and `subLiveCells` saturates at zero by design (`VaultRedeemLib.sol:159`).

**If violated** — the counter is what bounds the gas of `redeemProRata`, the one path the design forbids gating, rate-limiting or splitting into instalments.

---

#### I-5

`Conservation` · On-chain: **No**

> `Σ PlacementRecord.amount` over a pool's cells equals the inventory those cells still hold.

**Derivation** — Δ-pair: `record.liquidity += liquidity` ↔ `record.amount = _toUint128(uint256(record.amount) + amount)` (`VaultPlacementLib.sol:944 ↔ VaultPlacementLib.sol:945`). The pairing is maintained on three of four removal paths — `_burnback` zeroes both (`VaultPlacementLib.sol:1154 ↔ :1156`), `withdrawRetiredBids` zeroes both (`VaultRolloutLib.sol:309 ↔ :311`), `_harvestAsks` pro-rates both (`VaultRolloutLib.sol:431 ↔ :432`) — and deliberately broken on the fourth: `unwind` writes `record.liquidity = live - removed` (`VaultRedeemLib.sol:757`) with no matching `record.amount` write, documented at `VaultRedeemLib.sol:758-764` as a gas decision on the ungated floor.

**If violated** — `PlacementRecord.amount` is a disclosure field only; nothing prices from it, but any consumer (indexer, dashboard, future logic) that treats it as the cell's holding will over-count after any redemption.

---

#### I-6

`Conservation` · On-chain: **Yes**

> `IERC20(amps).balanceOf(AmpsBonds) ≥ Σ over all positions of (principal − claimed)`.

**Derivation** — Δ-pair: `bond` writes `_positions[to].push(VestingPosition({principal: issued, claimed: 0, ...}))` and mints the same `issued` into this contract (`AmpsBonds.sol:411-419 ↔ AmpsBonds.sol:454`); `claim` writes `record.claimed = uint128(vested)` against a transfer of exactly `vested − claimed` (`AmpsBonds.sol:566 ↔ AmpsBonds.sol:569`), and `claimAll` the same per position (`AmpsBonds.sol:584 ↔ AmpsBonds.sol:590`). Inequality rather than equality because the balance is also reachable by donation.

**If violated** — a vested position could not be claimed, which is the one outcome the structurally ungated `claim` exists to prevent.

---

#### I-7

`Conservation` · On-chain: **No** *(negative conservation)*

> `AmpsVault.redeemProRata` moves value out of the protocol with no storage counter of cumulative redemptions.

**Derivation** — Δ-pair (absence): the body at `AmpsVault.sol:829-888` writes no vault storage at all other than through `VaultRedeemLib.unwind`'s per-record liquidity and the live-cell counter. `IAmps.burn(msg.sender, shares)` (`AmpsVault.sol:848`) and `IAmps.burn(address(this), result.inventoryBurned)` (`:882`) reduce `totalSupply`; nothing on the path records how much left.

**If violated** — not a solvency problem (the burn is the accounting), but it means redemption volume is reconstructible only from `Redeem`/`Burn` logs, so any on-chain consumer of "how much has been redeemed" has no source.

---

#### I-8

`Ratio` · On-chain: **Yes**

> `navPerShareX18 = floor((A + 1) × 1e18 / (totalSupply + VIRTUAL_SHARES))`, with `VIRTUAL_SHARES = 1e3`.

**Derivation** — guard-lift + formula: `AmpsVault.sol:1497-1501`. `supply` is read live inside the same function; `assetsUsd18` is computed by `VaultNavLib.totalAssetsUsd18` immediately before (`AmpsVault.sol:1513`), so both snapshots are same-frame. `supply == 0` short-circuits to zero rather than to `1e18 / VIRTUAL_SHARES` (`AmpsVault.sol:1499`).

**If violated** — every downstream price depends on it: the reference floor, the bond accretion floor's denominator, and the R1 bleed bound.

---

#### I-9

`Ratio` · On-chain: **Yes**

> A redemption pays `net_j = floor(floor(b_j × shares / supply) + released_j) × (BPS − redeemFeeBps) / BPS)` per asset, with `supply` read before the burn.

**Derivation** — Δ-pair + ordering: `uint256 supply = IAmps(_AMPS).totalSupply();` at `AmpsVault.sol:845` precedes `IAmps(_AMPS).burn(msg.sender, shares)` at `:848`, and the same `supply` is threaded into `VaultRedeemLib.redemption` (`AmpsVault.sol:872`) whose arithmetic is `VaultRedeemLib.sol:668`.

**If violated** — reading `supply` after the burn would let a redemption inflate its own pro-rata share.

---

#### I-10

`Ratio` · On-chain: **Yes**

> `qFloorX18 = floor(floor(collateralPriceUsd18 × (BPS − hSessionBps) / BPS) × 1e18 / ceil(navPerShareX18 × (BPS + minAccretionBps) / BPS))`, computed twice independently.

**Derivation** — guard-lift: the shell's copy at `AmpsBonds.sol:994-1004` is compared against the policy's answer at `AmpsBonds.sol:542`; the policy's own copy is `BondPolicy.sol:55-64` (comment-stripped listing `qFloorX18`). Rounding directions are numerator down, denominator up, quotient down in both.

**If violated** — the duplication is the whole reason a pointer-upgradeable pricing policy is safe; if the two copies drift, a policy swap becomes an issuance decision.

---

#### I-11

`Ratio` · On-chain: **Yes**

> `P_ref = max(navPerShareX18, rateLimited(P_mkt))` — a downward move to `P_mkt` is immediate, an upward one is capped at `refUpRateBps` per hour of elapsed time.

**Derivation** — formula: `VaultNavLib.referencePrice` at `VaultNavLib.sol:355-384`, with `elapsed` supplied as `last == 0 ? 0 : block.timestamp - last` from `AmpsVault.sol:1525`. The NAV floor is unconditional at `VaultNavLib.sol:382`.

**If violated** — the reference is the anchor every ask is placed at; a reference below NAV would let the ladder sell inventory below the protocol's own backing.

---

#### I-12

`Bound` · On-chain: **Yes**

> Bond discount `d ∈ [dMinBps, dMaxBps] ⊆ [DISCOUNT_BPS_MIN, DISCOUNT_BPS_MAX]` (500–2500 bp), with `dMinBps ≤ dMaxBps`.

**Derivation** — guard-lift: `_validateDiscountParams` (`AmpsBonds.sol:1394-1399`) including `if (dMinBps > dMaxBps) revert OutOfBand("dMinBps", ...)`. Write sites of the three fields enumerated: `AmpsBonds.sol:646-648` (`addCollateral`, validated at `:617`) and `AmpsBonds.sol:701-703` (`setDiscountParams`, validated at `:694`). The policy clamps to the same pair at `BondPolicy.sol:86-87`.

**If violated** — the discount is what a bond is sold at; an unclamped one is an unbounded transfer from holders to bonders, subject only to the accretion floor.

---

#### I-13

`Bound` · On-chain: **Yes**

> `graceSeconds > gapSeconds`, so the layer-A watchdog's `blocksAdvanced < elapsed / gapSeconds` test cannot trip on an ordinary quiet minute.

**Derivation** — guard-lift: `if (value <= _gapSeconds) revert OutOfBand("graceSeconds", ...)` (`OracleGate.sol:663-665`) and its mirror `if (value >= _graceSeconds) revert OutOfBand("gapSeconds", ...)` (`OracleGate.sol:676`). Write sites enumerated: `OracleGate.sol:251-252` (constructor, 3600 > 120) and the two setters at `:666` and `:678`. Both directions are guarded.

**If violated** — the watchdog is the substitute for a sequencer-uptime feed on a chain that publishes none; a mis-ordered pair would trip it permanently or never.

---

#### I-14

`StateMachine` · On-chain: **Yes**

> `_genesisMinted: false → true`, one-way.

**Derivation** — edge: `false@AmpsVault.sol:998 → true@AmpsVault.sol:999`. Grep confirms `_genesisMinted` is assigned at `AmpsVault.sol:999` and nowhere else; there is no reverse path.

**If violated** — `S0` is minted from a constant tranche split; a second mint would double the supply against unchanged backing.

---

#### I-15

`StateMachine` · On-chain: **Yes**

> `_initialized: false → true`, one-way, and it drags `_wiringFrozen` with it.

**Derivation** — edge: `false@AmpsVault.sol:1025 → true@AmpsVault.sol:1035`, with `_wiringFrozen = true` at `:1036` in the same block. `VaultNavLib.setPointer` refuses a set-once slot afterwards (`VaultNavLib.sol:477`).

**If violated** — the four set-once pointers (`registry`, `bonds`, `bountyPot`, `genesis`) would remain re-pointable after launch.

---

#### I-16

`StateMachine` · On-chain: **Yes**

> `AmpsGenesis._settledLatch: false → true`, one-way, and it doubles as the settlement reentrancy guard.

**Derivation** — edge: `false@AmpsGenesis.sol:235 → true@AmpsGenesis.sol:242`, written before every external interaction in the body.

**If violated** — `settle()` is permissionless and sweeps two auctions; a second entry would re-run the sweeps and the vault handover.

---

#### I-17

`StateMachine` · On-chain: **Yes**

> A pool is registered exactly once: `_pools[poolId].registered: false → true`, and each entry-pool leg (`_hubPoolId`, `_wethPoolId`) is claimed once.

**Derivation** — edge: `if (_pools[poolId].registered) revert AlreadyInitialized();` (`PoolRegistry.sol:783`) followed by the struct write at `:784-796`; and `if (PoolId.unwrap(isHub ? _hubPoolId : _wethPoolId) != bytes32(0)) revert AlreadyInitialized();` (`PoolRegistry.sol:238`) followed by `:240-243`. No writer clears either.

**If violated** — a re-registered pool could carry a second, contradictory `PoolConfig` while the vault's own `PoolKey[]` still holds the first.

---

#### I-18

`Temporal` · On-chain: **Yes**

> A pool accepts at most one placement per `PLACEMENT_COOLDOWN_SECONDS` (60 s), and the stamp is written only when the call moved inventory.

**Derivation** — temporal: `if (last != 0 && block.timestamp < uint256(last) + Constants.PLACEMENT_COOLDOWN_SECONDS) revert PlacementCooldown(...)` (`VaultPlacementLib.sol:544`, mirrored at `VaultRolloutLib.sol:485`). Checked-then-updated: the write is `if (placed != 0 || boughtBackAmps != 0) cooldown[poolId] = uint32(block.timestamp);` (`VaultPlacementLib.sol:288`, and the same condition at `:466` for `compound`), so a no-op call does not deny the pool.

**If violated** — a permissionless caller that could take the cooldown for free would deny `compound`, `place`, `rollout` and `deployBonded` on that pool once a minute.

---

#### I-19

`Temporal` · On-chain: **Yes**

> The rollout allowance decays linearly to zero over `ONE_DAY` from the last charge, and the window start advances on every charge.

**Derivation** — temporal: `_decayedMoved` computes `moved × (ONE_DAY − elapsed) / ONE_DAY` (`VaultRolloutLib.sol:593-602`) and `_addRolloutMoved` re-stamps `block.timestamp` into slot 15 alongside the new total (`VaultRolloutLib.sol:605-614`). The charge is `moved - returned`, taken after the rollback loop (`VaultRolloutLib.sol:186-187`).

**If violated** — a tumbling window has an edge to straddle: the whole allowance a second before it and the whole allowance a second after it.

---

#### I-20

`Temporal` · On-chain: **No**

> `BountyPot` pays at most `dailyCeilingUsd18` per rolling 24 hours.

**Derivation** — temporal: `if (start == 0 || nowTs - start >= Constants.ONE_DAY) { _windowStart = nowTs; _spentWindowUsd18 = ...; } else { _spentWindowUsd18 += ...; }` (`BountyPot.sol:380-385`), read back by `spentLast24h` (`BountyPot.sol:180-184`). This is a resetting window, not a trailing sum, and the contract's own NatSpec states the weaker property it does hold: *"no 24-hour interval can pay out more than two ceilings"* (`BountyPot.sol:44-46`).

**If violated** — the ceiling is the only bound on total keeper spend; the reachable worst case is 2× the governed number inside one rolling day.

---

#### I-21

`Temporal` · On-chain: **Yes**

> `creatorBps(t) = CREATOR_FEE_BPS × max(0, 1 − (t − genesisTimestamp) / CREATOR_DECAY_SECONDS)` — monotone non-increasing, exactly zero from day 30.

**Derivation** — temporal: `AmpsVault.creatorBpsAt` (`AmpsVault.sol:574-583`) and the identical private copy the placement path uses, `VaultPlacementLib._creatorBps` (`VaultPlacementLib.sol:1566-1572`). `_genesisTimestamp` is written once, at `AmpsVault.sol:1034`.

**If violated** — the creator slice is the only transfer of protocol-held AMPS to a non-pool address; an unbounded schedule is an unbounded drain on the fee burn.

---

#### I-22

`Bound` · On-chain: **Yes**

> A guardian freeze expires within `GUARDIAN_FREEZE_MAX_SECONDS` (7 days) of being set, protocol-wide and per constituent.

**Derivation** — guard-lift: `_requireFreezeWindow` (`OracleGate.sol:991-995`). Write sites of `_protocolFreezeUntil` enumerated: `OracleGate.sol:642` (`freezeProtocol`, guarded at `:641`) and `:648` (`unfreezeProtocol`, writes 0). Write sites of `_constituentFreezeUntil` enumerated: `OracleGate.sol:629` (guarded at `:628`) and `:635` (`delete`).

**If violated** — the guardian holds a delay-free power; a freeze that could be set without an expiry would be an indefinite halt of bonds and placements by one key.

---

**Categories:**
- **Conservation**: Two or more storage variables change by equal-and-opposite amounts in the same function body.
- **Bound**: A guard on a storage variable, lifted to a global property and enforced across every write site. On-chain=**No** if any write site lacks the equivalent guard.
- **Ratio**: A storage variable is defined as a formula of other storage variables.
- **StateMachine**: A storage variable transitions through discrete values with guards preventing reversal.
- **Temporal**: A condition depends on `block.timestamp`, `block.number`, or a duration/deadline variable.

---

## 3. Inferred Invariants (Cross-Contract)

Trust assumptions that span contract boundaries. Each block cites both caller-side and callee-side code.

---

#### X-1

On-chain: **No**

> `PoolRegistry` mirrors each pool's canonical grid origin from the hook, and every consumer of the lattice reads the registry's copy.

**Caller side** — `PoolRegistry.sol:829-835` — `_openPool` reads `IAmpsHook(_hook).gridBaseTick(poolId)` inside a `try`/`catch` and writes `_pools[poolId].gridBaseTick` only on success; a failure leaves the field at its `:795` initial value of `0` and emits nothing.

**Callee side** — `AmpsHook.sol:351` — `c.gridBaseTick = PriceLib.alignTick(tick, key.tickSpacing, true)` is the hook's only write of the origin, made during `afterInitialize`. Grep confirms `_pools[poolId].gridBaseTick` has exactly one writer (`PoolRegistry.sol:833`) and is never re-checked or repaired afterwards.

**If violated** — `VaultPlacementLib._requireOnGrid` (`:848`), `_cells` (`:808`) and `LadderPositionValuer._grid` (`LadderPositionValuer.sol:99-106`) all derive cell indices from the registry's copy, so a silent mirror failure puts the placement lattice and the valuation lattice on different origins.

---

#### X-2

On-chain: **No**

> The fee a pool charges as its pass-through base is the `buyFeeBps` the registry records for that pool.

**Caller side** — `AmpsHook.sol:345` — `c.buyFeeBps = pc.buyFeeBps == 0 ? _defaultBuyFee(pc.poolClass) : pc.buyFeeBps` is read from `IPoolRegistry.poolConfig` exactly once, at `afterInitialize`, and thereafter lives in the hook's own CONFIG word.

**Callee side** — `PoolRegistry.sol:404` — `reconfigureConstituent` writes `pool.buyFeeBps = params.buyFeeBps` (banded at `:402`) with no call into the hook. The hook's copy moves only through `AmpsHook.setBuyFeeBps` (`AmpsHook.sol:1648`).

**If violated** — both values stay inside their class bands, so no fee escapes its ceiling; what diverges is which number is authoritative, and `VaultPlacementLib._creatorSlice` reads the hook's while governance proposals and the dApp read the registry's.

---

#### X-3

On-chain: **No**

> `AmpsVault` refuses a gated selector whenever the oracle gate says the protocol is unhealthy.

**Caller side** — `AmpsVault.sol:1625-1650` — `_requireGate` reads the gate through two bounded, hand-decoded `staticcall`s (`_gateRead`, `:1657-1666`) and returns without refusing whenever `known` is false: `if (!known || word > uint256(type(GateState).max)) return;` (`:1641`).

**Callee side** — `OracleGate.sol:900-947` — `_snapshot` is the only producer of a `GateState`, and every layer it reads is itself a bounded probe that degrades to "unknown". `AmpsVault.setPolicyPointer` refuses a codeless replacement (`AmpsVault.sol:1271`), so reaching the fail-open branch takes a gate that reverts, answers short, or burns its 1,500,000-gas budget.

**If violated** — the fail-open is deliberate and documented (`AmpsVault.sol:77-84`): an immutable vault must never be locked out of replacing a broken gate. The consequence is that gate refusal is a liveness property of the gate's implementation, not of the vault.

---

#### X-4

On-chain: **No**

> `AmpsBonds` refuses to price while the vault's last NAV was built on a held-back or stale feed answer.

**Caller side** — `AmpsBonds.sol:1312-1318` — `_navUnconfirmed` is a bounded raw `staticcall` of `navUnconfirmed()` whose failure returns `false`, i.e. "confirmed"; the guard that consumes it is `AmpsBonds.sol:526`.

**Callee side** — `AmpsVault.sol:1536` — `_navUnconfirmed = unconfirmed` is written only inside `_checkpoint`, from `VaultNavLib.totalAssetsUsd18`'s second return value (`VaultNavLib.sol:159`), which is set when **any** priced asset read `!fresh || unconfirmed`.

**If violated** — the fail-open direction is the documented choice (a probe that cannot be answered must not halt every bond market at once), but it means the flag protects issuance only while the vault is readable.

---

#### X-5

On-chain: **No**

> `PoolRegistry.currentWeightBps` reports the *realised* index weight of a constituent.

**Caller side** — `PoolRegistry.sol:558-579` — `weightBps` is seeded with `_constituents[constituentId].targetWeightBps` **before** the call, and a hand-rolled `staticcall` capped at `VAULT_WEIGHT_PROBE_GAS` (2,000,000) replaces it only on a well-formed answer inside `[0, BPS]`.

**Callee side** — `VaultNavLib.sol:203-236` — `spokeWeightBps` reverts `SpokeUnpriceable` on three branches (no usable feed answer `:215`, no valuer or reference price `:219-221`, reference price outside `PriceLib`'s domain `:223`), and answers `0` for an unknown id or a zero checkpointed `A` (`:208-212`).

**If violated** — the fallback is the target weight, which prices `deficit == 0` and is the protocol-favourable direction; the effect is that the bond discount's index-deficit term and the rollout schedule's weighting silently stop responding to a spoke the protocol cannot price.

---

#### X-6

On-chain: **Yes**

> Only `AmpsBonds` can cause AMPS to be minted post-genesis, and only into its own custody.

**Caller side** — `AmpsBonds.sol:454` — `IAmpsVault(vault).mintVesting(address(this), ampsOut)`, reached only from `bond` after the accretion floor and both capacity clamps.

**Callee side** — `AmpsVault.sol:973-984` — `mintVesting` checks `msg.sender != bonds_` (`:977`) and `to != bonds_` (`:978`) before `IAmps(_AMPS).mint(to, amount)`. `Amps.mint` is `onlyVault` (`Amps.sol:46`), and the vault's only other mint site is `VaultNavLib.genesisAllocate` (`VaultNavLib.sol:727-729`), behind the one-shot `_genesisMinted` latch.

**If violated** — post-genesis issuance is the single dilution path in the protocol; a second one would make the accretion floor advisory.

---

#### X-7

On-chain: **Yes**

> A bond is priced against a checkpoint written in the same block, not a stale one inside the staleness window.

**Caller side** — `AmpsBonds.sol:387` — `bond` calls `IAmpsVault(vault).depositBonded(...)` and only then reads `checkpointData()` in `_price` (`AmpsBonds.sol:521`), bounded by `CHECKPOINT_MAX_AGE` at `:524`.

**Callee side** — `AmpsVault.sol:957` — `depositBonded` runs `_checkpoint()` **before** the collateral settles at `:960`, so the NAV the shell then reads is this block's pre-deposit NAV.

**If violated** — a second bond inside the 30-minute window could issue against a NAV a previous bond had already raised, diluting every holder.

---

#### X-8

On-chain: **Yes**

> Only the vault may open or add liquidity to an Amplestocks pool.

**Caller side** — `AmpsVault.sol:1062-1063` — `initializePool` is the only site that calls `IPoolManager.initialize`, and `VaultPlacementLib._placeCell` (`:778-788`) the only site that calls `modifyLiquidity` with a positive delta, both executing in the vault's context.

**Callee side** — `AmpsHook.sol:325` and `AmpsHook.sol:393` — `_beforeInitialize` and `_beforeAddLiquidity` both `revert NotVault(sender)` for any other `sender`. The hook's permission word carries no `BEFORE_REMOVE_LIQUIDITY` bit (`AmpsHook.sol:305`), so removals are never blockable.

**If violated** — protocol-owned liquidity is the whole market-making design; a third-party LP would break the ladder's sidedness and the position valuer's grid enumeration at once.

---

#### X-9

On-chain: **No**

> `PoolRegistry` closes a retired constituent's bond market and opens a new one's.

**Caller side** — `PoolRegistry.sol:897-907` — `_setMarketOpen` reads the live market id through a bounded, hand-decoded `staticcall` (`_liveMarketId`, `:916-933`) and returns silently when it reads `0`, emitting `BondMarketDetached` at most.

**Callee side** — `AmpsBonds.sol:681-689` — `setMarketOpen` accepts the registry as a governance caller (`_requireGovernance`, `:1382-1385`) and refuses to re-open a market whose collateral has been detached (`:685`).

**If violated** — a bonds pointer that cannot answer leaves a retired name's market in whatever state it was in, which is the documented degradation; the registry deliberately cannot be blocked from retiring by an unresponsive shell.

---

## 4. Economic Invariants

Higher-order properties derived from combinations of §2 and §3 invariants. Every block traces back to concrete invariant IDs.

---

#### E-1

On-chain: **Yes**

> AMPS `totalSupply` increases only at genesis and through a bond, and decreases only through redemption, the compound fee burn and the high-water buyback.

**Follows from** — `I-14` + `I-15` + `X-6`, plus the burn sites `AmpsVault.sol:848`, `AmpsVault.sol:882`, `VaultPlacementLib.sol:257`, `VaultPlacementLib.sol:383` and `VaultPlacementLib.sol:1271`, all of which reach `Amps.burn` behind `onlyVault` (`G-40`).

**If violated** — the share count is the denominator of NAV/share; an unaccounted mint dilutes every holder and an unaccounted burn misprices every subsequent bond.

---

#### E-2

On-chain: **Yes**

> A bond issues at or below `navPerShare × (1 + minAccretionBps)` per unit of haircut-adjusted collateral value — issuance is accretive to NAV/share by construction.

**Follows from** — `I-10` + `I-8` + `X-7`, with the shell's independent re-check at `G-38` and the recomputation of `ampsOut` from the bounded `q` at `AmpsBonds.sol:545`.

**If violated** — bonding becomes the cheapest way to acquire AMPS below backing, and every holder pays for it.

---

#### E-3

On-chain: **Yes**

> No placement, compound, rollout or bonded deployment may cost holders more than 2 bp of NAV/share; an evacuation may cost at most 50 bp.

**Follows from** — `I-8` + `G-20` + `G-21`, with `navBefore` and `navAfter` both taken from `_previewNav`/`_checkpoint` on the same valuation basis (`AmpsVault.sol:1456-1460`) and, on the migration path, both measured after the ladder is unwound to claims (`AmpsVault.sol:1330-1357`).

**If violated** — the placement engine is permissionless on three of its five entry points; without the bound, keeper-callable placement is a value-extraction surface.

---

#### E-4

On-chain: **No**

> Rollout drains the entry pools by at most `rolloutBpsPerDay` of the POL tranche per rolling day, and never below `entryFloorBps`.

**Follows from** — `I-19` + `G-32` + `G-33`. The rate limit itself holds; what it is measured against does not: `_askInventory` (`VaultRolloutLib.sol:344-365`) skips cells the high-water mark has crossed, so both the floor test and the schedule's inventory input describe tradeable ask depth rather than total AMPS in the entry pools.

**If violated** — the entry pools are the way in and out of the index; draining them faster than the governed schedule removes the depth every other price in the system is measured against.

---

#### E-5

On-chain: **No**

> Total keeper spend is bounded by `dailyCeilingUsd18` per day and by `gasCapMultiple × gasCostUsd18` per job.

**Follows from** — `I-20` + the per-job caps at `BountyPot.sol:346-368`. The per-job caps are exact; the daily bound is a resetting window whose reachable worst case is 2× the ceiling inside one rolling 24 hours.

**If violated** — the pot is segregated from NAV (`I21` in the project's own numbering), so an overspend degrades the keeper budget rather than the backing — but it is the only bound on how fast a funded pot can be emptied.

---

#### E-6

On-chain: **No**

> The bond discount and the rollout schedule respond to a constituent's realised index deficit.

**Follows from** — `X-5` + `I-3`. Both consumers compute `deficit = (target − current) / target`: `AmpsBonds._deficitX18` (`AmpsBonds.sol:1088-1106`) and `RolloutPolicy._deficitX18` (comment-stripped listing lines 67-71). The numerator depends on a weight vector nothing keeps normalised (`I-3`), and the "current" term falls back to the target on any unpriceable spoke (`X-5`), which prices `deficit == 0`.

**If violated** — the deficit term is the mechanism that steers new collateral toward under-weight names; with it pinned at zero the bond board and the rollout schedule are effectively flat-rate.
