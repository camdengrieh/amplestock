// SPDX-License-Identifier: MIT

/**
 * The end-to-end harness: a local `anvil`, the Amplestocks system deployed onto it through
 * `test/contracts/AmpsE2E.s.sol`, and this indexer run over the result.
 *
 * Everything is localhost. Nothing here reaches the network, and the whole suite is skipped unless
 * `AMPS_E2E=1` so `pnpm test` stays offline and toolchain-free — which is what keeps CI's `node`
 * job green on a runner with no Foundry.
 *
 * Two details that are not obvious and that the harness has to handle:
 *
 * - **Foundry's nonce bookkeeping.** `forge script --broadcast` does not increment the
 *   broadcaster's nonce for `CALL` transactions issued from a `vm.startBroadcast` window opened
 *   inside a *nested* contract. `AmpsE2E` therefore drives every transaction from its own window
 *   and calls only the pure/view halves of the Phase 3 scripts; see the note on `_register`.
 * - **Ponder's finality window.** The historical sync ends at the chain's finalized block, which on
 *   a fresh `anvil` trails the head by about thirty blocks. The harness mines filler blocks past
 *   the last real transaction and indexes to a block inside the finalized range, so "the sync is
 *   complete" and "every event is indexed" mean the same thing.
 */

import {spawn, spawnSync, type ChildProcess} from 'node:child_process'
import {existsSync, mkdtempSync, rmSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import {fileURLToPath} from 'node:url'

const here = fileURLToPath(new URL('.', import.meta.url))
const appRoot = join(here, '..', '..')
const repoRoot = join(appRoot, '..', '..')
const contractsRoot = join(repoRoot, 'contracts')

/** Anvil's first account: the deployer, the timelock and the guardian all at once. */
export const DEPLOYER = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'
const DEPLOYER_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'

/**
 * 2026-09-09 14:00:00 UTC — a Wednesday, 10:00 ET, squarely inside `REGULAR`. Every gated vault
 * path refuses in a `CLOSED` session, so the whole run happens on a live trading clock, exactly as
 * `Phase3Scripts.t.sol` does.
 */
export const GENESIS_TIME = 1_788_962_400

/** Whether the suite can run at all: `AMPS_E2E=1` and a Foundry toolchain on disk. */
export function e2eEnabled(): boolean {
  return process.env.AMPS_E2E === '1' && foundryBin('anvil') !== undefined
}

/** The path to a Foundry binary, from `PATH` or from the sandbox's install. */
export function foundryBin(name: string): string | undefined {
  const explicit = process.env.FOUNDRY_BIN
  const candidates = [
    ...(explicit ? [join(explicit, name)] : []),
    join('/root/.foundry/bin', name),
    join(process.env.HOME ?? '', '.foundry', 'bin', name),
  ]
  for (const candidate of candidates) if (existsSync(candidate)) return candidate
  const which = spawnSync('sh', ['-c', `command -v ${name}`], {encoding: 'utf8'})
  const found = which.stdout.trim()
  return found === '' ? undefined : found
}

const run = (
  command: string,
  args: string[],
  options: {cwd?: string; env?: NodeJS.ProcessEnv; timeout?: number} = {},
): {code: number; stdout: string; stderr: string} => {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: {...process.env, ...options.env},
    encoding: 'utf8',
    timeout: options.timeout ?? 600_000,
    maxBuffer: 64 * 1024 * 1024,
  })
  return {code: result.status ?? -1, stdout: result.stdout ?? '', stderr: result.stderr ?? ''}
}

// -------------------------------------------------------------------------------------------------
// anvil
// -------------------------------------------------------------------------------------------------

export interface Anvil {
  url: string
  port: number
  stop(): void
}

/** Start `anvil` on a free-ish port with room for the vault's 20M-gas placements. */
export async function startAnvil(port: number): Promise<Anvil> {
  const bin = foundryBin('anvil')
  if (bin === undefined) throw new Error('[e2e] anvil not found')
  const child = spawn(
    bin,
    [
      '--port',
      String(port),
      '--gas-limit',
      '3000000000',
      '--code-size-limit',
      '200000',
      '--base-fee',
      '0',
      '--timestamp',
      String(GENESIS_TIME),
      '--silent',
    ],
    {stdio: 'ignore', detached: false},
  )
  const url = `http://127.0.0.1:${port}`
  const deadline = Date.now() + 30_000
  for (;;) {
    try {
      await rpc(url, 'eth_chainId', [])
      break
    } catch {
      if (Date.now() > deadline) {
        child.kill('SIGKILL')
        throw new Error('[e2e] anvil did not start')
      }
      await sleep(200)
    }
  }
  return {url, port, stop: () => child.kill('SIGKILL')}
}

export const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

export async function rpc<T = unknown>(url: string, method: string, params: unknown[]): Promise<T> {
  const response = await fetch(url, {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({jsonrpc: '2.0', id: 1, method, params}),
  })
  const body = (await response.json()) as {result?: T; error?: {message: string}}
  if (body.error) throw new Error(`[e2e] ${method}: ${body.error.message}`)
  return body.result as T
}

export const blockNumber = async (url: string): Promise<number> =>
  Number(await rpc<string>(url, 'eth_blockNumber', []))

/** Advance the clock and mine, which is how `anvil` moves time at all. */
export async function warp(url: string, seconds: number): Promise<void> {
  await rpc(url, 'evm_increaseTime', [seconds])
  await rpc(url, 'evm_mine', [])
}

export const mine = async (url: string, blocks: number): Promise<void> => {
  await rpc(url, 'anvil_mine', [`0x${blocks.toString(16)}`])
}

// -------------------------------------------------------------------------------------------------
// forge script
// -------------------------------------------------------------------------------------------------

/**
 * The compilation the fixture needs: the production `src/` and the Phase 3 `script/` as libraries,
 * with `AmpsE2E` itself compiled from `apps/indexer/test/contracts`. `FOUNDRY_TEST` is pointed at
 * the same directory so a work-in-progress file under `contracts/test/` — another agent's, on a
 * shared checkout — cannot break this build; the mocks it does need arrive through the import
 * graph.
 */
const forgeEnv = (): NodeJS.ProcessEnv => ({
  FOUNDRY_OUT: 'out-indexer',
  FOUNDRY_CACHE_PATH: 'cache-indexer',
  FOUNDRY_SCRIPT: '../apps/indexer/test/contracts',
  FOUNDRY_TEST: '../apps/indexer/test/contracts',
  FOUNDRY_REMAPPINGS: ['amps/=src/', 'ampsscript/=script/', 'ampstest/=test/'].join('\n'),
  AMPS_E2E_DEPLOYER: DEPLOYER,
})

/** Compile the fixture once. Returns the compiler's own output on failure. */
export function buildFixture(): void {
  const bin = foundryBin('forge')
  if (bin === undefined) throw new Error('[e2e] forge not found')
  const result = run(bin, ['build'], {cwd: contractsRoot, env: forgeEnv(), timeout: 900_000})
  if (result.code !== 0) {
    throw new Error(`[e2e] forge build failed:\n${result.stdout}\n${result.stderr}`)
  }
}

export interface StepResult {
  stdout: string
  addresses: Record<string, string>
}

/** Run one `AmpsE2E` entry point against the node, broadcasting for real. */
export function step(
  rpcUrl: string,
  signature: string,
  addresses: Record<string, string> = {},
): StepResult {
  const bin = foundryBin('forge')
  if (bin === undefined) throw new Error('[e2e] forge not found')
  const result = run(
    bin,
    [
      'script',
      'AmpsE2E',
      '--sig',
      signature,
      '--rpc-url',
      rpcUrl,
      '--broadcast',
      '--slow',
      '--private-key',
      DEPLOYER_KEY,
    ],
    {cwd: contractsRoot, env: {...forgeEnv(), ...toEnv(addresses)}, timeout: 900_000},
  )
  if (result.code !== 0 || !result.stdout.includes('ONCHAIN EXECUTION COMPLETE')) {
    throw new Error(`[e2e] step ${signature} failed:\n${tail(result.stdout)}\n${tail(result.stderr)}`)
  }
  return {stdout: result.stdout, addresses: {...addresses, ...parseAddresses(result.stdout)}}
}

const tail = (text: string, lines = 60) => text.split('\n').slice(-lines).join('\n')

/**
 * The address book the script prints. `contracts/foundry.toml` grants write access to `./gas` and
 * `./script/config` only, and this fixture must not touch either, so the transport is stdout.
 */
export function parseAddresses(stdout: string): Record<string, string> {
  const out: Record<string, string> = {}
  for (const line of stdout.split('\n')) {
    const marker = line.indexOf('AMPS_E2E_ADDRESSES')
    if (marker === -1) continue
    const brace = line.indexOf('{', marker)
    if (brace === -1) continue
    const body = line.slice(brace + 1).replace(/,\s*$/, '')
    for (const [, key, value] of body.matchAll(/"([A-Za-z0-9]+)":"(0x[0-9a-fA-F]{40})"/g)) {
      if (value !== '0x0000000000000000000000000000000000000000') out[key] = value
    }
  }
  return out
}

/** Map the script's address names onto the environment names both the script and the indexer read. */
export function toEnv(addresses: Record<string, string>): NodeJS.ProcessEnv {
  const map: Record<string, string> = {
    poolManager: 'AMPS_POOL_MANAGER',
    amps: 'AMPS_TOKEN',
    vault: 'AMPS_VAULT',
    hook: 'AMPS_HOOK',
    registry: 'AMPS_REGISTRY',
    feedRegistry: 'AMPS_FEED_REGISTRY',
    bonds: 'AMPS_BONDS',
    staking: 'AMPS_STAKING',
    bountyPot: 'AMPS_BOUNTY_POT',
    valuer: 'AMPS_POSITION_VALUER',
    ladderPolicy: 'AMPS_LADDER_POLICY',
    rolloutPolicy: 'AMPS_ROLLOUT_POLICY',
    feePolicy: 'AMPS_FEE_POLICY',
    bondPolicy: 'AMPS_BOND_POLICY',
    oracleGate: 'AMPS_ORACLE_GATE',
    teamVesting: 'AMPS_TEAM_VESTING',
    usdg: 'AMPS_USDG',
    weth9: 'AMPS_WETH9',
    swapper: 'AMPS_E2E_SWAPPER',
    stock0: 'AMPS_E2E_STOCK0',
    creator: 'AMPS_CREATOR',
    timelock: 'AMPS_TIMELOCK',
    guardian: 'AMPS_GUARDIAN',
  }
  const env: NodeJS.ProcessEnv = {}
  for (const [key, name] of Object.entries(map)) {
    if (addresses[key] !== undefined) env[name] = addresses[key]
  }
  return env
}

// -------------------------------------------------------------------------------------------------
// the indexer
// -------------------------------------------------------------------------------------------------

export interface Indexer {
  url: string
  stop(): void
  get(path: string): Promise<unknown>
}

/** Start `ponder start` over the chain, indexed to `endBlock`, and wait until it has got there. */
export async function startIndexer(options: {
  rpcUrl: string
  addresses: Record<string, string>
  endBlock: number
  port: number
  schema: string
}): Promise<Indexer> {
  const directory = mkdtempSync(join(tmpdir(), 'amps-indexer-'))
  const child = spawn(
    'node',
    [
      join(appRoot, 'node_modules', 'ponder', 'dist', 'esm', 'bin', 'ponder.js'),
      'start',
      '--schema',
      options.schema,
      '--port',
      String(options.port),
      '--log-level',
      'warn',
    ],
    {
      cwd: appRoot,
      env: {
        ...process.env,
        ...toEnv(options.addresses),
        AMPS_CHAIN_ID: '31337',
        AMPS_RPC_URL: options.rpcUrl,
        AMPS_START_BLOCK: '0',
        AMPS_END_BLOCK: String(options.endBlock),
        AMPS_MULTIPLIER_POLL_BLOCKS: '10',
        AMPS_RECONCILE_POLL_BLOCKS: '10',
        AMPS_DENYLIST_WATCH: options.addresses.stock0 ?? '',
        AMPS_PGLITE_DIR: join(directory, 'pglite'),
        // The environment must not carry a Postgres URL into a PGlite run.
        DATABASE_URL: '',
        DATABASE_PRIVATE_URL: '',
      },
      stdio: 'ignore',
    },
  )

  const url = `http://127.0.0.1:${options.port}`
  const deadline = Date.now() + 300_000
  for (;;) {
    if (Date.now() > deadline) {
      child.kill('SIGKILL')
      rmSync(directory, {recursive: true, force: true})
      throw new Error(`[e2e] the indexer did not reach block ${options.endBlock}`)
    }
    try {
      const status = (await (await fetch(`${url}/status`)).json()) as Record<
        string,
        {block?: {number?: number}}
      >
      if ((status.amps?.block?.number ?? -1) >= options.endBlock) break
    } catch {
      // not listening yet
    }
    await sleep(1_000)
  }

  return {
    url,
    stop: () => {
      child.kill('SIGKILL')
      rmSync(directory, {recursive: true, force: true})
    },
    async get(path: string) {
      const response = await fetch(`${url}${path}`)
      if (!response.ok) throw new Error(`[e2e] GET ${path} -> ${response.status}`)
      return response.json()
    },
  }
}
