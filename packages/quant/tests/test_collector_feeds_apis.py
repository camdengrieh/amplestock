# SPDX-License-Identifier: MIT
"""Chainlink RDD parsing and the aggregator cross-check."""

from __future__ import annotations

from conftest import make_token

from amplestocks_quant.constituents.chain import CHAINLINK_RDD_URL
from amplestocks_quant.constituents.collectors.apis import ApiCrossCheckCollector
from amplestocks_quant.constituents.collectors.feeds import FeedCollector, _looks_svr, _symbol_of
from amplestocks_quant.constituents.transport import FixtureTransport

# ------------------------------------------------------------------------------------------------
# Feeds
# ------------------------------------------------------------------------------------------------


def test_symbol_extraction_handles_the_shapes_the_rdd_uses() -> None:
    assert _symbol_of({"pair": ["AAPL", "USD"]}) == "AAPL"
    assert _symbol_of({"name": "TSLA / USD"}) == "TSLA"
    assert _symbol_of({"docs": {"baseAsset": "gme"}}) == "GME"


def test_svr_detection_looks_at_every_identifying_field() -> None:
    assert _looks_svr({"name": "AAPL / USD SVR"})
    assert _looks_svr({"docs": {"productSubType": "Smart Value Recapture (SVR)"}})
    assert not _looks_svr({"name": "AAPL / USD", "docs": {"productType": "Price"}})


def test_standard_feeds_win_over_svr_for_the_same_ticker(context) -> None:
    transport: FixtureTransport = context.transport
    transport.cassette["json"][CHAINLINK_RDD_URL] = [
        {
            "name": "GME / USD SVR",
            "pair": ["GME", "USD"],
            "proxyAddress": "0x" + "5a" * 20,
            "docs": {"productSubType": "Smart Value Recapture (SVR)"},
        },
        {
            "name": "GME / USD",
            "pair": ["GME", "USD"],
            "proxyAddress": "0x" + "17" * 20,
            "heartbeat": 3600,
            "threshold": 0.5,
            "feedCategory": "low",
            "docs": {"assetClass": "Equity"},
        },
    ]
    feeds = FeedCollector().collect(context)
    assert set(feeds) == {"GME"}
    assert feeds["GME"].proxy.lower() == "0x" + "17" * 20
    assert feeds["GME"].heartbeat_seconds == 3600
    assert feeds["GME"].threshold_percent == 0.5
    assert feeds["GME"].is_svr is False


def test_an_svr_only_ticker_never_becomes_a_candidate(context) -> None:
    feeds = FeedCollector().collect(context)
    assert "FXSVR" not in feeds, "an SVR-only ticker has no Standard feed"
    assert "FXNOFEED" not in feeds
    assert "FXTHIN" in feeds and feeds["FXTHIN"].asset_class == "Equity"


def test_a_dead_rdd_leaves_every_name_unregisterable(context) -> None:
    del context.transport.cassette["json"][CHAINLINK_RDD_URL]
    assert FeedCollector().collect(context) == {}
    assert any("Chainlink RDD unavailable" in w for w in context.warnings)


# ------------------------------------------------------------------------------------------------
# Aggregators
# ------------------------------------------------------------------------------------------------


def test_each_aggregator_shape_is_parsed(context) -> None:
    tokens = [make_token("FXTHIN", "0x32411990AFDe8D09A51ED049903f19E2447dBF81")]
    quotes = ApiCrossCheckCollector(delay_seconds=0.0).collect_for(context, tokens)
    by_source = {q.source: q for q in quotes[tokens[0].key]}
    assert set(by_source) == {"geckoterminal", "dexpaprika", "dexscreener"}
    for quote in by_source.values():
        assert quote.volume_usd_24h and quote.volume_usd_24h > 0
        assert quote.reserve_usd and quote.reserve_usd > 0
        assert quote.pools == 1


def test_cross_check_can_be_switched_off(context) -> None:
    context.params = context.params.with_(cross_check=False)
    assert ApiCrossCheckCollector().collect_for(context, [make_token("FXTHIN")]) == {}
    assert any(s.source == "disabled" for s in context.sources)


def test_a_missing_token_is_recorded_not_fatal(context) -> None:
    quotes = ApiCrossCheckCollector(delay_seconds=0.0).collect_for(context, [make_token("NOPE")])
    assert quotes == {}
    failures = [s for s in context.sources if s.collector == "api-crosscheck" and not s.ok]
    assert failures
