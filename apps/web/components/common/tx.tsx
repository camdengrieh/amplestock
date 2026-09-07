// SPDX-License-Identifier: MIT
'use client'

import * as React from 'react'

import {Alert, AlertDescription, AlertTitle} from '@/components/ui/alert'
import {Button, type ButtonProps} from '@/components/ui/button'
import type {SurfacedError} from '@/lib/errors'

/**
 * The state machine every write surface shares.
 *
 * `simulating` is not decoration: every write is simulated before it is offered, so a revert is
 * surfaced as a named, explained error *before* a wallet ever opens. A button that cannot be
 * simulated is disabled with the reason next to it.
 */
export type TxPhase = 'idle' | 'simulating' | 'blocked' | 'ready' | 'signing' | 'pending' | 'success' | 'error'

export interface TxButtonProps extends Omit<ButtonProps, 'children'> {
  phase: TxPhase
  label: string
  pendingLabel?: string
  blockedReason?: string
}

const PHASE_LABEL: Partial<Record<TxPhase, string>> = {
  simulating: 'Simulating…',
  signing: 'Confirm in your wallet…',
  pending: 'Submitted…',
}

export function TxButton({phase, label, pendingLabel, blockedReason, disabled, ...props}: TxButtonProps) {
  const busy = phase === 'simulating' || phase === 'signing' || phase === 'pending'
  const text = phase === 'pending' && pendingLabel ? pendingLabel : (PHASE_LABEL[phase] ?? label)
  return (
    <div className="space-y-2">
      <Button {...props} disabled={disabled || busy || phase === 'blocked'} aria-busy={busy} data-phase={phase}>
        {text}
      </Button>
      {phase === 'blocked' && blockedReason ? (
        <p className="text-xs text-amber-300" data-testid="tx-blocked-reason">
          {blockedReason}
        </p>
      ) : null}
    </div>
  )
}

export function TxError({error}: {error: SurfacedError | null}) {
  if (!error) return null
  return (
    <Alert variant="danger" data-testid="tx-error">
      <AlertTitle>{error.title}</AlertTitle>
      <AlertDescription>
        <p>{error.detail}</p>
        {error.action ? <p className="mt-2 font-medium">{error.action}</p> : null}
        {error.name ? <p className="mt-2 font-mono text-xs opacity-70">{error.name}</p> : null}
      </AlertDescription>
    </Alert>
  )
}

export function TxSuccess({hash, explorerUrl}: {hash: string; explorerUrl: string | null}) {
  return (
    <Alert variant="info" data-testid="tx-success">
      <AlertTitle>Confirmed</AlertTitle>
      <AlertDescription>
        {explorerUrl ? (
          <a className="underline" href={explorerUrl} target="_blank" rel="noreferrer">
            {hash}
          </a>
        ) : (
          <span className="font-mono text-xs">{hash}</span>
        )}
      </AlertDescription>
    </Alert>
  )
}
