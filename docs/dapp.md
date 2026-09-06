<!-- SPDX-License-Identifier: MIT -->

# `apps/web` — the Amplestocks dApp

Next.js App Router front end for the Amplestocks contracts on Robinhood Chain. Nine routes, two
gates, one rule about numbers, and a build that never touches the network.

- **Surfaces**: [Buy / Sell](#buy--sell), [Rotate](#rotate), [Bond](#bond), [Redeem](#redeem),
  [Stake](#stake), [Vault](#vault), [Governance](#governance), the static [`/risk`](#risk) page,
  and `/blocked`.
- **Gates**: an IP geo-block on US / CA / UK / CH with a pluggable provider, plus a per-browser
  terms gate carrying a jurisdiction self-attestation. Every trading surface is behind both.
- **The rule**: `AmpsQuoter` never reverts — a read that fails leaves its fields at zero and raises
  a bit in `degraded`. **A degraded field is rendered as unavailable, never as zero**, and a
  degraded quote is never permission to trade.

---

## Stack, and what was pinned

Every dependency is pinned to an exact version. The plan's numbers were targets; the table records
what npm actually had on 2026-09-06 and where the two differ.

| Package | Plan target | Pinned | Note |
|---|---|---|---|
| `next` | 16.3 | **16.3.4** | Turbopack is the default builder in 16. `middleware.ts` is now `proxy.ts`. |
| `react` / `react-dom` | 19.2 | **19.2.8** | |
| `viem` | 2.56 | **2.56.3** | Ships `robinhood` (4663) and `robinhoodTestnet` (46630) as built-in chains; the app uses those rather than defining its own. |
| `wagmi` | 2.19.5 | **2.19.5** | **Deliberately not the current stable.** npm's latest is `wagmi@3.7.7`, but `@reown/appkit-adapter-wagmi@1.8.23` still resolves `@wagmi/core@2.x` internally, so the `Config` its `WagmiAdapter` builds is type-incompatible with wagmi 3's `WagmiProvider` (`_internal.connectors.setup` and the `Storage` shape both diverge). 2.19.5 is the newest 2.x and is what the AppKit adapter supports. Revisit when Reown ships a wagmi-3 adapter. |
| `@tanstack/react-query` | 5 | **5.102.8** | |
| `tailwindcss` / `@tailwindcss/postcss` | 4 | **4.3.3** | |
| `@reown/appkit`, `@reown/appkit-adapter-wagmi` | 1.8.x | **1.8.23** | |
| `@uniswap/v4-sdk` | 2.3.3 | **2.3.3** | |
| `@uniswap/universal-router-sdk` | 5.11.5 | **5.11.5** | |
| `@uniswap/sdk-core` | — | **7.19.2** | |
| `typescript` | — | **5.9.3** | TypeScript 7.0.2 exists; the rest of the workspace is on 5.9.3 and a one-package bump would fork the toolchain. |
| `vitest` / `vite` / `@vitejs/plugin-react` | — | **5.0.0 / 8.2.2 / 6.1.1** | |
| `@playwright/test` | — | **1.56.1** | **Pinned to the pre-installed browser.** `/opt/pw-browsers` carries Chromium revision 1194, which is Playwright 1.56.x; 1.63.0 is the current release and expects 1243. `playwright install` is never run. |
| shadcn components | — | vendored | shadcn copies source into the repo by design. `components/ui/*` are those components, on `@radix-ui/*` 1.x/2.x primitives, `class-variance-authority` 0.7.1, `clsx` 2.1.1, `tailwind-merge` 3.6.0. |

ABIs come from `@amplestocks/abis`, imported through its **`./generated` subpath** rather than its
root: the root re-exports with `export * from './generated.js'`, an extension TypeScript rewrites
and the bundler does not, so the root entry resolves to an empty module under Turbopack.

---

## Configuration

Two halves, and the split is deliberate.

**Reference addresses** — PoolManager, UniversalRouter, Permit2, WETH9, USDG, bridged USDC, the
Across SpokePool, the stock-token beacon, the Chainlink feeds — come from `@amplestocks/config` and
are never written down in `apps/web`. `@amplestocks/config` holds a book for 4663 only; 46630
returns `null`, and every consumer handles that rather than silently borrowing mainnet's.

**Deployment addresses** — the Amplestocks contracts themselves — come from the environment,
because they do not exist yet: nothing is deployed, `@amplestocks/config` has no slot for them, and
inventing one would put a zero address in the repository that looks like data. A missing address is
not an error and never a zero-address read: the surface renders its "not deployed on this chain"
state instead.

```
NEXT_PUBLIC_AMPS_CHAIN_ID      4663 or 46630 (default)
NEXT_PUBLIC_AMPS_RPC_URL       optional override; defaults to the chain's public RPC
NEXT_PUBLIC_REOWN_PROJECT_ID   empty -> AppKit is not mounted; injected connector only
NEXT_PUBLIC_AMPS_INDEXER_URL   empty -> indexed panels render "indexer unavailable"

NEXT_PUBLIC_AMPS_TOKEN / _VAULT / _QUOTER / _BONDS / _BONDS_LENS / _STAKING /
NEXT_PUBLIC_AMPS_REGISTRY / _REGISTRY_LENS / _HOOK / _ORACLE_GATE / _TIMELOCK

NEXT_PUBLIC_FLAG_ACROSS_ZAP     "1" shows the (inert) Across USDC->USDG entry point
NEXT_PUBLIC_FLAG_TESTNET_BANNER "1" shows the testnet badge

GEO_PROVIDER            vercel | cloudflare | header | none   (server-side only)
GEO_COUNTRY_HEADER      header name when GEO_PROVIDER=header
GEO_BLOCKED_COUNTRIES   default US,CA,GB,UK,CH
```

`NEXT_PUBLIC_*` is inlined at **build** time, not read at start time. Changing a deployment address
means rebuilding.

See `apps/web/.env.example`.

---

## Surfaces

Every surface reads through `AmpsQuoter` where it can, because that contract is specified never to
revert and to say which of its sub-reads failed.

### Buy / Sell
`app/(gated)/buy` → `components/surfaces/buy-sell.tsx`

`AMPS/WETH` by default (with a native-ETH toggle) and `AMPS/USDG`. The pool list is one
`AmpsQuoter.quoteAll()`.

- **Reads**: `AmpsQuoter.quoteAll()` (fees in both directions, `refuseBuy`/`refuseSell`, ticks and
  bands, gate state, session, NAV, reference and market price, `degraded`); ERC-20 and Permit2
  allowances for the input token.
- **Writes**: `UniversalRouter.execute(commands, inputs, deadline)` — `WRAP_ETH` (optional),
  `V4_SWAP`, `UNWRAP_WETH` (optional). The router address is `@amplestocks/config`'s
  `universalRouter`, never the SDK's own default.
- Shows the sell fee and the rotation-credit rule on the surface, not in a tooltip. Renders
  `refuseBuy`/`refuseSell` as "this swap would revert" with the reason a smaller size does not help.
  The Across USDC→USDG zap sits behind `NEXT_PUBLIC_FLAG_ACROSS_ZAP` and is an explicit, disabled
  stub — the entry point and the SpokePool address exist, the bridge call does not.

### Rotate
`app/(gated)/rotate` → `components/surfaces/rotate.tsx`

Stock → AMPS → stock, exact input, one transaction.

- **Reads**: `AmpsQuoter.quoteRotation(hop1, hop2, amountIn)` → `(amountOut, hop1FeePips,
  hop2FeePips, creditUsed)`; `quoteAll()` for the spoke list and per-pool fees.
- **Writes**: `UniversalRouter.execute` with one `V4_SWAP` carrying one `SWAP_EXACT_IN` and a
  two-element `PathKey[]`.
- Shows the credited second hop next to the same two swaps done separately. It does **not** claim
  to have surveyed the market: no external aggregator is configured, and the panel says so.

### Bond
`app/(gated)/bond` → `components/surfaces/bond.tsx`

- **Reads**: `AmpsBondsLens.board(bonds, amountIn)` (every market, including the ones that cannot be
  bonded — `quote()` never reverts for a known market, it returns `ampsOut == 0` with a reason);
  `AmpsBonds.quote(marketId, amountIn)`; `AmpsBonds.dailyIssuance()`;
  `AmpsBondsLens.positionsOf` / `positionTotals`.
- **Writes**: `AmpsBonds.bond(marketId, amountIn, minAmpsOut, to)`; `AmpsBonds.claim(positionId, to)`.
- **`minAmpsOut` is always exactly the quoted `ampsOut`.** The capacity clamp reduces the AMPS
  issued and never the collateral taken, so a lower bound is not tolerance — it is consent to hand
  over the whole deposit for a capped issue. `lib/bonds.ts` exports `assertBondMinAmpsOut`, which
  throws if anything ever tries to widen it, and a test pins that.
- Shows the discount, the capacity left, the vest schedule and whether `q` came from the market
  discount or from the NAV floor.

### Redeem
`app/(gated)/redeem` → `components/surfaces/redeem.tsx`

- **Reads**: `AmpsVault.previewRedeem(shares)` → `(tokens, amounts, inventoryBurned)`;
  `AmpsVault.checkpointData()`; `AmpsVault.redeemFeeBps()`; `Amps.totalSupply()`.
- **Writes**: `AmpsVault.redeemProRata(shares, to)`.
- One line per asset, with the fee broken out rather than folded invisibly into the payout, and the
  released inventory AMPS burned alongside disclosed — which is why total supply falls by more than
  the amount redeemed. The surface says plainly that it pays assets, not cash.

### Stake
`app/(gated)/stake` → `components/surfaces/stake.tsx`

- **Reads**: `AmpsStaking.totalAssets/totalSupply/pendingRewards/releasedRewards/streamEnd/
  streamSecondsRemaining/rewardStreamSeconds/totalNotified/balanceOf`; the indexer's
  `stakingStats()` for the realised APR.
- **Writes**: `AmpsStaking.deposit(assets, receiver)`, `AmpsStaking.withdraw(assets, receiver, owner)`.
- The APR is realised — computed from sell fees already collected and streamed over a past window —
  and is labelled as such. With no indexer it is unavailable, not zero.

### Vault
`app/(gated)/vault` → `components/surfaces/vault.tsx`, `vault-panels.tsx`

The disclosure page.

- **Reads (chain)**: `AmpsVault.checkpointData` (NAV/share, `P_ref`, `P_mkt`, timestamp),
  `previewNavPerShareX18`, `totalAssetsUsd18`, `inventoryAmps`, `redeemFeeBps`, `burnBps`,
  `stakerBps`, `genesisTimestamp`, `liveCells`, `initialized`; `Amps.totalSupply`;
  `AmpsStaking.totalAssets`; `AmpsQuoter.quoteAll` for the per-pool gate table.
- **Reads (indexer)**: NAV/share history, ladder fill per pool with proceeds per cell, burn
  history, `peg_dev_bp`.
- **Writes**: `AmpsVault.checkpoint()` — free, permissionless, and offered as a button.
- Premium is `pRef / navPerShare - 1` rendered as a signed number with the note that nothing on
  chain consumes it.

### Governance
`app/(gated)/governance` → `components/surfaces/governance.tsx`

Read-only.

- **Reads**: `PoolRegistry.constituentCount/activeConstituentCount/poolCount/indexCapBps/
  indexFloorBps/hubPoolId/wethPoolId`; `PoolRegistryLens.activeConstituents/indexWeights`;
  the vault's fee parameters; the timelock address.
- Every parameter is shown next to the band hardcoded in the contract that consumes it, with the
  timelock delay. The pending-operations panel refuses to imply the queue is empty:
  `TimelockController` answers only for an operation id you already hold, and enumerating the queue
  needs the `CallScheduled` log stream from the indexer.

### Risk
`app/risk` — static, no wallet, no chain read, outside both gates. It has to render for somebody
who has accepted nothing and been blocked by everything. Content lives in `lib/copy.ts` as data so
tests can assert over it: POL-only bid depth, redemption as the only floor, the premium as a
number, no authorised participant, chain-level censorship, issuer denylist and pause risk, no
returns, the jurisdiction block, and immutability.

---

## Gates

**Geo (`proxy.ts`).** `GEO_PROVIDER` selects where the country comes from — `vercel`
(`x-vercel-ip-country`), `cloudflare` (`cf-ipcountry`), `header` (a named header), or `none`.
A blocked country is rewritten to `/blocked`. **No signal is not a block**: the request is marked
`x-amps-geo-unverified` and the app tells the user the attestation is the only check standing,
because pretending to have checked would be worse than saying so. `/blocked` and `/risk` stay
reachable from everywhere.

**Terms (`components/gates/terms-gate.tsx`).** Two boxes, both required: not resident in a
restricted jurisdiction, and has read `/risk`. Stored in `localStorage` with the terms version, so
changing the disclosures re-prompts everybody. No account, no cookie, no server-side record. A
browser with storage disabled simply re-prompts every load. Everything under `app/(gated)/` is
behind it; `/risk` and `/blocked` are not.

---

## Transactions

Every write is **simulated before it is offered**. `useSimulateContract` runs on the read path and
its failure puts the button into `blocked` with a named, explained reason before a wallet ever
opens — nobody should learn the rail is breached by paying gas to find out.

`lib/errors.ts` decodes and explains `BeyondRail` / `BeyondOuterRail`, `SlippageExceeded`,
`CapacityExceeded`, `GateNotHealthy`, `PlacementCooldown`, `PlacementDiverged`,
`AccretionFloorViolated`, `MarketClosed`, `StaleCheckpoint`, `ConstituentFrozen`,
`InsufficientInventory`, `Reentrancy` and `OutOfBand`, each with one honest explanation and one
next step. A wallet rejection is recognised and reported as "nothing moved".

Approvals: the Universal Router pulls the input token through Permit2, so a first swap needs the
ERC-20 → Permit2 allowance and then the Permit2 → router allowance. `hooks/use-approvals.ts` reads
both and says which is missing rather than asking twice blindly.

---

## Running it

```sh
pnpm install                                    # from the repository root
cp apps/web/.env.example apps/web/.env.local    # then fill in what you have
pnpm --filter @amplestocks/web dev              # http://localhost:3000

pnpm --filter @amplestocks/web typecheck
pnpm --filter @amplestocks/web test             # vitest, 218 tests
pnpm --filter @amplestocks/web build            # production build, no network required
pnpm --filter @amplestocks/web test:e2e         # Playwright, 16 tests — NOT part of `pnpm test`
```

`test:e2e` is deliberately outside `pnpm test` and outside CI: it needs a browser, and CI runners do
not have one. It rebuilds `.next` with a fixture deployment in the environment (because
`NEXT_PUBLIC_*` is inlined at build time), serves it with `next start`, answers every JSON-RPC call
from `e2e/rpc-mock.ts` through a Playwright route, and aborts any request that tries to leave for
the internet. Chromium is pre-installed at `/opt/pw-browsers`; do not run `playwright install`.
Run `pnpm --filter @amplestocks/web build` afterwards to restore the ordinary bundle.

## Tests

**vitest — 218 tests in 21 files**, all offline.

| File | What it pins |
|---|---|
| `test/fees.test.ts` | the rotation-credit blend `buyFee + ceilDiv((sellFee - buyFee)(in - c), in)`, its rounding direction and monotonicity; the fee clamp and the degraded fee floor; the creator schedule reaching exactly zero at day 30 |
| `test/route.test.ts` | the **golden vector** below, plus the wrap/unwrap commands and that AMPS stays `currency0` |
| `test/bonds.test.ts` | `minAmpsOut` is exactly the quote and `assertBondMinAmpsOut` refuses anything else; capacity-clamp detection; `q_floor`; the linear vest |
| `test/quoter.test.ts` | the degraded bitfield → per-field availability map; `isTradeable` false for any degraded quote |
| `test/redeem.test.ts` | pro-rata preview, fee reconstruction, the floor as arithmetic |
| `test/geo.test.ts`, `test/terms.test.ts` | the two gates |
| `test/copy.test.ts` | scans `app/`, `components/` and `lib/` for language the plan forbids, and asserts each required disclosure is present |
| `test/errors.test.ts`, `test/format.test.ts`, `test/indexer.test.ts`, `test/deployment.test.ts` | error surfacing, "never a zero for an unavailable value", the indexer client, address handling |
| `test/components/*.test.tsx` (9 files) | degraded rendering, the swap quote, the terms gate, the bond board and quote panel, the redeem preview, the rotation comparison, the vault panels, the governance tables, the transaction states |

**Playwright — 16 tests in 2 files**: every surface loads and renders chain data from the mock;
both gates behave; `/risk` is reachable with nothing accepted and from a blocked jurisdiction.

### The route-encoding golden vector

`NVDA → AMPS → AAPL`, exact input `1e18`, minimum out `0.99e18`, tick spacing 60,
`fee = DYNAMIC_FEE_FLAG (0x800000)`, `hooks = 0x…38C0`:

```
commands = 0x10                     one V4_SWAP command, and only one
actions  = 0x070c0f                 SWAP_EXACT_IN, SETTLE_ALL, TAKE_ALL
inputs   = [ 1 element, 1120 bytes ]
           SWAP_EXACT_IN(( currencyIn = NVDA,
                           path = [ {AMPS,  0x800000, 60, 0x…38C0, 0x},
                                    {AAPL,  0x800000, 60, 0x…38C0, 0x} ],
                           amountIn          = 1000000000000000000,
                           amountOutMinimum  =  990000000000000000 ))
```

The shape is the point. Two commands, two transactions or an exact-**output** second leg all encode
differently and all throw the rotation credit away: the credit lives in EIP-1153 transient storage,
so it cannot cross a transaction, and an exact-output sell does not consume it at all. The full
1120-byte input is asserted byte for byte in `test/route.test.ts`.

The ETH leg: `commands = 0x0b10` (`WRAP_ETH` then `V4_SWAP`) for a native-ETH buy, `0x100c`
(`V4_SWAP` then `UNWRAP_WETH`) for a native-ETH sell, with `WRAP_ETH`'s recipient being
`address(2)` — the router itself — so the swap can settle the WETH.

---

## What the UI must never say

Enforced by `test/copy.test.ts`, which scans every `.ts`, `.tsx` and `.css` file under `app/`,
`components/` and `lib/` and fails the build.

- **No "AP channel", and no creation/redemption channel with the issuer.** Bonds are a discounted
  issuance; redemption is a pro-rata claim on the vault. Neither is an arrangement with the token
  issuer, and `/risk` says there is no authorised participant at all.
- **No promised return.** No "guaranteed returns/profit/yield/income/price", no "risk-free", no
  "APY" (staking pays realised fees, not a compounding yield), no "passive income", no "assured
  returns".
- **No price forecast.** No "price target", no "will increase / rise / go up / appreciate", no "to
  the moon", no "cannot lose".
- **The premium is a number.** Signed, explicit, described as the arithmetic difference between the
  reference price and NAV per share, with the note that nothing on chain consumes it. It is never
  a target, a forecast or a reason to do anything.
- **Nothing unavailable is rendered as zero.** A degraded quote field, a missing indexer series and
  an unread parameter all render as `—` with the reason. `AmpsQuoter` zeroing a failed read is the
  whole reason this rule exists.
- **No claim the app cannot back.** The rotation comparison says it is not a survey of the market;
  the timelock panel says it cannot see the queue; the "not deployed" state says no number on the
  page is real.

---

## Known gaps

- **Deployment addresses have no home in `packages/config`.** They live in the environment because
  nothing is deployed yet. When the Phase 6 scripts run, either keep them in `.env` or add a
  deployment record to `packages/config`; `lib/deployment.ts` is the one file that changes.
- **The indexer's field shapes are the dApp's requirement, not a transcription.** `ENDPOINTS` in
  `lib/indexer/client.ts` matches `docs/indexer.md` §7 route for route; the response types in
  `lib/indexer/types.ts` are what the panels need. Every reader tolerates a missing field by
  rendering that panel as unavailable, so a name that differs costs one panel rather than the page.
  `bigint` crosses the wire as a decimal string, per that document.
- **Amount-level quotes need `V4Quoter`.** `AmpsQuoter` is a fee-and-state view by design;
  `lib/v4quoter.ts` carries the `IV4Quoter` ABI for the curve half. The two are shown side by side
  and never substituted for one another.
- **No contract-side gap blocks the UI**, but three views would remove a workaround each. None was
  added; `contracts/**` is out of scope for this change.
  1. **Per-pool POL depth is not readable from the chain.** The plan requires bid depth to be
     published per pool, and it is the counter-asset the vault currently holds as bids there. The
     vault's `ladderAt`/`ladderLength` give the amount *at placement*, not the live decomposition,
     and `LadderPositionValuer` computes valuations without exposing the token amounts. A view like
     `amountsOf(poolId) -> (uint256 amps, uint256 counter)` would let the dApp publish the number
     from the chain instead of from the indexer.
  2. **`AmpsQuoter.PoolQuote` carries no `tickSpacing`.** Building a Universal Router `PathKey`
     needs the pool's `fee`, `tickSpacing` and `hooks`, and `quoteAll()` returns only `poolId` and
     `counter`. The app therefore issues one `PoolRegistry.poolKey(poolId)` per routed pool
     (`hooks/use-pool-keys.ts`). An `int24 tickSpacing` on `PoolQuote`, or a batched
     `PoolRegistryLens.poolKeys()`, would make one `quoteAll()` sufficient to route.
  3. **There is no view for unvested bonded AMPS.** The Vault surface's circulating / inventory /
     vesting / staked split uses `Amps.balanceOf(bonds)`, which is the honest upper bound — vested
     but unclaimed AMPS is still sitting there. `AmpsBonds` knows the exact unvested total.
  Also observed and worked around rather than a gap: `peg_dev_bp` has no chain view and comes from
  the indexer, and `TimelockController` cannot enumerate its own queue, so the pending-operations
  panel says so rather than implying it is empty.
