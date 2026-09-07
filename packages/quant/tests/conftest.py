# SPDX-License-Identifier: MIT
"""Shared fixtures. No test in this package touches the network."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from amplestocks_quant.constituents.collectors.base import RunContext
from amplestocks_quant.constituents.config import RunParams
from amplestocks_quant.constituents.pipeline import DEFAULT_CASSETTE
from amplestocks_quant.constituents.records import (
    Pool,
    PoolMarket,
    StockToken,
)
from amplestocks_quant.constituents.rpc import JsonRpc
from amplestocks_quant.constituents.transport import FixtureTransport


@pytest.fixture(scope="session")
def cassette_path() -> Path:
    """The synthetic cassette shipped with the package."""
    return DEFAULT_CASSETTE


@pytest.fixture(scope="session")
def cassette(cassette_path: Path) -> dict:
    """The cassette as data."""
    return json.loads(cassette_path.read_text())


@pytest.fixture
def transport(cassette_path: Path) -> FixtureTransport:
    """A fresh fixture transport."""
    return FixtureTransport.from_path(cassette_path)


@pytest.fixture
def params() -> RunParams:
    """Default run parameters in fixture mode."""
    return RunParams(fixtures=True, count=12)


@pytest.fixture
def context(transport: FixtureTransport, params: RunParams) -> RunContext:
    """A context wired to the cassette, with the window already resolved."""
    rpc = JsonRpc(transport=transport, endpoints=("https://fixture.invalid",))
    head = rpc.block_number()
    head_ts = rpc.block_timestamp(head)
    return RunContext(
        transport=transport,
        params=params,
        rpc=rpc,
        now_ts=head_ts,
        head_block=head,
        window_from_block=rpc.block_at_timestamp(head_ts - 30 * 86_400, head=head),
        short_from_block=rpc.block_at_timestamp(head_ts - 7 * 86_400, head=head),
    )


def make_token(symbol: str, address: str | None = None, **kwargs) -> StockToken:
    """A `StockToken` with sane defaults, for model-level tests."""
    return StockToken(
        symbol=symbol,
        address=address or ("0x" + symbol.encode().hex().ljust(40, "0")[:40]),
        name=f"{symbol} Inc.",
        decimals=18,
        ui_multiplier=kwargs.pop("ui_multiplier", 1.0),
        beacon_verified=kwargs.pop("beacon_verified", True),
        **kwargs,
    )


def make_market(token: StockToken, *, volume7: float, volume30: float, depth: float,
                price: float = 100.0, fee_bps: float = 30.0, protocol: str = "v4",
                tick_spacing: int = 60) -> PoolMarket:
    """A `PoolMarket` with the aggregate figures a model test needs."""
    pool = Pool(
        protocol=protocol,
        identifier="0x" + token.symbol.encode().hex().ljust(64, "0")[:64],
        token=token.address,
        counter="0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
        counter_symbol="USDG",
        fee_bps=fee_bps,
        tick_spacing=tick_spacing,
    )
    return PoolMarket(
        pool=pool,
        volume_usd_7d=volume7,
        volume_usd_30d=volume30,
        depth_usd_2pct=depth,
        price_usd=price,
        effective_fee_bps=fee_bps,
        swaps_7d=10,
        swaps_30d=40,
    )
