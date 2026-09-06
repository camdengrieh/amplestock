// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'
import {chains} from '@amplestocks/config'
import {ConfigError, defaultRpcUrl, defaultWsUrl, loadConfig, KNOWN_CHAIN_IDS} from '../src/config.js'

const BASE = {
  AMPS_TOKEN_ADDRESS: '0x00000000000000000000000000000000000000a1',
  AMPS_SENDER_ADDRESS: '0x00000000000000000000000000000000000000e0',
  AMPS_SUBMITTER: 'local',
  AMPS_PRIVATE_KEY: `0x${'11'.repeat(32)}`,
} as NodeJS.ProcessEnv

describe('endpoints are configuration, never literals', () => {
  it('takes both chains’ RPC and websocket from @amplestocks/config', () => {
    expect(defaultRpcUrl(chains.mainnet.id)).toBe(chains.mainnet.rpcUrls.http[0])
    expect(defaultWsUrl(chains.mainnet.id)).toBe(chains.mainnet.rpcUrls.webSocket[0])
    expect(defaultRpcUrl(chains.testnet.id)).toBe(chains.testnet.rpcUrls.http[0])
    expect(defaultWsUrl(chains.testnet.id)).toBe(chains.testnet.rpcUrls.webSocket[0])
    expect(KNOWN_CHAIN_IDS).toEqual([4663, 46630])
  })

  it('defaults to the testnet and its endpoint', () => {
    const config = loadConfig({...BASE})
    expect(config.chainId).toBe(chains.testnet.id)
    expect(config.rpcUrl).toBe(chains.testnet.rpcUrls.http[0])
  })

  it('an unknown chain must be given an RPC explicitly', () => {
    expect(() => loadConfig({...BASE, AMPS_CHAIN_ID: '31337'})).toThrow(ConfigError)
    const local = loadConfig({...BASE, AMPS_CHAIN_ID: '31337', AMPS_RPC_URL: 'http://127.0.0.1:8545'})
    expect(local.rpcUrl).toBe('http://127.0.0.1:8545')
  })

  it('no source file hardcodes an endpoint in a code path', async () => {
    const {readFileSync, readdirSync, statSync} = await import('node:fs')
    const {join} = await import('node:path')
    const walk = (dir: string): string[] =>
      readdirSync(dir).flatMap((entry) => {
        const full = join(dir, entry)
        return statSync(full).isDirectory() ? walk(full) : full.endsWith('.ts') ? [full] : []
      })
    for (const file of walk(new URL('../src', import.meta.url).pathname)) {
      const body = readFileSync(file, 'utf8')
      // Comments may quote an endpoint; code may not.
      const code = body
        .split('\n')
        .filter((line) => !/^\s*(\*|\/\/)/.test(line))
        .join('\n')
      expect(code, file).not.toContain('rpc.mainnet.chain.robinhood.com')
      expect(code, file).not.toContain('robinhood-rpc.publicnode.com')
    }
  })
})

describe('the submitter choice', () => {
  it('defaults to the relayer and demands its three settings', () => {
    expect(() => loadConfig({AMPS_TOKEN_ADDRESS: BASE.AMPS_TOKEN_ADDRESS, AMPS_SENDER_ADDRESS: BASE.AMPS_SENDER_ADDRESS})).toThrow(
      /AMPS_RELAYER_URL/,
    )
    const config = loadConfig({
      ...BASE,
      AMPS_SUBMITTER: 'relayer',
      AMPS_RELAYER_URL: 'http://relayer:8080',
      AMPS_RELAYER_ID: 'amps-keeper',
      AMPS_RELAYER_API_KEY: 'secret',
    })
    expect(config.submitter).toBe('relayer')
    expect(config.relayer?.relayerId).toBe('amps-keeper')
  })

  it('the local signer is the fallback and needs a key', () => {
    expect(() => loadConfig({...BASE, AMPS_PRIVATE_KEY: ''})).toThrow(/AMPS_PRIVATE_KEY/)
    expect(loadConfig({...BASE}).submitter).toBe('local')
  })

  it('rejects a malformed address rather than starting against nothing', () => {
    expect(() => loadConfig({...BASE, AMPS_TOKEN_ADDRESS: 'nope'})).toThrow(/AMPS_TOKEN_ADDRESS/)
  })
})

describe('the policy', () => {
  it('starts at the Constants.sol values', () => {
    const {policy} = loadConfig({...BASE})
    expect(policy.placementCooldownSeconds).toBe(60)
    expect(policy.placementDivergenceTicks).toBe(800)
    expect(policy.maxLiveCells).toBe(512)
    expect(policy.checkpointMaxAgeSeconds).toBe(1800)
    expect(policy.allowRefDiverged).toBe(false)
    expect(policy.runUnpaid).toBe(false)
  })

  it('is overridable end to end', () => {
    const {policy, ethUsd18} = loadConfig({
      ...BASE,
      AMPS_ALLOW_REF_DIVERGED: 'true',
      AMPS_CHOST_USD18: '5000000000000000000',
      AMPS_SCAN_INTERVAL_SECONDS: '5',
      AMPS_ETH_USD18: '2500000000000000000000',
    })
    expect(policy.allowRefDiverged).toBe(true)
    expect(policy.chostOverrideUsd18).toBe(5n * 10n ** 18n)
    expect(policy.scanIntervalSeconds).toBe(5)
    expect(ethUsd18).toBe(2_500n * 10n ** 18n)
  })
})
