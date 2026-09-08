#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate the synthetic cassette the `--fixtures` run replays.

    python3 tools/generate_fixtures.py            # writes src/.../constituents/fixtures/cassette.json

**Everything this writes is invented.** Tickers are `FX*`, addresses are `keccak(label)[:20]`, the
price paths are a seeded random walk around a made-up level, and the volumes and depths are chosen
to put one token in each corner of the model: deep-and-busy, thin-and-busy, mid-table, dead,
feedless, SVR-only, corporate-action, WETH-quoted, unreadable-multiplier. No figure here came from
a market and none of it may be used as one.

The cassette is regenerated deterministically from `SEED`, so a change in the pipeline that changes
fixture output shows up as a diff in `cassette.json` only when the *generator* changed.
"""

from __future__ import annotations

import json
import math
import random
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from amplestocks_quant.constituents.abi import (
    call_data,
    encode_uint,
    keccak256,
)
from amplestocks_quant.constituents.chain import (
    BLOCKSCOUT_TOKENS_URL,
    CHAINLINK_RDD_URL,
    DEXPAPRIKA_TOKEN_URL,
    DEXSCREENER_TOKEN_URL,
    ERC1967_BEACON_SLOT,
    GECKOTERMINAL_POOLS_URL,
    POOL_MANAGER,
    ROBINHOOD_ASSETS_URL,
    ROBINHOOD_DOCS_URL,
    SIG_DECIMALS,
    SIG_NAME,
    SIG_STATE_VIEW_GET_LIQUIDITY,
    SIG_STATE_VIEW_GET_SLOT0,
    SIG_SYMBOL,
    SIG_UI_MULTIPLIER,
    SIG_V3_LIQUIDITY,
    SIG_V3_SLOT0,
    STATE_VIEW,
    STOCK_TOKEN_BEACON,
    USDG,
    V3_FACTORY,
    V3_POOL_CREATED_TOPIC,
    V3_SWAP_TOPIC,
    V4_INITIALIZE_TOPIC,
    V4_SWAP_TOPIC,
    WETH9,
)
from amplestocks_quant.constituents.pricing import (
    DEPTH_BAND,
    Q96,
    sqrt_x96_from_price,
)

SEED = 20260907
OUT = ROOT / "src" / "amplestocks_quant" / "constituents" / "fixtures" / "cassette.json"

#: Fixed synthetic head: block 300,000,000 at 2026-09-01T00:00:00Z, 100 ms blocks (a chain about
#: 347 days old, so pools created four months before the window still have positive block numbers).
HEAD_BLOCK = 300_000_000
HEAD_TS = 1_788_220_800
BLOCK_TIME = 0.1
#: Price samples per pool. Eight samples over the 30-day window is enough for a volatility and a
#: beta estimate and keeps the cassette small; a real run sees thousands. It also means the
#: fixture report carries `historyDays` well below `MIN_HISTORY_DAYS`, which is the honest shape
#: of a 30-day window and is called out in the report.
SAMPLES = 8
SECONDARY_SAMPLES = 3
WETH_USD = 2_500.0
USDG_DECIMALS = 6


@dataclass
class Profile:
    """One synthetic token and the corner of the model it is there to exercise."""

    symbol: str
    name: str
    kind: str
    price: float
    volume30: float
    depth: float
    vol_annual: float
    beta: float
    feed: str = "standard"  # standard | none | svr
    multiplier: float | None = 1.0
    quote: str = "USDG"
    secondary: bool = False
    in_docs: bool = True
    decimals: int = 18
    api_skew: float = 1.0
    note: str = ""


PROFILES: list[Profile] = [
    Profile("FXDEEP", "Fixture Deep Industries", "equity", 210.0, 900_000_000, 12_000_000, 0.32, 1.05,
            secondary=True, note="mega-cap analogue: deepest book, most flow"),
    Profile("FXBIG", "Fixture Big Systems", "equity", 145.0, 420_000_000, 6_000_000, 0.38, 1.10,
            secondary=True, note="high volume, deep"),
    Profile("FXFLOW", "Fixture Flow Corp", "equity", 62.0, 260_000_000, 3_500_000, 0.44, 1.05,
            secondary=True),
    Profile("FXTHIN", "Fixture Thin Robotics", "equity", 7.4, 105_000_000, 63_000, 0.95, 1.30,
            note="the WYFI/RCAT corner: heavy flow on a $63k book"),
    Profile("FXWISP", "Fixture Wisp Networks", "equity", 3.1, 66_000_000, 125_000, 0.88, 1.22,
            note="the BULL corner"),
    Profile("FXSPARK", "Fixture Spark Mining", "equity", 12.5, 40_000_000, 210_000, 0.72, 1.40),
    Profile("FXQUANT", "Fixture Quantum Labs", "equity", 41.0, 24_000_000, 300_000, 0.81, 1.35),
    Profile("FXORBIT", "Fixture Orbit Launch", "equity", 28.0, 18_000_000, 260_000, 0.66, 1.18),
    Profile("FXMID", "Fixture Midcap Holdings", "equity", 88.0, 9_500_000, 480_000, 0.41, 0.90),
    Profile("FXSTEADY", "Fixture Steady Foods", "equity", 55.0, 6_200_000, 700_000, 0.22, 0.55,
            note="low vol, deep: the 5 bp bucket"),
    Profile("FXCHIP", "Fixture Chip Works", "equity", 132.0, 5_100_000, 240_000, 0.58, 1.12),
    Profile("FXCLOUD", "Fixture Cloud Compute", "equity", 74.0, 3_900_000, 180_000, 0.63, 1.25),
    Profile("FXSPLIT", "Fixture Split Motors", "equity", 19.0, 3_100_000, 150_000, 0.70, 1.15,
            multiplier=4.0, note="corporate action in effect: uiMultiplier() = 4"),
    Profile("FXWETHQ", "Fixture WETH-Quoted Metals", "equity", 9.6, 2_400_000, 95_000, 0.52, 0.85,
            quote="WETH", note="only pool is against WETH: exercises the ETH pricing route"),
    Profile("FXETF", "Fixture Broad Market ETF", "etf", 640.0, 2_050_000, 1_100_000, 0.18, 1.00,
            note="ETF: deep, low vol, low turnover"),
    Profile("FXOPAQUE", "Fixture Opaque Systems", "equity", 23.0, 1_400_000, 88_000, 0.49, 0.98,
            multiplier=None, note="uiMultiplier() reverts"),
    Profile("FXNOFEED", "Fixture Unfeeded Ventures", "equity", 15.0, 31_000_000, 70_000, 0.90, 1.28,
            feed="none", note="busy and thin, but no Chainlink feed: hard drop"),
    Profile("FXSVR", "Fixture SVR-Only Materials", "equity", 44.0, 12_000_000, 120_000, 0.61, 1.05,
            feed="svr", note="feed exists but is SVR-only: hard drop"),
    Profile("FXDEAD", "Fixture Dormant Mining", "equity", 0.8, 260_000, 4_200, 0.30, 0.40,
            note="no flow in the 7-day window: dead"),
    Profile("FXDUST", "Fixture Dust Exploration", "equity", 0.3, 900_000, 400, 1.40, 1.60,
            note="depth under the $1k floor: dead"),
    Profile("FXNEW", "Fixture Newly Listed", "equity", 31.0, 7_800_000, 140_000, 0.85, 1.20,
            note="pool created mid-window: V30 understates the run rate"),
    Profile("FXQUIET", "Fixture Quiet Utilities", "equity", 96.0, 1_150_000, 620_000, 0.20, 0.45,
            in_docs=False, note="only Blockscout knows it"),
    Profile("FXSKEW", "Fixture Skewed Data", "equity", 17.0, 4_400_000, 130_000, 0.55, 1.02,
            api_skew=0.35, note="aggregators disagree with the chain by >40%"),
    Profile("FXSMALL", "Fixture Smallcap Tools", "equity", 6.2, 2_700_000, 105_000, 0.68, 1.08),
]

#: Decoy ERC-20s Blockscout returns that are not stock tokens: their beacon slot is empty.
DECOYS = [("FXLP", "Fixture LP Token"), ("FXGOV", "Fixture Governance Token")]


# ------------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------------


def address_for(label: str) -> str:
    """Deterministic fake address."""
    return "0x" + keccak256(f"amplestocks-fixture:{label}".encode()).hex()[:40]


def id_for(label: str) -> str:
    """Deterministic fake 32-byte id."""
    return "0x" + keccak256(f"amplestocks-fixture-id:{label}".encode()).hex()


def word_int(value: int) -> str:
    """One 32-byte word for a signed or unsigned integer."""
    return encode_uint(value)


def pad_address(value: str) -> str:
    """Address as a topic/word."""
    return "0x" + value.lower().replace("0x", "").rjust(64, "0")


def liquidity_for_depth(depth_usd: float, sqrt_price_x96: int, dec0: int, dec1: int,
                        price0_usd: float, price1_usd: float) -> int:
    """Invert the +/-2% depth formula: what `liquidity` produces `depth_usd`?"""
    sqrt_p = sqrt_price_x96 / Q96
    unit = (sqrt_p * math.sqrt(1 + DEPTH_BAND) - sqrt_p) / 10**dec1 * price1_usd
    unit += (1.0 / (sqrt_p * math.sqrt(1 - DEPTH_BAND)) - 1.0 / sqrt_p) / 10**dec0 * price0_usd
    if unit <= 0:
        return 0
    return int(depth_usd / unit)


def price_path(rng: random.Random, base: float, vol_annual: float, beta: float,
               market: list[float], samples: int) -> list[float]:
    """A toy price path: `beta` times a shared market factor plus idiosyncratic noise."""
    idio = max(1e-6, math.sqrt(max(0.0, vol_annual**2 - (beta * 0.30) ** 2)))
    daily = idio / math.sqrt(365)
    prices = [base]
    for i in range(1, samples):
        shock = beta * market[i] + rng.gauss(0.0, daily)
        prices.append(max(1e-6, prices[-1] * math.exp(shock)))
    return prices


# ------------------------------------------------------------------------------------------------
# Cassette assembly
# ------------------------------------------------------------------------------------------------


class Cassette:
    """Accumulates the recorded payloads."""

    def __init__(self) -> None:
        self.json: dict[str, object] = {}
        self.text: dict[str, str] = {}
        self.logs: list[dict[str, object]] = []
        self.calls: dict[str, str] = {}
        self.storage: dict[str, str] = {}

    def call(self, to: str, data: str, result: str) -> None:
        """Record one `eth_call` answer."""
        self.calls[f"{to.lower()}:{data.lower()}"] = result

    def log(self, address: str, topics: list[str], data: str, block: int) -> None:
        """Record one log."""
        # Only the fields the decoders read are recorded; a real log also carries logIndex,
        # transactionHash and blockHash, none of which this pipeline looks at.
        self.logs.append(
            {
                "address": address.lower(),
                "topics": [t.lower() for t in topics],
                "data": "0x" + data,
                "blockNumber": hex(block),
            }
        )


def block_for_ts(ts: int) -> int:
    """Synthetic block number for a timestamp, matching the transport's own synthesis."""
    return max(1, int(HEAD_BLOCK - (HEAD_TS - ts) / BLOCK_TIME))


def build() -> dict[str, object]:
    """Assemble the whole cassette."""
    rng = random.Random(SEED)
    cassette = Cassette()
    window_start_ts = HEAD_TS - 30 * 86_400

    # A shared market factor so betas are meaningful.
    market = [0.0] + [rng.gauss(0.0, 0.30 / math.sqrt(365)) for _ in range(SAMPLES - 1)]

    tokens: list[dict[str, object]] = []
    gecko: dict[str, object] = {}

    # -- the WETH/USDG reference pool (v3) --------------------------------------------------------
    weth_pool = address_for("weth-usdg-v3")
    weth_is_0 = WETH9.lower() < USDG.lower()
    dec0, dec1 = (18, USDG_DECIMALS) if weth_is_0 else (USDG_DECIMALS, 18)
    weth_price0 = WETH_USD if weth_is_0 else 1.0 / WETH_USD
    weth_sqrt = sqrt_x96_from_price(weth_price0, dec0, dec1)
    weth_liquidity = liquidity_for_depth(
        46_000_000 / 20, weth_sqrt, dec0, dec1,
        WETH_USD if weth_is_0 else 1.0, 1.0 if weth_is_0 else WETH_USD,
    )
    token0, token1 = (WETH9, USDG) if weth_is_0 else (USDG, WETH9)
    cassette.log(
        V3_FACTORY,
        [V3_POOL_CREATED_TOPIC, pad_address(token0), pad_address(token1), word_int(3000)],
        word_int(60) + pad_address(weth_pool)[2:],
        block_for_ts(window_start_ts - 86_400 * 200),
    )
    cassette.call(weth_pool, call_data(SIG_V3_SLOT0),
                  "0x" + word_int(weth_sqrt) + word_int(0) * 6)
    cassette.call(weth_pool, call_data(SIG_V3_LIQUIDITY), "0x" + word_int(weth_liquidity))
    for i in range(SAMPLES):
        ts = window_start_ts + int(i * 30 * 86_400 / SAMPLES)
        amount_usdg = int(46_000_000 / SAMPLES * 10**USDG_DECIMALS)
        amount_weth = int(46_000_000 / SAMPLES / WETH_USD * 10**18)
        a0, a1 = (-amount_weth, amount_usdg) if weth_is_0 else (amount_usdg, -amount_weth)
        cassette.log(
            weth_pool,
            [V3_SWAP_TOPIC, pad_address(address_for("router")), pad_address(address_for("taker"))],
            word_int(a0) + word_int(a1) + word_int(weth_sqrt) + word_int(weth_liquidity) + word_int(0),
            block_for_ts(ts),
        )

    # -- the stock tokens -------------------------------------------------------------------------
    for profile in PROFILES:
        token = address_for(profile.symbol)
        quote_address = USDG if profile.quote == "USDG" else WETH9
        quote_decimals = USDG_DECIMALS if profile.quote == "USDG" else 18
        quote_usd = 1.0 if profile.quote == "USDG" else WETH_USD

        token_is_0 = token.lower() < quote_address.lower()
        dec0, dec1 = (
            (profile.decimals, quote_decimals) if token_is_0 else (quote_decimals, profile.decimals)
        )
        token_in_quote = profile.price / quote_usd
        price0 = token_in_quote if token_is_0 else 1.0 / token_in_quote
        sqrt_price = sqrt_x96_from_price(price0, dec0, dec1)
        prices = price_path(rng, profile.price, profile.vol_annual, profile.beta, market, SAMPLES)
        if profile.symbol == "FXDEAD":
            prices = prices[: SAMPLES - 4]  # nothing in the last stretch: V7 = 0
        head_price = prices[-1]
        head_in_quote = head_price / quote_usd
        head_price0 = head_in_quote if token_is_0 else 1.0 / head_in_quote
        head_sqrt = sqrt_x96_from_price(head_price0, dec0, dec1)
        head_liquidity = liquidity_for_depth(
            profile.depth * (0.75 if profile.secondary else 1.0),
            head_sqrt, dec0, dec1,
            head_price if token_is_0 else quote_usd,
            quote_usd if token_is_0 else head_price,
        )

        pool_id = id_for(profile.symbol)
        created = block_for_ts(
            window_start_ts + int(0.8 * 30 * 86_400) if profile.symbol == "FXNEW"
            else window_start_ts - 86_400 * 120
        )
        c0, c1 = (token, quote_address) if token_is_0 else (quote_address, token)
        cassette.log(
            POOL_MANAGER,
            [V4_INITIALIZE_TOPIC, pool_id, pad_address(c0), pad_address(c1)],
            word_int(3000) + word_int(60) + pad_address(address_for("some-hook"))[2:]
            + word_int(sqrt_price) + word_int(0),
            created,
        )
        cassette.call(STATE_VIEW, call_data(SIG_STATE_VIEW_GET_SLOT0, pool_id),
                      "0x" + word_int(head_sqrt) + word_int(0) + word_int(0) + word_int(3000))
        cassette.call(STATE_VIEW, call_data(SIG_STATE_VIEW_GET_LIQUIDITY, pool_id),
                      "0x" + word_int(head_liquidity))

        # Swaps: 90% of the volume in the primary pool, the last 7 days holding ~7/30 of it.
        primary_volume = profile.volume30 * (0.9 if profile.secondary else 1.0)
        first_sample = SAMPLES - 3 if profile.symbol == "FXNEW" else 0
        for i in range(first_sample, len(prices)):
            ts = window_start_ts + int(i * 30 * 86_400 / SAMPLES) + 3_600
            share = 1.0 / max(1, len(prices) - first_sample)
            usd_leg = primary_volume * share
            quote_raw = int(usd_leg / quote_usd * 10**quote_decimals)
            token_raw = int(usd_leg / max(prices[i], 1e-9) * 10**profile.decimals)
            sign = 1 if i % 2 == 0 else -1
            token_in_quote_i = prices[i] / quote_usd
            price0_i = token_in_quote_i if token_is_0 else 1.0 / token_in_quote_i
            sqrt_i = sqrt_x96_from_price(price0_i, dec0, dec1)
            a0, a1 = (
                (-sign * token_raw, sign * quote_raw)
                if token_is_0
                else (sign * quote_raw, -sign * token_raw)
            )
            cassette.log(
                POOL_MANAGER,
                [V4_SWAP_TOPIC, pool_id, pad_address(address_for("router"))],
                word_int(a0) + word_int(a1) + word_int(sqrt_i) + word_int(head_liquidity)
                + word_int(0) + word_int(3000),
                block_for_ts(ts),
            )

        # A v3 secondary pool for the deepest names.
        if profile.secondary:
            v3_pool = address_for(f"{profile.symbol}-v3")
            v3_liquidity = liquidity_for_depth(
                profile.depth * 0.25, head_sqrt, dec0, dec1,
                head_price if token_is_0 else quote_usd,
                quote_usd if token_is_0 else head_price,
            )
            cassette.log(
                V3_FACTORY,
                [V3_POOL_CREATED_TOPIC, pad_address(c0), pad_address(c1), word_int(500)],
                word_int(10) + pad_address(v3_pool)[2:],
                created,
            )
            cassette.call(v3_pool, call_data(SIG_V3_SLOT0), "0x" + word_int(head_sqrt) + word_int(0) * 6)
            cassette.call(v3_pool, call_data(SIG_V3_LIQUIDITY), "0x" + word_int(v3_liquidity))
            for i in range(SECONDARY_SAMPLES):
                ts = window_start_ts + int((i + 0.5) * 30 * 86_400 / SECONDARY_SAMPLES)
                usd_leg = profile.volume30 * 0.1 / SECONDARY_SAMPLES
                quote_raw = int(usd_leg / quote_usd * 10**quote_decimals)
                token_raw = int(usd_leg / profile.price * 10**profile.decimals)
                a0, a1 = (
                    (-token_raw, quote_raw) if token_is_0 else (quote_raw, -token_raw)
                )
                cassette.log(
                    v3_pool,
                    [V3_SWAP_TOPIC, pad_address(address_for("router")), pad_address(address_for("taker"))],
                    word_int(a0) + word_int(a1) + word_int(head_sqrt) + word_int(v3_liquidity)
                    + word_int(0),
                    block_for_ts(ts),
                )

        # Token metadata reads.
        cassette.call(token, call_data(SIG_DECIMALS), "0x" + word_int(profile.decimals))
        cassette.call(token, call_data(SIG_SYMBOL), _string_return(profile.symbol))
        cassette.call(token, call_data(SIG_NAME), _string_return(profile.name))
        if profile.multiplier is not None:
            cassette.call(token, call_data(SIG_UI_MULTIPLIER),
                          "0x" + word_int(int(profile.multiplier * 10**18)))
        cassette.storage[f"{token.lower()}:{ERC1967_BEACON_SLOT.lower()}"] = pad_address(STOCK_TOKEN_BEACON)

        tokens.append(
            {
                "symbol": profile.symbol,
                "name": profile.name,
                "address": token,
                "decimals": profile.decimals,
                "kind": profile.kind,
                "profile": profile,
            }
        )

        # Aggregator payloads.
        chain_daily = profile.volume30 / 30
        api_daily = chain_daily / profile.api_skew if profile.api_skew else chain_daily
        gecko[token] = api_daily
        cassette.json[GECKOTERMINAL_POOLS_URL.format(address=token)] = {
            "data": [
                {
                    "id": f"robinhood_{token}",
                    "attributes": {
                        "name": f"{profile.symbol} / {profile.quote}",
                        "volume_usd": {"h24": f"{api_daily:.2f}"},
                        "reserve_in_usd": f"{profile.depth * 6:.2f}",
                    },
                }
            ]
        }
        cassette.json[DEXPAPRIKA_TOKEN_URL.format(address=token)] = {
            "pools": [
                {
                    "id": f"rh-{profile.symbol.lower()}",
                    "dex_name": "uniswap-v4",
                    "volume_usd": api_daily * 0.96,
                    "reserve_in_usd": profile.depth * 5.8,
                }
            ]
        }
        cassette.json[DEXSCREENER_TOKEN_URL.format(address=token)] = [
            {
                "chainId": "robinhood",
                "pairAddress": address_for(f"{profile.symbol}-pair"),
                "volume": {"h24": api_daily * 1.04},
                "liquidity": {"usd": profile.depth * 6.2},
            }
        ]

    # -- decoys ------------------------------------------------------------------------------------
    decoy_entries = []
    for symbol, name in DECOYS:
        address = address_for(symbol)
        decoy_entries.append({"address": address, "symbol": symbol, "name": name, "decimals": "18"})
        cassette.call(address, call_data(SIG_DECIMALS), "0x" + word_int(18))
        cassette.call(address, call_data(SIG_SYMBOL), _string_return(symbol))
        cassette.call(address, call_data(SIG_NAME), _string_return(name))

    # -- universe sources --------------------------------------------------------------------------
    cassette.json[ROBINHOOD_ASSETS_URL] = {
        "$fixture": "SYNTHETIC - not a Robinhood payload",
        "results": [
            {
                "symbol": t["symbol"],
                "name": t["name"],
                "asset_class": "equity",
                "contracts": [
                    {"chain_id": 4663, "address": t["address"], "decimals": t["decimals"]}
                ],
            }
            for t in tokens
            if t["symbol"] != "FXQUIET"
        ],
    }
    rows = "\n".join(
        f"<tr><td>{t['symbol']}</td><td>{t['name']}</td><td>{t['address']}</td><td>18</td></tr>"
        for t in tokens
        if t["profile"].in_docs
    )
    cassette.text[ROBINHOOD_DOCS_URL] = (
        "<html><body><h1>SYNTHETIC FIXTURE - not docs.robinhood.com</h1>"
        "<table><tr><th>Symbol</th><th>Name</th><th>Address</th><th>Decimals</th></tr>"
        f"{rows}</table></body></html>"
    )
    cassette.json[BLOCKSCOUT_TOKENS_URL] = {
        "$fixture": "SYNTHETIC - not a Blockscout payload",
        "items": [
            {
                "address": t["address"],
                "symbol": t["symbol"],
                "name": t["name"],
                "decimals": str(t["decimals"]),
                "type": "ERC-20",
            }
            for t in tokens
        ]
        + decoy_entries,
        "next_page_params": None,
    }

    # -- Chainlink RDD -----------------------------------------------------------------------------
    feeds = [
        {
            "$fixture": "SYNTHETIC - not a Chainlink payload",
            "name": "USDG / USD",
            "pair": ["USDG", "USD"],
            "proxyAddress": address_for("feed-USDG"),
            "heartbeat": 86400,
            "threshold": 0.5,
            "feedType": "Fiat",
            "docs": {"assetClass": "Fiat", "baseAsset": "USDG", "quoteAsset": "USD"},
        }
    ]
    for t in tokens:
        profile: Profile = t["profile"]  # type: ignore[assignment]
        if profile.feed == "none":
            continue
        if profile.feed in ("standard", "svr"):
            if profile.feed == "standard":
                feeds.append(
                    {
                        "name": f"{profile.symbol} / USD",
                        "pair": [profile.symbol, "USD"],
                        "proxyAddress": address_for(f"feed-{profile.symbol}"),
                        "heartbeat": 86400 if profile.vol_annual < 0.8 else 3600,
                        "threshold": 0.5,
                        "feedCategory": "low",
                        "feedType": "Equities",
                        "docs": {
                            "assetClass": "Equity",
                            "assetName": profile.name,
                            "baseAsset": profile.symbol,
                            "quoteAsset": "USD",
                            "productType": "Price",
                        },
                    }
                )
            else:
                feeds.append(
                    {
                        "name": f"{profile.symbol} / USD SVR",
                        "pair": [profile.symbol, "USD"],
                        "proxyAddress": address_for(f"svr-{profile.symbol}"),
                        "heartbeat": 3600,
                        "threshold": 0.5,
                        "feedType": "Equities",
                        "docs": {
                            "assetClass": "Equity",
                            "baseAsset": profile.symbol,
                            "quoteAsset": "USD",
                            "productSubType": "Smart Value Recapture (SVR)",
                        },
                    }
                )
    cassette.json[CHAINLINK_RDD_URL] = feeds

    return {
        "$comment": (
            "SYNTHETIC FIXTURE CASSETTE - not market data. Generated by "
            "packages/quant/tools/generate_fixtures.py from a fixed seed. Every address, ticker, "
            "price, volume and depth in this file is invented to exercise the constituent "
            "pipeline. Block headers are synthesised by FixtureTransport from `chain` below."
        ),
        "synthetic": True,
        "seed": SEED,
        "generator": "packages/quant/tools/generate_fixtures.py",
        "chain": {
            "chainId": 4663,
            "headBlock": HEAD_BLOCK,
            "headTimestamp": HEAD_TS,
            "blockTimeSeconds": BLOCK_TIME,
        },
        "json": cassette.json,
        "text": cassette.text,
        "calls": cassette.calls,
        "storage": cassette.storage,
        "logs": cassette.logs,
    }


def _string_return(value: str) -> str:
    """ABI-encoded dynamic `string` return data."""
    payload = value.encode()
    body = payload.hex().ljust(64 * ((len(payload) + 31) // 32), "0") or "0" * 64
    return "0x" + encode_uint(32) + encode_uint(len(payload)) + body


def _dump(cassette: dict[str, object]) -> str:
    """Pretty at the top level, one compact line per recorded entry: readable diffs, small file."""
    lines = ["{"]
    keys = list(cassette)
    for index, key in enumerate(keys):
        value = cassette[key]
        tail = "," if index + 1 < len(keys) else ""
        if isinstance(value, dict) and key in ("json", "text", "calls", "storage"):
            lines.append(f" {json.dumps(key)}: {{")
            items = list(value.items())
            for i, (name, payload) in enumerate(items):
                comma = "," if i + 1 < len(items) else ""
                lines.append(f"  {json.dumps(name)}: {json.dumps(payload, separators=(',', ':'))}{comma}")
            lines.append(f" }}{tail}")
        elif isinstance(value, list) and key == "logs":
            lines.append(f" {json.dumps(key)}: [")
            for i, entry in enumerate(value):
                comma = "," if i + 1 < len(value) else ""
                lines.append(f"  {json.dumps(entry, separators=(',', ':'))}{comma}")
            lines.append(f" ]{tail}")
        else:
            lines.append(f" {json.dumps(key)}: {json.dumps(value, indent=2)}{tail}")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> int:
    """Write the cassette."""
    cassette = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(_dump(cassette))
    size = OUT.stat().st_size
    print(f"wrote {OUT} ({size / 1024:.0f} KiB, {len(cassette['logs'])} logs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
