# X-Ray Report

> Amplestocks ($AMPS) | 8,989 nSLOC | 1f6dd11 (`claude/amplestocks-rwa-token-xhtnn5`, working tree includes the uncommitted Phase 6 polish) | Foundry 1.8.1 · solc 0.8.30 · Uniswap v4 | 07/09/26

---

## 1. Protocol Overview

**What it does:** AMPS is a fixed-balance ERC-20 share of a vault that owns every position in 32 Uniswap v4 pools (AMPS/WETH, AMPS/USDG and 30 AMPS/tokenized-stock spokes) behind one hook; the share is floored by permissionless pro-rata redemption at NAV − 1 % and free-floats above it.

- **Users**: traders (swap AMPS against WETH/USDG/stocks through the router), bonders (deposit a registered Stock Token for discounted, 12 h-vested AMPS), holders (redeem pro-rata; stake into xAMPS), keepers (bountied `compound` / `rollout` / `deployBonded`).
- **Core flow**: every AMPS sell pays a 1–6 % fee in AMPS to the protocol-owned liquidity; at `compound` that fee is split creator → stakers → burn → re-laddered as asks, so volume either retires supply or returns as backing.
- **Key mechanism**: static ask/bid ladders of one-sided range orders on a canonical doubling grid, never re-centred; NAV numerator valued at the previous checkpoint's reference price; a six-layer oracle gate (watchdog, 24/5 calendar, freshness, corporate action, divergence, reference integrity) that reprices rather than pauses.
- **Token model**: `Amps` (18-dec share, vault-only mint/burn, `currency0` everywhere), `xAMPS` (ERC-4626 over AMPS fed by streamed sell fees), Stock Tokens / WETH / USDG as counter assets and bond collateral, USDG in a segregated `BountyPot`.
- **Admin model**: Safe → OZ `TimelockController` (48 h / 7 d / 14 d by convention, one `minDelay` on-chain) for every parameter and pointer; a Guardian Safe with disable-only, self-expiring freezes and a predicate-gated `emergencyMigrate`; every parameter inside a hard band; `redeemProRata` and `claim` structurally ungated.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Share token | Amps | 30 | ERC-20 + permit; vault-only mint/burn/setVault |
| Vault & placement | AmpsVault, VaultNavLib, VaultPlacementLib, VaultRedeemLib, VaultRolloutLib | 2,637 | Custody, NAV/reference checkpoint, genesis, redemption, ladder placement, compound, rollout, migration (four `DELEGATECALL` libraries share the vault's storage) |
| Valuers | LadderPositionValuer, ZeroPositionValuer | 138 | Decompose ladder positions at the reference sqrt price for the NAV numerator |
| Hook | AmpsHook, HookStateLib | 903 | One `0x38C0` hook for all pools: directional dynamic fee, rotation credit, truncated TWAP ring, rail |
| Core libraries | PriceLib, LadderLib, TruncatedOracleLib, PoolStateLib | 765 | Decimal/tick conversions, ladder geometry, per-block-capped oracle, MIT `extsload` reader of v4 state |
| Bonds | AmpsBonds, AmpsBondsLens, BondPolicy | 921 | Sole post-genesis issuance: collateral custody shell, capacity, linear vesting; pure pricing law |
| Policies | LadderPolicy, FeePolicy, RolloutPolicy | 379 | Pure, pointer-upgradeable proposers for ladder shape, swap fee and rollout size |
| Oracle gate | OracleGate, FeedRegistry, GatePriceMath, StreamsSchemaLib | 1,248 | Layers A–F gate, Chainlink freshness/jump confirmation, calendar, guardian freezes |
| Registry | PoolRegistry, PoolRegistryLens | 562 | Pool allowlist, constituent lifecycle, index weights, inclusion record |
| Staking & keeper | AmpsStaking, BountyPot | 304 | ERC-4626 xAMPS with a 24 h reward stream; segregated USDG bounty pot with caps |
| Periphery | AmpsQuoter, QuoterSwapLib | 674 | Revert-free read surface with bounded staticcalls and a tick-walk simulator |
| Shared types | Types, Constants, Errors | 428 | Structs/enums, every hard band and default, custom errors |

Interfaces (`src/interfaces/*`, 887 nSLOC) and vendored libraries (`lib/`) are out of scope. `test/mocks/*` are not protocol code.

### Backwards-Compatibility and Unreferenced Code

- `ZeroPositionValuer` — the Phase 2 stub valuer (every pool worth zero). Superseded by `LadderPositionValuer`; no caller in `src/` or `script/`, kept as the documented pre-Phase-3 pointer target and a test fixture. Not live functionality once the deploy pipeline wires the ladder valuer.
- `StreamsSchemaLib` — forward-looking groundwork for a v2 `StreamsRelay` ("Nothing wires this yet", `StreamsSchemaLib.sol:11`); no caller in `src/`.
- `AmpsVault._requireWiringOpen()` (`AmpsVault.sol:1470`) and `VaultPlacementLib._setWord()` (`VaultPlacementLib.sol:1269`) — private helpers with no callers (the set-once check lives in `VaultNavLib.setPointer`; the rollout library has its own used copy of `_setWord`). Dead code, not active paths.

### How It Fits Together

The core trick: AMPS is never minted to defend a price and never priced by the vault — the vault only ever *sells* protocol-owned AMPS through static ask ladders at or above NAV and *buys* it back through the bids those sales left behind, so every fill and every fee either raises the numerator or lowers the denominator of `NAV/share = A / totalSupply`.

### Swap through the hook

```
Router.swap(key, params)
└─ PoolManager.swap()
   ├─ AmpsHook.beforeSwap()                       ← reads the pool's packed CONFIG/DYNAMIC/ARMED words, no gate call
   │  ├─ base = zeroForOne ? ampsFeeBps : buyFeeBps[class]
   │  ├─ credit = tload(ROTATION_CREDIT); blend base over min(amountIn, credit)   *transient, same tx only*
   │  ├─ FeePolicy.quoteFee() (bounded staticcall) → dyn = f_vol + f_dev + f_session + surge + capture, clamped
   │  └─ deviation-increasing and beyond outerRail? → revert BeyondRail   *the only swap revert*
   ├─ PoolManager executes at fee | OVERRIDE_FEE_FLAG                     *fee accrues to the vault's positions*
   └─ AmpsHook.afterSwap()
      ├─ TruncatedOracleLib.write(): tick clamped to ±maxTickMovePerBlock, head accumulator exact, ring commit every 115 s
      ├─ buy? tstore(ROTATION_CREDIT += delta.amount0())                  *credit = AMPS actually received*
      ├─ every gateCacheSeconds: OracleGate.snapshotByPool() / FeePolicy bands / IStockToken.uiMultiplier() (all bounded staticcalls) → cached fairTick, bands, dynCap, session
      └─ post-swap deviation beyond rail and increasing? → revert BeyondRail
```

### Bond

```
AmpsBonds.bond(marketId, amountIn, minAmpsOut, to)
├─ OracleGate.checkBond(constituentId)            ← refuses only DIVERGED / SCHEDULED_FREEZE; stale feed ⇒ haircut
├─ roll epoch / day counters
├─ AmpsVault.depositBonded(marketId, collateral, bonder, amountIn)
│  ├─ _registerAsset(collateral); _checkpoint()   *NAV re-read in this block, before pricing*
│  └─ PoolManager.unlock(ACTION_SETTLE) → VaultRedeemLib.settleFrom(): sync → transferFrom(bonder → PoolManager) → settle → mint claim
├─ _price(): m = AmpsHook.twapTick30m(spoke) · P_i = FeedRegistry.latestAnswer · BondPolicy.quote()
│  └─ q = min(m / (1 − d), P_i(1 − h_session) / (nav(1 + minAccretion)))   *shell re-derives the floor and reverts if the policy exceeds it*
├─ capacity clamp: ampsOut = min(priced, epochLeft, dailyLeft); require ampsOut ≥ minAmpsOut
└─ _issue(): AmpsVault.mintVesting(AmpsBonds, ampsOut) → Amps.mint   *totalSupply rises now; position vests linearly over vestSeconds*
```

### Compound (the flywheel)

```
AmpsVault.compound(poolId)                          ← permissionless, bountied, gate GREEN/REF_DIVERGED
└─ VaultPlacementLib.compound()
   ├─ gauntlet: cooldown 60 s · |tick − fairTick| ≤ 800 · OracleGate.checkPlacement()
   ├─ PoolManager.unlock(ACTION_COMPOUND): modifyLiquidity(0) on every record → fees to claims
   ├─ _burnback(): cells whose upper bound the high-water tick crossed → liquidity 0, AMPS burned   *never re-placed*
   ├─ _split(ampsFees): creator (100 bp → 0 over 30 d) → stakers (stakerBps, streamed 24 h) → burn (burnBps) → relaid
   ├─ _placeLadder(relaid, above): asks on the grid above the current tick at LadderPolicy weights
   ├─ AmpsHook.resetHighWater() / armSurge()
   ├─ payBounty(): BountyPot.pay(keeper, measured work value, EIP-150-corrected gas)
   └─ AmpsVault._afterPlacement(): _checkpoint(); require navAfter ≥ navBefore·(1 − 2 bp); _sweepClean()
```

### Redeem

```
AmpsVault.redeemProRata(shares, to)                 ← no gate, no oracle, no guardian, no pointer read
├─ supply = Amps.totalSupply(); Amps.burn(msg.sender, shares)        *effects first*
├─ PoolManager.unlock(ACTION_UNWIND) → VaultRedeemLib.unwind(): every record −floor(L·shares/supply); principal → claims, fees stay
├─ VaultRedeemLib.redemption(): payout_i = floor(b_i·shares/supply)·(1 − redeemFeeBps); inventoryBurned = floor(inv·shares/supply) + releasedAmps
├─ PoolManager.unlock(ACTION_PAYOUT) → burn claims / take → to; idle ERC-20 → to
└─ Amps.burn(vault, inventoryBurned)                                 *supply falls by more than shares*
```

---

## 2. Threat & Trust Model

> **Bullet brevity rule:** one tight sentence per bullet; the `file:line` carries the evidence.

### Protocol Threat Profile

> Protocol classified as: **Yield Vault / NAV-backed asset manager** with **AMM/DEX (Uniswap v4 hook)**, **Bonding/issuance** and **Staking/rewards** characteristics

The vault owns every pool position and defines the share price as `A / totalSupply` with a pro-rata exit (vault signals: `redeemProRata`, `navPerShare`, `VIRTUAL_SHARES`, position valuer); the hook is a fee-only v4 hook with dynamic fees, TWAP observations and a rail (AMM signals); `AmpsBonds` is an Olympus-shaped discounted issuance with capacity and vesting; `AmpsStaking` is an ERC-4626 reward vault. Oracle dependence (Chainlink 24/5 equity feeds, issuer-controlled Stock Tokens) cuts across all four.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Timelock (Safe 3/5 proposer, open executor) | Trusted (one on-chain `minDelay`; 48 h / 7 d / 14 d classes are signing policy) | 60 admin entry points: every fee/bond/ladder/rollout/oracle parameter inside a hard band; **re-point `positionValuer`, `oracleGate`, `feedRegistry`, `marketReference`, `ladderPolicy`, `rolloutPolicy`, `BondPolicy`, `FeePolicy`** (no band, changes NAV inputs); constituent lifecycle; `sweep` the bounty pot; register the standby vault. Cannot mint, cannot touch redemption or claims, cannot move liquidity. |
| Guardian (Safe 2/4) | Bounded (disable-only, ≤ 7 d auto-expiry; `emergencyMigrate` needs the on-chain denylist predicate and a pre-registered standby) | Freeze one constituent or the protocol: closes placements, compounds and bonds, never swaps, redemption or claims. Triggers full evacuation to the standby — instant, no delay, all claims incl. AMPS. |
| AmpsVault | Trusted (immutable; sole `IUnlockCallback`, sole minter/burner) | Owns every position, mints only for bonds, burns on redeem/compound, pays bounties, notifies staking, hands `onlyVault` roles to a standby on migration. |
| PoolRegistry | Trusted (immutable, timelock-driven) | Opens pools through the vault, opens/closes bond markets atomically, withdraws retired bids; holds no funds. |
| AmpsBonds | Trusted (immutable code, governed state) | Only address that can `depositBonded`/`mintVesting`; holds vesting AMPS; `claim` is ungated. |
| Keeper | Bounded (permissionless, paid ≤ tip + 2 % of measured work, ≤ 3× gas, ≤ $25/day, ≥ $1 work) | Chooses which pool/constituent to `compound`/`rollout`/`deployBonded` and when (60 s cooldown per pool). |
| Creator | Bounded (receives ≤ 1 pt of the sell fee, decaying to 0 at day 30) | Reassigns itself. |
| Bonder / Trader / Holder / Staker | Untrusted | `bond`, swaps through the hook, `redeemProRata`, ERC-4626 deposit/withdraw. |
| Stock Token issuer (beacon admin, codeless key) | External, unbounded | Denylist any address incl. the PoolManager, pause, change `uiMultiplier`, upgrade the token; the protocol only detects and evacuates. |
| Chainlink (equity feeds, 24/5) | External, bounded by freshness/jump rules | Feeds hold Friday's close all weekend; a bad round ≥ 10 % is held for confirmation. |
| Uniswap v4 PoolManager | External, immutable, trusted as ground truth | Custodies every asset (claims and positions); read via `extsload`. |

**Adversary Ranking** (ordered by threat level for this protocol type, adjusted by git evidence):

1. **Stock Token issuer / beacon admin** — a codeless, un-timelocked key that can denylist or pause the only custody address and rewrite the display multiplier the hook and gate probe.
2. **Governance proposer (timelock)** — the pointer slots that feed NAV (`positionValuer`, `oracleGate`, `feedRegistry`, `marketReference`) are not banded and the on-chain delay is one `minDelay`.
3. **Swap-flow manipulator (MEV, hub pumper, TWAP pusher)** — the hub TWAP is `P_mkt` for every fee wall, rail, bond quote and, rate-limited, for the reference every ask anchors on.
4. **Bonder / redeemer gaming issuance and exit arithmetic** — capacity, floor rounding and the inventory-burn path dependence (ruling U) all sit on user-chosen amounts and ordering.
5. **Keeper** — chooses the pool, the moment and the pool state a bountied placement runs against; bounded by the pot's caps but not by intent.
6. **Guardian** — disable-only, but `emergencyMigrate` is instant once the predicate holds.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Timelock → vault pointers** — `setPolicyPointer` (`AmpsVault.sol:1153-1158`) re-points six NAV/gate inputs with no band; the one on-chain delay is the timelock's `minDelay`, the 7-day class is policy. Worst instant action after the delay: a `positionValuer` that values positions at `slot0`, or a `marketReference` that reports a chosen TWAP. *Git signal: `IAmpsVault.sol` and `AmpsVault.sol` are the two most-modified files (4 each).*
- **Vault → gate (fail-open)** — `_requireGate` (`AmpsVault.sol:1424-1441`) treats a reverting or zero gate as absent and skips the guardian-freeze read in the same `catch`; a bricked gate can never lock governance out, and can never lock anything else either.
- **Guardian → everything gated** — `freezeProtocol` (`OracleGate.sol:636`) closes placements/compounds/bonds for ≤ 7 d without delay; `emergencyMigrate` (`AmpsVault.sol:1186`) moves every claim to the standby instantly once `migrationPredicate` (`VaultNavLib.sol:250-284`) holds; neither touches `redeemProRata` or `claim`.
- **Registry ↔ bonds ↔ vault** — the registry is the only caller of `initializePool`/`withdrawRetiredBids` and a second accepted caller of `addCollateral`/`setMarketOpen` (`AmpsBonds.sol:1168-1171`); the bonds shell is the only caller of `depositBonded`/`mintVesting` (`AmpsVault.sol:851,888`).
- **Vault → linked libraries** — four libraries reached by `DELEGATECALL` read and write vault storage by literal slot numbers (`VaultPlacementLib.sol` `SLOT_*`, `VaultNavLib.sol:319-321`); the layout contract between them is enforced by tests, not code.
- **Hook → PoolManager** — `onlyPoolManager` on every callback (OZ `BaseHook`), `sender == vault` on initialise and add-liquidity (`AmpsHook.sol:232,297`); the hook never custodies and never reverts a swap except at the rail.
- **Protocol → issuer** — every probe into a Stock Token is a gas-capped raw `staticcall` with "unknown ⇒ not paused / no change" defaults (`OracleGate.sol:1033-1047`, `AmpsHook.sol:846`); the denylist predicate is the only issuer signal that moves funds.

### Key Attack Surfaces

- **Redemption path dependence** &nbsp;&#91;[I-30](invariants.md#i-30), [I-31](invariants.md#i-31), [E-3](invariants.md#e-3)&#93; — `VaultRedeemLib.redemption:356-406` burns `floor(inventory·shares/T) + releasedAmps` per call, so `T` falls by more than `shares` and the next slice's `shares/T` is larger; ruling U in the state model is still open. Worth tracing the optimal slicing against the 1 % fee and gas, and what the two candidate fixes do to `I-30`.

- **Un-banded NAV input pointers** &nbsp;&#91;[I-29](invariants.md#i-29), [I-3](invariants.md#i-3), [X-7](invariants.md#x-7)&#93; — `VaultNavLib.setPointer:290-322` lets a proposal replace `positionValuer`, `oracleGate`, `feedRegistry` and `marketReference` with any address, and the NatSpec's "exactly once more" for `marketReference` (`AmpsVault.sol:1149-1151`) has no latch. Worth checking what a hostile or buggy valuer/reference does to `_checkpoint` and hence to every bond floor and ask anchor in the window before governance notices.

- **Fail-open gate reads in the vault** &nbsp;&#91;[X-3](invariants.md#x-3), [G-11](invariants.md#g-11), [G-12](invariants.md#g-12)&#93; — `AmpsVault._requireGate:1424-1441` returns on a reverting `state(0)` before reading `protocolFreezeUntil`, and `OracleGate.state` itself degrades on every failed bounded read. Worth confirming which gate failure modes (out-of-gas from a large calendar, a replaced pointer, a reverting registry) silently turn a guardian freeze or a `SCHEDULED_FREEZE` into GREEN for placements and bonds.

- **Hook decisions on a cached gate view** &nbsp;&#91;[X-6](invariants.md#x-6), [G-40](invariants.md#g-40), [I-18](invariants.md#i-18)&#93; — `_beforeSwap:307-345` measures the rail and bands against `_dyn[id]` refreshed at most once per `gateCacheSeconds` in `_afterSwap:390-393` and forced only by `armSurge`; a quiet spoke can carry a `fairTick` up to `GATE_CACHE_MAX_AGE` old. Worth tracing the first swaps after a Chainlink move, a session change and an `effectiveAt` flip, and the "conservative substitute" path once the cache ages out.

- **Two prices, two speeds** &nbsp;&#91;[I-5](invariants.md#i-5), [I-19](invariants.md#i-19), [E-5](invariants.md#e-5)&#93; — `P_mkt` (hub truncated TWAP, `VaultNavLib.marketPrice:147`) drives fees, rails and bond quotes within one window while `P_ref` (`referencePrice:206-240`) chases it upward at ≤ 10 %/h and drops instantly; the numerator is valued at the *previous* `P_ref` (`AmpsVault.sol:1358` vs `1375`). Worth checking the hub-pump-then-bond and hub-dump-then-redeem sequences across one TWAP window and one checkpoint interval, including the `REF_DIVERGED` fallback to NAV.

- **Bond floor on a held Chainlink answer** &nbsp;&#91;[E-1](invariants.md#e-1), [I-8](invariants.md#i-8), [X-2](invariants.md#x-2)&#93; — `BondPolicy.qFloorX18:121-132` prices the floor off `FeedRegistry.latestAnswer` (Friday's close all weekend) minus `h_session`, while `m` is the live 24/7 spoke TWAP (`AmpsBonds._price:457-480`); capacity is a share of the *live* supply (`_capacity:1013-1035`) and a registry that cannot answer prices `deficit = 0`. Worth checking the Monday-gap bound at `h_session = 300 bp`, the `k_w` deficit term against `I-25`, and the accepted-answer jump hold (`I-28`) interacting with a real gap.

- **Placement gauntlet asymmetries** &nbsp;&#91;[I-13](invariants.md#i-13), [I-14](invariants.md#i-14), [I-15](invariants.md#i-15), [I-16](invariants.md#i-16)&#93; — `VaultPlacementLib._executePlace:543-603` opens cells under `strictBudget` only from `place`; bountied merges `continue` at 576, `_writeRecords:731-790` merges by cell index, `_burnback:860-891` zeroes a record and flips `above` on the high-water rule, and `subLiveCells` saturates at zero. Worth tracing record/cell bookkeeping across merge → burnback → unwind → harvest for the same cell, and what a bid cell converted from a filled ask looks like to `LadderPositionValuer.amountsOf`.

- **Keeper-chosen state for bountied jobs** &nbsp;&#91;[I-11](invariants.md#i-11), [I-22](invariants.md#i-22), [X-8](invariants.md#x-8), [E-2](invariants.md#e-2)&#93; — `compound`/`rollout`/`deployBonded` are permissionless with a 60 s per-pool cooldown (G-24) and a 2 bp bleed allowance each (G-13); `payBounty:1102-1122` reports a work value the vault measures at feed prices and a gas figure it corrects itself. Worth checking the cheapest legal grind (tiny fee balances, 32 pools, one keeper) against `chost`, the daily ceiling and cumulative bleed, and whether a keeper can time `compound` around a pending `armSurge`.

- **Emergency migration surface** &nbsp;&#91;[G-16](invariants.md#g-16), [G-17](invariants.md#g-17), [G-18](invariants.md#g-18), [G-14](invariants.md#g-14), [X-11](invariants.md#x-11)&#93; — `emergencyMigrate:1186-1241` runs `ACTION_UNWIND` over every pool, `evacuate:332-350` transfers every claim including AMPS, then hands four `onlyVault` roles to a standby whose layout must match the libraries' slot constants; the predicate accepts two failed 1-wei self-transfer probes. Worth tracing what a partially-denylisted set (one token blocked at the PoolManager) does inside the single `unlock`, and how the standby resumes ladders, checkpoints and the `POOL_KEYS_SLOT` list it never received.

- **Library slot coupling and raw `sstore`** &nbsp;&#91;[X-11](invariants.md#x-11)&#93; — `VaultRolloutLib._setWord:472`, `VaultNavLib.setPointer:319-321` and the `SLOT_*` constants in `VaultPlacementLib` write vault storage by number; `VaultPlacementLib._setWord:1269` is an unreferenced copy. Worth confirming the storage-layout tests cover every constant and that no library reads a packed word with a stale bit layout after the Phase 6 field additions.

- **Rotation credit across pools and swap kinds** &nbsp;&#91;[I-17](invariants.md#i-17)&#93; — `_credit:427-434` adds `delta.amount0()` on any buy in any pool; `_beforeSwap:319-336` spends it on exact-input sells only and blends at the *current* pool's buy fee. Worth checking a buy in the cheapest-fee spoke followed by a sell in an entry pool, exact-output sells, and multi-hop paths where the same transaction re-enters `beforeSwap` before `afterSwap` credited the first hop.

- **Index weight vector drifts between proposals** &nbsp;&#91;[I-25](invariants.md#i-25), [I-23](invariants.md#i-23)&#93; — only `setIndexWeights:445-470` checks `Σ == BPS`; `addConstituent:283-297`, `reconfigureConstituent:397` and every retire/reinstate change `n` or a weight without it. Worth tracing what `RolloutPolicy.propose:57-86` and `BondPolicy`'s `k_w·deficit` compute from an un-normalised vector, and whether `currentWeightBps` can make a deficit read as 100 %.

- **Corporate-action detection defaults** &nbsp;&#91;[G-45](invariants.md#g-45), [X-6](invariants.md#x-6)&#93; — `OracleGate._corporateAction:1024-1047` reads `oraclePaused`/`effectiveAt`/`newUIMultiplier`/`uiMultiplier` through gas-capped raw calls with "unknown ⇒ not paused" and `AmpsHook._detectMultiplierStep:768-800` arms a capture fee for steps ≤ 2 % and `caArmed` above. Worth checking a token whose probe reverts exactly during a split window, the `DIVIDEND_STEP_BPS_MAX` boundary, and how `caArmed` clears (`_clearCorporateAction:814-825`).

- **Reward stream re-timing** &nbsp;&#91;[I-21](invariants.md#i-21), [X-9](invariants.md#x-9)&#93; — `notifyReward:218-236` folds the unreleased remainder into a fresh `rewardStreamSeconds` window on every compound, so a frequent compounder keeps rewards perpetually mostly unreleased while `totalAssets` nets them out. Worth checking share-price behaviour for depositors around dense compound bursts and the `_decimalsOffset = 3` inflation bound against a first deposit of dust.

- **Truncated-oracle ring after the ruling V rework** &nbsp;&#91;[I-19](invariants.md#i-19), [G-43](invariants.md#g-43)&#93; — `TruncatedOracleLib.write:238-309` keeps an exact head accumulator and commits a ring slot only every `MIN_INSERT_INTERVAL` (115 s); `consult` floors, `_interpolate` ceils, `observationCoverage` decides `WATCHDOG` for layer F. Worth checking the first 30 minutes after `initialize`, a pool idle longer than the ring covers, and the `WindowNotCovered` path the quoter and gate treat as "no reference".

### Protocol-Type Concerns

**As a Yield Vault / NAV-backed share:**
- `VaultNavLib.totalAssetsUsd18:80-116` reverts on any registered asset with a zero feed answer (G-23) — every gated path then refuses until the feed returns while `redeemProRata` continues at the last checkpoint-free arithmetic; worth confirming the intended behaviour for a delisted constituent whose feed is retired.
- `PriceLib` rounds every conversion in the protocol's favour (`PriceLib.sol:100-270`: sqrt price up, USD values down, counter amounts up); `LadderLib.split:178-190` gives the last bucket the remainder. Worth checking the asymmetric rounding does not accumulate against redeemers across 32 pools × 24 cells.
- `VIRTUAL_SHARES = 1e3` with `+1` on the numerator (`AmpsVault.sol:1360-1362`) is a divide-by-zero guard, not an inflation defence; the genesis latch and no-NAV-mint are what close the first-depositor vector.

**As an AMM / v4 hook:**
- The hook's fee is applied by the PoolManager on the *input* currency, so sell fees accrue in AMPS and buy fees in the counter (`AmpsHook.sol:307-345`); the split and burn only happen at `compound`, so uncollected fees sit in positions and are excluded from NAV (`PoolStateLib.feesOwed:477`, valuer excludes fees).
- Fees accrued while a pool has no in-range position are stranded by design (state model ruling 13); worth measuring how often an entry pool trades above its top ask.
- `QuoterSwapLib` re-implements v4's swap step for quotes (`QuoterSwapLib.sol:90-184`); a divergence from the PoolManager's arithmetic mis-quotes but cannot move funds.

**As a bonding / issuance mechanism:**
- Capacity is computed against `Amps.totalSupply()` at each bond (`AmpsBonds._capacity:1013-1035`), so issuance compounds within an epoch as supply grows; the vesting mint counts toward the next bond's cap base immediately.
- `_fillX18:1000-1004` rounds fill *up* and a zero-capacity market reads as full, narrowing the discount in the protocol's favour; `kFillX18 × fill` is subtracted with rounding up (`BondPolicy.sol:154`).

**As a staking / rewards vault:**
- `AmpsStaking.totalAssets:130-132` is `balanceOf − unreleased`; a direct AMPS donation raises the share price for everyone (documented), and `notifyReward` requires the balance to already cover the pending stream (G-36).

### Temporal Risk Profile

**Deployment & Initialization:**
- `genesis()` and `initializePool()` are gate-checked, and the gate's layer-F reads the hub TWAP, so the `oracleGate` pointer must stay unset until the hub has 30 minutes of history (`docs/phase2-state-model.md` §9.1); the runbook, not the code, enforces the order — worth checking what a proposal that sets the gate first can and cannot undo.
- `AmpsVault.place` is timelock-or-registry only (`AmpsVault.sol:973`) and the check is in the body, not a modifier; the broadcast test caught a proposal built as if it were permissionless.
- The four custody pointers freeze at `genesis` (G-22); anything wired wrong before that point (a mock bonds shell, a test staking contract) becomes permanent — worth confirming the deploy script's pre-genesis verification covers all four.
- Genesis mints 5,000 AMPS against $5,000 of seed; every launch parameter is a `Constants` default and the ask ladder's top bucket alone can raise ~$540k (state model ruling 9). Early-window liquidity is thin by design.

**Market Stress:**
- A weekend gap larger than `h_session` (300 bp) on a bonded stock, or a sequencer stall longer than `graceSeconds` (1 h) with fewer than `elapsed/gapSeconds` blocks, moves the gate to `DEGRADED`/`WATCHDOG`: placements and compounds stop, bonds continue at the haircut (`OracleGate.sol:817-830, 936-950`), swaps and redemption never stop.
- Under `DIVERGED` a spoke keeps trading at `DYN_CAP_DEGRADED_BPS` with bonds closed for that name only; under `REF_DIVERGED` every anchor falls to NAV (`VaultNavLib.referencePrice:220`). Worth checking a scenario where the WETH cross-rate feed is the one that is wrong.

**Deprecation:**
- `ZeroPositionValuer` remains deployable as a valid `positionValuer` target: a proposal that re-points to it drops every position from NAV and makes the floor equal to idle claims only — legal governance action, large blast radius.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Uniswap v4 PoolManager** — via `AmpsVault.unlockCallback` / `VaultPlacementLib` / `VaultRedeemLib` (`unlock`, `modifyLiquidity`, `sync/settle`, `mint/burn/take`), `PoolStateLib` (`extsload`/`exttload`)
> - Assumes: v4-core 1.0.2 storage layout (`POOLS_SLOT = 6`, offsets in `PoolStateLib.sol:76-98`), ERC-6909 claims, exact deltas, `Foundry ≥1.8` transient semantics in tests
> - Validates: `msg.sender == PoolManager` on the callback, `settled` amounts, `opened == poolId`, defensive `currencyDelta` reads
> - Mutability: Immutable
> - On failure: placements/redemption revert atomically; quoter and valuer degrade to zeros

> **Chainlink equity feeds (24/5, Standard proxies only)** — via `FeedRegistry._probe` (`latestRoundData`, gas-capped `try`), read by `OracleGate`, `VaultNavLib`, `AmpsBonds`, `PoolRegistry` (direct, governance paths)
> - Assumes: 8 decimals, RDD heartbeat/threshold, Friday close held all weekend, no SVR proxy
> - Validates: `answer > 0`, `updatedAt != 0`, per-feed min/max, session-scaled `maxAge`, ≥ 10 % jump held for confirmation, `isStandardProxy` allowlist
> - Mutability: Chainlink can deprecate a feed; the allowlist and feed pointer are timelock-governed
> - On failure: gate `DEGRADED` (placements stop, bonds haircut), NAV read reverts on a zero answer (G-23), redemption unaffected

> **Stock Tokens (Jersey-issued, beacon-proxied ERC-20s with `uiMultiplier`, denylist, pause)** — via bounded `staticcall`s in `OracleGate.sol:1033-1041`, `AmpsHook.sol:846`, `VaultNavLib.sol:250-284,472`, and plain `transferFrom`/`transfer` through the PoolManager
> - Assumes: plain ERC-20 transfer semantics (no fee, no rebase, 18 decimals), raw balances never change on a split, `isBlocked(address)` exists
> - Validates: settled amount equals `amountIn` (X-1), probe return lengths, gas caps, `uiMultiplier` change detection
> - Mutability: Upgradeable by a codeless admin key with no timelock; `ACCESS_CONTROLLED_REGISTRY` semantics unknown (Phase 0 go/no-go)
> - On failure: a blocked PoolManager freezes that asset for everyone; `emergencyMigrate` is the only answer, and it needs the predicate to see the block

> **WETH9 / USDG** — via the entry pools and bond `ENTRY` class (closed at launch)
> - Assumes: 18 / 6 decimals, no fee-on-transfer, USDG never blacklists the PoolManager
> - Validates: decimals through `PriceLib` bands; nothing about blacklists
> - Mutability: USDG is an upgradeable stable
> - On failure: same custody exposure as a Stock Token, without a denylist probe

> **OpenZeppelin 5.x (`ERC20Permit`, `ERC4626`, `SafeERC20`, `TimelockController`, `VestingWallet`) and OZ `uniswap-hooks` `BaseHook`** — via inheritance
> - Assumes: audited upstream behaviour; `uniswap-hooks` is labelled experimental upstream
> - Validates: pinned submodules; licence gate in CI
> - Mutability: Submodule pins
> - On failure: n/a at runtime

**Token Assumptions** *(unvalidated only)*:
- Stock Tokens / WETH / USDG: assumes no fee-on-transfer and no rebasing for pool *fees and positions* — a settled deposit is checked (X-1) but a token whose balance moves after settlement would drift NAV against the PoolManager's accounting.
- USDG: assumes the PoolManager and the BountyPot are never blacklisted — impact if violated: the settlement hub and keeper economics stop; no probe or migration path covers it.
- Stock Tokens: assumes the display multiplier never applies to raw balances — impact if violated: every ladder and NAV reads the wrong quantity (the design's central Phase 0 assumption).

**Shared State Exposure**:
- The 32 hooked pools are POL-only, so no other protocol holds positions in them; but `P_mkt` is a *public* TWAP that any integrator may read as an AMPS price, and the entry pools sit next to the chain's deepest ETH/USDG pools, which the WETH cross-check (`OracleGate._referenceIntegrity:1099-1111`) implicitly depends on.
- The same Chainlink equity feeds serve every stock-token venue on the chain; a feed incident is a chain-wide event, not a protocol one.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **53 Enforced Guards** (`G-1` … `G-53`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **33 Single-Contract Invariants** (`I-1` … `I-33`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **11 Cross-Contract Invariants** (`X-1` … `X-11`) — caller/callee pairs that cross scope boundaries
> - **7 Economic Invariants** (`E-1` … `E-7`) — higher-order properties deriving from `I-N` + `X-N`
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The **On-chain=No** blocks (`I-25`, `I-29`, `I-31`, `X-3`, `X-6`, `X-11`, `E-2`, `E-3`) are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` (monorepo), `contracts/README.md` (toolchain, gates, layout) |
| NatSpec | ~4,450 tags / ~7,500 doc lines over 8,989 nSLOC | Every contract, error, constant and public function annotated; `@inheritdoc` throughout; rounding directions and invariant IDs stated inline |
| Spec/Whitepaper | Present | `docs/phase2-state-model.md` (612 lines) and `docs/phase3-state-model.md` (1,023 lines): call graphs, invariants I3–I39, rulings A–AB incl. open ruling U; plus the implementation plan. Claims tagged `(per spec)` in this report are from those files |
| Inline Comments | Thorough | Design rationale ("why a contract and not a library", fail-open reasoning, EIP-170 trade-offs) is written next to the code; one NatSpec/code mismatch found (`marketReference` set-once claim, `I-29`) |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 111 (incl. 26 mocks, 2 utils, 3 script tests) | File scan (always reliable) |
| Test functions | 1,131 | File scan (always reliable) |
| Line coverage | Unavailable — the in-report `forge coverage` run was cancelled after 25 min to keep the concurrent CI mirror inside the box's 16 GB (two via-IR solc builds); the CI `coverage` job publishes lcov + summary per push | Coverage tool (requires compilation) |
| Branch coverage | Unavailable — same run; the plan's 100 % branch targets on `PriceLib`, `TruncatedOracleLib`, gate logic and bond pricing are asserted by the CI job, not verified here | Coverage tool (requires compilation) |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 903 functions / 38 files | broad — every contract and library incl. `GuardSymmetry`, selector gate, storage layout, hook address |
| Integration | 57 functions / 8 files | Phase 2/3 fixtures, flywheel, hub pump, corporate action, launch shape, gas |
| Attack | 39 functions / 12 files | named attacks: Arrakis-style flash bond, VTSwapHook round trip, rounding grind, JIT, first depositor, reentrant token, rotation-credit gaming, staking sandwich, TWAP-dump-then-bond, hub-pump-then-dump, creator wash, denylist drill |
| Script / broadcast | 23 functions + `test/script/broadcast.sh` (anvil, real timelock) | deploy pipeline 00–12 |
| Fork | 0 | none — blocked by the sandbox network policy (Phase 0 pending) |
| Stateless Fuzz | 130 | PriceLib, LadderLib, TruncatedOracleLib, policies, staking, bonds pricing |
| Stateful Fuzz (Foundry) | 36 invariant functions / 3 suites (`AmpsVault`, `Phase2`, `Phase3` with split handlers) | vault, bonds, hook, placement path |
| Stateful Fuzz (Medusa) | config present (`medusa.json`), reuses the Foundry handlers; no Medusa-specific properties | — |
| Stateful Fuzz (Echidna) | 0 | none |
| Formal Verification (Certora / Halmos / HEVM) | 0 | none |

### Gaps

- **No formal verification** on the money math (`PriceLib`, `LadderLib`, `VaultRedeemLib.redemption`, `BondPolicy`) — the highest-value gap for a protocol whose floor is an arithmetic promise.
- **No fork tests** against real Stock Token bytecode, the real PoolManager or real feeds; every issuer behaviour (denylist, `uiMultiplier`, pause) is exercised only through `MockStockToken`.
- **Medusa/Echidna** campaigns are configured but not yet run as a separate long-running property suite; the `fizz` step of Phase 6 is meant to add them.
- Gas suite covers the hook and a 32-pool redemption at the launch shape, not the 64-constituent bound (`MAX_LIVE_CELLS` decision still open).

---

## 6. Developer & Git History

> Repo shape: normal_dev — 34 commits over two days (2026-09-05 → 2026-09-06), 18 of them touching `contracts/src`, in phase-sized slices with a merge per phase.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Claude | 31 (18 on `contracts/src`) | +21,629 / −912 | 100 % |
| Camden | 3 (initial commit, 2 merges) | +0 / −0 | 0 % |

Single-developer dominance: every source line was authored by one agent-driven author; the second contributor's role is review and merge.

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 2 | Single-dev codebase with one merger |
| Merge commits | 2 of 34 (6 %) | PRs merged per phase; no line-level review comments visible in history |
| Repo age | 2026-09-05 → 2026-09-06 | 2 days — the entire protocol was written in one sprint |
| Recent source activity (30d) | 15 source commits (avg 1,373 lines each) | Active / late burst: everything is "recent" |
| Test co-change rate | 93 % (14 of 15 source-touching commits per the analyser; 17 of 18 counting interface-only commits) | Source commits almost always ship with tests — measures co-modification, NOT coverage. The one exception is `ff33d7e` (interfaces, types and constants) |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| `contracts/src/vault/AmpsVault.sol` | 4 | Highest churn and the custody core — prioritise review |
| `contracts/src/interfaces/IAmpsVault.sol` | 4 | Interface reshaped at every phase |
| `contracts/src/types/Types.sol` | 3 | Packed layouts changed three times |
| `contracts/src/types/Constants.sol` | 3 | Bands and defaults re-tuned (K_VOL, MAX_LIVE_CELLS) |
| `contracts/src/registry/PoolRegistry.sol` | 3 | Lifecycle + opened-price read added |
| `contracts/src/oracle/OracleGate.sol` | 3 | Hand-decoded reads (ruling AA) |
| `contracts/src/bonds/AmpsBonds.sol` | 3 | Same-block checkpoint reorder |
| `contracts/src/lib/TruncatedOracleLib.sol` | 2 | Ring rewrite (ruling V) |

### Security-Relevant Commits

**Score** = weighted sum of fix-like signals in a commit: message keywords, diff patterns (deletes code, changes `require`/`assert`, touches access control or accounting), and change shape. **10+ warrants a manual diff.**

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| a48281c | 2026-09-05 | Price bonds against a same-block checkpoint; add Phase 2 integration and invariant suites | 16 | involves oracle/pricing; adds runtime guards; spans 5 security domains — **the one real fix in history, manual diff warranted** |
| 5949464 | 2026-09-05 | Add Amps share token, Stock Token and oracle mocks, and the CREATE2 miner | 16 | tightens access control (+9); feature addition |
| 51614f0 | 2026-09-06 | Add AmpsHook, the hook miner and the real-hook gas baseline | 9 | adds runtime guards (+20); large change |
| d94f3db | 2026-09-06 | Add the Phase 3 declarations, PoolStateLib and LadderPositionValuer | 9 | spans 5 security domains; large change |
| aff7a1c | 2026-09-05 | Add AmpsVault core and VaultNavLib | 9 | changes token transfer + accounting logic |
| 77e9038 | 2026-09-05 | Add AmpsBonds, BondPolicy and AmpsBondsLens | 9 | changes token transfer + accounting logic |
| f58e1b2 | 2026-09-06 | Add the Phase 3 integration, attack and invariant suites | 8 | explicit security language (test-only commit) |
| aae2bbf | 2026-09-06 | Add AmpsQuoter and the OracleGate hook-state read | 7 | spans 5 security domains |
| c24d0d8 | 2026-09-06 | Add the vault placement path behind four linked libraries | 7 | very large change (>2,000 source lines) |
| 0d7e8df | 2026-09-06 | Add LadderPolicy, FeePolicy and RolloutPolicy | 6 | changes accounting logic |

All but `a48281c` are feature commits that score on size and domain spread rather than on fix signals. The second real fix, `5ab497e` "Keep TWAP coverage under active trading by rate-limiting ring insertion" (false `WATCHDOG` under real flow), scores below the table's threshold because its message carries no fix keyword.

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| oracle_price | 15 | `AmpsBonds.sol`, `AmpsHook.sol`, `OracleGate.sol` |
| state_machines | 14 | `AmpsBonds.sol`, `AmpsHook.sol`, `PoolRegistry.sol` |
| fund_flows | 13 | `AmpsBonds.sol`, `AmpsHook.sol`, `BountyPot.sol`, `AmpsVault.sol` |
| access_control | 10 | `AmpsVault.sol`, `OracleGate.sol`, `PoolRegistry.sol`, `BountyPot.sol` |
| signatures (auth handling) | 10 | `IAmpsVault.sol`, `OracleGate.sol`, `FeePolicy.sol` |

Every area was touched by most of the 15 source-touching commits — expected for a codebase built in one sprint; the oracle/pricing area leads, consistent with where both real fixes landed.

### Forked Dependencies

All three libraries are pinned git submodules, not internalised copies: `lib/openzeppelin-contracts` (OZ 5.x), `lib/uniswap-hooks` (OZ hooks, bundles v4-core / v4-periphery), `lib/hookmate` (no known upstream mapping in the analyser; 9 files, `^0.8.26`). The CI licence gate bans BUSL/AGPL/GPL headers from the dependency graph, which is why `PoolStateLib` re-implements `StateLibrary`.

### Technical Debt Markers

None: no `TODO` / `FIXME` / `HACK` / `XXX` in `contracts/src`.

### Security Observations

- **Single author** — 100 % of source lines from one author in two days; no independent human review recorded in history.
- **Phase-sized commits** — the largest source commits are 4,374 (`ff33d7e`), 2,973 (`c24d0d8`) and 2,215 (`7403717`) lines; unreviewable by diff.
- **Two real fixes already in history** — `a48281c` (bond priced on a stale checkpoint) and `5ab497e` (TWAP ring coverage): both are in the pricing/oracle path that the attack surfaces above centre on.
- **Vault interface reshaped every phase** — `IAmpsVault.sol` × 4, `Types.sol` × 3: consumers (keeper, indexer, quoter) were regenerated each time; worth checking ABI drift once more after the Phase 6 polish.
- **EIP-170 pressure shaped the design** — `AmpsVault` sits 271 B under the limit, which is why four `DELEGATECALL` libraries write its storage by slot number (`X-11`).
- **Uncommitted working tree** — the analysed tree carries the Phase 6 polish (bounty economics, event fields, hand-decoded gate reads) on top of `1f6dd11`; line references in this report are to the working tree.

### Cross-Reference Synthesis

- **`AmpsVault.sol` is #1 in churn AND the hub of five attack surfaces** (pointers, fail-open gate, redemption, migration, slot coupling) → highest-leverage review: `_checkpoint`, `_requireGate`, `redeemProRata`, `emergencyMigrate`, `setPolicyPointer`.
- **Both real fix commits sit in pricing/oracle code** (`a48281c`, `5ab497e`) + `OracleGate.sol` × 3 churn → the bond-floor and reference-price surfaces (`E-1`, `E-5`, `X-6`) are where regressions have already happened once.
- **Open ruling U + `I-31` On-chain=No** → the redemption path-dependence surface is a known, unresolved design decision, not a latent bug to discover; the auditor's value is quantifying it and reviewing the fix.
- **NatSpec/code mismatch on `marketReference`** (`I-29`) + un-banded pointer slots → documentation promises more than `setPointer` enforces; worth deciding whether the code or the doc is wrong.

---

## X-Ray Verdict

**HARDENED** — unit + stateless fuzz + Foundry invariant suites exist with a spec and thorough NatSpec, and access control is role-separated behind a timelock with an emergency freeze; no formal verification and no fork tests keep it below FORTIFIED.

**Structural facts:**
1. 8,989 nSLOC of protocol code across 12 subsystems and 32 files; no proxies, no upgradeable contracts, seven pointer-upgradeable pure/view policy and oracle contracts.
2. 110 entry points: 21 permissionless, 29 role-gated (vault / bonds / registry / PoolManager / guardian / creator), 60 timelock-only, every numeric one band-checked.
3. 1,131 test functions in 111 files: 130 stateless fuzz, 36 Foundry invariant functions, 39 named attack tests, 23 deploy-script tests plus an anvil broadcast rehearsal; 0 fork, 0 Echidna/Medusa properties, 0 formal verification.
4. One author wrote 100 % of the source in two days across 18 source commits with a 94 % test co-change rate; two merges, no line-level review in history.
5. 8 of 51 inferred invariants are not enforced on-chain, three of them by documented design (fail-open gate, cached hook view, slot coupling) and one by an open product decision (split redemption).
