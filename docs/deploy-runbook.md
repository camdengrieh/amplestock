# Amplestocks deploy runbook

How the `$AMPS` system is brought up on a chain, in the order the contracts allow — which is not the order the
component list suggests. Four facts drive everything below.

1. **`AmpsVault` is a `DELEGATECALL` consumer of four deployed libraries.** An unlinked artefact carries
   `__$…$__` placeholders and cannot be deployed at all, so the library addresses are the first thing the
   deployment fixes (`docs/phase2-state-model.md` §10.1, `docs/phase3-state-model.md` §12 ruling A).
2. **The gate and the first pool are circular.** `AmpsVault.initializePool` and `genesis()` both take
   `_requireHealthy`, and `OracleGate` reports `WATCHDOG` while the hub pool is unregistered *or* its observation
   ring covers less than `twapWindow`. A freshly initialised pool has no observations, so with the gate already
   wired **no pool can be registered and `genesis()` can never run** (`docs/phase2-state-model.md` §9.1).
3. **The timelock address is immutable.** `AmpsVault`, `PoolRegistry` and `AmpsHook` take it in their
   constructors and hold it in bytecode. There is no `setTimelock`. Whatever address the constructors are given
   has to make all ~100 bootstrap calls itself, so the bootstrap runs *through* the `TimelockController`, at
   `minDelay = 0`, and the launch ends by raising the delay and revoking the deployer (§0.2).
4. **Every broadcast window must be opened by the script `forge script` was pointed at** (§0.1).

---

## 0. Prerequisites

```bash
export PATH=$HOME/.foundry/bin:$PATH            # Foundry 1.8.1, pinned
cd contracts
export RPC=$ROBINHOOD_RPC_URL                   # or $ROBINHOOD_TESTNET_RPC_URL for 46630
```

Every address a script reads comes from `script/config/*.json` and may be overridden by the environment variable
named beside it in `deployments.json`'s `envOverrides`. Phase 0 must re-verify every address in
`script/config/preflight.json` and `script/config/constituents.json` on chain before any of it is used; `00_Preflight`
is the script that does it.

### 0.1 The broadcast rule

**A `vm.startBroadcast` window opened by a *helper contract* writes every transaction into
`broadcast/…/run-latest.json` with the same nonce.** Observed with Foundry 1.8.1, `--slow` or not: 26 registry
calls all at nonce `0x28`, and the run dies with `EOA nonce changed unexpectedly while sending transactions.
Expected 40 got 41`. Simulation is unaffected, which is why a fork-free `forge test` harness cannot see it.

The rule, and it applies to every script in this repository:

> The broadcast window, and every state-changing call inside it, must belong to the contract `forge script` was
> pointed at. Helpers may be `internal` libraries (inlined, same frame) or `pure`/`view` contracts instantiated
> **outside** every window. They may not open a window, and they may not issue a transaction.

What that shaped:

* `10_TestnetPools` **is a** `05_Registry` (`contract TestnetPools is Registry`) rather than owning one. It
  substitutes the mock counter assets and then calls the inherited `execute`, in its own frame.
* `script/lib/Gov.sol` and `script/lib/Calendar.sol` are libraries of `internal` functions, inlined into the
  calling script's own code — so the window and every call `Gov.send` makes are in the script's frame.
* `03_Core` and `12_Verify` instantiate **nothing**: the vault's link check scans the deployed runtime code for
  the four addresses `libraries.json` records, and `12_Verify` reads the same address book `03_Core` writes
  rather than calling `Core.readDeployments()` on an instance. `test/script/DeployScripts.t.sol` asserts the two
  readers agree.
* `contracts/test/script/broadcast.sh` runs the whole pipeline against anvil with `--broadcast`, twice. That is
  the only harness that can catch a regression here (§8).

### 0.2 Governance: what "the timelock" is, and the two modes

The plan's governance is a Safe 3/5 proposer → OZ `TimelockController` with `EXECUTOR_ROLE = address(0)` (anyone
may execute a matured operation), delays 48 h / 7 d / 14 d, and a guardian Safe 2/4 as canceller. `TimelockController`
has a single `minDelay`; **48 h is the floor and the 7-day and 14-day classes are per-proposal `delay` arguments**,
which the Safe's signing policy and `docs/launch-runbook.md` §7 enforce.

Because the timelock is immutable in the core contracts, the bootstrap has to be made by it. `03_Core` therefore
deploys it with `minDelay = 0` and **two** proposers — the Safe and the deployer key — and every governed call in
`03`, `05`, `09` and `11` goes `schedule(delay 0)` → `execute` from the deployer. `script/lib/Gov.sol` is the one
place that knows this; the mode is chosen by two variables:

| mode | `AMPS_TIMELOCK` is | who signs | how a governed call is made |
|---|---|---|---|
| direct (default) | an EOA or Safe the operator controls | that address | plain `CALL` |
| relay (`AMPS_GOV_RELAY=true`, `AMPS_DEPLOYER=0x…`) | an OZ `TimelockController` | `AMPS_DEPLOYER` | `schedule` then `execute` |

Relay is the mainnet shape. Direct is what the fork-free dry run, `Phase3Scripts.t.sol` and a single-operator
testnet use.

> **Until `03_Core CORE_STAGE=finalize` runs, the deployer key is as powerful as the proposer Safe.** It is a
> fresh hardware key, it is used for nothing else, and finalisation is the last step of the launch
> (`docs/launch-runbook.md` §2 step 11). `Gov.requireBootstrappable` refuses to start a bootstrap through a
> timelock whose delay is no longer zero, so a script run after finalisation fails immediately instead of half
> way through.

### 0.3 The numbered pipeline

The plan numbers the scripts `00 01 02 03 04 05 06 07 08`. What exists on disk is the same pipeline with the
mutually dependent deployments folded into one script, because their addresses are predicted from each other's
nonces and splitting them would mean re-deriving the same predictions four times.

| plan | file | what it does |
|---|---|---|
| `00_Preflight` | `script/00_Preflight.s.sol` | the on-chain pre-flight; reads only |
| `01_MineAmps` | `script/01_MineAmps.s.sol`, `script/mine-amps.py` | the AMPS CREATE2 salt |
| — | `script/02_Libraries.s.sol` | the four linked vault libraries (two passes) |
| `02_Token` + `03_Vault` + `07_Bonds` | `script/03_Core.s.sol` | the timelock, the token, the vault, the hook, the registry, the whole periphery — `AmpsQuoter` and `AmpsRouter` included — and the set-once wiring |
| `04_MineHook` | `script/04_MineHook.s.sol` | the hook salt; `03_Core` mines the same salt inline, and this stays as the standalone re-check CI runs after every dependency bump |
| `05_Registry` | `script/05_Registry.s.sol` | the 32 pools and 30 bond markets |
| — | `script/09_Phase3Wire.s.sol` | the Phase 3 pointer moves and the gate (§5) |
| — | `script/10_TestnetPools.s.sol` | mock counter assets + registration, on a test chain only |
| `06_Genesis` | `script/11_GenesisPlacement.s.sol` | `genesis()` and the §3.3 ladders |
| — | `script/12_Verify.s.sol` | the Blockscout verification commands |

`03_Vault` and `07_Bonds` are aliases for parts of `03_Core`; `06_Genesis` is an alias for `11_GenesisPlacement`.
The file names do not change. **`08_Staking` is gone**: plan revision 6 removed staking from the protocol, so
there is no `AmpsStaking` to deploy and no `staking` vault pointer to wire. What revision 6 added in its place is
`AmpsRouter`, deployed by `03_Core` with `(poolManager, amps, registry, weth)`, recorded under `core.router` in
`deployments.json` and overridable at run time by `AMPS_ROUTER`; it is immutable, ownerless and holds no funds, so
replacing it is a deploy plus one `AmpsHook.setRouter` proposal.

---

## 1. The whole sequence, in order

```bash
# 0. pre-flight: read the chain, verify every configured address, pin the PoolManager code hash
forge script script/00_Preflight.s.sol --rpc-url $RPC

# 1. the four vault libraries, two passes (§2)
forge script script/02_Libraries.s.sol --broadcast --rpc-url $RPC
export PLACEMENT=$(jq -r .libraries.VaultPlacementLib.address script/config/libraries.json)
LIB_ROLLOUT_ONLY=true forge script script/02_Libraries.s.sol --broadcast --rpc-url $RPC \
  --libraries src/vault/VaultPlacementLib.sol:VaultPlacementLib:$PLACEMENT
export LIBS=$(jq -r .librariesFlag script/config/libraries.json)

# 2. mine the AMPS salt off-chain against the vault address 03_Core will predict (§3)
#    03_Core deploys the TimelockController at NONCE, Amps (CREATE2, i.e. a transaction to the factory) at
#    NONCE+1, and AmpsVault at NONCE+2. With AMPS_TIMELOCK already deployed, drop one.
NONCE=$(cast nonce $DEPLOYER --rpc-url $RPC)
export PREDICTED_VAULT=$(cast compute-address --nonce $((NONCE + 2)) $DEPLOYER | awk '{print $NF}')
python3 script/mine-amps.py --vault $PREDICTED_VAULT      # -> AMPS_SALT
AMPS_VAULT=$PREDICTED_VAULT AMPS_SALT=$SALT forge script script/01_MineAmps.s.sol   # verify it

# 3. the system (§3)
export AMPS_GOV_RELAY=true AMPS_DEPLOYER=$DEPLOYER
CORE_PROPOSER_SAFE=$PROPOSER_SAFE AMPS_GUARDIAN=$GUARDIAN_SAFE AMPS_CREATOR=$CREATOR \
AMPS_TEAM_BENEFICIARY=$TEAM AMPS_SALT=$SALT \
  forge script script/03_Core.s.sol --broadcast --rpc-url $RPC $LIBS

# 4. the 32 pools and 30 bond markets, with the gate pointer still unset (§4)
forge script script/05_Registry.s.sol --broadcast --rpc-url $RPC $LIBS

# 5. wait ~30 minutes of blocks for the hub's observation ring (§5)
cast call $HOOK "observationCoverage(bytes32)(uint32)" $HUB_POOL_ID --rpc-url $RPC

# 6. the Phase 3 pointer moves and the gate (§5)
WIRE_DIRECT=true WIRE_REDEPLOY_GATE=false \
  forge script script/09_Phase3Wire.s.sol --broadcast --rpc-url $RPC $LIBS

# 7. move the founders' $5,000 into the timelock, then genesis and the ladders (§6)
forge script script/11_GenesisPlacement.s.sol --broadcast --rpc-url $RPC $LIBS
#    ...wait out the 60-second per-pool cooldown, then run it again for the entry-pool seed bids
forge script script/11_GenesisPlacement.s.sol --broadcast --rpc-url $RPC $LIBS

# 8. verification (§7)
forge script script/12_Verify.s.sol --rpc-url $RPC && bash script/config/verify.sh

# 9. hand governance over: minDelay 0 -> 48 h, deployer stops being a proposer (§0.2)
CORE_STAGE=finalize forge script script/03_Core.s.sol --broadcast --rpc-url $RPC $LIBS
```

On a **testnet** replace steps 3–4 with `10_TestnetPools` on either side of `03_Core` (§9), and drop
`AMPS_GOV_RELAY` if the timelock is simply an EOA you hold.

---

## 2. The four vault libraries, and the `--libraries` flags

`VaultRolloutLib` calls `VaultPlacementLib.place`, which is `public`, so its own artefact carries a link
reference and can only be built once `VaultPlacementLib`'s address is known. Deployment is therefore two passes.
Pass 2 re-reads the deployed runtime code and reverts `UnlinkedRollout` if the address Foundry linked in is not
the `VaultPlacementLib` this deployment owns. Both passes rewrite `script/config/libraries.json`, which carries
the ready-to-paste flag string under `librariesFlag`.

**Every later command that builds, deploys, measures or verifies `AmpsVault` takes all four flags:**

```
--libraries src/vault/VaultNavLib.sol:VaultNavLib:$NAV_LIB \
--libraries src/vault/VaultRedeemLib.sol:VaultRedeemLib:$REDEEM_LIB \
--libraries src/vault/VaultPlacementLib.sol:VaultPlacementLib:$PLACEMENT_LIB \
--libraries src/vault/VaultRolloutLib.sol:VaultRolloutLib:$ROLLOUT_LIB
```

> **Do not put these in `foundry.toml`'s `libraries` key.** That would pin one chain's addresses into *every*
> build, `forge test` included, where Foundry deploys its own copies at its own addresses. The flags are passed
> per command and recorded in JSON precisely so that the test build stays chain-agnostic.

The EIP-170 gate must measure the *linked* artefact: `forge build --sizes $LIBS`. `03_Core` proves the link
rather than assuming it — `Libraries.assertLinked` scans the deployed vault's runtime code for each library's
20 bytes, which is where a linked `DELEGATECALL` target lives — and refuses to continue if any is missing.

---

## 3. Token, vault, hook, registry, periphery — `03_Core`

The addresses are mutually dependent, so they are mined and predicted rather than discovered:

| Contract | How its address is fixed |
|---|---|
| `TimelockController` | plain CREATE, first, because it is an immutable constructor argument of three later contracts |
| `Amps` | CREATE2 salt mined to three leading zero bytes against `abi.encode(vault)`, so AMPS is `currency0` in all 32 pools |
| `AmpsVault` | plain CREATE, address *predicted* at `nonce + 1` — the AMPS salt is mined against it |
| `AmpsHook` | CREATE2 salt mined so the low 14 bits are exactly `0x38C0`, against `(poolManager, amps, vault, registry, timelock)` |
| `PoolRegistry` | plain CREATE, address *predicted* at `nonce + 3` — the hook takes the registry and the registry takes the hook |

A CREATE2 deployment inside a broadcast is still a transaction to the factory, so it consumes a nonce; that is
what makes the vault `nonce + 1` and the registry `nonce + 3`. Both predictions are asserted, not trusted, and a
mismatch aborts the run rather than continuing with a token bound to the wrong vault.

`AMPS_SALT` should be mined **off chain** for mainnet: three leading zero bytes is ~16.7 million CREATE2 attempts
and belongs in `script/mine-amps.py`, not in an EVM loop. Set `AMPS_ZERO_BYTES=2` (65k attempts, under a second)
only on a local chain, where every counter asset is an ordinary CREATE address. Whatever the source, the salt is
re-checked against the strength requested before it is used (`WeakAmpsSalt`).

Mining needs the vault address before the vault exists, so it is predicted from the deployer's nonce, and the
prediction is **asserted** rather than trusted: if anything slips a transaction in between, `03_Core` aborts with
`AddressPrediction` instead of deploying a token bound to an address that will never hold a vault. There is no
recovery from getting this wrong other than starting again with a fresh salt, which is why the assertion exists.

`03_Core` also does **§9.1 step 1**: the set-once vault pointers (`registry`, `bonds`, `bountyPot`,
`feedRegistry`) plus `marketReference` → `AmpsHook` and `positionValuer` → `LadderPositionValuer`, the gate's DST
table and NYSE holiday bitmap, `FeedRegistry.setOracleGate`, and `grantRole(CANCELLER_ROLE, guardian)` on the
timelock. It deliberately **leaves `vault.oracleGate` unset** — a gate that is absent is exactly as permissive as
a gate that is `GREEN`, and that is what lets step 2 register 32 pools whose observation rings are empty.

Outputs: `script/config/deployments.json` (every address) and `script/config/constructor-args.json` (every
ABI-encoded constructor argument, for verification).

Re-run `04_MineHook` after **every** dependency bump: the salt is valid for one exact creation-code hash, and the
creation code moves with solc *and* with the library addresses. CI's `hook-address` job does this automatically.

---

## 4. Registering the 32 pools

```bash
forge script script/05_Registry.s.sol --broadcast --rpc-url $RPC $LIBS
```

`registerEntryPool` for `AMPS/USDG` and `AMPS/WETH`, then `addConstituent` for each of the 30 names in
`script/config/constituents.json`, then one `setIndexWeights` that installs the launch weight vector, then any
per-market bond parameter that differs from the contract default. Each `vault.initializePool` passes because
there is no gate yet. Idempotent: anything already registered is skipped, so a run that dies half way through is
resumed by running it again. Writes `script/config/pools.json`.

In relay mode this is ~97 governed calls and therefore ~194 transactions. `--slow` is worth the time.

Two weight vectors, and it is not a workaround: `PoolRegistry._requireWeight` measures a proposed
`targetWeightBps` against the band for the count the registration *produces* — floor `min(10000/(2n), 500)`, cap
`max(ceilDiv(10000, n), 3000)` — so at `n = 1..10` the floor is 500 bps and no launch weight (equal weight over 30
names is 333) is legal at registration time. Every name is registered at 500 and the real vector is installed once
all 30 are `ACTIVE`, where the only constraints are `[166, 3000]` per name and a sum of exactly 10,000.

---

## 5. The hub ring, then the Phase 3 pointers and the gate

### Step 3 — let the hub ring cover `twapWindow`

Thirty minutes of blocks after the hub pool's first observation, which `AmpsHook.afterInitialize` wrote. Nothing
to run; check it with

```bash
cast call $HOOK "observationCoverage(bytes32)(uint32)" $HUB_POOL_ID --rpc-url $RPC
```

and wait until it is at least `vault.twapWindow()` (1,800 s at launch).

### Step 4 — the pointer moves, then the gate

```bash
# emit the proposal calldata for the Safe (default)
forge script script/09_Phase3Wire.s.sol

# or execute it now, at the bootstrap timelock's zero delay
WIRE_DIRECT=true WIRE_REDEPLOY_GATE=false \
  forge script script/09_Phase3Wire.s.sol --broadcast --rpc-url $RPC $LIBS
```

Eight calls, in this order:

| # | Move | Delay class |
|---|---|---|
| 1 | `vault.marketReference → AmpsHook` | 7 d |
| 2 | `vault.positionValuer → LadderPositionValuer` | 7 d |
| 3 | `vault.ladderPolicy → LadderPolicy` | 7 d |
| 4 | `vault.rolloutPolicy → RolloutPolicy` | 7 d |
| 5 | `AmpsHook.setFeePolicy(FeePolicy)` | 7 d |
| 6 | `AmpsHook.setRouter(AmpsRouter)` | 7 d |
| 7 | `AmpsBonds.setPolicy(BondPolicy)` | 7 d |
| 8 | `vault.oracleGate → OracleGate` | 7 d |

**Call 6 is revision 6's, and its position in the order is deliberate.** Until it executes, `AmpsHook.router()` is
the zero address and no hop in any pool can be priced pass-through: every swap, in both directions, pays
`ampsFeeBps`. That is the safe direction to be wrong in — a rotation is merely dear before the wiring lands, never
mispriced — so there is no window in which the exemption is granted to something that is not the router. Verify it
afterwards with `cast call $HOOK "router()(address)"` against `deployments.json`'s `core.router`; the dApp's Rotate
surface reads the same pointer and warns if the two disagree.

Moves 1 and 2 are already made by `03_Core`, so on a fresh deployment this run makes 3–8 and skips the rest —
the script is idempotent per pointer. `WIRE_REDEPLOY_GATE=false` is the flag for a deployment where `03_Core`
already deployed the gate against `AmpsHook`; `true` deploys a fresh one and re-installs the calendar, which is
the shape a *later* gate replacement takes. Call 7 goes last, after `checkBootstrap` has confirmed the pools
exist and the hub ring is covered, and the run ends by asserting `gate.state(0) == GREEN` and recording the gate
in `deployments.json`.

Proposal mode writes `script/config/phase3-proposal.json` with `scheduleBatch` / `executeBatch` calldata for the
proposer Safe; the gate must be deployed before the batch is scheduled, because call 7 points at it.

Only `2026` NYSE holidays ship, in `script/lib/Calendar.sol`. Each later year is its own 48-hour
`setHolidayBitmap` proposal; an unknown year is treated as having no full-day closures, which is a liveness
choice, not a safety one. `docs/launch-runbook.md` §9 carries it as a recurring December task.

---

## 6. Genesis and the §3.3 ladders

`genesis()` pulls the seed from `msg.sender`, and `msg.sender` is the timelock — so **the founders' $5,000 must be
sitting in the `TimelockController`** before this runs, not in the deployer's wallet. On mainnet that is a
transfer the proposer Safe signs (`docs/launch-runbook.md` §2 step 8).

```bash
# phase 1: genesis() plus the ask ladder in all 32 pools
forge script script/11_GenesisPlacement.s.sol --broadcast --rpc-url $RPC $LIBS

# ...wait out the 60-second per-pool cooldown, then run it again for the entry-pool seed bids
forge script script/11_GenesisPlacement.s.sol --broadcast --rpc-url $RPC $LIBS
```

The script works out which phase is due from chain state (`nextPhase`), so `--resume` is just "run it again";
`cooldownRemaining` reports the wait, read off the ladder records' own `placedAt`. Everything in this step is a
governed call: `genesis()` is `onlyTimelock`, and `AmpsVault.place` is
`msg.sender == timelock || msg.sender == registry` — the `locked` modifier in its signature is not the whole
guard. So the two approvals, `genesis()` and all 34 placements go through `Gov`. The launch vector:

| Where | What | Cells |
|---|---|---|
| `AMPS/USDG`, `AMPS/WETH` | 1,662.5 AMPS of asks each, 10 doublings, tilt 1.25 | `m = 0..9` |
| `AMPS/USDG`, `AMPS/WETH` | $2,500 of counter each as seed bids, 4 halvings | `m = -1..-4` |
| 30 spokes | 47.5 AMPS each (1% of the 4,750 POL tranche) | `m = 0..9` |

3,325 + 1,425 = 4,750 AMPS of POL, 250 to the team's `VestingWallet`, `S0` = 5,000, NAV/share = $1.00. The run
asserts NAV/share against the launch price and checks the cell layout with `assertLayout`. 328 live cells when
both phases are done.

> **Known deviation from §3.3.** Valuing a freshly placed ask ladder at the reference price picks up a sliver of
> counter-side value on the cell the price sits in, so each placement lifts NAV/share — about +2 bps across all 32
> ladders — and `P_ref` follows it. `VaultPlacementLib._cells` then starts a ladder at
> `ceilDiv(fairTick(P_ref) − gridBase, D)`, which is 1 rather than 0 for a pool whose exact fair tick sits within
> those ~2 ticks below a 60-tick spacing boundary: a few pools out of 32 get `m = 1..10` instead of `m = 0..9`.
> That is invariant I32 doing its job (no ask below `P_ref`), so `assertLayout` asserts the guaranteed shape —
> `ladderDoublings` contiguous one-cell asks anchored at the origin or one cell above it — rather than the
> coincidence. See `test/script/Phase3Scripts.t.sol`.

After genesis the wiring latch is closed: `09_Phase3Wire` refuses with `AlreadyGenesis`, by design. Later pointer
moves are ordinary governance proposals, not deployment steps.

---

## 7. Verification

```bash
forge script script/12_Verify.s.sol --rpc-url $RPC     # writes script/config/verify.sh
bash script/config/verify.sh                           # Blockscout needs no API key
```

`12_Verify` re-encodes every constructor argument from `deployments.json` and `libraries.json` — the same values
`03_Core` deployed with — and emits one command per contract:

```
forge verify-contract --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api/ \
  --chain-id 4663 --compiler-version 0.8.30 \
  [--libraries src/vault/VaultNavLib.sol:VaultNavLib:0x… …] \
  [--constructor-args 0x…] \
  <address> <src/path.sol:Contract>
```

Three things the command line has to carry, and all three are why this is generated rather than typed:

1. **`--constructor-args`.** Blockscout matches the *creation* code, so a wrong blob fails the verification with
   no useful message. Every Amplestocks constructor takes between one and seven addresses that only exist after
   the deployment.
2. **`--libraries`,** four flags for `AmpsVault` and one for `VaultRolloutLib`. A linked `DELEGATECALL` target is
   part of the code; a verifier given different addresses produces different bytecode.
3. **The compiler profile.** `src/vault/*`, `src/bonds/*` and `src/hook/*` build at `optimizer_runs = 200` through
   the IR pipeline and everything else at 1,000,000 through the legacy one. `forge verify-contract` reads that
   from `foundry.toml`, which is why the commands run from `contracts/` rather than through a web form.

`script/config/verification.json` carries the same data machine-readably, for verifying one contract by hand.

---

## 8. Proving a run before you make it

```bash
forge build --sizes $LIBS                        # EIP-170 on the linked artefact
forge test --match-path 'test/script/*'          # the fork-free dry run of every script above
FOUNDRY_PROFILE=ci forge test --isolate --match-path 'test/script/*'
pnpm --filter @amplestocks/contracts broadcast-test   # the real thing, against anvil
python3 ../scripts/licence-gate.py               # no BUSL/AGPL/GPL reachable from src/
```

**`test/script/Phase3Scripts.t.sol`** runs `02`, `05`, `09`, `10` and `11` against a local `PoolManager` and
asserts the state they leave: 32 pools, 30 bond markets, the pointers, the genesis vector and the ladder layout —
then runs them again and asserts nothing moves. It never broadcasts, which is its limit.

**`test/script/broadcast.sh`** is the one that broadcasts. It starts an anvil on chain 46630, runs
`00 → 02 → 10(assets) → 03 → 10(register) → 09 → 11 → 11 → 12` with `--broadcast --slow --private-key <anvil key 0>`
through a real `TimelockController` in relay mode, advances the chain past `twapWindow` and the placement
cooldown with `evm_increaseTime`, and then asserts the resulting chain state with `cast`: 32 pools, 30
constituents, 30 bond markets, every pointer, `gate.state(0) == GREEN`, `S0` = 5,000 AMPS with 250 vesting,
NAV/share within 1% of $1.00, 328 live cells and the §3.3 layout. Then it runs the entire pipeline a second time
and asserts that a chain fingerprint (pool count, constituent count, market count, total supply, live cells,
NAV/share, gate pointer) is byte-identical — except `09_Phase3Wire`, which must refuse with `AlreadyGenesis`.
Finally it runs `CORE_STAGE=finalize` and checks the timelock ended at 48 h with the deployer no longer a
proposer and the guardian still a canceller.

It needs nothing beyond localhost. Measured on a 4-core runner: **370 s of pipeline** across the eighteen stages
(the slowest are `03_Core` at 59 s, `11_GenesisPlacement` phase 1 at 48 s and `12_Verify` at 45 s), on top of
whatever `forge build` costs. Most of the pipeline time is `forge script` recompiling: `--libraries` changes the
compiler input, so the run pays for three distinct configurations — none, the `VaultPlacementLib` flag alone, and
all four — and each one re-runs the via-IR compile of `src/vault/*`, `src/bonds/*` and `src/hook/*`. A cold cache
adds twenty minutes or so on top, essentially all of it that compile.

It runs as its own `broadcast-test` job in `.github/workflows/ci.yml`, after Foundry is installed and separately
from the `contracts` job, so a slow chain harness cannot hold up the unit suite — and, since it is in the
roll-up's required set, cannot be quietly skipped either.

---

## 9. Testnet (chain 46630)

`10_TestnetPools` stands the same 32-pool shape up against mocks: 30 `MockStockToken`s (settable `uiMultiplier`,
scheduled multiplier and `effectiveAt`, `oraclePaused`, beacon-shaped denylist), 30 `MockAggregator`s at the
illustrative prices in `constituents.json`, a `MockUsdg` and a `MockWeth9`. Since `PoolRegistry` takes WETH9 and
USDG in its constructor, a chain that starts empty needs two passes:

```bash
# 1. the mocks (and, with TESTNET_DEPLOY_POOL_MANAGER=true, a v4 PoolManager on a chain that has none)
TESTNET_ASSETS_ONLY=true forge script script/10_TestnetPools.s.sol --broadcast --rpc-url $TESTNET_RPC

# 2. 03_Core, as in §3

# 3. registration, through the inherited 05_Registry
forge script script/10_TestnetPools.s.sol --broadcast --rpc-url $TESTNET_RPC $LIBS
```

Idempotent and resumable off `script/config/testnet.json`, asset by asset; it also records the PoolManager, WETH9
and USDG it settled on into `deployments.json` so `03_Core` picks them up. It refuses to run on any chain but
46630 unless `TESTNET_ALLOW_ANY_CHAIN=true`: the mocks carry an open mint.

---

## 10. Placeholder config, pending Phase 0

Nothing in `script/config/constituents.json` or `script/config/preflight.json` may be treated as verified. A zero
address carries the matching `tokenTodo` / `feedTodo` flag and `05_Registry` refuses to register that name until
it is filled in; `00_Preflight` reports it as `TODO`.

| Item | State |
|---|---|
| Stock Token addresses | 11 of 30 known (AAPL, AMZN, COIN, GME, GOOGL, META, MSFT, NVDA, TSLA, SPY, QQQ); the other 19 are `TODO` |
| Chainlink feeds | 5 of 30 known (AAPL, MSFT, NVDA, TSLA, SPY); the other 25 are `TODO`, and **ETH/USD for the `AMPS/WETH` entry pool is `TODO` too** |
| `poolManagerCodeHash` | `TODO` — `00_Preflight` prints the measured hash; pin it in `preflight.json` and the check turns from `TODO` into a comparison |
| `poolClass` (high-σ or not) | placeholder classification; Phase 0's volatility sample sets it |
| `inclusion` records (beta, tracking error, index vol, history) | placeholder; Phase 0 measures them against the real series |
| index and rollout weights | equal weight at launch; the published quarterly rule replaces the vector through `setIndexWeights` |
| `testnetPriceUsd8` | illustrative fixture prices for the 46630 `MockAggregator`s only — not price data |
| CREATE2 factory `0x4e59…4956C` | recorded as **unverified** on 4663; `00_Preflight` asserts its code before anything relies on it |
| Standard-vs-SVR per feed | `00_Preflight` reports the proxy shape and flags anything naming SVR; the Chainlink RDD is the authority and Phase 0 confirms it in writing |

---

## 11. Failure modes and what to do

| Symptom | Cause | Fix |
|---|---|---|
| `EOA nonce changed unexpectedly` | a broadcast window opened by a helper contract | §0.1; the offending script must open its own window |
| `UnlinkedRollout` | pass 2 of `02_Libraries` ran without `--libraries` | re-run pass 2 with the flag `libraries.json` prints |
| `AddressPrediction("vault", …)` | an extra transaction slipped between the AMPS and vault deployments | start from a clean deployer nonce; nothing is salvageable, the salt is bound to the wrong vault |
| `WeakAmpsSalt` | `AMPS_SALT` was mined against a different vault or to fewer zero bytes | re-mine with `script/mine-amps.py --vault $PREDICTED_VAULT` |
| `TimelockNotBootstrappable` | the timelock is already finalised, or the deployer is not a proposer | this is not a deployment any more; make the change as a Safe proposal |
| `CoverageMissing` | step 3's thirty minutes have not passed | wait, then re-run `09` |
| `GateNotGreen` | a feed is stale, the session is closed, or the hub ring is short | read `OracleGate.state(0)` and `docs/keeper-runbook.md` §4 |
| `AlreadyGenesis` | `09_Phase3Wire` re-run after genesis | expected; later moves are governance proposals |
| `PlaceholderAddress` | a constituent still carries a Phase 0 `TODO` | fill in `constituents.json`, or drop the name from this deployment |
| `CellBudgetExhausted` | more than `MAX_LIVE_CELLS` (512) cells | `docs/phase3-state-model.md` §12 ruling E; the registry cannot carry this many pools at this ladder shape |
