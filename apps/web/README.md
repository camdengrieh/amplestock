# @amplestocks/web

Amplestocks dApp. **Placeholder — deliberately not scaffolded (Phase 5).**

Dependencies are declared (Next 16, React 19, wagmi 2, viem 2, TanStack Query 5) so the workspace
resolves and CI has something to install, but there is no `app/`, no `next.config`, no components.
Run `pnpm dlx create-next-app` into this directory when Phase 5 starts, keeping the package name and
the workspace dependencies on `@amplestocks/config` and `@amplestocks/abis`.

Planned surface, from the plan:

- NAV/share, fully diluted, next to the market price of each of the 32 pools, with the premium or
  discount and the redemption floor (NAV − `redeemFeeBps`) shown explicitly.
- Per-pool POL disclosure: because pools are POL-only, the vault is the only bidder, so bid depth is
  exactly the counter-assets the POL has earned. That number is published per pool, not hidden.
- Redeem (pro-rata, unpausable), stake/unstake xAMPS, and the open bond markets with their current
  discount, remaining epoch capacity and vest.
- Oracle and session state per constituent (Regular / Pre-Post / Overnight / Closed) with the
  haircut currently applied, and any guardian freeze in force.
- Governance queue: what is timelocked, by which Safe, and when it can execute.

MIT licensed — see the repository root `LICENSE`.
