// SPDX-License-Identifier: MIT

/**
 * The indexing functions, driven with synthetic logs.
 *
 * Every handler is the real one — imported through `src/index.ts`, which is what registers them —
 * and every event is a plain object shaped like the one Ponder hands over. The database is the
 * in-memory stand-in in `test/support/db.ts`, and the chain reads are stubbed per test, so the
 * whole file runs offline in milliseconds.
 *
 * What is being pinned here is the *ordering* the handlers depend on, because that is where an
 * indexer silently goes wrong: the hook's `RotationCreditConsumed` preceding the `PoolManager`'s
 * `Swap`, the registry's `PoolRegistered` preceding every v4 log for that pool, `compound`'s
 * checkpoint preceding its `Compound`, and a bond's accretion being closed out by the checkpoint
 * *after* it.
 */

import {encodeFunctionData, toFunctionSelector} from 'viem'
import {beforeEach, describe, expect, it} from 'vitest'

import '../src/index'

import * as schema from '../ponder.schema'
import {checkLadders as checkLaddersJob} from '../src/handlers/reconcile'
import {amountsForLiquidity} from '../src/lib/math'
import {createFakeDb, type FakeDb} from './support/db'
import {
  ADDRESSES,
  CALLER,
  COUNTER,
  NEW_VAULT,
  POOL_ID,
  TOKEN,
  bondMarketDetached,
  collateralForwarded,
  makeContext,
  makeEvent,
  resetLogIndex,
  run,
  sweepResidue,
  vaultChanged,
  type TestContext,
} from './support/events'
import {registeredHandlers} from './support/registry'

const WAD = 10n ** 18n
const Q96 = 2n ** 96n
const TX = `0x${'cd'.repeat(32)}` as `0x${string}`

/** A Solidity `bytes32` short string, the way the vault emits its `reason` fields. */
const REASON = (text: string): `0x${string}` =>
  `0x${Buffer.from(text, 'utf8').toString('hex').padEnd(64, '0')}` as `0x${string}`

let db: FakeDb
let context: TestContext

// The chain reads the handlers still make. `poolConfig()` and `buyFeeBps()` are gone: pool geometry
// arrives in `PoolRegistered` and `PoolGridSet`, so registration costs no read at all.
const READS = {
  symbol: 'USDG',
  decimals: 6,
  totalSupply: 5_000n * WAD,
  inventoryAmps: 4_750n * WAD,
  balanceOf: 0n,
  previewNavPerShareX18: WAD,
  totalAssetsUsd18: 5_000n * WAD,
  checkpointData: {
    navPerShareX18: WAD,
    pRefX18: WAD,
    pMktX18: WAD,
    timestamp: 0,
    blockNumber: 0,
  },
  totalAssets: 0n,
  convertToAssets: WAD,
}

beforeEach(() => {
  db = createFakeDb()
  context = makeContext(READS, db)
  resetLogIndex()
})

/** Register the pool the v4 handlers filter on. */
async function registerPool(blockNumber = 10n): Promise<void> {
  await run(
    'PoolRegistry:PoolRegistered',
    makeEvent({
      args: {
        poolId: POOL_ID,
        counter: COUNTER,
        poolClass: 1,
        constituentId: 0,
        tickSpacing: 60,
        counterDecimals: 6,
        buyFeeBps: 30,
      },
      blockNumber,
      logIndex: 0,
      address: ADDRESSES.PoolRegistry,
    }),
    context,
  )
  await run(
    'PoolRegistry:PoolOpened',
    makeEvent({
      args: {poolId: POOL_ID, feed: '0x00000000000000000000000000000000000000f1', sqrtPriceX96: Q96},
      blockNumber,
      logIndex: 1,
      address: ADDRESSES.PoolRegistry,
    }),
    context,
  )
  // Emitted immediately after `PoolOpened` whenever the registry mirrored the vault's grid.
  await run(
    'PoolRegistry:PoolGridSet',
    makeEvent({
      args: {poolId: POOL_ID, gridBaseTick: 0},
      blockNumber,
      logIndex: 2,
      address: ADDRESSES.PoolRegistry,
    }),
    context,
  )
}

// -------------------------------------------------------------------------------------------------

describe('registration', () => {
  it('registers every event the plan names', () => {
    const names = registeredHandlers()
    for (const name of [
      'AmpsVault:Genesis',
      'AmpsVault:NavCheckpoint',
      'AmpsVault:RefCheckpoint',
      'AmpsVault:Redeem',
      'AmpsVault:Burn',
      'AmpsVault:Placement',
      'AmpsVault:Rollout',
      'AmpsVault:Compound',
      'AmpsVault:GateChanged',
      'AmpsVault:BondedDeposit',
      'AmpsVault:VestingMinted',
      'AmpsVault:SweepResidue',
      'AmpsBonds:Bond',
      'AmpsBonds:Claim',
      'AmpsBonds:CollateralForwarded',
      'AmpsBonds:CollateralRemoved',
      'AmpsStaking:RewardNotified',
      'PoolRegistry:ConstituentAdded',
      'PoolRegistry:ConstituentRetired',
      'PoolRegistry:ConstituentReinstated',
      'PoolRegistry:ConstituentReconfigured',
      'PoolRegistry:ConstituentFrozen',
      'PoolRegistry:PoolRegistered',
      'PoolRegistry:PoolOpened',
      'PoolRegistry:PoolGridSet',
      'PoolRegistry:BondMarketDetached',
      'PoolRegistry:VaultChanged',
      'PoolManager:Swap',
      'PoolManager:ModifyLiquidity',
      'PoolManager:Initialize',
      'AmpsHook:RebalanceNeeded',
      'AmpsHook:RotationCreditConsumed',
      'AmpsHook:VaultChanged',
      'OracleGate:GateChanged',
      'FeedRegistry:AnswerLatched',
      'BountyPot:BountyPaid',
      'StockTokenCalls:transaction:to',
      'DenylistWatch:transaction:to',
      'constituentPoll:block',
      'reconcile:block',
    ]) {
      expect(names, `missing handler ${name}`).toContain(name)
    }
  })
})

describe('the registry is the allowlist', () => {
  it('creates the pool row from the geometry the events now carry', async () => {
    await registerPool()
    const pool = await db.find(schema.pool, {id: POOL_ID})
    expect(pool).not.toBeNull()
    expect(pool!.tickSpacing).toBe(60)
    expect(pool!.doublingTicks).toBe(6960)
    expect(pool!.counterDecimals).toBe(6)
    expect(pool!.buyFeeBps).toBe(30)
    expect(pool!.gridBaseTick).toBe(0)
    expect(pool!.openSqrtPriceX96).toBe(Q96)
  })

  it('lets PoolGridSet override the opening-tick fallback PoolOpened seeds', async () => {
    // `PoolOpened` seeds `gridBaseTick` from the opening price for a pool the registry could not
    // mirror; `PoolGridSet` lands at a higher log index and carries the vault's real origin.
    await run(
      'PoolRegistry:PoolRegistered',
      makeEvent({
        args: {
          poolId: POOL_ID,
          counter: COUNTER,
          poolClass: 1,
          constituentId: 0,
          tickSpacing: 60,
          counterDecimals: 6,
          buyFeeBps: 30,
        },
        blockNumber: 10n,
        logIndex: 0,
        address: ADDRESSES.PoolRegistry,
      }),
      context,
    )
    await run(
      'PoolRegistry:PoolOpened',
      makeEvent({
        args: {poolId: POOL_ID, feed: '0x00000000000000000000000000000000000000f1', sqrtPriceX96: Q96},
        blockNumber: 10n,
        logIndex: 1,
        address: ADDRESSES.PoolRegistry,
      }),
      context,
    )
    expect((await db.find(schema.pool, {id: POOL_ID}))!.gridBaseTick).toBe(0)

    await run(
      'PoolRegistry:PoolGridSet',
      makeEvent({
        args: {poolId: POOL_ID, gridBaseTick: -13_860},
        blockNumber: 10n,
        logIndex: 2,
        address: ADDRESSES.PoolRegistry,
      }),
      context,
    )
    expect((await db.find(schema.pool, {id: POOL_ID}))!.gridBaseTick).toBe(-13_860)
  })

  it('ignores a PoolGridSet for a pool the registry never announced', async () => {
    await run(
      'PoolRegistry:PoolGridSet',
      makeEvent({
        args: {poolId: `0x${'99'.repeat(32)}`, gridBaseTick: 120},
        blockNumber: 10n,
        logIndex: 0,
        address: ADDRESSES.PoolRegistry,
      }),
      context,
    )
    expect(db.rows(schema.pool)).toHaveLength(0)
  })

  it('drops a v4 swap on a pool the registry never announced', async () => {
    await run(
      'PoolManager:Swap',
      makeEvent({
        args: {
          id: `0x${'99'.repeat(32)}`,
          sender: CALLER,
          amount0: -1n * WAD,
          amount1: 1n,
          sqrtPriceX96: Q96,
          liquidity: 1n,
          tick: 0,
          fee: 50_000,
        },
        address: ADDRESSES.PoolManager,
      }),
      context,
    )
    expect(db.count(schema.swap)).toBe(0)
  })

  it('materialises the token to constituent reverse index', async () => {
    await run(
      'PoolRegistry:ConstituentAdded',
      makeEvent({
        args: {constituentId: 1, token: TOKEN, poolId: POOL_ID, targetWeightBps: 500},
        address: ADDRESSES.PoolRegistry,
      }),
      context,
    )
    expect((await db.find(schema.tokenIndex, {id: TOKEN}))!.constituentId).toBe(1)
    const c = await db.find(schema.constituent, {id: '1'})
    expect(c!.statusLabel).toBe('ACTIVE')
    expect(c!.targetWeightBps).toBe(500)
  })

  it('moves a constituent through retire and reinstate', async () => {
    await run(
      'PoolRegistry:ConstituentAdded',
      makeEvent({
        args: {constituentId: 1, token: TOKEN, poolId: POOL_ID, targetWeightBps: 500},
        address: ADDRESSES.PoolRegistry,
      }),
      context,
    )
    await run(
      'PoolRegistry:ConstituentRetired',
      makeEvent({args: {constituentId: 1, token: TOKEN}, address: ADDRESSES.PoolRegistry}),
      context,
    )
    expect((await db.find(schema.constituent, {id: '1'}))!.statusLabel).toBe('RETIRED')
    await run(
      'PoolRegistry:ConstituentReinstated',
      makeEvent({args: {constituentId: 1, rolloutWeightBps: 300}, address: ADDRESSES.PoolRegistry}),
      context,
    )
    const row = await db.find(schema.constituent, {id: '1'})
    expect(row!.statusLabel).toBe('ACTIVE')
    expect(row!.rolloutWeightBps).toBe(300)
  })
})

describe('checkpoints', () => {
  it('records NAV and the change since the previous checkpoint', async () => {
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {navPerShareX18: WAD, totalAssetsUsd18: 5_000n * WAD, totalSupply: 5_000n * WAD},
        blockNumber: 100n,
        logIndex: 0,
      }),
      context,
    )
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {
          navPerShareX18: (WAD * 10_100n) / 10_000n,
          totalAssetsUsd18: 5_050n * WAD,
          totalSupply: 5_000n * WAD,
        },
        blockNumber: 200n,
        logIndex: 0,
      }),
      context,
    )
    const rows = db.rows(schema.navCheckpoint)
    expect(rows).toHaveLength(2)
    expect(rows[1]!.navChangeBps).toBe(100)
    const summary = await db.find(schema.vaultSummary, {id: 'singleton'})
    expect(summary!.navPerShareX18).toBe((WAD * 10_100n) / 10_000n)
  })

  it('turns a reference checkpoint into a premium', async () => {
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {navPerShareX18: WAD, totalAssetsUsd18: 5_000n * WAD, totalSupply: 5_000n * WAD},
        blockNumber: 100n,
        logIndex: 0,
      }),
      context,
    )
    await run(
      'AmpsVault:RefCheckpoint',
      makeEvent({
        args: {pRefX18: (WAD * 12n) / 10n, pMktX18: (WAD * 12n) / 10n, rateLimited: false, navFloored: false},
        blockNumber: 100n,
        logIndex: 1,
      }),
      context,
    )
    const [ref] = db.rows(schema.refCheckpoint)
    expect(ref!.premiumBps).toBe(2_000)
    expect((await db.find(schema.vaultSummary, {id: 'singleton'}))!.premiumBps).toBe(2_000)
  })

  it('runs reconciliation at every checkpoint and passes when the chain agrees', async () => {
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {navPerShareX18: WAD, totalAssetsUsd18: 5_000n * WAD, totalSupply: 5_000n * WAD},
        blockNumber: 100n,
        logIndex: 0,
      }),
      context,
    )
    await run(
      'AmpsVault:RefCheckpoint',
      makeEvent({
        args: {pRefX18: WAD, pMktX18: WAD, rateLimited: false, navFloored: true},
        blockNumber: 100n,
        logIndex: 1,
      }),
      context,
    )
    // A second checkpoint now has a P_ref to compare.
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {navPerShareX18: WAD, totalAssetsUsd18: 5_000n * WAD, totalSupply: 5_000n * WAD},
        blockNumber: 200n,
        logIndex: 0,
      }),
      context,
    )
    const runs = db.rows(schema.reconciliation)
    expect(runs.length).toBeGreaterThan(0)
    const last = runs[runs.length - 1]!
    expect(last.ok).toBe(true)
    expect(last.trigger).toBe('checkpoint')
    expect(db.rows(schema.alert).filter((a) => a.kind === 'reconciliation')).toHaveLength(0)
  })

  it('raises a critical alert when the chain disagrees past the dust bound', async () => {
    const drifted = makeContext({...READS, checkpointData: {...READS.checkpointData, navPerShareX18: WAD * 2n}}, db)
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {navPerShareX18: WAD, totalAssetsUsd18: 5_000n * WAD, totalSupply: 5_000n * WAD},
        blockNumber: 100n,
        logIndex: 0,
      }),
      drifted,
    )
    await run(
      'AmpsVault:RefCheckpoint',
      makeEvent({
        args: {pRefX18: WAD, pMktX18: WAD, rateLimited: false, navFloored: true},
        blockNumber: 100n,
        logIndex: 1,
      }),
      drifted,
    )
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {navPerShareX18: WAD, totalAssetsUsd18: 5_000n * WAD, totalSupply: 5_000n * WAD},
        blockNumber: 200n,
        logIndex: 0,
      }),
      drifted,
    )
    const failures = db.rows(schema.reconciliation).filter((r) => r.ok === false)
    expect(failures).toHaveLength(1)
    expect(String(failures[0]!.breached)).toContain('nav')
    const alerts = db.rows(schema.alert).filter((a) => a.kind === 'reconciliation')
    expect(alerts).toHaveLength(1)
    expect(alerts[0]!.severity).toBe('critical')
  })
})

describe('supply movements', () => {
  it('decodes a burn reason and moves the net supply', async () => {
    const reason = REASON('compound')
    await run(
      'AmpsVault:Burn',
      makeEvent({args: {amount: 10n * WAD, reason}, blockNumber: 100n, logIndex: 0}),
      context,
    )
    const [burn] = db.rows(schema.burnEvent)
    expect(burn!.reason).toBe('compound')
    expect(burn!.amount).toBe(10n * WAD)
    const summary = await db.find(schema.vaultSummary, {id: 'singleton'})
    expect(summary!.netSupplyChange).toBe(-10n * WAD)
  })

  it('mints through VestingMinted and never double-counts the bond it funds', async () => {
    await run(
      'AmpsVault:VestingMinted',
      makeEvent({
        args: {to: ADDRESSES.AmpsBonds, amount: 100n * WAD, reason: REASON('bond')},
        blockNumber: 100n,
        logIndex: 0,
      }),
      context,
    )
    const [mint] = db.rows(schema.vestingMint)
    expect(mint!.reason).toBe('bond')
    expect(mint!.to).toBe(ADDRESSES.AmpsBonds)

    // `AmpsBonds:Bond` describes this same mint, so the summary must not move again.
    await run(
      'AmpsBonds:Bond',
      makeEvent({
        args: {
          buyer: CALLER,
          marketId: 1,
          collateral: TOKEN,
          amountIn: 10n * WAD,
          ampsOut: 100n * WAD,
          positionId: 0n,
          qX18: 10n * WAD,
          discountBps: 1_250,
          floorBinding: false,
          vestSeconds: 604_800,
        },
        blockNumber: 100n,
        logIndex: 1,
        address: ADDRESSES.AmpsBonds,
      }),
      context,
    )
    const summary = await db.find(schema.vaultSummary, {id: 'singleton'})
    expect(summary!.vestingMintedTotal).toBe(100n * WAD)
    expect(summary!.netSupplyChange).toBe(100n * WAD)
  })

  it('leaves the supply to the two Burns a redemption emits', async () => {
    // `redeemProRata` burns the redeemer's shares and the vault's inventory slice as two `Burn`
    // logs, then emits `Redeem`. Moving the supply on `Redeem` too would double-count the exit.
    await run(
      'AmpsVault:Burn',
      makeEvent({args: {amount: 100n * WAD, reason: REASON('redeem')}, blockNumber: 101n, logIndex: 0}),
      context,
    )
    await run(
      'AmpsVault:Burn',
      makeEvent({
        args: {amount: 5n * WAD, reason: REASON('redeemInventory')},
        blockNumber: 101n,
        logIndex: 1,
      }),
      context,
    )
    await run(
      'AmpsVault:Redeem',
      makeEvent({
        args: {owner: CALLER, to: CALLER, shares: 100n * WAD, inventoryBurned: 5n * WAD, feeBps: 100},
        blockNumber: 101n,
        logIndex: 2,
      }),
      context,
    )
    const summary = await db.find(schema.vaultSummary, {id: 'singleton'})
    expect(summary!.netSupplyChange).toBe(-105n * WAD)
    expect(summary!.burnedAllTotal).toBe(105n * WAD)
    expect(summary!.redeemedSharesTotal).toBe(100n * WAD)
    expect(db.rows(schema.burnEvent).map((b) => b.reason)).toEqual(['redeem', 'redeemInventory'])
  })

  it('prices a redemption at the NAV in force', async () => {
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {navPerShareX18: 2n * WAD, totalAssetsUsd18: 10_000n * WAD, totalSupply: 5_000n * WAD},
        blockNumber: 100n,
        logIndex: 0,
      }),
      context,
    )
    await run(
      'AmpsVault:Redeem',
      makeEvent({
        args: {owner: CALLER, to: CALLER, shares: 100n * WAD, inventoryBurned: 5n * WAD, feeBps: 100},
        blockNumber: 101n,
        logIndex: 0,
      }),
      context,
    )
    const [redemption] = db.rows(schema.redemption)
    expect(redemption!.navPerShareX18).toBe(2n * WAD)
    expect(redemption!.grossUsd18).toBe(200n * WAD)
    expect(redemption!.feeUsd18).toBe(2n * WAD)
  })
})

describe('the valuer cross-check', () => {
  // The job takes Ponder's own `db`, whose type carries a `sql` escape hatch the in-memory double
  // has no use for. Everything the job actually touches — `find`, `update` — is on both.
  const checkLadders = (ctx: TestContext, block: bigint) =>
    checkLaddersJob(ctx as unknown as Parameters<typeof checkLaddersJob>[0], block)

  /** Register a pool, name it as constituent 7's, and give it one live ask cell. */
  async function ladderWithOneCell(): Promise<void> {
    await registerPool()
    await run(
      'PoolRegistry:ConstituentAdded',
      makeEvent({
        args: {constituentId: 7, token: TOKEN, poolId: POOL_ID, targetWeightBps: 500},
        blockNumber: 11n,
        logIndex: 0,
        address: ADDRESSES.PoolRegistry,
      }),
      context,
    )
    await run(
      'PoolManager:ModifyLiquidity',
      makeEvent({
        args: {
          id: POOL_ID,
          sender: ADDRESSES.AmpsVault,
          tickLower: 0,
          tickUpper: 6960,
          liquidityDelta: 10n ** 18n,
          salt: `0x${'00'.repeat(32)}`,
        },
        blockNumber: 20n,
        logIndex: 0,
        txHash: TX,
        address: ADDRESSES.PoolManager,
      }),
      context,
    )
  }

  /** What the indexer's own port of `LiquidityAmounts` makes of that cell at the reference price. */
  const expectedAmps = amountsForLiquidity(Q96, 0, 6960, 10n ** 18n).amount0

  it('agrees with the valuer when the maths matches', async () => {
    await ladderWithOneCell()
    context = makeContext({...READS, amountsOf: [expectedAmps, 7n], referenceSqrtPriceX96: Q96}, db)
    await checkLadders(context, 21n)

    const pool = await db.find(schema.pool, {id: POOL_ID})
    expect(pool!.valuerAmps).toBe(expectedAmps)
    expect(pool!.valuerCounter).toBe(7n)
    expect(pool!.valuerDeltaBps).toBe(0)
    expect(pool!.valuerCheckedBlock).toBe(21n)
  })

  it('records the divergence when it does not, without raising a breach', async () => {
    await ladderWithOneCell()
    context = makeContext(
      {...READS, amountsOf: [(expectedAmps * 12_000n) / 10_000n, 7n], referenceSqrtPriceX96: Q96},
      db,
    )
    await checkLadders(context, 21n)

    const pool = await db.find(schema.pool, {id: POOL_ID})
    expect(pool!.valuerDeltaBps).toBe(1_666) // 20% high on the valuer side
    expect(db.rows(schema.alert)).toHaveLength(0)
  })

  it('does nothing when the valuer is not deployed', async () => {
    await ladderWithOneCell()
    context = makeContext({...READS, amountsOf: [expectedAmps, 7n], referenceSqrtPriceX96: Q96}, db)
    context.contracts.LadderPositionValuer = {address: '0x' + '00'.repeat(20)}
    await checkLadders(context, 21n)
    expect((await db.find(schema.pool, {id: POOL_ID}))!.valuerCheckedBlock).toBe(0n)
  })
})

describe('rollout', () => {
  it('records both halves of the move and the keeper job that did it', async () => {
    await registerPool()
    await run(
      'AmpsVault:Rollout',
      makeEvent({
        args: {
          constituentId: 7,
          poolId: POOL_ID,
          movedAmps: 500n * WAD,
          placedAmps: 480n * WAD,
        },
        blockNumber: 30n,
        logIndex: 0,
        txHash: TX,
        input: toFunctionSelector('rollout(uint16)'),
      }),
      context,
    )

    const [rollout] = db.rows(schema.rolloutEvent)
    expect(rollout!.constituentId).toBe(7)
    expect(rollout!.toPoolId).toBe(POOL_ID)
    expect(rollout!.movedAmps).toBe(500n * WAD)
    // The residue — what the destination ladder could not commit — stays idle and is the gap.
    expect(rollout!.placedAmps).toBe(480n * WAD)

    const job = await db.find(schema.keeperJob, {id: TX})
    expect(job!.job).toBe('rollout')
    expect(job!.outcome).toBe('ok')
    expect(job!.constituentId).toBe(7)
  })

  it('marks a rollout that placed nothing as a no-op', async () => {
    await registerPool()
    await run(
      'AmpsVault:Rollout',
      makeEvent({
        args: {constituentId: 7, poolId: POOL_ID, movedAmps: 0n, placedAmps: 0n},
        blockNumber: 30n,
        logIndex: 0,
        txHash: TX,
        input: toFunctionSelector('rollout(uint16)'),
      }),
      context,
    )
    expect((await db.find(schema.keeperJob, {id: TX}))!.outcome).toBe('noop')
  })
})

describe('compound', () => {
  it('records the four-way split and the NAV either side', async () => {
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {navPerShareX18: WAD, totalAssetsUsd18: 5_000n * WAD, totalSupply: 5_000n * WAD},
        blockNumber: 100n,
        logIndex: 0,
      }),
      context,
    )
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {
          navPerShareX18: (WAD * 10_010n) / 10_000n,
          totalAssetsUsd18: 5_005n * WAD,
          totalSupply: 5_000n * WAD,
        },
        blockNumber: 200n,
        logIndex: 0,
      }),
      context,
    )
    await run(
      'AmpsVault:Compound',
      makeEvent({
        args: {
          poolId: POOL_ID,
          ampsFees: 100n * WAD,
          creatorPaid: 20n * WAD,
          stakerPaid: 24n * WAD,
          burned: 5n * WAD,
          relaid: 51n * WAD,
        },
        blockNumber: 200n,
        logIndex: 1,
        input: toFunctionSelector('compound(bytes32)'),
      }),
      context,
    )
    const [compound] = db.rows(schema.compoundEvent)
    expect(compound!.navBeforeX18).toBe(WAD)
    expect(compound!.navAfterX18).toBe((WAD * 10_010n) / 10_000n)
    expect(compound!.navChangeBps).toBe(10)
    expect(
      (compound!.creatorPaid as bigint) +
        (compound!.stakerPaid as bigint) +
        (compound!.burned as bigint) +
        (compound!.relaid as bigint),
    ).toBe(100n * WAD)

    const summary = await db.find(schema.vaultSummary, {id: 'singleton'})
    expect(summary!.feesAmpsTotal).toBe(100n * WAD)
    expect(summary!.compoundCount).toBe(1)

    const [job] = db.rows(schema.keeperJob)
    expect(job!.job).toBe('compound')
    expect(job!.outcome).toBe('ok')
  })

  it('pages when a compound bleeds past the 2 bp R1 bound', async () => {
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {navPerShareX18: WAD, totalAssetsUsd18: 5_000n * WAD, totalSupply: 5_000n * WAD},
        blockNumber: 100n,
        logIndex: 0,
      }),
      context,
    )
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {
          navPerShareX18: (WAD * 9_900n) / 10_000n,
          totalAssetsUsd18: 4_950n * WAD,
          totalSupply: 5_000n * WAD,
        },
        blockNumber: 200n,
        logIndex: 0,
      }),
      context,
    )
    await run(
      'AmpsVault:Compound',
      makeEvent({
        args: {
          poolId: POOL_ID,
          ampsFees: 1n,
          creatorPaid: 0n,
          stakerPaid: 0n,
          burned: 0n,
          relaid: 1n,
        },
        blockNumber: 200n,
        logIndex: 1,
      }),
      context,
    )
    const alerts = db.rows(schema.alert).filter((a) => a.kind === 'nav-bleed')
    expect(alerts).toHaveLength(1)
    expect(alerts[0]!.severity).toBe('critical')
  })
})

describe('the ladder', () => {
  it('builds a cell from a ModifyLiquidity and attributes it to the placement', async () => {
    await registerPool()
    await run(
      'PoolManager:ModifyLiquidity',
      makeEvent({
        args: {
          id: POOL_ID,
          sender: ADDRESSES.AmpsVault,
          tickLower: 0,
          tickUpper: 6960,
          liquidityDelta: 10n ** 18n,
          salt: `0x${'00'.repeat(32)}`,
        },
        blockNumber: 20n,
        logIndex: 0,
        txHash: TX,
        address: ADDRESSES.PoolManager,
      }),
      context,
    )
    await run(
      'AmpsVault:Placement',
      makeEvent({
        args: {
          poolId: POOL_ID,
          above: true,
          buckets: 1,
          amount: 1_662n * WAD,
          anchorTick: 0,
          reason: REASON('place'),
          lowerTick: 0,
          upperTick: 6960,
        },
        blockNumber: 20n,
        logIndex: 1,
        txHash: TX,
        input: toFunctionSelector('place(bytes32,bool,uint256)'),
      }),
      context,
    )

    const cell = await db.find(schema.ladderCell, {id: `${POOL_ID}-0`})
    expect(cell).not.toBeNull()
    expect(cell!.above).toBe(true)
    expect(cell!.cellIndex).toBe(8) // m = 0, GRID_MIN_M = -8
    expect(cell!.ampsRemaining).toBeGreaterThan(0n)
    expect(cell!.counterRaised).toBe(0n)
    expect(cell!.fillBps).toBe(0)

    const [placement] = db.rows(schema.placement)
    expect(placement!.cells).toBe(1)
    expect(placement!.action).toBe('place')
    expect(placement!.reason).toBe('place')
    expect(placement!.lowerTick).toBe(0)
    expect(placement!.upperTick).toBe(6960)
    expect(placement!.liquidityAdded).toBe(10n ** 18n)

    const pool = await db.find(schema.pool, {id: POOL_ID})
    expect(pool!.askCells).toBe(1)
    expect(pool!.ampsInLadder).toBe(cell!.ampsRemaining)
  })

  it('ignores the zero-delta modifyLiquidity compound uses to realise fees', async () => {
    await registerPool()
    await run(
      'PoolManager:ModifyLiquidity',
      makeEvent({
        args: {
          id: POOL_ID,
          sender: ADDRESSES.AmpsVault,
          tickLower: 0,
          tickUpper: 6960,
          liquidityDelta: 0n,
          salt: `0x${'00'.repeat(32)}`,
        },
        blockNumber: 21n,
        address: ADDRESSES.PoolManager,
      }),
      context,
    )
    expect(db.count(schema.ladderCell)).toBe(0)
    expect(db.count(schema.liquidityChange)).toBe(1)
  })

  it('converts an ask into proceeds as the price crosses it', async () => {
    await registerPool()
    await run(
      'PoolManager:ModifyLiquidity',
      makeEvent({
        args: {
          id: POOL_ID,
          sender: ADDRESSES.AmpsVault,
          tickLower: 0,
          tickUpper: 6960,
          liquidityDelta: 10n ** 18n,
          salt: `0x${'00'.repeat(32)}`,
        },
        blockNumber: 20n,
        logIndex: 0,
        address: ADDRESSES.PoolManager,
      }),
      context,
    )
    const before = await db.find(schema.ladderCell, {id: `${POOL_ID}-0`})

    // A buy walks the price up through the middle of the cell.
    await run(
      'PoolManager:Swap',
      makeEvent({
        args: {
          id: POOL_ID,
          sender: CALLER,
          amount0: 10n * WAD,
          amount1: -10n * 10n ** 6n,
          sqrtPriceX96: 2n ** 96n + 2n ** 94n,
          liquidity: 10n ** 18n,
          tick: 3480,
          fee: 3_000,
        },
        blockNumber: 30n,
        logIndex: 0,
        address: ADDRESSES.PoolManager,
      }),
      context,
    )

    const after = await db.find(schema.ladderCell, {id: `${POOL_ID}-0`})
    expect(after!.ampsRemaining).toBeLessThan(before!.ampsRemaining as bigint)
    expect(after!.counterRaised).toBeGreaterThan(0n)
    expect(after!.fillBps).toBeGreaterThan(0)
  })
})

describe('swaps', () => {
  beforeEach(async () => {
    await registerPool()
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {navPerShareX18: WAD, totalAssetsUsd18: 5_000n * WAD, totalSupply: 5_000n * WAD},
        blockNumber: 15n,
        logIndex: 0,
      }),
      context,
    )
    await run(
      'AmpsVault:RefCheckpoint',
      makeEvent({
        args: {pRefX18: WAD, pMktX18: WAD, rateLimited: false, navFloored: true},
        blockNumber: 15n,
        logIndex: 1,
      }),
      context,
    )
  })

  it('decodes an uncredited sell', async () => {
    await run(
      'PoolManager:Swap',
      makeEvent({
        args: {
          id: POOL_ID,
          sender: CALLER,
          amount0: -100n * WAD,
          amount1: 95n * 10n ** 6n,
          sqrtPriceX96: Q96,
          liquidity: 10n ** 18n,
          tick: 0,
          fee: 50_000,
        },
        blockNumber: 40n,
        logIndex: 0,
        address: ADDRESSES.PoolManager,
      }),
      context,
    )
    const [swap] = db.rows(schema.swap)
    expect(swap!.sell).toBe(true)
    expect(swap!.baseFeeBps).toBe(500)
    expect(swap!.dynamicFeeBps).toBe(0)
    expect(swap!.feeAmps).toBe(5n * WAD)
    expect(swap!.credited).toBe(false)
    expect(swap!.notionalUsd18).toBe(100n * WAD)

    const pool = await db.find(schema.pool, {id: POOL_ID})
    expect(pool!.sellVolumeAmps).toBe(100n * WAD)
    expect(pool!.sellFeeAmps).toBe(5n * WAD)
    expect(pool!.swapCount).toBe(1)
  })

  it('takes the blended base from the hook credit that preceded it in the same transaction', async () => {
    await run(
      'AmpsHook:RotationCreditConsumed',
      makeEvent({
        args: {poolId: POOL_ID, consumed: 100n * WAD, blendedFeeBps: 30},
        blockNumber: 41n,
        logIndex: 0,
        txHash: TX,
        address: ADDRESSES.AmpsHook,
      }),
      context,
    )
    await run(
      'PoolManager:Swap',
      makeEvent({
        args: {
          id: POOL_ID,
          sender: CALLER,
          amount0: -100n * WAD,
          amount1: 99n * 10n ** 6n,
          sqrtPriceX96: Q96,
          liquidity: 10n ** 18n,
          tick: 0,
          fee: 3_000,
        },
        blockNumber: 41n,
        logIndex: 1,
        txHash: TX,
        address: ADDRESSES.PoolManager,
      }),
      context,
    )
    const [swap] = db.rows(schema.swap)
    expect(swap!.credited).toBe(true)
    expect(swap!.creditedAmount).toBe(100n * WAD)
    expect(swap!.baseFeeBps).toBe(30)
    expect(swap!.dynamicFeeBps).toBe(0)
    // The parked credit is consumed exactly once.
    expect(db.count(schema.pendingCredit)).toBe(0)

    const pool = await db.find(schema.pool, {id: POOL_ID})
    expect(pool!.rotationCreditedAmps).toBe(100n * WAD)
  })

  it('splits the charged fee into base and dynamic', async () => {
    await run(
      'PoolManager:Swap',
      makeEvent({
        args: {
          id: POOL_ID,
          sender: CALLER,
          amount0: -100n * WAD,
          amount1: 90n * 10n ** 6n,
          sqrtPriceX96: Q96,
          liquidity: 10n ** 18n,
          tick: 0,
          fee: 62_500,
        },
        blockNumber: 42n,
        logIndex: 0,
        address: ADDRESSES.PoolManager,
      }),
      context,
    )
    const [swap] = db.rows(schema.swap)
    expect(swap!.feeBps).toBe(625)
    expect(swap!.baseFeeBps).toBe(500)
    expect(swap!.dynamicFeeBps).toBe(125)
  })

  it('follows the hook when the sell fee moves', async () => {
    await run(
      'AmpsHook:HookParameterChanged',
      makeEvent({
        args: {
          parameter: `0x${Buffer.from('ampsFeeBps', 'utf8').toString('hex').padEnd(64, '0')}`,
          poolId: `0x${'00'.repeat(32)}`,
          previousValue: 500n,
          newValue: 300n,
        },
        blockNumber: 43n,
        logIndex: 0,
        address: ADDRESSES.AmpsHook,
      }),
      context,
    )
    await run(
      'PoolManager:Swap',
      makeEvent({
        args: {
          id: POOL_ID,
          sender: CALLER,
          amount0: -100n * WAD,
          amount1: 97n * 10n ** 6n,
          sqrtPriceX96: Q96,
          liquidity: 10n ** 18n,
          tick: 0,
          fee: 30_000,
        },
        blockNumber: 44n,
        logIndex: 0,
        address: ADDRESSES.PoolManager,
      }),
      context,
    )
    const [swap] = db.rows(schema.swap)
    expect(swap!.baseFeeBps).toBe(300)
    expect(swap!.dynamicFeeBps).toBe(0)
  })
})

describe('bonds', () => {
  it('closes the accretion out at the checkpoint after the bond', async () => {
    await run(
      'AmpsBonds:CollateralAdded',
      makeEvent({
        args: {marketId: 1, collateral: TOKEN, class: 0, constituentId: 1},
        blockNumber: 50n,
        logIndex: 0,
        address: ADDRESSES.AmpsBonds,
      }),
      context,
    )
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {navPerShareX18: WAD, totalAssetsUsd18: 5_000n * WAD, totalSupply: 5_000n * WAD},
        blockNumber: 51n,
        logIndex: 0,
      }),
      context,
    )
    await run(
      'AmpsBonds:Bond',
      makeEvent({
        args: {
          buyer: CALLER,
          marketId: 1,
          collateral: TOKEN,
          amountIn: 10n * WAD,
          ampsOut: 100n * WAD,
          positionId: 0n,
          qX18: 10n * WAD,
          discountBps: 1_250,
          floorBinding: false,
          vestSeconds: 604_800,
        },
        blockNumber: 51n,
        logIndex: 1,
        address: ADDRESSES.AmpsBonds,
      }),
      context,
    )
    // The bond raised NAV/share by 1%.
    await run(
      'AmpsVault:NavCheckpoint',
      makeEvent({
        args: {
          navPerShareX18: (WAD * 10_100n) / 10_000n,
          totalAssetsUsd18: 5_151n * WAD,
          totalSupply: 5_100n * WAD,
        },
        blockNumber: 52n,
        logIndex: 0,
      }),
      context,
    )

    const [purchase] = db.rows(schema.bondPurchase)
    expect(purchase!.vestSeconds).toBe(604_800) // straight off the log, no lens read
    expect(purchase!.navBeforeX18).toBe(WAD)
    expect(purchase!.navAfterX18).toBe((WAD * 10_100n) / 10_000n)
    expect(purchase!.accretionUsd18).toBe(50n * WAD) // 0.01 x 5,000 shares
    expect(purchase!.accretionBps).toBe(100)

    const market = await db.find(schema.bondMarket, {id: '1'})
    expect(market!.totalIssued).toBe(100n * WAD)
    expect(market!.accretionUsd18).toBe(50n * WAD)
    expect(market!.bondCount).toBe(1)

    const summary = await db.find(schema.vaultSummary, {id: 'singleton'})
    expect(summary!.bondIssuedTotal).toBe(100n * WAD)
  })

  it('tracks a vesting position through its claims', async () => {
    await run(
      'AmpsBonds:CollateralAdded',
      makeEvent({
        args: {marketId: 1, collateral: TOKEN, class: 0, constituentId: 1},
        blockNumber: 50n,
        logIndex: 0,
        address: ADDRESSES.AmpsBonds,
      }),
      context,
    )
    await run(
      'AmpsBonds:Bond',
      makeEvent({
        args: {
          buyer: CALLER,
          marketId: 1,
          collateral: TOKEN,
          amountIn: 10n * WAD,
          ampsOut: 100n * WAD,
          positionId: 0n,
          qX18: 10n * WAD,
          discountBps: 1_250,
          floorBinding: true,
          vestSeconds: 259_200,
        },
        blockNumber: 51n,
        logIndex: 1,
        address: ADDRESSES.AmpsBonds,
      }),
      context,
    )
    await run(
      'AmpsBonds:Claim',
      makeEvent({
        args: {owner: CALLER, positionId: 0n, to: CALLER, amount: 60n * WAD},
        blockNumber: 60n,
        logIndex: 0,
        address: ADDRESSES.AmpsBonds,
      }),
      context,
    )
    let position = await db.find(schema.bondPosition, {id: `${CALLER}-0`})
    expect(position!.vestSeconds).toBe(259_200)
    expect(position!.claimed).toBe(60n * WAD)
    expect(position!.fullyClaimed).toBe(false)

    await run(
      'AmpsBonds:Claim',
      makeEvent({
        args: {owner: CALLER, positionId: 0n, to: CALLER, amount: 40n * WAD},
        blockNumber: 61n,
        logIndex: 0,
        address: ADDRESSES.AmpsBonds,
      }),
      context,
    )
    position = await db.find(schema.bondPosition, {id: `${CALLER}-0`})
    expect(position!.claimed).toBe(100n * WAD)
    expect(position!.fullyClaimed).toBe(true)
  })
})

describe('the gate', () => {
  it('records a transition and alerts on anything but GREEN', async () => {
    await registerPool()
    await run(
      'OracleGate:GateChanged',
      makeEvent({
        args: {poolId: POOL_ID, previousState: 0, newState: 1},
        blockNumber: 70n,
        logIndex: 0,
        address: ADDRESSES.OracleGate,
      }),
      context,
    )
    const [transition] = db.rows(schema.gateTransition)
    expect(transition!.newLabel).toBe('DEGRADED')
    expect((await db.find(schema.gateStatus, {id: POOL_ID}))!.stateLabel).toBe('DEGRADED')
    expect((await db.find(schema.pool, {id: POOL_ID}))!.gateStateLabel).toBe('DEGRADED')
    const alerts = db.rows(schema.alert).filter((a) => a.kind === 'gate')
    expect(alerts).toHaveLength(1)
    expect(alerts[0]!.severity).toBe('warning')
  })

  it('calls a tripped watchdog critical', async () => {
    await run(
      'OracleGate:WatchdogTripped',
      makeEvent({
        args: {tripped: true, elapsed: 900},
        blockNumber: 71n,
        logIndex: 0,
        address: ADDRESSES.OracleGate,
      }),
      context,
    )
    const alerts = db.rows(schema.alert).filter((a) => a.kind === 'gate')
    expect(alerts[0]!.severity).toBe('critical')
    expect((await db.find(schema.gateStatus, {id: 'protocol'}))!.watchdogTripped).toBe(true)
  })
})

describe('feeds', () => {
  it('records the answer the protocol accepted and mirrors it onto the constituent', async () => {
    await run(
      'PoolRegistry:ConstituentAdded',
      makeEvent({
        args: {constituentId: 1, token: TOKEN, poolId: POOL_ID, targetWeightBps: 500},
        blockNumber: 10n,
        logIndex: 0,
        address: ADDRESSES.PoolRegistry,
      }),
      context,
    )
    await run(
      'FeedRegistry:FeedSet',
      makeEvent({
        args: {
          token: TOKEN,
          previousAggregator: '0x0000000000000000000000000000000000000000',
          aggregator: '0x00000000000000000000000000000000000000f1',
        },
        blockNumber: 11n,
        logIndex: 0,
        address: ADDRESSES.FeedRegistry,
      }),
      context,
    )
    await run(
      'FeedRegistry:AnswerLatched',
      makeEvent({
        args: {token: TOKEN, answerUsd8: 20_000_000_000n, updatedAt: 1_788_000_000, roundId: 7n},
        blockNumber: 12n,
        logIndex: 0,
        address: ADDRESSES.FeedRegistry,
      }),
      context,
    )
    const [answer] = db.rows(schema.feedAnswer)
    expect(answer!.source).toBe('latched')
    expect(answer!.answerUsd8).toBe(20_000_000_000n)
    const constituent = await db.find(schema.constituent, {id: '1'})
    expect(constituent!.answerUsd8).toBe(20_000_000_000n)
  })
})

describe('the denylist alarm', () => {
  const blockAccounts = (accounts: `0x${string}`[]) =>
    encodeFunctionData({
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

  it('fires on a blockAccounts transaction to a registered stock token', async () => {
    await run(
      'PoolRegistry:ConstituentAdded',
      makeEvent({
        args: {constituentId: 1, token: TOKEN, poolId: POOL_ID, targetWeightBps: 500},
        blockNumber: 10n,
        logIndex: 0,
        address: ADDRESSES.PoolRegistry,
      }),
      context,
    )
    await run(
      'StockTokenCalls:transaction:to',
      makeEvent({
        args: {},
        blockNumber: 80n,
        to: TOKEN,
        from: '0x00000000000000000000000000000000000000ad',
        input: blockAccounts(['0x00000000000000000000000000000000000000e1']),
      }),
      context,
    )
    const [alarm] = db.rows(schema.denylistAlarm)
    expect(alarm!.detection).toBe('call')
    expect(alarm!.selector).toBe('0x6abf7081')
    expect(alarm!.target).toBe(TOKEN)
    expect(alarm!.constituentId).toBe(1)
    expect(alarm!.touchesProtocol).toBe(false)
    expect(alarm!.severity).toBe('warning')
    expect(alarm!.blockNumber).toBe(80n)

    const alerts = db.rows(schema.alert).filter((a) => a.kind === 'denylist')
    expect(alerts).toHaveLength(1)
  })

  it('is critical when the blocked address is the vault', async () => {
    await run(
      'DenylistWatch:transaction:to',
      makeEvent({
        args: {},
        blockNumber: 81n,
        to: '0x00000000000000000000000000000000000000be',
        input: blockAccounts([ADDRESSES.AmpsVault as `0x${string}`]),
      }),
      context,
    )
    const [alarm] = db.rows(schema.denylistAlarm)
    expect(alarm!.touchesProtocol).toBe(true)
    expect(alarm!.severity).toBe('critical')
  })

  it('ignores any other call to a watched contract', async () => {
    await run(
      'DenylistWatch:transaction:to',
      makeEvent({
        args: {},
        blockNumber: 82n,
        to: '0x00000000000000000000000000000000000000be',
        input: toFunctionSelector('transfer(address,uint256)'),
      }),
      context,
    )
    expect(db.count(schema.denylistAlarm)).toBe(0)
  })
})

describe('the constituent poll', () => {
  beforeEach(async () => {
    await run(
      'PoolRegistry:ConstituentAdded',
      makeEvent({
        args: {constituentId: 1, token: TOKEN, poolId: POOL_ID, targetWeightBps: 500},
        blockNumber: 10n,
        logIndex: 0,
        address: ADDRESSES.PoolRegistry,
      }),
      context,
    )
  })

  const pollContext = (over: Record<string, unknown>) =>
    makeContext({...READS, uiMultiplier: WAD, newUIMultiplier: 0n, effectiveAt: 0n, oraclePaused: false, paused: false, isBlocked: false, ...over}, db)

  it('records the first observation and then stays silent while nothing moves', async () => {
    const c = pollContext({})
    await run('constituentPoll:block', makeEvent({args: {}, blockNumber: 300n}), c)
    expect(db.count(schema.multiplierPoint)).toBe(1)
    expect(db.rows(schema.multiplierPoint)[0]!.changed).toBe('first')

    await run('constituentPoll:block', makeEvent({args: {}, blockNumber: 600n}), c)
    expect(db.count(schema.multiplierPoint)).toBe(1)
  })

  it('records a dividend-shaped step as a state diff', async () => {
    await run('constituentPoll:block', makeEvent({args: {}, blockNumber: 300n}), pollContext({}))
    const stepped = pollContext({uiMultiplier: (WAD * 10_050n) / 10_000n})
    await run('constituentPoll:block', makeEvent({args: {}, blockNumber: 600n}), stepped)

    const points = db.rows(schema.multiplierPoint)
    expect(points).toHaveLength(2)
    expect(points[1]!.changed).toBe('multiplier')
    expect(points[1]!.deltaBps).toBe(50)
    expect((await db.find(schema.constituent, {id: '1'}))!.uiMultiplierX18).toBe((WAD * 10_050n) / 10_000n)
  })

  it('records a scheduled change and an issuer pause', async () => {
    await run('constituentPoll:block', makeEvent({args: {}, blockNumber: 300n}), pollContext({}))
    const scheduled = pollContext({newUIMultiplier: 2n * WAD, effectiveAt: 1_789_000_000n, oraclePaused: true})
    await run('constituentPoll:block', makeEvent({args: {}, blockNumber: 600n}), scheduled)
    const point = db.rows(schema.multiplierPoint)[1]!
    expect(String(point.changed)).toContain('scheduled')
    expect(String(point.changed)).toContain('oraclePaused')
    expect(point.effectiveAt).toBe(1_789_000_000n)
  })

  it('raises the denylist alarm when isBlocked comes back true for the vault', async () => {
    await run('constituentPoll:block', makeEvent({args: {}, blockNumber: 300n}), pollContext({}))
    const blocked = pollContext({isBlocked: true})
    await run('constituentPoll:block', makeEvent({args: {}, blockNumber: 600n}), blocked)
    const [alarm] = db.rows(schema.denylistAlarm)
    expect(alarm!.detection).toBe('probe')
    expect(alarm!.severity).toBe('critical')
    expect(alarm!.constituentId).toBe(1)
  })

  it('leaves the cached value in place when a probe reverts', async () => {
    await run('constituentPoll:block', makeEvent({args: {}, blockNumber: 300n}), pollContext({}))
    const broken = pollContext({uiMultiplier: new Error('beacon upgraded under us')})
    await run('constituentPoll:block', makeEvent({args: {}, blockNumber: 600n}), broken)
    expect(db.count(schema.multiplierPoint)).toBe(1)
    expect((await db.find(schema.constituent, {id: '1'}))!.uiMultiplierX18).toBe(WAD)
  })
})

describe('the bounty pot', () => {
  it('records the payment and the keeper job behind it', async () => {
    await run(
      'BountyPot:BountyPaid',
      makeEvent({
        args: {
          to: CALLER,
          workValueUsd18: WAD,
          paidUsd18: WAD,
          paidRaw: 10n ** 6n,
          reason: REASON('compound'),
        },
        blockNumber: 90n,
        logIndex: 0,
        input: toFunctionSelector('compound(bytes32)'),
        address: ADDRESSES.BountyPot,
      }),
      context,
    )
    const [payment] = db.rows(schema.bountyPayment)
    expect(payment!.reason).toBe('compound')
    expect(payment!.paidUsd18).toBe(WAD)
    const [job] = db.rows(schema.keeperJob)
    expect(job!.job).toBe('compound')
    expect(job!.bountyPaidUsd18).toBe(WAD)
  })
})

/**
 * The four disclosures the audited contracts added, all of them the same shape: a fact a hostile or
 * frozen counterparty could otherwise have turned into a permanent revert is now emitted instead.
 * The indexer's job is therefore to make each of them *visible*, and — just as importantly — to
 * leave NAV, the supply and the market's issuance history alone, because none of them moves money.
 */
describe('the disclosures that replaced reverts', () => {
  /** `AmpsBonds.CollateralAdded`, which is what materialises the collateral to market index. */
  async function addMarket(
    marketId = 1,
    collateral: `0x${string}` = TOKEN,
    constituentId = 1,
  ): Promise<void> {
    await run(
      'AmpsBonds:CollateralAdded',
      makeEvent({
        args: {marketId, collateral, class: 0, constituentId},
        blockNumber: 50n,
        logIndex: 0,
        address: ADDRESSES.AmpsBonds,
      }),
      context,
    )
  }

  it('raises a sweep-residue alert naming the token the vault could not absorb', async () => {
    await run(
      'PoolRegistry:ConstituentAdded',
      makeEvent({
        args: {constituentId: 1, token: TOKEN, poolId: POOL_ID, targetWeightBps: 500},
        blockNumber: 60n,
        logIndex: 0,
        address: ADDRESSES.PoolRegistry,
      }),
      context,
    )
    await run(
      'AmpsVault:SweepResidue',
      sweepResidue({balance: 1n}, {blockNumber: 61n, logIndex: 3}),
      context,
    )

    const alerts = db.rows(schema.alert).filter((a) => a.kind === 'sweep-residue')
    expect(alerts).toHaveLength(1)
    // Disclosure, not a breach: the residue is still backing, valued in `A` and paid out by
    // redemption, so it pages at `warning` rather than `critical`.
    expect(alerts[0]!.severity).toBe('warning')
    expect(alerts[0]!.subject).toBe(TOKEN)
    expect(alerts[0]!.id).toBe('000000000061-000003')
    const detail = alerts[0]!.detail as Record<string, unknown>
    expect(detail.balance).toBe('1')
    expect(detail.constituentId).toBe(1)

    // Nothing about the vault's money moved.
    expect(db.count(schema.navCheckpoint)).toBe(0)
    expect(db.count(schema.burnEvent)).toBe(0)
  })

  it('still records a residue for a token that is not one of ours', async () => {
    const donated = '0x00000000000000000000000000000000000000f9' as const
    await run(
      'AmpsVault:SweepResidue',
      sweepResidue({token: donated, balance: 7n}, {blockNumber: 62n, logIndex: 0}),
      context,
    )
    const [alert] = db.rows(schema.alert)
    expect(alert!.subject).toBe(donated)
    expect((alert!.detail as Record<string, unknown>).constituentId).toBeNull()
  })

  it('attributes forwarded collateral to its market and accumulates it there', async () => {
    await addMarket()
    await run(
      'AmpsBonds:CollateralForwarded',
      collateralForwarded({amount: 3n}, {blockNumber: 52n, logIndex: 4}),
      context,
    )
    await run(
      'AmpsBonds:CollateralForwarded',
      collateralForwarded({amount: 5n}, {blockNumber: 53n, logIndex: 2}),
      context,
    )

    const market = await db.find(schema.bondMarket, {id: '1'})
    expect(market!.forwardedCollateral).toBe(8n)
    // A donation is not issuance: nothing else on the market moved.
    expect(market!.totalCollateral).toBe(0n)
    expect(market!.bondCount).toBe(0)

    const state = await db.find(schema.parameterState, {id: 'bonds:collateralForwarded:1'})
    expect(state!.value).toBe(5n)
    expect(db.rows(schema.parameterChange)).toHaveLength(2)
  })

  it('buckets a forward whose collateral it cannot place under market 0', async () => {
    await addMarket()
    await run(
      'AmpsBonds:CollateralForwarded',
      collateralForwarded({collateral: COUNTER, amount: 9n}, {blockNumber: 54n, logIndex: 0}),
      context,
    )
    expect((await db.find(schema.bondMarket, {id: '1'}))!.forwardedCollateral).toBe(0n)
    const state = await db.find(schema.parameterState, {id: 'bonds:collateralForwarded:0'})
    expect(state!.value).toBe(9n)
  })

  it('detaches a market when its collateral is removed, and forgets the reverse lookup', async () => {
    await addMarket()
    expect((await db.find(schema.collateralIndex, {id: TOKEN}))!.marketId).toBe(1)

    await run(
      'AmpsBonds:CollateralRemoved',
      makeEvent({
        args: {marketId: 1, collateral: TOKEN},
        blockNumber: 55n,
        logIndex: 0,
        address: ADDRESSES.AmpsBonds,
      }),
      context,
    )

    const market = await db.find(schema.bondMarket, {id: '1'})
    expect(market!.open).toBe(false)
    expect(market!.detached).toBe(true)
    // The market row survives — its issuance history is still true — but the lookup is gone, so a
    // later forward of the same collateral cannot be attributed to a market that no longer owns it.
    expect(await db.find(schema.collateralIndex, {id: TOKEN})).toBeNull()
  })

  it('records the registry finding the bond market already gone', async () => {
    await addMarket()
    await run(
      'PoolRegistry:BondMarketDetached',
      bondMarketDetached({constituentId: 1, marketId: 1}, {blockNumber: 56n, logIndex: 1}),
      context,
    )

    expect((await db.find(schema.bondMarket, {id: '1'}))!.detached).toBe(true)
    const [detached] = db.rows(schema.constituentEvent).filter((e) => e.kind === 'bondMarketDetached')
    expect(detached!.constituentId).toBe(1)
    expect(detached!.field).toBe('marketId')
    expect(detached!.newValue).toBe(1n)
    expect(detached!.id).toBe('000000000056-000001')
  })

  it('logs the detachment even when the market was never indexed', async () => {
    await run(
      'PoolRegistry:BondMarketDetached',
      bondMarketDetached({constituentId: 4, marketId: 9}, {blockNumber: 57n, logIndex: 0}),
      context,
    )
    expect(db.count(schema.bondMarket)).toBe(0)
    expect(db.rows(schema.constituentEvent)).toHaveLength(1)
  })

  it('follows the vault pointer through the registry and the hook', async () => {
    await run(
      'PoolRegistry:VaultChanged',
      vaultChanged('PoolRegistry', {}, {blockNumber: 80n, logIndex: 0}),
      context,
    )
    await run(
      'AmpsHook:VaultChanged',
      vaultChanged('AmpsHook', {}, {blockNumber: 80n, logIndex: 1}),
      context,
    )

    const registry = await db.find(schema.parameterState, {id: 'registry.pointer:vault'})
    expect(registry!.addressValue).toBe(NEW_VAULT)
    expect(registry!.previousAddress).toBe(ADDRESSES.AmpsVault)
    const hook = await db.find(schema.parameterState, {id: 'hook.pointer:vault'})
    expect(hook!.addressValue).toBe(NEW_VAULT)
    // Same shape as the pointers `AmpsBonds`, `AmpsStaking` and `BountyPot` already emit, so the
    // Governance page reads one table for all of them.
    expect(db.rows(schema.parameterChange).filter((c) => c.name === 'vault')).toHaveLength(2)
  })
})
