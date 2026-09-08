// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsHook} from "../interfaces/IAmpsHook.sol";
import {IAmpsVault} from "../interfaces/IAmpsVault.sol";
import {IFeePolicy} from "../interfaces/IFeePolicy.sol";
import {IMarketReference} from "../interfaces/IMarketReference.sol";
import {IOracleGate} from "../interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {PriceLib} from "../lib/PriceLib.sol";
import {TruncatedOracleLib} from "../lib/TruncatedOracleLib.sol";
import {Constants} from "../types/Constants.sol";
import {BeyondRail, NotInitialized, NotTimelock, NotVault, OutOfBand, ZeroAddress} from "../types/Errors.sol";
import {GateState, HookPoolState, PoolClass, PoolConfig, Session} from "../types/Types.sol";
import {HookStateLib} from "./HookStateLib.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title AmpsHook
/// @notice The one immutable hook behind all 32 Amplestocks pools: one protocol-wide AMPS fee on both directions
///         of every pool, a pass-through exemption for the protocol router's rotation hops, a truncated
///         observation ring, and the per-pool state the vault, the bonds shell and the quoter read.
///
/// @dev **The fee model in three lines (revision 6).** Every hop of every pool pays `ampsFeeBps` (500 bp at
///      launch) as its base, buys and sells alike, plus the unchanged dynamic components and the unchanged rail
///      refusal. The single exception is a hop the protocol router flags as one leg of a rotation
///      ({_isPassThrough}): its base is the pool's own `buyFeeBps` — 30 bp entry, 5 or 10 bp spoke — which is the
///      price of *moving through* the index rather than entering or leaving it. `buyFeeBps` is therefore the
///      pass-through fee, and nothing else in the system pays it.
///
/// @dev **Shape (I13, I18).** Permissions are exactly `0x38C0` — `BEFORE_INITIALIZE | AFTER_INITIALIZE |
///      BEFORE_ADD_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP`. No `*_RETURNS_DELTA` bit, no `BEFORE_REMOVE_LIQUIDITY`
///      bit: removals can never be blocked. The contract holds no ERC-20 and no ERC-6909, mirrors no PoolManager
///      balance, never calls `settle`, `take`, `mint`, `burn`, `donate` or `swap`, and performs no liquidity
///      operation in any callback. `beforeSwap` returns `ZERO_DELTA` and `afterSwap` returns `0`, always.
///
/// @dev **The one deliberate revert (`docs/phase3-state-model.md` §10 ruling 2).** A swap is refused only when it
///      is deviation-increasing and beyond the outer rail — checked twice, on the start-of-swap tick in
///      `beforeSwap` and on the post-swap tick in `afterSwap`, both throwing `Errors.BeyondRail`. Nothing else in
///      either callback may revert a swap: every external read is a bounded low-level `staticcall` whose failure
///      raises `gateFlags.refreshFailed` and leaves the cached value in place (I15).
///
/// @dev **Why low-level `staticcall` rather than `try`/`catch`.** `catch` does not catch a decoding failure that
///      follows a *successful* call, and a call to an address with no code succeeds with empty return data. A
///      registry, gate, policy or token that returns garbage — or nothing — would therefore revert the swap
///      through `try`/`catch` but cannot through a manual decode. Every hot-path read here decodes by hand and
///      clamps what it decodes.
///
/// @dev **Caching (§1.7).** `beforeSwap` reads three of this contract's own words plus the pure fee policy and
///      nothing else. The gate, the feeds, the hub TWAP and `uiMultiplier()` are pulled in `afterSwap` at most
///      once per pool per {gateCacheSeconds}; once a cache is older than `Constants.GATE_CACHE_MAX_AGE`,
///      `beforeSwap` substitutes the most conservative values rather than reading anything.
contract AmpsHook is BaseHook, IAmpsHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using TruncatedOracleLib for TruncatedOracleLib.State;

    // -------------------------------------------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Domain separator of the EIP-1153 slots carrying the same-transaction rotation credit, in AMPS wei:
    ///      `uint256(Constants.ROTATION_CREDIT_SLOT)` = `keccak256("amplestocks.hook.ROTATION_CREDIT")`.
    ///      Spelled as a literal because inline assembly accepts only direct number constants; the two are
    ///      asserted equal in `test/unit/RotationCredit.t.sol`, which is what keeps them from drifting (I26).
    ///
    /// @dev **The credit is per `sender`, not per transaction.** The slot actually written is
    ///      `keccak256(abi.encode(ROTATION_CREDIT_SLOT, sender))` — see {_creditSlot}. One transaction-global slot
    ///      would let AMPS bought through *any* settlement path discount an unrelated sell settled through *any
    ///      other* one in the same transaction: two independent routers in one multicall, or two bundle-mates
    ///      sharing a block builder's transaction, would pool their credits, and a credit earned in the deep hub
    ///      would discount a sell into a thin spoke. Keying by `sender` bounds the credit to one settlement path.
    ///
    /// @dev **And, since revision 6, only one `sender` can hold a credit at all.** A buy earns a credit only when
    ///      it is the protocol router's rotation hop ({_isPassThrough}), and a sell spends one only on the same
    ///      condition; every other hop in the system pays `ampsFeeBps` and neither earns nor spends. The batching
    ///      case the earlier design accepted — a settlement contract pairing one party's entry with another
    ///      party's exit and blending them — is therefore gone: that contract is not {router}, so both of its legs
    ///      pay the AMPS fee. What is left is exactly the flow the credit was priced for, built by one audited
    ///      contract in one `unlock`, with the second hop selling precisely what the first hop bought.
    uint256 private constant ROTATION_CREDIT_SLOT = 0x28ef4cf38086db5318537797461c68e4f15873dbd0e73f3e45f6b1f32032b976;

    /// @dev Gas ceiling on the gate snapshot. Generous — but finite, so a gate that loops cannot take the swap
    ///      with it. The budget only binds when the gate is genuinely that expensive: a normal refresh forwards
    ///      what it forwards and costs what it costs, and this number never adds gas to a swap.
    ///
    /// @dev **Why 1,000,000 and not the 400,000 this started at.** `OracleGate.snapshotByPool` grew: it now reads
    ///      `feedStatusIn` — itself budgeted at eight per-feed probes — and can take up to two extra
    ///      `getRoundData` probes per feed read. Measured in-fixture against the mock feeds it costs 239k–252k;
    ///      against real Chainlink aggregator proxies, whose reads are several storage slots deeper and whose
    ///      round-data path is longer, the same call is estimated at 330k–390k. 400,000 left no room for a slow
    ///      feed, another probe, or an aggregator upgrade, and the failure mode is not local: a refresh that runs
    ///      out of budget raises `refreshFailed`, leaves the cache to age past `Constants.GATE_CACHE_MAX_AGE`, and
    ///      then pins **every** pool on the conservative substitute with no path back, because every subsequent
    ///      refresh runs out of the same budget. One million is roughly 2.5x the estimated real-feed cost and
    ///      still a small fraction of a block, so a looping gate is bounded while a merely slow one is not.
    uint256 private constant GATE_PROBE_GAS = 1_000_000;

    /// @dev Gas ceiling on a pure policy call (`quoteFee`, `innerBandTicks`, `outerRailTicks`).
    uint256 private constant POLICY_PROBE_GAS = 120_000;

    /// @dev Gas ceiling on the reads that really are single-slot getters behind an external call:
    ///      `IAmpsVault.oracleGate`, and the Stock Token's `oraclePaused` / `effectiveAt` in
    ///      {_clearCorporateAction}. None of them can plausibly cost more than this.
    ///
    /// @dev **`IOracleGate.closedHours` used to be metered here and is not any more.** It is not a pointer read:
    ///      it runs `Calendar.sessionAt`, which scans every DST window that started before now (two cold `SLOAD`s
    ///      apiece) and reads the holiday bitmap, and then walks back up to 16 local days, each with another
    ///      bitmap read and two more UTC-offset scans. Against the 2025–2032 table `script/03_Core` installs the
    ///      scan grows by roughly 4k gas per calendar year covered, reaching ~45–50k on a holiday weekend in
    ///      2032 — inside 60,000 today and outside it well before the table runs out. The failure would have been
    ///      silent and seasonal: the read is only reached when the session is `CLOSED`, so it would have started
    ///      failing on weekends and holidays only, dropping every pool onto the conservative substitute for the
    ///      whole close. It is therefore read under {GATE_PROBE_GAS}, the same budget as the snapshot beside it.
    uint256 private constant POINTER_PROBE_GAS = 60_000;

    /// @dev A surge decays to nothing after eight half-lives; past that `afterSwap` clears the word.
    uint32 private constant DECAY_HORIZON = 8;

    /// @dev The ARMED word stores the EWMA variance as X12: `EWMA(d^2) x VARIANCE_STORE_SCALE`. The X18 form the
    ///      policy is calibrated against does not fit 64 bits. See `HookStateLib.Armed` and {_updateVariance}.
    uint256 private constant VARIANCE_STORE_SCALE = 1e12;

    /// @dev `1e18 / VARIANCE_STORE_SCALE`: what the stored value is multiplied by to become `FeeInput.varianceX18`.
    uint256 private constant VARIANCE_SCALE_TO_X18 = 1e6;

    /// @dev `GateSnapshot` is thirteen static words; a shorter return cannot be one.
    uint256 private constant GATE_SNAPSHOT_WORDS = 13;

    /// @dev `FeeQuote` is five static words.
    uint256 private constant FEE_QUOTE_WORDS = 5;

    // -------------------------------------------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsHook
    address public immutable amps;

    /// @inheritdoc IAmpsHook
    address public immutable registry;

    /// @inheritdoc IAmpsHook
    address public immutable timelock;

    // -------------------------------------------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Slot 0, packed: the protocol-wide sell fee, the fee-policy pointer and the gate-cache interval.
    uint16 private _ampsFee;
    address private _policy;
    uint32 private _gateCache;

    /// @inheritdoc IAmpsHook
    /// @dev **Storage, not immutable.** Every vault-only check in this contract — `beforeInitialize`,
    ///      `beforeAddLiquidity`, {resetHighWater}, {armSurge} — and the gate pointer {_gateAddress} reads are all
    ///      against this address, so a hook that froze it would make `AmpsVault.emergencyMigrate` a one-way door:
    ///      the standby vault could never initialise a pool, add liquidity or arm a surge. Its own slot, so the
    ///      packed word above is untouched. Moved only by {setVault}, and only by the vault itself.
    address public vault;

    /// @inheritdoc IAmpsHook
    /// @dev **The whole of the pass-through exemption is this one word.** A swap hop is pass-through — priced at
    ///      the pool's `buyFeeBps` rather than at the protocol-wide `ampsFeeBps`, and allowed to earn or spend a
    ///      rotation credit — iff the PoolManager reports this address as the swap's `sender` **and** the hop
    ///      carries `Constants.ROUTER_ROTATE` as its `hookData`. Everything else in the world pays `ampsFeeBps`
    ///      in both directions.
    ///
    /// @dev Storage rather than immutable, and replaceable by the timelock alone: the router is ordinary
    ///      periphery with no privileges beyond this one, so a bug in it must be fixable without redeploying the
    ///      hook, and the zero address is a valid setting meaning "no router, nothing is pass-through".
    address public router;

    /// @dev Per pool: the CONFIG word (§1.2), written at `afterInitialize` and thereafter only by governance.
    mapping(PoolId poolId => uint256 word) private _cfg;

    /// @dev Per pool: the DYNAMIC word (§1.2), written by `afterSwap`.
    mapping(PoolId poolId => uint256 word) private _dyn;

    /// @dev Per pool: the ARMED word (§1.2), written by `afterSwap` and by {armSurge}.
    mapping(PoolId poolId => uint256 word) private _arm;

    /// @dev Per pool: the truncated observation ring (64 slots plus one packed head).
    mapping(PoolId poolId => TruncatedOracleLib.State state) private _obs;

    // -------------------------------------------------------------------------------------------------------------
    // Memory-only working types
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Everything one fee quote produces. A struct rather than a tuple because `beforeSwap` needs the
    ///      deviation and the rail it was measured against for the `BeyondRail` payload.
    struct Quote {
        uint16 feeBps;
        uint16 baseBps;
        uint16 dynBps;
        bool refuse;
        uint256 creditConsumed;
        int24 devTicks;
        int24 railTicks;
    }

    /// @dev The swap as the fee law sees it. A struct rather than four parameters because the legacy pipeline
    ///      runs out of stack slots otherwise, and because `beforeSwap` and {quoteFee} must pass exactly the same
    ///      four values.
    struct SwapCtx {
        bool sell;
        bool exactInput;
        bool passThrough;
        uint256 amountIn;
        uint256 credit;
    }

    /// @dev Everything one gate-cache refresh reads, in one memory slot's worth of pointer. A struct because
    ///      `_refreshGate` would otherwise run the legacy pipeline out of stack, and because "what the gate said"
    ///      and "what was cached" have to be the same shape for a failed refresh to fall back cleanly.
    struct GateView {
        bool ok;
        bool degraded;
        bool corporateFreeze;
        uint8 session;
        uint16 dynCapBps;
        uint16 closedHours;
        int24 fairTick;
        int24 bandTicks;
        int24 railTicks;
    }

    /// @dev The gate view actually in force for a swap: either the cached one or, once the cache is older than
    ///      `GATE_CACHE_MAX_AGE`, the most conservative substitute (§1.4 step 6).
    struct Effective {
        int24 bandTicks;
        int24 railTicks;
        uint16 dynCapBps;
        bool frozen;
    }

    constructor(IPoolManager poolManager_, address amps_, address vault_, address registry_, address timelock_)
        BaseHook(poolManager_)
    {
        if (amps_ == address(0) || vault_ == address(0) || registry_ == address(0) || timelock_ == address(0)) {
            revert ZeroAddress();
        }
        amps = amps_;
        vault = vault_;
        registry = registry_;
        timelock = timelock_;
        _ampsFee = Constants.AMPS_FEE_BPS_DEFAULT;
        _gateCache = Constants.GATE_CACHE_SECONDS_DEFAULT;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Permissions
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc BaseHook
    /// @dev Must equal the mined address bits `0x38C0`; `BaseHook`'s constructor asserts exactly that.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------------------------------------------
    // Initialisation and liquidity
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The five preconditions of §1.3, in the order that makes each failure unambiguous. `currency0 == AMPS`
    ///      catches native ETH (`address(0)`) on the way past.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (sender != vault) revert NotVault(sender);
        if (Currency.unwrap(key.currency0) != amps) revert Currency0NotAmps();
        if (!key.fee.isDynamicFee()) revert FeeNotDynamic();

        PoolId id = key.toId();
        PoolConfig memory pc = IPoolRegistry(registry).poolConfig(id);
        if (!pc.registered) revert PoolNotRegistered(id);
        if (pc.counter != Currency.unwrap(key.currency1)) revert PoolKeyMismatch("counter");
        if (pc.tickSpacing != key.tickSpacing) revert PoolKeyMismatch("tickSpacing");

        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Writes the CONFIG word (grid origin included — `PoolRegistry._openPool` reads it back on the next
    ///      line), seeds the observation ring at the opening tick, and takes a first gate and multiplier reading.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId id = key.toId();
        PoolConfig memory pc = IPoolRegistry(registry).poolConfig(id);

        HookStateLib.Config memory c;
        c.buyFeeBps = pc.buyFeeBps == 0 ? _defaultBuyFee(pc.poolClass) : pc.buyFeeBps;
        c.constituentId = pc.constituentId;
        c.poolClass = pc.poolClass;
        c.tickSpacing = key.tickSpacing;
        c.maxTickMovePerBlock = Constants.MAX_TICK_MOVE_PER_BLOCK_DEFAULT;
        c.counterDecimals = pc.counterDecimals;
        c.gridBaseTick = PriceLib.alignTick(tick, key.tickSpacing, true);
        c.initialized = true;
        _cfg[id] = HookStateLib.packConfig(c);

        _obs[id].initialize(uint32(block.timestamp), tick);

        HookStateLib.Dynamic memory d;
        d.lastTick = tick;
        d.fairTick = tick;
        d.lastUpdate = uint32(block.timestamp);
        d.session = Session.REGULAR;
        d.dynCapBps = Constants.DYN_CAP_NORMAL_BPS;
        d.innerBandTicks = Constants.INNER_BAND_REGULAR_TICKS;
        d.outerRailTicks = _defaultRail(c.poolClass, Constants.INNER_BAND_REGULAR_TICKS);

        HookStateLib.Armed memory a;
        a.uiMultiplierX18 = uint64(Constants.WAD);

        _refreshGate(id, c, d, a, false);
        if (c.poolClass != PoolClass.ENTRY) {
            uint256 m = _probeMultiplier(Currency.unwrap(key.currency1));
            a.lastCorporateCheck = uint32(block.timestamp);
            if (m != 0) a.uiMultiplierX18 = _toUint64(m);
        }

        _dyn[id] = HookStateLib.packDynamic(d);
        _arm[id] = HookStateLib.packArmed(a);

        return BaseHook.afterInitialize.selector;
    }

    /// @dev POL-only pools (Decision 5): the vault is the sole liquidity provider in all 32 pools. There is no
    ///      `beforeRemoveLiquidity` counterpart, so a removal is never blockable (I18).
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != vault) revert NotVault(sender);
        return BaseHook.beforeAddLiquidity.selector;
    }

    // -------------------------------------------------------------------------------------------------------------
    // beforeSwap
    // -------------------------------------------------------------------------------------------------------------

    /// @dev §1.4, in order: three cold `SLOAD`s, the base fee and — on the protocol router's rotation hop alone —
    ///      the rotation blend, the start-of-swap rail check, the dynamic components through the policy pointer,
    ///      the clamp, the override flag.
    ///
    /// @dev `sender` is the account that unlocked the PoolManager. It decides two things and no others: whether
    ///      this hop is the protocol router's rotation hop (see {_isPassThrough}), and, if it is, which account's
    ///      rotation credit it may spend — its own and no one else's.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        uint256 cfgWord = _cfg[id];
        if (!HookStateLib.isInitialized(cfgWord)) revert NotInitialized();

        SwapCtx memory ctx;
        ctx.sell = params.zeroForOne;
        ctx.exactInput = params.amountSpecified < 0;
        ctx.passThrough = _isPassThrough(sender, hookData);
        if (ctx.exactInput) ctx.amountIn = uint256(-params.amountSpecified);

        // Hashed once, on the only path that can spend a credit, and reused by the write below. A hop that is not
        // the router's rotation hop neither reads nor writes the slot: it pays `ampsFeeBps` whatever is in it.
        uint256 slot;
        if (ctx.passThrough && ctx.sell && ctx.exactInput && ctx.amountIn != 0) {
            slot = _creditSlot(sender);
            ctx.credit = _tload(slot);
        }

        Quote memory q = _quote(
            HookStateLib.unpackConfig(cfgWord),
            HookStateLib.unpackDynamic(_dyn[id]),
            HookStateLib.unpackArmed(_arm[id]),
            ctx
        );

        // The one deliberate revert, on the start-of-swap tick and direction (§10 ruling 2).
        if (q.refuse) revert BeyondRail(PoolId.unwrap(id), q.devTicks, q.railTicks);

        // `creditConsumed != 0` implies `ctx.credit != 0`, which implies `slot` was computed above.
        if (q.creditConsumed != 0) {
            uint256 remaining = ctx.credit - q.creditConsumed;
            assembly ("memory-safe") {
                tstore(slot, remaining)
            }
            emit RotationCreditConsumed(id, q.creditConsumed, q.baseBps);
        }

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            (uint24(q.feeBps) * Constants.PIPS_PER_BPS) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // afterSwap
    // -------------------------------------------------------------------------------------------------------------

    /// @dev §1.5. Every external read below is bounded and manually decoded, so no downstream failure — a
    ///      reverting gate, a policy that runs out of gas, a token that returns garbage — can reach the swapper.
    ///      The post-swap rail check at the end is the single deliberate exception (§10 ruling 2).
    ///
    /// @dev `sender` and `hookData` are carried rather than discarded for the same reason `beforeSwap` carries
    ///      them: only the protocol router's rotation hop earns a credit, and it earns it for itself (see
    ///      {ROTATION_CREDIT_SLOT} and {_isPassThrough}).
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();
        // A pool the hook never initialised cannot be one of ours; there is nothing to record and nothing to
        // refuse, and reverting here would be a revert for a non-rail reason.
        HookStateLib.Config memory c = HookStateLib.unpackConfig(_cfg[id]);
        if (!c.initialized) return (BaseHook.afterSwap.selector, int128(0));

        HookStateLib.Dynamic memory d = HookStateLib.unpackDynamic(_dyn[id]);
        HookStateLib.Armed memory a = HookStateLib.unpackArmed(_arm[id]);

        (, int24 tick,,) = PoolStateLib.slot0(poolManager, id);
        int24 previousTick = d.lastTick;

        // 2. The truncated observation, the high-water mark and the 30-minute TWAP (I25, I33).
        _record(id, c.maxTickMovePerBlock, tick);

        // 3. EWMA realised variance on the raw tick delta, and the pre-computed `f_vol`.
        _updateVariance(d, a, tick);

        // 4. The rotation credit, from the realised delta and never the requested amount (I26), to the buyer and
        //    no one else — and only when the buy was the protocol router's rotation hop (I26, revision 6). An
        //    ordinary buy pays `ampsFeeBps` and earns nothing, so there is nothing for it to leave behind.
        if (!params.zeroForOne && _isPassThrough(sender, hookData)) _credit(sender, delta);

        // 5. Surge and capture are decayed at quote time; this only clears them once they are worth nothing.
        _clearDecayed(a);

        // 6 and 7. The dividend-step detector and the gate cache, at most once per pool per `gateCacheSeconds`.
        //
        // §1.5 numbers the refresh 6 and the detector 7; they run the other way round here because the detector
        // owns `gateFlags.caArmed` and the refresh is what turns that flag into `dynCapBps`. Running the refresh
        // first would leave a corporate action's escalation cap - or its removal - one whole interval late.
        if (_elapsed(d.gateAttemptedAt) >= _gateCache) {
            bool probeFailed;
            if (c.poolClass != PoolClass.ENTRY) {
                probeFailed = _detectMultiplierStep(id, Currency.unwrap(key.currency1), d, a);
            }
            _refreshGate(id, c, d, a, probeFailed);
        }

        // 8. One dirty `SSTORE` per word.
        d.lastTick = tick;
        d.lastUpdate = uint32(block.timestamp);
        _dyn[id] = HookStateLib.packDynamic(d);
        _arm[id] = HookStateLib.packArmed(a);

        // Both deviations are measured against the fair tick now in force, so that what is compared is the
        // swap's own contribution and not a fair-tick move the refresh above may have just applied.
        int24 devAfter = _deviation(tick, d.fairTick);
        if (devAfter > d.innerBandTicks / 2) emit RebalanceNeeded(id, tick, d.fairTick);

        // 9. The post-swap half of the rail check: refuse a swap that ended beyond the rail having increased the
        //    deviation. The state written above is rolled back with it.
        if (devAfter > _deviation(previousTick, d.fairTick)) {
            int24 rail = _effective(c, d).railTicks;
            if (devAfter > rail) revert BeyondRail(PoolId.unwrap(id), devAfter, rail);
        }

        return (BaseHook.afterSwap.selector, int128(0));
    }

    /// @dev Step 2 of §1.5, kept out of `afterSwap`'s frame so the legacy pipeline has stack left for the rest.
    ///      Reading the high-water mark first also warms the head slot `write` is about to read five times over.
    function _record(PoolId id, int24 maxMove, int24 tick) private {
        int24 previousHighWater = _obs[id].highWaterTick;
        int24 cap = maxMove > 0 ? maxMove : Constants.MAX_TICK_MOVE_PER_BLOCK_DEFAULT;
        int24 truncated = _obs[id].write(uint32(block.timestamp), uint32(block.number), tick, cap);
        if (truncated > previousHighWater) emit HighWaterAdvanced(id, truncated);
    }

    /// @dev Step 4 of §1.5: credit the AMPS a buyer actually received, never the amount they asked for (I26), to
    ///      the account that received it and to no one else — and only when that account is {router} and the hop
    ///      carried `Constants.ROUTER_ROTATE`, which the caller has already checked.
    /// @param sender The account the PoolManager attributes the swap to; the credit's owner.
    /// @param delta The realised balance delta.
    function _credit(address sender, BalanceDelta delta) private {
        int128 ampsOut = delta.amount0();
        if (ampsOut <= 0) return;
        uint256 gained = uint256(uint128(ampsOut));
        uint256 slot = _creditSlot(sender);
        assembly ("memory-safe") {
            tstore(slot, add(tload(slot), gained))
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // The fee quote (shared by `beforeSwap` and {quoteFee})
    // -------------------------------------------------------------------------------------------------------------

    /// @dev §1.4 steps 3 to 7, with no side effects, so the view surface and the hot path cannot disagree. The
    ///      caller owns the transient slot: the credit goes in, `creditConsumed` comes out.
    function _quote(
        HookStateLib.Config memory c,
        HookStateLib.Dynamic memory d,
        HookStateLib.Armed memory a,
        SwapCtx memory ctx
    ) private view returns (Quote memory q) {
        uint16 ampsFee = _ampsFee;

        // Step 3: the base fee.
        //
        // **Revision 6.** `ampsFeeBps` is the base fee on BOTH directions of every pool, and `buyFeeBps` is the
        // *pass-through* base: the price of moving through a pool rather than entering or leaving the index
        // through it. So the default below is `ampsFeeBps`, and only the protocol router's rotation hop
        // ({_isPassThrough}) ever sees anything else.
        q.baseBps = ampsFee;

        if (ctx.passThrough) {
            if (!ctx.sell) {
                // Hop 1 of a rotation: the pass-through base outright. `afterSwap` credits what it realises.
                q.baseBps = c.buyFeeBps;
            } else if (ctx.exactInput) {
                // Hop 2: `buyFeeBps` on the AMPS this transaction's hop 1 actually bought, `ampsFeeBps` on any
                // excess. A `rotate` sells exactly what hop 1 returned, so the excess is zero and the whole sell
                // is pass-through; anything larger is an exit wearing a rotation's clothes and is priced as one.
                uint256 consumed = ctx.credit < ctx.amountIn ? ctx.credit : ctx.amountIn;
                uint256 uncredited = ctx.amountIn - consumed;
                q.creditConsumed = consumed;
                if (uncredited == 0) {
                    // Fully covered — and the degenerate `amountIn == 0` the view surface asks about, which is
                    // "what would a pass-through sell cost", not "what does a zero-sized one cost".
                    q.baseBps = c.buyFeeBps;
                } else if (ampsFee > c.buyFeeBps) {
                    // Rounded up, so a credit never rounds a fee down in the swapper's favour. `mulDivRoundingUp`
                    // carries the 512-bit intermediate the naive `(buy*c + amps*(in-c) + in-1)/in` form overflows
                    // on. The bands ([100, 600] against [1, 100]) make `ampsFee >= buyFee` structural; the guard
                    // is there so a future band change can never underflow the subtraction.
                    q.baseBps = c.buyFeeBps
                        + uint16(FullMath.mulDivRoundingUp(ampsFee - c.buyFeeBps, uncredited, ctx.amountIn));
                }
            }
            // An exact-**output** sell falls through to `ampsFeeBps`: it consumes no credit, and the router only
            // ever builds a rotation out of two exact-input hops.
        }

        // Step 4: the deviation, measured on the start-of-swap tick, and the rail.
        Effective memory e = _effective(c, d);
        q.railTicks = e.railTicks;
        q.devTicks = _deviation(d.lastTick, d.fairTick);
        bool increasing = ctx.sell ? d.lastTick <= d.fairTick : d.lastTick >= d.fairTick;
        q.refuse = increasing && q.devTicks > e.railTicks;

        // Steps 5 and 6: the dynamic components, the frozen floor and the cap.
        uint16 dynBps = _dynamicBps(c, d, a, e, ctx, increasing, q.devTicks);
        if (e.frozen && dynBps < Constants.FROZEN_FEE_FLOOR_BPS) dynBps = Constants.FROZEN_FEE_FLOOR_BPS;
        if (dynBps > e.dynCapBps) dynBps = e.dynCapBps;
        q.dynBps = dynBps;

        // Step 7: `clamp(base + dyn, F_MIN_BPS, base + dynCap)`, then the protocol-wide ceiling. The ceiling is a
        // clamp and not a `require`: `base <= 600` and `dynCap <= 2000` make it unreachable, and I15 says a swap
        // never reverts for anything but the rail.
        uint256 total = uint256(q.baseBps) + uint256(dynBps);
        if (total < Constants.F_MIN_BPS) total = Constants.F_MIN_BPS;
        if (total > Constants.TOTAL_FEE_BPS_MAX) total = Constants.TOTAL_FEE_BPS_MAX;
        q.feeBps = uint16(total);
    }

    /// @dev The pointer-upgradeable half of the fee law. A policy that has no code, reverts, runs out of its gas
    ///      allowance or returns undecodable data falls back to the cached `f_vol` — never to a revert.
    function _dynamicBps(
        HookStateLib.Config memory c,
        HookStateLib.Dynamic memory d,
        HookStateLib.Armed memory a,
        Effective memory e,
        SwapCtx memory ctx,
        bool increasing,
        int24 devTicks
    ) private view returns (uint16 dynBps) {
        address policy = _policy;
        if (policy.code.length == 0) return d.fVolBps;

        IFeePolicy.FeeInput memory input = IFeePolicy.FeeInput({
            zeroForOne: ctx.sell,
            exactInput: ctx.exactInput,
            deviationIncreasing: increasing,
            amountIn: ctx.amountIn,
            rotationCredit: ctx.credit,
            poolClass: c.poolClass,
            ampsFeeBps: _ampsFee,
            buyFeeBps: c.buyFeeBps,
            devTicks: devTicks,
            innerBandTicks: e.bandTicks,
            outerRailTicks: e.railTicks,
            varianceX18: uint128(uint256(a.varianceX12) * VARIANCE_SCALE_TO_X18),
            surgeBps: a.surgeBps,
            surgeElapsed: _elapsed(a.surgeArmedAt),
            captureFeeBps: a.captureFeeBps,
            captureElapsed: _elapsed(a.captureArmedAt),
            // A `+delta` multiplier step makes each raw stock token worth more, so the arbitrage takes stock out
            // of the pool. AMPS is `currency0` everywhere, so that direction is `zeroForOne == true`.
            captureDirectionTakesStock: ctx.sell && c.poolClass != PoolClass.ENTRY,
            // Entry-pool legs (WETH, USDG) trade 24/7 and never pay `f_session`.
            session: c.poolClass == PoolClass.ENTRY ? Session.REGULAR : d.session,
            gate: _gateStateOf(d.gateFlags),
            dynCapBps: e.dynCapBps
        });

        (bool ok, bytes memory ret) =
            policy.staticcall{gas: POLICY_PROBE_GAS}(abi.encodeCall(IFeePolicy.quoteFee, (input)));
        if (!ok || ret.length < FEE_QUOTE_WORDS * 32) return d.fVolBps;

        // `FeeQuote` is five static words: feePips, baseBps, dynBps, creditConsumed, refuse. Only `dynBps` is the
        // policy's to decide; the base fee, the credit and the rail are the hook's own (§1.4).
        uint256 raw;
        assembly ("memory-safe") {
            raw := mload(add(ret, 0x60))
        }
        dynBps = raw > type(uint16).max ? type(uint16).max : uint16(raw);
    }

    /// @dev The gate view in force. Past `GATE_CACHE_MAX_AGE` the cache is not trusted and the most conservative
    ///      substitute is used instead: the widest band for the class, the degraded cap, and the frozen floor on
    ///      the dynamic part (§1.4 step 6). Nothing here reads another contract.
    function _effective(HookStateLib.Config memory c, HookStateLib.Dynamic memory d)
        private
        view
        returns (Effective memory e)
    {
        bool stale = d.gateRefreshedAt == 0 || _elapsed(d.gateRefreshedAt) > Constants.GATE_CACHE_MAX_AGE;
        if (stale) {
            e.bandTicks = Constants.INNER_BAND_MAX_TICKS;
            e.railTicks = _defaultRail(c.poolClass, e.bandTicks);
            e.dynCapBps = Constants.DYN_CAP_DEGRADED_BPS;
            e.frozen = true;
        } else {
            e.bandTicks = d.innerBandTicks;
            e.railTicks = d.outerRailTicks;
            e.dynCapBps = d.dynCapBps;
            e.frozen = HookStateLib.hasFlag(d.gateFlags, HookStateLib.FLAG_DEGRADED);
        }
        if (e.bandTicks <= 0) e.bandTicks = Constants.INNER_BAND_REGULAR_TICKS;
        if (e.railTicks <= 0) e.railTicks = _defaultRail(c.poolClass, e.bandTicks);
        if (e.dynCapBps == 0 || e.dynCapBps > Constants.DYN_CAP_ESCALATION_BPS) {
            e.dynCapBps = Constants.DYN_CAP_NORMAL_BPS;
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // afterSwap internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev EWMA variance with `lambda = LAMBDA_X18` on the raw tick delta, exactly as §1.5 step 3 gives it.
    ///
    /// @dev **Units (§12.1 ruling H).** What the policy is calibrated against is
    ///      `FeeInput.varianceX18 = EWMA(d^2) x 1e18`, where `d` is the **raw pool tick change of one swap**
    ///      (`tick_after - tick_before`, one unit = one tick ~ one basis point of price), the EWMA is updated
    ///      **once per swap** - not per block and not per second - and `lambda = 0.98` is per swap as well. At
    ///      `K_VOL_X18 = 5e15` that is `f_vol = 1 bp` at a per-swap sigma of ~14 ticks and the 100 bp cap at
    ///      ~141 ticks.
    ///
    /// @dev **The store is X12, the wire is X18.** `141^2 x 1e18` ~ 2e22 does not fit the 64 bits §1.2 gives the
    ///      packed field, so the hook keeps `EWMA(d^2) x 1e12` and scales by `VARIANCE_SCALE_TO_X18` on the way
    ///      out. `HookPoolState.varianceX18` reports the **stored X12 value**; see {poolState}.
    ///
    /// @dev **The clamp below is load-bearing, and the saturation point is *under* the arithmetic range, not
    ///      over it.** `type(uint64).max / 1e12` is ~1.84e7 ticks^2, while the largest `d^2` one swap can produce
    ///      is `(2 x MAX_TICK)^2` ~ 3.1e12 ticks^2 — about five orders of magnitude **above** the ceiling. One
    ///      swap moving ~30,370 ticks saturates the store from zero (a new observation enters weighted by
    ///      `1 - lambda = 0.02`), and a run of ~4,295-tick swaps saturates it in steady state. Dropping the clamp
    ///      would let the `uint64` cast wrap and report a *lower* variance, and therefore a lower fee, on exactly
    ///      the moves that must raise it. Saturating is otherwise harmless: `f_vol` is already pinned at
    ///      `F_VOL_CAP_BPS` from `EWMA(d^2) ~ 20,000` ticks^2 (sigma ~ 141 ticks), three orders of magnitude below
    ///      the ceiling, so every saturated value quotes the same capped `f_vol`.
    function _updateVariance(HookStateLib.Dynamic memory d, HookStateLib.Armed memory a, int24 tick) private pure {
        int256 delta = int256(tick) - int256(d.lastTick);
        uint256 squared = uint256(delta * delta);
        uint256 lambda = uint256(Constants.LAMBDA_X18);

        // Safe: `squared <= (2 * MAX_TICK)^2` ~ 3.1e12, so the second term is at most ~6.3e40 and the first at
        // most ~1.8e37 — both far inside `uint256`, so this cannot overflow. It *can* exceed `uint64`, by up to
        // ~3.4e3 x, which is what the clamp on the next line is for; see the note above.
        uint256 varianceX12 =
            (lambda * uint256(a.varianceX12) + (Constants.WAD - lambda) * squared * VARIANCE_STORE_SCALE)
                / Constants.WAD;
        if (varianceX12 > type(uint64).max) varianceX12 = type(uint64).max;
        a.varianceX12 = uint64(varianceX12);

        uint256 fVol = (Constants.K_VOL_X18 * varianceX12 * VARIANCE_SCALE_TO_X18) / 1e36;
        if (fVol > Constants.F_VOL_CAP_BPS) fVol = Constants.F_VOL_CAP_BPS;
        d.fVolBps = uint8(fVol);
    }

    /// @dev Zeroes a surge or a capture fee once it has decayed to nothing, so `_arm` does not carry dead state.
    function _clearDecayed(HookStateLib.Armed memory a) private view {
        if (a.surgeBps != 0 && _elapsed(a.surgeArmedAt) >= Constants.SURGE_HALF_LIFE * DECAY_HORIZON) {
            a.surgeBps = 0;
            a.surgeArmedAt = 0;
        }
        if (a.captureFeeBps != 0 && _elapsed(a.captureArmedAt) >= Constants.DIVIDEND_CAPTURE_HALF_LIFE * DECAY_HORIZON)
        {
            a.captureFeeBps = 0;
            a.captureArmedAt = 0;
        }
    }

    /// @dev §1.5 step 6. One bounded snapshot from the gate, the class's band and rail from the policy, and the
    ///      pool's own truncated TWAP as the fair tick for entry pools always and for a spoke whose snapshot did
    ///      not answer. Any failure raises `refreshFailed`, leaves every cached value in place and still advances
    ///      `gateAttemptedAt`, so a broken gate costs one bounded call per pool per interval and never a swap.
    function _refreshGate(
        PoolId id,
        HookStateLib.Config memory c,
        HookStateLib.Dynamic memory d,
        HookStateLib.Armed memory a,
        bool probeFailed
    ) private {
        d.gateAttemptedAt = uint32(block.timestamp);
        GateView memory g = _readGate(id, c, d);

        // A reference jump larger than `SURGE_REF_JUMP_BPS` arms a surge, so a fair-tick move cannot be
        // sandwiched at the old fee. One tick is one basis point to within 0.005%.
        if (_deviation(g.fairTick, d.fairTick) > int24(uint24(Constants.SURGE_REF_JUMP_BPS))) {
            _armSurgeMemory(id, a, Constants.SURGE_MAX_BPS, "refJump");
        }
        // A session opening up (towards `REGULAR`) does the same.
        if (g.session < uint8(d.session)) _armSurgeMemory(id, a, Constants.SURGE_MAX_BPS, "sessionOpen");

        d.session = Session(g.session);
        d.fairTick = g.fairTick;
        d.innerBandTicks = g.bandTicks;
        d.outerRailTicks = g.railTicks;
        d.dynCapBps = HookStateLib.hasFlag(d.gateFlags, HookStateLib.FLAG_CA_ARMED)
            ? Constants.DYN_CAP_ESCALATION_BPS
            : g.dynCapBps;
        d.gateFlags = HookStateLib.withFlag(d.gateFlags, HookStateLib.FLAG_DEGRADED, g.degraded);
        d.gateFlags = HookStateLib.withFlag(d.gateFlags, HookStateLib.FLAG_CORPORATE_FREEZE, g.corporateFreeze);
        // `refreshFailed` covers the whole interval's external work, the token probe included, which is why the
        // detector's verdict is threaded in rather than written by the detector itself: this is the one place the
        // flag is set, so it can also be the one place it is cleared.
        d.gateFlags = HookStateLib.withFlag(d.gateFlags, HookStateLib.FLAG_REFRESH_FAILED, !g.ok || probeFailed);
        if (g.ok) d.gateRefreshedAt = uint32(block.timestamp);

        emit GateCacheRefreshed(id, d.gateFlags, g.session, d.dynCapBps, g.bandTicks, g.railTicks, g.fairTick);
    }

    /// @dev The read half of the refresh: the cached view first, then whatever the gate and the policy are
    ///      willing to answer, each one bounded and hand-decoded. `g.ok` is false as soon as anything failed.
    function _readGate(PoolId id, HookStateLib.Config memory c, HookStateLib.Dynamic memory d)
        private
        view
        returns (GateView memory g)
    {
        g.ok = true;
        g.session = uint8(d.session);
        g.dynCapBps = d.dynCapBps;
        g.fairTick = d.fairTick;
        g.bandTicks = d.innerBandTicks;
        g.railTicks = d.outerRailTicks;
        g.degraded = HookStateLib.hasFlag(d.gateFlags, HookStateLib.FLAG_DEGRADED);
        g.corporateFreeze = HookStateLib.hasFlag(d.gateFlags, HookStateLib.FLAG_CORPORATE_FREEZE);

        address gate = _gateAddress();
        bool snapshotOk = gate != address(0) && _snapshotInto(gate, id, c.poolClass, g);
        if (!snapshotOk) g.ok = false;

        // An entry pool's fair tick is its own truncated TWAP: WETH and USDG trade 24/7 and have no equity feed to
        // be measured against (§1.5 step 6).
        //
        // A spoke falls back to the same reading when — and only when — the snapshot did not answer. Its fair tick
        // is normally `tickOf(P_mkt / P_i)` derived by the gate, and leaving that value pinned while the gate is
        // unreachable is worse than it looks: a pool whose snapshot has *never* succeeded would keep the opening
        // tick as its reference for as long as the outage lasts, so every deviation, every rail check and every
        // `RebalanceNeeded` would be measured against a price that stopped being true at initialisation. Its own
        // truncated TWAP is at least a real, manipulation-capped reading of where the pool has been. The ring is
        // used only once it actually covers the window; below that the last known fair tick stands, because a
        // half-covered ring is not a reference and zero is not one either.
        if (c.poolClass == PoolClass.ENTRY || !snapshotOk) {
            if (_obs[id].observationCoverage(uint32(block.timestamp)) >= TruncatedOracleLib.TWAP_WINDOW) {
                g.fairTick = _obs[id].twap30m(uint32(block.timestamp));
            }
        }

        // `closedHours` walks the calendar (see {POINTER_PROBE_GAS}), so it is metered against the snapshot's
        // budget and not the pointer one - it is the most expensive read on this path after the snapshot itself.
        if (g.session == uint8(Session.CLOSED) && gate != address(0)) {
            (bool got, uint256 hoursClosed) =
                _staticUint(gate, abi.encodeCall(IOracleGate.closedHours, ()), GATE_PROBE_GAS);
            if (got) g.closedHours = hoursClosed > type(uint16).max ? type(uint16).max : uint16(hoursClosed);
            else g.ok = false;
        }

        _bandsInto(c.poolClass, g);

        if (g.dynCapBps == 0 || g.dynCapBps > Constants.DYN_CAP_ESCALATION_BPS) {
            g.dynCapBps = Constants.DYN_CAP_NORMAL_BPS;
        }
    }

    /// @dev The five fields of `GateSnapshot` the hook caches, decoded by hand out of the thirteen static words a
    ///      well-formed snapshot returns and clamped so that no value a hostile gate can invent reaches storage.
    /// @return ok Whether the gate answered with a well-formed snapshot at all. The caller needs this separately
    ///         from `g.ok` — which the policy reads below can also clear — to decide whether a spoke's fair tick
    ///         has to fall back to the pool's own truncated TWAP.
    function _snapshotInto(address gate, PoolId id, PoolClass poolClass, GateView memory g)
        private
        view
        returns (bool ok)
    {
        (bool called, bytes memory ret) =
            gate.staticcall{gas: GATE_PROBE_GAS}(abi.encodeCall(IOracleGate.snapshotByPool, (id)));
        if (!called || ret.length < GATE_SNAPSHOT_WORDS * 32) return false;

        uint256 state_;
        uint256 session_;
        uint256 freeze_;
        uint256 cap_;
        int256 fair_;
        assembly ("memory-safe") {
            let p := add(ret, 0x20)
            state_ := mload(p) // 0: GateState
            session_ := mload(add(p, 0x20)) // 1: Session
            freeze_ := mload(add(p, 0x60)) // 3: corporateFreeze
            cap_ := mload(add(p, 0xe0)) // 7: dynCapBps
            fair_ := mload(add(p, 0x120)) // 9: fairTick
        }

        // An out-of-range enum is read as the worse state; an out-of-range cap or tick is ignored.
        g.degraded = state_ != uint256(uint8(GateState.GREEN));
        g.session = session_ > uint256(uint8(type(Session).max)) ? uint8(Session.CLOSED) : uint8(session_);
        g.corporateFreeze = freeze_ != 0;
        g.dynCapBps = cap_ > Constants.DYN_CAP_ESCALATION_BPS ? Constants.DYN_CAP_ESCALATION_BPS : uint16(cap_);
        // A spoke's fair tick is `tickOf(P_mkt / P_i)`, which the gate derives from the hub TWAP and the
        // constituent's feed; zero means it could not derive one, and the cached value stands.
        if (poolClass != PoolClass.ENTRY && fair_ != 0 && fair_ >= TickMath.MIN_TICK && fair_ <= TickMath.MAX_TICK) {
            g.fairTick = int24(fair_);
        }

        ok = true;
    }

    /// @dev The class's band and rail from the pure fee policy. Both are single words, so both are decoded by
    ///      hand and range-checked before either can become a rail a swap is refused against.
    function _bandsInto(PoolClass poolClass, GateView memory g) private view {
        address policy = _policy;
        if (policy.code.length == 0) {
            g.ok = false;
            return;
        }

        (bool gotBand, int256 bandRaw) = _staticInt(
            policy, abi.encodeCall(IFeePolicy.innerBandTicks, (poolClass, Session(g.session), g.closedHours))
        );
        if (!gotBand || bandRaw <= 0 || bandRaw > Constants.INNER_BAND_MAX_TICKS) {
            g.ok = false;
            return;
        }

        (bool gotRail, int256 railRaw) =
            _staticInt(policy, abi.encodeCall(IFeePolicy.outerRailTicks, (poolClass, int24(bandRaw))));
        if (!gotRail || railRaw <= 0 || railRaw > TickMath.MAX_TICK) {
            g.ok = false;
            return;
        }

        g.bandTicks = int24(bandRaw);
        g.railTicks = int24(railRaw);
    }

    /// @dev §1.5 step 7. `0 < delta <= DIVIDEND_STEP_BPS_MAX` arms the asymmetric capture fee; a larger step is a
    ///      corporate action and raises `gateFlags.caArmed` instead, which the refresh turns into the escalation
    ///      cap. The cached multiplier moves either way.
    /// @param id The pool.
    /// @param token The constituent's Stock Token, which is the pool's `currency1`.
    /// @param d The pool's dynamic state, updated in place.
    /// @param a The pool's armed state, updated in place.
    /// @return probeFailed Whether `uiMultiplier()` could not be read, for the caller to fold into `refreshFailed`.
    function _detectMultiplierStep(PoolId id, address token, HookStateLib.Dynamic memory d, HookStateLib.Armed memory a)
        private
        returns (bool probeFailed)
    {
        a.lastCorporateCheck = uint32(block.timestamp);

        uint256 m = _probeMultiplier(token);
        if (m == 0) return true;

        // Compare like with like. `uiMultiplierX18` is the **saturated** cast of the last reading, so measuring
        // the step against the un-saturated `m` would recompute the same phantom step on every single refresh once
        // a token's `uiMultiplier()` passed `type(uint64).max`: `FLAG_CA_ARMED` would latch for good (a step above
        // `DIVIDEND_STEP_BPS_MAX`) or a capture fee and a surge would be re-armed forever (a step below it), and
        // {_clearCorporateAction} — which only runs when the measured step is small — would never be reached
        // again. Measured against the stored value, a saturated reading yields `deltaBps == 0`, which is this
        // detector's "nothing observed".
        uint256 previous = a.uiMultiplierX18;
        uint256 current = _toUint64(m);
        a.uiMultiplierX18 = uint64(current);

        uint256 deltaBps;
        if (previous != 0 && current > previous) deltaBps = ((current - previous) * Constants.BPS) / previous;

        if (
            deltaBps <= Constants.DIVIDEND_STEP_BPS_MAX && HookStateLib.hasFlag(d.gateFlags, HookStateLib.FLAG_CA_ARMED)
        ) {
            _clearCorporateAction(token, d);
        }
        if (deltaBps == 0) return false;

        if (deltaBps <= Constants.DIVIDEND_STEP_BPS_MAX) {
            uint16 captureFeeBps = uint16((deltaBps * Constants.DIVIDEND_CAPTURE_NUMERATOR_BPS) / Constants.BPS);
            a.captureFeeBps = captureFeeBps;
            a.captureArmedAt = uint32(block.timestamp);
            _armSurgeMemory(id, a, Constants.SURGE_MAX_BPS, "multiplierStep");
            emit MultiplierStepDetected(id, previous, m, captureFeeBps);
        } else {
            d.gateFlags = HookStateLib.withFlag(d.gateFlags, HookStateLib.FLAG_CA_ARMED, true);
            emit MultiplierStepDetected(id, previous, m, 0);
        }
    }

    /// @dev Lowers `gateFlags.caArmed` once the corporate action it was raised for is over: no further step this
    ///      interval, the issuer's oracle un-paused, and no `effectiveAt` inside the corporate-action window.
    ///
    /// @dev **Why the hook has to clear it.** `OracleGate` reads bit 3 to shut a constituent's bonds and
    ///      placements, so a flag the hook only ever raises would freeze that constituent for good. Both probes
    ///      are bounded and only run while the flag is up, so the common path pays nothing for them; a probe that
    ///      cannot be read leaves the flag exactly where it is, which is the conservative answer.
    /// @param token The constituent's Stock Token.
    /// @param d The pool's dynamic state, updated in place.
    function _clearCorporateAction(address token, HookStateLib.Dynamic memory d) private view {
        if (token.code.length == 0) return;

        (bool gotPaused, uint256 paused) =
            _staticUint(token, abi.encodeCall(IStockToken.oraclePaused, ()), POINTER_PROBE_GAS);
        if (!gotPaused || paused != 0) return;

        (bool gotEffective, uint256 effectiveAt) =
            _staticUint(token, abi.encodeCall(IStockToken.effectiveAt, ()), POINTER_PROBE_GAS);
        if (!gotEffective) return;
        if (effectiveAt != 0) {
            uint256 nowTs = block.timestamp;
            uint256 distance = effectiveAt > nowTs ? effectiveAt - nowTs : nowTs - effectiveAt;
            if (distance <= Constants.CORPORATE_ACTION_WINDOW_DEFAULT) return;
        }

        d.gateFlags = HookStateLib.withFlag(d.gateFlags, HookStateLib.FLAG_CA_ARMED, false);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Bounded external reads
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The gate pointer, read from the vault rather than held immutable: `OracleGate` is pointer-upgradeable
    ///      and is redeployed in Phase 3 (§10 ruling 10), so a hook that froze its address would go blind.
    function _gateAddress() private view returns (address gate) {
        (bool ok, uint256 word) = _staticUint(vault, abi.encodeCall(IAmpsVault.oracleGate, ()), POINTER_PROBE_GAS);
        if (!ok) return address(0);
        gate = address(uint160(word));
        if (gate.code.length == 0) gate = address(0);
    }

    /// @dev `uiMultiplier()` under `Constants.STOCK_TOKEN_PROBE_GAS`. Zero means "could not read it", which is a
    ///      flag and never a revert; the issuer's token is the least trustworthy contract the hook touches.
    function _probeMultiplier(address token) private view returns (uint256 multiplier) {
        if (token.code.length == 0) return 0;
        (bool ok, bytes memory ret) =
            token.staticcall{gas: Constants.STOCK_TOKEN_PROBE_GAS}(abi.encodeCall(IStockToken.uiMultiplier, ()));
        if (!ok || ret.length < 32) return 0;
        assembly ("memory-safe") {
            multiplier := mload(add(ret, 0x20))
        }
    }

    /// @dev One bounded `staticcall` returning one unsigned word. The budget is a parameter because the callers
    ///      are not alike: `IAmpsVault.oracleGate` and the Stock Token's two flags are slot reads,
    ///      `IOracleGate.closedHours` walks a calendar. See {POINTER_PROBE_GAS}.
    function _staticUint(address target, bytes memory data, uint256 gasBudget)
        private
        view
        returns (bool ok, uint256 word)
    {
        bytes memory ret;
        (ok, ret) = target.staticcall{gas: gasBudget}(data);
        if (!ok || ret.length < 32) return (false, 0);
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
    }

    /// @dev One bounded `staticcall` returning one signed word.
    function _staticInt(address target, bytes memory data) private view returns (bool ok, int256 word) {
        bytes memory ret;
        (ok, ret) = target.staticcall{gas: POLICY_PROBE_GAS}(data);
        if (!ok || ret.length < 32) return (false, 0);
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Pure helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `|a - b|` in int256, clamped into `int24`. Two ticks are at most `2 * MAX_TICK` apart, which does not
    ///      fit in `int24`, so the subtraction is done wide and the result saturated.
    function _deviation(int24 a, int24 b) private pure returns (int24 dev) {
        int256 delta = int256(a) - int256(b);
        if (delta < 0) delta = -delta;
        dev = delta > TickMath.MAX_TICK ? TickMath.MAX_TICK : int24(delta);
    }

    /// @dev Seconds since `since`. An unset stamp reads as "forever ago", which is what makes
    ///      `gateAttemptedAt = 0` mean "refresh on the next swap" — the vault sets exactly that in {armSurge}.
    ///      A stamp in the future (only reachable by warping a test backwards) reads as zero.
    function _elapsed(uint32 since) private view returns (uint32 secondsAgo) {
        if (since == 0) return type(uint32).max;
        uint32 nowTs = uint32(block.timestamp);
        secondsAgo = since > nowTs ? 0 : nowTs - since;
    }

    /// @dev The rail the class defaults to: entry pools get a flat 2,000 ticks so price discovery is never
    ///      refused inside about +/-22% per window; spokes get `max(3 x band, 800)`.
    function _defaultRail(PoolClass poolClass, int24 band) private pure returns (int24 rail) {
        if (poolClass == PoolClass.ENTRY) return Constants.OUTER_RAIL_ENTRY_TICKS;
        rail = band * Constants.OUTER_RAIL_BAND_MULTIPLE;
        if (rail < Constants.OUTER_RAIL_MIN_TICKS) rail = Constants.OUTER_RAIL_MIN_TICKS;
    }

    /// @dev The launch buy fee of a class, used only when the registry reports none.
    function _defaultBuyFee(PoolClass poolClass) private pure returns (uint16 bps) {
        if (poolClass == PoolClass.ENTRY) return Constants.BUY_FEE_BPS_ENTRY_DEFAULT;
        if (poolClass == PoolClass.SPOKE_HIGH_VOL) return Constants.BUY_FEE_BPS_SPOKE_HIGH_VOL_DEFAULT;
        return Constants.BUY_FEE_BPS_SPOKE_DEFAULT;
    }

    /// @dev The `GateState` the cached flags summarise, for the policy's `FeeInput`. The hook caches the four
    ///      flags §1.2 defines rather than the whole enum, so this is the reverse mapping: a corporate action is a
    ///      `SCHEDULED_FREEZE`, anything else non-green is `DEGRADED`.
    function _gateStateOf(uint8 gateFlags) private pure returns (GateState gate) {
        if (HookStateLib.hasFlag(gateFlags, HookStateLib.FLAG_CORPORATE_FREEZE)) return GateState.SCHEDULED_FREEZE;
        if (HookStateLib.hasFlag(gateFlags, HookStateLib.FLAG_CA_ARMED)) return GateState.SCHEDULED_FREEZE;
        if (HookStateLib.hasFlag(gateFlags, HookStateLib.FLAG_DEGRADED)) return GateState.DEGRADED;
        gate = GateState.GREEN;
    }

    /// @dev Saturating cast, so a multiplier no `uint64` can hold cannot corrupt the ARMED word.
    function _toUint64(uint256 value) private pure returns (uint64 out) {
        out = value > type(uint64).max ? type(uint64).max : uint64(value);
    }

    /// @dev Whether this hop is the protocol router's rotation hop — the one and only pass-through case.
    ///
    /// @dev **Both halves are necessary.** The `sender` check is what confines the exemption to a contract
    ///      governance has vetted and can replace; the `hookData` flag is what confines it to the *shape* the
    ///      exemption is priced for. `AmpsRouter.buy` and `AmpsRouter.sell` pass empty `hookData` and are
    ///      therefore ordinary swaps paying `ampsFeeBps`, exactly like a swap through any other router: routing an
    ///      exit through the protocol's own front end must not make the exit cheaper. Only `AmpsRouter.rotate`
    ///      sets the flag, and it sets it on both hops of one `unlock`.
    ///
    /// @dev **Why not simply exempt every swap the router settles.** A hop's fee is fixed in `beforeSwap`, before
    ///      the swap runs, and the first hop of a route cannot know whether a second follows. Charging the
    ///      pass-through fee on hop 1 and reconciling afterwards would need the hook to hold and refund value,
    ///      which it never does (I13) — so the router declares its intent up front instead, and the hook checks
    ///      the declaration against an address only the timelock can move.
    ///
    /// @dev The length test comes before the storage read on purpose: an ordinary swap passes empty `hookData`
    ///      and therefore pays nothing at all for this check — not even the cold `SLOAD` of {router}.
    /// @param sender The account the PoolManager reports as the swap's initiator.
    /// @param hookData The bytes that account attached to this hop.
    /// @return passThrough Whether the hop is priced as one leg of a protocol rotation.
    function _isPassThrough(address sender, bytes calldata hookData) private view returns (bool passThrough) {
        if (hookData.length != 32) return false;
        bytes32 flag;
        assembly ("memory-safe") {
            flag := calldataload(hookData.offset)
        }
        if (flag != Constants.ROUTER_ROTATE) return false;
        passThrough = sender == router && sender != address(0);
    }

    /// @dev The transient slot holding one account's rotation credit: `keccak256(ROTATION_CREDIT_SLOT, sender)`.
    ///      One keccak of two words, computed at most once per callback.
    /// @param sender The credit's owner, as the PoolManager reports it.
    /// @return slot The transient slot.
    function _creditSlot(address sender) private pure returns (uint256 slot) {
        slot = uint256(keccak256(abi.encode(ROTATION_CREDIT_SLOT, sender)));
    }

    /// @dev One `TLOAD`. Not a state read, so this is legal in a `view`.
    function _tload(uint256 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /// @dev The transient rotation credit `sender` holds right now.
    function _rotationCredit(address sender) private view returns (uint256 credit) {
        credit = _tload(_creditSlot(sender));
    }

    /// @dev Arms a surge in the memory copy of the ARMED word and emits the event; the caller writes the word.
    function _armSurgeMemory(PoolId id, HookStateLib.Armed memory a, uint16 surgeBps_, bytes32 reason) private {
        a.surgeBps = surgeBps_;
        a.surgeArmedAt = uint32(block.timestamp);
        emit SurgeArmed(id, surgeBps_, reason);
    }

    // -------------------------------------------------------------------------------------------------------------
    // IMarketReference
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IMarketReference
    function twapTick(PoolId poolId, uint32 window) external view returns (int24 meanTick) {
        uint32 coverage = _requireObserved(poolId);
        if (window == 0 || window > coverage) revert WindowNotCovered(poolId, window, coverage);
        meanTick = _obs[poolId].consult(uint32(block.timestamp), window);
    }

    /// @inheritdoc IMarketReference
    function twapTick30m(PoolId poolId) external view returns (int24 meanTick) {
        uint32 coverage = _requireObserved(poolId);
        if (coverage < TruncatedOracleLib.TWAP_WINDOW) {
            revert WindowNotCovered(poolId, TruncatedOracleLib.TWAP_WINDOW, coverage);
        }
        meanTick = _obs[poolId].twap30m(uint32(block.timestamp));
    }

    /// @inheritdoc IMarketReference
    function observationCoverage(PoolId poolId) external view returns (uint32 secondsCovered) {
        secondsCovered = _obs[poolId].observationCoverage(uint32(block.timestamp));
    }

    /// @inheritdoc IMarketReference
    function lastTruncatedTick(PoolId poolId) external view returns (int24 tick) {
        _requireObserved(poolId);
        tick = _obs[poolId].lastTruncatedTick;
    }

    /// @inheritdoc IMarketReference
    function highWaterTick(PoolId poolId) external view returns (int24 tick) {
        _requireObserved(poolId);
        tick = _obs[poolId].highWaterTick;
    }

    /// @inheritdoc IMarketReference
    function twapWindow() external pure returns (uint32 window) {
        window = TruncatedOracleLib.TWAP_WINDOW;
    }

    /// @inheritdoc IMarketReference
    function maxTickMovePerBlock(PoolId poolId) external view returns (int24 cap) {
        cap = HookStateLib.unpackConfig(_cfg[poolId]).maxTickMovePerBlock;
    }

    /// @dev The ring must exist before it can be read; `observationCoverage` is what callers check to degrade.
    function _requireObserved(PoolId poolId) private view returns (uint32 coverage) {
        if (_obs[poolId].cardinality == 0) revert PoolNotObserved(poolId);
        coverage = _obs[poolId].observationCoverage(uint32(block.timestamp));
    }

    // -------------------------------------------------------------------------------------------------------------
    // IAmpsHook reads
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsHook
    function oracleGate() external view returns (address gateAddress) {
        gateAddress = _gateAddress();
    }

    /// @inheritdoc IAmpsHook
    function feePolicy() external view returns (address policyAddress) {
        policyAddress = _policy;
    }

    /// @inheritdoc IAmpsHook
    function gateCacheSeconds() external view returns (uint32 seconds_) {
        seconds_ = _gateCache;
    }

    /// @inheritdoc IAmpsHook
    /// @dev Never reverts, for any pool id at all: `PoolRegistry._openPool` reads it on the line after
    ///      `initializePool` and a revert there would silently leave the registry's grid origin at zero.
    function gridBaseTick(PoolId poolId) external view returns (int24 tick) {
        tick = HookStateLib.gridBaseTick(_cfg[poolId]);
    }

    /// @inheritdoc IAmpsHook
    /// @dev **One field's unit is not its name's.** `state.varianceX18` reports the hook's **stored X12** value,
    ///      `EWMA(d^2) x 1e12` with `d` the raw tick change of one swap; the X18 number the fee policy is
    ///      calibrated against is that times `1e6`. `Types.HookPoolState` is a Phase 2 declaration and its field
    ///      is a `uint64`, which `141^2 x 1e18` ~ 2e22 does not fit, so reporting the X18 form here would mean
    ///      saturating every value above 18.45 ticks^2 - which is nearly all of them. Nothing reads this field to
    ///      price a swap: `quoteFee` is the priced surface (§12.1 rulings H and K).
    function poolState(PoolId poolId) external view returns (HookPoolState memory state) {
        HookStateLib.Config memory c = HookStateLib.unpackConfig(_cfg[poolId]);
        HookStateLib.Dynamic memory d = HookStateLib.unpackDynamic(_dyn[poolId]);
        HookStateLib.Armed memory a = HookStateLib.unpackArmed(_arm[poolId]);

        state.initialized = c.initialized;
        state.poolClass = c.poolClass;
        state.constituentId = c.constituentId;
        state.buyFeeBps = c.buyFeeBps;
        state.tickSpacing = c.tickSpacing;
        state.maxTickMovePerBlock = c.maxTickMovePerBlock;
        state.counterDecimals = c.counterDecimals;
        state.gridBaseTick = c.gridBaseTick;

        state.uiMultiplierX18 = a.uiMultiplierX18;
        state.varianceX18 = a.varianceX12;
        state.surgeBps = a.surgeBps;
        state.surgeArmedAt = a.surgeArmedAt;
        state.captureFeeBps = a.captureFeeBps;
        state.captureArmedAt = a.captureArmedAt;
        state.lastCorporateCheck = a.lastCorporateCheck;

        state.lastSwapAt = d.lastUpdate;
        state.lastTick = d.lastTick;
        state.fairTick = d.fairTick;
        state.innerBandTicks = d.innerBandTicks;
        state.outerRailTicks = d.outerRailTicks;
        state.dynCapBps = d.dynCapBps;
        state.session = d.session;
        state.gateFlags = d.gateFlags;
        state.fVolBps = d.fVolBps;
        state.gateRefreshedAt = d.gateRefreshedAt;
    }

    /// @inheritdoc IAmpsHook
    function rotationCredit(address sender) external view returns (uint256 credit) {
        credit = _rotationCredit(sender);
    }

    /// @inheritdoc IAmpsHook
    /// @dev Never reverts. An unknown pool reports `refuse == true`, which is what a swap through it would do.
    ///
    /// @dev **It is a pure function of its arguments and the pool's state; it reads no transient storage.** The
    ///      rotation credit is keyed by the swap's `sender`, so a credit read here would be `msg.sender`'s — zero
    ///      in every fresh `eth_call`, and never the credit of the account whose swap is being priced. What
    ///      `passThrough` does instead is *model* the router hop: the credit a `rotate` carries into hop 2 is by
    ///      construction exactly the AMPS hop 1 returned, so the modelled blend is the fee the hook will charge,
    ///      to the basis point, rather than an approximation of it. `AmpsQuoter.quoteSellWithCredit` is where a
    ///      partially covered sell is priced, and it takes the credit as an argument for the same reason.
    function quoteFee(PoolId poolId, bool zeroForOne, bool exactInput, uint256 amountIn, bool passThrough)
        public
        view
        returns (uint24, uint16, uint16, bool)
    {
        if (!HookStateLib.isInitialized(_cfg[poolId])) return (0, 0, 0, true);
        uint256 modelled = exactInput ? amountIn : 0;
        SwapCtx memory ctx = SwapCtx({
            sell: zeroForOne,
            exactInput: exactInput,
            passThrough: passThrough,
            amountIn: modelled,
            // The router sells exactly what its own hop 1 bought, so a pass-through sell is fully covered.
            credit: passThrough ? modelled : 0
        });
        Quote memory q = _quote(
            HookStateLib.unpackConfig(_cfg[poolId]),
            HookStateLib.unpackDynamic(_dyn[poolId]),
            HookStateLib.unpackArmed(_arm[poolId]),
            ctx
        );
        return (uint24(q.feeBps) * Constants.PIPS_PER_BPS, q.baseBps, q.dynBps, q.refuse);
    }

    /// @inheritdoc IAmpsHook
    function quoteFee(PoolId poolId, bool zeroForOne, bool exactInput, uint256 amountIn)
        external
        view
        returns (uint24, uint16, uint16, bool)
    {
        return quoteFee(poolId, zeroForOne, exactInput, amountIn, false);
    }

    /// @inheritdoc IAmpsHook
    function innerBandTicks(PoolId poolId) external view returns (int24 ticks) {
        uint256 cfgWord = _cfg[poolId];
        if (!HookStateLib.isInitialized(cfgWord)) return 0;
        ticks = _effective(HookStateLib.unpackConfig(cfgWord), HookStateLib.unpackDynamic(_dyn[poolId])).bandTicks;
    }

    /// @inheritdoc IAmpsHook
    function outerRailTicks(PoolId poolId) external view returns (int24 ticks) {
        uint256 cfgWord = _cfg[poolId];
        if (!HookStateLib.isInitialized(cfgWord)) return 0;
        ticks = _effective(HookStateLib.unpackConfig(cfgWord), HookStateLib.unpackDynamic(_dyn[poolId])).railTicks;
    }

    /// @inheritdoc IAmpsHook
    function fairTick(PoolId poolId) external view returns (int24 tick) {
        tick = HookStateLib.unpackDynamic(_dyn[poolId]).fairTick;
    }

    /// @inheritdoc IAmpsHook
    function ampsFeeBps() external view returns (uint16 value) {
        value = _ampsFee;
    }

    /// @inheritdoc IAmpsHook
    function buyFeeBps(PoolId poolId) external view returns (uint16 value) {
        value = HookStateLib.unpackConfig(_cfg[poolId]).buyFeeBps;
    }

    /// @inheritdoc IAmpsHook
    function AMPS_FEE_BPS_MIN() external pure returns (uint16 value) {
        value = Constants.AMPS_FEE_BPS_MIN;
    }

    /// @inheritdoc IAmpsHook
    function AMPS_FEE_BPS_MAX() external pure returns (uint16 value) {
        value = Constants.AMPS_FEE_BPS_MAX;
    }

    /// @inheritdoc IAmpsHook
    function TOTAL_FEE_BPS_MAX() external pure returns (uint16 value) {
        value = Constants.TOTAL_FEE_BPS_MAX;
    }

    /// @inheritdoc IAmpsHook
    function HOOK_FLAGS() external pure returns (uint16 value) {
        value = Constants.HOOK_FLAGS;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Vault-only mutators
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsHook
    /// @dev **The mark is re-armed on the raw clock, not on the truncated one.** The vault compares the mark
    ///      against the *raw* tick bounds of the buckets it lays (`upperTick <= highWater && tick <= lowerTick`),
    ///      but `lastTruncatedTick` moves at most `maxTickMovePerBlock` per block: after a fast fall it can sit
    ///      thousands of ticks above the pool. Re-arming at it alone would leave a mark already covering the asks
    ///      `compound` re-lays at the fallen price, and the next `compound` would withdraw and burn them as
    ///      bought-back inventory that was never sold. So the mark is floored at the pool's raw tick — the same
    ///      raw post-swap tick `afterSwap` writes into the DYNAMIC word, which between swaps *is* `slot0.tick`
    ///      because nothing but a swap moves a tick — and `TruncatedOracleLib.resetHighWater` takes the minimum.
    ///      The floor can only lower the mark, so it never makes the burn more aggressive than it already was.
    function resetHighWater(PoolId poolId) external returns (int24 previousHighWaterTick) {
        if (msg.sender != vault) revert NotVault(msg.sender);
        if (!HookStateLib.isInitialized(_cfg[poolId])) revert NotInitialized();

        previousHighWaterTick = _obs[poolId].highWaterTick;
        int24 newHighWaterTick = _obs[poolId].resetHighWater(HookStateLib.lastTick(_dyn[poolId]));
        emit HighWaterReset(poolId, previousHighWaterTick, newHighWaterTick);
    }

    /// @inheritdoc IAmpsHook
    function armSurge(PoolId poolId, uint16 surgeBps_, bytes32 reason) external {
        if (msg.sender != vault) revert NotVault(msg.sender);
        if (!HookStateLib.isInitialized(_cfg[poolId])) revert NotInitialized();
        if (surgeBps_ > Constants.SURGE_MAX_BPS) {
            revert OutOfBand("surgeBps", surgeBps_, 0, Constants.SURGE_MAX_BPS);
        }

        HookStateLib.Armed memory a = HookStateLib.unpackArmed(_arm[poolId]);
        _armSurgeMemory(poolId, a, surgeBps_, reason);
        _arm[poolId] = HookStateLib.packArmed(a);

        // Force the next `afterSwap` to refresh the gate cache: a placement moves the fair tick, and the surge
        // exists so the move cannot be sandwiched at the old fee.
        HookStateLib.Dynamic memory d = HookStateLib.unpackDynamic(_dyn[poolId]);
        d.gateAttemptedAt = 0;
        _dyn[poolId] = HookStateLib.packDynamic(d);
    }

    /// @inheritdoc IAmpsHook
    /// @dev **The only writer is the vault itself**, which is what makes this safe to expose: handing the hook
    ///      over is one leg of `AmpsVault.emergencyMigrate`, and a vault that is being migrated away from is the
    ///      one contract entitled to name its successor. There is no timelock leg and no governance leg, because
    ///      a migration is not a governed parameter change — the vault's own migration path already carries the
    ///      guardian and timelock checks, and a second gate here would strand the hook whenever that path is used
    ///      in anger. The old vault loses every vault-only entry point in this contract the moment this returns.
    function setVault(address newVault) external {
        if (msg.sender != vault) revert NotVault(msg.sender);
        if (newVault == address(0)) revert ZeroAddress();

        address previous = vault;
        vault = newVault;
        emit VaultChanged(previous, newVault);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Timelock-only parameters
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsHook
    function setAmpsFeeBps(uint16 value) external {
        _onlyTimelock();
        if (value < Constants.AMPS_FEE_BPS_MIN || value > Constants.AMPS_FEE_BPS_MAX) {
            revert OutOfBand("ampsFeeBps", value, Constants.AMPS_FEE_BPS_MIN, Constants.AMPS_FEE_BPS_MAX);
        }
        uint16 previous = _ampsFee;
        _ampsFee = value;
        emit HookParameterChanged("ampsFeeBps", PoolId.wrap(bytes32(0)), previous, value);
    }

    /// @inheritdoc IAmpsHook
    function setBuyFeeBps(PoolId poolId, uint16 value) external {
        _onlyTimelock();
        uint256 cfgWord = _cfg[poolId];
        if (!HookStateLib.isInitialized(cfgWord)) revert NotInitialized();

        HookStateLib.Config memory c = HookStateLib.unpackConfig(cfgWord);
        (uint16 min, uint16 max) = c.poolClass == PoolClass.ENTRY
            ? (Constants.BUY_FEE_BPS_ENTRY_MIN, Constants.BUY_FEE_BPS_ENTRY_MAX)
            : (Constants.BUY_FEE_BPS_SPOKE_MIN, Constants.BUY_FEE_BPS_SPOKE_MAX);
        if (value < min || value > max) revert OutOfBand("buyFeeBps", value, min, max);

        uint16 previous = c.buyFeeBps;
        c.buyFeeBps = value;
        _cfg[poolId] = HookStateLib.packConfig(c);
        emit HookParameterChanged("buyFeeBps", poolId, previous, value);
    }

    /// @inheritdoc IAmpsHook
    function setMaxTickMovePerBlock(PoolId poolId, int24 value) external {
        _onlyTimelock();
        uint256 cfgWord = _cfg[poolId];
        if (!HookStateLib.isInitialized(cfgWord)) revert NotInitialized();
        if (value < Constants.MAX_TICK_MOVE_PER_BLOCK_MIN || value > Constants.MAX_TICK_MOVE_PER_BLOCK_MAX) {
            revert OutOfBand(
                "maxTickMovePerBlock",
                uint256(uint24(value)),
                uint256(uint24(Constants.MAX_TICK_MOVE_PER_BLOCK_MIN)),
                uint256(uint24(Constants.MAX_TICK_MOVE_PER_BLOCK_MAX))
            );
        }

        HookStateLib.Config memory c = HookStateLib.unpackConfig(cfgWord);
        int24 previous = c.maxTickMovePerBlock;
        c.maxTickMovePerBlock = value;
        _cfg[poolId] = HookStateLib.packConfig(c);
        emit HookParameterChanged("maxTickMovePerBlock", poolId, uint256(uint24(previous)), uint256(uint24(value)));
    }

    /// @inheritdoc IAmpsHook
    /// @dev The pointer must have code: a `staticcall` to an address with none succeeds with empty return data,
    ///      which would silently turn every dynamic component into the cached `f_vol`.
    function setFeePolicy(address newPolicy) external {
        _onlyTimelock();
        if (newPolicy == address(0) || newPolicy.code.length == 0) revert ZeroAddress();
        address previous = _policy;
        _policy = newPolicy;
        emit FeePolicyChanged(previous, newPolicy);
    }

    /// @inheritdoc IAmpsHook
    /// @dev **The zero address is a legal setting**, and it is the safe one: it turns the pass-through exemption
    ///      off entirely, so every hop in every pool pays `ampsFeeBps` until a router is named again. There is no
    ///      code check on the address either, because a router that has not been deployed yet cannot be given one
    ///      — the address is a *permission*, not a pointer the hook ever calls. Nothing here can move value,
    ///      block a swap or change a rail; the worst a wrong address can do is fail to be anybody, in which case
    ///      no hop is ever pass-through.
    function setRouter(address newRouter) external {
        _onlyTimelock();
        address previous = router;
        router = newRouter;
        emit RouterChanged(previous, newRouter);
    }

    /// @notice Sets how often `afterSwap` may refresh a pool's cached gate view. **Only timelock (48 h).**
    /// @dev Not on `IAmpsHook` — the interface declares the getter and §1.6 the setter, so this is the setter with
    ///      no interface entry. Banded `[1, GATE_CACHE_MAX_AGE]`: zero would refresh on every swap and anything
    ///      above the maximum age would leave `beforeSwap` permanently on its conservative substitute.
    /// @param value The new interval in seconds.
    function setGateCacheSeconds(uint32 value) external {
        _onlyTimelock();
        if (value == 0 || value > Constants.GATE_CACHE_MAX_AGE) {
            revert OutOfBand("gateCacheSeconds", value, 1, Constants.GATE_CACHE_MAX_AGE);
        }
        uint32 previous = _gateCache;
        _gateCache = value;
        emit HookParameterChanged("gateCacheSeconds", PoolId.wrap(bytes32(0)), previous, value);
    }

    /// @dev Every governed setter is the timelock's alone; the guardian can freeze through the gate, never here.
    function _onlyTimelock() private view {
        if (msg.sender != timelock) revert NotTimelock(msg.sender);
    }
}
