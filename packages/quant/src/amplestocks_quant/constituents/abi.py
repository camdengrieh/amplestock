# SPDX-License-Identifier: MIT
"""Minimal ABI codec and a pure-Python Keccak-256.

The constituent pipeline talks to chain 4663 over raw JSON-RPC, so it needs exactly three things
from an ABI library: event topic hashes, function selectors, and static word decoding. Pulling in
`web3`/`eth-abi` for that would add a compiled dependency tree to a package whose only current
dependencies are numpy and pandas, so the ~120 lines live here instead.

`hashlib.sha3_256` is **NIST SHA-3**, not the Keccak-256 Ethereum uses (the padding differs), so
the permutation is implemented here and checked against published vectors in
`tests/test_abi.py` — including the well-known `Transfer(address,address,uint256)` topic.

Everything is little-endian-lane Keccak-f[1600] with rate 136 and the original `0x01 … 0x80`
padding.
"""

from __future__ import annotations

# ------------------------------------------------------------------------------------------------
# Keccak-256
# ------------------------------------------------------------------------------------------------

_MASK64 = (1 << 64) - 1
_RATE_BYTES = 136

#: Keccak-f[1600] round constants.
_ROUND_CONSTANTS: tuple[int, ...] = (
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
)

#: Rho rotation offsets, indexed `[x][y]`.
_ROTATIONS: tuple[tuple[int, ...], ...] = (
    (0, 36, 3, 41, 18),
    (1, 44, 10, 45, 2),
    (62, 6, 43, 15, 61),
    (28, 55, 25, 21, 56),
    (27, 20, 39, 8, 14),
)


def _rotl64(value: int, shift: int) -> int:
    """Rotate a 64-bit lane left by `shift`."""
    shift %= 64
    return ((value << shift) | (value >> (64 - shift))) & _MASK64


def _keccak_f1600(lanes: list[int]) -> None:
    """In-place Keccak-f[1600] over 25 lanes indexed `x + 5*y`."""
    for rnd in range(24):
        # theta
        c = [lanes[x] ^ lanes[x + 5] ^ lanes[x + 10] ^ lanes[x + 15] ^ lanes[x + 20] for x in range(5)]
        d = [c[(x + 4) % 5] ^ _rotl64(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(0, 25, 5):
                lanes[x + y] ^= d[x]
        # rho + pi
        b = [0] * 25
        for x in range(5):
            for y in range(5):
                b[y + 5 * ((2 * x + 3 * y) % 5)] = _rotl64(lanes[x + 5 * y], _ROTATIONS[x][y])
        # chi
        for y in range(0, 25, 5):
            for x in range(5):
                lanes[x + y] = b[x + y] ^ ((~b[(x + 1) % 5 + y]) & b[(x + 2) % 5 + y]) & _MASK64
        # iota
        lanes[0] ^= _ROUND_CONSTANTS[rnd]


def keccak256(data: bytes) -> bytes:
    """Keccak-256 (Ethereum's hash, *not* NIST SHA-3) of `data`."""
    lanes = [0] * 25
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % _RATE_BYTES != 0:
        padded.append(0x00)
    padded[-1] ^= 0x80

    for offset in range(0, len(padded), _RATE_BYTES):
        block = padded[offset:offset + _RATE_BYTES]
        for i in range(_RATE_BYTES // 8):
            lanes[i] ^= int.from_bytes(block[i * 8:i * 8 + 8], "little")
        _keccak_f1600(lanes)

    out = bytearray()
    for i in range(4):  # 32 bytes = 4 lanes, all inside the rate
        out += lanes[i].to_bytes(8, "little")
    return bytes(out)


def event_topic(signature: str) -> str:
    """`0x`-prefixed topic0 for a canonical event signature, e.g. `Swap(bytes32,address,...)`."""
    return "0x" + keccak256(signature.encode()).hex()


def selector(signature: str) -> str:
    """`0x`-prefixed 4-byte function selector for a canonical signature."""
    return "0x" + keccak256(signature.encode()).hex()[:8]


# ------------------------------------------------------------------------------------------------
# Word decoding
# ------------------------------------------------------------------------------------------------


def checksum_address(value: str) -> str:
    """EIP-55 checksummed address.

    The repo's address book is checksummed, so the writers emit checksummed addresses too; every
    comparison in this package is still case-insensitive.
    """
    raw = strip0x(value).lower().rjust(40, "0")[-40:]
    digest = keccak256(raw.encode()).hex()
    out = "".join(char.upper() if int(digest[i], 16) >= 8 else char for i, char in enumerate(raw))
    return "0x" + out


def strip0x(value: str) -> str:
    """`value` without a leading `0x`."""
    return value[2:] if value.startswith(("0x", "0X")) else value


def to_bytes(value: str | bytes) -> bytes:
    """Hex string or bytes to bytes."""
    if isinstance(value, bytes):
        return value
    raw = strip0x(value)
    if len(raw) % 2:
        raw = "0" + raw
    return bytes.fromhex(raw)


def words(data: str | bytes) -> list[bytes]:
    """Split ABI-encoded return data into 32-byte words (a trailing partial word is dropped)."""
    raw = to_bytes(data)
    return [raw[i:i + 32] for i in range(0, len(raw) - len(raw) % 32, 32)]


def decode_uint(word: bytes | str) -> int:
    """Decode one 32-byte word as `uintN`."""
    return int.from_bytes(to_bytes(word), "big")


def decode_int(word: bytes | str, bits: int = 256) -> int:
    """Decode one 32-byte word as a two's-complement `intN`."""
    value = decode_uint(word)
    limit = 1 << (bits - 1)
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >= limit else value


def decode_address(word: bytes | str) -> str:
    """Decode one 32-byte word as a lowercase `0x`-prefixed address."""
    return "0x" + to_bytes(word)[-20:].hex()


def decode_bool(word: bytes | str) -> bool:
    """Decode one 32-byte word as `bool`."""
    return decode_uint(word) != 0


def decode_string(data: str | bytes) -> str:
    """Decode ABI-encoded `string`/`bytes` return data (offset, length, payload)."""
    raw = to_bytes(data)
    if len(raw) < 64:
        # Some tokens return a right-padded bytes32 instead of a dynamic string.
        return raw.rstrip(b"\x00").decode("utf-8", "replace")
    offset = int.from_bytes(raw[0:32], "big")
    if offset + 32 > len(raw):
        return raw.rstrip(b"\x00").decode("utf-8", "replace")
    length = int.from_bytes(raw[offset:offset + 32], "big")
    payload = raw[offset + 32:offset + 32 + length]
    return payload.decode("utf-8", "replace")


def encode_uint(value: int) -> str:
    """Encode an integer as one hex word, no `0x`."""
    return f"{value & ((1 << 256) - 1):064x}"


def encode_address(value: str) -> str:
    """Encode an address as one hex word, no `0x`."""
    return f"{int(strip0x(value), 16):064x}"


def encode_bytes32(value: str) -> str:
    """Encode a 32-byte id as one hex word, no `0x`."""
    return strip0x(value).rjust(64, "0")


def call_data(signature: str, *args: str | int) -> str:
    """`0x`-prefixed calldata for a signature whose arguments are all static words."""
    encoded = []
    for arg in args:
        if isinstance(arg, int):
            encoded.append(encode_uint(arg))
        elif len(strip0x(arg)) == 40:
            encoded.append(encode_address(arg))
        else:
            encoded.append(encode_bytes32(arg))
    return selector(signature) + "".join(encoded)
