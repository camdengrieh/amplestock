# SPDX-License-Identifier: MIT
"""Volume, price and depth, read out of the cassette through the real decoding paths."""

from __future__ import annotations

import pytest

from amplestocks_quant.constituents.collectors.market import BlockClock, MarketCollector
from amplestocks_quant.constituents.collectors.pools import PoolCollector
from amplestocks_quant.constituents.collectors.universe import TokenUniverseCollector


@pytest.fixture
def markets(context):
    tokens = TokenUniverseCollector().collect(context)
    pool_set = PoolCollector().collect_for(context, tokens)
    by_key = {t.key: t for t in tokens}
    measured = MarketCollector().collect_for(context, pool_set, by_key)
    return {by_key[key].symbol: value for key, value in measured.items()}


def test_block_clock_interpolates_between_the_two_known_anchors() -> None:
    clock = BlockClock(from_block=100, from_ts=1_000, head_block=1_100, head_ts=1_100)
    assert clock.ts(100) == 1_000
    assert clock.ts(1_100) == 1_100
    assert clock.ts(600) == 1_050


def test_volume_matches_the_generated_notional(markets) -> None:
    thin = markets["FXTHIN"][0]
    assert thin.volume_usd_30d == pytest.approx(105_000_000, rel=1e-6)
    assert 0 < thin.volume_usd_7d < thin.volume_usd_30d
    assert thin.swaps_30d == 8


def test_depth_matches_the_generated_depth(markets) -> None:
    thin = markets["FXTHIN"][0]
    assert thin.depth_usd_2pct == pytest.approx(63_000, rel=1e-3)
    assert thin.liquidity and thin.liquidity > 0


def test_price_comes_from_the_head_state(markets) -> None:
    thin = markets["FXTHIN"][0]
    assert thin.price_usd is not None
    assert 1.0 < thin.price_usd < 100.0
    # The fixture's head state is the last swap of the path, so the two agree.
    assert thin.price_usd == pytest.approx(thin.daily_prices[-1][1], rel=1e-6)


def test_a_weth_quoted_pool_is_priced_through_the_weth_stable_pool(markets) -> None:
    weth_quoted = markets["FXWETHQ"][0]
    assert weth_quoted.pool.counter_symbol == "WETH"
    assert weth_quoted.price_usd == pytest.approx(9.6, rel=0.5)
    assert weth_quoted.volume_usd_30d == pytest.approx(2_400_000, rel=1e-6)


def test_effective_fee_is_volume_weighted_across_a_token_s_pools(markets) -> None:
    deep = markets["FXDEEP"]
    assert len(deep) == 2
    fees = {m.pool.protocol: m.effective_fee_bps for m in deep}
    assert fees["v4"] == pytest.approx(30.0)
    assert fees["v3"] == pytest.approx(5.0)


def test_a_pool_with_no_recent_swaps_reports_zero_not_missing(markets) -> None:
    dead = markets["FXDEAD"][0]
    assert dead.volume_usd_7d == 0.0
    assert dead.volume_usd_30d > 0.0


def test_every_measured_pool_has_a_price_and_a_depth(markets) -> None:
    for symbol, pools in markets.items():
        for market in pools:
            assert market.price_usd is not None, f"{symbol} has an unpriced pool"
            assert market.depth_usd_2pct is not None, f"{symbol} has no depth"
