// SPDX-License-Identifier: MIT
import {describe, expect, it} from 'vitest'
import {createMetrics, Registry} from '../src/metrics.js'

describe('the Prometheus exposition', () => {
  it('renders HELP, TYPE and sorted label sets', () => {
    const registry = new Registry()
    const counter = registry.counter('amps_test_total', 'A test counter.')
    counter.inc({job: 'compound', reason: 'cooldown'})
    counter.inc({job: 'compound', reason: 'cooldown'})
    counter.inc({job: 'rollout', reason: 'cell-budget'})

    expect(registry.render()).toBe(
      [
        '# HELP amps_test_total A test counter.',
        '# TYPE amps_test_total counter',
        'amps_test_total{job="compound",reason="cooldown"} 2',
        'amps_test_total{job="rollout",reason="cell-budget"} 1',
        '',
      ].join('\n'),
    )
  })

  it('is byte-identical across two scrapes of an unchanged registry', () => {
    const registry = new Registry()
    const gauge = registry.gauge('amps_test_gauge', 'A gauge.')
    gauge.set({b: '2'}, 5)
    gauge.set({a: '1'}, 7)
    expect(registry.render()).toBe(registry.render())
  })

  it('renders histogram buckets cumulatively, with +Inf, sum and count', () => {
    const registry = new Registry()
    const histogram = registry.histogram('amps_test_hist', 'A histogram.', [1, 10])
    histogram.observe({job: 'compound'}, 0.5)
    histogram.observe({job: 'compound'}, 5)
    histogram.observe({job: 'compound'}, 50)

    const text = registry.render()
    expect(text).toContain('amps_test_hist_bucket{job="compound",le="1"} 1')
    expect(text).toContain('amps_test_hist_bucket{job="compound",le="10"} 2')
    expect(text).toContain('amps_test_hist_bucket{job="compound",le="+Inf"} 3')
    expect(text).toContain('amps_test_hist_sum{job="compound"} 55.5')
    expect(text).toContain('amps_test_hist_count{job="compound"} 3')
  })

  it('escapes label values so a revert string cannot break the format', () => {
    const registry = new Registry()
    registry.counter('amps_test_total', 'x').inc({error: 'a"b\\c\nd'})
    expect(registry.render()).toContain('amps_test_total{error="a\\"b\\\\c\\nd"} 1')
  })
})

describe('the keeper metric set', () => {
  it('exposes the gate, the pot, the decision and the gas series', () => {
    const metrics = createMetrics()
    metrics.up.set({}, 1)
    metrics.gateState.set({}, 0)
    metrics.potQuoteUsd.set({}, 0.07)
    metrics.skipped.inc({job: 'compound', reason: 'below-chost'})
    metrics.gasUsed.observe({job: 'compound'}, 1_500_000)
    metrics.measuredGasAllowance.set({job: 'compound'}, 0.0375)
    metrics.reportedGasAllowance.set({job: 'compound'}, 1)

    const text = metrics.registry.render()
    for (const name of [
      'amps_keeper_up',
      'amps_keeper_gate_state',
      'amps_keeper_pot_quote_usd',
      'amps_keeper_skipped_total',
      'amps_keeper_gas_used_bucket',
      'amps_keeper_measured_gas_allowance_usd',
      'amps_keeper_reported_gas_allowance_usd',
    ]) {
      expect(text, name).toContain(name)
    }
  })
})
