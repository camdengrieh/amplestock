// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolStateLib} from "../../src/lib/PoolStateLib.sol";
import {StubAmpsHook} from "../gas/StubAmpsHook.sol";
import {LadderSwapper} from "../mocks/LadderSwapper.sol";
import {PoolStateLp} from "../mocks/PoolStateLp.sol";
import {V4TestBase} from "../utils/V4TestBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CurrencyDelta} from "@uniswap/v4-core/src/libraries/CurrencyDelta.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Lock} from "@uniswap/v4-core/src/libraries/Lock.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title PoolStateLibTest
/// @notice Differential proof that `PoolStateLib`'s hand-derived slot arithmetic reads the same bytes Uniswap's own
///         `StateLibrary` / `TransientStateLibrary` read, on a live local `PoolManager`.
///
/// @dev **Why this test is the whole safety argument.** `PoolStateLib` may not import either Uniswap helper from
///      `src/` — both drag in BUSL-1.1 files (`Position`, `Lock`, `NonzeroDeltaCount`, `CurrencyReserves`) and the
///      licence gate would fail. The library therefore re-derives every slot from the documented storage layout.
///      Tests never ship, so here the BUSL helpers *are* imported and every single read is asserted equal, against
///      two pools (one with the `0x38C0` hook, one bare), nine positions spanning non-zero salts, negative ticks,
///      `MIN_TICK`/`MAX_TICK` alignment and two distinct owners, before and after swaps in both directions.
///
/// @dev Transient reads happen **inside** `unlockCallback`. Foundry >= 1.8 clears transient storage between the
///      top-level calls a test makes, so an `exttload` assertion is only meaningful in the same call frame that
///      opened the lock.
contract PoolStateLibTest is V4TestBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @dev Three leading zero bytes, so AMPS sorts first and is `currency0` in both pools.
    address internal constant AMPS_ADDRESS = 0x0000001234567890123456789012345678901234;
    address internal constant USDG_ADDRESS = 0x1111111111111111111111111111111111111111;
    address internal constant STOCK_ADDRESS = 0x2222222222222222222222222222222222222222;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    int24 internal constant HOOKED_SPACING = 10;
    int24 internal constant BARE_SPACING = 60;

    uint8 internal constant ACTION_MODIFY = 0;
    uint8 internal constant ACTION_PROBE_TRANSIENT = 1;

    /// @dev 0.05% each way, well inside v4's 0.1% per-direction cap; packed as `oneForZero << 12 | zeroForOne`.
    uint24 internal constant PROTOCOL_FEE = uint24(500) | (uint24(500) << 12);

    bytes32 internal constant SALT_ONE = keccak256("amplestocks.test.salt.one");
    bytes32 internal constant SALT_TWO = bytes32(uint256(42));

    /// @notice One position the differential suite walks over.
    struct Pos {
        int24 lower;
        int24 upper;
        bytes32 salt;
        address owner;
        bool hooked;
    }

    MockERC20 internal amps;
    MockERC20 internal usdg;
    MockERC20 internal stock;
    StubAmpsHook internal hook;
    PoolStateLp internal secondLp;
    LadderSwapper internal swapper;

    PoolKey internal hookedKey;
    PoolKey internal bareKey;
    PoolId internal hookedId;
    PoolId internal bareId;

    Pos[] internal positions;

    bool internal transientProbeRan;

    function setUp() public {
        deployV4();

        amps = deployTokenAt(AMPS_ADDRESS, "Amplestocks", "AMPS", 18);
        usdg = deployTokenAt(USDG_ADDRESS, "Global Dollar", "USDG", 6);
        stock = deployTokenAt(STOCK_ADDRESS, "Mock Stock Token", "STOCK", 18);

        // The test contract is the vault: it mines and deploys the hook and is that pool's only LP.
        bytes memory args = abi.encode(poolManager, Currency.wrap(AMPS_ADDRESS), address(this));
        (address mined, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(StubAmpsHook).creationCode, args);
        hook = new StubAmpsHook{salt: salt}(poolManager, Currency.wrap(AMPS_ADDRESS), address(this));
        require(address(hook) == mined, "hook address mismatch");
        vm.label(address(hook), "StubAmpsHook");

        secondLp = new PoolStateLp(poolManager);
        vm.label(address(secondLp), "PoolStateLp");
        amps.transfer(address(secondLp), 1_000_000e18);
        stock.transfer(address(secondLp), 10_000e18);

        swapper = new LadderSwapper(poolManager);
        vm.label(address(swapper), "LadderSwapper");
        amps.transfer(address(swapper), 3_000_000e18);
        usdg.transfer(address(swapper), 3_000_000e6);

        hookedKey = PoolKey({
            currency0: Currency.wrap(AMPS_ADDRESS),
            currency1: Currency.wrap(USDG_ADDRESS),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: HOOKED_SPACING,
            hooks: IHooks(address(hook))
        });
        bareKey = PoolKey({
            currency0: Currency.wrap(AMPS_ADDRESS),
            currency1: Currency.wrap(STOCK_ADDRESS),
            fee: 3000,
            tickSpacing: BARE_SPACING,
            hooks: IHooks(address(0))
        });
        hookedId = hookedKey.toId();
        bareId = bareKey.toId();

        // AMPS $1.00 against 6-decimal USDG: raw amount1/amount0 == 1e6 / 1e18.
        poolManager.initialize(hookedKey, _sqrtPriceX96(1e6, 1e18));
        // AMPS $1.00 against an 18-decimal $180 stock: raw amount1/amount0 == 1 / 180.
        poolManager.initialize(bareKey, _sqrtPriceX96(1, 180));

        // A non-zero protocol fee is the only way `slot0` bits [184..207] are ever exercised on a local pool.
        vm.prank(POOL_MANAGER_OWNER);
        poolManager.setProtocolFeeController(address(this));
        poolManager.setProtocolFee(hookedKey, PROTOCOL_FEE);

        _seedHookedPool();
        _seedBarePool();
        _generateFees();
    }

    // -------------------------------------------------------------------------------------------------------------
    // The slot derivations themselves
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `PoolManager._pools` really is slot 6, established against live storage rather than by reading the
    ///         (BUSL) source: exactly one candidate mapping slot in `[0, 24)` hashes to a word whose low 160 bits
    ///         are the pool's live `sqrtPriceX96`, and it is 6.
    function test_poolsMappingLivesAtSlotSix() public view {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(hookedId);
        assertTrue(sqrtPriceX96 != 0, "pool must be initialised");

        uint256 matches;
        uint256 found = type(uint256).max;
        for (uint256 k; k < 24; ++k) {
            bytes32 candidate = keccak256(abi.encodePacked(PoolId.unwrap(hookedId), bytes32(k)));
            bytes32 word = vm.load(address(poolManager), candidate);
            if (word != bytes32(0) && uint160(uint256(word)) == sqrtPriceX96) {
                ++matches;
                found = k;
            }
        }
        assertEq(matches, 1, "exactly one mapping slot holds slot0");
        assertEq(found, 6, "the pools mapping is at slot 6");
        assertEq(uint256(PoolStateLib.POOLS_SLOT), 6, "POOLS_SLOT");
        assertEq(PoolStateLib.POOLS_SLOT, StateLibrary.POOLS_SLOT, "POOLS_SLOT vs StateLibrary");
    }

    /// @notice `extsload` is a plain `SLOAD`: every derived slot reads what `vm.load` reads.
    function test_extsloadEqualsRawStorage() public view {
        bytes32 stateSlot = PoolStateLib.poolStateSlot(hookedId);
        for (uint256 offset; offset < 4; ++offset) {
            bytes32 slot = bytes32(uint256(stateSlot) + offset);
            assertEq(poolManager.extsload(slot), vm.load(address(poolManager), slot), "extsload vs vm.load");
        }
    }

    /// @notice The `Pool.State` field offsets match the ones Uniswap's helper uses.
    function test_stateOffsetsMatchStateLibrary() public pure {
        assertEq(PoolStateLib.FEE_GROWTH_GLOBAL0_OFFSET, StateLibrary.FEE_GROWTH_GLOBAL0_OFFSET, "feeGrowthGlobal0");
        assertEq(PoolStateLib.LIQUIDITY_OFFSET, StateLibrary.LIQUIDITY_OFFSET, "liquidity");
        assertEq(PoolStateLib.TICKS_OFFSET, StateLibrary.TICKS_OFFSET, "ticks");
        assertEq(PoolStateLib.TICK_BITMAP_OFFSET, StateLibrary.TICK_BITMAP_OFFSET, "tickBitmap");
        assertEq(PoolStateLib.POSITIONS_OFFSET, StateLibrary.POSITIONS_OFFSET, "positions");
    }

    /// @notice The two hard-coded transient slots equal both their documented preimages and v4's own constants.
    function test_transientSlotsMatchTheirPreimages() public pure {
        assertEq(PoolStateLib.IS_UNLOCKED_SLOT, bytes32(uint256(keccak256("Unlocked")) - 1), "Unlocked preimage");
        assertEq(PoolStateLib.IS_UNLOCKED_SLOT, Lock.IS_UNLOCKED_SLOT, "Unlocked vs v4");
        assertEq(
            PoolStateLib.NONZERO_DELTA_COUNT_SLOT,
            bytes32(uint256(keccak256("NonzeroDeltaCount")) - 1),
            "NonzeroDeltaCount preimage"
        );
        assertEq(
            PoolStateLib.NONZERO_DELTA_COUNT_SLOT, NonzeroDeltaCount.NONZERO_DELTA_COUNT_SLOT, "NonzeroDeltaCount vs v4"
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // Pool-level reads
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `slot0`, `liquidity` and the fee-growth globals agree in both pools, before and after swaps.
    function test_poolReadsMatchStateLibrary() public view {
        _assertPoolReadsMatch(hookedId);
        _assertPoolReadsMatch(bareId);
    }

    /// @notice The hooked pool carries a dynamic LP fee written by the hook's `beforeSwap` override; the bare pool
    ///         carries its static one. Both unpack identically, which is what exercises the upper `slot0` fields.
    function test_slot0FeeFieldsUnpack() public view {
        (,,, uint24 hookedLpFee) = PoolStateLib.slot0(poolManager, hookedId);
        (,,, uint24 bareLpFee) = PoolStateLib.slot0(poolManager, bareId);
        (,,, uint24 expectedHooked) = poolManager.getSlot0(hookedId);
        (,,, uint24 expectedBare) = poolManager.getSlot0(bareId);
        assertEq(hookedLpFee, expectedHooked, "hooked lpFee");
        assertEq(bareLpFee, expectedBare, "bare lpFee");
        assertEq(bareLpFee, uint24(3000), "bare pool keeps its static fee");

        (,, uint24 hookedProtocolFee,) = PoolStateLib.slot0(poolManager, hookedId);
        (,, uint24 expectedProtocolFee,) = poolManager.getSlot0(hookedId);
        assertEq(hookedProtocolFee, expectedProtocolFee, "protocolFee");
        assertEq(hookedProtocolFee, PROTOCOL_FEE, "the protocol fee really is set");
        assertTrue(hookedProtocolFee != 0, "slot0 bits [184..207] are exercised");
        // A dynamic-fee pool stores 0 until the hook calls `updateDynamicLPFee`; the stub hook only ever returns
        // a per-swap `OVERRIDE_FEE_FLAG` fee, which never touches `slot0`.
        assertEq(hookedLpFee, uint24(0), "a dynamic-fee pool stores no lpFee of its own");
    }

    /// @notice `sqrtPriceAndTick` is the two-field shorthand for `slot0`.
    function test_sqrtPriceAndTickMatchesSlot0() public view {
        (uint160 expectedSqrt, int24 expectedTick,,) = poolManager.getSlot0(hookedId);
        (uint160 sqrtPriceX96, int24 tick) = PoolStateLib.sqrtPriceAndTick(poolManager, hookedId);
        assertEq(sqrtPriceX96, expectedSqrt, "sqrtPriceX96");
        assertEq(tick, expectedTick, "tick");
    }

    /// @notice Reads of a pool that was never initialised are zeros, never reverts: the NAV path must degrade to
    ///         "worth nothing".
    function test_uninitialisedPoolReadsZero() public view {
        PoolId ghost = PoolId.wrap(keccak256("no such pool"));
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = PoolStateLib.slot0(poolManager, ghost);
        assertEq(sqrtPriceX96, 0, "sqrtPriceX96");
        assertEq(tick, int24(0), "tick");
        assertEq(protocolFee, uint24(0), "protocolFee");
        assertEq(lpFee, uint24(0), "lpFee");
        assertEq(PoolStateLib.liquidity(poolManager, ghost), 0, "liquidity");
        (uint256 g0, uint256 g1) = PoolStateLib.feeGrowthGlobals(poolManager, ghost);
        assertEq(g0 | g1, 0, "fee growth globals");
        assertEq(PoolStateLib.positionLiquidity(poolManager, ghost, address(this), -60, 60, bytes32(0)), 0, "position");
        assertEq(PoolStateLib.tickBitmap(poolManager, ghost, int16(0)), 0, "bitmap");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Positions
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every one of the nine seeded positions reads identically through both libraries: key, slot,
    ///         liquidity, both cached fee-growth words, live `feeGrowthInside` and `feesOwed`.
    function test_positionReadsMatchStateLibrary() public view {
        uint256 length = positions.length;
        assertEq(length, 9, "nine positions seeded");
        uint256 nonEmpty;
        for (uint256 i; i < length; ++i) {
            Pos memory p = positions[i];
            if (_assertPositionReadsMatch(p) != 0) ++nonEmpty;
        }
        assertGe(nonEmpty, 7, "most seeded positions must actually hold liquidity");
    }

    /// @notice Two positions that differ only in salt are two positions, and the library separates them.
    function test_nonZeroSaltIsADistinctPosition() public view {
        Pos memory zeroSalt = positions[1];
        Pos memory oneSalt = positions[2];
        assertEq(zeroSalt.lower, oneSalt.lower, "same lower");
        assertEq(zeroSalt.upper, oneSalt.upper, "same upper");
        assertTrue(zeroSalt.salt != oneSalt.salt, "different salt");

        bytes32 slotA =
            PoolStateLib.positionSlot(hookedId, address(this), zeroSalt.lower, zeroSalt.upper, zeroSalt.salt);
        bytes32 slotB = PoolStateLib.positionSlot(hookedId, address(this), oneSalt.lower, oneSalt.upper, oneSalt.salt);
        assertTrue(slotA != slotB, "distinct slots");

        uint128 liquidityA = PoolStateLib.positionLiquidity(
            poolManager, hookedId, address(this), zeroSalt.lower, zeroSalt.upper, zeroSalt.salt
        );
        uint128 liquidityB = PoolStateLib.positionLiquidity(
            poolManager, hookedId, address(this), oneSalt.lower, oneSalt.upper, oneSalt.salt
        );
        assertTrue(liquidityA != 0 && liquidityB != 0, "both funded");
        assertTrue(liquidityA != liquidityB, "seeded with different sizes");
    }

    /// @notice The same range and salt owned by two different accounts are two positions.
    function test_ownerSeparatesPositions() public view {
        Pos memory mine = positions[6];
        Pos memory theirs = positions[7];
        assertEq(mine.lower, theirs.lower, "same lower");
        assertEq(mine.upper, theirs.upper, "same upper");
        assertEq(mine.salt, theirs.salt, "same salt");
        assertTrue(mine.owner != theirs.owner, "different owner");

        uint128 a = PoolStateLib.positionLiquidity(poolManager, bareId, mine.owner, mine.lower, mine.upper, mine.salt);
        uint128 b =
            PoolStateLib.positionLiquidity(poolManager, bareId, theirs.owner, theirs.lower, theirs.upper, theirs.salt);
        assertTrue(a != 0 && b != 0, "both funded");
        assertTrue(a != b, "seeded with different sizes");
    }

    /// @notice The batched reads return exactly the per-position reads, in order, including empty slots.
    function test_batchedPositionLiquidityMatchesSingleReads() public view {
        bytes32[] memory keys = new bytes32[](5);
        bytes32[] memory slots = new bytes32[](5);
        uint128[] memory expected = new uint128[](5);

        bytes32 base = PoolStateLib.positionsBaseSlot(hookedId);
        for (uint256 i; i < 4; ++i) {
            Pos memory p = positions[i];
            keys[i] = PoolStateLib.positionKey(p.owner, p.lower, p.upper, p.salt);
            slots[i] = PoolStateLib.positionSlotIn(base, keys[i]);
            expected[i] = poolManager.getPositionLiquidity(hookedId, keys[i]);
        }
        // A never-created position: the batch must return a zero, not skip or revert.
        keys[4] = PoolStateLib.positionKey(address(0xBEEF), -120, 120, bytes32(uint256(7)));
        slots[4] = PoolStateLib.positionSlotIn(base, keys[4]);
        expected[4] = 0;

        uint128[] memory byKeys = PoolStateLib.positionLiquidityBatch(poolManager, hookedId, keys);
        uint128[] memory bySlots = PoolStateLib.positionLiquidityAtSlots(poolManager, slots);
        assertEq(byKeys.length, 5, "batch length");
        assertEq(bySlots.length, 5, "slot batch length");
        for (uint256 i; i < 5; ++i) {
            assertEq(byKeys[i], expected[i], "batch by key");
            assertEq(bySlots[i], expected[i], "batch by slot");
        }
        assertEq(byKeys[4], 0, "empty position reads zero");
    }

    /// @notice The in-place narrowing inside `positionLiquidityAtSlots` must not corrupt the words it masks: a
    ///         position whose *upper* 128 bits are non-zero is impossible in `Position.State`, so instead this
    ///         checks the masking against the raw slot word for every seeded position.
    function test_batchNarrowingKeepsOnlyTheLowWord() public view {
        bytes32[] memory slots = new bytes32[](4);
        for (uint256 i; i < 4; ++i) {
            Pos memory p = positions[i];
            slots[i] = PoolStateLib.positionSlot(hookedId, p.owner, p.lower, p.upper, p.salt);
        }
        uint128[] memory narrowed = PoolStateLib.positionLiquidityAtSlots(poolManager, slots);
        for (uint256 i; i < 4; ++i) {
            bytes32 raw = vm.load(address(poolManager), slots[i]);
            assertEq(narrowed[i], uint128(uint256(raw)), "low 128 bits preserved");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Ticks and the bitmap
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every tick touched by a seeded position — negative, positive, `MIN_TICK`- and `MAX_TICK`-aligned —
    ///         reads identically, as does an untouched tick.
    function test_tickReadsMatchStateLibrary() public view {
        uint256 length = positions.length;
        uint256 initialised;
        for (uint256 i; i < length; ++i) {
            Pos memory p = positions[i];
            PoolId id = p.hooked ? hookedId : bareId;
            if (_assertTickReadsMatch(id, p.lower)) ++initialised;
            if (_assertTickReadsMatch(id, p.upper)) ++initialised;
        }
        assertGe(initialised, 12, "most seeded ticks must be initialised");

        // Untouched ticks: zeros through both libraries.
        assertFalse(_assertTickReadsMatch(hookedId, 123_450), "an untouched tick is uninitialised");
        assertFalse(_assertTickReadsMatch(bareId, -123_480), "an untouched negative tick is uninitialised");
    }

    /// @notice The `MIN_TICK`/`MAX_TICK`-aligned positions really do sit on the usable extremes.
    function test_extremeTicksAreAtTheUsableBounds() public view {
        assertEq(positions[4].lower, TickMath.minUsableTick(HOOKED_SPACING), "min usable tick");
        assertEq(positions[5].upper, TickMath.maxUsableTick(HOOKED_SPACING), "max usable tick");
        _assertTickReadsMatch(hookedId, TickMath.minUsableTick(HOOKED_SPACING));
        _assertTickReadsMatch(hookedId, TickMath.maxUsableTick(HOOKED_SPACING));
    }

    /// @notice The bitmap word of every seeded tick matches, and at least one word is non-zero.
    function test_tickBitmapMatchesStateLibrary() public view {
        uint256 length = positions.length;
        uint256 nonZeroWords;
        for (uint256 i; i < length; ++i) {
            Pos memory p = positions[i];
            PoolId id = p.hooked ? hookedId : bareId;
            int24 spacing = p.hooked ? HOOKED_SPACING : BARE_SPACING;
            if (_assertBitmapMatches(id, p.lower, spacing)) ++nonZeroWords;
            if (_assertBitmapMatches(id, p.upper, spacing)) ++nonZeroWords;
        }
        assertGe(nonZeroWords, 12, "seeded ticks must be flagged in the bitmap");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Fee growth, in every branch
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `feeGrowthInside` is exercised in all three branches (tick below, inside and above the range) by
    ///         walking the price across a position with swaps, and matches Uniswap's helper at every step.
    function test_feeGrowthInsideMatchesInEveryBranch() public {
        Pos memory p = positions[0];
        (, int24 tick,,) = poolManager.getSlot0(hookedId);
        assertTrue(tick > p.lower && tick < p.upper, "start inside the range");
        _assertFeeGrowthInsideMatches(hookedId, p.lower, p.upper);
        _assertPositionReadsMatch(p);

        // Walk the price to an exact tick above the range, then below it, then back inside.
        _moveTickTo(hookedKey, p.upper + 100 * HOOKED_SPACING);
        (, tick,,) = poolManager.getSlot0(hookedId);
        assertGt(tick, p.upper, "tick above the range");
        _assertFeeGrowthInsideMatches(hookedId, p.lower, p.upper);
        _assertPositionReadsMatch(p);

        _moveTickTo(hookedKey, p.lower - 100 * HOOKED_SPACING);
        (, tick,,) = poolManager.getSlot0(hookedId);
        assertLt(tick, p.lower, "tick below the range");
        _assertFeeGrowthInsideMatches(hookedId, p.lower, p.upper);
        _assertPositionReadsMatch(p);

        _moveTickTo(hookedKey, (p.lower + p.upper) / 2);
        (, tick,,) = poolManager.getSlot0(hookedId);
        assertTrue(tick > p.lower && tick < p.upper, "tick back inside the range");
        _assertFeeGrowthInsideMatches(hookedId, p.lower, p.upper);
        _assertPositionReadsMatch(p);
    }

    /// @notice Fee growth is non-zero after the seeded swaps, so the equality above is not the trivial `0 == 0`.
    function test_feeGrowthIsNonZeroAfterSwaps() public view {
        (uint256 g0, uint256 g1) = PoolStateLib.feeGrowthGlobals(poolManager, hookedId);
        assertTrue(g0 != 0 || g1 != 0, "swaps must have accrued fees");
        (uint256 b0, uint256 b1) = PoolStateLib.feeGrowthGlobals(poolManager, bareId);
        assertTrue(b0 != 0 || b1 != 0, "bare pool fees");
    }

    /// @notice `feesOwed` equals the same arithmetic done through Uniswap's helpers, and is non-zero for a
    ///         position that was in range while fees accrued.
    function test_feesOwedMatchesAndIsNonZero() public view {
        Pos memory p = positions[0];
        (uint256 owed0, uint256 owed1) = PoolStateLib.feesOwed(poolManager, hookedId, p.owner, p.lower, p.upper, p.salt);
        (uint256 expected0, uint256 expected1) = _expectedFeesOwed(hookedId, p);
        assertEq(owed0, expected0, "owed0");
        assertEq(owed1, expected1, "owed1");
        assertTrue(owed0 != 0 || owed1 != 0, "the wide position collected fees");
    }

    /// @notice A position with no liquidity owes nothing, and does not divide by zero on the way there.
    function test_feesOwedOnAnEmptyPositionIsZero() public view {
        (uint256 owed0, uint256 owed1) =
            PoolStateLib.feesOwed(poolManager, hookedId, address(0xBEEF), -120, 120, bytes32(0));
        assertEq(owed0, 0, "owed0");
        assertEq(owed1, 0, "owed1");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Transient state
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Outside a lock the manager is locked and no delta is open; inside `unlockCallback` every transient
    ///         read matches `TransientStateLibrary`, including a live negative delta and the slot derivation.
    function test_transientReadsMatchTransientStateLibrary() public {
        assertFalse(PoolStateLib.isUnlocked(poolManager), "locked outside unlock");
        assertEq(PoolStateLib.isUnlocked(poolManager), poolManager.isUnlocked(), "isUnlocked outside");
        assertEq(PoolStateLib.nonzeroDeltaCount(poolManager), 0, "no open deltas outside");
        assertEq(PoolStateLib.nonzeroDeltaCount(poolManager), poolManager.getNonzeroDeltaCount(), "count outside");

        poolManager.unlock(abi.encode(ACTION_PROBE_TRANSIENT, hookedKey, int24(0), int24(0), int256(0), bytes32(0)));

        assertTrue(transientProbeRan, "the probe must have run inside the callback");
        assertFalse(PoolStateLib.isUnlocked(poolManager), "locked again afterwards");
    }

    /// @notice The `(target, currency)` transient slot is `keccak256(abi.encode(target, currency))`, matching v4's
    ///         own `CurrencyDelta._computeSlot`.
    function testFuzz_currencyDeltaSlotMatchesV4(address target, address currency) public pure {
        Currency wrapped = Currency.wrap(currency);
        assertEq(PoolStateLib.currencyDeltaSlot(target, wrapped), CurrencyDelta._computeSlot(target, wrapped), "slot");
        assertEq(PoolStateLib.currencyDeltaSlot(target, wrapped), keccak256(abi.encode(target, currency)), "encode");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Fuzzed slot arithmetic
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The position key equals both v4's own helper and the `abi.encodePacked` it documents, for arbitrary
    ///         owners, ticks and salts.
    function testFuzz_positionKeyMatchesV4(address owner, int24 lower, int24 upper, bytes32 salt) public pure {
        bytes32 key = PoolStateLib.positionKey(owner, lower, upper, salt);
        assertEq(key, Position.calculatePositionKey(owner, lower, upper, salt), "vs Position");
        assertEq(key, keccak256(abi.encodePacked(owner, lower, upper, salt)), "vs encodePacked");
    }

    /// @notice The key assembly is memory-safe: the free memory pointer is untouched and a fresh allocation made
    ///         straight afterwards is uncorrupted.
    function testFuzz_positionKeyIsMemorySafe(address owner, int24 lower, int24 upper, bytes32 salt) public pure {
        uint256 fmpBefore;
        assembly ("memory-safe") {
            fmpBefore := mload(0x40)
        }
        bytes32 key = PoolStateLib.positionKey(owner, lower, upper, salt);
        uint256 fmpAfter;
        assembly ("memory-safe") {
            fmpAfter := mload(0x40)
        }
        assertEq(fmpAfter, fmpBefore, "free memory pointer unmoved");

        bytes memory fresh = abi.encode(owner, lower, upper, salt);
        assertEq(keccak256(fresh), keccak256(abi.encode(owner, lower, upper, salt)), "scratch left clean");
        assertEq(key, keccak256(abi.encodePacked(owner, lower, upper, salt)), "key still correct");
    }

    /// @notice Every derived slot matches Uniswap's for arbitrary pool ids, ticks, owners and salts.
    function testFuzz_slotsMatchStateLibrary(
        bytes32 rawId,
        int24 tick,
        address owner,
        int24 lower,
        int24 upper,
        bytes32 salt
    ) public pure {
        PoolId id = PoolId.wrap(rawId);
        assertEq(PoolStateLib.poolStateSlot(id), StateLibrary._getPoolStateSlot(id), "poolStateSlot");
        assertEq(PoolStateLib.tickInfoSlot(id, tick), StateLibrary._getTickInfoSlot(id, tick), "tickInfoSlot");

        bytes32 key = Position.calculatePositionKey(owner, lower, upper, salt);
        assertEq(PoolStateLib.positionSlot(id, key), StateLibrary._getPositionInfoSlot(id, key), "positionSlot(key)");
        assertEq(
            PoolStateLib.positionSlot(id, owner, lower, upper, salt),
            StateLibrary._getPositionInfoSlot(id, key),
            "positionSlot(owner,...)"
        );
        assertEq(
            PoolStateLib.positionSlotIn(PoolStateLib.positionsBaseSlot(id), key),
            StateLibrary._getPositionInfoSlot(id, key),
            "positionSlotIn"
        );
        assertEq(
            uint256(PoolStateLib.positionsBaseSlot(id)),
            uint256(StateLibrary._getPoolStateSlot(id)) + StateLibrary.POSITIONS_OFFSET,
            "positionsBaseSlot"
        );
    }

    /// @notice The tick-bitmap slot matches the mapping-slot rule Uniswap uses, for arbitrary word positions.
    function testFuzz_tickBitmapSlotMatchesStateLibrary(bytes32 rawId, int16 wordPos) public pure {
        PoolId id = PoolId.wrap(rawId);
        bytes32 expected = keccak256(
            abi.encodePacked(
                int256(wordPos), bytes32(uint256(StateLibrary._getPoolStateSlot(id)) + StateLibrary.TICK_BITMAP_OFFSET)
            )
        );
        assertEq(PoolStateLib.tickBitmapSlot(id, wordPos), expected, "tickBitmapSlot");
    }

    /// @notice Reads at fuzzed live-pool coordinates match, whether or not anything is stored there.
    function testFuzz_liveReadsMatchStateLibrary(int24 tick, int16 wordPos, address owner, bytes32 salt) public view {
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        _assertTickReadsMatch(hookedId, tick);
        assertEq(
            PoolStateLib.tickBitmap(poolManager, hookedId, wordPos),
            poolManager.getTickBitmap(hookedId, wordPos),
            "tickBitmap"
        );
        _assertFuzzedPositionMatches(tick, owner, salt);
    }

    /// @dev Split out of the fuzz test above purely to stay inside the legacy pipeline's stack window.
    function _assertFuzzedPositionMatches(int24 tick, address owner, bytes32 salt) private view {
        int24 lower = _align(tick, HOOKED_SPACING);
        int24 upper = lower + HOOKED_SPACING;
        (uint128 expected, uint256 expectedF0, uint256 expectedF1) =
            poolManager.getPositionInfo(hookedId, owner, lower, upper, salt);
        (uint128 liquidity_, uint256 f0, uint256 f1) =
            PoolStateLib.positionInfo(poolManager, hookedId, owner, lower, upper, salt);
        assertEq(liquidity_, expected, "position liquidity");
        assertEq(f0, expectedF0, "feeGrowthInside0Last");
        assertEq(f1, expectedF1, "feeGrowthInside1Last");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Differential helpers
    // -------------------------------------------------------------------------------------------------------------

    function _assertPoolReadsMatch(PoolId id) private view {
        (uint160 expectedSqrt, int24 expectedTick, uint24 expectedProtocolFee, uint24 expectedLpFee) =
            poolManager.getSlot0(id);
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = PoolStateLib.slot0(poolManager, id);
        assertEq(sqrtPriceX96, expectedSqrt, "sqrtPriceX96");
        assertEq(tick, expectedTick, "tick");
        assertEq(protocolFee, expectedProtocolFee, "protocolFee");
        assertEq(lpFee, expectedLpFee, "lpFee");

        assertEq(PoolStateLib.liquidity(poolManager, id), poolManager.getLiquidity(id), "liquidity");

        (uint256 expected0, uint256 expected1) = poolManager.getFeeGrowthGlobals(id);
        (uint256 global0, uint256 global1) = PoolStateLib.feeGrowthGlobals(poolManager, id);
        assertEq(global0, expected0, "feeGrowthGlobal0");
        assertEq(global1, expected1, "feeGrowthGlobal1");

        assertEq(PoolStateLib.poolStateSlot(id), StateLibrary._getPoolStateSlot(id), "poolStateSlot");
    }

    /// @dev Returns the position's liquidity so callers can assert the sample is not all-empty. Split into four
    ///      helpers purely to stay inside the legacy pipeline's stack window.
    function _assertPositionReadsMatch(Pos memory p) private view returns (uint128 liquidity_) {
        PoolId id = p.hooked ? hookedId : bareId;
        _assertPositionKeyMatches(id, p);
        liquidity_ = _assertPositionInfoMatches(id, p);
        _assertFeeGrowthInsideMatches(id, p.lower, p.upper);
        _assertFeesOwedMatch(id, p);
    }

    function _assertPositionKeyMatches(PoolId id, Pos memory p) private pure {
        bytes32 expectedKey = Position.calculatePositionKey(p.owner, p.lower, p.upper, p.salt);
        assertEq(PoolStateLib.positionKey(p.owner, p.lower, p.upper, p.salt), expectedKey, "positionKey");
        assertEq(
            PoolStateLib.positionSlot(id, p.owner, p.lower, p.upper, p.salt),
            StateLibrary._getPositionInfoSlot(id, expectedKey),
            "positionSlot"
        );
    }

    function _assertPositionInfoMatches(PoolId id, Pos memory p) private view returns (uint128 liquidity_) {
        (uint128 expectedLiquidity, uint256 expectedF0, uint256 expectedF1) =
            poolManager.getPositionInfo(id, p.owner, p.lower, p.upper, p.salt);
        (uint128 actual, uint256 f0, uint256 f1) =
            PoolStateLib.positionInfo(poolManager, id, p.owner, p.lower, p.upper, p.salt);
        assertEq(actual, expectedLiquidity, "position liquidity");
        assertEq(f0, expectedF0, "feeGrowthInside0Last");
        assertEq(f1, expectedF1, "feeGrowthInside1Last");
        assertEq(
            PoolStateLib.positionLiquidity(poolManager, id, p.owner, p.lower, p.upper, p.salt),
            expectedLiquidity,
            "positionLiquidity"
        );
        liquidity_ = actual;
    }

    function _assertFeesOwedMatch(PoolId id, Pos memory p) private view {
        (uint256 owed0, uint256 owed1) = PoolStateLib.feesOwed(poolManager, id, p.owner, p.lower, p.upper, p.salt);
        (uint256 expectedOwed0, uint256 expectedOwed1) = _expectedFeesOwed(id, p);
        assertEq(owed0, expectedOwed0, "feesOwed0");
        assertEq(owed1, expectedOwed1, "feesOwed1");
    }

    function _assertFeeGrowthInsideMatches(PoolId id, int24 lower, int24 upper) private view {
        (uint256 expected0, uint256 expected1) = poolManager.getFeeGrowthInside(id, lower, upper);
        (uint256 inside0, uint256 inside1) = PoolStateLib.feeGrowthInside(poolManager, id, lower, upper);
        assertEq(inside0, expected0, "feeGrowthInside0");
        assertEq(inside1, expected1, "feeGrowthInside1");
    }

    /// @dev Returns true when the tick is initialised, so the caller can assert the sample is not all-empty. Split
    ///      into three helpers purely to stay inside the legacy pipeline's stack window.
    function _assertTickReadsMatch(PoolId id, int24 tick) private view returns (bool initialised) {
        assertEq(PoolStateLib.tickInfoSlot(id, tick), StateLibrary._getTickInfoSlot(id, tick), "tickInfoSlot");
        initialised = _assertTickInfoMatches(id, tick);
        _assertTickLiquidityMatches(id, tick);
        _assertTickFeeGrowthOutsideMatches(id, tick);
    }

    function _assertTickInfoMatches(PoolId id, int24 tick) private view returns (bool initialised) {
        (uint128 expectedGross, int128 expectedNet, uint256 expectedOut0, uint256 expectedOut1) =
            poolManager.getTickInfo(id, tick);
        (uint128 gross, int128 net, uint256 out0, uint256 out1) = PoolStateLib.tickInfo(poolManager, id, tick);
        assertEq(gross, expectedGross, "liquidityGross");
        assertEq(net, expectedNet, "liquidityNet");
        assertEq(out0, expectedOut0, "feeGrowthOutside0");
        assertEq(out1, expectedOut1, "feeGrowthOutside1");
        initialised = expectedGross != 0;
    }

    function _assertTickLiquidityMatches(PoolId id, int24 tick) private view {
        (uint128 gross, int128 net) = PoolStateLib.tickLiquidity(poolManager, id, tick);
        (uint128 expectedGross, int128 expectedNet) = poolManager.getTickLiquidity(id, tick);
        assertEq(gross, expectedGross, "tickLiquidity gross");
        assertEq(net, expectedNet, "tickLiquidity net");
    }

    function _assertTickFeeGrowthOutsideMatches(PoolId id, int24 tick) private view {
        (uint256 fee0, uint256 fee1) = PoolStateLib.tickFeeGrowthOutside(poolManager, id, tick);
        (uint256 expectedFee0, uint256 expectedFee1) = poolManager.getTickFeeGrowthOutside(id, tick);
        assertEq(fee0, expectedFee0, "tickFeeGrowthOutside0");
        assertEq(fee1, expectedFee1, "tickFeeGrowthOutside1");
    }

    /// @dev Returns true when the bitmap word is non-zero.
    function _assertBitmapMatches(PoolId id, int24 tick, int24 spacing) private view returns (bool nonZero) {
        int16 wordPos = int16((tick / spacing) >> 8);
        if (tick < 0 && tick % spacing != 0) wordPos = int16(((tick / spacing) - 1) >> 8);
        uint256 word = PoolStateLib.tickBitmap(poolManager, id, wordPos);
        assertEq(word, poolManager.getTickBitmap(id, wordPos), "tickBitmap word");
        nonZero = word != 0;
    }

    function _expectedFeesOwed(PoolId id, Pos memory p) private view returns (uint256 owed0, uint256 owed1) {
        (uint128 liquidity_, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(id, p.owner, p.lower, p.upper, p.salt);
        if (liquidity_ == 0) return (0, 0);
        (uint256 now0, uint256 now1) = poolManager.getFeeGrowthInside(id, p.lower, p.upper);
        unchecked {
            owed0 = FullMath.mulDiv(now0 - last0, liquidity_, FixedPoint128.Q128);
            owed1 = FullMath.mulDiv(now1 - last1, liquidity_, FixedPoint128.Q128);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Fixture
    // -------------------------------------------------------------------------------------------------------------

    function _seedHookedPool() private {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(hookedId);

        int24 wideLower = _align(tick - 5000, HOOKED_SPACING);
        int24 wideUpper = _align(tick + 5000, HOOKED_SPACING);
        _add(
            hookedKey,
            wideLower,
            wideUpper,
            bytes32(0),
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(wideLower),
                TickMath.getSqrtPriceAtTick(wideUpper),
                1_000_000e18,
                1_000_000e6
            )
        );

        int24 askLower = _align(tick + 1000, HOOKED_SPACING);
        int24 askUpper = _align(tick + 20_000, HOOKED_SPACING);
        uint160 askSqrtLower = TickMath.getSqrtPriceAtTick(askLower);
        uint160 askSqrtUpper = TickMath.getSqrtPriceAtTick(askUpper);
        _add(
            hookedKey,
            askLower,
            askUpper,
            bytes32(0),
            LiquidityAmounts.getLiquidityForAmount0(askSqrtLower, askSqrtUpper, 500_000e18)
        );
        // Same range, non-zero salt: a second, independent position at the PoolManager.
        _add(
            hookedKey,
            askLower,
            askUpper,
            SALT_ONE,
            LiquidityAmounts.getLiquidityForAmount0(askSqrtLower, askSqrtUpper, 100_000e18)
        );

        int24 bidLower = _align(tick - 30_000, HOOKED_SPACING);
        int24 bidUpper = _align(tick - 10_000, HOOKED_SPACING);
        _add(
            hookedKey,
            bidLower,
            bidUpper,
            bytes32(0),
            LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(bidLower), TickMath.getSqrtPriceAtTick(bidUpper), 100_000e6
            )
        );

        int24 minTick = TickMath.minUsableTick(HOOKED_SPACING);
        int24 maxTick = TickMath.maxUsableTick(HOOKED_SPACING);
        _add(hookedKey, minTick, minTick + HOOKED_SPACING * 100, bytes32(0), 1e6);
        _add(hookedKey, maxTick - HOOKED_SPACING * 100, maxTick, bytes32(0), 1e6);
    }

    function _seedBarePool() private {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(bareId);

        int24 lower = _align(tick - 6000, BARE_SPACING);
        int24 upper = _align(tick + 6000, BARE_SPACING);
        _add(
            bareKey,
            lower,
            upper,
            bytes32(0),
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(lower),
                TickMath.getSqrtPriceAtTick(upper),
                1_000_000e18,
                6000e18
            )
        );

        // The same range and salt, owned by a different account: two positions, not one.
        uint128 theirs = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), 200_000e18, 1200e18
        );
        secondLp.modifyLiquidity(bareKey, lower, upper, int256(uint256(theirs)), bytes32(0));
        positions.push(Pos({lower: lower, upper: upper, salt: bytes32(0), owner: address(secondLp), hooked: false}));

        int24 deepLower = _align(tick - 12_000, BARE_SPACING);
        int24 deepUpper = lower;
        uint128 deep = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(deepLower), TickMath.getSqrtPriceAtTick(deepUpper), 500e18
        );
        secondLp.modifyLiquidity(bareKey, deepLower, deepUpper, int256(uint256(deep)), SALT_TWO);
        positions.push(
            Pos({lower: deepLower, upper: deepUpper, salt: SALT_TWO, owner: address(secondLp), hooked: false})
        );
    }

    function _generateFees() private {
        _buy(hookedKey, 100_000e6);
        _sell(hookedKey, 200_000e18);
        _buy(bareKey, 500e18);
        _sell(bareKey, 50_000e18);
    }

    function _add(PoolKey memory key, int24 lower, int24 upper, bytes32 salt, uint128 liquidity_) private {
        require(liquidity_ != 0, "seed liquidity must be non-zero");
        poolManager.unlock(abi.encode(ACTION_MODIFY, key, lower, upper, int256(uint256(liquidity_)), salt));
        positions.push(
            Pos({
                lower: lower, upper: upper, salt: salt, owner: address(this), hooked: address(key.hooks) != address(0)
            })
        );
    }

    function _buy(PoolKey memory key, uint256 amountIn) private {
        swapRouter.swapExactTokensForTokens(amountIn, 0, false, key, "", address(this), block.timestamp + 1);
    }

    function _sell(PoolKey memory key, uint256 amountIn) private {
        swapRouter.swapExactTokensForTokens(amountIn, 0, true, key, "", address(this), block.timestamp + 1);
    }

    /// @dev Walks the pool to (approximately) `targetTick` through a third-party swapper, so the price is set by a
    ///      price limit rather than by guessing an input size.
    function _moveTickTo(PoolKey memory key, int24 targetTick) private {
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        if (targetTick == tick) return;
        bool zeroForOne = targetTick < tick;
        swapper.swapToPrice(key, zeroForOne, -type(int128).max, TickMath.getSqrtPriceAtTick(targetTick));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "unlockCallback: not the PoolManager");
        (uint8 action, PoolKey memory key, int24 lower, int24 upper, int256 liquidityDelta, bytes32 salt) =
            abi.decode(data, (uint8, PoolKey, int24, int24, int256, bytes32));

        if (action == ACTION_PROBE_TRANSIENT) {
            _probeTransient(key);
            return "";
        }

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: salt}),
            ""
        );
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    /// @dev Every `exttload` assertion lives here, inside the one call frame that holds the lock.
    function _probeTransient(PoolKey memory key) private {
        assertTrue(PoolStateLib.isUnlocked(poolManager), "unlocked inside the callback");
        assertEq(PoolStateLib.isUnlocked(poolManager), poolManager.isUnlocked(), "isUnlocked inside");
        assertEq(PoolStateLib.nonzeroDeltaCount(poolManager), poolManager.getNonzeroDeltaCount(), "count on entry");
        assertEq(PoolStateLib.nonzeroDeltaCount(poolManager), 0, "no deltas yet");

        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        int24 lower = _align(tick - 600, HOOKED_SPACING);
        int24 upper = _align(tick + 600, HOOKED_SPACING);
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int256(1e18), salt: bytes32(0)}),
            ""
        );

        assertEq(PoolStateLib.nonzeroDeltaCount(poolManager), poolManager.getNonzeroDeltaCount(), "count with deltas");
        assertGt(PoolStateLib.nonzeroDeltaCount(poolManager), 0, "deltas are open");

        int256 delta0 = PoolStateLib.currencyDelta(poolManager, address(this), key.currency0);
        int256 delta1 = PoolStateLib.currencyDelta(poolManager, address(this), key.currency1);
        assertEq(delta0, poolManager.currencyDelta(address(this), key.currency0), "currencyDelta0");
        assertEq(delta1, poolManager.currencyDelta(address(this), key.currency1), "currencyDelta1");
        assertLt(delta0, 0, "we owe currency0");
        assertLt(delta1, 0, "we owe currency1");
        assertEq(delta0, int256(delta.amount0()), "delta0 equals the reported balance delta");
        assertEq(delta1, int256(delta.amount1()), "delta1 equals the reported balance delta");

        // An account with nothing open reads zero, through both libraries.
        assertEq(PoolStateLib.currencyDelta(poolManager, address(0xDEAD), key.currency0), 0, "stranger delta");
        assertEq(
            PoolStateLib.currencyDelta(poolManager, address(0xDEAD), key.currency0),
            poolManager.currencyDelta(address(0xDEAD), key.currency0),
            "stranger delta agrees"
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());

        assertEq(PoolStateLib.nonzeroDeltaCount(poolManager), 0, "settled");
        assertEq(PoolStateLib.nonzeroDeltaCount(poolManager), poolManager.getNonzeroDeltaCount(), "settled agrees");
        transientProbeRan = true;
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

    function _align(int24 tick, int24 spacing) private pure returns (int24 aligned) {
        aligned = (tick / spacing) * spacing;
        if (tick < 0 && tick % spacing != 0) aligned -= spacing;
    }

    function _sqrtPriceX96(uint256 num, uint256 den) private pure returns (uint160) {
        uint256 ratioX96 = FullMath.mulDiv(num, 1 << 96, den);
        return uint160(FixedPointMathLib.sqrt(ratioX96 << 96));
    }
}
