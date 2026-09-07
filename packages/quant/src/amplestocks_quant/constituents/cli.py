# SPDX-License-Identifier: MIT
"""`python -m amplestocks_quant.constituents` — the one command that produces a launch set.

    # the real run (needs the hosts in README.md's runbook section reachable)
    python -m amplestocks_quant.constituents run \\
        --rpc https://rpc.mainnet.chain.robinhood.com --window 30 --placement 300 --out out

    # the recorded run: no network, synthetic cassette, artefacts labelled FIXTURE DATA
    python -m amplestocks_quant.constituents run --fixtures --out out

`--out` is a directory. It receives `constituents.json` (the full ranking as data),
`launch-set.ts` (the paste source for `packages/config/src/index.ts`) and
`constituents.registry.json` (the `contracts/script/config/constituents.json` shape). The Markdown
report goes to `docs/launch-constituents.md` unless `--report` says otherwise, and the registry
config is only copied into the contracts tree when `--write-registry-config` asks for it.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .chain import RPC_FALLBACK, RPC_PRIMARY
from .config import RunParams
from .pipeline import DEFAULT_CASSETTE, run
from .report import render
from .results import RunResult
from .rpc import DEFAULT_CHUNK_BLOCKS, DEFAULT_DISCOVERY_CHUNK_BLOCKS
from .writers import (
    FixtureWriteRefused,
    write_launch_set_ts,
    write_ranking_json,
    write_registry_config,
)

REGISTRY_CONFIG_RELATIVE = Path("contracts/script/config/constituents.json")
REPORT_RELATIVE = Path("docs/launch-constituents.md")


def find_repo_root(start: Path | None = None) -> Path:
    """Nearest ancestor holding `pnpm-workspace.yaml` (or `.git`), else the current directory."""
    here = (start or Path.cwd()).resolve()
    for candidate in (here, *here.parents):
        if (candidate / "pnpm-workspace.yaml").exists() or (candidate / ".git").exists():
            return candidate
    return here


def build_parser() -> argparse.ArgumentParser:
    """The CLI."""
    parser = argparse.ArgumentParser(
        prog="python -m amplestocks_quant.constituents",
        description="Rank Robinhood Stock Tokens by fee ROI on protocol-owned liquidity and pick "
        "the launch set.",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    cmd = sub.add_parser("run", help="collect, model, select and write every artefact")

    data = cmd.add_argument_group("data window")
    data.add_argument("--window", type=int, default=30, metavar="DAYS", help="long window (V30), default 30")
    data.add_argument("--short-window", type=int, default=7, metavar="DAYS", help="short window (V7), default 7")

    net = cmd.add_argument_group("endpoints")
    net.add_argument("--rpc", default=RPC_PRIMARY, help=f"JSON-RPC endpoint (default {RPC_PRIMARY})")
    net.add_argument("--fallback-rpc", default=RPC_FALLBACK, help="second endpoint, tried per request")
    net.add_argument("--chunk-blocks", type=int, default=DEFAULT_CHUNK_BLOCKS, help="eth_getLogs span for swaps")
    net.add_argument(
        "--discovery-chunk-blocks",
        type=int,
        default=DEFAULT_DISCOVERY_CHUNK_BLOCKS,
        help="eth_getLogs span for pool discovery (Initialize/PoolCreated are rare)",
    )
    net.add_argument("--pools-from-block", type=int, default=0, help="first block of pool discovery")
    net.add_argument("--timeout", type=float, default=30.0, help="per-request timeout, seconds")
    net.add_argument("--retries", type=int, default=3, help="attempts per request")
    net.add_argument("--no-cross-check", action="store_true", help="skip the aggregator collectors")
    net.add_argument("--api-delay", type=float, default=2.0, help="sleep between aggregator calls")
    net.add_argument("--fixtures", action="store_true", help="replay the recorded synthetic cassette")
    net.add_argument("--cassette", type=Path, default=None, help=f"cassette path (default {DEFAULT_CASSETTE})")
    net.add_argument("--strict-universe", action="store_true", help="fail if no universe source parses")

    model = cmd.add_argument_group("model")
    model.add_argument(
        "--placement",
        type=float,
        action="append",
        metavar="USD",
        help="placement per spoke; repeatable, first one ranks (default 300, 1000, 5000)",
    )
    model.add_argument("--fee-basis", choices=("base", "effective"), default="base")
    model.add_argument("--vol-threshold", type=float, default=0.60, help="sigma above which a spoke is 10 bp")
    model.add_argument("--dead-depth", type=float, default=1000.0, metavar="USD", help="depth floor")
    model.add_argument("--usdg-usd", type=float, default=1.0, help="USDG price used to value the stable leg")

    pick = cmd.add_argument_group("selection")
    pick.add_argument("--count", type=int, default=30, help="launch set size, default 30")
    pick.add_argument("--min-high-volume", type=int, default=10, help="floor on top-quartile-volume names")
    pick.add_argument("--tick-spacing", type=int, default=60, help="fallback tick spacing")

    out = cmd.add_argument_group("output")
    out.add_argument("--out", type=Path, default=Path("out"), help="output directory, default ./out")
    out.add_argument("--report", type=Path, default=None, help="Markdown report path")
    out.add_argument("--no-report", action="store_true", help="skip the Markdown report")
    out.add_argument(
        "--write-registry-config",
        action="store_true",
        help="also write contracts/script/config/constituents.json",
    )
    out.add_argument("--registry-config", type=Path, default=None, help="override that path")
    out.add_argument("--force", action="store_true", help="allow a fixture run to write into contracts/")
    out.add_argument("--quiet", action="store_true", help="only print the written paths")
    return parser


def params_from_args(args: argparse.Namespace) -> RunParams:
    """Map parsed arguments onto `RunParams`."""
    placements = tuple(args.placement) if args.placement else (300.0, 1000.0, 5000.0)
    return RunParams(
        window_days=args.window,
        short_window_days=args.short_window,
        rpc_url=args.rpc,
        fallback_rpc_url=args.fallback_rpc,
        chunk_blocks=args.chunk_blocks,
        discovery_chunk_blocks=args.discovery_chunk_blocks,
        pools_from_block=args.pools_from_block,
        timeout=args.timeout,
        retries=args.retries,
        fixtures=args.fixtures,
        cross_check=not args.no_cross_check,
        placements=placements,
        fee_basis=args.fee_basis,
        vol_threshold=args.vol_threshold,
        dead_depth_usd=args.dead_depth,
        usdg_usd=args.usdg_usd,
        count=args.count,
        min_high_volume=args.min_high_volume,
        default_tick_spacing=args.tick_spacing,
    )


def write_outputs(result: RunResult, args: argparse.Namespace, root: Path) -> list[Path]:
    """Write every artefact the run was asked for; returns the paths written."""
    out_dir: Path = args.out
    written: list[Path] = []
    written.append(write_ranking_json(out_dir / "constituents.json", result))
    written.append(write_launch_set_ts(out_dir / "launch-set.ts", result))

    template = args.registry_config or (root / REGISTRY_CONFIG_RELATIVE)
    written.append(
        write_registry_config(out_dir / "constituents.registry.json", result, template, allow_fixture=True)
    )
    if args.write_registry_config:
        written.append(
            write_registry_config(template, result, template, allow_fixture=args.force)
        )

    if not args.no_report:
        report_path = args.report or (root / REPORT_RELATIVE)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(render(result))
        written.append(report_path)
    return written


def main(argv: list[str] | None = None) -> int:
    """Entry point."""
    args = build_parser().parse_args(argv)
    params = params_from_args(args)
    root = find_repo_root()
    log = (lambda message: None) if args.quiet else (lambda message: print(f"  {message}", file=sys.stderr))

    if not args.quiet:
        mode = "FIXTURE (no network)" if params.fixtures else f"live: {params.rpc_url}"
        print(f"amplestocks constituent run — {mode}", file=sys.stderr)

    result = run(
        params,
        cassette=args.cassette,
        api_delay_seconds=args.api_delay,
        strict_universe=args.strict_universe,
        log=log,
    )

    try:
        written = write_outputs(result, args, root)
    except FixtureWriteRefused as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    for path in written:
        print(path)
    if not args.quiet:
        chosen = ", ".join(c.metrics.symbol for c in result.selection.chosen)
        print(
            f"\nselected {len(result.selection.chosen)}/{params.count}: {chosen}",
            file=sys.stderr,
        )
        if result.selection.shortfall:
            print(f"SHORT by {result.selection.shortfall}", file=sys.stderr)
        for warning in result.warnings:
            print(f"warning: {warning}", file=sys.stderr)
    return 0
