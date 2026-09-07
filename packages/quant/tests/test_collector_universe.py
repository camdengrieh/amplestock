# SPDX-License-Identifier: MIT
"""The universe collector: three sources, one merged set.

None of the three payload shapes could be verified from the sandbox that wrote this package, so
what is tested here is the *tolerance*: two plausible shapes of the issuer registry, a docs table
with extra columns, a paginated Blockscout response, and the on-chain beacon check that is the only
membership test that is not a guess.
"""

from __future__ import annotations

import pytest

from amplestocks_quant.constituents.chain import (
    BLOCKSCOUT_TOKENS_URL,
    ROBINHOOD_ASSETS_URL,
    ROBINHOOD_DOCS_URL,
)
from amplestocks_quant.constituents.collectors.universe import (
    TokenUniverseCollector,
    _scale_multiplier,
)
from amplestocks_quant.constituents.transport import FixtureTransport, TransportError

TOKEN_A = "0x" + "a1" * 20
TOKEN_B = "0x" + "b2" * 20


def test_parses_a_flat_issuer_payload() -> None:
    tokens = TokenUniverseCollector()._parse_assets(
        {"results": [{"symbol": "aapl", "name": "Apple Inc.", "address": TOKEN_A, "decimals": 18}]}
    )
    assert [(t.symbol, t.decimals) for t in tokens] == [("AAPL", 18)]
    assert tokens[0].address.lower() == TOKEN_A


def test_parses_a_nested_per_chain_issuer_payload() -> None:
    tokens = TokenUniverseCollector()._parse_assets(
        [
            {
                "ticker": "SPY",
                "asset_name": "SPDR S&P 500 ETF Trust",
                "contracts": [
                    {"chain_id": 1, "address": "0x" + "11" * 20},
                    {"chain_id": 4663, "address": TOKEN_B, "decimals": 8},
                ],
            }
        ]
    )
    assert len(tokens) == 1
    assert tokens[0].address.lower() == TOKEN_B
    assert tokens[0].decimals == 8
    assert tokens[0].kind == "etf", "an ETF should not be classified as an equity"


def test_skips_entries_it_cannot_understand_instead_of_guessing() -> None:
    tokens = TokenUniverseCollector()._parse_assets(
        {"results": [{"symbol": "NOADDR"}, {"address": TOKEN_A}, "junk", {"symbol": "BAD", "address": "0x12"}]}
    )
    assert tokens == []


def test_parses_the_docs_html_table() -> None:
    html = f"""
    <h1>Contracts</h1>
    <table>
      <tr><th>Symbol</th><th>Company</th><th>Address</th><th>Decimals</th></tr>
      <tr><td>TSLA</td><td>Tesla, Inc.</td><td>{TOKEN_A}</td><td>18</td></tr>
      <tr><td colspan=4>no address here</td></tr>
    </table>
    """
    tokens = TokenUniverseCollector()._parse_docs(html)
    assert [(t.symbol, t.name) for t in tokens] == [("TSLA", "Tesla, Inc.")]


def test_blockscout_items_drop_non_equity_assets() -> None:
    collector = TokenUniverseCollector()
    assert collector._parse_blockscout_item(
        {"address": TOKEN_A, "symbol": "USDG", "name": "Global Dollar", "decimals": "6"}
    ) is None
    token = collector._parse_blockscout_item(
        {"address_hash": TOKEN_B, "symbol": "GME", "name": "GameStop Corp.", "decimals": "18"}
    )
    assert token is not None and token.decimals == 18


def test_multiplier_scaling_tries_the_plausible_fixed_points() -> None:
    assert _scale_multiplier("0x" + f"{4 * 10**18:064x}") == 4.0
    assert _scale_multiplier("0x" + f"{10**8:064x}") == 1.0
    assert _scale_multiplier(None) is None
    assert _scale_multiplier("0x" + "00" * 32) is None, "zero is not a multiplier of 1"
    assert _scale_multiplier("0x" + f"{10**40:064x}") is None, "an unrecognised scale is not coerced"


def test_end_to_end_against_the_cassette(context) -> None:
    tokens = TokenUniverseCollector().collect(context)
    symbols = {t.symbol for t in tokens}
    assert "FXTHIN" in symbols
    assert "FXQUIET" in symbols, "a token only Blockscout knows about must still be found"
    assert not any(s.startswith(("FXLP", "FXGOV")) for s in symbols), (
        "decoy ERC-20s whose beacon slot is empty are not stock tokens"
    )
    assert all(t.beacon_verified for t in tokens)

    split = next(t for t in tokens if t.symbol == "FXSPLIT")
    assert split.ui_multiplier == 4.0

    opaque = next(t for t in tokens if t.symbol == "FXOPAQUE")
    assert opaque.ui_multiplier is None
    assert any("uiMultiplier" in note for note in opaque.notes)

    sources = {s.source for s in context.sources if s.collector == "universe"}
    assert sources == {"robinhood-assets", "robinhood-docs", "blockscout", "beacon-slot"}


def test_a_dead_issuer_registry_degrades_to_the_other_sources(context, cassette_path) -> None:
    transport = FixtureTransport.from_path(cassette_path)
    del transport.cassette["json"][ROBINHOOD_ASSETS_URL]
    context.transport = transport
    context.rpc.transport = transport

    tokens = TokenUniverseCollector().collect(context)
    assert len(tokens) >= 20
    assert any("issuer registry unavailable" in w for w in context.warnings)
    failed = [s for s in context.sources if not s.ok]
    assert failed and failed[0].source == "robinhood-assets"


def test_strict_mode_fails_loudly_when_nothing_parses(context, cassette_path) -> None:
    transport = FixtureTransport.from_path(cassette_path)
    for url in (ROBINHOOD_ASSETS_URL, BLOCKSCOUT_TOKENS_URL):
        del transport.cassette["json"][url]
    del transport.cassette["text"][ROBINHOOD_DOCS_URL]
    context.transport = transport
    context.rpc.transport = transport

    with pytest.raises(TransportError):
        TokenUniverseCollector(strict=True).collect(context)
