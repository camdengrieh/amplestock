# @amplestocks/keeper

Permissionless keeper for Amplestocks. **Placeholder — deliberately not scaffolded (Phase 4).**

`viem` 2 is declared so the workspace resolves; there is no bot yet. Everything this process will do
is permissionless and bounty-paid from `BountyPot`: if this keeper stops, anyone else's does the same
work and collects the same tip. Nothing here is a trusted component.

Planned jobs:

- `compound()` per pool when the accrued fee is worth more than `chost` ($1 start), collecting the
  `tip` ($0.05 start, governed upward with TVL) from `BountyPot`.
- Rollout: move unfilled ask buckets from the entry pools into the spokes at `rolloutBpsPerDay`
  (200 bp/day start) subject to `entryFloorBps` (3000).
- Bond epoch turnover on `epochSeconds` (6 h) and the global `dailyCapBps` (200) accounting.
- Oracle liveness: watch feed staleness and the equity session, and surface (never act on) a stale
  feed to the guardian Safe.
- Health checks that never touch funds: NAV/share vs pool prices, POL bid depth per pool, timelock
  queue.

Needs a funded EOA and an RPC on 4663; it cannot run until the sandbox network policy is widened.

MIT licensed — see the repository root `LICENSE`.
