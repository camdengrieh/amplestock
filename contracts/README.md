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
```

Later phases add `src/vault/AmpsVault.sol`, `src/hook/AmpsHook.sol`, `src/bonds/AmpsBonds.sol`,
`src/staking/AmpsStaking.sol`, `src/policy/*`, `src/oracle/*`, `src/registry/PoolRegistry.sol`,
`src/keeper/BountyPot.sol` and `src/periphery/AmpsQuoter.sol` as described in the implementation plan.
