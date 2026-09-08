# SPDX-License-Identifier: MIT
"""The fixture transport and the JSON-RPC client.

These two are the reason the rest of the suite can run with no network, so they are tested against
the same cassette the `--fixtures` run replays, plus hand-built stubs for the failure paths a real
endpoint produces (range caps, batch refusal, reverts).
"""

from __future__ import annotations

import pytest

from amplestocks_quant.constituents.chain import V4_SWAP_TOPIC
from amplestocks_quant.constituents.rpc import JsonRpc, RpcError, describe_window, load_endpoints
from amplestocks_quant.constituents.transport import FixtureTransport, TransportError

URL = "https://fixture.invalid"


def rpc_for(transport) -> JsonRpc:
    return JsonRpc(transport=transport, endpoints=(URL,))


# ------------------------------------------------------------------------------------------------
# FixtureTransport
# ------------------------------------------------------------------------------------------------


def test_cassette_is_labelled_synthetic(cassette: dict) -> None:
    assert cassette["synthetic"] is True
    assert "SYNTHETIC" in cassette["$comment"]
    assert cassette["generator"].endswith("generate_fixtures.py")


def test_block_headers_are_synthesised_consistently(transport: FixtureTransport, cassette: dict) -> None:
    rpc = rpc_for(transport)
    head = rpc.block_number()
    assert head == cassette["chain"]["headBlock"]
    assert rpc.block_timestamp(head) == cassette["chain"]["headTimestamp"]
    # 100 ms blocks: a day back is 864,000 blocks back. The search returns the *first* block of
    # the target second, and ten blocks share each second, so the answer is within one second.
    day_ago = rpc.block_at_timestamp(cassette["chain"]["headTimestamp"] - 86_400, head=head)
    assert abs((head - day_ago) - 864_000) <= 10
    assert rpc.block_timestamp(day_ago) >= cassette["chain"]["headTimestamp"] - 86_400
    assert rpc.block_timestamp(day_ago - 1) < cassette["chain"]["headTimestamp"] - 86_400


def test_get_logs_filters_by_range_and_topic(transport: FixtureTransport) -> None:
    rpc = rpc_for(transport)
    head = rpc.block_number()
    everything = rpc.get_logs(from_block=0, to_block=head, topics=[V4_SWAP_TOPIC], chunk=10_000_000)
    assert everything, "the cassette should hold v4 swaps"
    assert all(log["topics"][0] == V4_SWAP_TOPIC.lower() for log in everything)

    half = rpc.get_logs(
        from_block=head - 7 * 864_000, to_block=head, topics=[V4_SWAP_TOPIC], chunk=10_000_000
    )
    assert 0 < len(half) < len(everything)


def test_chunking_covers_the_range_exactly_once(transport: FixtureTransport) -> None:
    rpc = rpc_for(transport)
    head = rpc.block_number()
    one_shot = rpc.get_logs(from_block=0, to_block=head, topics=[V4_SWAP_TOPIC], chunk=10**9)
    chunked = rpc.get_logs(from_block=0, to_block=head, topics=[V4_SWAP_TOPIC], chunk=1_000_000)
    assert len(one_shot) == len(chunked)


def test_missing_eth_call_reads_as_a_revert_not_a_crash(transport: FixtureTransport) -> None:
    rpc = rpc_for(transport)
    assert rpc.eth_call("0x" + "11" * 20, "0xdeadbeef") is None


def test_unknown_http_url_raises(transport: FixtureTransport) -> None:
    with pytest.raises(TransportError):
        transport.get_json("https://example.invalid/nope")


# ------------------------------------------------------------------------------------------------
# JsonRpc failure paths
# ------------------------------------------------------------------------------------------------


class _RangeCappedTransport:
    """A node that refuses any range wider than `cap` blocks, like most public endpoints."""

    def __init__(self, cap: int) -> None:
        self.cap = cap
        self.widest = 0
        self.calls = 0

    def post_json(self, url, payload, *, headers=None):
        self.calls += 1
        flt = payload["params"][0]
        span = int(flt["toBlock"], 16) - int(flt["fromBlock"], 16) + 1
        self.widest = max(self.widest, span)
        if span > self.cap:
            return {
                "jsonrpc": "2.0",
                "id": payload["id"],
                "error": {"code": -32005, "message": "query returned more than 10000 results"},
            }
        return {"jsonrpc": "2.0", "id": payload["id"], "result": []}

    def get_json(self, url, *, headers=None):  # pragma: no cover - unused
        raise TransportError(url)

    def get_text(self, url, *, headers=None):  # pragma: no cover - unused
        raise TransportError(url)


def test_get_logs_halves_the_range_when_the_node_says_no() -> None:
    node = _RangeCappedTransport(cap=25_000)
    rpc = rpc_for(node)
    rpc.get_logs(from_block=0, to_block=99_999, chunk=100_000)
    assert node.calls > 1
    # It backed off from 100k until the node accepted a span.
    assert node.widest == 100_000


def test_get_logs_reraises_an_error_that_is_not_about_range() -> None:
    class _Broken(_RangeCappedTransport):
        def post_json(self, url, payload, *, headers=None):
            return {
                "jsonrpc": "2.0",
                "id": payload["id"],
                "error": {"code": -32000, "message": "method not supported"},
            }

    with pytest.raises(RpcError):
        rpc_for(_Broken(0)).get_logs(from_block=0, to_block=10, chunk=10)


def test_batch_falls_back_to_sequential_calls_when_batching_is_refused() -> None:
    class _NoBatch:
        def post_json(self, url, payload, *, headers=None):
            if isinstance(payload, list):
                raise TransportError("batch not supported")
            return {"jsonrpc": "2.0", "id": payload["id"], "result": "0x2a"}

        def get_json(self, url, *, headers=None):  # pragma: no cover - unused
            raise TransportError(url)

        def get_text(self, url, *, headers=None):  # pragma: no cover - unused
            raise TransportError(url)

    rpc = rpc_for(_NoBatch())
    assert rpc.batch([("eth_call", []), ("eth_call", [])]) == ["0x2a", "0x2a"]
    assert any("batched requests refused" in w for w in rpc.warnings)


def test_second_endpoint_is_tried_when_the_first_is_down() -> None:
    class _FirstDown:
        def post_json(self, url, payload, *, headers=None):
            if url.endswith("down"):
                raise TransportError("connection refused")
            return {"jsonrpc": "2.0", "id": payload["id"], "result": "0x1"}

        def get_json(self, url, *, headers=None):  # pragma: no cover - unused
            raise TransportError(url)

        def get_text(self, url, *, headers=None):  # pragma: no cover - unused
            raise TransportError(url)

    rpc = JsonRpc(transport=_FirstDown(), endpoints=("https://down", "https://up"))
    assert rpc.block_number() == 1


def test_load_endpoints_deduplicates_and_describe_window_counts_calls() -> None:
    assert load_endpoints("https://a", "https://a") == ("https://a",)
    assert load_endpoints("https://a", None) == ("https://a",)
    assert "2 eth_getLogs" in describe_window(0, 199, 100).replace("~", "")
