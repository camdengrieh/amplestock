# Amplestocks ($AMPS)

AMPS is a fixed-balance ERC-20 share of a protocol-owned index of tokenised equities on Robinhood
Chain (4663). One immutable Uniswap v4 hook serves 32 protocol-owned-liquidity pools: 30
`AMPS/<stock>` spokes plus `AMPS/WETH` and `AMPS/USDG` entry pools. The vault holds the basket,
prices it from Chainlink equity feeds, and publishes a fully diluted NAV per share; pro-rata
redemption at NAV minus a 1% fee is unpausable, so NAV is a hard floor while the market sets any
premium above it. All 32 pools are POL-only, so 100% of swap fees accrue to NAV. A 5% sell fee (band
1–6%) is charged in AMPS and split creator → xAMPS stakers → burn → re-laddered as asks; buys are
cheap (5–30 bp). Genesis is 5,000 AMPS against $5,000 of seed liquidity — $1.00 per share — with 5%
vesting to the team and 95% placed as a 1.25×-per-doubling ask ladder. After genesis the only path
that increases supply is discounted, vesting bonds against registered collateral. The constituent
set, fees and bond parameters are timelocked state; the contracts themselves are immutable bytecode.

**Status: Phase 1 (monorepo scaffold).** No production Solidity is written yet, no contract is
deployed, and every address in `packages/config` is marked for on-chain re-verification.

## Repository layout

```
amplestock/
├─ contracts/          Foundry workspace — solc 0.8.30, evm_version=cancun, tests run --isolate
│  ├─ src/             production Solidity (token, vault, hook, bonds, staking, policy, oracle, registry)
│  ├─ script/          deploy and preflight scripts
│  ├─ test/            unit / fuzz / invariant / fork / attack / gas
│  └─ lib/             git submodules: forge-std, uniswap-hooks (+ v4-core, v4-periphery), OZ, hookmate
├─ packages/
│  ├─ config/          @amplestocks/config — chains, address book, launch token list, launch parameters
│  ├─ abis/            @amplestocks/abis — wagmi CLI codegen from contracts/out (no output committed yet)
│  └─ quant/           amplestocks-quant — Phase 0B backtests and parameter sweeps (Python)
├─ apps/
│  ├─ web/             dApp (Next.js + wagmi + viem) — placeholder
│  ├─ indexer/         Ponder indexer — placeholder
│  └─ keeper/          compound / rollout / bounty keeper (viem) — placeholder
├─ scripts/
│  └─ licence-gate.py  SPDX gate over the production import graph
└─ .github/workflows/ci.yml
```

## Build and test

Requires Node 22 (`.nvmrc`), pnpm 10.33, Python 3.11 and Foundry.

```bash
# JS/TS workspace
pnpm install
pnpm build          # turbo run build   (^build ordering)
pnpm test           # turbo run test
pnpm typecheck
pnpm lint

# contracts
cd contracts
forge build --sizes
forge fmt --check
FOUNDRY_PROFILE=ci forge test --isolate --no-match-path 'test/gas/*'
forge test --match-path 'test/gas/*'      # gas gate: NEVER --isolate (see below)
forge coverage --no-match-path 'test/gas/*' --report lcov

# licence gate — builds its own --build-info artifacts if none are usable
pnpm licence-gate                                     # == --out out-licence --cache cache-licence
python3 scripts/licence-gate.py --out out-mono        # read an artifacts dir you already built
python3 scripts/licence-gate.py --no-build            # never shell out to forge (exit 2 if unusable)
```

The gas suite is the one thing that must **not** run under `--isolate`: isolation changes
storage warm/cold accounting, so isolated numbers cannot be compared against
`contracts/gas/baseline.json`, which is measured from a normal transaction. The suite fails if any
measurement exceeds baseline x 1.2, and logs SKIP if the baseline file is absent.

If you run Foundry while another agent or process is building the same tree, use a private artifacts
directory so you do not share `out/` and `cache/`:

```bash
FOUNDRY_OUT=out-mono FOUNDRY_CACHE_PATH=cache-mono forge build --build-info
```

## Licence policy

Everything in this repository is **MIT** (`LICENSE`, copyright 2026 Amplestocks contributors), and
every source file carries an SPDX header.

The hard rule: **no BUSL-1.1, AGPL-3.0, GPL-2.0 or GPL-3.0 code may be reachable from
`contracts/src/**`** — not by import, not by copy, not by line-by-line port. Mechanisms described in
such projects (Olympus v2 and Bond Protocol bond markets, both AGPL-3.0) are used as reference only
and reimplemented from scratch. Uniswap v4-core is a mixed-licence repository: its interfaces,
types and libraries are MIT and we import them; its `PoolManager` implementation is BUSL-1.1 and we
only ever talk to the already-deployed instance through the MIT `IPoolManager` interface. Tests may
use hookmate's prebuilt v4 artefacts (MIT wrapper, compiled Uniswap bytecode inside) — `test/` and
`script/` are exempt from the rule, but the gate still reports what they pull in.

`scripts/licence-gate.py` enforces this mechanically: it reads Foundry's `--build-info` output,
walks the real import graph out of `contracts/src/**`, reads each file's SPDX header, and exits
non-zero on a forbidden licence or a missing header. It runs on every push and pull request. See
[`NOTICES.md`](./NOTICES.md) for the full attribution record.

**Known trap.** Two convenient v4-core helpers are MIT but import BUSL-1.1 files, so importing
either from `contracts/src/**` fails the gate:

| MIT helper | pulls in (BUSL-1.1) |
|---|---|
| `v4-core/src/libraries/StateLibrary.sol` | `libraries/Position.sol` |
| `v4-core/src/libraries/TransientStateLibrary.sol` | `libraries/Lock.sol`, `CurrencyReserves.sol`, `NonzeroDeltaCount.sol` |

Production code must read pool state through `extsload`/`exttload` against the MIT `IExtsload` /
`IExttload` interfaces with our own slot arithmetic in `PriceLib`, and keep `StateLibrary` to
`test/` and `script/`. The BUSL files in v4-core are `PoolManager.sol`, `libraries/{Pool, Position,
Lock, CurrencyDelta, CurrencyReserves, NonzeroDeltaCount}.sol` and `test/ProxyPoolManager.sol`;
everything else we import is MIT.
