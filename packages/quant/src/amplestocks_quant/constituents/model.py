# SPDX-License-Identifier: MIT
"""The revenue model: what a dollar of protocol-owned liquidity earns in each name.

For one stock token, aggregated over every pool it trades in:

    V7, V30  USD swap volume over the 7- and 30-day windows
    L        USD depth within +/-2% of price, summed across its pools (a head snapshot)
    P        the placement Amplestocks puts in that spoke, in USD
    s        = P / (L + P)          capturable share, proportional to in-range liquidity
    f        the fee Amplestocks charges on the stock leg (5 bp SPOKE, 10 bp SPOKE_HIGH_VOL)
    R        = (V30 / 30) * s * f   expected fee revenue per day, USD
    ROI      = R * 365 / P          annualised return on the placed capital

`s` is the honest part and the fragile part. It says a marginal dollar of liquidity earns fees in
proportion to its share of what is quotable at the touch, which is the standard first-order model
for a concentrated-liquidity LP and is right about *relative* attractiveness. What it cannot know
is how much of the measured flow would route through an `AMPS/<stock>` pool at all: today's volume
is `<stock>/USDG`, and a router only crosses the AMPS spoke for someone who wants AMPS on the other
side, or for an arbitrageur closing a gap against the index. Treat `R` as an upper bound on the
fee capture and as a *ranking* signal, not as a revenue forecast. The report repeats this.

Two fee bases are always computed: `base` (the protocol's own 5/10 bp) and `effective` (the
volume-weighted fee the token's existing pools actually charge). Ranking uses `--fee-basis`,
default `base`, because the base fee is what Amplestocks will charge whatever the incumbent tier is.
"""

from __future__ import annotations

from .config import RunParams
from .pricing import daily_closes, quantile, realised_vol_annual
from .records import ApiQuote, FeedInfo, PlacementScore, PoolMarket, StockToken, TokenMetrics

#: Flags a name can carry. Order is the report's column order.
FLAGS = (
    "high_volume",
    "thin_liquidity",
    "dead",
    "no_feed",
    "multiplier",
    "insufficient_history",
    "unpriced",
    "api_delta",
)


def build_metrics(
    tokens: list[StockToken],
    markets_by_token: dict[str, list[PoolMarket]],
    feeds: dict[str, FeedInfo],
    api_quotes: dict[str, list[ApiQuote]],
    params: RunParams,
) -> tuple[list[TokenMetrics], dict[str, float]]:
    """Aggregate pools into one record per token, then flag and score every one of them.

    Returns the records and the quartile cut-offs the flags were measured against.
    """
    metrics = [
        _aggregate(token, markets_by_token.get(token.key, []), feeds, api_quotes.get(token.key, []), params)
        for token in tokens
    ]
    quartiles = apply_flags(metrics, params)
    for record in metrics:
        score_token(record, params)
    return metrics, quartiles


# ------------------------------------------------------------------------------------------------
# Aggregation
# ------------------------------------------------------------------------------------------------


def _aggregate(
    token: StockToken,
    markets: list[PoolMarket],
    feeds: dict[str, FeedInfo],
    quotes: list[ApiQuote],
    params: RunParams,
) -> TokenMetrics:
    record = TokenMetrics(token=token, markets=markets, feed=feeds.get(token.symbol.upper()))
    record.api_quotes = quotes

    fee_weighted = 0.0
    fee_volume = 0.0
    samples: list[tuple[int, float]] = []
    deepest: tuple[float, float] | None = None
    for market in markets:
        record.volume_usd_7d += market.volume_usd_7d
        record.volume_usd_30d += market.volume_usd_30d
        record.depth_usd_2pct += market.depth_usd_2pct or 0.0
        if market.effective_fee_bps is not None and market.volume_usd_30d > 0:
            fee_weighted += market.effective_fee_bps * market.volume_usd_30d
            fee_volume += market.volume_usd_30d
        samples.extend(market.daily_prices)
        depth = market.depth_usd_2pct or 0.0
        if market.price_usd and (deepest is None or depth > deepest[1]):
            deepest = (market.price_usd, depth)

    record.effective_fee_bps = (fee_weighted / fee_volume) if fee_volume > 0 else None
    record.price_usd = deepest[0] if deepest else None
    record.realised_vol_annual, record.vol_observations = realised_vol_annual(daily_closes(samples))
    record.tick_spacing = _tick_spacing(markets, params.default_tick_spacing)
    for market in markets:
        record.notes.extend(f"{market.pool.identifier[:10]}: {note}" for note in market.notes)
    return record


def _tick_spacing(markets: list[PoolMarket], default: int) -> int:
    """The token's most common v4 tick spacing, else the launch default (60)."""
    counts: dict[int, int] = {}
    for market in markets:
        spacing = market.pool.tick_spacing
        if market.pool.protocol == "v4" and spacing:
            counts[spacing] = counts.get(spacing, 0) + 1
    if not counts:
        return default
    return min(counts.items(), key=lambda kv: (-kv[1], kv[0]))[0]


# ------------------------------------------------------------------------------------------------
# Flags
# ------------------------------------------------------------------------------------------------


def apply_flags(metrics: list[TokenMetrics], params: RunParams) -> dict[str, float]:
    """Set every flag on every record; returns the quartile cut-offs used.

    `dead` and `no_feed` are absolute. `high_volume` and `thin_liquidity` are quartiles measured
    over the *live, feed-having* population only: quartiles that include dead names would put a
    pool with $40 of volume in the top quartile of a set that is mostly zeros.
    """
    for record in metrics:
        record.flags -= {"dead", "high_volume", "thin_liquidity", "no_feed", "multiplier",
                         "insufficient_history", "unpriced", "api_delta"}
        if record.volume_usd_7d <= 0 or record.depth_usd_2pct < params.dead_depth_usd:
            record.flags.add("dead")
        if record.feed is None:
            record.flags.add("no_feed")
        multiplier = record.token.ui_multiplier
        if multiplier is not None and abs(multiplier - 1.0) > 1e-9:
            record.flags.add("multiplier")
        if record.realised_vol_annual is None:
            record.flags.add("insufficient_history")
        if record.price_usd is None:
            record.flags.add("unpriced")
        if _api_delta(record) is not None and abs(_api_delta(record) or 0.0) > 0.40:
            record.flags.add("api_delta")

    live = [m for m in metrics if "dead" not in m.flags and "no_feed" not in m.flags]
    volumes = [m.volume_usd_30d for m in live]
    turnovers = [m.turnover for m in live if m.turnover is not None]
    cuts = {
        "volume_p75": quantile(volumes, 0.75) if volumes else 0.0,
        "turnover_p75": quantile(turnovers, 0.75) if turnovers else 0.0,
        "population": float(len(live)),
    }
    for record in live:
        if record.volume_usd_30d >= cuts["volume_p75"] and record.volume_usd_30d > 0:
            record.flags.add("high_volume")
        turnover = record.turnover
        if turnover is not None and turnover >= cuts["turnover_p75"] and turnover > 0:
            record.flags.add("thin_liquidity")
    return cuts


def _api_delta(record: TokenMetrics) -> float | None:
    """Relative gap between the chain's daily volume and the aggregators' median 24 h volume."""
    quotes = [q.volume_usd_24h for q in record.api_quotes if q.volume_usd_24h is not None]
    if not quotes:
        return None
    chain_daily = record.volume_usd_30d / 30.0
    api_daily = sorted(quotes)[len(quotes) // 2]
    if api_daily <= 0 and chain_daily <= 0:
        return 0.0
    if api_daily <= 0:
        return 1.0
    return (chain_daily - api_daily) / api_daily


def api_delta(record: TokenMetrics) -> float | None:
    """Public alias of the chain-vs-API delta, for the report."""
    return _api_delta(record)


# ------------------------------------------------------------------------------------------------
# Scoring
# ------------------------------------------------------------------------------------------------


def buy_fee_bps(record: TokenMetrics, params: RunParams) -> float:
    """The spoke's own buy fee: 10 bp when realised vol clears the threshold, else 5 bp."""
    vol = record.realised_vol_annual
    if vol is not None and vol > params.vol_threshold:
        return params.spoke_high_vol_fee_bps
    return params.spoke_fee_bps


def pool_class(record: TokenMetrics, params: RunParams) -> str:
    """`SPOKE` or `SPOKE_HIGH_VOL`, from the same rule as `buy_fee_bps`."""
    return "SPOKE_HIGH_VOL" if buy_fee_bps(record, params) >= params.spoke_high_vol_fee_bps else "SPOKE"


def capturable_share(placement_usd: float, depth_usd: float) -> float:
    """`s = P / (L + P)`; a pool with no depth is fully capturable by definition."""
    denominator = depth_usd + placement_usd
    if denominator <= 0:
        return 0.0
    return placement_usd / denominator


def score_token(record: TokenMetrics, params: RunParams) -> None:
    """Fill `record.scores` for every placement size the run was asked about."""
    base_fee = buy_fee_bps(record, params) / 10_000.0
    effective_fee = (
        record.effective_fee_bps / 10_000.0 if record.effective_fee_bps is not None else base_fee
    )
    daily_volume = record.volume_usd_30d / max(1, params.window_days)

    for placement in params.placements:
        share = capturable_share(placement, record.depth_usd_2pct)
        revenue_base = daily_volume * share * base_fee
        revenue_effective = daily_volume * share * effective_fee
        record.scores[placement] = PlacementScore(
            placement_usd=placement,
            capturable_share=share,
            revenue_usd_day_base=revenue_base,
            revenue_usd_day_effective=revenue_effective,
            roi_base=(revenue_base * 365.0 / placement) if placement > 0 else 0.0,
            roi_effective=(revenue_effective * 365.0 / placement) if placement > 0 else 0.0,
        )


def roi_of(record: TokenMetrics, params: RunParams) -> float:
    """The ROI the ranking uses: primary placement, `--fee-basis` fee."""
    score = record.scores.get(params.placement)
    if score is None:
        return 0.0
    return score.roi_effective if params.fee_basis == "effective" else score.roi_base


def revenue_of(record: TokenMetrics, params: RunParams) -> float:
    """Daily USD revenue at the primary placement, on the ranking fee basis."""
    score = record.scores.get(params.placement)
    if score is None:
        return 0.0
    return score.revenue_usd_day_effective if params.fee_basis == "effective" else score.revenue_usd_day_base
