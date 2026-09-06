# Keeper runbook

Operations for `apps/keeper`: what it does, what it refuses to do, what every alert means, and what to do in
each gate state.

> **Nothing in this document is a trust assumption.** Every job the keeper runs is permissionless. If this
> process stops, anyone else's keeper does the same work and collects the same bounty; the protocol's only loss
> from a keeper outage is time. Ladders are static, so trading is unaffected, and bonds and redemption never
> touch the keeper at all.

---

## 1. What it runs

Five calls on `AmpsVault`, and no others.

| Job | Call | Paid? | Fires when |
|---|---|---|---|
| Compound | `compound(bytes32 poolId)` | bounty | a pool's simulated fee collection is worth more than `chost` |
| Rollout | `rollout(uint16 constituentId)` | bounty | the rollout schedule proposes a non-zero move into an ACTIVE spoke |
| Deploy bonded | `deployBonded(uint16 constituentId)` | bounty | idle bonded collateral clears `deployThresholdUsd18` |
| Checkpoint | `checkpoint()` | **no** | the vault checkpoint is older than `AMPS_CHECKPOINT_REFRESH_SECONDS` (1,200 s) |
| Touch | `touch()` | **no** | every `AMPS_TOUCH_INTERVAL_SECONDS` (900 s), and immediately whenever the watchdog has tripped |

**It never re-centres and never re-widens anything.** There is no vault entry point that could, and there never
will be — ladders are placed once and consumed (`docs/phase3-state-model.md` §3, invariant I35). `AmpsHook`'s
`RebalanceNeeded` event is a notification that the fee schedule reacted to a deviation; the keeper's answer to
it is a `compound`, never a range move.

---

## 2. The decision, in order

Two stages. Screening is free (`view` reads only); qualification costs one `eth_call` and one `eth_estimateGas`.

### 2.1 Screening — the placement gauntlet, as far as a view can see it

| # | Check | Refusal reason | Source |
|---|---|---|---|
| 1 | `OracleGate.protocolFreezeUntil() <= now` | `protocol-frozen` | guardian freeze, auto-expires within 7 d |
| 2 | `OracleGate.state(0) == GREEN` | `gate-not-green` / `gate-ref-diverged` | the vault's own `_requireHealthy` |
| 3 | `OracleGate.isPlacementAllowed(poolId).allowed` | `placement-refused` | §3.8 step 2 |
| 4 | `abs(slot0.tick - fairTick) <= 800` | `diverged` | §3.8 step 3, `PLACEMENT_DIVERGENCE_TICKS` |
| 5 | `now >= lastPlacementAt + 60` | `cooldown` (carries `readyAt`) | §3.8 step 6 |
| 6 | `liveCells + headroom <= 512` | `cell-budget` | §12 ruling E |
| 7 | job-specific: idle collateral, rollout weight, checkpoint age | `below-deploy-threshold`, `no-work`, `not-due`, `checkpoint-fresh` | §3.7 |

Steps 1 and 7 of the gauntlet — the transient lock and the R1 post-condition — are invisible to a `view`. They
land in the simulation, below.

`touch()` is screened differently on purpose: **the watchdog is what it exists to clear.** `AmpsVault.touch`
pokes `OracleGate` *before* it checks the gate, and `OracleGate.poke()` stamps the watchdog, so one `touch`
heals a tripped watchdog inside the same transaction and then passes the health check. That is what makes the
keeper self-healing after an outage.

### 2.2 Qualification — after the simulation

| # | Check | Refusal reason |
|---|---|---|
| 1 | the `eth_call` succeeded (R1, exit divergence, `sweepClean`, the lock) | `simulation-reverted` |
| 2 | unpaid jobs stop here and are sent | — |
| 3 | measured work value `>= chost` | `below-chost` |
| 4 | the pot's rolling daily ceiling is not exhausted | `daily-ceiling` |
| 5 | the pot can pay something (unless `AMPS_RUN_UNPAID=1`) | `pot-depleted` |
| 6 | `bounty >= gasEstimate x basefee x ethUsd x (1 + margin)` | `unprofitable` |

**Work value** is measured, not taken on trust:

* `compound` — `(ampsFees + boughtBack) x P_ref`, where `boughtBack = burned - burnCut` and `burnCut` comes
  from re-running §3.6 step 5's split client-side. Counter-side fees are not returned by the call and are not
  counted, so the measure is a lower bound — the safe direction for a dust guard.
* `rollout` — `moved x P_ref`.
* `deployBonded` — the placed slice of the idle collateral, valued at the feed.

---

## 3. Two contract-side gaps the operator has to know about

Both are v1 facts, not bugs the keeper can fix, and both are why the keeper carries guards the contracts appear
to have already.

### 3.1 `BountyPot`'s `chost` dust guard cannot fire

`VaultPlacementLib` and `VaultRolloutLib` pass **hardcoded private constants** to `BountyPot.pay`:

```solidity
uint256 private constant WORK_VALUE_USD18    = 1e18;   // $1, flat
uint256 private constant GAS_ALLOWANCE_USD18 = 1e18;   // $1, flat
```

`BountyPot._quote` refuses when `workValueUsd18 < chostUsd18`, and `1e18 < 1e18` is false at the launch `chost`
of $1. So **a `compound()` on a pool with zero accrued fees is paid the full tip**, and on-chain a spam
campaign is bounded only by the 60-second per-pool cooldown ($0.07 per pool per minute) and the $25 daily
ceiling.

The guard that works is the keeper's own, applied to the work value it measured. `test/chain.test.ts` runs
twenty consecutive scans against an idle chain and asserts the pot is untouched.

*Governance levers:* raise `chostUsd18` (it still cannot fire), or lower `dailyCeilingUsd18` to bound the loss.
*The real fix is v2:* give the three entry points a `workValueUsd18` argument, or have the libraries compute it.

### 3.2 The 3x gas cap is inert, so the keeper reports gas as a metric instead

The plan asks Phase 4's keeper to "report measured gas to make the cap live". **There is no channel for it**:
`compound`, `rollout` and `deployBonded` take no gas-allowance argument, and the constants above are `private`
in a linked library. `3 x $1 = $3` is far above the `$0.05 + 2% x $1 = $0.07` a job earns, so the cap never
binds and a gas spike is not what stops a job — the keeper's own profitability check is.

What the keeper does instead is measure and publish:

| Metric | Meaning |
|---|---|
| `amps_keeper_measured_work_value_usd` | what the job was actually worth |
| `amps_keeper_reported_work_value_usd` | the flat `$1` the vault reports (always 1) |
| `amps_keeper_measured_gas_allowance_usd` | `gasEstimate x basefee x ethUsd`, i.e. what would make the cap bind |
| `amps_keeper_reported_gas_allowance_usd` | the flat `$1` the vault reports (always 1) |
| `amps_keeper_gas_used` | a histogram of real `gasUsed`, by job |

The gap between the measured and reported series is the input governance needs to size `tip`, `chipBps` and
`gasCapMultiple`, and the evidence for the v2 change.

### 3.3 A note on the launch tip

`docs/phase3-state-model.md` §12 measures `compound` at 1.0–3.3M gas. At the Arbitrum Orbit floor basefee
(0.01 gwei) and $2,500 ETH that is **$0.025–$0.083** of gas against a **$0.07** bounty, and at 0.1 gwei the tip
does not cover the cheapest compound. With `AMPS_ETH_USD18` set, the keeper refuses those jobs (metric
`amps_keeper_unprofitable_total`) rather than working at a loss. `AMPS_ETH_USD18=0` — the default, and the
honest setting until Phase 0 resolves the ETH/USD feed on 4663 — turns the check off and the keeper works
whatever the gas costs.

---

## 4. Configuration

Everything is environment. **No endpoint and no address is a literal in a code path**; the RPC defaults come
from `@amplestocks/config`'s chain records (4663 and 46630), which Phase 0 re-verifies on chain.

The keeper is told **one** address — AMPS — and resolves the rest every scan: `Amps.vault()` names the live
vault, so an `emergencyMigrate` is followed without a redeploy, and the vault names the registry, the bonds,
the staking contract, the bounty pot, the oracle gate and the hook. A governance pointer move is a value that
changes between two scans, not an outage.

| Variable | Default | Notes |
|---|---|---|
| `AMPS_CHAIN_ID` | `46630` | 4663 mainnet, 46630 testnet |
| `AMPS_RPC_URL` | from `@amplestocks/config` | required for any other chain id |
| `AMPS_WS_URL` | from `@amplestocks/config` | reserved; the scan loop is polling |
| `AMPS_TOKEN_ADDRESS` | — | **required** |
| `AMPS_VAULT_ADDRESS` | — | pins the vault instead of reading `Amps.vault()`; fixtures only |
| `AMPS_SENDER_ADDRESS` | — | **required**; the address simulations run as |
| `AMPS_SUBMITTER` | `relayer` | `relayer` or `local` |
| `AMPS_RELAYER_URL` / `_ID` / `_API_KEY` | — | required when `AMPS_SUBMITTER=relayer` |
| `AMPS_RELAYER_SPEED` | `fast` | `safeLow` \| `average` \| `fast` \| `fastest` |
| `AMPS_PRIVATE_KEY` | — | required when `AMPS_SUBMITTER=local`. **anvil only** |
| `AMPS_ETH_USD18` | `0` | zero disables the bounty-versus-gas check |
| `AMPS_SCAN_INTERVAL_SECONDS` | `15` | |
| `AMPS_CHECKPOINT_REFRESH_SECONDS` | `1200` | must stay under `CHECKPOINT_MAX_AGE` = 1,800 |
| `AMPS_TOUCH_INTERVAL_SECONDS` | `900` | must stay well under `GRACE` = 3,600 |
| `AMPS_PLACEMENT_COOLDOWN_SECONDS` | `60` | mirrors `Constants.PLACEMENT_COOLDOWN_SECONDS` |
| `AMPS_PLACEMENT_DIVERGENCE_TICKS` | `800` | mirrors `Constants.PLACEMENT_DIVERGENCE_TICKS` |
| `AMPS_MAX_LIVE_CELLS` / `AMPS_LIVE_CELL_HEADROOM` | `512` / `24` | mirrors `Constants.MAX_LIVE_CELLS` |
| `AMPS_CHOST_USD18` | from `BountyPot.chostUsd18()` | client-side override of the dust guard |
| `AMPS_BOUNTY_MARGIN_BPS` | `0` | require the bounty to exceed gas by this margin |
| `AMPS_RUN_UNPAID` | `false` | keep working when the pot cannot pay |
| `AMPS_ALLOW_REF_DIVERGED` | `false` | the vault permits `REF_DIVERGED`; the keeper does not by default |
| `AMPS_GAS_LIMIT_BUFFER_BPS` / `AMPS_GAS_LIMIT_CEILING` | `2500` / `30000000` | applied to `eth_estimateGas` |
| `AMPS_METRICS_HOST` / `AMPS_METRICS_PORT` | `0.0.0.0` / `9464` | |
| `AMPS_LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` |
| `AMPS_ONCE` | `false` | one scan, then exit |

### The relayer

Production submits through a **self-hosted OpenZeppelin Relayer**. The keeper holds no key: it POSTs to
`POST {url}/api/v1/relayers/{id}/transactions` with a bearer token and polls
`GET .../transactions/{txId}` for the hash. The relayer owns nonce management, replacement and gas bumping,
which is what makes a second keeper instance safe — two processes behind one relayer cannot collide on a nonce.

If your deployment's REST shape differs, `src/chain/submitter.ts` is the only file to change; `Submitter` is a
three-method interface and `runner.ts` never learns which implementation it has.

`AMPS_SUBMITTER=local` signs with `AMPS_PRIVATE_KEY` and exists for anvil and the chain suite. Do not use it in
production: a keeper that holds a key is a keeper whose host is a key custodian.

---

## 5. Metrics

Prometheus text exposition at `GET /metrics`, plus `GET /healthz` (liveness) and `GET /readyz` (fails when the
last completed scan is four intervals old).

**Liveness** `amps_keeper_up`, `amps_keeper_build_info`, `amps_keeper_scans_total`,
`amps_keeper_scan_errors_total`, `amps_keeper_scan_duration_seconds`,
`amps_keeper_last_scan_timestamp_seconds`, `amps_keeper_block_number`.

**Gate** `amps_keeper_gate_state`, `amps_keeper_watchdog_tripped`, `amps_keeper_protocol_freeze_until_seconds`,
`amps_keeper_pool_gate_state{pool}`, `amps_keeper_pool_divergence_ticks{pool}`.

**Hook state, per pool** `amps_keeper_pool_surge_bps{pool}`, `amps_keeper_pool_high_water_tick{pool}`,
`amps_keeper_pool_last_swap_age_seconds{pool}` (`-1` for a pool nobody has traded yet),
`amps_keeper_pool_ladder_cells{pool}` (at most 24; their sum is `amps_keeper_live_cells`). The keeper **watches**
these and acts on none of them: the surge is armed by every placement, so it spikes right after the keeper
itself has run, and the high-water mark is what the next `compound`'s buyback burn will consume — the
simulation already prices it into the work value.

**Vault** `amps_keeper_nav_per_share_usd`, `amps_keeper_checkpoint_age_seconds`, `amps_keeper_live_cells`,
`amps_keeper_live_cell_budget`.

**Pot** `amps_keeper_pot_balance_raw`, `amps_keeper_pot_budget_left_usd`, `amps_keeper_pot_spent_24h_usd`,
`amps_keeper_pot_quote_usd`, `amps_keeper_pot_quote_reason{reason}`.

**Decisions** `amps_keeper_candidates{job}`, `amps_keeper_eligible{job}`, `amps_keeper_skipped_total{job,reason}`,
`amps_keeper_simulations_total{job}`, `amps_keeper_simulation_reverts_total{job,error}`.

**Sends** `amps_keeper_sent_total{job}`, `amps_keeper_confirmed_total{job}`, `amps_keeper_failed_total{job}`,
`amps_keeper_submit_errors_total{job}`, `amps_keeper_in_flight`.

**Bounty and gas** `amps_keeper_gas_estimate{job}`, `amps_keeper_gas_used{job}`,
`amps_keeper_measured_work_value_usd{job}`, `amps_keeper_reported_work_value_usd{job}`,
`amps_keeper_measured_gas_allowance_usd{job}`, `amps_keeper_reported_gas_allowance_usd{job}`,
`amps_keeper_bounty_expected_usd{job}`, `amps_keeper_bounty_paid_usd_total{job}`,
`amps_keeper_unprofitable_total{job}`, `amps_keeper_chost_blocked_total{job}`.

`skipped_total`'s `reason` label is a closed set — every value is in the table in §2 — so a dashboard can
enumerate it. Logs are one JSON object per line on stdout.

---

## 6. What to do in each gate state

`OracleGate.state(0)` is what `AmpsVault._requireHealthy` reads; `stateByPool(poolId)` is what a placement
reads. `amps_keeper_gate_state` carries the ordinal.

| State | Ordinal | What it means | The keeper | The operator |
|---|---|---|---|---|
| `GREEN` | 0 | everything fresh, in session, no divergence | works normally | nothing |
| `DEGRADED` | 1 | a feed is stale beyond its session-scaled `maxAge`, **or the session is CLOSED** | refuses every job | **Usually nothing.** Overnight and every weekend the equity calendar closes and this is the normal state. Investigate only if it persists inside a REGULAR session — then it is a stale feed: check `FeedRegistry.feedStatus(token)` and the aggregator's `updatedAt`, and escalate to the Safe if a feed has genuinely died. Bonds continue at the session haircut; redemption is never affected. |
| `DIVERGED` | 2 | layer E: a pool is beyond `divergenceBps` for `divergenceSustainSeconds` | refuses that pool | Swaps continue and the band is unchanged, by design (I19). Arbitrage should close it. If it persists for hours, the pool's fair price and its feed disagree — check for an unannounced corporate action on that constituent. |
| `REF_DIVERGED` | 3 | layer F: the hub TWAP and `AMPS/WETH x ETH/USD` disagree, so `P_ref` falls back to NAV | refuses by default | The vault *permits* placements here with the NAV anchor forced. Set `AMPS_ALLOW_REF_DIVERGED=1` to match the contract, if you have decided that anchoring at NAV is what you want. The default is not to. |
| `SCHEDULED_FREEZE` | 4 | layer D: a corporate action, or the guardian's protocol freeze | refuses every job | Wait. A corporate-action freeze clears when `effectiveAt` passes; a guardian freeze auto-expires within 7 days and can be lifted early by the Guardian Safe. **Never work around it.** |
| `WATCHDOG` | 5 | layer A: no block or observation for longer than `GRACE` (3,600 s) | sends `touch()`, which clears it | Nothing, if the keeper is running: `touch` is exactly the remedy and it is unpaid, so it always fires. If `amps_keeper_watchdog_tripped` stays at 1 for fifteen minutes the keeper cannot send at all — check the relayer, the sender's ETH balance and the RPC. |

---

## 7. Incidents

### The keeper is down

Nothing breaks. Ladders are static so trading, bonds and redemption are unaffected; fee AMPS accumulates in the
pools' positions and bonded stock accumulates as ERC-6909 claims in the vault. Both queue and are collected on
resumption. **A 48-hour outage is a supported state**, exercised in `test/chain.test.ts`.

On restart the keeper rebuilds every decision from chain state — there is no state it cannot re-read — and
drains the backlog at one job per pool per scan. No duplicate is possible: the vault stamps `_lastPlacementAt`,
and the next simulation reverts `PlacementCooldown` for the following 60 seconds.

A second operator can start an instance from a clean checkout at any time; the jobs are permissionless and the
relayer serialises the nonces.

### An on-chain revert (`amps_keeper_failed_total` > 0)

Every job is simulated immediately before it is sent, so a revert means state moved in between — another keeper
won the race, or the gate changed. It costs gas and pays nothing. One is noise; a pattern means the scan
interval is too long for the pool's activity, or two of your own instances are racing each other. Point both at
the same relayer, or stagger the scan intervals.

### The pot is empty

Jobs degrade to unpaid, they do not stop (`BountyPot.pay` returns what it could transfer and emits `BountyPaid`
with `reason = "depleted"`). The keeper refuses bountied work by default. Either fund the pot (`fund(amount)`
after approving it) or set `AMPS_RUN_UNPAID=1` and compound out of the operator's own pocket — which is a
reasonable thing for the protocol's own operator to do and an unreasonable thing to expect of anyone else.

### The daily ceiling is exhausted

Expected on a busy day: `dailyCeilingUsd18` starts at $25 and the window is a rolling reset, not a trailing sum
(`BountyPot`'s own note). The keeper waits. Governance raises the ceiling through the 48-hour timelock.

### The live-cell budget is nearly full

At `MAX_LIVE_CELLS` the bountied paths **merge into existing cells and leave the remainder idle** rather than
revert (§12 ruling E), so the call still stamps the cooldown and still pays a tip while doing a fraction of the
work. The keeper stops before the vault does (`cell-budget`). This is the constraint on growing the constituent
set past ~36 pools at the launch ladder shape; the answer is coarser ladders or a migration with a larger
budget, not a keeper change.

### A pointer moved

`topology pointer moved` in the logs, at `warn`. The keeper follows it on the next scan. A **vault** move —
`emergencyMigrate` — also clears the cooldown cache, because the new vault's `_lastPlacementAt` starts empty.

---

## 8. Deploying

```sh
cd apps/keeper
cp .env.example .env          # fill in the relayer's API key and the AMPS address
docker compose up -d
```

`docker-compose.yml` is a **sketch**: relayer + redis + keeper + Prometheus + Grafana, with the relayer's own
signer configuration left to the deployment (`relayer/config/`), because that is where the key lives and it is
not something a compose file should invent. Prometheus loads `alerts.yml`, which is §5's metrics turned into
the rules in §6 and §7.

The image runs the keeper from TypeScript source under `tsx`. That is deliberate: `@amplestocks/abis` publishes
`src/index.ts` as its entry so the indexer and the dApp can consume it without a build step, and a compiled
`dist` for the keeper alone would import a `.ts` file at runtime. `pnpm typecheck` is the build gate.

---

## 9. Running the chain suite

```sh
pnpm --filter @amplestocks/keeper test          # unit suites, offline, milliseconds
pnpm --filter @amplestocks/keeper test:chain    # + the anvil suite; needs Foundry 1.8.1
```

The chain suite spawns its own anvil, stands the whole system up through
`apps/keeper/test/chain/KeeperFixture.s.sol` — the production contracts, `AmpsHook` mined to `0x38C0` — and
drives the keeper against it. It is opt-in (`AMPS_KEEPER_CHAIN_TESTS=1`) because the CI `node` job does not
install Foundry, and it takes about eleven minutes.

Twenty drills: the fixture itself and the topology resolution; `compound` firing on accrued fees with the
bounty landing in the keeper's account; the dust guard refusing an empty pool; a 20-scan spam campaign blocked
outright; the cooldown waited out; a guardian freeze and a closed market stopping everything; a diverged pool
refused while its neighbours run; a stale checkpoint refreshed; a tripped watchdog healed by `touch`;
`deployBonded` firing above the deploy threshold and not below it; a 48-hour outage resumed with no duplicate
send; a second instance deciding identically; the bounty-versus-gas refusal at a pinned 1 gwei basefee; the
measured-versus-reported gas metrics; the pot swept empty and the degrade-to-unpaid switch; and the assertion
that only the five permissionless jobs are ever encoded and that no ladder cell moves.

### A Phase 3 script bug the fixture found

**`10_TestnetPools.run()` and `09_Phase3Wire.run()` cannot broadcast as written.** Both delegate to a helper
contract deployed inside the script (`_registrar().execute(...)`, `wireScript.execute(...)`), and a
`vm.startBroadcast` window opened by a *helper* gets every transaction written into
`broadcast/…/run-latest.json` with the **same nonce**. Observed with Foundry 1.8.1, `--slow` or not: 26 registry
calls all at nonce `0x28`, and the run dies with `EOA nonce changed unexpectedly while sending transactions.
Expected 40 got 41`.

Simulation is unaffected, which is exactly why `contracts/test/script/Phase3Scripts.t.sol` is green — it never
broadcasts. The rule for the deploy runbook is: **every broadcast window must be opened by the script
`forge script` was pointed at.** `KeeperFixture.s.sol` inlines the registration, the wiring and the genesis
placement for that reason, and documents it at the top of the file.
