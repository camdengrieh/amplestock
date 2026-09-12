# Fizz Suite

A stateful fuzz harness for the Amplestocks protocol, driven by **Medusa**. It reuses
`test/integration/Phase3Fixture.sol` verbatim: the whole Phase 3 world — the real `Amps`, `AmpsVault` behind its
four linked libraries, the real `AmpsHook` at a `0x38C0`-shaped CREATE2 address, `PoolRegistry`, `AmpsBonds`,
`BountyPot`, `OracleGate` + `FeedRegistry`, the four policies, `LadderPositionValuer`, `AmpsQuoter` and
`AmpsRouter`, on a local Uniswap v4 stack with 32 pools and the §3.3 genesis ladders in place — is built by
`FuzzTester`'s constructor.

## What Is Here

- `Base.sol`: `is StringUtils, Clamp, Deployer, Math, Phase3Fixture`. `setup()`, the three actors and their
  balances, the roles (timelock / guardian / keeper), the cached pool list, the shared clamping helpers, and the
  Medusa-safe overrides of the fixture (see *Medusa cheatcodes* below)
- `Snapshots.sol`: before/after state capture used by properties (minimal until Step 9)
- `Properties.sol`: global and function-specific invariants (empty until Step 9)
- `handlers/`: protocol actions exposed to the fuzzer, one file per target contract
- `utils/`: shared helper libraries, assertions, clamping logic, math helpers, deploy helpers, logging, and mocks.
  **`utils/Hevm.sol` is deliberately unused** — see below
- `FuzzTester.sol`: the Medusa entry point; its constructor is the whole world
- `FoundryTester.sol`: Foundry harness for quick debugging, gas measurement and local repros

## Inheritance Chain

```
Base (is StringUtils, Clamp, Deployer, Math, Phase3Fixture)
        └─► Snapshots (is Base)
              └─► Properties (is PropertiesAsserts, Snapshots)
                    └─► <Contract>Handler (is Properties)   — one per target contract
                          └─► Handlers (is <all handlers>)  — aggregator + actor switching
                                ├─► FuzzTester (is Handlers)     — Medusa entry point
                                └─► FoundryTester (is Handlers)  — Foundry quick debug/PoC entry point
```

`Phase3Fixture` descends from `V4TestBase`, which descends from forge-std's `Test`. Two consequences:

- **`vm` comes from forge-std.** `CommonBase` already declares `vm` at the cheatcode address, so no file in this
  suite may import the file-level `vm` constant from `utils/Hevm.sol`; two declarations in one inheritance graph do
  not compile. `utils/Hevm.sol` is left in place as scaffold, unused.
- **`FoundryTester` does not inherit `Test`.** It gets it through `Handlers`.

## Medusa cheatcodes (1.5.1, this sandbox)

Probed directly against the binary. **Implemented**: `chainId`, `warp`, `roll`, `prank`, `startPrank`, `stopPrank`,
`etch`, `store`, `load`, `label`, `getNonce`, `deal`, `toString`, `assertTrue`. **Not implemented**:
`getBlockTimestamp`, `getBlockNumber`, `computeCreateAddress`, `assume`, `snapshot`.

The fixture uses the first three of the missing ones on the `setup()` path, so `Base.sol` overrides
`warpBy`, `advance`, `refreshGateCache` (they read `block.timestamp` / `block.number` instead) and `_deployCore`
(it computes the CREATE address from RLP in `Base.computeCreate`). Those four functions were made
`internal virtual` in `Phase3Fixture.sol`; nothing else in the fixture changed, and the Phase 3 suites still get
the cheatcode versions.

`setup()` also calls `vm.chainId(31337)` first: `V4TestBase.deployV4()` only deploys a *fresh* v4 stack on Anvil's
chain id, and would otherwise point `poolManager` at an empty mainnet address.

Two more Medusa facts this harness depends on, both established by the same probe:

- Medusa **segfaults with `coverageEnabled: false`** (`panic: runtime error: invalid memory address or nil pointer
  dereference` in `fuzzing/coverage.(*CoverageTracer).SetInitialContractsSet`, `coverage_tracer.go:123`). Leave
  coverage on.
- `chainConfig.codeSizeCheckDisabled` covers **EIP-3860** as well as EIP-170: a probe contract with 160,887 bytes of
  init code deployed and its constructor ran. That matters here because `FuzzTester`'s runtime is only 35,020 bytes
  but its **init code is 156,304 bytes** — the whole v4 stack, the `Amps`/`AmpsHook` creation code and the hookmate
  artifact blobs are constructor-time data.

## Permit2 is a `STOP` stub, and every call into it is routed around

`V4TestBase._deployPermit2` installs Permit2's runtime at its canonical address with `vm.etch`, and **code
installed that way is not reliably callable in Medusa 1.5.1**. Probed directly: with a one-byte `STOP` etched at an
address, empty calldata and a 36-byte call return normally, while a 68-byte and a 132-byte call both fail with
`vm error ('stack underflow (0 <=> 2)')`, in either order. On the real world that was
`Failed to initialize the test chain` on the first `permit2.approve` (132 bytes of calldata) inside `deployToken`.

So `Base` does two things: `_stubPermit2()` puts one `STOP` byte at the canonical address before `deployV4()` runs,
so the fixture skips etching 20 kB of Permit2 runtime; and `_deployAssets` / `approveStack` are overridden to drop
the two `permit2.approve` legs entirely. The ERC-20 `approve` calls that merely *name* Permit2 as a spender are
kept — those are ordinary token calls.

**Consequence:** the ordinary v4 `swapRouter` path is dead in this harness, because it pulls through Permit2. No
handler uses it — every trade goes through `AmpsRouter`, which pulls with `IERC20.safeTransferFrom` — but
`Phase3Fixture.buyAmps` / `sellAmps` / `rotate` cannot be used until this is solved.

## Medusa's per-file coverage misses contracts with immutables

The lcov reports **0 lines hit** for `AmpsVault`, `AmpsHook`, `AmpsBonds`, `PoolRegistry`, `OracleGate`,
`AmpsRouter`, `Amps`, `BountyPot` and `FeePolicy`, while `BondPolicy` (71%), `RolloutPolicy` (55%), `LadderLib`
(26%), `PriceLib` (38%) and `MockStockToken` (23%) — deployed in the same constructor — report real coverage. The
discriminator is immutables, exactly: `FeePolicy` has 7 and reports 0%; `BondPolicy`, `RolloutPolicy` and
`LadderPolicy` have none and report real numbers. A contract with immutables has runtime code that differs from its
artifact, so Medusa cannot match it back to a source map.

Drive coverage work off the **aggregate `branches` counter** and targeted `FoundryTester` probes, not off per-file
percentages.

## Pranks: single-shot, never `startPrank`

`asActor` / `asAdmin` / `asGuardian` / `asKeeper` are `vm.prank`, not `vm.startPrank` + `vm.stopPrank`, and that is
load-bearing rather than stylistic. Every function carrying one of them makes exactly one external call, and a fuzz
handler reverts as a matter of course. With `startPrank`, a revert inside the body skips the modifier's trailing
`stopPrank` and the prank stays armed: the next handler fails with *"vm.prank: cannot override an ongoing prank"*
and everything after it acts as the wrong account. That is not hypothetical — it is what `test_sequence` did before
the change, where the deliberately-reverting `FeedRegistry.refresh` on an unknown token leaked its prank into the
next step. Where a body genuinely needs two pranked calls (`BountyPot.fund`, which approves and then funds), it uses
two single-shot pranks rather than one window.

The same rule applies to guards: never `return` early from inside a `startPrank` window. `AmpsVaultHandler`'s
`place` uses an explicit `vm.prank` for exactly that reason.

## Handlers

Primary-tier entry points get their own clamped and unclamped handlers; secondary-tier ones sit behind a
`<contract>_secondary(uint8 selector, ...)` dispatcher, which is what keeps their call frequency low.

| File | Clamped / stress | Unclamped | Dispatcher | Pranked as |
|---|---|---|---|---|
| `AmpsRouterHandler` | `buy_clamped`, `buy_dust`, `sell_clamped`, `sell_full`, `rotate_clamped`, `rotate_spokeToSpoke` | `buy`, `sell`, `rotate` | — | actor |
| `AmpsVaultHandler` | `checkpoint`, `touch`, `compound`, `rollout`, `deployBonded`, `redeemProRata` (+ `_full`, `_dust`), `donateERC20`, `donateETH` | same six | `ampsVault_secondary`: `place`, `setLadderShape`, `setRedeemFeeBps`, `setRolloutParams`, `withdrawRetiredBids` | keeper for the three bountied paths, actor for the stamps and the redemption, **timelock** for the dispatcher |
| `AmpsBondsHandler` | `bond_clamped`, `bond_dust`, `bond_full`, `claim_clamped`, `claimAll_clamped` | `bond`, `claim`, `claimAll` | `ampsBonds_secondary`: the five banded bond parameters | actor; **timelock** for the dispatcher |
| `OracleGateHandler` | — | the four pokes and the four freezes | `oracleGate_secondary` (8) and `env_secondary` (warp, moveFeed, stepMultiplier, pause the issuer's beacon) | actor for the pokes, **guardian** for the freezes, unpranked for the mocks this contract owns |
| `FeedRegistryHandler` | — | `refresh`, `refreshMany`, `refresh` on an unknown token | `feedRegistry_secondary` | actor (permissionless) |
| `PoolRegistryHandler` | — | `retireConstituent`, `reinstateConstituent`, `setIndexWeights` | `poolRegistry_secondary` | **timelock** |
| `AmpsHookHandler` | — | `setAmpsFeeBps`, `setBuyFeeBps` | `ampsHook_secondary` | **timelock** |
| `AmpsHandler` | — | `transfer`, `transferAll`, `approve` | `amps_secondary` | actor |
| `BountyPotHandler` | — | `fund`, `fundDust` | `bountyPot_secondary` | actor (permissionless) |

`Handlers.sol` inherits all nine and adds `setCurrentActor(uint256)`.

### The rotation direction rule

`AmpsRouter.rotate` needs at least one leg to be a constituent's spoke (`NotARotation` otherwise), so the clamped
rotation draws **hop 1** from `spokePools` and hop 2 from the two entry pools. Getting it the other way round is a
dead end worth stating: a spoke's genesis ladder is asks only (`SPOKE_SEED_AMPS` above the tick, nothing below it),
so an AMPS sell *into* a spoke walks straight to the tick floor and the hook's outer rail refuses it —
`WrappedError(hook, …, BeyondRail(poolId, …), HookCallFailed())`. `rotate_spokeToSpoke` keeps probing the canonical
`stock -> AMPS -> stock` shape anyway: it starts landing once `deployBonded` has put bonded collateral under hop 2's
tick, which makes it a live signal that the bond→deploy path worked. `test_sequence` shows exactly that — it refuses
before `deployBonded` and succeeds after it.

## Numbers

| | |
|---|---|
| `spokeCount()` | 30 (`Base.FIZZ_SPOKES`) → 32 pools, 328 genesis ladder cells |
| `setup()` gas | **545,379,298** (`forge test --match-test test_setupGas -vv`) |
| `FuzzTester` | 156,304 B init code, 35,020 B runtime |
| `FoundryTester` | 320,440 B runtime (it calls `setup()` from `setUp()`, so the v4 artifact blobs land in the runtime rather than the init code) |
| `medusa.json` `blockGasLimit` | 2,000,000,000 |
| `medusa.json` `transactionGasLimit` | 700,000,000 (above `setup()`, so it cannot be the binding limit on deployment whichever of the two Medusa uses) |
| `medusa.json` `targetContractsBalances` | `0xd3c21bcecceda1000000` (1e24 wei). The scaffold's `0xffff…ffff` (2^192−1) is **more than Medusa's deployer holds** and fails chain init with `insufficient funds for gas * price + value` |
| `slither` | disabled — not installed in this sandbox |
| Smoke campaign | 20,071 calls / 198 sequences in 88 s, `failures: 0/198`, branches **9,687 → 17,044**, corpus 287, ~500 M gas/s |
| Compile cost | ~13 min for a change to `Base.sol`; `crytic-compile --foundry-compile-all` (a forced `forge build --build-info`) measured 31m52s |

`FIZZ_SPOKES` is the throughput lever: 32 pools make every `_previewNav`, every placement and every
`redeemProRata` iterate the full pool set. Drop it to 8 if a coverage campaign needs call throughput more than it
needs the launch width.

## Related Paths Outside This Directory

- `../../fizz_data/`: extracted ABI inventory, entry-point selection, corpora, logs and coverage outputs
- `../../medusa.json`: Medusa config for this suite (targets `FuzzTester`)
- `../../medusa.phase3.json`: the *other* campaign's config (`Phase3InvariantTest`). Not this suite's
- `../../echidna.yaml`: Echidna config. **Echidna is not installed in this sandbox**; the config is kept for
  parity but has not been exercised
- `../integration/Phase3Fixture.sol`: the world
- `../invariant/Phase3Handler.sol`, `Phase3VaultHandler.sol`: the Foundry invariant campaign's handlers, which are
  the ground truth these handlers were ported from

## How To Run

From `contracts/`, always under the build lock (one via-IR build at a time on this box):

```bash
export PATH=/root/.foundry/bin:$HOME/.local/bin:$PATH

# compile
flock /tmp/amps-forge.lock nice -n 10 forge build

# the Foundry gates
flock /tmp/amps-forge.lock nice -n 10 forge test --match-contract FoundryTester -vv
flock /tmp/amps-forge.lock nice -n 10 forge test --match-test test_setupGas -vv   # constructor gas

# Medusa (crytic-compile runs `forge build --build-info --force` first: budget ~15 min)
flock /tmp/amps-forge.lock nice -n 10 medusa fuzz --config medusa.json
#   or, with the skill's wrapper (log file + plateau detection):
flock /tmp/amps-forge.lock nice -n 10 \
  node ../.claude/skills/fizz/scripts/run_medusa.js "$PWD" --meta-dir fizz_data --timeout 600
```

Do **not** run `setup_fuzz_profile.sh`: a `[profile.fuzz]` without `foundry.toml`'s per-path via-IR
`compilation_restrictions` pushes `AmpsVault` past EIP-170. The default profile is the one that works.

## How To Read The Suite

Recommended order:

1. `README.md`
2. `../integration/Phase3Fixture.sol` — the world every handler drives
3. `Base.sol`
4. `handlers/Handlers.sol`
5. individual handler files under `handlers/`
6. `Snapshots.sol`
7. `Properties.sol`
8. `utils/` when you need to understand helper behavior or mocks
9. `FuzzTester.sol`
10. `FoundryTester.sol`
