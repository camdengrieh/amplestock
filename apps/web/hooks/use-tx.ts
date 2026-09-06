// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'
import {useWaitForTransactionReceipt, useWriteContract} from 'wagmi'
import type {Hash} from 'viem'

import {surfaceError, type SurfacedError} from '@/lib/errors'
import {allAbis} from '@/lib/contracts'
import type {TxPhase} from '@/components/common/tx'

/**
 * One write, with the phases every surface shows: simulate, sign, wait, done.
 *
 * The simulation is not optional. `useSimulateContract` runs on the read path and its failure is
 * what puts the button into `blocked` with a named reason — `BeyondRail`, `CapacityExceeded`,
 * `GateNotHealthy`, `PlacementCooldown`, `SlippageExceeded` — *before* a wallet opens. A user
 * should never learn that the rail is breached by paying gas to find out.
 */
export function useTx(params: {
  /** The simulation result from `useSimulateContract`, or `undefined` while it is unavailable. */
  simulation: {request: unknown} | undefined
  simulationError: unknown
  isSimulating: boolean
  /** A local reason the write cannot be offered at all (no wallet, zero amount, degraded quote). */
  blockedReason?: string
  onSuccess?: (hash: Hash) => void
}) {
  const {writeContractAsync, data: hash, reset: resetWrite, isPending: isSigning} = useWriteContract()
  const receipt = useWaitForTransactionReceipt({hash, query: {enabled: hash !== undefined}})
  const [error, setError] = React.useState<SurfacedError | null>(null)

  const simulationSurfaced = React.useMemo(
    () => (params.simulationError ? surfaceError(params.simulationError, allAbis) : null),
    [params.simulationError],
  )

  const phase: TxPhase = (() => {
    if (error) return 'error'
    if (receipt.isSuccess) return 'success'
    if (hash) return 'pending'
    if (isSigning) return 'signing'
    if (params.blockedReason) return 'blocked'
    if (params.isSimulating) return 'simulating'
    if (simulationSurfaced) return 'blocked'
    if (params.simulation) return 'ready'
    return 'idle'
  })()

  const send = React.useCallback(async () => {
    if (!params.simulation) return
    setError(null)
    try {
      const sent = await writeContractAsync((params.simulation as {request: never}).request)
      params.onSuccess?.(sent)
    } catch (caught) {
      setError(surfaceError(caught, allAbis))
    }
  }, [params, writeContractAsync])

  const reset = React.useCallback(() => {
    setError(null)
    resetWrite()
  }, [resetWrite])

  return {
    phase,
    hash,
    send,
    reset,
    error: error ?? simulationSurfaced,
    blockedReason: params.blockedReason ?? simulationSurfaced?.title,
    isConfirmed: receipt.isSuccess,
  }
}
