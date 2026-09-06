# The Chainlink CRE mirror

A cron-triggered CRE workflow that reaches the same decisions as `apps/keeper`, from the same code.

## Why it exists

The keeper is permissionless: `compound`, `rollout` and `deployBonded` pay a bounty to whoever calls them, and
`checkpoint` / `touch` are unpaid and open to anyone. So a second, independent trigger costs the protocol
nothing and removes the operator as a single point of failure. If both fire at once, the loser hits the
60-second per-pool cooldown and its transaction reverts without paying a bounty — the race is safe by
construction, which is why running both is a configuration choice rather than a coordination problem.

## What is mirrored, and what is not

| Stage | Where it runs | In the mirror? |
|---|---|---|
| Gate state, protocol freeze, per-pool placement permission | `view` reads | yes |
| Divergence at entry, the 60 s cooldown, the live-cell budget | `view` reads | yes |
| Checkpoint staleness, the deploy threshold, rollout eligibility | `view` reads | yes |
| Measured work value against `chost` | needs `eth_call` return values | no |
| Bounty against `gasEstimate x basefee` | needs `eth_estimateGas` | no |

`workflow.ts` imports `screen()` from `../domain/decide.js` — **the same function the service calls**. "The CRE
workflow mirrors the keeper" is therefore one implementation called from two places, not two implementations
kept in step by hand; `test/cre.test.ts` asserts the agreement candidate by candidate anyway.

The second half of the keeper's decision needs a simulation, and a CRE workflow has no `eth_estimateGas`. The
consumer contract that acts on the report is where that lands: it should simulate before it sends, exactly as
`src/jobs/index.ts` does, and drop a job whose bounty does not cover its gas.

## Shape

```
src/cre/
├─ sdk.ts        — the SDK surface the workflow uses, declared locally (CreSdk, CreRuntime, WorkflowBinding)
├─ workflow.ts   — decideJobs(), encodeReport(), buildWorkflow(sdk, config, readSnapshot), runWorkflow(...)
└─ README.md     — this file
```

`buildWorkflow` takes the SDK as a **parameter**. That is what makes the file compile and typecheck here with
`@chainlink/cre-sdk` absent, and what lets `test/cre.test.ts` drive the handler with a fake SDK and a scripted
snapshot. It is also the one line that changes on deployment.

`readSnapshot` is injected for the same reason: CRE's EVM read surface differs between SDK versions, and the
decision function does not care where a `ChainSnapshot` came from.

## Deploying it to Robinhood Chain testnet

Not possible from this repository as it stands — the sandbox reaches npm and nothing else, and the plan puts
the testnet work behind the network-policy widening (Phase 0). The steps, for when it is:

1. **Add the SDK** to `apps/keeper`:
   ```sh
   flock /tmp/amps-pnpm.lock pnpm --filter @amplestocks/keeper add -E @chainlink/cre-sdk
   ```

2. **Write the entry module**, `src/cre/main.ts`, which is the only file that touches the real package:
   ```ts
   import {cron, handler, runner} from '@chainlink/cre-sdk'
   import {runWorkflow} from './workflow.js'
   import {readSnapshotFromEvm} from './read.js'   // your ABI-encoded read sequence

   runWorkflow({cron, handler, runner}, {
     chainSelector: process.env.CRE_CHAIN_SELECTOR!,   // the CCIP selector for 46630
     amps: process.env.AMPS_TOKEN_ADDRESS as `0x${string}`,
     schedule: '*/1 * * * *',
   }, readSnapshotFromEvm)
   ```
   If the installed SDK's exported names differ from `CreSdk`, adapt them in this file; `workflow.ts` never
   imports the package, so nothing else moves.

3. **Implement `readSnapshotFromEvm`.** It builds the same `ChainSnapshot` `ChainReader` builds, through
   `runtime.evm(chainSelector).call(...)` with calldata from `@amplestocks/abis`:
   `Amps.vault()`, then the vault's pointer set, then `OracleGate.state(0)` / `protocolFreezeUntil()` /
   `watchdog()`, `AmpsVault.checkpointData()` / `liveCells()` / the parameter getters, `BountyPot`'s parameters
   and `quote(1e18, 1e18)`, and per pool `PoolRegistry.poolConfig`, `OracleGate.snapshotByPool` and
   `isPlacementAllowed`, `AmpsHook.highWaterTick`. Nothing on that list can revert.

4. **Compile to WASM** with the CRE toolchain (`cre workflow compile`, javy plugin) and simulate locally
   (`cre workflow simulate`).

5. **Deploy** against the testnet with the CRE CLI, funding the workflow's own account, and register the
   consumer contract that turns a report into `compound` / `rollout` / `deployBonded` calls. The consumer needs
   no privileges: all three are permissionless.

6. **Run both** the service and the workflow for the plan's seven consecutive testnet days. Zero missed
   triggers is the exit criterion; a duplicate is not a failure, it is the cooldown doing its job.

## Configuration

| Field | Meaning |
|---|---|
| `chainSelector` | CCIP-style selector for the target chain, from the CRE deployment. Never a literal in code. |
| `amps` | The AMPS token. Everything else is resolved from it, exactly as the service does. |
| `schedule` | Cron, UTC. One minute matches the keeper's default scan interval closely enough. |
| `policy` | A `KeeperPolicy`; defaults to `DEFAULT_POLICY`, which is `Constants.sol`'s values. |
| `lastTouchAt` | CRE runs are stateless, so the `touch()` clock is passed in — the consumer contract's own record is the natural source. |
