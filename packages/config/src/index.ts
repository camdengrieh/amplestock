// SPDX-License-Identifier: MIT

/**
 * `@amplestocks/config` — the single source of truth for chain ids, addresses, the launch
 * constituent set and the launch parameters.
 *
 * Everything in here is **reference data pending on-chain re-verification**. The values come from
 * the implementation plan's "Verified reference data" and "Launch parameters" tables, which were
 * themselves read off explorers and directories, not off a node. Phase 0's preflight script
 * (`contracts/script/00_Preflight`) must re-read every address from chain 4663 and every feed from
 * the Chainlink Reference Data Directory before any of it is hardcoded into a deployment.
 *
 * All addresses are stored in EIP-55 checksummed form; `test/addresses.test.ts` enforces that
 * mechanically with viem's `getAddress`, and `launch.json` is a byte-for-byte mirror of the
 * exports below (regenerate with `pnpm --filter @amplestocks/config gen:json`).
 */

import type {Address} from 'viem'

// ---------------------------------------------------------------------------------------------
// Chains
// ---------------------------------------------------------------------------------------------

export const AMPS_MAINNET_CHAIN_ID = 4663
export const AMPS_TESTNET_CHAIN_ID = 46630

export type AmpsChainId = typeof AMPS_MAINNET_CHAIN_ID | typeof AMPS_TESTNET_CHAIN_ID

export interface ChainConfig {
  readonly id: AmpsChainId
  /** Human name. */
  readonly name: string
  /** `viem/chains` export that corresponds to this network, where one exists. */
  readonly viemChain: string | null
  readonly network: 'mainnet' | 'testnet'
  readonly nativeCurrency: {readonly name: string; readonly symbol: string; readonly decimals: number}
  readonly rpcUrls: {readonly http: readonly string[]; readonly webSocket: readonly string[]}
  readonly blockExplorers: readonly {readonly name: string; readonly url: string}[]
  readonly faucetUrl: string | null
  /**
   * Robinhood Chain is an Arbitrum Orbit chain on ArbOS 61 / Cancun. Two consequences the
   * contracts depend on: EIP-7702 is live, so `tx.origin == msg.sender` is not an EOA check and is
   * never used as one; EIP-1153 transient storage is available and is used by the hook.
   */
  readonly arbOsVersion: number
  readonly evmVersion: 'cancun'
  readonly eip7702: boolean
  readonly eip1153: boolean
}

export const chains = {
  mainnet: {
    id: AMPS_MAINNET_CHAIN_ID,
    name: 'Robinhood Chain',
    viemChain: 'robinhood',
    network: 'mainnet',
    nativeCurrency: {name: 'Ether', symbol: 'ETH', decimals: 18},
    rpcUrls: {
      http: ['https://rpc.mainnet.chain.robinhood.com'],
      webSocket: ['wss://robinhood-rpc.publicnode.com'],
    },
    blockExplorers: [{name: 'Blockscout', url: 'https://robinhoodchain.blockscout.com'}],
    faucetUrl: null,
    arbOsVersion: 61,
    evmVersion: 'cancun',
    eip7702: true,
    eip1153: true,
  },
  testnet: {
    id: AMPS_TESTNET_CHAIN_ID,
    name: 'Robinhood Chain Testnet',
    viemChain: null,
    network: 'testnet',
    nativeCurrency: {name: 'Ether', symbol: 'ETH', decimals: 18},
    rpcUrls: {
      http: ['https://rpc.testnet.chain.robinhood.com'],
      webSocket: ['wss://robinhood-sepolia-rpc.publicnode.com'],
    },
    blockExplorers: [{name: 'Blockscout', url: 'https://explorer.testnet.chain.robinhood.com'}],
    faucetUrl: 'https://faucet.testnet.chain.robinhood.com',
    arbOsVersion: 61,
    evmVersion: 'cancun',
    eip7702: true,
    eip1153: true,
  },
} as const satisfies Record<'mainnet' | 'testnet', ChainConfig>

export const chainById = {
  [AMPS_MAINNET_CHAIN_ID]: chains.mainnet,
  [AMPS_TESTNET_CHAIN_ID]: chains.testnet,
} as const

// ---------------------------------------------------------------------------------------------
// Address book — chain 4663
// ---------------------------------------------------------------------------------------------

export interface AddressBook {
  // Uniswap v4
  readonly poolManager: Address
  readonly positionManager: Address
  readonly stateView: Address
  readonly v4Quoter: Address
  readonly universalRouter: Address
  readonly universalRouterOrphanedSdk: Address
  readonly swapProxy: Address
  readonly permit2: Address
  readonly v3Factory: Address
  // Assets
  readonly weth9: Address
  readonly usdg: Address
  readonly usdc: Address
  // Bridging
  readonly acrossSpokePool: Address
  // Robinhood Stock Tokens
  readonly stockTokenBeacon: Address
  readonly stockTokenImplementation: Address
  readonly stockTokenAdmin: Address
  // Chainlink
  readonly chainlinkUsdgUsd: Address
  readonly chainlinkStreamsVerifierProxy: Address
  readonly ccipRouter: Address
  // Infra
  readonly safeL2Singleton: Address
  readonly create2Factory: Address
  readonly zeroExAllowanceHolder: Address
}

/**
 * Chain 4663 address book. Testnet (46630) is intentionally absent: nothing on it has been
 * verified yet, and a half-filled book invites a deploy against the wrong PoolManager.
 */
export const addresses = {
  [AMPS_MAINNET_CHAIN_ID]: {
    // --- Uniswap v4 -------------------------------------------------------------------------
    poolManager: '0x8366a39CC670B4001A1121B8F6A443A643e40951',
    positionManager: '0x58daec3116aae6D93017bAAea7749052E8a04fA7',
    stateView: '0xF3334192D15450CdD385c8B70e03f9A6bD9E673b',
    v4Quoter: '0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94',
    /** The router that is actually live and routable on 4663. Use this one. */
    universalRouter: '0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99',
    /** Published by the Uniswap SDK for 4663 but orphaned on chain — never route through it. */
    universalRouterOrphanedSdk: '0x8876789976dEcBfCbBbe364623C63652db8C0904',
    swapProxy: '0x0000000085E102724e78eCd2F45DC9cA239Affad',
    permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
    v3Factory: '0x1f7d7550B1b028f7571E69A784071F0205FD2EfA',
    // --- Assets -----------------------------------------------------------------------------
    /**
     * The ETH leg of the main speculative route is WETH9, not native ETH: native ETH is
     * `address(0)` and would always be `currency0`, breaking the AMPS-is-currency0 invariant the
     * hook relies on. The router wraps.
     */
    weth9: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73',
    /** Primary settlement stable, 6 decimals. */
    usdg: '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',
    /** Bridged USDC. */
    usdc: '0x80e0e24718dbFcad49ECAA6F1e6C89A190586cA8',
    // --- Bridging ---------------------------------------------------------------------------
    acrossSpokePool: '0xD29C85F15DF544bA632C9E25829fd29d767d7978',
    // --- Robinhood Stock Tokens -------------------------------------------------------------
    stockTokenBeacon: '0xe10b6f6B275de231345c20D14Ab812db62151b00',
    stockTokenImplementation: '0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2',
    stockTokenAdmin: '0xD6f8378F8e440c65F8382F5f2728c78DfD55B66d',
    // --- Chainlink --------------------------------------------------------------------------
    chainlinkUsdgUsd: '0x61B7e5650328764B076A108EFF5fa7282a1B9aD2',
    chainlinkStreamsVerifierProxy: '0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7',
    ccipRouter: '0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9',
    // --- Infra ------------------------------------------------------------------------------
    /** Safe v1.4.1 L2 singleton — the governance Safe and the guardian Safe both use it. */
    safeL2Singleton: '0x29fcB43b46531BcA003ddC8FCB67FFE91900C762',
    /** Canonical deterministic-deployment-proxy. Present but **unverified** on 4663. */
    create2Factory: '0x4e59b44847b379578588920cA78FbF26c0B4956C',
    zeroExAllowanceHolder: '0x0000000000001fF3684f28c67538d4D072C22734',
  },
} as const satisfies Record<typeof AMPS_MAINNET_CHAIN_ID, AddressBook>

export interface AddressNote {
  /** Whether the deployment is source-verified on the Blockscout explorer. */
  readonly verified: boolean
  /** Must be re-read from chain 4663 in Phase 0 before being hardcoded into a deploy script. */
  readonly reverify: boolean
  readonly note?: string
}

/** Provenance and health flags for {@link addresses}. Absent key ⇒ verified, still re-verify. */
export const addressNotes = {
  universalRouter: {
    verified: true,
    reverify: true,
    note: 'Live and routable on 4663; prefer over the SDK-published address.',
  },
  universalRouterOrphanedSdk: {
    verified: false,
    reverify: true,
    note: 'Published by the Uniswap SDK for 4663 but orphaned on chain. Recorded so nobody rediscovers it and routes through it.',
  },
  create2Factory: {
    verified: false,
    reverify: true,
    note: 'UNVERIFIED on the explorer. Confirm the deployed bytecode matches the canonical deterministic-deployment-proxy before using it to mine the hook address.',
  },
} as const satisfies Record<string, AddressNote>

// ---------------------------------------------------------------------------------------------
// Launch constituent set — the 30 spokes
// ---------------------------------------------------------------------------------------------

export type ConstituentKind = 'equity' | 'etf' | 'private'

export interface LaunchConstituent {
  readonly symbol: string
  readonly name: string
  readonly kind: ConstituentKind
  /** Robinhood Stock Token address on 4663, or `null` when not yet resolved. */
  readonly token: Address | null
  /** Chainlink `<symbol>/USD` aggregator on 4663, or `null` when not yet resolved. */
  readonly feed: Address | null
  /**
   * `true` while `token` or `feed` is still unknown. A constituent may not be registered in
   * `PoolRegistry` while this is `true`.
   */
  readonly verify: boolean
}

/**
 * The 30 launch spokes (Decision 2). This is the launch set, **not** a fixed set: `PoolRegistry`
 * can add, retire, reinstate and reconfigure constituents under the 7-day timelock, up to
 * `MAX_CONSTITUENTS` = 64.
 *
 * Addresses and feeds that are `null` were not resolvable from the sources available offline; they
 * are resolved in Phase 0 from `https://api.robinhood.com/rhj/assets` and the Chainlink Reference
 * Data Directory (`feeds-robinhood-mainnet.json`, 35 equity feeds).
 */
export const launchConstituents = [
  {
    symbol: 'AAPL',
    name: 'Apple Inc.',
    kind: 'equity',
    token: '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9',
    feed: '0x6B22A786bAa607d76728168703a39Ea9C99f2cD0',
    verify: false,
  },
  {symbol: 'AMD', name: 'Advanced Micro Devices, Inc.', kind: 'equity', token: null, feed: null, verify: true},
  {
    symbol: 'AMZN',
    name: 'Amazon.com, Inc.',
    kind: 'equity',
    token: '0x12f190a9F9d7D37a250758b26824B97CE941bF54',
    feed: null,
    verify: true,
  },
  {symbol: 'ASML', name: 'ASML Holding N.V.', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'BABA', name: 'Alibaba Group Holding Limited', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'CLSK', name: 'CleanSpark, Inc.', kind: 'equity', token: null, feed: null, verify: true},
  {
    symbol: 'COIN',
    name: 'Coinbase Global, Inc.',
    kind: 'equity',
    token: '0x6330D8C3178a418788dF01a47479c0ce7CCF450b',
    feed: null,
    verify: true,
  },
  {symbol: 'CRCL', name: 'Circle Internet Group, Inc.', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'CRWV', name: 'CoreWeave, Inc.', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'DELL', name: 'Dell Technologies Inc.', kind: 'equity', token: null, feed: null, verify: true},
  {
    symbol: 'GME',
    name: 'GameStop Corp.',
    kind: 'equity',
    token: '0x1b0E319c6A659F002271B69dB8A7df2F911c153E',
    feed: null,
    verify: true,
  },
  {
    symbol: 'GOOGL',
    name: 'Alphabet Inc. Class A',
    kind: 'equity',
    token: '0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3',
    feed: null,
    verify: true,
  },
  {symbol: 'INTC', name: 'Intel Corporation', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'IONQ', name: 'IonQ, Inc.', kind: 'equity', token: null, feed: null, verify: true},
  {
    symbol: 'META',
    name: 'Meta Platforms, Inc.',
    kind: 'equity',
    token: '0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35',
    feed: null,
    verify: true,
  },
  {
    symbol: 'MSFT',
    name: 'Microsoft Corporation',
    kind: 'equity',
    token: '0xe93237C50D904957Cf27E7B1133b510C669c2e74',
    feed: '0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E',
    verify: false,
  },
  {symbol: 'MSTR', name: 'Strategy Inc.', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'MU', name: 'Micron Technology, Inc.', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'NBIS', name: 'Nebius Group N.V.', kind: 'equity', token: null, feed: null, verify: true},
  {
    symbol: 'NVDA',
    name: 'NVIDIA Corporation',
    kind: 'equity',
    token: '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC',
    feed: '0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15',
    verify: false,
  },
  {symbol: 'ORCL', name: 'Oracle Corporation', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'PLTR', name: 'Palantir Technologies Inc.', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'RGTI', name: 'Rigetti Computing, Inc.', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'RKLB', name: 'Rocket Lab Corporation', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'SNDK', name: 'SanDisk Corporation', kind: 'equity', token: null, feed: null, verify: true},
  {symbol: 'SPCX', name: 'SpaceX (private-market exposure)', kind: 'private', token: null, feed: null, verify: true},
  {
    symbol: 'TSLA',
    name: 'Tesla, Inc.',
    kind: 'equity',
    token: '0x322F0929c4625eD5bAd873c95208D54E1c003b2d',
    feed: '0x4A1166a659A55625345e9515b32adECea5547C38',
    verify: false,
  },
  {
    symbol: 'TSM',
    name: 'Taiwan Semiconductor Manufacturing Company Limited',
    kind: 'equity',
    token: null,
    feed: null,
    verify: true,
  },
  {
    symbol: 'SPY',
    name: 'SPDR S&P 500 ETF Trust',
    kind: 'etf',
    token: '0x117cc2133c37B721F49dE2A7a74833232B3B4C0C',
    feed: '0x319724394D3A0e3669269846abE664Cd621f9f6A',
    verify: false,
  },
  {
    symbol: 'QQQ',
    name: 'Invesco QQQ Trust, Series 1',
    kind: 'etf',
    token: '0xD5f3879160bc7c32ebb4dC785F8a4F505888de68',
    feed: null,
    verify: true,
  },
] as const satisfies readonly LaunchConstituent[]

export const LAUNCH_CONSTITUENT_COUNT = 30

/** Ticker list in registry order. */
export const launchSymbols: readonly string[] = launchConstituents.map((c) => c.symbol)

/** `symbol -> constituent`, for lookups that should not scan the array. */
export const launchConstituentsBySymbol: Readonly<Record<string, LaunchConstituent>> =
  Object.freeze(Object.fromEntries(launchConstituents.map((c) => [c.symbol, c])))

// ---------------------------------------------------------------------------------------------
// Test fixtures — deliberately not part of the launch set
// ---------------------------------------------------------------------------------------------

export interface StockTokenFixture {
  readonly symbol: string
  readonly name: string
  readonly token: Address
  /**
   * Robinhood Stock Token share multiplier. A non-1.0 multiplier is the corporate-action mechanism
   * (splits, spin-offs) and is exactly the case the vault's accounting must survive, which is why
   * this fixture exists.
   */
  readonly multiplier: number
  readonly inLaunchSet: false
  readonly note: string
}

export const testFixtures = {
  CRWD: {
    symbol: 'CRWD',
    name: 'CrowdStrike Holdings, Inc.',
    token: '0xea72Ecca2d0f6bFA1394DBBCff85b52CD4233931',
    multiplier: 4.0,
    inLaunchSet: false,
    note: 'Multiplier 4.0 — the only Stock Token found with a non-unit multiplier, used as the corporate-action fork-test fixture. Not a launch constituent.',
  },
} as const satisfies Record<string, StockTokenFixture>

// ---------------------------------------------------------------------------------------------
// Launch parameters
// ---------------------------------------------------------------------------------------------

const WAD = 10n ** 18n
const HOUR = 3600
const DAY = 86_400

export interface Band<T> {
  readonly min: T
  readonly max: T
}

/**
 * The confirmed launch parameters. `*Band` / `*Cap` entries are the **hard-coded** limits enforced
 * in the consuming contract, not governance defaults: governance can move a parameter inside its
 * band, never outside it.
 */
export const launchParameters = {
  supply: {
    /**
     * `S0` — minted once, by `AmpsVault.genesisMint`. 20,000 AMPS, 18 decimals.
     *
     * Revision 7 doubled the supply and split it three ways instead of two, because half of it is
     * now **sold at auction** rather than retained: the launch price is whatever two Continuous
     * Clearing Auctions clear at, not a number chosen in advance. `contracts/src/types/Constants.sol`
     * holds the same three figures as constants and `genesisMint` rejects any other allocation, so
     * these are a mirror of the bytecode rather than a parameter set.
     */
    s0: 20_000n * WAD,
    s0Amps: 20_000,
    /** 5% to the team under an OZ `VestingWallet`, 2-month linear, no cliff. */
    teamAmps: 1_000,
    teamWei: 1_000n * WAD,
    teamVestSeconds: 60 * DAY,
    teamCliffSeconds: 0,
    /** 50% sold through the two auctions. See {@link launchParameters.auction}. */
    auctionAmps: 10_000,
    auctionWei: 10_000n * WAD,
    /** 45% protocol-owned liquidity, placed after settlement and anchored at the clearing price. */
    polAmps: 9_000,
    polWei: 9_000n * WAD,
    /** 1% of the POL tranche seeded as the ask in each of the 30 spokes: 90 x 30 = 2,700. */
    perSpokeSeedAmps: 90,
    perSpokeSeedWei: 90n * WAD,
    spokeCount: 30,
    spokeSeedTotalAmps: 2_700,
    /** The remaining 6,300 AMPS, split evenly across the two entry pools. */
    entryPoolAmpsEach: 3_150,
    entryPoolWeiEach: 3_150n * WAD,
    entryPoolTotalAmps: 6_300,
  },
  /**
   * The genesis auction (plan revision 7, `docs/genesis-cca.md`).
   *
   * Half of `S0` is sold through **two Uniswap Continuous Clearing Auctions** — one denominated in
   * USDG, one in native ETH — at a floor of $1.00 per AMPS in each currency. The uniform clearing
   * price becomes `P0`, the vault's launch reference price, and all 32 pools are opened at it; the
   * currency raised becomes the vault's backing and the entry pools' bid ladders.
   *
   * **The tranche sizes and the floor are not governance parameters.** `AmpsGenesis.createAuctions`
   * computes the floor itself and refuses any allocation other than the constants, so what a
   * proposal actually sets is the schedule, the tick spacing, the graduation bar and the validation
   * hook — `contracts/script/config/genesis.json`, not this file.
   *
   * `navPerShareAtFloorUsd` is arithmetic on the two figures above, not a promise: at a full clear
   * at the floor the auctions raise $10,000 against a fully diluted `S0` of 20,000, so NAV/share
   * opens at $0.50 and the launch premium is 100%. It is **disclosed, not smoothed** — the vault
   * keeps 45% of the supply as inventory backed by nothing until it sells, and every ask that fills
   * at or above `P0` raises the backing.
   */
  auction: {
    /** Both legs together: `Constants.AUCTION_SHARES`. */
    totalAmps: 10_000,
    totalWei: 10_000n * WAD,
    /** `Constants.AUCTION_USDG_SHARES` — sold for USDG. */
    usdgAmps: 5_000,
    usdgWei: 5_000n * WAD,
    /** `Constants.AUCTION_ETH_SHARES` — sold for native ETH, wrapped to WETH9 at settlement. */
    ethAmps: 5_000,
    ethWei: 5_000n * WAD,
    /** $1.00 per AMPS in each currency, computed inside `AmpsGenesis.createAuctions`. */
    floorPriceUsd: 1.0,
    legs: 2,
    mechanism: 'Uniswap Continuous Clearing Auction v2.1.0',
    /** What a full clear at the floor raises, in USD. */
    raisedAtFloorUsd: 10_000,
    /** `raised / S0` at a full clear at the floor, fully diluted (Decision 14). */
    navPerShareAtFloorUsd: 0.5,
    /** `P0 / NAV - 1` at a full clear at the floor. Disclosed, never smoothed. */
    premiumAtFloorBps: 10_000,
  },
  /**
   * The founders' seed, kept **only** as the non-graduation fallback.
   *
   * If neither auction reaches its `requiredCurrencyRaised`, bidders refund in full through the
   * auctions themselves, `AmpsGenesis.settle()` returns the whole tranche to the vault and calls
   * nothing, and the timelock runs `AmpsVault.genesisPlace` with `p0X18 = 1e18` out of this seed —
   * the pre-revision-7 launch exactly, pools opening at $1.00. It is scaled to `S0`: $20,000
   * against 20,000 AMPS is NAV/share $1.00, the same price the floor would have cleared at.
   *
   * `contracts/script/config/genesis.json`'s `fallback.seedUsdg` / `fallback.seedWeth` carry the
   * raw amounts the script approves; these are the human figures behind them.
   */
  fallbackSeed: {
    totalUsd: 20_000,
    usdgUsd: 10_000,
    ethUsd: 10_000,
    /** 10,000 USDG at 6 decimals. */
    usdgRaw: 10_000_000_000n,
    /** 4 WETH — $10,000 at the $2,500 ETH the fixtures price it at. */
    wethWei: 4n * WAD,
    /** `p0X18` on the fallback path, and therefore NAV/share at a $20,000 seed against `S0`. */
    launchPriceUsd: 1.0,
    entryPools: ['AMPS/WETH', 'AMPS/USDG'],
  },
  /**
   * The revision-6 fee model, in one place.
   *
   * - **`ampsFeeBps` is charged both ways.** Entering the index and leaving it are the same trade
   *   seen from two sides, so the hook charges it on every net buy *and* every net sell in all 32
   *   pools. A fee charged on one side alone is a fee a round trip halves.
   * - **The pass-through fee is only reachable through the router.** `buyFeeBps*` is what a
   *   *rotation* hop pays — selling one constituent to buy another, which passes through AMPS and
   *   leaves the index's AMPS float where it found it. The exemption is bound to one contract:
   *   `sender == AmpsHook.router()` **and** the hop carries the router's rotate flag. `AmpsRouter`
   *   sets it on the two hops of `rotate` and nowhere else, so its own `buy` and `sell` pay
   *   `ampsFeeBps` like everybody else.
   * - **The creator is paid in kind, in every currency.** At `compound()` the creator receives
   *   `creatorBps(t) / ampsFeeBps` of the fees collected in *each* currency — AMPS by transfer,
   *   the counter asset in kind with an ERC-6909 claim fallback — which is exactly
   *   `creatorFeeBps` of the volume that produced them, decaying linearly to zero over
   *   `creatorFeeDecaySeconds`. It is carved out of the fee, never added on top.
   * - **Everything left of the AMPS side is burned.** There is no staker slice and nothing is
   *   re-laddered, so `totalSupply` falls by `ampsFees - creatorAmps` at every compound and by the
   *   whole buyback on top. The counter side stays in the pool that earned it, re-placed as bids.
   */
  fees: {
    /** Charged on every net buy and every net sell in all 32 pools. Both directions, always. */
    ampsFeeBps: 500,
    ampsFeeBpsBand: {min: 100, max: 600},
    /** The **pass-through** base fee, paid only by an `AmpsRouter.rotate` hop: entry / spoke /
     *  high-sigma spoke. No other swap in the protocol is priced at it. */
    buyFeeBpsEntry: 30,
    buyFeeBpsSpoke: 5,
    buyFeeBpsSpokeHighVol: 10,
    buyFeeBpsEntryBand: {min: 5, max: 100},
    buyFeeBpsSpokeBand: {min: 1, max: 50},
    /** The floor exit: dearer than a rotation hop, cheaper than a market exit at 500 bp. */
    redeemFeeBps: 250,
    redeemFeeBpsCap: 500,
    /** 1% of volume to the creator, in every currency in kind, decaying to zero over 30 days. */
    creatorFeeBps: 100,
    creatorFeeDecaySeconds: 30 * DAY,
  },
  bonds: {
    dBaseBps: 1_250,
    dMinBps: 1_000,
    dMaxBps: 1_500,
    discountBandBps: {min: 500, max: 2_500},
    /** Capacity per market per epoch, in bp of `T`. */
    capBpsPerEpoch: 50,
    capBpsPerEpochCap: 200,
    /** Global capacity per day, in bp of `T`. */
    dailyCapBps: 200,
    dailyCapBpsCap: 500,
    epochSeconds: 6 * HOUR,
    epochSecondsBand: {min: 1 * HOUR, max: 7 * DAY},
    vestSeconds: 12 * HOUR,
    vestSecondsBand: {min: 1 * HOUR, max: 7 * DAY},
    /** A bond that would accrete less than this to NAV/share is refused. */
    minAccretionBps: 50,
    /** Stale-feed haircut by equity session: Regular / Pre-Post / Overnight / Closed. */
    hSessionBps: [0, 50, 150, 300],
    hSession: {regular: 0, prePost: 50, overnight: 150, closed: 300},
    hSessionBandBps: {min: 0, max: 1_000},
    /** `ENTRY` collateral (WETH, USDG) exists from v1 but is closed at launch. */
    entryCollateralOpenAtLaunch: false,
  },
  reference: {
    /** Maximum upward move of the reference price, per hour. */
    refUpRateBps: 1_000,
    refUpRateBpsBand: {min: 100, max: 5_000},
    refUpRatePeriodSeconds: 1 * HOUR,
  },
  ladder: {
    /** Bucket `k` holds `tilt^k / sum(tilt^j)` of the pool's inventory. */
    ladderTilt: 1.25,
    ladderTiltBand: {min: 1.0, max: 1.5},
    /** 10 doublings: $1 -> $1,024. */
    ladderDoublings: 10,
    ladderDoublingsBand: {min: 6, max: 14},
    /** Seed bids sit as 4 halvings below the anchor, weighted toward it. */
    seedHalvings: 4,
    bondBidHalvings: 4,
    halvingsBand: {min: 2, max: 8},
  },
  rollout: {
    /** Rate at which unfilled entry-pool buckets migrate into the spokes. */
    rolloutBpsPerDay: 200,
    rolloutBpsPerDayCap: 1_000,
    /** Floor on entry-pool inventory: rollout never drains the entry pools below this. */
    entryFloorBps: 3_000,
  },
  keeper: {
    /** Bounty paid per successful keeper call, governed upward with TVL. */
    tipUsd: 0.05,
    /** Minimum accrued value that makes a `compound()` worth calling. */
    chostUsd: 1,
  },
  pools: {
    /** 30 spokes + `AMPS/WETH` + `AMPS/USDG`, all on one immutable hook. */
    totalPools: 32,
    spokePools: 30,
    entryPools: 2,
    /** `PoolRegistry` hard cap on constituents. */
    maxConstituents: 64,
    /** Hook permission flags: the hook's mined address must end in these bits. */
    hookFlags: '0x38C0',
  },
  governance: {
    /** Safe 3/5 proposer -> OZ `TimelockController` with `EXECUTOR_ROLE = address(0)`. */
    proposerThreshold: {n: 3, of: 5},
    guardianThreshold: {n: 2, of: 4},
    /** Fees, bands, bond parameters, ladder shape, rollout rates. */
    timelockFastSeconds: 48 * HOUR,
    /** Constituent lifecycle, collateral set, index weights, policy pointers. */
    timelockSlowSeconds: 7 * DAY,
    /** Standby vault. */
    timelockStandbySeconds: 14 * DAY,
    /** Guardian freeze is disable-only and auto-expires; it can never block `redeemProRata`. */
    guardianFreezeExpirySeconds: 7 * DAY,
  },
} as const

// ---------------------------------------------------------------------------------------------
// JSON mirror helpers
// ---------------------------------------------------------------------------------------------

/**
 * `JSON.stringify` replacer that renders `bigint` as a decimal string. Used by
 * `scripts/gen-launch-json.ts` and by the test that keeps `launch.json` honest.
 */
export function jsonReplacer(_key: string, value: unknown): unknown {
  return typeof value === 'bigint' ? value.toString() : value
}

/** Everything that is mirrored into `launch.json`, in mirror order. */
export const launchJsonSource = {
  $comment:
    'Generated from packages/config/src/index.ts by `pnpm --filter @amplestocks/config gen:json`. Do not edit by hand. Every address is reference data pending on-chain re-verification in Phase 0.',
  chains,
  addresses,
  addressNotes,
  launchConstituents,
  testFixtures,
  launchParameters,
} as const
