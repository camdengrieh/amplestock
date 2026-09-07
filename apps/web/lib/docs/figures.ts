// SPDX-License-Identifier: MIT

/**
 * Every figure the documentation is allowed to print, and where it comes from.
 *
 * **The rule this file exists to enforce:** a `rows` or `table` block in `/docs` cannot contain a
 * number. It can only name a figure id, and the id is resolved at render time from the chain, from
 * `@amplestocks/config` or from the deployment record. A figure whose source cannot answer renders
 * the unavailable treatment with its reason — never a zero, never last week's value, and never a
 * number typed into a documentation page and left to rot.
 *
 * `test/docs.test.ts` walks every page and fails if a block names an id that is not in this
 * catalogue, and fails if any id resolves to a printed value when its source is absent.
 */

export type FigureSource =
  /** A live contract read. */
  | 'chain'
  /** `@amplestocks/config` — reference data the deploy scripts re-verify on chain in Phase 0. */
  | 'config'
  /** The deployment record: `NEXT_PUBLIC_*`, absent until Phase 6 has run. */
  | 'deployment'

export interface FigureSpec {
  /** What the row is called when this figure is the whole row. */
  label: string
  /** Where the number comes from, so the docs can say so on the page. */
  source: FigureSource
  /** The exact call or key, printed under the table so a reader can check it themselves. */
  from: string
}

export const FIGURES = {
  // --- Fees ---------------------------------------------------------------------------------
  ampsFee: {label: 'AMPS fee, live', source: 'chain', from: 'AmpsHook.ampsFeeBps()'},
  ampsFeeBand: {label: 'AMPS fee band', source: 'chain', from: 'AmpsHook.AMPS_FEE_BPS_MIN / _MAX'},
  totalFeeMax: {label: 'Absolute fee ceiling', source: 'chain', from: 'AmpsHook.TOTAL_FEE_BPS_MAX()'},
  entryBaseFeeBand: {label: 'Entry-pool base fee band', source: 'chain', from: 'PoolRegistry.BUY_FEE_BPS_ENTRY_MIN / _MAX'},
  spokeBaseFeeBand: {label: 'Spoke base fee band', source: 'chain', from: 'PoolRegistry.BUY_FEE_BPS_SPOKE_MIN / _MAX'},
  creatorFeeGenesis: {label: 'Creator fee at genesis', source: 'chain', from: 'AmpsVault.CREATOR_FEE_BPS()'},
  creatorDecay: {label: 'Creator fee decays over', source: 'chain', from: 'AmpsVault.CREATOR_DECAY_SECONDS()'},
  creatorFeeNow: {label: 'Creator fee in force now', source: 'chain', from: 'AmpsVault.creatorBpsAt(now)'},

  // --- Redemption ---------------------------------------------------------------------------
  redeemFee: {label: 'Redemption fee, live', source: 'chain', from: 'AmpsVault.redeemFeeBps()'},
  redeemFeeMax: {label: 'Redemption fee ceiling', source: 'chain', from: 'AmpsVault.REDEEM_FEE_BPS_MAX()'},

  // --- Vault --------------------------------------------------------------------------------
  navPerShare: {label: 'NAV per share', source: 'chain', from: 'AmpsVault.checkpointData().navPerShareX18'},
  pRef: {label: 'Reference price', source: 'chain', from: 'AmpsVault.checkpointData().pRefX18'},
  pMkt: {label: 'Market price', source: 'chain', from: 'AmpsVault.checkpointData().pMktX18'},
  premium: {label: 'Premium to NAV', source: 'chain', from: 'pRefX18 / navPerShareX18 − 1'},
  totalAssets: {label: 'Total assets', source: 'chain', from: 'AmpsVault.totalAssetsUsd18()'},
  inventoryAmps: {label: 'Protocol inventory', source: 'chain', from: 'AmpsVault.inventoryAmps()'},
  totalSupply: {label: 'Total supply', source: 'chain', from: 'Amps.totalSupply()'},
  liveCells: {label: 'Live ladder cells', source: 'chain', from: 'AmpsVault.liveCells()'},
  assetCount: {label: 'Assets held', source: 'chain', from: 'AmpsVault.assetCount()'},
  rolloutRate: {label: 'Rollout rate', source: 'chain', from: 'AmpsVault.rolloutBpsPerDay()'},
  rolloutRateMax: {label: 'Rollout rate ceiling', source: 'chain', from: 'AmpsVault.ROLLOUT_BPS_PER_DAY_MAX()'},
  entryFloor: {label: 'Entry-pool floor', source: 'chain', from: 'AmpsVault.entryFloorBps()'},
  refUpRate: {label: 'Reference up-rate', source: 'chain', from: 'AmpsVault.refUpRateBps()'},
  refDivergence: {label: 'Reference divergence limit', source: 'chain', from: 'AmpsVault.refDivergenceBps()'},
  twapWindow: {label: 'TWAP window', source: 'chain', from: 'AmpsVault.twapWindow()'},
  ladderDoublings: {label: 'Ladder doublings', source: 'chain', from: 'AmpsVault.ladderDoublings()'},
  ladderTilt: {label: 'Ladder tilt', source: 'chain', from: 'AmpsVault.ladderTiltX18()'},
  spokeSeed: {label: 'Spoke seed share', source: 'chain', from: 'AmpsVault.spokeSeedBps()'},
  vaultInitialized: {label: 'Vault initialised', source: 'chain', from: 'AmpsVault.initialized()'},

  // --- Bonds --------------------------------------------------------------------------------
  bondVest: {label: 'Vest length', source: 'chain', from: 'AmpsBonds.vestSeconds()'},
  bondVestBand: {label: 'Vest band', source: 'chain', from: 'AmpsBonds.VEST_SECONDS_MIN / _MAX'},
  bondEpoch: {label: 'Epoch length', source: 'chain', from: 'AmpsBonds.epochSeconds()'},
  bondMinAccretion: {label: 'Minimum accretion', source: 'chain', from: 'AmpsBonds.minAccretionBps()'},
  bondDailyCap: {label: 'Daily issuance cap', source: 'chain', from: 'AmpsBonds.dailyCapBps()'},
  bondDiscountBand: {label: 'Discount band', source: 'chain', from: 'AmpsBonds.DISCOUNT_BPS_MIN / _MAX'},
  bondMarkets: {label: 'Markets', source: 'chain', from: 'AmpsBonds.marketCount()'},
  bondIssuedToday: {label: 'Issued today', source: 'chain', from: 'AmpsBonds.dailyIssuance()'},

  // --- Registry -----------------------------------------------------------------------------
  poolCount: {label: 'Pools registered', source: 'chain', from: 'PoolRegistry.poolCount()'},
  constituentCount: {label: 'Constituents', source: 'chain', from: 'PoolRegistry.constituentCount()'},
  activeConstituentCount: {label: 'Active constituents', source: 'chain', from: 'PoolRegistry.activeConstituentCount()'},
  indexCap: {label: 'Index weight cap', source: 'chain', from: 'PoolRegistry.indexCapBps()'},
  indexFloor: {label: 'Index weight floor', source: 'chain', from: 'PoolRegistry.indexFloorBps()'},
  maxConstituents: {label: 'Maximum constituents', source: 'chain', from: 'PoolRegistry.MAX_CONSTITUENTS()'},

  // --- Deployment addresses -----------------------------------------------------------------
  addrAmps: {label: 'Amps', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_TOKEN'},
  addrVault: {label: 'AmpsVault', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_VAULT'},
  addrQuoter: {label: 'AmpsQuoter', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_QUOTER'},
  addrBonds: {label: 'AmpsBonds', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_BONDS'},
  addrBondsLens: {label: 'AmpsBondsLens', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_BONDS_LENS'},
  addrRouter: {label: 'AmpsRouter', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_ROUTER'},
  addrRegistry: {label: 'PoolRegistry', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_REGISTRY'},
  addrRegistryLens: {label: 'PoolRegistryLens', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_REGISTRY_LENS'},
  addrHook: {label: 'AmpsHook', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_HOOK'},
  addrOracleGate: {label: 'OracleGate', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_ORACLE_GATE'},
  addrTimelock: {label: 'TimelockController', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_TIMELOCK'},

  // --- Reference addresses ------------------------------------------------------------------
  refPoolManager: {label: 'PoolManager', source: 'config', from: 'addresses[4663].poolManager'},
  refUniversalRouter: {label: 'UniversalRouter', source: 'config', from: 'addresses[4663].universalRouter'},
  refPermit2: {label: 'Permit2', source: 'config', from: 'addresses[4663].permit2'},
  refWeth9: {label: 'WETH9', source: 'config', from: 'addresses[4663].weth9'},
  refUsdg: {label: 'USDG', source: 'config', from: 'addresses[4663].usdg'},
  refUsdc: {label: 'USDC (bridged)', source: 'config', from: 'addresses[4663].usdc'},
  refAcross: {label: 'Across SpokePool', source: 'config', from: 'addresses[4663].acrossSpokePool'},
  refStockBeacon: {label: 'Stock token beacon', source: 'config', from: 'addresses[4663].stockTokenBeacon'},

  // --- Genesis auction ------------------------------------------------------------------------
  auctionUsdgAddress: {label: 'AMPS/USDG auction', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_AUCTION_USDG'},
  auctionEthAddress: {label: 'AMPS/ETH auction', source: 'deployment', from: 'NEXT_PUBLIC_AMPS_AUCTION_ETH'},
  auctionUsdgPhase: {label: 'AMPS/USDG auction', source: 'chain', from: 'startBlock() / endBlock() / claimBlock()'},
  auctionEthPhase: {label: 'AMPS/ETH auction', source: 'chain', from: 'startBlock() / endBlock() / claimBlock()'},
  auctionUsdgClearing: {label: 'AMPS/USDG clearing price', source: 'chain', from: 'ContinuousClearingAuction.clearingPrice()'},
  auctionEthClearing: {label: 'AMPS/ETH clearing price', source: 'chain', from: 'ContinuousClearingAuction.clearingPrice()'},
  auctionUsdgRaised: {label: 'AMPS/USDG raised', source: 'chain', from: 'ContinuousClearingAuction.currencyRaised()'},
  auctionEthRaised: {label: 'AMPS/ETH raised', source: 'chain', from: 'ContinuousClearingAuction.currencyRaised()'},
  auctionUsdgSupply: {label: 'AMPS/USDG tranche', source: 'chain', from: 'ContinuousClearingAuction.totalSupply()'},
  auctionEthSupply: {label: 'AMPS/ETH tranche', source: 'chain', from: 'ContinuousClearingAuction.totalSupply()'},
  auctionUsdgGraduated: {label: 'AMPS/USDG graduated', source: 'chain', from: 'ContinuousClearingAuction.isGraduated()'},
  auctionEthGraduated: {label: 'AMPS/ETH graduated', source: 'chain', from: 'ContinuousClearingAuction.isGraduated()'},
  ccaLens: {label: 'CCALens', source: 'config', from: 'CCA_LENS_ADDRESS'},

  // --- Launch parameters --------------------------------------------------------------------
  cfgChain: {label: 'Chain', source: 'config', from: 'chainById[chainId].name'},
  cfgChainId: {label: 'Chain id', source: 'config', from: 'chainById[chainId].id'},
  cfgS0: {label: 'Genesis supply S₀', source: 'config', from: 'launchParameters.supply.s0'},
  cfgLaunchPrice: {label: 'NAV per share at genesis', source: 'config', from: 'launchParameters.seed.launchPriceUsd'},
  cfgTotalPools: {label: 'Pools at launch', source: 'config', from: 'launchParameters.pools.totalPools'},
  cfgSpokePools: {label: 'Spokes at launch', source: 'config', from: 'launchParameters.pools.spokePools'},
  cfgEntryPools: {label: 'Entry pools', source: 'config', from: 'launchParameters.pools.entryPools'},
  cfgTimelockFast: {label: 'Timelock — parameters', source: 'config', from: 'launchParameters.governance.timelockFastSeconds'},
  cfgTimelockSlow: {label: 'Timelock — constituents and policies', source: 'config', from: 'launchParameters.governance.timelockSlowSeconds'},
  cfgTimelockStandby: {label: 'Timelock — standby vault', source: 'config', from: 'launchParameters.governance.timelockStandbySeconds'},
  cfgGuardianFreeze: {label: 'Guardian freeze expiry', source: 'config', from: 'launchParameters.governance.guardianFreezeExpirySeconds'},
  cfgProposer: {label: 'Proposer Safe', source: 'config', from: 'launchParameters.governance.proposerThreshold'},
  cfgGuardian: {label: 'Guardian Safe', source: 'config', from: 'launchParameters.governance.guardianThreshold'},
  cfgLaunchConstituents: {label: 'Launch constituent set', source: 'config', from: 'launchConstituents.length'},
  cfgHookFlags: {label: 'Hook permission flags', source: 'config', from: 'launchParameters.pools.hookFlags'},
} as const satisfies Record<string, FigureSpec>

export type FigureId = keyof typeof FIGURES

export const FIGURE_IDS = Object.keys(FIGURES) as FigureId[]

export function isFigureId(value: string): value is FigureId {
  return Object.prototype.hasOwnProperty.call(FIGURES, value)
}

/** A resolved figure. There is no third state where a number is printed without a source. */
export type FigureValue =
  | {status: 'value'; text: string}
  | {status: 'unavailable'; reason: string}

export function figureText(value: FigureValue | undefined): string | null {
  return value?.status === 'value' ? value.text : null
}

export function figureReason(value: FigureValue | undefined): string {
  return value?.status === 'unavailable' ? value.reason : 'Not resolved'
}
