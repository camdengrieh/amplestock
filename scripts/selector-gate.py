#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Amplestocks external-mutating-selector gate.

Step 1 of the I14 enumeration proof (`docs/phase2-state-model.md` §7). The Solidity half of the
proof lives in `contracts/test/unit/GuardSymmetry.t.sol`: it holds one classification entry per
external state-changing selector of `AmpsVault` and of `AmpsBonds`, asserts the counts, asserts the
entries are distinct, and drills the refusals. What Solidity *cannot* do is check that list against
the contract it is meant to describe -- `ffi` is off and `fs_permissions` does not cover the
artifact directories -- so a function can be added to either contract and simply never appear in
the table.

This script closes that hole. It reads the compiled ABI, lists every non-`view`/non-`pure`
function, and fails if any of them is missing from the classification tables. An unclassified
selector is a function nobody decided how to guard, which is exactly the mistake the enumeration
exists to make impossible.

Both directions are reported, but only one of them fails the build:

    unclassified   in the ABI, not in the table   -> exit 1. A new function nobody classified.
    stale          in the table, not in the ABI   -> warning. A renamed or removed function; it
                                                    makes the table lie but it cannot let an
                                                    unguarded selector through, and the Solidity
                                                    count assertions catch it on the next run.

Usage
-----
    python3 scripts/selector-gate.py                       # contracts/out-recon, else contracts/out
    python3 scripts/selector-gate.py --out contracts/out   # an explicit artifacts directory
    python3 scripts/selector-gate.py --json report.json    # also write a machine-readable report

`--out` is a plain path, resolved against the current directory (unlike `licence-gate.py`'s
`--out`, which is relative to `--contracts`). Run it from the repository root.

Exit codes
----------
    0  every mutating selector of both contracts is classified
    1  at least one mutating selector is unclassified
    2  the gate could not run (no artifacts, no classification file, malformed input)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# --------------------------------------------------------------------------------------------
# What is gated, and where the classification lives
# --------------------------------------------------------------------------------------------

#: The classification file, relative to the repository root.
GUARD_SYMMETRY = Path("contracts/test/unit/GuardSymmetry.t.sol")

#: Artifact directories tried in order when `--out` is not given. `out-recon` is the scratch
#: profile the reconciliation work uses; `out` is what a plain `forge build` writes in CI.
DEFAULT_OUT_DIRS: tuple[str, ...] = ("contracts/out-recon", "contracts/out")

#: `_add("<name>", ...)` inside `_buildSelectorTable`: the vault's classification table.
VAULT_ENTRY_RE = re.compile(r"""_add\(\s*"([A-Za-z_][A-Za-z0-9_]*)\"""")

#: The marker block holding the `AmpsBonds` classification arrays.
BONDS_BLOCK_RE = re.compile(
    r"//\s*selector-gate:AmpsBonds:begin(.*?)//\s*selector-gate:AmpsBonds:end",
    re.DOTALL,
)

#: A bare identifier string literal, used to read names out of the `AmpsBonds` marker block.
IDENTIFIER_LITERAL_RE = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*)"')

#: Solidity state mutabilities that mean "this function cannot change state".
READ_ONLY = ("view", "pure")


class GateError(Exception):
    """The gate could not run at all, as distinct from finding a violation."""


# --------------------------------------------------------------------------------------------
# Reading the compiled ABI
# --------------------------------------------------------------------------------------------


def artifact_path(out_dir: Path, contract: str) -> Path:
    """The Foundry artifact for `contract`, which lives at `<out>/<Name>.sol/<Name>.json`."""
    return out_dir / f"{contract}.sol" / f"{contract}.json"


def mutating_selectors(out_dir: Path, contract: str) -> dict[str, str]:
    """Every non-view/non-pure function of `contract`, as `{name: "selector signature"}`.

    Selectors come from the artifact's own `methodIdentifiers` map rather than being recomputed,
    so this script needs no keccak implementation and can never disagree with solc about a
    canonical signature. A function with no entry there (an unlikely artifact shape) is reported
    with an unknown selector rather than skipped: the name is what the classification is keyed on.
    """
    path = artifact_path(out_dir, contract)
    if not path.is_file():
        raise GateError(f"no artifact for {contract}: {path} (run `forge build` first)")
    try:
        artifact = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:  # pragma: no cover - a corrupt artifact is a build problem
        raise GateError(f"{path} is not valid JSON: {exc}") from exc

    abi = artifact.get("abi")
    if not isinstance(abi, list):
        raise GateError(f"{path} has no ABI array")
    identifiers = artifact.get("methodIdentifiers") or {}

    found: dict[str, str] = {}
    for entry in abi:
        if entry.get("type") != "function":
            continue
        if entry.get("stateMutability") in READ_ONLY:
            continue
        name = entry.get("name")
        if not name:
            continue
        signature = canonical_signature(entry)
        selector = identifiers.get(signature)
        found[name] = f"0x{selector} {signature}" if selector else f"?????????? {signature}"
    return found


def canonical_signature(entry: dict) -> str:
    """`name(type,type)` for one ABI function entry, with tuples expanded the way solc expands them."""
    return f"{entry['name']}({','.join(abi_type(i) for i in entry.get('inputs', []))})"


def abi_type(component: dict) -> str:
    """One ABI parameter type, expanding `tuple` and `tuple[]` into their component list."""
    kind = component.get("type", "")
    if not kind.startswith("tuple"):
        return kind
    inner = ",".join(abi_type(c) for c in component.get("components", []))
    return f"({inner}){kind[len('tuple'):]}"


# --------------------------------------------------------------------------------------------
# Reading the classification
# --------------------------------------------------------------------------------------------


def read_classification(path: Path) -> dict[str, set[str]]:
    """The classified names per contract, parsed out of `GuardSymmetry.t.sol`.

    `AmpsVault`'s table is the `_add("name", ...)` call list, which is the same text the Solidity
    test iterates, so the two can never drift. `AmpsBonds`'s is the string-array block between the
    `selector-gate:AmpsBonds` markers.
    """
    if not path.is_file():
        raise GateError(f"no classification file: {path}")
    source = path.read_text(encoding="utf-8")

    vault = set(VAULT_ENTRY_RE.findall(source))
    if not vault:
        raise GateError(f"{path} contains no `_add(\"...\")` entries; the vault table has moved")

    block = BONDS_BLOCK_RE.search(source)
    if block is None:
        raise GateError(f"{path} has no `selector-gate:AmpsBonds:begin/end` block")
    bonds = set(IDENTIFIER_LITERAL_RE.findall(block.group(1)))
    if not bonds:
        raise GateError(f"{path}'s AmpsBonds block contains no names")

    return {"AmpsVault": vault, "AmpsBonds": bonds}


# --------------------------------------------------------------------------------------------
# The gate
# --------------------------------------------------------------------------------------------


def resolve_out_dir(explicit: str | None, repo_root: Path) -> Path:
    """The artifacts directory: `--out` if given, else the first default that exists."""
    if explicit:
        candidate = Path(explicit)
        if not candidate.is_absolute():
            candidate = Path.cwd() / candidate
        if not candidate.is_dir():
            raise GateError(f"no such artifacts directory: {candidate}")
        return candidate
    for name in DEFAULT_OUT_DIRS:
        candidate = repo_root / name
        if candidate.is_dir():
            return candidate
    raise GateError(
        "no artifacts directory found; tried "
        + ", ".join(str(repo_root / n) for n in DEFAULT_OUT_DIRS)
        + " (run `forge build` first, or pass --out)"
    )


def main(argv: list[str] | None = None) -> int:
    repo_root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(
        prog="selector-gate.py",
        description=(
            "Fail if any external state-changing selector of AmpsVault or AmpsBonds is missing from the "
            "I14 classification tables in contracts/test/unit/GuardSymmetry.t.sol."
        ),
    )
    ap.add_argument(
        "--out",
        default=None,
        help=(
            "Foundry artifacts directory, as a plain path from the current directory "
            f"(default: the first of {', '.join(DEFAULT_OUT_DIRS)} that exists)."
        ),
    )
    ap.add_argument(
        "--guard-symmetry",
        default=None,
        help=f"The classification file (default: <repo>/{GUARD_SYMMETRY}).",
    )
    ap.add_argument("--json", dest="json_out", default=None, help="Write a machine-readable report here.")
    ap.add_argument("--quiet", action="store_true", help="Only print the verdict and any violations.")
    args = ap.parse_args(argv)

    try:
        out_dir = resolve_out_dir(args.out, repo_root)
        classification_path = Path(args.guard_symmetry) if args.guard_symmetry else repo_root / GUARD_SYMMETRY
        classified = read_classification(classification_path)
        abis = {name: mutating_selectors(out_dir, name) for name in classified}
    except GateError as exc:
        print(f"selector-gate: {exc}", file=sys.stderr)
        return 2

    print("Amplestocks selector gate")
    print(f"  artifacts        {out_dir}")
    print(f"  classification   {classification_path}")
    print()

    unclassified: dict[str, list[str]] = {}
    stale: dict[str, list[str]] = {}
    report: dict[str, dict] = {}

    for contract, found in abis.items():
        expected = classified[contract]
        missing = sorted(name for name in found if name not in expected)
        extra = sorted(name for name in expected if name not in found)
        if missing:
            unclassified[contract] = missing
        if extra:
            stale[contract] = extra
        report[contract] = {
            "mutating": {name: found[name] for name in sorted(found)},
            "classified": sorted(expected),
            "unclassified": missing,
            "stale": extra,
        }

        print(f"  {contract}: {len(found)} external mutating selectors, {len(expected)} classified")
        if not args.quiet:
            for name in sorted(found):
                mark = "UNCLASSIFIED" if name in missing else "ok"
                print(f"      {found[name]:<58} {mark}")
        print()

    for contract, names in stale.items():
        print(f"  warning: {contract} classifies {len(names)} name(s) that are not in the ABI: {', '.join(names)}")

    if unclassified:
        print()
        for contract, names in unclassified.items():
            print(f"selector-gate: {contract} has unclassified mutating selectors:", file=sys.stderr)
            for name in names:
                print(f"    {abis[contract][name]}", file=sys.stderr)
        print(
            "selector-gate: classify each one in contracts/test/unit/GuardSymmetry.t.sol "
            "(the vault's `_buildSelectorTable`, or the `selector-gate:AmpsBonds` block) and update the "
            "count assertions alongside it.",
            file=sys.stderr,
        )
        verdict = 1
    else:
        print("  VERDICT: every external mutating selector is classified.")
        verdict = 0

    if args.json_out:
        Path(args.json_out).write_text(
            json.dumps({"out": str(out_dir), "contracts": report, "ok": verdict == 0}, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"  wrote {args.json_out}")

    return verdict


if __name__ == "__main__":
    sys.exit(main())
