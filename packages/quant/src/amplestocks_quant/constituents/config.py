# SPDX-License-Identifier: MIT
"""Run parameters — every knob the CLI exposes, in one frozen-ish record.

Defaults are the launch plan's, not arbitrary: the spoke buy fees (5 bp / 10 bp), the 30-name
count, the 60 tick spacing and the `sigma > 60%` high-volatility bucket all come from
`packages/config/src/index.ts` (`launchParameters`) and `contracts/src/types/Constants.sol`.

The one default that does **not** come from the repo is `placements = (300, 1000, 5000)`. The task
brief specifies $300 as the per-spoke placement; `launchParameters.supply.perSpokeSeedAmps` is
47.5 AMPS (= $47.50 at the $1 floor). The pipeline computes every placement it is given and the
report prints the discrepancy rather than silently picking one — see `docs/launch-constituents.md`.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from typing import Any

from .chain import RPC_FALLBACK, RPC_PRIMARY
from .rpc import DEFAULT_CHUNK_BLOCKS, DEFAULT_DISCOVERY_CHUNK_BLOCKS


@dataclass
class RunParams:
    """Everything that changes what a run computes."""

    # -- data window -----------------------------------------------------------------------------
    window_days: int = 30
    short_window_days: int = 7
    # -- endpoints -------------------------------------------------------------------------------
    rpc_url: str = RPC_PRIMARY
    fallback_rpc_url: str | None = RPC_FALLBACK
    chunk_blocks: int = DEFAULT_CHUNK_BLOCKS
    discovery_chunk_blocks: int = DEFAULT_DISCOVERY_CHUNK_BLOCKS
    timeout: float = 30.0
    retries: int = 3
    fixtures: bool = False
    cross_check: bool = True
    max_pages: int = 20
    #: First block of the pool-discovery scan. `Initialize`/`PoolCreated` are rare but can predate
    #: the volume window by months, so the default is genesis.
    pools_from_block: int = 0
    # -- model -----------------------------------------------------------------------------------
    placements: tuple[float, ...] = (300.0, 1000.0, 5000.0)
    spoke_fee_bps: float = 5.0
    spoke_high_vol_fee_bps: float = 10.0
    fee_basis: str = "base"
    vol_threshold: float = 0.60
    dead_depth_usd: float = 1000.0
    usdg_usd: float = 1.0
    # -- selection -------------------------------------------------------------------------------
    count: int = 30
    min_high_volume: int = 10
    default_tick_spacing: int = 60
    # -- provenance ------------------------------------------------------------------------------
    label: str = ""
    extra: dict[str, Any] = field(default_factory=dict)

    @property
    def placement(self) -> float:
        """The placement the ranking uses: the first one given."""
        return self.placements[0] if self.placements else 300.0

    def with_(self, **changes: Any) -> RunParams:
        """A copy with `changes` applied."""
        return replace(self, **changes)

    def to_dict(self) -> dict[str, Any]:
        """JSON form, for the report's provenance block."""
        return {
            "windowDays": self.window_days,
            "shortWindowDays": self.short_window_days,
            "rpcUrl": self.rpc_url,
            "fallbackRpcUrl": self.fallback_rpc_url,
            "chunkBlocks": self.chunk_blocks,
            "discoveryChunkBlocks": self.discovery_chunk_blocks,
            "poolsFromBlock": self.pools_from_block,
            "fixtures": self.fixtures,
            "crossCheck": self.cross_check,
            "placementsUsd": list(self.placements),
            "primaryPlacementUsd": self.placement,
            "spokeFeeBps": self.spoke_fee_bps,
            "spokeHighVolFeeBps": self.spoke_high_vol_fee_bps,
            "feeBasis": self.fee_basis,
            "volThreshold": self.vol_threshold,
            "deadDepthUsd": self.dead_depth_usd,
            "usdgUsd": self.usdg_usd,
            "count": self.count,
            "minHighVolume": self.min_high_volume,
            "defaultTickSpacing": self.default_tick_spacing,
            "label": self.label,
        }
