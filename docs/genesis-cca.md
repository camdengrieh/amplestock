# Genesis through a Continuous Clearing Auction

**Status:** revision 7 of the plan, implemented. This document is the executable form of it: every
claim below is a line in `contracts/src`, `contracts/script` or `contracts/test`.

Amplestocks does not launch by having the founders put $5,000 into a vault and declare the share
price. It launches by **selling half of the supply at auction** and taking the price the market
paid. Two [Continuous Clearing Auctions](https://github.com/Uniswap/continuous-clearing-auction)
(Uniswap, MIT) run for 72 hours; whatever they clear at becomes `P0`, the launch reference price;
the proceeds become the vault's backing and the entry pools' bid ladders; and every one of the 32
pools is opened at `P0` rather than at a number chosen in advance.

---

## 1. The supply, and where every AMPS goes

`S0 = 20,000 AMPS`, minted exactly once, split three ways by `contracts/src/types/Constants.sol`.
The split is constants, not parameters: `AmpsVault.genesisMint` rejects any other allocation.

| Tranche | Constant | AMPS | Where it goes |
|---|---|---|---|
| Team | `TEAM_SHARES` | 1,000 (5%) | An OZ `VestingWallet`, 2-month linear, no cliff |
| Auction | `AUCTION_SHARES` | 10,000 (50%) | The `AmpsGenesis` adapter, then the two auctions |
| — USDG leg | `AUCTION_USDG_SHARES` | 5,000 | Sold for USDG |
| — ETH leg | `AUCTION_ETH_SHARES` | 5,000 | Sold for native ETH, wrapped to WETH9 at settlement |
| POL | `POL_SHARES` | 9,000 (45%) | Retained by the vault as ask inventory |

`TEAM_SHARES + AUCTION_SHARES + POL_SHARES == S0` by construction, which is why one equality per
tranche is the whole allocation check.

The POL tranche is placed by `11_GenesisPlacement`, all of it anchored at `P0`:

| Where | What | Cells |
|---|---|---|
| `AMPS/USDG`, `AMPS/WETH` | 3,150 AMPS of asks each (6,300 total), 10 doublings, tilt 1.25 | `m = 0..9` |
| `AMPS/USDG`, `AMPS/WETH` | the auction proceeds held in each pool's counter, 4 halvings | `m = -1..-4` |
| 30 spokes | 90 AMPS each (`spokeSeedBps` = 100 bp of the POL tranche; 2,700 total), 10 doublings | `m = 0..9` |

## 2. The floor, the raise and the launch NAV

The floor is **$1.00 per AMPS in each currency**, and it is computed by `AmpsGenesis`, never taken
from the proposal — a mis-scaled floor is a total loss for bidders, and it is the one parameter a
launch cannot take on trust:

```
floorUsdgQ96 = 1e6 * 2^96 / 1e18                 // USDG raw units per AMPS wei, Q96
floorEthQ96  = 2^96 * 1e18 / ethUsdX18           // wei per AMPS wei, Q96
```

At a full clear at the floor the auctions raise **$10,000**, so under the fully diluted accounting
of decision 14 (`T = Amps.totalSupply()`, inventory included):

```
NAV/share at launch = raised / S0 = $10,000 / 20,000 = $0.50
P0                  = $1.00
premium             = P0 / NAV - 1 = 100%
```

The premium is **disclosed, not smoothed**. It exists because the vault keeps 45% of the supply as
inventory that is backed by nothing until it sells: every ask that fills at or above `P0` raises
backing, so the premium shrinks as the ladder works. `AmpsVault.premiumX18()` reports it and the
dApp's Auction surface shows it. The alternative — circulating-supply NAV, which would put the
redemption floor at `P0` — is a change to decision 14 and to I6/I10/I23 and remains a user decision,
not something this implementation makes.

`AmpsVault.genesisPlace` floors `P_ref` at NAV/share (`_pRefX18 = max(p0X18, navPerShare)`) so that
I24 (`P_ref >= NAV`) holds from block one whatever a proposal passes. At the launch above the floor
does not bind: `$1.00 > $0.50`.

## 3. Two-step genesis in the vault

Revision 7 replaces `AmpsVault.genesis(GenesisParams)` with two calls behind two latches.

### `genesisMint(GenesisMintParams)` — `onlyTimelock`, once

```solidity
struct GenesisMintParams {
    address teamVestingWallet;
    address creator;
    address genesis;        // must equal the vault's set-once `genesis` pointer, and hold code
    uint256 teamShares;     // == Constants.TEAM_SHARES
    uint256 auctionShares;  // == Constants.AUCTION_SHARES
    uint256 polShares;      // == Constants.POL_SHARES
}
```

It mints and records the creator, and it does **nothing else**: no asset moves, no checkpoint is
written, `_initialized` stays false. It emits
`GenesisMinted(teamVestingWallet, creator, genesis, teamShares, auctionShares, polShares)`.

### The window between the two steps

This is the state the auction runs in, and it is the reason the call is split at all: the auction
cannot sell a supply that does not exist, and the vault must not price `S0` against an `A` of zero.

```
totalSupply == S0        A == 0        navPerShareX18 == 0        pRefX18 == 0
```

Everything that would price one against the other refuses with `NotInitialized`:
`checkpoint`, `touch`, `depositBonded`, `mintVesting`, `place` — **and `redeemProRata`**. That last
one is new in revision 7 and deliberate: without it a holder of the team's or the auction's AMPS
could burn shares against a vault holding nothing. The check reads slot 3 (a one-way latch) and no
gate, registry, valuer, price or pointer, so section 7's enumeration and its `vm.record` storage
proof are unchanged — `unit/GuardSymmetry.t.sol` still classifies `redeemProRata` as the structural
exemption, and still proves it touches no gated slot.

In practice nobody *can* redeem in that window anyway: the team's AMPS is inside a `VestingWallet`,
the auction tranche is inside the auctions, and no pool exists so no swap is possible. The latch is
what makes that structural rather than circumstantial.

### `genesisPlace(GenesisPlaceParams)` — the adapter **or** the timelock, once

```solidity
struct GenesisPlaceParams {
    uint256 p0X18;          // the clearing price, or 1e18 on the fallback path
    address[] tokens;       // WETH9 and USDG, never AMPS
    uint256[] amounts;      // pulled from msg.sender into ERC-6909 claims
    uint256 unsoldAmps;     // pulled from msg.sender into the vault's own inventory
}
```

In order: the registry's assets join the enumeration; each `amounts[i]` of `tokens[i]` is pulled
from `msg.sender` straight into the PoolManager through the existing `ACTION_SETTLE` unlock (the
seed leg, unchanged); `unsoldAmps` is pulled with a plain `transferFrom` into the vault's own
balance — **neither minted nor counted in `A`**, because every AMPS leg is valued at zero (I5) and
`sweepClean` walks the asset list, which never contains AMPS, so it stays idle inventory where the
ask ladders are laid out of it; `_genesisTimestamp` is stamped (the creator's decay clock starts at
**launch**, not at the mint, so the bidding window does not eat into it); `_initialized` and
`_wiringFrozen` close; a checkpoint runs; and only then is `_pRefX18` written to
`max(p0X18, navPerShare)`.

The reference is written **after** the checkpoint, not before. `_checkpoint` derives `P_ref` from
NAV and the hub TWAP, and at that instant there is no hub pool and no observation ring, so it would
resolve to NAV and bury `P0`. Two events come out: the `RefCheckpoint` the checkpoint itself emits,
and a second `RefCheckpoint(p0, pMkt, false, navFloored)` carrying the seeded value.

`Genesis(creator, S0, navPerShareX18, p0X18, raisedUsd18)` is the launch log. `raisedUsd18` is `A`
reconstructed from NAV/share and `T`, exact to the wei `navPerShare`'s own rounding drops.

Everything after this is the existing governed `place` path, unchanged.

### Where the code lives, and why

`AmpsVault` was at 23,493 B against the 24,576 B EIP-170 limit before revision 7. The two-step path
adds 204 B net, because both bodies live in `VaultNavLib` — already a linked library, so no new
`02_Libraries` entry, no `foundry.toml` change and no new deploy step:

* `VaultNavLib.genesisAllocate` — the tranche checks, the three mints, the `GenesisMinted` log;
* `VaultNavLib.genesisSettle` — the registry walk, the asset pull loop and the unsold-AMPS pull.

The two latches, the caller rules, the reference write and the `Genesis` log stay in `AmpsVault`,
where the storage layout of `docs/phase2-state-model.md` §1.1 is.

## 4. `AmpsGenesis` — the adapter

`contracts/src/genesis/AmpsGenesis.sol`. Immutable, ownerless, one-shot. Six immutables
(`vault, amps, factory, weth9, usdg, timelock`), one governed call, one permissionless call.

It is `fundsRecipient` **and** `tokensRecipient` of both auctions and the only auction-side caller
of `genesisPlace`. There is no admin, no upgrade path, no rescue function, and no way to change
where the money goes.

### `createAuctions(AuctionSpec usdgSpec, AuctionSpec ethSpec, uint256 ethUsdX18)` — `onlyTimelock`, once

Each leg is either its whole constant or disabled (`shares == 0`); a "half tranche" is not a launch
parameter. What the adapter validates, and a proposal therefore cannot get wrong:

* the tranche is on the adapter (`genesisMint` has run) and equals `AUCTION_SHARES`;
* the floor, which it computes rather than reads;
* `ethUsdX18` against the vault's `FeedRegistry` answer for WETH, inside the vault's
  `refDivergenceBps` — skipped entirely when no feed is readable, because this is a fat-finger guard
  and not an oracle dependency;
* `startBlock >= block.number`, `startBlock < endBlock <= claimBlock`;
* `auctionStepsData`: `SUM(mps x blocks) == 1e7` (exactly 100% of the tranche) over exactly
  `endBlock - startBlock` blocks. An under-issuing schedule strands the tranche inside the auction.

It then builds `AuctionParameters` with `tokensRecipient = fundsRecipient = address(this)`, deploys
each auction through the factory, funds it, and emits
`AuctionsCreated(usdgAuction, ethAuction, floorUsdgQ96, floorEthQ96, startBlock, endBlock)`.

**Single-auction mode**: with one leg disabled, that leg's tranche simply stays on the adapter and
is returned to the vault as unsold at settlement.

### `settle()` — permissionless, once, after every created leg's `endBlock`

1. `checkpoint()` each leg, so the end block is checkpointed and the clearing price is final;
2. `sweepCurrency()` on each **graduated** leg, `sweepUnsoldTokens()` on every leg;
3. wrap the whole native balance into WETH9;
4. read the three balances that actually arrived — the protocol fee is *measured*, never predicted;
5. derive `P0`;
6. approve the vault for exactly those balances and call `genesisPlace`;
7. assert the adapter is empty.

`P0` is the USDG leg's clearing price converted to 18-decimal USD per AMPS:

```
p0X18 = clearingQ96 * 1e36 / (2^96 * usdgUnit)          // USDG leg
p0X18 = clearingQ96 * ethUsdX18 / 2^96                  // ETH leg (both sides 18-decimal)
```

The USDG leg wins whenever it graduated, because it is the only one denominated in the unit `P_ref`
is quoted in and needs no oracle to become a price. When both graduated the two are compared: a gap
wider than the vault's `refDivergenceBps` emits `ClearingPricesDiverged(usdgP0X18, ethP0X18,
toleranceBps)` and the USDG price is used regardless. `ethUsdX18` is refreshed from the vault's feed
registry at settlement when that read succeeds and otherwise stays at the value recorded at
creation — the bidding window is 72 h long and the ETH leg's clearing price is quoted in ETH.

`Settled(p0X18, usdgRaised, ethRaised, unsoldAmps, usdgGraduated, ethGraduated)` is emitted whatever
the outcome.

**One escape hatch.** If the vault has *already* been opened when `settle()` runs — which can only happen if the
timelock ran the founders'-seed `genesisPlace` while these auctions were still live, a governance mistake rather
than a state the adapter can produce — `genesisPlace` would revert on its latch, and because `sweepCurrency` is
one-shot and `fundsRecipient`-only, a permanently reverting `settle()` would strand the whole raise inside the
auctions. So in that case the adapter forwards everything to the vault as plain balances instead: the vault's own
`sweepClean` folds the currency into backing at its next entry point and the AMPS stays as inventory, which is
where `genesisPlace` would have put them. Only the `P_ref` seeding is lost, and by then it is lost anyway.

### No graduation

If neither leg reaches its `requiredCurrencyRaised`, bidders refund in full **through the auctions
themselves** (`exitBid`), `settle()` transfers the whole tranche back to the vault and calls
nothing, and `phase()` reports `Aborted`. The vault stays shut. `06b_GenesisSettle` then makes the
two governed calls the fallback needs — approve the founders' seed out of the timelock, and
`genesisPlace` with `p0X18 = 1e18` — which is the pre-revision-7 launch exactly: pools open at
$1.00, ladders as before.

### Views the dApp and the indexer read

`usdgAuction()`, `ethAuction()`, `phase()`, `settled()`, `p0X18()`, `raisedUsdg()`, `raisedWeth()`,
`raisedUsd18()`, `unsoldAmps()`, `ethUsdX18()`, `floorUsdgQ96()`, `floorEthQ96()`, plus the wiring
(`vault()`, `amps()`, `factory()`, `weth9()`, `usdg()`, `timelock()`) and two pure helpers for
checking a proposal offline, `packStep(uint24,uint40)` and `stepsTotals(bytes)`.

`phase()` is derived, not stored:

| Phase | When |
|---|---|
| `Created` | constructed, or created and `block.number < startBlock` |
| `Bidding` | `startBlock <= block.number < endBlock` |
| `Ended` | `block.number >= endBlock`, unsettled |
| `Settled` | `settle()` ran and at least one leg graduated |
| `Aborted` | `settle()` ran and no leg graduated |

## 5. Order of operations, and which step needs which

This is the part revision 7 changes most, and the constraint that forces it is one line of
`PoolRegistry`: `_openPool` anchors every pool at `AmpsVault.pRefX18()`, falling back to $1.00 only
while that word is still zero. `PoolRegistry` **registers a constituent and initialises its pool in
the same call** — `_registerPool` then `_openPool`, with no way to do the first without the second —
so if the pools are to open at `P0`, the whole of `05_Registry` has to run after settlement.

| # | Step | Needs | Produces |
|---|---|---|---|
| 0 | `00_Preflight` | — | asserts the CCA factory holds code |
| 1 | `02_Libraries`, `03_Core`, `04_MineHook` | — | every contract, `AmpsGenesis` included |
| 2 | `09_Phase3Wire` **pass 1** (`WIRE_DEFER_GATE=true`) | step 1 | the 8 pointer moves incl. `vault.genesis`; gate deliberately unset |
| 2b | `05_Registry` / `10_TestnetPools` with `REGISTRY_FEEDS_ONLY=true` | step 1 | every feed installed, **no pool registered** |
| 3 | `06a_GenesisAuction` | `vault.genesis` set; the WETH feed; no gate | `genesisMint` + two funded auctions |
| 4 | bidding, ~72 h (2.59M blocks at 100 ms) | step 3 | bids |
| 5 | `06b_GenesisSettle` | every `endBlock` passed; **no pool registered yet** | `settle()` → `genesisPlace` → `P_ref = P0` |
| 6 | `05_Registry` / `10_TestnetPools` | `pRefX18() == P0`; no gate | 32 pools opened at `P0`, 30 bond markets, index weights |
| 7 | TWAP warm-up | step 6 | the hub ring covers `twapWindow` |
| 8 | `09_Phase3Wire` **pass 2** | steps 6-7 | the gate pointer, `GREEN` |
| 9 | `11_GenesisPlacement` phase 1 | gate `GREEN`; `initialized` | ask ladders in all 32 pools |
| 10 | `11_GenesisPlacement` phase 2 | +60 s cooldown | seed bids in the two entry pools |
| 11 | `12_Verify` | — | the verification table, `AmpsGenesis` included |

**Why `09` runs twice.** Before the CCA, the pools were registered at a fixed $1.00 anchor *before*
genesis, so one pass could do every pointer move and the gate move together. Now registration has to
happen after settlement, and settlement has to happen after the pointer moves, because the vault
needs its `genesis` pointer before it will mint the auction tranche. So the pointer batch goes
first and the gate move goes last. `checkBootstrap(t, 0)` is the pass-1 form: every pointer check
still runs (including the new `genesis` one), and the pool-count and ring-coverage checks are
skipped, because "no pools yet" is the correct state on that pass rather than an unfinished step.

**Why the feeds come first (step 2b).** `genesisPlace` ends in a checkpoint, and a checkpoint prices
every asset the vault holds — at that moment WETH9 and USDG, the auction proceeds. Their feeds must
therefore be installed before `06b`, and registration can no longer carry them: it now runs *after*
settlement. So `05_Registry` grew a feeds-only pass (`Registry.installFeeds`, `REGISTRY_FEEDS_ONLY=1`)
that installs all 32 feeds and registers nothing. `_installFeed` compares `feedOf(token)` first, so
the registration pass at step 6 re-installs none of them. `06a` wants the WETH feed too, to
cross-check the ETH/USD price its proposal carries against `FeedRegistry`.

**What `genesisPlace` does and does not need.** It does **not** need any pool to exist. It needs the
proceeds' tokens, which it registers itself from the `tokens` array; `_registerRegistryAssets` runs
too and is a harmless no-op before registration, because `initializePool` registers each pool's
counter asset as the pool is opened, so the enumeration ends up identical either way. Its
`_checkpoint()` reads an empty asset list plus the claims it has just settled, and `marketPrice` is
unusable with no hub pool, so `P_ref` falls back to NAV — which is precisely why `P0` is written
after the checkpoint rather than before it.

**What the gate must not be.** Steps 3, 5 and 6 all run with `vault.oracleGate() == address(0)`.
`OracleGate` reports `WATCHDOG` while the hub pool is unregistered or its ring is short, and
`initializePool`, `genesisMint` and `genesisPlace` all take `_requireHealthy`, so a gate pointed too
early makes the launch unreachable. An absent gate is exactly as permissive as a `GREEN` one.
A consequence worth stating in the keeper runbook: because `settle()` is permissionless and gated,
**the gate pointer must not be set between step 3 and step 5**, or a third party's `settle()` will
revert `GateNotHealthy`.

## 6. `script/config/genesis.json`

| Key | Meaning |
|---|---|
| `factory` | `ContinuousClearingAuctionFactory`. Canonical: `0x000000001F26a0044BaA66024e7b6599c61963F8`. Env `AMPS_CCA_FACTORY` |
| `ethUsdX18` | ETH/USD, 18 decimals, at creation. `0` = read the vault's feed. Env `AMPS_ETH_USD_X18` |
| `blockMs` / `AMPS_BLOCK_MS` | Robinhood Chain block time; every block figure is derived from it |
| `startDelayHours`, `durationHours`, `claimDelayHours` | the block schedule. Defaults 24 / 72 / 0 |
| `usdg.enabled`, `eth.enabled` | whether each leg runs. Disabling one returns its tranche as unsold |
| `usdg.tickSpacing`, `eth.tickSpacing` | Q96 price granularity. 1% of the floor; upstream's minimum is 2 |
| `usdg.requiredCurrencyRaised`, `eth.requiredCurrencyRaised` | graduation, in currency raw units |
| `usdg.validationHook`, `eth.validationHook` | `IValidationHook` for geo-blocking or an allowlist, or zero |
| `usdg.salt`, `eth.salt` | CREATE2 salts |
| `usdg.steps`, `eth.steps` | `[{mps, blocks}]`. A single `{0,0}` asks `06a` for a flat schedule |
| `fallback.p0X18`, `fallback.seedWeth`, `fallback.seedUsdg` | the founders' seed, used only when nothing graduates |

Tranche sizes are **not** here — they are `Constants` and `genesisMint` refuses anything else — and
neither is the floor price.

## 7. Two things upstream's own documents disagree about

Both are recorded here because a deployment has to resolve them against the live factory on a
testnet before the mainnet run, and both are handled defensively rather than assumed.

1. **`create` vs `initializeDistribution`.** CCA's `TechnicalDocumentation.md` documents the factory
   entry point as `initializeDistribution(token, amount, configData, salt)`. Its own `CHANGELOG.md`
   for v2.0.0 records PR #356, which renamed it to `create` (and `getAuctionAddress` to
   `getAddress`). `AmpsGenesis._deploy` tries `create` first — the newer of the two normative
   statements — and falls back to `initializeDistribution`, bubbling the factory's own revert when
   both fail. Both names take identical arguments and return the auction address, so the fallback
   cannot deploy a *different* auction; it can only reach an older factory.
   `unit/AmpsGenesis.t.sol::test_create_reachesALegacyFactory` covers the second branch.
2. **The `auctionStepsData` packing.** The quoted `AuctionStepLib.parse` reads
   `mps = uint24(bytes3(data))` (the top 24 bits) and `blockDelta = uint40(uint64(data))` (the low
   40), i.e. `word = (mps << 40) | blockDelta`. The prose example a few lines below shows
   `uint64(mps) | (blockDelta << 24)`, which is the other way round. `AmpsGenesis.packStep`
   implements the `parse`-derived layout, because that is what the deployed bytecode runs, and
   `stepsTotals` is a public pure view so an operator can check a proposal's blob offline before it
   is signed.

A third integration note, not a contradiction: the docs do not say whether the factory pulls the
tranche or expects it pushed, and there is no `onTokensReceived` in the interface although the
auction emits `TokensReceived`. `AmpsGenesis._createLeg` handles both — it approves the factory
before the call and clears the allowance after, pushes whatever the factory did not take, makes a
best-effort `onTokensReceived()` nudge, and then **asserts the auction's balance equals the
tranche**. The balance assertion is what actually decides; the other three are how it gets there.

## 8. Risks a bidder should read

* **A non-graduating auction refunds in full**, through the auction, not through Amplestocks.
* **The protocol fee** is Uniswap's, charged by the factory's fee controller at sweep time, and is
  deducted from what reaches the vault. Amplestocks measures it rather than predicting it. A
  self-deployed factory with `protocolFeeController == address(0)` charges nothing and is a
  one-key change in `genesis.json`.
* **The launch premium is 100% at a full clear at the floor** and is disclosed, not smoothed
  (section 2).
* **`settle()` is permissionless**, so the launch cannot be held hostage by whoever holds a key —
  but it *can* be blocked by an oracle gate pointed too early (section 5).
* **The timelock can still pre-empt the auction** by running the founders'-seed `genesisPlace` while bidding is
  live. That does not strand the raise (section 4's escape hatch) but it does mean the launch reference is the
  fallback $1.00 rather than the price bidders paid. It is a governance action with a 7-day delay and a visible
  proposal, and the runbook's answer is not to schedule one.
* **The auction contracts are Uniswap's**, audited by Spearbit, OpenZeppelin and ABDK. Amplestocks
  trusts the factory address, the bytecode it deploys and the fee its controller charges; the
  factory is fixed in the adapter's bytecode at construction and `createAuctions` is `onlyTimelock`.

## 9. What the tests prove

| File | What |
|---|---|
| `test/unit/VaultGenesis.t.sol` | both latches, the caller rules, the whole `NotInitialized` window incl. `redeemProRata`, `P_ref = P0`, the NAV floor on `p0X18`, `NAV = raised / S0`, unsold AMPS as inventory and not in `A`, the timestamp at *place* |
| `test/unit/AmpsGenesis.t.sol` | floors, funding, schedule validation, the ETH/USD cross-check, single-leg mode, the legacy factory name, a factory that reverts, all four settlement outcomes, the protocol fee, divergence, sweep-clean, the `receive()` guard, `settle()` twice, `settle()` early, `phase()` |
| `test/mocks/MockCCA.sol`, `MockCCAFactory.sol` | the auction's interface contract: who may call what and when, and what a sweep pays out |
| `test/script/Phase3Scripts.t.sol` | the whole pipeline in the order of section 5, and every script run twice |
| `test/script/broadcast.sh` | the same rehearsal on anvil, both genesis steps included |
| `test/unit/GuardSymmetry.t.sol` | `genesisMint`/`genesisPlace` classified, and `redeemProRata` still touching no gated slot |
| `test/unit/VaultLayout.t.sol` | slot 3's third latch and slot 22's adapter pointer |
