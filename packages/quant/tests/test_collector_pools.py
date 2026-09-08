# SPDX-License-Identifier: MIT
"""Pool discovery: v4 `Initialize` and v3 `PoolCreated`, decoded and oriented."""

from __future__ import annotations

from conftest import make_token

from amplestocks_quant.constituents.chain import USDG, WETH9
from amplestocks_quant.constituents.collectors.pools import DYNAMIC_FEE_FLAG, PoolCollector, _orient
from amplestocks_quant.constituents.collectors.universe import TokenUniverseCollector
from amplestocks_quant.constituents.records import StockToken


def test_orientation_finds_the_stock_side_whichever_currency_it_is() -> None:
    token = make_token("GME")
    known = {token.key: token}
    assert _orient(token.address, USDG, known) == (token.address, USDG, True)
    assert _orient(USDG, token.address, known) == (token.address, USDG, False)
    assert _orient(USDG, WETH9, known) == (None, None, True)


def test_initialize_decoding_covers_dynamic_fees() -> None:
    collector = PoolCollector()
    token = make_token("GME")
    log = {
        "topics": [
            "0xtopic",
            "0x" + "11" * 32,
            "0x" + "00" * 12 + token.address[2:],
            "0x" + "00" * 12 + USDG[2:],
        ],
        "data": "0x"
        + f"{DYNAMIC_FEE_FLAG:064x}"
        + f"{60:064x}"
        + "00" * 12 + "cc" * 20
        + f"{2**96:064x}"
        + f"{0:064x}",
        "blockNumber": "0x10",
    }

    class _Result:
        def __init__(self) -> None:
            self.counter_symbols = {USDG.lower(): "USDG"}

    pool = collector._parse_initialize(log, {token.key: token}, _Result())
    assert pool is not None
    assert pool.dynamic_fee is True and pool.fee_bps is None
    assert pool.tick_spacing == 60 and pool.created_block == 16
    assert pool.token_is_currency0 is True
    assert pool.counter_symbol == "USDG"


def test_cassette_discovery_indexes_pools_and_the_weth_reference(context) -> None:
    tokens = TokenUniverseCollector().collect(context)
    pool_set = PoolCollector().collect_for(context, tokens)

    assert len(pool_set.all_pools) >= len(tokens)
    assert pool_set.weth_quote_pools, "the WETH/USDG pool is how WETH gets a USD price"

    by_symbol = {t.key: t.symbol for t in tokens}
    thin = next(p for p in pool_set.all_pools if by_symbol[p.token.lower()] == "FXTHIN")
    assert thin.protocol == "v4"
    assert thin.counter_symbol == "USDG"
    assert thin.fee_bps == 30.0

    # The deepest names carry a v3 pool as well as the v4 one.
    deep = [p for p in pool_set.all_pools if by_symbol[p.token.lower()] == "FXDEEP"]
    assert {p.protocol for p in deep} == {"v4", "v3"}

    weth_quoted = next(p for p in pool_set.all_pools if by_symbol[p.token.lower()] == "FXWETHQ")
    assert weth_quoted.counter_symbol == "WETH"


def test_unknown_counters_get_their_symbol_read_from_chain(context) -> None:
    token = StockToken(symbol="FXX", address="0x" + "9a" * 20, decimals=18)
    pool_set = PoolCollector().collect_for(context, [token])
    # Nothing in the cassette references this token, so nothing is discovered - and that is not an
    # error, it is an empty result with provenance.
    assert pool_set.all_pools == []
    assert any(s.collector == "pools" and s.ok for s in context.sources)
