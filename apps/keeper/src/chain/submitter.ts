// SPDX-License-Identifier: MIT

/**
 * How a decided job actually reaches the chain.
 *
 * Two implementations behind one interface:
 *
 *  * {@link RelayerSubmitter} — the production path: a **self-hosted OpenZeppelin Relayer**. The keeper holds
 *    no key at all; it POSTs a transaction request and polls for the hash. Nonce management, replacement and
 *    gas bumping are the relayer's job, which is the whole reason for using one: two keeper instances behind
 *    one relayer cannot produce a nonce collision, and the plan's exit criterion "a second operator instance
 *    runs from a clean checkout" is then a configuration change rather than a coordination problem.
 *  * {@link LocalSignerSubmitter} — the fallback, and **only** for anvil and the chain suite. It signs locally
 *    with a private key from the environment.
 *
 * Both return the same {@link Submission}, so `runner.ts` never learns which one it has.
 *
 * The relayer's HTTP shape is configurable because self-hosted deployments differ; the defaults follow
 * openzeppelin-relayer's v1 REST API (`POST /api/v1/relayers/{id}/transactions`, bearer auth, a `data` envelope
 * carrying `{id, status, hash}`). `docs/keeper-runbook.md` records what to change if the deployment differs.
 */

import {createWalletClient, http, type Account, type Hex, type PublicClient} from 'viem'
import {privateKeyToAccount} from 'viem/accounts'
import type {KeeperConfig, RelayerConfig} from '../config.js'
import type {Logger} from '../logger.js'
import {resolveChain} from './clients.js'

/** One transaction the keeper wants sent. */
export interface TxRequest {
  readonly to: `0x${string}`
  readonly data: Hex
  readonly gasLimit: bigint
  /** `<kind>:<target>`, carried through to the relayer so a duplicate is visible in its own logs. */
  readonly jobKey: string
}

/** What a submitter reports back. `hash` may be null while the relayer is still assigning one. */
export interface Submission {
  readonly id: string
  readonly hash: `0x${string}` | null
}

export interface Submitter {
  readonly kind: 'relayer' | 'local'
  /** The address transactions come from, which is also the address simulations are run as. */
  readonly sender: `0x${string}`
  submit(request: TxRequest): Promise<Submission>
  /** Resolves once the transaction is mined, or rejects. */
  wait(submission: Submission): Promise<{hash: `0x${string}`; success: boolean; gasUsed: bigint}>
}

// ---------------------------------------------------------------------------------------------------------------
// OpenZeppelin Relayer
// ---------------------------------------------------------------------------------------------------------------

interface RelayerTransactionResponse {
  readonly data?: {readonly id?: string; readonly status?: string; readonly hash?: string}
  readonly id?: string
  readonly status?: string
  readonly hash?: string
}

export class RelayerSubmitter implements Submitter {
  readonly kind = 'relayer' as const
  readonly sender: `0x${string}`

  private readonly config: RelayerConfig
  private readonly client: PublicClient
  private readonly logger: Logger
  private readonly fetchImpl: typeof fetch

  constructor(
    config: RelayerConfig,
    sender: `0x${string}`,
    client: PublicClient,
    logger: Logger,
    fetchImpl: typeof fetch = fetch,
  ) {
    this.config = config
    this.sender = sender
    this.client = client
    this.logger = logger
    this.fetchImpl = fetchImpl
  }

  private url(path: string): string {
    return `${this.config.url.replace(/\/$/, '')}/api/v1/relayers/${this.config.relayerId}${path}`
  }

  async submit(request: TxRequest): Promise<Submission> {
    const body = {
      to: request.to,
      value: '0x0',
      data: request.data,
      gas_limit: Number(request.gasLimit),
      speed: this.config.speed,
      // Echoed back in the relayer's own records; the keeper uses it to spot a duplicate it did not send.
      valid_until: null,
      metadata: {job: request.jobKey, source: 'amplestocks-keeper'},
    }

    const response = await this.fetchImpl(this.url('/transactions'), {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${this.config.apiKey}`,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(this.config.timeoutMs),
    })

    if (!response.ok) {
      const text = await response.text().catch(() => '')
      throw new Error(`relayer rejected ${request.jobKey}: HTTP ${response.status} ${text.slice(0, 512)}`)
    }

    const parsed = (await response.json()) as RelayerTransactionResponse
    const envelope = parsed.data ?? parsed
    const id = envelope.id
    if (id === undefined) throw new Error(`relayer response for ${request.jobKey} carried no transaction id`)
    const hash = envelope.hash !== undefined && envelope.hash.startsWith('0x') ? (envelope.hash as `0x${string}`) : null
    this.logger.debug('relayer accepted', {job: request.jobKey, id, hash})
    return {id, hash}
  }

  async wait(submission: Submission): Promise<{hash: `0x${string}`; success: boolean; gasUsed: bigint}> {
    const deadline = Date.now() + this.config.timeoutMs * 10
    let hash = submission.hash

    while (hash === null && Date.now() < deadline) {
      const response = await this.fetchImpl(this.url(`/transactions/${submission.id}`), {
        headers: {authorization: `Bearer ${this.config.apiKey}`},
        signal: AbortSignal.timeout(this.config.timeoutMs),
      })
      if (response.ok) {
        const parsed = (await response.json()) as RelayerTransactionResponse
        const envelope = parsed.data ?? parsed
        if (envelope.hash !== undefined && envelope.hash.startsWith('0x')) hash = envelope.hash as `0x${string}`
        if (envelope.status === 'failed' || envelope.status === 'cancelled' || envelope.status === 'expired') {
          throw new Error(`relayer transaction ${submission.id} ended ${envelope.status}`)
        }
      }
      if (hash === null) await new Promise((resolve) => setTimeout(resolve, 1_000))
    }

    if (hash === null) throw new Error(`relayer transaction ${submission.id} never produced a hash`)
    const receipt = await this.client.waitForTransactionReceipt({hash})
    return {hash, success: receipt.status === 'success', gasUsed: receipt.gasUsed}
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Local signer (anvil only)
// ---------------------------------------------------------------------------------------------------------------

export class LocalSignerSubmitter implements Submitter {
  readonly kind = 'local' as const
  readonly sender: `0x${string}`

  private readonly account: Account
  private readonly client: PublicClient
  private readonly wallet: ReturnType<typeof createWalletClient>

  constructor(config: KeeperConfig, client: PublicClient) {
    if (config.privateKey === null) throw new Error('LocalSignerSubmitter needs AMPS_PRIVATE_KEY')
    this.account = privateKeyToAccount(config.privateKey)
    this.sender = this.account.address
    this.client = client
    this.wallet = createWalletClient({
      account: this.account,
      chain: resolveChain(config),
      transport: http(config.rpcUrl),
    })
  }

  async submit(request: TxRequest): Promise<Submission> {
    const hash = await this.wallet.sendTransaction({
      account: this.account,
      chain: null,
      to: request.to,
      data: request.data,
      gas: request.gasLimit,
      value: 0n,
    })
    return {id: hash, hash}
  }

  async wait(submission: Submission): Promise<{hash: `0x${string}`; success: boolean; gasUsed: bigint}> {
    if (submission.hash === null) throw new Error('local submitter always has a hash')
    const receipt = await this.client.waitForTransactionReceipt({hash: submission.hash})
    return {hash: submission.hash, success: receipt.status === 'success', gasUsed: receipt.gasUsed}
  }
}

/** Builds whichever submitter the configuration asks for. */
export function createSubmitter(config: KeeperConfig, client: PublicClient, logger: Logger): Submitter {
  if (config.submitter === 'local') return new LocalSignerSubmitter(config, client)
  if (config.relayer === null) throw new Error('AMPS_SUBMITTER=relayer needs the relayer configuration')
  return new RelayerSubmitter(config.relayer, config.senderAddress, client, logger)
}
