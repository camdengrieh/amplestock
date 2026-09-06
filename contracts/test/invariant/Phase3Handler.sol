// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsBonds} from "../../src/bonds/AmpsBonds.sol";
import {AmpsHook} from "../../src/hook/AmpsHook.sol";
import {BountyPot} from "../../src/keeper/BountyPot.sol";
import {OracleGate} from "../../src/oracle/OracleGate.sol";
import {AmpsQuoter} from "../../src/periphery/AmpsQuoter.sol";
import {PoolRegistry} from "../../src/registry/PoolRegistry.sol";
import {AmpsStaking} from "../../src/staking/AmpsStaking.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {Phase3Ghosts} from "./Phase3Ghosts.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {PathKey} from "hookmate/interfaces/router/PathKey.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

/// @notice Everything `Phase3Handler` needs to drive the wired Phase 3 system, in one argument so the constructor
///         stays inside the stack limit.
/// @param vault The `AmpsVault`.
/// @param amps The AMPS token.
/// @param hook The real `AmpsHook`.
/// @param bonds The bonds shell.
/// @param staking xAMPS.
/// @param pot The keeper bounty pot.
/// @param gate The oracle gate.
/// @param registry The pool registry.
/// @param quoter The periphery quoter.
/// @param poolManager The v4 PoolManager.
/// @param router The v4 swap router.
/// @param permit2 Permit2.
/// @param usdg USDG, the hub's counter and the pot's token.
/// @param weth The WETH stand-in.
/// @param wethFeed The ETH/USD aggregator.
/// @param usdgFeed The USDG/USD aggregator.
/// @param timelock The governance timelock.
/// @param guardian The guardian Safe.
/// @param keeper The keeper the bounty pot pays.
/// @param hubPool The `AMPS/USDG` pool.
/// @param wethPool The `AMPS/WETH` pool.
/// @param tickSpacing The one tick spacing every pool uses.
/// @param stocks The constituent Stock Tokens.
/// @param stockFeeds Their aggregators.
/// @param constituentIds Their registry ids.
/// @param marketIds Their bond markets.
/// @param spokePools Their pools.
/// @param stockUsd8 Their launch prices.
struct Phase3Wiring {
    AmpsVault vault;
    Amps amps;
    AmpsHook hook;
    AmpsBonds bonds;
    AmpsStaking staking;
    BountyPot pot;
    OracleGate gate;
    PoolRegistry registry;
    AmpsQuoter quoter;
    IPoolManager poolManager;
    IUniswapV4Router04 router;
    IPermit2 permit2;
    address usdg;
    address weth;
    MockAggregator wethFeed;
    MockAggregator usdgFeed;
    address timelock;
    address guardian;
    address keeper;
    PoolId hubPool;
    PoolId wethPool;
    int24 tickSpacing;
    address[] stocks;
    address[] stockFeeds;
    uint16[] constituentIds;
    uint16[] marketIds;
    PoolId[] spokePools;
    uint128[] stockUsd8;
}

/// @title Phase3Handler
/// @notice `docs/phase3-state-model.md` §8.2's handler, driving the fully wired Phase 3 stack: real swaps through
///         the real hook in both directions and as a one-transaction rotation, real bonds, claims, redemptions,
///         compounds, rollouts, bonded deployments, checkpoints, a clock, feeds that move, display multipliers
///         that step and a gate that can be frozen.
///
/// @dev **This is the market-facing half of the action space.** Swaps, the one-transaction rotation, bonds and
///      claims, the clock, the feeds, the display multipliers, the gate and the direct hook probe live here;
///      `redeem`, `compound`, `rollout`, `deployBonded`, `checkpoint` and the bare removal live in
///      {Phase3VaultHandler}, and `Phase3.invariant.t.sol` targets both. The split is structural, not cosmetic:
///      with everything in one contract the handler was 31,203 B of runtime, past EIP-170, which
///      `forge build --sizes` gates and Medusa's geth enforces at deploy time - so a single handler could not be
///      fuzzed at all (§8.3). All bookkeeping moved to {Phase3Ghosts}; the action space, the ghosts and the
///      assertions are unchanged.
///
/// @dev **Nothing in here asserts.** Every action is wrapped in `try`/`catch` and every finding is recorded as a
///      ghost, which is what lets the campaign run with `fail_on_revert = false` and still prove something: a
///      revert is a legitimate outcome of a bounded action space (a cooldown, a full epoch, a frozen gate, the
///      outer rail), while a *silent* violation is not, and only the ghosts can tell them apart.
///
/// @dev **Market moves are labelled.** {moveFeed}, {stepMultiplier} and the swap actions move a price and record
///      no NAV comparison; the placement paths in {Phase3VaultHandler} do, so `navEverFell` means what I11 says.
contract Phase3Handler is CommonBase, StdCheats, StdUtils {
    // -------------------------------------------------------------------------------------------------------------
    // Wiring
    // -------------------------------------------------------------------------------------------------------------

    AmpsVault internal immutable VAULT;
    Amps internal immutable AMPS;
    AmpsHook internal immutable HOOK;
    AmpsBonds internal immutable BONDS;
    OracleGate internal immutable GATE;
    PoolRegistry internal immutable REGISTRY;
    IPoolManager internal immutable POOL_MANAGER;
    /// @dev The wiring this half of the action space does not use - the staking contract, the bounty pot, the
    ///      quoter, the timelock, the keeper and the hub pool id - is carried by `Phase3Wiring` for the other
    ///      half and by {Phase3Ghosts}, and is deliberately not held here: an unused immutable is bytecode.
    IUniswapV4Router04 internal immutable ROUTER;
    IPermit2 internal immutable PERMIT2;
    address internal immutable USDG;
    address internal immutable WETH;
    MockAggregator internal immutable WETH_FEED;
    MockAggregator internal immutable USDG_FEED;
    address internal immutable GUARDIAN;
    PoolId internal immutable WETH_POOL;
    int24 internal immutable TICK_SPACING;

    address[] internal stocks;
    address[] internal stockFeeds;
    uint16[] internal constituentIds;
    uint16[] internal marketIds;
    PoolId[] internal spokePools;
    uint128[] internal stockUsd8;
    PoolId[] internal pools;

    /// @dev The three actors the campaign trades through, so positions and balances are not all one account's.
    address internal constant TRADER = address(0x74AD34);
    address internal constant BONDER = address(0xB04DE4);

    /// @notice The shared ghost book both handlers write and the invariant suite reads.
    Phase3Ghosts internal immutable GHOSTS;

    /// @param w The whole wired world.
    /// @param ghosts_ The shared ghost book.
    constructor(Phase3Wiring memory w, Phase3Ghosts ghosts_) {
        GHOSTS = ghosts_;
        VAULT = w.vault;
        AMPS = w.amps;
        HOOK = w.hook;
        BONDS = w.bonds;
        GATE = w.gate;
        REGISTRY = w.registry;
        POOL_MANAGER = w.poolManager;
        ROUTER = w.router;
        PERMIT2 = w.permit2;
        USDG = w.usdg;
        WETH = w.weth;
        WETH_FEED = w.wethFeed;
        USDG_FEED = w.usdgFeed;
        GUARDIAN = w.guardian;
        WETH_POOL = w.wethPool;
        TICK_SPACING = w.tickSpacing;

        stocks = w.stocks;
        stockFeeds = w.stockFeeds;
        constituentIds = w.constituentIds;
        marketIds = w.marketIds;
        spokePools = w.spokePools;
        stockUsd8 = w.stockUsd8;

        pools.push(w.hubPool);
        pools.push(w.wethPool);
        for (uint256 i; i < w.spokePools.length; ++i) {
            pools.push(w.spokePools[i]);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Actions - swaps
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Buys AMPS out of one pool's ask ladder.
    /// @param poolSeed Chooses the pool.
    /// @param amountSeed Chooses the size.
    function swapBuy(uint256 poolSeed, uint256 amountSeed) external {
        GHOSTS.open("swapBuy");
        PoolId poolId = pools[poolSeed % pools.length];
        uint256 amountIn = _counterUnit(poolId) * _bound(amountSeed, 1, 40);
        _fund(_counterOf(poolId), TRADER, amountIn);

        (,,, bool refuse) = _quoteFee(poolId, false, true, amountIn);
        PoolKey memory key = REGISTRY.poolKey(poolId);
        vm.prank(TRADER);
        try ROUTER.swapExactTokensForTokens(amountIn, 0, false, key, "", TRADER, type(uint256).max) {
            GHOSTS.noteSuccess();
        } catch {
            // See {swapSell}: a router failure is not evidence about the hook, and {probeHook} is.
            refuse;
        }
        GHOSTS.close();
    }

    /// @notice Sells AMPS into one pool.
    /// @param poolSeed Chooses the pool.
    /// @param amountSeed Chooses the size.
    function swapSell(uint256 poolSeed, uint256 amountSeed) external {
        GHOSTS.open("swapSell");
        PoolId poolId = pools[poolSeed % pools.length];
        uint256 balance = AMPS.balanceOf(TRADER);
        if (balance != 0) {
            uint256 amountIn = _bound(amountSeed, 1, balance);
            (,,, bool refuse) = _quoteFee(poolId, true, true, amountIn);
            PoolKey memory key = REGISTRY.poolKey(poolId);
            _approveStack(address(AMPS), TRADER);
            vm.prank(TRADER);
            try ROUTER.swapExactTokensForTokens(amountIn, 0, true, key, "", TRADER, type(uint256).max) {
                GHOSTS.noteSuccess();
            } catch {
                // I15 through the router records nothing, deliberately: a router swap can fail for reasons that
                // have nothing to do with the hook - slippage, a price limit, a side of a pool with nothing left
                // in it - and the outer rail is checked twice, on the start-of-swap tick *and* on the post-swap
                // tick (§10 ruling 2), so a `BeyondRail` revert on a swap the start-of-swap quote was happy with
                // is correct behaviour. The invariant is tested where it is stated: directly on the hook's two
                // callbacks, in {probeHook}, with no router in the way.
                refuse;
            }
        }
        GHOSTS.close();
    }

    /// @notice A two-hop rotation `counterA -> AMPS -> counterB` inside one transaction, which is the shape the
    ///         rotation credit exists for (I26).
    /// @param aSeed Chooses hop 1's pool.
    /// @param bSeed Chooses hop 2's pool.
    /// @param amountSeed Chooses the size.
    function swapRotate(uint256 aSeed, uint256 bSeed, uint256 amountSeed) external {
        GHOSTS.open("swapRotate");
        PoolId hop1 = pools[aSeed % pools.length];
        PoolId hop2 = pools[bSeed % pools.length];
        if (PoolId.unwrap(hop1) != PoolId.unwrap(hop2)) {
            address counterIn = _counterOf(hop1);
            address counterOut = _counterOf(hop2);
            uint256 amountIn = _counterUnit(hop1) * _bound(amountSeed, 1, 20);
            _fund(counterIn, TRADER, amountIn);

            PathKey[] memory path = new PathKey[](2);
            path[0] = PathKey({
                intermediateCurrency: Currency.wrap(address(AMPS)),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(HOOK)),
                hookData: ""
            });
            path[1] = PathKey({
                intermediateCurrency: Currency.wrap(counterOut),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(HOOK)),
                hookData: ""
            });

            vm.prank(TRADER);
            try ROUTER.swapExactTokensForTokens(
                amountIn, 0, Currency.wrap(counterIn), path, TRADER, type(uint256).max
            ) {
                GHOSTS.noteSuccess();
            } catch {}
        }
        GHOSTS.close();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Actions - bonds
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Buys a bond, sized to the market's remaining capacity so the deposit is never silently over-paid.
    /// @param iSeed Chooses the market.
    /// @param amountSeed Chooses the fraction of capacity to take.
    function bond(uint256 iSeed, uint256 amountSeed) external {
        GHOSTS.open("bond");
        uint256 i = iSeed % stocks.length;
        uint256 capacity = BONDS.capacityRemaining(marketIds[i]);
        if (capacity != 0) {
            uint256 want = _bound(amountSeed, capacity / 10 + 1, capacity);
            (uint256 probeOut,,,,) = _probeQuote(marketIds[i]);
            if (probeOut != 0) {
                uint256 collateral = want * 1e18 / probeOut;
                if (collateral != 0) {
                    // The ghost writes happen *outside* the prank window on purpose: `Phase3Ghosts` only accepts
                    // writes from a named handler, and a `startPrank` that is still armed would present the
                    // bonder as the caller. `vm.prank` elsewhere in this contract is consumed by the call it
                    // precedes, so only this one - the only `startPrank` in the action space - has to be closed
                    // before the book is touched.
                    uint256 issued;
                    MockStockToken(stocks[i]).mint(BONDER, collateral);
                    vm.startPrank(BONDER);
                    MockStockToken(stocks[i]).approve(address(VAULT), type(uint256).max);
                    try BONDS.bond(marketIds[i], collateral, want / 2, BONDER) returns (uint256 out, uint256) {
                        issued = out;
                    } catch {}
                    vm.stopPrank();

                    if (issued != 0) {
                        GHOSTS.noteBond(issued);
                        GHOSTS.noteSuccess();
                    }
                }
            }
        }
        GHOSTS.close();
    }

    /// @notice Claims whatever has vested on the bonder's oldest position.
    /// @param idSeed Chooses the position.
    function claim(uint256 idSeed) external {
        GHOSTS.open("claim");
        uint256 count = BONDS.positionCount(BONDER);
        if (count != 0) {
            uint256 id = idSeed % count;
            vm.prank(BONDER);
            try BONDS.claim(id, BONDER) returns (uint256) {
                GHOSTS.noteSuccess();
            } catch {}
        }
        GHOSTS.close();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Actions - the world
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Moves the clock forward and produces blocks with it, then republishes every feed.
    /// @param dtSeed Chooses the interval.
    function warp(uint256 dtSeed) external {
        GHOSTS.open("warp");
        uint256 dt = _bound(dtSeed, 1, 3 * Constants.ONE_HOUR);
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + dt / 2 + 1);
        _republishFeeds();
        GHOSTS.noteSuccess();
        GHOSTS.close();
    }

    /// @notice Moves one Chainlink answer, which is the campaign's market move.
    /// @param iSeed Chooses the feed.
    /// @param bpsSeed Chooses the move, +/- 10%.
    function moveFeed(uint256 iSeed, uint256 bpsSeed) external {
        GHOSTS.open("moveFeed");
        uint256 i = iSeed % stocks.length;
        uint256 bps = _bound(bpsSeed, 1, 2000);
        uint128 current = stockUsd8[i];
        uint128 moved = bps < 1000
            ? uint128(uint256(current) * (Constants.BPS - bps) / Constants.BPS)
            : uint128(uint256(current) * (Constants.BPS + bps - 1000) / Constants.BPS);
        if (moved == 0) moved = 1;
        stockUsd8[i] = moved;
        MockAggregator(stockFeeds[i]).setAnswer(int256(uint256(moved)));
        GHOSTS.noteSuccess();
        GHOSTS.close();
    }

    /// @notice Steps one Stock Token's display multiplier: a dividend reinvestment, or a split.
    /// @param iSeed Chooses the token.
    /// @param bpsSeed Chooses the step.
    function stepMultiplier(uint256 iSeed, uint256 bpsSeed) external {
        GHOSTS.open("stepMultiplier");
        uint256 i = iSeed % stocks.length;
        uint256 bps = _bound(bpsSeed, 1, 5000);
        uint256 current = MockStockToken(stocks[i]).uiMultiplier();
        MockStockToken(stocks[i]).setUIMultiplier(current + current * bps / Constants.BPS);
        GHOSTS.noteSuccess();
        GHOSTS.close();
    }

    /// @notice Arms and disarms the gate: guardian freezes, oracle pauses and stale feeds.
    /// @param modeSeed Chooses what to do.
    function armGate(uint256 modeSeed) external {
        GHOSTS.open("armGate");
        uint256 mode = modeSeed % 6;
        uint16 constituentId = constituentIds[modeSeed % constituentIds.length];
        if (mode == 0) {
            vm.prank(GUARDIAN);
            try GATE.freezeConstituent(constituentId, uint32(block.timestamp + 1 hours)) {} catch {}
        } else if (mode == 1) {
            vm.prank(GUARDIAN);
            try GATE.unfreezeConstituent(constituentId) {} catch {}
        } else if (mode == 2) {
            vm.prank(GUARDIAN);
            try GATE.freezeProtocol(uint32(block.timestamp + 30 minutes)) {} catch {}
        } else if (mode == 3) {
            vm.prank(GUARDIAN);
            try GATE.unfreezeProtocol() {} catch {}
        } else if (mode == 4) {
            MockStockToken(stocks[modeSeed % stocks.length]).setOraclePaused(true);
        } else {
            MockStockToken(stocks[modeSeed % stocks.length]).setOraclePaused(false);
        }
        GHOSTS.noteSuccess();
        GHOSTS.close();
    }

    /// @notice Probes the hook's two swap callbacks directly, as the PoolManager, so the "never reverts except
    ///         `BeyondRail`" rule is tested on the hook rather than through a router that has its own reasons to
    ///         fail (I15, §10 ruling 2).
    /// @param poolSeed Chooses the pool.
    /// @param directionSeed Chooses the direction and exact kind.
    function probeHook(uint256 poolSeed, uint256 directionSeed) external {
        GHOSTS.open("probeHook");
        PoolId poolId = pools[poolSeed % pools.length];
        PoolKey memory key = REGISTRY.poolKey(poolId);
        SwapParams memory params = SwapParams({
            zeroForOne: directionSeed % 2 == 0,
            amountSpecified: directionSeed % 4 < 2 ? -int256(1e15) : int256(1e15),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(POOL_MANAGER));
        try HOOK.beforeSwap(address(this), key, params, "") returns (bytes4, BeforeSwapDelta delta, uint24 fee) {
            if (BeforeSwapDelta.unwrap(delta) != 0 || fee == 0) GHOSTS.noteMalformedFee();
        } catch (bytes memory reason) {
            GHOSTS.noteProbeFailure(reason);
        }

        vm.prank(address(POOL_MANAGER));
        try HOOK.afterSwap(address(this), key, params, toBalanceDelta(0, 0), "") returns (bytes4, int128 delta) {
            if (delta != 0) GHOSTS.noteMalformedFee();
        } catch (bytes memory reason) {
            GHOSTS.noteProbeFailure(reason);
        }
        GHOSTS.noteSuccess();
        GHOSTS.close();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Views the invariant suite reads
    // -------------------------------------------------------------------------------------------------------------

    /// @notice How many pools this campaign drives.
    /// @return count The count.
    function poolCount() external view returns (uint256 count) {
        return pools.length;
    }

    /// @notice Pool `i`.
    /// @param i The index.
    /// @return poolId The pool.
    function poolAt(uint256 i) external view returns (PoolId poolId) {
        return pools[i];
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The pool's counter asset.
    function _counterOf(PoolId poolId) private view returns (address counter) {
        return REGISTRY.poolConfig(poolId).counter;
    }

    /// @dev One "unit" of a pool's counter asset: small enough that a step stays inside the outer rail.
    function _counterUnit(PoolId poolId) private view returns (uint256 unit) {
        uint8 decimals = REGISTRY.poolConfig(poolId).counterDecimals;
        if (decimals == 6) return 1e5;
        if (PoolId.unwrap(poolId) == PoolId.unwrap(WETH_POOL)) return 1e13;
        return 1e14;
    }

    /// @dev Mints `amount` of `token` to `who` and approves the router stack from them.
    function _fund(address token, address who, uint256 amount) private {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", who, amount));
        ok;
        _approveStack(token, who);
    }

    /// @dev Permit2 and router approvals for one owner.
    function _approveStack(address token, address who) private {
        vm.startPrank(who);
        (bool a,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(PERMIT2), type(uint256).max));
        (bool b,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(ROUTER), type(uint256).max));
        a;
        b;
        try PERMIT2.approve(token, address(ROUTER), type(uint160).max, type(uint48).max) {} catch {}
        vm.stopPrank();
    }

    /// @dev The hook's own fee quote, degraded to "no refusal" when it cannot be taken.
    function _quoteFee(PoolId poolId, bool zeroForOne, bool exactInput, uint256 amountIn)
        private
        view
        returns (uint24 feePips, uint16 baseBps, uint16 dynBps, bool refuse)
    {
        try HOOK.quoteFee(poolId, zeroForOne, exactInput, amountIn) returns (uint24 f, uint16 b, uint16 d, bool r) {
            return (f, b, d, r);
        } catch {
            return (0, 0, 0, false);
        }
    }

    /// @dev The bond quote, degraded to zero when it cannot be taken.
    function _probeQuote(uint16 marketId)
        private
        view
        returns (uint256 ampsOut, uint256 qX18, uint16 discountBps, bool floorBinding, uint256 capacityLeft)
    {
        try BONDS.quote(marketId, 1e18) returns (uint256 a, uint256 q, uint16 d, bool f, uint256 c, bytes32) {
            return (a, q, d, f, c);
        } catch {
            return (0, 0, 0, false, 0);
        }
    }

    /// @dev Republishes every aggregator at its current answer.
    function _republishFeeds() private {
        (, int256 wethAnswer,,,) = WETH_FEED.latestRoundData();
        (, int256 usdgAnswer,,,) = USDG_FEED.latestRoundData();
        WETH_FEED.setAnswer(wethAnswer);
        USDG_FEED.setAnswer(usdgAnswer);
        for (uint256 i; i < stockFeeds.length; ++i) {
            MockAggregator(stockFeeds[i]).setAnswer(int256(uint256(stockUsd8[i])));
        }
    }
}
