// SPDX-License-Identifier: MIT

/**
 * Contract errors, turned into something a person can act on.
 *
 * The named errors come from `contracts/src/types/Errors.sol` and `IAmpsHook`. Each one has
 * exactly one honest explanation and exactly one next step, and none of them is "try again with
 * more slippage" unless that is genuinely the fix.
 */

import {BaseError, ContractFunctionRevertedError, decodeErrorResult, type Abi, type Hex} from 'viem'

export interface SurfacedError {
  /** The Solidity error name, when one was decoded. */
  name: string | null
  title: string
  detail: string
  /** What the user can actually do. Empty when nothing they do changes it. */
  action: string
  /** Decoded arguments, for the details disclosure. */
  args?: readonly unknown[]
}

const CATALOGUE: Readonly<Record<string, Omit<SurfacedError, 'name' | 'args'>>> = {
  BeyondRail: {
    title: 'Beyond the outer rail',
    detail:
      'This swap starts outside the pool’s outer rail on the side that would push the price further away, so the hook refuses it. Swaps that move the price back toward the reference are never refused.',
    action: 'Trade in the opposite direction, or wait for the pool to come back inside the rail.',
  },
  BeyondOuterRail: {
    title: 'Beyond the outer rail',
    detail:
      'This swap starts outside the pool’s outer rail on the deviation-increasing side. The rail is a start-of-swap condition, so a smaller size does not help.',
    action: 'Trade in the opposite direction, or wait for the pool to come back inside the rail.',
  },
  SlippageExceeded: {
    title: 'Output below your minimum',
    detail: 'The route would have paid out less than the minimum you signed for, so it reverted and nothing moved.',
    action: 'Re-quote. If it keeps happening, the pool is moving faster than the quote survives.',
  },
  CapacityExceeded: {
    title: 'Bond capacity exhausted',
    detail:
      'This market has issued its allowance for the current epoch, or the protocol has hit its daily cap. A bond that overruns capacity would take the whole deposit for a capped issue, which is why the transaction refuses rather than proceeding.',
    action: 'Wait for the epoch to roll, or bond a smaller amount.',
  },
  GateNotHealthy: {
    title: 'Gate is not green',
    detail:
      'The oracle gate is in a state that stops this path: a stale feed, a closed session, a corporate-action freeze, a divergence latch or the block watchdog. Swaps and redemption are never stopped by the gate; placements, compounding and some bond markets are.',
    action: 'Redemption stays open in every gate state. For everything else, wait for the gate to clear.',
  },
  PlacementCooldown: {
    title: 'Placement cooldown',
    detail: 'This pool placed liquidity less than 60 seconds ago and the vault will not place again yet.',
    action: 'Wait for the cooldown to expire.',
  },
  PlacementDiverged: {
    title: 'Pool diverged from the reference',
    detail: 'The pool tick is too far from the fair tick for the vault to place liquidity safely.',
    action: 'Nothing to do — the keeper retries once the pool converges.',
  },
  AccretionFloorViolated: {
    title: 'Bond price above the accretion floor',
    detail:
      'The bond shell recomputed the NAV floor and the policy’s price sat above it. The shell refuses rather than issuing a bond that would dilute holders.',
    action: 'Nothing to do — this is the protocol refusing to issue below its own floor.',
  },
  MarketClosed: {
    title: 'Bond market closed',
    detail: 'This collateral’s market is not accepting bonds right now.',
    action: 'Try another market, or check the gate state on the Vault page.',
  },
  StaleCheckpoint: {
    title: 'Vault checkpoint is stale',
    detail: 'The NAV checkpoint this path prices against is older than the maximum age it accepts.',
    action: 'Call checkpoint() from the Vault page — it is free and anyone may call it — then retry.',
  },
  ConstituentFrozen: {
    title: 'Constituent frozen',
    detail: 'A guardian freeze or a corporate action covers this constituent. The freeze is disable-only and expires by itself.',
    action: 'Redemption is unaffected. Everything else waits for the freeze to expire.',
  },
  InsufficientInventory: {
    title: 'Not enough inventory',
    detail: 'The vault does not hold enough uncommitted AMPS for this placement.',
    action: 'Nothing to do — inventory is finite and is never minted.',
  },
  Reentrancy: {
    title: 'Reentrancy lock held',
    detail: 'Another call into the vault is in flight in the same transaction.',
    action: 'Retry as a standalone transaction.',
  },
  OutOfBand: {
    title: 'Parameter outside its hard band',
    detail: 'A governed parameter was set outside the band hardcoded in the consuming contract. Bands cannot be widened.',
    action: '',
  },
}

const USER_REJECTED = /user (rejected|denied)|rejected the request|ACTION_REJECTED/i

export function surfaceError(error: unknown, abis: readonly Abi[] = []): SurfacedError {
  if (error === null || error === undefined) {
    return {name: null, title: 'Unknown error', detail: 'No error was reported.', action: ''}
  }

  const message = error instanceof Error ? error.message : String(error)

  if (USER_REJECTED.test(message)) {
    return {
      name: null,
      title: 'Signature rejected',
      detail: 'The wallet declined the request. Nothing was sent and nothing moved.',
      action: 'Sign again when you are ready.',
    }
  }

  const decoded = decodeRevert(error, abis)
  if (decoded) {
    const entry = CATALOGUE[decoded.name]
    if (entry) return {name: decoded.name, args: decoded.args, ...entry}
    return {
      name: decoded.name,
      args: decoded.args,
      title: decoded.name,
      detail: 'The contract reverted with this error.',
      action: '',
    }
  }

  // Fall back to a name match on the raw text: some providers surface the selector name only.
  for (const name of Object.keys(CATALOGUE)) {
    if (message.includes(name)) {
      const entry = CATALOGUE[name]
      if (entry) return {name, ...entry}
    }
  }

  return {
    name: null,
    title: 'Transaction failed',
    detail: message.split('\n')[0] ?? message,
    action: '',
  }
}

function decodeRevert(error: unknown, abis: readonly Abi[]): {name: string; args: readonly unknown[]} | null {
  if (error instanceof BaseError) {
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError)
    if (reverted instanceof ContractFunctionRevertedError && reverted.data) {
      return {name: reverted.data.errorName, args: reverted.data.args ?? []}
    }
  }
  const data = extractRevertData(error)
  if (!data) return null
  for (const abi of abis) {
    try {
      const result = decodeErrorResult({abi, data})
      return {name: result.errorName, args: (result.args ?? []) as readonly unknown[]}
    } catch {
      // not this ABI
    }
  }
  return null
}

function extractRevertData(error: unknown): Hex | null {
  const candidate = error as {data?: unknown; cause?: unknown}
  if (typeof candidate?.data === 'string' && candidate.data.startsWith('0x')) return candidate.data as Hex
  if (candidate?.cause) return extractRevertData(candidate.cause)
  return null
}

/** The catalogue keys, for the tests that assert every named error has an explanation. */
export const explainedErrors = Object.keys(CATALOGUE)
