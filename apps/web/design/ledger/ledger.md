<!-- SPDX-License-Identifier: MIT -->

# How the implementation deviates from the design, and why

This file is a **deviation log**. The spec is the two `.dc.html` templates next to it; everything
below is a place where `apps/web` does something the templates do not, with the reason.

Three kinds of entry:

- **Protocol** — the design's draft copy predates plan revision 6 and describes a system that is not
  the one being shipped. The documentation template says so itself, in a `NOTE` inside its own
  script: *"the draft copy below predates plan revision 6 — it still describes staking,
  burnBps/stakerBps and the sell-only fee."*
- **Truthfulness** — the design shows a figure this app has no source for. The rule for the whole
  interface is that a number is read or it is not printed, so the block keeps the design's shape and
  the figure renders as an explicit unavailable state.
- **Reach** — the design is a static mock; the app has to be operable by keyboard, by screen reader
  and at 390 pt.

---

## 1 · Staking is gone (Protocol)

The design draws a whole **Stake** screen (`data-screen-label="Stake"`), and staking appears in six
other places: a `Stake` nav item on every app screen, a `Staked as xAMPS` row in Vault's Supply
disclosure, a `Staker slice` row in the landing fee split and in the growth docs page, `stakerBps` in
the parameters table, and a `staking` docs page.

Revision 6 removes staking entirely. **None of it is implemented.** There is no `Stake` surface, no
`AmpsStaking` read, no `xAMPS` anywhere in `apps/web` — `test/docs.test.ts` and
`e2e/surfaces.spec.ts` both fail if the string reappears. The nav has eight items where the design
has seven plus Stake.

**What the Stake screen was used for instead:** its patterns are the best ones in the file for a
"deposit something, hold a position" surface, so they carry the **Auction**: the `repeat(auto-fit,
minmax(200px,1fr))` stat band over a 2 px ink rule, the `minmax(0,0.85fr) minmax(0,1.15fr)` split
with the form on the left and the position on the right, the segmented two-button control, the
amount well, the full-width `padding:18px` submit, and the `Your position` row group.

## 2 · The fee is charged both ways, and the burn is not a share (Protocol)

The design says the sell fee is charged "on every AMPS-in swap" and splits AMPS-side fees into
governed `burnBps` / `stakerBps` slices.

Revision 6: the **AMPS fee** is charged on *both* buys and sells, base pool fees are charged on top
only for a pass-through, and the AMPS side of every fee is burned in full after the creator slice —
there is no governed burn share and no staker share at all.

| Where the design says it | What the app says |
| --- | --- |
| Buy / Sell quote, `Sell fee` row | `AMPS fee — both ways`, plus a separate `Pool base fee — pass-through only` row and the hook's own hardcoded band |
| Rotate callout, "the sell fee" | "The AMPS fee is charged on every swap that touches AMPS — buying it and selling it alike." |
| Landing fee split: Creator / Staker / Burned / Re-laddered | Creator slice (live, decaying) / AMPS side **Burned** / counter-asset side **Re-laddered** / Stakers **None** |
| Growth docs `compound()` listing with staker and burn lines | The same listing with the creator slice and then the whole AMPS side burned |
| Parameters table rows `burnBps`, `stakerBps` | Absent. The Governance surface prints one sentence naming them, and it is the sentence that says they do not exist. |

`ampsFeeBps` is still exposed on chain as `AmpsHook.sellFeeBps()`, from before it was charged both
ways. `lib/fees.ts` wraps it in one accessor and both the Fees docs page and the Governance note say
so, so the rename is a single line and the reader is not misled in the meantime.

## 3 · The redemption fee is read, never written (Truthfulness)

The design writes `1.00%` in eight places — the landing floor section, the Redeem lede, the Redeem
`1% fee` mobile chip, `redeemMeta`, Vault's parameters, and three docs pages.

`redeemFeeBps` is governed inside a hardcoded band. **No number is written anywhere in `apps/web`.**
Every one of those places reads `AmpsVault.redeemFeeBps()` and renders a dash with a reason if the
read fails; the hard cap beside it is `REDEEM_FEE_BPS_MAX`, also read. The design's sentence "less a
1% fee" becomes "less the redemption fee", with the live figure printed next to it.

## 4 · Figures the design shows and no source provides (Truthfulness)

Each of these keeps the design's block and column, and renders the unavailable treatment with the
reason rather than a plausible number.

| Design figure | Why it is unavailable here |
| --- | --- |
| `Fees 30d` column, Vault holdings and both ladder tables | The indexer serves a fee **APR over a configurable window**, not a 30-day fee total. The column is replaced by one the data supports — `Rollout` in the ladder, `Cells`/`Gate` in holdings — rather than relabelled. |
| `Value` in USD per position | There is no per-constituent USD read that is not a multiplication of two other numbers. The holdings grid on the landing page shows the **realised index weight** from `PoolRegistry.currentWeightBps` against the target weight, which is what the registry actually publishes. |
| `Realised APR`, Stake screen | No staking. |
| Auction graduation target | `IContinuousClearingAuction` keeps `requiredCurrencyRaised` as an internal immutable with no getter. `isGraduated()` is the only on-chain answer, so that is what is shown and the target says why it cannot be. |
| Clearing price in USD, ETH auction leg | There is no ETH/USD feed in `@amplestocks/config`. The USDG leg converts through `chainlinkUsdgUsd`; the ETH leg is priced in ether and says so. |
| `192 live cells · 32 pools` | Both halves are read (`AmpsVault.liveCells`, `PoolRegistry.poolCount`) and either can be a dash on its own. |
| Constituent logos | The design's `mark()` fetches `assets.parqet.com/logos/...` and falls back to a ruled monogram. This app **always draws the fallback**: there is no logo source in the deployment record, a remote image would be a third-party read on every page load, and a broken `img` is a worse mark than a good monogram. `AssetMark` in `components/ledger/primitives.tsx` is the design's own fallback branch, at the design's three sizes (30 / 24 / 20 px). |

## 5 · Vault holdings columns (Protocol)

The design's holdings table is `Position / Value / Stock side / AMPS side / Cells / Fees 30d / Gate`.
The implementation keeps the seven-column shape, the mark, the section head and the eight-row default
with its "show all" toggle, and swaps four columns:

`Position / Target / Realised / Drift / Rolled out / Cells / Gate`

Publishing one number and calling it "the weight" would hide the thing that is actually interesting:
the registry sets a target, the rollout moves inventory into it on a daily cap, and the market moves
the assets in between — so target, realised and their drift are three different facts. The `Cells`
and `Gate` columns are the design's and are joined from the pool directory by symbol; a constituent
with no pool yet keeps both unavailable rather than borrowing another pool's state.

The per-pool bid depth the design lists in disclosure `03 Protocol-owned liquidity` is kept exactly
as the design lists it — one `label / hint / value` row per pool, closed by an all-pools ask-inventory
total — because the plan requires that number published rather than inferred.

## 6 · Surfaces the design does not draw

- **Auction** (`/auction`) and the `auction` docs page. Genesis Continuous Clearing Auction, Uniswap
  CCA v2.1.0 (MIT). Built from the Stake screen's patterns as described in §1. No new colour, no new
  type size, no new component.
- **Governance** (`/governance`), read-only. Built from `SurfaceHeading`, `SectionHead`, the ledger
  table and the left-rule callout. It replaces the design's `parameters` docs page table with the
  live value beside the contract's own hardcoded band, because a band that cannot be widened is the
  only thing that makes "governance can change the fee" a bounded statement.
- **Risk** (`/risk`). Built from the design's numbered-step block: a mono ordinal in a 44 px column,
  a 28 px heading, prose at a reading measure.
- **Blocked** (`/blocked`) and the terms gate. Neither is drawn; both use the same vocabulary.

## 7 · Documentation: groups, order and the `Source` block

The documentation template's `GROUPS` are `Protocol / Surfaces / Reference` and its `ORDER` is
`GROUPS.flatMap(g => g.items)`. `lib/docs/pages.ts` now matches both: the same three group labels,
and `READING_ORDER` derived the same way, so the sidebar and the pager can never disagree whatever
order the page list happens to be written in.

The rail's second block is the design's `Source` — the contract functions and module paths a page is
read from — so `DocsPage` gained a `source` field and `test/docs.test.ts` fails if a page omits it.

The design has eight docs pages; this app has eleven. `staking` is gone (§1); `auction`,
`pass-through`, `pools`, `index` and `risk` are added, and `growth`/`redemption` become
`pools`/`nav-and-redemption`.

## 8 · Reach: keyboard, screen reader, 390 pt

The design is a static mock and does not have to be operable. These are additions, not departures
from its look.

- **Every disclosure is a real button** with `aria-expanded` / `aria-controls`, and the panel it
  controls stays in the DOM under `hidden` rather than being unmounted, so browser find works and a
  screen reader can be told the relationship. The design's `<sc-if>` removes it.
- **The theme toggle is a two-option radio group**, not a switch: the two states have names, and a
  switch with a name on it is a lie about which way is "on". Arrow keys move between them.
- **Focus is visible**, in ink, on every interactive element. The design draws no focus state.
- **Tables scroll inside their own container** (`.ledger-scroll`), so a wide table on a phone moves
  sideways and the page does not.
- **At 390 pt** the stat band becomes a fixed two-up rather than collapsing to one column (the
  design's Mobile screen draws it that way), the disclosure row drops its gloss and keeps a 44 pt
  target, the app header keeps only the wordmark, `Menu` and the wallet — the theme toggle moves into
  the menu panel — and the four-tab bar the design draws takes the foot of the screen.
- **A skip link** precedes every frame.
- **`prefers-color-scheme` seeds the theme** before first paint and the choice persists per browser;
  `prefers-reduced-motion` disables the transitions.

## 9 · Copy the app adds

Every one of these says something true about the system that the design had no reason to know:

- the quoter's degraded rule — *"a flagged field is shown as unavailable, never as zero"* — which is
  why `Value` exists and why so many cells above are dashes;
- `NOTES.routerOnly`: a pass-through is only creditable through `AmpsRouter.rotate(...)`, because a
  hop's fee is fixed before that hop runs;
- `NOTES.noAggregator`: no external aggregator is configured, so the Rotate comparison is between
  the same two pools priced with and without the credit — not a claim about the whole market;
- `unconfirmedNav` as a named bond-quote refusal reason;
- the geo-block and the terms gate, neither of which the design draws.
