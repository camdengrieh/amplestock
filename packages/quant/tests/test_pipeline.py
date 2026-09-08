# SPDX-License-Identifier: MIT
"""The end-to-end fixture run, and the CLI around it.

This is the test that says the recorded run is reproducible: same cassette, same launch set. It
also pins the behaviours the report claims — dead and feedless names never reach the set, the
thin-book names out-rank the deep ones on ROI, and nothing here opens a socket.
"""

from __future__ import annotations

import json
import socket
from pathlib import Path

import pytest

from amplestocks_quant.constituents import cli
from amplestocks_quant.constituents.config import RunParams
from amplestocks_quant.constituents.model import roi_of
from amplestocks_quant.constituents.pipeline import run
from amplestocks_quant.constituents.results import FIXTURE_BANNER


@pytest.fixture(autouse=True)
def no_network(monkeypatch: pytest.MonkeyPatch) -> None:
    """Any socket this suite opens is a bug: the whole pipeline must run off the cassette."""

    def deny(*args, **kwargs):  # pragma: no cover - only runs if something regresses
        raise AssertionError("the fixture run must not touch the network")

    monkeypatch.setattr(socket, "socket", deny)
    monkeypatch.setattr(socket, "create_connection", deny)


@pytest.fixture(scope="module")
def result():
    return run(RunParams(fixtures=True, count=12), api_delay_seconds=0.0)


def test_the_run_measures_the_whole_cassette_universe(result) -> None:
    assert len(result.metrics) == 24
    assert sum(len(m.markets) for m in result.metrics) == 27
    assert result.head_block == 300_000_000
    assert result.window_from_block < result.short_from_block < result.head_block
    assert result.is_fixture and result.banner == FIXTURE_BANNER


def test_the_run_is_deterministic() -> None:
    first = run(RunParams(fixtures=True, count=12), api_delay_seconds=0.0)
    second = run(RunParams(fixtures=True, count=12), api_delay_seconds=0.0)
    assert [c.metrics.symbol for c in first.selection.chosen] == [
        c.metrics.symbol for c in second.selection.chosen
    ]
    assert [c.target_weight_bps for c in first.selection.chosen] == [
        c.target_weight_bps for c in second.selection.chosen
    ]


def test_hard_drops_never_reach_the_set(result) -> None:
    chosen = {c.metrics.symbol for c in result.selection.chosen}
    assert "FXNOFEED" not in chosen, "no Standard feed, however good the economics"
    assert "FXSVR" not in chosen, "an SVR feed is not a Standard feed"
    assert "FXDEAD" not in chosen and "FXDUST" not in chosen
    reasons = {r.symbol: r.reason for r in result.selection.rejected}
    assert reasons["FXNOFEED"] == "no_feed" and reasons["FXSVR"] == "no_feed"
    assert reasons["FXDEAD"] == "dead" and reasons["FXDUST"] == "dead"


def test_the_thin_book_ranks_first_and_the_deep_book_still_makes_the_set(result) -> None:
    ranked = [c.metrics.symbol for c in result.selection.chosen]
    assert ranked[0] == "FXTHIN", "highest turnover, smallest book: the WYFI corner"
    assert "FXDEEP" in ranked and "FXBIG" in ranked
    thin = next(m for m in result.metrics if m.symbol == "FXTHIN")
    deep = next(m for m in result.metrics if m.symbol == "FXDEEP")
    params = result.params
    assert roi_of(thin, params) > roi_of(deep, params)
    assert deep.volume_usd_30d > thin.volume_usd_30d


def test_flags_land_on_the_names_they_were_built_for(result) -> None:
    flags = {m.symbol: m.flags for m in result.metrics}
    assert "multiplier" in flags["FXSPLIT"]
    assert "api_delta" in flags["FXSKEW"]
    assert "insufficient_history" in flags["FXNEW"]
    assert "high_volume" in flags["FXDEEP"]
    assert "thin_liquidity" in flags["FXTHIN"]
    assert not flags["FXSTEADY"] & {"dead", "no_feed", "unpriced"}


def test_buckets_and_tick_spacing_follow_the_measurements(result) -> None:
    by_symbol = {c.metrics.symbol: c for c in result.selection.chosen}
    assert by_symbol["FXTHIN"].pool_class == "SPOKE_HIGH_VOL"
    assert by_symbol["FXTHIN"].buy_fee_bps == 10
    assert by_symbol["FXFLOW"].pool_class == "SPOKE"
    assert by_symbol["FXFLOW"].buy_fee_bps == 5
    assert all(c.metrics.tick_spacing == 60 for c in result.selection.chosen)


def test_every_selected_name_has_a_token_a_feed_and_a_price(result) -> None:
    for constituent in result.selection.chosen:
        record = constituent.metrics
        assert record.token.address.startswith("0x")
        assert record.token.beacon_verified is True
        assert record.feed is not None and not record.feed.is_svr
        assert record.price_usd and record.price_usd > 0
        assert record.volume_usd_7d > 0


def test_the_run_records_provenance_for_every_source(result) -> None:
    sources = {(s.collector, s.source) for s in result.sources}
    assert ("universe", "robinhood-assets") in sources
    assert ("universe", "blockscout") in sources
    assert ("feeds", "chainlink-rdd") in sources
    assert ("market", "pool-state") in sources
    assert ("api-crosscheck", "geckoterminal") in sources
    assert result.hosts and "rpc.mainnet.chain.robinhood.com" in result.hosts


def test_cli_writes_every_artefact(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    out = tmp_path / "out"
    report = tmp_path / "docs" / "launch-constituents.md"
    code = cli.main(
        [
            "run", "--fixtures", "--count", "12", "--api-delay", "0",
            "--out", str(out), "--report", str(report), "--quiet",
        ]
    )
    assert code == 0
    for name in ("constituents.json", "launch-set.ts", "constituents.registry.json"):
        assert (out / name).exists(), name
    assert report.exists()
    payload = json.loads((out / "constituents.json").read_text())
    assert payload["fixture"] is True
    assert len(payload["selection"]["chosen"]) == 12


def test_cli_refuses_to_put_fixture_data_in_the_contracts_tree(tmp_path: Path, capsys) -> None:
    template = tmp_path / "contracts" / "script" / "config" / "constituents.json"
    template.parent.mkdir(parents=True)
    template.write_text(json.dumps({"constituents": [], "entryPools": []}))
    code = cli.main(
        [
            "run", "--fixtures", "--count", "12", "--api-delay", "0", "--quiet",
            "--out", str(tmp_path / "out"), "--no-report",
            "--write-registry-config", "--registry-config", str(template),
        ]
    )
    assert code == 2
    assert "refusing to write fixture data" in capsys.readouterr().err
    assert json.loads(template.read_text())["constituents"] == []


def test_cli_placement_flag_is_repeatable_and_the_first_one_ranks() -> None:
    args = cli.build_parser().parse_args(
        ["run", "--placement", "1000", "--placement", "300", "--window", "45"]
    )
    params = cli.params_from_args(args)
    assert params.placements == (1000.0, 300.0)
    assert params.placement == 1000.0
    assert params.window_days == 45


def test_cli_defaults_match_the_documented_command() -> None:
    params = cli.params_from_args(cli.build_parser().parse_args(["run"]))
    assert params.placements == (300.0, 1000.0, 5000.0)
    assert (params.window_days, params.short_window_days) == (30, 7)
    assert (params.count, params.min_high_volume) == (30, 10)
    assert params.rpc_url == "https://rpc.mainnet.chain.robinhood.com"
    assert params.fee_basis == "base"
