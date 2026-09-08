# SPDX-License-Identifier: MIT
"""The three config writers and the Markdown report.

The registry-config test is the one that matters operationally: `05_Registry.s.sol` reads this file
by JSON path, so a missing key or a renamed field is a failed deploy, and a fixture address in it
would be a deploy against a token that does not exist.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from amplestocks_quant.constituents.config import RunParams
from amplestocks_quant.constituents.pipeline import run
from amplestocks_quant.constituents.report import render
from amplestocks_quant.constituents.results import FIXTURE_BANNER
from amplestocks_quant.constituents.writers import (
    FixtureWriteRefused,
    build_launch_set_ts,
    build_registry_config,
    write_launch_set_ts,
    write_ranking_json,
    write_registry_config,
)

REPO = Path(__file__).resolve().parents[3]
TEMPLATE = REPO / "contracts" / "script" / "config" / "constituents.json"

#: Every JSON path `script/05_Registry.s.sol` reads out of a constituent entry.
REGISTRY_FIELDS = (
    "symbol", "token", "feed", "poolClass", "tickSpacing", "buyFeeBps", "targetWeightBps",
    "rolloutWeightBps", "hSessionOverrideBps", "hSessionOverrideSet", "openBondMarket",
    "heartbeatSeconds",
)
INCLUSION_FIELDS = ("betaX18", "trackingErrorX18", "indexVolX18", "historyDays")
BOND_FIELDS = ("dBaseBps", "dMinBps", "dMaxBps", "capBpsPerEpoch", "kWeightX18", "kFillX18")


@pytest.fixture(scope="module")
def result():
    return run(RunParams(fixtures=True, count=12), api_delay_seconds=0.0)


def test_the_template_is_where_the_deploy_script_expects_it() -> None:
    assert TEMPLATE.exists(), "05_Registry.s.sol reads ./script/config/constituents.json"


def test_registry_config_keeps_everything_it_did_not_generate(result) -> None:
    template = json.loads(TEMPLATE.read_text())
    payload = build_registry_config(result, template)
    assert payload["entryPools"] == template["entryPools"], "the entry pools are not ours to change"
    assert payload["chainId"] == template["chainId"]
    assert payload["registrationWeightBps"] == template["registrationWeightBps"]
    assert payload["registrationWeightNote"] == template["registrationWeightNote"]
    assert set(template["notes"]).issubset(set(payload["notes"]))


def test_registry_config_carries_every_field_the_deploy_script_reads(result) -> None:
    payload = build_registry_config(result, json.loads(TEMPLATE.read_text()))
    assert payload["constituentCount"] == len(payload["constituents"])
    for entry in payload["constituents"]:
        for field in REGISTRY_FIELDS:
            assert field in entry, f"{entry.get('symbol')} is missing {field}"
        for field in INCLUSION_FIELDS:
            assert isinstance(entry["inclusion"][field], int)
        for field in BOND_FIELDS:
            assert isinstance(entry["bond"][field], int)
        assert entry["poolClass"] in ("SPOKE", "SPOKE_HIGH_VOL")
        assert entry["buyFeeBps"] in (5, 10)
        assert entry["token"].startswith("0x") and len(entry["token"]) == 42
        assert entry["feed"].startswith("0x") and len(entry["feed"]) == 42
        assert entry["tokenTodo"] is False and entry["feedTodo"] is False


def test_registry_weights_are_a_legal_vector(result) -> None:
    payload = build_registry_config(result, json.loads(TEMPLATE.read_text()))
    weights = [entry["targetWeightBps"] for entry in payload["constituents"]]
    assert sum(weights) == 10_000
    assert all(entry["rolloutWeightBps"] == entry["targetWeightBps"] for entry in payload["constituents"])


def test_unmeasurable_inclusion_stays_a_placeholder(result) -> None:
    payload = build_registry_config(result, json.loads(TEMPLATE.read_text()))
    for entry in payload["constituents"]:
        # The fixture window is 30 days with 8 price samples, so nothing clears MIN_HISTORY_DAYS.
        assert entry["inclusion"]["placeholder"] is True
        measurement = entry["inclusion"]["measurement"]
        assert measurement["historyDays"] < 30
        # Either "the window is too short to register" or "there was not enough overlap to measure".
        assert "MIN_HISTORY_DAYS" in measurement["note"] or "overlapping days" in measurement["note"]


def test_a_fixture_run_may_not_write_into_the_contracts_tree(result, tmp_path: Path) -> None:
    target = tmp_path / "contracts" / "script" / "config" / "constituents.json"
    with pytest.raises(FixtureWriteRefused):
        write_registry_config(target, result, TEMPLATE)
    assert not target.exists()
    # ... unless it is asked twice, which is what `--force` is.
    written = write_registry_config(target, result, TEMPLATE, allow_fixture=True)
    assert written.exists()
    assert FIXTURE_BANNER in json.loads(written.read_text())["$comment"]


def test_fixture_artefacts_are_labelled(result, tmp_path: Path) -> None:
    ranking = write_ranking_json(tmp_path / "constituents.json", result)
    payload = json.loads(ranking.read_text())
    assert FIXTURE_BANNER in payload["$comment"]
    assert payload["fixture"] is True
    assert FIXTURE_BANNER in build_launch_set_ts(result)
    assert FIXTURE_BANNER in render(result)


def test_launch_set_ts_mirrors_packages_config_style(result, tmp_path: Path) -> None:
    path = write_launch_set_ts(tmp_path / "launch-set.ts", result)
    text = path.read_text()
    assert "export const launchConstituents = [" in text
    assert "] as const satisfies readonly LaunchConstituent[]" in text
    assert f"export const LAUNCH_CONSTITUENT_COUNT = {len(result.selection.chosen)}" in text
    assert "export const launchIndexWeightsBps" in text
    for constituent in result.selection.chosen:
        assert f"symbol: '{constituent.metrics.symbol}'" in text
    assert '"' not in text.split("export const launchConstituents")[1], "single quotes, like the source"
    assert ";" not in text, "packages/config is written without semicolons"


def test_ranking_json_is_self_describing(result, tmp_path: Path) -> None:
    payload = json.loads(write_ranking_json(tmp_path / "constituents.json", result).read_text())
    assert payload["window"]["days"] == 30
    assert payload["params"]["primaryPlacementUsd"] == 300.0
    assert payload["hosts"], "the report needs the host list for the allowlist request"
    assert len(payload["ranking"]) == len(result.metrics)
    selected = [row for row in payload["ranking"] if row["selected"]]
    assert len(selected) == len(result.selection.chosen)
    assert [row["rank"] for row in selected] == list(range(1, len(selected) + 1))
    assert payload["sources"] and all("collector" in s for s in payload["sources"])


def test_report_has_every_section_and_the_full_table(result) -> None:
    text = render(result)
    for heading in (
        "## 1. What this run measured",
        "## 2. Methodology",
        "## 3. The launch set",
        "## 4. Full ranking",
        "## 5. Placement sensitivity",
        "## 6. Rejected",
        "## 7. Inclusion evidence",
        "## 8. Chain vs aggregators",
        "## 9. Caveats",
        "## 10. Provenance",
        "## 11. Reproducing this",
    ):
        assert heading in text, f"missing {heading}"
    for record in result.metrics:
        assert record.symbol in text, f"{record.symbol} is missing from the report"
    assert "FXNOFEED" in text and "no Standard (non-SVR) Chainlink feed" in text
    assert "upper bound" in text, "the caveat about R must survive edits"
