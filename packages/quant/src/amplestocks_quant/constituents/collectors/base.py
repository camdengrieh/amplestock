# SPDX-License-Identifier: MIT
"""The collector contract and the run context they share.

A collector does one job: turn one family of upstream sources into typed records, recording a
`SourceRecord` for every source it touched — including the ones that failed. It never decides
anything. Selection reads only what collectors recorded, so a source outage shows up in the report
as a missing input rather than as a silently different launch set.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any

from ..config import RunParams
from ..records import SourceRecord
from ..rpc import JsonRpc
from ..transport import Transport


@dataclass
class RunContext:
    """Shared state for one run: transports, the resolved block window, and provenance."""

    transport: Transport
    params: RunParams
    rpc: JsonRpc | None = None
    #: Wall-clock timestamp the run is anchored to (head block's timestamp on a real run).
    now_ts: int = 0
    head_block: int = 0
    #: First block of the long (`--window`) window.
    window_from_block: int = 0
    #: First block of the short (7-day) window.
    short_from_block: int = 0
    sources: list[SourceRecord] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def record(
        self, collector: str, source: str, url: str, ok: bool, items: int = 0, note: str = ""
    ) -> None:
        """Append a provenance record."""
        self.sources.append(SourceRecord(collector, source, url, ok, items, note))

    def warn(self, message: str) -> None:
        """Record a warning once."""
        if message not in self.warnings:
            self.warnings.append(message)

    @property
    def window_seconds(self) -> int:
        """Length of the long window."""
        return self.params.window_days * 86_400

    @property
    def short_window_seconds(self) -> int:
        """Length of the short window."""
        return self.params.short_window_days * 86_400


class Collector(ABC):
    """One family of sources.

    Subclasses declare `key` (the name used in provenance and warnings) and `hosts` (every host the
    collector may dial, which is what the runbook's allowlist section is generated from).
    """

    key: str = "collector"
    hosts: tuple[str, ...] = ()

    @abstractmethod
    def collect(self, ctx: RunContext) -> Any:
        """Gather this collector's records, appending provenance to `ctx`."""
        raise NotImplementedError


def all_hosts(collectors: list[Collector]) -> list[str]:
    """Sorted, de-duplicated host list for a set of collectors."""
    seen: set[str] = set()
    for collector in collectors:
        seen.update(collector.hosts)
    return sorted(seen)
