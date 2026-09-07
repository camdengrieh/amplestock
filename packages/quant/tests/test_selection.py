# SPDX-License-Identifier: MIT
"""Selection and weighting.

The weight tests are the important ones: `PoolRegistry.setIndexWeights` reverts unless the vector
sums to exactly 10,000 bp with every entry inside `[floor_n, cap_n]`, so a rounding bug here is a
failed governance call on launch day.
"""

from __future__ import annotations

import random

import pytest
from conftest import make_market, make_token

from amplestocks_quant.constituents.config import RunParams
from amplestocks_quant.constituents.model import apply_flags, score_token
from amplestocks_quant.constituents.records import FeedInfo, TokenMetrics
from amplestocks_quant.constituents.selection import cap_bps, floor_bps, index_weights, select


def record(symbol: str, volume30: float, depth: float, *, volume7: float | None = None,
           feed: bool = True, vol: float | None = 0.3) -> TokenMetrics:
    token = make_token(symbol)
    market = make_market(token, volume7=volume7 if volume7 is not None else volume30 / 4,
                         volume30=volume30, depth=depth)
    return TokenMetrics(
        token=token,
        markets=[market],
        volume_usd_7d=volume7 if volume7 is not None else volume30 / 4,
        volume_usd_30d=volume30,
        depth_usd_2pct=depth,
        price_usd=10.0,
        effective_fee_bps=30.0,
        realised_vol_annual=vol,
        feed=FeedInfo(symbol=symbol, name=f"{symbol} / USD", proxy="0x" + "22" * 20,
                      heartbeat_seconds=3600) if feed else None,
    )


def prepared(records: list[TokenMetrics], params: RunParams) -> list[TokenMetrics]:
    apply_flags(records, params)
    for item in records:
        score_token(item, params)
    return records


# ------------------------------------------------------------------------------------------------
# The registry band
# ------------------------------------------------------------------------------------------------


def test_cap_and_floor_match_the_solidity_constants() -> None:
    assert (cap_bps(1), floor_bps(1)) == (10_000, 500)
    assert (cap_bps(3), floor_bps(3)) == (3_334, 500)
    assert (cap_bps(4), floor_bps(4)) == (3_000, 500)
    assert (cap_bps(10), floor_bps(10)) == (3_000, 500)
    assert (cap_bps(30), floor_bps(30)) == (3_000, 166)
    assert (cap_bps(64), floor_bps(64)) == (3_000, 78)


def test_a_legal_vector_always_exists_for_every_reachable_count() -> None:
    for n in range(1, 65):
        assert n * floor_bps(n) <= 10_000 <= n * cap_bps(n)


@pytest.mark.parametrize("n", [1, 2, 3, 12, 29, 30, 31, 64])
def test_weights_sum_to_exactly_10000_inside_the_band(n: int) -> None:
    rng = random.Random(n)
    raw = [rng.uniform(0.0, 10.0**rng.randint(0, 9)) for _ in range(n)]
    weights = index_weights(raw, n)
    assert sum(weights) == 10_000
    assert all(floor_bps(n) <= w <= cap_bps(n) for w in weights)
    assert len(weights) == n


def test_weights_hold_the_invariant_over_many_random_shapes() -> None:
    """The property `setIndexWeights` actually enforces, over the shapes that break naive code."""
    rng = random.Random(7)
    for _ in range(400):
        n = rng.randint(1, 64)
        style = rng.choice(("uniform", "skew", "zeros", "one_big", "equal"))
        if style == "uniform":
            raw = [rng.uniform(0, 1e6) for _ in range(n)]
        elif style == "skew":
            raw = [10.0 ** rng.randint(0, 12) for _ in range(n)]
        elif style == "zeros":
            raw = [0.0 if rng.random() < 0.7 else rng.uniform(0, 1e6) for _ in range(n)]
        elif style == "one_big":
            raw = [1e12] + [rng.uniform(0, 1) for _ in range(n - 1)]
        else:
            raw = [1.0] * n
        weights = index_weights(raw, n)
        assert sum(weights) == 10_000, (n, style)
        assert all(floor_bps(n) <= w <= cap_bps(n) for w in weights), (n, style)


def test_weights_track_the_raw_ordering_where_the_band_allows() -> None:
    weights = index_weights([100.0, 50.0, 25.0, 25.0], 4)
    assert weights[0] >= weights[1] >= weights[2]
    assert sum(weights) == 10_000


def test_one_dominant_name_is_capped_and_the_rest_share_the_remainder() -> None:
    weights = index_weights([10**9, 1.0, 1.0, 1.0, 1.0], 5)
    assert weights[0] == cap_bps(5)
    assert sum(weights) == 10_000
    assert min(weights[1:]) >= floor_bps(5)


def test_all_zero_raw_weights_degrade_to_equal_weight() -> None:
    weights = index_weights([0.0] * 30, 30)
    assert sum(weights) == 10_000
    assert max(weights) - min(weights) <= 1


def test_empty_set_has_no_weights() -> None:
    assert index_weights([], 0) == []


# ------------------------------------------------------------------------------------------------
# Selection
# ------------------------------------------------------------------------------------------------


def test_dead_and_feedless_names_are_dropped_before_ranking() -> None:
    params = RunParams(count=3, placements=(300.0,), min_high_volume=0)
    records = prepared(
        [
            record("GOOD1", 30_000_000, 100_000),
            record("GOOD2", 20_000_000, 200_000),
            record("GOOD3", 10_000_000, 300_000),
            record("NOFEED", 90_000_000, 50_000, feed=False),
            record("DEAD", 5_000_000, 400_000, volume7=0),
            record("DUST", 5_000_000, 10),
        ],
        params,
    )
    result = select(records, params)
    assert [c.metrics.symbol for c in result.chosen] == ["GOOD1", "GOOD2", "GOOD3"]
    reasons = {r.symbol: r.reason for r in result.rejected}
    assert reasons["NOFEED"] == "no_feed"
    assert reasons["DEAD"] == "dead" and reasons["DUST"] == "dead"


def test_ranking_is_by_roi_with_volume_as_the_tie_break() -> None:
    params = RunParams(count=2, placements=(300.0,), min_high_volume=0)
    # Same ROI (same volume/depth ratio), different volume.
    records = prepared(
        [record("SMALL", 1_000_000, 10_000), record("LARGE", 10_000_000, 100_000)], params
    )
    result = select(records, params)
    assert next(c.metrics.symbol for c in result.chosen) == "LARGE"


def test_rotation_depth_rule_promotes_deep_names_over_thin_ones() -> None:
    params = RunParams(count=4, placements=(300.0,), min_high_volume=2)
    # Four thin books out-rank two deep ones on ROI; the rule pulls two deep names back in.
    records = prepared(
        [
            record("THIN1", 20_000_000, 20_000),
            record("THIN2", 18_000_000, 20_000),
            record("THIN3", 16_000_000, 20_000),
            record("THIN4", 14_000_000, 20_000),
            record("DEEP1", 900_000_000, 40_000_000),
            record("DEEP2", 800_000_000, 40_000_000),
        ],
        params,
    )
    result = select(records, params)
    chosen = [c.metrics.symbol for c in result.chosen]
    assert len(chosen) == 4
    assert "DEEP1" in chosen and "DEEP2" in chosen
    assert sum(1 for c in result.chosen if "high_volume" in c.metrics.flags) >= 2
    assert any("rotation-depth" in note for note in result.notes)
    displaced = {r.symbol for r in result.rejected if r.reason == "displaced"}
    assert displaced.issubset({"THIN1", "THIN2", "THIN3", "THIN4"})


def test_the_rule_cannot_promote_names_that_do_not_exist() -> None:
    params = RunParams(count=2, placements=(300.0,), min_high_volume=10)
    records = prepared([record("A", 1_000_000, 10_000), record("B", 900_000, 10_000)], params)
    result = select(records, params)
    assert len(result.chosen) == 2


def test_a_short_universe_reports_a_shortfall_rather_than_padding() -> None:
    params = RunParams(count=30, placements=(300.0,), min_high_volume=0)
    records = prepared([record(f"T{i}", 1_000_000 * (i + 1), 100_000) for i in range(5)], params)
    result = select(records, params)
    assert len(result.chosen) == 5
    assert result.shortfall == 25
    assert any("short of the launch count" in note for note in result.notes)


def test_selected_weights_sum_and_rationales_are_populated() -> None:
    params = RunParams(count=12, placements=(300.0,), min_high_volume=0)
    records = prepared(
        [record(f"T{i}", 1_000_000 * (i + 1), 50_000 * (i + 1)) for i in range(20)], params
    )
    result = select(records, params)
    assert sum(c.target_weight_bps for c in result.chosen) == 10_000
    assert all(c.rollout_weight_bps == c.target_weight_bps for c in result.chosen)
    assert all(c.rationale and "ROI" in c.rationale for c in result.chosen)
    assert [c.rank for c in result.chosen] == list(range(1, 13))
