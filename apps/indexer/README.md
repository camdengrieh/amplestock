# @amplestocks/indexer

Ponder 0.17 indexer for Amplestocks: every protocol event, the Uniswap v4 `PoolManager` filtered to
our 32 pools with the fee decomposed by direction and rotation credit, the `uiMultiplier()` state
diff per constituent, the beacon-level denylist alarm, and NAV/inventory reconciliation against
chain reads at every checkpoint block.

**`docs/indexer.md` is the documentation** — the schema, the fee-decoding rules, the reconciliation
bounds, the alert semantics and the HTTP surface. This file is the short version.

## Run

```sh
cp .env.example .env.local          # fill in the deployment addresses
pnpm dev                            # PGlite, GraphQL on :42069/graphql, typed layer on /api/*
pnpm start                          # production: Postgres via DATABASE_URL, PGlite otherwise
```

Every address is deployment state and comes from the environment or from the `deployments.json` the
deploy scripts write (`AMPS_DEPLOYMENTS`); only the chain's own infrastructure — the v4 PoolManager,
WETH9, USDG and the Stock Token beacon on 4663 — falls back to `@amplestocks/config`.

## Test

```sh
pnpm test                           # offline: pure units plus every handler on synthetic logs
AMPS_E2E=1 pnpm test:e2e            # anvil: the whole system, then the indexer over it
pnpm typecheck
```

`pnpm test` needs no chain, no Foundry and no network. The end-to-end suite is opt-in for exactly
that reason.

## Layout

```
ponder.config.ts     sources: eleven log contracts, two account (transaction) sources, two block jobs
ponder.schema.ts     46 tables
src/config/          the address book and the environment, both read at start-up
src/abi/external.ts  the Stock Token and Chainlink ABIs (ours come from @amplestocks/abis)
src/lib/             fee decoding, tick and liquidity maths, reconciliation, alerts, ids, flywheel
src/handlers/        one module per contract, plus the two block jobs and the denylist alarm
src/api/             GraphQL plus the typed HTTP layer
test/                unit tests, handler tests on synthetic logs, and test/e2e against anvil
```

MIT licensed — see the repository root `LICENSE`.
