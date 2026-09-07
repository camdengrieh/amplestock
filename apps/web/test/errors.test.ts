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
] as const satisfies Abi

function revert(name: string, args: readonly unknown[]) {
  return {data: encodeErrorResult({abi: errorsAbi, errorName: name as never, args: args as never})}
}

describe('every named error the write surfaces can hit has an explanation', () => {
  it.each(['BeyondRail', 'SlippageExceeded', 'CapacityExceeded', 'GateNotHealthy', 'PlacementCooldown'])(
    '%s',
    (name) => {
      expect(explainedErrors).toContain(name)
    },
  )
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
