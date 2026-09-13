# @amplestocks/web

The Amplestocks dApp: Auction, Buy/Sell, Rotate, Bond, Redeem, Vault, Governance, `/docs` and a
static `/risk` page, behind a geo gate and a terms gate.

There is no Stake surface. Plan revision 6 removes staking: no xAMPS, no staker slice of the fee,
no reward stream. The AMPS side of every fee is burned after the creator slice, in full.

The fee model the surfaces are built on: `AmpsHook.ampsFeeBps` is the base on **both** directions of
every pool, and the pool's own `buyFeeBps` is the *pass-through* price — what one hop of an
`AmpsRouter.rotate` pays instead, and nothing else can reach it. The hook grants that price on a hop
only when the swap's sender is the address in `AmpsHook.router()` and the hop carries
`Constants.ROUTER_ROTATE`, so Rotate builds `AmpsRouter.rotate` and Buy / Sell quotes the AMPS fee
in both directions.

The interface is **Ledger** — a paper/ink two-theme system of hairline rules, a serif for text and a
mono for every label and figure. The design's tokens, type scale and component vocabulary are in
[`design/ledger/`](./design/ledger/), and the tokens themselves live in
[`app/globals.css`](./app/globals.css), which is the only place a colour is written down.

Full documentation of the surfaces and the reads/writes each makes, the configuration, the gates,
the route-encoding golden vector, and what the interface must never say lives in
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
| `test` | vitest — 323 tests, all offline |
| `test:e2e` | Playwright — 21 smoke tests plus the screenshot run, against a real production build with a mocked chain. **Not** part of `test` and not run in CI: it needs a browser. |

`test:e2e` rebuilds `.next` with a fixture deployment baked in, because `NEXT_PUBLIC_*` is inlined
at build time. Run `pnpm --filter @amplestocks/web build` afterwards to restore the ordinary bundle.
Chromium is pre-installed at `/opt/pw-browsers`; do not run `playwright install`.

`e2e/screenshots.spec.ts` writes every surface in both themes at 1400 px and 390 px into
`design/ledger/screenshots/`.

## Layout

```
app/                 routes; everything under app/(gated)/ is behind the terms gate.
                     /docs and /risk sit outside it — somebody deciding whether to accept the
                     terms should be able to read what they are accepting first
components/ui/       the Ledger primitives, keeping the shadcn API the surfaces already speak
components/ledger/   Kicker, Rule, SectionRule, Figure — the design's own vocabulary
components/surfaces/ one file per surface, with its presentational panels exported for tests
components/docs/     the docs frame and the block renderers
components/common/   Value, Stat, DegradedNotice, TxButton — the shared vocabulary
hooks/               wagmi read hooks, the write/simulate hook, approvals, the indexer hook
lib/                 the pure maths and policy: fees, route encoding, auction Q96 maths, bonds,
                     redeem, quoter, theme, geo, terms, copy, config and the indexer client
lib/abi/             two files. `cca.ts` transcribes Uniswap's ContinuousClearingAuction, a
                     third-party dependency with no Solidity source here, so codegen can never
                     produce it; `router.ts` re-exports the generated ampsRouterAbi and keeps
                     routerDeadline beside it. The four temporary transcriptions this list used to
                     name are gone: @amplestocks/abis was regenerated from the revision-6 and
                     revision-7 artefacts, so lib/contracts.ts takes ampsVaultAbi, ampsQuoterAbi,
                     ampsHookAbi, ampsRouterAbi and ampsGenesisAbi from the package itself.
lib/docs/            the documentation as data: pages, blocks, the figure catalogue and the pure
                     resolver that turns live reads into the strings a page prints
proxy.ts             the IP half of the geo gate (Next 16's name for middleware)
test/                vitest
e2e/                 Playwright, with the JSON-RPC mock and the screenshot run
```

## The two rules that run through all of it

**A degraded field is rendered as unavailable, never as zero.** `AmpsQuoter` never reverts, so a
read that fails leaves its fields at zero and raises a bit in `degraded`. A zero rendered as data is
something a user can trade on, and a degraded quote is never permission to trade.

**No figure is written down.** Every percentage, address, count and price on every surface — and
every one in `/docs` — names a source and is resolved when the page loads: a contract call, the
deployment record, or `@amplestocks/config`. A source that cannot answer renders a dash with its
reason. `test/docs.test.ts` fails the build if a documentation page prints a number that no source
can be checked against.

MIT licensed — see the repository root `LICENSE`.
