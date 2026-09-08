# SPDX-License-Identifier: MIT
"""Price, depth and volatility math for concentrated-liquidity pools.

Three things the rest of the pipeline needs and nothing else:

* **Price** from a `sqrtPriceX96`, decimal-adjusted.
* **Depth within +/-2%** — the denominator of the capturable-share model. For a concentrated pool
  this is *not* TVL: what matters is how much of each side sits between the current price and the
  price 2% away. Under the standard constant-liquidity approximation over that band,

      amount1 (quote) = L * (sqrt(P_hi) - sqrt(P))
      amount0 (base)  = L * (1/sqrt(P_lo) - 1/sqrt(P))

  both in raw token units, and the USD depth is the two of them priced and summed. The
  approximation is exact while no tick boundary is crossed inside the band and understates depth
  when a tighter position sits just outside the current tick range; it is the same estimator
  DEX aggregators publish as "2% depth", and the report says so.
* **Realised volatility** from a daily close series built out of swap prices.
"""

from __future__ import annotations

import math

Q96 = 1 << 96
#: Trading days used to annualise on-chain daily log returns. Stock tokens trade on a 24/5-ish
#: chain rather than a 6.5 h session, so calendar-day annualisation is the honest convention here.
ANNUALISATION_DAYS = 365
#: The band the depth figure is measured over, each way.
DEPTH_BAND = 0.02


def price_from_sqrt_x96(sqrt_price_x96: int, decimals0: int, decimals1: int) -> float:
    """Price of token0 denominated in token1, decimal-adjusted."""
    if sqrt_price_x96 <= 0:
        return 0.0
    ratio = (sqrt_price_x96 / Q96) ** 2
    return ratio * (10**decimals0) / (10**decimals1)


def sqrt_x96_from_price(price: float, decimals0: int, decimals1: int) -> int:
    """Inverse of `price_from_sqrt_x96`, for fixtures and round-trip tests."""
    if price <= 0:
        return 0
    ratio = price * (10**decimals1) / (10**decimals0)
    return int(math.sqrt(ratio) * Q96)


def depth_usd_within_band(
    *,
    liquidity: int,
    sqrt_price_x96: int,
    decimals0: int,
    decimals1: int,
    price0_usd: float | None,
    price1_usd: float | None,
    band: float = DEPTH_BAND,
) -> float | None:
    """Two-sided USD notional inside `+/-band` of the current price.

    Returns `None` when neither side can be priced; a side that cannot be priced contributes 0 and
    the caller is expected to note the one-sided read.
    """
    if liquidity <= 0 or sqrt_price_x96 <= 0:
        return 0.0
    if price0_usd is None and price1_usd is None:
        return None

    sqrt_p = sqrt_price_x96 / Q96
    sqrt_hi = sqrt_p * math.sqrt(1.0 + band)
    sqrt_lo = sqrt_p * math.sqrt(max(1e-18, 1.0 - band))

    amount1_raw = liquidity * (sqrt_hi - sqrt_p)
    amount0_raw = liquidity * (1.0 / sqrt_lo - 1.0 / sqrt_p)

    total = 0.0
    if price1_usd is not None:
        total += (amount1_raw / 10**decimals1) * price1_usd
    if price0_usd is not None:
        total += (amount0_raw / 10**decimals0) * price0_usd
    return total


def realised_vol_annual(closes: list[float]) -> tuple[float | None, int]:
    """Annualised stdev of daily log returns, and the number of returns it used.

    Fewer than three returns is not a volatility estimate; the caller gets `None` and the name
    keeps the `insufficient_history` flag rather than an invented sigma.
    """
    prices = [p for p in closes if p and p > 0]
    if len(prices) < 4:
        return None, max(0, len(prices) - 1)
    returns = [math.log(prices[i] / prices[i - 1]) for i in range(1, len(prices))]
    n = len(returns)
    mean = sum(returns) / n
    variance = sum((r - mean) ** 2 for r in returns) / (n - 1)
    return math.sqrt(variance) * math.sqrt(ANNUALISATION_DAYS), n


def daily_close_map(samples: list[tuple[int, float]]) -> dict[int, float]:
    """`utc_day -> last price of that day` from `(unix_ts, price)` samples."""
    by_day: dict[int, tuple[int, float]] = {}
    for ts, price in samples:
        if price is None or price <= 0:
            continue
        day = ts // 86_400
        seen = by_day.get(day)
        if seen is None or ts >= seen[0]:
            by_day[day] = (ts, price)
    return {day: value[1] for day, value in by_day.items()}


def daily_closes(samples: list[tuple[int, float]]) -> list[float]:
    """Last price of each UTC day, oldest first, from `(unix_ts, price)` samples."""
    by_day = daily_close_map(samples)
    return [by_day[day] for day in sorted(by_day)]


def median(values: list[float]) -> float:
    """Median of `values`; 0.0 for an empty list."""
    if not values:
        return 0.0
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return 0.5 * (ordered[mid - 1] + ordered[mid])


def quantile(values: list[float], q: float) -> float:
    """Linear-interpolation quantile, matching `numpy.quantile`'s default method."""
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * q
    lo = math.floor(position)
    hi = math.ceil(position)
    if lo == hi:
        return ordered[int(position)]
    return ordered[lo] * (hi - position) + ordered[hi] * (position - lo)


def geometric_mean(a: float, b: float) -> float:
    """`sqrt(a*b)`, clamped at zero so a dead leg cannot produce a complex weight."""
    if a <= 0 or b <= 0:
        return 0.0
    return math.sqrt(a * b)
