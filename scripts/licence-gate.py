#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Amplestocks SPDX / copyleft gate.

The rule this enforces (Decision 3, and `NOTICES.md`): **no BUSL-1.1, AGPL-3.0, GPL-2.0 or
GPL-3.0 source may be reachable from `contracts/src/**`**, and every production-reachable file
must carry an SPDX header. `contracts/test/**` and `contracts/script/**` are exempt -- they never
ship -- but what they pull in is still reported so the exemption stays visible.

"Reachable" is not a grep over `remappings.txt`; it is the real import graph. The script reads
Foundry's `--build-info` output (solc standard-JSON input + output), walks `ImportDirective` nodes
in each source unit's AST out of the `src/` roots, and reads the SPDX identifier solc itself parsed
(falling back to a regex over the source text when an AST is unavailable).

The canonical case this exists to catch: Uniswap v4-core is a mixed-licence repository. Its
interfaces, types and libraries are MIT and we import them freely; its `PoolManager` implementation
is BUSL-1.1. Production code must only ever reach the MIT `IPoolManager` interface, while tests may
stand up a real PoolManager from hookmate's prebuilt artefact. This gate is what makes that
boundary a fact rather than an intention.

Usage
-----
    python3 scripts/licence-gate.py                     # read contracts/out/build-info
    python3 scripts/licence-gate.py --out out-mono      # read an alternate artifacts dir
    python3 scripts/licence-gate.py --build             # run `forge build --build-info` first
    python3 scripts/licence-gate.py --json report.json  # also write a machine-readable report

Exit codes
----------
    0  no production-reachable violations (including the trivial case: `src/` is empty)
    1  at least one production-reachable violation
    2  the gate could not run (no usable build-info, forge missing, bad arguments)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------------------------
# Policy
# --------------------------------------------------------------------------------------------

#: SPDX identifiers that may not appear anywhere in the production import graph.
FORBIDDEN_PREFIXES: tuple[str, ...] = (
    "BUSL-1.1",
    "BUSL",
    "AGPL-3.0",
    "AGPL-1.0",
    "GPL-2.0",
    "GPL-3.0",
)

#: Identifiers we positively expect. Anything outside this set is reported as "unrecognised"
#: (not fatal on its own, but it means a human has to look).
KNOWN_PERMISSIVE: tuple[str, ...] = (
    "MIT",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
    "CC0-1.0",
    "Unlicense",
    "MIT-0",
)

NO_LICENSE = "<none>"

SPDX_RE = re.compile(r"SPDX-License-Identifier:\s*([^\s*/]+(?:\s+(?:OR|AND)\s+[^\s*/]+)*)")
IMPORT_RE = re.compile(r"""^\s*import\s+(?:[^'"]*?\bfrom\s*)?['"]([^'"]+)['"]""", re.MULTILINE)


def is_forbidden_token(token: str) -> bool:
    t = token.strip().strip("()").upper()
    return any(t.startswith(p.upper()) for p in FORBIDDEN_PREFIXES)


def classify(license_expr: str) -> tuple[bool, str]:
    """Return ``(forbidden, reason)`` for an SPDX expression.

    A dual licence such as ``GPL-2.0-or-later OR MIT`` is *not* forbidden: we may take the MIT
    branch. It is only forbidden when every ``OR`` alternative is forbidden.
    """
    if license_expr == NO_LICENSE or not license_expr.strip():
        return True, "no SPDX header"

    expr = license_expr.replace("(", " ").replace(")", " ")
    alternatives = [a.strip() for a in re.split(r"\bOR\b", expr, flags=re.IGNORECASE) if a.strip()]
    if not alternatives:
        return True, "unparseable SPDX expression"

    def alt_forbidden(alt: str) -> bool:
        # An `AND` conjunction is forbidden if any conjunct is forbidden.
        conjuncts = [c.strip() for c in re.split(r"\bAND\b", alt, flags=re.IGNORECASE) if c.strip()]
        return any(is_forbidden_token(c) for c in conjuncts)

    if all(alt_forbidden(a) for a in alternatives):
        return True, "copyleft / source-available licence"
    return False, ""


def is_recognised(license_expr: str) -> bool:
    if license_expr == NO_LICENSE:
        return False
    tokens = [t for t in re.split(r"\b(?:OR|AND)\b|\s+", license_expr, flags=re.IGNORECASE) if t]
    return all(t.strip("()") in KNOWN_PERMISSIVE or is_forbidden_token(t) for t in tokens)


# --------------------------------------------------------------------------------------------
# Build-info loading
# --------------------------------------------------------------------------------------------


@dataclass
class SourceUnit:
    path: str
    license: str = NO_LICENSE
    imports: set[str] = field(default_factory=set)
    origin: str = ""  # which build-info file it came from


class GateError(Exception):
    """The gate could not run (exit 2), as distinct from finding a violation (exit 1)."""


def run_forge_build(contracts_dir: Path, out_dir: str, cache_dir: str | None) -> bool:
    """Build with `--build-info`. Returns True if `test/**` made it into the graph.

    If the full build fails, retry with `--skip 'test/**'`. A test that does not compile is the
    `contracts` CI job's problem; it must not stop this gate from checking the production graph,
    which is the only part that can actually ship. The exempt report is then incomplete and says so.
    """
    env = dict(os.environ)
    env["FOUNDRY_OUT"] = out_dir
    if cache_dir:
        env["FOUNDRY_CACHE_PATH"] = cache_dir

    def build(extra: list[str]) -> subprocess.CompletedProcess[str]:
        cmd = ["forge", "build", "--build-info", *extra]
        print(f"  $ FOUNDRY_OUT={out_dir} {' '.join(cmd)}   (cwd={contracts_dir})")
        try:
            return subprocess.run(cmd, cwd=contracts_dir, env=env, capture_output=True, text=True)
        except FileNotFoundError as exc:  # forge not on PATH
            raise GateError(
                "forge is not on PATH. Install Foundry, or add it: export PATH=$HOME/.foundry/bin:$PATH"
            ) from exc

    proc = build([])
    if proc.returncode == 0:
        return True

    print("  WARNING: the full build failed, so test/** cannot be reported. Retrying with --skip 'test/**'")
    print("           so the production graph is still checked. Tail of the failing build:")
    for line in (proc.stdout + proc.stderr).strip().splitlines()[-12:]:
        print(f"           {line}")
    retry = build(["--skip", "test/**"])
    if retry.returncode != 0:
        raise GateError(f"forge build failed even with tests skipped:\n{retry.stdout}\n{retry.stderr}")
    return False


def load_build_info(build_info_dir: Path) -> dict[str, SourceUnit]:
    """Merge every full build-info JSON in ``build_info_dir`` into one path -> SourceUnit map."""
    if not build_info_dir.is_dir():
        raise GateError(
            f"no build-info directory at {build_info_dir}. Run with --build, or run "
            f"`forge build --build-info` in contracts/ first."
        )

    files = sorted(build_info_dir.glob("*.json"))
    if not files:
        raise GateError(f"{build_info_dir} contains no JSON. Run with --build.")

    units: dict[str, SourceUnit] = {}
    full = 0
    skipped: list[str] = []

    for f in files:
        try:
            with f.open(encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            skipped.append(f"{f.name}: unreadable ({exc})")
            continue

        inputs = data.get("input", {}).get("sources")
        outputs = data.get("output", {}).get("sources")
        if not inputs:
            # Foundry writes a minimal build-info (id + source_id_to_path) unless --build-info
            # was passed. Those cannot be used; say so rather than silently passing.
            skipped.append(f"{f.name}: minimal build-info, no `input.sources` (built without --build-info)")
            continue
        full += 1

        for path, entry in inputs.items():
            content = entry.get("content", "") or ""
            unit = units.get(path)
            if unit is None:
                unit = SourceUnit(path=path, origin=f.name)
                units[path] = unit

            ast = (outputs or {}).get(path, {}).get("ast")
            lic = None
            if isinstance(ast, dict):
                lic = ast.get("license")
                for node in ast.get("nodes", []) or []:
                    if node.get("nodeType") == "ImportDirective":
                        target = node.get("absolutePath")
                        if target:
                            unit.imports.add(target)
            if not lic:
                head = content[:4000]
                m = SPDX_RE.search(head)
                lic = m.group(1).strip() if m else None
            if lic:
                unit.license = lic.strip()

            if not unit.imports and content:
                # No AST (or an AST without imports): fall back to the raw import statements. These
                # are unresolved specifiers, so remapping-relative; resolution happens later.
                unit.imports.update(IMPORT_RE.findall(content))

    if full == 0:
        raise GateError(
            "no usable build-info found. Every file was a minimal build-info; rebuild with "
            "`forge build --build-info` (or pass --build).\n  " + "\n  ".join(skipped)
        )
    if skipped:
        for s in skipped:
            print(f"  note: skipped {s}")
    return units


def resolve_import(specifier: str, importer: str, units: dict[str, SourceUnit]) -> str | None:
    """Best-effort resolution of a raw import specifier to a build-info source path."""
    if specifier in units:
        return specifier
    if specifier.startswith("."):
        base = Path(importer).parent
        cand = os.path.normpath(str(base / specifier))
        if cand in units:
            return cand
    # Remapped specifier: match on suffix, longest first, to avoid `IERC20.sol` matching wildly.
    tail = specifier.lstrip("./")
    matches = [p for p in units if p.endswith("/" + tail) or p == tail]
    if len(matches) == 1:
        return matches[0]
    if matches:
        return min(matches, key=len)
    return None


def reachable_from(roots: list[str], units: dict[str, SourceUnit]) -> set[str]:
    seen: set[str] = set()
    stack = list(roots)
    while stack:
        cur = stack.pop()
        if cur in seen:
            continue
        seen.add(cur)
        unit = units.get(cur)
        if unit is None:
            continue
        for spec in unit.imports:
            target = resolve_import(spec, cur, units)
            if target and target not in seen:
                stack.append(target)
    return seen


# --------------------------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------------------------


def table(rows: list[tuple[str, ...]], headers: tuple[str, ...]) -> str:
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    sep = "  ".join("-" * w for w in widths)
    out = ["  ".join(h.ljust(widths[i]) for i, h in enumerate(headers)), sep]
    for row in rows:
        out.append("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)))
    return "\n".join(out)


def summarise(paths: set[str], units: dict[str, SourceUnit]) -> list[tuple[str, ...]]:
    counts: dict[str, int] = {}
    for p in sorted(paths):
        lic = units[p].license if p in units else NO_LICENSE
        counts[lic] = counts.get(lic, 0) + 1
    rows = []
    for lic, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        forbidden, _ = classify(lic)
        mark = "FORBIDDEN" if forbidden else ("ok" if is_recognised(lic) else "unrecognised")
        rows.append((lic, str(n), mark))
    return rows


def main(argv: list[str] | None = None) -> int:
    repo_root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(
        prog="licence-gate.py",
        description="Fail if any source reachable from contracts/src/** is BUSL/AGPL/GPL or lacks an SPDX header.",
    )
    ap.add_argument(
        "--contracts",
        default=str(repo_root / "contracts"),
        help="Foundry project directory (default: <repo>/contracts)",
    )
    ap.add_argument(
        "--out",
        default="out",
        help="Artifacts directory relative to --contracts, i.e. FOUNDRY_OUT (default: out). "
        "Use e.g. --out out-mono when another process owns out/.",
    )
    ap.add_argument(
        "--cache",
        default=None,
        help="FOUNDRY_CACHE_PATH to use with --build (default: Foundry's own). Pair with --out.",
    )
    ap.add_argument("--build", action="store_true", help="Run `forge build --build-info` before reading artifacts.")
    ap.add_argument(
        "--no-build",
        action="store_true",
        help="Never invoke forge. Without this, a missing or minimal build-info triggers one "
        "`forge build --build-info` into --out and a retry, so the gate works from a clean checkout.",
    )
    ap.add_argument("--json", dest="json_out", default=None, help="Write a machine-readable report here.")
    ap.add_argument("--quiet", action="store_true", help="Only print the summary tables and the verdict.")
    args = ap.parse_args(argv)

    contracts = Path(args.contracts).resolve()
    if not contracts.is_dir():
        print(f"licence-gate: no such directory: {contracts}", file=sys.stderr)
        return 2

    print("Amplestocks licence gate")
    print(f"  project     {contracts}")
    print(f"  artifacts   {args.out}")
    print(f"  forbidden   {', '.join(FORBIDDEN_PREFIXES)} and any file without an SPDX header")
    print()

    tests_included = True
    try:
        if args.build:
            tests_included = run_forge_build(contracts, args.out, args.cache)
        try:
            units = load_build_info(contracts / args.out / "build-info")
        except GateError as exc:
            # Foundry writes a *minimal* build-info unless `--build-info` was passed, so a plain
            # `forge build` in CI leaves nothing this gate can read. Build once and retry rather
            # than failing on a technicality.
            if args.build or args.no_build:
                raise
            print(f"  note: {exc}")
            print("  note: building once with --build-info and retrying")
            tests_included = run_forge_build(contracts, args.out, args.cache)
            units = load_build_info(contracts / args.out / "build-info")
    except GateError as exc:
        print(f"licence-gate: {exc}", file=sys.stderr)
        return 2

    src_roots = sorted(p for p in units if p.startswith("src/"))
    test_roots = sorted(p for p in units if p.startswith("test/"))
    script_roots = sorted(p for p in units if p.startswith("script/"))

    production = reachable_from(src_roots, units)
    exempt_roots = test_roots + script_roots
    exempt = reachable_from(exempt_roots, units) - production

    print(f"  compiled units          {len(units)}")
    print(f"  src/ roots              {len(src_roots)}")
    print(f"  production-reachable    {len(production)}")
    print(f"  test/ + script/ roots   {len(exempt_roots)}")
    print(f"  exempt-only reachable   {len(exempt)}")
    print()

    violations: list[tuple[str, str, str]] = []
    for p in sorted(production):
        lic = units[p].license if p in units else NO_LICENSE
        forbidden, reason = classify(lic)
        if forbidden:
            violations.append((p, lic, reason))

    exempt_forbidden: list[tuple[str, str, str]] = []
    for p in sorted(exempt):
        lic = units[p].license if p in units else NO_LICENSE
        forbidden, reason = classify(lic)
        if forbidden:
            exempt_forbidden.append((p, lic, reason))

    if src_roots:
        print("Production graph (reachable from contracts/src/**)")
        print(table(summarise(production, units), ("SPDX", "files", "verdict")))
    else:
        print("Production graph (reachable from contracts/src/**)")
        print("  contracts/src is empty -- nothing to check. The gate passes trivially.")
        print("  This is expected at Phase 1 and stops being true the moment Amps.sol lands.")
    print()

    print("Exempt graph (reachable only from contracts/test/** or contracts/script/**)")
    if not tests_included:
        print("  INCOMPLETE: contracts/test/** was skipped because it does not compile.")
    if exempt:
        print(table(summarise(exempt, units), ("SPDX", "files", "verdict")))
    else:
        print("  (nothing)")
    print()

    if exempt_forbidden and not args.quiet:
        print(f"Copyleft / source-available files in the exempt graph ({len(exempt_forbidden)}) -- allowed, reported:")
        for p, lic, _ in exempt_forbidden:
            print(f"  {lic:<12} {p}")
        print()

    if args.json_out:
        report = {
            "contracts": str(contracts),
            "out": args.out,
            "counts": {
                "units": len(units),
                "src_roots": len(src_roots),
                "production": len(production),
                "exempt": len(exempt),
            },
            "violations": [{"path": p, "license": lic, "reason": r} for p, lic, r in violations],
            "exempt_forbidden": [{"path": p, "license": lic} for p, lic, _ in exempt_forbidden],
            "production_files": {p: units[p].license for p in sorted(production)},
        }
        Path(args.json_out).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"  wrote {args.json_out}")
        print()

    if violations:
        print(f"FAIL: {len(violations)} production-reachable file(s) violate the licence policy:")
        for p, lic, reason in violations:
            print(f"  {lic:<12} {p}   ({reason})")
        print()
        print("Fix by removing the import from contracts/src/**, or by moving the dependency behind")
        print("an interface. If the file is ours, add `// SPDX-License-Identifier: MIT` to it.")
        return 1

    print("PASS: no BUSL/AGPL/GPL and no missing SPDX header in the production import graph.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
