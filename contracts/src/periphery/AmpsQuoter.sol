// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsBonds} from "../interfaces/IAmpsBonds.sol";
import {IAmpsHook} from "../interfaces/IAmpsHook.sol";
import {IAmpsQuoter} from "../interfaces/IAmpsQuoter.sol";
import {IAmpsVault} from "../interfaces/IAmpsVault.sol";
import {IFeedRegistry} from "../interfaces/IFeedRegistry.sol";
import {IMarketReference} from "../interfaces/IMarketReference.sol";
import {IOracleGate} from "../interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {PriceLib} from "../lib/PriceLib.sol";
import {Constants} from "../types/Constants.sol";
import {Checkpoint, GateState, HookPoolState, PoolClass, PoolConfig, Session} from "../types/Types.sol";
import {QuoterSwapLib} from "./QuoterSwapLib.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title AmpsQuoter
/// @notice The read surface an aggregator, a solver, a front end or a monitoring job calls to price an Amplestocks
///         pool without simulating a swap, and the only contract in the system whose specification is a negative:
///         **it never reverts**.
///
/// @dev **How "never reverts" is achieved, mechanically.** Every external read is a raw `staticcall` with an
///      explicit gas cap, whose result is accepted only when the callee has code, the call succeeded, and the
///      returndata is at least as long as the ABI shape demands. The words are then unpacked by hand — never by
///      `abi.decode` into a struct — because a hostile or broken dependency can return a `bool` that is not 0 or 1,
///      an enum ordinal out of range or a dirty `uint16`, and Solidity's decoder answers those with a `Panic` that
///      `try`/`catch` does not catch. Hand-unpacking masks and clamps instead, so garbage degrades a field rather
///      than taking the quote down. The two `pure` price conversions that can revert on their own inputs
///      (`PriceLib`) are reached through gas-capped self-`staticcall`s for the same reason.
///
/// @dev **The `degraded` bitfield.** `IAmpsQuoter` names bits 0-5; this implementation adds two more, because the
///      quoter reads two sources the interface's table does not name and silently zeroing their fields would be
///      indistinguishable from a healthy zero:
///
///      | bit | source | what is zeroed when it is set |
///      |-----|--------|-------------------------------|
///      | 0   | `AmpsHook` | `fairTick`, bands, `buyFeeBps`/`sellFeeBps`, both fee legs, `refuseBuy`/`refuseSell` |
///      | 1   | `OracleGate` | `gateState`, `session`, `feedStale`, `corporateFreeze` |
///      | 2   | `FeedRegistry` | the counter-asset answer behind `pMktX18` |
///      | 3   | vault checkpoint | `navPerShareX18`, `pRefX18`, `premiumX18`, `checkpointAge` |
///      | 4   | `AmpsBonds` | `bondQX18`, `bondDiscountBps`, `bondCapacityLeft`, `bondOpen` |
///      | 5   | TWAP coverage | `pMktX18` (the ring covers less than `twapWindow`, or the tick is unreadable) |
///      | 6   | `PoolRegistry` | `counter`, `poolClass`, `tickSpacing`, `counterDecimals` (the hook is the fallback) |
///      | 7   | PoolManager | `poolTick`, and any simulated `amountOut` (an `extsload` failed, or the tick walk hit {MAX_SWAP_STEPS}) |
///
///      Bits 0-5 keep exactly the meaning `IAmpsQuoter` documents, so a consumer written against the interface is
///      unaffected by the addition. `degraded != 0` still means "do not trade on this field".
///
/// @dev **What is exact and what is not.** The fee arithmetic is exact: it is the hook's own `quoteFee` plus, for
///      hop 2 of a rotation, the same `ceilDiv` blend on the same `sellFeeBps - buyFeeBps` delta, so a rotation
///      quote matches the fee the hook will actually charge rather than approximating it. The `amountOut` of
///      {quoteExactIn} and {quoteRotation} is a full tick walk over the PoolManager's published state and matches a
///      real swap to the wei, up to two documented limits: it is bounded at {MAX_SWAP_STEPS} tick words, and it is
///      a *view* of state that any transaction landing before the caller's can move.
///
/// @dev **The rotation credit is simulated, never read.** `IAmpsHook.rotationCredit()` is EIP-1153 transient
///      storage and is therefore zero in every fresh `eth_call`; consulting it would understate hop 2's credit by
///      exactly the amount that matters. {quoteRotation} models the credit the caller's own hop 1 will create, and
///      takes the sell base from `IAmpsHook.sellFeeBps()` rather than from `quoteFee`'s `baseBps`, so a quoter
///      called from inside a transaction that already holds a credit cannot double-count it.
contract AmpsQuoter is IAmpsQuoter {
    // -------------------------------------------------------------------------------------------------------------
    // Degraded bits
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `degraded` bit 0: a read into `AmpsHook` failed.
    uint8 public constant DEGRADED_HOOK = 0x01;

    /// @notice `degraded` bit 1: a read into `OracleGate` failed.
    uint8 public constant DEGRADED_GATE = 0x02;

    /// @notice `degraded` bit 2: a read into `FeedRegistry` failed, or the counter asset has no usable answer.
    uint8 public constant DEGRADED_FEEDS = 0x04;

    /// @notice `degraded` bit 3: the vault checkpoint could not be read.
    uint8 public constant DEGRADED_CHECKPOINT = 0x08;

    /// @notice `degraded` bit 4: a read into `AmpsBonds` failed.
    uint8 public constant DEGRADED_BONDS = 0x10;

    /// @notice `degraded` bit 5: the pool's observation ring does not cover `twapWindow`, so there is no `P_mkt`.
    uint8 public constant DEGRADED_TWAP = 0x20;

    /// @notice `degraded` bit 6: a read into `PoolRegistry` failed. Not named by `IAmpsQuoter`; see the contract
    ///         NatSpec.
    uint8 public constant DEGRADED_REGISTRY = 0x40;

    /// @notice `degraded` bit 7: a PoolManager `extsload` failed, or a tick walk did not finish. Not named by
    ///         `IAmpsQuoter`; see the contract NatSpec.
    uint8 public constant DEGRADED_POOL = 0x80;

    // -------------------------------------------------------------------------------------------------------------
    // Bounds
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Gas forwarded to an ordinary bounded read (registry, hook, vault, feeds, PoolManager).
    /// @dev Generous enough that no healthy dependency is ever cut short, and small enough that a hostile one
    ///      cannot consume the caller's whole budget in a single read.
    uint256 public constant PROBE_GAS = 400_000;

    /// @notice Gas forwarded to `OracleGate` and `AmpsBonds`, both of which do real work per call (the calendar
    ///         walk, the feed round trip, the bond curve).
    uint256 public constant DEEP_PROBE_GAS = 2_000_000;

    /// @notice Gas forwarded to one simulated swap.
    uint256 public constant SIMULATION_GAS = 6_000_000;

    /// @notice The tick-walk bound of a single simulated swap. A quote that needs more sets bit 7.
    uint256 public constant MAX_SWAP_STEPS = 96;

    /// @notice Ticks below the NAV/share tick at which {navRail} reports a pool to be under the redemption floor.
    /// @dev `Constants.OUTER_RAIL_MIN_TICKS` (800), the plan's "NAV x (1 - 800 ticks)" rail, read from the shared
    ///      constant rather than restated so the two can never drift.
    int24 public constant NAV_RAIL_TICKS = Constants.OUTER_RAIL_MIN_TICKS;

    // -------------------------------------------------------------------------------------------------------------
    // Wiring (immutable: a quoter that can be re-pointed is a quoter that can be made to lie)
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The v4 PoolManager, read only through the MIT `IExtsload`.
    IExtsload internal immutable _poolManager;

    /// @dev `AmpsHook`.
    address internal immutable _hook;

    /// @dev `AmpsVault`.
    address internal immutable _vault;

    /// @dev `PoolRegistry`.
    address internal immutable _registry;

    /// @dev `AmpsBonds`.
    address internal immutable _bonds;

    /// @dev `OracleGate`. Pointer-upgradeable in the protocol, immutable here: this contract is redeployed with it.
    address internal immutable _oracleGate;

    /// @dev `FeedRegistry`.
    address internal immutable _feedRegistry;

    /// @notice Deploys the quoter against a wired protocol.
    /// @dev No address is required to be non-zero and none is required to have code. A missing dependency is a
    ///      degraded bit, not a failed deployment: the quoter is deployed alongside the system it reads and must
    ///      answer usefully while the rest of it is still being wired.
    /// @param poolManager_ The v4 PoolManager.
    /// @param hook_ `AmpsHook`.
    /// @param vault_ `AmpsVault`.
    /// @param registry_ `PoolRegistry`.
    /// @param bonds_ `AmpsBonds`.
    /// @param oracleGate_ `OracleGate`.
    /// @param feedRegistry_ `FeedRegistry`.
    constructor(
        address poolManager_,
        address hook_,
        address vault_,
        address registry_,
        address bonds_,
        address oracleGate_,
        address feedRegistry_
    ) {
        _poolManager = IExtsload(poolManager_);
        _hook = hook_;
        _vault = vault_;
        _registry = registry_;
        _bonds = bonds_;
        _oracleGate = oracleGate_;
        _feedRegistry = feedRegistry_;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Wiring reads
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsQuoter
    function vault() external view returns (address vaultAddress) {
        return _vault;
    }

    /// @inheritdoc IAmpsQuoter
    function registry() external view returns (address registryAddress) {
        return _registry;
    }

    /// @inheritdoc IAmpsQuoter
    function hook() external view returns (address hookAddress) {
        return _hook;
    }

    /// @inheritdoc IAmpsQuoter
    function bonds() external view returns (address bondsAddress) {
        return _bonds;
    }

    /// @notice The v4 PoolManager this quoter reads pool state from.
    /// @return poolManagerAddress The PoolManager.
    function poolManager() external view returns (address poolManagerAddress) {
        return address(_poolManager);
    }

    /// @notice The oracle gate this quoter reads per-pool gate flags from.
    /// @return gateAddress The gate.
    function oracleGate() external view returns (address gateAddress) {
        return _oracleGate;
    }

    /// @notice The feed registry this quoter reads counter-asset prices from.
    /// @return feedRegistryAddress The feed registry.
    function feedRegistry() external view returns (address feedRegistryAddress) {
        return _feedRegistry;
    }

    /// @inheritdoc IAmpsQuoter
    function version() external pure returns (bytes32 id) {
        return "amps-quoter-v1";
    }

    // -------------------------------------------------------------------------------------------------------------
    // The pool quote
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsQuoter
    function quotePool(PoolId poolId) public view returns (PoolQuote memory quote) {
        quote.poolId = poolId;

        (bool okRegistry, PoolConfig memory cfg) = _poolConfig(poolId);
        if (!okRegistry) quote.degraded |= DEGRADED_REGISTRY;
        quote.poolClass = cfg.poolClass;
        quote.counter = cfg.counter;

        (bool okHook, HookPoolState memory hookState) = _poolState(poolId);
        if (!okHook) {
            quote.degraded |= DEGRADED_HOOK;
        } else {
            quote.fairTick = hookState.fairTick;
            quote.innerBandTicks = hookState.innerBandTicks;
            quote.outerRailTicks = hookState.outerRailTicks;
            quote.dynCapBps = hookState.dynCapBps;
            quote.session = uint8(hookState.session);
            quote.buyFeeBps = hookState.buyFeeBps;
            quote.corporateFreeze = hookState.gateFlags & 0x02 != 0;
            // The hook mirrors the registry's shape into its own CONFIG word at `afterInitialize`, so it is the
            // fallback when the registry cannot answer — which is why a registry outage still leaves a usable quote.
            if (!okRegistry) {
                quote.poolClass = hookState.poolClass;
                cfg.counterDecimals = hookState.counterDecimals;
                cfg.tickSpacing = hookState.tickSpacing;
                cfg.constituentId = hookState.constituentId;
            }
        }

        (bool okSlot0, uint160 sqrtPriceX96, int24 tick) = _slot0(poolId);
        if (!okSlot0) quote.degraded |= DEGRADED_POOL;
        else if (sqrtPriceX96 != 0) quote.poolTick = tick;

        _fillFees(quote, poolId);
        _fillGate(quote, poolId);
        _fillCheckpoint(quote);
        _fillMarketPrice(quote, poolId, cfg);
        _fillBond(quote, cfg.counter);
    }

    /// @inheritdoc IAmpsQuoter
    function quoteAll() external view returns (PoolQuote[] memory quotes) {
        PoolId[] memory ids = poolIds();
        quotes = new PoolQuote[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            quotes[i] = quotePool(ids[i]);
        }
    }

    /// @notice Every pool the registry knows about, in its own order: the hub, the WETH entry pool, then one spoke
    ///         per constituent id.
    /// @dev Bounded by `Constants.MAX_CONSTITUENTS + 2`. A pool the registry cannot answer for is returned as
    ///      `bytes32(0)`, which {quotePool} renders as a zeroed quote with `poolClass == NONE`.
    /// @return ids The pool ids.
    function poolIds() public view returns (PoolId[] memory ids) {
        uint256 count = _uintRead(_registry, abi.encodeWithSelector(IPoolRegistry.constituentCount.selector));
        if (count > Constants.MAX_CONSTITUENTS) count = Constants.MAX_CONSTITUENTS;

        ids = new PoolId[](count + 2);
        ids[0] = PoolId.wrap(bytes32(_uintRead(_registry, abi.encodeWithSelector(IPoolRegistry.hubPoolId.selector))));
        ids[1] = PoolId.wrap(bytes32(_uintRead(_registry, abi.encodeWithSelector(IPoolRegistry.wethPoolId.selector))));
        for (uint256 i = 0; i < count; ++i) {
            ids[i + 2] = PoolId.wrap(
                bytes32(_uintRead(_registry, abi.encodeWithSelector(IPoolRegistry.poolIdOf.selector, uint16(i + 1))))
            );
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Amount-level quotes
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Prices one exact-input swap: the fee the hook would charge, whether it would be refused, and the
    ///         output a full tick walk over the PoolManager's published state produces.
    /// @dev Never reverts. `amountOut` is zero whenever the swap would be refused, the pool is not initialised, or
    ///      the walk could not finish — all three of which also raise a bit in `degraded`, except the refusal,
    ///      which is reported through `refuse`.
    /// @param poolId The pool.
    /// @param zeroForOne True for a sell (AMPS in), false for a buy.
    /// @param amountIn The input, in the input currency's raw units.
    /// @return amountOut The output, in the output currency's raw units.
    /// @return feePips The total fee in pips, base plus the clamped dynamic part.
    /// @return refuse Whether the hook would refuse the swap for beginning beyond the outer rail.
    /// @return degraded The bitfield, restricted to the reads this call made.
    function quoteExactIn(PoolId poolId, bool zeroForOne, uint256 amountIn)
        public
        view
        returns (uint256 amountOut, uint24 feePips, bool refuse, uint8 degraded)
    {
        bool okFee;
        (okFee, feePips,, refuse) = _quoteFee(poolId, zeroForOne, true, amountIn);
        if (!okFee) return (0, 0, false, DEGRADED_HOOK);
        if (refuse) return (0, feePips, true, 0);

        uint8 simDegraded;
        (amountOut, simDegraded) = _simulate(poolId, zeroForOne, amountIn, feePips);
        return (amountOut, feePips, false, simDegraded);
    }

    /// @inheritdoc IAmpsQuoter
    /// @dev Hop 1 is a buy in `hop1` at `buyFeeBps[hop1]` plus its dynamic part; the AMPS it yields is both hop 2's
    ///      input and hop 2's credit, so the blend below always resolves to `buyFeeBps[hop2]` for a pure rotation
    ///      and degrades continuously toward `sellFeeBps` as the caller sells more than it just bought. The general
    ///      case — selling more than the hop before it bought — is {quoteSellWithCredit}.
    /// @dev `amountOut` is **zero** whenever the route would not execute: either hop refused for beginning beyond
    ///      its outer rail, a pool unreadable, or a tick walk that did not finish. The fees are still reported in
    ///      that case, so a front end can say what the route *would* have cost; a router must treat `amountOut ==
    ///      0` as "no route" and {quotePool} or {wouldRevert} as the explanation.
    function quoteRotation(PoolId hop1, PoolId hop2, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint24 hop1FeePips, uint24 hop2FeePips, uint256 creditUsed)
    {
        bool refuse1;
        {
            bool okFee1;
            (okFee1, hop1FeePips,, refuse1) = _quoteFee(hop1, false, true, amountIn);
            if (!okFee1) return (0, 0, 0, 0);
        }

        uint256 ampsIn;
        {
            uint8 degraded;
            (ampsIn, degraded) = _simulate(hop1, false, amountIn, hop1FeePips);
            if (degraded != 0 || ampsIn == 0) return (0, hop1FeePips, 0, 0);
        }
        creditUsed = ampsIn;

        bool refuse2;
        uint8 hop2Degraded;
        (amountOut, hop2FeePips, refuse2, hop2Degraded) = quoteSellWithCredit(hop2, ampsIn, creditUsed);
        if (refuse1 || refuse2 || hop2Degraded != 0) return (0, hop1FeePips, hop2FeePips, creditUsed);
    }

    /// @notice Prices an exact-input **sell** that carries a same-transaction rotation credit, which is the shape
    ///         the dApp builds whenever a user sells more AMPS than the hop before it bought.
    /// @dev The general case of hop 2 of {quoteRotation}: `credit >= ampsIn` reproduces a pure rotation and prices
    ///      the whole sell at `buyFeeBps`, `credit == 0` prices it at `sellFeeBps`, and everything between is the
    ///      hook's `ceilDiv` blend on the uncredited excess. The credit is an argument rather than a read, because
    ///      the hook holds it in transient storage where an `eth_call` always sees zero.
    /// @param poolId The pool sold through.
    /// @param ampsIn AMPS wei sold.
    /// @param credit AMPS wei of same-transaction rotation credit the caller will hold when the sell lands.
    /// @return amountOut The counter asset received, in its raw units.
    /// @return feePips The total fee in pips, with the credit applied.
    /// @return refuse Whether the hook would refuse the sell.
    /// @return degraded The bitfield, restricted to the reads this call made.
    function quoteSellWithCredit(PoolId poolId, uint256 ampsIn, uint256 credit)
        public
        view
        returns (uint256 amountOut, uint24 feePips, bool refuse, uint8 degraded)
    {
        (bool okFee,, uint16 dynBps, bool refused) = _quoteFee(poolId, true, true, ampsIn);
        if (!okFee) return (0, 0, false, DEGRADED_HOOK);

        feePips = _blendedSellFeePips(poolId, ampsIn, credit, dynBps);
        if (feePips == 0) return (0, 0, false, DEGRADED_HOOK);
        if (refused) return (0, feePips, true, 0);

        (amountOut, degraded) = _simulate(poolId, true, ampsIn, feePips);
    }

    /// @notice Whether a swap would revert right now, and why.
    /// @dev The rail is the hook's answer, not this contract's: `IAmpsHook.quoteFee` reports the refusal that
    ///      `beforeSwap` would throw as `Errors.BeyondRail`. The quoter fails **open** — a hook it cannot read
    ///      reports `refuse == false` with bit 0 set — because a display path must not invent a refusal and an
    ///      execution path must never treat `degraded != 0` as permission to trade.
    /// @param poolId The pool.
    /// @param zeroForOne True for a sell (AMPS in).
    /// @param exactInput True for an exact-input swap.
    /// @param amount The input amount, or 0 when unknown.
    /// @return refuse Whether the swap would revert.
    /// @return reason `bytes32(0)`, `bytes32("rail")` or `bytes32("uninitialized")`.
    /// @return degraded The bitfield, restricted to the reads this call made.
    function wouldRevert(PoolId poolId, bool zeroForOne, bool exactInput, uint256 amount)
        external
        view
        returns (bool refuse, bytes32 reason, uint8 degraded)
    {
        (bool okSlot0, uint160 sqrtPriceX96,) = _slot0(poolId);
        if (!okSlot0) degraded |= DEGRADED_POOL;
        else if (sqrtPriceX96 == 0) return (true, "uninitialized", degraded);

        (bool okFee,,, bool refused) = _quoteFee(poolId, zeroForOne, exactInput, amount);
        if (!okFee) return (false, bytes32(0), degraded | DEGRADED_HOOK);
        return (refused, refused ? bytes32("rail") : bytes32(0), degraded);
    }

    /// @notice The redemption floor expressed in the pool's own ticks: the tick at which AMPS trades at NAV/share,
    ///         the rail `NAV_RAIL_TICKS` below it, and whether the pool is currently under that rail.
    /// @dev Disclosure, not enforcement. Nothing on-chain refuses a swap for being below NAV; what the plan says is
    ///      that nobody rational sells below the redemption floor, and this is the number that makes that visible.
    ///      A pool below the rail is a pool where `redeemProRata` is the better exit.
    /// @param poolId The pool.
    /// @return navTick The spacing-aligned tick at which the pool prices AMPS at NAV/share.
    /// @return railTick `navTick - NAV_RAIL_TICKS`.
    /// @return belowRail Whether the live tick is below `railTick`.
    /// @return navPerShareX18 The NAV/share the ticks were derived from.
    /// @return degraded The bitfield, restricted to the reads this call made.
    function navRail(PoolId poolId)
        external
        view
        returns (int24 navTick, int24 railTick, bool belowRail, uint256 navPerShareX18, uint8 degraded)
    {
        (bool okRegistry, PoolConfig memory cfg) = _poolConfig(poolId);
        if (!okRegistry) return (0, 0, false, 0, DEGRADED_REGISTRY);

        (bool okCheckpoint, Checkpoint memory checkpoint) = _checkpoint();
        if (!okCheckpoint) return (0, 0, false, 0, DEGRADED_CHECKPOINT);
        navPerShareX18 = checkpoint.navPerShareX18;

        (bool okAnswer, uint256 answerUsd8) = _counterAnswerUsd8(cfg.counter);
        if (!okAnswer) return (0, 0, false, navPerShareX18, DEGRADED_FEEDS);

        try this.tickAtPrice{gas: PROBE_GAS}(navPerShareX18, answerUsd8, cfg.counterDecimals, cfg.tickSpacing) returns (
            int24 tick_
        ) {
            navTick = tick_;
        } catch {
            return (0, 0, false, navPerShareX18, DEGRADED_FEEDS);
        }
        railTick = navTick - NAV_RAIL_TICKS;

        (bool okSlot0, uint160 sqrtPriceX96, int24 poolTick) = _slot0(poolId);
        if (!okSlot0 || sqrtPriceX96 == 0) return (navTick, railTick, false, navPerShareX18, DEGRADED_POOL);
        belowRail = poolTick < railTick;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Bonds
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsQuoter
    /// @dev Mirrors `AmpsBonds` by *calling* it: `q` is whatever `IAmpsBonds.quote` says it is for one whole unit
    ///      of the collateral, so the two cannot disagree about `min(qMarket, qFloor)` or about a rounding
    ///      direction. Zero is a valid answer and means the market cannot price right now.
    function bondQuote(uint16 marketId)
        public
        view
        returns (uint256 qX18, uint16 discountBps, uint256 capacityLeft, bool open, uint8 degraded)
    {
        if (marketId == 0) return (0, 0, 0, false, 0);

        uint256 unit = 1e18;
        (bool okMarket, bytes memory market) =
            _read(_bonds, abi.encodeWithSelector(IAmpsBonds.market.selector, marketId), PROBE_GAS, 15);
        if (!okMarket) {
            degraded |= DEGRADED_BONDS;
        } else {
            open = _word(market, 2) != 0;
            uint8 decimals = uint8(_word(market, 3));
            if (decimals <= 18) unit = 10 ** uint256(decimals);
        }

        (bool okQuote, bytes memory data) =
            _read(_bonds, abi.encodeWithSelector(IAmpsBonds.quote.selector, marketId, unit), DEEP_PROBE_GAS, 6);
        if (!okQuote) return (0, 0, 0, false, degraded | DEGRADED_BONDS);

        qX18 = _word(data, 1);
        discountBps = uint16(_word(data, 2));
        capacityLeft = _word(data, 4);
        if (_word(data, 5) != 0) open = false;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Self-`staticcall` targets: `pure` conversions that revert on their own inputs
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `PriceLib.sqrtPriceX96ToAmpsPriceUsd18` at a tick, as an external `pure` so the quoter can bound it.
    /// @dev Reverts on an out-of-range tick, a zero answer or impossible decimals, which is precisely why it is
    ///      called through a `try` rather than inline.
    /// @param tick The tick.
    /// @param counterPriceUsd8 The counter asset's answer, 8 decimals.
    /// @param counterDecimals The counter asset's decimals.
    /// @return priceUsd18 The implied AMPS price in USD, 18 decimals.
    function ampsPriceAt(int24 tick, uint256 counterPriceUsd8, uint8 counterDecimals)
        external
        pure
        returns (uint256 priceUsd18)
    {
        return
            PriceLib.sqrtPriceX96ToAmpsPriceUsd18(PriceLib.tickToSqrtPriceX96(tick), counterPriceUsd8, counterDecimals);
    }

    /// @notice `PriceLib.fairTick`, as an external `pure` so the quoter can bound it.
    /// @param priceUsd18 The AMPS price in USD, 18 decimals.
    /// @param counterPriceUsd8 The counter asset's answer, 8 decimals.
    /// @param counterDecimals The counter asset's decimals.
    /// @param tickSpacing The pool's tick spacing.
    /// @return tick The spacing-aligned tick.
    function tickAtPrice(uint256 priceUsd18, uint256 counterPriceUsd8, uint8 counterDecimals, int24 tickSpacing)
        external
        pure
        returns (int24 tick)
    {
        return PriceLib.fairTick(priceUsd18, counterPriceUsd8, counterDecimals, tickSpacing);
    }

    /// @notice One bounded exact-input tick walk, exposed so the quoter can call it through a gas-capped `try` and
    ///         so an integrator can run the same simulation directly.
    /// @dev Reverts if the PoolManager cannot answer; every internal caller wraps it.
    /// @param poolId The pool.
    /// @param tickSpacing The pool's tick spacing.
    /// @param zeroForOne True for a sell (AMPS in).
    /// @param amountIn The input amount.
    /// @param feePips The total fee in pips the hook would override.
    /// @return amountOut The output amount.
    /// @return complete Whether the walk consumed the whole input within {MAX_SWAP_STEPS}.
    function simulateExactIn(PoolId poolId, int24 tickSpacing, bool zeroForOne, uint256 amountIn, uint24 feePips)
        external
        view
        returns (uint256 amountOut, bool complete)
    {
        QuoterSwapLib.Result memory result = QuoterSwapLib.exactInput(
            QuoterSwapLib.Params({
                manager: _poolManager,
                id: poolId,
                tickSpacing: tickSpacing,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                lpFeePips: feePips,
                maxSteps: MAX_SWAP_STEPS
            })
        );
        return (result.amountOut, result.complete && result.initialized);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals: filling the quote
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Both fee legs and the sell base, all from the hook. `dynBps` is reported as the larger of the two
    ///      directions' clamped dynamic components: the wall is directional (`f_dev` and the dividend capture apply
    ///      to one side only), so the single field the struct carries is the worst side, and each direction's own
    ///      dynamic part is recoverable as `feePips / PIPS_PER_BPS - baseBps`.
    function _fillFees(PoolQuote memory quote, PoolId poolId) private view {
        if (quote.degraded & DEGRADED_HOOK != 0) return;

        (bool okBuy, uint24 buyPips, uint16 buyBase, uint16 buyDyn, bool refuseBuy_) = _quoteFeeFull(poolId, false);
        (bool okSell, uint24 sellPips, uint16 sellBase, uint16 sellDyn, bool refuseSell_) = _quoteFeeFull(poolId, true);
        if (!okBuy || !okSell) {
            quote.degraded |= DEGRADED_HOOK;
            return;
        }

        quote.buyFeePips = buyPips;
        quote.sellFeePips = sellPips;
        quote.buyFeeBps = buyBase;
        quote.sellFeeBps = sellBase;
        quote.dynBps = buyDyn > sellDyn ? buyDyn : sellDyn;
        quote.refuseBuy = refuseBuy_;
        quote.refuseSell = refuseSell_;
    }

    /// @dev The gate is the authority on the session and on every freeze; the hook's cached copies are only the
    ///      fallback, because the hook refreshes them at most once per `GATE_CACHE_SECONDS_DEFAULT`.
    function _fillGate(PoolQuote memory quote, PoolId poolId) private view {
        (bool ok, bytes memory data) =
            _read(_oracleGate, abi.encodeWithSelector(IOracleGate.snapshotByPool.selector, poolId), DEEP_PROBE_GAS, 13);
        if (!ok) {
            quote.degraded |= DEGRADED_GATE;
            return;
        }
        uint256 gateState = _word(data, 0);
        uint256 session = _word(data, 1);
        quote.gateState = gateState > uint256(uint8(type(GateState).max)) ? 0 : uint8(gateState);
        quote.session = session > uint256(uint8(type(Session).max)) ? 0 : uint8(session);
        quote.feedStale = _word(data, 2) != 0;
        quote.corporateFreeze = _word(data, 3) != 0;
        // The hook's cached band, rail and fair tick are what `beforeSwap` charges from, so they win while it is
        // readable; the gate's copies are the fallback for a pool whose hook cannot answer.
        if (quote.degraded & DEGRADED_HOOK != 0) {
            quote.dynCapBps = uint16(_word(data, 7));
            quote.fairTick = int24(int256(_word(data, 9)));
        }
    }

    /// @dev The vault checkpoint: NAV/share, the reference and the premium between them.
    function _fillCheckpoint(PoolQuote memory quote) private view {
        (bool ok, Checkpoint memory checkpoint) = _checkpoint();
        if (!ok) {
            quote.degraded |= DEGRADED_CHECKPOINT;
            return;
        }
        quote.navPerShareX18 = checkpoint.navPerShareX18;
        quote.pRefX18 = checkpoint.pRefX18;
        if (checkpoint.navPerShareX18 != 0) {
            quote.premiumX18 = int256(FullMath.mulDiv(checkpoint.pRefX18, Constants.WAD, checkpoint.navPerShareX18))
                - int256(Constants.WAD);
        }
        quote.checkpointAge =
            block.timestamp > checkpoint.timestamp ? uint32(block.timestamp - checkpoint.timestamp) : 0;
    }

    /// @dev `P_mkt` for one pool: its own 30-minute truncated TWAP, converted through the counter asset's Chainlink
    ///      answer. Zero with bit 5 set means the ring does not cover the window yet — a young pool, not a broken
    ///      one — and that distinction is the whole reason the bit exists.
    function _fillMarketPrice(PoolQuote memory quote, PoolId poolId, PoolConfig memory cfg) private view {
        uint32 window = uint32(_uintRead(_hook, abi.encodeWithSelector(IMarketReference.twapWindow.selector)));
        (bool okCoverage, uint256 coverage) =
            _uintReadChecked(_hook, abi.encodeWithSelector(IMarketReference.observationCoverage.selector, poolId));
        if (!okCoverage || window == 0) {
            quote.degraded |= DEGRADED_HOOK | DEGRADED_TWAP;
            return;
        }
        quote.observationCoverage = uint32(coverage);
        if (coverage < window) {
            quote.degraded |= DEGRADED_TWAP;
            return;
        }

        (bool okTick, uint256 tickWord) =
            _uintReadChecked(_hook, abi.encodeWithSelector(IMarketReference.twapTick30m.selector, poolId));
        if (!okTick) {
            quote.degraded |= DEGRADED_HOOK | DEGRADED_TWAP;
            return;
        }

        (bool okAnswer, uint256 answerUsd8) = _counterAnswerUsd8(cfg.counter);
        if (!okAnswer) {
            quote.degraded |= DEGRADED_FEEDS;
            return;
        }

        try this.ampsPriceAt{gas: PROBE_GAS}(int24(int256(tickWord)), answerUsd8, cfg.counterDecimals) returns (
            uint256 price
        ) {
            quote.pMktX18 = price;
        } catch {
            quote.degraded |= DEGRADED_TWAP;
        }
    }

    /// @dev The bond terms of whichever market takes this pool's counter asset as collateral.
    function _fillBond(PoolQuote memory quote, address counter) private view {
        if (counter == address(0)) return;
        (bool ok, uint256 marketId) =
            _uintReadChecked(_bonds, abi.encodeWithSelector(IAmpsBonds.marketIdOf.selector, counter));
        if (!ok) {
            quote.degraded |= DEGRADED_BONDS;
            return;
        }
        if (marketId == 0 || marketId > type(uint16).max) return;

        (uint256 qX18, uint16 discountBps, uint256 capacityLeft, bool open, uint8 degraded) =
            bondQuote(uint16(marketId));
        quote.bondQX18 = qX18;
        quote.bondDiscountBps = discountBps;
        quote.bondCapacityLeft = capacityLeft;
        quote.bondOpen = open;
        quote.degraded |= degraded;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals: the fee arithmetic
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `IAmpsHook.quoteFee`, hand-decoded.
    function _quoteFee(PoolId poolId, bool zeroForOne, bool exactInput, uint256 amountIn)
        private
        view
        returns (bool ok, uint24 feePips, uint16 dynBps, bool refuse)
    {
        bytes memory data;
        (ok, data) = _read(
            _hook,
            abi.encodeWithSelector(IAmpsHook.quoteFee.selector, poolId, zeroForOne, exactInput, amountIn),
            PROBE_GAS,
            4
        );
        if (!ok) return (false, 0, 0, false);
        feePips = uint24(_word(data, 0));
        dynBps = uint16(_word(data, 2));
        refuse = _word(data, 3) != 0;
    }

    /// @dev {_quoteFee} with the base component as well, for the two legs of {quotePool}.
    function _quoteFeeFull(PoolId poolId, bool zeroForOne)
        private
        view
        returns (bool ok, uint24 feePips, uint16 baseBps, uint16 dynBps, bool refuse)
    {
        bytes memory data;
        (ok, data) = _read(
            _hook,
            abi.encodeWithSelector(IAmpsHook.quoteFee.selector, poolId, zeroForOne, true, uint256(0)),
            PROBE_GAS,
            4
        );
        if (!ok) return (false, 0, 0, 0, false);
        feePips = uint24(_word(data, 0));
        baseBps = uint16(_word(data, 1));
        dynBps = uint16(_word(data, 2));
        refuse = _word(data, 3) != 0;
    }

    /// @dev Hop 2 of a rotation, in the hook's own delta form:
    ///
    ///      ```
    ///      base = buyFeeBps[hop2] + ceilDiv((sellFeeBps - buyFeeBps[hop2]) * (ampsIn - credit), ampsIn)
    ///      fee  = clamp(base + dyn, F_MIN_BPS, base + dynCapBps)
    ///      ```
    ///
    ///      Rounded **up**, and carried through `FullMath.mulDivRoundingUp` so the 512-bit intermediate cannot
    ///      overflow for an `amountIn` above `2**256 / 600` the way the naive `(buy * c + sell * (in - c)) / in`
    ///      does. `dyn` arrives already clamped from `IAmpsHook.quoteFee`, and lowering the base cannot lift the
    ///      dynamic part above `base + dynCapBps`, so the upper clamp needs no restatement here.
    /// @return feePips The blended total in pips, or 0 when the hook could not be read.
    function _blendedSellFeePips(PoolId poolId, uint256 ampsIn, uint256 credit, uint16 dynBps)
        private
        view
        returns (uint24 feePips)
    {
        (bool okSell, uint256 sellFeeBps) =
            _uintReadChecked(_hook, abi.encodeWithSelector(IAmpsHook.sellFeeBps.selector));
        (bool okBuy, uint256 buyFeeBps) =
            _uintReadChecked(_hook, abi.encodeWithSelector(IAmpsHook.buyFeeBps.selector, poolId));
        if (!okSell || !okBuy) return 0;
        sellFeeBps = uint16(sellFeeBps);
        buyFeeBps = uint16(buyFeeBps);

        uint256 base = sellFeeBps;
        if (ampsIn != 0 && credit != 0 && sellFeeBps > buyFeeBps) {
            uint256 consumed = credit < ampsIn ? credit : ampsIn;
            base = buyFeeBps + FullMath.mulDivRoundingUp(sellFeeBps - buyFeeBps, ampsIn - consumed, ampsIn);
        }

        uint256 total = base + dynBps;
        if (total < Constants.F_MIN_BPS) total = Constants.F_MIN_BPS;
        if (total > Constants.TOTAL_FEE_BPS_MAX) total = Constants.TOTAL_FEE_BPS_MAX;
        return uint24(total) * Constants.PIPS_PER_BPS;
    }

    /// @dev One bounded simulation, with the pool's tick spacing resolved first.
    function _simulate(PoolId poolId, bool zeroForOne, uint256 amountIn, uint24 feePips)
        private
        view
        returns (uint256 amountOut, uint8 degraded)
    {
        (bool ok, PoolConfig memory cfg) = _poolConfig(poolId);
        int24 tickSpacing = cfg.tickSpacing;
        if (!ok || tickSpacing <= 0) {
            (bool okHook, HookPoolState memory hookState) = _poolState(poolId);
            if (!okHook) return (0, DEGRADED_REGISTRY | DEGRADED_HOOK);
            tickSpacing = hookState.tickSpacing;
            degraded |= DEGRADED_REGISTRY;
        }

        try this.simulateExactIn{gas: SIMULATION_GAS}(poolId, tickSpacing, zeroForOne, amountIn, feePips) returns (
            uint256 out, bool complete
        ) {
            if (!complete) return (0, degraded | DEGRADED_POOL);
            return (out, degraded);
        } catch {
            return (0, degraded | DEGRADED_POOL);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals: bounded reads
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `PoolRegistry.poolConfig`, hand-decoded into the eight fields of `Types.PoolConfig`.
    function _poolConfig(PoolId poolId) private view returns (bool ok, PoolConfig memory cfg) {
        bytes memory data;
        (ok, data) = _read(_registry, abi.encodeWithSelector(IPoolRegistry.poolConfig.selector, poolId), PROBE_GAS, 8);
        if (!ok) return (false, cfg);
        cfg.counter = address(uint160(_word(data, 0)));
        uint256 poolClass = _word(data, 1);
        cfg.poolClass = poolClass > uint8(type(PoolClass).max) ? PoolClass.NONE : PoolClass(poolClass);
        cfg.counterDecimals = uint8(_word(data, 2));
        cfg.tickSpacing = int24(int256(_word(data, 3)));
        cfg.buyFeeBps = uint16(_word(data, 4));
        cfg.constituentId = uint16(_word(data, 5));
        cfg.registered = _word(data, 6) != 0;
        cfg.gridBaseTick = int24(int256(_word(data, 7)));
    }

    /// @dev `IAmpsHook.poolState`, hand-decoded. Only the fields the quote renders are unpacked; the rest of the
    ///      memory view stays zero, which is why the return type is the shared struct rather than a bespoke one.
    function _poolState(PoolId poolId) private view returns (bool ok, HookPoolState memory state) {
        bytes memory data;
        (ok, data) = _read(_hook, abi.encodeWithSelector(IAmpsHook.poolState.selector, poolId), PROBE_GAS, 25);
        if (!ok) return (false, state);
        state.initialized = _word(data, 0) != 0;
        uint256 poolClass = _word(data, 1);
        state.poolClass = poolClass > uint8(type(PoolClass).max) ? PoolClass.NONE : PoolClass(poolClass);
        state.constituentId = uint16(_word(data, 2));
        state.buyFeeBps = uint16(_word(data, 3));
        state.tickSpacing = int24(int256(_word(data, 4)));
        state.innerBandTicks = int24(int256(_word(data, 13)));
        state.outerRailTicks = int24(int256(_word(data, 14)));
        state.dynCapBps = uint16(_word(data, 15));
        state.counterDecimals = uint8(_word(data, 17));
        state.gridBaseTick = int24(int256(_word(data, 18)));
        state.lastTick = int24(int256(_word(data, 19)));
        state.fairTick = int24(int256(_word(data, 20)));
        uint256 session = _word(data, 21);
        state.session = session > uint8(type(Session).max) ? Session.REGULAR : Session(session);
        state.gateFlags = uint8(_word(data, 22));
        state.fVolBps = uint8(_word(data, 23));
        state.gateRefreshedAt = uint32(_word(data, 24));
    }

    /// @dev `IAmpsVault.checkpointData`, hand-decoded into the five fields of `Types.Checkpoint`.
    function _checkpoint() private view returns (bool ok, Checkpoint memory checkpoint) {
        bytes memory data;
        (ok, data) = _read(_vault, abi.encodeWithSelector(IAmpsVault.checkpointData.selector), PROBE_GAS, 5);
        if (!ok) return (false, checkpoint);
        checkpoint.navPerShareX18 = uint128(_word(data, 0));
        checkpoint.pRefX18 = uint128(_word(data, 1));
        checkpoint.pMktX18 = uint128(_word(data, 2));
        checkpoint.timestamp = uint32(_word(data, 3));
        checkpoint.blockNumber = uint32(_word(data, 4));
    }

    /// @dev The counter asset's Chainlink answer, 8 decimals, whatever its freshness: staleness is disclosed
    ///      through `feedStale`, and refusing to render a price because a feed is one heartbeat late would leave
    ///      the dApp blank exactly when a user most wants to see where the pool is.
    function _counterAnswerUsd8(address counter) private view returns (bool ok, uint256 answerUsd8) {
        if (counter == address(0)) return (false, 0);
        bytes memory data;
        (ok, data) =
            _read(_feedRegistry, abi.encodeWithSelector(IFeedRegistry.latestAnswer.selector, counter), PROBE_GAS, 3);
        if (!ok) return (false, 0);
        answerUsd8 = _word(data, 0);
        return (answerUsd8 != 0, answerUsd8);
    }

    /// @dev The pool's `slot0`, through a bounded `extsload` rather than through `PoolStateLib` directly, so a
    ///      PoolManager that reverts, runs out of gas or answers short degrades the field instead of the call.
    function _slot0(PoolId poolId) private view returns (bool ok, uint160 sqrtPriceX96, int24 tick) {
        (bool success, bytes memory data) = _read(
            address(_poolManager),
            abi.encodeWithSignature("extsload(bytes32)", PoolStateLib.poolStateSlot(poolId)),
            PROBE_GAS,
            1
        );
        if (!success) return (false, 0, 0);
        uint256 word = _word(data, 0);
        sqrtPriceX96 = uint160(word);
        tick = int24(int256(word >> 160));
        return (true, sqrtPriceX96, tick);
    }

    /// @dev A bounded read whose answer is one word, with "the callee could not answer" collapsed into zero.
    function _uintRead(address target, bytes memory callData) private view returns (uint256 value) {
        (, value) = _uintReadChecked(target, callData);
    }

    /// @dev A bounded read whose answer is one word.
    function _uintReadChecked(address target, bytes memory callData) private view returns (bool ok, uint256 value) {
        bytes memory data;
        (ok, data) = _read(target, callData, PROBE_GAS, 1);
        if (!ok) return (false, 0);
        return (true, _word(data, 0));
    }

    /// @dev The one place an external read happens. A codeless target answers a `staticcall` *successfully* with
    ///      empty returndata, so the code check is load-bearing rather than an optimisation; the length check is
    ///      what makes hand-unpacking safe; and the gas cap is what stops a hostile dependency from consuming the
    ///      caller's whole budget. Nothing here can revert.
    function _read(address target, bytes memory callData, uint256 gasCap, uint256 words)
        private
        view
        returns (bool ok, bytes memory data)
    {
        if (target == address(0) || target.code.length == 0) return (false, data);
        (bool success, bytes memory returned) = target.staticcall{gas: gasCap}(callData);
        if (!success || returned.length < words * 32) return (false, data);
        return (true, returned);
    }

    /// @dev Word `index` of an ABI-encoded return, read without decoding. The caller has already checked the
    ///      length, so this cannot read out of bounds.
    function _word(bytes memory data, uint256 index) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }
}
