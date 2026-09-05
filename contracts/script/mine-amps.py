#!/usr/bin/env python3
"""Mine a CREATE2 salt that puts Amps at an address with N leading zero bytes.

AMPS must be `currency0` in every Amplestocks pool, i.e. it must sort below WETH9
(0x0Bd7...) and every Robinhood Stock Token. Three leading zero bytes
(address < 0x0000010000000000000000000000000000000000) clears all of them with room to spare.

The deployer is the canonical deterministic-deployment proxy
0x4e59b44847b379578588920cA78FbF26c0B4956C, which prepends nothing: it CREATE2s from its own
address with the first 32 bytes of calldata as the salt. So

    address = keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]
    initCode = type(Amps).creationCode ++ abi.encode(vault)

Usage
-----
    # from contracts/, after `FOUNDRY_OUT=out-token FOUNDRY_CACHE_PATH=cache-token forge build`
    python3 script/mine-amps.py --vault 0x000000000000000000000000000000000000dEaD \
        --out script/config/amps-mining-example.json

    # or mine against a hash you already have
    python3 script/mine-amps.py --init-code-hash 0x1234...

Equivalent Foundry one-liner (Rust, much faster; use it when you have `cast`):

    cast create2 --starts-with 000000 \
        --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C \
        --init-code-hash <hash>

Requires pycryptodome (`pip install pycryptodome`).

The salt is only valid for one exact init code: changing Amps.sol, the constructor argument, the
solc version, the optimizer settings or `bytecode_hash`/`cbor_metadata` changes the hash and
invalidates the salt. Re-mine after any of those.
"""

from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import os
import secrets
import sys
import time
from datetime import datetime, timezone
from queue import Empty as queue_empty

try:
    from Crypto.Hash import keccak as _keccak
except ImportError:  # pragma: no cover - dependency hint only
    sys.exit("pycryptodome is required: pip install pycryptodome")

CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
PLACEHOLDER_VAULT = "0x000000000000000000000000000000000000dEaD"
DEFAULT_ARTIFACT = "out-token/Amps.sol/Amps.json"
REPORT_EVERY = 1 << 18


def keccak256(data: bytes) -> bytes:
    return _keccak.new(digest_bits=256, data=data).digest()


def to_checksum(addr: bytes) -> str:
    """EIP-55 checksum of a 20-byte address."""
    lower = addr.hex()
    digest = keccak256(lower.encode()).hex()
    out = "".join(c.upper() if c.isalpha() and int(digest[i], 16) >= 8 else c for i, c in enumerate(lower))
    return "0x" + out


def abi_encode_address(addr: str) -> bytes:
    return bytes(12) + bytes.fromhex(addr.removeprefix("0x"))


def init_code_hash_from_artifact(path: str, vault: str) -> tuple[bytes, int]:
    with open(path, "r", encoding="utf-8") as fh:
        artifact = json.load(fh)
    creation = artifact["bytecode"]["object"]
    code = bytes.fromhex(creation.removeprefix("0x"))
    init_code = code + abi_encode_address(vault)
    return keccak256(init_code), len(init_code)


def _worker(queue, prefix: bytes, suffix: bytes, zero_bytes: int, found, counter, lock) -> None:
    """Grind salts of the form <16 random bytes><16 byte counter> until the address matches."""
    seed = secrets.token_bytes(16)
    head = prefix + seed
    zeros = bytes(zero_bytes)
    local = 0
    i = 0
    while not found.is_set():
        tail = i.to_bytes(16, "big")
        if keccak256(head + tail + suffix)[12 : 12 + zero_bytes] == zeros:
            with lock:
                counter.value += local + 1
            found.set()
            queue.put(seed + tail)
            return
        i += 1
        local += 1
        if local % REPORT_EVERY == 0:
            with lock:
                counter.value += REPORT_EVERY
            local = 0
    with lock:
        counter.value += local


def mine(init_hash: bytes, factory: str, zero_bytes: int, processes: int) -> tuple[bytes, bytes, int, float]:
    prefix = b"\xff" + bytes.fromhex(factory.removeprefix("0x"))
    ctx = mp.get_context("fork" if sys.platform != "win32" else "spawn")
    found = ctx.Event()
    counter = ctx.Value("Q", 0)
    lock = ctx.Lock()
    queue = ctx.Queue()

    started = time.time()
    workers = [
        ctx.Process(target=_worker, args=(queue, prefix, init_hash, zero_bytes, found, counter, lock), daemon=True)
        for _ in range(processes)
    ]
    for w in workers:
        w.start()

    salt = None
    while salt is None:
        try:
            salt = queue.get(timeout=2.0)
        except queue_empty:
            elapsed = time.time() - started
            with lock:
                tried = counter.value
            rate = tried / elapsed if elapsed > 0 else 0.0
            print(f"  ... {tried:,} salts in {elapsed:6.1f}s ({rate:,.0f}/s)", file=sys.stderr, flush=True)
            if all(not w.is_alive() for w in workers):
                raise SystemExit("all workers exited without a result")

    elapsed = time.time() - started
    for w in workers:
        w.join(timeout=1.0)
        if w.is_alive():
            w.terminate()
    with lock:
        attempts = counter.value
    address = keccak256(prefix + salt + init_hash)[12:]
    return salt, address, attempts, elapsed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--artifact", default=DEFAULT_ARTIFACT, help=f"forge artifact (default {DEFAULT_ARTIFACT})")
    ap.add_argument("--init-code-hash", help="skip the artifact and mine this init code hash directly")
    ap.add_argument("--vault", default=PLACEHOLDER_VAULT, help="constructor argument (default: dEaD placeholder)")
    ap.add_argument("--factory", default=CREATE2_FACTORY, help="CREATE2 deployer")
    ap.add_argument("--zero-bytes", type=int, default=3, help="required leading zero bytes (default 3)")
    ap.add_argument("--processes", type=int, default=os.cpu_count() or 1, help="worker processes")
    ap.add_argument("--out", help="write the result as JSON to this path")
    args = ap.parse_args()

    if args.init_code_hash:
        init_hash = bytes.fromhex(args.init_code_hash.removeprefix("0x"))
        init_len = None
        if len(init_hash) != 32:
            return ap.error("--init-code-hash must be 32 bytes")
    else:
        init_hash, init_len = init_code_hash_from_artifact(args.artifact, args.vault)

    print(f"factory        {args.factory}")
    print(f"vault          {args.vault}")
    print(f"init code hash 0x{init_hash.hex()}" + (f"  ({init_len} bytes of init code)" if init_len else ""))
    print(f"target         {args.zero_bytes} leading zero bytes on {args.processes} processes")
    print(f"cast create2 --starts-with {'00' * args.zero_bytes} --deployer {args.factory} "
          f"--init-code-hash 0x{init_hash.hex()}")

    salt, address, attempts, elapsed = mine(init_hash, args.factory, args.zero_bytes, args.processes)
    checksummed = to_checksum(address)
    rate = attempts / elapsed if elapsed > 0 else 0.0
    print(f"\nsalt      0x{salt.hex()}")
    print(f"address   {checksummed}")
    print(f"attempts  {attempts:,} in {elapsed:.1f}s ({rate:,.0f} salts/s)")

    if args.out:
        record = {
            "note": (
                "Mined against a PLACEHOLDER vault. The salt is bound to this exact init code hash: re-mine "
                "with the real AmpsVault address (and after any Amps.sol or compiler-setting change) before "
                "deploying. Regenerate with script/mine-amps.py, verify with script/01_MineAmps.s.sol."
            ),
            "factory": args.factory,
            "vault": args.vault,
            "vaultIsPlaceholder": args.vault.lower() == PLACEHOLDER_VAULT.lower(),
            "initCodeHash": "0x" + init_hash.hex(),
            "salt": "0x" + salt.hex(),
            "predictedAddress": checksummed,
            "leadingZeroBytes": args.zero_bytes,
            "attempts": attempts,
            "saltsPerSecond": int(rate),
            "minedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "compiler": {
                "solc": "0.8.30",
                "optimizer": True,
                "optimizerRuns": 1000000,
                "viaIr": False,
                "evmVersion": "cancun",
                "bytecodeHash": "none",
                "cborMetadata": False,
            },
        }
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(record, fh, indent=2)
            fh.write("\n")
        print(f"wrote     {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
