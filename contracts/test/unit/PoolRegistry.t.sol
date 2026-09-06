// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolRegistry} from "../../src/interfaces/IPoolRegistry.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {PoolRegistry} from "../../src/registry/PoolRegistry.sol";
import {PoolRegistryLens} from "../../src/registry/PoolRegistryLens.sol";
import {Constants} from "../../src/types/Constants.sol";
import {
    AlreadyInitialized,
    LengthMismatch,
    NotTimelock,
    OutOfBand,
    UnknownConstituent,
    UnknownPool,
    ZeroAddress
} from "../../src/types/Errors.sol";
import {
    CollateralClass,
    ConstituentConfig,
    ConstituentStatus,
    InclusionRecord,
    PoolClass,
    PoolConfig
} from "../../src/types/Types.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockBondsForRegistry} from "../mocks/MockBondsForRegistry.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockVaultForRegistry} from "../mocks/MockVaultForRegistry.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title PoolRegistryFixture
/// @notice The registry under test wired to the two mocks it drives, plus the 32-pool launch fixture: 30 mock
///         Stock Tokens with their own aggregators, WETH9 and USDG.
/// @dev    AMPS is the *mined example address* from `script/config/amps-mining-example.json`. It is used verbatim
///         rather than a round number because every pool key in the protocol depends on AMPS sorting below every
///         counter asset, and a test that quietly used `address(1)` would prove nothing about the real deployment.
abstract contract PoolRegistryFixture is Test {
    /// @dev The CREATE2-mined AMPS address, three leading zero bytes, sorts below every counter asset.
    address internal constant AMPS = 0x000000dD2F33b84B4430E5Bc69c5d4BF1eE9fd4d;

    /// @dev A stand-in for the flag-mined hook: the low 14 bits are `Constants.HOOK_FLAGS`.
    address internal constant HOOK = address(uint160(0x00000000000000000000000000000000000038c0));

    address internal constant TIMELOCK = address(0x7E10C4);
    address internal constant GUARDIAN = address(0x64A2D1);
    address internal constant STRANGER = address(0xBAD);

    /// @dev The launch set of Decision 2, in the order `packages/config` lists it.
    string[30] internal LAUNCH_SYMBOLS = [
        "AAPL",
        "AMD",
        "AMZN",
        "ASML",
        "BABA",
        "CLSK",
        "COIN",
        "CRCL",
        "CRWV",
        "DELL",
        "GME",
        "GOOGL",
        "INTC",
        "IONQ",
        "META",
        "MSFT",
        "MSTR",
        "MU",
        "NBIS",
        "NVDA",
        "ORCL",
        "PLTR",
        "RGTI",
        "RKLB",
        "SNDK",
        "SPCX",
        "TSLA",
        "TSM",
        "SPY",
        "QQQ"
    ];

    int24 internal constant SPOKE_TICK_SPACING = 60;
    int24 internal constant ENTRY_TICK_SPACING = 60;

    PoolRegistry internal registry;
    PoolRegistryLens internal lens;
    MockVaultForRegistry internal vault;
    MockBondsForRegistry internal bonds;

    MockStockToken internal weth;
    MockERC20 internal usdg;
    MockAggregator internal wethFeed;
    MockAggregator internal usdgFeed;

    MockStockToken[30] internal stocks;
    MockAggregator[30] internal feeds;

    function setUp() public virtual {
        bonds = new MockBondsForRegistry();
        vault = new MockVaultForRegistry(address(bonds), AMPS, TIMELOCK);
        vault.setPRefX18(1e18);

        weth = new MockStockToken("Wrapped Ether", "WETH");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        wethFeed = new MockAggregator("ETH / USD", 8, 4000e8);
        usdgFeed = new MockAggregator("USDG / USD", 8, 1e8);

        for (uint256 i; i < 30; ++i) {
            stocks[i] = new MockStockToken(LAUNCH_SYMBOLS[i], LAUNCH_SYMBOLS[i]);
            feeds[i] = new MockAggregator(string.concat(LAUNCH_SYMBOLS[i], " / USD"), 8, int256(_price(i)));
            vm.label(address(stocks[i]), LAUNCH_SYMBOLS[i]);
        }

        registry = new PoolRegistry(address(vault), HOOK, TIMELOCK, AMPS, address(weth), address(usdg));
        lens = new PoolRegistryLens(address(registry));

        vm.label(AMPS, "AMPS");
        vm.label(address(registry), "PoolRegistry");
        vm.label(address(lens), "PoolRegistryLens");
        vm.label(address(vault), "MockVault");
        vm.label(address(bonds), "MockBonds");
    }

    /* -------------------------------------------- fixture data -------------------------------------------- */

    /// @dev A plausible 8-decimal price per launch name; NVDA (index 19) is pinned at $180 because the
    ///      `sqrtPriceX96` assertion is written against it.
    function _price(uint256 index) internal pure returns (uint256 priceUsd8) {
        if (index == 19) return 180e8;
        priceUsd8 = (20 + index * 7) * 1e8;
    }

    /// @dev The inclusion evidence a name that passes the beta rule carries: beta 0.9 against a 3% tracking error
    ///      and 20% index vol, i.e. a threshold of 0.51125.
    function _passingInclusion() internal pure returns (InclusionRecord memory record) {
        record = InclusionRecord({
            betaX18: 0.9e18, trackingErrorX18: 0.03e18, indexVolX18: 0.2e18, historyDays: 400, recordedAt: 0
        });
    }

    function _addParams(uint256 index) internal view returns (IPoolRegistry.AddConstituentParams memory params) {
        params = IPoolRegistry.AddConstituentParams({
            token: address(stocks[index]),
            feed: address(feeds[index]),
            poolClass: PoolClass.SPOKE,
            tickSpacing: SPOKE_TICK_SPACING,
            buyFeeBps: Constants.BUY_FEE_BPS_SPOKE_DEFAULT,
            // 500 bp is legal at every `n`: the floor is 500 up to n = 10 and falls after it, and the cap is never
            // below 3000. It is replaced wholesale by `setIndexWeights` once the set is complete.
            targetWeightBps: 500,
            rolloutWeightBps: 300,
            hSessionOverrideBps: 0,
            hSessionOverrideSet: false,
            inclusion: _passingInclusion(),
            openBondMarket: true
        });
    }

    function _add(uint256 index) internal returns (uint16 constituentId, PoolId poolId) {
        vm.prank(TIMELOCK);
        (constituentId, poolId) = registry.addConstituent(_addParams(index));
    }

    function _addWith(IPoolRegistry.AddConstituentParams memory params)
        internal
        returns (uint16 constituentId, PoolId poolId)
    {
        vm.prank(TIMELOCK);
        (constituentId, poolId) = registry.addConstituent(params);
    }

    function _entryKey(address counter) internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(AMPS),
            currency1: Currency.wrap(counter),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: ENTRY_TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    function _spokeKey(address counter) internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(AMPS),
            currency1: Currency.wrap(counter),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: SPOKE_TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    function _registerEntryPools() internal {
        vm.startPrank(TIMELOCK);
        registry.registerEntryPool(_entryKey(address(usdg)), 6, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, address(usdgFeed));
        registry.registerEntryPool(_entryKey(address(weth)), 18, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, address(wethFeed));
        vm.stopPrank();
    }

    /// @dev A weight vector for `n` active names that sums to exactly `BPS` and respects the floor at that `n`.
    function _evenWeights(uint16 n) internal pure returns (uint16[] memory weightsBps) {
        weightsBps = new uint16[](n);
        uint16 each = uint16(Constants.BPS / n);
        uint16 remainder = uint16(Constants.BPS - uint256(each) * n);
        for (uint16 i; i < n; ++i) {
            weightsBps[i] = each + (i == 0 ? remainder : 0);
        }
    }

    function _ids(uint16 n) internal pure returns (uint16[] memory ids) {
        ids = new uint16[](n);
        for (uint16 i; i < n; ++i) {
            ids[i] = i + 1;
        }
    }
}

/// @title PoolRegistryTest
/// @notice Unit coverage for `PoolRegistry`: the 32-pool launch registration, the constituent lifecycle, every
///         hard band, the index weight rule, the timelock guard and the structural pool-key requirements.
contract PoolRegistryTest is PoolRegistryFixture {
    // -------------------------------------------------------------------------------------------------------------
    // Construction and wiring
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The constructor records the six addresses the registry can never change.
    function test_constructor_wiring() public view {
        assertEq(registry.vault(), address(vault), "vault");
        assertEq(registry.hook(), HOOK, "hook");
        (address timelockAddress, address ampsAddress, address weth9Address, address usdgAddress) = registry.wiring();
        assertEq(timelockAddress, TIMELOCK, "timelock");
        assertEq(ampsAddress, AMPS, "amps");
        assertEq(weth9Address, address(weth), "weth9");
        assertEq(usdgAddress, address(usdg), "usdg");
        assertEq(registry.constituentCount(), 0, "no constituents");
        assertEq(registry.activeConstituentCount(), 0, "no active constituents");
        assertEq(registry.poolCount(), 0, "no pools");
    }

    /// @notice Every constructor argument is required.
    function test_constructor_revertsOnZeroAddress() public {
        for (uint256 i; i < 6; ++i) {
            // Rebuilt inside the loop: a `memory` struct or array assigned to another `memory` variable is an
            // alias, not a copy, so a hoisted template would accumulate the previous iterations' zeroes.
            address[6] memory args = [address(vault), HOOK, TIMELOCK, AMPS, address(weth), address(usdg)];
            args[i] = address(0);
            vm.expectRevert(ZeroAddress.selector);
            new PoolRegistry(args[0], args[1], args[2], args[3], args[4], args[5]);
        }
    }

    /// @notice The hard bands the interface exposes are the ones in `Constants`, not restated literals.
    function test_hardBandsMatchConstants() public view {
        assertEq(registry.MAX_CONSTITUENTS(), Constants.MAX_CONSTITUENTS, "MAX_CONSTITUENTS");
        assertEq(registry.BUY_FEE_BPS_ENTRY_MIN(), Constants.BUY_FEE_BPS_ENTRY_MIN, "entry min");
        assertEq(registry.BUY_FEE_BPS_ENTRY_MAX(), Constants.BUY_FEE_BPS_ENTRY_MAX, "entry max");
        assertEq(registry.BUY_FEE_BPS_SPOKE_MIN(), Constants.BUY_FEE_BPS_SPOKE_MIN, "spoke min");
        assertEq(registry.BUY_FEE_BPS_SPOKE_MAX(), Constants.BUY_FEE_BPS_SPOKE_MAX, "spoke max");
        assertEq(registry.MIN_HISTORY_DAYS(), Constants.MIN_HISTORY_DAYS, "history");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Entry pools
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The two entry pools register with class ENTRY, constituent id 0, and land in the hub/WETH slots.
    function test_registerEntryPool_hubAndWeth() public {
        PoolKey memory hubKey = _entryKey(address(usdg));
        PoolId hubId = hubKey.toId();

        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.PoolRegistered(hubId, address(usdg), PoolClass.ENTRY, 0);

        vm.prank(TIMELOCK);
        registry.registerEntryPool(hubKey, 6, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, address(usdgFeed));

        assertEq(PoolId.unwrap(registry.hubPoolId()), PoolId.unwrap(hubId), "hub pool id");
        assertTrue(registry.isRegistered(hubId), "registered");
        assertEq(registry.constituentOfPool(hubId), 0, "entry pools carry constituent id 0");

        PoolConfig memory config = registry.poolConfig(hubId);
        assertEq(config.counter, address(usdg), "counter");
        assertEq(uint8(config.poolClass), uint8(PoolClass.ENTRY), "class");
        assertEq(config.counterDecimals, 6, "decimals");
        assertEq(config.tickSpacing, ENTRY_TICK_SPACING, "tick spacing");
        assertEq(config.buyFeeBps, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, "buy fee");
        assertTrue(config.registered, "registered flag");

        PoolKey memory stored = registry.poolKey(hubId);
        assertEq(Currency.unwrap(stored.currency0), AMPS, "currency0");
        assertEq(Currency.unwrap(stored.currency1), address(usdg), "currency1");
        assertEq(stored.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "dynamic fee flag");
        assertEq(address(stored.hooks), HOOK, "hook");

        vm.prank(TIMELOCK);
        registry.registerEntryPool(_entryKey(address(weth)), 18, 30, address(wethFeed));
        assertEq(PoolId.unwrap(registry.wethPoolId()), PoolId.unwrap(_entryKey(address(weth)).toId()), "weth pool id");
        assertEq(registry.poolCount(), 2, "two pools");
        assertEq(registry.constituentCount(), 0, "entry pools are not constituents");
    }

    /// @notice The hub pool is opened at `P_ref / P_USDG` through the vault, with USDG's six decimals.
    function test_registerEntryPool_initialisesThroughVaultAtReferencePrice() public {
        vault.setPRefX18(1e18);
        vm.prank(TIMELOCK);
        registry.registerEntryPool(_entryKey(address(usdg)), 6, 30, address(usdgFeed));

        MockVaultForRegistry.InitCall memory call = vault.lastInitCall();
        assertEq(call.sqrtPriceX96, PriceLib.ampsPerCounterToSqrtPriceX96(1e18, 1e8, 6), "sqrtPriceX96");
        assertEq(PoolId.unwrap(call.poolId), PoolId.unwrap(_entryKey(address(usdg)).toId()), "pool id");
        assertEq(vault.initCallCount(), 1, "one initialisation");
    }

    /// @notice Before genesis the vault reports no reference price; the entry pools open at the $1.00 launch price.
    function test_registerEntryPool_preGenesisUsesLaunchPrice() public {
        vault.setPRefX18(0);
        vm.prank(TIMELOCK);
        registry.registerEntryPool(_entryKey(address(usdg)), 6, 30, address(usdgFeed));
        assertEq(vault.lastInitCall().sqrtPriceX96, PriceLib.ampsPerCounterToSqrtPriceX96(1e18, 1e8, 6), "launch price");
    }

    /// @notice A pool whose counter is neither WETH9 nor USDG is not an entry pool.
    function test_registerEntryPool_revertsOnForeignCounter() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("counterNotEntryAsset")));
        registry.registerEntryPool(_entryKey(address(stocks[0])), 18, 30, address(feeds[0]));
    }

    /// @notice The three structural key requirements are enforced on the entry path too.
    function test_registerEntryPool_revertsOnMalformedKey() public {
        // Each mutation starts from a fresh key: `PoolKey memory a = b` aliases, it does not copy.
        PoolKey memory wrongCurrency0 = _entryKey(address(usdg));
        wrongCurrency0.currency0 = Currency.wrap(address(weth));
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("currency0NotAmps")));
        registry.registerEntryPool(wrongCurrency0, 6, 30, address(usdgFeed));

        PoolKey memory staticFee = _entryKey(address(usdg));
        staticFee.fee = 3000;
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("notDynamicFee")));
        registry.registerEntryPool(staticFee, 6, 30, address(usdgFeed));

        PoolKey memory foreignHook = _entryKey(address(usdg));
        foreignHook.hooks = IHooks(address(0xDEAD));
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("hooks")));
        registry.registerEntryPool(foreignHook, 6, 30, address(usdgFeed));

        PoolKey memory badSpacing = _entryKey(address(usdg));
        badSpacing.tickSpacing = 0;
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("tickSpacing")));
        registry.registerEntryPool(badSpacing, 6, 30, address(usdgFeed));

        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("counterDecimals")));
        registry.registerEntryPool(_entryKey(address(usdg)), 18, 30, address(usdgFeed));
    }

    /// @notice The entry buy fee lives in `[5, 100]` bp.
    function test_registerEntryPool_buyFeeBand() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("buyFeeBps"),
                uint256(Constants.BUY_FEE_BPS_ENTRY_MIN - 1),
                uint256(Constants.BUY_FEE_BPS_ENTRY_MIN),
                uint256(Constants.BUY_FEE_BPS_ENTRY_MAX)
            )
        );
        registry.registerEntryPool(_entryKey(address(usdg)), 6, Constants.BUY_FEE_BPS_ENTRY_MIN - 1, address(usdgFeed));

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("buyFeeBps"),
                uint256(Constants.BUY_FEE_BPS_ENTRY_MAX + 1),
                uint256(Constants.BUY_FEE_BPS_ENTRY_MIN),
                uint256(Constants.BUY_FEE_BPS_ENTRY_MAX)
            )
        );
        registry.registerEntryPool(_entryKey(address(usdg)), 6, Constants.BUY_FEE_BPS_ENTRY_MAX + 1, address(usdgFeed));
    }

    /// @notice Neither entry pool can be registered twice.
    function test_registerEntryPool_revertsOnSecondRegistration() public {
        _registerEntryPools();

        vm.prank(TIMELOCK);
        vm.expectRevert(AlreadyInitialized.selector);
        registry.registerEntryPool(_entryKey(address(usdg)), 6, 30, address(usdgFeed));

        // A different tick spacing is a different pool id, but the hub slot is already taken.
        PoolKey memory other = _entryKey(address(usdg));
        other.tickSpacing = 10;
        vm.prank(TIMELOCK);
        vm.expectRevert(AlreadyInitialized.selector);
        registry.registerEntryPool(other, 6, 30, address(usdgFeed));
    }

    // -------------------------------------------------------------------------------------------------------------
    // The launch registration: 32 pools
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The whole launch set: two entry pools and the 30 spokes of Decision 2, then the quarterly weight
    ///         vector. Gas per registration is printed so the 7-day proposal can be costed.
    function test_launch_registers32Pools() public {
        _registerEntryPools();

        uint256 total;
        uint256 worst;
        for (uint256 i; i < 30; ++i) {
            IPoolRegistry.AddConstituentParams memory params = _addParams(i);
            vm.prank(TIMELOCK);
            uint256 before = gasleft();
            (uint16 id, PoolId poolId) = registry.addConstituent(params);
            uint256 used = before - gasleft();
            total += used;
            if (used > worst) worst = used;

            assertEq(id, uint16(i + 1), "ids are issued in order");
            assertEq(registry.constituentIdOf(address(stocks[i])), id, "token -> id");
            assertEq(PoolId.unwrap(registry.poolIdOf(id)), PoolId.unwrap(poolId), "id -> pool");
            assertEq(registry.constituentOfPool(poolId), id, "pool -> id");
            console2.log(LAUNCH_SYMBOLS[i], used);
        }

        console2.log("addConstituent gas: total", total);
        console2.log("addConstituent gas: mean", total / 30);
        console2.log("addConstituent gas: worst", worst);

        assertEq(registry.poolCount(), Constants.LAUNCH_POOLS, "32 pools");
        assertEq(registry.constituentCount(), Constants.LAUNCH_CONSTITUENTS, "30 constituents");
        assertEq(registry.activeConstituentCount(), Constants.LAUNCH_CONSTITUENTS, "30 active");
        assertEq(vault.initCallCount(), Constants.LAUNCH_POOLS, "every pool initialised through the vault");
        assertEq(bonds.addCallCount(), Constants.LAUNCH_CONSTITUENTS, "one bond market per spoke");

        // The published quarterly rule then replaces the placeholder weights wholesale.
        vm.prank(TIMELOCK);
        registry.setIndexWeights(_ids(30), _evenWeights(30));

        (uint16[] memory ids, uint16[] memory weightsBps, uint256 totalBps) = lens.indexWeights();
        assertEq(ids.length, 30, "30 weighted names");
        assertEq(totalBps, Constants.BPS, "weights sum to 100%");
        assertEq(weightsBps[0], 343, "largest-remainder head");
        assertEq(weightsBps[29], 333, "even tail");
    }

    /// @notice AMPS sorts below every counter asset in the fixture, which is what makes it `currency0` everywhere.
    function test_launch_ampsIsCurrency0Everywhere() public {
        _registerEntryPools();
        for (uint256 i; i < 30; ++i) {
            assertLt(uint160(AMPS), uint160(address(stocks[i])), "AMPS below every stock token");
            _add(i);
        }
        assertLt(uint160(AMPS), uint160(address(weth)), "AMPS below WETH9");
        assertLt(uint160(AMPS), uint160(address(usdg)), "AMPS below USDG");

        for (uint256 i; i < 30; ++i) {
            PoolKey memory key = registry.poolKey(registry.poolIdOf(uint16(i + 1)));
            assertEq(Currency.unwrap(key.currency0), AMPS, "currency0 is AMPS");
            assertEq(Currency.unwrap(key.currency1), address(stocks[i]), "currency1 is the stock");
            assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "dynamic fee");
            assertEq(key.tickSpacing, SPOKE_TICK_SPACING, "configured tick spacing");
            assertEq(address(key.hooks), HOOK, "the one hook");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // addConstituent
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A registration writes the constituent record, the inclusion evidence, the pool record and the key,
    ///         emits both events and opens the bond market in the same proposal.
    function test_addConstituent_writesEveryRecord() public {
        _registerEntryPools();

        IPoolRegistry.AddConstituentParams memory params = _addParams(19); // NVDA
        params.poolClass = PoolClass.SPOKE_HIGH_VOL;
        params.buyFeeBps = Constants.BUY_FEE_BPS_SPOKE_HIGH_VOL_DEFAULT;
        params.hSessionOverrideBps = 250;
        params.hSessionOverrideSet = true;

        PoolId expectedId = _spokeKey(address(stocks[19])).toId();

        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.PoolRegistered(expectedId, address(stocks[19]), PoolClass.SPOKE_HIGH_VOL, 1);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentAdded(1, address(stocks[19]), expectedId, params.targetWeightBps);

        (uint16 id, PoolId poolId) = _addWith(params);
        assertEq(id, 1, "first id is 1");
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(expectedId), "pool id");

        ConstituentConfig memory config = registry.constituent(id);
        assertEq(config.token, address(stocks[19]), "token");
        assertEq(uint8(config.status), uint8(ConstituentStatus.ACTIVE), "active");
        assertEq(config.decimals, 18, "decimals");
        assertEq(config.targetWeightBps, params.targetWeightBps, "target weight");
        assertEq(config.rolloutWeightBps, params.rolloutWeightBps, "rollout weight");
        assertEq(config.hSessionOverrideBps, 250, "haircut override");
        assertTrue(config.hSessionOverrideSet, "haircut override set");
        assertFalse(config.caFreezeOverride, "no forced freeze");
        assertEq(config.marketId, 1, "bond market recorded");
        assertEq(config.feed, address(feeds[19]), "feed");
        assertEq(config.freezeUntil, 0, "no guardian freeze");
        assertEq(config.addedAt, uint32(block.timestamp), "addedAt");
        assertEq(config.retiredAt, 0, "never retired");

        InclusionRecord memory record = registry.inclusionRecord(id);
        assertEq(record.betaX18, 0.9e18, "beta");
        assertEq(record.trackingErrorX18, 0.03e18, "tracking error");
        assertEq(record.indexVolX18, 0.2e18, "index vol");
        assertEq(record.historyDays, 400, "history");
        assertEq(record.recordedAt, uint32(block.timestamp), "recordedAt is stamped in-contract");

        PoolConfig memory pool = registry.poolConfig(poolId);
        assertEq(pool.counter, address(stocks[19]), "counter");
        assertEq(uint8(pool.poolClass), uint8(PoolClass.SPOKE_HIGH_VOL), "class");
        assertEq(pool.counterDecimals, 18, "counter decimals");
        assertEq(pool.buyFeeBps, Constants.BUY_FEE_BPS_SPOKE_HIGH_VOL_DEFAULT, "buy fee");
        assertEq(pool.constituentId, 1, "constituent id");
        assertTrue(pool.registered, "registered");

        MockBondsForRegistry.AddCall memory call = bonds.addCall(0);
        assertEq(call.collateral, address(stocks[19]), "collateral");
        assertEq(uint8(call.class), uint8(CollateralClass.CONSTITUENT), "class");
        assertEq(call.dBaseBps, Constants.BOND_D_BASE_BPS_DEFAULT, "dBase");
        assertEq(call.dMinBps, Constants.BOND_D_MIN_BPS_DEFAULT, "dMin");
        assertEq(call.dMaxBps, Constants.BOND_D_MAX_BPS_DEFAULT, "dMax");
        assertEq(call.capBpsPerEpoch, Constants.BOND_CAP_BPS_PER_EPOCH_DEFAULT, "capacity");
        assertTrue(call.open, "market opens with the spoke");
    }

    /// @notice `openBondMarket == false` registers the spoke and leaves `AmpsBonds` untouched.
    function test_addConstituent_withoutBondMarket() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.openBondMarket = false;
        (uint16 id,) = _addWith(params);
        assertEq(bonds.addCallCount(), 0, "no collateral added");
        assertEq(registry.constituent(id).marketId, 0, "no market id");
    }

    /// @notice The pool opens at `P_ref / P_i`: AMPS at $1.00 against NVDA at $180 is 1/180 counter per AMPS.
    function test_addConstituent_initialPriceForOneDollarAgainstA180DollarStock() public {
        vault.setPRefX18(1e18);
        (, PoolId poolId) = _add(19);

        MockVaultForRegistry.InitCall memory call = vault.lastInitCall();
        uint160 expected = PriceLib.ampsPerCounterToSqrtPriceX96(1e18, 180e8, 18);
        assertEq(call.sqrtPriceX96, expected, "sqrtPriceX96 from PriceLib");
        assertEq(PoolId.unwrap(call.poolId), PoolId.unwrap(poolId), "pool id");

        // Independent check, not a restatement: the pool price is 1/180 counter raw units per AMPS raw unit (both
        // sides are 18-decimal), so sqrt(1/180) * 2**96 is ~5.9053e27 and the implied tick is
        // log_1.0001(1/180) = -51,932.2, floored to -51,933. Neither number comes from the registry.
        assertApproxEqRel(uint256(expected), 5.9053e27, 0.0001e18, "sqrt(1/180) * 2**96");
        assertApproxEqAbs(int256(PriceLib.sqrtPriceX96ToTick(expected)), int256(-51_933), 1, "tick of 1/180");

        // And the round trip recovers the $1.00 reference the pool was anchored at.
        assertApproxEqRel(PriceLib.sqrtPriceX96ToAmpsPriceUsd18(expected, 180e8, 18), 1e18, 1e12, "round trip");
    }

    /// @notice A second registration of the same token is refused, retired or not.
    function test_addConstituent_revertsOnDuplicateToken() public {
        (uint16 id,) = _add(0);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.ConstituentExists.selector, address(stocks[0]), id));
        registry.addConstituent(_addParams(0));

        vm.prank(TIMELOCK);
        registry.retireConstituent(id);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.ConstituentExists.selector, address(stocks[0]), id));
        registry.addConstituent(_addParams(0));
    }

    /// @notice `ENTRY` is not a class a constituent can carry.
    function test_addConstituent_revertsOnEntryClass() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.poolClass = PoolClass.ENTRY;
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("poolClassNotSpoke")));
        registry.addConstituent(params);

        params.poolClass = PoolClass.NONE;
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("poolClassNotSpoke")));
        registry.addConstituent(params);
    }

    /// @notice A spoke's buy fee lives in `[1, 50]` bp.
    function test_addConstituent_buyFeeBand() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);

        params.buyFeeBps = Constants.BUY_FEE_BPS_SPOKE_MIN - 1;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("buyFeeBps"),
                uint256(params.buyFeeBps),
                uint256(Constants.BUY_FEE_BPS_SPOKE_MIN),
                uint256(Constants.BUY_FEE_BPS_SPOKE_MAX)
            )
        );
        registry.addConstituent(params);

        params.buyFeeBps = Constants.BUY_FEE_BPS_SPOKE_MAX + 1;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("buyFeeBps"),
                uint256(params.buyFeeBps),
                uint256(Constants.BUY_FEE_BPS_SPOKE_MIN),
                uint256(Constants.BUY_FEE_BPS_SPOKE_MAX)
            )
        );
        registry.addConstituent(params);

        params.buyFeeBps = Constants.BUY_FEE_BPS_SPOKE_MAX;
        _addWith(params);
    }

    /// @notice The rollout weight is a share of the daily budget and cannot exceed 100%.
    function test_addConstituent_rolloutWeightBand() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.rolloutWeightBps = uint16(Constants.BPS) + 1;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("rolloutWeightBps"),
                uint256(params.rolloutWeightBps),
                uint256(0),
                Constants.BPS
            )
        );
        registry.addConstituent(params);
    }

    /// @notice A per-constituent haircut override is capped at `H_SESSION_BPS_MAX`.
    function test_addConstituent_haircutOverrideBand() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.hSessionOverrideSet = true;
        params.hSessionOverrideBps = Constants.H_SESSION_BPS_MAX + 1;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("hSessionOverrideBps"),
                uint256(params.hSessionOverrideBps),
                uint256(0),
                uint256(Constants.H_SESSION_BPS_MAX)
            )
        );
        registry.addConstituent(params);
    }

    /// @notice The inclusion rule needs at least 30 days of history, whatever the beta.
    function test_addConstituent_historyBand() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.inclusion.historyDays = Constants.MIN_HISTORY_DAYS - 1;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("historyDays"),
                uint256(params.inclusion.historyDays),
                uint256(Constants.MIN_HISTORY_DAYS),
                uint256(type(uint32).max)
            )
        );
        registry.addConstituent(params);

        params.inclusion.historyDays = Constants.MIN_HISTORY_DAYS;
        _addWith(params);
    }

    /// @notice A zero index volatility makes the rule undefined and is refused.
    function test_addConstituent_revertsOnZeroIndexVol() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.inclusion.indexVolX18 = 0;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("indexVolX18"), uint256(0), uint256(1), uint256(type(uint64).max)
            )
        );
        registry.addConstituent(params);
    }

    /// @notice A name that fails `beta > 0.5 + sigma_u^2 / (2 sigma_I^2)` may be registered with zero rollout
    ///         weight — it gets a pool, a seed ladder and a bond market — and only then.
    function test_addConstituent_betaRuleGatesRolloutWeightOnly() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.inclusion.betaX18 = 0.4e18; // threshold is 0.51125 at these sigmas

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(PoolRegistry.BetaBelowThreshold.selector, int256(0.4e18), uint256(0.51125e18))
        );
        registry.addConstituent(params);

        params.rolloutWeightBps = 0;
        (uint16 id, PoolId poolId) = _addWith(params);
        assertEq(registry.constituent(id).rolloutWeightBps, 0, "no rollout for a failing name");
        assertTrue(registry.isRegistered(poolId), "but it still gets a pool");
        assertEq(registry.constituent(id).marketId, 1, "and a bond market");
        assertEq(registry.inclusionRecord(id).betaX18, 0.4e18, "the failing beta is recorded, not hidden");
    }

    /// @notice A beta exactly at the threshold is not above it.
    function test_addConstituent_betaAtThresholdIsRejected() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.inclusion.betaX18 = 0.51125e18;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(PoolRegistry.BetaBelowThreshold.selector, int256(0.51125e18), uint256(0.51125e18))
        );
        registry.addConstituent(params);

        params.inclusion.betaX18 = 0.51125e18 + 1;
        _addWith(params);
    }

    /// @notice A negative beta is rejected without any conversion sleight of hand.
    function test_addConstituent_negativeBetaIsRejected() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.inclusion.betaX18 = -0.9e18;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(PoolRegistry.BetaBelowThreshold.selector, int256(-0.9e18), uint256(0.51125e18))
        );
        registry.addConstituent(params);
    }

    /// @notice The feed must be a live, 8-decimal, positive-answer Chainlink Standard proxy.
    function test_addConstituent_feedRequirements() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);

        params.feed = address(0);
        vm.prank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        registry.addConstituent(params);

        MockAggregator wrongDecimals = new MockAggregator("AAPL / USD", 18, 200e18);
        params.feed = address(wrongDecimals);
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(PoolRegistry.InvalidFeed.selector, address(wrongDecimals), bytes32("decimals"))
        );
        registry.addConstituent(params);

        MockAggregator dead = new MockAggregator("AAPL / USD", 8, 0);
        params.feed = address(dead);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(PoolRegistry.InvalidFeed.selector, address(dead), bytes32("answer")));
        registry.addConstituent(params);

        MockAggregator svr = new MockAggregator("AAPL / USD SVR", 8, 200e8);
        params.feed = address(svr);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(PoolRegistry.NotStandardProxy.selector, address(svr)));
        registry.addConstituent(params);

        // The Standard proxy for the same pair is accepted.
        params.feed = address(feeds[0]);
        _addWith(params);
    }

    /// @notice A token that is not an 18-or-fewer-decimal ERC-20 cannot be a counter asset.
    function test_addConstituent_revertsOnUnsupportedDecimals() public {
        MockERC20 wide = new MockERC20("Wide", "WIDE", 24);
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.token = address(wide);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("counterDecimals")));
        registry.addConstituent(params);
    }

    /// @notice A tick spacing outside the v4 range cannot be initialised, so it is refused here.
    function test_addConstituent_tickSpacingMustBeUsable() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.tickSpacing = 0;
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("tickSpacing")));
        registry.addConstituent(params);
    }

    /// @notice The set is hard-capped at 64 names, retired ones included: ids are never reused, so the cap binds
    ///         on ids issued rather than on the live count.
    function test_addConstituent_maxConstituents() public {
        MockStockToken[] memory extra = new MockStockToken[](Constants.MAX_CONSTITUENTS);
        for (uint256 i; i < Constants.MAX_CONSTITUENTS; ++i) {
            extra[i] = new MockStockToken("Filler", "FILL");
            IPoolRegistry.AddConstituentParams memory params = _addParams(0);
            params.token = address(extra[i]);
            _addWith(params);
        }
        assertEq(registry.constituentCount(), Constants.MAX_CONSTITUENTS, "64 registered");
        assertEq(registry.activeConstituentCount(), Constants.MAX_CONSTITUENTS, "64 active");

        MockStockToken overflow = new MockStockToken("One too many", "OVER");
        IPoolRegistry.AddConstituentParams memory last = _addParams(0);
        last.token = address(overflow);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.ConstituentSetFull.selector, Constants.MAX_CONSTITUENTS));
        registry.addConstituent(last);

        // Retiring one does not free its id, so the set stays full.
        vm.prank(TIMELOCK);
        registry.retireConstituent(1);
        assertEq(registry.activeConstituentCount(), Constants.MAX_CONSTITUENTS - 1, "63 active");
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.ConstituentSetFull.selector, Constants.MAX_CONSTITUENTS));
        registry.addConstituent(last);
    }

    /// @notice A vault that refuses to initialise the pool aborts the whole registration.
    function test_addConstituent_vaultRevertPropagates() public {
        vault.setInitializeReverts(true);
        vm.prank(TIMELOCK);
        vm.expectRevert(MockVaultForRegistry.VaultRefused.selector);
        registry.addConstituent(_addParams(0));
        assertEq(registry.constituentCount(), 0, "nothing was written");
    }

    /// @notice The registry checks that the vault opened the pool it recorded, not a different one.
    function test_addConstituent_poolIdMismatchIsCaught() public {
        vault.setForcedPoolId(PoolId.wrap(bytes32(uint256(1))));
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("poolIdMismatch")));
        registry.addConstituent(_addParams(0));
    }

    /// @notice A bonds shell that refuses the collateral aborts the registration with it.
    function test_addConstituent_bondsRevertPropagates() public {
        bonds.setAddReverts(true);
        vm.prank(TIMELOCK);
        vm.expectRevert(MockBondsForRegistry.BondsRefused.selector);
        registry.addConstituent(_addParams(0));
    }

    // -------------------------------------------------------------------------------------------------------------
    // Lifecycle: retire, reinstate, reconfigure
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The full drill: add, retire, reinstate, reconfigure — with the events, the statuses, the bond
    ///         market and the rollout weight asserted at every step.
    function test_lifecycleDrill() public {
        _registerEntryPools();
        (uint16 id, PoolId poolId) = _add(0);
        assertEq(uint8(registry.constituent(id).status), uint8(ConstituentStatus.ACTIVE), "added active");
        assertEq(registry.activeConstituentCount(), 1, "n = 1");
        assertTrue(bonds.marketOpen(1), "market opened with the spoke");

        // --- retire ---------------------------------------------------------------------------------------
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentRetired(id, address(stocks[0]));
        vm.prank(TIMELOCK);
        registry.retireConstituent(id);

        ConstituentConfig memory retired = registry.constituent(id);
        assertEq(uint8(retired.status), uint8(ConstituentStatus.RETIRED), "retired");
        assertEq(retired.rolloutWeightBps, 0, "rollout weight zeroed (I37)");
        assertEq(retired.retiredAt, uint32(block.timestamp), "retiredAt stamped");
        assertEq(retired.targetWeightBps, 500, "the index weight survives retirement");
        assertEq(registry.activeConstituentCount(), 0, "n = 0");
        assertEq(registry.constituentCount(), 1, "the id is not freed");
        assertFalse(bonds.marketOpen(1), "bond market closed to new bonds");
        assertEq(bonds.lastOpenCall().marketId, 1, "the market the registry closed");
        // The pool stays addressable as an exit market: a v4 pool cannot be deleted.
        assertTrue(registry.isRegistered(poolId), "pool still registered");
        assertEq(registry.poolCount(), 3, "pool count unchanged by retirement");

        // --- reinstate ------------------------------------------------------------------------------------
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentReinstated(id, 250);
        vm.prank(TIMELOCK);
        registry.reinstateConstituent(id, 250);

        ConstituentConfig memory back = registry.constituent(id);
        assertEq(uint8(back.status), uint8(ConstituentStatus.ACTIVE), "active again");
        assertEq(back.rolloutWeightBps, 250, "rollout weight restored");
        assertEq(registry.activeConstituentCount(), 1, "n = 1");
        assertTrue(bonds.marketOpen(1), "bond market reopened");

        // --- reconfigure ----------------------------------------------------------------------------------
        IPoolRegistry.ReconfigureParams memory params = IPoolRegistry.ReconfigureParams({
            setPoolClass: true,
            poolClass: PoolClass.SPOKE_HIGH_VOL,
            setBuyFeeBps: true,
            buyFeeBps: 10,
            setTargetWeightBps: true,
            targetWeightBps: 2000,
            setRolloutWeightBps: true,
            rolloutWeightBps: 400,
            setFeed: true,
            feed: address(feeds[1]),
            setHSessionOverride: true,
            hSessionOverrideBps: 175,
            hSessionOverrideSet: true,
            setCaFreezeOverride: true,
            caFreezeOverride: true
        });

        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentReconfigured(
            id, "poolClass", uint256(uint8(PoolClass.SPOKE)), uint256(uint8(PoolClass.SPOKE_HIGH_VOL))
        );
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentReconfigured(id, "buyFeeBps", Constants.BUY_FEE_BPS_SPOKE_DEFAULT, 10);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentReconfigured(id, "targetWeightBps", 500, 2000);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentReconfigured(id, "rolloutWeightBps", 250, 400);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentReconfigured(
            id, "feed", uint256(uint160(address(feeds[0]))), uint256(uint160(address(feeds[1])))
        );
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentReconfigured(id, "hSessionOverrideBps", 0, 175);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentReconfigured(id, "hSessionOverrideSet", 0, 1);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentReconfigured(id, "caFreezeOverride", 0, 1);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.ConstituentFrozen(id, 0);

        vm.prank(TIMELOCK);
        registry.reconfigureConstituent(id, params);

        ConstituentConfig memory changed = registry.constituent(id);
        assertEq(uint8(changed.status), uint8(ConstituentStatus.FROZEN), "a forced CA freeze reads as FROZEN");
        assertEq(changed.targetWeightBps, 2000, "weight");
        assertEq(changed.rolloutWeightBps, 400, "rollout weight");
        assertEq(changed.feed, address(feeds[1]), "feed");
        assertEq(changed.hSessionOverrideBps, 175, "haircut override");
        assertTrue(changed.hSessionOverrideSet, "override set");
        assertTrue(changed.caFreezeOverride, "forced freeze");

        PoolConfig memory pool = registry.poolConfig(poolId);
        assertEq(uint8(pool.poolClass), uint8(PoolClass.SPOKE_HIGH_VOL), "fee bucket moved");
        assertEq(pool.buyFeeBps, 10, "buy fee moved with it");

        // A freeze is disable-only and temporary: it must not move the index count the cap and floor use.
        assertEq(registry.activeConstituentCount(), 1, "a frozen name still counts toward n");

        // Clearing the override restores the plain ACTIVE reading.
        IPoolRegistry.ReconfigureParams memory thaw;
        thaw.setCaFreezeOverride = true;
        vm.prank(TIMELOCK);
        registry.reconfigureConstituent(id, thaw);
        assertEq(uint8(registry.constituent(id).status), uint8(ConstituentStatus.ACTIVE), "thawed");
    }

    /// @notice Only an ACTIVE constituent can be retired, and only a RETIRED one reinstated.
    function test_lifecycle_invalidTransitions() public {
        (uint16 id,) = _add(0);

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(IPoolRegistry.InvalidStatusTransition.selector, id, ConstituentStatus.ACTIVE)
        );
        registry.reinstateConstituent(id, 100);

        vm.prank(TIMELOCK);
        registry.retireConstituent(id);

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(IPoolRegistry.InvalidStatusTransition.selector, id, ConstituentStatus.RETIRED)
        );
        registry.retireConstituent(id);

        vm.prank(TIMELOCK);
        registry.reinstateConstituent(id, 100);
        assertEq(uint8(registry.constituent(id).status), uint8(ConstituentStatus.ACTIVE), "back");
    }

    /// @notice Every lifecycle entry point refuses an id that was never issued.
    function test_lifecycle_unknownConstituent() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(UnknownConstituent.selector, uint16(0)));
        registry.retireConstituent(0);
        vm.expectRevert(abi.encodeWithSelector(UnknownConstituent.selector, uint16(7)));
        registry.retireConstituent(7);
        vm.expectRevert(abi.encodeWithSelector(UnknownConstituent.selector, uint16(7)));
        registry.reinstateConstituent(7, 0);
        vm.expectRevert(abi.encodeWithSelector(UnknownConstituent.selector, uint16(7)));
        registry.withdrawRetiredBids(7);
        IPoolRegistry.ReconfigureParams memory empty;
        vm.expectRevert(abi.encodeWithSelector(UnknownConstituent.selector, uint16(7)));
        registry.reconfigureConstituent(7, empty);
        vm.stopPrank();
    }

    /// @notice Retiring a constituent with no bond market leaves `AmpsBonds` alone.
    function test_retire_withoutBondMarketDoesNotCallBonds() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.openBondMarket = false;
        (uint16 id,) = _addWith(params);

        vm.prank(TIMELOCK);
        registry.retireConstituent(id);
        assertEq(bonds.openCallCount(), 0, "no market to close");
    }

    /// @notice Reinstatement re-checks the stored index weight against the count it produces: a name whose weight
    ///         became illegal while it was out has to be re-weighted first.
    function test_reinstate_revertsWhenStoredWeightNoLongerFits() public {
        IPoolRegistry.AddConstituentParams memory first = _addParams(0);
        first.targetWeightBps = 9000; // legal at n = 1, cap 10000
        (uint16 id,) = _addWith(first);

        vm.prank(TIMELOCK);
        registry.retireConstituent(id);

        // Four other names bring the cap down to 3000.
        for (uint256 i = 1; i < 5; ++i) {
            _add(i);
        }

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(IPoolRegistry.WeightOutOfRange.selector, uint16(9000), uint16(500), uint16(3000))
        );
        registry.reinstateConstituent(id, 100);

        IPoolRegistry.ReconfigureParams memory fix;
        fix.setTargetWeightBps = true;
        fix.targetWeightBps = 2000;
        vm.prank(TIMELOCK);
        registry.reconfigureConstituent(id, fix);

        vm.prank(TIMELOCK);
        registry.reinstateConstituent(id, 100);
        assertEq(registry.activeConstituentCount(), 5, "n = 5");
    }

    /// @notice A retired constituent may not be given a rollout weight by the back door (I37).
    function test_reconfigure_retiredNameCannotCarryRolloutWeight() public {
        (uint16 id,) = _add(0);
        vm.prank(TIMELOCK);
        registry.retireConstituent(id);

        IPoolRegistry.ReconfigureParams memory params;
        params.setRolloutWeightBps = true;
        params.rolloutWeightBps = 100;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("rolloutWeightBps"), uint256(100), uint256(0), uint256(0)
            )
        );
        registry.reconfigureConstituent(id, params);

        params.rolloutWeightBps = 0;
        vm.prank(TIMELOCK);
        registry.reconfigureConstituent(id, params);
        assertEq(registry.constituent(id).rolloutWeightBps, 0, "still zero");
    }

    /// @notice An empty proposal changes nothing and emits nothing.
    function test_reconfigure_emptyProposalIsANoOp() public {
        (uint16 id,) = _add(0);
        ConstituentConfig memory before = registry.constituent(id);

        vm.recordLogs();
        IPoolRegistry.ReconfigureParams memory empty;
        vm.prank(TIMELOCK);
        registry.reconfigureConstituent(id, empty);
        assertEq(vm.getRecordedLogs().length, 0, "no events");

        ConstituentConfig memory unchangedConfig = registry.constituent(id);
        assertEq(unchangedConfig.targetWeightBps, before.targetWeightBps, "weight");
        assertEq(unchangedConfig.rolloutWeightBps, before.rolloutWeightBps, "rollout weight");
        assertEq(unchangedConfig.feed, before.feed, "feed");
    }

    /// @notice A new fee bucket and a new buy fee in one proposal are checked against the *new* bucket's band.
    function test_reconfigure_buyFeeIsCheckedAgainstTheNewClass() public {
        (uint16 id,) = _add(0);
        IPoolRegistry.ReconfigureParams memory params;
        params.setPoolClass = true;
        params.poolClass = PoolClass.SPOKE_HIGH_VOL;
        params.setBuyFeeBps = true;
        params.buyFeeBps = Constants.BUY_FEE_BPS_SPOKE_MAX + 1;

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("buyFeeBps"),
                uint256(Constants.BUY_FEE_BPS_SPOKE_MAX + 1),
                uint256(Constants.BUY_FEE_BPS_SPOKE_MIN),
                uint256(Constants.BUY_FEE_BPS_SPOKE_MAX)
            )
        );
        registry.reconfigureConstituent(id, params);
    }

    /// @notice The fee bucket may not be moved to ENTRY or NONE.
    function test_reconfigure_classMustStaySpoke() public {
        (uint16 id,) = _add(0);
        IPoolRegistry.ReconfigureParams memory params;
        params.setPoolClass = true;
        params.poolClass = PoolClass.ENTRY;
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("poolClassNotSpoke")));
        registry.reconfigureConstituent(id, params);
    }

    /// @notice A replacement feed goes through the same Standard-proxy and liveness checks as the original.
    function test_reconfigure_feedMustBeAStandardProxy() public {
        (uint16 id,) = _add(0);
        MockAggregator svr = new MockAggregator("AAPL / USD SVR", 8, 200e8);

        IPoolRegistry.ReconfigureParams memory params;
        params.setFeed = true;
        params.feed = address(svr);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(PoolRegistry.NotStandardProxy.selector, address(svr)));
        registry.reconfigureConstituent(id, params);

        params.feed = address(feeds[2]);
        vm.prank(TIMELOCK);
        registry.reconfigureConstituent(id, params);
        assertEq(registry.constituent(id).feed, address(feeds[2]), "feed replaced");
    }

    /// @notice Ids are never reused: a token registered, retired and replaced by a fresh listing gets a new id,
    ///         and the old pool stays addressable.
    function test_ids_areNeverReused() public {
        (uint16 first, PoolId firstPool) = _add(0);
        vm.prank(TIMELOCK);
        registry.retireConstituent(first);

        (uint16 second, PoolId secondPool) = _add(1);
        assertEq(second, first + 1, "the next id, not the retired one");
        assertEq(registry.constituentIdOf(address(stocks[0])), first, "the retired token keeps its id");
        assertTrue(registry.isRegistered(firstPool), "the retired pool is still ours");
        assertTrue(PoolId.unwrap(firstPool) != PoolId.unwrap(secondPool), "distinct pools");
        assertEq(registry.constituentCount(), 2, "two ids issued");
        assertEq(registry.activeConstituentCount(), 1, "one active");
    }

    /// @notice `withdrawRetiredBids` is a retired-only hand-off to the vault.
    function test_withdrawRetiredBids() public {
        (uint16 id,) = _add(0);

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(IPoolRegistry.InvalidStatusTransition.selector, id, ConstituentStatus.ACTIVE)
        );
        registry.withdrawRetiredBids(id);

        vm.prank(TIMELOCK);
        registry.retireConstituent(id);

        vault.setRetiredBidsMoved(1234e18);
        vm.expectEmit(true, true, true, true, address(registry));
        emit PoolRegistry.RetiredBidsWithdrawn(id, 1234e18);
        vm.prank(TIMELOCK);
        registry.withdrawRetiredBids(id);

        assertEq(vault.retiredBidWithdrawalCount(), 1, "one hand-off");
        assertEq(vault.retiredBidWithdrawals(0), id, "for the retired constituent");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The index weight rule
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `cap_n = max(3000, ceilDiv(10000, n))` and `floor_n = min(500, 10000 / (2n))`, at the four counts
    ///         the plan calls out.
    function test_weightRule_atTheDocumentedCounts() public view {
        (uint16 floor1, uint16 cap1) = lens.weightBoundsFor(1);
        assertEq(cap1, 10_000, "n = 1 cap");
        assertEq(floor1, 500, "n = 1 floor");

        (uint16 floor5, uint16 cap5) = lens.weightBoundsFor(5);
        assertEq(cap5, 3000, "n = 5 cap");
        assertEq(floor5, 500, "n = 5 floor");

        (uint16 floor30, uint16 cap30) = lens.weightBoundsFor(30);
        assertEq(cap30, 3000, "n = 30 cap");
        assertEq(floor30, 166, "n = 30 floor");

        (uint16 floor64, uint16 cap64) = lens.weightBoundsFor(64);
        assertEq(cap64, 3000, "n = 64 cap");
        assertEq(floor64, 78, "n = 64 floor");

        // The cap is a ceiling division, so three names can each hold 3334 and cover the whole index.
        (, uint16 cap3) = lens.weightBoundsFor(3);
        assertEq(cap3, 3334, "n = 3 cap is a ceiling");
    }

    /// @notice The live `indexCapBps`/`indexFloorBps` follow the active count as names are added and retired.
    function test_weightRule_followsTheLiveActiveCount() public {
        assertEq(registry.indexCapBps(), uint16(Constants.BPS), "no index yet: the cap is open");
        assertEq(registry.indexFloorBps(), 0, "no index yet: no floor");

        _add(0);
        assertEq(registry.indexCapBps(), 10_000, "n = 1");
        assertEq(registry.indexFloorBps(), 500, "n = 1");

        for (uint256 i = 1; i < 30; ++i) {
            _add(i);
        }
        assertEq(registry.activeConstituentCount(), 30, "n = 30");
        assertEq(registry.indexCapBps(), 3000, "n = 30 cap");
        assertEq(registry.indexFloorBps(), 166, "n = 30 floor");

        vm.prank(TIMELOCK);
        registry.retireConstituent(30);
        assertEq(registry.indexFloorBps(), 172, "n = 29 floor");
    }

    /// @notice A registration is measured against the count it produces, not the one it starts from: the first
    ///         name must clear the `n = 1` floor of 500 bp.
    function test_addConstituent_weightIsCheckedAgainstTheResultingCount() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.targetWeightBps = 499;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(IPoolRegistry.WeightOutOfRange.selector, uint16(499), uint16(500), uint16(10_000))
        );
        registry.addConstituent(params);

        params.targetWeightBps = 500;
        _addWith(params);

        // With one name live, the second registration is measured at n = 2: cap 5000.
        IPoolRegistry.AddConstituentParams memory second = _addParams(1);
        second.targetWeightBps = 5001;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(IPoolRegistry.WeightOutOfRange.selector, uint16(5001), uint16(500), uint16(5000))
        );
        registry.addConstituent(second);

        second.targetWeightBps = 5000;
        _addWith(second);
    }

    /// @notice The quarterly rule replaces the vector wholesale; the result must be in band and sum to 100%.
    function test_setIndexWeights() public {
        for (uint256 i; i < 5; ++i) {
            _add(i);
        }

        uint16[] memory ids = _ids(5);
        uint16[] memory weightsBps = _evenWeights(5);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IPoolRegistry.IndexWeightsSet(ids, weightsBps);
        vm.prank(TIMELOCK);
        registry.setIndexWeights(ids, weightsBps);

        (, uint16[] memory stored, uint256 totalBps) = lens.indexWeights();
        assertEq(totalBps, Constants.BPS, "sums to 100%");
        assertEq(stored[0], 2000, "even five-way split");
    }

    /// @notice Parallel arrays, known and active ids, in-band weights, and a vector that sums to `BPS`.
    function test_setIndexWeights_rejections() public {
        for (uint256 i; i < 5; ++i) {
            _add(i);
        }
        uint16[] memory ids = _ids(5);
        uint16[] memory weightsBps = _evenWeights(5);

        vm.startPrank(TIMELOCK);

        uint16[] memory shortWeights = new uint16[](4);
        vm.expectRevert(LengthMismatch.selector);
        registry.setIndexWeights(ids, shortWeights);

        uint16[] memory unknownIds = _ids(5);
        unknownIds[4] = 9;
        vm.expectRevert(abi.encodeWithSelector(UnknownConstituent.selector, uint16(9)));
        registry.setIndexWeights(unknownIds, weightsBps);

        uint16[] memory tooSmall = _evenWeights(5);
        tooSmall[0] = 499;
        vm.expectRevert(
            abi.encodeWithSelector(IPoolRegistry.WeightOutOfRange.selector, uint16(499), uint16(500), uint16(3000))
        );
        registry.setIndexWeights(ids, tooSmall);

        uint16[] memory tooLarge = _evenWeights(5);
        tooLarge[0] = 3001;
        vm.expectRevert(
            abi.encodeWithSelector(IPoolRegistry.WeightOutOfRange.selector, uint16(3001), uint16(500), uint16(3000))
        );
        registry.setIndexWeights(ids, tooLarge);

        // In band everywhere, but the vector no longer sums to 100%.
        uint16[] memory unbalanced = _evenWeights(5);
        unbalanced[0] = 1000;
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("indexWeightSum"), uint256(9000), Constants.BPS, Constants.BPS
            )
        );
        registry.setIndexWeights(ids, unbalanced);

        vm.stopPrank();

        // A retired name is not part of the index and cannot be re-weighted.
        vm.prank(TIMELOCK);
        registry.retireConstituent(5);
        uint16[] memory fourIds = _ids(4);
        uint16[] memory fourWeights = _evenWeights(4);
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(IPoolRegistry.InvalidStatusTransition.selector, uint16(5), ConstituentStatus.RETIRED)
        );
        registry.setIndexWeights(ids, weightsBps);

        // With the retired name excluded the four remaining weights have to cover the whole index.
        vm.prank(TIMELOCK);
        registry.setIndexWeights(fourIds, fourWeights);
        (,, uint256 totalBps) = lens.indexWeights();
        assertEq(totalBps, Constants.BPS, "the live vector still sums to 100%");
    }

    /// @notice Weights of retired names are excluded from the index sum, so a retirement does not have to be
    ///         followed by an immediate re-weight for the invariant to hold on the live set.
    function test_setIndexWeights_ignoresRetiredNames() public {
        for (uint256 i; i < 4; ++i) {
            _add(i);
        }
        vm.prank(TIMELOCK);
        registry.setIndexWeights(_ids(4), _evenWeights(4));

        vm.prank(TIMELOCK);
        registry.retireConstituent(4);

        (uint16[] memory ids,, uint256 totalBps) = lens.indexWeights();
        assertEq(ids.length, 3, "three live names");
        assertEq(totalBps, 7500, "the retired name's 2500 bp left with it");

        uint16[] memory threeWeights = new uint16[](3);
        threeWeights[0] = 3334;
        threeWeights[1] = 3333;
        threeWeights[2] = 3333;
        vm.prank(TIMELOCK);
        registry.setIndexWeights(_ids(3), threeWeights);
        (,, uint256 rebalanced) = lens.indexWeights();
        assertEq(rebalanced, Constants.BPS, "re-normalised");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Access control
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every mutator on this contract is timelock-only; the guardian reaches none of them.
    function test_onlyTimelock_everyMutator() public {
        (uint16 id,) = _add(0);
        vm.prank(TIMELOCK);
        registry.retireConstituent(id);

        address[2] memory callers = [STRANGER, GUARDIAN];
        for (uint256 i; i < callers.length; ++i) {
            address caller = callers[i];

            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, caller));
            registry.registerEntryPool(_entryKey(address(usdg)), 6, 30, address(usdgFeed));

            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, caller));
            registry.addConstituent(_addParams(1));

            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, caller));
            registry.retireConstituent(id);

            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, caller));
            registry.reinstateConstituent(id, 100);

            IPoolRegistry.ReconfigureParams memory params;
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, caller));
            registry.reconfigureConstituent(id, params);

            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, caller));
            registry.setIndexWeights(_ids(1), _evenWeights(1));

            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, caller));
            registry.withdrawRetiredBids(id);
        }

        // Nothing above changed a thing.
        assertEq(registry.constituentCount(), 1, "still one id");
        assertEq(uint8(registry.constituent(id).status), uint8(ConstituentStatus.RETIRED), "still retired");
        assertEq(registry.poolCount(), 1, "still one pool");
    }

    /// @notice The vault itself is not privileged here: the registry drives the vault, never the other way round.
    function test_onlyTimelock_vaultIsNotPrivileged() public {
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, address(vault)));
        registry.addConstituent(_addParams(0));
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Unknown ids and pools read as empty rather than reverting, except `poolKey`, which has no empty
    ///         value a caller could mistake for a real pool.
    function test_reads_unknownEntities() public {
        PoolId unknown = PoolId.wrap(bytes32(uint256(0xdead)));
        assertFalse(registry.isRegistered(unknown), "not registered");
        assertEq(registry.poolConfig(unknown).counter, address(0), "empty pool config");
        assertEq(uint8(registry.poolConfig(unknown).poolClass), uint8(PoolClass.NONE), "class NONE");
        assertEq(registry.constituentOfPool(unknown), 0, "no constituent");
        assertEq(uint8(registry.constituent(42).status), uint8(ConstituentStatus.NONE), "status NONE");
        assertEq(registry.constituentIdOf(address(stocks[0])), 0, "no id");
        assertEq(PoolId.unwrap(registry.poolIdOf(42)), bytes32(0), "no pool");
        assertEq(registry.inclusionRecord(42).recordedAt, 0, "no evidence");

        vm.expectRevert(abi.encodeWithSelector(UnknownPool.selector, PoolId.unwrap(unknown)));
        registry.poolKey(unknown);
    }

    /// @notice The active list is derived, in ascending id order, and follows retirement and reinstatement.
    function test_reads_activeConstituents() public {
        for (uint256 i; i < 4; ++i) {
            _add(i);
        }
        uint16[] memory active = lens.activeConstituents();
        assertEq(active.length, 4, "four active");
        for (uint16 i; i < 4; ++i) {
            assertEq(active[i], i + 1, "ascending ids");
        }

        vm.prank(TIMELOCK);
        registry.retireConstituent(2);
        active = lens.activeConstituents();
        assertEq(active.length, 3, "three active");
        assertEq(active[0], 1, "1");
        assertEq(active[1], 3, "3");
        assertEq(active[2], 4, "4");

        vm.prank(TIMELOCK);
        registry.reinstateConstituent(2, 0);
        assertEq(lens.activeConstituents().length, 4, "four again");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Structural guards
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A constituent needs a token.
    function test_addConstituent_revertsOnZeroToken() public {
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.token = address(0);
        vm.prank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        registry.addConstituent(params);
    }

    /// @notice A counter asset that sorts *below* AMPS is refused: AMPS is `currency0` in every pool by
    ///         construction, and a pool where it is not would invert the sign of every fee direction.
    function test_addConstituent_revertsWhenCounterSortsBelowAmps() public {
        // A token planted below the mined AMPS address. `MockStockToken`'s `decimals()` is a constant in code, so
        // the etched runtime answers correctly without any storage.
        address low = address(0x11);
        vm.etch(low, address(new MockStockToken("Low", "LOW")).code);

        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.token = low;
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.InvalidPoolKey.selector, bytes32("currencyOrder")));
        registry.addConstituent(params);
    }

    /// @notice An entry-pool counter cannot be re-registered as a constituent behind the same pool id.
    function test_addConstituent_revertsWhenThePoolAlreadyExists() public {
        _registerEntryPools();

        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.token = address(weth);
        params.tickSpacing = ENTRY_TICK_SPACING;
        vm.prank(TIMELOCK);
        vm.expectRevert(AlreadyInitialized.selector);
        registry.addConstituent(params);
    }

    /// @notice Opening a bond market needs a wired `AmpsBonds`.
    function test_addConstituent_revertsWhenBondsIsUnset() public {
        vault.setBonds(address(0));
        vm.prank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        registry.addConstituent(_addParams(0));

        // Without a bond market the same proposal goes through.
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.openBondMarket = false;
        _addWith(params);
    }

    /// @notice The SVR probe is failure-tolerant: an aggregator that will not describe itself, or describes itself
    ///         in fewer than three characters, is accepted on the strength of the reviewed RDD pin instead.
    function test_addConstituent_svrProbeToleratesSilentFeeds() public {
        SilentDescriptionFeed silent = new SilentDescriptionFeed();
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.feed = address(silent);
        (uint16 first,) = _addWith(params);
        assertEq(registry.constituent(first).feed, address(silent), "accepted");

        MockAggregator terse = new MockAggregator("AB", 8, 100e8);
        IPoolRegistry.AddConstituentParams memory second = _addParams(1);
        second.feed = address(terse);
        (uint16 id,) = _addWith(second);
        assertEq(registry.constituent(id).feed, address(terse), "accepted");
    }

    /// @notice A feed whose `description()` returns something that is not a well-formed string is accepted rather
    ///         than reverting the proposal: the probe parses the answer by hand precisely so that a malformed one
    ///         cannot become a denial of service on registration.
    function test_addConstituent_svrProbeToleratesMalformedReturnData() public {
        // A string whose offset is not 0x20.
        RawDescriptionFeed wrongOffset = new RawDescriptionFeed(abi.encode(uint256(0x40), uint256(3), bytes32("ABC")));
        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.feed = address(wrongOffset);
        (uint16 first,) = _addWith(params);
        assertEq(registry.constituent(first).feed, address(wrongOffset), "accepted");

        // A string whose length runs past the end of the return data.
        RawDescriptionFeed longLength = new RawDescriptionFeed(abi.encode(uint256(0x20), uint256(1000), bytes32("SVR")));
        IPoolRegistry.AddConstituentParams memory second = _addParams(1);
        second.feed = address(longLength);
        (uint16 id,) = _addWith(second);
        assertEq(registry.constituent(id).feed, address(longLength), "accepted");
    }

    /* ------------------------------------- the canonical grid origin ------------------------------------- */
    //
    // `docs/phase3-state-model.md` §3.2 and §10 ruling 14. `PoolConfig.gridBaseTick` is the origin of the lattice
    // every vault position lies on, and the registry's copy is the one `LadderPositionValuer` enumerates. The hook
    // owns the value — it computes it in `afterInitialize` from the tick the PoolManager reports — and the registry
    // mirrors it. These three tests pin the mirror, its absence and its failure mode, because a wrong grid origin
    // would silently point the valuer at ranges the vault never placed on.

    /// @notice With a hook deployed, the registry mirrors whatever grid origin the hook reports, for both pool
    ///         classes.
    function test_gridBaseTick_isMirroredFromTheHook() public {
        vm.etch(HOOK, address(new GridBaseHook(6930)).code);

        _registerEntryPools();
        assertEq(registry.poolConfig(_entryKey(address(usdg)).toId()).gridBaseTick, 6930, "entry pool mirrors the hook");

        (, PoolId spokeId) = _add(19);
        assertEq(registry.poolConfig(spokeId).gridBaseTick, 6930, "spoke mirrors the hook");
    }

    /// @notice Without a hook there is no grid, and the registry says so by leaving the origin at zero rather than
    ///         inventing one.
    /// @dev The `extcodesize` guard in `_openPool` is load-bearing: a `staticcall` to an address with no code
    ///      *succeeds* with empty return data, and a decode failure after a successful call is not catchable by
    ///      `catch`. Without the guard this registration would revert.
    function test_gridBaseTick_isZeroWhileNoHookIsDeployed() public {
        assertEq(HOOK.code.length, 0, "the fixture's hook is an address, not a contract");

        vm.prank(TIMELOCK);
        registry.registerEntryPool(_entryKey(address(usdg)), 6, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, address(usdgFeed));
        assertEq(registry.poolConfig(_entryKey(address(usdg)).toId()).gridBaseTick, 0, "no hook, no grid");
    }

    /// @notice A hook that reverts on the mirror read cannot block a registration: the origin stays zero and the
    ///         7-day proposal still lands.
    function test_gridBaseTick_hookRevertDoesNotBlockRegistration() public {
        vm.etch(HOOK, address(new RevertingGridHook()).code);

        vm.prank(TIMELOCK);
        registry.registerEntryPool(_entryKey(address(usdg)), 6, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, address(usdgFeed));
        assertTrue(registry.isRegistered(_entryKey(address(usdg)).toId()), "registered anyway");
        assertEq(registry.poolConfig(_entryKey(address(usdg)).toId()).gridBaseTick, 0, "and the origin stays zero");
    }
}

/// @notice A stand-in hook that reports one grid origin for every pool.
contract GridBaseHook {
    int24 private immutable _tick;

    constructor(int24 tick) {
        _tick = tick;
    }

    function gridBaseTick(PoolId) external view returns (int24) {
        return _tick;
    }
}

/// @notice A stand-in hook whose grid-origin read reverts.
contract RevertingGridHook {
    error Nope();

    function gridBaseTick(PoolId) external pure returns (int24) {
        revert Nope();
    }
}

/// @notice An aggregator whose `description()` returns arbitrary bytes, well formed or not.
contract RawDescriptionFeed {
    bytes private _blob;

    constructor(bytes memory blob) {
        _blob = blob;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 100e8, block.timestamp, block.timestamp, 1);
    }

    /// @dev Returns `_blob` verbatim as the call's return data, which is what makes a malformed encoding testable.
    fallback(bytes calldata) external returns (bytes memory) {
        return _blob;
    }
}

/// @title PoolRegistryLensTest
/// @notice Coverage for the derived reads that live outside the registry, and for their agreement with the
///         registry's own live getters.
contract PoolRegistryLensTest is PoolRegistryFixture {
    /// @notice The lens points at the registry and refuses a zero one.
    function test_lens_wiring() public {
        assertEq(address(lens.registry()), address(registry), "registry");
        vm.expectRevert(ZeroAddress.selector);
        new PoolRegistryLens(address(0));
    }

    /// @notice The lens's cap/floor rule agrees with the registry's live getters at every count the set passes
    ///         through, which is what makes it safe for the rule to live in two contracts.
    function test_lens_boundsAgreeWithTheRegistry() public {
        (uint16 emptyFloor, uint16 emptyCap) = lens.weightBoundsFor(0);
        assertEq(emptyFloor, registry.indexFloorBps(), "n = 0 floor");
        assertEq(emptyCap, registry.indexCapBps(), "n = 0 cap");

        for (uint256 i; i < 8; ++i) {
            _add(i);
            (uint16 floorBps, uint16 capBps) = lens.weightBoundsFor(registry.activeConstituentCount());
            assertEq(floorBps, registry.indexFloorBps(), "floor agrees");
            assertEq(capBps, registry.indexCapBps(), "cap agrees");
        }

        vm.prank(TIMELOCK);
        registry.retireConstituent(3);
        (uint16 afterFloor, uint16 afterCap) = lens.weightBoundsFor(registry.activeConstituentCount());
        assertEq(afterFloor, registry.indexFloorBps(), "floor follows retirement");
        assertEq(afterCap, registry.indexCapBps(), "cap follows retirement");
    }

    /// @notice A frozen constituent is still an index member: the freeze is disable-only and temporary, so it
    ///         stays in the active list and keeps its weight in the vector.
    function test_lens_frozenNamesStayInTheIndex() public {
        for (uint256 i; i < 3; ++i) {
            _add(i);
        }
        uint16[] memory weightsBps = new uint16[](3);
        weightsBps[0] = 3334;
        weightsBps[1] = 3333;
        weightsBps[2] = 3333;
        vm.prank(TIMELOCK);
        registry.setIndexWeights(_ids(3), weightsBps);

        IPoolRegistry.ReconfigureParams memory freeze;
        freeze.setCaFreezeOverride = true;
        freeze.caFreezeOverride = true;
        vm.prank(TIMELOCK);
        registry.reconfigureConstituent(2, freeze);
        assertEq(uint8(registry.constituent(2).status), uint8(ConstituentStatus.FROZEN), "frozen");

        assertEq(lens.activeConstituents().length, 3, "still three members");
        (uint16[] memory ids, uint16[] memory stored, uint256 totalBps) = lens.indexWeights();
        assertEq(ids[1], 2, "the frozen name keeps its place");
        assertEq(stored[1], 3333, "and its weight");
        assertEq(totalBps, Constants.BPS, "the vector still sums to 100%");
    }
}

/// @notice An aggregator that answers rounds but refuses to describe itself, as a proxy behind an unexpected
///         implementation might.
contract SilentDescriptionFeed {
    error NoDescription();

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        revert NoDescription();
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 100e8, block.timestamp, block.timestamp, 1);
    }
}
