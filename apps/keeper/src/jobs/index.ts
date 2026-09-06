// SPDX-License-Identifier: MIT

/**
 * The five jobs: how each one is encoded, simulated and priced.
 *
 * Every send is preceded by an `eth_call` and an `eth_estimateGas` against the same block. That is not
 * belt-and-braces — it is where four of the placement gauntlet's nine guards actually become visible:
 *
 *  * the R1 post-condition (`navAfter >= navBefore x (1 - 2 bp)`), which is a revert and nothing else;
 *  * the divergence check **at exit**, which depends on where the placement leaves the tick;
 *  * the `sweepClean` invariant at function exit;
 *  * the 60-second cooldown, whose revert carries the exact `readyAt` the keeper then caches.
 *
 * A simulation that reverts is a decision, not an error: `PlacementCooldown` means "wait, and here is until
 * when", `GateNotHealthy` means "the gate moved between the read and the call", `NavBleedExceeded` means "this
 * placement would bleed NAV and the vault is right to refuse it".
 */

import {
  decodeErrorResult,
  encodeFunctionData,
  parseAbi,
  BaseError,
  ContractFunctionRevertedError,
  type Address,
  type Hex,
  type PublicClient,
} from 'viem'
import {ampsVaultAbi} from '@amplestocks/abis'
import type {JobCandidate, JobKind, Simulation} from '../domain/types.js'

/**
 * The custom errors the keeper decodes.
 *
 * They live in `contracts/src/types/Errors.sol` and are thrown from `VaultPlacementLib` / `VaultRolloutLib`,
 * which are **linked libraries**: solc puts their errors in the library's ABI, not the vault's, so the vault
 * ABI this package exports cannot decode a revert that comes from one. Restating the six signatures the keeper
 * reacts to is the smallest honest fix; anything not on this list is reported by its raw selector.
 */
export const KEEPER_ERROR_ABI = parseAbi([
  'error PlacementCooldown(bytes32 poolId, uint32 readyAt)',
  'error PlacementDiverged(bytes32 poolId, int24 poolTick, int24 fairTick, int24 maxTicks)',
  'error GateNotHealthy(uint8 state, bytes32 poolId)',
  'error NavBleedExceeded(uint256 navBefore, uint256 navAfter, uint16 maxBleedBps)',
  'error CellBudgetExceeded(bytes32 poolId, uint32 liveCells, uint32 budget)',
  'error RolloutLimitExceeded(bytes32 limit, uint256 requested, uint256 available)',
  'error InsufficientInventory(uint256 requested, uint256 available)',
  'error UnknownPool(bytes32 poolId)',
  'error UnknownConstituent(uint16 constituentId)',
  'error ConstituentFrozen(uint16 constituentId, uint32 until)',
  'error StaleCheckpoint(uint32 age, uint32 maxAge)',
  'error SweepDirty(address token, uint256 balance)',
  'error BeyondRail(bytes32 poolId, int24 devTicks, int24 outerRailTicks)',
  'error OffGrid(bytes32 poolId, int24 lowerTick, int24 gridBaseTick, int24 cellWidth)',
  'error WrongSide(bytes32 poolId, bool above, int24 bucketTick, int24 boundTick)',
  'error Reentrancy()',
])

/** The vault call one job makes. */
export function encodeJob(job: JobCandidate): Hex {
  switch (job.kind) {
    case 'compound':
      return encodeFunctionData({abi: ampsVaultAbi, functionName: 'compound', args: [job.target as Hex]})
    case 'rollout':
      return encodeFunctionData({abi: ampsVaultAbi, functionName: 'rollout', args: [Number(job.target)]})
    case 'deployBonded':
      return encodeFunctionData({abi: ampsVaultAbi, functionName: 'deployBonded', args: [Number(job.target)]})
    case 'checkpoint':
      return encodeFunctionData({abi: ampsVaultAbi, functionName: 'checkpoint', args: []})
    case 'touch':
      return encodeFunctionData({abi: ampsVaultAbi, functionName: 'touch', args: []})
  }
}

function callArgs(job: JobCandidate): {functionName: string; args: readonly unknown[]} {
  switch (job.kind) {
    case 'compound':
      return {functionName: 'compound', args: [job.target as Hex]}
    case 'rollout':
      return {functionName: 'rollout', args: [Number(job.target)]}
    case 'deployBonded':
      return {functionName: 'deployBonded', args: [Number(job.target)]}
    case 'checkpoint':
      return {functionName: 'checkpoint', args: []}
    case 'touch':
      return {functionName: 'touch', args: []}
  }
}

/**
 * Pulls the revert data out of whatever wrapped it, and decodes it if the signature is one we know.
 *
 * Three sources, in order of trust: viem's own decoded `ContractFunctionRevertedError.data` (which covers every
 * error declared on the vault ABI); the raw revert bytes viem carries alongside it; and, last, a hex blob
 * scraped out of the error text, because a library's custom error is not on the vault's ABI and several RPC
 * implementations only surface it as a string.
 */
export function decodeRevert(error: unknown): Simulation['revert'] {
  const candidates: string[] = []

  if (error instanceof BaseError) {
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError)
    if (reverted instanceof ContractFunctionRevertedError) {
      if (reverted.data !== undefined) {
        return {
          name: reverted.data.errorName,
          args: (reverted.data.args ?? []) as readonly unknown[],
          raw: typeof reverted.raw === 'string' ? reverted.raw : '',
        }
      }
      if (typeof reverted.raw === 'string') candidates.push(reverted.raw)
    }
    if (error.details !== undefined) candidates.push(error.details)
    if (error.shortMessage !== undefined) candidates.push(error.shortMessage)
    candidates.push(error.message)
  } else if (error instanceof Error) {
    candidates.push(error.message)
  } else {
    candidates.push(String(error))
  }

  for (const candidate of candidates) {
    const match = /0x[0-9a-fA-F]{8,}/.exec(candidate)
    if (match === null) continue
    const data = match[0] as Hex
    try {
      const decoded = decodeErrorResult({abi: KEEPER_ERROR_ABI, data})
      return {name: decoded.errorName, args: (decoded.args ?? []) as readonly unknown[], raw: data}
    } catch {
      return {name: 'Unknown', args: [], raw: data}
    }
  }

  return {name: 'Unknown', args: [], raw: (candidates[0] ?? '').slice(0, 256)}
}

/**
 * `eth_call` + `eth_estimateGas` for one job, from the keeper's own sender.
 *
 * The estimate is taken only when the call succeeds: estimating a reverting call wastes a round trip and tells
 * us nothing. `gasEstimate` is therefore zero on a revert, which is exactly what {@link qualify} wants — a
 * reverted job has no cost to weigh.
 */
export async function simulateJob(
  client: PublicClient,
  vault: Address,
  sender: Address,
  job: JobCandidate,
): Promise<Simulation> {
  const {functionName, args} = callArgs(job)
  try {
    const {result} = await client.simulateContract({
      account: sender,
      address: vault,
      abi: ampsVaultAbi,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- the union of five signatures
      functionName: functionName as any,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      args: args as any,
    })
    const gasEstimate = await client.estimateContractGas({
      account: sender,
      address: vault,
      abi: ampsVaultAbi,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      functionName: functionName as any,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      args: args as any,
    })
    return {ok: true, result, gasEstimate}
  } catch (error) {
    return {ok: false, gasEstimate: 0n, revert: decodeRevert(error)}
  }
}

/**
 * When a reverting simulation says the job can be retried, and when.
 *
 * `PlacementCooldown` is the only revert that carries its own answer; everything else is re-screened on the
 * next scan from fresh reads.
 */
export function retryAfter(simulation: Simulation): number | null {
  return cooldownFrom(simulation)?.readyAt ?? null
}

/**
 * The pool and the timestamp a `PlacementCooldown` revert names.
 *
 * The pool matters as much as the time: a `rollout` is addressed by constituent id but harvests from the two
 * **entry** pools, so the cooldown it trips is theirs. Taking the id out of the error rather than off the job
 * is what lets one refused rollout teach the keeper about a pool it was not asking about.
 */
export function cooldownFrom(simulation: Simulation): {poolId: `0x${string}`; readyAt: number} | null {
  if (simulation.ok || simulation.revert?.name !== 'PlacementCooldown') return null
  const [poolId, readyAt] = simulation.revert.args
  if (typeof poolId !== 'string' || !poolId.startsWith('0x')) return null
  return {poolId: poolId as `0x${string}`, readyAt: typeof readyAt === 'number' ? readyAt : Number(readyAt)}
}

/** Human label for the metrics, one per decoded error name. */
export function revertLabel(simulation: Simulation): string {
  return simulation.revert?.name ?? 'Unknown'
}

/** The jobs, in the order the runner considers them. */
export const JOB_ORDER: readonly JobKind[] = ['touch', 'checkpoint', 'compound', 'deployBonded', 'rollout']
