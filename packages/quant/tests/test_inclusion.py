# SPDX-License-Identifier: MIT
"""Inclusion evidence: beta, tracking error, index vol and observed history."""

from __future__ import annotations

import math

import pytest
from conftest import make_market, make_token

from amplestocks_quant.constituents.inclusion import MIN_RETURNS, compute_inclusion
from amplestocks_quant.constituents.records import TokenMetrics

DAY = 86_400


def with_prices(symbol: str, prices: list[float], start_day: int = 20_000) -> TokenMetrics:
    token = make_token(symbol)
    market = make_market(token, volume7=1.0, volume30=1.0, depth=1.0)
    market.daily_prices = [((start_day + i) * DAY + 3_600, price) for i, price in enumerate(prices)]
    return TokenMetrics(token=token, markets=[market])


def test_a_name_that_is_the_index_has_beta_one_and_no_tracking_error() -> None:
    path = [100.0 * math.exp(0.01 * math.sin(i)) for i in range(12)]
    twins = [with_prices("A", path), with_prices("B", path)]
    stats = compute_inclusion(twins)
    for symbol in ("A", "B"):
        assert stats[symbol].measured
        assert stats[symbol].beta == pytest.approx(1.0, abs=1e-9)
        assert stats[symbol].tracking_error == pytest.approx(0.0, abs=1e-9)
        assert stats[symbol].passes() is True


def test_beta_scales_with_the_amplitude_of_the_move() -> None:
    base = [0.0, 0.02, -0.01, 0.015, -0.02, 0.01, 0.005, -0.012, 0.02, -0.004]
    def path(scale: float) -> list[float]:
        prices = [50.0]
        for ret in base[1:]:
            prices.append(prices[-1] * math.exp(scale * ret))
        return prices

    records = [with_prices("ONE", path(1.0)), with_prices("TWO", path(2.0))]
    stats = compute_inclusion(records)
    # index = mean of the two return series => beta(2x) / beta(1x) = 2.
    assert stats["TWO"].beta / stats["ONE"].beta == pytest.approx(2.0, rel=1e-6)
    assert stats["ONE"].index_vol and stats["ONE"].index_vol > 0


def test_history_days_is_what_was_observed_not_what_is_wanted() -> None:
    stats = compute_inclusion([with_prices("A", [1.0] * 8), with_prices("B", [1.0] * 8)])
    assert stats["A"].history_days == 8
    assert stats["A"].to_x18()["historyDays"] == 8


def test_too_little_overlap_is_reported_rather_than_estimated() -> None:
    long_path = [100.0 * (1 + 0.01 * i) for i in range(12)]
    short = with_prices("SHORT", [10.0, 11.0], start_day=20_000)
    stats = compute_inclusion([with_prices("LONG", long_path), with_prices("LONG2", long_path), short])
    assert stats["SHORT"].measured is False
    assert stats["SHORT"].passes() is None
    assert f"need {MIN_RETURNS}" in stats["SHORT"].note


def test_x18_conversion_is_registry_shaped() -> None:
    stats = compute_inclusion([with_prices("A", [1.0] * 8), with_prices("B", [1.0] * 8)])["A"]
    fields = stats.to_x18()
    assert set(fields) == {"betaX18", "trackingErrorX18", "indexVolX18", "historyDays"}
    assert all(isinstance(v, int) for v in fields.values())
    assert fields["trackingErrorX18"] >= 0 and fields["indexVolX18"] >= 0
