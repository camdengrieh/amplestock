# SPDX-License-Identifier: MIT
"""Collector 3 — volume, price and depth, read from the chain.

Chain data is authoritative here; the API collector only gets to disagree in a footnote.

**Volume** is the sum of the *quote* leg of every `Swap` in the window, priced in USD: the stable
leg at `--usdg-usd` (default $1.00) or the WETH leg at the WETH/stable pool price. Counting only the
quote leg is what every venue means by "volume" and avoids double-counting a swap.

**Price** comes from `sqrtPriceX96` on the swap, not from the amounts: the post-swap pool price is
unaffected by the fee and by how much of the trade was slippage.

**Depth** is a state read, not an event read: `StateView.getSlot0`/`getLiquidity` for v4 and
`slot0()`/`liquidity()` for v3, put through the +/-2% band formula in `pricing.py`. It is therefore
a snapshot at head, while volume is a window — the report says so, because a pool whose LP pulled
out yesterday will look better on this measure than it deserves.

**Timestamps.** `eth_getLogs` does not return block timestamps and a 30-day window on a 100 ms chain
holds ~26 M blocks, so per-log `eth_getBlockByNumber` is not an option. Block numbers are mapped to
time by linear interpolation between the two window anchors, whose timestamps *were* read exactly
(binary search in `rpc.block_at_timestamp`). The error is bounded by the chain's block-time drift
across the window and only ever affects which UTC day a price sample lands in.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from ..abi import call_data, decode_int, decode_uint, words
from ..chain import (
    POOL_MANAGER,
    SIG_STATE_VIEW_GET_LIQUIDITY,
    SIG_STATE_VIEW_GET_SLOT0,
    SIG_V3_LIQUIDITY,
    SIG_V3_SLOT0,
    STABLE_QUOTES,
    STATE_VIEW,
    V3_SWAP_TOPIC,
    V4_SWAP_TOPIC,
)
from ..pricing import depth_usd_within_band, price_from_sqrt_x96
from ..records import Pool, PoolMarket, StockToken
from ..rpc import RpcError
from .base import Collector, RunContext
from .pools import DYNAMIC_FEE_FLAG, PoolSet

#: How many pool ids / addresses go into one `eth_getLogs` filter.
TOPIC_BATCH = 50


@dataclass
class _Swap:
    """One decoded swap, in raw token units."""

    pool_key: str
    block: int
    amount0: int
    amount1: int
    sqrt_price_x96: int
    liquidity: int
    fee_bps: float | None


class BlockClock:
    """Linear block -> timestamp map anchored on two exactly-known blocks."""

    def __init__(self, from_block: int, from_ts: int, head_block: int, head_ts: int) -> None:
        self.from_block = from_block
        self.from_ts = from_ts
        self.head_block = head_block
        self.head_ts = head_ts
        span = max(1, head_block - from_block)
        self.seconds_per_block = (head_ts - from_ts) / span

    def ts(self, block: int) -> int:
        """Interpolated timestamp for `block`."""
        return int(self.from_ts + (block - self.from_block) * self.seconds_per_block)


class MarketCollector(Collector):
    """Swap-event volume and state-read depth for every discovered pool."""

    key = "market"
    hosts = ("rpc.mainnet.chain.robinhood.com", "robinhood-rpc.publicnode.com")

    def collect(self, ctx: RunContext) -> Any:
        """Unused: the market collector needs the pool set, see `collect_for`."""
        raise NotImplementedError("use collect_for(ctx, pool_set, tokens)")

    def collect_for(
        self, ctx: RunContext, pool_set: PoolSet, tokens: dict[str, StockToken]
    ) -> dict[str, list[PoolMarket]]:
        """`token address -> markets`, one market per pool."""
        if ctx.rpc is None or not pool_set.all_pools:
            return {}

        clock = BlockClock(ctx.window_from_block, ctx.now_ts - ctx.window_seconds, ctx.head_block, ctx.now_ts)
        state = self._read_state(ctx, pool_set)
        weth_usd = self._weth_price(ctx, pool_set, state)
        swaps = self._read_swaps(ctx, pool_set)

        markets: dict[str, PoolMarket] = {p.identifier.lower(): PoolMarket(pool=p) for p in pool_set.all_pools}
        prices: dict[str, float] = {}

        # Pass 1: pools quoted in a stable or in WETH can be priced immediately.
        for pool in pool_set.all_pools:
            counter_usd = self._counter_price(ctx, pool, pool_set, weth_usd, prices)
            if counter_usd is None:
                continue
            self._fill_market(
                ctx, markets[pool.identifier.lower()], pool, pool_set, swaps, state, clock, counter_usd
            )
            price = markets[pool.identifier.lower()].price_usd
            if price and pool.token.lower() not in prices:
                prices[pool.token.lower()] = price

        # Pass 2: stock/stock pools, now that most stock tokens have a price.
        for pool in pool_set.all_pools:
            market = markets[pool.identifier.lower()]
            if market.price_usd is not None or market.notes:
                continue
            counter_usd = self._counter_price(ctx, pool, pool_set, weth_usd, prices)
            if counter_usd is None:
                market.notes.append(f"counter {pool.counter_symbol} could not be priced in USD")
                ctx.warn(f"{pool.counter_symbol} pools left unpriced: no USD route")
                continue
            self._fill_market(ctx, market, pool, pool_set, swaps, state, clock, counter_usd)

        out: dict[str, list[PoolMarket]] = {}
        for pool in pool_set.all_pools:
            out.setdefault(pool.token.lower(), []).append(markets[pool.identifier.lower()])
        ctx.record(self.key, "swaps", "eth_getLogs", True, sum(len(v) for v in swaps.values()), "swap logs")
        return out

    # -- swap events -----------------------------------------------------------------------------

    def _read_swaps(self, ctx: RunContext, pool_set: PoolSet) -> dict[str, list[_Swap]]:
        rpc = ctx.rpc
        assert rpc is not None
        out: dict[str, list[_Swap]] = {}

        v4_ids = [p.identifier for p in pool_set.all_pools if p.protocol == "v4"]
        v4_ids += [p.identifier for p in pool_set.weth_quote_pools if p.protocol == "v4"]
        for group in _chunks(sorted(set(v4_ids)), TOPIC_BATCH):
            try:
                logs = rpc.get_logs(
                    from_block=ctx.window_from_block,
                    to_block=ctx.head_block,
                    address=POOL_MANAGER,
                    topics=[V4_SWAP_TOPIC, list(group)],
                    chunk=ctx.params.chunk_blocks,
                )
            except RpcError as exc:
                ctx.record(self.key, "v4-swap", POOL_MANAGER, False, note=str(exc))
                ctx.warn(f"v4 swap scan failed: {exc}")
                continue
            for log in logs:
                swap = self._parse_v4_swap(log)
                if swap is not None:
                    out.setdefault(swap.pool_key, []).append(swap)

        v3_addresses = [p.identifier for p in pool_set.all_pools if p.protocol == "v3"]
        v3_addresses += [p.identifier for p in pool_set.weth_quote_pools if p.protocol == "v3"]
        for group in _chunks(sorted({a.lower() for a in v3_addresses}), TOPIC_BATCH):
            try:
                logs = rpc.get_logs(
                    from_block=ctx.window_from_block,
                    to_block=ctx.head_block,
                    address=list(group),
                    topics=[V3_SWAP_TOPIC],
                    chunk=ctx.params.chunk_blocks,
                )
            except RpcError as exc:
                ctx.record(self.key, "v3-swap", "v3 pools", False, note=str(exc))
                ctx.warn(f"v3 swap scan failed: {exc}")
                continue
            for log in logs:
                swap = self._parse_v3_swap(log)
                if swap is not None:
                    out.setdefault(swap.pool_key, []).append(swap)

        for swaps in out.values():
            swaps.sort(key=lambda s: s.block)
        return out

    @staticmethod
    def _parse_v4_swap(log: dict[str, Any]) -> _Swap | None:
        topics = log.get("topics") or []
        data = words(str(log.get("data", "0x")))
        if len(topics) < 2 or len(data) < 6:
            return None
        fee = decode_uint(data[5])
        return _Swap(
            pool_key=str(topics[1]).lower(),
            block=int(str(log.get("blockNumber", "0x0")), 16),
            amount0=decode_int(data[0], 128),
            amount1=decode_int(data[1], 128),
            sqrt_price_x96=decode_uint(data[2]),
            liquidity=decode_uint(data[3]),
            fee_bps=None if fee & DYNAMIC_FEE_FLAG else fee / 100.0,
        )

    @staticmethod
    def _parse_v3_swap(log: dict[str, Any]) -> _Swap | None:
        data = words(str(log.get("data", "0x")))
        if len(data) < 5:
            return None
        return _Swap(
            pool_key=str(log.get("address", "")).lower(),
            block=int(str(log.get("blockNumber", "0x0")), 16),
            amount0=decode_int(data[0], 256),
            amount1=decode_int(data[1], 256),
            sqrt_price_x96=decode_uint(data[2]),
            liquidity=decode_uint(data[3]),
            fee_bps=None,
        )

    # -- state reads -----------------------------------------------------------------------------

    def _read_state(self, ctx: RunContext, pool_set: PoolSet) -> dict[str, tuple[int, int]]:
        """`pool key -> (sqrtPriceX96, liquidity)` at head."""
        rpc = ctx.rpc
        assert rpc is not None
        pools = list(pool_set.all_pools) + list(pool_set.weth_quote_pools)
        calls: list[tuple[str, str]] = []
        keys: list[str] = []
        for pool in pools:
            keys.append(pool.identifier.lower())
            if pool.protocol == "v4":
                calls.append((STATE_VIEW, call_data(SIG_STATE_VIEW_GET_SLOT0, pool.identifier)))
                calls.append((STATE_VIEW, call_data(SIG_STATE_VIEW_GET_LIQUIDITY, pool.identifier)))
            else:
                calls.append((pool.identifier, call_data(SIG_V3_SLOT0)))
                calls.append((pool.identifier, call_data(SIG_V3_LIQUIDITY)))
        answers = rpc.eth_call_many(calls)

        state: dict[str, tuple[int, int]] = {}
        misses = 0
        for i, key in enumerate(keys):
            slot0, liquidity = answers[2 * i : 2 * i + 2]
            if slot0 is None or liquidity is None:
                misses += 1
                continue
            slot_words = words(slot0)
            if not slot_words:
                misses += 1
                continue
            state[key] = (decode_uint(slot_words[0]), decode_uint(liquidity))
        ctx.record(self.key, "pool-state", STATE_VIEW, True, len(state), f"{misses} unreadable")
        return state

    def _weth_price(self, ctx: RunContext, pool_set: PoolSet, state: dict[str, tuple[int, int]]) -> float | None:
        """USD price of WETH, from the deepest WETH/stable pool at head."""
        best: tuple[float, float] | None = None
        for pool in pool_set.weth_quote_pools:
            entry = state.get(pool.identifier.lower())
            if entry is None:
                continue
            sqrt_price, liquidity = entry
            stable_usd = ctx.params.usdg_usd if pool.counter_symbol == "USDG" else 1.0
            weth_dec, stable_dec = 18, pool_set.counter_decimals.get(pool.counter.lower(), 6)
            dec0, dec1 = (weth_dec, stable_dec) if pool.token_is_currency0 else (stable_dec, weth_dec)
            price0 = price_from_sqrt_x96(sqrt_price, dec0, dec1)
            if price0 <= 0:
                continue
            weth_in_stable = price0 if pool.token_is_currency0 else 1.0 / price0
            candidate = weth_in_stable * stable_usd
            if best is None or liquidity > best[1]:
                best = (candidate, float(liquidity))
        if best is None:
            ctx.warn("no WETH/stable pool readable: WETH-quoted pools cannot be priced in USD")
            ctx.record(self.key, "weth-price", "state", False, note="no readable WETH/stable pool")
            return None
        ctx.record(self.key, "weth-price", "state", True, 1, f"WETH = ${best[0]:,.2f}")
        return best[0]

    # -- per-pool assembly -----------------------------------------------------------------------

    def _counter_price(
        self,
        ctx: RunContext,
        pool: Pool,
        pool_set: PoolSet,
        weth_usd: float | None,
        prices: dict[str, float],
    ) -> float | None:
        symbol = pool_set.counter_symbols.get(pool.counter.lower(), pool.counter_symbol)
        if symbol in STABLE_QUOTES:
            return ctx.params.usdg_usd if symbol == "USDG" else 1.0
        if symbol == "WETH":
            return weth_usd
        return prices.get(pool.counter.lower())

    def _fill_market(
        self,
        ctx: RunContext,
        market: PoolMarket,
        pool: Pool,
        pool_set: PoolSet,
        swaps: dict[str, list[_Swap]],
        state: dict[str, tuple[int, int]],
        clock: BlockClock,
        counter_usd: float,
    ) -> None:
        """Fill one `PoolMarket` from its swaps and its head state."""
        token_dec = pool_set.counter_decimals.get(pool.token.lower())
        counter_dec = pool_set.counter_decimals.get(pool.counter.lower())
        if token_dec is None or counter_dec is None:
            market.notes.append("decimals unknown for one side; pool skipped")
            return
        dec0, dec1 = (token_dec, counter_dec) if pool.token_is_currency0 else (counter_dec, token_dec)

        pool_swaps = swaps.get(pool.identifier.lower(), [])
        fee_weighted = 0.0
        fee_volume = 0.0
        for swap in pool_swaps:
            quote_raw = swap.amount1 if pool.token_is_currency0 else swap.amount0
            volume = abs(quote_raw) / (10**counter_dec) * counter_usd
            market.volume_usd_30d += volume
            market.swaps_30d += 1
            if swap.block >= ctx.short_from_block:
                market.volume_usd_7d += volume
                market.swaps_7d += 1
            price0 = price_from_sqrt_x96(swap.sqrt_price_x96, dec0, dec1)
            if price0 > 0:
                token_in_counter = price0 if pool.token_is_currency0 else 1.0 / price0
                market.daily_prices.append((clock.ts(swap.block), token_in_counter * counter_usd))
            fee = swap.fee_bps if swap.fee_bps is not None else pool.fee_bps
            if fee is not None and volume > 0:
                fee_weighted += fee * volume
                fee_volume += volume
        if pool_swaps:
            market.first_swap_ts = clock.ts(pool_swaps[0].block)
        market.effective_fee_bps = (fee_weighted / fee_volume) if fee_volume > 0 else pool.fee_bps

        entry = state.get(pool.identifier.lower())
        if entry is None:
            market.notes.append("pool state unreadable at head; depth unknown")
            if market.daily_prices:
                market.price_usd = market.daily_prices[-1][1]
            return
        sqrt_price, liquidity = entry
        market.sqrt_price_x96 = sqrt_price
        market.liquidity = liquidity
        price0 = price_from_sqrt_x96(sqrt_price, dec0, dec1)
        if price0 > 0:
            token_in_counter = price0 if pool.token_is_currency0 else 1.0 / price0
            market.price_usd = token_in_counter * counter_usd
        elif market.daily_prices:
            market.price_usd = market.daily_prices[-1][1]

        price0_usd = market.price_usd if pool.token_is_currency0 else counter_usd
        price1_usd = counter_usd if pool.token_is_currency0 else market.price_usd
        market.depth_usd_2pct = depth_usd_within_band(
            liquidity=liquidity,
            sqrt_price_x96=sqrt_price,
            decimals0=dec0,
            decimals1=dec1,
            price0_usd=price0_usd,
            price1_usd=price1_usd,
        )


def _chunks(items: list[str], size: int) -> list[list[str]]:
    """Split `items` into lists of at most `size`."""
    return [items[i : i + size] for i in range(0, len(items), size)] or []
