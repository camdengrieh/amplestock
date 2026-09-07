# SPDX-License-Identifier: MIT
"""Collector 5 — third-party aggregators, used only to challenge the chain read.

GeckoTerminal, DexPaprika and DexScreener each publish a 24 h volume and a pool reserve for the
same pools this pipeline reads from `Swap` events. They index differently (routing hops, wrapped
legs, their own USD price source), so they will not agree with the chain to the dollar, and none of
them decides anything here: `model.py` consumes chain numbers and the report prints the delta.

A delta bigger than `--api-delta-warn` (default 40%) raises a warning against that name, because in
practice a gap that wide means one of two things worth knowing before launch: the pool is being
routed through a hop this pipeline does not decode, or the aggregator is stale.

All three are rate-limited (GeckoTerminal's free tier is ~30 requests/minute), so a real run sleeps
between calls; `--api-delay` tunes it and `--no-cross-check` skips the whole collector.
"""

from __future__ import annotations

import time
from typing import Any

from ..chain import DEXPAPRIKA_TOKEN_URL, DEXSCREENER_TOKEN_URL, GECKOTERMINAL_POOLS_URL
from ..records import ApiQuote, StockToken
from ..transport import TransportError
from .base import Collector, RunContext


def _num(value: Any) -> float | None:
    """Tolerant numeric parse: aggregators mix strings, floats and `None`."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).replace(",", "").replace("$", "").strip()
    try:
        return float(text)
    except ValueError:
        return None


def _dig(payload: Any, *path: str) -> Any:
    """Walk a nested dict path, returning `None` at the first miss."""
    node = payload
    for key in path:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


class ApiCrossCheckCollector(Collector):
    """One `ApiQuote` per (source, token), best-effort."""

    key = "api-crosscheck"
    hosts = ("api.geckoterminal.com", "api.dexpaprika.com", "api.dexscreener.com")

    def __init__(self, *, delay_seconds: float = 2.0, sleep: Any = time.sleep) -> None:
        self.delay_seconds = delay_seconds
        self._sleep = sleep

    def collect(self, ctx: RunContext) -> Any:
        """Unused: the cross-check needs the token list, see `collect_for`."""
        raise NotImplementedError("use collect_for(ctx, tokens)")

    def collect_for(self, ctx: RunContext, tokens: list[StockToken]) -> dict[str, list[ApiQuote]]:
        """`token address -> quotes`, one per source that answered."""
        if not ctx.params.cross_check:
            ctx.record(self.key, "disabled", "-", True, 0, "--no-cross-check")
            return {}

        out: dict[str, list[ApiQuote]] = {}
        ok = {"geckoterminal": 0, "dexpaprika": 0, "dexscreener": 0}
        for token in tokens:
            for source, fetch in (
                ("geckoterminal", self._geckoterminal),
                ("dexpaprika", self._dexpaprika),
                ("dexscreener", self._dexscreener),
            ):
                quote = fetch(ctx, token)
                if quote is not None:
                    out.setdefault(token.key, []).append(quote)
                    ok[source] += 1
                if self.delay_seconds and not ctx.params.fixtures:
                    self._sleep(self.delay_seconds)
        for source, count in ok.items():
            ctx.record(self.key, source, source, count > 0, count)
        return out

    # -- sources ---------------------------------------------------------------------------------

    def _geckoterminal(self, ctx: RunContext, token: StockToken) -> ApiQuote | None:
        url = GECKOTERMINAL_POOLS_URL.format(address=token.address)
        payload = self._get(ctx, url)
        if payload is None:
            return None
        pools = payload.get("data") if isinstance(payload, dict) else payload
        if not isinstance(pools, list):
            return None
        volume = reserve = 0.0
        for pool in pools:
            attributes = pool.get("attributes", {}) if isinstance(pool, dict) else {}
            volume += _num(_dig(attributes, "volume_usd", "h24")) or 0.0
            reserve += _num(attributes.get("reserve_in_usd")) or 0.0
        return ApiQuote(
            source="geckoterminal",
            symbol=token.symbol,
            address=token.address,
            volume_usd_24h=volume,
            reserve_usd=reserve,
            pools=len(pools),
        )

    def _dexpaprika(self, ctx: RunContext, token: StockToken) -> ApiQuote | None:
        url = DEXPAPRIKA_TOKEN_URL.format(address=token.address)
        payload = self._get(ctx, url)
        if payload is None:
            return None
        pools = payload.get("pools") if isinstance(payload, dict) else payload
        if not isinstance(pools, list):
            return None
        volume = reserve = 0.0
        for pool in pools:
            if not isinstance(pool, dict):
                continue
            volume += _num(pool.get("volume_usd") or _dig(pool, "day", "volume_usd")) or 0.0
            reserve += _num(pool.get("reserve_in_usd") or pool.get("liquidity_usd")) or 0.0
        return ApiQuote(
            source="dexpaprika",
            symbol=token.symbol,
            address=token.address,
            volume_usd_24h=volume,
            reserve_usd=reserve,
            pools=len(pools),
        )

    def _dexscreener(self, ctx: RunContext, token: StockToken) -> ApiQuote | None:
        url = DEXSCREENER_TOKEN_URL.format(address=token.address)
        payload = self._get(ctx, url)
        if payload is None:
            return None
        pairs = payload if isinstance(payload, list) else payload.get("pairs")
        if not isinstance(pairs, list):
            return None
        volume = reserve = 0.0
        for pair in pairs:
            if not isinstance(pair, dict):
                continue
            volume += _num(_dig(pair, "volume", "h24")) or 0.0
            reserve += _num(_dig(pair, "liquidity", "usd")) or 0.0
        return ApiQuote(
            source="dexscreener",
            symbol=token.symbol,
            address=token.address,
            volume_usd_24h=volume,
            reserve_usd=reserve,
            pools=len(pairs),
        )

    def _get(self, ctx: RunContext, url: str) -> Any:
        try:
            return ctx.transport.get_json(url)
        except TransportError as exc:
            ctx.record(self.key, "fetch", url, False, note=str(exc))
            return None
