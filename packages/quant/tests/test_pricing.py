# SPDX-License-Identifier: MIT
"""Price, depth and volatility math."""

from __future__ import annotations

import math

import pytest

from amplestocks_quant.constituents import pricing


def test_price_round_trips_through_sqrt_x96() -> None:
    for price, dec0, dec1 in ((100.0, 18, 6), (0.0004, 6, 18), (2500.0, 18, 18)):
        sqrt_price = pricing.sqrt_x96_from_price(price, dec0, dec1)
        assert pricing.price_from_sqrt_x96(sqrt_price, dec0, dec1) == pytest.approx(price, rel=1e-9)


def test_zero_sqrt_price_is_not_a_price() -> None:
    assert pricing.price_from_sqrt_x96(0, 18, 18) == 0.0
    assert pricing.sqrt_x96_from_price(0.0, 18, 18) == 0


def test_depth_matches_the_closed_form_for_a_balanced_pool() -> None:
    """At price 1 with equal decimals the virtual reserves are `L` a side, so +/-2% is ~2% of 2L."""
    liquidity = 10**18
    sqrt_price = pricing.sqrt_x96_from_price(1.0, 18, 18)
    depth = pricing.depth_usd_within_band(
        liquidity=liquidity,
        sqrt_price_x96=sqrt_price,
        decimals0=18,
        decimals1=18,
        price0_usd=1.0,
        price1_usd=1.0,
    )
    expected = (math.sqrt(1.02) - 1) + (1 / math.sqrt(0.98) - 1)
    assert depth == pytest.approx(expected, rel=1e-9)
    assert depth == pytest.approx(0.0201, rel=1e-2)


def test_depth_is_linear_in_liquidity_and_zero_without_it() -> None:
    sqrt_price = pricing.sqrt_x96_from_price(50.0, 18, 6)
    args = {"sqrt_price_x96": sqrt_price, "decimals0": 18, "decimals1": 6,
            "price0_usd": 50.0, "price1_usd": 1.0}
    one = pricing.depth_usd_within_band(liquidity=10**18, **args)
    ten = pricing.depth_usd_within_band(liquidity=10**19, **args)
    assert ten == pytest.approx(10 * one, rel=1e-9)
    assert pricing.depth_usd_within_band(liquidity=0, **args) == 0.0


def test_depth_is_none_when_neither_side_can_be_priced() -> None:
    assert (
        pricing.depth_usd_within_band(
            liquidity=10**18,
            sqrt_price_x96=pricing.sqrt_x96_from_price(1.0, 18, 18),
            decimals0=18,
            decimals1=18,
            price0_usd=None,
            price1_usd=None,
        )
        is None
    )


def test_realised_vol_of_a_flat_series_is_zero_and_of_a_short_one_is_unknown() -> None:
    flat, n = pricing.realised_vol_annual([10.0] * 8)
    assert flat == pytest.approx(0.0) and n == 7
    unknown, n = pricing.realised_vol_annual([10.0, 11.0])
    assert unknown is None and n == 1


def test_realised_vol_annualises_daily_log_returns() -> None:
    # Alternating +/-1% daily moves: stdev of the return series times sqrt(365).
    prices = [100.0]
    for i in range(30):
        prices.append(prices[-1] * (1.01 if i % 2 == 0 else 1 / 1.01))
    vol, n = pricing.realised_vol_annual(prices)
    returns = [math.log(prices[i] / prices[i - 1]) for i in range(1, len(prices))]
    mean = sum(returns) / len(returns)
    expected = math.sqrt(sum((r - mean) ** 2 for r in returns) / (len(returns) - 1)) * math.sqrt(365)
    assert vol == pytest.approx(expected, rel=1e-12)
    assert n == 30


def test_daily_closes_keeps_the_last_price_of_each_utc_day() -> None:
    day = 86_400
    samples = [(day * 3 + 10, 1.0), (day * 3 + 500, 2.0), (day * 5, 3.0), (day * 4 + 1, 4.0)]
    assert pricing.daily_closes(samples) == [2.0, 4.0, 3.0]
    assert pricing.daily_close_map(samples)[3] == 2.0


def test_quantile_matches_linear_interpolation() -> None:
    values = [1.0, 2.0, 3.0, 4.0]
    assert pricing.quantile(values, 0.75) == pytest.approx(3.25)
    assert pricing.quantile(values, 0.0) == 1.0
    assert pricing.quantile([], 0.5) == 0.0
    assert pricing.median([3.0, 1.0, 2.0]) == 2.0


def test_geometric_mean_refuses_a_dead_leg() -> None:
    assert pricing.geometric_mean(4.0, 9.0) == pytest.approx(6.0)
    assert pricing.geometric_mean(0.0, 9.0) == 0.0
