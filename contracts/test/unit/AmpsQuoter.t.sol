// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsBonds} from "../../src/bonds/AmpsBonds.sol";
import {IAmpsBonds} from "../../src/interfaces/IAmpsBonds.sol";
import {IAmpsQuoter} from "../../src/interfaces/IAmpsQuoter.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {AmpsQuoter} from "../../src/periphery/AmpsQuoter.sol";
import {BondPolicy} from "../../src/policy/BondPolicy.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {
    BondMarket,
    Checkpoint,
    CollateralClass,
    GateSnapshot,
    GateState,
    HookPoolState,
    PoolClass,
    PoolConfig,
    Session
} from "../../src/types/Types.sol";
import {StubAmpsHook} from "../gas/StubAmpsHook.sol";
import {MockAmpsVault} from "../mocks/MockAmpsVault.sol";
import {MockFeedRegistry} from "../mocks/MockFeedRegistry.sol";
import {MockOracleGate} from "../mocks/MockOracleGate.sol";
import {MockPoolRegistry} from "../mocks/MockPoolRegistry.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockUsdg} from "../mocks/MockUsdg.sol";
import {QuoterFaultProxy} from "../mocks/QuoterFaultProxy.sol";
import {QuoterGateStub} from "../mocks/QuoterGateStub.sol";
import {QuoterHookStub} from "../mocks/QuoterHookStub.sol";
import {V4TestBase} from "../utils/V4TestBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {PathKey} from "hookmate/interfaces/router/PathKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @notice The fixture every `AmpsQuoter` test runs against: a live local v4 stack with two real pools behind
///         `StubAmpsHook`, a settable `QuoterHookStub` standing in for the production hook's read surface, the
///         Phase 2 mocks for the gate, the feed registry, the registry and the vault, a real `AmpsBonds`, and a
///         `QuoterFaultProxy` in front of every one of them.
///
/// @dev **Why two hooks.** The pools need a hook that actually charges a fee, and `StubAmpsHook` is the Phase 1
///      contract that does exactly that at a fixed 30 bp buy / 500 bp sell with the rotation blend. The quoter
///      needs a hook that answers `poolState`, `quoteFee` and the market reference, and the production `AmpsHook`
///      does not exist yet. So the pool's hook is `StubAmpsHook` and the quoter's hook is `QuoterHookStub`,
///      configured with the same fees — which is what "the test may inject that fee into the quoter's fee input"
///      means, and what makes the wei-exact comparison a test of the *quoter's* arithmetic rather than of a mock's.
abstract contract QuoterFixture is V4TestBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Three leading zero bytes, so AMPS is `currency0` in both pools and `zeroForOne == true` is a sell.
    address internal constant AMPS_ADDRESS = 0x0000001234567890123456789012345678901234;
    address internal constant USDG_ADDRESS = 0x1111111111111111111111111111111111111111;
    address internal constant STOCK_ADDRESS = 0x2222222222222222222222222222222222222222;

    /// @dev Where `QuoterHookStub` is etched: `& 0x3FFF == 0x38C0`, the production hook's mined shape.
    address internal constant HOOK_VIEW_ADDRESS = 0xAaaa0000000000000000000000000000000038C0;

    int24 internal constant TICK_SPACING = 10;
    int24 internal constant TWO_SIDED_HALF_WIDTH = 5000;
    int24 internal constant ASK_LOWER_OFFSET = 1000;
    int24 internal constant ASK_UPPER_OFFSET = 20_000;

    uint16 internal constant BUY_FEE_BPS = 30;
    uint16 internal constant SELL_FEE_BPS = 500;
    uint24 internal constant BUY_FEE_PIPS = 3000;
    uint24 internal constant SELL_FEE_PIPS = 50_000;

    uint256 internal constant STOCK_PRICE_USD8 = 180e8;
    uint256 internal constant USDG_PRICE_USD8 = 1e8;
    uint128 internal constant NAV_X18 = 1e18;
    uint128 internal constant P_REF_X18 = 1.05e18;

    /// @dev The seven dependencies, in the order {sourceName} reports them.
    uint256 internal constant SOURCE_HOOK = 0;
    uint256 internal constant SOURCE_GATE = 1;
    uint256 internal constant SOURCE_FEEDS = 2;
    uint256 internal constant SOURCE_VAULT = 3;
    uint256 internal constant SOURCE_BONDS = 4;
    uint256 internal constant SOURCE_REGISTRY = 5;
    uint256 internal constant SOURCE_POOL_MANAGER = 6;
    uint256 internal constant SOURCE_COUNT = 7;

    MockERC20 internal amps;
    MockERC20 internal usdg;
    MockERC20 internal stock;
    StubAmpsHook internal poolHook;

    QuoterHookStub internal hookStub;
    MockOracleGate internal gate;
    QuoterGateStub internal gateStub;
    MockFeedRegistry internal feeds;
    MockPoolRegistry internal registry;
    MockAmpsVault internal vaultMock;
    AmpsBonds internal bondsShell;
    BondPolicy internal bondPolicy;
    Amps internal ampsToken;
    MockStockToken internal bondCollateral;
    MockUsdg internal bondUsdg;

    QuoterFaultProxy[SOURCE_COUNT] internal proxies;
    AmpsQuoter internal quoter;

    PoolKey internal usdgKey;
    PoolKey internal stockKey;
    PoolId internal usdgPool;
    PoolId internal stockPool;

    uint16 internal constituentId;
    uint16 internal stockMarketId;

    address internal timelock = makeAddr("timelock");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(1_000_000);
        deployV4();

        amps = deployTokenAt(AMPS_ADDRESS, "Amplestocks", "AMPS", 18);
        usdg = deployTokenAt(USDG_ADDRESS, "Global Dollar", "USDG", 6);
        stock = deployTokenAt(STOCK_ADDRESS, "Mock Stock Token", "STOCK", 18);

        _deployPoolsBehindStubHook();
        _deployMocks();
        _deployBonds();
        _wireQuoter();
    }

    /* ------------------------------------------------------------------ */
    /*                              fixture                               */
    /* ------------------------------------------------------------------ */

    /// @dev The two real pools, seeded two-sided plus a one-sided ask, exactly as the gas baseline seeds them.
    function _deployPoolsBehindStubHook() private {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory args = abi.encode(poolManager, Currency.wrap(AMPS_ADDRESS), address(this));
        (address mined, bytes32 salt) = HookMiner.find(address(this), flags, type(StubAmpsHook).creationCode, args);
        poolHook = new StubAmpsHook{salt: salt}(poolManager, Currency.wrap(AMPS_ADDRESS), address(this));
        require(address(poolHook) == mined, "hook address mismatch");

        usdgKey = _poolKey(USDG_ADDRESS);
        stockKey = _poolKey(STOCK_ADDRESS);
        usdgPool = usdgKey.toId();
        stockPool = stockKey.toId();

        poolManager.initialize(usdgKey, _sqrtPriceX96(1e6, 1e18));
        poolManager.initialize(stockKey, _sqrtPriceX96(1, 180));
        _seedPool(usdgKey, 1_000_000e18, 1_000_000e6, 500_000e18);
        _seedPool(stockKey, 1_000_000e18, 6000e18, 500_000e18);
    }

    /// @dev The read surface: a `0x38C0`-shaped hook stub, the gate, the feeds, the registry and the vault.
    function _deployMocks() private {
        QuoterHookStub implementation = new QuoterHookStub();
        vm.etch(HOOK_VIEW_ADDRESS, address(implementation).code);
        hookStub = QuoterHookStub(HOOK_VIEW_ADDRESS);
        vm.label(HOOK_VIEW_ADDRESS, "QuoterHookStub");

        // `vm.etch` copies code, not storage, so every field the stub's declaration initialises has to be
        // written back through a setter — starting with the TWAP window every coverage check is measured against.
        hookStub.setTwapWindow(Constants.TWAP_WINDOW_DEFAULT);
        hookStub.initPool(usdgPool, PoolClass.ENTRY, 6, TICK_SPACING, BUY_FEE_BPS);
        hookStub.initPool(stockPool, PoolClass.SPOKE, 18, TICK_SPACING, BUY_FEE_BPS);
        hookStub.setFlatFees(usdgPool, BUY_FEE_BPS, SELL_FEE_BPS);
        hookStub.setFlatFees(stockPool, BUY_FEE_BPS, SELL_FEE_BPS);
        hookStub.setObservation(usdgPool, _tickOf(usdgPool), _tickOf(usdgPool), Constants.TWAP_WINDOW_DEFAULT);
        hookStub.setObservation(stockPool, _tickOf(stockPool), _tickOf(stockPool), Constants.TWAP_WINDOW_DEFAULT);
        hookStub.setTicks(usdgPool, _tickOf(usdgPool), _tickOf(usdgPool));
        hookStub.setTicks(stockPool, _tickOf(stockPool), _tickOf(stockPool));

        gate = new MockOracleGate();
        gateStub = new QuoterGateStub();
        feeds = new MockFeedRegistry();
        registry = new MockPoolRegistry();
        vaultMock = new MockAmpsVault(timelock);

        feeds.setAnswer(USDG_ADDRESS, uint128(USDG_PRICE_USD8));
        feeds.setAnswer(STOCK_ADDRESS, uint128(STOCK_PRICE_USD8));

        registry.addEntryPool(usdgPool, USDG_ADDRESS, 6, TICK_SPACING, BUY_FEE_BPS);
        registry.setHubPoolId(usdgPool);
        registry.setWethPoolId(PoolId.wrap(bytes32(0)));
        constituentId = registry.addConstituentAndPool(
            STOCK_ADDRESS, address(0xFEED), stockPool, PoolClass.SPOKE, TICK_SPACING, 3333
        );

        vaultMock.setCheckpoint(NAV_X18, P_REF_X18, NAV_X18, uint32(block.timestamp));
        vaultMock.setTotalAssetsUsd18(5000e18);
    }

    /// @dev A real `AmpsBonds` on a real `BondPolicy`, so `bondQuote` is reconciled against the shell rather than
    ///      against a mock that could agree with the quoter by construction.
    function _deployBonds() private {
        ampsToken = new Amps(address(vaultMock));
        vaultMock.setAmps(address(ampsToken));
        bondPolicy = new BondPolicy();
        bondsShell = new AmpsBonds(address(vaultMock), address(registry), address(bondPolicy));
        vaultMock.setBonds(address(bondsShell));
        vaultMock.setPointers(address(gate), address(feeds), address(registry), HOOK_VIEW_ADDRESS);
        vaultMock.mintGenesis(address(this), Constants.S0);

        // The bond markets are keyed by collateral address, and the pools' counter assets are the two `MockERC20`s
        // the v4 stack holds, so the markets are opened against those very addresses.
        bondCollateral = MockStockToken(STOCK_ADDRESS);
        bondUsdg = MockUsdg(USDG_ADDRESS);
        vm.startPrank(timelock);
        stockMarketId = bondsShell.addCollateral(
            STOCK_ADDRESS,
            CollateralClass.CONSTITUENT,
            Constants.BOND_D_BASE_BPS_DEFAULT,
            Constants.BOND_D_MIN_BPS_DEFAULT,
            Constants.BOND_D_MAX_BPS_DEFAULT,
            Constants.BOND_CAP_BPS_PER_EPOCH_DEFAULT,
            true
        );
        vm.stopPrank();
    }

    /// @dev Every dependency behind its own fault proxy, and the quoter pointed at the proxies.
    function _wireQuoter() private {
        proxies[SOURCE_HOOK] = new QuoterFaultProxy(HOOK_VIEW_ADDRESS);
        proxies[SOURCE_GATE] = new QuoterFaultProxy(address(gate));
        proxies[SOURCE_FEEDS] = new QuoterFaultProxy(address(feeds));
        proxies[SOURCE_VAULT] = new QuoterFaultProxy(address(vaultMock));
        proxies[SOURCE_BONDS] = new QuoterFaultProxy(address(bondsShell));
        proxies[SOURCE_REGISTRY] = new QuoterFaultProxy(address(registry));
        proxies[SOURCE_POOL_MANAGER] = new QuoterFaultProxy(address(poolManager));

        quoter = new AmpsQuoter(
            address(proxies[SOURCE_POOL_MANAGER]),
            address(proxies[SOURCE_HOOK]),
            address(proxies[SOURCE_VAULT]),
            address(proxies[SOURCE_REGISTRY]),
            address(proxies[SOURCE_BONDS]),
            address(proxies[SOURCE_GATE]),
            address(proxies[SOURCE_FEEDS])
        );
    }

    /* ------------------------------------------------------------------ */
    /*                              helpers                               */
    /* ------------------------------------------------------------------ */

    /// @dev The bit `AmpsQuoter` raises when source `index` cannot answer at all.
    function _expectedBit(uint256 index) internal pure returns (uint8 bit) {
        if (index == SOURCE_HOOK) return 0x01;
        if (index == SOURCE_GATE) return 0x02;
        if (index == SOURCE_FEEDS) return 0x04;
        if (index == SOURCE_VAULT) return 0x08;
        if (index == SOURCE_BONDS) return 0x10;
        if (index == SOURCE_REGISTRY) return 0x40;
        return 0x80;
    }

    /// @dev A readable name for an assertion message.
    function _sourceName(uint256 index) internal pure returns (string memory name) {
        if (index == SOURCE_HOOK) return "hook";
        if (index == SOURCE_GATE) return "gate";
        if (index == SOURCE_FEEDS) return "feeds";
        if (index == SOURCE_VAULT) return "vault";
        if (index == SOURCE_BONDS) return "bonds";
        if (index == SOURCE_REGISTRY) return "registry";
        return "poolManager";
    }

    /// @dev Whether a failure mode answers with something of the *right shape*. `WORD_SOUP` and `BOMB` both
    ///      return at least as many words as every read expects, so no caller — this one included — can tell them
    ///      from a healthy answer. The claim for those two modes is survival, not detection: the quoter must not
    ///      revert on an out-of-range enum, a dirty `bool` or a returndata flood, and must not pretend it noticed.
    function _isShapeValid(QuoterFaultProxy.Mode mode) internal pure returns (bool shapeValid) {
        return mode == QuoterFaultProxy.Mode.WORD_SOUP || mode == QuoterFaultProxy.Mode.BOMB;
    }

    /// @dev Puts every proxy back into pass-through.
    function _healAll() internal {
        for (uint256 i = 0; i < SOURCE_COUNT; ++i) {
            proxies[i].setMode(QuoterFaultProxy.Mode.PASS);
        }
    }

    function _tickOf(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    function _poolKey(address counter) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(AMPS_ADDRESS),
            currency1: Currency.wrap(counter),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(poolHook))
        });
    }

    function _sqrtPriceX96(uint256 num, uint256 den) internal pure returns (uint160) {
        return uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(num, 1 << 96, den) << 96));
    }

    function _seedPool(PoolKey memory key, uint256 amount0, uint256 amount1, uint256 askAmount0) internal {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());

        int24 lower = _align(tick - TWO_SIDED_HALF_WIDTH);
        int24 upper = _align(tick + TWO_SIDED_HALF_WIDTH);
        _addLiquidity(
            key,
            lower,
            upper,
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
            )
        );

        int24 askLower = _align(tick + ASK_LOWER_OFFSET);
        int24 askUpper = _align(tick + ASK_UPPER_OFFSET);
        _addLiquidity(
            key,
            askLower,
            askUpper,
            LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(askLower), TickMath.getSqrtPriceAtTick(askUpper), askAmount0
            )
        );
    }

    function _align(int24 tick) internal pure returns (int24) {
        int24 aligned = (tick / TICK_SPACING) * TICK_SPACING;
        return tick < 0 && tick % TICK_SPACING != 0 ? aligned - TICK_SPACING : aligned;
    }

    function _addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) internal {
        poolManager.unlock(abi.encode(key, tickLower, tickUpper, int256(uint256(liquidity))));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "unlockCallback: not the PoolManager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
            abi.decode(data, (PoolKey, int24, int24, int256));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            poolManager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transfer(address(poolManager), uint256(uint128(-amount)));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @title AmpsQuoterTest
/// @notice `AmpsQuoter`'s specification is a negative — it never reverts — plus two positives: the degraded
///         bitfield says exactly which sub-read failed, and the numbers it does publish are the ones the hook and
///         the pool would actually produce.
///
/// @dev The suite is organised as those three claims. Section 1 reads a healthy system. Section 2 breaks every
///      dependency in every way, singly, in every pair and in every combination, and asserts that nothing reverts
///      and that the right bit is raised. Section 3 checks the arithmetic against hand-computed values and against
///      real swaps through a real PoolManager, to the wei.
contract AmpsQuoterTest is QuoterFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // -------------------------------------------------------------------------------------------------------------
    // 1. A healthy system
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every field of a spoke's quote, against a system where nothing is broken.
    function test_quotePool_healthy() public view {
        IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(stockPool);

        assertEq(PoolId.unwrap(quote.poolId), PoolId.unwrap(stockPool), "poolId");
        assertEq(uint8(quote.poolClass), uint8(PoolClass.SPOKE), "class");
        assertEq(quote.counter, STOCK_ADDRESS, "counter");
        assertEq(quote.degraded, 0, "nothing degraded");

        assertEq(quote.poolTick, _tickOf(stockPool), "the live tick");
        assertEq(quote.innerBandTicks, Constants.INNER_BAND_REGULAR_TICKS, "band");
        assertEq(quote.outerRailTicks, Constants.OUTER_RAIL_MIN_TICKS, "rail");
        assertEq(quote.dynCapBps, Constants.DYN_CAP_NORMAL_BPS, "cap");

        assertEq(quote.buyFeeBps, BUY_FEE_BPS, "buy base");
        assertEq(quote.sellFeeBps, SELL_FEE_BPS, "sell base");
        assertEq(quote.buyFeePips, BUY_FEE_PIPS, "buy pips");
        assertEq(quote.sellFeePips, SELL_FEE_PIPS, "sell pips");
        assertEq(quote.dynBps, 0, "no dynamic part at rest");
        assertFalse(quote.refuseBuy, "buy allowed");
        assertFalse(quote.refuseSell, "sell allowed");

        assertEq(quote.navPerShareX18, NAV_X18, "nav");
        assertEq(quote.pRefX18, P_REF_X18, "reference");
        assertEq(quote.premiumX18, int256(0.05e18), "5% premium");
        assertEq(quote.checkpointAge, 0, "fresh checkpoint");

        assertEq(uint8(quote.gateState), uint8(GateState.GREEN), "green");
        assertEq(uint8(quote.session), uint8(Session.REGULAR), "regular");
        assertFalse(quote.feedStale, "fresh feed");
        assertFalse(quote.corporateFreeze, "no corporate action");
        assertEq(quote.observationCoverage, Constants.TWAP_WINDOW_DEFAULT, "coverage");

        // AMPS is seeded at $1.00 against a $180 stock, so `P_mkt` recovered from the tick is $1 within rounding.
        assertApproxEqRel(quote.pMktX18, 1e18, 1e15, "P_mkt");
    }

    /// @notice The bond fields of a spoke's quote are `AmpsBonds`' own answer for one whole unit of collateral.
    function test_quotePool_bondFieldsMirrorTheShell() public view {
        IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(stockPool);
        (, uint256 qX18, uint16 discountBps,, uint256 capacityLeft,) = bondsShell.quote(stockMarketId, 1e18);

        assertEq(quote.bondQX18, qX18, "q");
        assertEq(quote.bondDiscountBps, discountBps, "discount");
        assertEq(quote.bondCapacityLeft, capacityLeft, "capacity");
        assertTrue(quote.bondOpen, "open");
        assertGt(qX18, 0, "the market prices");
    }

    /// @notice {bondQuote} equals `AmpsBonds.quote` for the market, and answers zero for a market that does not
    ///         exist rather than reverting the way the shell does.
    function test_bondQuote_matchesTheShell() public {
        (uint256 qX18, uint16 discountBps, uint256 capacityLeft, bool open, uint8 degraded) =
            quoter.bondQuote(stockMarketId);
        (, uint256 shellQ, uint16 shellDiscount,, uint256 shellCapacity,) = bondsShell.quote(stockMarketId, 1e18);

        assertEq(qX18, shellQ, "q");
        assertEq(discountBps, shellDiscount, "discount");
        assertEq(capacityLeft, shellCapacity, "capacity");
        assertTrue(open, "open");
        assertEq(degraded, 0, "clean");

        vm.expectRevert();
        bondsShell.quote(99, 1e18);
        (uint256 unknownQ,,, bool unknownOpen, uint8 unknownDegraded) = quoter.bondQuote(99);
        assertEq(unknownQ, 0, "no price for an unknown market");
        assertFalse(unknownOpen, "not open");
        assertEq(unknownDegraded, 0x10, "and the bonds bit is raised");
    }

    /// @notice A closed market quotes zero and reports itself closed.
    function test_bondQuote_closedMarket() public {
        vm.prank(timelock);
        bondsShell.setMarketOpen(stockMarketId, false);
        (,,, bool open,) = quoter.bondQuote(stockMarketId);
        assertFalse(open, "closed");
        assertFalse(quoter.quotePool(stockPool).bondOpen, "and the pool quote agrees");
    }

    /// @notice An unregistered pool is a zeroed quote with `poolClass == NONE`, not a revert.
    function test_quotePool_unknownPoolIsZeroed() public view {
        IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(PoolId.wrap(keccak256("nope")));
        assertEq(uint8(quote.poolClass), uint8(PoolClass.NONE), "NONE");
        assertEq(quote.counter, address(0), "no counter");
        assertEq(quote.poolTick, 0, "no tick");
        assertEq(quote.pMktX18, 0, "no market price");
    }

    /// @notice {quoteAll} walks the registry's own order: the hub, the WETH pool, then one spoke per constituent.
    function test_quoteAll() public view {
        IAmpsQuoter.PoolQuote[] memory quotes = quoter.quoteAll();
        assertEq(quotes.length, 3, "hub + weth + one constituent");
        assertEq(PoolId.unwrap(quotes[0].poolId), PoolId.unwrap(usdgPool), "hub first");
        assertEq(PoolId.unwrap(quotes[1].poolId), bytes32(0), "no WETH pool registered");
        assertEq(PoolId.unwrap(quotes[2].poolId), PoolId.unwrap(stockPool), "then the spoke");
        assertEq(uint8(quotes[0].poolClass), uint8(PoolClass.ENTRY), "the hub is an entry pool");
        assertEq(quotes[0].degraded, 0, "hub clean");
        assertEq(quotes[2].degraded, 0, "spoke clean");
    }

    /// @notice The wiring getters and the version identifier.
    function test_wiring() public view {
        assertEq(quoter.hook(), address(proxies[SOURCE_HOOK]), "hook");
        assertEq(quoter.vault(), address(proxies[SOURCE_VAULT]), "vault");
        assertEq(quoter.registry(), address(proxies[SOURCE_REGISTRY]), "registry");
        assertEq(quoter.bonds(), address(proxies[SOURCE_BONDS]), "bonds");
        assertEq(quoter.oracleGate(), address(proxies[SOURCE_GATE]), "gate");
        assertEq(quoter.feedRegistry(), address(proxies[SOURCE_FEEDS]), "feeds");
        assertEq(quoter.poolManager(), address(proxies[SOURCE_POOL_MANAGER]), "pool manager");
        assertEq(quoter.version(), bytes32("amps-quoter-v1"), "version");
    }

    /// @notice A gate that is not green reaches the quote, and a corporate freeze with it.
    /// @dev Driven through {QuoterGateStub} rather than `MockOracleGate`, because the quoter reads
    ///      `snapshotByPool` and that mock keys the freeze and staleness flags by constituent rather than by pool.
    function test_quotePool_gateStateIsRendered() public {
        proxies[SOURCE_GATE].setTarget(address(gateStub));
        gateStub.setSnapshot(
            stockPool,
            GateSnapshot({
                state: GateState.DEGRADED,
                session: Session.CLOSED,
                feedStale: true,
                corporateFreeze: true,
                diverged: false,
                watchdogTripped: false,
                hSessionBps: Constants.H_SESSION_CLOSED_BPS_DEFAULT,
                dynCapBps: Constants.DYN_CAP_DEGRADED_BPS,
                poolTick: 0,
                fairTick: 0,
                observedAt: uint32(block.timestamp),
                answerUpdatedAt: uint32(block.timestamp),
                answerUsd8: uint64(STOCK_PRICE_USD8)
            })
        );

        IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(stockPool);
        assertEq(uint8(quote.gateState), uint8(GateState.DEGRADED), "degraded");
        assertEq(uint8(quote.session), uint8(Session.CLOSED), "closed");
        assertTrue(quote.feedStale, "stale");
        assertTrue(quote.corporateFreeze, "frozen");
        assertEq(quote.degraded, 0, "a non-green gate is not a degraded read");
        assertEq(quote.dynCapBps, Constants.DYN_CAP_NORMAL_BPS, "the hook's cached cap wins while it answers");
    }

    /// @notice With the hook down, the gate's copies of the cap and the fair tick are what the quote falls back to.
    function test_quotePool_gateIsTheFallbackForTheHooksCache() public {
        proxies[SOURCE_GATE].setTarget(address(gateStub));
        gateStub.setSnapshot(
            stockPool,
            GateSnapshot({
                state: GateState.WATCHDOG,
                session: Session.OVERNIGHT,
                feedStale: false,
                corporateFreeze: false,
                diverged: false,
                watchdogTripped: true,
                hSessionBps: 0,
                dynCapBps: Constants.DYN_CAP_DEGRADED_BPS,
                poolTick: -1234,
                fairTick: -1200,
                observedAt: uint32(block.timestamp),
                answerUpdatedAt: uint32(block.timestamp),
                answerUsd8: uint64(STOCK_PRICE_USD8)
            })
        );
        proxies[SOURCE_HOOK].setMode(QuoterFaultProxy.Mode.REVERT_EMPTY);

        IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(stockPool);
        assertEq(quote.dynCapBps, Constants.DYN_CAP_DEGRADED_BPS, "the gate's cap");
        assertEq(quote.fairTick, -1200, "the gate's fair tick");
        assertEq(uint8(quote.session), uint8(Session.OVERNIGHT), "the gate's session");
        assertEq(quote.degraded & 0x01, 0x01, "and bit 0 says where the rest went");
    }

    /// @notice A ring that does not cover the window is bit 5 and a zero `P_mkt`, which is a young pool rather
    ///         than a broken one — the distinction `IAmpsQuoter` makes load-bearing.
    function test_quotePool_shortCoverageIsBitFive() public {
        hookStub.setObservation(stockPool, _tickOf(stockPool), _tickOf(stockPool), Constants.TWAP_WINDOW_DEFAULT - 1);
        IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(stockPool);
        assertEq(quote.pMktX18, 0, "no market price");
        assertEq(quote.degraded, 0x20, "bit 5 only");
        assertEq(quote.observationCoverage, Constants.TWAP_WINDOW_DEFAULT - 1, "and the coverage is reported");
        assertEq(quote.sellFeePips, SELL_FEE_PIPS, "the fee legs still answer");
    }

    // -------------------------------------------------------------------------------------------------------------
    // 2. Faults: singly, in pairs, and all at once
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every dependency, broken every way, one at a time: the call never reverts and the source's own bit
    ///         is raised whenever the answer was unusable.
    /// @dev `WORD_SOUP` is the one mode that does **not** raise a bit, and deliberately so: an answer of the right
    ///      length and the wrong content is indistinguishable from a healthy one to any caller. What it proves is
    ///      that the quoter survives it — out-of-range enums, dirty `bool`s and impossible decimals included —
    ///      which an implementation that `abi.decode`d structs would not, because the decoder's `Panic` is not
    ///      catchable.
    function test_faults_singleSourceEveryMode() public {
        for (uint256 source = 0; source < SOURCE_COUNT; ++source) {
            for (uint256 mode = 1; mode <= uint256(type(QuoterFaultProxy.Mode).max); ++mode) {
                _healAll();
                proxies[source].setMode(QuoterFaultProxy.Mode(mode));

                IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(stockPool);
                string memory label = string.concat(_sourceName(source), "/mode", vm.toString(mode));

                if (_isShapeValid(QuoterFaultProxy.Mode(mode))) {
                    // Survival is the claim; the content is garbage by construction.
                    continue;
                }
                assertTrue(quote.degraded & _expectedBit(source) != 0, label);
            }
        }
        _healAll();
    }

    /// @notice The same sweep over the amount-level entry points, which walk the pool as well as reading it.
    function test_faults_amountQuotesNeverRevert() public {
        for (uint256 source = 0; source < SOURCE_COUNT; ++source) {
            for (uint256 mode = 1; mode <= uint256(type(QuoterFaultProxy.Mode).max); ++mode) {
                _healAll();
                proxies[source].setMode(QuoterFaultProxy.Mode(mode));

                quoter.quoteExactIn(stockPool, true, 1e18);
                quoter.quoteExactIn(usdgPool, false, 1e6);
                quoter.quoteRotation(stockPool, usdgPool, 1e18);
                quoter.quoteSellWithCredit(usdgPool, 1e18, 5e17);
                quoter.wouldRevert(stockPool, true, true, 1e18);
                quoter.navRail(stockPool);
                quoter.bondQuote(stockMarketId);
            }
        }
        _healAll();
    }

    /// @notice Every dependency broken at once, in every mode: still no revert, and every bit that can be raised
    ///         is raised.
    function test_faults_everythingAtOnce() public {
        for (uint256 mode = 1; mode <= uint256(type(QuoterFaultProxy.Mode).max); ++mode) {
            for (uint256 source = 0; source < SOURCE_COUNT; ++source) {
                proxies[source].setMode(QuoterFaultProxy.Mode(mode));
            }

            IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(stockPool);
            quoter.quoteAll();
            quoter.quoteRotation(stockPool, usdgPool, 1e18);

            if (!_isShapeValid(QuoterFaultProxy.Mode(mode))) {
                assertEq(quote.degraded & 0x8B, 0x8B, string.concat("mode", vm.toString(mode)));
            }
        }
        _healAll();
    }

    /// @notice Every *combination* of broken dependencies, at one mode per run, driven by a bitmask.
    /// @dev 128 subsets x the mode: the "in every combination" half of §8.2's requirement, done exhaustively
    ///      rather than by sampling.
    function test_faults_everySubset() public {
        for (uint256 subset = 0; subset < (1 << SOURCE_COUNT); ++subset) {
            QuoterFaultProxy.Mode mode = QuoterFaultProxy.Mode(1 + (subset % uint256(type(QuoterFaultProxy.Mode).max)));
            for (uint256 source = 0; source < SOURCE_COUNT; ++source) {
                proxies[source].setMode(subset & (1 << source) != 0 ? mode : QuoterFaultProxy.Mode.PASS);
            }
            quoter.quotePool(stockPool);
            quoter.quoteRotation(stockPool, usdgPool, 1e18);
        }
        _healAll();
    }

    /// @notice The same, fuzzed over subset and mode together.
    /// @param subset A bitmask of which dependencies are broken.
    /// @param modeSeed Which failure they exhibit.
    function testFuzz_faults_neverRevert(uint8 subset, uint8 modeSeed) public {
        QuoterFaultProxy.Mode mode =
            QuoterFaultProxy.Mode(uint256(modeSeed) % (uint256(type(QuoterFaultProxy.Mode).max) + 1));
        for (uint256 source = 0; source < SOURCE_COUNT; ++source) {
            proxies[source].setMode(subset & (1 << source) != 0 ? mode : QuoterFaultProxy.Mode.PASS);
        }
        quoter.quotePool(stockPool);
        quoter.quotePool(usdgPool);
        quoter.quoteAll();
        quoter.quoteRotation(stockPool, usdgPool, 1e18);
        quoter.quoteExactIn(stockPool, true, 1e18);
        quoter.bondQuote(stockMarketId);
        quoter.navRail(usdgPool);
        quoter.wouldRevert(usdgPool, false, true, 1e6);
    }

    /// @notice A quoter wired to nothing at all: no address has code, every read fails, and the struct comes back
    ///         zeroed with the bits to say why.
    function test_faults_absentDependencies() public {
        AmpsQuoter absent =
            new AmpsQuoter(address(0), address(0), address(0), address(0), address(0), address(0), address(0));
        IAmpsQuoter.PoolQuote memory quote = absent.quotePool(stockPool);
        // Bits 2 and 4 stay clear because those reads are never *attempted*: without a hook there is no TWAP to
        // convert, so the feed is not consulted, and without a registry there is no counter asset to look a bond
        // market up by. "A read that failed" and "a read nobody made" are different claims and the bitfield keeps
        // them apart.
        assertEq(quote.degraded, 0xEB, "hook, gate, checkpoint, TWAP, registry and pool manager");
        assertEq(quote.pMktX18, 0, "no price");
        assertEq(quote.navPerShareX18, 0, "no nav");
        assertFalse(quote.refuseBuy, "fails open");
        assertFalse(quote.refuseSell, "fails open");
        assertEq(absent.quoteAll().length, 2, "hub and weth, both zero");

        (uint256 amountOut, uint24 hop1, uint24 hop2, uint256 credit) = absent.quoteRotation(stockPool, usdgPool, 1e18);
        assertEq(amountOut + hop1 + hop2 + credit, 0, "a rotation through nothing quotes nothing");
    }

    /// @notice An EOA-shaped dependency — an address with no code — is the other absence, and answers a
    ///         `staticcall` *successfully* with no data, which is why the code check exists.
    function test_faults_codelessDependencies() public {
        AmpsQuoter codeless = new AmpsQuoter(
            makeAddr("pm"),
            makeAddr("hook"),
            makeAddr("vault"),
            makeAddr("registry"),
            makeAddr("bonds"),
            makeAddr("gate"),
            makeAddr("feeds")
        );
        assertEq(codeless.quotePool(stockPool).degraded, 0xEB, "the same six bits as an unset pointer");
    }

    /// @notice A hook that cannot answer leaves the refusal flags **false**, never true: the quoter fails open for
    ///         display, and an execution path must check `degraded` rather than trust `refuse == false`.
    function test_faults_hookDownFailsOpen() public {
        hookStub.setRefuse(stockPool, true, true);
        assertTrue(quoter.quotePool(stockPool).refuseSell, "refused while the hook answers");

        proxies[SOURCE_HOOK].setMode(QuoterFaultProxy.Mode.REVERT_REASON);
        IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(stockPool);
        assertFalse(quote.refuseSell, "and open once it cannot");
        assertEq(quote.degraded & 0x01, 0x01, "with bit 0 raised");

        (bool refuse,, uint8 degraded) = quoter.wouldRevert(stockPool, true, true, 1e18);
        assertFalse(refuse, "wouldRevert fails open too");
        assertEq(degraded & 0x01, 0x01, "with bit 0 raised");
    }

    /// @notice The gate's own view survives a hook outage: bit 1 stays clear and the gate's fields are intact.
    function test_faults_bitsAreIndependent() public {
        proxies[SOURCE_VAULT].setMode(QuoterFaultProxy.Mode.REVERT_EMPTY);
        IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(stockPool);
        assertEq(quote.degraded, 0x08, "only the checkpoint bit");
        assertEq(quote.navPerShareX18, 0, "nav zeroed");
        assertEq(quote.premiumX18, 0, "premium zeroed");
        assertEq(quote.sellFeePips, SELL_FEE_PIPS, "fees untouched");
        assertEq(uint8(quote.gateState), uint8(GateState.GREEN), "gate untouched");
        assertGt(quote.pMktX18, 0, "market price untouched");
        assertGt(quote.bondQX18, 0, "bond terms untouched");
    }
}

/// @title AmpsQuoterExactnessTest
/// @notice The positive half of the specification: the fee the quoter publishes is the fee the hook charges, and
///         the `amountOut` it publishes is the one the PoolManager pays, to the wei.
contract AmpsQuoterExactnessTest is QuoterFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant STOCK_IN = 55e18; // ~ $9.9k
    uint256 internal constant USDG_IN = 10_000e6;
    uint256 internal constant AMPS_IN = 10_000e18;

    // -------------------------------------------------------------------------------------------------------------
    // 3a. Against a real swap
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A one-hop buy: the quote equals what the PoolManager pays, to the wei, and the fee equals what the
    ///         hook charged.
    function test_quoteExactIn_buyMatchesARealSwap() public {
        (uint256 quoted, uint24 feePips, bool refuse, uint8 degraded) = quoter.quoteExactIn(usdgPool, false, USDG_IN);
        assertFalse(refuse, "not refused");
        assertEq(degraded, 0, "clean");
        assertEq(feePips, BUY_FEE_PIPS, "30 bp");

        vm.recordLogs();
        uint256 received = _swapOneHop(usdgKey, false, USDG_IN);
        uint24[] memory charged = _swapFees(vm.getRecordedLogs());

        assertEq(received, quoted, "buy quoted to the wei");
        assertEq(charged.length, 1, "one hop");
        assertEq(charged[0], feePips, "and the hook charged the quoted fee");
    }

    /// @notice A one-hop uncredited sell, the same way.
    function test_quoteExactIn_sellMatchesARealSwap() public {
        (uint256 quoted, uint24 feePips,, uint8 degraded) = quoter.quoteExactIn(usdgPool, true, AMPS_IN);
        assertEq(degraded, 0, "clean");
        assertEq(feePips, SELL_FEE_PIPS, "500 bp");

        vm.recordLogs();
        uint256 received = _swapOneHop(usdgKey, true, AMPS_IN);
        uint24[] memory charged = _swapFees(vm.getRecordedLogs());

        assertEq(received, quoted, "sell quoted to the wei");
        assertEq(charged[0], feePips, "and the hook charged the quoted fee");
    }

    /// @notice **The rotation.** `STOCK -> AMPS -> USDG` in one transaction, quoted before it happens and matched
    ///         against the router's own output to the wei — including the rotation credit, which turns hop 2 from
    ///         a 500 bp sell into a 30 bp one.
    /// @dev The two hops are one top-level router call, so the hook's EIP-1153 credit is created and spent inside
    ///      a single transaction whether or not the suite runs under `--isolate`.
    function test_quoteRotation_matchesARealTwoHopSwapToTheWei() public {
        (uint256 quoted, uint24 hop1FeePips, uint24 hop2FeePips, uint256 creditUsed) =
            quoter.quoteRotation(stockPool, usdgPool, STOCK_IN);

        assertEq(hop1FeePips, BUY_FEE_PIPS, "hop 1 is a buy");
        assertEq(hop2FeePips, BUY_FEE_PIPS, "hop 2 is fully credited, so it is a buy fee too");
        (uint256 hop1Out,,,) = quoter.quoteExactIn(stockPool, false, STOCK_IN);
        assertEq(creditUsed, hop1Out, "the credit is exactly what hop 1 yields");
        assertGt(quoted, 0, "and the route quotes something");

        vm.recordLogs();
        uint256 received = _twoHopStockToUsdg(STOCK_IN);
        uint24[] memory charged = _swapFees(vm.getRecordedLogs());

        assertEq(received, quoted, "rotation quoted to the wei");
        assertEq(charged.length, 2, "two hops");
        assertEq(charged[0], hop1FeePips, "hop 1 fee as quoted");
        assertEq(charged[1], hop2FeePips, "hop 2 fee as quoted, credit included");
    }

    /// @notice An uncredited sell of the same AMPS costs the sell fee, which is what makes the credit worth
    ///         modelling: the same exit pays 500 bp outside a rotation and 30 bp inside one.
    function test_quoteRotation_creditIsWorthTheDifference() public view {
        (uint256 hop1Out,,,) = quoter.quoteExactIn(stockPool, false, STOCK_IN);
        (uint256 rotated,,,) = quoter.quoteRotation(stockPool, usdgPool, STOCK_IN);
        (uint256 uncredited, uint24 uncreditedFee,,) = quoter.quoteExactIn(usdgPool, true, hop1Out);

        assertEq(uncreditedFee, SELL_FEE_PIPS, "an uncredited exit pays the sell fee");
        assertGt(rotated, uncredited, "and the rotation pays less");
    }

    /// @notice A partially credited sell sits between the two, and its output matches a real swap at the blended
    ///         fee to the wei.
    function test_quoteSellWithCredit_matchesARealSwapAtTheBlendedFee() public {
        uint256 ampsIn = 1000e18;
        uint256 credit = 400e18;
        (uint256 quoted, uint24 feePips, bool refuse, uint8 degraded) =
            quoter.quoteSellWithCredit(usdgPool, ampsIn, credit);
        assertFalse(refuse, "not refused");
        assertEq(degraded, 0, "clean");

        // 30 bp on the credited 400, 500 bp on the uncredited 600, rounded up: 30 + ceil(470 * 600 / 1000) = 312.
        assertEq(feePips, uint24(312) * Constants.PIPS_PER_BPS, "the hand-computed blend");

        // Arming the credit and spending it must happen inside **one** top-level call: Foundry 1.8 clears
        // transient storage between the calls a test makes, exactly as the EVM clears it between transactions.
        uint256 received = this.creditedSell(credit, ampsIn);
        assertEq(received, quoted, "and the pool pays the quoted amount");
    }

    /// @notice Seeds the hook's transient rotation credit and spends it in the same transaction.
    /// @param credit The credit to arm.
    /// @param ampsIn The sell size.
    /// @return amountOut The USDG received.
    function creditedSell(uint256 credit, uint256 ampsIn) external returns (uint256 amountOut) {
        poolHook.debugSetRotationCredit(credit);
        return _swapOneHop(usdgKey, true, ampsIn);
    }

    // -------------------------------------------------------------------------------------------------------------
    // 3b. The arithmetic on its own
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The blend, against hand-computed values across the whole credit range, including a case whose
    ///         division does not divide exactly and therefore exercises the rounding.
    function test_blend_handComputed() public view {
        uint256 ampsIn = 1000e18;

        (, uint24 none,,) = quoter.quoteSellWithCredit(usdgPool, ampsIn, 0);
        assertEq(none, SELL_FEE_PIPS, "no credit is the plain sell fee");

        (, uint24 full,,) = quoter.quoteSellWithCredit(usdgPool, ampsIn, ampsIn);
        assertEq(full, BUY_FEE_PIPS, "a full credit is the plain buy fee");

        (, uint24 over,,) = quoter.quoteSellWithCredit(usdgPool, ampsIn, ampsIn * 3);
        assertEq(over, BUY_FEE_PIPS, "more credit than input is still the buy fee");

        // 30 + ceil(470 * 667 / 1000) = 30 + ceil(313.49) = 344.
        (, uint24 blended,,) = quoter.quoteSellWithCredit(usdgPool, ampsIn, 333e18);
        assertEq(blended, uint24(344) * Constants.PIPS_PER_BPS, "rounded up, never down");
    }

    /// @notice The blend is monotone in the credit and never leaves `[buyFee, sellFee]`.
    /// @param ampsIn The sell size.
    /// @param credit The credit carried into it.
    function testFuzz_blend_boundedAndMonotone(uint128 ampsIn, uint128 credit) public view {
        ampsIn = uint128(bound(ampsIn, 1, type(uint96).max));
        credit = uint128(bound(credit, 0, type(uint96).max));

        (, uint24 feePips,,) = quoter.quoteSellWithCredit(usdgPool, ampsIn, credit);
        assertGe(feePips, BUY_FEE_PIPS, "never below the buy fee");
        assertLe(feePips, SELL_FEE_PIPS, "never above the sell fee");

        if (credit > 0) {
            (, uint24 less,,) = quoter.quoteSellWithCredit(usdgPool, ampsIn, credit - 1);
            assertGe(less, feePips, "more credit is never a higher fee");
        }
    }

    /// @notice The `F_MIN_BPS` floor: a fully credited sell in a 1 bp pool would price at 1 bp, and the hook's
    ///         clamp lifts it to 3.
    function test_blend_fMinFloor() public {
        hookStub.setBuyFeeBps(usdgPool, 1);
        (, uint24 feePips,,) = quoter.quoteSellWithCredit(usdgPool, 1000e18, 1000e18);
        assertEq(feePips, uint24(Constants.F_MIN_BPS) * Constants.PIPS_PER_BPS, "floored at 3 bp");
    }

    /// @notice The dynamic component rides on top of the blended base, exactly as `clamp(base + dyn, ...)` says.
    function test_blend_carriesTheDynamicPart() public {
        hookStub.setFee(
            usdgPool,
            true,
            QuoterHookStub.FeeAnswer({feePips: 75_000, baseBps: SELL_FEE_BPS, dynBps: 250, refuse: false})
        );
        (, uint24 feePips,,) = quoter.quoteSellWithCredit(usdgPool, 1000e18, 1000e18);
        assertEq(feePips, uint24(BUY_FEE_BPS + 250) * Constants.PIPS_PER_BPS, "buy base plus the dynamic part");
    }

    /// @notice The total can never exceed `TOTAL_FEE_BPS_MAX`, whatever the hook reports.
    function test_blend_neverExceedsTheHardCeiling() public {
        hookStub.setFee(
            usdgPool,
            true,
            QuoterHookStub.FeeAnswer({feePips: 999_999, baseBps: SELL_FEE_BPS, dynBps: type(uint16).max, refuse: false})
        );
        (, uint24 feePips,,) = quoter.quoteSellWithCredit(usdgPool, 1000e18, 0);
        assertEq(feePips, uint24(Constants.TOTAL_FEE_BPS_MAX) * Constants.PIPS_PER_BPS, "clamped");
    }

    // -------------------------------------------------------------------------------------------------------------
    // 3c. The rail, the NAV floor and the walk's bound
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A refused leg quotes zero out and says so, on both the single quote and the rotation.
    function test_rail_refusedLegQuotesNothing() public {
        hookStub.setRefuse(usdgPool, true, true);

        (uint256 amountOut, uint24 feePips, bool refuse, uint8 degraded) = quoter.quoteExactIn(usdgPool, true, AMPS_IN);
        assertTrue(refuse, "refused");
        assertEq(amountOut, 0, "nothing comes out of a swap that reverts");
        assertEq(feePips, SELL_FEE_PIPS, "the fee it would have paid is still reported");
        assertEq(degraded, 0, "a refusal is not a degraded read");

        (bool wouldRefuse, bytes32 reason,) = quoter.wouldRevert(usdgPool, true, true, AMPS_IN);
        assertTrue(wouldRefuse, "wouldRevert agrees");
        assertEq(reason, bytes32("rail"), "and blames the rail");

        (uint256 rotated,, uint24 hop2FeePips,) = quoter.quoteRotation(stockPool, usdgPool, STOCK_IN);
        assertEq(rotated, 0, "the route is dead");
        assertGt(hop2FeePips, 0, "but the fee it would have paid is still reported");
    }

    /// @notice A pool the PoolManager has never initialised would revert, and {wouldRevert} says which.
    function test_wouldRevert_uninitializedPool() public view {
        (bool refuse, bytes32 reason, uint8 degraded) =
            quoter.wouldRevert(PoolId.wrap(keccak256("never")), true, true, 1e18);
        assertTrue(refuse, "refused");
        assertEq(reason, bytes32("uninitialized"), "because there is no pool");
        assertEq(degraded, 0, "the PoolManager answered, the pool is just empty");
    }

    /// @notice The NAV rail: the tick at which the pool prices AMPS at NAV/share, 800 ticks of slack below it, and
    ///         a live tick that is only under the rail when NAV says it is.
    function test_navRail() public {
        (int24 navTick, int24 railTick, bool belowRail, uint256 nav, uint8 degraded) = quoter.navRail(stockPool);
        assertEq(degraded, 0, "clean");
        assertEq(nav, NAV_X18, "nav/share");
        assertEq(navTick, PriceLib.fairTick(NAV_X18, STOCK_PRICE_USD8, 18, TICK_SPACING), "the NAV tick");
        assertEq(railTick, navTick - quoter.NAV_RAIL_TICKS(), "800 ticks below it");
        assertFalse(belowRail, "the pool is seeded at NAV");

        // Lifting NAV by 50% lifts the rail by ~4,055 ticks, which the seeded pool is now far below.
        vaultMock.setCheckpoint(1.5e18, 1.5e18, NAV_X18, uint32(block.timestamp));
        (,, bool belowNow,,) = quoter.navRail(stockPool);
        assertTrue(belowNow, "and the pool is under the redemption floor");
    }

    /// @notice A walk that cannot finish inside {MAX_SWAP_STEPS} publishes nothing and raises bit 7, rather than
    ///         publishing the part of the swap it managed to price.
    function test_walk_isBounded() public view {
        (uint256 amountOut,,, uint8 degraded) = quoter.quoteExactIn(stockPool, true, 1e30);
        assertEq(amountOut, 0, "no number");
        assertEq(degraded, 0x80, "bit 7");

        (uint256 rotated,,, uint256 credit) = quoter.quoteRotation(stockPool, usdgPool, 1e30);
        assertEq(rotated + credit, 0, "and a rotation through it quotes nothing");
    }

    /// @notice What the two reads cost, so a later change that makes the quoter quietly unaffordable for an
    ///         aggregator's `eth_call` budget shows up as a failing test rather than as a support ticket.
    /// @dev Measured against the fault proxies, which add one forwarding `staticcall` per read on top of the real
    ///      cost. The ceilings are round numbers well above the current figures, not a baseline to be tuned.
    function test_gas() public view {
        uint256 start = gasleft();
        quoter.quotePool(stockPool);
        uint256 poolQuote = start - gasleft();

        start = gasleft();
        quoter.quoteRotation(stockPool, usdgPool, STOCK_IN);
        uint256 rotation = start - gasleft();

        start = gasleft();
        quoter.quoteExactIn(usdgPool, false, USDG_IN);
        uint256 oneHop = start - gasleft();

        console.log("quotePool      ", poolQuote);
        console.log("quoteExactIn   ", oneHop);
        console.log("quoteRotation  ", rotation);

        assertLt(poolQuote, 400_000, "quotePool");
        assertLt(oneHop, 200_000, "quoteExactIn");
        assertLt(rotation, 400_000, "quoteRotation");
    }

    /// @notice A zero-amount quote is a fee quote, not a failure.
    function test_walk_zeroAmount() public view {
        (uint256 amountOut, uint24 feePips,, uint8 degraded) = quoter.quoteExactIn(usdgPool, false, 0);
        assertEq(amountOut, 0, "nothing in, nothing out");
        assertEq(feePips, BUY_FEE_PIPS, "the fee is still the fee");
        assertEq(degraded, 0, "and nothing is degraded");
    }

    /// @notice Sizes from dust to a large fraction of the pool all match a real swap to the wei.
    /// @param amountIn The buy size in USDG.
    function testFuzz_quoteExactIn_matchesARealSwap(uint96 amountIn) public {
        amountIn = uint96(bound(amountIn, 1e3, 200_000e6));
        (uint256 quoted,,, uint8 degraded) = quoter.quoteExactIn(usdgPool, false, amountIn);
        vm.assume(degraded == 0);
        uint256 received = _swapOneHop(usdgKey, false, amountIn);
        assertEq(received, quoted, "to the wei");
    }

    // -------------------------------------------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------------------------------------------

    function _swapOneHop(PoolKey memory key, bool zeroForOne, uint256 amountIn) private returns (uint256 amountOut) {
        MockERC20 outToken = zeroForOne ? MockERC20(Currency.unwrap(key.currency1)) : amps;
        uint256 balanceBefore = outToken.balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, key, "", address(this), block.timestamp + 1);
        amountOut = outToken.balanceOf(address(this)) - balanceBefore;
    }

    function _twoHopStockToUsdg(uint256 amountIn) private returns (uint256 amountOut) {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(AMPS_ADDRESS),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(poolHook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(USDG_ADDRESS),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(poolHook)),
            hookData: ""
        });

        uint256 balanceBefore = usdg.balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(
            amountIn, 0, Currency.wrap(STOCK_ADDRESS), path, address(this), block.timestamp + 1
        );
        amountOut = usdg.balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Every `IPoolManager.Swap` fee field in the recorded logs, in emission order (one per hop).
    function _swapFees(Vm.Log[] memory logs) private pure returns (uint24[] memory fees) {
        uint256 count;
        uint24[] memory buffer = new uint24[](logs.length);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                buffer[count++] = fee;
            }
        }
        fees = new uint24[](count);
        for (uint256 i = 0; i < count; ++i) {
            fees[i] = buffer[i];
        }
    }
}

/// @title QuoterAbiLayoutTest
/// @notice `AmpsQuoter` and `OracleGate` both read `HookPoolState` by **word index** rather than by
///         `abi.decode`, because a hostile or mis-pointed hook can answer with a `bool` that is not 0 or 1 or an
///         enum ordinal out of range, and Solidity's decoder answers those with an uncatchable `Panic`.
///
/// @dev Hand-unpacking buys immunity at the price of a coupling: the indices are only correct while the struct's
///      field order is. Appending a field is safe and keeps every index; **reordering one is not**, and it would
///      be silent — the quoter would render a different field and the gate would read a different flag. This
///      suite is the tripwire. It fails the moment `Types.HookPoolState` is reshaped, naming the constant that
///      has to move with it.
contract QuoterAbiLayoutTest is Test {
    /// @dev The indices `AmpsQuoter._poolState` and `OracleGate._hookCorporateArmed` are written against.
    function test_hookPoolStateWordIndices() public pure {
        HookPoolState memory state;
        state.initialized = true;
        state.poolClass = PoolClass.SPOKE_HIGH_VOL;
        state.constituentId = 7;
        state.buyFeeBps = 11;
        state.tickSpacing = 60;
        state.innerBandTicks = 200;
        state.outerRailTicks = 800;
        state.dynCapBps = 300;
        state.counterDecimals = 6;
        state.gridBaseTick = -120;
        state.lastTick = -1234;
        state.fairTick = -1200;
        state.session = Session.OVERNIGHT;
        state.gateFlags = 0x08;
        state.fVolBps = 42;
        state.gateRefreshedAt = 1_800_000_000;

        bytes memory encoded = abi.encode(state);
        assertEq(encoded.length, 25 * 32, "25 static fields, one word each");

        assertEq(_word(encoded, 0), 1, "0 initialized");
        assertEq(_word(encoded, 1), uint256(uint8(PoolClass.SPOKE_HIGH_VOL)), "1 poolClass");
        assertEq(_word(encoded, 2), 7, "2 constituentId");
        assertEq(_word(encoded, 3), 11, "3 buyFeeBps");
        assertEq(int256(_word(encoded, 4)), int256(60), "4 tickSpacing");
        assertEq(_word(encoded, 13), 200, "13 innerBandTicks");
        assertEq(_word(encoded, 14), 800, "14 outerRailTicks");
        assertEq(_word(encoded, 15), 300, "15 dynCapBps");
        assertEq(_word(encoded, 17), 6, "17 counterDecimals");
        assertEq(int24(int256(_word(encoded, 18))), int24(-120), "18 gridBaseTick");
        assertEq(int24(int256(_word(encoded, 19))), int24(-1234), "19 lastTick");
        assertEq(int24(int256(_word(encoded, 20))), int24(-1200), "20 fairTick");
        assertEq(_word(encoded, 21), uint256(uint8(Session.OVERNIGHT)), "21 session");
        assertEq(_word(encoded, 22), 0x08, "22 gateFlags -- OracleGate.HOOK_POOL_STATE_GATE_FLAGS_WORD");
        assertEq(_word(encoded, 23), 42, "23 fVolBps");
        assertEq(_word(encoded, 24), 1_800_000_000, "24 gateRefreshedAt");
    }

    /// @dev The same, for the other four shapes the quoter unpacks by hand.
    function test_otherWordIndices() public pure {
        PoolConfig memory pool = PoolConfig({
            counter: address(0xC0FFEE),
            poolClass: PoolClass.ENTRY,
            counterDecimals: 6,
            tickSpacing: 10,
            buyFeeBps: 30,
            constituentId: 3,
            registered: true,
            gridBaseTick: -276_360
        });
        bytes memory encoded = abi.encode(pool);
        assertEq(encoded.length, 8 * 32, "PoolConfig is eight words");
        assertEq(address(uint160(_word(encoded, 0))), address(0xC0FFEE), "0 counter");
        assertEq(_word(encoded, 6), 1, "6 registered");

        Checkpoint memory checkpoint =
            Checkpoint({navPerShareX18: 1e18, pRefX18: 2e18, pMktX18: 3e18, timestamp: 4, blockNumber: 5});
        encoded = abi.encode(checkpoint);
        assertEq(encoded.length, 5 * 32, "Checkpoint is five words");
        assertEq(_word(encoded, 1), 2e18, "1 pRefX18");
        assertEq(_word(encoded, 3), 4, "3 timestamp");

        GateSnapshot memory snapshot;
        snapshot.dynCapBps = 300;
        snapshot.fairTick = -1200;
        snapshot.corporateFreeze = true;
        encoded = abi.encode(snapshot);
        assertEq(encoded.length, 13 * 32, "GateSnapshot is thirteen words");
        assertEq(_word(encoded, 3), 1, "3 corporateFreeze");
        assertEq(_word(encoded, 7), 300, "7 dynCapBps");
        assertEq(int24(int256(_word(encoded, 9))), int24(-1200), "9 fairTick");

        BondMarket memory market;
        market.open = true;
        market.decimals = 18;
        encoded = abi.encode(market);
        assertEq(encoded.length, 15 * 32, "BondMarket is fifteen words");
        assertEq(_word(encoded, 2), 1, "2 open");
        assertEq(_word(encoded, 3), 18, "3 decimals");
    }

    function _word(bytes memory data, uint256 index) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }
}
