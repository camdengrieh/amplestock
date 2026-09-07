# SPDX-License-Identifier: MIT
"""Collector 1 — the Robinhood Stock Token universe.

Three sources, in the brief's priority order:

1. `https://api.robinhood.com/rhj/assets` — the issuer registry, and the only source that is
   authoritative about which tickers Robinhood itself considers live.
2. `https://docs.robinhood.com/chain/contracts/` — an HTML table, parsed with `html.parser`.
3. Blockscout `.../api/v2/tokens?type=ERC-20` — everything the explorer has indexed, filtered down
   to beacon proxies of the stock-token beacon.

None of the three payload shapes could be verified from this sandbox (no egress), so every parser
here is written to be *tolerant*: it looks for fields by a set of plausible names, skips anything it
cannot understand, and records what it skipped. `--strict-universe` turns "understood nothing" into
a hard failure so a silently-changed API cannot produce a quietly empty launch set.

The membership test that is not guesswork is the on-chain one: a Robinhood Stock Token is an
ERC-1967 beacon proxy whose beacon slot holds `0xe10b6f6b275de231345c20d14ab812db62151b00`. When an
RPC is available every candidate is checked against that slot, and `beacon_verified` records the
answer.
"""

from __future__ import annotations

import re
from html.parser import HTMLParser
from typing import Any
from urllib.parse import urlencode

from ..abi import call_data, checksum_address, decode_address, decode_string, decode_uint
from ..chain import (
    BLOCKSCOUT_TOKENS_URL,
    ERC1967_BEACON_SLOT,
    ROBINHOOD_ASSETS_URL,
    ROBINHOOD_DOCS_URL,
    SIG_DECIMALS,
    SIG_NAME,
    SIG_SYMBOL,
    SIG_UI_MULTIPLIER,
    STOCK_TOKEN_BEACON,
    same_address,
)
from ..records import StockToken
from ..transport import TransportError
from .base import Collector, RunContext

ADDRESS_RE = re.compile(r"0x[0-9a-fA-F]{40}")
TICKER_RE = re.compile(r"^[A-Z][A-Z0-9.\-]{0,9}$")

#: Keys a source might use for each field. First hit wins.
_SYMBOL_KEYS = ("symbol", "ticker", "asset_symbol", "token_symbol", "code")
_NAME_KEYS = ("name", "asset_name", "full_name", "display_name", "description")
_ADDRESS_KEYS = (
    "address",
    "contract_address",
    "token_address",
    "erc20_address",
    "contract",
    "address_hash",
)
_DECIMALS_KEYS = ("decimals", "token_decimals", "erc20_decimals")
_NESTED_KEYS = ("contracts", "tokens", "addresses", "deployments", "chains", "networks")
#: Things that are tokenised on 4663 but are not equities.
_NON_EQUITY_HINTS = ("usdg", "usdc", "weth", "wrapped ether", "global dollar")


def _first(item: dict[str, Any], keys: tuple[str, ...]) -> Any:
    for key in keys:
        if key in item and item[key] not in (None, ""):
            return item[key]
    return None


def _as_int(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return int(str(value), 0) if str(value).startswith("0x") else int(value)
    except (TypeError, ValueError):
        return None


def _kind_for(symbol: str, name: str) -> str:
    """Best-effort `equity` / `etf` classification; the registry config needs a `kind`."""
    haystack = f"{symbol} {name}".lower()
    if any(word in haystack for word in ("etf", "trust", "index fund", "spdr", "invesco qqq")):
        return "etf"
    return "equity"


class _TableParser(HTMLParser):
    """Collects every `<table>` as a list of rows of cell text."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.tables: list[list[list[str]]] = []
        self._table: list[list[str]] | None = None
        self._row: list[str] | None = None
        self._cell: list[str] | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        """Open a table / row / cell."""
        if tag == "table":
            self._table = []
        elif tag == "tr" and self._table is not None:
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = []

    def handle_endtag(self, tag: str) -> None:
        """Close a table / row / cell."""
        if tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._row.append(" ".join("".join(self._cell).split()))
            self._cell = None
        elif tag == "tr" and self._row is not None and self._table is not None:
            if self._row:
                self._table.append(self._row)
            self._row = None
        elif tag == "table" and self._table is not None:
            self.tables.append(self._table)
            self._table = None

    def handle_data(self, data: str) -> None:
        """Accumulate cell text."""
        if self._cell is not None:
            self._cell.append(data)


class TokenUniverseCollector(Collector):
    """Merges the three universe sources into one address-keyed set of `StockToken`s."""

    key = "universe"
    hosts = ("api.robinhood.com", "docs.robinhood.com", "robinhoodchain.blockscout.com")

    def __init__(self, *, strict: bool = False) -> None:
        self.strict = strict

    # -- entry point -----------------------------------------------------------------------------

    def collect(self, ctx: RunContext) -> list[StockToken]:
        """Every stock token the run can see, best source first."""
        merged: dict[str, StockToken] = {}
        for source, tokens in (
            ("robinhood-assets", self._from_robinhood(ctx)),
            ("robinhood-docs", self._from_docs(ctx)),
            ("blockscout", self._from_blockscout(ctx)),
        ):
            for token in tokens:
                self._merge(merged, token, source)

        if not merged:
            message = "no stock tokens resolved from any universe source"
            if self.strict:
                raise TransportError(message)
            ctx.warn(message)
            return []

        tokens = sorted(merged.values(), key=lambda t: t.symbol)
        self._enrich_on_chain(ctx, tokens)
        return [t for t in tokens if t.beacon_verified is not False]

    # -- sources ---------------------------------------------------------------------------------

    def _from_robinhood(self, ctx: RunContext) -> list[StockToken]:
        url = ROBINHOOD_ASSETS_URL
        try:
            payload = ctx.transport.get_json(url)
        except TransportError as exc:
            ctx.record(self.key, "robinhood-assets", url, False, note=str(exc))
            ctx.warn(f"issuer registry unavailable ({exc}); falling back to docs and Blockscout")
            return []
        tokens = self._parse_assets(payload)
        ctx.record(self.key, "robinhood-assets", url, True, len(tokens))
        return tokens

    def _parse_assets(self, payload: Any) -> list[StockToken]:
        """Tolerant parse of the issuer registry: list, `results`, or `assets`."""
        items = payload
        if isinstance(payload, dict):
            for key in ("results", "assets", "data", "items", "tokens"):
                if isinstance(payload.get(key), list):
                    items = payload[key]
                    break
        if not isinstance(items, list):
            return []

        out: list[StockToken] = []
        for item in items:
            if not isinstance(item, dict):
                continue
            symbol = str(_first(item, _SYMBOL_KEYS) or "").strip().upper()
            name = str(_first(item, _NAME_KEYS) or "").strip()
            address = _first(item, _ADDRESS_KEYS)
            decimals = _as_int(_first(item, _DECIMALS_KEYS))
            if address is None:
                address, nested_decimals = self._nested_address(item)
                decimals = decimals if decimals is not None else nested_decimals
            if not symbol or not address or not ADDRESS_RE.fullmatch(str(address)):
                continue
            out.append(
                StockToken(
                    symbol=symbol,
                    address=checksum_address(str(address)),
                    name=name,
                    decimals=decimals,
                    kind=_kind_for(symbol, name),
                    sources=("robinhood-assets",),
                )
            )
        return out

    @staticmethod
    def _nested_address(item: dict[str, Any]) -> tuple[str | None, int | None]:
        """Dig one level for a per-chain contract entry."""
        for key in _NESTED_KEYS:
            nested = item.get(key)
            if not isinstance(nested, list):
                continue
            for entry in nested:
                if not isinstance(entry, dict):
                    continue
                chain = _as_int(_first(entry, ("chain_id", "chainId", "chain")))
                address = _first(entry, _ADDRESS_KEYS)
                if address and (chain is None or chain == 4663):
                    return str(address), _as_int(_first(entry, _DECIMALS_KEYS))
        return None, None

    def _from_docs(self, ctx: RunContext) -> list[StockToken]:
        url = ROBINHOOD_DOCS_URL
        try:
            html = ctx.transport.get_text(url)
        except TransportError as exc:
            ctx.record(self.key, "robinhood-docs", url, False, note=str(exc))
            return []
        tokens = self._parse_docs(html)
        ctx.record(self.key, "robinhood-docs", url, True, len(tokens))
        return tokens

    @staticmethod
    def _parse_docs(html: str) -> list[StockToken]:
        """Pull `(symbol, name, address)` out of every table row that has an address in it."""
        parser = _TableParser()
        parser.feed(html)
        out: list[StockToken] = []
        seen: set[str] = set()
        for table in parser.tables:
            for row in table:
                address = next((c for c in row if ADDRESS_RE.fullmatch(c.strip())), None)
                if not address or address.lower() in seen:
                    continue
                cells = [c.strip() for c in row if c.strip() and c.strip() != address]
                symbol = next((c for c in cells if TICKER_RE.fullmatch(c)), "")
                name = next((c for c in cells if c != symbol and len(c) > 2), "")
                if not symbol:
                    continue
                seen.add(address.lower())
                out.append(
                    StockToken(
                        symbol=symbol,
                        address=checksum_address(address.strip()),
                        name=name,
                        kind=_kind_for(symbol, name),
                        sources=("robinhood-docs",),
                    )
                )
        return out

    def _from_blockscout(self, ctx: RunContext) -> list[StockToken]:
        url = BLOCKSCOUT_TOKENS_URL
        out: list[StockToken] = []
        pages = 0
        next_params: dict[str, Any] | None = None
        while pages < ctx.params.max_pages:
            page_url = url if not next_params else f"{url}&{urlencode(next_params)}"
            try:
                payload = ctx.transport.get_json(page_url)
            except TransportError as exc:
                ctx.record(self.key, "blockscout", page_url, False, note=str(exc))
                break
            items = payload.get("items", payload) if isinstance(payload, dict) else payload
            if not isinstance(items, list):
                break
            for item in items:
                token = self._parse_blockscout_item(item)
                if token is not None:
                    out.append(token)
            pages += 1
            next_params = payload.get("next_page_params") if isinstance(payload, dict) else None
            if not next_params:
                break
        ctx.record(self.key, "blockscout", url, bool(out), len(out), f"{pages} page(s)")
        return out

    @staticmethod
    def _parse_blockscout_item(item: Any) -> StockToken | None:
        if not isinstance(item, dict):
            return None
        address = _first(item, _ADDRESS_KEYS)
        if isinstance(address, dict):
            address = _first(address, _ADDRESS_KEYS)
        symbol = str(_first(item, _SYMBOL_KEYS) or "").strip().upper()
        name = str(_first(item, _NAME_KEYS) or "").strip()
        if not address or not ADDRESS_RE.fullmatch(str(address)) or not symbol:
            return None
        if any(hint in f"{symbol} {name}".lower() for hint in _NON_EQUITY_HINTS):
            return None
        return StockToken(
            symbol=symbol,
            address=checksum_address(str(address)),
            name=name,
            decimals=_as_int(_first(item, _DECIMALS_KEYS)),
            kind=_kind_for(symbol, name),
            sources=("blockscout",),
        )

    # -- merge and enrich ------------------------------------------------------------------------

    @staticmethod
    def _merge(merged: dict[str, StockToken], token: StockToken, source: str) -> None:
        """First source to supply a field wins; later sources only fill blanks."""
        existing = merged.get(token.key)
        if existing is None:
            token.sources = (source,)
            merged[token.key] = token
            return
        if source not in existing.sources:
            existing.sources = (*existing.sources, source)
        if not existing.name and token.name:
            existing.name = token.name
        if existing.decimals is None and token.decimals is not None:
            existing.decimals = token.decimals
        if existing.symbol != token.symbol:
            existing.notes.append(f"symbol disagreement: {existing.symbol} vs {token.symbol}@{source}")

    def _enrich_on_chain(self, ctx: RunContext, tokens: list[StockToken]) -> None:
        """Read `decimals()`, `symbol()`, `uiMultiplier()` and the beacon slot for every candidate."""
        rpc = ctx.rpc
        if rpc is None or not tokens:
            for token in tokens:
                token.notes.append("not verified on chain: no RPC in this run")
            return

        calls: list[tuple[str, str]] = []
        for token in tokens:
            calls.append((token.address, call_data(SIG_DECIMALS)))
            calls.append((token.address, call_data(SIG_SYMBOL)))
            calls.append((token.address, call_data(SIG_NAME)))
            calls.append((token.address, call_data(SIG_UI_MULTIPLIER)))
        results = rpc.eth_call_many(calls)

        slots = rpc.batch(
            [("eth_getStorageAt", [t.address, ERC1967_BEACON_SLOT, "latest"]) for t in tokens]
        )
        verified = 0
        for i, token in enumerate(tokens):
            decimals, symbol, name, multiplier = results[4 * i : 4 * i + 4]
            if decimals:
                on_chain = decode_uint(decimals)
                if token.decimals is not None and token.decimals != on_chain:
                    token.notes.append(f"decimals mismatch: source {token.decimals}, chain {on_chain}")
                token.decimals = on_chain
            if symbol:
                chain_symbol = decode_string(symbol).strip().upper()
                if chain_symbol and chain_symbol != token.symbol:
                    token.notes.append(f"symbol mismatch: source {token.symbol}, chain {chain_symbol}")
                    token.symbol = chain_symbol or token.symbol
            if name and not token.name:
                token.name = decode_string(name).strip()
            token.ui_multiplier = _scale_multiplier(multiplier)
            if multiplier is not None and token.ui_multiplier is None:
                token.notes.append("uiMultiplier() returned an unrecognised scale")
            if multiplier is None:
                token.notes.append("uiMultiplier() not readable (reverted or absent)")

            slot = slots[i] if i < len(slots) else None
            if slot:
                beacon = decode_address(slot)
                token.beacon_verified = same_address(beacon, STOCK_TOKEN_BEACON)
                verified += int(bool(token.beacon_verified))
            else:
                token.notes.append("ERC-1967 beacon slot unreadable")
        ctx.record(self.key, "beacon-slot", "eth_getStorageAt", True, verified, "beacon proxies confirmed")


def _scale_multiplier(word: str | None) -> float | None:
    """Interpret `uiMultiplier()`'s raw word.

    The scale is not documented anywhere this package can read, so the three plausible fixed-point
    scales are tried and the one that lands in a sane range (0.001 - 1000) wins. Anything else is
    reported as unrecognised rather than coerced to 1.0 — a wrong multiplier silently changes what
    a share of the token is worth.
    """
    if word is None:
        return None
    raw = decode_uint(word)
    if raw == 0:
        return None
    for scale in (10**18, 10**8, 10**6):
        value = raw / scale
        if 0.001 <= value <= 1000:
            return value
    return None
