// SPDX-License-Identifier: MIT

/**
 * Turning live reads into the strings the documentation prints.
 *
 * Pure on purpose. Every input is optional, every output is either a formatted value or an
 * unavailable with a reason, and there is no branch that invents a number. The React hook in
 * `hooks/use-docs-figures.ts` does nothing but gather the inputs; all of the "is this actually
 * known?" logic is here, where a test can drive it with nothing available and assert that nothing
 * is printed.
 */

import {
  AMPS_MAINNET_CHAIN_ID,
  addresses as referenceAddresses,
  chainById,
  launchConstituents,
  launchParameters,
  type AmpsChainId,
} from '@amplestocks/config'
import {formatUnits, type Address} from 'viem'

import {FIGURE_IDS, type FigureId, type FigureValue} from './figures'
import {ROUTER_ROTATE} from '../protocol'
import {CCA_LENS_ADDRESS} from '../abi/cca'
import type {Deployment, GenesisAuctions} from '../deployment'
import {formatAmount, formatBps, formatDuration, formatPremiumX18, formatUsd18} from '../format'

/** Why a figure has no value. Each one names the source that did not answer. */
export const REASONS = {
  chain: 'Not readable on this chain — the contracts are not deployed, or the read failed',
  deployment: 'No address is configured for this contract on this chain',
  config: 'No verified reference book exists for this chain',
  checkpoint: 'The vault checkpoint could not be read',
  twap: 'Not enough observation history yet',
  unsettled: 'Genesis has not been settled yet, so there is no launch price to print',
  aborted: 'No auction leg graduated, so there was no launch: bidders refund through the auctions themselves',
} as const

export interface DocsChainReads {
  ampsFeeBps?: number
  ampsFeeBand?: {min: number; max: number} | null
  totalFeeBpsMax?: number
  entryBaseFeeBand?: {min: number; max: number} | null
  spokeBaseFeeBand?: {min: number; max: number} | null
  maxConstituents?: number

  redeemFeeBps?: number
  redeemFeeBpsMax?: number
  creatorFeeBps?: number
  creatorDecaySeconds?: number
  creatorBpsNow?: number

  navPerShareX18?: bigint
  pRefX18?: bigint
  pMktX18?: bigint
  totalAssetsUsd18?: bigint
  inventoryAmps?: bigint
  totalSupply?: bigint
  liveCells?: number
  assetCount?: number
  initialized?: boolean
  rolloutBpsPerDay?: number
  rolloutBpsPerDayMax?: number
  entryFloorBps?: number
  refUpRateBps?: number
  refDivergenceBps?: number
  twapWindow?: number
  ladderDoublings?: number
  ladderTiltX18?: bigint
  spokeSeedBps?: number

  bondVestSeconds?: number
  bondVestBand?: {min: number; max: number} | null
  bondEpochSeconds?: number
  bondMinAccretionBps?: number
  bondDailyCapBps?: number
  bondDiscountBand?: {min: number; max: number} | null
  bondMarketCount?: number
  bondIssuedToday?: {issued: bigint; capacity: bigint}

  poolCount?: number
  constituentCount?: number
  activeConstituentCount?: number
  indexCapBps?: number
  indexFloorBps?: number

  /**
   * `AmpsHook.router()`. Read from the hook, not from the address book: the pass-through exemption
   * is whatever the hook says it is, and a deployment record can be out of date with it.
   */
  hookRouter?: Address

  /** One entry per genesis auction, keyed by its deployment key. */
  auctions?: Partial<Record<'usdg' | 'eth', DocsAuctionRead>>

  /** `AmpsGenesis`, the adapter that turns the two auctions into a launch. */
  genesis?: DocsGenesisRead
}

/**
 * What the docs need from `AmpsGenesis`.
 *
 * `p0X18` is zero both before settlement and after a settlement in which nothing graduated, and
 * neither of those is a price — so the resolver reads the phase rather than the number, and prints
 * the unavailable treatment with the reason instead of `$0.00`.
 */
export interface DocsGenesisRead {
  /** The decoded phase label, or `undefined` when the adapter did not answer. */
  phase?: string
  settled?: boolean
  p0X18?: bigint
  raisedUsd18?: bigint
  raisedUsdg?: bigint
  usdgDecimals?: number
  raisedWeth?: bigint
  unsoldAmps?: bigint
  ethUsdX18?: bigint
  floorUsdgX18?: bigint
  floorEthX18?: bigint
  /** NAV/share at launch: the vault's own checkpoint, or `raisedUsd18 / T` before it is readable. */
  navPerShareX18?: bigint
}

/**
 * What the docs need from one Continuous Clearing Auction.
 *
 * Prices arrive already converted to whole currency per whole AMPS at 18 decimals, because the
 * conversion needs the currency's decimals and those are a read of their own — doing it here would
 * mean this module knowing which auction has which currency.
 */
export interface DocsAuctionRead {
  phase?: string
  clearingPriceX18?: bigint
  currencySymbol?: string
  raised?: bigint
  currencyDecimals?: number
  trancheSupply?: bigint
  isGraduated?: boolean
}

export interface DocsResolveInput {
  chainId: AmpsChainId
  deployment: Deployment
  auctions?: GenesisAuctions
  reads: DocsChainReads
}

function value(text: string): FigureValue {
  return {status: 'value', text}
}

function missing(reason: string): FigureValue {
  return {status: 'unavailable', reason}
}

function num(v: number | undefined, format: (n: number) => string, reason: string = REASONS.chain): FigureValue {
  return v === undefined ? missing(reason) : value(format(v))
}

function band(
  b: {min: number; max: number} | null | undefined,
  format: (n: number) => string,
  reason: string = REASONS.chain,
): FigureValue {
  return b ? value(`${format(b.min)} – ${format(b.max)}`) : missing(reason)
}

function big(v: bigint | undefined, format: (n: bigint) => string, reason: string = REASONS.chain): FigureValue {
  return v === undefined ? missing(reason) : value(format(v))
}

function address(v: Address | undefined, reason: string): FigureValue {
  return v === undefined ? missing(reason) : value(v)
}

/**
 * Resolves every figure in the catalogue.
 *
 * Returns a complete record: an id that no source can answer for is present with
 * `status: 'unavailable'` and a reason, so a renderer never has to decide what a missing key means.
 */
export function resolveDocFigures(input: DocsResolveInput): Record<FigureId, FigureValue> {
  const {reads, deployment, chainId} = input
  const auctionAddresses = input.auctions ?? {}

  const auctionPhaseFigure = (key: 'usdg' | 'eth'): FigureValue => {
    const phase = reads.auctions?.[key]?.phase
    return phase === undefined ? missing(REASONS.deployment) : value(phase)
  }
  const auctionPriceFigure = (key: 'usdg' | 'eth'): FigureValue => {
    const read = reads.auctions?.[key]
    if (!read || read.clearingPriceX18 === undefined) return missing(REASONS.chain)
    const n = Number(read.clearingPriceX18) / 1e18
    if (!Number.isFinite(n)) return missing(REASONS.chain)
    return value(`${n.toLocaleString('en-US', {minimumFractionDigits: 6, maximumFractionDigits: 6})} ${read.currencySymbol ?? ''}`.trim())
  }
  const auctionRaisedFigure = (key: 'usdg' | 'eth'): FigureValue => {
    const read = reads.auctions?.[key]
    if (!read || read.raised === undefined || read.currencyDecimals === undefined) return missing(REASONS.chain)
    return value(`${formatAmount(read.raised, read.currencyDecimals)} ${read.currencySymbol ?? ''}`.trim())
  }
  const auctionSupplyFigure = (key: 'usdg' | 'eth'): FigureValue => {
    const supply = reads.auctions?.[key]?.trancheSupply
    return supply === undefined ? missing(REASONS.chain) : value(`${formatAmount(supply, 18)} AMPS`)
  }
  const auctionGraduatedFigure = (key: 'usdg' | 'eth'): FigureValue => {
    const graduated = reads.auctions?.[key]?.isGraduated
    return graduated === undefined ? missing(REASONS.chain) : value(graduated ? 'Yes' : 'Not yet')
  }
  // Genesis. Every figure below is gated on the phase rather than on the number, because zero is a
  // legitimate answer from `p0X18()` in two different states and neither of them is a price.
  const genesis = reads.genesis
  const genesisReason =
    genesis?.phase === undefined
      ? REASONS.chain
      : genesis.phase === 'aborted'
        ? REASONS.aborted
        : genesis.settled === true
          ? REASONS.chain
          : REASONS.unsettled
  const settledOnly = (v: bigint | undefined, format: (n: bigint) => string): FigureValue =>
    genesis?.settled !== true || v === undefined ? missing(genesisReason) : value(format(v))
  const genesisPremiumX18 =
    genesis?.p0X18 !== undefined &&
    genesis.p0X18 > 0n &&
    genesis.navPerShareX18 !== undefined &&
    genesis.navPerShareX18 > 0n
      ? (genesis.p0X18 * 10n ** 18n) / genesis.navPerShareX18 - 10n ** 18n
      : undefined

  const book = chainId === AMPS_MAINNET_CHAIN_ID ? referenceAddresses[AMPS_MAINNET_CHAIN_ID] : null
  const chain = chainById[chainId]
  const gov = launchParameters.governance

  const premiumX18 =
    reads.pRefX18 !== undefined && reads.navPerShareX18 !== undefined && reads.navPerShareX18 > 0n
      ? (reads.pRefX18 * 10n ** 18n) / reads.navPerShareX18 - 10n ** 18n
      : undefined

  const resolved: Record<FigureId, FigureValue> = {
    // --- Fees -------------------------------------------------------------------------------
    ampsFee: num(reads.ampsFeeBps, formatBps),
    ampsFeeBand: band(reads.ampsFeeBand, formatBps),
    totalFeeMax: num(reads.totalFeeBpsMax, formatBps),
    entryBaseFeeBand: band(reads.entryBaseFeeBand, formatBps),
    spokeBaseFeeBand: band(reads.spokeBaseFeeBand, formatBps),
    creatorFeeGenesis: num(reads.creatorFeeBps, formatBps),
    creatorDecay: num(reads.creatorDecaySeconds, formatDuration),
    creatorFeeNow: num(reads.creatorBpsNow, formatBps),
    hookRouter: address(reads.hookRouter, REASONS.chain),
    // Derived from the same string the contracts hash, so it cannot disagree with them unless the
    // string does — which is why it is a `config` figure and not a `chain` one.
    rotateFlag: value(ROUTER_ROTATE),

    // --- Redemption -------------------------------------------------------------------------
    redeemFee: num(reads.redeemFeeBps, formatBps),
    redeemFeeMax: num(reads.redeemFeeBpsMax, formatBps),

    // --- Vault ------------------------------------------------------------------------------
    navPerShare: big(reads.navPerShareX18, (v) => formatUsd18(v, 4), REASONS.checkpoint),
    pRef: big(reads.pRefX18, (v) => formatUsd18(v, 4), REASONS.checkpoint),
    // A zeroed `pMktX18` means the observation ring has not covered the window; it is not a price.
    pMkt:
      reads.pMktX18 === undefined
        ? missing(REASONS.checkpoint)
        : reads.pMktX18 === 0n
          ? missing(REASONS.twap)
          : value(formatUsd18(reads.pMktX18, 4)),
    premium: big(premiumX18, formatPremiumX18, REASONS.checkpoint),
    totalAssets: big(reads.totalAssetsUsd18, (v) => formatUsd18(v)),
    inventoryAmps: big(reads.inventoryAmps, (v) => `${formatAmount(v, 18)} AMPS`),
    totalSupply: big(reads.totalSupply, (v) => `${formatAmount(v, 18)} AMPS`),
    liveCells: num(reads.liveCells, String),
    assetCount: num(reads.assetCount, String),
    rolloutRate: num(reads.rolloutBpsPerDay, (v) => `${formatBps(v)} per day`),
    rolloutRateMax: num(reads.rolloutBpsPerDayMax, (v) => `${formatBps(v)} per day`),
    entryFloor: num(reads.entryFloorBps, formatBps),
    refUpRate: num(reads.refUpRateBps, (v) => `${formatBps(v)} per hour`),
    refDivergence: num(reads.refDivergenceBps, formatBps),
    twapWindow: num(reads.twapWindow, formatDuration),
    ladderDoublings: num(reads.ladderDoublings, String),
    ladderTilt: big(reads.ladderTiltX18, (v) => Number(formatUnits(v, 18)).toFixed(2)),
    spokeSeed: num(reads.spokeSeedBps, formatBps),
    vaultInitialized:
      reads.initialized === undefined ? missing(REASONS.chain) : value(reads.initialized ? 'Yes' : 'No'),

    // --- Bonds ------------------------------------------------------------------------------
    bondVest: num(reads.bondVestSeconds, formatDuration),
    bondVestBand: band(reads.bondVestBand, formatDuration),
    bondEpoch: num(reads.bondEpochSeconds, formatDuration),
    bondMinAccretion: num(reads.bondMinAccretionBps, formatBps),
    bondDailyCap: num(reads.bondDailyCapBps, formatBps),
    bondDiscountBand: band(reads.bondDiscountBand, formatBps),
    bondMarkets: num(reads.bondMarketCount, String),
    bondIssuedToday: reads.bondIssuedToday
      ? value(
          `${formatAmount(reads.bondIssuedToday.issued, 18)} / ${formatAmount(reads.bondIssuedToday.capacity, 18)} AMPS`,
        )
      : missing(REASONS.chain),

    // --- Registry ---------------------------------------------------------------------------
    poolCount: num(reads.poolCount, String),
    constituentCount: num(reads.constituentCount, String),
    activeConstituentCount: num(reads.activeConstituentCount, String),
    indexCap: num(reads.indexCapBps, formatBps),
    indexFloor: num(reads.indexFloorBps, formatBps),
    maxConstituents: num(reads.maxConstituents, String),

    // --- Deployment addresses ---------------------------------------------------------------
    addrAmps: address(deployment.amps, REASONS.deployment),
    addrVault: address(deployment.vault, REASONS.deployment),
    addrQuoter: address(deployment.quoter, REASONS.deployment),
    addrBonds: address(deployment.bonds, REASONS.deployment),
    addrBondsLens: address(deployment.bondsLens, REASONS.deployment),
    addrRouter: address(deployment.router, REASONS.deployment),
    addrRegistry: address(deployment.registry, REASONS.deployment),
    addrRegistryLens: address(deployment.registryLens, REASONS.deployment),
    addrHook: address(deployment.hook, REASONS.deployment),
    addrOracleGate: address(deployment.oracleGate, REASONS.deployment),
    addrTimelock: address(deployment.timelock, REASONS.deployment),
    addrGenesis: address(deployment.genesis, REASONS.deployment),

    // --- Reference addresses ----------------------------------------------------------------
    refPoolManager: book ? value(book.poolManager) : missing(REASONS.config),
    refUniversalRouter: book ? value(book.universalRouter) : missing(REASONS.config),
    refPermit2: book ? value(book.permit2) : missing(REASONS.config),
    refWeth9: book ? value(book.weth9) : missing(REASONS.config),
    refUsdg: book ? value(book.usdg) : missing(REASONS.config),
    refUsdc: book ? value(book.usdc) : missing(REASONS.config),
    refAcross: book ? value(book.acrossSpokePool) : missing(REASONS.config),
    refStockBeacon: book ? value(book.stockTokenBeacon) : missing(REASONS.config),

    // --- Genesis auction --------------------------------------------------------------------
    auctionUsdgAddress: address(auctionAddresses.usdg, REASONS.deployment),
    auctionEthAddress: address(auctionAddresses.eth, REASONS.deployment),
    auctionUsdgPhase: auctionPhaseFigure('usdg'),
    auctionEthPhase: auctionPhaseFigure('eth'),
    auctionUsdgClearing: auctionPriceFigure('usdg'),
    auctionEthClearing: auctionPriceFigure('eth'),
    auctionUsdgRaised: auctionRaisedFigure('usdg'),
    auctionEthRaised: auctionRaisedFigure('eth'),
    auctionUsdgSupply: auctionSupplyFigure('usdg'),
    auctionEthSupply: auctionSupplyFigure('eth'),
    auctionUsdgGraduated: auctionGraduatedFigure('usdg'),
    auctionEthGraduated: auctionGraduatedFigure('eth'),
    ccaLens: value(CCA_LENS_ADDRESS),

    // --- The genesis adapter ------------------------------------------------------------------
    genesisPhase: genesis?.phase === undefined ? missing(REASONS.chain) : value(genesis.phase),
    genesisSettled:
      genesis?.settled === undefined ? missing(REASONS.chain) : value(genesis.settled ? 'Yes' : 'Not yet'),
    genesisP0: settledOnly(genesis?.p0X18, (v) => formatUsd18(v, 6)),
    genesisRaised: settledOnly(genesis?.raisedUsd18, (v) => formatUsd18(v)),
    genesisRaisedUsdg:
      genesis?.settled !== true || genesis.raisedUsdg === undefined || genesis.usdgDecimals === undefined
        ? missing(genesisReason)
        : value(`${formatAmount(genesis.raisedUsdg, genesis.usdgDecimals)} USDG`),
    genesisRaisedWeth: settledOnly(genesis?.raisedWeth, (v) => `${formatAmount(v, 18)} WETH`),
    genesisUnsold: settledOnly(genesis?.unsoldAmps, (v) => `${formatAmount(v, 18)} AMPS`),
    genesisFloorUsdg: big(genesis?.floorUsdgX18, (v) => `${formatUsd18(v, 6)} per AMPS`),
    genesisFloorEth: big(genesis?.floorEthX18, (v) => `${formatUnits(v, 18)} ETH per AMPS`),
    genesisEthUsd:
      genesis?.ethUsdX18 === undefined || genesis.ethUsdX18 === 0n
        ? missing(REASONS.chain)
        : value(formatUsd18(genesis.ethUsdX18, 2)),
    genesisNav: settledOnly(genesis?.navPerShareX18, (v) => formatUsd18(v, 4)),
    genesisPremium:
      genesis?.settled !== true || genesisPremiumX18 === undefined
        ? missing(genesisReason)
        : value(formatPremiumX18(genesisPremiumX18)),

    // --- Launch parameters ------------------------------------------------------------------
    cfgChain: chain ? value(chain.name) : missing(REASONS.config),
    cfgChainId: chain ? value(String(chain.id)) : missing(REASONS.config),
    cfgS0: value(`${formatAmount(launchParameters.supply.s0, 18)} AMPS`),
    cfgTeamTranche: value(`${formatAmount(launchParameters.supply.teamWei, 18)} AMPS`),
    cfgAuctionTranche: value(`${formatAmount(launchParameters.auction.totalWei, 18)} AMPS`),
    cfgAuctionUsdgTranche: value(`${formatAmount(launchParameters.auction.usdgWei, 18)} AMPS`),
    cfgAuctionEthTranche: value(`${formatAmount(launchParameters.auction.ethWei, 18)} AMPS`),
    cfgAuctionFloor: value(`$${launchParameters.auction.floorPriceUsd.toFixed(2)} per AMPS`),
    cfgPolTranche: value(`${formatAmount(launchParameters.supply.polWei, 18)} AMPS`),
    cfgEntryPoolAsks: value(`${formatAmount(launchParameters.supply.entryPoolWeiEach, 18)} AMPS`),
    cfgSpokeSeedAmps: value(`${formatAmount(launchParameters.supply.perSpokeSeedWei, 18)} AMPS`),
    cfgNavAtFloor: value(`$${launchParameters.auction.navPerShareAtFloorUsd.toFixed(2)}`),
    cfgPremiumAtFloor: value(formatBps(launchParameters.auction.premiumAtFloorBps)),
    cfgGraduationPerLeg: value(`$${launchParameters.auction.terms.graduationUsdPerLeg.toLocaleString('en-US')}`),
    cfgNavAtGraduation: value(`$${launchParameters.auction.graduationMinimum.navPerShareUsd.toFixed(2)}`),
    cfgPremiumAtGraduation: value(formatBps(launchParameters.auction.graduationMinimum.premiumBps)),
    cfgAuctionStartDelay: value(`${launchParameters.auction.terms.startDelayHours} hours`),
    cfgAuctionDuration: value(`${launchParameters.auction.terms.durationHours} hours`),
    cfgAuctionClaimDelay: value(`${launchParameters.auction.terms.claimDelayHours} hours`),
    cfgAuctionTickSpacing: value(formatBps(launchParameters.auction.terms.tickSpacingBps)),
    cfgAuctionValidationHook: value(
      launchParameters.auction.terms.validationHook === 'none' ? 'None' : launchParameters.auction.terms.validationHook,
    ),
    cfgFallbackLaunchPrice: value(`$${launchParameters.fallbackSeed.launchPriceUsd.toFixed(2)} per AMPS`),
    cfgFallbackSeed: value(
      `$${launchParameters.fallbackSeed.totalUsd.toLocaleString('en-US')} (${formatAmount(launchParameters.fallbackSeed.usdgRaw, 6)} USDG + ${formatAmount(launchParameters.fallbackSeed.wethWei, 18)} WETH)`,
    ),
    cfgTotalPools: value(String(launchParameters.pools.totalPools)),
    cfgSpokePools: value(String(launchParameters.pools.spokePools)),
    cfgEntryPools: value(String(launchParameters.pools.entryPools)),
    cfgTimelockFast: value(formatDuration(gov.timelockFastSeconds)),
    cfgTimelockSlow: value(formatDuration(gov.timelockSlowSeconds)),
    cfgTimelockStandby: value(formatDuration(gov.timelockStandbySeconds)),
    cfgGuardianFreeze: value(formatDuration(gov.guardianFreezeExpirySeconds)),
    cfgProposer: value(`${gov.proposerThreshold.n} of ${gov.proposerThreshold.of}`),
    cfgGuardian: value(`${gov.guardianThreshold.n} of ${gov.guardianThreshold.of}`),
    cfgLaunchConstituents: value(String(launchConstituents.length)),
    cfgHookFlags: value(launchParameters.pools.hookFlags),
  }

  // The catalogue is the contract: a figure added there without a branch here would silently print
  // nothing, so fill any gap with an explicit unavailable rather than `undefined`.
  for (const id of FIGURE_IDS) {
    if (resolved[id] === undefined) resolved[id] = missing(REASONS.chain)
  }
  return resolved
}
