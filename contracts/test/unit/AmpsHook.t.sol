// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsHook} from "../../src/hook/AmpsHook.sol";
import {HookStateLib} from "../../src/hook/HookStateLib.sol";
import {IAmpsHook} from "../../src/interfaces/IAmpsHook.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotInitialized, NotTimelock, NotVault, OutOfBand, ZeroAddress} from "../../src/types/Errors.sol";
import {GateState, HookPoolState, PoolClass, PoolConfig, Session} from "../../src/types/Types.sol";
import {HookStubFeePolicy} from "../mocks/HookStubFeePolicy.sol";
import {HookTestFixture} from "../mocks/HookTestFixture.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title AmpsHookTest
/// @notice The hook's shape: its permission bits, the `beforeInitialize` preconditions, the POL-only liquidity
///         guard, the three packed storage words, the grid origin the registry mirrors, and every governed setter.
///
/// @dev The fee arithmetic lives in `AmpsHookFee.t.sol`, the rotation credit in `RotationCredit.t.sol` and the
///      observation ring in `AmpsHookObservations.t.sol`; this file is the structure.
contract AmpsHookTest is HookTestFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _deployFixture();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Permissions (I13, I18)
    // -----------------------------------------------------------------------------------------------------------

    function test_permissionBitsEqualTheMinedAddressBits() public view {
        assertEq(uint160(address(hook)) & uint160(Hooks.ALL_HOOK_MASK), uint160(0x38C0), "flags must be 0x38C0");
        assertEq(uint256(hook.HOOK_FLAGS()), 0x38C0, "HOOK_FLAGS");
        assertEq(uint256(Constants.HOOK_FLAGS), 0x38C0, "the constant the miner uses");
        assertEq(
            uint160(address(hook)) & uint160(Constants.HOOK_ADDRESS_MASK),
            uint160(Constants.HOOK_FLAGS),
            "address & HOOK_ADDRESS_MASK"
        );
    }

    function test_noReturnsDeltaAndNoRemoveLiquidityBits() public view {
        assertEq(uint160(address(hook)) & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG, 0, "beforeSwap returns-delta");
        assertEq(uint160(address(hook)) & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG, 0, "afterSwap returns-delta");
        assertEq(uint160(address(hook)) & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG, 0, "addLiquidity returns-delta");
        assertEq(uint160(address(hook)) & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG, 0, "removeLiquidity delta");
        assertEq(uint160(address(hook)) & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG, 0, "no beforeRemoveLiquidity");
        assertEq(uint160(address(hook)) & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG, 0, "no afterRemoveLiquidity");
        assertEq(uint160(address(hook)) & Hooks.BEFORE_DONATE_FLAG, 0, "no beforeDonate");
        assertEq(uint160(address(hook)) & Hooks.AFTER_DONATE_FLAG, 0, "no afterDonate");
    }

    function test_getHookPermissionsMatchesTheAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.afterInitialize && p.beforeAddLiquidity, "the three write guards");
        assertTrue(p.beforeSwap && p.afterSwap, "the two swap callbacks");
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity, "removals are never hooked (I18)");
        assertFalse(p.afterAddLiquidity || p.beforeDonate || p.afterDonate, "nothing else");
        assertFalse(
            p.beforeSwapReturnDelta || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta,
            "no returns-delta bit anywhere (I13)"
        );
    }

    /// @notice I18: a removal is never routed through the hook, so it can never be blocked — in any gate state.
    function test_removalsAreNeverBlocked() public {
        gate.setDefaultState(GateState.DEGRADED);
        gate.setWatchdogTripped(true);

        int24 tick = _currentTick(usdgId);
        int24 lower = _align(tick - 20_000);
        int24 upper = _align(tick + 20_000);

        uint256 balanceBefore = amps.balanceOf(address(this));
        poolManager.unlock(abi.encode(usdgKey, lower, upper, -int256(1e12)));
        assertGt(amps.balanceOf(address(this)), balanceBefore, "liquidity came back out");
    }

    // -----------------------------------------------------------------------------------------------------------
    // beforeInitialize
    // -----------------------------------------------------------------------------------------------------------

    function test_beforeInitializeRejectsANonVaultSender() public {
        PoolKey memory key = _poolKey(USDG_ADDRESS);
        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, STRANGER));
        hook.beforeInitialize(STRANGER, key, _sqrtPriceX96(1e6, 1e18));
    }

    function test_beforeInitializeRejectsNativeCurrencyZero() public {
        PoolKey memory key = _poolKey(USDG_ADDRESS);
        key.currency0 = Currency.wrap(address(0));
        key.currency1 = Currency.wrap(AMPS_ADDRESS);

        vm.prank(address(poolManager));
        vm.expectRevert(IAmpsHook.Currency0NotAmps.selector);
        hook.beforeInitialize(address(this), key, _sqrtPriceX96(1e6, 1e18));
    }

    function test_beforeInitializeRejectsANonAmpsCurrencyZero() public {
        PoolKey memory key = _poolKey(USDG_ADDRESS);
        key.currency0 = Currency.wrap(USDG_ADDRESS);
        key.currency1 = Currency.wrap(WETH_ADDRESS);

        vm.prank(address(poolManager));
        vm.expectRevert(IAmpsHook.Currency0NotAmps.selector);
        hook.beforeInitialize(address(this), key, _sqrtPriceX96(1e6, 1e18));
    }

    function test_beforeInitializeRejectsAStaticFee() public {
        PoolKey memory key = _poolKey(USDG_ADDRESS);
        key.fee = 3000;

        vm.prank(address(poolManager));
        vm.expectRevert(IAmpsHook.FeeNotDynamic.selector);
        hook.beforeInitialize(address(this), key, _sqrtPriceX96(1e6, 1e18));
    }

    function test_beforeInitializeRejectsAnUnregisteredPool() public {
        MockERC20 outsider = deployToken("Outsider", "OUT", 18);
        PoolKey memory key = _poolKey(address(outsider));

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(IAmpsHook.PoolNotRegistered.selector, key.toId()));
        hook.beforeInitialize(address(this), key, _sqrtPriceX96(1, 1));
    }

    function test_beforeInitializeRejectsACounterMismatch() public {
        PoolKey memory key = _poolKey(USDG_ADDRESS);
        PoolConfig memory config = registry.poolConfig(key.toId());
        config.counter = WETH_ADDRESS;
        registry.setPool(key.toId(), config);

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(IAmpsHook.PoolKeyMismatch.selector, bytes32("counter")));
        hook.beforeInitialize(address(this), key, _sqrtPriceX96(1e6, 1e18));
    }

    function test_beforeInitializeRejectsATickSpacingMismatch() public {
        PoolKey memory key = _poolKey(USDG_ADDRESS);
        registry.setTickSpacing(key.toId(), 60);

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(IAmpsHook.PoolKeyMismatch.selector, bytes32("tickSpacing")));
        hook.beforeInitialize(address(this), key, _sqrtPriceX96(1e6, 1e18));
    }

    /// @notice The same refusal end to end, wrapped by the PoolManager as ERC-7751 says it must be.
    function test_initializeThroughThePoolManagerBubblesTheRefusal() public {
        MockERC20 outsider = deployToken("Outsider", "OUT", 18);
        PoolKey memory key = _poolKey(address(outsider));

        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(IAmpsHook.PoolNotRegistered.selector, key.toId())
            )
        );
        poolManager.initialize(key, _sqrtPriceX96(1, 1));
    }

    // -----------------------------------------------------------------------------------------------------------
    // beforeAddLiquidity (POL-only)
    // -----------------------------------------------------------------------------------------------------------

    function test_beforeAddLiquidityAcceptsTheVaultOnly() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: 1, salt: bytes32(0)});

        vm.prank(address(poolManager));
        bytes4 selector = hook.beforeAddLiquidity(address(this), usdgKey, params, "");
        assertEq(selector, IHooks.beforeAddLiquidity.selector, "the vault may add");

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, STRANGER));
        hook.beforeAddLiquidity(STRANGER, usdgKey, params, "");
    }

    // -----------------------------------------------------------------------------------------------------------
    // afterInitialize: the CONFIG word and the grid origin
    // -----------------------------------------------------------------------------------------------------------

    function test_afterInitializeWritesTheGridOriginTheRegistryMirrors() public view {
        (, int24 tick,,) = _slot0(usdgId);
        int24 expected = tick % TICK_SPACING == 0
            ? tick
            : (tick > 0 ? (tick / TICK_SPACING + 1) * TICK_SPACING : (tick / TICK_SPACING) * TICK_SPACING);

        assertEq(hook.gridBaseTick(usdgId), expected, "gridBaseTick is the opening tick aligned up");
        assertEq(hook.poolState(usdgId).gridBaseTick, expected, "and the same in the memory view");
    }

    /// @notice `PoolRegistry._openPool` reads this on the line after `initializePool`; it must never revert, not
    ///         even for a pool the hook has never seen (deviation note in §11.5).
    function test_gridBaseTickNeverRevertsForAnUnknownPool() public view {
        assertEq(hook.gridBaseTick(PoolId.wrap(keccak256("nothing"))), int24(0), "unknown pools report zero");
    }

    function test_afterInitializeSeedsTheConfigWord() public view {
        HookPoolState memory entry = hook.poolState(usdgId);
        assertTrue(entry.initialized, "initialized");
        assertEq(uint8(entry.poolClass), uint8(PoolClass.ENTRY), "class");
        assertEq(entry.buyFeeBps, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, "entry buy fee");
        assertEq(entry.constituentId, 0, "entry pools have no constituent");
        assertEq(entry.tickSpacing, TICK_SPACING, "tick spacing");
        assertEq(entry.counterDecimals, 6, "USDG decimals");
        assertEq(entry.maxTickMovePerBlock, Constants.MAX_TICK_MOVE_PER_BLOCK_DEFAULT, "truncation cap");
        assertEq(entry.uiMultiplierX18, uint64(Constants.WAD), "entry pools carry a unit multiplier");

        HookPoolState memory spoke = hook.poolState(stockId);
        assertEq(uint8(spoke.poolClass), uint8(PoolClass.SPOKE), "class");
        assertEq(spoke.buyFeeBps, Constants.BUY_FEE_BPS_SPOKE_DEFAULT, "spoke buy fee");
        assertEq(spoke.constituentId, SPOKE_CONSTITUENT_ID, "constituent");
        assertEq(spoke.uiMultiplierX18, uint64(1e18), "the probed multiplier");
        assertEq(spoke.lastTick, _currentTick(stockId), "lastTick seeded at the opening tick");
        assertEq(spoke.fairTick, _currentTick(stockId), "fairTick seeded at the opening tick");
    }

    function test_theObservationRingIsSeededAtInitialize() public view {
        assertEq(hook.lastTruncatedTick(usdgId), _currentTick(usdgId), "seeded");
        assertEq(hook.highWaterTick(usdgId), _currentTick(usdgId), "high water starts at the opening tick");
        assertEq(hook.observationCoverage(usdgId), 0, "no history yet");
        assertEq(hook.twapWindow(), 1800, "the protocol-wide window");
        assertEq(hook.maxTickMovePerBlock(usdgId), Constants.MAX_TICK_MOVE_PER_BLOCK_DEFAULT, "the cap");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Storage-word packing
    // -----------------------------------------------------------------------------------------------------------

    function testFuzz_configWordRoundTrips(
        uint16 buyFeeBps,
        uint16 constituentId,
        uint8 poolClass,
        int24 tickSpacing,
        int24 maxTickMovePerBlock,
        uint8 counterDecimals,
        int24 gridBaseTick,
        bool initialized
    ) public pure {
        HookStateLib.Config memory c = HookStateLib.Config({
            buyFeeBps: buyFeeBps,
            constituentId: constituentId,
            poolClass: PoolClass(poolClass % 4),
            tickSpacing: tickSpacing,
            maxTickMovePerBlock: maxTickMovePerBlock,
            counterDecimals: counterDecimals,
            gridBaseTick: gridBaseTick,
            initialized: initialized
        });

        HookStateLib.Config memory out = HookStateLib.unpackConfig(HookStateLib.packConfig(c));
        assertEq(out.buyFeeBps, c.buyFeeBps);
        assertEq(out.constituentId, c.constituentId);
        assertEq(uint8(out.poolClass), uint8(c.poolClass));
        assertEq(out.tickSpacing, c.tickSpacing);
        assertEq(out.maxTickMovePerBlock, c.maxTickMovePerBlock);
        assertEq(out.counterDecimals, c.counterDecimals);
        assertEq(out.gridBaseTick, c.gridBaseTick);
        assertEq(out.initialized, c.initialized);

        assertEq(HookStateLib.isInitialized(HookStateLib.packConfig(c)), c.initialized, "the cheap read agrees");
        assertEq(HookStateLib.gridBaseTick(HookStateLib.packConfig(c)), c.gridBaseTick, "and so does this one");
    }

    function testFuzz_dynamicWordRoundTrips(
        int24 lastTick,
        uint32 lastUpdate,
        int24 fairTick,
        int24 innerBandTicks,
        int24 outerRailTicks,
        uint16 dynCapBps,
        uint8 session,
        uint8 gateFlags,
        uint8 fVolBps,
        uint32 gateRefreshedAt,
        uint32 gateAttemptedAt
    ) public pure {
        HookStateLib.Dynamic memory d = HookStateLib.Dynamic({
            lastTick: lastTick,
            lastUpdate: lastUpdate,
            fairTick: fairTick,
            innerBandTicks: innerBandTicks,
            outerRailTicks: outerRailTicks,
            dynCapBps: dynCapBps,
            session: Session(session % 4),
            gateFlags: gateFlags,
            fVolBps: fVolBps,
            gateRefreshedAt: gateRefreshedAt,
            gateAttemptedAt: gateAttemptedAt
        });

        HookStateLib.Dynamic memory out = HookStateLib.unpackDynamic(HookStateLib.packDynamic(d));
        assertEq(out.lastTick, d.lastTick);
        assertEq(out.lastUpdate, d.lastUpdate);
        assertEq(out.fairTick, d.fairTick);
        assertEq(out.innerBandTicks, d.innerBandTicks);
        assertEq(out.outerRailTicks, d.outerRailTicks);
        assertEq(out.dynCapBps, d.dynCapBps);
        assertEq(uint8(out.session), uint8(d.session));
        assertEq(out.gateFlags, d.gateFlags);
        assertEq(out.fVolBps, d.fVolBps);
        assertEq(out.gateRefreshedAt, d.gateRefreshedAt);
        assertEq(out.gateAttemptedAt, d.gateAttemptedAt);
    }

    function testFuzz_armedWordRoundTrips(
        uint16 surgeBps,
        uint32 surgeArmedAt,
        uint16 captureFeeBps,
        uint32 captureArmedAt,
        uint64 uiMultiplierX18,
        uint64 varianceX12,
        uint32 lastCorporateCheck
    ) public pure {
        HookStateLib.Armed memory a = HookStateLib.Armed({
            surgeBps: surgeBps,
            surgeArmedAt: surgeArmedAt,
            captureFeeBps: captureFeeBps,
            captureArmedAt: captureArmedAt,
            uiMultiplierX18: uiMultiplierX18,
            varianceX12: varianceX12,
            lastCorporateCheck: lastCorporateCheck
        });

        HookStateLib.Armed memory out = HookStateLib.unpackArmed(HookStateLib.packArmed(a));
        assertEq(out.surgeBps, a.surgeBps);
        assertEq(out.surgeArmedAt, a.surgeArmedAt);
        assertEq(out.captureFeeBps, a.captureFeeBps);
        assertEq(out.captureArmedAt, a.captureArmedAt);
        assertEq(out.uiMultiplierX18, a.uiMultiplierX18);
        assertEq(out.varianceX12, a.varianceX12);
        assertEq(out.lastCorporateCheck, a.lastCorporateCheck);
    }

    function testFuzz_theThreeWordsAreDisjoint(uint8 flags) public pure {
        assertEq(HookStateLib.withFlag(flags, HookStateLib.FLAG_DEGRADED, true) & HookStateLib.FLAG_DEGRADED, 1);
        assertEq(HookStateLib.withFlag(flags, HookStateLib.FLAG_DEGRADED, false) & HookStateLib.FLAG_DEGRADED, 0);
        assertTrue(HookStateLib.hasFlag(HookStateLib.FLAG_CA_ARMED, HookStateLib.FLAG_CA_ARMED));
        assertFalse(HookStateLib.hasFlag(HookStateLib.FLAG_CA_ARMED, HookStateLib.FLAG_DEGRADED));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Governed parameters
    // -----------------------------------------------------------------------------------------------------------

    function test_sellFeeIsTimelockOnlyAndBanded() public {
        assertEq(hook.sellFeeBps(), Constants.SELL_FEE_BPS_DEFAULT, "launch value");
        assertEq(hook.SELL_FEE_BPS_MIN(), 100, "hard floor");
        assertEq(hook.SELL_FEE_BPS_MAX(), 600, "hard ceiling");

        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, address(this)));
        hook.setSellFeeBps(300);

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("sellFeeBps"), uint256(99), uint256(100), uint256(600))
        );
        hook.setSellFeeBps(99);

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("sellFeeBps"), uint256(601), uint256(100), uint256(600))
        );
        hook.setSellFeeBps(601);

        vm.prank(TIMELOCK);
        hook.setSellFeeBps(600);
        assertEq(hook.sellFeeBps(), 600, "set");
    }

    function test_buyFeeBandsFollowThePoolClass() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("buyFeeBps"), uint256(4), uint256(5), uint256(100))
        );
        hook.setBuyFeeBps(usdgId, 4);

        vm.prank(TIMELOCK);
        hook.setBuyFeeBps(usdgId, 100);
        assertEq(hook.buyFeeBps(usdgId), 100, "entry band tops out at 100 bp");

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("buyFeeBps"), uint256(51), uint256(1), uint256(50))
        );
        hook.setBuyFeeBps(stockId, 51);

        vm.prank(TIMELOCK);
        hook.setBuyFeeBps(stockId, 50);
        assertEq(hook.buyFeeBps(stockId), 50, "spoke band tops out at 50 bp");

        vm.prank(TIMELOCK);
        vm.expectRevert(NotInitialized.selector);
        hook.setBuyFeeBps(PoolId.wrap(keccak256("nothing")), 10);
    }

    function test_maxTickMovePerBlockIsBanded() public {
        vm.prank(TIMELOCK);
        vm.expectRevert();
        hook.setMaxTickMovePerBlock(usdgId, 9);

        vm.prank(TIMELOCK);
        vm.expectRevert();
        hook.setMaxTickMovePerBlock(usdgId, 2001);

        vm.prank(TIMELOCK);
        hook.setMaxTickMovePerBlock(usdgId, 2000);
        assertEq(hook.maxTickMovePerBlock(usdgId), 2000, "set");
    }

    function test_feePolicyPointerIsTimelockOnlyAndMustHaveCode() public {
        assertEq(hook.feePolicy(), address(policy), "wired in the fixture");

        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, address(this)));
        hook.setFeePolicy(address(0xDEAD));

        vm.prank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        hook.setFeePolicy(address(0));

        // A `staticcall` to an address with no code succeeds with empty return data, which would silently turn
        // every dynamic component into the cached `f_vol`. The setter refuses it.
        vm.prank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        hook.setFeePolicy(address(0xC0DE1E55));

        HookStubFeePolicy replacement = new HookStubFeePolicy();
        vm.prank(TIMELOCK);
        hook.setFeePolicy(address(replacement));
        assertEq(hook.feePolicy(), address(replacement), "pointer moved");
    }

    function test_gateCacheSecondsIsTimelockOnlyAndBanded() public {
        assertEq(hook.gateCacheSeconds(), Constants.GATE_CACHE_SECONDS_DEFAULT, "launch value");

        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, address(this)));
        hook.setGateCacheSeconds(30);

        vm.prank(TIMELOCK);
        vm.expectRevert();
        hook.setGateCacheSeconds(0);

        vm.prank(TIMELOCK);
        vm.expectRevert();
        hook.setGateCacheSeconds(Constants.GATE_CACHE_MAX_AGE + 1);

        vm.prank(TIMELOCK);
        hook.setGateCacheSeconds(30);
        assertEq(hook.gateCacheSeconds(), 30, "set");
    }

    function test_vaultOnlyMutators() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, STRANGER));
        hook.resetHighWater(usdgId);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, STRANGER));
        hook.armSurge(usdgId, 100, "placement");

        vm.expectRevert();
        hook.armSurge(usdgId, Constants.SURGE_MAX_BPS + 1, "placement");

        hook.armSurge(usdgId, Constants.SURGE_MAX_BPS, "placement");
        assertEq(hook.poolState(usdgId).surgeBps, Constants.SURGE_MAX_BPS, "armed");
        assertEq(hook.poolState(usdgId).surgeArmedAt, uint32(block.timestamp), "armed now");

        vm.expectRevert(NotInitialized.selector);
        hook.resetHighWater(PoolId.wrap(keccak256("nothing")));
    }

    function test_theImmutablePointers() public view {
        assertEq(hook.amps(), AMPS_ADDRESS, "amps");
        assertEq(hook.vault(), address(this), "vault");
        assertEq(hook.registry(), address(registry), "registry");
        assertEq(hook.timelock(), TIMELOCK, "timelock");
        assertEq(hook.oracleGate(), address(gate), "the gate, read through the vault");
        assertEq(hook.TOTAL_FEE_BPS_MAX(), Constants.TOTAL_FEE_BPS_MAX, "2,600 bp");
    }

    /// @notice A vault that cannot answer `oracleGate()` degrades to "no gate", never to a revert.
    function test_theGatePointerDegradesRatherThanReverting() public {
        gatePointerReverts = true;
        assertEq(hook.oracleGate(), address(0), "unreadable is address(0)");
        gatePointerReverts = false;

        _setGatePointer(address(0xC0DE1E55));
        assertEq(hook.oracleGate(), address(0), "an address with no code is address(0)");
    }
}
