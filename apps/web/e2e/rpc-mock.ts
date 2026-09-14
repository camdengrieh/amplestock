// SPDX-License-Identifier: MIT

/**
 * A JSON-RPC responder for the end-to-end run.
 *
 * Everything is offline: the app dials `RPC_URL`, Playwright intercepts the POST, and this answers
 * it. The answers are ABI-encoded properly rather than stubbed as opaque bytes, so viem's decoders
 * run for real and a struct whose field order drifted would fail the test rather than pass it.
 *
 * Two layers:
 *
 * - a **default** built from each function's own output types, so every read the app makes gets a
 *   well-formed answer without this file having to enumerate all of them;
 * - **fixtures** for the reads whose values the assertions care about.
 *
 * `aggregate3` is unwrapped and each inner call answered on its own, because wagmi batches through
 * Multicall3 whenever the chain declares one — and both Robinhood chains do.
 */
import {
  ampsAbi,
  ampsBondsAbi,
  ampsBondsLensAbi,
  ladderPositionValuerAbi,
  oracleGateAbi,
  poolRegistryAbi,
  poolRegistryLensAbi,
} from '@amplestocks/abis/generated'
import {
  decodeAbiParameters,
  decodeFunctionData,
  encodeAbiParameters,
  encodeFunctionResult,
  getAbiItem,
  parseAbiParameters,
  type Abi,
  type AbiParameter,
  type Hex,
} from 'viem'

// The mock has to encode the exact struct the app will decode, so it reads the *same* ABIs the app
// does — `@amplestocks/abis`, generated from the revision-6 Foundry artefacts. A `PoolQuote`
// encoded from a different tuple would decode into a different one, silently.
import {
  ampsGenesisAbi,
  ampsHookAbi,
  ampsQuoterAbi,
  ampsRouterAbi,
  ampsVaultAbi,
} from '@amplestocks/abis/generated'

import {ccaAbi, chainlinkAggregatorAbi} from '../lib/abi/cca'
import {E2E, MULTICALL3} from './addresses'

const WAD = 10n ** 18n
const Q96 = 1n << 96n
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'
const POOL_WETH = `0x${'11'.repeat(32)}` as Hex
const POOL_USDG = `0x${'22'.repeat(32)}` as Hex
const POOL_NVDA = `0x${'33'.repeat(32)}` as Hex
const POOL_AAPL = `0x${'44'.repeat(32)}` as Hex

/** Reference assets, from the same book the app reads. */
const WETH9 = '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73'
const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168'
const NVDA = '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC'
const AAPL = '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9'
/** The USDG/USD aggregator `@amplestocks/config` names for 4663. */
const USDG_USD_FEED = '0x61B7e5650328764B076A108EFF5fa7282a1B9aD2'

const ABIS: Record<string, Abi> = {
  [E2E.amps.toLowerCase()]: ampsAbi as unknown as Abi,
  [E2E.vault.toLowerCase()]: ampsVaultAbi as unknown as Abi,
  [E2E.quoter.toLowerCase()]: ampsQuoterAbi as unknown as Abi,
  [E2E.bonds.toLowerCase()]: ampsBondsAbi as unknown as Abi,
  [E2E.bondsLens.toLowerCase()]: ampsBondsLensAbi as unknown as Abi,
  [E2E.router.toLowerCase()]: ampsRouterAbi as unknown as Abi,
  [E2E.hook.toLowerCase()]: ampsHookAbi as unknown as Abi,
  [E2E.auctionUsdg.toLowerCase()]: ccaAbi as unknown as Abi,
  [E2E.auctionEth.toLowerCase()]: ccaAbi as unknown as Abi,
  [E2E.genesis.toLowerCase()]: ampsGenesisAbi as unknown as Abi,
  // The auction currency is an ordinary ERC-20, and the surface asks it for its own symbol and
  // decimals rather than assuming either. `ampsAbi` is an ERC-20 superset, which is enough here.
  [USDG.toLowerCase()]: ampsAbi as unknown as Abi,
  [USDG_USD_FEED.toLowerCase()]: chainlinkAggregatorAbi as unknown as Abi,
  [E2E.registry.toLowerCase()]: poolRegistryAbi as unknown as Abi,
  [E2E.registryLens.toLowerCase()]: poolRegistryLensAbi as unknown as Abi,
  [E2E.oracleGate.toLowerCase()]: oracleGateAbi as unknown as Abi,
  // `LadderPositionValuer` has no environment slot: the app reads its address from the vault.
  [E2E.valuer.toLowerCase()]: ladderPositionValuerAbi as unknown as Abi,
}

function poolQuote(overrides: Record<string, unknown> = {}) {
  return {
    poolId: POOL_WETH,
    poolClass: 1,
    counter: WETH9,
    pMktX18: 1_150_000_000_000_000_000n,
    pRefX18: 1_120_000_000_000_000_000n,
    navPerShareX18: WAD,
    premiumX18: 120_000_000_000_000_000n,
    poolTick: 120,
    fairTick: 100,
    innerBandTicks: 200,
    outerRailTicks: 2_000,
    // Revision 6's four legs: an ordinary buy and an ordinary sell both pay `ampsFeeBps`; both
    // hops of a protocol-router rotation pay the pool's pass-through base.
    buyFeeBps: 30,
    ampsFeeBps: 500,
    buyFeePips: 50_000,
    sellFeePips: 50_000,
    passThroughBuyFeePips: 3_000,
    passThroughSellFeePips: 3_000,
    dynBps: 0,
    dynCapBps: 300,
    refuseSell: false,
    refuseBuy: false,
    bondQX18: 0n,
    bondDiscountBps: 0,
    bondCapacityLeft: 0n,
    bondOpen: false,
    gateState: 0,
    session: 0,
    feedStale: false,
    corporateFreeze: false,
    observationCoverage: 1_800,
    checkpointAge: 30,
    degraded: 0,
    tickSpacing: 60,
    ...overrides,
  }
}

const QUOTES = [
  poolQuote(),
  poolQuote({poolId: POOL_USDG, counter: USDG}),
  poolQuote({
    poolId: POOL_NVDA,
    counter: NVDA,
    poolClass: 2,
    buyFeeBps: 5,
    passThroughBuyFeePips: 500,
    passThroughSellFeePips: 500,
    bondQX18: 8n * WAD,
    bondDiscountBps: 1_250,
    bondCapacityLeft: 50n * WAD,
    bondOpen: true,
  }),
  poolQuote({
    poolId: POOL_AAPL,
    counter: AAPL,
    poolClass: 2,
    buyFeeBps: 5,
    passThroughBuyFeePips: 500,
    passThroughSellFeePips: 500,
    // One degraded pool, so the surfaces have to render an unavailable field somewhere.
    degraded: 0b100000,
    pMktX18: 0n,
  }),
]

const bondMarket = (marketId: number, collateral: string) => ({
  collateral,
  class: 0,
  open: true,
  decimals: 18,
  constituentId: marketId,
  dBaseBps: 1_250,
  dMinBps: 1_000,
  dMaxBps: 1_500,
  capBpsPerEpoch: 50,
  kWeightX18: 500_000_000_000_000_000n,
  kFillX18: 250_000_000_000_000_000n,
  epochStart: 1_800_000_000,
  lastBondAt: 1_800_000_000,
  issuedThisEpoch: 0n,
  totalIssued: 0n,
})

const FIXTURES: Record<string, Record<string, unknown>> = {
  [E2E.quoter.toLowerCase()]: {
    quoteAll: [QUOTES],
    quotePool: [QUOTES[0]],
    // Both hops at the pools' pass-through base (5 bp = 500 pips), and the credit hop 1 created.
    quoteRotation: [8n * WAD, 500, 500, 10n * WAD],
    bondQuote: [8n * WAD, 1_250, 50n * WAD, true, 0],
    quoteExactIn: [95n * WAD, 50_000, false, 0],
    wouldRevert: [false, `0x${'00'.repeat(32)}`, 0],
  },
  [E2E.vault.toLowerCase()]: {
    checkpointData: [{navPerShareX18: WAD, pRefX18: 1_120_000_000_000_000_000n, pMktX18: 1_150_000_000_000_000_000n, timestamp: 1_800_000_000, blockNumber: 12_345}],
    previewNavPerShareX18: [WAD],
    totalAssetsUsd18: [5_000n * WAD],
    inventoryAmps: [4_750n * WAD],
    // Released by an earlier redemption and draining to the sink on the 24-hour stream.
    pendingInventoryBurn: [12n * WAD],
    burnStreamStart: [1_799_996_400n],
    redeemFeeBps: [250],
    REDEEM_FEE_BPS_MAX: [500],
    CREATOR_FEE_BPS: [100],
    CREATOR_DECAY_SECONDS: [2_592_000n],
    genesisTimestamp: [1_800_000_000],
    S0: [20_000n * WAD],
    liveCells: [14],
    initialized: [true],
    rolloutBpsPerDay: [200],
    ROLLOUT_BPS_PER_DAY_MAX: [1_000],
    entryFloorBps: [3_000],
    refUpRateBps: [1_000],
    refDivergenceBps: [500],
    twapWindow: [1_800],
    spokeSeedBps: [100],
    ladderDoublings: [10],
    ladderTiltX18: [1_250_000_000_000_000_000n],
    assetCount: [3n],
    creator: ['0x00000000000000000000000000000000000c0001'],
    timelock: [E2E.timelock],
    guardian: ['0x00000000000000000000000000000000000c0002'],
    deployThresholdUsd18: [1_000n * WAD],
    ladderLength: [12n],
    previewRedeem: [[WETH9, USDG, NVDA], [990_000_000_000_000_000n, 1_980_000n, 2_970_000_000_000_000_000n], 2n * WAD],
    creatorBpsAt: [50],
    positionValuer: [E2E.valuer],
    lastPlacementAt: [1_800_000_000],
  },
  [E2E.valuer.toLowerCase()]: {
    amountsOf: [1_662n * WAD, 2n * WAD],
    referenceSqrtPriceX96: [79_228_162_514_264_337_593_543_950_336n],
  },
  [USDG.toLowerCase()]: {
    symbol: ['USDG'],
    decimals: [6],
    totalSupply: [1_000_000n * 10n ** 6n],
  },
  [USDG_USD_FEED.toLowerCase()]: {
    // A stablecoin is not a dollar: the auction's USD column is this answer, not an assumption.
    latestRoundData: [1n, 100_010_000n, 1_800_000_000n, 1_800_000_000n, 1n],
    decimals: [8],
  },
  [E2E.amps.toLowerCase()]: {
    totalSupply: [5_000n * WAD],
    balanceOf: [100n * WAD],
    decimals: [18],
    symbol: ['AMPS'],
  },
  [E2E.hook.toLowerCase()]: {
    // The AMPS fee, read straight from the hook: the base on both directions of every pool.
    ampsFeeBps: [500],
    AMPS_FEE_BPS_MIN: [100],
    AMPS_FEE_BPS_MAX: [600],
    TOTAL_FEE_BPS_MAX: [2_600],
    // The pass-through base — what a rotation hop pays, and nothing else.
    buyFeeBps: [30],
    // The router the hook honours. It matches the configured address, so Rotate shows no mismatch;
    // the mismatch path is covered by the component test instead, where it can be forced.
    router: [E2E.router],
  },
  [E2E.auctionUsdg.toLowerCase()]: {
    currency: [USDG],
    token: [E2E.amps],
    // Revision 7: each leg sells 5,000 AMPS — `Constants.AUCTION_USDG_SHARES`.
    totalSupply: [5_000n * WAD],
    startBlock: [12_000n],
    endBlock: [20_000n],
    claimBlock: [21_000n],
    // 1 USDG per AMPS on the Q96 grid, at the currency's own 6 decimals.
    clearingPrice: [(Q96 * 10n ** 6n) / WAD],
    floorPrice: [(Q96 * 10n ** 6n) / WAD],
    tickSpacing: [(Q96 * 10n ** 4n) / WAD],
    nextActiveTickPrice: [(Q96 * 11n * 10n ** 5n) / WAD],
    MAX_BID_PRICE: [(Q96 * 10n ** 8n) / WAD],
    currencyRaised: [5_000_000_000n],
    totalCleared: [4_000n * WAD],
    remainingSupply: [1_000n * WAD],
    isGraduated: [true],
    lastCheckpointedBlock: [12_340n],
    step: [{mps: 1_250, startBlock: 12_000n, endBlock: 20_000n}],
    latestCheckpoint: [
      {
        clearingPrice: (Q96 * 10n ** 6n) / WAD,
        currencyRaisedAtClearingPriceQ96X7: 0n,
        cumulativeMpsPerPrice: 0n,
        cumulativeMps: 7_500_000,
        prev: 12_000n,
        next: 0n,
      },
    ],
    // Both auctions pay into the adapter, never into the vault: it is `fundsRecipient` and
    // `tokensRecipient` of both legs and the only auction-side caller of `genesisPlace`.
    fundsRecipient: [E2E.genesis],
    tokensRecipient: [E2E.genesis],
    validationHook: [ZERO_ADDRESS],
    nextBidId: [3n],
    requiredDemandQ96: [500n * Q96],
    requiredDemandQ96AtNextActiveTick: [500n * Q96],
  },
  [E2E.auctionEth.toLowerCase()]: {
    currency: [ZERO_ADDRESS],
    token: [E2E.amps],
    totalSupply: [5_000n * WAD],
    startBlock: [12_000n],
    endBlock: [20_000n],
    claimBlock: [21_000n],
    clearingPrice: [Q96 / 2_500n],
    floorPrice: [Q96 / 2_500n],
    tickSpacing: [Q96 / 250_000n],
    nextActiveTickPrice: [Q96 / 2_400n],
    MAX_BID_PRICE: [Q96],
    currencyRaised: [2n * WAD],
    totalCleared: [4_000n * WAD],
    remainingSupply: [1_000n * WAD],
    isGraduated: [false],
    lastCheckpointedBlock: [12_340n],
    step: [{mps: 1_250, startBlock: 12_000n, endBlock: 20_000n}],
    fundsRecipient: [E2E.genesis],
    tokensRecipient: [E2E.genesis],
    validationHook: [ZERO_ADDRESS],
    nextBidId: [1n],
  },
  // The genesis adapter, mid-launch: both legs graduated, `settle()` has run, and the vault is
  // open at P0. The numbers are the ones the fixture's two auctions actually produced — 5,000 USDG
  // and 2 WETH at $2,500 is $10,000 against S0 = 20,000, so NAV/share is $0.50 and the premium is
  // exactly 100%. Nothing here is a round number chosen for the screenshot.
  [E2E.genesis.toLowerCase()]: {
    phase: [3],
    settled: [true],
    p0X18: [WAD],
    raisedUsdg: [5_000_000_000n],
    raisedWeth: [2n * WAD],
    raisedUsd18: [10_000n * WAD],
    unsoldAmps: [2_000n * WAD],
    ethUsdX18: [2_500n * WAD],
    floorUsdgQ96: [(Q96 * 10n ** 6n) / WAD],
    floorEthQ96: [(Q96 * WAD) / (2_500n * WAD)],
    usdgAuction: [E2E.auctionUsdg],
    ethAuction: [E2E.auctionEth],
    vault: [E2E.vault],
    amps: [E2E.amps],
    timelock: [E2E.timelock],
  },
  [E2E.bonds.toLowerCase()]: {
    vestSeconds: [43_200],
    epochSeconds: [21_600],
    minAccretionBps: [50],
    dailyCapBps: [200],
    VEST_SECONDS_MIN: [3_600],
    VEST_SECONDS_MAX: [604_800],
    DISCOUNT_BPS_MIN: [500],
    DISCOUNT_BPS_MAX: [2_500],
    MIN_ACCRETION_BPS_MAX: [500],
    CAP_BPS_PER_EPOCH_MAX: [200],
    DAILY_CAP_BPS_MAX: [500],
    hSessionBps: [0],
    dailyIssuance: [40n * WAD, 100n * WAD],
    quote: [8n * WAD, 8n * WAD, 1_250, false, 50n * WAD, `0x${'00'.repeat(32)}`],
    marketCount: [2],
  },
  [E2E.bondsLens.toLowerCase()]: {
    board: [
      [
        {
          marketId: 1,
          record: bondMarket(1, NVDA),
          ampsOut: 8n * WAD,
          qX18: 8n * WAD,
          discountBps: 1_250,
          floorBinding: false,
          capacityLeft: 50n * WAD,
          reason: `0x${'00'.repeat(32)}`,
        },
        {
          marketId: 2,
          record: {...bondMarket(2, AAPL), open: false},
          ampsOut: 0n,
          qX18: 0n,
          discountBps: 0,
          floorBinding: true,
          capacityLeft: 0n,
          reason: `0x${'00'.repeat(31)}01`,
        },
      ],
    ],
    positionsOf: [[{principal: 12n * WAD, claimed: 0n, start: 1_800_000_000, vestSeconds: 43_200, marketId: 1}]],
    positionTotals: [12n * WAD, 0n, 6n * WAD],
    unvested: [6n * WAD, 6n * WAD],
  },
  [E2E.registry.toLowerCase()]: {
    constituentCount: [2],
    activeConstituentCount: [2],
    poolCount: [4],
    indexCapBps: [5_000],
    indexFloorBps: [166],
    hubPoolId: [POOL_USDG],
    wethPoolId: [POOL_WETH],
    BUY_FEE_BPS_ENTRY_MIN: [5],
    BUY_FEE_BPS_ENTRY_MAX: [100],
    BUY_FEE_BPS_SPOKE_MIN: [1],
    BUY_FEE_BPS_SPOKE_MAX: [50],
    // Revision 8: what the redemption gas budget proves — 512 live cells / 14 per pool, less the
    // two entry pools.
    MAX_CONSTITUENTS: [34],
    // The realised weight, next to the registry's target. They differ on purpose: the rollout
    // moves inventory on a daily cap, so the two are never the same figure.
    currentWeightBps: [4_200],
    poolIdOf: [POOL_NVDA],
    constituent: [
      {
        token: NVDA,
        status: 1,
        decimals: 18,
        targetWeightBps: 5_000,
        rolloutWeightBps: 2_000,
        hSessionOverrideBps: 0,
        hSessionOverrideSet: false,
        caFreezeOverride: false,
        marketId: 1,
        feed: ZERO_ADDRESS,
        freezeUntil: 0,
        addedAt: 1_800_000_000,
        retiredAt: 0,
      },
    ],
    // The responder is argument-blind, so every pool answers with the same key. That is enough for
    // a smoke test, which asserts that the surface *has* a key rather than which one.
    poolKey: [
      {
        currency0: E2E.amps,
        currency1: WETH9,
        fee: 0x800000,
        tickSpacing: 60,
        hooks: E2E.hook,
      },
    ],
  },
  [E2E.registryLens.toLowerCase()]: {
    activeConstituents: [[1, 2]],
    indexWeights: [[1, 2], [5_000, 5_000], 10_000n],
    weightBoundsFor: [166, 5_000],
  },
}

/** A well-formed zero for any ABI output type, so an unfixtured read still decodes. */
function defaultFor(param: AbiParameter): unknown {
  const type = param.type
  if (type.endsWith('[]')) return []
  const fixedArray = /^(.*)\[(\d+)\]$/.exec(type)
  if (fixedArray) {
    const inner = {...param, type: fixedArray[1]!} as AbiParameter
    return Array.from({length: Number(fixedArray[2])}, () => defaultFor(inner))
  }
  if (type === 'address') return ZERO_ADDRESS
  if (type === 'bool') return false
  if (type === 'string') return ''
  if (type === 'bytes') return '0x'
  if (/^bytes\d+$/.test(type)) return `0x${'00'.repeat(Number(type.slice(5)))}`
  if (/^u?int\d*$/.test(type)) return 0n
  if (type === 'tuple') {
    const components = (param as {components?: readonly AbiParameter[]}).components ?? []
    const out: Record<string, unknown> = {}
    for (const component of components) out[component.name ?? ''] = defaultFor(component)
    return out
  }
  return 0n
}

function answer(to: string, data: Hex): Hex {
  const abi = ABIS[to.toLowerCase()]
  if (!abi) return '0x'
  let functionName: string
  try {
    functionName = decodeFunctionData({abi, data}).functionName
  } catch {
    return '0x'
  }
  const item = getAbiItem({abi, name: functionName}) as {outputs?: readonly AbiParameter[]} | undefined
  const outputs = item?.outputs ?? []
  const fixture = FIXTURES[to.toLowerCase()]?.[functionName] as unknown[] | undefined
  const values = fixture ?? outputs.map((output) => defaultFor(output))
  return encodeFunctionResult({abi, functionName, result: (outputs.length === 1 ? values[0] : values) as never})
}

const AGGREGATE3_IN = parseAbiParameters('(address target, bool allowFailure, bytes callData)[]')
const AGGREGATE3_OUT = parseAbiParameters('(bool success, bytes returnData)[]')

function decodeAggregate3(data: Hex): {target: string; allowFailure: boolean; callData: Hex}[] {
  // aggregate3((address target, bool allowFailure, bytes callData)[]) — selector 0x82ad56cb.
  const body = `0x${data.slice(10)}` as Hex
  const [calls] = decodeAbiParameters(AGGREGATE3_IN, body)
  return calls as unknown as {target: string; allowFailure: boolean; callData: Hex}[]
}

function handleCall(to: string, data: Hex): Hex {
  if (to.toLowerCase() === MULTICALL3.toLowerCase()) {
    const results = decodeAggregate3(data).map((call) => {
      try {
        const returnData = handleCall(call.target, call.callData)
        return {success: returnData !== '0x', returnData}
      } catch {
        return {success: false, returnData: '0x' as Hex}
      }
    })
    return encodeAbiParameters(AGGREGATE3_OUT, [results] as never)
  }
  return answer(to, data)
}

export interface JsonRpcRequest {
  id: number | string
  method: string
  params?: unknown[]
}

/** Answers one JSON-RPC request. Unknown methods get a benign default rather than an error. */
export function respond(request: JsonRpcRequest): {id: number | string; jsonrpc: '2.0'; result: unknown} {
  const base = {id: request.id, jsonrpc: '2.0' as const}
  switch (request.method) {
    case 'eth_chainId':
      return {...base, result: '0x1237'} // 4663
    case 'eth_blockNumber':
      return {...base, result: '0x3039'}
    case 'net_version':
      return {...base, result: '4663'}
    case 'eth_getBlockByNumber':
      return {
        ...base,
        result: {number: '0x3039', hash: `0x${'ab'.repeat(32)}`, timestamp: '0x6b49d200', baseFeePerGas: '0x1'},
      }
    case 'eth_call': {
      const [call] = (request.params ?? []) as [{to?: string; data?: Hex}]
      if (!call?.to || !call.data) return {...base, result: '0x'}
      try {
        return {...base, result: handleCall(call.to, call.data)}
      } catch {
        return {...base, result: '0x'}
      }
    }
    case 'eth_estimateGas':
      return {...base, result: '0x5208'}
    case 'eth_gasPrice':
      return {...base, result: '0x1'}
    case 'eth_getBalance':
      return {...base, result: '0x0'}
    default:
      return {...base, result: null}
  }
}

/** Handles a batched or single JSON-RPC body. */
export function respondToBody(body: unknown): unknown {
  if (Array.isArray(body)) return body.map((entry) => respond(entry as JsonRpcRequest))
  return respond(body as JsonRpcRequest)
}
