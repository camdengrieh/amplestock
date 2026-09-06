// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsBonds} from "../src/interfaces/IAmpsBonds.sol";
import {IFeedRegistry} from "../src/interfaces/IFeedRegistry.sol";
import {IPoolRegistry} from "../src/interfaces/IPoolRegistry.sol";
import {Constants} from "../src/types/Constants.sol";
import {
    BondMarket,
    ConstituentConfig,
    ConstituentStatus,
    FeedConfig,
    InclusionRecord,
    PoolClass
} from "../src/types/Types.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

/// @title Registry
/// @notice Batch-registers the 32 launch pools through `PoolRegistry`: `registerEntryPool` for `AMPS/USDG` and
///         `AMPS/WETH`, then `addConstituent` for each of the 30 names in `script/config/constituents.json`, then
///         one `setIndexWeights` that installs the real weight vector. Idempotent — anything already registered
///         is skipped — and it records every pool it opened, with the price the pool actually opened at, in
///         `script/config/pools.json`.
///
/// @dev **Every `PoolKey` has one shape** (`docs/phase3-state-model.md` §7): `{currency0: AMPS, currency1:
///      counter, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, hooks: AmpsHook}`. AMPS is `currency0` in all 32
///      pools by construction of its CREATE2-mined address, and `PoolRegistry._validateKeyShape` hard-requires it.
///
/// @dev **Two weight vectors, and the reason.** `PoolRegistry._requireWeight` measures a proposed
///      `targetWeightBps` against the band for the count the registration *produces*: floor `min(10000/(2n), 500)`,
///      cap `max(ceilDiv(10000, n), 3000)`. For `n` in 1..10 the floor is 500 bps, so no launch weight — equal
///      weight over 30 names is 333 bps — is legal at registration time. Every name is therefore registered at
///      `registrationWeightBps` (500), and the real vector is installed in a single {IPoolRegistry-setIndexWeights}
///      once all 30 are `ACTIVE`, where the only constraints are `[166, 3000]` per name and a sum of exactly
///      10,000. That is not a workaround: `setIndexWeights` is the published quarterly-rule entry point and the
///      launch vector is its first application.
///
/// @dev **What it does not do.** It places no liquidity — the §3.3 genesis ladders are `11_GenesisPlacement`'s
///      job — and it never points the vault at the `OracleGate`. Pool registration must happen with the gate
///      pointer *unset*, because `OracleGate` reports `WATCHDOG` until the hub pool's observation ring covers
///      `twapWindow`, and a freshly initialised pool has no observations (`docs/phase2-state-model.md` §9.1).
///
/// @dev **Usage.**
/// ```
///   # register everything the config names, against the addresses in script/config/deployments.json
///   forge script script/05_Registry.s.sol --broadcast --rpc-url $RPC $(cat script/config/libraries.flags)
///
///   # a single address may be overridden from the environment
///   AMPS_REGISTRY=0x... AMPS_TIMELOCK=0x... forge script script/05_Registry.s.sol --broadcast --rpc-url $RPC
/// ```
contract Registry is Script {
    using stdJson for string;
    using PoolIdLibrary for PoolKey;

    // -----------------------------------------------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The launch registration set: two entry pools and 30 constituents.
    string internal constant CONSTITUENTS_PATH = "./script/config/constituents.json";

    /// @notice Where the opened pools are recorded.
    string internal constant POOLS_PATH = "./script/config/pools.json";

    /// @notice The core deployment addresses every Phase 3 script reads.
    string internal constant DEPLOYMENTS_PATH = "./script/config/deployments.json";

    /// @notice Deviation, in bps, at which `FeedRegistry` treats a new answer as a jump needing a second
    ///         confirmation. 50 bps is the value every fixture and the Phase 2 integration suite install.
    uint16 internal constant FEED_THRESHOLD_BPS = 50;

    /// @notice Sanity band installed with every feed: any positive answer, no ceiling. Phase 0 narrows these
    ///         per name from the real series; a band that is too tight is an outage, not a safety feature.
    uint128 internal constant FEED_MIN_ANSWER_USD8 = 1;

    /// @dev `PoolRegistry.PoolOpened(PoolId indexed, address indexed, uint160)`.
    bytes32 internal constant POOL_OPENED_TOPIC = keccak256("PoolOpened(bytes32,address,uint160)");

    // -----------------------------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The addresses this script calls into.
    /// @param timelock The 7-day timelock — the sole caller of every registry mutator, and this script's sender.
    /// @param registry `PoolRegistry`.
    /// @param amps AMPS, `currency0` of every key.
    /// @param hook `AmpsHook`, the `hooks` field of every key.
    /// @param feedRegistry `FeedRegistry`, or zero to skip feed installation entirely.
    /// @param bonds `AmpsBonds`, or zero to skip the per-market bond parameter overrides.
    /// @param registrationWeightBps The placeholder index weight every name is registered at.
    struct Wiring {
        address timelock;
        address registry;
        address amps;
        address hook;
        address feedRegistry;
        address bonds;
        uint16 registrationWeightBps;
    }

    /// @notice One entry pool: `AMPS/USDG` (the hub) or `AMPS/WETH`.
    struct EntryPoolSpec {
        string symbol;
        address counter;
        uint8 counterDecimals;
        uint16 buyFeeBps;
        address feed;
        uint32 heartbeatSeconds;
        int24 tickSpacing;
    }

    /// @notice One constituent, flattened out of `constituents.json` so the registration loop needs no re-reads.
    struct SpokeSpec {
        string symbol;
        address token;
        address feed;
        PoolClass poolClass;
        int24 tickSpacing;
        uint16 buyFeeBps;
        uint16 targetWeightBps;
        uint16 rolloutWeightBps;
        uint16 hSessionOverrideBps;
        bool hSessionOverrideSet;
        bool openBondMarket;
        uint32 heartbeatSeconds;
        InclusionRecord inclusion;
        BondParams bond;
    }

    /// @notice The per-market bond parameters carried alongside a constituent. Applied only when they differ from
    ///         what `AmpsBonds` already holds, so the launch set — which uses the confirmed defaults — makes no
    ///         extra call at all.
    struct BondParams {
        uint16 dBaseBps;
        uint16 dMinBps;
        uint16 dMaxBps;
        uint16 capBpsPerEpoch;
        uint64 kWeightX18;
        uint64 kFillX18;
    }

    /// @notice One pool this run opened.
    /// @param poolId The v4 pool id.
    /// @param counter `currency1`.
    /// @param sqrtPriceX96 The price the pool **actually** opened at, taken from `PoolOpened` — the vault snaps
    ///        the requested price down to the grid origin, so the request and `slot0` can differ by up to one
    ///        tick spacing (`docs/phase3-state-model.md` §12 ruling C and §12.1 ruling J).
    /// @param constituentId 0 for an entry pool.
    /// @param symbol The ticker.
    struct OpenedPool {
        bytes32 poolId;
        address counter;
        uint160 sqrtPriceX96;
        uint16 constituentId;
        string symbol;
    }

    /// @notice What one run did.
    struct Result {
        uint16 entryRegistered;
        uint16 entrySkipped;
        uint16 spokesRegistered;
        uint16 spokesSkipped;
        bool weightsInstalled;
        OpenedPool[] pools;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A constituent still carries a placeholder token or feed address. Phase 0 fills these in; until
    ///         then the name cannot be registered, because `PoolRegistry` would open a pool against `address(0)`.
    /// @param symbol The ticker.
    /// @param token The token address as configured.
    /// @param feed The feed address as configured.
    error PlaceholderAddress(string symbol, address token, address feed);

    /// @notice A required wiring address is zero.
    /// @param what Which one.
    error MissingAddress(string what);

    // -----------------------------------------------------------------------------------------------------------
    // Entry points
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Loads the config, registers everything missing, and rewrites `script/config/pools.json`.
    function run() external {
        Wiring memory w = loadWiring();
        Result memory result = execute(w, loadEntryPools(), loadSpokes());
        writePools(w, result);
    }

    /// @notice Registers every entry pool and constituent in `entries`/`spokes` that is not registered yet, then
    ///         installs the index weight vector and any bond parameter overrides.
    /// @dev Idempotent at every step: an entry pool whose id is already registered, a token that already has a
    ///      constituent id, a feed already installed and a bond market already carrying the configured parameters
    ///      are each skipped. Re-running after a partial failure is the intended recovery.
    /// @param w The addresses to call into.
    /// @param entries The two entry pools.
    /// @param spokes The constituents.
    /// @return result What was registered, skipped and opened.
    function execute(Wiring memory w, EntryPoolSpec[] memory entries, SpokeSpec[] memory spokes)
        public
        returns (Result memory result)
    {
        if (w.registry == address(0)) revert MissingAddress("registry");
        if (w.timelock == address(0)) revert MissingAddress("timelock");
        if (w.amps == address(0)) revert MissingAddress("amps");
        if (w.hook == address(0)) revert MissingAddress("hook");

        IPoolRegistry registry = IPoolRegistry(w.registry);
        result.pools = new OpenedPool[](entries.length + spokes.length);
        uint256 opened;

        vm.recordLogs();
        vm.startBroadcast(w.timelock);

        for (uint256 i; i < entries.length; ++i) {
            EntryPoolSpec memory e = entries[i];
            PoolKey memory key = poolKeyFor(w.amps, e.counter, e.tickSpacing, w.hook);
            PoolId poolId = key.toId();
            if (registry.isRegistered(poolId)) {
                ++result.entrySkipped;
                console2.log("entry %s already registered", e.symbol);
                continue;
            }
            if (e.counter == address(0) || e.feed == address(0)) {
                revert PlaceholderAddress(e.symbol, e.counter, e.feed);
            }

            _installFeed(w.feedRegistry, e.counter, e.feed, e.heartbeatSeconds);
            registry.registerEntryPool(key, e.counterDecimals, e.buyFeeBps, e.feed);
            result.pools[opened++] = OpenedPool({
                poolId: PoolId.unwrap(poolId), counter: e.counter, sqrtPriceX96: 0, constituentId: 0, symbol: e.symbol
            });
            ++result.entryRegistered;
            console2.log("entry %s registered", e.symbol);
        }

        for (uint256 i; i < spokes.length; ++i) {
            SpokeSpec memory s = spokes[i];
            if (s.token != address(0) && registry.constituentIdOf(s.token) != 0) {
                ++result.spokesSkipped;
                continue;
            }
            if (s.token == address(0) || s.feed == address(0)) revert PlaceholderAddress(s.symbol, s.token, s.feed);

            _installFeed(w.feedRegistry, s.token, s.feed, s.heartbeatSeconds);
            (uint16 constituentId, PoolId poolId) = registry.addConstituent(_addParams(s, w.registrationWeightBps));
            result.pools[opened++] = OpenedPool({
                poolId: PoolId.unwrap(poolId),
                counter: s.token,
                sqrtPriceX96: 0,
                constituentId: constituentId,
                symbol: s.symbol
            });
            ++result.spokesRegistered;
            console2.log("spoke %s registered as constituent %s", s.symbol, constituentId);
        }

        result.weightsInstalled = _installWeights(registry, spokes);
        _applyBondParams(w, registry, spokes);

        vm.stopBroadcast();

        // Trim to what was actually opened, then fill in the price each pool opened at from `PoolOpened`.
        OpenedPool[] memory trimmed = new OpenedPool[](opened);
        for (uint256 i; i < opened; ++i) {
            trimmed[i] = result.pools[i];
        }
        result.pools = trimmed;
        _readOpeningPrices(result.pools);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The one pool-key shape every Amplestocks pool has.
    /// @param amps AMPS.
    /// @param counter The counter asset.
    /// @param tickSpacing The pool's tick spacing.
    /// @param hook `AmpsHook`.
    /// @return key The key.
    function poolKeyFor(address amps, address counter, int24 tickSpacing, address hook)
        public
        pure
        returns (PoolKey memory key)
    {
        key = PoolKey({
            currency0: Currency.wrap(amps),
            currency1: Currency.wrap(counter),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
    }

    // -----------------------------------------------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Reads the core addresses out of `script/config/deployments.json`, letting the environment win.
    /// @return w The wiring.
    function loadWiring() public view returns (Wiring memory w) {
        string memory deployments = vm.readFile(DEPLOYMENTS_PATH);
        string memory constituents = vm.readFile(CONSTITUENTS_PATH);
        w = Wiring({
            timelock: _address(deployments, ".core.timelock", "AMPS_TIMELOCK"),
            registry: _address(deployments, ".core.registry", "AMPS_REGISTRY"),
            amps: _address(deployments, ".core.amps", "AMPS_TOKEN"),
            hook: _address(deployments, ".core.hook", "AMPS_HOOK"),
            feedRegistry: _address(deployments, ".core.feedRegistry", "AMPS_FEED_REGISTRY"),
            bonds: _address(deployments, ".core.bonds", "AMPS_BONDS"),
            registrationWeightBps: uint16(constituents.readUint(".registrationWeightBps"))
        });
    }

    /// @notice The two entry pools, from `constituents.json`.
    /// @return entries The specs.
    function loadEntryPools() public view returns (EntryPoolSpec[] memory entries) {
        string memory json = vm.readFile(CONSTITUENTS_PATH);
        entries = new EntryPoolSpec[](2);
        for (uint256 i; i < 2; ++i) {
            string memory at = string.concat(".entryPools[", vm.toString(i), "]");
            entries[i] = EntryPoolSpec({
                symbol: json.readString(string.concat(at, ".symbol")),
                counter: json.readAddress(string.concat(at, ".counter")),
                counterDecimals: uint8(json.readUint(string.concat(at, ".counterDecimals"))),
                buyFeeBps: uint16(json.readUint(string.concat(at, ".buyFeeBps"))),
                feed: json.readAddress(string.concat(at, ".feed")),
                heartbeatSeconds: uint32(json.readUint(string.concat(at, ".heartbeatSeconds"))),
                tickSpacing: int24(json.readInt(string.concat(at, ".tickSpacing")))
            });
        }
    }

    /// @notice The 30 constituents, from `constituents.json`.
    /// @return spokes The specs, in registry order.
    function loadSpokes() public view returns (SpokeSpec[] memory spokes) {
        string memory json = vm.readFile(CONSTITUENTS_PATH);
        uint256 n = json.readUint(".constituentCount");
        spokes = new SpokeSpec[](n);
        for (uint256 i; i < n; ++i) {
            spokes[i] = _readSpoke(json, string.concat(".constituents[", vm.toString(i), "]"));
        }
    }

    /// @notice Rewrites `script/config/pools.json` with everything this run opened.
    /// @param w The wiring the run used.
    /// @param result The run's result.
    function writePools(Wiring memory w, Result memory result) public {
        string memory root = "amplestocks.pools";
        vm.serializeString(
            root,
            "$comment",
            "Written by script/05_Registry.s.sol. `sqrtPriceX96` is the price each pool ACTUALLY opened at, read "
            "from PoolRegistry.PoolOpened: the vault snaps the requested price down to the pool's grid origin."
        );
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "registry", w.registry);
        vm.serializeAddress(root, "hook", w.hook);
        vm.serializeUint(root, "poolCount", result.pools.length);

        string[] memory pools = new string[](result.pools.length);
        for (uint256 i; i < result.pools.length; ++i) {
            OpenedPool memory p = result.pools[i];
            string memory obj = string.concat("amplestocks.pools.", vm.toString(i));
            vm.serializeString(obj, "symbol", p.symbol);
            vm.serializeBytes32(obj, "poolId", p.poolId);
            vm.serializeAddress(obj, "counter", p.counter);
            vm.serializeUint(obj, "constituentId", p.constituentId);
            pools[i] = vm.serializeUint(obj, "sqrtPriceX96", p.sqrtPriceX96);
        }

        string memory json = vm.serializeString(root, "pools", pools);
        vm.writeJson(json, POOLS_PATH);
        console2.log("wrote %s (%s pools)", POOLS_PATH, result.pools.length);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev `AddConstituentParams` for one spoke, at the placeholder registration weight.
    function _addParams(SpokeSpec memory s, uint16 registrationWeightBps)
        private
        pure
        returns (IPoolRegistry.AddConstituentParams memory params)
    {
        params = IPoolRegistry.AddConstituentParams({
            token: s.token,
            feed: s.feed,
            poolClass: s.poolClass,
            tickSpacing: s.tickSpacing,
            buyFeeBps: s.buyFeeBps,
            targetWeightBps: registrationWeightBps,
            rolloutWeightBps: s.rolloutWeightBps,
            hSessionOverrideBps: s.hSessionOverrideBps,
            hSessionOverrideSet: s.hSessionOverrideSet,
            inclusion: s.inclusion,
            openBondMarket: s.openBondMarket
        });
    }

    /// @dev Allowlists an aggregator as a Chainlink Standard proxy and configures it for `token`. A no-op when the
    ///      feed registry is not wired yet or the feed is already the configured one.
    function _installFeed(address feedRegistry, address token, address aggregator, uint32 heartbeatSeconds) private {
        if (feedRegistry == address(0)) return;
        IFeedRegistry feeds = IFeedRegistry(feedRegistry);
        if (feeds.feedOf(token) == aggregator) return;

        feeds.setStandardProxy(aggregator, true);
        feeds.setFeed(
            token,
            aggregator,
            FeedConfig({
                aggregator: address(0),
                decimals: 0,
                set: false,
                heartbeat: heartbeatSeconds,
                thresholdBps: FEED_THRESHOLD_BPS,
                minAnswerUsd8: FEED_MIN_ANSWER_USD8,
                maxAnswerUsd8: type(uint128).max
            })
        );
    }

    /// @dev Installs the launch weight vector over every ACTIVE constituent. Returns false — without reverting —
    ///      when the registry holds an active name this run has no weight for, because `setIndexWeights` requires
    ///      the active weights to sum to exactly 10,000 and a partial vector cannot satisfy that.
    function _installWeights(IPoolRegistry registry, SpokeSpec[] memory spokes) private returns (bool installed) {
        uint16 count = registry.constituentCount();
        uint16 active = registry.activeConstituentCount();
        if (active == 0) return false;

        uint16[] memory ids = new uint16[](active);
        uint16[] memory weights = new uint16[](active);
        uint256 found;
        uint256 sum;
        bool changed;

        for (uint16 id = 1; id <= count; ++id) {
            ConstituentConfig memory c = registry.constituent(id);
            if (c.status != ConstituentStatus.ACTIVE) continue;
            uint16 weight = _weightFor(spokes, c.token);
            if (weight == 0) {
                console2.log("no configured weight for constituent %s; index weights left as they are", id);
                return false;
            }
            ids[found] = id;
            weights[found] = weight;
            if (c.targetWeightBps != weight) changed = true;
            sum += weight;
            ++found;
        }

        if (sum != Constants.BPS) {
            console2.log("configured weights sum to %s, not 10000; index weights left as they are", sum);
            return false;
        }
        if (!changed) return false;

        registry.setIndexWeights(ids, weights);
        installed = true;
        console2.log("index weights installed over %s constituents", active);
    }

    /// @dev The configured launch weight for `token`, or 0 when this run does not know the name.
    function _weightFor(SpokeSpec[] memory spokes, address token) private pure returns (uint16 weight) {
        for (uint256 i; i < spokes.length; ++i) {
            if (spokes[i].token == token) return spokes[i].targetWeightBps;
        }
    }

    /// @dev Applies per-market bond overrides, and only the ones that differ from what the market already holds.
    function _applyBondParams(Wiring memory w, IPoolRegistry registry, SpokeSpec[] memory spokes) private {
        if (w.bonds == address(0)) return;
        IAmpsBonds bonds = IAmpsBonds(w.bonds);

        for (uint256 i; i < spokes.length; ++i) {
            SpokeSpec memory s = spokes[i];
            if (!s.openBondMarket || s.token == address(0)) continue;
            uint16 constituentId = registry.constituentIdOf(s.token);
            if (constituentId == 0) continue;
            uint16 marketId = registry.constituent(constituentId).marketId;
            if (marketId == 0) continue;

            BondMarket memory m = bonds.market(marketId);
            if (m.dBaseBps != s.bond.dBaseBps || m.dMinBps != s.bond.dMinBps || m.dMaxBps != s.bond.dMaxBps) {
                bonds.setDiscountParams(marketId, s.bond.dBaseBps, s.bond.dMinBps, s.bond.dMaxBps);
                console2.log("%s discount params updated", s.symbol);
            }
            if (m.kWeightX18 != s.bond.kWeightX18 || m.kFillX18 != s.bond.kFillX18) {
                bonds.setCoefficients(marketId, s.bond.kWeightX18, s.bond.kFillX18);
                console2.log("%s bond coefficients updated", s.symbol);
            }
            if (m.capBpsPerEpoch != s.bond.capBpsPerEpoch) {
                bonds.setCapBpsPerEpoch(marketId, s.bond.capBpsPerEpoch);
                console2.log("%s bond capacity updated", s.symbol);
            }
        }
    }

    /// @dev Fills in `sqrtPriceX96` for each opened pool from the `PoolOpened` events this run emitted. The event
    ///      carries the price the pool really opened at, which is the requested price snapped down to the grid
    ///      origin, so it is the only number an indexer or a later placement may trust.
    function _readOpeningPrices(OpenedPool[] memory pools) private view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length != 3 || entry.topics[0] != POOL_OPENED_TOPIC) continue;
            bytes32 poolId = entry.topics[1];
            uint160 sqrtPriceX96 = uint160(uint256(abi.decode(entry.data, (uint256))));
            for (uint256 j; j < pools.length; ++j) {
                if (pools[j].poolId == poolId) pools[j].sqrtPriceX96 = sqrtPriceX96;
            }
        }
    }

    /// @dev One constituent, read field by field. Deliberately not an `abi.decode` of the whole object: that
    ///      binds the JSON to a struct's alphabetical field order and fails silently when either moves.
    function _readSpoke(string memory json, string memory at) private pure returns (SpokeSpec memory s) {
        s.symbol = json.readString(string.concat(at, ".symbol"));
        s.token = json.readAddress(string.concat(at, ".token"));
        s.feed = json.readAddress(string.concat(at, ".feed"));
        s.poolClass = _poolClass(json.readString(string.concat(at, ".poolClass")));
        s.tickSpacing = int24(json.readInt(string.concat(at, ".tickSpacing")));
        s.buyFeeBps = uint16(json.readUint(string.concat(at, ".buyFeeBps")));
        s.targetWeightBps = uint16(json.readUint(string.concat(at, ".targetWeightBps")));
        s.rolloutWeightBps = uint16(json.readUint(string.concat(at, ".rolloutWeightBps")));
        s.hSessionOverrideBps = uint16(json.readUint(string.concat(at, ".hSessionOverrideBps")));
        s.hSessionOverrideSet = json.readBool(string.concat(at, ".hSessionOverrideSet"));
        s.openBondMarket = json.readBool(string.concat(at, ".openBondMarket"));
        s.heartbeatSeconds = uint32(json.readUint(string.concat(at, ".heartbeatSeconds")));
        s.inclusion = InclusionRecord({
            betaX18: int64(json.readInt(string.concat(at, ".inclusion.betaX18"))),
            trackingErrorX18: uint64(json.readUint(string.concat(at, ".inclusion.trackingErrorX18"))),
            indexVolX18: uint64(json.readUint(string.concat(at, ".inclusion.indexVolX18"))),
            historyDays: uint32(json.readUint(string.concat(at, ".inclusion.historyDays"))),
            recordedAt: 0
        });
        s.bond = BondParams({
            dBaseBps: uint16(json.readUint(string.concat(at, ".bond.dBaseBps"))),
            dMinBps: uint16(json.readUint(string.concat(at, ".bond.dMinBps"))),
            dMaxBps: uint16(json.readUint(string.concat(at, ".bond.dMaxBps"))),
            capBpsPerEpoch: uint16(json.readUint(string.concat(at, ".bond.capBpsPerEpoch"))),
            kWeightX18: uint64(json.readUint(string.concat(at, ".bond.kWeightX18"))),
            kFillX18: uint64(json.readUint(string.concat(at, ".bond.kFillX18")))
        });
    }

    /// @dev `"SPOKE_HIGH_VOL"` or anything else, which is `SPOKE`. `ENTRY` is not a constituent class and
    ///      `PoolRegistry.addConstituent` rejects it, so it is not spellable here.
    function _poolClass(string memory name) private pure returns (PoolClass class) {
        class = keccak256(bytes(name)) == keccak256("SPOKE_HIGH_VOL") ? PoolClass.SPOKE_HIGH_VOL : PoolClass.SPOKE;
    }

    /// @dev An address from the config, overridden by `envName` when that variable is set.
    function _address(string memory json, string memory path, string memory envName)
        private
        view
        returns (address value)
    {
        value = vm.envOr(envName, json.readAddress(path));
    }
}
