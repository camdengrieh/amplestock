# @amplestocks/abis

Typed ABIs for every Amplestocks contract, generated from the Foundry artefacts and **committed**.

## Entry point

```ts
import {ampsVaultAbi, contractAbis, eventAbi} from '@amplestocks/abis'
```

| What | Path |
|---|---|
| Package entry (`"."` export, `main`, `types`) | `packages/abis/src/index.ts` |
| Generated ABIs (`"./generated"` export) | `packages/abis/src/generated.ts` |

There is **no build step**. `main` and `types` point at `src/index.ts`, so consumers import TypeScript source
directly; `pnpm --filter @amplestocks/abis build` is a no-op that exists only so `turbo run build` has something
to depend on. A Next.js consumer that transpiles `node_modules` should list `@amplestocks/abis` in
`transpilePackages`.

## What is exported

One `<contract>Abi` const per contract, `as const` so viem and wagmi infer argument and return types:

`ampsAbi`, `ampsVaultAbi`, `ampsHookAbi`, `ampsBondsAbi`, `ampsStakingAbi`, `bountyPotAbi`, `poolRegistryAbi`,
`poolRegistryLensAbi`, `ampsBondsLensAbi`, `oracleGateAbi`, `feedRegistryAbi`, `ampsQuoterAbi`, `bondPolicyAbi`,
`feePolicyAbi`, `ladderPolicyAbi`, `rolloutPolicyAbi`, `ladderPositionValuerAbi`, `poolManagerAbi`.

`poolManagerAbi` is Uniswap v4-core's `IPoolManager`: nothing here deploys a PoolManager, and the indexer
subscribes to `Initialize` / `Swap` / `ModifyLiquidity` / `Donate` on the canonical deployment named in
`@amplestocks/config`.

`src/index.ts` adds three things codegen cannot:

* `contractAbis` — a `Record<AmpsContractName, Abi>` for runtime lookups;
* `contractNames` — the export order, as a typed tuple;
* `eventAbi(abi)` / `abiItem(abi, name)` — narrow an ABI to its events, or find one item by name.

## Regenerating

```sh
pnpm --filter @amplestocks/abis generate
```

Three steps, in order:

1. `node scripts/forge-build.mjs` — runs
   `FOUNDRY_OUT=out-abis FOUNDRY_CACHE_PATH=cache-abis forge build --skip test --skip script` in `contracts/`.
   The dedicated out/cache pair keeps codegen off `contracts/out`, which CI, the gas suite and the invariant
   campaigns all write; both are covered by the root `.gitignore`.
2. `wagmi generate` — `@wagmi/cli` 2.10 against `wagmi.config.ts`.
3. `node scripts/postprocess.mjs` — prepends the SPDX header and the do-not-edit banner. Idempotent.

Requires Foundry 1.8.1 (`FORGE_BIN` overrides the binary). **CI never runs this**: the output is committed, so
the `node` job needs no Solidity toolchain.

### Why not `@wagmi/cli`'s `foundry` plugin

`contracts/foundry.toml` carries three `[[profile.default.compilation_restrictions]]` blocks — `src/vault/*`,
`src/bonds/*` and `src/hook/*` compile through the IR pipeline at 200 optimizer runs so `AmpsVault`, `AmpsBonds`
and `AmpsHook` fit EIP-170. Foundry writes **one artefact per compiler profile**, so a single build leaves
`Amps.json` *and* `Amps.vault.json` side by side, and a file reached only through a restricted profile has no
plain artefact at all: `IPoolManager` exists solely as `IPoolManager.default.json` and `IPoolManager.vault.json`.
The plugin globs `<Name>.json` and derives the contract name from the file name, so it would miss `IPoolManager`
outright and emit a contract called `Amps.vault`.

`scripts/artifacts.mjs` resolves the variants instead, and **asserts every variant of a contract has a
byte-identical ABI** — a compiler profile may change codegen, never the interface — then hands the list to
`@wagmi/cli` through the config's `contracts` field. The CLI still does the generating.

## Tests

```sh
pnpm --filter @amplestocks/abis test
```

`test/exports.test.ts` (13 cases) checks:

* the export set and that no ABI is empty, and that viem can hash every function and event item;
* **the I14 tables**: it parses the classification tables out of `contracts/test/unit/GuardSymmetry.t.sol` — the
  same source `scripts/selector-gate.py` gates CI on — and asserts that every classified mutating selector of
  `AmpsVault` and `AmpsBonds` is in the exported ABI, and that the exported ABI carries no mutating selector the
  enumeration does not classify. A stale ABI is a keeper building calldata for a contract that no longer exists;
* the exact signatures `apps/keeper` encodes (`compound(bytes32)`, `rollout(uint16)`, `deployBonded(uint16)`,
  `checkpoint()`, `touch()`), `BountyPot.quote(uint256,uint256)`, the `OracleGate` reads, and the event sets the
  indexer subscribes to on `AmpsVault`, `PoolRegistry`, `AmpsHook`, `BountyPot` and the v4 `PoolManager`.

MIT licensed — see the repository root `LICENSE`.
