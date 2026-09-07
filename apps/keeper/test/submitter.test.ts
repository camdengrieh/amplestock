// SPDX-License-Identifier: MIT
import {describe, expect, it, vi} from 'vitest'
import {RelayerSubmitter} from '../src/chain/submitter.js'
import {createLogger} from '../src/logger.js'
import type {RelayerConfig} from '../src/config.js'
import type {PublicClient} from 'viem'

const RELAYER: RelayerConfig = {
  url: 'http://relayer:8080/',
  relayerId: 'amps-keeper',
  apiKey: 'secret-token',
  speed: 'fast',
  timeoutMs: 1_000,
}

const SENDER = '0x00000000000000000000000000000000000000e0' as const
const VAULT = '0x00000000000000000000000000000000000000a0' as const
const HASH = `0x${'ab'.repeat(32)}` as const

function silent() {
  return createLogger({}, {sink: () => undefined})
}

function fakeClient(status: 'success' | 'reverted' = 'success', gasUsed = 1_500_000n): PublicClient {
  return {
    waitForTransactionReceipt: async () => ({status, gasUsed}),
  } as unknown as PublicClient
}

describe('the OpenZeppelin Relayer submitter', () => {
  it('POSTs to the relayer’s transaction endpoint with bearer auth and the job key', async () => {
    const fetchImpl = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      expect(String(url)).toBe('http://relayer:8080/api/v1/relayers/amps-keeper/transactions')
      const headers = init?.headers as Record<string, string>
      expect(headers.authorization).toBe('Bearer secret-token')
      const body = JSON.parse(String(init?.body)) as Record<string, unknown>
      expect(body.to).toBe(VAULT)
      expect(body.data).toBe('0xdeadbeef')
      expect(body.gas_limit).toBe(2_000_000)
      expect(body.speed).toBe('fast')
      expect(body.metadata).toEqual({job: 'compound:0xpool', source: 'amplestocks-keeper'})
      return new Response(JSON.stringify({data: {id: 'tx-1', status: 'pending', hash: HASH}}), {status: 200})
    })

    const submitter = new RelayerSubmitter(RELAYER, SENDER, fakeClient(), silent(), fetchImpl as unknown as typeof fetch)
    const submission = await submitter.submit({
      to: VAULT,
      data: '0xdeadbeef',
      gasLimit: 2_000_000n,
      jobKey: 'compound:0xpool',
    })
    expect(submission).toEqual({id: 'tx-1', hash: HASH})
    expect(fetchImpl).toHaveBeenCalledOnce()
  })

  it('holds no key: the sender is configuration, and nothing is signed here', () => {
    const submitter = new RelayerSubmitter(RELAYER, SENDER, fakeClient(), silent(), fetch)
    expect(submitter.kind).toBe('relayer')
    expect(submitter.sender).toBe(SENDER)
  })

  it('surfaces an HTTP rejection with the job named, so the metric has a cause', async () => {
    const fetchImpl = vi.fn(async () => new Response('nonce too low', {status: 400}))
    const submitter = new RelayerSubmitter(RELAYER, SENDER, fakeClient(), silent(), fetchImpl as unknown as typeof fetch)
    await expect(
      submitter.submit({to: VAULT, data: '0x00', gasLimit: 1n, jobKey: 'rollout:3'}),
    ).rejects.toThrow(/rollout:3.*HTTP 400.*nonce too low/s)
  })

  it('polls for a hash when the relayer accepts before assigning one', async () => {
    let call = 0
    const fetchImpl = vi.fn(async (url: string | URL | Request) => {
      call += 1
      if (String(url).endsWith('/transactions')) {
        return new Response(JSON.stringify({data: {id: 'tx-2', status: 'pending'}}), {status: 200})
      }
      expect(String(url)).toBe('http://relayer:8080/api/v1/relayers/amps-keeper/transactions/tx-2')
      return new Response(JSON.stringify({data: {id: 'tx-2', status: 'submitted', hash: HASH}}), {status: 200})
    })

    const submitter = new RelayerSubmitter(RELAYER, SENDER, fakeClient(), silent(), fetchImpl as unknown as typeof fetch)
    const submission = await submitter.submit({to: VAULT, data: '0x00', gasLimit: 1n, jobKey: 'touch:'})
    expect(submission.hash).toBeNull()
    const receipt = await submitter.wait(submission)
    expect(receipt).toEqual({hash: HASH, success: true, gasUsed: 1_500_000n})
    expect(call).toBeGreaterThanOrEqual(2)
  })

  it('treats a relayer-side failure as an error rather than a silent drop', async () => {
    const fetchImpl = vi.fn(async (url: string | URL | Request) =>
      String(url).endsWith('/transactions')
        ? new Response(JSON.stringify({data: {id: 'tx-3', status: 'pending'}}), {status: 200})
        : new Response(JSON.stringify({data: {id: 'tx-3', status: 'failed'}}), {status: 200}),
    )
    const submitter = new RelayerSubmitter(RELAYER, SENDER, fakeClient(), silent(), fetchImpl as unknown as typeof fetch)
    const submission = await submitter.submit({to: VAULT, data: '0x00', gasLimit: 1n, jobKey: 'touch:'})
    await expect(submitter.wait(submission)).rejects.toThrow(/ended failed/)
  })

  it('reports an on-chain revert as an unsuccessful receipt, not as a throw', async () => {
    const fetchImpl = vi.fn(
      async () => new Response(JSON.stringify({data: {id: 'tx-4', hash: HASH}}), {status: 200}),
    )
    const submitter = new RelayerSubmitter(
      RELAYER,
      SENDER,
      fakeClient('reverted', 21_000n),
      silent(),
      fetchImpl as unknown as typeof fetch,
    )
    const submission = await submitter.submit({to: VAULT, data: '0x00', gasLimit: 1n, jobKey: 'compound:0x1'})
    await expect(submitter.wait(submission)).resolves.toEqual({hash: HASH, success: false, gasUsed: 21_000n})
  })
})
