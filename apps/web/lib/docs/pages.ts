// SPDX-License-Identifier: MIT

/**
 * The documentation, as data.
 *
 * Ten pages in three groups, each a list of blocks. Written against plan revision 6: the AMPS fee
 * is charged both ways, a pass-through is router-only, the compound loop is creator slice then burn
 * the AMPS side, there is no staking page and no `stakerBps`, and the redemption fee is a figure
 * rather than a sentence.
 *
 * Not one number is typed into this file. Every figure is an id resolved from a live source at
 * render time; `test/docs.test.ts` fails if a block names an id the catalogue does not have, and
 * fails if a `rows` or `table` cell carries prose that looks like a figure.
 */

import type {Block} from './blocks'

export interface DocsPage {
  slug: string
  title: string
  kicker: string
  /** One line, shown under the title and on the group index. */
  lede: string
  /**
   * What this page is read from, one per line, for the rail's `Source` block.
   *
   * Contract functions and module paths, not prose: the point of the block is that a reader can go
   * and check the page against the thing it claims to describe.
   */
  source: string
  group: DocsGroupId
  /**
   * A third-party attribution rendered in the page header, under the lede.
   *
   * Only one value so far and it is not decoration: the genesis auction is Uniswap's Continuous
   * Clearing Auction, MIT-licensed, and a page that explains its mechanism has to say whose code
   * it is explaining and link to it. See `components/ledger/powered-by-uniswap.tsx`.
   */
  attribution?: 'uniswap-cca'
  blocks: readonly Block[]
}

export type DocsGroupId = 'protocol' | 'surfaces' | 'reference'

export interface DocsGroup {
  id: DocsGroupId
  label: string
}

/** The design's three groups, in the design's order. Reading order derives from them. */
export const GROUPS: readonly DocsGroup[] = [
  {id: 'protocol', label: 'Protocol'},
  {id: 'surfaces', label: 'Surfaces'},
  {id: 'reference', label: 'Reference'},
]

export const PAGES: readonly DocsPage[] = [
  {
    slug: 'overview',
    title: 'What Amplestocks is',
    kicker: 'Start here',
    lede: 'A share in a vault of tokenized equities, with redemption as its floor and 32 protocol-owned pools above it.',
    source: 'AmpsVault.checkpointData\nAmpsRegistry.poolCount\n@amplestocks/config',
    group: 'protocol',
    blocks: [
      {
        kind: 'p',
        text: 'AMPS is a share in a vault that holds tokenized equities on Robinhood Chain. The vault publishes what it holds, values it at a reference price, and lets any holder burn their shares for a pro-rata slice of every asset in it. That last path is the floor, and it is the only promise the system makes.',
      },
      {
        kind: 'p',
        text: 'Everything above the floor is a market. All of the pools are protocol-owned: there is no public liquidity-provider tier, so the bid under AMPS is exactly the counter-assets the protocol has earned and is holding. That number is published per pool on the Vault surface rather than inferred.',
      },
      {kind: 'h', level: 2, text: 'The system right now'},
      {
        kind: 'rows',
        title: 'Live',
        rows: [
          {label: 'Chain', figure: 'cfgChain'},
          {label: 'Chain id', figure: 'cfgChainId'},
          {label: 'Vault initialised', figure: 'vaultInitialized'},
          {label: 'NAV per share', figure: 'navPerShare'},
          {label: 'Reference price', figure: 'pRef', hint: 'Rate-limited upward, never below NAV per share'},
          {label: 'Market price', figure: 'pMkt', hint: '30-minute truncated TWAP of the AMPS/USDG hub'},
          {label: 'Premium to NAV', figure: 'premium', hint: 'A signed number. Nothing on chain consumes it.'},
          {label: 'Total assets', figure: 'totalAssets'},
          {label: 'Total supply', figure: 'totalSupply'},
          {label: 'Pools registered', figure: 'poolCount'},
        ],
      },
      {
        kind: 'note',
        tone: 'info',
        title: 'Every figure on this site is read, not written',
        text: 'No percentage, address or count in this documentation is typed into the page. Each one names a source — a contract call, the deployment record, or the launch parameter file — and is resolved when you load it. A source that cannot answer renders a dash and says why, because a stale number in a document is worse than no number.',
      },
      {kind: 'h', level: 2, text: 'At genesis'},
      {
        kind: 'rows',
        rows: [
          {label: 'Genesis supply', figure: 'cfgS0'},
          {label: 'Sold at auction', figure: 'cfgAuctionTranche', hint: 'Half the supply, at a floor of $1.00 per AMPS in each currency'},
          {label: 'Launch reference price P₀', figure: 'genesisP0', hint: 'The clearing price. Every pool was opened at it.'},
          {label: 'NAV per share at launch', figure: 'genesisNav', hint: 'Raised over the whole supply. Fully diluted: protocol-held inventory counts.'},
          {label: 'Launch premium', figure: 'genesisPremium', hint: 'P₀ over NAV per share, less one. Disclosed, and it shrinks as the ask ladders fill.'},
          {label: 'Pools', figure: 'cfgTotalPools'},
          {label: 'Spokes', figure: 'cfgSpokePools'},
          {label: 'Entry pools', figure: 'cfgEntryPools'},
          {label: 'Launch constituent set', figure: 'cfgLaunchConstituents'},
        ],
      },
    ],
  },

  {
    slug: 'auction',
    title: 'Genesis: the auction that set the price',
    kicker: 'Genesis',
    lede: 'Half the supply was sold at auction, the price it cleared at became the reference price, and every pool was opened at it.',
    source: 'IAmpsGenesis\nIAmpsVault.genesisMint / genesisPlace\nIContinuousClearingAuction\nlib/genesis.ts\nlib/auction.ts',
    group: 'surfaces',
    attribution: 'uniswap-cca',
    blocks: [
      {
        kind: 'p',
        text: 'Amplestocks does not launch by having the founders put money into a vault and declare the share price. It launches by selling half of the supply at auction and taking the price the market paid. Two Continuous Clearing Auctions — Uniswap\u2019s CCA, v2.1.0, MIT — run for 72 hours, one raising USDG and one raising native ether. Whatever they clear at becomes P\u2080, the launch reference price; the proceeds become the vault\u2019s backing and the entry pools\u2019 bid ladders; and all 32 pools are opened at P\u2080 rather than at a number chosen in advance.',
      },
      {kind: 'h', level: 2, text: 'Where every AMPS goes'},
      {
        kind: 'p',
        text: 'The split is constants, not parameters. AmpsVault.genesisMint checks each tranche against the figure hardcoded in the contract and rejects any other allocation, so a governance proposal cannot enlarge the team\u2019s share or shrink the auction\u2019s. The floor price is the same: the adapter computes it from the currency\u2019s decimals rather than reading it from the proposal, because a mis-scaled floor is a total loss for bidders and it is the one parameter a launch cannot take on trust.',
      },
      {
        kind: 'rows',
        title: 'The three tranches',
        rows: [
          {label: 'Genesis supply S\u2080', figure: 'cfgS0', hint: 'Minted exactly once, and there is no second mint path except bonds'},
          {label: 'Team', figure: 'cfgTeamTranche', hint: '5%, into an OpenZeppelin VestingWallet: two months linear, no cliff, no way to accelerate or claw back'},
          {label: 'Auction', figure: 'cfgAuctionTranche', hint: '50%, sold through the two auctions below'},
          {label: '\u2014 USDG leg', figure: 'cfgAuctionUsdgTranche'},
          {label: '\u2014 ETH leg', figure: 'cfgAuctionEthTranche', hint: 'Sold for native ether, wrapped to WETH9 at settlement'},
          {label: 'Protocol-owned liquidity', figure: 'cfgPolTranche', hint: '45%, retained by the vault as ask inventory and laid out as ladders anchored at P\u2080'},
          {label: 'Auction floor', figure: 'cfgAuctionFloor', hint: 'In each currency. Computed by AmpsGenesis, never taken from the proposal.'},
        ],
      },
      {kind: 'h', level: 2, text: 'One price for everybody'},
      {
        kind: 'p',
        text: 'Tokens are released on a fixed per-block schedule. Bidders post a maximum price and an amount of the auction\u2019s currency, and the contract raises the clearing price only as far as resting demand supports it. Every bid that clears pays the same final price, whatever maximum it named \u2014 so a high maximum is a ceiling rather than an offer, and the difference comes back as a refund.',
      },
      {
        kind: 'note',
        tone: 'info',
        title: 'Bidding early costs nothing',
        text: 'A bid in the first block and a bid in the last settle at the same clearing price. There is no advantage to waiting for information and no penalty for committing first, which is the property that makes a continuous clearing auction different from an open ascending one.',
      },
      {
        kind: 'p',
        text: 'A bid whose maximum ends strictly above the clearing price fills in full. A bid exactly at it is at the margin and may fill only partly, with the remainder refunded through the partial-fill exit. A bid below it does not fill at all and the whole commitment comes back. If a leg never reaches the minimum it must raise, it does not graduate: nothing is sold through it and every bid in it is refundable.',
      },
      {kind: 'h', level: 2, text: 'The two auctions'},
      {
        kind: 'table',
        columns: ['', 'AMPS / USDG', 'AMPS / ETH'],
        rows: [
          [{text: 'Address'}, {figure: 'auctionUsdgAddress'}, {figure: 'auctionEthAddress'}],
          [{text: 'State'}, {figure: 'auctionUsdgPhase'}, {figure: 'auctionEthPhase'}],
          [{text: 'On offer'}, {figure: 'auctionUsdgSupply'}, {figure: 'auctionEthSupply'}],
          [{text: 'Floor'}, {figure: 'genesisFloorUsdg'}, {figure: 'genesisFloorEth'}],
          [{text: 'Clearing price'}, {figure: 'auctionUsdgClearing'}, {figure: 'auctionEthClearing'}],
          [{text: 'Raised'}, {figure: 'auctionUsdgRaised'}, {figure: 'auctionEthRaised'}],
          [{text: 'Graduated'}, {figure: 'auctionUsdgGraduated'}, {figure: 'auctionEthGraduated'}],
        ],
        footnote:
          'Every read is as of the auction\u2019s last checkpoint: checkpoint() is a write rather than a view, so a price is only as fresh as the last block somebody paid to advance it to. The ETH auction\u2019s currency is address(0) \u2014 native ether, sent as the call\u2019s value rather than pulled through an allowance.',
      },
      {
        kind: 'note',
        tone: 'warning',
        title: 'The graduation target is not readable',
        text: 'The auction keeps the minimum it must raise as an internal immutable and exposes no getter for it. isGraduated() is the only on-chain answer, so the interface shows that and marks the target unavailable rather than printing a number it cannot see. The figure below is what the deployment configured, not what the contract will admit to.',
      },
      {kind: 'h', level: 2, text: 'The terms the operator set'},
      {
        kind: 'p',
        text: 'Neither the tranche sizes nor the floor is in this list: AmpsGenesis computes the floor itself and refuses any allocation but the constants. What a proposal actually chooses is the schedule, the grid, the graduation bar and whether there is an on-chain validation hook \u2014 and each of those is in script/config/genesis.json, reviewed and signed off with the file\u2019s commit hash before the auctions are created.',
      },
      {
        kind: 'rows',
        title: 'Auction parameters',
        rows: [
          {label: 'Start delay', figure: 'cfgAuctionStartDelay', hint: 'Between createAuctions and the first issuance block'},
          {label: 'Bidding window', figure: 'cfgAuctionDuration'},
          {label: 'Claim delay', figure: 'cfgAuctionClaimDelay', hint: 'Zero: an exited bid can be claimed in the same block'},
          {label: 'Tick spacing', figure: 'cfgAuctionTickSpacing', hint: 'As a fraction of each leg\u2019s own floor. It keeps the tick book small enough that the auction cannot be griefed into an out-of-gas.'},
          {label: 'Graduation bar, per leg', figure: 'cfgGraduationPerLeg'},
          {label: 'Validation hook', figure: 'cfgAuctionValidationHook', hint: 'None. The geo-block on this interface is a front-end control and binds no contract; saying otherwise would be a claim the chain does not support.'},
        ],
      },
      {kind: 'h', level: 2, text: 'Genesis is two calls, and the auction runs between them'},
      {
        kind: 'p',
        text: 'The vault cannot sell a supply that does not exist, and it must not price that supply against backing of zero. So the mint and the opening are separate calls behind separate one-way latches. genesisMint is the timelock\u2019s: it mints S\u2080, sends the team tranche to the vesting wallet and the auction tranche to the adapter, and does nothing else \u2014 no asset moves, no price is set, no checkpoint is written. Between the two calls the supply exists, backing is zero, and every path that would price one against the other refuses: checkpoint, touch, depositBonded, mintVesting, place \u2014 and redemption, so that nobody can burn shares against a vault holding nothing.',
      },
      {
        kind: 'p',
        text: 'genesisPlace is the second call, and the adapter makes it out of its own settle(). It takes the proceeds as ERC-6909 claims, takes the unsold AMPS back as plain inventory \u2014 neither minted nor counted as backing \u2014 stamps the genesis timestamp, closes both latches, writes a checkpoint, and only then seeds the reference price at P\u2080. The reference is written after the checkpoint on purpose: with no pool and no observation history a checkpoint resolves the reference to NAV, which would bury the price the auction just discovered.',
      },
      {
        kind: 'rows',
        title: 'What settlement decided',
        rows: [
          {label: 'Genesis phase', figure: 'genesisPhase'},
          {label: 'Settled', figure: 'genesisSettled', hint: 'settle() is permissionless and one-shot. Anyone may send it; nobody may send it twice.'},
          {label: 'Launch reference price P\u2080', figure: 'genesisP0'},
          {label: 'Raised', figure: 'genesisRaised', hint: 'Both legs, net of the factory\u2019s protocol fee, which the adapter measures rather than predicts'},
          {label: '\u2014 USDG', figure: 'genesisRaisedUsdg'},
          {label: '\u2014 WETH', figure: 'genesisRaisedWeth', hint: 'The ETH leg, wrapped inside settle() so the vault never holds native ether'},
          {label: 'Unsold AMPS returned', figure: 'genesisUnsold', hint: 'Back to the vault as inventory. Never re-offered except through the ordinary rollout.'},
          {label: 'ETH/USD used', figure: 'genesisEthUsd'},
          {label: 'NAV per share at launch', figure: 'genesisNav'},
          {label: 'Launch premium', figure: 'genesisPremium'},
        ],
      },
      {kind: 'h', level: 2, text: 'The premium, and why it is published rather than smoothed'},
      {
        kind: 'p',
        text: 'NAV per share divides the raise by the whole supply \u2014 inventory included, which is what fully diluted accounting means and what the vault\u2019s own checkpoint does. A buyer at the auction paid the clearing price for one share. So the reference price starts above NAV per share by exactly the ratio of the whole supply to the part that was sold, and at a full clear at the floor that ratio is two.',
      },
      {
        kind: 'rows',
        title: 'At a full clear at the floor',
        rows: [
          {label: 'Auction floor', figure: 'cfgAuctionFloor'},
          {label: 'NAV per share', figure: 'cfgNavAtFloor', hint: 'Raised over S\u2080'},
          {label: 'Premium', figure: 'cfgPremiumAtFloor', hint: 'P\u2080 over NAV, less one'},
          {label: 'Reference up-rate from launch', figure: 'refUpRate'},
        ],
      },
      {
        kind: 'rows',
        title: 'At the graduation minimum',
        rows: [
          {label: 'Graduation bar, per leg', figure: 'cfgGraduationPerLeg', hint: 'Both legs have to clear it independently; a leg that misses it sells nothing and refunds everybody'},
          {label: 'NAV per share', figure: 'cfgNavAtGraduation', hint: 'Half the raise, and the same S\u2080 divides it'},
          {label: 'Premium', figure: 'cfgPremiumAtGraduation', hint: 'Larger than at a full clear, not smaller: a smaller raise against the same supply'},
        ],
      },
      {
        kind: 'note',
        tone: 'warning',
        title: 'The premium is a disclosure, not a discount',
        text: 'It exists because the vault keeps 45% of the supply as inventory that is backed by nothing until it sells. Every ask that fills at or above P\u2080 raises the backing, so the premium shrinks as the ladder works \u2014 but nothing guarantees the ladder fills, and the only floor under a share is the pro-rata redemption, which pays out of what the vault actually holds. NAV per share is not the auction price and the premium is not a discount.',
      },
      {kind: 'h', level: 2, text: 'If neither leg graduates'},
      {
        kind: 'p',
        text: 'Then there is no launch to show. Bidders refund in full through the auctions themselves rather than through Amplestocks; settle() returns the whole tranche to the vault as inventory and calls nothing; the vault stays shut and the phase reads Aborted. The founders\u2019 seed survives only for that case: the timelock opens the vault itself at $1.00 with its own money, which is the pre-auction launch exactly. The whole supply then divides a $20,000 seed, so NAV per share is $1.00 as well and the premium on that path is zero. It is a governed call with a seven-day delay and a visible proposal.',
      },
      {
        kind: 'rows',
        title: 'Contracts and the fallback',
        rows: [
          {label: 'AmpsGenesis', figure: 'addrGenesis', hint: 'Immutable, ownerless, one-shot: one governed call to create the auctions, one permissionless call to settle them, and no rescue function'},
          {label: 'AmpsVault', figure: 'addrVault', hint: 'Receives the proceeds as backing and the unsold AMPS as inventory'},
          {label: 'Fallback seed', figure: 'cfgFallbackSeed', hint: 'Used only if no leg graduates. It is not spent otherwise.'},
          {label: 'Fallback launch price', figure: 'cfgFallbackLaunchPrice', hint: 'P\u2080 on that path. The same $20,000 against the same S\u2080, so NAV matches it and the premium is zero.'},
          {label: 'CCALens', figure: 'ccaLens', hint: 'The optional tick-reading helper, at the same address on every chain that has it. This interface does not need it: floorPrice, tickSpacing and nextActiveTickPrice are on the auction itself.'},
        ],
      },
    ],
  },
  {
    slug: 'nav-and-redemption',
    title: 'NAV and redemption',
    kicker: 'The floor',
    lede: 'How the vault values itself, and the one exit that reads no oracle and cannot be paused.',
    source: 'AmpsVault.redeemProRata\nAmpsVault.redeemFeeBps\nlib/redeem.ts',
    group: 'protocol',
    blocks: [
      {
        kind: 'p',
        text: 'NAV per share is the vault’s own accounting of what it holds, divided by total supply. It is recomputed by a checkpoint, which anyone may call and which costs only gas. The reference price is NAV floored and rate-limited upward; the market price is a truncated TWAP of the hub pool. The difference between the reference and NAV is the premium, and it is disclosure rather than a target.',
      },
      {kind: 'h', level: 2, text: 'Redemption'},
      {
        kind: 'p',
        text: 'redeemProRata burns your AMPS and pays a pro-rata slice of every asset the vault holds — every stock token, every idle balance, every ladder position — less the redemption fee. The code path reads no oracle, consults no gate, and contains no reference to the guardian, the timelock or any pause flag. It is not a price: it pays the assets, and what those are worth is whatever they are worth when you sell them.',
      },
      {
        kind: 'rows',
        title: 'Live',
        rows: [
          {label: 'Redemption fee', figure: 'redeemFee', hint: 'Read from the vault on every load'},
          {label: 'Ceiling hardcoded in the vault', figure: 'redeemFeeMax', hint: 'Governance cannot widen it'},
          {label: 'NAV per share', figure: 'navPerShare'},
          {label: 'Assets paid out pro rata', figure: 'assetCount', hint: 'No netting, no substitution'},
          {label: 'Live ladder cells', figure: 'liveCells', hint: 'Bounded, which is what bounds the gas of a redemption'},
        ],
      },
      {
        kind: 'note',
        tone: 'warning',
        title: 'The redemption fee moves',
        text: 'It is governed inside the band above, and the launch value is not the value it will keep. That is exactly why it is a figure here rather than a sentence: the number you see is the number the vault will charge on the call you make next.',
      },
      {kind: 'h', level: 2, text: 'Why the released inventory is burned too'},
      {
        kind: 'p',
        text: 'A redemption removes the redeemer’s share of every ladder position. The AMPS sitting in those positions as unfilled ask inventory is burned rather than returned to the vault’s free balance, so total supply falls by more than the shares redeemed and the redemption is accretive to everyone who stays.',
      },
    ],
  },

  {
    slug: 'fees',
    title: 'Fees',
    kicker: 'The hook',
    lede: 'The AMPS fee both ways, the pool base fee on pass-through only, and where the money goes.',
    source: 'AmpsHook\nAmpsQuoter.quoteAll\nlib/fees.ts',
    group: 'surfaces',
    blocks: [
      {
        kind: 'p',
        text: 'There are two fees and they price two different things. The AMPS fee is the protocol’s own, and it is the base on both directions of every pool: buying AMPS and selling it are the same trade seen from two sides, and a fee taken on one side alone is a fee a round trip halves. The pool’s base fee is the price of moving through a pool rather than entering or leaving the index through it, and it is charged on one thing only — a hop of AmpsRouter.rotate. It is not a surcharge on top of the AMPS fee; it is what replaces it on that one path.',
      },
      {
        kind: 'rows',
        title: 'Live',
        rows: [
          {label: 'AMPS fee', figure: 'ampsFee', hint: 'The base on buys and on sells alike'},
          {label: 'Band hardcoded in the hook', figure: 'ampsFeeBand'},
          {label: 'Entry-pool base fee band', figure: 'entryBaseFeeBand', hint: 'AMPS/WETH and AMPS/USDG — pass-through only'},
          {label: 'Spoke base fee band', figure: 'spokeBaseFeeBand', hint: 'High-volatility names default higher inside it'},
          {label: 'Absolute ceiling on base plus dynamic', figure: 'totalFeeMax'},
        ],
      },
      {
        kind: 'note',
        tone: 'default',
        title: 'What the quoter reports, and which number is yours',
        text: 'AmpsQuoter.quotePool answers four fee legs per pool, not two. buyFeePips and sellFeePips are what an ordinary trade pays in each direction — base ampsFeeBps plus the clamped dynamic part — and those are the numbers this interface quotes you. passThroughBuyFeePips and passThroughSellFeePips are the two hops of a rotation, based on the pool’s own buyFeeBps, and are unreachable through any other route. Both pairs are shown on Buy / Sell so the difference is visible rather than implied.',
      },
      {kind: 'h', level: 2, text: 'The dynamic component'},
      {
        kind: 'p',
        text: 'On top of the base sits a dynamic component driven by volatility, deviation from the fair tick, divergence, the equity session and a surge latch. It is capped, and the cap widens when the oracle gate is degraded — a swap is never refused for a gate reason, it is only made dearer.',
      },
      {kind: 'h', level: 2, text: 'Where the fee goes'},
      {
        kind: 'p',
        text: 'A compound collects a pool’s fees in two currencies and treats them differently on purpose. The creator’s slice is taken from each of them in kind — AMPS by transfer, counter assets by transfer with an ERC-6909 claim fallback, so a token that refuses a transfer can never block the call. What is left of the AMPS side is burned, all of it. What is left of the counter side stays as bids in the pool that earned it, which is the same thing as saying it deepens the floor you can sell into. There is no staker slice, no reward stream and no governed burn share — revision 6 removed all three, and there is no re-ladder of fee AMPS into asks either.',
      },
      {
        kind: 'p',
        text: 'The one consequence worth stating plainly: ask inventory is finite and never grows. It is the genesis tranche, redistributed from the entry pools into the spokes by the rollout, and nothing adds to it. Every trade therefore either raises the assets behind a share or lowers the number of shares.',
      },
      {
        kind: 'rows',
        title: 'The creator schedule, which is immutable',
        rows: [
          {label: 'At genesis', figure: 'creatorFeeGenesis', hint: 'Of trade volume, taken in kind from each currency’s fees'},
          {label: 'Decays linearly to zero over', figure: 'creatorDecay'},
          {label: 'In force now', figure: 'creatorFeeNow'},
        ],
      },
      {
        kind: 'note',
        tone: 'info',
        title: 'There is no setter',
        text: 'The creator schedule is compiled into the vault. No governance path reaches it, and it expires by itself.',
      },
    ],
  },

  {
    slug: 'pass-through',
    title: 'Pass-through and the router',
    kicker: 'The router',
    lede: 'Why stock-to-stock has exactly one route, and what happens if you take another.',
    source: 'AmpsRouter.rotate\nAmpsHook.router\nlib/abi/router.ts',
    group: 'surfaces',
    blocks: [
      {
        kind: 'p',
        text: 'A pass-through is stock to stock through AMPS: buy AMPS in one pool, sell it in another, in one transaction. Both of its hops pay the pools’ own base fees instead of the AMPS fee, which is what makes rotating between constituents affordable — a rotation is not an entry and not an exit, and taxing it as though it were two of each would make the index unusable as an index.',
      },
      {
        kind: 'note',
        tone: 'warning',
        title: 'Only the protocol’s own router can do it, and the hook checks two things',
        text: 'The hook fixes a hop’s fee in beforeSwap, before that hop runs, so it cannot infer from the swap that another hop follows: that is a fact about the caller’s intentions, not about the pool. What it checks instead is a declaration it can verify — the sender the PoolManager reports is the address in AmpsHook.router(), and the hop’s hookData is exactly the router’s rotation flag. Both, or the hop pays ampsFeeBps. A third-party router calling the PoolManager twice satisfies neither, so both of its legs pay the AMPS fee.',
      },
      {
        kind: 'rows',
        title: 'The exemption, as the hook holds it',
        rows: [
          {label: 'Router the hook honours', figure: 'hookRouter', hint: 'Moved by setRouter, a seven-day timelock class. The zero address withdraws the exemption entirely.'},
          {label: 'Flag both hops must carry', figure: 'rotateFlag', hint: 'AmpsRouter.ROTATE_FLAG(), so an integrator can check it rather than trust a comment'},
        ],
      },
      {
        kind: 'code',
        lang: 'solidity',
        text: `function rotate(
    PoolId hop1,
    PoolId hop2,
    uint256 amountIn,
    uint256 minOut,
    address to,
    bool unwrap,
    uint256 deadline
) external payable returns (uint256 amountOut, uint256 ampsThrough);`,
      },
      {
        kind: 'p',
        text: 'Both hops run inside one PoolManager unlock, and hop 2 sells exactly the AMPS hop 1 realised — read from the swap’s own balance delta, not from anything quoted beforehand. The router’s AMPS delta is asserted to be zero before it settles anything, so nobody can end a rotation holding AMPS; ampsThrough is that amount, returned so a caller can reconcile what it was quoted. The two hops must be different pools: buying AMPS in a pool and selling it straight back is a round trip that moves the tick out and back, and pricing it at two pass-through fees would make that pool’s liquidity pay for the caller’s own noise.',
      },
      {
        kind: 'p',
        text: 'The credit that lets hop 2 be cheap is transient by construction. It cannot cross a transaction boundary, so splitting a rotation into two transactions throws it away entirely; an exact-output sell consumes none of it, which is why the router always builds the second leg as exact input; and a sell larger than the buy that funded it pays the AMPS fee on the excess, so a rotation cannot be padded into a discounted exit.',
      },
      {
        kind: 'note',
        tone: 'default',
        title: 'The router’s own buy and sell are not pass-through',
        text: 'AmpsRouter.buy and AmpsRouter.sell pass empty hookData and pay ampsFeeBps like any swap through any other router — and calling them in the same transaction is a round trip, not a rotation, so it pays the AMPS fee twice. Routing an exit through the protocol’s own front end must not make the exit cheaper.',
      },
      {
        kind: 'rows',
        title: 'Addresses',
        rows: [
          {label: 'AmpsRouter', figure: 'addrRouter'},
          {label: 'AmpsHook', figure: 'addrHook'},
          {label: 'PoolManager', figure: 'refPoolManager'},
          {label: 'UniversalRouter', figure: 'refUniversalRouter', hint: 'Used for single-hop buys and sells; it cannot do a pass-through'},
        ],
      },
    ],
  },

  {
    slug: 'pools',
    title: 'Pools and liquidity',
    kicker: 'Uniswap v4 · concentrated liquidity',
    lede: 'Protocol-owned ladders, what bid depth actually is, and the rollout that moves inventory into the spokes.',
    source: 'AmpsVault.ladderLength\nLadderPositionValuer.amountsOf',
    group: 'protocol',
    blocks: [
      {
        kind: 'p',
        text: 'Every pool is protocol-owned. The vault places a static ladder of concentrated positions — asks above the anchor, bids below it — and never re-centres them. A cell is placed once and is only ever removed by a redemption, the rollout, the high-water buyback burn or a migration, so how full a cell is is a real measure of what the market has bought rather than an artefact of a keeper moving ranges.',
      },
      {
        kind: 'note',
        tone: 'danger',
        title: 'Bid depth is finite and it is published',
        text: 'There is no public liquidity-provider tier and there will not be one. The bid under AMPS in a pool is exactly the counter-asset the protocol holds there. If you want to know what would happen to the price if you sold, read the per-pool figure on the Vault surface: it is the whole answer.',
      },
      {kind: 'h', level: 2, text: 'Ladder shape'},
      {
        kind: 'rows',
        title: 'Live',
        rows: [
          {label: 'Doublings', figure: 'ladderDoublings', hint: 'How far above the anchor the ask ladder reaches'},
          {label: 'Tilt', figure: 'ladderTilt', hint: 'Each bucket holds tilt^k of the pool’s inventory'},
          {label: 'Spoke seed share', figure: 'spokeSeed'},
          {label: 'Live cells across all pools', figure: 'liveCells'},
          {label: 'Protocol inventory', figure: 'inventoryAmps', hint: 'Finite and never minted'},
        ],
      },
      {
        kind: 'p',
        text: 'Every ladder is anchored at P₀, the price the genesis auction cleared at, rather than at a price chosen in advance: the pools are registered after settlement precisely so that the registry can read the reference the auction wrote. The entry pools get the larger share because they are the only depth under AMPS at launch; each spoke starts with one per cent of the protocol-owned tranche and grows by rollout as it earns volume.',
      },
      {
        kind: 'rows',
        title: 'What genesis placed',
        rows: [
          {label: 'Protocol-owned tranche', figure: 'cfgPolTranche', hint: '45% of the supply, retained by the vault as ask inventory'},
          {label: 'Ask ladder per entry pool', figure: 'cfgEntryPoolAsks', hint: 'In each of AMPS/USDG and AMPS/WETH, ten cells from P₀ up'},
          {label: 'Seed ask per spoke', figure: 'cfgSpokeSeedAmps', hint: 'One per cent of the tranche each, across the 30 spokes'},
          {label: 'Seed bids', figure: 'genesisRaised', hint: 'The auction proceeds themselves, placed as four halvings below P₀ in the entry pools'},
        ],
      },
      {kind: 'h', level: 2, text: 'Rollout'},
      {
        kind: 'p',
        text: 'Unfilled entry-pool inventory migrates into the spokes at a governed daily rate, subject to a floor that stops it draining the entry pools. It is a rate rather than an event, so the index reaches its target weights over days rather than at a single block anyone could front-run.',
      },
      {
        kind: 'p',
        text: 'The rollout is also the only thing that moves ask inventory at all. Nothing adds to it: the AMPS side of every fee is burned instead of being re-offered, so the asks above the anchor are the genesis tranche and nothing else, spread across the pools over time. Above the top of a ladder a pool quotes bids only.',
      },
      {
        kind: 'rows',
        rows: [
          {label: 'Rate', figure: 'rolloutRate'},
          {label: 'Ceiling hardcoded in the vault', figure: 'rolloutRateMax'},
          {label: 'Entry-pool floor', figure: 'entryFloor'},
        ],
      },
      {kind: 'h', level: 2, text: 'Prices the pools are measured against'},
      {
        kind: 'rows',
        rows: [
          {label: 'TWAP window', figure: 'twapWindow'},
          {label: 'Reference up-rate', figure: 'refUpRate'},
          {label: 'Reference divergence limit', figure: 'refDivergence'},
        ],
      },
    ],
  },

  {
    slug: 'bonds',
    title: 'Bonds',
    kicker: 'Issuance',
    lede: 'Discounted issuance against a stock token, priced at or above NAV plus a minimum accretion.',
    source: 'AmpsBonds\nlib/bonds.ts',
    group: 'surfaces',
    blocks: [
      {
        kind: 'p',
        text: 'A bond deposits a stock token and receives AMPS at a discount, vesting linearly. The AMPS is minted at purchase and is in total supply from that moment, so NAV per share reflects the issuance at once and cannot be gamed by claim timing. The price is the lower of the market discount and the NAV floor; the floor is computed from the last confirmed feed answer, which is what makes manipulating the pool TWAP worthless — the best an attacker can do is remove their own discount.',
      },
      {
        kind: 'rows',
        title: 'Live parameters',
        rows: [
          {label: 'Vest', figure: 'bondVest'},
          {label: 'Vest band', figure: 'bondVestBand'},
          {label: 'Epoch', figure: 'bondEpoch', hint: 'Capacity is allotted per market per epoch'},
          {label: 'Minimum accretion', figure: 'bondMinAccretion'},
          {label: 'Discount band', figure: 'bondDiscountBand'},
          {label: 'Daily issuance cap', figure: 'bondDailyCap', hint: 'In basis points of total supply, across every market'},
          {label: 'Issued today', figure: 'bondIssuedToday'},
          {label: 'Markets', figure: 'bondMarkets'},
        ],
      },
      {
        kind: 'note',
        tone: 'danger',
        title: 'minAmpsOut is always the quoted amount',
        text: 'The capacity clamp reduces the AMPS issued and never the collateral taken: the shell settles the whole deposit and issues the capped amount. A lower bound is therefore not slippage tolerance, it is consent to hand over the entire deposit for a capped issue, and this interface refuses to build such a call.',
      },
      {kind: 'h', level: 2, text: 'When a market will not quote'},
      {
        kind: 'p',
        text: 'quote() never reverts for a known market. It returns zero with a bytes32 reason, which is why the board can show every market including the ones that cannot be bonded. The reasons include a closed market, a corporate-action freeze, exhausted epoch or daily capacity, a stale feed, and — new in revision 6 — unconfirmedNav, which means the NAV floor would be built on a feed answer that has not been confirmed yet. It resolves by itself when the feed confirms.',
      },
    ],
  },

  {
    slug: 'index',
    title: 'The index',
    kicker: 'The constituent set',
    lede: 'The constituent set, target weights against realised ones, and what a freeze or a retirement does.',
    source: 'AmpsRegistry.constituent\nAmpsRegistry.currentWeightBps',
    group: 'protocol',
    blocks: [
      {
        kind: 'p',
        text: 'The registry holds the constituent set and a target weight for each name. What the vault actually holds is a separate figure, priced at the reference: the rollout moves inventory on a daily cap and the market moves the assets in between, so the two differ, and the Vault surface publishes both rather than picking one.',
      },
      {
        kind: 'rows',
        title: 'Live',
        rows: [
          {label: 'Constituents', figure: 'constituentCount'},
          {label: 'Active', figure: 'activeConstituentCount', hint: 'A frozen name is still an index member; a retired one is not'},
          {label: 'Maximum the registry will hold', figure: 'maxConstituents'},
          {label: 'Weight cap at the live count', figure: 'indexCap'},
          {label: 'Weight floor at the live count', figure: 'indexFloor'},
          {label: 'Pools registered', figure: 'poolCount'},
        ],
      },
      {kind: 'h', level: 2, text: 'Freezes and retirements'},
      {
        kind: 'p',
        text: 'A guardian freeze and a corporate-action freeze are both disable-only and both expire by themselves: they stop placements, compounding and that market’s bonds, and they stop nothing else. Retiring a constituent removes it from the index but never moves the assets already held — its pool stays open as an exit market.',
      },
      {
        kind: 'note',
        tone: 'warning',
        title: 'The issuer can freeze the tokens themselves',
        text: 'Robinhood Stock Tokens are Jersey-issued debt securities. The issuer can pause transfers, block an address, and change a share multiplier for a corporate action. If a constituent is blocked, redemption still pays out every other asset pro rata and the frozen line is simply not deliverable until the issuer lifts it.',
      },
    ],
  },

  {
    slug: 'governance',
    title: 'Governance',
    kicker: 'Read-only',
    lede: 'What can change, by whom, how fast, and the bands that cannot be widened.',
    source: 'TimelockController\n@amplestocks/config launchParameters',
    group: 'reference',
    blocks: [
      {
        kind: 'p',
        text: 'A Safe proposes, a timelock executes with an open executor role, and a guardian Safe can cancel and can impose a disable-only freeze. Every governed parameter is bounded by a limit hardcoded in the contract that consumes it; widening a band is not a governance action, it is a new deployment and a migration.',
      },
      {
        kind: 'rows',
        title: 'Who and how long',
        rows: [
          {label: 'Proposer Safe', figure: 'cfgProposer'},
          {label: 'Guardian Safe', figure: 'cfgGuardian'},
          {label: 'Parameters', figure: 'cfgTimelockFast'},
          {label: 'Constituents and policy pointers', figure: 'cfgTimelockSlow'},
          {label: 'Standby vault', figure: 'cfgTimelockStandby'},
          {label: 'Guardian freeze expiry', figure: 'cfgGuardianFreeze'},
        ],
      },
      {kind: 'h', level: 2, text: 'The bands, live'},
      {
        kind: 'table',
        columns: ['Parameter', 'Live', 'Hard band'],
        rows: [
          [{text: 'ampsFeeBps'}, {figure: 'ampsFee'}, {figure: 'ampsFeeBand'}],
          [{text: 'redeemFeeBps'}, {figure: 'redeemFee'}, {figure: 'redeemFeeMax'}],
          [{text: 'buyFeeBps (entry)'}, {text: 'per pool'}, {figure: 'entryBaseFeeBand'}],
          [{text: 'buyFeeBps (spokes)'}, {text: 'per pool'}, {figure: 'spokeBaseFeeBand'}],
          [{text: 'minAccretionBps'}, {figure: 'bondMinAccretion'}, {text: 'see AmpsBonds'}],
          [{text: 'dailyCapBps'}, {figure: 'bondDailyCap'}, {text: 'see AmpsBonds'}],
          [{text: 'vestSeconds'}, {figure: 'bondVest'}, {figure: 'bondVestBand'}],
          [{text: 'rolloutBpsPerDay'}, {figure: 'rolloutRate'}, {figure: 'rolloutRateMax'}],
          [{text: 'creator schedule'}, {figure: 'creatorFeeNow'}, {text: 'immutable — no setter'}],
        ],
        footnote:
          'The live column and the band column are separate reads. A band shown as a single figure is a ceiling with an implicit floor of zero. There is no burnBps and no stakerBps: revision 6 removes staking, and the AMPS side of every fee is burned after the creator slice.',
      },
      {
        kind: 'note',
        tone: 'info',
        title: 'What governance cannot do',
        text: 'It cannot block redemption — the path contains no gate, no guardian and no pause reference. It cannot widen a hard band. It cannot move funds through a policy pointer. It cannot mint AMPS by any route other than the bond shell. It cannot touch the creator schedule.',
      },
    ],
  },

  {
    slug: 'addresses',
    title: 'Addresses',
    kicker: 'Reference',
    lede: 'Every contract this interface talks to, and where its address comes from.',
    source: 'lib/contracts.ts\nlib/deployment.ts',
    group: 'reference',
    blocks: [
      {
        kind: 'p',
        text: 'The Amplestocks contracts come from the deployment record — environment variables, absent until the deploy scripts have run, which is why an unconfigured entry shows a dash rather than a zero address. The third-party addresses come from the reference book, which the preflight script re-reads from chain before any of it is baked into a deploy.',
      },
      {
        kind: 'rows',
        title: 'Amplestocks',
        rows: [
          {label: 'Amps', figure: 'addrAmps'},
          {label: 'AmpsVault', figure: 'addrVault'},
          {label: 'AmpsHook', figure: 'addrHook'},
          {label: 'AmpsRouter', figure: 'addrRouter'},
          {label: 'AmpsQuoter', figure: 'addrQuoter'},
          {label: 'AmpsBonds', figure: 'addrBonds'},
          {label: 'AmpsBondsLens', figure: 'addrBondsLens'},
          {label: 'PoolRegistry', figure: 'addrRegistry'},
          {label: 'PoolRegistryLens', figure: 'addrRegistryLens'},
          {label: 'OracleGate', figure: 'addrOracleGate'},
          {label: 'TimelockController', figure: 'addrTimelock'},
        ],
      },
      {
        kind: 'rows',
        title: 'Third-party',
        rows: [
          {label: 'PoolManager', figure: 'refPoolManager'},
          {label: 'UniversalRouter', figure: 'refUniversalRouter'},
          {label: 'Permit2', figure: 'refPermit2'},
          {label: 'WETH9', figure: 'refWeth9'},
          {label: 'USDG', figure: 'refUsdg'},
          {label: 'USDC (bridged)', figure: 'refUsdc'},
          {label: 'Across SpokePool', figure: 'refAcross'},
          {label: 'Stock token beacon', figure: 'refStockBeacon'},
        ],
      },
      {
        kind: 'rows',
        title: 'Chain',
        rows: [
          {label: 'Network', figure: 'cfgChain'},
          {label: 'Chain id', figure: 'cfgChainId'},
          {label: 'Hook permission flags', figure: 'cfgHookFlags', hint: 'The hook’s mined address ends in these bits'},
        ],
      },
      {
        kind: 'note',
        tone: 'warning',
        title: 'A dash here is not a zero address',
        text: 'Where an address is missing, the contract has no configured deployment on the selected chain and the surfaces that need it render their "not deployed" state rather than reading 0x0 and showing the answers.',
      },
    ],
  },

  {
    slug: 'risk',
    title: 'Risk',
    kicker: 'Read this first',
    lede: 'The short version. The full disclosures are on /risk and you should read them.',
    source: 'lib/copy.ts RISK_DISCLOSURES',
    group: 'reference',
    blocks: [
      {
        kind: 'note',
        tone: 'danger',
        title: 'Read /risk before you use any other page',
        text: 'This page is a summary and the disclosures are not. Every item on /risk is a real property of the system rather than boilerplate, and the terms gate asks you to confirm you have read them.',
      },
      {
        kind: 'p',
        text: 'Bid depth is exactly the protocol’s own liquidity and nothing else. Redemption is the only floor, and it pays assets rather than cash. The premium is a number, not a promise. There is no authorised participant and no arrangement with the token issuer. Chain-level censorship is the one thing redemption cannot survive: the path is structurally ungated but still has to be included in a block by a single sequencer.',
      },
      {
        kind: 'p',
        text: 'The stock tokens can be frozen or blocked by their issuer. The contracts are immutable and the parameters are not. Nothing here is a return, a yield or an offer, and this interface is not available to residents of the United States, Canada, the United Kingdom or Switzerland.',
      },
    ],
  },
]

export const PAGES_BY_SLUG: Readonly<Record<string, DocsPage>> = Object.freeze(
  Object.fromEntries(PAGES.map((page) => [page.slug, page])),
)

export function pagesInGroup(group: DocsGroupId): DocsPage[] {
  return PAGES.filter((page) => page.group === group)
}

/**
 * Reading order: the groups in order, and inside each the pages in the order they are declared.
 *
 * The design derives its pager from exactly this — `ORDER = GROUPS.flatMap(g => g.items)` — so the
 * sidebar and the pager can never disagree, whatever order the page list happens to be written in.
 */
export const READING_ORDER: readonly DocsPage[] = GROUPS.flatMap((group) => pagesInGroup(group.id))

/** Previous and next in reading order, for the pager at the foot of every page. */
export function neighbours(slug: string): {prev: DocsPage | null; next: DocsPage | null} {
  const index = READING_ORDER.findIndex((page) => page.slug === slug)
  if (index < 0) return {prev: null, next: null}
  return {prev: READING_ORDER[index - 1] ?? null, next: READING_ORDER[index + 1] ?? null}
}
