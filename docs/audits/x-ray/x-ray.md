# X-Ray Report

> Amplestocks ($AMPS) | 10,597 nSLOC | `ccffe6c` (`claude/amplestocks-rwa-token-xhtnn5`) | Foundry | 09/09/26

---

## 1. Protocol Overview

**What it does:** A share token whose backing is a book of tokenized US equities, market-made by the protocol's own Uniswap v4 liquidity, priced against a NAV floor, and issued post-genesis only through discounted vesting bonds.

- **Users**: traders (buy/sell/rotate AMPS through 32 v4 pools), redeemers (pro-rata claim on the whole asset book), bonders (deposit a registered collateral for AMPS at a discount, vesting linearly), keepers (paid in USDG for `compound` / `rollout` / `deployBonded`).
- **Core flow**: swap into AMPS through an entry pool → the vault's ladders are the counterparty → redeem pro-rata at any time for a slice of every registered asset, less `redeemFeeBps`.
- **Key mechanism**: the vault is the *sole* LP in every pool (`beforeAddLiquidity` refuses any other sender) and lays geometric doubling ladders on a canonical per-pool grid; an immutable hook charges a protocol-wide fee both ways, keeps a truncated-tick observation ring, and refuses only swaps beyond an outer rail.
- **Token model**: `AMPS` (18-dec ERC-20 + permit, mint/burn by the vault only), ERC-6909 claims inside the PoolManager for every asset, `VestingPosition[]` per bonder inside `AmpsBonds`, `USDG` in a segregated `BountyPot`.
- **Admin model**: one `TimelockController` address per contract (immutable), plus a guardian Safe whose entire power is expiring disable-only freezes and a predicate-gated evacuation. No proxies, no `initialize()`, no pause flag anywhere in `src/`.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Vault | `AmpsVault`, `VaultPlacementLib`, `VaultNavLib`, `VaultRedeemLib`, `VaultRolloutLib` | 3,061 | Custody, NAV, reference price, pro-rata redemption, the whole placement engine |
| Hook | `AmpsHook`, `HookStateLib` | 1,026 | Dynamic fee law, outer-rail refusal, truncated TWAP ring, high-water mark |
| Oracle | `OracleGate`, `FeedRegistry`, `GatePriceMath`, `StreamsSchemaLib` | 1,303 | Six-layer gate (cadence, calendar, freshness, corporate actions, divergence, reference integrity) |
| Bonds | `AmpsBonds`, `AmpsBondsLens` | 920 | The only post-genesis issuance path: discount, accretion floor, capacity, vesting |
| Periphery | `AmpsQuoter`, `AmpsRouter`, `QuoterSwapLib` | 1,021 | Never-reverting quote surface and the buy / sell / rotate router |
| Registry | `PoolRegistry`, `PoolRegistryLens` | 612 | Pool and constituent allowlist, index weights, lifecycle |
| Genesis | `AmpsGenesis` | 366 | Two-leg Continuous Clearing Auction adapter and launch-price derivation |
| Policy | `FeePolicy`, `LadderPolicy`, `BondPolicy`, `RolloutPolicy` | 441 | Pointer-upgradeable pure pricing and shaping laws |
| Keeper | `BountyPot` | 182 | Segregated USDG bounty budget, excluded from NAV |
| Valuer | `LadderPositionValuer`, `ZeroPositionValuer` | 138 | Decomposes v4 positions at the reference price for the NAV sum |
| Token | `Amps` | 30 | Share token; `totalSupply` moves only where the vault moves it |
| Types | `Constants`, `Types`, `Errors` | 443 | Hard bands, shared structs, shared errors |
| Shared libs *(not in the enumerator's total — see note)* | `PriceLib`, `LadderLib`, `PoolStateLib`, `TruncatedOracleLib` | 784 | Price/tick conversions, ladder maths, `IExtsload` slot arithmetic, observation ring |

The 10,597 figure is the enumerator's exact TOTAL. It excludes `src/lib/` (4 files, 784 nSLOC) because the tool's
`-not -path '*/lib/*'` filter, meant for the Foundry dependency directory, also matches this project's own
`src/lib/`. **True in-scope nSLOC is 11,381 across 33 protocol-authored files.**

### Backwards-Compatibility Code

- `AmpsVault._reservedSlot6` (slot 6) — held the xAMPS staking vault until plan revision 6 removed staking; no writer names it any more and `VaultLayout.t.sol` asserts it stays zero.
- `AmpsVault._reservedFeeSplit` (slot 2 `[16..47]`) — held `burnBps` and `stakerBps` until the staker leg was retired and the burn became unconditional; retained so no field above it shifts.
- `AmpsVault._checkpointReserved` / `_reservedSlot21` — declared packing fillers that keep the documented slot map literally true; never read or written.
- `VaultRedeemLib.NAV_BEFORE` — a transient slot constant written by nothing since `emergencyMigrate` began measuring both sides of its bleed bound live.
- `ConstituentConfig.freezeUntil` — written only as `0` at `PoolRegistry.sol:305` and read at `PoolRegistry.sol:1001`; the "future gate callback" that would set it does not exist, so the read-side freeze overlay is driven entirely by `caFreezeOverride`.

### How It Fits Together

The core trick: the protocol is its own market maker, so every AMPS a trader buys comes off a ladder the vault
placed at or above its own NAV, and every AMPS sold walks back down that ladder into inventory the vault burns.

### Trading against protocol-owned liquidity

```
AmpsRouter.buy(poolId, amountIn, minAmpsOut, to, deadline)
└─ PoolManager.unlock()
   └─ PoolManager.swap(key, exactInput)
      ├─ AmpsHook.beforeSwap()          ← three cold SLOADs; base fee = ampsFeeBps (500 bp)
      │  └─ FeePolicy.quoteFee()         ← deviation, variance, session, surge, dividend-capture toll
      │     └─ *refuses only when deviation-increasing AND beyond the outer rail*
      └─ AmpsHook.afterSwap()
         ├─ TruncatedOracleLib.write()   ← *tick capped at maxTickMovePerBlock; high-water mark advances*
         └─ OracleGate.snapshotByPool()  ← *at most once per pool per gateCacheSeconds; failure keeps the cache*
```

### Pro-rata redemption — the structurally ungated floor

```
AmpsVault.redeemProRata(shares, to)
├─ Amps.burn(msg.sender, shares)         ← *effects first: shares gone before an asset moves*
├─ PoolManager.unlock(ACTION_UNWIND)
│  └─ VaultRedeemLib.unwind()            ← removes floor(L × shares / T) from every live cell in every pool
├─ VaultRedeemLib.redemption()           ← *no gate, no price, no registry read on this path*
└─ VaultRedeemLib.payout()
   ├─ PoolManager.take() per asset       ← ERC-20 attempt, gas-bounded
   └─ PoolManager.transfer() per asset   ← *fallback: hands over the ERC-6909 claim no token can refuse*
```

### Bonding — the only post-genesis issuance

```
AmpsBonds.bond(marketId, amountIn, minAmpsOut, to)
├─ OracleGate.checkBond()                ← *only freeze or divergence refuses; staleness widens the haircut*
├─ AmpsVault.depositBonded()
│  ├─ AmpsVault._checkpoint()            ← *NAV is re-derived BEFORE the collateral lands*
│  └─ VaultRedeemLib.settleFrom()        ← bonder → PoolManager → ERC-6909 claim to the vault
├─ BondPolicy.quote()                    ← discount = dBase + k_w·deficit − k_c·fill, clamped
├─ AmpsBonds._qFloorX18()                ← *the shell recomputes the floor and discards the policy's product*
└─ AmpsVault.mintVesting() → Amps.mint() ← minted into AmpsBonds custody, vesting linearly
```

### The placement engine — permissionless and bountied

```
AmpsVault.compound(poolId)               ← anyone; paid from BountyPot
├─ OracleGate.checkPlacement()
├─ VaultPlacementLib.compound()
│  ├─ _collect()                          ← realise fees in both currencies; creator slice paid as a claim
│  ├─ _burnback()                         ← *cells the high-water mark crossed are withdrawn and their AMPS burned*
│  ├─ _split()                            ← *whole AMPS remainder burned; nothing is re-laddered as an ask*
│  └─ _placeLadder(bids)                  ← counter side re-placed below the tick, on the canonical grid
├─ AmpsHook.resetHighWater() / armSurge()
└─ AmpsVault._afterPlacement()            ← *R1: reverts if NAV/share fell more than 2 bp*
```

### Genesis

```
Timelock.genesisMint()  → mints S0 = 20,000 AMPS (team 1,000 / auction 10,000 / POL 9,000)
Timelock.createAuctions() → two Continuous Clearing Auctions (USDG and native ETH legs)
[bidding window]
Anyone.settle()
├─ sweepCurrency() + sweepUnsoldTokens() per leg
├─ _launchPrice()                        ← *USDG leg wins when it graduated; it needs no oracle to become a price*
└─ AmpsVault.genesisPlace()              ← *P_ref = max(p0, navPerShare); _initialized and _wiringFrozen latch*
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield Aggregator / Vault** with **DEX/AMM** and **Stablecoin** characteristics

Share-based accounting with `navPerShareX18`, `totalAssetsUsd18`, a virtual-share offset and a pro-rata redemption
put the vault model first; a full Uniswap v4 hook with dynamic fees, TWAP observations and protocol-owned ladders
adds the AMM profile; a NAV-anchored reference price, a haircut-adjusted accretion floor and an open redemption
mechanism add the stablecoin profile without a peg target.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Timelock | Trusted | 59 setters across 8 contracts, all instant on-chain. Re-points `oracleGate`, `feedRegistry`, `positionValuer`, `marketReference`, `ladderPolicy`, `rolloutPolicy`, `genesis`; sets every fee, band and cap; `genesisMint`; `sweep`s the bounty pot; `addConstituent`/`retire`/`setIndexWeights`. Cannot move a user's funds, mint, or stop `redeemProRata`/`claim`. |
| Guardian | Bounded (disable-only, all powers auto-expire ≤ 7 d) | `freezeProtocol` / `freezeConstituent` (no delay, expiring), `unfreeze*`, and `emergencyMigrate` — instant, no timelock, hands five `onlyVault` roles and the whole estate to the pre-registered standby. Cannot block redemption or claim. |
| Vault (`AmpsVault`) | Trusted (immutable bytecode) | Sole minter/burner of AMPS, sole LP in all 32 pools, sole `pay` caller on `BountyPot`, holds every claim. Its own address is movable only by the guardian's evacuation. |
| Creator | Bounded (fee recipient only) | Receives `creatorBps(t)` of each currency's collected fees, decaying to 0 at day 30; may re-assign the recipient. No other power. |
| `PoolRegistry` | Trusted (timelock-only mutators) | Opens pools through the vault, opens/closes bond markets, sets index weights. |
| `AmpsBonds` | Trusted (immutable) | The only contract that can make the vault mint post-genesis. |
| Keeper | Bounded (paid, unprivileged) | Calls `compound`, `rollout`, `deployBonded` on any pool/constituent, once per pool per 60 s; chooses ordering and timing. Not subject to any pause — no pause exists. |
| Genesis adapter | Bounded (one call, latched) | Sole auction-side caller of `genesisPlace`; ownerless and immutable. |
| PoolManager (v4) | Trusted (external, immutable) | Holds every claim and every position; drives all five hook callbacks. |

**Adversary Ranking** (ordered by threat level for this protocol type, adjusted by git evidence):

1. **Donation / share-price manipulator** — the vault's `A` is built from live balances and ERC-6909 claims, and any address can donate to the vault, the bonds shell, the router or a pool at any time.
2. **Keeper-ordering adversary** — three permissionless, bountied entry points reshape protocol-owned liquidity and burn supply, and the caller picks which pool, which constituent and in what order.
3. **Oracle manipulator** — every price in the system descends from Chainlink answers and the hook's own truncated TWAP, both of which the protocol reads through fail-open probes.
4. **Compromised timelock holder** — one address holds 59 instant setters including every pointer the vault calls.
5. **MEV searcher / sandwich attacker** — the ladders are a public, deterministic, grid-aligned order book with a 60-second placement cooldown.
6. **Hostile constituent issuer** — Stock Tokens are third-party beacon proxies that can pause, denylist, restate a multiplier or burn gas on any call.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Timelock → every governed contract** — one immutable address per contract, checked with a bare `msg.sender` comparison; the 48 h / 7 d / 14 d tiers exist only in the documentation and in the `TimelockController`'s single `minDelay`, which `script/03_Core.s.sol:296` deploys as **0** with an open executor until `CORE_STAGE=finalize` runs.

- **Guardian → vault estate** — no delay at all; the only brake is the on-chain denylist predicate at `VaultNavLib.sol:406-427` and the requirement that the destination was pre-registered.

- **Vault → oracle gate** — the vault treats an unreadable gate as *absent*, not as a refusal (`AmpsVault.sol:1641`), which is deliberate for an immutable contract but means gate enforcement is a liveness property of the gate's own implementation. *Git signal: `OracleGate.sol` appears in 6 source-touching commits, and `access_control` changed in 17 of 24 — elevated risk.*

- **Vault → linked libraries** — `VaultNavLib`, `VaultPlacementLib`, `VaultRedeemLib` and `VaultRolloutLib` are `DELEGATECALL` targets fixed at link time, so they are part of the immutable vault, but they are also separately deployed contracts with `public` functions and their own (empty) storage.

- **Protocol → Stock Tokens** — every read of an issuer's contract is a gas-capped, hand-decoded `staticcall` whose failure degrades rather than reverts; the one thing an issuer *can* do is make a redemption pay in ERC-6909 claims instead of tokens.

### Key Attack Surfaces

- **Governance delay tiering is not on-chain** — `script/03_Core.s.sol:289-299` deploys one `TimelockController` with `minDelay = 0`, an open executor and the deployer as a proposer; every contract stores that one address (`AmpsVault.sol:314`, `OracleGate.sol:139`, `PoolRegistry.sol:125`, `AmpsHook.sol:185`, `BountyPot.sol:93`). Worth confirming what `CORE_STAGE=finalize` actually sets and whether anything distinguishes a 48-hour setter from a 14-day one after it.

- **Vault gate reads fail open by construction** &nbsp;&#91;[X-3](invariants.md#x-3), [G-22](invariants.md#g-22), [G-23](invariants.md#g-23)&#93; — `AmpsVault._requireGate:1625-1650` returns without refusing whenever `_gateRead` cannot believe the answer, and both reads carry a 1,500,000-gas cap. Worth tracing which gated selectors remain reachable when the gate is merely expensive rather than broken.

- **Three permissionless entry points reshape protocol-owned liquidity** &nbsp;&#91;[I-4](invariants.md#i-4), [E-3](invariants.md#e-3), [G-20](invariants.md#g-20), [G-25](invariants.md#g-25)&#93; — `compound`, `rollout` and `deployBonded` (`AmpsVault.sol:1097-1125`) each remove, burn and re-place inventory under a 2 bp NAV bound and a 60-second per-pool cooldown, with the caller choosing the pool and the ordering. Worth tracing what a keeper who calls them in an adversarial sequence across pools can move that a single call cannot.

- **Registry and hook hold two copies of a pool's configuration** &nbsp;&#91;[X-1](invariants.md#x-1), [X-2](invariants.md#x-2)&#93; — the hook reads `buyFeeBps` and derives `gridBaseTick` once at `afterInitialize` (`AmpsHook.sol:345`, `:351`), and `PoolRegistry._openPool:829-835` mirrors the origin back inside a `try`/`catch` that leaves the field at zero on failure. Worth confirming which copy each consumer reads and what happens to the placement lattice if the mirror ever misses.

- **Index weight normalisation is enforced at one call site** &nbsp;&#91;[I-3](invariants.md#i-3), [E-6](invariants.md#e-6), [G-41](invariants.md#g-41)&#93; — `PoolRegistry.sol:479` checks the sum; `addConstituent:275`, `reconfigureConstituent:408` and the retire/reinstate counter moves at `:347`/`:374` check only the per-name band. Worth checking what the bond discount's deficit term and the rollout schedule price against a vector that no longer sums to `BPS`.

- **Bond pricing chains three fail-open reads** &nbsp;&#91;[X-4](invariants.md#x-4), [X-7](invariants.md#x-7), [G-36](invariants.md#g-36), [G-37](invariants.md#g-37), [E-2](invariants.md#e-2)&#93; — `AmpsBonds._price:515-550` requires a same-block checkpoint, a confirmed-NAV flag read through a raw `staticcall` that answers `false` on failure (`:1312-1318`), and a policy answer it then re-derives. Worth tracing the three orderings in which the vault is readable for one of those and not the others.

- **The redemption floor's payout path is a gas budget** &nbsp;&#91;[I-9](invariants.md#i-9), [G-1](invariants.md#g-1), [G-2](invariants.md#g-2)&#93; — `VaultRedeemLib.payout:418-464` sizes a reserve as `32,000 × tokens.length + 60,000`, skips the ERC-20 leg entirely below `reserve + 200,000`, and pays idle dust only while `gasleft() >= 8 × STOCK_TOKEN_PROBE_GAS`. Worth measuring the reserve against the 66-asset maximum the collateral cap admits.

- **Guardian evacuation runs with no delay and a relaxed bleed bound** &nbsp;&#91;[G-16](invariants.md#g-16), [G-17](invariants.md#g-17), [G-18](invariants.md#g-18), [G-21](invariants.md#g-21)&#93; — `AmpsVault.emergencyMigrate:1319-1391` unwinds every position, moves every claim and hands over five `onlyVault` roles, and both halves of the 50 bp bound are skipped when either side is unpriceable (`:1360-1366`, `:1386-1388`). Worth checking what the predicate at `VaultNavLib.sol:406` accepts as evidence and who can produce it.

- **The protocol is its own price oracle** &nbsp;&#91;[I-11](invariants.md#i-11), [X-5](invariants.md#x-5)&#93; — `P_mkt` comes from the hook's own ring (`AmpsHook._obs`), the gate's `fairTick` from the same ring plus a feed, and a spoke's realised index weight from the vault's own valuation of its own positions. Worth tracing which of those loops has an external anchor and which closes on protocol state.

- **Deployed libraries expose public entry points** — `VaultNavLib.setPointer/evacuate/handover/migrationPredicate`, `VaultPlacementLib.place/compound/unlockAction/payBounty/splitHarvestFees`, `VaultRedeemLib.unlockAction/settleFrom/payout/unwind/sweepClean` and the three `VaultRolloutLib` jobs are `public` on separately deployed addresses. Worth confirming that each reads only the caller's own (empty) storage when reached by `CALL` rather than `DELEGATECALL`.

- **Keeper spend accounting is a resetting window** &nbsp;&#91;[I-20](invariants.md#i-20), [E-5](invariants.md#e-5)&#93; — `BountyPot._chargeWindow:376-386` opens a fresh window on the first payment 24 h after the last one opened, and the work value the caps are applied to is derived by the vault inside the same call (`VaultPlacementLib.payBounty:1670`). Worth checking the gas-reserve arithmetic at `_gasUsed:1704-1710` against a caller-chosen transaction gas limit.

- **Ladder bookkeeping diverges on one of four removal paths** &nbsp;&#91;[I-5](invariants.md#i-5)&#93; — `VaultRedeemLib.unwind:757` decrements `record.liquidity` without the matching `record.amount` write the other three paths make. Worth confirming nothing downstream prices from that field.

- **Feed jump confirmation has a keeperless path** &nbsp;&#91;[G-44](invariants.md#g-44)&#93; — `FeedRegistry._evaluate:658-696` falls back to comparing the candidate against `roundId - 1` and `roundId - 2` whenever no latch exists or the latch is older than one heartbeat, and every failed probe reads as "no previous round", i.e. not a jump. Worth tracing which branch a production deployment with no `refresh()` keeper actually takes.

### Upgrade Architecture Concerns

No proxies exist. The upgrade surface is instead a set of pointer slots the timelock rewrites in place:

- **Ten pointer slots, one setter** — `AmpsVault.setPolicyPointer:1267` writes slots 4, 5, 7, 8, 9, 10, 11, 12, 13 and 22 by name through `VaultNavLib.setPointer:449-483` using raw `sstore`; only four are set-once, and the slot numbers are duplicated as private constants in `VaultPlacementLib` and `VaultRolloutLib`.
- **`marketReference` carries no latch by design** — `AmpsVault.sol:1257-1266` documents the decision; the hook it points at is the protocol's own price reference, high-water mark and surge target.
- **A standby vault is an unaudited second implementation** — `emergencyMigrate` hands it five `onlyVault` roles with no way back, and nothing in `src/` constrains its bytecode beyond `code.length != 0`.

### Protocol-Type Concerns

**As a Yield Aggregator / Vault:**
- `VaultNavLib.totalAssetsUsd18:134-163` builds `A` from live `balanceOf` plus ERC-6909 claims plus a valuer term, so a donation of any registered asset lands in `A` at the next checkpoint; `VIRTUAL_SHARES = 1e3` is the only inflation offset and `S0 = 20,000e18` is minted before the first deposit.
- An unreadable `balanceOf` contributes **zero** to `A` (`VaultNavLib.sol:580-585`), so one issuer can understate NAV for every asset it does not touch.

**As a DEX/AMM:**
- `VaultPlacementLib._cells:803-845` clips the bucket count to the grid's bounds rather than reverting, and the ask/bid anchors round in opposite directions with a documented one-tick-spacing residue on the first ask cell (`:1597-1627`).
- `AmpsHook._updateVariance:821-838` stores the EWMA at X12 and saturates `uint64` five orders of magnitude below the arithmetic maximum; the clamp is what stops a wrap reporting a *lower* fee on the largest moves.

**As a Stablecoin:**
- `AmpsBonds._qFloorX18:994-1004` and `BondPolicy.qFloorX18` are deliberate duplicates compared at `AmpsBonds.sol:542`; the rounding directions (numerator down, denominator up, quotient down) must match exactly for the comparison to mean anything.

### Temporal Risk Profile

**Deployment & Initialization:**
- The gate and the first pool are circular: `initializePool` and both genesis steps take the management policy, and the gate reports `WATCHDOG` on an unobserved hub, so the gate pointer must be set last (`docs/phase2-state-model.md` §9.1) — an ordering the contracts do not enforce.
- `AmpsGenesis.settle()` is permissionless and one-shot; if the timelock runs the founders'-seed `genesisPlace` while the auctions are live, the raise is forwarded as plain balances and the `P_ref` seeding is lost (`AmpsGenesis.sol:273-285`).
- `PoolRegistry._referencePriceUsd18:866-869` anchors every pool at $1.00 while `pRefX18() == 0`, and `AmpsVault.checkpoint` refuses before genesis specifically to keep that word zero.

**Market Stress:**
- `FeedRegistry._maxAge:624-628` disables the freshness bound entirely when the session is `CLOSED`, so a weekend answer never ages out; the bond haircut is the only thing pricing that.
- `AmpsHook._effective:764-793` substitutes the *regular* band once the gate cache is older than 900 s, deliberately tightening the rail at the moment the fair tick falls back to the pool's own TWAP.

**Deprecation:**
- `_standbyVault` plus `emergencyMigrate` is a live migration path with no deadline and no rehearsal in `src/`; `AmpsStaking` was removed outright in revision 6, leaving the storage reservations listed in Section 1.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Uniswap v4 `PoolManager`** — via `AmpsVault.unlockCallback`, `AmpsRouter.unlockCallback`, `VaultPlacementLib`, `VaultRedeemLib`
> - Assumes: `unlock` re-enters only the caller; `modifyLiquidity` returns `callerDelta` and `feesAccrued` separately; ERC-6909 `transfer` cannot be refused by a token
> - Validates: `msg.sender == poolManager` plus a transient action discriminator (vault) or the entry-point lock (router)
> - Mutability: Immutable
> - On failure: reverts; the vault's `sweepClean` and `payout` legs wrap their own `unlock`s in `try`/`catch`

> **Chainlink aggregators** — via `FeedRegistry._probe` / `_probeRound`
> - Assumes: `latestRoundData` is a Standard (not SVR) proxy, `decimals() <= 18`, positive answer, non-future `updatedAt`
> - Validates: `code.length`, gas cap, positivity, per-ticker min/max band, session-scaled staleness, two-confirmation jump rule
> - Mutability: Upgradeable behind a Chainlink proxy the protocol does not control; the aggregator behind it can be re-pointed
> - On failure: the last latched answer stands and ages out; the gate degrades to `DEGRADED`

> **Stock Tokens (issuer beacon proxies)** — via `OracleGate._corporateAction`, `AmpsHook._probeMultiplier`, every vault balance read
> - Assumes: nothing — every call is a gas-capped `staticcall` with a hand-decoded first word
> - Validates: return length, gas, and (for `transfer`) SafeERC20's acceptance rule by hand
> - Mutability: Upgradeable by the issuer; can pause, denylist and restate `uiMultiplier()` at will
> - On failure: skipped, or read as evidence for the migration predicate

> **Continuous Clearing Auction factory** — via `AmpsGenesis._deploy` / `_harvest`
> - Assumes: `create` or `initializeDistribution` returns an address; `clearingPrice()` is Q96 currency-per-token; `sweepCurrency`/`sweepUnsoldTokens` pay the recorded recipient
> - Validates: the returned address holds code and the full tranche; the issuance schedule totals exactly 100% over the block window; both legs are past `claimBlock`
> - Mutability: Third-party bytecode, fixed at `AmpsGenesis` construction
> - On failure: `createAuctions` surfaces the factory's own revert; `settle()` is one-shot, so a failure there is terminal for the raise

> **`OracleGate` / `FeedRegistry` / `LadderPositionValuer` / policies** — via every vault and hook read
> - Assumes: shapes only — no return value is trusted without a length check and a range clamp
> - Validates: gas caps of 50k / 400k / 1.5M by call site, hand-decoded words, saturating casts
> - Mutability: **Governed** — all re-pointable by the timelock in one transaction
> - On failure: degrade (cached value, target weight, `type(int24).min` high-water, `LadderLib` weights)

**Token Assumptions** *(unvalidated only)*:
- Rebasing collateral: the vault settles a bond on the exact `amountIn` and rejects any mismatch, but a balance that rebases *after* settlement is absorbed into `A` at the next checkpoint with no attribution — impact: the rebase accrues to every holder rather than to the depositor.
- ERC-777 / callback tokens: `VaultRedeemLib._absorb:336-354` moves the `transfer` outside the unlock precisely so a re-entrant token hits `ManagerLocked`, but the same token reached through `PoolManager.take` inside `_payOut:506` runs while the manager is unlocked — impact: a foreign delta opened there fails the whole unlock, which is what the claims-only second attempt exists to survive.

**Shared State Exposure**:
- All 32 pools share one hook contract, one `OracleGate`, one `FeedRegistry` and one vault, so a per-pool fault (a stuck gate cache, a dead feed, a saturated variance) is scoped per pool but the gate's protocol-wide freeze and the `state(0)` read the vault gates on are not.
- The hub `AMPS/USDG` pool's TWAP is the reference every spoke's fair tick is derived from, so hub depth is the protocol's own oracle depth.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **45 Enforced Guards** (`G-1` … `G-45`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **22 Single-Contract Invariants** (`I-1` … `I-22`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **9 Cross-Contract Invariants** (`X-1` … `X-9`) — caller/callee pairs that cross scope boundaries
> - **6 Economic Invariants** (`E-1` … `E-6`) — higher-order properties deriving from `I-N` + `X-N`
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The **On-chain=No** blocks are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks (e.g. `[X-1]`, `[I-3]`).

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `contracts/README.md` — toolchain pins, deployment pipeline, library-linking flags, the Foundry broadcast rule |
| NatSpec | ~55 annotated files | Every source file carries `@notice`/`@dev`/`@param`/`@return`; roughly 55% of `src/` line count is comment, and the comments carry dated audit-fix rationale inline |
| Spec/Whitepaper | Present | `docs/phase2-state-model.md` (751 lines), `docs/phase3-state-model.md` (1,440 lines), `docs/genesis-cca.md`, plus deploy/launch/keeper runbooks and `docs/audits/` |
| Inline Comments | Thorough | Storage layouts documented slot-by-slot and asserted by `test/unit/VaultLayout.t.sol`; several comments record decisions *against* an audit finding with the reasoning |

The state models are the executable spec: they carry the caller matrix (per spec, §2), the three gate policies
(per spec, §7.1), the NAV and reference-price formulas (per spec, §4–§5) and a numbered invariant set `I1`–`I39`
that the test suite references by name. Claims in Section 2 above are code-verified unless tagged `(per spec)`.

One documentation gap is load-bearing: the delay tiers in the §2 caller matrix (48 h / 7 d / 14 d) have no
on-chain representation — see the first attack surface.

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 125 | File scan (always reliable) |
| Test functions | 1,388 | File scan (always reliable) |
| Line coverage | Pending | `forge coverage` still running at report time |
| Branch coverage | Pending | `forge coverage` still running at report time |

`forge coverage` was launched in the background per the pipeline and had completed compilation (236 + 274 files,
Solc 0.8.30) but had not emitted a coverage table when this report was written. Test *presence* below is from the
file scan and is unaffected.

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | broad | `test/unit/` — layout, guard symmetry, hook packing, fee table, rotation credit, placement, compound, rollout, redemption, quoter, registry/bonds wiring |
| Integration | present | `test/integration/` — Phase 2 and Phase 3 flywheel, hub pump, corporate action |
| Attack | present | `test/attack/` — TWAP dump-then-bond, hub pump into spoke bids, JIT at an empty tick, rotation-credit gaming, creator-fee wash trading |
| Fork | 0 | none |
| Stateless Fuzz | 116 | `test/fuzz/` plus inline fuzz cases; `fuzz = { runs = 512 }`, CI profile 4,096 |
| Stateful Fuzz (Foundry) | 37 | `test/invariant/` — `invariant = { runs = 64, depth = 64 }`, CI 256 × 128 |
| Stateful Fuzz (Echidna) | 0 | none |
| Stateful Fuzz (Medusa) | 0 functions : 1 config | `medusa.json` present and targets `Phase3Handler`; no `medusa_`-prefixed property functions found |
| Formal Verification (Certora) | 0 | none |
| Formal Verification (Halmos) | 0 | none |
| Formal Verification (HEVM) | 0 | none |

### Gaps

- **No formal verification of the NAV and bond-floor arithmetic.** `navPerShareX18`, `qFloorX18`, the ladder split and the redemption pro-rata are the highest-value math in the codebase and are exercised only by fuzzing. `halmos-cheatcodes` is already vendored under `lib/openzeppelin-contracts`, so the symbolic path is available.
- **Medusa is configured but not implemented.** `medusa.json` exists; no property function carries the `medusa_` prefix the config targets, so the campaign the Phase 3 spec describes cannot currently run.
- **Invariant depth is shallow for a 512-cell ladder.** The default profile runs 64 × 64 and CI 256 × 128 against a four-pool fixture; the live system is 32 pools with a `MAX_LIVE_CELLS` budget of 512.
- **No fork tests.** Every third-party assumption — the Chainlink Standard proxies, the Stock Token beacons, the Continuous Clearing Auction factory — is exercised only against local mocks.
- **The deployment pipeline is tested without broadcast in CI.** `test/script/broadcast.sh` proves the nonce rule against a local anvil, but it is a separate job rather than part of `forge test`.

---

## 6. Developer & Git History

> Repo shape: **normal_dev** — 24 of 66 commits touch source, spread over 4 days (2026-09-05 → 2026-09-09) on branch `claude/amplestocks-rwa-token-xhtnn5`. Analyzed branch: `claude/amplestocks-rwa-token-xhtnn5` at `ccffe6c`.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Claude | 61 | +29,352 / -3,244 | 100% |
| Camden | 5 | +0 / -0 | 0% |

Single-author source history: one contributor wrote 100% of `contracts/src/`. The second contributor's five
commits touch no source file.

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 2 | Single-dev on source |
| Merge commits | 4 of 66 (6%) | Almost no merge-based review; changes land directly on the branch |
| Repo age | 2026-09-05 → 2026-09-09 | 4 days |
| Recent source activity (30d) | 24 commits | Entire history is inside the window — this is a first-audit codebase, not a mature one |
| Test co-change rate | 95.8% | 23 of 24 source-touching commits also modify test files (co-modification, **not** coverage) |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| `contracts/src/vault/AmpsVault.sol` | 11 | High churn — the NAV, custody and migration authority |
| `contracts/src/types/Constants.sol` | 11 | Every hard band in the protocol; changes here move guards everywhere |
| `contracts/src/interfaces/IAmpsVault.sol` | 10 | The vault's ABI was still moving four days before the audit |
| `contracts/src/interfaces/IAmpsHook.sol` | 9 | Same for the hook |
| `contracts/src/vault/VaultPlacementLib.sol` | 8 | The placement engine — prioritize review |
| `contracts/src/vault/VaultNavLib.sol` | 8 | The NAV read side |
| `contracts/src/periphery/AmpsQuoter.sol` | 8 | Never-reverting surface, rewritten repeatedly |
| `contracts/src/hook/AmpsHook.sol` | 8 | Fee law and rail |
| `contracts/src/registry/PoolRegistry.sol` | 7 | Constituent lifecycle |
| `contracts/src/oracle/OracleGate.sol` | 6 | Six-layer gate |

### Security-Relevant Commits

**Score** = weighted sum of fix-like signals in a commit: message keywords, diff patterns (deletes code, changes `require`/`assert`, touches access control or accounting), and change shape (focused = higher). **10+ warrants a manual diff.**

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| `a48281c` | 2026-09-05 | Price bonds against a same-block checkpoint; add Phase 2 integration and invariant suites | 16 | Focused 3-file change spanning 5 security domains; +6 runtime guards |
| `5949464` | 2026-09-05 | Add Amps share token, Stock Token and oracle mocks, and the CREATE2 miner | 16 | Tightens access control (+9/-0) across 4 domains |
| `43b7cad` | 2026-09-09 | Remediate the revision-7 audit findings | 10 | 1,131 lines across 17 source files, 5 security domains — **the day before HEAD** |
| `0cdfcf9` | 2026-09-08 | Charge the AMPS fee both ways, pay the creator in kind, burn the rest | 9 | 2,204 lines; +14/-4 runtime guards; rewrote the whole fee model |
| `51614f0` | 2026-09-06 | Add AmpsHook, the hook miner and the real-hook gas baseline | 9 | +20 runtime guards in one commit |
| `d94f3db` | 2026-09-06 | Add the Phase 3 declarations, PoolStateLib and LadderPositionValuer | 9 | 12 files, 5 domains |
| `aff7a1c` | 2026-09-05 | Add AmpsVault core and VaultNavLib | 9 | 1,954 lines, 5 domains |
| `77e9038` | 2026-09-05 | Add AmpsBonds, BondPolicy and AmpsBondsLens | 9 | 1,444 lines, 4 domains |
| `f8a5211` | 2026-09-09 | Remediate the re-audit findings | 8 | 908 lines across 14 files — **HEAD's parent generation** |
| `495d54a` | 2026-09-08 | Run genesis through a Uniswap Continuous Clearing Auction | 8 | 1,485 lines; replaced the entire launch mechanism |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| fund_flows | 23 | `AmpsVault.sol`, `VaultPlacementLib.sol`, `AmpsBonds.sol` |
| oracle_price | 23 | `OracleGate.sol`, `FeedRegistry.sol`, `AmpsHook.sol` |
| state_machines | 22 | `AmpsVault.sol`, `AmpsGenesis.sol`, `PoolRegistry.sol` |
| signatures | 21 | `AmpsBonds.sol`, `VaultPlacementLib.sol`, `PoolRegistry.sol` |
| access_control | 17 | `AmpsVault.sol`, `OracleGate.sol`, `PoolRegistry.sol`, `BountyPot.sol` |

Every one of the five security domains changed in 17 or more of the 24 source-touching commits — there is no
settled area of this codebase.

### Forked Dependencies

None detected. All four `lib/` entries (`forge-std`, `openzeppelin-contracts`, `uniswap-hooks`, `hookmate`) are
standard submodules; `forked_deps.detected_libs` is empty. `PoolStateLib` and `TruncatedOracleLib` are
protocol-authored re-implementations rather than internalized copies — the README explains that v4-core pins
`solc =0.8.26` and cannot share a compilation graph with the project's 0.8.30 sources.

### Technical Debt Markers

None. `tech_debt.total_count == 0`, confirmed by an independent grep for `TODO`/`FIXME`/`HACK`/`XXX` across
`src/`, which returns nothing.

### Security Observations

- **Single-author source** — one contributor wrote +29,352 / -3,244 source lines, 100% of the total.
- **Almost no merge-based review** — 4 merge commits out of 66 (6%); source changes land on the branch directly.
- **The two largest commits are the two most recent** — `f8a5211` (908 lines) and `43b7cad` (1,131 lines) both landed 2026-09-09, the same day as HEAD.
- **Average commit size is 1,274 lines** — large enough that per-commit review is impractical; `ff33d7e` alone is 4,374.
- **The fee model was replaced 2 days before HEAD** — `0cdfcf9` (2,204 lines) moved the AMPS fee to both directions, paid the creator in kind and made the burn unconditional.
- **The launch mechanism was replaced 1 day before that** — `495d54a` routed genesis through a third-party Continuous Clearing Auction and added `AmpsGenesis.sol` whole.
- **Test co-change is near-total but shallow in one place** — 23 of 24 source commits touch tests; the exception is `ff33d7e`, the 4,374-line interface and constants commit.
- **A whole subsystem was deleted mid-history** — `contracts/src/staking/AmpsStaking.sol` appears in `da823a4` and `0cdfcf9` and is absent from HEAD, leaving the reserved storage listed in Section 1.

### Cross-Reference Synthesis

- **`AmpsVault.sol` is #1 in churn *and* carries five of the twelve attack surfaces** → highest-leverage review: `_requireGate:1625`, `emergencyMigrate:1319`, `_afterPlacement:1456`, `setPolicyPointer:1267`, `redeemProRata:829`.
- **`Constants.sol` at 11 modifications is the shared root of every `G-N` band** → a band that moved late moves guards in eight contracts at once; `43b7cad`, `f8a5211`, `0cdfcf9`, `7477f0c` and `495d54a` all touch it.
- **`oracle_price` churned in 23 of 24 commits and every fail-open probe traces to it** → `X-3`, `X-4` and `X-5` all describe reads that degrade rather than refuse, in the subsystem with the least settled history.
- **Zero TODOs against 24 source commits in 4 days** → the debt is not annotated in the code; it is in the interface churn (`IAmpsVault` 10, `IAmpsHook` 9) and in the two mechanism replacements that landed in the last 48 hours.

---

## X-Ray Verdict

**ADEQUATE** — unit, stateless-fuzz and stateful-invariant suites all exist and documentation is thorough, but access control is a single instant-acting timelock address per contract with no on-chain delay tiering and no pause mechanism anywhere in `src/`.

**Structural facts:**
1. 11,381 nSLOC across 33 protocol-authored source files in 12 subsystems (the enumerator's 10,597 excludes `src/lib/`, 784 nSLOC, via its `*/lib/*` filter).
2. 110 state-changing entry points: 20 permissionless, 31 role-gated, 59 admin-only; all 59 admin functions resolve to one `TimelockController` address per contract, fixed at construction.
3. Zero upgradeable proxies and zero `initialize()` functions; the mutable surface is 10 pointer slots the vault rewrites in place, 4 of which are set-once.
4. 125 test files with 1,388 test functions, 116 stateless-fuzz and 37 Foundry-invariant functions; no formal verification, no fork tests, and a Medusa config with no matching property functions.
5. One contributor authored 100% of source changes (+29,352 / -3,244) across 24 source-touching commits in 4 days, with 4 merge commits in the whole repository.
