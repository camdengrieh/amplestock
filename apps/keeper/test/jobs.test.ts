// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'
import {
  encodeAbiParameters,
  encodeErrorResult,
  encodeEventTopics,
  toFunctionSelector,
  type AbiEvent,
} from 'viem'
import {ampsVaultAbi, bountyPotAbi} from '@amplestocks/abis'
import {
  cooldownFrom,
  decodeRevert,
  encodeJob,
  readBountyReport,
  KEEPER_ERROR_ABI,
  retryAfter,
} from '../src/jobs/index.js'
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

describe('reading the vault’s own bounty report', () => {
  const POT = '0x00000000000000000000000000000000000000b3' as const

  function bountyPaidLog(workValueUsd18: bigint, paidUsd18: bigint, paidRaw: bigint, reason: string) {
    const event = bountyPotAbi.find((i) => i.type === 'event' && i.name === 'BountyPaid') as AbiEvent
    const encoded = encodeEventTopics({
      abi: bountyPotAbi,
      eventName: 'BountyPaid',
      args: {to: '0x00000000000000000000000000000000000000e0'},
    })
    const padded = `0x${Buffer.from(reason, 'ascii').toString('hex').padEnd(64, '0')}` as `0x${string}`
    return {
      address: POT,
      topics: encoded as `0x${string}`[],
      data: encodeAbiParameters(
        event.inputs.filter((i) => i.indexed !== true),
        [workValueUsd18, paidUsd18, paidRaw, padded],
      ),
    }
  }

  it('decodes the work value, the payout and the constraint that bound it', () => {
    const report = readBountyReport([bountyPaidLog(12n * 10n ** 18n, 118_500_000_000_000_000n, 118_500n, '')], POT)
    expect(report).toEqual({
      workValueUsd18: 12n * 10n ** 18n,
      paidUsd18: 118_500_000_000_000_000n,
      paidRaw: 118_500n,
      reason: '',
    })
  })

  it('reads the reason back as its ASCII name', () => {
    for (const reason of ['chost', 'gasCap', 'dailyCeiling', 'depleted']) {
      expect(readBountyReport([bountyPaidLog(0n, 0n, 0n, reason)], POT)?.reason).toBe(reason)
    }
  })

  it('ignores logs from anything but the pot, so a hostile token cannot forge a payout', () => {
    const forged = {...bountyPaidLog(1_000n * 10n ** 18n, 0n, 0n, ''), address: '0x00000000000000000000000000000000000000ff'}
    expect(readBountyReport([forged], POT)).toBeUndefined()
  })

  it('is undefined when the job emitted no BountyPaid at all', () => {
    expect(readBountyReport([], POT)).toBeUndefined()
  })
})
