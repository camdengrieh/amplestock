# SPDX-License-Identifier: MIT
"""Launch-constituent selection for Amplestocks.

Ranks every Robinhood Stock Token on chain 4663 by the fee revenue protocol-owned liquidity would
earn per dollar placed, picks the launch 30, and writes the report and the deploy configs.

    from amplestocks_quant.constituents import RunParams, run
    result = run(RunParams(fixtures=True))

CLI: `python -m amplestocks_quant.constituents run --help`.
"""

from __future__ import annotations

from .config import RunParams
from .pipeline import run
from .report import render
from .results import FIXTURE_BANNER, RunResult
from .selection import cap_bps, floor_bps, index_weights, select

__all__ = [
    "FIXTURE_BANNER",
    "RunParams",
    "RunResult",
    "cap_bps",
    "floor_bps",
    "index_weights",
    "render",
    "run",
    "select",
]
