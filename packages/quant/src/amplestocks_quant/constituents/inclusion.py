# SPDX-License-Identifier: MIT
"""The registry's inclusion evidence, computed from the same swap prices as everything else.

`PoolRegistry` stores an `InclusionRecord{betaX18, trackingErrorX18, indexVolX18, historyDays}` with
every constituent and, whenever `rolloutWeightBps != 0`, enforces the plan's rule

    beta > 0.5 + trackingError^2 / (2 * indexVol^2)      and      historyDays >= 30

Today `contracts/script/config/constituents.json` carries hand-written placeholders for all four.
This module replaces the three statistical ones with measurements wherever the window supports it:

* the **index** is the equal-weighted daily log return of the selected set, over the days on which
  at least two names have a price;
* **beta** is `cov(r_i, r_index) / var(r_index)`;
* **tracking error** is the stdev of `r_i - beta * r_index`;
* **index vol** is the annualised stdev of `r_index`.

`historyDays` is what the run actually observed, which after a 30-day window is *at most 30* — one
day short of `MIN_HISTORY_DAYS`. That is not a bug in the model, it is the honest answer: a 30-day
chain window cannot evidence 30+ days of history, so a real registration needs `--window 45` or
longer (or the equity history from Phase 0A). The writer keeps `placeholder: true` on any record
whose inputs were insufficient, and the report calls the shortfall out.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .pricing import ANNUALISATION_DAYS, daily_close_map
from .records import TokenMetrics

#: Minimum overlapping daily returns before beta/TE mean anything.
MIN_RETURNS = 5
WAD = 10**18


@dataclass
class InclusionStats:
    """Measured inclusion evidence for one name."""

    symbol: str
    beta: float | None = None
    tracking_error: float | None = None
    index_vol: float | None = None
    history_days: int = 0
    measured: bool = False
    note: str = ""

    def passes(self) -> bool | None:
        """The registry's own test, or `None` when it could not be evaluated."""
        if not self.measured or self.beta is None or self.tracking_error is None or not self.index_vol:
            return None
        return self.beta > 0.5 + (self.tracking_error**2) / (2 * self.index_vol**2)

    def to_x18(self) -> dict[str, int]:
        """The four fields as the registry stores them."""
        return {
            "betaX18": round((self.beta or 0.0) * WAD),
            "trackingErrorX18": max(0, round((self.tracking_error or 0.0) * WAD)),
            "indexVolX18": max(0, round((self.index_vol or 0.0) * WAD)),
            "historyDays": self.history_days,
        }


def _returns(record: TokenMetrics) -> dict[int, float]:
    """`utc_day -> log return` for one name."""
    samples: list[tuple[int, float]] = []
    for market in record.markets:
        samples.extend(market.daily_prices)
    closes = daily_close_map(samples)
    days = sorted(closes)
    out: dict[int, float] = {}
    for i in range(1, len(days)):
        previous, current = closes[days[i - 1]], closes[days[i]]
        if previous > 0 and current > 0 and days[i] - days[i - 1] <= 4:
            out[days[i]] = math.log(current / previous)
    return out


def _stdev(values: list[float]) -> float:
    if len(values) < 2:
        return 0.0
    mean = sum(values) / len(values)
    return math.sqrt(sum((v - mean) ** 2 for v in values) / (len(values) - 1))


def compute_inclusion(records: list[TokenMetrics]) -> dict[str, InclusionStats]:
    """Inclusion evidence for every record, measured against the equal-weighted index of the set."""
    series = {record.symbol: _returns(record) for record in records}
    day_counts: dict[int, list[float]] = {}
    for returns in series.values():
        for day, value in returns.items():
            day_counts.setdefault(day, []).append(value)
    index = {day: sum(v) / len(v) for day, v in day_counts.items() if len(v) >= 2}

    index_days = sorted(index)
    index_values = [index[day] for day in index_days]
    index_vol_daily = _stdev(index_values)
    index_vol = index_vol_daily * math.sqrt(ANNUALISATION_DAYS)
    variance = index_vol_daily**2

    out: dict[str, InclusionStats] = {}
    for record in records:
        returns = series[record.symbol]
        history_days = len(returns) + (1 if returns else 0)
        common = [day for day in index_days if day in returns]
        stats = InclusionStats(symbol=record.symbol, history_days=history_days, index_vol=index_vol or None)
        if len(common) < MIN_RETURNS or variance <= 0:
            stats.note = f"{len(common)} overlapping days; need {MIN_RETURNS}"
            out[record.symbol] = stats
            continue
        own = [returns[day] for day in common]
        idx = [index[day] for day in common]
        own_mean = sum(own) / len(own)
        idx_mean = sum(idx) / len(idx)
        covariance = sum((o - own_mean) * (i - idx_mean) for o, i in zip(own, idx)) / (len(common) - 1)
        idx_var = sum((i - idx_mean) ** 2 for i in idx) / (len(common) - 1)
        if idx_var <= 0:
            stats.note = "index variance is zero over the window"
            out[record.symbol] = stats
            continue
        beta = covariance / idx_var
        residuals = [o - beta * i for o, i in zip(own, idx)]
        stats.beta = beta
        stats.tracking_error = _stdev(residuals) * math.sqrt(ANNUALISATION_DAYS)
        stats.index_vol = index_vol
        stats.measured = True
        out[record.symbol] = stats
    return out
