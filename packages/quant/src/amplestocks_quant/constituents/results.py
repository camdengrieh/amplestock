# SPDX-License-Identifier: MIT
"""The finished run, in one record.

Everything downstream — the report, the three config writers, the tests — reads a `RunResult` and
nothing else. That is what lets the fixture run and a real run produce byte-identical output shapes
and lets the tests assert on the whole pipeline without a network.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any

from .config import RunParams
from .inclusion import InclusionStats
from .records import SelectionResult, SourceRecord, TokenMetrics

#: Stamped into every artefact a fixture run writes. Grep for it before trusting a file.
FIXTURE_BANNER = "FIXTURE DATA - not a launch set"


@dataclass
class RunResult:
    """One complete run of the pipeline."""

    params: RunParams
    metrics: list[TokenMetrics]
    selection: SelectionResult
    inclusion: dict[str, InclusionStats] = field(default_factory=dict)
    sources: list[SourceRecord] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    quartiles: dict[str, float] = field(default_factory=dict)
    generated_at: int = field(default_factory=lambda: int(time.time()))
    data_timestamp: int = 0
    head_block: int = 0
    window_from_block: int = 0
    short_from_block: int = 0
    rpc_requests: int = 0
    log_requests: int = 0
    hosts: list[str] = field(default_factory=list)

    @property
    def is_fixture(self) -> bool:
        """Whether this run replayed the fixture cassette."""
        return self.params.fixtures

    @property
    def banner(self) -> str:
        """The label every artefact carries, empty for a real run."""
        return FIXTURE_BANNER if self.is_fixture else ""

    def iso(self, timestamp: int | None = None) -> str:
        """UTC ISO-8601 for a unix timestamp, defaulting to the data timestamp."""
        value = timestamp if timestamp is not None else (self.data_timestamp or self.generated_at)
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(value))

    def to_dict(self) -> dict[str, Any]:
        """The full ranking as data — what `out/constituents.json` holds."""
        chosen = {c.metrics.symbol: c for c in self.selection.chosen}
        return {
            "$comment": (
                f"{self.banner}. " if self.banner else ""
            )
            + "Full constituent ranking written by amplestocks_quant.constituents. "
            "Chain data is authoritative; API figures are cross-checks only.",
            "generatedAt": self.iso(self.generated_at),
            "dataTimestamp": self.iso(self.data_timestamp) if self.data_timestamp else None,
            "fixture": self.is_fixture,
            "chainId": 4663,
            "window": {
                "days": self.params.window_days,
                "shortDays": self.params.short_window_days,
                "headBlock": self.head_block,
                "fromBlock": self.window_from_block,
                "shortFromBlock": self.short_from_block,
            },
            "params": self.params.to_dict(),
            "quartiles": self.quartiles,
            "rpc": {"requests": self.rpc_requests, "logRequests": self.log_requests},
            "hosts": self.hosts,
            "warnings": list(self.warnings),
            "sources": [s.to_dict() for s in self.sources],
            "selection": self.selection.to_dict(),
            "ranking": [
                {
                    **record.to_dict(),
                    "selected": record.symbol in chosen,
                    "rank": chosen[record.symbol].rank if record.symbol in chosen else None,
                    "inclusion": (
                        {
                            **self.inclusion[record.symbol].to_x18(),
                            "measured": self.inclusion[record.symbol].measured,
                            "passesRule": self.inclusion[record.symbol].passes(),
                            "note": self.inclusion[record.symbol].note,
                        }
                        if record.symbol in self.inclusion
                        else None
                    ),
                }
                for record in sorted(
                    self.metrics, key=lambda m: (chosen[m.symbol].rank if m.symbol in chosen else 10_000, m.symbol)
                )
            ],
        }
