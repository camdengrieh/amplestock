# SPDX-License-Identifier: MIT
"""Picking the 30 and weighting them.

Selection, in order:

1. **Drop the impossible.** `dead` (no volume in the 7-day window, or less than `--dead-depth` of
   +/-2% depth) and `no_feed` (no Standard Chainlink equity feed on 4663) are hard drops. The feed
   is a contract-level requirement, not a preference: `05_Registry.s.sol` reverts on a zero feed.
2. **Rank by ROI** at the chosen placement, ties broken by 30-day volume.
3. **Guarantee rotation depth.** At least `--min-high-volume` (default 10) of the 30 come from the
   top-volume quartile, even if thin books out-rank them: the rotation credit and the bond desk
   both need names that can absorb size, and a launch set of nothing but $60k books would make the
   index untradeable at any size that matters.
4. **Weight.** `sqrt(V30 * L)` — the geometric mean of flow and depth — then the registry's own
   band, `cap_n = max(3000, ceilDiv(10000, n))` and `floor_n = min(500, 10000 / (2n))`, normalised
   to exactly 10,000 bp. Rollout weights equal target weights, per the launch config.

The geometric mean is deliberate: weighting on volume alone concentrates the index in whatever was
churning last month, weighting on depth alone concentrates it in whatever is easiest to buy. The
plan's "60-day median TVL x turnover" is the same shape; with a 30-day chain window this run cannot
compute a 60-day median, and the report says so.
"""

from __future__ import annotations

import math

from .config import RunParams
from .model import buy_fee_bps, pool_class, roi_of
from .pricing import geometric_mean
from .records import Constituent, Rejection, SelectionResult, TokenMetrics

#: `PoolRegistry` band ends, mirrored from `contracts/src/types/Constants.sol`.
INDEX_CAP_FLOOR_BPS = 3_000
INDEX_FLOOR_CEILING_BPS = 500
BPS = 10_000


def cap_bps(n: int) -> int:
    """`max(3000, ceilDiv(10000, n))` — the per-name cap at `n` constituents."""
    if n <= 0:
        return BPS
    return max(INDEX_CAP_FLOOR_BPS, -(-BPS // n))


def floor_bps(n: int) -> int:
    """`min(500, 10000 / (2n))` — the per-name floor at `n` constituents."""
    if n <= 0:
        return 0
    return min(INDEX_FLOOR_CEILING_BPS, BPS // (2 * n))


def _clamped_total(weights: list[float], scale: float, lo: int, hi: int) -> float:
    """`sum(clamp(scale * w_i, lo, hi))` — non-decreasing in `scale`."""
    return sum(min(float(hi), max(float(lo), scale * w)) for w in weights)


def index_weights(raw: list[float], n: int | None = None) -> list[int]:
    """Integer bps weights summing to exactly 10,000, every one inside `[floor_n, cap_n]`.

    The continuous step solves `sum(clamp(lambda * w_i, floor_n, cap_n)) = 10000` for `lambda` by
    bisection. Clamping one name at a time and redistributing does **not** work: when the cap binds
    on a few names at the same time as the floor binds on many, the redistribution over-spends the
    budget and the vector no longer sums to 10,000 (`PoolRegistry.setIndexWeights` would revert).
    Bisection has no such failure mode — the clamped total is monotone in `lambda`, it starts at
    `n * floor_n` and ends at `n * cap_n`, and `n * floor_n <= 10000 <= n * cap_n` holds for every
    reachable `n`.

    The integer step is largest-remainder, and never pushes a name past the cap or below the floor.
    """
    count = len(raw) if n is None else n
    if count <= 0:
        return []
    lo, hi = floor_bps(count), cap_bps(count)
    weights = [max(0.0, value) for value in raw]
    if sum(weights) <= 0:
        weights = [1.0] * count

    low, high = 0.0, 1.0
    for _ in range(200):
        if _clamped_total(weights, high, lo, hi) >= BPS:
            break
        high *= 2.0
    for _ in range(200):
        mid = 0.5 * (low + high)
        if _clamped_total(weights, mid, lo, hi) < BPS:
            low = mid
        else:
            high = mid
    scale = 0.5 * (low + high)
    values = [min(float(hi), max(float(lo), scale * w)) for w in weights]

    out = [math.floor(v) for v in values]
    remainder = BPS - sum(out)
    order = sorted(range(count), key=lambda i: (-(values[i] - math.floor(values[i])), -values[i]))
    cursor = 0
    guard = 0
    while remainder != 0 and guard < 4 * count + BPS:
        i = order[cursor % count]
        cursor += 1
        guard += 1
        if remainder > 0 and out[i] < hi:
            out[i] += 1
            remainder -= 1
        elif remainder < 0 and out[i] > lo:
            out[i] -= 1
            remainder += 1
    return out


def rationale(record: TokenMetrics, params: RunParams) -> str:
    """One line explaining why a name is in the set."""
    score = record.scores.get(params.placement)
    roi = roi_of(record, params)
    depth = record.depth_usd_2pct
    turnover = record.turnover
    parts: list[str] = []
    if "high_volume" in record.flags and "thin_liquidity" in record.flags:
        parts.append("top-quartile flow *and* top-quartile turnover for its depth")
    elif "high_volume" in record.flags:
        parts.append("top-quartile 30-day volume")
    elif "thin_liquidity" in record.flags:
        parts.append("thin book, high turnover")
    else:
        parts.append("mid-table flow and depth")
    parts.append(f"V30 {_usd(record.volume_usd_30d)}, L {_usd(depth)}")
    if turnover is not None:
        parts.append(f"turnover {turnover:.2f}x/day")
    if score is not None:
        parts.append(f"s {_share(score.capturable_share)}")
    parts.append(f"ROI {roi * 100:.1f}%/yr at ${params.placement:,.0f}")
    if "multiplier" in record.flags:
        parts.append(f"multiplier {record.token.ui_multiplier}")
    return "; ".join(parts)


def select(metrics: list[TokenMetrics], params: RunParams) -> SelectionResult:
    """Rank, pick and weight. Returns everything the report and the writers need."""
    rejected: list[Rejection] = []
    candidates: list[TokenMetrics] = []
    for record in metrics:
        if "no_feed" in record.flags:
            rejected.append(
                Rejection(record.symbol, "no_feed", "no Standard (non-SVR) Chainlink feed on 4663")
            )
            continue
        if "dead" in record.flags:
            rejected.append(
                Rejection(
                    record.symbol,
                    "dead",
                    f"V7 {_usd(record.volume_usd_7d)}, depth {_usd(record.depth_usd_2pct)}"
                    f" (< ${params.dead_depth_usd:,.0f})",
                )
            )
            continue
        candidates.append(record)

    ranked = sorted(candidates, key=lambda m: (-roi_of(m, params), -m.volume_usd_30d, m.symbol))
    chosen = ranked[: params.count]
    notes: list[str] = []

    # Rotation-depth guarantee.
    wanted = min(params.min_high_volume, sum(1 for m in ranked if "high_volume" in m.flags))
    have = sum(1 for m in chosen if "high_volume" in m.flags)
    if have < wanted:
        pool = [m for m in ranked[params.count :] if "high_volume" in m.flags]
        droppable = [m for m in reversed(chosen) if "high_volume" not in m.flags]
        promoted: list[str] = []
        for promote in pool:
            if have >= wanted or not droppable:
                break
            drop = droppable.pop(0)
            chosen[chosen.index(drop)] = promote
            promoted.append(f"{promote.symbol} in / {drop.symbol} out")
            rejected.append(
                Rejection(drop.symbol, "displaced", f"displaced by {promote.symbol} for rotation depth")
            )
            have += 1
        if promoted:
            notes.append(
                f"rotation-depth rule promoted {len(promoted)} high-volume name(s): " + ", ".join(promoted)
            )
    for record in ranked[params.count :]:
        if record in chosen:
            continue
        if not any(r.symbol == record.symbol for r in rejected):
            rejected.append(
                Rejection(record.symbol, "rank", f"ranked {ranked.index(record) + 1} of {len(ranked)}")
            )

    chosen = sorted(chosen, key=lambda m: (-roi_of(m, params), -m.volume_usd_30d, m.symbol))
    raw = [geometric_mean(m.volume_usd_30d, m.depth_usd_2pct) for m in chosen]
    weights = index_weights(raw, len(chosen))

    constituents = [
        Constituent(
            metrics=record,
            rank=i + 1,
            target_weight_bps=weights[i],
            rollout_weight_bps=weights[i],
            buy_fee_bps=int(buy_fee_bps(record, params)),
            pool_class=pool_class(record, params),
            rationale=rationale(record, params),
        )
        for i, record in enumerate(chosen)
    ]

    shortfall = max(0, params.count - len(constituents))
    if shortfall:
        notes.append(
            f"only {len(constituents)} of {params.count} names cleared the filters: "
            f"{shortfall} short of the launch count"
        )
    return SelectionResult(
        chosen=constituents,
        rejected=rejected,
        ranked=ranked,
        quartiles={},
        shortfall=shortfall,
        notes=notes,
    )


def _share(value: float) -> str:
    """Capturable share, kept legible from 40% down to a few parts per million."""
    scaled = value * 100
    if scaled >= 1:
        return f"{scaled:.2f}%"
    if scaled >= 0.01:
        return f"{scaled:.3f}%"
    return f"{scaled:.4f}%"


def _usd(value: float | None) -> str:
    """Compact USD formatting for prose."""
    if value is None:
        return "n/a"
    if value >= 1_000_000_000:
        return f"${value / 1e9:.2f}B"
    if value >= 1_000_000:
        return f"${value / 1e6:.2f}M"
    if value >= 1_000:
        return f"${value / 1e3:.1f}k"
    return f"${value:,.0f}"
