# SPDX-License-Identifier: MIT
"""Collector 4 — Chainlink feeds, the one hard requirement.

`FeedRegistry` prices the basket, `OracleGate` gates every placement on a fresh answer, and
`05_Registry.s.sol` refuses to register a constituent whose feed is the zero address. So a stock
token without a **Standard** (non-SVR) equity feed on 4663 is not a candidate at any volume, and
`no_feed` is a hard drop rather than a penalty.

Source: the Chainlink Reference Data Directory, `feeds-robinhood-mainnet.json`. The parser keeps
`proxyAddress`, `heartbeat` and `threshold` (the deviation threshold, in percent) because
`FeedRegistry.setFeed` needs the heartbeat and the report needs the threshold to explain how stale
an answer can be before `OracleGate` stops the vault.

**SVR** ("Smart Value Recapture") feeds share a ticker with the Standard feed but route MEV back to
the protocol that integrates them; they are a different product with different liveness. When both
exist for a ticker the Standard one wins and the SVR one is recorded as an alternative.
"""

from __future__ import annotations

from typing import Any

from ..abi import checksum_address
from ..chain import CHAINLINK_RDD_URL
from ..records import FeedInfo
from ..transport import TransportError
from .base import Collector, RunContext

_SVR_HINTS = ("svr", "smart value recapture")


def _looks_svr(entry: dict[str, Any]) -> bool:
    """True when any identifying field marks the entry as an SVR feed."""
    haystack = " ".join(
        str(entry.get(key, "")) for key in ("name", "path", "ens", "feedType", "contractType")
    )
    docs = entry.get("docs")
    if isinstance(docs, dict):
        haystack += " " + " ".join(str(v) for v in docs.values())
    haystack = haystack.lower()
    return any(hint in haystack for hint in _SVR_HINTS)


def _symbol_of(entry: dict[str, Any]) -> str:
    """Base ticker of a `<BASE> / USD` feed."""
    pair = entry.get("pair")
    if isinstance(pair, list) and pair:
        return str(pair[0]).strip().upper()
    docs = entry.get("docs")
    if isinstance(docs, dict) and docs.get("baseAsset"):
        return str(docs["baseAsset"]).strip().upper()
    name = str(entry.get("name", ""))
    if "/" in name:
        return name.split("/")[0].strip().upper()
    return name.strip().upper()


def _quote_of(entry: dict[str, Any]) -> str:
    pair = entry.get("pair")
    if isinstance(pair, list) and len(pair) > 1:
        return str(pair[1]).strip().upper()
    docs = entry.get("docs")
    if isinstance(docs, dict) and docs.get("quoteAsset"):
        return str(docs["quoteAsset"]).strip().upper()
    name = str(entry.get("name", ""))
    return name.split("/")[-1].strip().upper() if "/" in name else ""


def _asset_class(entry: dict[str, Any]) -> str:
    docs = entry.get("docs")
    if isinstance(docs, dict) and docs.get("assetClass"):
        return str(docs["assetClass"])
    return str(entry.get("feedType", ""))


class FeedCollector(Collector):
    """Chainlink RDD reader: `ticker -> FeedInfo` for every USD-quoted feed on 4663."""

    key = "feeds"
    hosts = ("reference-data-directory.vercel.app",)

    def collect(self, ctx: RunContext) -> dict[str, FeedInfo]:
        """`SYMBOL -> FeedInfo`, Standard feeds preferred over SVR."""
        url = CHAINLINK_RDD_URL
        try:
            payload = ctx.transport.get_json(url)
        except TransportError as exc:
            ctx.record(self.key, "chainlink-rdd", url, False, note=str(exc))
            ctx.warn(f"Chainlink RDD unavailable ({exc}); no name can clear the feed requirement")
            return {}

        entries = payload if isinstance(payload, list) else payload.get("feeds", [])
        standard: dict[str, FeedInfo] = {}
        svr: dict[str, FeedInfo] = {}
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            proxy = entry.get("proxyAddress") or entry.get("contractAddress")
            symbol = _symbol_of(entry)
            if not proxy or not symbol or _quote_of(entry) not in ("USD", ""):
                continue
            info = FeedInfo(
                symbol=symbol,
                name=str(entry.get("name", f"{symbol} / USD")),
                proxy=checksum_address(str(proxy)),
                heartbeat_seconds=_as_int(entry.get("heartbeat")),
                threshold_percent=_as_float(entry.get("threshold")),
                is_svr=_looks_svr(entry),
                category=str(entry.get("feedCategory", "")),
                asset_class=_asset_class(entry),
            )
            target = svr if info.is_svr else standard
            target.setdefault(symbol, info)

        for symbol, info in svr.items():
            if symbol not in standard:
                # Recorded, but not usable: the pipeline never promotes an SVR-only ticker.
                info.category = (info.category + " (SVR only)").strip()
        ctx.record(
            self.key,
            "chainlink-rdd",
            url,
            True,
            len(standard),
            f"{len(standard)} standard, {len(svr)} SVR",
        )
        return standard


def _as_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _as_float(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None
