# SPDX-License-Identifier: MIT
"""Collector 2 — every pool with a stock token on one side.

Two scans, both over the full chain history rather than the volume window: a pool created before
the window still carries flow inside it, and `Initialize` / `PoolCreated` are rare enough that a
genesis-to-head scan is cheap compared with the swap scan.

* **Uniswap v4** — `Initialize(PoolId indexed id, Currency indexed currency0, Currency indexed
  currency1, uint24 fee, int24 tickSpacing, IHooks hooks, uint160 sqrtPriceX96, int24 tick)` from
  the PoolManager. v4 has no per-pool address, so the `PoolId` in `topics[1]` is the identifier and
  all later reads go through `StateView`.
* **Uniswap v3** — `PoolCreated(address indexed token0, address indexed token1, uint24 indexed fee,
  int24 tickSpacing, address pool)` from the factory.

Pools are kept when *either* currency is a stock token, whatever the counter is; the WETH/stable
pools are kept separately because the ETH price is derived from them.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ..abi import call_data, decode_address, decode_int, decode_string, decode_uint, words
from ..chain import (
    POOL_MANAGER,
    QUOTE_DECIMALS,
    QUOTE_TOKENS,
    SIG_DECIMALS,
    SIG_SYMBOL,
    STABLE_QUOTES,
    V3_FACTORY,
    V3_POOL_CREATED_TOPIC,
    V4_INITIALIZE_TOPIC,
)
from ..records import Pool, StockToken
from ..rpc import RpcError
from .base import Collector, RunContext

#: v4's dynamic-fee flag; a pool carrying it prices per swap, so its "tier" is meaningless.
DYNAMIC_FEE_FLAG = 0x800000


@dataclass
class PoolSet:
    """Discovered pools, indexed the three ways the pipeline needs them."""

    by_token: dict[str, list[Pool]] = field(default_factory=dict)
    all_pools: list[Pool] = field(default_factory=list)
    #: WETH quoted in a stable — the bridge that prices WETH-quoted stock pools.
    weth_quote_pools: list[Pool] = field(default_factory=list)
    counter_symbols: dict[str, str] = field(default_factory=dict)
    counter_decimals: dict[str, int] = field(default_factory=dict)

    def add(self, pool: Pool) -> None:
        """Index one pool under its stock token."""
        self.all_pools.append(pool)
        self.by_token.setdefault(pool.token.lower(), []).append(pool)


class PoolCollector(Collector):
    """Uniswap v4 + v3 pool discovery over JSON-RPC."""

    key = "pools"
    hosts = ("rpc.mainnet.chain.robinhood.com", "robinhood-rpc.publicnode.com")

    def collect(self, ctx: RunContext) -> PoolSet:
        """Discover pools for the universe already in `ctx.extra_universe`."""
        raise NotImplementedError("use collect_for(ctx, tokens)")

    def collect_for(self, ctx: RunContext, tokens: list[StockToken]) -> PoolSet:
        """Every v4 and v3 pool touching one of `tokens`, plus the WETH/stable reference pools."""
        result = PoolSet()
        if ctx.rpc is None:
            ctx.record(self.key, "rpc", "eth_getLogs", False, note="no RPC configured")
            return result

        known: dict[str, StockToken] = {t.key: t for t in tokens}
        for address, symbol in QUOTE_TOKENS.items():
            result.counter_symbols[address] = symbol
            result.counter_decimals[address] = QUOTE_DECIMALS[symbol]
        for token in tokens:
            if token.decimals is not None:
                result.counter_decimals[token.key] = token.decimals
            result.counter_symbols.setdefault(token.key, token.symbol)

        self._scan_v4(ctx, known, result)
        self._scan_v3(ctx, known, result)
        self._resolve_unknown_counters(ctx, result)
        return result

    # -- v4 --------------------------------------------------------------------------------------

    def _scan_v4(self, ctx: RunContext, known: dict[str, StockToken], result: PoolSet) -> None:
        rpc = ctx.rpc
        assert rpc is not None
        try:
            logs = rpc.get_logs(
                from_block=ctx.params.pools_from_block,
                to_block=ctx.head_block,
                address=POOL_MANAGER,
                topics=[V4_INITIALIZE_TOPIC],
                chunk=ctx.params.discovery_chunk_blocks,
            )
        except RpcError as exc:
            ctx.record(self.key, "v4-initialize", POOL_MANAGER, False, note=str(exc))
            ctx.warn(f"v4 pool discovery failed: {exc}")
            return

        kept = 0
        for log in logs:
            pool = self._parse_initialize(log, known, result)
            if pool is None:
                continue
            result.add(pool)
            kept += 1
        self._collect_weth_quotes(logs, result, self._parse_initialize_raw)
        ctx.record(self.key, "v4-initialize", POOL_MANAGER, True, kept, f"{len(logs)} Initialize logs")

    @staticmethod
    def _parse_initialize_raw(log: dict[str, Any]) -> tuple[str, str, str, dict[str, Any]] | None:
        topics = log.get("topics") or []
        if len(topics) < 4:
            return None
        pool_id = str(topics[1])
        currency0 = decode_address(str(topics[2]))
        currency1 = decode_address(str(topics[3]))
        data = words(str(log.get("data", "0x")))
        if len(data) < 5:
            return None
        fee = decode_uint(data[0])
        extra = {
            "fee": fee,
            "tickSpacing": decode_int(data[1], 24),
            "hooks": decode_address(data[2]),
            "sqrtPriceX96": decode_uint(data[3]),
            "block": int(str(log.get("blockNumber", "0x0")), 16),
        }
        return pool_id, currency0, currency1, extra

    def _parse_initialize(
        self, log: dict[str, Any], known: dict[str, StockToken], result: PoolSet
    ) -> Pool | None:
        parsed = self._parse_initialize_raw(log)
        if parsed is None:
            return None
        pool_id, currency0, currency1, extra = parsed
        token, counter, token_is_0 = _orient(currency0, currency1, known)
        if token is None or counter is None:
            return None
        dynamic = bool(extra["fee"] & DYNAMIC_FEE_FLAG)
        return Pool(
            protocol="v4",
            identifier=pool_id,
            token=token,
            counter=counter,
            counter_symbol=result.counter_symbols.get(counter.lower(), counter[:10]),
            fee_bps=None if dynamic else extra["fee"] / 100.0,
            dynamic_fee=dynamic,
            tick_spacing=extra["tickSpacing"],
            hooks=extra["hooks"],
            token_is_currency0=token_is_0,
            created_block=extra["block"],
            init_sqrt_price_x96=extra["sqrtPriceX96"],
        )

    # -- v3 --------------------------------------------------------------------------------------

    def _scan_v3(self, ctx: RunContext, known: dict[str, StockToken], result: PoolSet) -> None:
        rpc = ctx.rpc
        assert rpc is not None
        try:
            logs = rpc.get_logs(
                from_block=ctx.params.pools_from_block,
                to_block=ctx.head_block,
                address=V3_FACTORY,
                topics=[V3_POOL_CREATED_TOPIC],
                chunk=ctx.params.discovery_chunk_blocks,
            )
        except RpcError as exc:
            ctx.record(self.key, "v3-poolcreated", V3_FACTORY, False, note=str(exc))
            ctx.warn(f"v3 pool discovery failed: {exc}")
            return

        kept = 0
        for log in logs:
            pool = self._parse_pool_created(log, known, result)
            if pool is None:
                continue
            result.add(pool)
            kept += 1
        self._collect_weth_quotes(logs, result, self._parse_pool_created_raw)
        ctx.record(self.key, "v3-poolcreated", V3_FACTORY, True, kept, f"{len(logs)} PoolCreated logs")

    @staticmethod
    def _parse_pool_created_raw(log: dict[str, Any]) -> tuple[str, str, str, dict[str, Any]] | None:
        topics = log.get("topics") or []
        if len(topics) < 4:
            return None
        token0 = decode_address(str(topics[1]))
        token1 = decode_address(str(topics[2]))
        fee = decode_uint(str(topics[3]))
        data = words(str(log.get("data", "0x")))
        if len(data) < 2:
            return None
        extra = {
            "fee": fee,
            "tickSpacing": decode_int(data[0], 24),
            "pool": decode_address(data[1]),
            "block": int(str(log.get("blockNumber", "0x0")), 16),
        }
        return extra["pool"], token0, token1, extra

    def _parse_pool_created(
        self, log: dict[str, Any], known: dict[str, StockToken], result: PoolSet
    ) -> Pool | None:
        parsed = self._parse_pool_created_raw(log)
        if parsed is None:
            return None
        address, token0, token1, extra = parsed
        token, counter, token_is_0 = _orient(token0, token1, known)
        if token is None or counter is None:
            return None
        return Pool(
            protocol="v3",
            identifier=address,
            token=token,
            counter=counter,
            counter_symbol=result.counter_symbols.get(counter.lower(), counter[:10]),
            fee_bps=extra["fee"] / 100.0,
            tick_spacing=extra["tickSpacing"],
            token_is_currency0=token_is_0,
            created_block=extra["block"],
        )

    # -- shared ----------------------------------------------------------------------------------

    @staticmethod
    def _collect_weth_quotes(logs: list[dict[str, Any]], result: PoolSet, parser: Any) -> None:
        """Keep WETH/stable pools: they are how a WETH-quoted stock pool gets a USD price."""
        for log in logs:
            parsed = parser(log)
            if parsed is None:
                continue
            identifier, side0, side1, extra = parsed
            symbols = {
                QUOTE_TOKENS.get(side0.lower(), ""),
                QUOTE_TOKENS.get(side1.lower(), ""),
            }
            if "WETH" not in symbols or not (symbols & STABLE_QUOTES):
                continue
            weth_is_0 = QUOTE_TOKENS.get(side0.lower()) == "WETH"
            counter = side1 if weth_is_0 else side0
            result.weth_quote_pools.append(
                Pool(
                    protocol="v4" if "sqrtPriceX96" in extra else "v3",
                    identifier=identifier,
                    token=side0 if weth_is_0 else side1,
                    counter=counter,
                    counter_symbol=QUOTE_TOKENS.get(counter.lower(), "?"),
                    fee_bps=None if extra["fee"] & DYNAMIC_FEE_FLAG else extra["fee"] / 100.0,
                    dynamic_fee=bool(extra["fee"] & DYNAMIC_FEE_FLAG),
                    tick_spacing=extra["tickSpacing"],
                    token_is_currency0=weth_is_0,
                    created_block=extra["block"],
                    init_sqrt_price_x96=extra.get("sqrtPriceX96"),
                )
            )

    def _resolve_unknown_counters(self, ctx: RunContext, result: PoolSet) -> None:
        """`symbol()`/`decimals()` for counters that are neither a stock token nor a known quote."""
        rpc = ctx.rpc
        unknown = sorted(
            {
                p.counter.lower()
                for p in result.all_pools
                if p.counter.lower() not in result.counter_decimals
            }
        )
        if not unknown or rpc is None:
            return
        calls: list[tuple[str, str]] = []
        for address in unknown:
            calls.append((address, call_data(SIG_SYMBOL)))
            calls.append((address, call_data(SIG_DECIMALS)))
        answers = rpc.eth_call_many(calls)
        for i, address in enumerate(unknown):
            symbol, decimals = answers[2 * i : 2 * i + 2]
            if symbol:
                result.counter_symbols[address] = decode_string(symbol).strip() or address[:10]
            if decimals:
                result.counter_decimals[address] = decode_uint(decimals)
        for pool in result.all_pools:
            pool.counter_symbol = result.counter_symbols.get(pool.counter.lower(), pool.counter_symbol)
        ctx.record(self.key, "counter-metadata", "eth_call", True, len(unknown), "unknown counters")


def _orient(side0: str, side1: str, known: dict[str, StockToken]) -> tuple[str | None, str | None, bool]:
    """Return `(stock_token, counter, token_is_currency0)`, or `(None, None, ...)` if neither side is one.

    A stock/stock pool is attributed to `currency0` and noted; both names still see the flow, but
    counting it twice would double-count chain volume.
    """
    zero_known = side0.lower() in known
    one_known = side1.lower() in known
    if zero_known:
        return side0, side1, True
    if one_known:
        return side1, side0, False
    return None, None, True
