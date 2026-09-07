// SPDX-License-Identifier: MIT

/**
 * The small pure modules: `bytes32` short strings, the action classifier, the denylist calldata
 * decoder, the alert sink, the flywheel arithmetic, ids and configuration resolution.
 */

import {encodeFunctionData, toFunctionSelector} from 'viem'
import {describe, expect, it, vi} from 'vitest'

import {BLOCK_ACCOUNTS_SELECTOR, UNBLOCK_ACCOUNTS_SELECTOR, stockTokenAbi} from '../src/abi/external'
import {ENV_OVERRIDES, ZERO_ADDRESS, resolveAddresses, unresolved} from '../src/config/addresses'
import {readEnv} from '../src/config/env'
import {denylistWatchList, poolIdFilter} from '../src/config/pools'
import {decodeAddressArray} from '../src/handlers/denylist'
import {classifyAction, functionNameOf, isKeeperJob, selectorOf} from '../src/lib/actions'
import {noopSink, serialiseAlert, setAlertSink, webhookSink, deliver} from '../src/lib/alerts'
import {decodeBytes32String} from '../src/lib/bytes32'
import {annualisedBps, ampsToUsd18, realisedLvrAmps, stakingAprBps} from '../src/lib/flywheel'
import {cellKey, creditKey, dayKey, dayStart, eventId, jobId, positionKey} from '../src/lib/ids'

const WAD = 10n ** 18n
const pad = (s: string) => `0x${Buffer.from(s, 'utf8').toString('hex').padEnd(64, '0')}` as `0x${string}`

describe('bytes32 short strings', () => {
  it('decodes the reasons the vault packs', () => {
    expect(decodeBytes32String(pad('compound'))).toBe('compound')
    expect(decodeBytes32String(pad('buyback'))).toBe('buyback')
    expect(decodeBytes32String(pad('spokeSeed'))).toBe('spokeSeed')
  })

  it('decodes the empty word as an empty string', () => {
    expect(decodeBytes32String(`0x${'00'.repeat(32)}`)).toBe('')
  })

  it('returns the raw hex when the word is not a left-aligned short string', () => {
    const hashed = `0x${'ff'.repeat(32)}` as `0x${string}`
    expect(decodeBytes32String(hashed)).toBe(hashed)
    // A zero in the middle followed by data is not a short string either.
    const broken = `0x${'61'.repeat(4)}00${'62'.repeat(27)}` as `0x${string}`
    expect(decodeBytes32String(broken)).toBe(broken)
  })
})

describe('action classification', () => {
  it('extracts a four-byte selector and ignores a bare transfer', () => {
    expect(selectorOf('0xdeadbeef00' as `0x${string}`)).toBe('0xdeadbeef')
    expect(selectorOf('0x' as `0x${string}`)).toBeUndefined()
    expect(selectorOf(undefined)).toBeUndefined()
  })

  it('names a vault function from its selector', () => {
    // `checkpoint()` takes no arguments, so its selector is stable and easy to state.
    expect(functionNameOf(toFunctionSelector('checkpoint()'))).toBe('checkpoint')
    expect(functionNameOf(toFunctionSelector('compound(bytes32)'))).toBe('compound')
    expect(functionNameOf(toFunctionSelector('rollout(uint16)'))).toBe('rollout')
    expect(functionNameOf('0x00000000')).toBeUndefined()
  })

  it('classifies by selector when the call went straight to the vault', () => {
    expect(classifyAction(toFunctionSelector('compound(bytes32)'))).toBe('compound')
    expect(classifyAction(toFunctionSelector('rollout(uint16)'))).toBe('rollout')
    expect(classifyAction(toFunctionSelector('deployBonded(uint16)'))).toBe('bonded')
    expect(classifyAction(toFunctionSelector('redeemProRata(uint256,address)'))).toBe('redeem')
  })

  it('falls back to the shape of the events when the selector is not ours', () => {
    expect(classifyAction('0xdeadbeef', {hasCompound: true})).toBe('compound')
    expect(classifyAction('0xdeadbeef', {hasGenesis: true})).toBe('genesis')
    expect(classifyAction('0xdeadbeef', {hasEntryWithdrawal: true, hasSpokeAskPlacement: true})).toBe('rollout')
    expect(classifyAction('0xdeadbeef', {hasBidPlacement: true})).toBe('bonded')
    expect(classifyAction('0xdeadbeef')).toBe('unknown')
  })

  it('knows which actions are keeper jobs', () => {
    expect(isKeeperJob('compound')).toBe(true)
    expect(isKeeperJob('rollout')).toBe(true)
    expect(isKeeperJob('redeem')).toBe(false)
    expect(isKeeperJob('unknown')).toBe(false)
  })
})

describe('the denylist selector and calldata', () => {
  it('pins blockAccounts(address[]) at 0x6abf7081', () => {
    expect(toFunctionSelector('blockAccounts(address[])')).toBe(BLOCK_ACCOUNTS_SELECTOR)
    expect(toFunctionSelector('unblockAccounts(address[])')).toBe(UNBLOCK_ACCOUNTS_SELECTOR)
  })

  it('mirrors the IStockToken read surface', () => {
    const names = stockTokenAbi.map((f) => f.name).sort()
    expect(names).toEqual([
      'balanceOf',
      'decimals',
      'effectiveAt',
      'isBlocked',
      'newUIMultiplier',
      'oraclePaused',
      'paused',
      'symbol',
      'uiMultiplier',
    ])
  })

  it('decodes the address array a blockAccounts call carries', () => {
    const accounts = [
      '0x00000000000000000000000000000000000000a1',
      '0x00000000000000000000000000000000000000a2',
    ] as `0x${string}`[]
    const data = encodeFunctionData({
      abi: [
        {
          type: 'function',
          name: 'blockAccounts',
          stateMutability: 'nonpayable',
          inputs: [{name: 'accounts', type: 'address[]'}],
          outputs: [],
        },
      ],
      functionName: 'blockAccounts',
      args: [accounts],
    })
    expect(decodeAddressArray(data).map((a) => a.toLowerCase())).toEqual(accounts)
  })

  it('returns nothing for calldata that is not an address array', () => {
    expect(decodeAddressArray('0x6abf7081')).toEqual([])
    expect(decodeAddressArray(`0x6abf7081${'ff'.repeat(64)}`)).toEqual([])
  })
})

describe('alerts', () => {
  it('records but does not deliver by default', async () => {
    const previous = setAlertSink(noopSink)
    const result = await deliver({
      kind: 'denylist',
      severity: 'critical',
      subject: 'x',
      message: 'y',
      blockNumber: 1n,
      timestamp: 2n,
      detail: {},
    })
    expect(result.delivered).toBe(false)
    setAlertSink(previous)
  })

  it('renders bigints as decimal strings on the wire', () => {
    const body = serialiseAlert({
      kind: 'reconciliation',
      severity: 'warning',
      subject: '1',
      message: 'm',
      blockNumber: 12n,
      timestamp: 34n,
      detail: {nav: 10n ** 18n},
    })
    expect(JSON.parse(body).detail.nav).toBe('1000000000000000000')
    expect(JSON.parse(body).blockNumber).toBe('12')
  })

  it('reports a webhook failure instead of throwing', async () => {
    const fetchMock = vi.fn(async () => new Response('nope', {status: 500}))
    vi.stubGlobal('fetch', fetchMock)
    const sink = webhookSink('http://127.0.0.1:1/hook', 100)
    const result = await sink({
      kind: 'denylist',
      severity: 'critical',
      subject: 'x',
      message: 'y',
      blockNumber: 1n,
      timestamp: 2n,
      detail: {},
    })
    expect(result.delivered).toBe(false)
    expect(result.error).toBe('HTTP 500')
    vi.unstubAllGlobals()
  })

  it('reports a delivered webhook', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('ok', {status: 200})))
    const sink = webhookSink('http://127.0.0.1:1/hook', 100)
    const result = await sink({
      kind: 'denylist',
      severity: 'critical',
      subject: 'x',
      message: 'y',
      blockNumber: 1n,
      timestamp: 2n,
      detail: {},
    })
    expect(result.delivered).toBe(true)
    vi.unstubAllGlobals()
  })
})

describe('flywheel arithmetic', () => {
  it('marks a sell against the post-swap price', () => {
    // 100 AMPS in (1 AMPS of fee), 99 USDG out, post-swap price 1 USDG per AMPS.
    const lvr = realisedLvrAmps({
      sell: true,
      amountIn: 100n * WAD,
      amountOut: 99n * 10n ** 6n,
      feeAmount: 1n * WAD,
      counterDecimals: 6,
      priceX18: WAD,
    })
    // The pool received 99 AMPS net and paid out 99 USDG worth 99 AMPS: no loss.
    expect(lvr).toBe(0n)
  })

  it('is positive when the pool sold the counter too cheaply for the new price', () => {
    const lvr = realisedLvrAmps({
      sell: true,
      amountIn: 100n * WAD,
      amountOut: 110n * 10n ** 6n,
      feeAmount: 0n,
      counterDecimals: 6,
      priceX18: WAD,
    })
    expect(lvr).toBe(10n * WAD)
  })

  it('is negative on a price-improving trade, and is not clamped', () => {
    const lvr = realisedLvrAmps({
      sell: true,
      amountIn: 100n * WAD,
      amountOut: 90n * 10n ** 6n,
      feeAmount: 0n,
      counterDecimals: 6,
      priceX18: WAD,
    })
    expect(lvr).toBe(-10n * WAD)
  })

  it('is zero when there is no price to mark against', () => {
    expect(
      realisedLvrAmps({
        sell: true,
        amountIn: 1n,
        amountOut: 1n,
        feeAmount: 0n,
        counterDecimals: 6,
        priceX18: 0n,
      }),
    ).toBe(0n)
  })

  it('prices an AMPS amount at P_ref', () => {
    expect(ampsToUsd18(100n * WAD, (WAD * 3n) / 2n)).toBe(150n * WAD)
  })

  it('annualises a realised amount and never divides by zero', () => {
    // 1 unit earned on 100 of capital over a day is 365% a year.
    expect(annualisedBps(1n, 100n, 86_400n)).toBe(36_500)
    expect(annualisedBps(1n, 0n, 86_400n)).toBe(0)
    expect(annualisedBps(1n, 100n, 0n)).toBe(0)
    expect(stakingAprBps(0n, 100n, 86_400n)).toBe(0)
  })
})

describe('ids', () => {
  it('sorts lexically in chain order', () => {
    const a = eventId(9n, 1)
    const b = eventId(10n, 0)
    expect(a < b).toBe(true)
    expect(eventId(1n, 2)).toBe('000000000001-000002')
  })

  it('builds the composite keys the schema uses', () => {
    expect(cellKey('0xAB', -6960)).toBe('0xab--6960')
    expect(creditKey('0xTX' as `0x${string}`, '0xAB')).toBe('0xtx-0xab')
    expect(positionKey('0xAA', 3n)).toBe('0xaa-3')
    expect(jobId(5n, 'shares')).toBe('000000000005-shares')
    expect(jobId(5n, 'multiplier', 7)).toBe('000000000005-multiplier-7')
  })

  it('floors a timestamp to UTC midnight', () => {
    expect(dayStart(86_400n + 3_600n)).toBe(86_400n)
    expect(dayKey(3, 86_400n + 1n)).toBe('3-86400')
  })
})

describe('configuration', () => {
  it('prefers the environment over the deployments file over the reference book', () => {
    const book = resolveAddresses({
      chainId: 4663,
      env: {AMPS_VAULT: '0x00000000000000000000000000000000000000a1'} as NodeJS.ProcessEnv,
      deployments: {core: {vault: '0x00000000000000000000000000000000000000b1', bonds: '0x00000000000000000000000000000000000000b2'}},
    })
    expect(book.vault.toLowerCase()).toBe('0x00000000000000000000000000000000000000a1')
    expect(book.bonds.toLowerCase()).toBe('0x00000000000000000000000000000000000000b2')
    // The PoolManager is chain infrastructure, so the reference book supplies it on 4663.
    expect(book.poolManager).not.toBe(ZERO_ADDRESS)
  })

  it('leaves an unknown address as the zero address rather than dropping the source', () => {
    const book = resolveAddresses({chainId: 31337, env: {} as NodeJS.ProcessEnv, deployments: {}})
    expect(book.vault).toBe(ZERO_ADDRESS)
    expect(unresolved(book)).toContain('vault')
    expect(Object.keys(book).sort()).toEqual(Object.keys(ENV_OVERRIDES).sort())
  })

  it('refuses a deployments file for a different chain', () => {
    expect(() =>
      resolveAddresses({chainId: 31337, env: {} as NodeJS.ProcessEnv, deployments: {chainId: 4663}}),
    ).toThrow(/chain 4663/)
  })

  it('rejects a malformed address instead of indexing the wrong contract', () => {
    expect(() =>
      resolveAddresses({chainId: 31337, env: {AMPS_VAULT: 'not-an-address'} as NodeJS.ProcessEnv, deployments: {}}),
    ).toThrow(/not an address/)
  })

  it('reads the pool-id filter from the environment and de-duplicates it', () => {
    const id = `0x${'11'.repeat(32)}`
    expect(poolIdFilter({AMPS_POOL_IDS: `${id},${id}`} as NodeJS.ProcessEnv)).toEqual([id])
    expect(poolIdFilter({} as NodeJS.ProcessEnv)).toEqual([])
    expect(() => poolIdFilter({AMPS_POOL_IDS: '0x1234'} as NodeJS.ProcessEnv)).toThrow(/pool id/)
  })

  it('never hands Ponder an empty denylist watch list', () => {
    const book = resolveAddresses({chainId: 31337, env: {} as NodeJS.ProcessEnv, deployments: {}})
    expect(denylistWatchList(book, {} as NodeJS.ProcessEnv)).toEqual([ZERO_ADDRESS])
    expect(
      denylistWatchList(book, {AMPS_DENYLIST_WATCH: '0x00000000000000000000000000000000000000e1'} as NodeJS.ProcessEnv),
    ).toHaveLength(1)
  })

  it('uses PGlite unless DATABASE_URL is present', () => {
    expect(readEnv({} as NodeJS.ProcessEnv).databaseUrl).toBeUndefined()
    expect(readEnv({DATABASE_URL: 'postgres://x'} as NodeJS.ProcessEnv).databaseUrl).toBe('postgres://x')
    expect(
      readEnv({DATABASE_URL: 'postgres://x', DATABASE_PRIVATE_URL: 'postgres://y'} as NodeJS.ProcessEnv).databaseUrl,
    ).toBe('postgres://y')
  })

  it('defaults the dust bound to 2 bp, the same budget R1 allows a compound', () => {
    const env = readEnv({} as NodeJS.ProcessEnv)
    expect(env.dustBps).toBe(2)
    expect(env.dustWei).toBe(10n ** 12n)
  })
})
