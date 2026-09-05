# @amplestocks/indexer

Ponder indexer for Amplestocks. **Placeholder — deliberately not scaffolded (Phase 5).**

`ponder` 0.17 and `viem` 2 are declared so the workspace resolves; there is no `ponder.config.ts`,
no schema and no event handlers yet. Scaffold with `pnpm create ponder` into this directory when the
contracts and their ABIs exist, sourcing chain config from `@amplestocks/config` and ABIs from
`@amplestocks/abis`.

Planned indexes:

- NAV/share and total supply over time, from vault `compound()` and bond issuance.
- Per-pool swap flow across all 32 hooked pools, split into buys and sells, with the fee actually
  charged (directional fee plus any surge) and the rotation credits applied.
- Ladder state per pool: which buckets are filled, what each raised, and what was re-laddered,
  burned or rolled out.
- Bond markets: discount path, epoch capacity used, accretion per bond and vesting claims.
- xAMPS: deposits, withdrawals, share price and the 24 h reward stream.
- Governance and safety: timelock queue/execute, guardian freezes, oracle staleness and session
  transitions per constituent.

Runs against Robinhood Chain 4663 (and 46630 on testnet); an RPC that supports historical logs is
required, so this cannot run until the sandbox network policy is widened.

MIT licensed — see the repository root `LICENSE`.
