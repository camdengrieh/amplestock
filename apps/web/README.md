# @amplestocks/web

The Amplestocks dApp: Buy/Sell, Rotate, Bond, Redeem, Stake, Vault, Governance and a static
`/risk` page, behind a geo gate and a terms gate.

Full documentation — surfaces and the reads/writes each makes, configuration, the gates, the
route-encoding golden vector, and what the interface must never say — lives in
[`docs/dapp.md`](../../docs/dapp.md).

## Quick start

```sh
pnpm install                                    # from the repository root
cp apps/web/.env.example apps/web/.env.local
pnpm --filter @amplestocks/web dev              # http://localhost:3000
```

Nothing is deployed yet, so with an empty `.env.local` every trading surface renders its "not
deployed on this chain" state rather than reading the zero address and showing the answers.

## Scripts

| Script | What it does |
|---|---|
| `dev` | Next dev server on port 3000 |
| `build` | production build; succeeds with no network access |
| `typecheck` / `lint` | `tsc --noEmit` (the same check twice, matching the rest of the workspace) |
| `test` | vitest — 218 tests, all offline |
| `test:e2e` | Playwright — 16 tests against a real production build with a mocked chain. **Not** part of `test` and not run in CI: it needs a browser. |

`test:e2e` rebuilds `.next` with a fixture deployment baked in, because `NEXT_PUBLIC_*` is inlined
at build time. Run `pnpm --filter @amplestocks/web build` afterwards to restore the ordinary bundle.
Chromium is pre-installed at `/opt/pw-browsers`; do not run `playwright install`.

## Layout

```
app/                 routes; everything under app/(gated)/ is behind the terms gate
components/ui/       vendored shadcn components
components/surfaces/ one file per surface, with its presentational panels exported for tests
components/common/   Value, Stat, DegradedNotice, TxButton — the shared vocabulary
hooks/               wagmi read hooks, the write/simulate hook, approvals, the indexer hook
lib/                 the pure maths and policy: fees, route encoding, bonds, redeem, quoter,
                     geo, terms, copy, config and the indexer client
proxy.ts             the IP half of the geo gate (Next 16's name for middleware)
test/                vitest
e2e/                 Playwright, with the JSON-RPC mock
```

The rule that runs through all of it: `AmpsQuoter` never reverts, so a read that fails leaves its
fields at zero and raises a bit in `degraded`. **A degraded field is rendered as unavailable, never
as zero**, and a degraded quote is never permission to trade.

MIT licensed — see the repository root `LICENSE`.
