// SPDX-License-Identifier: MIT

/**
 * The words the app is allowed to use about itself.
 *
 * Two things live here and nowhere else: the risk disclosures `/risk` renders, and the short
 * explanations each surface shows next to a number that would otherwise be read as a claim. Both
 * are data rather than JSX so a test can assert over them, and so the same sentence cannot drift
 * between the page that discloses it and the tooltip that summarises it.
 *
 * `test/copy.test.ts` scans `app/`, `components/` and `lib/` for language that promises a return,
 * calls bonds or redemption a creation/redemption channel with the issuer, or dresses the premium
 * up as anything other than a number. It fails the build rather than filing a bug.
 *
 * **No percentage that governance can move is written down here.** The redemption fee, the AMPS
 * fee and the pool base fees are read live and rendered by the component; this file names the
 * *bands*, which are hardcoded in the consuming contract and cannot move without a migration.
 */

export interface Disclosure {
  id: string
  title: string
  body: readonly string[]
}

export const RISK_DISCLOSURES: readonly Disclosure[] = [
  {
    id: 'pol-only',
    title: 'Bid depth is exactly the protocol’s own liquidity, and nothing else',
    body: [
      'Every one of the 32 pools is protocol-owned. There is no public liquidity-provider tier, and there will not be one: the vault is the only entity placing liquidity, so the bid depth under AMPS is exactly the counter-assets the protocol has earned and holds, pool by pool.',
      'That number is published per pool on the Vault page rather than hidden. If you want to know what would happen to the price if you sold, read it: it is the whole answer, and it is finite.',
      'Ask inventory is finite too, and it is exactly one thing: the genesis tranche, redistributed from the entry pools into the spokes by the rollout. It is never minted, and nothing adds to it — the AMPS side of every fee is burned rather than re-laddered, and AMPS bought back by the protocol’s own bids is burned too.',
    ],
  },
  {
    id: 'redemption-floor',
    title: 'Redemption is the only floor, and it pays in assets, not in cash',
    body: [
      'redeemProRata burns your AMPS and pays you a pro-rata slice of every asset the vault holds — every stock token, every idle balance, every position — less the redemption fee. It reads no oracle, consults no gate and cannot be paused by governance, the guardian or the timelock; the code path contains no reference to any of them.',
      'What it does not do is pay you a price. It pays you the assets. Their market value is whatever those assets are worth when you sell them, which may be less than the NAV figure that was displayed when you redeemed.',
      'The redemption fee is governed inside a band that is hardcoded in the vault, with a ceiling of five per cent. The live value is shown on the Redeem and Governance pages and is read from the vault every time; it is not written down in this interface, because it moves.',
    ],
  },
  {
    id: 'premium',
    title: 'The premium is a number, not a promise',
    body: [
      'The app shows the market price, the reference price and NAV per share side by side, and the premium is the arithmetic difference between two of them. It is disclosure. Nothing on chain consumes it, no path issues shares at NAV, and it is not a forecast of where the price goes next.',
      'A premium can be negative. The market price of AMPS is set by the pools, and the pools are a market.',
    ],
  },
  {
    id: 'no-ap',
    title: 'There is no authorised participant and no arrangement with the token issuer',
    body: [
      'There is no authorised participant. This is not an exchange-traded fund, and there is no creation or redemption arrangement with the issuer of the underlying stock tokens. Nobody stands ready to arbitrage the price back to NAV on your behalf.',
      'Bonds are a discounted issuance of AMPS against stock tokens, priced at or above NAV plus a minimum accretion. Redemption is a pro-rata claim on the vault. Neither is a channel to or from the issuer, and neither should be read as one.',
    ],
  },
  {
    id: 'censorship',
    title: 'Chain-level censorship is the one thing redemption cannot survive',
    body: [
      'The redemption path is structurally ungated, but it still has to be included in a block. Robinhood Chain is an Arbitrum Orbit chain with a sequencer. If the sequencer refuses your transaction, or the chain stops producing blocks, no property of this contract helps you.',
      'This is a real dependency on a single operator, and it is disclosed rather than argued away.',
    ],
  },
  {
    id: 'issuer-denylist',
    title: 'The stock tokens can be frozen or blocked by their issuer',
    body: [
      'Robinhood Stock Tokens are Jersey-issued debt securities. The issuer can pause transfers, can block an address, and can change a token’s share multiplier for a corporate action. The vault, the bond shell, the hook and the PoolManager are all addresses that could in principle be blocked.',
      'If a constituent is blocked or paused, redemption still pays out every other asset pro rata, and the frozen line is simply not deliverable until the issuer lifts it. Governance can retire a constituent, but retiring one never moves the assets already held.',
      'A corporate action freezes that constituent’s bond market and stops placements while it is pending. The protocol does not attempt to price through it.',
    ],
  },
  {
    id: 'fees-both-ways',
    title: 'The AMPS fee is charged in both directions, and a pass-through has one route',
    body: [
      'The protocol’s own fee is taken on every swap that touches AMPS — buying it and selling it — inside a band hardcoded in the hook. It is not a spread you can route around, and the live value for the pool you are trading is shown before you sign.',
      'A pass-through — stock to stock through AMPS — pays the two pools’ base fees on both of its hops instead of the AMPS fee, and it is available through the protocol’s own router and nowhere else. The hook fixes a hop’s fee before that hop runs, so what it checks instead is a declaration it can verify: the swap’s sender is the router address the hook holds, and the hop carries the router’s rotation flag. Any other router pays the AMPS fee on both legs.',
      'The AMPS side of every fee is burned after the creator slice is taken. The counter-asset side stays in the pool as bids. Neither is a distribution to anybody.',
    ],
  },
  {
    id: 'no-promise',
    title: 'Nothing here is a return, a yield or an offer',
    body: [
      'The bond discount is the discount currently being offered by a market with finite capacity. It is not income. A bond mints AMPS at purchase and vests it linearly; the AMPS is in total supply from the moment you buy, so NAV per share reflects the issuance immediately.',
      'The creator fee is one per cent of trade volume at genesis, decaying linearly to exactly zero thirty days later. It is immutable — there is no setter — and the remaining schedule is published on the Vault page.',
      'This interface is information about a set of public contracts. It is not investment advice, not an offer, and not a solicitation.',
    ],
  },
  {
    id: 'jurisdiction',
    title: 'Restricted jurisdictions',
    body: [
      'This interface is not available to residents of the United States, Canada, the United Kingdom or Switzerland. The underlying stock tokens are sold to non-US persons only and carry their own jurisdictional restrictions.',
      'The block is a front-end control. The contracts are permissionless and are not aware of it.',
    ],
  },
  {
    id: 'immutable',
    title: 'The contracts are immutable, and the parameters are not',
    body: [
      'The token, the vault, the hook, the bond shell, the registry, the router and the quoter are immutable bytecode. A bug in them can only be fixed by migrating to a new vault, which is itself a governed, timelocked action.',
      'The pricing and shape policies are pointer-upgradeable behind a 7-day timelock and cannot move funds. Every governed parameter is bounded by a limit hardcoded in the contract that consumes it; the Governance page shows the live value next to its band.',
    ],
  },
]

/** One-liners shown next to a live number, so it cannot be misread as a claim. */
export const NOTES = {
  premium:
    'The arithmetic difference between the reference price and NAV per share. Disclosure only; nothing on chain consumes it.',
  ampsFee:
    'The protocol’s own fee, charged on every swap that touches AMPS — buying it and selling it alike. Governed inside a band hardcoded in the hook; the live value for this pool is read from the chain.',
  poolBaseFee:
    'The pool’s own base fee: 30 bp in an entry pool, 5–10 bp in a spoke. It is the pass-through price — what one hop of a protocol-router rotation pays instead of the AMPS fee, not something added on top of it. An ordinary buy or sell never pays it.',
  rotationCredit:
    'Buying AMPS in one pool and selling it in another, in one call through the protocol’s own router, pays the two pools’ base fees instead of the AMPS fee — on both hops. The credit that proves the second hop is selling what the first hop bought lives in transient storage: it never carries across transactions, and an exact-output sell does not consume it at all, which is why the router always builds hop 2 as exact input.',
  routerOnly:
    'A hop’s fee is fixed before that hop runs, so the exemption cannot be inferred from the swap — it has to be declared by an address the hook trusts. The hook grants it to one address, held in AmpsHook.router() and movable only by a seven-day timelock, and only for hops carrying that router’s rotation flag. Any other router pays the AMPS fee on both legs.',
  noAggregator:
    'No external aggregator is configured, so no third-party route is quoted. The comparison is between the same two pools priced with and without the credit — not a claim about the whole market.',
  redemptionFloor:
    'Pro-rata in every asset the vault holds, less the redemption fee. It reads no oracle and no gate, and no governance path can block it.',
  redemptionFee:
    'Read from the vault on every load, never written down here. Governance can move it inside a band whose ceiling is hardcoded at five per cent.',
  bondMinAmpsOut:
    'The capacity clamp reduces the AMPS issued, never the collateral taken. The minimum is therefore always exactly the quoted amount — anything lower is consent to hand over the whole deposit for a capped issue.',
  unconfirmedNav:
    'NAV built on an unconfirmed answer; wait for the feed to confirm.',
  degraded:
    'The quoter never reverts: a read that fails leaves its fields at zero and raises a flag. A flagged field is shown as unavailable, never as zero.',
  polDepth: 'The pools are protocol-owned. This is the entire bid under AMPS in this pool.',
  checkpoint: 'Recomputes NAV and the reference price from live balances. Anyone may call it and it costs only gas.',
  burnSink:
    'Every compound takes the creator’s slice of each currency first — AMPS by transfer, counter assets in kind — then burns the whole AMPS-side remainder. The counter-asset side stays as bids in the pool that earned it. The high-water buyback burns what the protocol’s own bids bought back, in the same call and before anything is placed.',
  creatorSchedule:
    'One per cent of trade volume at genesis, decaying linearly to exactly zero at day 30, paid in kind out of each currency’s fees at compound(). Immutable: there is no setter, and the schedule expires by itself.',
  targetVsRealised:
    'The target weight is what the registry says the index should hold. The realised weight is what the vault holds right now, at the reference price. Rollout and market moves are why they differ.',
} as const

/**
 * The landing page's own copy, taken from the design's `Landing` screen with revision 6 applied.
 *
 * Three overrides, each recorded in `design/ledger/ledger.md` §4: the design says redemption costs
 * "1%" and this says "the redemption fee" because the value is governed and read live; the design's
 * fee split has a staker slice and a governed burn share, and revision 6 has neither; and the
 * design's fourth loop step re-ladders "the remainder" after three splits, where revision 6 takes
 * the creator slice and burns the whole AMPS side.
 */
export const LANDING_COPY = {
  lede: 'AMPS is a single token that holds tokenised shares in thirty listed companies. At any moment you can burn it and take your slice of everything the vault holds — no permission, no price feed, no pause button.',
  pillars: [
    {
      n: '01 — The vault',
      h: 'Thirty v4 positions',
      b: 'Tokenised shares in thirty listed companies, each held as a concentrated-liquidity position in its own AMPS pool. Every position, both its sides, and its fee take are published.',
    },
    {
      n: '02 — The floor',
      h: 'Redemption, always open',
      b: 'Burn AMPS and take your pro-rata slice of everything the vault holds, less the redemption fee. Nothing in that code path can be switched off.',
    },
    {
      n: '03 — The market',
      h: 'Liquidity the protocol owns',
      b: 'Above the floor, price is set by pools the protocol owns outright. The bid under AMPS is exactly what it has earned — published pool by pool.',
    },
  ],
  floorSteps: [
    {n: '01', h: 'You call redeemProRata', b: 'From any address, at any time. There is no queue and no counterparty.'},
    {n: '02', h: 'Your AMPS is burned', b: 'Supply falls, so NAV per share does not fall for anyone left holding.'},
    {
      n: '03',
      h: 'Assets are sent to you',
      b: 'A slice of every line the vault holds, in proportion to your share, less the redemption fee.',
    },
    {
      n: '04',
      h: 'Nothing can intervene',
      b: 'No oracle read, no gate check, no pause reference. Governance cannot add one without a new vault.',
    },
  ],
  feeFlow: [
    {
      n: '01',
      h: 'A swap crosses a live cell',
      b: 'Every buy and sell of AMPS routes through a protocol-owned concentrated-liquidity range. The swap fee is paid to that position — to the vault, not to an outside liquidity provider.',
    },
    {
      n: '02',
      h: 'compound() collects it',
      b: 'Anyone may call it. Fees are pulled out of the positions and split in a fixed order, with a sixty-second cooldown per pool before that pool can place again.',
    },
    {
      n: '03',
      h: 'The creator slice is taken, then the AMPS side is burned',
      b: 'The creator schedule first, taken in kind from each currency — one per cent of trade volume at genesis, decaying to exactly zero at day 30 — and then the whole AMPS side of the fee is burned. There is no staker slice and no governed burn share.',
    },
    {
      n: '04',
      h: 'The counter-asset side stays as bids',
      b: 'What was collected in the pool’s own counter asset goes back into that same pool’s grid as bid depth — never moved to another pool. The assets behind each share go up; the share count goes down.',
    },
  ],
  feeSplit: [
    {
      k: 'AMPS side',
      v: 'Burned',
      b: 'All of it, after the creator slice. Supply falls, so the assets behind every remaining share rise.',
    },
    {
      k: 'Counter-asset side',
      v: 'Placed as bids',
      b: 'Back into the grid of the pool that earned it, as bid depth. This is the part that deepens the floor you can sell into.',
    },
    {
      k: 'Stakers',
      v: 'None',
      b: 'There is no staking, no xAMPS and no reward stream. Nothing is distributed to anybody.',
    },
  ],
} as const

/**
 * The genesis auction, explained.
 *
 * Shown before the auction opens and kept there afterwards, because the property that matters most
 * — that an early bid is never disadvantaged — is the one a reader is most likely to disbelieve
 * without being told why.
 */
export const AUCTION_COPY: readonly {title: string; body: string}[] = [
  {
    title: 'One price for everybody',
    body: 'Every bid that clears pays the same final clearing price, whatever maximum it named. Bidding a high maximum does not mean paying it: it means the bid keeps clearing as the price rises, and the difference between the maximum and the final price comes back as a refund.',
  },
  {
    title: 'Bidding early costs nothing',
    body: 'Tokens are released on a fixed per-block schedule and the clearing price only rises as far as demand supports. A bid submitted in the first block and one submitted in the last settle at the same price, so there is no advantage to waiting and no penalty for going first.',
  },
  {
    title: 'Above the clearing price, you fill in full',
    body: 'A bid whose maximum is strictly above the final clearing price fills completely. A bid exactly at it is at the margin and may fill only partly, with the remainder refunded. A bid below it does not fill at all and the whole commitment comes back.',
  },
  {
    title: 'If it does not graduate, everything is refunded',
    body: 'The auction has a minimum it must raise. If it never reaches it, the auction does not graduate, no tokens are sold and every bid is refundable in full. That is a property of the contract rather than a policy anyone administers.',
  },
  {
    title: 'What the proceeds become',
    body: 'The currency raised becomes the entry pools’ bid liquidity — the first depth under AMPS, placed by the vault as a static ladder. It is not a treasury and it is not spent: it is the bid you can sell into.',
  },
  {
    title: 'What the clearing price becomes',
    body: 'The final clearing price becomes the launch reference price the vault starts from. From that point the reference is floored at NAV per share and rate-limited upward, and the market price is whatever the pools say it is.',
  },
] as const

/** The line the footer carries above everything else. */
export const NO_CUSTODY_LINE =
  'Nothing here can move funds. This interface holds no keys, takes no custody and signs nothing on your behalf: every transaction is built in your browser, simulated before it is offered, and signed by your own wallet against contracts that are public and immutable.'

export const LEGAL_FOOTER =
  'Information about a set of public, immutable contracts. Not investment advice, not an offer, not a solicitation. Not available in the United States, Canada, the United Kingdom or Switzerland.'
