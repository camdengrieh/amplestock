// SPDX-License-Identifier: MIT
import {AMPS_MAINNET_CHAIN_ID, AMPS_TESTNET_CHAIN_ID} from '@amplestocks/config'
import {describe, expect, it} from 'vitest'

import {
  deploymentReady,
  explorerAddressUrl,
  explorerTxUrl,
  hasAnyGenesisAuction,
  isDeployed,
  readDeployment,
  readGenesisAuctions,
  referenceBook,
} from '@/lib/deployment'

const VALID = '0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99'

describe('readDeployment', () => {
  it('drops anything that is not an address rather than keeping a zero', () => {
    const record = readDeployment({vault: VALID, quoter: 'not-an-address', registry: '', bonds: '0x0'} as never)
    expect(record.vault).toBe(VALID)
    expect(record.quoter).toBeUndefined()
    expect(record.registry).toBeUndefined()
    expect(record.bonds).toBeUndefined()
  })

  it('reports a contract as not deployed rather than reading the zero address', () => {
    const record = readDeployment({vault: VALID} as never)
    expect(isDeployed('vault', record)).toBe(true)
    expect(isDeployed('quoter', record)).toBe(false)
    expect(deploymentReady(record)).toBe(false)
  })

  it('is ready only when every contract the read path needs is present', () => {
    const record = readDeployment({vault: VALID, quoter: VALID, registry: VALID} as never)
    expect(deploymentReady(record)).toBe(true)
  })

  it('carries the genesis adapter as an ordinary contract, and does not require it for reads', () => {
    // `AmpsGenesis` is ours and has a generated ABI, so it is a deployment key like any other —
    // unlike the two auctions, which are Uniswap's and are kept apart. But it is one-shot, so a
    // deployment without it is a launched protocol, not a broken one.
    const record = readDeployment({vault: VALID, quoter: VALID, registry: VALID, genesis: VALID} as never)
    expect(record.genesis).toBe(VALID)
    expect(isDeployed('genesis', record)).toBe(true)
    expect(deploymentReady(readDeployment({vault: VALID, quoter: VALID, registry: VALID} as never))).toBe(true)
  })
})

describe('the genesis auctions', () => {
  it('are read separately from the protocol contracts', () => {
    const auctions = readGenesisAuctions({usdg: VALID, eth: 'not-an-address'} as never)
    expect(auctions.usdg).toBe(VALID)
    expect(auctions.eth).toBeUndefined()
    expect(hasAnyGenesisAuction(auctions)).toBe(true)
    expect(hasAnyGenesisAuction(readGenesisAuctions({usdg: '', eth: ''} as never))).toBe(false)
  })
})

describe('referenceBook', () => {
  it('serves the 4663 address book', () => {
    const book = referenceBook(AMPS_MAINNET_CHAIN_ID)
    expect(book?.universalRouter).toBe(VALID)
    expect(book?.weth9).toBeDefined()
    expect(book?.permit2).toBeDefined()
  })

  it('refuses to borrow mainnet’s book for the testnet', () => {
    // A half-filled testnet book invites a deploy against the wrong PoolManager, so
    // `@amplestocks/config` deliberately has none and this must not invent one.
    expect(referenceBook(AMPS_TESTNET_CHAIN_ID)).toBeNull()
  })
})

describe('explorer links', () => {
  it('builds transaction and address links from the chain metadata', () => {
    expect(explorerTxUrl(AMPS_MAINNET_CHAIN_ID, '0xabc')).toBe('https://robinhoodchain.blockscout.com/tx/0xabc')
    expect(explorerAddressUrl(AMPS_TESTNET_CHAIN_ID, VALID)).toBe(
      `https://explorer.testnet.chain.robinhood.com/address/${VALID}`,
    )
  })
})
