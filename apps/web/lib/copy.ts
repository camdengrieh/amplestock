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
      'Ask inventory is finite too. It is the genesis tranche plus the re-laddered share of AMPS collected as sell fees, and it is never minted. AMPS bought back by the protocol’s own bids is burned, not re-placed.',
    ],
  },
  {
    id: 'redemption-floor',
    title: 'Redemption is the only floor, and it pays in assets, not in cash',
    body: [
      'redeemProRata burns your AMPS and pays you a pro-rata slice of every asset the vault holds — every stock token, every idle balance, every position — less the redemption fee. It reads no oracle, consults no gate and cannot be paused by governance, the guardian or the timelock; the code path contains no reference to any of them.',
      'What it does not do is pay you a price. It pays you the assets. Their market value is whatever those assets are worth when you sell them, which may be less than the NAV figure that was displayed when you redeemed.',
      'The redemption fee starts at 1% and is capped in the contract at 5%. Governance can move it inside that band.',
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
    id: 'no-promise',
    title: 'Nothing here is a return, a yield or an offer',
    body: [
      'Staking pays out realised sell fees that have actually been collected, streamed linearly. It is not an emission, there is no inflationary reward, and the rate shown is what was collected over a past window — not what will be collected over a future one.',
      'The bond discount is the discount currently being offered by a market with finite capacity. It is not income. A bond mints AMPS at purchase and vests it linearly; the AMPS is in total supply from the moment you buy, so NAV per share reflects the issuance immediately.',
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
      'The token, the vault, the hook, the bond shell, the staking contract, the registry and the quoter are immutable bytecode. A bug in them can only be fixed by migrating to a new vault, which is itself a governed, timelocked action.',
      'The pricing and shape policies are pointer-upgradeable behind a 7-day timelock and cannot move funds. Every governed parameter is bounded by a limit hardcoded in the contract that consumes it; the Governance page shows the live value next to its band.',
    ],
  },
]

/** One-liners shown next to a live number, so it cannot be misread as a claim. */
export const NOTES = {
  premium: 'The arithmetic difference between the reference price and NAV per share. Disclosure only; nothing on chain consumes it.',
  sellFee:
    'Charged on every AMPS-in swap in all 32 pools unless a rotation credit covers it. Governed inside a hard band of 1%–6%.',
  rotationCredit:
    'Buying AMPS in one pool and selling it in another inside the same transaction pays the buy fee on the credited part instead of the sell fee. The credit lives in transient storage: it never carries across transactions, and an exact-output sell does not consume it at all.',
  redemptionFloor:
    'Pro-rata in every asset the vault holds, less the redemption fee. It reads no oracle and no gate, and no governance path can block it.',
  bondMinAmpsOut:
    'The capacity clamp reduces the AMPS issued, never the collateral taken. The minimum is therefore always exactly the quoted amount — anything lower is consent to hand over the whole deposit for a capped issue.',
  stakingApr:
    'Computed from sell fees that have already been collected and streamed. A past-window rate, not a projection.',
  degraded:
    'The quoter never reverts: a read that fails leaves its fields at zero and raises a flag. A flagged field is shown as unavailable, never as zero.',
  polDepth: 'The pools are protocol-owned. This is the entire bid under AMPS in this pool.',
  checkpoint: 'Recomputes NAV and the reference price from live balances. Anyone may call it and it costs only gas.',
} as const

export const LEGAL_FOOTER =
  'Information about a set of public, immutable contracts. Not investment advice, not an offer, not a solicitation. Not available in the United States, Canada, the United Kingdom or Switzerland.'
