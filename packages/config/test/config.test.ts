// SPDX-License-Identifier: MIT
/**
 * Run with: pnpm --filter @amplestocks/config test
 *
 * Node 22 strips the types natively, so there is no test-runner build step.
 */
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {dirname, join} from 'node:path'
import {test} from 'node:test'
import {fileURLToPath} from 'node:url'

import {getAddress, isAddress} from 'viem'

import * as config from '../src/index.ts'

const here = dirname(fileURLToPath(import.meta.url))
const launchJsonPath = join(here, '..', 'launch.json')

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/

interface Found {
  readonly path: string
  readonly value: string
}

/** Every 40-hex string anywhere in `node`, with the path it was found at. */
function collectAddressLike(node: unknown, path: string, out: Found[]): void {
  if (typeof node === 'string') {
    if (ADDRESS_RE.test(node)) out.push({path, value: node})
    return
  }
  if (Array.isArray(node)) {
    node.forEach((child, i) => collectAddressLike(child, `${path}[${i}]`, out))
    return
  }
  if (node !== null && typeof node === 'object') {
    for (const [key, child] of Object.entries(node)) {
      collectAddressLike(child, path === '' ? key : `${path}.${key}`, out)
    }
  }
}

test('every address exported by @amplestocks/config is EIP-55 checksummed', () => {
  const found: Found[] = []
  collectAddressLike(config.launchJsonSource, '', found)

  assert.ok(found.length > 0, 'expected the config module to contain at least one address')

  const wrong = found.filter((f) => f.value !== getAddress(f.value))
  assert.deepEqual(
    wrong.map((f) => `${f.path}: ${f.value} should be ${getAddress(f.value)}`),
    [],
    'found non-checksummed addresses',
  )

  for (const f of found) {
    assert.ok(isAddress(f.value, {strict: true}), `${f.path}: ${f.value} is not a valid address`)
  }
})

test('every address in launch.json is EIP-55 checksummed', () => {
  const mirror: unknown = JSON.parse(readFileSync(launchJsonPath, 'utf8'))
  const found: Found[] = []
  collectAddressLike(mirror, '', found)

  assert.ok(found.length > 0, 'expected launch.json to contain at least one address')
  const wrong = found.filter((f) => f.value !== getAddress(f.value))
  assert.deepEqual(wrong.map((f) => `${f.path}: ${f.value}`), [], 'found non-checksummed addresses in launch.json')
})

test('launch.json is an exact mirror of the typed exports', () => {
  const mirror: unknown = JSON.parse(readFileSync(launchJsonPath, 'utf8'))
  const expected: unknown = JSON.parse(JSON.stringify(config.launchJsonSource, config.jsonReplacer))
  assert.deepEqual(
    mirror,
    expected,
    'launch.json has drifted from src/index.ts — run `pnpm --filter @amplestocks/config gen:json`',
  )
})

test('no address is duplicated across distinct roles', () => {
  const found: Found[] = []
  collectAddressLike(config.addresses, '', found)
  const seen = new Map<string, string>()
  for (const f of found) {
    const prior = seen.get(f.value.toLowerCase())
    assert.equal(prior, undefined, `${f.value} appears as both ${prior} and ${f.path}`)
    seen.set(f.value.toLowerCase(), f.path)
  }
})

test('the launch set is the 30 names the plan confirmed', () => {
  const expected = [
    'AAPL', 'AMD', 'AMZN', 'ASML', 'BABA', 'CLSK', 'COIN', 'CRCL', 'CRWV', 'DELL',
    'GME', 'GOOGL', 'INTC', 'IONQ', 'META', 'MSFT', 'MSTR', 'MU', 'NBIS', 'NVDA',
    'ORCL', 'PLTR', 'RGTI', 'RKLB', 'SNDK', 'SPCX', 'TSLA', 'TSM', 'SPY', 'QQQ',
  ]
  assert.equal(config.launchConstituents.length, config.LAUNCH_CONSTITUENT_COUNT)
  assert.equal(config.launchConstituents.length, 30)
  assert.deepEqual([...config.launchSymbols].sort(), [...expected].sort())
  assert.equal(new Set(config.launchSymbols).size, 30, 'duplicate ticker in the launch set')
})

test('CRWD is a test fixture, not a launch constituent', () => {
  assert.equal(config.testFixtures.CRWD.inLaunchSet, false)
  assert.equal(config.testFixtures.CRWD.multiplier, 4)
  assert.ok(!config.launchSymbols.includes('CRWD'), 'CRWD must not be in the launch set')
})

test('the `verify` flag is set exactly when a token or feed is missing', () => {
  for (const c of config.launchConstituents) {
    const complete = c.token !== null && c.feed !== null
    assert.equal(c.verify, !complete, `${c.symbol}: verify flag does not match token/feed completeness`)
  }
})

test('supply arithmetic matches the revision-7 genesis split', () => {
  const s = config.launchParameters.supply
  assert.equal(s.teamAmps + s.auctionAmps + s.polAmps, s.s0Amps, '5% team + 50% auction + 45% POL must equal S0')
  assert.equal(s.teamWei + s.auctionWei + s.polWei, s.s0, 'wei split must equal S0 exactly')
  // The three tranches are `Constants.sol` figures, and `genesisMint` refuses any other allocation.
  assert.equal(s.s0Amps, 20_000)
  assert.equal(s.teamAmps, 1_000)
  assert.equal(s.auctionAmps, 10_000)
  assert.equal(s.polAmps, 9_000)
  assert.equal(s.perSpokeSeedAmps * s.spokeCount, s.spokeSeedTotalAmps, '90 x 30 = 2,700')
  assert.equal(s.perSpokeSeedWei * BigInt(s.spokeCount), 2_700n * 10n ** 18n)
  assert.equal(s.entryPoolAmpsEach * 2, s.entryPoolTotalAmps, 'two entry pools at 3,150 each')
  assert.equal(s.spokeSeedTotalAmps + s.entryPoolTotalAmps, s.polAmps, '2,700 + 6,300 = 9,000 POL')
  assert.equal(s.entryPoolWeiEach * 2n + s.perSpokeSeedWei * BigInt(s.spokeCount), s.polWei)
  // `spokeSeedBps` is 100 bp of the POL tranche, and 90 is exactly that.
  assert.equal(s.perSpokeSeedAmps, (s.polAmps * 100) / 10_000)
})

/** `P0 / NAV - 1`, in bps, derived rather than written down twice. */
const premiumBps = (p0Usd: number, navUsd: number): number => Math.round((p0Usd / navUsd - 1) * 10_000)

test('the auction sells half of S0 in two legs at a $1.00 floor', () => {
  const a = config.launchParameters.auction
  const s = config.launchParameters.supply
  assert.equal(a.usdgAmps + a.ethAmps, a.totalAmps, 'the two legs must be the whole tranche')
  assert.equal(a.usdgWei + a.ethWei, a.totalWei)
  assert.equal(a.usdgAmps, a.ethAmps, 'the legs are sized 50/50')
  assert.equal(a.totalAmps, s.auctionAmps, 'the auction block and the supply block must agree')
  assert.equal(a.totalAmps * 2, s.s0Amps, 'half the supply is sold')
  assert.equal(a.legs, 2)
  assert.equal(a.floorPriceUsd, 1.0)
  assert.equal(a.raisedAtFloorUsd, a.totalAmps * a.floorPriceUsd)
})

test('NAV per share at launch divides by the WHOLE supply, inventory included', () => {
  const a = config.launchParameters.auction
  const s = config.launchParameters.supply
  // Decision 14 stands: the divisor is `S0`, which is what `AmpsVault._checkpoint` divides by.
  // The 9,000-AMPS POL tranche counts, and is backed by nothing until it sells — which is exactly
  // what the premium below discloses.
  assert.equal(a.navPerShareAtFloorUsd, a.raisedAtFloorUsd / s.s0Amps)
  assert.equal(a.navPerShareAtFloorUsd, 0.5)
  assert.equal(a.premiumAtFloorBps, premiumBps(a.floorPriceUsd, a.navPerShareAtFloorUsd))
  assert.equal(a.premiumAtFloorBps, 10_000)
})

test('the graduation minimum is about half the floor raise, and prices out at a higher premium', () => {
  const a = config.launchParameters.auction
  const g = a.graduationMinimum
  const s = config.launchParameters.supply
  assert.equal(g.raisedUsd, a.terms.graduationUsdPerLeg * a.legs, '2,500 a leg, both legs')
  assert.equal(g.soldAmps, g.raisedUsd / a.floorPriceUsd, 'at the floor, a dollar buys an AMPS')
  assert.equal(g.navPerShareUsd, g.raisedUsd / s.s0Amps, 'the same S0 divides a half-sized raise')
  assert.equal(g.navPerShareUsd, 0.25)
  // Half the raise against the whole supply is a *higher* premium, not a lower one.
  assert.equal(g.premiumBps, premiumBps(a.floorPriceUsd, g.navPerShareUsd))
  assert.equal(g.premiumBps, 30_000)
  assert.ok(g.premiumBps > a.premiumAtFloorBps, 'a smaller raise discloses a larger premium')
})

test('the auction terms are the recommended set the operator actually sets', () => {
  const t = config.launchParameters.auction.terms
  assert.equal(t.factory, 'canonical')
  assert.ok(isAddress(t.factoryAddress), 'the factory address must be an address')
  assert.equal(getAddress(t.factoryAddress), t.factoryAddress, 'and EIP-55 checksummed')
  assert.equal(t.startDelayHours, 24)
  assert.equal(t.durationHours, 72)
  assert.equal(t.claimDelayHours, 0)
  assert.equal(t.tickSpacingBps, 100, '1% of the floor of each leg')
  assert.equal(t.graduationUsdPerLeg, 2_500)
  assert.equal(t.graduationUsdgRaw, 2_500_000_000n, '2,500 USDG at 6 decimals')
  // No on-chain validation hook: the dApp's geo-block is a front-end control and binds no contract.
  assert.equal(t.validationHook, 'none')
  assert.equal(t.schedule, 'flat, increasing tail')
})

test('the founders seed survives only as the non-graduation fallback', () => {
  const seed = config.launchParameters.fallbackSeed
  const s = config.launchParameters.supply
  assert.equal('seed' in config.launchParameters, false, 'launchParameters.seed must not exist any more')
  assert.equal(seed.ethUsd + seed.usdgUsd, seed.totalUsd)
  assert.equal(seed.ethUsd, seed.usdgUsd, 'the fallback seed is 50/50')
  assert.equal(seed.launchPriceUsd, 1.0)
  // $20,000 against 20,000 AMPS fully diluted is NAV/share $1.00 — the pre-revision-7 launch,
  // scaled to the new S0 — so P0 and NAV are the same number and the premium is exactly zero.
  assert.equal(seed.totalUsd / s.s0Amps, seed.launchPriceUsd)
  assert.equal(seed.premiumBps, premiumBps(seed.launchPriceUsd, seed.totalUsd / s.s0Amps))
  assert.equal(seed.premiumBps, 0)
  assert.equal(seed.usdgRaw, 10_000_000_000n, '10,000 USDG at 6 decimals')
  assert.equal(seed.wethWei, 4n * 10n ** 18n, '4 WETH')
  // The tranche returns to the vault as inventory; nobody is named to receive it.
  assert.equal('seedRecipient' in seed, false, 'there is no seedRecipient on this path')
})

test('every start value sits inside its hard band', () => {
  const p = config.launchParameters
  const inBand = (v: number, b: {min: number; max: number}, what: string): void => {
    assert.ok(v >= b.min && v <= b.max, `${what}: ${v} outside [${b.min}, ${b.max}]`)
  }
  inBand(p.fees.ampsFeeBps, p.fees.ampsFeeBpsBand, 'ampsFeeBps')
  inBand(p.fees.buyFeeBpsEntry, p.fees.buyFeeBpsEntryBand, 'buyFeeBpsEntry')
  inBand(p.fees.buyFeeBpsSpoke, p.fees.buyFeeBpsSpokeBand, 'buyFeeBpsSpoke')
  inBand(p.fees.buyFeeBpsSpokeHighVol, p.fees.buyFeeBpsSpokeBand, 'buyFeeBpsSpokeHighVol')
  assert.ok(p.fees.redeemFeeBps <= p.fees.redeemFeeBpsCap, 'redeemFeeBps over cap')
  assert.ok(p.fees.creatorFeeBps <= p.fees.ampsFeeBps, 'creatorFeeBps over the AMPS fee it is carved out of')
  inBand(p.bonds.dBaseBps, p.bonds.discountBandBps, 'dBaseBps')
  inBand(p.bonds.dMinBps, p.bonds.discountBandBps, 'dMinBps')
  inBand(p.bonds.dMaxBps, p.bonds.discountBandBps, 'dMaxBps')
  assert.ok(p.bonds.dMinBps <= p.bonds.dBaseBps && p.bonds.dBaseBps <= p.bonds.dMaxBps, 'dMin <= dBase <= dMax')
  assert.ok(p.bonds.capBpsPerEpoch <= p.bonds.capBpsPerEpochCap, 'capBpsPerEpoch over cap')
  assert.ok(p.bonds.dailyCapBps <= p.bonds.dailyCapBpsCap, 'dailyCapBps over cap')
  inBand(p.bonds.epochSeconds, p.bonds.epochSecondsBand, 'epochSeconds')
  inBand(p.bonds.vestSeconds, p.bonds.vestSecondsBand, 'vestSeconds')
  for (const h of p.bonds.hSessionBps) inBand(h, p.bonds.hSessionBandBps, 'hSession')
  inBand(p.reference.refUpRateBps, p.reference.refUpRateBpsBand, 'refUpRateBps')
  inBand(p.ladder.ladderTilt, p.ladder.ladderTiltBand, 'ladderTilt')
  inBand(p.ladder.ladderDoublings, p.ladder.ladderDoublingsBand, 'ladderDoublings')
  inBand(p.ladder.seedHalvings, p.ladder.halvingsBand, 'seedHalvings')
  inBand(p.ladder.bondBidHalvings, p.ladder.halvingsBand, 'bondBidHalvings')
  assert.ok(p.rollout.rolloutBpsPerDay <= p.rollout.rolloutBpsPerDayCap, 'rolloutBpsPerDay over cap')
})

test('the fee model is revision 6: AMPS fee both ways, pass-through only, no staking', () => {
  const p = config.launchParameters
  const fees = p.fees as Record<string, unknown>

  // Staking is gone: no staker slice of a compound, and no burn share either — the AMPS-side
  // remainder is burned in full, so a governed `burnBps` would be a lever over nothing.
  assert.equal('staking' in p, false, 'launchParameters.staking must not exist')
  assert.equal('burnBps' in fees, false, 'fees.burnBps must not exist')
  assert.equal('burnBpsCap' in fees, false, 'fees.burnBpsCap must not exist')
  assert.equal('sellFeeBps' in fees, false, 'the sell fee was renamed ampsFeeBps')

  // The AMPS fee is charged both ways, so the pass-through fee a rotation hop pays must be
  // strictly cheaper than it — otherwise `AmpsRouter.rotate` would price a rotation as two exits.
  assert.equal(p.fees.ampsFeeBps, 500)
  assert.ok(p.fees.buyFeeBpsEntry < p.fees.ampsFeeBps, 'the pass-through entry fee must undercut the AMPS fee')
  assert.ok(p.fees.buyFeeBpsSpokeHighVol < p.fees.buyFeeBpsEntry, 'a spoke hop is cheaper than an entry hop')

  // The redemption floor sits between the two: dearer than a rotation hop, cheaper than a market exit.
  assert.equal(p.fees.redeemFeeBps, 250)
  assert.ok(p.fees.redeemFeeBps > p.fees.buyFeeBpsEntry && p.fees.redeemFeeBps < p.fees.ampsFeeBps)

  // 1% of volume, decaying to zero at 30 days: at launch that is 100/500 = one fifth of the fees
  // collected in *every* currency, which is what the vault divides by `ampsFeeBps` to reach.
  assert.equal(p.fees.creatorFeeBps, 100)
  assert.equal(p.fees.creatorFeeDecaySeconds, 30 * 24 * 60 * 60)
})

test('session haircuts are ordered Regular <= Pre-Post <= Overnight <= Closed', () => {
  const h = config.launchParameters.bonds
  assert.deepEqual([...h.hSessionBps], [h.hSession.regular, h.hSession.prePost, h.hSession.overnight, h.hSession.closed])
  assert.deepEqual([...h.hSessionBps], [0, 50, 150, 300])
  const sorted = [...h.hSessionBps].sort((a, b) => a - b)
  assert.deepEqual([...h.hSessionBps], sorted, 'haircuts must be non-decreasing by session illiquidity')
})

test('the pool set is 30 spokes + 2 entry pools on one hook', () => {
  const p = config.launchParameters.pools
  assert.equal(p.spokePools, config.LAUNCH_CONSTITUENT_COUNT)
  assert.equal(p.spokePools + p.entryPools, p.totalPools)
  assert.equal(p.totalPools, 32)
  assert.ok(p.spokePools <= p.maxConstituents, 'launch set exceeds MAX_CONSTITUENTS')
  // Decision 4: the cap is what the redemption gas budget proves, not a round number.
  // MAX_LIVE_CELLS / cells-per-pool - the two entry pools = 512 / 14 - 2 = 34.
  assert.equal(p.maxConstituents, 34)
  assert.equal(p.spokePools + p.entryPools, 32, 'the launch shape sits well inside the cap')
})

test('chain ids and endpoints are the ones the plan verified', () => {
  assert.equal(config.chains.mainnet.id, 4663)
  assert.equal(config.chains.testnet.id, 46630)
  assert.equal(config.chainById[4663], config.chains.mainnet)
  assert.equal(config.chainById[46630], config.chains.testnet)
  for (const chain of [config.chains.mainnet, config.chains.testnet]) {
    for (const url of chain.rpcUrls.http) assert.ok(url.startsWith('https://'), url)
    for (const url of chain.rpcUrls.webSocket) assert.ok(url.startsWith('wss://'), url)
    for (const e of chain.blockExplorers) assert.ok(e.url.startsWith('https://'), e.url)
    // EIP-7702 is live on ArbOS 61: tx.origin guards are worthless and must never be used.
    assert.equal(chain.eip7702, true)
    assert.equal(chain.eip1153, true)
    assert.equal(chain.evmVersion, 'cancun')
  }
})

test('the orphaned SDK UniversalRouter is recorded and flagged unusable', () => {
  const book = config.addresses[4663]
  assert.notEqual(book.universalRouter, book.universalRouterOrphanedSdk)
  assert.equal(config.addressNotes.universalRouterOrphanedSdk.verified, false)
  assert.equal(config.addressNotes.create2Factory.verified, false, 'CREATE2 factory must stay flagged unverified')
})
