// SPDX-License-Identifier: MIT

/**
 * Everything the keeper reads, and nothing it writes.
 *
 * Two ideas run through this file.
 *
 * **The topology is a read, not a config file.** The keeper is given one address — AMPS — and resolves the rest
 * every time it refreshes: `Amps.vault()` names the live vault, so an `emergencyMigrate` is followed without a
 * restart, and the vault names the registry, the bonds, the bounty pot, the oracle gate and the hook
 * (`marketReference`). A governance pointer move is therefore a value that changes between two scans rather
 * than an outage.
 *
 * **Nothing here can revert the scan.** Every read is a `view` chosen because it is documented not to revert
 * (`OracleGate.isPlacementAllowed`, `BountyPot.quote`, `AmpsVault.checkpointData`), and the few that can are
 * wrapped so one unreachable pool degrades that pool rather than the cycle.
 */

import {erc20Abi, type Address, type PublicClient} from 'viem'
import {
  ampsAbi,
  ampsHookAbi,
  ampsVaultAbi,
  bountyPotAbi,
  feedRegistryAbi,
  oracleGateAbi,
  poolManagerAbi,
  poolRegistryAbi,
} from '@amplestocks/abis'
import {
  GateState,
  PoolClass,
  Session,
  type ChainSnapshot,
  type ConstituentSnapshot,
  type PoolSnapshot,
  type PotSnapshot,
  type VaultSnapshot,
} from '../domain/types.js'
import {VAULT_REPORTED_GAS_ALLOWANCE_USD18, VAULT_REPORTED_WORK_VALUE_USD18} from '../domain/bounty.js'
import type {Logger} from '../logger.js'

/** Every address the keeper talks to, all of them derived from AMPS. */
export interface Topology {
  readonly amps: Address
  readonly vault: Address
  readonly registry: Address
  readonly bonds: Address
  readonly staking: Address
  readonly bountyPot: Address
  readonly oracleGate: Address
  /** `AmpsVault.marketReference()`, which is `AmpsHook` from the Phase 3 wiring onward. */
  readonly hook: Address
  readonly poolManager: Address
  readonly feedRegistry: Address
}

const ZERO: Address = '0x0000000000000000000000000000000000000000'

/** `PriceLib.counterValueUsd18`, in TypeScript. */
export function counterValueUsd18(amountRaw: bigint, decimals: number, priceUsd8: bigint): bigint {
  if (priceUsd8 === 0n) return 0n
  return (amountRaw * priceUsd8 * 10n ** 10n) / 10n ** BigInt(decimals)
}

/** The v4 currency id of an ERC-20: `uint256(uint160(token))`. */
export function currencyId(token: Address): bigint {
  return BigInt(token)
}

export class ChainReader {
  private readonly client: PublicClient
  private readonly logger: Logger

  constructor(client: PublicClient, logger: Logger) {
    this.client = client
    this.logger = logger
  }

  /** Resolves the whole address graph from AMPS, or from a pinned vault on a fixture chain. */
  async topology(amps: Address, vaultOverride: Address | null): Promise<Topology> {
    const vault =
      vaultOverride ??
      ((await this.client.readContract({address: amps, abi: ampsAbi, functionName: 'vault'})) as Address)

    const read = async (name: 'registry' | 'bonds' | 'staking' | 'bountyPot' | 'oracleGate' | 'marketReference' | 'poolManager' | 'feedRegistry') =>
      (await this.client.readContract({address: vault, abi: ampsVaultAbi, functionName: name})) as Address

    const [registry, bonds, staking, bountyPot, oracleGate, hook, poolManager, feedRegistry] = await Promise.all([
      read('registry'),
      read('bonds'),
      read('staking'),
      read('bountyPot'),
      read('oracleGate'),
      read('marketReference'),
      read('poolManager'),
      read('feedRegistry'),
    ])

    return {amps, vault, registry, bonds, staking, bountyPot, oracleGate, hook, poolManager, feedRegistry}
  }

  private async vaultSnapshot(topology: Topology, now: number): Promise<VaultSnapshot> {
    const vault = {address: topology.vault, abi: ampsVaultAbi} as const
    const [checkpoint, liveCells, burnBps, stakerBps, creatorBps, deployThreshold, rolloutBpsPerDay, entryFloorBps] =
      await Promise.all([
        this.client.readContract({...vault, functionName: 'checkpointData'}),
        this.client.readContract({...vault, functionName: 'liveCells'}),
        this.client.readContract({...vault, functionName: 'burnBps'}),
        this.client.readContract({...vault, functionName: 'stakerBps'}),
        this.client.readContract({...vault, functionName: 'creatorBpsAt', args: [BigInt(now)]}),
        this.client.readContract({...vault, functionName: 'deployThresholdUsd18'}),
        this.client.readContract({...vault, functionName: 'rolloutBpsPerDay'}),
        this.client.readContract({...vault, functionName: 'entryFloorBps'}),
      ])

    const snapshot = checkpoint as {
      navPerShareX18: bigint
      pRefX18: bigint
      pMktX18: bigint
      timestamp: number
      blockNumber: number
    }

    return {
      address: topology.vault,
      navPerShareX18: snapshot.navPerShareX18,
      pRefX18: snapshot.pRefX18,
      pMktX18: snapshot.pMktX18,
      checkpointTimestamp: Number(snapshot.timestamp),
      liveCells: Number(liveCells as number),
      burnBps: Number(burnBps as number),
      stakerBps: Number(stakerBps as number),
      creatorBps: Number(creatorBps as number),
      deployThresholdUsd18: deployThreshold as bigint,
      rolloutBpsPerDay: Number(rolloutBpsPerDay as number),
      entryFloorBps: Number(entryFloorBps as number),
    }
  }

  private async potSnapshot(topology: Topology): Promise<PotSnapshot> {
    if (topology.bountyPot === ZERO) {
      return {
        address: ZERO,
        tipUsd18: 0n,
        chipBps: 0,
        chostUsd18: 0n,
        gasCapMultiple: 0,
        dailyCeilingUsd18: 0n,
        spentLast24hUsd18: 0n,
        budgetLeftUsd18: 0n,
        balanceRaw: 0n,
        usdScale: 1n,
        quotedPayableRaw: 0n,
        quotedReason: 'depleted',
      }
    }

    const pot = {address: topology.bountyPot, abi: bountyPotAbi} as const
    const [tip, chip, chost, gasCap, ceiling, spent, budget, balance, scale, quote] = await Promise.all([
      this.client.readContract({...pot, functionName: 'tipUsd18'}),
      this.client.readContract({...pot, functionName: 'chipBps'}),
      this.client.readContract({...pot, functionName: 'chostUsd18'}),
      this.client.readContract({...pot, functionName: 'gasCapMultiple'}),
      this.client.readContract({...pot, functionName: 'dailyCeilingUsd18'}),
      this.client.readContract({...pot, functionName: 'spentLast24h'}),
      this.client.readContract({...pot, functionName: 'budgetLeftUsd18'}),
      this.client.readContract({...pot, functionName: 'balance'}),
      this.client.readContract({...pot, functionName: 'usdScale'}),
      this.client.readContract({
        ...pot,
        functionName: 'quote',
        args: [VAULT_REPORTED_WORK_VALUE_USD18, VAULT_REPORTED_GAS_ALLOWANCE_USD18],
      }),
    ])

    const [payableRaw, reason] = quote as [bigint, `0x${string}`]
    return {
      address: topology.bountyPot,
      tipUsd18: tip as bigint,
      chipBps: Number(chip as number),
      chostUsd18: chost as bigint,
      gasCapMultiple: Number(gasCap as number),
      dailyCeilingUsd18: ceiling as bigint,
      spentLast24hUsd18: spent as bigint,
      budgetLeftUsd18: budget as bigint,
      balanceRaw: balance as bigint,
      usdScale: scale as bigint,
      quotedPayableRaw: payableRaw,
      quotedReason: decodeBytes32(reason),
    }
  }

  /** Every registered pool: the two entry pools plus one per constituent, retired ones included. */
  async poolIds(topology: Topology): Promise<`0x${string}`[]> {
    const registry = {address: topology.registry, abi: poolRegistryAbi} as const
    const [hub, weth, count] = await Promise.all([
      this.client.readContract({...registry, functionName: 'hubPoolId'}),
      this.client.readContract({...registry, functionName: 'wethPoolId'}),
      this.client.readContract({...registry, functionName: 'constituentCount'}),
    ])

    const ids: `0x${string}`[] = []
    for (const entry of [hub, weth] as `0x${string}`[]) {
      if (entry !== '0x0000000000000000000000000000000000000000000000000000000000000000') ids.push(entry)
    }

    const constituentIds = Array.from({length: Number(count as number)}, (_, i) => i + 1)
    const poolIds = await Promise.all(
      constituentIds.map((id) =>
        this.client.readContract({...registry, functionName: 'poolIdOf', args: [id]}) as Promise<`0x${string}`>,
      ),
    )
    for (const id of poolIds) {
      if (id !== '0x0000000000000000000000000000000000000000000000000000000000000000') ids.push(id)
    }
    return ids
  }

  private async poolSnapshot(
    topology: Topology,
    poolId: `0x${string}`,
    vault: VaultSnapshot,
    sellFeeBps: number,
    lastPlacementAt: number,
  ): Promise<PoolSnapshot | null> {
    const registry = {address: topology.registry, abi: poolRegistryAbi} as const
    const config = (await this.client.readContract({
      ...registry,
      functionName: 'poolConfig',
      args: [poolId],
    })) as {counter: Address; poolClass: number; counterDecimals: number; constituentId: number; registered: boolean}

    if (!config.registered) return null

    const gate = {address: topology.oracleGate, abi: oracleGateAbi} as const
    const hook = {address: topology.hook, abi: ampsHookAbi} as const
    const [gateSnapshot, placement, highWater, hookState, ladderCells] = await Promise.all([
      this.client.readContract({...gate, functionName: 'snapshotByPool', args: [poolId]}) as Promise<{
        state: number
        session: number
        feedStale: boolean
        corporateFreeze: boolean
        poolTick: number
        fairTick: number
      }>,
      this.client.readContract({...gate, functionName: 'isPlacementAllowed', args: [poolId]}) as Promise<
        readonly [boolean, boolean]
      >,
      this.client.readContract({...hook, functionName: 'highWaterTick', args: [poolId]}).catch(() => 0) as Promise<
        number
      >,
      // The hook's own packed words: what the fee schedule is doing, which the keeper watches but never acts
      // on. A pool the hook has never seen answers a zeroed struct rather than reverting.
      this.client
        .readContract({...hook, functionName: 'poolState', args: [poolId]})
        .catch(() => ({initialized: false, surgeBps: 0, lastSwapAt: 0})) as Promise<{
        initialized: boolean
        surgeBps: number
        lastSwapAt: number
      }>,
      this.client.readContract({
        address: topology.vault,
        abi: ampsVaultAbi,
        functionName: 'ladderLength',
        args: [poolId],
      }) as Promise<bigint>,
    ])

    return {
      poolId,
      poolClass: config.poolClass as PoolClass,
      constituentId: Number(config.constituentId),
      counter: config.counter,
      gateState: gateSnapshot.state as GateState,
      placementAllowed: placement[0],
      anchorAtNav: placement[1],
      poolTick: Number(gateSnapshot.poolTick),
      fairTick: Number(gateSnapshot.fairTick),
      ladderCells: Number(ladderCells),
      lastPlacementAt,
      highWaterTick: Number(highWater),
      surgeBps: Number(hookState.surgeBps),
      lastSwapAt: Number(hookState.lastSwapAt),
      hookInitialized: hookState.initialized === true,
      session: gateSnapshot.session as Session,
      feedStale: gateSnapshot.feedStale,
      corporateFreeze: gateSnapshot.corporateFreeze,
      pRefX18: vault.pRefX18,
      navPerShareX18: vault.navPerShareX18,
      sellFeeBps,
    }
  }

  private async constituentSnapshot(topology: Topology, constituentId: number): Promise<ConstituentSnapshot | null> {
    const registry = {address: topology.registry, abi: poolRegistryAbi} as const
    const config = (await this.client.readContract({
      ...registry,
      functionName: 'constituent',
      args: [constituentId],
    })) as {token: Address; status: number; decimals: number; rolloutWeightBps: number}

    if (config.token === ZERO) return null

    const poolId = (await this.client.readContract({
      ...registry,
      functionName: 'poolIdOf',
      args: [constituentId],
    })) as `0x${string}`

    const [claim, idleErc20, priceUsd8] = await Promise.all([
      this.client.readContract({
        address: topology.poolManager,
        abi: poolManagerAbi,
        functionName: 'balanceOf',
        args: [topology.vault, currencyId(config.token)],
      }) as Promise<bigint>,
      this.client.readContract({
        address: config.token,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [topology.vault],
      }) as Promise<bigint>,
      this.client
        .readContract({address: topology.feedRegistry, abi: feedRegistryAbi, functionName: 'priceUsd8', args: [config.token]})
        .catch(() => 0n) as Promise<bigint>,
    ])

    const idle = claim + idleErc20
    return {
      constituentId,
      token: config.token,
      poolId,
      decimals: Number(config.decimals),
      status: Number(config.status),
      idleCollateral: idle,
      idleCollateralUsd18: counterValueUsd18(idle, Number(config.decimals), priceUsd8),
      rolloutWeightBps: Number(config.rolloutWeightBps),
    }
  }

  /**
   * Seeds the cooldown clock from the ladder records at start-up.
   *
   * `AmpsVault._lastPlacementAt` is private and has no getter, so this reproduces
   * `11_GenesisPlacement.lastPlacementAt`: the newest `placedAt` across a pool's records. It is a **lower
   * bound** — a `compound` that relaid nothing stamps the vault's map without touching a record — so it is only
   * a seed. The authority is the simulation, which reverts `PlacementCooldown(poolId, readyAt)` and hands the
   * keeper the exact timestamp.
   */
  async seedLastPlacementAt(topology: Topology, poolIds: readonly `0x${string}`[]): Promise<Map<string, number>> {
    const out = new Map<string, number>()
    const vault = {address: topology.vault, abi: ampsVaultAbi} as const

    await Promise.all(
      poolIds.map(async (poolId) => {
        try {
          const length = Number(
            (await this.client.readContract({...vault, functionName: 'ladderLength', args: [poolId]})) as bigint,
          )
          let newest = 0
          const records = await Promise.all(
            Array.from({length}, (_, i) =>
              this.client.readContract({...vault, functionName: 'ladderAt', args: [poolId, BigInt(i)]}),
            ),
          )
          for (const record of records) {
            const placedAt = Number((record as readonly unknown[])[6] as number)
            if (placedAt > newest) newest = placedAt
          }
          out.set(poolId, newest)
        } catch (error) {
          this.logger.warn('ladder seed failed', {poolId, error})
        }
      }),
    )
    return out
  }

  /** One whole scan. */
  async snapshot(
    topology: Topology,
    lastPlacementAt: ReadonlyMap<string, number>,
    ethUsd18: bigint,
  ): Promise<ChainSnapshot> {
    const block = await this.client.getBlock({blockTag: 'latest'})
    const now = Number(block.timestamp)

    const gate = {address: topology.oracleGate, abi: oracleGateAbi} as const
    const [vault, pot, globalState, freezeUntil, watchdog, sellFeeBps] = await Promise.all([
      this.vaultSnapshot(topology, now),
      this.potSnapshot(topology),
      topology.oracleGate === ZERO
        ? Promise.resolve(GateState.GREEN)
        : (this.client.readContract({...gate, functionName: 'state', args: [0]}) as Promise<number>),
      topology.oracleGate === ZERO
        ? Promise.resolve(0)
        : (this.client.readContract({...gate, functionName: 'protocolFreezeUntil'}) as Promise<number>),
      topology.oracleGate === ZERO
        ? Promise.resolve([0, 0, false] as const)
        : (this.client.readContract({...gate, functionName: 'watchdog'}) as Promise<readonly [number, number, boolean]>),
      this.client.readContract({address: topology.hook, abi: ampsHookAbi, functionName: 'sellFeeBps'}).catch(() => 500) as Promise<number>,
    ])

    const ids = await this.poolIds(topology)
    const pools = (
      await Promise.all(
        ids.map((poolId) =>
          this.poolSnapshot(topology, poolId, vault, Number(sellFeeBps), lastPlacementAt.get(poolId) ?? 0).catch(
            (error: unknown) => {
              this.logger.warn('pool read failed', {poolId, error})
              return null
            },
          ),
        ),
      )
    ).filter((p): p is PoolSnapshot => p !== null)

    const count = Number(
      (await this.client.readContract({
        address: topology.registry,
        abi: poolRegistryAbi,
        functionName: 'constituentCount',
      })) as number,
    )
    const constituents = (
      await Promise.all(
        Array.from({length: count}, (_, i) =>
          this.constituentSnapshot(topology, i + 1).catch((error: unknown) => {
            this.logger.warn('constituent read failed', {constituentId: i + 1, error})
            return null
          }),
        ),
      )
    ).filter((c): c is ConstituentSnapshot => c !== null)

    return {
      now,
      blockNumber: block.number ?? 0n,
      globalGateState: Number(globalState) as GateState,
      protocolFreezeUntil: Number(freezeUntil),
      watchdogTripped: watchdog[2],
      vault,
      pot,
      pools,
      constituents,
      baseFeeWei: block.baseFeePerGas ?? 0n,
      ethUsd18,
    }
  }
}

/** `bytes32` holding a short ASCII string, as `BountyPot` emits its `reason`. */
export function decodeBytes32(value: `0x${string}`): string {
  const bytes = value.slice(2).match(/.{2}/g) ?? []
  let out = ''
  for (const byte of bytes) {
    const code = Number.parseInt(byte, 16)
    if (code === 0) break
    out += String.fromCharCode(code)
  }
  return out
}
