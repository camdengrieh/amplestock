// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'
import {encodeErrorResult, toFunctionSelector} from 'viem'
import {ampsVaultAbi} from '@amplestocks/abis'
import {cooldownFrom, decodeRevert, encodeJob, KEEPER_ERROR_ABI, retryAfter} from '../src/jobs/index.js'
import {jobKey} from '../src/domain/decide.js'
import {SPOKE_POOL} from './helpers.js'

describe('calldata', () => {
  it('encodes each job at the selector the vault ABI declares', () => {
    const selectors = {
      compound: toFunctionSelector('compound(bytes32)'),
      rollout: toFunctionSelector('rollout(uint16)'),
      deployBonded: toFunctionSelector('deployBonded(uint16)'),
      checkpoint: toFunctionSelector('checkpoint()'),
      touch: toFunctionSelector('touch()'),
    } as const

    expect(encodeJob({kind: 'compound', target: SPOKE_POOL, key: jobKey('compound', SPOKE_POOL)})).toMatch(
      new RegExp(`^${selectors.compound}`),
    )
    expect(encodeJob({kind: 'rollout', target: '3', key: jobKey('rollout', '3')})).toBe(
      `${selectors.rollout}${'0'.repeat(63)}3`,
    )
    expect(encodeJob({kind: 'deployBonded', target: '12', key: 'x'})).toMatch(
      new RegExp(`^${selectors.deployBonded}`),
    )
    expect(encodeJob({kind: 'checkpoint', target: '', key: 'x'})).toBe(selectors.checkpoint)
    expect(encodeJob({kind: 'touch', target: '', key: 'x'})).toBe(selectors.touch)
  })

  it('the vault ABI really carries those five, so the encoding cannot drift', () => {
    const names = ampsVaultAbi.filter((item) => item.type === 'function').map((item) => item.name)
    for (const name of ['compound', 'rollout', 'deployBonded', 'checkpoint', 'touch']) {
      expect(names).toContain(name)
    }
  })
})

describe('revert decoding', () => {
  it('decodes PlacementCooldown, which is where the keeper learns the exact ready time', () => {
    const data = encodeErrorResult({
      abi: KEEPER_ERROR_ABI,
      errorName: 'PlacementCooldown',
      args: [SPOKE_POOL, 1_788_962_460],
    })
    const decoded = decodeRevert(new Error(`execution reverted: ${data}`))
    expect(decoded?.name).toBe('PlacementCooldown')
    expect(decoded?.args[1]).toBe(1_788_962_460)
    expect(retryAfter({ok: false, gasEstimate: 0n, revert: decoded})).toBe(1_788_962_460)
  })

  it('decodes the other gauntlet reverts by name', () => {
    for (const [errorName, args] of [
      ['GateNotHealthy', [1, SPOKE_POOL]],
      ['NavBleedExceeded', [10n ** 18n, 10n ** 17n, 2]],
      ['CellBudgetExceeded', [SPOKE_POOL, 512, 512]],
      ['RolloutLimitExceeded', ['0x' + '00'.repeat(32), 1n, 0n]],
    ] as const) {
      const data = encodeErrorResult({
        abi: KEEPER_ERROR_ABI,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        errorName: errorName as any,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        args: args as any,
      })
      expect(decodeRevert(new Error(`reverted ${data}`))?.name).toBe(errorName)
    }
  })

  it('reports an unknown selector rather than throwing', () => {
    const decoded = decodeRevert(new Error('execution reverted: 0xdeadbeef'))
    expect(decoded?.name).toBe('Unknown')
    expect(decoded?.raw).toBe('0xdeadbeef')
  })

  it('cooldownFrom names the pool the revert is about, not the pool the job asked for', () => {
    // A `rollout` is addressed by constituent id but trips the *entry* pools' cooldowns. Taking the id out of
    // the error is what lets one refused rollout teach the keeper about a pool it never asked about.
    const data = encodeErrorResult({
      abi: KEEPER_ERROR_ABI,
      errorName: 'PlacementCooldown',
      args: [SPOKE_POOL, 1_788_962_460],
    })
    const decoded = decodeRevert(new Error(`reverted ${data}`))
    expect(cooldownFrom({ok: false, gasEstimate: 0n, revert: decoded})).toEqual({
      poolId: SPOKE_POOL,
      readyAt: 1_788_962_460,
    })
    expect(cooldownFrom({ok: true, gasEstimate: 1n})).toBeNull()
  })

  it('retryAfter is null for anything but a cooldown', () => {
    expect(retryAfter({ok: true, gasEstimate: 1n})).toBeNull()
    expect(retryAfter({ok: false, gasEstimate: 0n, revert: {name: 'GateNotHealthy', args: [], raw: '0x'}})).toBeNull()
  })
})
