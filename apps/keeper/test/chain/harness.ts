// SPDX-License-Identifier: MIT

/**
 * Brings up a real chain and stands the whole Amplestocks system on it, so the keeper suite drives production
 * contracts instead of a mock of them.
 *
 * The sequence is `KeeperFixture.s.sol`'s six stages, with anvil's clock advanced between them: registration
 * needs no gate, the gate needs thirty minutes of hub observations before it goes GREEN, and the two genesis
 * placement phases are separated by the 60-second per-pool cooldown. Everything is localhost — no RPC leaves the
 * machine, and the suite runs with the network down.
 *
 * Each test takes an `evm_snapshot` and reverts to it, so a drill that freezes the protocol or breaks a feed
 * cannot leak into the next one.
 */

import {spawn, spawnSync, type ChildProcess} from 'node:child_process'
import {existsSync, readFileSync} from 'node:fs'
import {createServer} from 'node:net'
import {dirname, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'
import {createPublicClient, createWalletClient, http, parseAbi, type Abi, type Address, type PublicClient} from 'viem'
import {privateKeyToAccount} from 'viem/accounts'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(here, '..', '..', '..', '..')
const contractsRoot = resolve(repoRoot, 'contracts')
const fixtureScript = resolve(here, 'KeeperFixture.s.sol')

/** Anvil's account #0, the fixture's operator: deployer, timelock, guardian and creator all at once. */
export const OPERATOR: Address = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'
export const OPERATOR_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' as const

/** Anvil's account #1, the keeper. A different account from the operator on purpose: the jobs are permissionless. */
export const KEEPER: Address = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8'
export const KEEPER_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' as const

/** 2026-09-09 14:00:00 UTC — a Wednesday, 10:00 ET, squarely inside the REGULAR session. */
export const GENESIS_TIME = 1_788_962_400

/** `docs/phase2-state-model.md` §9.1 step 3: the hub's ring has to cover `twapWindow` before the gate is GREEN. */
const TWAP_WINDOW_SECONDS = 1_800

const FOUNDRY_BIN = process.env.FOUNDRY_BIN ?? '/root/.foundry/bin'
const FORGE = process.env.FORGE_BIN ?? resolve(FOUNDRY_BIN, 'forge')
const ANVIL = process.env.ANVIL_BIN ?? resolve(FOUNDRY_BIN, 'anvil')

/** The chain suite is opt-in: it needs Foundry, and the CI `node` job deliberately does not install it. */
export function chainTestsEnabled(): boolean {
  if (process.env.AMPS_KEEPER_CHAIN_TESTS !== '1') return false
  return existsSync(FORGE) && existsSync(ANVIL)
}

export interface FixtureAddresses {
  readonly [name: string]: Address
}

async function freePort(): Promise<number> {
  return new Promise((res, rej) => {
    const server = createServer()
    server.on('error', rej)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      const port = typeof address === 'object' && address !== null ? address.port : 0
      server.close(() => res(port))
    })
  })
}

function artifact(file: string, contract: string): {abi: Abi; bytecode: `0x${string}`} {
  const path = resolve(contractsRoot, 'out-keeper', file, `${contract}.json`)
  const parsed = JSON.parse(readFileSync(path, 'utf8')) as {abi: Abi; bytecode: {object: `0x${string}`}}
  return {abi: parsed.abi, bytecode: parsed.bytecode.object}
}

export const mockAbis = {
  usdg: () => artifact('MockUsdg.sol', 'MockUsdg').abi,
  weth9: () => artifact('10_TestnetPools.s.sol', 'MockWeth9').abi,
  stock: () => artifact('MockStockToken.sol', 'MockStockToken').abi,
  aggregator: () => artifact('MockAggregator.sol', 'MockAggregator').abi,
  swapper: () => artifact('KeeperFixture.s.sol', 'KeeperSwapper').abi,
}

/** The pool key shape every Amplestocks pool has, for the swapper's calldata. */
export const POOL_KEY_ABI = parseAbi([
  'struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }',
  'function swap(PoolKey key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) returns (int256)',
])

export class Fixture {
  readonly rpcUrl: string
  readonly addresses: FixtureAddresses
  readonly client: PublicClient
  private readonly anvil: ChildProcess

  constructor(rpcUrl: string, addresses: FixtureAddresses, client: PublicClient, anvil: ChildProcess) {
    this.rpcUrl = rpcUrl
    this.addresses = addresses
    this.client = client
    this.anvil = anvil
  }

  address(name: string): Address {
    const value = this.addresses[name]
    if (value === undefined) throw new Error(`fixture has no address named ${name}`)
    return value
  }

  async rpc(method: string, params: unknown[] = []): Promise<unknown> {
    const response = await fetch(this.rpcUrl, {
      method: 'POST',
      headers: {'content-type': 'application/json'},
      body: JSON.stringify({jsonrpc: '2.0', id: 1, method, params}),
    })
    const parsed = (await response.json()) as {result?: unknown; error?: {message: string}}
    if (parsed.error !== undefined) throw new Error(`${method}: ${parsed.error.message}`)
    return parsed.result
  }

  async increaseTime(seconds: number): Promise<void> {
    await this.rpc('evm_increaseTime', [seconds])
    await this.rpc('evm_mine', [])
  }

  async mine(count = 1): Promise<void> {
    for (let i = 0; i < count; i += 1) await this.rpc('evm_mine', [])
  }

  /**
   * Pins the basefee and mines, so the next `getBlock('latest')` reports it.
   *
   * anvil's basefee decays toward zero across empty blocks, and a zero basefee makes every job free and the
   * keeper's profitability check vacuous. A drill about gas has to say what the gas costs.
   */
  async setBaseFee(wei: bigint): Promise<void> {
    await this.rpc('anvil_setNextBlockBaseFeePerGas', [`0x${wei.toString(16)}`])
    await this.rpc('evm_mine', [])
  }

  async snapshot(): Promise<string> {
    return (await this.rpc('evm_snapshot', [])) as string
  }

  async revert(id: string): Promise<void> {
    await this.rpc('evm_revert', [id])
    await this.rpc('evm_mine', [])
  }

  /** A wallet client for one of anvil's accounts. */
  wallet(key: `0x${string}`) {
    return createWalletClient({account: privateKeyToAccount(key), transport: http(this.rpcUrl)})
  }

  async stop(): Promise<void> {
    this.anvil.kill('SIGKILL')
  }
}

/** Runs one `forge script` stage against the fixture chain and returns its stdout. */
function runStage(stage: number, rpcUrl: string, env: Record<string, string>): string {
  const result = spawnSync(
    FORGE,
    [
      'script',
      '--remappings',
      'amps/=src/',
      '--remappings',
      'ampstest/=test/',
      '--remappings',
      'ampsscript/=script/',
      fixtureScript,
      '--tc',
      'KeeperFixture',
      '--rpc-url',
      rpcUrl,
      '--broadcast',
      '--slow',
      '--private-key',
      OPERATOR_KEY,
    ],
    {
      cwd: contractsRoot,
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
      env: {
        ...process.env,
        ...env,
        FIXTURE_STAGE: String(stage),
        FIXTURE_OPERATOR: OPERATOR,
        FOUNDRY_OUT: 'out-keeper',
        FOUNDRY_CACHE_PATH: 'cache-keeper',
        PATH: `${FOUNDRY_BIN}:${process.env.PATH ?? ''}`,
      },
    },
  )
  const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`
  if (result.status !== 0) {
    throw new Error(`fixture stage ${stage} failed:\n${output.slice(-4_000)}`)
  }
  return output
}

/** `FIXTURE <name> <address>` lines, as the script prints them. */
function parseAddresses(output: string, into: Record<string, string>): Record<string, string> {
  for (const match of output.matchAll(/FIXTURE\s+([A-Za-z0-9]+)\s+(0x[0-9a-fA-F]{40})/g)) {
    into[(match[1] as string).toUpperCase()] = match[2] as string
  }
  return into
}

/**
 * Compiles the fixture, brings up anvil and runs the six stages.
 *
 * Slow by construction — a cold Foundry cache spends about a minute on the compile and the rest on 90-odd
 * deployment transactions — so the suite shares one fixture across every test and isolates them with snapshots.
 */
export async function startFixture(): Promise<Fixture> {
  const build = spawnSync(
    FORGE,
    [
      'build',
      '--remappings',
      'amps/=src/',
      '--remappings',
      'ampstest/=test/',
      '--remappings',
      'ampsscript/=script/',
      fixtureScript,
    ],
    {
      cwd: contractsRoot,
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
      env: {...process.env, FOUNDRY_OUT: 'out-keeper', FOUNDRY_CACHE_PATH: 'cache-keeper'},
    },
  )
  if (build.status !== 0) throw new Error(`fixture build failed:\n${build.stdout}\n${build.stderr}`)

  const port = await freePort()
  const rpcUrl = `http://127.0.0.1:${port}`
  const anvil = spawn(
    ANVIL,
    ['--port', String(port), '--host', '127.0.0.1', '--silent', '--timestamp', String(GENESIS_TIME)],
    {stdio: 'ignore', detached: false},
  )
  // Node does not reap children on exit, and a suite killed by a timeout would otherwise leave an anvil
  // holding a port for the rest of the session.
  const reap = (): void => {
    anvil.kill('SIGKILL')
  }
  process.once('exit', reap)
  process.once('SIGINT', reap)
  process.once('SIGTERM', reap)

  const client = createPublicClient({transport: http(rpcUrl)}) as PublicClient
  const deadline = Date.now() + 30_000
  for (;;) {
    try {
      await client.getBlockNumber()
      break
    } catch {
      if (Date.now() > deadline) throw new Error('anvil did not come up')
      await new Promise((r) => setTimeout(r, 200))
    }
  }

  const env: Record<string, string> = {}
  const addresses: Record<string, string> = {}

  // Stage 1: the v4 stack, the mocks, the core and the periphery.
  parseAddresses(runStage(1, rpcUrl, env), addresses)
  for (const [name, value] of Object.entries(addresses)) env[`FIXTURE_${name}`] = value

  // Stage 2: pools and constituents, with the gate still unset (§9.1 step 2).
  runStage(2, rpcUrl, env)

  // Step 3: let the hub's observation ring cover `twapWindow`, then wire the gate.
  const fixture = new Fixture(rpcUrl, addresses as FixtureAddresses, client, anvil)
  await fixture.increaseTime(TWAP_WINDOW_SECONDS + 1)

  parseAddresses(runStage(3, rpcUrl, env), addresses)
  for (const [name, value] of Object.entries(addresses)) env[`FIXTURE_${name}`] = value

  // Stage 4: genesis and the ask ladders. Stage 5 after the 60-second cooldown.
  runStage(4, rpcUrl, env)
  await fixture.increaseTime(61)
  runStage(5, rpcUrl, env)
  runStage(6, rpcUrl, env)

  // Clear the 60-second placement cooldown the genesis bids left on the two entry pools, so a suite that
  // starts from this state screens every pool on its merits rather than on the fixture's own clock.
  await fixture.increaseTime(120)

  return new Fixture(rpcUrl, addresses as FixtureAddresses, client, anvil)
}
