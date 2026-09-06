# @amplestocks/keeper

The permissionless bountied upkeep service for Amplestocks. TypeScript, viem 2, Node 22.

It runs five calls on `AmpsVault` and no others:

| Job | Paid from `BountyPot`? |
|---|---|
| `compound(poolId)` | yes |
| `rollout(constituentId)` | yes |
| `deployBonded(constituentId)` | yes |
| `checkpoint()` | no, by design |
| `touch()` | no, by design |

**It never re-centres and never re-widens a ladder.** No vault entry point could, and none ever will —
placements are made once and consumed (`docs/phase3-state-model.md` §3, invariant I35). `AmpsHook`'s
`RebalanceNeeded` is a notification that the fee schedule reacted; the answer to it is a `compound`.

**Nothing here is trusted.** Every job is permissionless: if this process stops, anyone else's keeper does the
same work and collects the same tip. The protocol's only loss from a keeper outage is time.

It **watches** more than it acts on: every pool's `AmpsHook` state — the surge in force, the high-water tick
the next buyback burn will consume, how long since the pool last traded — is read every scan and exported as
metrics, and none of it changes a decision. `RebalanceNeeded` is in that category too.

Operations, alerts and the gate-state table: **`docs/keeper-runbook.md`**.

## Running it

```sh
pnpm --filter @amplestocks/keeper start        # a service
AMPS_ONCE=1 pnpm --filter @amplestocks/keeper start   # one scan, then exit
```

Configuration is entirely environment — see `.env.example` and the runbook's §4. The keeper is told **one**
address, AMPS, and resolves the rest from the chain each scan (`Amps.vault()`, then the vault's pointer set),
so an `emergencyMigrate` or a policy repoint is followed without a restart.

Docker: `docker build -f apps/keeper/Dockerfile -t amplestocks/keeper .` from the repository root, and
`docker compose up -d` in this directory for the relayer + keeper + Prometheus + Grafana sketch.

## Layout

```
src/
├─ index.ts            entry point and the public surface
├─ config.ts           the environment schema; no endpoint or address is ever a literal in a code path
├─ logger.ts           one JSON object per line
├─ metrics.ts          a small Prometheus registry and the keeper's metric set
├─ server.ts           GET /metrics, /healthz, /readyz
├─ runner.ts           the scan loop: read -> screen -> simulate -> qualify -> send
├─ domain/             PURE. No viem, no node, no clock.
│  ├─ types.ts         the chain snapshot, the jobs, the verdicts
│  ├─ policy.ts        the thresholds, all from Constants.sol
│  ├─ bounty.ts        BountyPot._quote and the section 3.6 fee split, mirrored
│  └─ decide.ts        screen() and qualify() — the decision, and what the CRE mirror shares
├─ chain/
│  ├─ clients.ts       viem clients and the chain definition
│  ├─ reader.ts        every read; the topology is resolved, never configured
│  └─ submitter.ts     OpenZeppelin Relayer, with a local-signer fallback for anvil
├─ jobs/index.ts       calldata, simulation and revert decoding
└─ cre/                the Chainlink CRE mirror — see cre/README.md
```

`domain/` is pure on purpose: the same `screen()` runs in the service, in the unit suites, and inside the CRE
workflow, so "the CRE mirror matches the keeper" is one function called from two places.

## Tests

```sh
pnpm --filter @amplestocks/keeper test        # unit suites, offline, ~2 s
pnpm --filter @amplestocks/keeper test:chain  # + the anvil suite; needs Foundry 1.8.1
```

The chain suite spawns anvil, stands the whole production system up through
`test/chain/KeeperFixture.s.sol` (`AmpsVault`, `AmpsHook` mined to `0x38C0`, `OracleGate`, `PoolRegistry`,
`BountyPot`, the four linked vault libraries, the three policies, six pools, four constituents) and drives the
keeper against it: a fee accrual makes `compound` fire with the right bounty, a bonded deposit above the
threshold makes `deployBonded` fire, a frozen or degraded gate stops everything, a diverged pool is refused,
the cooldown is waited out, a stale checkpoint is refreshed, a tripped watchdog is healed by `touch`, a
48-hour gap resumes with no duplicate send, and a synthetic spam campaign is blocked outright.

It is opt-in (`AMPS_KEEPER_CHAIN_TESTS=1`) because the CI `node` job does not install Foundry, and it takes
about eleven minutes: a minute of Solidity compilation, a minute standing the system up, and the rest driving
real transactions through 20 drills.

## Two things the contracts cannot do, and what the keeper does instead

`VaultPlacementLib` and `VaultRolloutLib` pass **hardcoded** `WORK_VALUE_USD18 = 1e18` and
`GAS_ALLOWANCE_USD18 = 1e18` to `BountyPot.pay`, and the three entry points take no argument that could carry
anything else. Two consequences, both covered in the runbook's §3:

1. **`BountyPot`'s `chost` guard cannot fire** (`1e18 < 1e18` is false), so an empty `compound()` is paid the
   full tip. The keeper applies its own dust guard to the work it measured.
2. **The 3x gas cap is inert**, so "the keeper reports measured gas to make the cap live" has no channel. The
   keeper measures it and publishes it — `amps_keeper_measured_gas_allowance_usd` against
   `amps_keeper_reported_gas_allowance_usd` — which is what governance needs to size `tip` and `chipBps`.

MIT licensed — see the repository root `LICENSE`.
