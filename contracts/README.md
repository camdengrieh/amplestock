# Amplestocks contracts

Foundry package for the $AMPS protocol on Robinhood Chain (chain id 4663, testnet 46630).

## Toolchain

| Component | Pin | Notes |
|---|---|---|
| Foundry | 1.8.1 (pinned in CI) | `forge`, `cast`, `anvil` |
| solc | 0.8.30 (pinned in `foundry.toml`) | evm `cancun`, `bytecode_hash = "none"`, optimizer 1,000,000 runs |
| forge-std | 1.16.2 | `lib/forge-std` |
| OpenZeppelin uniswap-hooks | 1.2.2 | `lib/uniswap-hooks` (`BaseHook`); nests v4-core 1.0.2 and v4-periphery 1.0.3 |
| OpenZeppelin Contracts | 5.7.0 | `lib/openzeppelin-contracts` |
| hookmate | 0.6.0 | pre-compiled v4 artifacts used only in tests |

Every source and test file pins `pragma solidity 0.8.30;` and carries `// SPDX-License-Identifier: MIT`.

### Why tests never import `PoolManager.sol`

Uniswap v4-core pins `solc =0.8.26`, which cannot share a compilation graph with our 0.8.30 sources. Tests therefore
deploy the PoolManager, PositionManager, Permit2 and the v4 swap router from hookmate's pre-compiled artifacts through
`test/utils/V4TestBase.sol`. Importing `@uniswap/v4-core/src/PoolManager.sol` or `@uniswap/v4-core/test/utils/Deployers.sol`
breaks the build. Importing v4-core libraries (`Hooks`, `TickMath`, `StateLibrary`, `SqrtPriceMath`, `LPFeeLibrary`,
types and interfaces) is fine; they are MIT.

## Commands

```bash
export PATH=$HOME/.foundry/bin:$PATH
forge build
forge test                       # default profile: 512 fuzz runs
FOUNDRY_PROFILE=ci forge test --isolate
forge fmt --check
forge coverage --report lcov
```

When several agents or shells build concurrently, give each its own output directory so the cache is never shared:

```bash
FOUNDRY_OUT=out-<name> FOUNDRY_CACHE_PATH=cache-<name> forge test
```

`out-*` and `cache-*` are git-ignored.

## Layout

```
src/token/Amps.sol            fixed-balance share token (mint/burn by the vault only)
src/lib/PriceLib.sol          8-dec Chainlink / 18-dec / 6-dec / sqrtPriceX96 / tick conversions, AMPS always currency0
src/lib/LadderLib.sol         static ask/bid ladder maths (doubling buckets, tilt weights, liquidity)
src/lib/TruncatedOracleLib.sol per-pool truncated cumulative-tick observations (30-minute TWAP, high-water tick)
src/interfaces/               minimal external interfaces (Chainlink aggregator)
test/utils/V4TestBase.sol     local v4 stack from hookmate artifacts
test/mocks/                   MockStockToken (uiMultiplier, denylist, pause, reentrancy), MockAggregator, MockNavSource
test/{unit,fuzz,gas}/         suites; gas/baseline.json is the CI regression reference
script/                       deployment and mining scripts; script/config holds mined salts and addresses
test/script/                  fork-free dry run of the deployment scripts against a local PoolManager
```

## Deployment

`docs/deploy-runbook.md` is the runbook: the numbered pipeline, the library-linking flags, the bootstrap order the
contracts force, the broadcast rule, verification, and what is still placeholder config pending Phase 0.
`docs/launch-runbook.md` is the guarded mainnet launch: genesis, the capped start, the TVL ratchet, who signs
what, and the incident runbooks.

### The pipeline

| script | what it does |
|---|---|
| `script/00_Preflight.s.sol` | reads the chain and reports: chain id, ArbOS, `maxTxGasLimit`, code at every configured address (CREATE2 factory included), the PoolManager code hash, TSTORE/TLOAD acceptance, every feed's `latestRoundData` and Standard-vs-SVR proxy shape, AMPS ordering. Deploys nothing, sends nothing |
| `script/01_MineAmps.s.sol`, `script/mine-amps.py` | the AMPS CREATE2 salt: three leading zero bytes, so AMPS is `currency0` in all 32 pools |
| `script/02_Libraries.s.sol` | the four linked vault libraries, in two passes |
| `script/03_Core.s.sol` | the `TimelockController`, `Amps`, `AmpsVault`, `AmpsHook`, `PoolRegistry` and the whole periphery, plus the set-once wiring; records every address and every constructor argument. `CORE_STAGE=finalize` hands governance over |
| `script/04_MineHook.s.sol` | the `0x38C0` hook salt; the standalone re-check CI runs after every dependency bump |
| `script/05_Registry.s.sol` | the 32 pools, 30 bond markets and the launch index weight vector |
| `script/09_Phase3Wire.s.sol` | the Phase 3 pointer moves and the `OracleGate`, in the §9.1 bootstrap order |
| `script/10_TestnetPools.s.sol` | the same shape against mocks on a test chain; **is** a `05_Registry` rather than owning one |
| `script/11_GenesisPlacement.s.sol` | `genesis()` and the §3.3 ladders, in two phases sixty seconds apart |
| `script/12_Verify.s.sol` | the Blockscout `forge verify-contract` commands, with the right constructor args and `--libraries` |

`script/lib/Gov.sol` is how every script makes a governed call — directly when the timelock is an address you
control, or `schedule`+`execute` through a real `TimelockController` when it is not. `script/lib/Calendar.sol`
holds the DST and NYSE holiday tables `OracleGate` has no getter for.

### The broadcast rule

Under Foundry 1.8.1 a `vm.startBroadcast` window opened by a **helper contract** writes every transaction with the
same nonce, and the run dies with `EOA nonce changed unexpectedly`. Simulation is unaffected, so `forge test`
cannot see it. Every broadcast window and every state-changing call must therefore belong to the contract
`forge script` was pointed at; helpers are `internal` libraries, or `pure`/`view` contracts created outside every
window. `test/script/broadcast.sh` is the harness that proves it:

```bash
pnpm --filter @amplestocks/contracts broadcast-test
```

It starts an anvil, runs the whole pipeline with `--broadcast` through a real `TimelockController`, asserts the
chain state with `cast`, runs it all again and asserts nothing moved, then finalises the timelock. About three
minutes, localhost only, and its own CI job.

### Library linking

`AmpsVault` reaches four **deployed** libraries by `DELEGATECALL`, so an unlinked artefact carries `__$...$__`
placeholders and cannot be deployed. Every command that builds, deploys, measures or verifies the vault takes all
four flags, which `script/02_Libraries.s.sol` prints and records in `script/config/libraries.json`:

```
--libraries src/vault/VaultNavLib.sol:VaultNavLib:0x...
--libraries src/vault/VaultRedeemLib.sol:VaultRedeemLib:0x...
--libraries src/vault/VaultPlacementLib.sol:VaultPlacementLib:0x...
--libraries src/vault/VaultRolloutLib.sol:VaultRolloutLib:0x...
```

They are deliberately **not** in `foundry.toml`'s `libraries` key: that would pin one chain's addresses into every
build, `forge test` included, where Foundry deploys its own copies at its own addresses. `03_Core` proves the
link on the deployed vault rather than assuming it.
