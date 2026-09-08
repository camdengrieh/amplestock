# Amplestocks launch runbook (guarded mainnet)

The operational half of Phase 6. `docs/deploy-runbook.md` says how to get the contracts onto a chain; this says
what a guarded mainnet launch does with them, who signs what, how the caps are ratcheted, and what to do when
something breaks.

Nothing here is a promise about price or return. The protocol's only guarantee is the pro-rata redemption floor,
which no governance path can block.

---

## 1. Preconditions

Do not start §2 until all of these are true. They are the plan's Phase 6 exit criteria, restated as a checklist.

| # | Precondition | Evidence |
|---|---|---|
| 1 | 30 days of continuous testnet (46630) operation: 32 pools, 30 bond markets, production keeper and indexer | keeper Grafana, indexer reconciliation report |
| 2 | Agent audits clean: every Critical/High/Medium from `x-ray`, `solidity-auditor` and `fizz` fixed, re-audit clean | `docs/audits/` |
| 3 | ≥ 30 days of fuzzing (Medusa + the Foundry invariant campaigns) with no new violation | campaign logs |
| 4 | Every incident runbook in §8 rehearsed on 46630, including a full `emergencyMigrate` | drill log |
| 5 | Governance drills in §9 passed on 46630 | drill log |
| 6 | `00_Preflight` on 4663 reports zero `FAIL` and zero `TODO` | `script/config/preflight-report.json` |
| 7 | Counsel sign-off on the structure, the geo-block set and discounted issuance through bonds | written |
| 8 | Written contact with Chainlink Labs and Robinhood chain/BD, including bond-collateral custody | written |
| 9 | Proposer Safe 3/5 and guardian Safe 2/4 deployed on 4663, signers confirmed, hardware keys in hand | Safe addresses |
| 10 | Deployer key is a fresh hardware key used for nothing else | key ceremony note |
| 11 | The founders' $5,000 ($2,500 ETH, $2,500 USDG) is in the proposer Safe | on-chain |
| 12 | `pnpm --filter @amplestocks/contracts broadcast-test` green twice in a row on the launch commit | CI run |

**Stop conditions from Phase 0 still apply.** If modelled fee revenue is below modelled gap LVR + bounty + gas on
the top-weighted pools, or fewer than 5 names clear the β rule at σ_u = 3%, do not launch.

---

## 2. Launch day

One session, one operator at the keyboard, two Safe quorums on call. Every step is a `forge script` from
`docs/deploy-runbook.md` §1 unless it says otherwise.

| # | Step | Who | Notes |
|---|---|---|---|
| 1 | `00_Preflight` on 4663, strict | operator | must be zero `FAIL`; archive the report |
| 2 | `02_Libraries`, both passes | operator (deployer key) | record `librariesFlag` |
| 3 | Predict the vault address, mine the AMPS salt off chain, verify with `01_MineAmps` | operator | three leading zero bytes; the salt is bound to that exact vault address |
| 4 | `03_Core` | operator (deployer key) | deploys the `TimelockController` at `minDelay = 0` with the Safe **and** the deployer as proposers; guardian gets `CANCELLER_ROLE` |
| 5 | `12_Verify` + `verify.sh` for what exists so far | operator | verify early; a failed verification is cheaper to debug now |
| 6 | `05_Registry` | operator | 32 pools, 30 markets, the launch weight vector; ~194 transactions in relay mode |
| 7 | Wait for the hub ring to cover `twapWindow` (~30 min) | — | `observationCoverage(hubPoolId) >= 1800` |
| 8 | Proposer Safe transfers $2,500 WETH and $2,500 USDG to the `TimelockController` | Safe 3/5 | `genesis()` pulls from `msg.sender`, and that is the timelock |
| 9 | `09_Phase3Wire` (`WIRE_DIRECT=true WIRE_REDEPLOY_GATE=false`) | operator | ends by asserting `gate.state(0) == GREEN` |
| 10 | `11_GenesisPlacement`, phase 1, then phase 2 sixty seconds later | operator | §3; ends with 328 live cells and NAV/share $1.00 |
| 11 | Apply the guarded-launch parameters (§4, §5) as one timelock batch at zero delay | operator, from the Safe's approved calldata | halved bond capacity, halved rollout |
| 12 | `03_Core CORE_STAGE=finalize` | operator | `minDelay` 0 → 48 h; the deployer stops being a proposer and a canceller. **After this the deployer key is powerless.** |
| 13 | `12_Verify` + `verify.sh`, all contracts | operator | every address on Blockscout |
| 14 | Start the keeper and the indexer against 4663 | operator | `docs/keeper-runbook.md` §5 |
| 15 | Publish the dApp with the geo-block and terms gate live | operator | |
| 16 | Announce the deployment addresses and `docs/` | — | no price or return language |

**Abort points.** Steps 1–7 are reversible in the sense that nothing is at risk: no user funds exist and the
worst case is a redeployment. From step 8 the founders' seed is in the timelock; from step 10 `S0` is minted and
the genesis latch is closed — after that the only way back is a migration (§8.11). If anything is wrong at step
9 or 10, stop, do not run `finalize`, and redeploy from step 2 with fresh salts.

---

## 3. Genesis, per the confirmed table

`11_GenesisPlacement` mints `S0` and lays the ladders in one pass. These are the confirmed launch parameters, not
options.

| Item | Value |
|---|---|
| `S0` | 5,000 AMPS (18 dec), minted exactly once |
| Team tranche | 250 AMPS (5%) to an OZ `VestingWallet`, 2-month linear, **no cliff** |
| POL tranche | 4,750 AMPS (95%), held by the vault as ask inventory |
| → 30 spokes | 47.5 AMPS each (1% of the POL tranche) = 1,425 AMPS |
| → entry pools | 1,662.5 AMPS each in `AMPS/USDG` and `AMPS/WETH` = 3,325 AMPS |
| Founders' seed | $2,500 ETH against the `AMPS/WETH` asks, $2,500 USDG against the `AMPS/USDG` asks — 50/50 |
| Launch price | $1.00 = NAV/share at genesis |
| Ask ladder | 10 doublings, tilt 1.25, cells `m = 0..9` ($1 → $1,024) |
| Seed bids | 4 halvings, cells `m = -1..-4`, entry pools only |
| Live cells after both phases | 328 = 32 × 10 asks + 2 × 4 bids |
| Creator fee | 100 bp of **trade volume** — buys and sells alike — decaying linearly to zero over 30 days, paid **in kind** out of each currency's fees at `compound()`. Immutable schedule; only the current `creator` may reassign the address |

**The fee parameters at launch (revision 6).** These are not options either, and the first row is the one that
changed: the AMPS fee is the base on *both* directions of every pool.

| Parameter | Launch value | Hard band | What it prices |
|---|---|---|---|
| `ampsFeeBps` | **500 bp** | [100, 600] | Every swap that touches AMPS, buying **and** selling. `AmpsHook.setAmpsFeeBps`, 48 h |
| `buyFeeBps` (entry pools) | 30 bp | [5, 100] | The **pass-through** price of one hop of an `AmpsRouter.rotate`. Not what a buy pays |
| `buyFeeBps` (spokes) | 5 bp, 10 bp for high-volatility names | [1, 50] | The same, per spoke |
| `redeemFeeBps` | **250 bp** | ≤ 500 | Redemption, kept by the vault. `AmpsVault.setRedeemFeeBps`, 48 h |
| Creator schedule | 100 bp of volume → 0 over 30 d | immutable | `creatorBps(t)/ampsFeeBps` of each currency's fees, in kind |
| AMPS-side fee remainder | burned in full | — | No parameter: it is the whole remainder after the creator's slice |
| Counter-side fee remainder | placed as bids in the pool that earned it | — | No parameter, and no cross-pool relay |

There is **no `stakerBps` row, no `burnBps` row and no `rewardStreamSeconds` row**: revision 6 removed staking and
made the burn a whole share rather than a governed fraction of one, so none of the three exists to set.

Assert after step 10:

```bash
cast call $AMPS  "totalSupply()(uint256)"        # 5000000000000000000000
cast call $AMPS  "balanceOf(address)(uint256)" $TEAM_VESTING   # 250000000000000000000
cast call $VAULT "navPerShareX18()(uint256)"     # 1e18 +/- rounding
cast call $VAULT "liveCells()(uint32)"           # 328
cast call $GATE  "state(uint16)(uint8)" 0        # 0 == GREEN
```

---

## 4. Bond capacity starts at half the v1 values

Bonds are the only post-genesis issuance path, so bond capacity *is* the supply-growth throttle. The guarded
launch halves both caps and restores them on the first clean rung of §6.

| Parameter | v1 value | **Guarded launch** | Hard band | Setter |
|---|---|---|---|---|
| `capBpsPerEpoch` (per market, 6 h) | 50 bp of `T` | **25 bp** | ≤ 200 | `AmpsBonds.setCapBpsPerEpoch(marketId, 25)` — one call per market |
| `dailyCapBps` (global, rolling day) | 200 bp of `T` | **100 bp** | ≤ 500 | `AmpsBonds.setDailyCapBps(100)` |

Everything else launches at the confirmed value: `dBase/dMin/dMax` 12.5% / 10% / 15%, `epochSeconds` 6 h,
`vestSeconds` 12 h, `minAccretionBps` 50, `h_session` 0 / 50 / 150 / 300 bp, the `ENTRY` class (WETH, USDG)
registered but **closed**.

At 100 bp/day the supply can at most double in about 70 days and reach ten times genesis in about 230 — which is
what makes the §6 ratchet a monitored ceiling rather than a race.

Step 11's batch is 31 calls: 30 `setCapBpsPerEpoch` and one `setDailyCapBps`. All are 48-hour class, executed at
zero delay during the launch session; after `finalize` the same change is a 48-hour Safe proposal.

---

## 5. The launch tranche, in scheduled steps

Two distributions are on a schedule by construction, and one is throttled deliberately.

**The POL tranche moves by rollout, not at once.** Genesis puts 3,325 AMPS in the entry pools and only 47.5 into
each spoke. `AmpsVault.rollout(constituentId)` moves the rest out over time, and the keeper calls it — nobody
hands out a tranche.

| Parameter | v1 value | **Guarded launch** | Cap | Setter |
|---|---|---|---|---|
| `rolloutBpsPerDay` | 200 bp of the POL tranche per day | **100 bp** | ≤ 1000 | `AmpsVault.setRolloutParams(100, 3000)` |
| `entryFloorBps` | 3000 bp | 3000 bp | — | same call |

Rollout never places a spoke ask below `P_ref` and never takes the entry pools below `entryFloorBps` (I32), so
even a mis-set `rolloutBpsPerDay` cannot drain the hub. At 100 bp/day the spokes reach their target weights over
roughly a quarter, which is the intended pace: liquidity follows demonstrated volume rather than leading it.

**The team tranche vests itself.** 250 AMPS, OZ `VestingWallet`, 60 days linear, no cliff, no governance path to
accelerate or claw back. Nothing to operate.

**The creator fee expires by itself.** 100 bp of trade volume — buys and sells alike — decaying linearly to zero
over 30 days from genesis, and paid in kind out of each currency's fees at `compound()`: AMPS by transfer,
counter assets best-effort with an ERC-6909-claim fallback so a gated token can never block a compound. There is
no setter, no band and no extension.

**And nothing else is distributed at all.** After the creator's slice the whole AMPS side of every fee is burned,
and the counter side stays as bids in the pool that earned it. There is no staking tranche to schedule, no reward
stream to fund and no re-ladder to operate: the ask inventory is the genesis POL tranche and the rollout is the
only thing that moves it.

---

## 6. The TVL cap ratchet

| Rung | Cap on `A` (vault NAV) | Gate to the next rung |
|---|---|---|
| 1 | $50,000 | 30 clean days |
| 2 | $250,000 | 30 clean days |
| 3 | $1,000,000 | 30 clean days |
| 4 | $5,000,000 | 30 clean days, then the cap is retired |

**A "clean day" is a UTC day with:** zero guardian freezes, zero `REF_DIVERGED` or `WATCHDOG` gate transitions
lasting more than one TWAP window, zero keeper jobs missed beyond one interval, `peg_dev_bp` 95th percentile
under 50 bp intraday, NAV/share monotone non-decreasing ex-market-moves, cumulative placement bleed under 10 bp,
and no unexplained divergence between the indexer's reconciliation and chain reads. Any failing day resets the
30-day counter for the current rung.

**There is no TVL cap in the contracts, and there deliberately never will be** — a cap that could block deposits
would be a cap that could block redemption's sibling paths, and the immutability of `redeemProRata` is worth more
than the cap. The rung is therefore enforced by the two throttles that *do* exist plus a monitored trigger:

1. **Rate.** Post-genesis growth in `A` comes from bonds, and §4's caps bound issuance to 100 bp of `T` per day.
   At every rung, check that `dailyCapBps × 30 days` cannot carry `A` past the next rung; if it can, halve
   `dailyCapBps` for that rung.
2. **Trigger.** The indexer alerts at 80% of the rung. On the alert, the proposer Safe schedules
   `AmpsBonds.setDailyCapBps(<lower>)` (48 h). If `A` reaches the rung before that executes, the **guardian**
   closes issuance immediately with `OracleGate.freezeProtocol(now + 7 days)` — disable-only, auto-expiring, and
   it cannot touch redemption.
3. **Raising a rung** is one 48-hour proposal restoring `dailyCapBps` and `capBpsPerEpoch` (and, at rung 2,
   `rolloutBpsPerDay` back to 200). Record the 30 clean days in the proposal description.

Nothing in the ratchet touches `redeemProRata`, `claim()` on a vesting bond position, or the ability to sell into
the ladders. A cap that stopped people leaving would not be a cap, it would be a trap.

---

## 7. Governance: who signs what

| Role | Who | Powers |
|---|---|---|
| Proposer | Safe 3/5 | `schedule` / `scheduleBatch` on the `TimelockController`; nothing else |
| Executor | **anyone** (`EXECUTOR_ROLE = address(0)`) | `execute` a matured operation. Deliberate: a proposer that goes dark cannot strand an approved change |
| Canceller | Safe 3/5 and guardian Safe 2/4 | `cancel` a pending operation |
| Guardian | Safe 2/4 | `OracleGate.freezeProtocol` / `freezeConstituent` (disable-only, ≤ 7 days, auto-expiring), `unfreeze*`, `AmpsVault.emergencyMigrate` behind its on-chain predicate |
| Creator | the `creator` address | reassign `creator` only. No other power, and the fee schedule is immutable |
| Deployer | the launch key | powerless after §2 step 12 |

**Delay classes.** `TimelockController` has one `minDelay` (48 h after `finalize`); the 7-day and 14-day classes
are the `delay` argument the Safe passes at `schedule` time. The signing policy — not the contract — enforces
them, so every proposal description states its class and every signer checks it.

| Delay | Actions |
|---|---|
| 48 h | `ampsFeeBps` [100, 600], the pass-through base fees (`buyFeeBps`, entry [5, 100] / spoke [1, 50]), `redeemFeeBps` ≤ 500, `refUpRateBps` [100, 5000]/h, TWAP window, `maxTickMovePerBlock`, `GRACE`/`GAP_SECONDS`, freshness multipliers, calendar tables, ladder tilt/doublings, rollout, every bond variable and per-market open/close, keeper `tip`/`chost`/caps, `BountyPot` funding |
| 7 d | constituent add / retire / reinstate / reconfigure, index weights, bond collateral add / remove, every policy pointer (`LadderPolicy`, `FeePolicy`, `RolloutPolicy`, `BondPolicy`, `OracleGate`, `FeedRegistry`), and **`AmpsHook.setRouter`** — the pass-through exemption is a pointer like the others and moves at the same speed |
| 14 d | standby vault registration (`AmpsVault.setStandbyVault`) |
| none | guardian freezes and `emergencyMigrate` |

Every settable parameter is bounded by a hardcoded band in the consuming contract, so a mis-typed proposal
reverts on execution rather than taking effect. **No governance path can block `redeemProRata`.**

### 7.1 Proposals as JSON the Safe can load

Build the calldata, then wrap it. `cast calldata` for the inner call, `cast calldata` again for `schedule`:

```bash
INNER=$(cast calldata "setDailyCapBps(uint16)" 100)
SALT=$(cast keccak "amplestocks.2026-10-01.bond-daily-cap")
OUTER=$(cast calldata \
  "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $BONDS 0 $INNER 0x0000000000000000000000000000000000000000000000000000000000000000 $SALT 172800)
```

Safe Transaction Builder file — save as `proposal-<date>-<name>.json` and import it in the Safe UI:

```json
{
  "version": "1.0",
  "chainId": "4663",
  "createdAt": 0,
  "meta": {
    "name": "Bond daily cap 200 -> 100 bp (48 h)",
    "description": "Guarded launch, TVL rung 1. Executes AmpsBonds.setDailyCapBps(100) after 48 h."
  },
  "transactions": [
    { "to": "<TIMELOCK>", "value": "0", "data": "<OUTER>" }
  ]
}
```

Execution, 48 hours later, is permissionless:

```bash
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" \
  $BONDS 0 $INNER 0x00…00 $SALT --rpc-url $RPC --private-key $ANY_KEY
```

For a **batch** — anything with more than one call, such as §4's 31 bond calls — use
`scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)` and `executeBatch(...)` with the same salt.
`script/09_Phase3Wire.s.sol` writes exactly that shape to `script/config/phase3-proposal.json`; copy its
structure. Keep the salt in the proposal file: `execute` needs the identical salt, and losing it strands the
operation until it is re-scheduled.

**Every proposal file records:** the delay class, the band each parameter must stay inside, the reason, the
expected on-chain reads before and after, and the operation id (`hashOperation`) so signers can verify what they
are approving against the chain rather than against the description.

---

## 8. Incident runbooks

Common to all: **`redeemProRata` and `AmpsBonds.claim` never stop.** If an incident makes you want to stop them,
the incident is a migration (§8.11), not a freeze.

### 8.1 Sequencer outage

*Detection.* Keeper `gate-not-green` with `WATCHDOG`; indexer block lag; `cast block-number` flat.

*Immediate.* Nothing. The watchdog is designed for this: `OracleGate` trips when produced blocks fall behind
`elapsed / gapSeconds`, `P_ref` falls back to `navPerShare`, placements and compounding pause, swaps and
redemption continue. Ladders are static, so trading is unaffected.

*On resumption.* The first `AmpsVault.touch()` pokes the gate and clears the watchdog in the same transaction;
the keeper does this automatically and it is permissionless, so anyone can. Confirm `state(0) == GREEN`, then
confirm the keeper resumed `compound` without a duplicate send.

*Follow-up.* If the outage exceeded `GRACE`, re-check `GAP_SECONDS` against the observed cadence and propose a
48-hour adjustment if the calibration was wrong.

### 8.2 Feed failure (stale, dead, or out of band)

*Detection.* Keeper `gate-not-green`/`DEGRADED`; indexer's `AnswerUpdated` gap alert; `FeedRegistry.refresh`
reverting.

*Immediate.* The gate has already done the work: `DEGRADED` pauses placements and compounding, widens the hook's
dynamic cap, and prices bonds at the session haircut. Redemption and swaps continue. Do **not** freeze.

*Assess.* One name or all of them? `OracleGate.state(constituentId)` per constituent. A single dead feed is a
constituent problem; all of them is an infrastructure problem and probably §8.1.

*Act.* If one feed is dead beyond its heartbeat and Chainlink confirms deprecation, that is a 7-day
`reconfigureConstituent` to a replacement feed (allowlist the new aggregator with `setStandardProxy` in the same
batch). If the feed is alive but the band is wrong, a 48-hour `configureFeed` fixes the band. If neither, retire
the constituent (§8.10).

*Do not* point at a non-Standard proxy. `FeedRegistry.setFeed` refuses one, and that refusal is the control.

### 8.3 Denylist, and evacuation via `emergencyMigrate`

*Detection.* The indexer's denylist alarm on the Stock Token beacon's `blockAccounts` (`0x6abf7081`) — it fires
within one block — or a 1-wei self-transfer probe failing for a constituent.

*Assess, immediately.* Is the blocked address the vault, the hook, `AmpsBonds`, or the PoolManager? Only the
PoolManager is usefully denylistable in normal operation, because `sweepClean` (I12) means the protocol holds no
movable stock ERC-20 balance between transactions. A blocked vault degrades gracefully in the meantime: the exit
sweep skips the token and emits `SweepResidue`, and a redemption pays that constituent as an ERC-6909 claim the
redeemer takes later, so the floor keeps working. If a *protocol* address is blocked, escalate to evacuation.

*Preconditions for evacuation.* The standby vault must already be registered — that is a **14-day** proposal, so
it is registered at launch and re-registered whenever a new standby is built. `emergencyMigrate` refuses unless
`VaultNavLib.migrationPredicate` holds: `isBlocked(vault) == true` for some constituent, or a bounded 1-wei
self-transfer probe failing for at least two constituents. The guardian cannot migrate on a hunch.

*Act.* Guardian Safe 2/4 calls `AmpsVault.emergencyMigrate(standby)`. In one `unlock` it unwinds every ladder,
takes the assets as ERC-6909 claims, transfers them PoolManager-internally to the standby, which re-adds at the
same ticks; `Amps.setVault(new)`, `AmpsBonds.setVault(new)`, `BountyPot.setVault(new)`,
`PoolRegistry.setVault(new)` and a best-effort `AmpsHook.setVault(new)` — five roles, not six; the sixth handed
`AmpsStaking` on until revision 6 removed staking — happen in the same transaction
(`VaultNavLib.handover`), and the idle-ERC-20 leg of the evacuation is best-effort so an idle wei of the blocking
token cannot veto it. The placement
bleed cap is relaxed to 50 bp inside migration and only inside migration.

*After.* Verify `Amps.vault()`, `AmpsBonds.vault()`, `BountyPot.vault()`, `PoolRegistry.vault()` and
`AmpsHook.vault()` all point at the standby; verify NAV/share moved by less than 50 bp; re-point the keeper and indexer; register a **new**
standby (14 days) so the next evacuation is possible; publish the incident.

*Drill this.* §9 requires a full rehearsal on 46630, including `AmpsBonds.setVault`, before launch.

### 8.4 Issuer pause (`oraclePaused()` on a Stock Token)

*Detection.* Indexer's per-constituent `uiMultiplier`/`oraclePaused` poll; gate state `CORPORATE_ACTION` for that
name.

*Immediate.* Nothing. The gate closes that name's bond market and stops placements into its pool; swaps continue
at the widened band; NAV valuation for that name falls back per §3.8 of the state model. This is the corporate
action path working.

*Act.* Watch for the multiplier change that follows (§8.5). If the pause outlasts one trading session with no
corporate action, treat it as a feed failure (§8.2) and consider retirement (§8.10).

### 8.5 Corporate action (split, dividend, `uiMultiplier` change)

*Detection.* Indexer state-diff on `uiMultiplier()` / `effectiveAt`, usually preceded by `oraclePaused()`.

*Immediate.* Nothing, and this matters: **the answer is never re-multiplied.** `uiMultiplier` is a display
figure; raw balances are unaffected. A scheduled split with `oraclePaused()` produces zero position movement,
zero NAV change and a closed bond market. A dividend step is captured by the surge fee.

*Verify after `effectiveAt`.* NAV/share unchanged by more than rounding; no ladder cell moved; the bond market
reopened when the gate cleared; the surge captured ≥ 60% of the step. If any of those is false, freeze that
constituent (guardian, ≤ 7 days) and investigate before it can be bonded against.

### 8.6 Keeper outage

*Detection.* Prometheus: no `compound`/`checkpoint` for more than two intervals.

*Immediate.* Nothing is at risk. Every keeper job is permissionless; ladders are static so trading is unaffected;
bonds and redemption never touch the keeper. Fee AMPS and bonded stock queue.

*Act.* Bring up the second operator instance from a clean checkout (`docs/keeper-runbook.md` §9 proves it decides
identically). If both are down, anyone can run the five calls by hand — `compound(poolId)`, `rollout(id)`,
`deployBonded(id)`, `touch()`, `checkpoint()` — and collect the same bounty.

*On resumption.* Confirm no duplicate send, no R1 violation, and that `touch()` cleared any tripped watchdog.

### 8.7 Band breach (deviation beyond the outer rail)

*Detection.* Hook `RebalanceNeeded`; keeper refusal `diverged`; `|slot0.tick − fairTick| > 800`.

*Immediate.* Nothing. Inside the outer rail no swap reverts; beyond it only deviation-*increasing* swaps revert,
so the pool can always be arbitraged back. The keeper refuses to place into a diverged pool, which is the design.

*Assess.* Is the deviation real (the reference moved) or manipulated (a single large swap)? The truncated TWAP
bounds any single-block move to `maxTickMovePerBlock`, so a manipulated tick reverts placement rather than
poisoning it.

*Act.* If the deviation persists past one TWAP window with a healthy feed, that is a liquidity problem, not a
safety problem: consider a 48-hour `rolloutBpsPerDay` increase for that name, or a buy-fee change. Never
re-centre; there is no entry point that could, and there never will be.

### 8.8 Reference divergence (`REF_DIVERGED`)

*Detection.* `OracleGate.state(0) == REF_DIVERGED`: the `AMPS/USDG` hub TWAP and `AMPS/WETH × ETH/USD` disagree
by more than `refDivergenceBps`.

*Immediate.* Nothing. `P_ref` falls back to `navPerShare` — the NAV floor — and everything else continues. This is
the layer that makes a manipulated entry pool unable to lift the reference.

*Assess.* Which leg moved? Compare each entry pool's TWAP against the feeds. A one-sided move with a healthy
ETH/USD feed is an arbitrage opportunity that will close; a move that tracks a broken ETH/USD feed is §8.2.

*Act.* If ETH/USD is the problem and there is no replacement, the v1 fallback is a governed haircut on the
WETH/USDG v3 TWAP and disabling the cross-check — a 48-hour `setRefDivergenceBps` plus a 7-day feed reconfigure.
Nothing here is urgent: NAV-floored `P_ref` is a safe state, not a degraded one.

### 8.9 Bond-market abuse

*Detection.* Indexer flywheel dashboard: fill rate at 100% of capacity every epoch, realised discount pinned at
`dMax`, accretion at `minAccretionBps`, or a spoke TWAP dumped immediately before a bond.

*Assess.* Abuse is bounded by construction — `q ≤ q_floor` in every state (I27), every bond is accretive by at
least `minAccretionBps`, and a spoke-TWAP dump before a bond only removes the attacker's own discount. Filling
capacity at the floor costs the griefer `minAccretionBps` per epoch. So the question is whether it is *abuse* or
simply demand.

*Act.* Genuine griefing: raise `minAccretionBps` or lower `capBpsPerEpoch` for that market (48 h), or
`setMarketOpen(marketId, false)` (48 h; the guardian's protocol freeze does it immediately and expires in 7
days). Genuine demand at the cap: raise `capBpsPerEpoch` within the §6 rung.

*Never* touch `claim()`. A vesting position claims regardless of collateral removal, market pause, policy swap or
guardian freeze (I38).

### 8.10 Constituent retirement (issuer delisting, dead feed, failed β)

*Act.* One 7-day `PoolRegistry.retireConstituent(constituentId)`. It closes the name's bond market atomically
(I37), zeroes its rollout weight, and leaves the pool tradable.

*Then.* `PoolRegistry.withdrawRetiredBids(constituentId)` (7 d) moves the spoke's remaining **bid** inventory out
of its v4 positions and into idle ERC-6909 claims, where `A` still values it and `redeemProRata` still pays it.
The pool stays tradable and its unfilled asks stay where they are — those are the spoke's exit market, and I29
forbids ever moving a bid up. Re-install the index weight vector over the remaining names in the same batch,
since `setIndexWeights` requires the active weights to sum to exactly 10,000.

*Verify.* NAV/share unchanged beyond rounding; the market is closed; rollout weight is zero; vesting positions in
that market still claim.

*Reinstatement* is `reinstateConstituent(id, rolloutWeightBps)`, also 7 days, and re-opens the market.

### 8.11 Migration (planned)

A planned migration is §8.3's machinery without the emergency: register the standby (14 d), announce, then have
the guardian trigger it once the predicate holds — which it will not, for a planned move. So a *planned*
migration is not `emergencyMigrate`; it is a new deployment plus `redeemProRata`, because the contracts are
immutable and that is the honest cost of immutability.

**The sequence:** deploy the new system alongside; publish the redemption path; let holders redeem pro-rata at
NAV − `redeemFeeBps` and re-enter; retire the old constituents so no new bonds are issued; leave the old vault
running indefinitely so late redeemers are never stranded. Do not attempt to move user positions.

---

## 9. Governance drills

Rehearse all of these on 46630 before §1 item 5 can be ticked, and re-rehearse §9.1 and §9.4 quarterly.

| # | Drill | Pass condition |
|---|---|---|
| 1 | Propose, wait, execute a 48-hour parameter change | the value moves only after the delay, and only inside its band |
| 2 | Propose a parameter **outside** its band | `execute` reverts; nothing changes |
| 3 | Guardian cancels a pending proposal | the operation is gone; a re-proposal needs a new salt |
| 4 | Guardian freezes the protocol for 7 days | placements and bond issuance stop; **`redeemProRata` and `claim` still succeed**; the freeze lapses with no action |
| 5 | Guardian freezes one constituent | only that name's market and placements stop |
| 6 | Execute a matured proposal from an address with no roles | it succeeds — the executor is open |
| 7 | Swap a policy pointer (`FeePolicy`) | new fees apply to new swaps only; nothing re-prices retroactively |
| 8 | Swap `BondPolicy` | only new bonds re-price; existing vesting positions are untouched |
| 9 | Register a standby vault (14 d), then run the full denylist → `emergencyMigrate` drill | NAV/share moves < 50 bp; all five vault roles move (AMPS, bonds, pot, registry, hook); the standby can `initializePool` and place; a new standby is registered afterwards |
| 9a | Point `AmpsHook.setRouter` at the zero address (7 d), then back at `AmpsRouter` | while it is zero, a `rotate` still executes but both hops pay `ampsFeeBps` — the exemption is withdrawn, not the route; the dApp's Rotate surface shows the mismatch before a signature is asked for |
| 10 | Retire a constituent, then reinstate it | I37 holds throughout; vesting claims keep working |
| 11 | Lose the deployer key **after** `finalize` | nothing is lost: it has no roles |
| 12 | Lose 2 of 5 proposer signers | the Safe still reaches 3/5 and governance continues |
| 13 | Lose 3 of 5 proposer signers | governance is stuck for changes but the protocol keeps running, redemption included. Document this as the accepted failure mode |

---

## 10. Recurring operational tasks

| When | Task |
|---|---|
| Every December | Propose next year's NYSE holiday bitmap (48 h). An unknown year is treated as having no full-day closures — a liveness choice, not a safety one. `script/lib/Calendar.sol` holds the current table |
| Quarterly | Re-run the index rule and propose the new weight vector (7 d). Re-rehearse drills §9.1 and §9.4 |
| Quarterly | Re-mine and re-check the hook address after any dependency bump (CI's `hook-address` job does it per commit) |
| Monthly | Review the §6 clean-day ledger and either advance the rung or restate why not |
| Monthly | Reconcile the indexer against chain reads for NAV, `P_ref`, shares, fees and burns |
| On every dependency bump | `pnpm --filter @amplestocks/contracts broadcast-test`, twice |
| Day 30 after genesis | Confirm the creator fee has reached zero and the team vest has completed on schedule |
