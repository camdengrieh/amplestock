# Keeper runbook

Operations for `apps/keeper`: what it does, what it refuses to do, what every alert means, and what to do in
each gate state.

> **Nothing in this document is a trust assumption.** Every job the keeper runs is permissionless. If this
> process stops, anyone else's keeper does the same work and collects the same bounty; the protocol's only loss
> from a keeper outage is time. Ladders are static, so trading is unaffected, and bonds and redemption never
> touch the keeper at all.

---

## 1. What it runs

Five calls on `AmpsVault`, one on `AmpsGenesis` that runs once in the protocol's life, and no others.

| Job | Call | Paid? | Fires when |
|---|---|---|---|
| Compound | `compound(bytes32 poolId)` | bounty | a pool's simulated fee collection is worth more than `chost` |
| Rollout | `rollout(uint16 constituentId)` | bounty | the rollout schedule proposes a non-zero move into an ACTIVE spoke |
| Deploy bonded | `deployBonded(uint16 constituentId)` | bounty | idle bonded collateral clears `deployThresholdUsd18` |
| Checkpoint | `checkpoint()` | **no** | the vault checkpoint is older than `AMPS_CHECKPOINT_REFRESH_SECONDS` (1,200 s) |
| Touch | `touch()` | **no** | every `AMPS_TOUCH_INTERVAL_SECONDS` (900 s), and immediately whenever the watchdog has tripped |
| Settle genesis | `AmpsGenesis.settle()` | **no** | once, in the first block after both auctions' `endBlock`, while `AmpsGenesis.settled()` is false |

**Settle genesis is unpaid and one-shot**: it sweeps both legs, wraps the ETH and calls `AmpsVault.genesisPlace` in
the same transaction. It takes `_requireManageable` (through `genesisPlace`), so it fails while the vault's gate pointer is set and the hub pool
does not exist yet — the gate pointer must stay unset until settlement (`docs/genesis-cca.md` §5). After it
succeeds the job retires itself; the keeper's five ordinary jobs only start once the launch is placed.

It is the only job whose transaction does not go to the vault, and the only one screened on a single field: the
adapter's own `phase()`, which reads `Ended` exactly when the call is possible. It is deliberately **not** screened
on gate state — a launch stuck behind an early gate pointer must surface as a `GateNotHealthy` simulation revert
naming the real problem, not as "gate not green" every scan for ever. The reader latches the adapter reads off the
moment `settled()` comes back true, so a keeper started years after the launch pays four RPC calls once and then
never asks again, and the job stops appearing in the metrics at all: a job that can never run again is not a job
with a skip reason.

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
| 2 | `OracleGate.state(0) == GREEN` | `gate-not-green` / `gate-ref-diverged` | the vault's own `_requirePlaceable` |
| 3 | `OracleGate.isPlacementAllowed(poolId).allowed` | `placement-refused` | §3.8 step 2 |
| 4 | `abs(slot0.tick - fairTick) <= 800` | `diverged` | §3.8 step 3, `PLACEMENT_DIVERGENCE_TICKS` |
| 5 | `now >= lastPlacementAt + 60` | `cooldown` (carries `readyAt`) | §3.8 step 6 |
| 6 | `liveCells + headroom <= 512` | `cell-budget` | §12 ruling E |
| 7 | job-specific: idle collateral, rollout weight, checkpoint age | `below-deploy-threshold`, `no-work`, `not-due`, `checkpoint-fresh` | §3.7 |
| 8 | `settle` only: `AmpsGenesis.phase() == Ended` | `not-due` while the auctions run, `already-settled` once they have | §1 |

Steps 1 and 7 of the gauntlet — the transient lock and the R1 post-condition — are invisible to a `view`. They
land in the simulation, below.

**Checks 1-6 do not apply to `settle`.** It is not a placement and not a call on the vault, and screening it on
gate state would hide the one failure that matters (§1). Its whole screen is check 8; everything else about it is
decided by the simulation.

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

**Work value** comes from the vault where it can, and from the keeper's own estimate where it cannot:

* **Preferred** — the `BountyPaid` the job would emit, captured by running it through `eth_simulateV1`. That is
  the vault's own measurement and the pot's own payout, so `chost`, the daily ceiling, the 3× cap and the pot's
  balance are all already applied to it (§3.2).
* **Fallback**, on a node without `eth_simulateV1`:
  * `compound` — `burned x P_ref`. Under revision 6 `burned` is the *whole* AMPS-side movement of the call: the
    fee remainder after the creator's slice plus whatever the pool's own bids bought back, so there is no split
    left to re-run client-side. Counter-side fees are not returned by the call and are not counted, so this is a
    **lower bound** — the safe direction for a dust guard.
  * `rollout` — `moved x P_ref`.
  * `deployBonded` — the placed slice of the idle collateral, valued at the feed.
  The payout is then `BountyPot._quote` re-run client-side against that work value and
  `vaultGasAllowanceUsd18(eth_estimateGas, basefee, ethUsd)`, which is the vault's own gas formula.

---

## 3. What the vault reports, and what the keeper still checks itself

### 3.1 The vault measures its own bounty (was: two gaps, both now fixed)

The pre-audit slice replaced two hardcoded constants with measurements, and both of the gaps this runbook used
to warn about are closed.

**`BountyPot`'s `chost` dust guard fires.** `compound` reports the counter-side fees at their feed price plus
`ampsFees + boughtBack` at `P_ref`; `rollout` reports the AMPS actually moved at `P_ref`; `deployBonded` reports
the collateral placed at the same feed price its threshold was tested against. An empty job therefore reports
**zero**, and `workValueUsd18 < chostUsd18` is unambiguously true. Previously the vault reported a flat `$1`
whatever the job did, `1e18 < 1e18` was false, and an empty `compound()` was paid the full tip.

**The 3× gas cap binds, and is usually *the* binding constraint.** `VaultPlacementLib._gasUsed` is a real
`gasleft()` delta with the EIP-150 `gasleft()/63` correction, plus `KEEPER_GAS_OVERHEAD` (80,000) for the
intrinsic cost and the payment, clamped at `KEEPER_GAS_MAX` (8M). `_gasCostUsd18` prices it at `block.basefee`
clamped into `[0.01, 1] gwei` and at the ETH/USD answer the feed registry holds for the `AMPS/WETH` counter —
the same feed `A` values the vault's WETH bids with, so no new oracle and no new governed parameter.

Concretely, at the Orbit floor basefee and $2,500 ETH:

| job gas | allowance | 3× cap | gross on $10 of work | paid |
|---|---|---|---|---|
| 1.0M | $0.0270 | $0.0810 | $0.25 | **$0.0810** |
| 1.5M | $0.0395 | $0.1185 | $0.25 | **$0.1185** |
| 3.3M | $0.0845 | $0.2535 | $0.25 | **$0.2535** |

The cap now grows with the job, so the whole §12 gas range is paid more than it costs — which the flat report
never managed. `src/domain/bounty.ts` mirrors all of it (`vaultGasUsed`, `clampBaseFee`,
`vaultGasAllowanceUsd18`), and `test/bounty.test.ts` pins the numbers above.

### 3.2 The keeper still measures, for two reasons

**It reads the vault's own report where it can.** `src/jobs/index.ts`'s `simulateBounty` runs the job through
`eth_simulateV1` and decodes the `BountyPaid` it would emit, so the keeper knows the exact work value, the exact
payout and the exact binding constraint *before* it sends. `eth_simulateV1` is not universal — anvil has it,
Arbitrum Nitro does not guarantee it — so the first bountied job that simulates cleanly without producing a
`BountyPaid` latches the feature off for the process and the keeper falls back to its own estimate. There is
nothing to configure; the log line `eth_simulateV1 did not yield a BountyPaid` records the fallback.

**Its own estimate is a lower bound.** `compound` returns `(ampsFees, burned)` and says nothing about the
counter-side fees, which the vault does price in. The `Compound` log carries the rest —
`(poolId, ampsFees, counterFees, creatorAmps, creatorCounter, burned)` — so a keeper that wants the full picture
reads the receipt rather than the return value. So the fallback path under-states the work and can skip a job
the vault would have paid for; it never sends one the vault would refuse. `amps_keeper_measured_work_value_usd`
against `amps_keeper_reported_work_value_usd` (from the confirmed `BountyPaid`) is exactly that gap, and the
chain suite asserts `measured ≤ reported`.

The gas series are the same comparison from two sides: the keeper prices `eth_estimateGas`, the chain prices the
receipt's `gasUsed`, and the suite asserts they agree within 25%. A persistent divergence means the vault and
the keeper disagree about what a job costs — and the 3× cap is the thing that binds, so it matters.

### 3.3 The tip economics, which survive

The cap is generous now, but **`tip + chip` is still the binding term once the basefee leaves the floor.** At
0.1 gwei a 1.5M-gas compound costs $0.375 while the gross on $10 of work is only $0.05 + 2% = $0.25, so the job
is under water and the keeper refuses it (`amps_keeper_unprofitable_total`). The lever is `tipUsd18` and
`chipBps` through the 48-hour timelock, not `gasCapMultiple`. With `AMPS_ETH_USD18` unset the check is off and
the keeper works whatever the gas costs — the honest setting until Phase 0 resolves the ETH/USD feed on 4663.

### 3.4 The cooldown clock is a chain read

`AmpsVault.lastPlacementAt(PoolId)` exists, and the keeper reads it per pool every scan. It previously had no
getter, and the keeper reconstructed it from the newest `placedAt` across the ladder — a lower bound, because a
`compound` that placed nothing still stamped the map — and corrected it from the `PlacementCooldown` revert. Both
workarounds are gone. (Since revision 6 the cooldown follows what was actually placed, and a `compound` whose
counter side committed nothing takes no cooldown at all.)

Within a single scan the keeper layers an overlay on top: the snapshot is taken once, and a job sent early
stamps pools that later candidates in the same cycle would otherwise still see as free. The overlay is
populated from the confirmed job's own `Placement` logs — which now carry `reason`, `lowerTick` and `upperTick`,
and which name **exactly** the pools the vault stamped, including the entry pools a `rollout` harvested — and it
is cleared at the top of every scan. The chain is the authority; the overlay only covers one snapshot's
staleness.

### 3.5 Feed refresh (recommended, unpaid)

`FeedRegistry.refresh(token)` / `refreshMany(tokens)` advance the accepted-answer latch that the two-confirmation
rule measures against. Since the 2026-09-07 audit fixes the rule no longer depends on it — when the latch is older
than one heartbeat the registry evaluates a jump against the aggregator's own previous round — but a keeper that
calls `refreshMany` over the registered assets once per heartbeat keeps the latch path (and its `confirmSeconds`
release) live and makes held-back jumps clear on schedule. It is unpaid, so run it from the same relayer on a
timer rather than through the bounty logic.

## 4. Configuration

Everything is environment. **No endpoint and no address is a literal in a code path**; the RPC defaults come
from `@amplestocks/config`'s chain records (4663 and 46630), which Phase 0 re-verifies on chain.

The keeper is told **one** address — AMPS — and resolves the rest every scan: `Amps.vault()` names the live
vault, so an `emergencyMigrate` is followed without a redeploy, and the vault names the registry, the bonds, the
bounty pot, the oracle gate, the hook and — until the launch settles — the genesis adapter (`AmpsVault.genesis()`,
a set-once pointer, so it names the adapter for the life of the vault whether or not it has settled). **There is no
staking pointer to resolve**: revision 6 removed `AmpsStaking` from the protocol, so the keeper reads nothing about a
reward stream, has no `notifyReward` to watch and runs no staking job — a vault deployed before revision 6 would
answer `staking()`, and this keeper never asks. A governance pointer move is a value that changes between two scans,
not an outage.

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
| `AMPS_GENESIS_ADDRESS` | from `AmpsVault.genesis()` | optional; pins the adapter for a fixture chain whose pointer is not wired yet |
| `AMPS_SETTLE_ENABLED` | `true` | watch for the settlement and send `AmpsGenesis.settle()`. Ignored once `settled()` is true, so it costs nothing after the launch; set it to `false` to leave settlement to another operator — it is permissionless, so somebody else's keeper does the same work |
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
`amps_keeper_pot_quote_usd`, `amps_keeper_pot_quote_reason{reason}`. The last two are a **reference** quote —
$1 of work against $1 of allowance — answering "is the pot responding, and what is binding it right now". The
per-job payout is the vault's own, in `amps_keeper_bounty_paid_usd_total` and `amps_keeper_bounty_reason`.

**Decisions** `amps_keeper_candidates{job}`, `amps_keeper_eligible{job}`, `amps_keeper_skipped_total{job,reason}`,
`amps_keeper_simulations_total{job}`, `amps_keeper_simulation_reverts_total{job,error}`.

**Sends** `amps_keeper_sent_total{job}`, `amps_keeper_confirmed_total{job}`, `amps_keeper_failed_total{job}`,
`amps_keeper_submit_errors_total{job}`, `amps_keeper_in_flight`.

**Bounty and gas** `amps_keeper_gas_estimate{job}`, `amps_keeper_gas_used{job}`,
`amps_keeper_measured_work_value_usd{job}` (the keeper's estimate) against
`amps_keeper_reported_work_value_usd{job}` (the vault's, from the confirmed `BountyPaid`);
`amps_keeper_measured_gas_allowance_usd{job}` (priced from `eth_estimateGas`) against
`amps_keeper_reported_gas_allowance_usd{job}` (priced from the receipt's `gasUsed`);
`amps_keeper_bounty_expected_usd{job}`, `amps_keeper_bounty_paid_usd_total{job}`,
`amps_keeper_bounty_reason{job,reason}`, `amps_keeper_unprofitable_total{job}`,
`amps_keeper_chost_blocked_total{job}`.

`measured` should sit at or just below `reported` (§3.2), and the two gas series within a quarter of each other.
A sustained gap in either pair is the alert that the keeper and the vault disagree about what a job is worth or
what it costs.

`skipped_total`'s `reason` label is a closed set — every value is in the table in §2 — so a dashboard can
enumerate it. Logs are one JSON object per line on stdout.

---

## 6. What to do in each gate state

`OracleGate.state(0)` is what the vault's gate policies (`_requirePlaceable`, `_requireManageable`) read; `stateByPool(poolId)` is what a placement
reads. `amps_keeper_gate_state` carries the ordinal.

| State | Ordinal | What it means | The keeper | The operator |
|---|---|---|---|---|
| `GREEN` | 0 | everything fresh, in session, no divergence | works normally | nothing |
| `DEGRADED` | 1 | a feed is stale beyond its session-scaled `maxAge`, **or the session is CLOSED** | refuses every placement job; `touch` and `checkpoint` still run, because the vault's management gate admits `DEGRADED` | **Usually nothing.** Overnight and every weekend the equity calendar closes and this is the normal state. Investigate only if it persists inside a REGULAR session — then it is a stale feed: check `FeedRegistry.feedStatus(token)` and the aggregator's `updatedAt`, and escalate to the Safe if a feed has genuinely died. Bonds continue at the session haircut; redemption is never affected. |
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

Two reverts are not races (second remediation wave, 2026-09-07). `HighWaterResetFailed(poolId)` means an ask
placement — `rollout` or a governance `place`; since revision 6 `compound` places no asks at all and
`deployBonded` never did — could not reset the hook's high-water mark: the vault's market reference does not answer, or answers malformed. That is a wiring fault, not
a timing one — page the operator; do not retry. And a `rollout` that lands less than it harvested is not a
failure: the window is charged on what left the entry pools, the remainder is re-placed into them in the same call
(`Placed` with `reason = "rollback"`), and the bounty is paid on what was placed, which the `chost` guard may round
to zero when the destination's live-cell budget is full.

### Genesis will not settle

`amps_keeper_simulation_reverts_total{job="settle"}` is the one to watch during a launch, and the error label says
what to do:

| Revert | Cause | Fix |
|---|---|---|
| `AuctionNotEnded(auction, endBlock)` | the job ran a block early, or one leg's window is longer than the other's | nothing; `phase()` reads `Ended` only when every created leg has closed, and the next scan sends it |
| `GateNotHealthy(state, poolId)` | the vault's gate pointer was set before settlement, and the hub pool does not exist yet | this is an operator error, not a race (`docs/genesis-cca.md` §5). The gate must be unpointed by governance before the launch can proceed — page the Safe |
| `AlreadySettled()` | somebody else's `settle()` won | expected and harmless: the launch happened. The reader latches the reads off at the next scan and the job disappears |
| `NotSweptClean(token, balance)` | a leg paid out something the adapter did not expect | do not retry blindly; read `AmpsGenesis`'s balances and escalate — the adapter asserts it is empty on purpose |

`settle` never appears at all once `settled()` is true, so an *absent* settle metric after the launch is the
correct state, not a broken exporter.

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
work. The keeper stops before the vault does (`cell-budget`).

The constraint on growing the constituent set is now **the cap itself**, not this budget: revision 8 lowered
`MAX_CONSTITUENTS` to **34**, which is what the redemption gas budget proves — 512 live cells at 14 per fully
laddered pool is 36 pools, less the two entry pools. 34 constituents is 36 pools at the launch ladder shape, so a
registry that is full is also a cell budget that is full, and the two limits bind together by construction rather
than by coincidence. Growing past it is a migration with a larger budget or a coarser ladder, and neither is a
keeper change. The keeper reports `amps_keeper_live_cells` against `amps_keeper_live_cell_budget`; the gap
between them is the headroom, and it does not grow.

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

Twenty drills: the fixture itself and the topology resolution; `compound` firing on accrued fees, with every
`BountyPaid` decoded and reconciled against the pot's balance change, the payout checked against both of the
pot's constraints, and the keeper's pre-send prediction asserted equal to what the chain paid; the dust guard
refusing an empty pool against a work value the *vault* measured at zero; a 20-scan spam campaign blocked
outright; the cooldown waited out; a guardian freeze and a closed market stopping everything; a diverged pool
refused while its neighbours run; a stale checkpoint refreshed; a tripped watchdog healed by `touch`;
`deployBonded` firing above the deploy threshold and not below it; a 48-hour outage resumed with no duplicate
send; a second instance deciding identically; the bounty-versus-gas refusal at a pinned 1 gwei basefee; the
measured-versus-reported work and gas series agreeing; the pot swept empty and the degrade-to-unpaid switch;
and the assertion that only the permissionless jobs are ever encoded and that no ladder cell moves. The `settle`
job is covered by the offline suite rather than by the chain suite: the chain fixture stands the system up with
the launch already placed, so a settlement is not reachable in it.

### A Phase 3 script bug the fixture found (being fixed by the deploy agent)

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
