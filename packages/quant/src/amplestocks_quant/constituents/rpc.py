# SPDX-License-Identifier: MIT
"""A small JSON-RPC client: batching, chunked `eth_getLogs`, and a block-by-timestamp search.

Chain 4663 produces 100 ms blocks, so a 30-day window is ~25.9 million blocks. Two consequences
shape this module:

1. **`eth_getLogs` must be chunked** and the chunk size must adapt: public endpoints answer with a
   "query returned more than N results" / "block range too large" error rather than a truncated
   page, so `get_logs` halves the range and retries instead of failing the run.
2. **Never derive a window from block arithmetic alone.** `block_at_timestamp` binary-searches real
   headers (~25 requests) and only uses the nominal block time to seed the bounds.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

from .chain import BLOCK_TIME_SECONDS
from .transport import Transport, TransportError

#: Starting `eth_getLogs` span for the swap scan. 100 ms blocks make this ~14 hours of chain; the
#: range halves itself on any endpoint that says no, so starting wide costs nothing but a retry.
DEFAULT_CHUNK_BLOCKS = 500_000
#: Starting span for pool discovery. `Initialize`/`PoolCreated` are rare, so a genesis-to-head scan
#: at 100k blocks a call would be thousands of round trips for a few hundred events.
DEFAULT_DISCOVERY_CHUNK_BLOCKS = 5_000_000
#: Never split below this: a run that needs it is hitting a result cap, not a range cap.
MIN_CHUNK_BLOCKS = 500

#: Endpoint messages that mean "ask for less", not "this failed".
_RANGE_ERRORS = (
    "more than",
    "too large",
    "too many",
    "range",
    "limit exceeded",
    "response size",
    "query timeout",
    "timeout",
)


class RpcError(RuntimeError):
    """The node answered with a JSON-RPC error object."""

    def __init__(self, method: str, message: str, code: int | None = None) -> None:
        super().__init__(f"{method}: {message}")
        self.method = method
        self.message = message
        self.code = code


@dataclass
class JsonRpc:
    """JSON-RPC over a `Transport`, with an optional fallback endpoint.

    `endpoints` is tried in order per request; a request that fails everywhere raises. The counters
    are reported in the run's provenance block so a slow run is explicable after the fact.
    """

    transport: Transport
    endpoints: tuple[str, ...]
    request_count: int = 0
    log_request_count: int = 0
    warnings: list[str] = field(default_factory=list)
    _id: int = 0

    # -- primitives ------------------------------------------------------------------------------

    def _next_id(self) -> int:
        self._id += 1
        return self._id

    def call(self, method: str, params: list[Any] | None = None) -> Any:
        """One JSON-RPC call, tried against each endpoint in turn."""
        payload = {"jsonrpc": "2.0", "id": self._next_id(), "method": method, "params": params or []}
        last: Exception | None = None
        for url in self.endpoints:
            self.request_count += 1
            try:
                response = self.transport.post_json(url, payload)
            except TransportError as exc:
                last = exc
                continue
            if isinstance(response, list):
                response = response[0]
            if response.get("error"):
                error = response["error"]
                raise RpcError(method, str(error.get("message", error)), error.get("code"))
            return response.get("result")
        raise RpcError(method, f"every endpoint failed ({last})")

    def batch(self, requests: list[tuple[str, list[Any]]]) -> list[Any]:
        """A batched set of calls. Falls back to sequential calls if the node refuses batching."""
        if not requests:
            return []
        payload = [
            {"jsonrpc": "2.0", "id": i, "method": method, "params": params}
            for i, (method, params) in enumerate(requests)
        ]
        for url in self.endpoints:
            self.request_count += 1
            try:
                response = self.transport.post_json(url, payload)
            except TransportError:
                continue
            if not isinstance(response, list):
                continue
            out: list[Any] = [None] * len(requests)
            for item in response:
                index = int(item.get("id", 0))
                if 0 <= index < len(out):
                    out[index] = None if item.get("error") else item.get("result")
            return out
        self.warnings.append("batched requests refused; falling back to sequential calls")
        results: list[Any] = []
        for method, params in requests:
            try:
                results.append(self.call(method, params))
            except RpcError:
                results.append(None)
        return results

    # -- helpers ---------------------------------------------------------------------------------

    def block_number(self) -> int:
        """Current head block."""
        return int(str(self.call("eth_blockNumber")), 16)

    def block_timestamp(self, number: int) -> int:
        """Unix timestamp of `number`."""
        block = self.call("eth_getBlockByNumber", [hex(number), False])
        if not block:
            raise RpcError("eth_getBlockByNumber", f"block {number} not found")
        return int(str(block["timestamp"]), 16)

    def block_at_timestamp(self, target: int, *, head: int | None = None) -> int:
        """Lowest block whose timestamp is >= `target`, by binary search over real headers."""
        head = self.block_number() if head is None else head
        head_ts = self.block_timestamp(head)
        if target >= head_ts:
            return head
        # Seed the lower bound from the nominal block time, then widen until it really is below.
        span = int((head_ts - target) / max(BLOCK_TIME_SECONDS, 1e-9))
        lo = max(0, head - span * 2)
        while lo > 0 and self.block_timestamp(lo) > target:
            lo = max(0, lo - span)
        hi = head
        while lo < hi:
            mid = (lo + hi) // 2
            if self.block_timestamp(mid) < target:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def eth_call(self, to: str, data: str, *, block: str = "latest") -> str | None:
        """`eth_call`, returning `None` on revert instead of raising."""
        try:
            return str(self.call("eth_call", [{"to": to, "data": data}, block]))
        except RpcError:
            return None

    def eth_call_many(self, calls: list[tuple[str, str]]) -> list[str | None]:
        """Batched `eth_call`; entries that revert come back as `None`."""
        return self.batch([("eth_call", [{"to": to, "data": data}, "latest"]) for to, data in calls])

    def storage_at(self, address: str, slot: str) -> str | None:
        """`eth_getStorageAt`, `None` when unavailable."""
        try:
            return str(self.call("eth_getStorageAt", [address, slot, "latest"]))
        except RpcError:
            return None

    # -- logs ------------------------------------------------------------------------------------

    def get_logs(
        self,
        *,
        from_block: int,
        to_block: int,
        address: str | list[str] | None = None,
        topics: list[Any] | None = None,
        chunk: int = DEFAULT_CHUNK_BLOCKS,
        progress: Any = None,
    ) -> list[dict[str, Any]]:
        """All matching logs in `[from_block, to_block]`, chunked and adaptively halved."""
        out: list[dict[str, Any]] = []
        cursor = from_block
        size = max(MIN_CHUNK_BLOCKS, chunk)
        while cursor <= to_block:
            end = min(cursor + size - 1, to_block)
            flt: dict[str, Any] = {"fromBlock": hex(cursor), "toBlock": hex(end)}
            if address:
                flt["address"] = address
            if topics:
                flt["topics"] = topics
            try:
                self.log_request_count += 1
                logs = self.call("eth_getLogs", [flt])
            except RpcError as exc:
                message = str(exc).lower()
                if size > MIN_CHUNK_BLOCKS and any(hint in message for hint in _RANGE_ERRORS):
                    size = max(MIN_CHUNK_BLOCKS, size // 2)
                    continue
                raise
            out.extend(logs or [])
            if progress is not None:
                progress(end, to_block, len(out))
            cursor = end + 1
        return out


def load_endpoints(primary: str, fallback: str | None) -> tuple[str, ...]:
    """The endpoint tuple for `JsonRpc`, de-duplicated and order-preserving."""
    seen: list[str] = []
    for url in (primary, fallback):
        if url and url not in seen:
            seen.append(url)
    return tuple(seen)


def describe_window(from_block: int, to_block: int, chunk: int) -> str:
    """Human-readable note about how many `eth_getLogs` calls a window will cost."""
    span = max(0, to_block - from_block + 1)
    calls = (span + chunk - 1) // max(chunk, 1)
    return f"{span:,} blocks, ~{calls:,} eth_getLogs calls at {chunk:,} blocks per chunk"


def json_dumps(value: Any) -> str:
    """Stable JSON for provenance blobs."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"))
