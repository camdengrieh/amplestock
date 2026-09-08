# SPDX-License-Identifier: MIT
"""Keccak-256, event topics, selectors and word decoding.

The topic constants are the load-bearing part: if `keccak256` were subtly wrong, every
`eth_getLogs` filter in the package would silently match nothing and every run would report an
empty chain. These are the published Uniswap v3/v4 topic hashes.
"""

from __future__ import annotations

from amplestocks_quant.constituents import abi
from amplestocks_quant.constituents.chain import (
    V3_POOL_CREATED_TOPIC,
    V3_SWAP_TOPIC,
    V4_INITIALIZE_TOPIC,
    V4_SWAP_TOPIC,
)


def test_keccak_known_vectors() -> None:
    assert abi.keccak256(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    assert (
        abi.keccak256(b"abc").hex()
        == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
    )
    # Multi-block input: 200 bytes crosses the 136-byte rate.
    assert len(abi.keccak256(b"x" * 200)) == 32


def test_known_ethereum_topics_and_selectors() -> None:
    assert (
        abi.event_topic("Transfer(address,address,uint256)")
        == "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    )
    assert abi.selector("transfer(address,uint256)") == "0xa9059cbb"
    assert abi.selector("balanceOf(address)") == "0x70a08231"


def test_uniswap_topics_match_published_values() -> None:
    assert V4_INITIALIZE_TOPIC == "0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438"
    assert V4_SWAP_TOPIC == "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
    assert V3_POOL_CREATED_TOPIC == "0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118"
    assert V3_SWAP_TOPIC == "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"


def test_checksum_address_eip55_vectors() -> None:
    assert abi.checksum_address("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed") == (
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
    )
    assert abi.checksum_address("0xFB6916095CA1DF60BB79CE92CE3EA74C37C5D359") == (
        "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
    )


def test_decode_words() -> None:
    assert abi.decode_uint("0x" + "00" * 31 + "12") == 0x12
    assert abi.decode_int("0x" + "ff" * 32, 256) == -1
    # int128 negative, sign-extended into a 256-bit word the way solidity encodes it.
    assert abi.decode_int("0x" + "ff" * 32, 128) == -1
    assert abi.decode_address("0x" + "00" * 12 + "aa" * 20) == "0x" + "aa" * 20
    assert abi.decode_bool("0x" + "00" * 31 + "01") is True


def test_decode_string_dynamic_and_bytes32() -> None:
    encoded = "0x" + abi.encode_uint(32) + abi.encode_uint(4) + b"AAPL".hex().ljust(64, "0")
    assert abi.decode_string(encoded) == "AAPL"
    assert abi.decode_string("0x" + b"GME".hex().ljust(64, "0")) == "GME"


def test_call_data_encodes_static_arguments() -> None:
    pool_id = "0x" + "ab" * 32
    data = abi.call_data("getSlot0(bytes32)", pool_id)
    assert data.startswith(abi.selector("getSlot0(bytes32)"))
    assert data.endswith("ab" * 32)
    with_address = abi.call_data("feedOf(address)", "0x" + "cd" * 20)
    assert with_address.endswith("cd" * 20)
    assert len(abi.strip0x(with_address)) == 8 + 64
