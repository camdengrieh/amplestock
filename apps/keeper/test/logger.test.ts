// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'
import {createLogger} from '../src/logger.js'

describe('structured logging', () => {
  it('emits one JSON object per line, with the bindings merged in', () => {
    const lines: string[] = []
    const logger = createLogger({service: 'amps-keeper'}, {sink: (l) => lines.push(l), now: () => 0})
    logger.info('submitted', {job: 'compound:0xabc'})

    expect(lines).toHaveLength(1)
    expect(JSON.parse(lines[0] as string)).toEqual({
      ts: '1970-01-01T00:00:00.000Z',
      level: 'info',
      msg: 'submitted',
      service: 'amps-keeper',
      job: 'compound:0xabc',
    })
  })

  it('serialises bigints rather than throwing on them', () => {
    const lines: string[] = []
    const logger = createLogger({}, {sink: (l) => lines.push(l), now: () => 0})
    logger.info('bounty', {bountyUsd18: 70_000_000_000_000_000n, nested: {gas: 1_500_000n}})
    expect(JSON.parse(lines[0] as string)).toMatchObject({
      bountyUsd18: '70000000000000000',
      nested: {gas: '1500000'},
    })
  })

  it('flattens errors so a revert is greppable', () => {
    const lines: string[] = []
    const logger = createLogger({}, {sink: (l) => lines.push(l), now: () => 0})
    logger.error('scan failed', {error: new Error('PlacementCooldown')})
    const record = JSON.parse(lines[0] as string) as {error: {name: string; message: string}}
    expect(record.error.name).toBe('Error')
    expect(record.error.message).toBe('PlacementCooldown')
  })

  it('respects the level', () => {
    const lines: string[] = []
    const logger = createLogger({}, {sink: (l) => lines.push(l), level: 'warn', now: () => 0})
    logger.debug('x')
    logger.info('y')
    logger.warn('z')
    expect(lines).toHaveLength(1)
  })

  it('children inherit and extend the bindings', () => {
    const lines: string[] = []
    const logger = createLogger({a: 1}, {sink: (l) => lines.push(l), now: () => 0}).child({b: 2})
    logger.info('x')
    expect(JSON.parse(lines[0] as string)).toMatchObject({a: 1, b: 2})
  })
})
