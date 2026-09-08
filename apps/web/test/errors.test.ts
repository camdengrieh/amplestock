// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'
import {encodeErrorResult, type Abi} from 'viem'

import {explainedErrors, surfaceError} from '@/lib/errors'

const errorsAbi = [
  {type: 'error', name: 'BeyondRail', inputs: [{name: 'poolId', type: 'bytes32'}, {name: 'devTicks', type: 'int24'}, {name: 'outerRailTicks', type: 'int24'}]},
  {type: 'error', name: 'SlippageExceeded', inputs: [{name: 'received', type: 'uint256'}, {name: 'minimum', type: 'uint256'}]},
  {type: 'error', name: 'CapacityExceeded', inputs: [{name: 'requested', type: 'uint256'}, {name: 'available', type: 'uint256'}]},
  {type: 'error', name: 'GateNotHealthy', inputs: [{name: 'state', type: 'uint8'}, {name: 'poolId', type: 'bytes32'}]},
  {type: 'error', name: 'PlacementCooldown', inputs: [{name: 'poolId', type: 'bytes32'}, {name: 'readyAt', type: 'uint32'}]},
  // `AmpsRouter`, revision 6.
  {type: 'error', name: 'DeadlineExpired', inputs: [{name: 'deadline', type: 'uint256'}, {name: 'timestamp', type: 'uint256'}]},
  {type: 'error', name: 'SameHop', inputs: [{name: 'poolId', type: 'bytes32'}]},
  {type: 'error', name: 'AmpsResidual', inputs: [{name: 'delta', type: 'int256'}]},
  {type: 'error', name: 'UnexpectedValue', inputs: [{name: 'value', type: 'uint256'}]},
  {type: 'error', name: 'NativeTransferFailed', inputs: [{name: 'to', type: 'address'}, {name: 'amount', type: 'uint256'}]},
  {type: 'error', name: 'NotWrappedNative', inputs: [{name: 'counter', type: 'address'}]},
  {type: 'error', name: 'UnknownPool', inputs: [{name: 'poolId', type: 'bytes32'}]},
] as const satisfies Abi

function revert(name: string, args: readonly unknown[]) {
  return {data: encodeErrorResult({abi: errorsAbi, errorName: name as never, args: args as never})}
}

describe('every named error the write surfaces can hit has an explanation', () => {
  it.each([
    'BeyondRail',
    'SlippageExceeded',
    'CapacityExceeded',
    'GateNotHealthy',
    'PlacementCooldown',
    'UnconfirmedNav',
    'HighWaterResetFailed',
    // The router's own, all reachable from Rotate.
    'DeadlineExpired',
    'SameHop',
    'AmpsResidual',
    'UnexpectedValue',
    'NativeTransferFailed',
    'NotWrappedNative',
    'UnknownPool',
  ])('%s', (name) => {
    expect(explainedErrors).toContain(name)
  })
})

describe('the router’s errors decode and explain the router’s own rules', () => {
  it('SameHop says why a rotation into the same pool is not a rotation', () => {
    const surfaced = surfaceError(revert('SameHop', [`0x${'11'.repeat(32)}`]), [errorsAbi])
    expect(surfaced.name).toBe('SameHop')
    expect(surfaced.detail).toMatch(/round trip/i)
  })

  it('DeadlineExpired says nothing moved', () => {
    const surfaced = surfaceError(revert('DeadlineExpired', [1n, 2n]), [errorsAbi])
    expect(surfaced.name).toBe('DeadlineExpired')
    expect(surfaced.detail).toMatch(/nothing moved/i)
  })

  it('AmpsResidual is named as a safety assertion rather than something to retry', () => {
    const surfaced = surfaceError(revert('AmpsResidual', [-1n]), [errorsAbi])
    expect(surfaced.name).toBe('AmpsResidual')
    expect(surfaced.action).toMatch(/not a timing one/i)
  })

  it('the wrapping errors point at the WETH leg', () => {
    expect(surfaceError(revert('NotWrappedNative', ['0x0000000000000000000000000000000000000001']), [errorsAbi]).detail).toMatch(
      /wrapped native/i,
    )
    expect(surfaceError(revert('UnexpectedValue', [1n]), [errorsAbi]).action).toMatch(/native ETH/i)
    expect(
      surfaceError(revert('NativeTransferFailed', ['0x0000000000000000000000000000000000000001', 1n]), [errorsAbi]).action,
    ).toMatch(/WETH/i)
  })

  it('UnknownPool says the registry is the gate on which pools exist', () => {
    const surfaced = surfaceError(revert('UnknownPool', [`0x${'22'.repeat(32)}`]), [errorsAbi])
    expect(surfaced.detail).toMatch(/PoolRegistry/)
  })
})

describe('surfaceError', () => {
  it('decodes BeyondRail and explains that a smaller size does not help', () => {
    const surfaced = surfaceError(revert('BeyondRail', [`0x${'11'.repeat(32)}`, 900, 800]), [errorsAbi])
    expect(surfaced.name).toBe('BeyondRail')
    expect(surfaced.title).toMatch(/outer rail/i)
    expect(surfaced.action).toMatch(/opposite direction/i)
  })

  it('decodes CapacityExceeded and explains why it reverts rather than proceeding', () => {
    const surfaced = surfaceError(revert('CapacityExceeded', [10n, 1n]), [errorsAbi])
    expect(surfaced.name).toBe('CapacityExceeded')
    expect(surfaced.detail).toMatch(/whole deposit/i)
  })

  it('decodes GateNotHealthy and says redemption is unaffected', () => {
    const surfaced = surfaceError(revert('GateNotHealthy', [1, `0x${'11'.repeat(32)}`]), [errorsAbi])
    expect(surfaced.name).toBe('GateNotHealthy')
    expect(surfaced.action).toMatch(/redemption stays open/i)
  })

  it('decodes SlippageExceeded and PlacementCooldown', () => {
    expect(surfaceError(revert('SlippageExceeded', [1n, 2n]), [errorsAbi]).name).toBe('SlippageExceeded')
    expect(surfaceError(revert('PlacementCooldown', [`0x${'11'.repeat(32)}`, 1n]), [errorsAbi]).name).toBe('PlacementCooldown')
  })

  it('recognises a wallet rejection and says nothing moved', () => {
    const surfaced = surfaceError(new Error('User rejected the request.'))
    expect(surfaced.title).toMatch(/rejected/i)
    expect(surfaced.detail).toMatch(/nothing moved/i)
  })

  it('falls back to the first line of an unknown error', () => {
    const surfaced = surfaceError(new Error('something odd\nwith a stack'))
    expect(surfaced.name).toBeNull()
    expect(surfaced.detail).toBe('something odd')
  })

  it('handles a missing error without inventing one', () => {
    const surfaced = surfaceError(null)
    expect(surfaced.title).toMatch(/unknown/i)
  })

  it('matches a bare selector name in the message when no ABI decodes it', () => {
    const surfaced = surfaceError(new Error('execution reverted: MarketClosed'))
    expect(surfaced.name).toBe('MarketClosed')
  })
})
