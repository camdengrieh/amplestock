# Amplestocks deploy runbook

How the `$AMPS` system is brought up on a chain, in the order the contracts allow — which is not the order the
component list suggests. Two facts drive everything below:

1. **`AmpsVault` is a `DELEGATECALL` consumer of four deployed libraries.** An unlinked artefact carries
   `__$…$__` placeholders and cannot be deployed at all, so the library addresses are the first thing the
   deployment fixes (`docs/phase2-state-model.md` §10.1, `docs/phase3-state-model.md` §12 ruling A).
2. **The gate and the first pool are circular.** `AmpsVault.initializePool` and `genesis()` both take
   `_requireHealthy`, and `OracleGate` reports `WATCHDOG` while the hub pool is unregistered *or* its observation
   ring covers less than `twapWindow`. A freshly initialised pool has no observations, so with the gate already
   wired **no pool can be registered and `genesis()` can never run** (`docs/phase2-state-model.md` §9.1).

Everything else is a consequence of those two.

---

## 0. Prerequisites

```bash
export PATH=$HOME/.foundry/bin:$PATH            # Foundry 1.8.1
cd contracts
export RPC=$ROBINHOOD_RPC_URL                   # or $ROBINHOOD_TESTNET_RPC_URL for 46630
```

Fill in `script/config/deployments.json` as the deployment proceeds; every entry can also be overridden from the
environment (the file lists the variable name beside each address). Phase 0 must re-verify every address in
`script/config/constituents.json` and `packages/config` on chain before any of it is used.

Scripts that exist today: `01_MineAmps`, `02_Libraries`, `04_MineHook`, `05_Registry`, `09_Phase3Wire`,
`10_TestnetPools`, `11_GenesisPlacement`. `00_Preflight`, `03_Vault`, `07_Bonds` and `08_Staking` are not written
yet; the steps that need them below are marked **(manual)** and are ordinary `forge create` calls.

---

## 1. The four vault libraries, and the `--libraries` flags

`VaultRolloutLib` calls `VaultPlacementLib.place`, which is `public`, so its own artefact carries a link reference
and can only be built once `VaultPlacementLib`'s address is known. Deployment is therefore two passes.

```bash
# pass 1 — VaultNavLib, VaultRedeemLib, VaultPlacementLib (deterministic CREATE2, idempotent)
forge script script/02_Libraries.s.sol --broadcast --rpc-url $RPC

# pass 2 — VaultRolloutLib, built against the VaultPlacementLib pass 1 printed
LIB_ROLLOUT_ONLY=true forge script script/02_Libraries.s.sol --broadcast --rpc-url $RPC \
  --libraries src/vault/VaultPlacementLib.sol:VaultPlacementLib:$PLACEMENT
```

Pass 2 re-reads the deployed runtime code and reverts `UnlinkedRollout` if the address Foundry linked in is not
the `VaultPlacementLib` this deployment owns. Both passes rewrite `script/config/libraries.json`.

**Every later command that builds, deploys, measures or verifies `AmpsVault` takes all four flags:**

```
--libraries src/vault/VaultNavLib.sol:VaultNavLib:$NAV_LIB \
--libraries src/vault/VaultRedeemLib.sol:VaultRedeemLib:$REDEEM_LIB \
--libraries src/vault/VaultPlacementLib.sol:VaultPlacementLib:$PLACEMENT_LIB \
--libraries src/vault/VaultRolloutLib.sol:VaultRolloutLib:$ROLLOUT_LIB
```

`script/config/libraries.json` carries the same string ready to paste, under `librariesFlag`.

> **Do not put these in `foundry.toml`'s `libraries` key.** That would pin one chain's addresses into *every*
> build, `forge test` included, where Foundry deploys its own copies at its own addresses. The flags are passed
> per command and recorded in JSON precisely so that the test build stays chain-agnostic.

The EIP-170 gate must measure the *linked* artefact:

```bash
forge build --sizes $LIBRARY_FLAGS
```

After deploying `AmpsVault`, prove the link rather than assuming it — `Libraries.assertLinked(vault, set)` scans
the vault's runtime code for each library's 20 bytes, which is where a linked `DELEGATECALL` target lives.

---

## 2. Token, vault and hook

The addresses are mutually dependent, so they are mined and predicted rather than discovered:

| Contract | How its address is fixed |
|---|---|
| `Amps` | CREATE2 salt mined to three leading zero bytes, against `abi.encode(vault)`, so AMPS is `currency0` in all 32 pools (`01_MineAmps`, `script/mine-amps.py`) |
| `AmpsVault` | plain CREATE from the deployer; its address is *predicted* first, because the AMPS salt is mined against it |
| `AmpsHook` | CREATE2 salt mined so the low 14 bits are exactly `0x38C0`, against `(poolManager, amps, vault, registry, timelock)` (`04_MineHook`) |
| `PoolRegistry` | plain CREATE; takes the hook, and the hook takes the registry, so one of the two is predicted |

```bash
# 1. predict the vault address, mine the AMPS salt against it
python3 script/mine-amps.py --vault $PREDICTED_VAULT
AMPS_VAULT=$PREDICTED_VAULT AMPS_SALT=$SALT forge script script/01_MineAmps.s.sol

# 2. deploy Amps then AmpsVault  (manual)
# 3. mine and deploy the hook against the predicted registry address
HOOK_POOL_MANAGER=$PM HOOK_AMPS=$AMPS HOOK_VAULT=$VAULT HOOK_REGISTRY=$PREDICTED_REGISTRY \
  HOOK_TIMELOCK=$TIMELOCK HOOK_DEPLOY=true forge script script/04_MineHook.s.sol --broadcast --rpc-url $RPC
# 4. deploy PoolRegistry, FeedRegistry, AmpsBonds, AmpsStaking, BountyPot, LadderPositionValuer,
#    LadderPolicy, RolloutPolicy, FeePolicy, BondPolicy and the team VestingWallet  (manual)
```

Re-run `04_MineHook` after **every** dependency bump: the salt is valid for one exact creation-code hash, and the
creation code moves with solc *and* with the library addresses.

---

## 3. The bootstrap order

This is the part that cannot be reordered. `09_Phase3Wire.checkBootstrap` asserts steps 1–3 and
`assertGateGreen` is step 4, so the ordering is enforced in code rather than by this document.

### Step 1 — wire everything except the gate

```
vault.setPolicyPointer("registry",       PoolRegistry)          set-once, frozen by genesis()
vault.setPolicyPointer("bonds",          AmpsBonds)             set-once
vault.setPolicyPointer("staking",        AmpsStaking)           set-once
vault.setPolicyPointer("bountyPot",      BountyPot)             set-once
vault.setPolicyPointer("feedRegistry",   FeedRegistry)
vault.setPolicyPointer("positionValuer", LadderPositionValuer)
vault.setPolicyPointer("marketReference", …)
                          ↑ leave "oracleGate" UNSET
```

A gate that is absent is exactly as permissive as a gate that is `GREEN` (`docs/phase2-state-model.md` §7.1), the
vault holds no assets before `genesis()`, and the `wiringFrozen` latch `genesis()` sets does not cover the gate
pointer, which stays governable for the life of the vault.

### Step 2 — register the 32 pools

```bash
forge script script/05_Registry.s.sol --broadcast --rpc-url $RPC $LIBRARY_FLAGS
```

`registerEntryPool` for `AMPS/USDG` and `AMPS/WETH`, then `addConstituent` for each of the 30 names in
`script/config/constituents.json`, then one `setIndexWeights` that installs the launch weight vector. Each
`vault.initializePool` passes because there is no gate yet. Idempotent: anything already registered is skipped, so
a run that dies half way through is resumed by running it again. Writes `script/config/pools.json`.

Two weight vectors, and it is not a workaround: `PoolRegistry._requireWeight` measures a proposed
`targetWeightBps` against the band for the count the registration *produces* — floor `min(10000/(2n), 500)`, cap
`max(ceilDiv(10000, n), 3000)` — so at `n = 1..10` the floor is 500 bps and no launch weight (equal weight over 30
names is 333) is legal at registration time. Every name is registered at 500 and the real vector is installed once
all 30 are `ACTIVE`, where the only constraints are `[166, 3000]` per name and a sum of exactly 10,000.

### Step 3 — let the hub ring cover `twapWindow`

Thirty minutes of blocks after the hub pool's first observation, which `AmpsHook.afterInitialize` wrote. Nothing
to run; check it with

```bash
cast call $HOOK "observationCoverage(bytes32)(uint32)" $HUB_POOL_ID --rpc-url $RPC
```

and wait until it is at least `vault.twapWindow()` (1,800 s at launch).

### Step 4 — the Phase 3 pointer moves, then the gate

```bash
# emit the proposal calldata for the Safe (default)
forge script script/09_Phase3Wire.s.sol

# or execute directly, on a chain whose "timelock" is this script's sender
WIRE_DIRECT=true forge script script/09_Phase3Wire.s.sol --broadcast --rpc-url $RPC $LIBRARY_FLAGS
```

Seven calls, in this order:

| # | Move | Delay |
|---|---|---|
| 1 | `vault.marketReference → AmpsHook` | 7 d |
| 2 | `vault.positionValuer → LadderPositionValuer` | 7 d |
| 3 | `vault.ladderPolicy → LadderPolicy` | 7 d |
| 4 | `vault.rolloutPolicy → RolloutPolicy` | 7 d |
| 5 | `AmpsHook.setFeePolicy(FeePolicy)` | 48 h |
| 6 | `AmpsBonds.setPolicy(BondPolicy)` | 7 d |
| 7 | `vault.oracleGate → OracleGate` | 7 d |

`OracleGate` is **redeployed** in this batch so it is constructed with `AmpsHook` as its `marketReference` and
reads the hook's `poolState` for the corporate-action flag (`docs/phase3-state-model.md` §10 ruling 10); the
script re-installs the DST table and the NYSE holiday bitmap on it and re-points `FeedRegistry.setOracleGate`.
Call 7 goes last, after `checkBootstrap` has confirmed the pools exist and the hub ring is covered, and the run
ends by asserting `gate.state(0) == GREEN`. Proposal mode writes `script/config/phase3-proposal.json` with the
`scheduleBatch` / `executeBatch` calldata for the proposer Safe; the gate must be deployed before the batch is
scheduled, because call 7 points at it.

Only `2026` NYSE holidays ship with the script. Each later year is its own 48-hour `setHolidayBitmap` proposal; an
unknown year is treated as having no full-day closures, which is a liveness choice, not a safety one.

### Step 5 — genesis and the §3.3 ladders

```bash
# phase 1: genesis() plus the ask ladder in all 32 pools
forge script script/11_GenesisPlacement.s.sol --broadcast --rpc-url $RPC $LIBRARY_FLAGS

# ...wait out the 60-second per-pool cooldown, then run it again for the entry-pool seed bids
forge script script/11_GenesisPlacement.s.sol --broadcast --rpc-url $RPC $LIBRARY_FLAGS
```

The script works out which phase is due from chain state (`nextPhase`), so `--resume` is just "run it again";
`cooldownRemaining` reports the wait, read off the ladder records' own `placedAt`. The launch vector:

| Where | What | Cells |
|---|---|---|
| `AMPS/USDG`, `AMPS/WETH` | 1,662.5 AMPS of asks each, 10 doublings, tilt 1.25 | `m = 0..9` |
| `AMPS/USDG`, `AMPS/WETH` | $2,500 of counter each as seed bids, 4 halvings | `m = -1..-4` |
| 30 spokes | 47.5 AMPS each (1% of the 4,750 POL tranche) | `m = 0..9` |

3,325 + 1,425 = 4,750 AMPS of POL, 250 to the team's `VestingWallet`, `S0` = 5,000, NAV/share = $1.00. The run
asserts NAV/share against the launch price and checks the cell layout with `assertLayout`.

> **Known deviation from §3.3.** Valuing a freshly placed ask ladder at the reference price picks up a sliver of
> counter-side value on the cell the price sits in, so each placement lifts NAV/share — about +2 bps across all 32
> ladders — and `P_ref` follows it. `VaultPlacementLib._cells` then starts a ladder at
> `ceilDiv(fairTick(P_ref) − gridBase, D)`, which is 1 rather than 0 for a pool whose exact fair tick sits within
> those ~2 ticks below a 60-tick spacing boundary: a few pools out of 32 get `m = 1..10` instead of `m = 0..9`.
> That is invariant I32 doing its job (no ask below `P_ref`), so `assertLayout` asserts the guaranteed shape —
> `ladderDoublings` contiguous one-cell asks anchored at the origin or one cell above it — rather than the
> coincidence. See `test/script/Phase3Scripts.t.sol`.

---

## 4. Testnet (chain 46630)

`10_TestnetPools` stands the same 32-pool shape up against mocks: 30 `MockStockToken`s (settable `uiMultiplier`,
scheduled multiplier and `effectiveAt`, `oraclePaused`, beacon-shaped denylist), 30 `MockAggregator`s at the
illustrative prices in `constituents.json`, a `MockUsdg` and a `MockWeth9`. It then drives `05_Registry` over
them.

```bash
forge script script/10_TestnetPools.s.sol --broadcast --rpc-url $ROBINHOOD_TESTNET_RPC_URL $LIBRARY_FLAGS
```

Idempotent and resumable off `script/config/testnet.json`, asset by asset. It refuses to run on any chain but
46630 unless `TESTNET_ALLOW_ANY_CHAIN=true`: the mocks carry an open mint. `PoolRegistry` takes WETH9 and USDG in
its constructor, so on a fresh testnet the mocks are deployed **before** the registry.

---

## 5. Placeholder config, pending Phase 0

Nothing in `script/config/constituents.json` may be treated as verified. A zero address carries the matching
`tokenTodo` / `feedTodo` flag and `05_Registry` refuses to register that name until it is filled in.

| Item | State |
|---|---|
| Stock Token addresses | 11 of 30 known (AAPL, AMZN, COIN, GME, GOOGL, META, MSFT, NVDA, TSLA, SPY, QQQ); the other 19 are `TODO` |
| Chainlink feeds | 5 of 30 known (AAPL, MSFT, NVDA, TSLA, SPY); the other 25 are `TODO`, and **ETH/USD for the `AMPS/WETH` entry pool is `TODO` too** |
| `poolClass` (high-σ or not) | placeholder classification; Phase 0's volatility sample sets it |
| `inclusion` records (beta, tracking error, index vol, history) | placeholder; Phase 0 measures them against the real series |
| index and rollout weights | equal weight at launch; the published quarterly rule replaces the vector through `setIndexWeights` |
| `testnetPriceUsd8` | illustrative fixture prices for the 46630 `MockAggregator`s only — not price data |
| CREATE2 factory `0x4e59…4956C` | recorded as **unverified** on 4663; assert its code before relying on it |

---

## 6. Verifying a run

```bash
forge build --sizes $LIBRARY_FLAGS               # EIP-170 on the linked artefact
forge test --match-path 'test/script/*'          # the fork-free dry run of every script above
python3 ../scripts/licence-gate.py               # no BUSL/AGPL/GPL reachable from src/
forge verify-contract --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ \
  $LIBRARY_FLAGS <address> <contract>
```

`test/script/Phase3Scripts.t.sol` runs `02`, `05`, `09`, `10` and `11` against a local `PoolManager` and asserts
the state they leave: 32 pools, 30 bond markets, the six pointers, the genesis vector and the ladder layout — then
runs them again and asserts nothing moves. It is the substitute for a testnet rehearsal while the network policy
is closed, and should be re-run before every real deployment.
