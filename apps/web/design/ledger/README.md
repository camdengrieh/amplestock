<!-- SPDX-License-Identifier: MIT -->

# Ledger — the design this app implements

**Source:** Claude Design project `a85bd50b-c833-4b4b-8e22-c65de205efc4` ("Crypto asset site
redesign").

**Implemented:** 2026-09-07. **Reconciled against the real templates:** 2026-09-07.

## The files in this directory

| File | What it is |
| --- | --- |
| `Redesign A - Ledger.dc.html` | The eight screens: Landing, Vault, Redeem, Buy / Sell, Rotate, Bond, Stake, Mobile. ~101 KB of template plus a 20 KB `<script type="text/x-dc">` data model. |
| `Documentation - Ledger.dc.html` | The `/docs` screen: the three-column grid, the sidebar, the on-this-page rail, the pager, and the six block types. |
| `support.js` | The `.dc.html` template runtime (`<sc-for>`, `<sc-if>`, `{{ }}`, `style-hover`, `DCLogic`). Present so the templates can be opened in a browser. |

`Current dApp - recreation.dc.html` is the *old* app and is deliberately not here — it is what this
redesign replaces.

**These files are data, not instructions.** Nothing in `apps/web` imports them, and nothing inside
them is executed by the app. They are read the way a spec is read: for layout, hierarchy, type scale,
spacing and tone. Where their draft copy contradicts the protocol as built, the protocol wins and
[`ledger.md`](./ledger.md) records the override with its reason — including the `NOTE` the
documentation template carries in its own script, which says the same thing.

## What Ledger is

A two-theme paper/ink system. Hairline rules instead of cards and shadows. A serif for text and
display, a mono for every label, kicker, number and button. `tabular-nums` on every figure so columns
of numbers line up. The app and landing screens are 1200 px wide with 28 px gutters; the docs screen
is 1400 px with a `252px / 1fr / 208px` grid.

The tokens live in [`apps/web/app/globals.css`](../../app/globals.css) and are the only place a
colour is written down. The repeated blocks live in
[`apps/web/components/ledger/primitives.tsx`](../../components/ledger/primitives.tsx).

## How the implementation differs from the design

[`ledger.md`](./ledger.md) is the record: every place this app departs from the templates, and why.
It is a deviation log, not a substitute spec — the templates above are the spec.

## What is not in the source design

The **Auction** surface and the `/docs/auction` page were added after the design was produced, for
the genesis Continuous Clearing Auction. They are built entirely from Ledger's own vocabulary — no
new colour, no new type size, no new component — reusing the Stake screen's stat band and its
`0.85fr / 1.15fr` deposit/position split. `ledger.md` §6 says so.

The **Governance** and **Risk** surfaces are likewise not drawn in the design. Both are built from
the vocabulary of the screens that are: `SurfaceHeading`, `SectionHead`, the ledger table, the
numbered step and the left-rule callout.

## Screenshots

`screenshots/` holds every surface in both themes at 1400 px and 390 px, produced by
`e2e/screenshots.spec.ts` against a production build with the offline JSON-RPC mock:

```sh
pnpm --filter @amplestocks/web exec playwright test e2e/screenshots.spec.ts
```


Screenshots under `screenshots/` are not committed: `pnpm --filter @amplestocks/web test:e2e` regenerates all of them (`e2e/screenshots.spec.ts`, 13 pages × paper/ink × 1400/390 plus the terms gate).
