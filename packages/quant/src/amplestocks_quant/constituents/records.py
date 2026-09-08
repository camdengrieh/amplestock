# SPDX-License-Identifier: MIT
"""The data model the collectors fill in and the model/selection stages consume.

One rule runs through every record here: **a field that was not measured is `None`, never a
default.** A missing 30-day volume is not zero volume, an unreadable `uiMultiplier()` is not 1.0,
and a token with no Chainlink entry is not a token with a feed at the zero address. The report
prints the difference, and `selection.py` refuses to promote anything whose hard requirements were
merely assumed.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

# ------------------------------------------------------------------------------------------------
# Provenance
# ------------------------------------------------------------------------------------------------


@dataclass
class SourceRecord:
    """One attempt at one upstream source, successful or not."""

    collector: str
    source: str
    url: str
    ok: bool
    items: int = 0
    note: str = ""

    def to_dict(self) -> dict[str, Any]:
        """JSON form."""
        return {
            "collector": self.collector,
            "source": self.source,
            "url": self.url,
            "ok": self.ok,
            "items": self.items,
            "note": self.note,
        }


# ------------------------------------------------------------------------------------------------
# Universe
# ------------------------------------------------------------------------------------------------


@dataclass
class StockToken:
    """A Robinhood Stock Token, merged across the universe sources."""

    symbol: str
    address: str
    name: str = ""
    decimals: int | None = None
    #: `uiMultiplier()` scaled to a float, or `None` when the call reverted / was never made.
    ui_multiplier: float | None = None
    #: `True` when the ERC-1967 beacon slot was read and equals the stock-token beacon.
    beacon_verified: bool | None = None
    kind: str = "equity"
    sources: tuple[str, ...] = ()
    notes: list[str] = field(default_factory=list)

    @property
    def key(self) -> str:
        """Lowercased address, the canonical key everywhere in this package."""
        return self.address.lower()

    def to_dict(self) -> dict[str, Any]:
        """JSON form."""
        return {
            "symbol": self.symbol,
            "name": self.name,
            "address": self.address,
            "decimals": self.decimals,
            "uiMultiplier": self.ui_multiplier,
            "beaconVerified": self.beacon_verified,
            "kind": self.kind,
            "sources": list(self.sources),
            "notes": list(self.notes),
        }


# ------------------------------------------------------------------------------------------------
# Pools
# ------------------------------------------------------------------------------------------------


@dataclass
class Pool:
    """A pool that has the stock token on one side.

    `identifier` is the v4 `PoolId` or the v3 pool address; `token`/`counter` are the stock token
    and whatever it trades against, regardless of currency ordering.
    """

    protocol: str  # "v4" | "v3"
    identifier: str
    token: str
    counter: str
    counter_symbol: str
    fee_bps: float | None = None
    dynamic_fee: bool = False
    tick_spacing: int | None = None
    hooks: str | None = None
    token_is_currency0: bool = True
    created_block: int | None = None
    #: v4 only: the `Initialize` sqrt price, kept as the fallback price when no swap is in range.
    init_sqrt_price_x96: int | None = None

    def to_dict(self) -> dict[str, Any]:
        """JSON form."""
        return {
            "protocol": self.protocol,
            "id": self.identifier,
            "token": self.token,
            "counter": self.counter,
            "counterSymbol": self.counter_symbol,
            "feeBps": self.fee_bps,
            "dynamicFee": self.dynamic_fee,
            "tickSpacing": self.tick_spacing,
            "hooks": self.hooks,
            "tokenIsCurrency0": self.token_is_currency0,
            "createdBlock": self.created_block,
        }


@dataclass
class PoolMarket:
    """Measured market state for one pool over the run's windows."""

    pool: Pool
    volume_usd_7d: float = 0.0
    volume_usd_30d: float = 0.0
    swaps_7d: int = 0
    swaps_30d: int = 0
    #: USD notional inside +/-2% of the current price, both sides summed.
    depth_usd_2pct: float | None = None
    price_usd: float | None = None
    liquidity: int | None = None
    sqrt_price_x96: int | None = None
    #: Volume-weighted realised fee over the window, in bps.
    effective_fee_bps: float | None = None
    #: `(unix_day, close_price_usd)` from the last swap of each UTC day, for realised vol.
    daily_prices: list[tuple[int, float]] = field(default_factory=list)
    first_swap_ts: int | None = None
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        """JSON form."""
        out = self.pool.to_dict()
        out.update(
            {
                "volumeUsd7d": self.volume_usd_7d,
                "volumeUsd30d": self.volume_usd_30d,
                "swaps7d": self.swaps_7d,
                "swaps30d": self.swaps_30d,
                "depthUsd2pct": self.depth_usd_2pct,
                "priceUsd": self.price_usd,
                "liquidity": self.liquidity,
                "effectiveFeeBps": self.effective_fee_bps,
                "firstSwapTs": self.first_swap_ts,
                "notes": list(self.notes),
            }
        )
        return out


# ------------------------------------------------------------------------------------------------
# Feeds
# ------------------------------------------------------------------------------------------------


@dataclass
class FeedInfo:
    """One Chainlink Reference Data Directory entry, reduced to what registration needs."""

    symbol: str
    name: str
    proxy: str
    heartbeat_seconds: int | None = None
    threshold_percent: float | None = None
    is_svr: bool = False
    category: str = ""
    asset_class: str = ""

    def to_dict(self) -> dict[str, Any]:
        """JSON form."""
        return {
            "symbol": self.symbol,
            "name": self.name,
            "proxy": self.proxy,
            "heartbeatSeconds": self.heartbeat_seconds,
            "thresholdPercent": self.threshold_percent,
            "isSvr": self.is_svr,
            "category": self.category,
            "assetClass": self.asset_class,
        }


# ------------------------------------------------------------------------------------------------
# Cross-check
# ------------------------------------------------------------------------------------------------


@dataclass
class ApiQuote:
    """A third-party read of one token's aggregate market, used only to challenge the chain read."""

    source: str
    symbol: str
    address: str
    volume_usd_24h: float | None = None
    volume_usd_7d: float | None = None
    reserve_usd: float | None = None
    pools: int = 0

    def to_dict(self) -> dict[str, Any]:
        """JSON form."""
        return {
            "source": self.source,
            "symbol": self.symbol,
            "address": self.address,
            "volumeUsd24h": self.volume_usd_24h,
            "volumeUsd7d": self.volume_usd_7d,
            "reserveUsd": self.reserve_usd,
            "pools": self.pools,
        }


# ------------------------------------------------------------------------------------------------
# Model output
# ------------------------------------------------------------------------------------------------


@dataclass
class PlacementScore:
    """The economics of one placement size `P` in one token."""

    placement_usd: float
    capturable_share: float
    revenue_usd_day_base: float
    revenue_usd_day_effective: float
    roi_base: float
    roi_effective: float

    def to_dict(self) -> dict[str, Any]:
        """JSON form."""
        return {
            "placementUsd": self.placement_usd,
            "capturableShare": self.capturable_share,
            "revenueUsdDayBase": self.revenue_usd_day_base,
            "revenueUsdDayEffective": self.revenue_usd_day_effective,
            "roiBase": self.roi_base,
            "roiEffective": self.roi_effective,
        }


@dataclass
class TokenMetrics:
    """Everything measured for one stock token, aggregated across its pools."""

    token: StockToken
    markets: list[PoolMarket] = field(default_factory=list)
    volume_usd_7d: float = 0.0
    volume_usd_30d: float = 0.0
    depth_usd_2pct: float = 0.0
    price_usd: float | None = None
    effective_fee_bps: float | None = None
    realised_vol_annual: float | None = None
    vol_observations: int = 0
    feed: FeedInfo | None = None
    api_quotes: list[ApiQuote] = field(default_factory=list)
    tick_spacing: int = 60
    flags: set[str] = field(default_factory=set)
    scores: dict[float, PlacementScore] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)

    @property
    def symbol(self) -> str:
        """The token's ticker."""
        return self.token.symbol

    @property
    def turnover(self) -> float | None:
        """`V30 / 30 / L` — daily volume per dollar of +/-2% depth."""
        if self.depth_usd_2pct <= 0:
            return None
        return (self.volume_usd_30d / 30.0) / self.depth_usd_2pct

    def to_dict(self) -> dict[str, Any]:
        """JSON form."""
        return {
            "symbol": self.symbol,
            "token": self.token.to_dict(),
            "pools": [m.to_dict() for m in self.markets],
            "poolCount": len(self.markets),
            "volumeUsd7d": self.volume_usd_7d,
            "volumeUsd30d": self.volume_usd_30d,
            "depthUsd2pct": self.depth_usd_2pct,
            "turnoverPerDay": self.turnover,
            "priceUsd": self.price_usd,
            "effectiveFeeBps": self.effective_fee_bps,
            "realisedVolAnnual": self.realised_vol_annual,
            "volObservations": self.vol_observations,
            "tickSpacing": self.tick_spacing,
            "feed": self.feed.to_dict() if self.feed else None,
            "apiQuotes": [q.to_dict() for q in self.api_quotes],
            "flags": sorted(self.flags),
            "scores": {str(p): s.to_dict() for p, s in sorted(self.scores.items())},
            "notes": list(self.notes),
        }


@dataclass
class Constituent:
    """A selected name, with everything the registry config needs."""

    metrics: TokenMetrics
    rank: int
    target_weight_bps: int
    rollout_weight_bps: int
    buy_fee_bps: int
    pool_class: str
    rationale: str

    def to_dict(self) -> dict[str, Any]:
        """JSON form."""
        return {
            "symbol": self.metrics.symbol,
            "rank": self.rank,
            "targetWeightBps": self.target_weight_bps,
            "rolloutWeightBps": self.rollout_weight_bps,
            "buyFeeBps": self.buy_fee_bps,
            "poolClass": self.pool_class,
            "rationale": self.rationale,
        }


@dataclass
class Rejection:
    """A name that was ranked but not selected, and why."""

    symbol: str
    reason: str
    detail: str = ""

    def to_dict(self) -> dict[str, Any]:
        """JSON form."""
        return {"symbol": self.symbol, "reason": self.reason, "detail": self.detail}


@dataclass
class SelectionResult:
    """The output of `selection.select`."""

    chosen: list[Constituent]
    rejected: list[Rejection]
    ranked: list[TokenMetrics]
    quartiles: dict[str, float]
    shortfall: int = 0
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        """JSON form."""
        return {
            "chosen": [c.to_dict() for c in self.chosen],
            "rejected": [r.to_dict() for r in self.rejected],
            "quartiles": self.quartiles,
            "shortfall": self.shortfall,
            "notes": list(self.notes),
        }
