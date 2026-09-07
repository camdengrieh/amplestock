# SPDX-License-Identifier: MIT
"""Config writers: the registry JSON, the TypeScript constant, and the ranking data.

Three rules these writers follow, all of them there to keep a modelling run from quietly becoming a
deploy input:

1. **Never invent an address.** A name only reaches the registry config with a token address read
   from a universe source and a feed proxy read from the Chainlink RDD. Anything else keeps the
   `tokenTodo` / `feedTodo` flags that `05_Registry.s.sol` refuses to register against.
2. **Preserve the template.** `contracts/script/config/constituents.json` carries the two entry
   pools, the registration-weight note and the per-market bond defaults. The writer rewrites the
   `constituents` array and leaves everything else exactly as it found it.
3. **A fixture run cannot silently overwrite a deploy input.** The registry config is written into
   the run's `--out` directory by default; `--write-registry-config` copies it into
   `contracts/script/config/`, and that copy is refused for a fixture run unless `--force` is also
   given. The synthetic addresses in the cassette would otherwise land in a deploy script.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .inclusion import InclusionStats
from .records import Constituent
from .results import FIXTURE_BANNER, RunResult

#: Bond defaults, mirrored from `packages/config/src/index.ts` `launchParameters.bonds`.
DEFAULT_BOND = {
    "dBaseBps": 1250,
    "dMinBps": 1000,
    "dMaxBps": 1500,
    "capBpsPerEpoch": 50,
    "kWeightX18": 2000000000000000000,
    "kFillX18": 1000000000000000000,
}
DEFAULT_HEARTBEAT_SECONDS = 86_400
#: `Constants.MIN_HISTORY_DAYS`. Measured inclusion evidence below this cannot be registered.
MIN_HISTORY_DAYS = 30
DEFAULT_INCLUSION = {
    "betaX18": 900000000000000000,
    "trackingErrorX18": 30000000000000000,
    "indexVolX18": 200000000000000000,
    "historyDays": 400,
}


class FixtureWriteRefused(RuntimeError):
    """A fixture run tried to overwrite a real deploy input."""


def _dump(path: Path, payload: Any) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n")
    return path


def write_ranking_json(path: Path, result: RunResult) -> Path:
    """`out/constituents.json` — every measured name, ranked, with provenance."""
    return _dump(path, result.to_dict())


# ------------------------------------------------------------------------------------------------
# contracts/script/config/constituents.json
# ------------------------------------------------------------------------------------------------


def build_registry_config(result: RunResult, template: dict[str, Any]) -> dict[str, Any]:
    """The registry config for this run, on top of the existing file's non-constituent parts."""
    out = dict(template)
    previous = {c.get("symbol"): c for c in template.get("constituents", [])}

    comment = str(template.get("$comment", ""))
    generated = (
        f"Regenerated {result.iso(result.generated_at)} by "
        f"`python -m amplestocks_quant.constituents run` over a {result.params.window_days}-day "
        f"chain window ending {result.iso()}; ranking by fee ROI at "
        f"${result.params.placement:,.0f} per spoke."
    )
    out["$comment"] = (
        f"{FIXTURE_BANNER}. {generated} EVERY ADDRESS IN THIS FILE IS SYNTHETIC. " + comment
        if result.is_fixture
        else f"{generated} " + comment
    )
    out["source"] = (
        "packages/quant: amplestocks_quant.constituents (chain 4663 swap/state reads + Chainlink RDD)"
    )
    out["constituentCount"] = len(result.selection.chosen)
    out["constituents"] = [
        _registry_entry(c, previous.get(c.metrics.symbol), result.inclusion.get(c.metrics.symbol))
        for c in result.selection.chosen
    ]
    notes = dict(template.get("notes", {}))
    notes["generatedBy"] = (
        "poolClass/buyFeeBps from measured 30-day realised volatility; targetWeightBps and "
        "rolloutWeightBps from sqrt(V30 * depth) inside the registry band; tickSpacing from the "
        "token's most common v4 spacing; inclusion measured where the window allowed it."
    )
    out["notes"] = notes
    return out


def _registry_entry(
    constituent: Constituent, previous: dict[str, Any] | None, inclusion: InclusionStats | None
) -> dict[str, Any]:
    record = constituent.metrics
    token = record.token
    feed = record.feed
    inclusion_block = _inclusion_block(inclusion, previous)

    price_usd = record.price_usd or 0.0
    return {
        "symbol": record.symbol,
        "name": token.name or (previous or {}).get("name", record.symbol),
        "kind": token.kind or (previous or {}).get("kind", "equity"),
        "token": token.address,
        "feed": feed.proxy if feed else "0x" + "0" * 40,
        "tokenTodo": not bool(token.address),
        "feedTodo": feed is None,
        "poolClass": constituent.pool_class,
        "tickSpacing": record.tick_spacing,
        "buyFeeBps": constituent.buy_fee_bps,
        "targetWeightBps": constituent.target_weight_bps,
        "rolloutWeightBps": constituent.rollout_weight_bps,
        "hSessionOverrideBps": (previous or {}).get("hSessionOverrideBps", 0),
        "hSessionOverrideSet": (previous or {}).get("hSessionOverrideSet", False),
        "openBondMarket": (previous or {}).get("openBondMarket", True),
        "inclusion": inclusion_block,
        "bond": dict((previous or {}).get("bond", DEFAULT_BOND)),
        "heartbeatSeconds": (feed.heartbeat_seconds if feed and feed.heartbeat_seconds else DEFAULT_HEARTBEAT_SECONDS),
        "testnetPriceUsd8": round(price_usd * 10**8),
    }


def _inclusion_block(
    inclusion: InclusionStats | None, previous: dict[str, Any] | None
) -> dict[str, Any]:
    """The `inclusion` object for one entry.

    Measured evidence is only promoted into the registered fields when it would actually satisfy
    `PoolRegistry`: `historyDays >= MIN_HISTORY_DAYS`. A 30-day chain window evidences at most 30
    days, so a shorter window keeps the template's placeholder and parks the measurement in a
    `measurement` sub-object, where the deploy script does not read it but a reviewer does.
    """
    if inclusion is not None and inclusion.measured and inclusion.history_days >= MIN_HISTORY_DAYS:
        return {**inclusion.to_x18(), "placeholder": False}
    base = dict((previous or {}).get("inclusion", DEFAULT_INCLUSION))
    base.pop("placeholder", None)
    base.pop("measurement", None)
    block: dict[str, Any] = {**base, "placeholder": True}
    if inclusion is not None:
        block["measurement"] = {
            **inclusion.to_x18(),
            "measured": inclusion.measured,
            "passesRule": inclusion.passes(),
            "note": inclusion.note
            or (
                f"{inclusion.history_days} observed days < MIN_HISTORY_DAYS {MIN_HISTORY_DAYS};"
                " widen --window or supply Phase 0A history"
            ),
        }
    return block


def write_registry_config(
    path: Path, result: RunResult, template_path: Path, *, allow_fixture: bool = False
) -> Path:
    """Write the registry-shaped config, refusing to put fixture data in the contracts tree."""
    template = json.loads(template_path.read_text()) if template_path.exists() else {}
    payload = build_registry_config(result, template)
    in_contracts = "contracts" in path.parts
    if result.is_fixture and in_contracts and not allow_fixture:
        raise FixtureWriteRefused(
            f"refusing to write fixture data to {path}: re-run without --fixtures, or pass --force"
        )
    return _dump(path, payload)


# ------------------------------------------------------------------------------------------------
# packages/config/src/index.ts mirror
# ------------------------------------------------------------------------------------------------


def build_launch_set_ts(result: RunResult) -> str:
    """The `launchConstituents` literal for `packages/config/src/index.ts`, as text."""
    lines: list[str] = []
    lines.append("// SPDX-License-Identifier: MIT")
    lines.append("//")
    if result.is_fixture:
        lines.append(f"// {FIXTURE_BANNER}. Every address below is synthetic cassette data.")
        lines.append("//")
    lines.append(
        "// Generated by `python -m amplestocks_quant.constituents run"
        f" --window {result.params.window_days} --placement {result.params.placement:g}`"
        f" at {result.iso(result.generated_at)}."
    )
    lines.append(
        f"// Data window: {result.params.window_days} days of chain 4663 swap history ending"
        f" {result.iso()} (head block {result.head_block})."
    )
    lines.append(
        "// Paste the array below over `launchConstituents` in packages/config/src/index.ts and keep"
    )
    lines.append("// `LAUNCH_CONSTITUENT_COUNT` in step. Do not import this file: it is a paste source.")
    lines.append("")
    lines.append("export const launchConstituents = [")
    for constituent in result.selection.chosen:
        record = constituent.metrics
        feed = record.feed
        token = _ts_string(record.token.address)
        feed_value = _ts_string(feed.proxy) if feed else "null"
        verify = "false" if (record.token.beacon_verified and feed) else "true"
        name = _ts_string(record.token.name or record.symbol)
        lines.append(
            f"  {{symbol: {_ts_string(record.symbol)}, name: {name}, kind: {_ts_string(record.token.kind)},"
            f" token: {token}, feed: {feed_value}, verify: {verify}}},"
        )
    lines.append("] as const satisfies readonly LaunchConstituent[]")
    lines.append("")
    lines.append(f"export const LAUNCH_CONSTITUENT_COUNT = {len(result.selection.chosen)}")
    lines.append("")
    lines.append("// Target index weights (bps, sum 10000) for the single post-registration")
    lines.append("// `setIndexWeights` call. Registration itself uses `registrationWeightBps`.")
    lines.append("export const launchIndexWeightsBps: Readonly<Record<string, number>> = Object.freeze({")
    for constituent in result.selection.chosen:
        lines.append(f"  {constituent.metrics.symbol}: {constituent.target_weight_bps},")
    lines.append("})")
    lines.append("")
    return "\n".join(lines)


def write_launch_set_ts(path: Path, result: RunResult) -> Path:
    """Write the TypeScript paste source."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(build_launch_set_ts(result))
    return path


def _ts_string(value: str) -> str:
    """Single-quoted TS string literal, matching `packages/config` style."""
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"
