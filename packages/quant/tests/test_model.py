# SPDX-License-Identifier: MIT
"""The revenue model: flags, quartiles and the `s`/`R`/`ROI` arithmetic."""

from __future__ import annotations

import pytest
from conftest import make_market, make_token

from amplestocks_quant.constituents.config import RunParams
from amplestocks_quant.constituents.model import (
    api_delta,
    apply_flags,
    build_metrics,
    buy_fee_bps,
    capturable_share,
    pool_class,
    roi_of,
    score_token,
)
from amplestocks_quant.constituents.records import ApiQuote, FeedInfo, TokenMetrics


def feed(symbol: str) -> FeedInfo:
    return FeedInfo(symbol=symbol, name=f"{symbol} / USD", proxy="0x" + "11" * 20, heartbeat_seconds=3600)


def metrics_for(symbol: str, *, volume7: float, volume30: float, depth: float, **kwargs) -> TokenMetrics:
    token = make_token(symbol, **{k: v for k, v in kwargs.items() if k in ("ui_multiplier",)})
    market = make_market(token, volume7=volume7, volume30=volume30, depth=depth)
    record = TokenMetrics(
        token=token,
        markets=[market],
        volume_usd_7d=volume7,
        volume_usd_30d=volume30,
        depth_usd_2pct=depth,
        price_usd=100.0,
        effective_fee_bps=30.0,
        feed=None if kwargs.get("no_feed") else feed(symbol),
        realised_vol_annual=kwargs.get("vol", 0.30),
    )
    return record


def test_capturable_share_is_proportional_and_bounded() -> None:
    assert capturable_share(300, 0) == 1.0
    assert capturable_share(300, 300) == pytest.approx(0.5)
    assert capturable_share(300, 63_000) == pytest.approx(300 / 63_300)
    assert capturable_share(0, 1_000) == 0.0


def test_revenue_and_roi_arithmetic_is_the_documented_formula() -> None:
    params = RunParams(placements=(300.0,), window_days=30)
    record = metrics_for("THIN", volume7=800_000, volume30=105_000_000, depth=63_000, vol=0.95)
    score_token(record, params)
    score = record.scores[300.0]

    daily = 105_000_000 / 30
    share = 300 / 63_300
    fee = 10 / 10_000  # sigma 95% > 60% => the high-volatility bucket
    assert score.capturable_share == pytest.approx(share)
    assert score.revenue_usd_day_base == pytest.approx(daily * share * fee)
    assert score.roi_base == pytest.approx(daily * share * fee * 365 / 300)
    # The effective basis uses the pools' own 30 bp instead of our 10 bp.
    assert score.revenue_usd_day_effective == pytest.approx(daily * share * 30 / 10_000)


def test_roi_falls_as_the_placement_grows() -> None:
    params = RunParams(placements=(300.0, 1_000.0, 5_000.0))
    record = metrics_for("THIN", volume7=1, volume30=105_000_000, depth=63_000)
    score_token(record, params)
    rois = [record.scores[p].roi_base for p in params.placements]
    assert rois == sorted(rois, reverse=True)


def test_fee_bucket_follows_realised_volatility() -> None:
    params = RunParams()
    calm = metrics_for("CALM", volume7=1, volume30=1, depth=1, vol=0.35)
    wild = metrics_for("WILD", volume7=1, volume30=1, depth=1, vol=0.85)
    unknown = metrics_for("UNK", volume7=1, volume30=1, depth=1, vol=None)
    assert (buy_fee_bps(calm, params), pool_class(calm, params)) == (5.0, "SPOKE")
    assert (buy_fee_bps(wild, params), pool_class(wild, params)) == (10.0, "SPOKE_HIGH_VOL")
    assert pool_class(unknown, params) == "SPOKE", "an unmeasured sigma does not buy the 10 bp bucket"


def test_dead_and_no_feed_are_absolute_and_quartiles_ignore_them() -> None:
    params = RunParams(dead_depth_usd=1_000)
    population = [
        metrics_for("BIG", volume7=10_000_000, volume30=40_000_000, depth=2_000_000),
        metrics_for("MID", volume7=1_000_000, volume30=4_000_000, depth=500_000),
        metrics_for("THIN", volume7=900_000, volume30=3_800_000, depth=20_000),
        metrics_for("SMALL", volume7=10_000, volume30=40_000, depth=100_000),
        metrics_for("DEADVOL", volume7=0, volume30=9_000_000, depth=200_000),
        metrics_for("DUST", volume7=5_000, volume30=50_000, depth=400),
        metrics_for("UNFED", volume7=5_000_000, volume30=20_000_000, depth=50_000, no_feed=True),
    ]
    cuts = apply_flags(population, params)

    flags = {m.symbol: m.flags for m in population}
    assert "dead" in flags["DEADVOL"] and "dead" in flags["DUST"]
    assert "no_feed" in flags["UNFED"]
    assert cuts["population"] == 4, "quartiles are measured over live, feed-having names only"
    assert "high_volume" in flags["BIG"]
    assert "thin_liquidity" in flags["THIN"]
    assert "high_volume" not in flags["SMALL"]


def test_flagging_is_idempotent() -> None:
    params = RunParams()
    population = [
        metrics_for("A", volume7=1, volume30=100, depth=10_000),
        metrics_for("B", volume7=1, volume30=200, depth=10_000),
    ]
    first = apply_flags(population, params)
    snapshot = [set(m.flags) for m in population]
    second = apply_flags(population, params)
    assert first == second
    assert [set(m.flags) for m in population] == snapshot


def test_multiplier_flag_only_fires_on_a_known_non_unit_multiplier() -> None:
    params = RunParams()
    split = metrics_for("SPLIT", volume7=1, volume30=1, depth=10_000, ui_multiplier=4.0)
    unknown = metrics_for("OPAQUE", volume7=1, volume30=1, depth=10_000, ui_multiplier=None)
    apply_flags([split, unknown], params)
    assert "multiplier" in split.flags
    assert "multiplier" not in unknown.flags


def test_api_delta_is_measured_against_the_median_aggregator() -> None:
    record = metrics_for("SKEW", volume7=1, volume30=30_000_000, depth=10_000)
    record.api_quotes = [
        ApiQuote(source="a", symbol="SKEW", address="0x0", volume_usd_24h=500_000),
        ApiQuote(source="b", symbol="SKEW", address="0x0", volume_usd_24h=1_000_000),
        ApiQuote(source="c", symbol="SKEW", address="0x0", volume_usd_24h=2_000_000),
    ]
    assert api_delta(record) == pytest.approx(0.0)
    apply_flags([record], RunParams())
    assert "api_delta" not in record.flags


def test_build_metrics_aggregates_pools_and_picks_a_tick_spacing() -> None:
    params = RunParams(placements=(300.0,))
    token = make_token("MULTI")
    markets = {
        token.key: [
            make_market(token, volume7=1_000, volume30=10_000, depth=50_000, tick_spacing=10),
            make_market(token, volume7=3_000, volume30=30_000, depth=100_000, tick_spacing=10),
            make_market(token, volume7=1, volume30=1, depth=1, tick_spacing=200, protocol="v3"),
        ]
    }
    records, quartiles = build_metrics([token], markets, {"MULTI": feed("MULTI")}, {}, params)
    record = records[0]
    assert record.volume_usd_30d == pytest.approx(40_001)
    assert record.depth_usd_2pct == pytest.approx(150_001)
    assert record.tick_spacing == 10, "v3 spacings do not vote"
    assert record.turnover == pytest.approx((40_001 / 30) / 150_001)
    assert roi_of(record, params) > 0
    assert quartiles["population"] == 1
