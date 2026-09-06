// SPDX-License-Identifier: MIT

/**
 * The keeper against a live local chain.
 *
 * Every contract here is the production one — `AmpsVault`, `AmpsHook` mined to `0x38C0`, `OracleGate`,
 * `PoolRegistry`, `BountyPot`, the four linked vault libraries and the three policies — stood up by
 * `test/chain/KeeperFixture.s.sol` on an anvil the suite spawns. Nothing is stubbed except the counter assets,
 * which are the same mocks `10_TestnetPools` deploys, and nothing reaches the network beyond localhost.
 *
 * **Opt-in.** Foundry is not installed in the CI `node` job, so the whole file is skipped unless
 * `AMPS_KEEPER_CHAIN_TESTS=1` and `forge`/`anvil` are on disk. `pnpm --filter @amplestocks/keeper test:chain`
 * sets it.
 */

import {afterAll, beforeAll, beforeEach, describe, expect, it} from 'vitest'
import {
  concat,
  createPublicClient,
  encodeFunctionData,
  erc20Abi,
  http,
  keccak256,
  parseAbi,
  toHex,
  type Address,
  type PublicClient,
} from 'viem'
import {ampsVaultAbi, bountyPotAbi, oracleGateAbi, poolManagerAbi, poolRegistryAbi} from '@amplestocks/abis'
import {chainTestsEnabled, Fixture, KEEPER, KEEPER_KEY, mockAbis, OPERATOR, OPERATOR_KEY, startFixture} from './chain/harness.js'
import {ChainReader, type Topology} from '../src/chain/reader.js'
import {LocalSignerSubmitter} from '../src/chain/submitter.js'
import {Runner, type ScanResult} from '../src/runner.js'
import {DEFAULT_POLICY, type KeeperPolicy} from '../src/domain/policy.js'
import {GateState} from '../src/domain/types.js'
import {createLogger} from '../src/logger.js'
import {createMetrics} from '../src/metrics.js'
import {loadConfig} from '../src/config.js'
import {WAD} from '../src/domain/bounty.js'

const enabled = chainTestsEnabled()

const SWAPPER_ABI = parseAbi([
  'struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }',
  'function swap(PoolKey key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) returns (int256)',
])
const BONDS_ABI = parseAbi([
  'function bond(uint16 marketId, uint256 amountIn, uint256 minAmpsOut, address to) returns (uint256 payout, uint256 positionId)',
  'function marketCount() view returns (uint16)',
])
const ERC20_APPROVE = parseAbi(['function approve(address spender, uint256 value) returns (bool)'])

describe.skipIf(!enabled)('keeper against a live chain', () => {
  let fixture: Fixture
  let client: PublicClient
  let reader: ChainReader
  let topology: Topology
  let baseline: string

  const logger = createLogger({}, {sink: () => undefined})

  async function makeRunner(overrides: Partial<KeeperPolicy> = {}, ethUsd18 = 0n) {
    const metrics = createMetrics()
    const submitter = new LocalSignerSubmitter(
      {...loadConfig({
        AMPS_CHAIN_ID: '31337',
        AMPS_RPC_URL: fixture.rpcUrl,
        AMPS_TOKEN_ADDRESS: fixture.address('AMPS'),
        AMPS_SENDER_ADDRESS: KEEPER,
        AMPS_SUBMITTER: 'local',
        AMPS_PRIVATE_KEY: KEEPER_KEY,
      })},
      client,
    )
    const runner = new Runner({
      client,
      reader,
      submitter,
      policy: {...DEFAULT_POLICY, ...overrides},
      logger,
      metrics,
      amps: fixture.address('AMPS'),
      vaultOverride: null,
      ethUsd18,
    })
    return {runner, metrics, submitter}
  }

  /** Every compound refusal in one line, so a failed expectation names the guard that fired. */
  function why(result: ScanResult): string {
    const screened = result.screenings
      .filter((s) => s.candidate.kind === 'compound')
      .map((s) => `${s.candidate.target.slice(0, 8)}=${s.eligible ? 'eligible' : s.reason}${s.detail === undefined ? '' : `(${s.detail})`}`)
    const qualified = result.verdicts
      .filter((v) => v.candidate.kind === 'compound')
      .map((v) => `${v.candidate.target.slice(0, 8)}=${v.send ? 'send' : v.reason} work=${v.workValueUsd18}`)
    return `screened [${screened.join(', ')}] qualified [${qualified.join(', ')}]`
  }

  /** `slot0` for a pool, straight from the PoolManager: `keccak256(poolId ++ uint256(6))`. */
  async function slot0(poolId: `0x${string}`): Promise<{sqrtPriceX96: bigint; tick: number}> {
    const word = (await client.readContract({
      address: topology.poolManager,
      abi: poolManagerAbi,
      functionName: 'extsload',
      args: [keccak256(concat([poolId, toHex(6n, {size: 32})]))],
    })) as `0x${string}`
    const value = BigInt(word)
    let tick = Number((value >> 160n) & 0xffffffn)
    if (tick >= 0x800000) tick -= 0x1000000
    return {sqrtPriceX96: value & ((1n << 160n) - 1n), tick}
  }

  async function poolIdOf(which: 'USDG' | number): Promise<`0x${string}`> {
    return (await client.readContract({
      address: topology.registry,
      abi: poolRegistryAbi,
      functionName: which === 'USDG' ? 'hubPoolId' : 'poolIdOf',
      ...(which === 'USDG' ? {} : {args: [which]}),
    })) as `0x${string}`
  }

  /**
   * Round trips through one pool until both fee sides have something in them.
   *
   * **Bounded by price, not by size.** `AmpsHook`'s outer rail reverts a deviation-increasing swap beyond
   * `outerRailTicks` — 2,000 for an entry pool — and a ladder cell is a whole doubling wide, so a swap sized in
   * tokens overshoots by a mile: 200 USDG through the hub's genesis ladder is an 11,907-tick move and reverts
   * with `BeyondRail`. Each leg is therefore given a `sqrtPriceLimitX96` about 1,500 ticks away and an input
   * large enough that the limit is what stops it.
   *
   * Each round buys and sells the same AMPS back, so the pool ends within a few ticks of where it started —
   * which matters, because an entry pool's `fairTick` is its own truncated TWAP and a one-sided trade would
   * leave the pool diverged and the `compound` refused for a reason the test is not about.
   */
  async function churn(which: 'USDG' | number, rounds = 6): Promise<void> {
    const wallet = fixture.wallet(OPERATOR_KEY)
    const poolId = await poolIdOf(which)
    const key = (await client.readContract({
      address: topology.registry,
      abi: poolRegistryAbi,
      functionName: 'poolKey',
      args: [poolId],
    })) as {currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address}
    const swapper = fixture.address('SWAPPER')
    const amps = fixture.address('AMPS')

    const swap = async (zeroForOne: boolean, amountIn: bigint, limit: bigint): Promise<void> => {
      const hash = await wallet.sendTransaction({
        chain: null,
        to: swapper,
        data: encodeFunctionData({abi: SWAPPER_ABI, functionName: 'swap', args: [key, zeroForOne, -amountIn, limit]}),
        gas: 12_000_000n,
      })
      const receipt = await client.waitForTransactionReceipt({hash})
      expect(receipt.status, 'the swap leg succeeded').toBe('success')
    }

    for (let i = 0; i < rounds; i += 1) {
      const start = await slot0(poolId)
      const before = (await client.readContract({
        address: amps,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [swapper],
      })) as bigint

      // +~1,000 ticks: 1.0001^500 = 1.0513 on the sqrt price. The input is deliberately far larger than the
      // limit allows, so the limit is what stops the swap.
      //
      // A thousand and not two: the entry pools' outer rail is 2,000 ticks **from fair**, each round trip
      // leaves the pool a few tens of ticks higher than it started (the fees are not free), and a leg that
      // asks for more than the rail allows does not clip — `AmpsHook` reverts it with `BeyondRail`.
      await swap(false, 1_000_000_000_000n, (start.sqrtPriceX96 * 10_513n) / 10_000n)

      const after = (await client.readContract({
        address: amps,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [swapper],
      })) as bigint
      const bought = after - before
      expect(bought, 'the buy leg bought AMPS').toBeGreaterThan(0n)

      // ...and all of it back out. The AMPS is what stops this leg, not the limit.
      await swap(true, bought, (start.sqrtPriceX96 * 9_300n) / 10_000n)
    }
  }

  beforeAll(async () => {
    fixture = await startFixture()
    client = createPublicClient({transport: http(fixture.rpcUrl)}) as PublicClient
    reader = new ChainReader(client, logger)
    topology = await reader.topology(fixture.address('AMPS'), null)
    baseline = await fixture.snapshot()
  }, 900_000)

  afterAll(async () => {
    if (fixture !== undefined) await fixture.stop()
  })

  /**
   * Every test starts from the fixture's post-genesis state.
   *
   * In `beforeEach` rather than at the end of each test on purpose: a test that fails half way through would
   * otherwise leave a frozen gate, a moved feed or a drifted pool behind, and the next failure would be a
   * consequence of the first rather than a finding of its own.
   */
  beforeEach(async () => {
    await fixture.revert(baseline)
    baseline = await fixture.snapshot()
  })

  // -------------------------------------------------------------------------------------------------------------
  // The fixture itself
  // -------------------------------------------------------------------------------------------------------------

  it('stands up six pools, four constituents, a GREEN gate and a funded pot', async () => {
    expect(topology.vault).toBe(fixture.address('VAULT'))
    expect(topology.hook).toBe(fixture.address('HOOK'))
    expect(topology.oracleGate).toBe(fixture.address('ORACLEGATE'))

    const snapshot = await reader.snapshot(topology, new Map(), 0n)
    expect(snapshot.pools).toHaveLength(6)
    expect(snapshot.constituents).toHaveLength(4)
    expect(snapshot.globalGateState).toBe(GateState.GREEN)
    expect(snapshot.pot.balanceRaw).toBe(1_000_000_000n)
    expect(snapshot.vault.liveCells).toBe(68) // 6 pools x 10 asks + 2 entry pools x 4 seed bids
    expect(snapshot.vault.navPerShareX18).toBeGreaterThan(0n)
  })

  it('resolves the whole topology from the AMPS address alone', async () => {
    const resolved = await reader.topology(fixture.address('AMPS'), null)
    expect(resolved.registry).toBe(fixture.address('REGISTRY'))
    expect(resolved.bountyPot).toBe(fixture.address('BOUNTYPOT'))
    expect(resolved.feedRegistry).toBe(fixture.address('FEEDREGISTRY'))
  })

  // -------------------------------------------------------------------------------------------------------------
  // compound
  // -------------------------------------------------------------------------------------------------------------

  it('fees accrue, `compound` fires, and the bounty lands in the keeper’s pocket', async () => {
    await churn('USDG') // 200 USDG in, 40 AMPS back out
    const {runner, metrics} = await makeRunner()

    const potBefore = (await client.readContract({
      address: topology.bountyPot,
      abi: bountyPotAbi,
      functionName: 'balance',
    })) as bigint

    const result = await runner.scan()
    const compounds = result.sent.filter((s) => s.key.startsWith('compound:'))
    expect(compounds.length, why(result)).toBeGreaterThan(0)
    expect(compounds.every((s) => s.success === true)).toBe(true)

    const potAfter = (await client.readContract({
      address: topology.bountyPot,
      abi: bountyPotAbi,
      functionName: 'balance',
    })) as bigint
    // $0.05 tip + 2% of the flat $1 the vault reports = $0.07 = 70,000 raw USDG units per paid job.
    expect(potBefore - potAfter).toBe(70_000n * BigInt(compounds.length))

    const verdict = result.verdicts.find((v) => v.candidate.key.startsWith('compound:') && v.send)
    expect(verdict?.workValueUsd18).toBeGreaterThan(WAD)
    expect(verdict?.bountyUsd18).toBe(70n * 10n ** 15n)
    expect(metrics.confirmed.get({job: 'compound'})).toBe(compounds.length)
  }, 120_000)

  it('refuses to compound a pool with nothing accrued — the chost guard the pot cannot apply', async () => {
    const {runner, metrics} = await makeRunner()
    const result = await runner.scan()
    expect(result.sent.filter((s) => s.key.startsWith('compound:'))).toHaveLength(0)
    expect(metrics.chostBlocked.get({job: 'compound'})).toBe(6)

    // ...and the pot would have paid for every one of them, which is the finding.
    const quote = (await client.readContract({
      address: topology.bountyPot,
      abi: bountyPotAbi,
      functionName: 'quote',
      args: [WAD, WAD],
    })) as readonly [bigint, `0x${string}`]
    expect(quote[0]).toBe(70_000n)
  }, 120_000)

  it('a synthetic spam campaign is blocked 100%', async () => {
    // Twenty consecutive scans against a chain where nothing has happened. Not one transaction is sent, and the
    // pot is untouched — an attacker calling `compound()` directly would have drained 20 tips.
    const {runner, metrics} = await makeRunner()
    const before = (await client.readContract({
      address: topology.bountyPot,
      abi: bountyPotAbi,
      functionName: 'balance',
    })) as bigint

    let sent = 0
    for (let i = 0; i < 20; i += 1) {
      const result = await runner.scan()
      sent += result.sent.filter((s) => s.key.startsWith('compound:')).length
      await fixture.increaseTime(61)
    }
    expect(sent).toBe(0)
    // Six pools x twenty scans, minus any pool still inside the fixture's own placement cooldown on the first
    // pass. The claim under test is `sent === 0`; this asserts the refusals were the dust guard and not
    // something else silently doing the work.
    expect(metrics.chostBlocked.get({job: 'compound'})).toBeGreaterThanOrEqual(114)

    // The pot is *not* untouched: `rollout` is real work and is paid for it. What must be true is that not one
    // of the 120 empty `compound()` calls the pot would happily have funded was made — 70,000 raw units each.
    const after = (await client.readContract({
      address: topology.bountyPot,
      abi: bountyPotAbi,
      functionName: 'balance',
    })) as bigint
    const paidJobs = Number((before - after) / 70_000n)
    const rollouts = metrics.confirmed.get({job: 'rollout'}) + metrics.confirmed.get({job: 'deployBonded'})
    expect(paidJobs).toBe(rollouts)
  }, 300_000)

  it('waits out the 60-second cooldown rather than burning gas on a revert', async () => {
    await churn('USDG')
    const {runner} = await makeRunner()
    const first = await runner.scan()
    expect(first.sent.filter((s) => s.key.startsWith('compound:')).length, why(first)).toBeGreaterThan(0)

    const second = await runner.scan()
    expect(second.sent.filter((s) => s.key.startsWith('compound:'))).toHaveLength(0)
    const cooled = second.screenings.filter((s) => s.candidate.kind === 'compound' && s.reason === 'cooldown')
    expect(cooled.length).toBeGreaterThan(0)
    expect(cooled[0]?.readyAt).toBeGreaterThan(0)
  }, 180_000)

  // -------------------------------------------------------------------------------------------------------------
  // the gate
  // -------------------------------------------------------------------------------------------------------------

  it('a guardian protocol freeze stops every job', async () => {
    const wallet = fixture.wallet(OPERATOR_KEY)
    const block = await client.getBlock()
    const hash = await wallet.sendTransaction({
      chain: null,
      to: topology.oracleGate,
      data: encodeFunctionData({
        abi: oracleGateAbi,
        functionName: 'freezeProtocol',
        args: [Number(block.timestamp) + 3_600],
      }),
    })
    await client.waitForTransactionReceipt({hash})

    await churn('USDG')
    const {runner, metrics} = await makeRunner()
    const result = await runner.scan()

    expect(result.sent).toHaveLength(0)
    expect(result.snapshot.protocolFreezeUntil).toBeGreaterThan(result.snapshot.now)
    expect(metrics.skipped.get({job: 'compound', reason: 'protocol-frozen'})).toBe(6)
    expect(metrics.skipped.get({job: 'touch', reason: 'protocol-frozen'})).toBe(1)
  }, 180_000)

  it('a DEGRADED gate — the market closed — stops every job', async () => {
    // Friday 16:00 ET to Saturday: the equity calendar's CLOSED session, which `OracleGate` reports as DEGRADED
    // for every path but redemption. Three days forward from the fixture's Wednesday lands on Saturday.
    await fixture.increaseTime(3 * 86_400)
    const snapshot = await reader.snapshot(topology, new Map(), 0n)
    expect(snapshot.globalGateState).not.toBe(GateState.GREEN)

    const {runner, metrics} = await makeRunner()
    const result = await runner.scan()
    expect(result.sent).toHaveLength(0)
    expect(metrics.skipped.get({job: 'compound', reason: 'gate-not-green'})).toBe(6)
  }, 180_000)

  it('a diverged pool is refused, and its neighbours are not', async () => {
    // The spoke's feed moves 9.9% while the pool does not, so `fairTick = tickOf(P_mkt / P_stock)` moves ~944
    // ticks — past `PLACEMENT_DIVERGENCE_TICKS` (800), and the vault would revert the placement at entry.
    //
    // 9.9% and not 100%: `FeedRegistry` holds a single-round move above `ANSWER_JUMP_BPS` (1,000 bp) as
    // *pending* until a second round confirms it, so a doubled feed changes nothing the gate can see. That
    // two-confirmation rule is the reason a divergence drill has to move the feed in a step the registry will
    // adopt on sight — and the reason no single bad round can move a placement anchor.
    //
    // Moving the *pool* instead is not an option: `AmpsHook`'s outer rail reverts a deviation-increasing swap
    // beyond `max(3 x innerBand, 800)` ticks, which for a spoke in the REGULAR session is 800 exactly. The
    // hook makes the pool side of this divergence unreachable by construction.
    const wallet = fixture.wallet(OPERATOR_KEY)
    const hash = await wallet.sendTransaction({
      chain: null,
      to: fixture.address('FEED0'),
      data: encodeFunctionData({
        abi: mockAbis.aggregator(),
        functionName: 'setAnswer',
        args: [109_90_000_000n],
      }),
    })
    await client.waitForTransactionReceipt({hash})

    const snapshot = await reader.snapshot(topology, new Map(), 0n)
    const spokePool = (await client.readContract({
      address: topology.registry,
      abi: poolRegistryAbi,
      functionName: 'poolIdOf',
      args: [1],
    })) as `0x${string}`
    const pool = snapshot.pools.find((p) => p.poolId === spokePool)
    expect(Math.abs((pool?.poolTick ?? 0) - (pool?.fairTick ?? 0))).toBeGreaterThan(800)

    const {runner} = await makeRunner()
    const result = await runner.scan()
    const refused = result.screenings.find((s) => s.candidate.key === `compound:${spokePool}`)
    expect(refused?.eligible).toBe(false)
    expect(['diverged', 'gate-not-green', 'placement-refused']).toContain(refused?.reason)
  }, 180_000)

  // -------------------------------------------------------------------------------------------------------------
  // checkpoint and touch
  // -------------------------------------------------------------------------------------------------------------

  it('refreshes a stale checkpoint before AmpsBonds would start refusing to price', async () => {
    await fixture.increaseTime(1_300) // past checkpointRefreshAtSeconds, inside CHECKPOINT_MAX_AGE
    const {runner} = await makeRunner()
    const result = await runner.scan()

    expect(result.sent.map((s) => s.key)).toContain('checkpoint:')
    const after = (await client.readContract({
      address: topology.vault,
      abi: ampsVaultAbi,
      functionName: 'checkpointData',
    })) as {timestamp: number}
    expect(Number(after.timestamp)).toBeGreaterThan(result.snapshot.vault.checkpointTimestamp)
  }, 180_000)

  it('a tripped watchdog is cleared by `touch`, which is the one job the watchdog does not block', async () => {
    // `GRACE` is 3,600 s of no observation. Jump a day and the layer-A watchdog trips; `AmpsVault.touch` pokes
    // the gate before it checks it, so one call heals the whole system.
    await fixture.increaseTime(86_400 - 3_600 * 4)
    const before = await reader.snapshot(topology, new Map(), 0n)
    expect(before.watchdogTripped || before.globalGateState === GateState.WATCHDOG).toBe(true)

    const {runner} = await makeRunner()
    const result = await runner.scan()
    expect(result.sent.map((s) => s.key)).toContain('touch:')

    const after = await reader.snapshot(topology, new Map(), 0n)
    expect(after.watchdogTripped).toBe(false)
  }, 240_000)

  // -------------------------------------------------------------------------------------------------------------
  // deployBonded
  // -------------------------------------------------------------------------------------------------------------

  it('a bonded deposit above the deploy threshold makes `deployBonded` fire', async () => {
    const wallet = fixture.wallet(OPERATOR_KEY)
    const stock = fixture.address('STOCK0')
    const amount = 5n * WAD // 5 shares at $100 = $500 of collateral offered

    const approve = await wallet.sendTransaction({
      chain: null,
      to: stock,
      data: encodeFunctionData({abi: ERC20_APPROVE, functionName: 'approve', args: [topology.vault, amount]}),
    })
    await client.waitForTransactionReceipt({hash: approve})

    const bond = await wallet.sendTransaction({
      chain: null,
      to: topology.bonds,
      data: encodeFunctionData({abi: BONDS_ABI, functionName: 'bond', args: [1, amount, 0n, OPERATOR]}),
      gas: 12_000_000n,
    })
    const receipt = await client.waitForTransactionReceipt({hash: bond})
    expect(receipt.status).toBe('success')

    const snapshot = await reader.snapshot(topology, new Map(), 0n)
    const constituent = snapshot.constituents.find((c) => c.constituentId === 1)
    expect(constituent?.idleCollateral).toBeGreaterThan(0n)
    expect(constituent?.idleCollateralUsd18).toBeGreaterThanOrEqual(snapshot.vault.deployThresholdUsd18)

    await fixture.increaseTime(61)
    const {runner} = await makeRunner()
    const result = await runner.scan()
    expect(result.sent.map((s) => s.key)).toContain('deployBonded:1')
    expect(result.sent.find((s) => s.key === 'deployBonded:1')?.success).toBe(true)
  }, 240_000)

  it('does not fire `deployBonded` with no bonded collateral', async () => {
    const {runner, metrics} = await makeRunner()
    const result = await runner.scan()
    expect(result.sent.filter((s) => s.key.startsWith('deployBonded:'))).toHaveLength(0)
    expect(metrics.skipped.get({job: 'deployBonded', reason: 'no-work'})).toBe(4)
  }, 120_000)

  // -------------------------------------------------------------------------------------------------------------
  // outage and resumption
  // -------------------------------------------------------------------------------------------------------------

  it('a 48-hour outage resumes without a duplicate send', async () => {
    await churn('USDG')

    // The keeper that was running when the fees accrued.
    const warm = await makeRunner()
    const beforeOutage = await warm.runner.scan()
    expect(
      beforeOutage.sent.filter((s) => s.key.startsWith('compound:')).length,
      why(beforeOutage),
    ).toBeGreaterThan(0)

    // Two days pass with nobody watching. The watchdog trips; `touch` heals it; nothing else is duplicated.
    await fixture.increaseTime(48 * 3_600)

    // A cold instance, started from a clean checkout with no memory of the first one.
    const cold = await makeRunner()
    const first = await cold.runner.scan()
    expect(first.sent.map((s) => s.key)).toContain('touch:')

    const second = await cold.runner.scan()
    const duplicates = second.sent.filter((s) => first.sent.some((f) => f.key === s.key))
    expect(duplicates).toHaveLength(0)

    // ...and every transaction it did send succeeded. A resumed keeper never sends something that reverts.
    for (const sent of [...first.sent, ...second.sent]) expect(sent.success, sent.key).toBe(true)
  }, 300_000)

  it('a second operator instance decides identically from the same chain state', async () => {
    await churn('USDG')
    const a = await makeRunner()
    const b = await makeRunner()

    const snapshot = await fixture.snapshot()
    const first = await a.runner.scan()
    await fixture.revert(snapshot)
    const second = await b.runner.scan()

    expect(second.sent.map((s) => s.key).sort()).toEqual(first.sent.map((s) => s.key).sort())
  }, 300_000)

  // -------------------------------------------------------------------------------------------------------------
  // the bounty, measured
  // -------------------------------------------------------------------------------------------------------------

  it('refuses every bountied job when the bounty cannot cover gas', async () => {
    await churn('USDG')
    // 1 gwei and $2,500 ETH turns a 1.5M-gas compound into $3.75 of gas against a $0.07 tip. The basefee is
    // pinned rather than assumed: anvil decays it toward zero across empty blocks, and a free block would make
    // the check vacuous rather than passing.
    await fixture.setBaseFee(10n ** 9n)
    const {runner, metrics} = await makeRunner({}, 2_500n * WAD)
    const result = await runner.scan()
    expect(result.sent.filter((s) => s.key.startsWith('compound:'))).toHaveLength(0)
    expect(metrics.unprofitable.get({job: 'compound'})).toBeGreaterThan(0)
  }, 180_000)

  it('measures the gas the pot cannot see, and reports it as a metric', async () => {
    await churn('USDG')
    const {runner, metrics} = await makeRunner()
    await runner.scan()

    const text = metrics.registry.render()
    expect(text).toContain('amps_keeper_gas_used_bucket{job="compound"')
    expect(metrics.reportedGasAllowance.get({job: 'compound'})).toBe(1)
    // With `ethUsd18 = 0` the profitability check is off and the measured allowance is zero by construction;
    // the point of the assertion is that the *reported* allowance is the flat $1 whatever the keeper measured.
    expect(metrics.reportedWorkValue.get({job: 'compound'})).toBe(1)
    expect(metrics.measuredWorkValue.get({job: 'compound'})).toBeGreaterThan(1)
  }, 180_000)

  it('degrades to unpaid work when the pot is empty, only if asked to', async () => {
    const wallet = fixture.wallet(OPERATOR_KEY)
    const balance = (await client.readContract({
      address: topology.bountyPot,
      abi: bountyPotAbi,
      functionName: 'balance',
    })) as bigint
    const sweep = await wallet.sendTransaction({
      chain: null,
      to: topology.bountyPot,
      data: encodeFunctionData({abi: bountyPotAbi, functionName: 'sweep', args: [OPERATOR, balance]}),
    })
    await client.waitForTransactionReceipt({hash: sweep})

    await churn('USDG')

    const paid = await makeRunner()
    const refused = await paid.runner.scan()
    expect(refused.sent.filter((s) => s.key.startsWith('compound:'))).toHaveLength(0)
    expect(paid.metrics.skipped.get({job: 'compound', reason: 'pot-depleted'})).toBeGreaterThan(0)

    const unpaid = await makeRunner({runUnpaid: true})
    const done = await unpaid.runner.scan()
    expect(done.sent.filter((s) => s.key.startsWith('compound:')).length).toBeGreaterThan(0)
  }, 240_000)

  // -------------------------------------------------------------------------------------------------------------
  // what the keeper must never do
  // -------------------------------------------------------------------------------------------------------------

  it('sends only the five permissionless jobs, and the ladder is never re-centred', async () => {
    await churn('USDG')
    const {runner} = await makeRunner()

    const before = await ladderShape()
    const result = await runner.scan()
    for (const sent of result.sent) {
      expect(sent.key.split(':')[0]).toMatch(/^(compound|rollout|deployBonded|checkpoint|touch)$/)
    }

    // Every cell the keeper leaves behind is one that existed before it ran, or a new cell strictly above the
    // tick. Nothing moved: `compound` merges into the grid, and the vault has no entry point that could
    // re-centre a ladder even if the keeper wanted to.
    const after = await ladderShape()
    for (const [poolId, cells] of before) {
      const now = after.get(poolId) ?? []
      for (const cell of cells) {
        expect(now.some((c) => c.lower === cell.lower && c.upper === cell.upper), `${poolId}@${cell.lower}`).toBe(true)
      }
    }
  }, 240_000)

  async function ladderShape(): Promise<Map<string, {lower: number; upper: number}[]>> {
    const out = new Map<string, {lower: number; upper: number}[]>()
    for (const poolId of await reader.poolIds(topology)) {
      const length = Number(
        (await client.readContract({
          address: topology.vault,
          abi: ampsVaultAbi,
          functionName: 'ladderLength',
          args: [poolId],
        })) as bigint,
      )
      const cells: {lower: number; upper: number}[] = []
      for (let i = 0; i < length; i += 1) {
        const record = (await client.readContract({
          address: topology.vault,
          abi: ampsVaultAbi,
          functionName: 'ladderAt',
          args: [poolId, BigInt(i)],
        })) as readonly unknown[]
        if ((record[2] as bigint) === 0n) continue
        cells.push({lower: Number(record[0]), upper: Number(record[1])})
      }
      out.set(poolId, cells)
    }
    return out
  }
})

describe.skipIf(enabled)('chain suite', () => {
  it('is skipped without Foundry and AMPS_KEEPER_CHAIN_TESTS=1', () => {
    expect(chainTestsEnabled()).toBe(false)
  })
})
