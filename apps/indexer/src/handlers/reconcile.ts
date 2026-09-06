// SPDX-License-Identifier: MIT

/**
 * NAV and inventory reconciliation, and the share-class sample that goes with it.
 *
 * Two triggers, both landing in the same `reconciliation` table:
 *
 * - **`checkpoint`** — every block that carried a `NavCheckpoint`, which is every block in which
 *   the numbers the dApp displays could have moved. This is the one the Phase 5 exit criterion is
 *   about ("indexed NAV/share and `P_ref` reconcile with on-chain reads at every block").
 * - **`interval`** — every `AMPS_RECONCILE_POLL_BLOCKS` blocks, so a chain that is quiet (or an
 *   indexer that has fallen behind on a checkpoint) still produces a heartbeat row.
 *
 * The comparison itself is `src/lib/reconcile.ts`; this module only supplies the two sides. The
 * chain side is read **at the event's own block**, never at head, so a divergence is a real
 * disagreement rather than a race.
 */

import {ampsAbi, ampsVaultAbi} from '@amplestocks/abis'
import schema from 'ponder:schema'

import {readEnv} from '../config/env'
import {jobId} from '../lib/ids'
import {reconcile, reconcileSeverity} from '../lib/reconcile'
import {STATE, getState, raiseAlert, updateSummary, type Db} from '../lib/store'
import {jsonRecord} from '../lib/json'

const env = readEnv()

const ZERO = '0x0000000000000000000000000000000000000000'

/**
 * The slice of a Ponder indexing context these jobs need.
 *
 * `readContract` is deliberately widened: Ponder's own signature is generic over the ABI and the
 * function name, which cannot be expressed for a call site that picks the function by string at
 * runtime. The narrowing happens at the `read<T>()` boundary below, where the return type is named
 * once per call.
 */
export interface JobContext {
  db: Db
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  client: {readContract: (...args: any[]) => Promise<any>}
  contracts: Record<string, {address?: unknown}>
}

const addressOf = (context: JobContext, name: string): `0x${string}` =>
  (context.contracts[name]?.address as `0x${string}` | undefined) ?? (ZERO as `0x${string}`)

const read = async <T>(
  context: JobContext,
  address: `0x${string}`,
  abi: unknown,
  functionName: string,
  args: unknown[] = [],
): Promise<T | undefined> => {
  if (address === ZERO) return undefined
  try {
    return (await context.client.readContract({abi, address, functionName, args})) as T
  } catch {
    return undefined
  }
}

/**
 * Sample the four share classes from chain. `inventoryAmps()` is the vault's own view (ERC-20 plus
 * the ERC-6909 claim, §12 ruling F); the other three are plain balances, which is exactly what they
 * are on-chain — no accounting is invented here.
 */
export async function sampleShares(
  context: JobContext,
  blockNumber: bigint,
  timestamp: bigint,
  source: string,
): Promise<void> {
  const amps = addressOf(context, 'AmpsToken')
  const vault = addressOf(context, 'AmpsVault')
  const staking = addressOf(context, 'AmpsStaking')
  const bonds = addressOf(context, 'AmpsBonds')
  if (amps === ZERO || vault === ZERO) return

  // Nothing to sample until the vault has produced *something*: before genesis the contracts may
  // not even be deployed at this block, and a read against an empty address is an RPC round trip
  // (and, in Ponder, four retries) that can only fail. The summary row is created by the first
  // vault event the indexer sees, which is `Genesis` on a chain indexed from the deployment.
  const summary = await context.db.find(schema.vaultSummary, {id: 'singleton'})
  if (summary === null) return
  const vesting = (summary.teamVestingWallet as `0x${string}` | undefined) ?? ZERO

  const [totalSupply, inventory, stakedRaw, vestingRaw, bondRaw] = await Promise.all([
    read<bigint>(context, amps, ampsAbi, 'totalSupply'),
    read<bigint>(context, vault, ampsVaultAbi, 'inventoryAmps'),
    read<bigint>(context, amps, ampsAbi, 'balanceOf', [staking]),
    read<bigint>(context, amps, ampsAbi, 'balanceOf', [vesting]),
    read<bigint>(context, amps, ampsAbi, 'balanceOf', [bonds]),
  ])
  if (totalSupply === undefined) return

  const staked = stakedRaw ?? 0n
  const vested = vestingRaw ?? 0n
  const bondUnvested = bondRaw ?? 0n
  const held = inventory ?? 0n
  const circulating = totalSupply - held - vested - staked - bondUnvested

  await context.db
    .insert(schema.sharePoint)
    .values({
      id: jobId(blockNumber, 'shares'),
      blockNumber,
      timestamp,
      totalSupply,
      inventory: held,
      vesting: vested,
      staked,
      bondUnvested,
      circulating: circulating > 0n ? circulating : 0n,
      source,
    })
    .onConflictDoUpdate(() => ({
      totalSupply,
      inventory: held,
      vesting: vested,
      staked,
      bondUnvested,
      circulating: circulating > 0n ? circulating : 0n,
      source,
    }))

  await updateSummary(context.db, blockNumber, timestamp, () => ({
    totalSupply,
    inventory: held,
    vesting: vested,
    staked,
    circulating: circulating > 0n ? circulating : 0n,
  }))
}

/**
 * Re-run a reconciliation this block has already done, now that a later event in the same block has
 * moved the event-derived supply. No-op when this block has not been reconciled.
 *
 * This is what makes the supply pair comparable at all. A chain read is end-of-block state, and
 * `depositBonded` writes its checkpoint *before* it settles and mints (phase-2 §6), so the run
 * triggered by that checkpoint sees a pre-mint indexed supply against a post-mint chain read. The
 * `VestingMinted` that follows it in the same block calls this, the row is rewritten from the state
 * after the mint, and the two sides line up — without adding a row, a trigger or a chain read to any
 * block that did not already have one.
 */
export async function reconcileAgain(
  context: JobContext,
  blockNumber: bigint,
  timestamp: bigint,
): Promise<void> {
  const existing = await context.db.find(schema.reconciliation, {id: blockNumber.toString()})
  if (existing === null) return
  await runReconciliation(context, blockNumber, timestamp, 'checkpoint')
}

/**
 * Compare the index against the chain at `blockNumber` and record the result. Raises an alert on a
 * breach of the dust bound; never throws, because a reconciliation failure must not stop indexing.
 */
export async function runReconciliation(
  context: JobContext,
  blockNumber: bigint,
  timestamp: bigint,
  trigger: 'checkpoint' | 'interval',
): Promise<void> {
  const vault = addressOf(context, 'AmpsVault')
  const amps = addressOf(context, 'AmpsToken')
  if (vault === ZERO || amps === ZERO) return

  // Read the *indexed* side first and bail before touching the chain. Before the first checkpoint
  // there is nothing to compare, a "divergence" from zero is an artefact of the start block rather
  // than a fault, and the contracts may not be deployed at this block at all. `_checkpoint()` writes
  // `NavCheckpoint` and `RefCheckpoint` in the same call, one log index apart, so waiting for both
  // costs a single handler invocation.
  const navIndexed = (await getState(context.db, STATE.navPerShareX18)) ?? 0n
  const pRefIndexed = (await getState(context.db, STATE.pRefX18)) ?? 0n
  const supplyIndexed = (await getState(context.db, STATE.supplyEvented)) ?? 0n
  if (navIndexed === 0n || pRefIndexed === 0n) return

  const [checkpoint, preview, assets, inventory, supply] = await Promise.all([
    read<{navPerShareX18: bigint; pRefX18: bigint; pMktX18: bigint; timestamp: number; blockNumber: number}>(
      context,
      vault,
      ampsVaultAbi,
      'checkpointData',
    ),
    read<bigint>(context, vault, ampsVaultAbi, 'previewNavPerShareX18'),
    read<bigint>(context, vault, ampsVaultAbi, 'totalAssetsUsd18'),
    read<bigint>(context, vault, ampsVaultAbi, 'inventoryAmps'),
    read<bigint>(context, amps, ampsAbi, 'totalSupply'),
  ])
  if (checkpoint === undefined || supply === undefined) return

  const assetsIndexed = (await getState(context.db, STATE.totalAssetsUsd18)) ?? 0n
  const summary = await context.db.find(schema.vaultSummary, {id: 'singleton'})
  const inventoryIndexed = summary?.inventory ?? 0n

  const result = reconcile({
    trigger,
    dustBps: env.dustBps,
    dustWei: env.dustWei,
    navIndexedX18: navIndexed,
    navOnChainX18: checkpoint.navPerShareX18,
    navPreviewX18: preview ?? checkpoint.navPerShareX18,
    pRefIndexedX18: pRefIndexed,
    pRefOnChainX18: checkpoint.pRefX18,
    supplyIndexed,
    supplyOnChain: supply,
    inventoryIndexed,
    inventoryOnChain: inventory ?? inventoryIndexed,
    assetsIndexedUsd18: assetsIndexed,
    assetsOnChainUsd18: assets ?? assetsIndexed,
  })

  await context.db
    .insert(schema.reconciliation)
    .values({
      id: blockNumber.toString(),
      blockNumber,
      timestamp,
      trigger,
      navIndexedX18: navIndexed,
      navOnChainX18: checkpoint.navPerShareX18,
      navDeltaWei: result.navDeltaWei,
      navDeltaBps: result.navDeltaBps,
      navPreviewX18: preview ?? 0n,
      previewDeltaBps: result.previewDeltaBps,
      pRefIndexedX18: pRefIndexed,
      pRefOnChainX18: checkpoint.pRefX18,
      pRefDeltaWei: result.pRefDeltaWei,
      pRefDeltaBps: result.pRefDeltaBps,
      supplyIndexed,
      supplyOnChain: supply,
      supplyDeltaWei: result.supplyDeltaWei,
      inventoryIndexed,
      inventoryOnChain: inventory ?? inventoryIndexed,
      inventoryDeltaWei: result.inventoryDeltaWei,
      assetsIndexedUsd18: assetsIndexed,
      assetsOnChainUsd18: assets ?? assetsIndexed,
      assetsDeltaBps: result.assetsDeltaBps,
      dustBps: env.dustBps,
      dustWei: env.dustWei,
      ok: result.ok,
      breached: result.breached,
    })
    // A block can carry several checkpoints (a `compound` writes one at entry and one at exit).
    // The *last* run in the block is the one that matters, so every column is rewritten, not a
    // handful — a partial patch would leave the row a mixture of two different moments.
    .onConflictDoUpdate(() => ({
      timestamp,
      trigger,
      navIndexedX18: navIndexed,
      navOnChainX18: checkpoint.navPerShareX18,
      navDeltaWei: result.navDeltaWei,
      navDeltaBps: result.navDeltaBps,
      navPreviewX18: preview ?? 0n,
      previewDeltaBps: result.previewDeltaBps,
      pRefIndexedX18: pRefIndexed,
      pRefOnChainX18: checkpoint.pRefX18,
      pRefDeltaWei: result.pRefDeltaWei,
      pRefDeltaBps: result.pRefDeltaBps,
      supplyIndexed,
      supplyOnChain: supply,
      supplyDeltaWei: result.supplyDeltaWei,
      inventoryIndexed,
      inventoryOnChain: inventory ?? inventoryIndexed,
      inventoryDeltaWei: result.inventoryDeltaWei,
      assetsIndexedUsd18: assetsIndexed,
      assetsOnChainUsd18: assets ?? assetsIndexed,
      assetsDeltaBps: result.assetsDeltaBps,
      ok: result.ok,
      breached: result.breached,
    }))

  if (result.ok) {
    // A re-run that comes back clean retracts the alert the earlier run in this block raised, so a
    // pre-mint checkpoint inside a bond does not leave a page behind after the mint reconciled it.
    await context.db.delete(schema.alert, {id: jobId(blockNumber, 'reconciliation')})
    return
  }

  {
    await raiseAlert(context.db, jobId(blockNumber, 'reconciliation'), {
      kind: 'reconciliation',
      severity: reconcileSeverity(result),
      subject: blockNumber.toString(),
      message: `indexed state diverged from chain at block ${blockNumber}: ${result.breached}`,
      blockNumber,
      timestamp,
      detail: jsonRecord({
        breached: result.breachedFields,
        navIndexed,
        navOnChain: checkpoint.navPerShareX18,
        navDeltaBps: result.navDeltaBps,
        pRefIndexed,
        pRefOnChain: checkpoint.pRefX18,
        pRefDeltaBps: result.pRefDeltaBps,
        supplyIndexed,
        supplyOnChain: supply,
        inventoryIndexed,
        inventoryOnChain: inventory ?? inventoryIndexed,
        dustBps: env.dustBps,
        dustWei: env.dustWei,
      }),
    })
  }
}
