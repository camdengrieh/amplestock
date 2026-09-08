# SPDX-License-Identifier: MIT
"""Chain 4663 constants for the constituent pipeline.

Every address here is mirrored from `packages/config/src/index.ts` (`addresses[4663]`), which is
itself marked "reference data pending on-chain re-verification in Phase 0". Nothing in this module
has been read off chain 4663 by this package — the sandbox that wrote it has no route to the RPC —
so a real run re-reads what it can (`decimals()`, the ERC-1967 beacon slot, pool state) and reports
mismatches rather than trusting these strings.

Addresses are stored checksummed as they appear in `packages/config`, and compared case-insensitively
everywhere in this package.
"""

from __future__ import annotations

from .abi import event_topic

CHAIN_ID = 4663
CHAIN_NAME = "Robinhood Chain"

#: Nominal block time. 4663 targets 100 ms blocks; used only to seed the block/timestamp search.
BLOCK_TIME_SECONDS = 0.1

# ------------------------------------------------------------------------------------------------
# Contracts
# ------------------------------------------------------------------------------------------------

POOL_MANAGER = "0x8366a39CC670B4001A1121B8F6A443A643e40951"
STATE_VIEW = "0xF3334192D15450CdD385c8B70e03f9A6bD9E673b"
V3_FACTORY = "0x1f7d7550B1b028f7571E69A784071F0205FD2EfA"

WETH9 = "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73"
USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
USDC = "0x80e0e24718dbFcad49ECAA6F1e6C89A190586cA8"

STOCK_TOKEN_BEACON = "0xe10b6f6B275de231345c20D14Ab812db62151b00"
STOCK_TOKEN_IMPLEMENTATION = "0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2"

#: ERC-1967 beacon slot: `keccak256("eip1967.proxy.beacon") - 1`. A Robinhood Stock Token is a
#: beacon proxy, so this slot holding `STOCK_TOKEN_BEACON` is the membership test for the universe.
ERC1967_BEACON_SLOT = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"

#: Counter assets a stock-token pool may be quoted in, most trusted first.
QUOTE_TOKENS: dict[str, str] = {
    USDG.lower(): "USDG",
    USDC.lower(): "USDC",
    WETH9.lower(): "WETH",
}

#: Decimals of the counters, used to scale swap amounts before pricing.
QUOTE_DECIMALS: dict[str, int] = {"USDG": 6, "USDC": 6, "WETH": 18}

#: Stables that are priced at exactly $1 unless `--usdg-usd` overrides it.
STABLE_QUOTES: frozenset[str] = frozenset({"USDG", "USDC"})

# ------------------------------------------------------------------------------------------------
# Event topics — computed, never pasted (see tests/test_abi.py)
# ------------------------------------------------------------------------------------------------

#: `Initialize(PoolId indexed id, Currency indexed currency0, Currency indexed currency1, uint24 fee,
#: int24 tickSpacing, IHooks hooks, uint160 sqrtPriceX96, int24 tick)`
V4_INITIALIZE_TOPIC = event_topic(
    "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)"
)
#: `Swap(PoolId indexed id, address indexed sender, int128 amount0, int128 amount1,
#: uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)`
V4_SWAP_TOPIC = event_topic("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
#: `PoolCreated(address indexed token0, address indexed token1, uint24 indexed fee,
#: int24 tickSpacing, address pool)`
V3_POOL_CREATED_TOPIC = event_topic("PoolCreated(address,address,uint24,int24,address)")
#: `Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1,
#: uint160 sqrtPriceX96, uint128 liquidity, int24 tick)`
V3_SWAP_TOPIC = event_topic("Swap(address,address,int256,int256,uint160,uint128,int24)")

# ------------------------------------------------------------------------------------------------
# Function signatures
# ------------------------------------------------------------------------------------------------

SIG_DECIMALS = "decimals()"
SIG_SYMBOL = "symbol()"
SIG_NAME = "name()"
#: Robinhood Stock Token share multiplier — the corporate-action mechanism. Name unverified offline;
#: a real run treats a revert as "unreadable" rather than as `1.0`.
SIG_UI_MULTIPLIER = "uiMultiplier()"
SIG_STATE_VIEW_GET_SLOT0 = "getSlot0(bytes32)"
SIG_STATE_VIEW_GET_LIQUIDITY = "getLiquidity(bytes32)"
SIG_V3_SLOT0 = "slot0()"
SIG_V3_LIQUIDITY = "liquidity()"
SIG_V3_FEE = "fee()"

# ------------------------------------------------------------------------------------------------
# Endpoints
# ------------------------------------------------------------------------------------------------

RPC_PRIMARY = "https://rpc.mainnet.chain.robinhood.com"
RPC_FALLBACK = "https://robinhood-rpc.publicnode.com"
HYPERSYNC_URL = "https://robinhood.hypersync.xyz"

ROBINHOOD_ASSETS_URL = "https://api.robinhood.com/rhj/assets"
ROBINHOOD_DOCS_URL = "https://docs.robinhood.com/chain/contracts/"
BLOCKSCOUT_TOKENS_URL = "https://robinhoodchain.blockscout.com/api/v2/tokens?type=ERC-20"
CHAINLINK_RDD_URL = "https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json"
GECKOTERMINAL_POOLS_URL = (
    "https://api.geckoterminal.com/api/v2/networks/robinhood/tokens/{address}/pools"
)
DEXPAPRIKA_TOKEN_URL = "https://api.dexpaprika.com/networks/robinhood/tokens/{address}/pools"
DEXSCREENER_TOKEN_URL = "https://api.dexscreener.com/token-pairs/v1/robinhood/{address}"

#: Every host the pipeline dials, for the runbook and for an allowlist request.
HOSTS: tuple[str, ...] = (
    "rpc.mainnet.chain.robinhood.com",
    "robinhood-rpc.publicnode.com",
    "robinhood.hypersync.xyz",
    "api.robinhood.com",
    "docs.robinhood.com",
    "robinhoodchain.blockscout.com",
    "reference-data-directory.vercel.app",
    "api.geckoterminal.com",
    "api.dexpaprika.com",
    "api.dexscreener.com",
)


def same_address(a: str | None, b: str | None) -> bool:
    """Case-insensitive address comparison that tolerates `None`."""
    if a is None or b is None:
        return False
    return a.lower() == b.lower()
