// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolRegistry} from "../../src/interfaces/IPoolRegistry.sol";
import {LadderLib} from "../../src/lib/LadderLib.sol";
import {PoolStateLib} from "../../src/lib/PoolStateLib.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {ZeroAddress} from "../../src/types/Errors.sol";
import {PoolClass, PoolConfig} from "../../src/types/Types.sol";
import {LadderPositionValuer} from "../../src/valuer/LadderPositionValuer.sol";
import {LadderRegistryStub} from "../mocks/LadderRegistryStub.sol";
import {LadderSwapper} from "../mocks/LadderSwapper.sol";
import {PoolStateLp} from "../mocks/PoolStateLp.sol";
import {V4TestBase} from "../utils/V4TestBase.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title LadderPositionValuerTest
/// @notice The Phase 3 position valuer against a live local pool: grid enumeration, the three decomposition
///         branches, one-directional rounding, `totalLiquidity`, invariant **I7** and the worst-case gas bound.
///
/// @dev The test contract plays the **vault**: it owns every grid position at the PoolManager. A separate
///      `LadderSwapper` moves the price, so the vault's own idle balances never change and the I7 assertion is
///      about positions and nothing else.
contract LadderPositionValuerTest is V4TestBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Three leading zero bytes, so AMPS is `currency0`.
    address internal constant AMPS_ADDRESS = 0x0000001234567890123456789012345678901234;
    address internal constant USDG_ADDRESS = 0x1111111111111111111111111111111111111111;

    int24 internal constant SPACING = 10;
    int24 internal constant EMPTY_SPACING = 60;
    uint8 internal constant USDG_DECIMALS = 6;
    /// @dev USDG at $1.00, in Chainlink's 8-decimal scale.
    uint256 internal constant USDG_PRICE_USD8 = 1e8;

    /// @dev `sqrt(1.5)` and `sqrt(0.5)` in 1e18 fixed point: the sqrt-price multipliers for a +50% / -50% move.
    uint256 internal constant SQRT_1_5_X18 = 1_224_744_871_391_589_049;
    uint256 internal constant SQRT_0_5_X18 = 707_106_781_186_547_524;

    /// @dev +50% in price is +4054.65 ticks, -50% is -6931.5; the swaps must clear those.
    int24 internal constant TICKS_UP_50 = 4054;
    int24 internal constant TICKS_DOWN_50 = -6931;

    uint256 internal constant CELL_AMPS = 10_000e18;
    uint256 internal constant CELL_USDG = 1000e6;

    uint8 internal constant ACTION_MODIFY = 0;

    MockERC20 internal amps;
    MockERC20 internal usdg;
    LadderRegistryStub internal registry;
    LadderPositionValuer internal valuer;
    LadderSwapper internal swapper;
    PoolStateLp internal otherLp;

    PoolKey internal key;
    PoolId internal id;
    PoolKey internal emptyKey;
    PoolId internal emptyId;

    int24 internal gridBase;
    int24 internal width;

    function setUp() public {
        deployV4();

        amps = deployTokenAt(AMPS_ADDRESS, "Amplestocks", "AMPS", 18);
        usdg = deployTokenAt(USDG_ADDRESS, "Global Dollar", "USDG", USDG_DECIMALS);

        key = _poolKey(SPACING);
        emptyKey = _poolKey(EMPTY_SPACING);
        id = key.toId();
        emptyId = emptyKey.toId();

        // AMPS $1.00 against 6-decimal USDG: raw amount1/amount0 == 1e6 / 1e18.
        poolManager.initialize(key, _sqrtPriceX96(1e6, 1e18));
        poolManager.initialize(emptyKey, _sqrtPriceX96(1e6, 1e18));

        (, int24 tick,,) = poolManager.getSlot0(id);
        gridBase = PriceLib.alignTick(tick, SPACING, true);
        width = LadderLib.doublingTicks(SPACING);

        registry = new LadderRegistryStub();
        registry.setPool(id, USDG_ADDRESS, USDG_DECIMALS, SPACING, gridBase);
        registry.setPool(emptyId, USDG_ADDRESS, USDG_DECIMALS, EMPTY_SPACING, gridBase);

        valuer =
            new LadderPositionValuer(IExtsload(address(poolManager)), address(this), IPoolRegistry(address(registry)));
        vm.label(address(valuer), "LadderPositionValuer");

        swapper = new LadderSwapper(poolManager);
        amps.transfer(address(swapper), 2_000_000e18);
        usdg.transfer(address(swapper), 2_000_000e6);

        otherLp = new PoolStateLp(poolManager);
        amps.transfer(address(otherLp), 100_000e18);
        usdg.transfer(address(otherLp), 100_000e6);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Shape
    // -------------------------------------------------------------------------------------------------------------

    function test_versionAndImmutables() public view {
        assertEq(valuer.version(), bytes32("ladder-grid-valuer-v1"), "version");
        assertEq(address(valuer.poolManager()), address(poolManager), "poolManager");
        assertEq(valuer.vault(), address(this), "vault");
        assertEq(address(valuer.registry()), address(registry), "registry");
        assertEq(Constants.GRID_CELLS, 24, "24 cells");
        assertEq(Constants.GRID_MAX_M - Constants.GRID_MIN_M, int24(uint24(Constants.GRID_CELLS)), "cell count");
        assertEq(Constants.POSITION_SALT, bytes32(0), "ruling 12: salt is always zero");
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ZeroAddress.selector);
        new LadderPositionValuer(IExtsload(address(0)), address(this), IPoolRegistry(address(registry)));
        vm.expectRevert(ZeroAddress.selector);
        new LadderPositionValuer(IExtsload(address(poolManager)), address(0), IPoolRegistry(address(registry)));
        vm.expectRevert(ZeroAddress.selector);
        new LadderPositionValuer(IExtsload(address(poolManager)), address(this), IPoolRegistry(address(0)));
    }

    // -------------------------------------------------------------------------------------------------------------
    // Empty and degenerate pools
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A registered pool the vault has never placed into is worth zero, in both currencies.
    function test_emptyPoolReturnsZeros() public view {
        (uint256 amount0, uint256 amount1) = valuer.valuePool(emptyId, _sqrtAt(gridBase));
        assertEq(amount0, 0, "amount0");
        assertEq(amount1, 0, "amount1");
        assertEq(valuer.totalLiquidity(emptyId), 0, "totalLiquidity");
    }

    /// @notice An unregistered pool is worth zero rather than a revert: the valuer is never gated (ruling 7).
    function test_unregisteredPoolReturnsZeros() public view {
        PoolId ghost = PoolId.wrap(keccak256("not a registered pool"));
        (uint256 amount0, uint256 amount1) = valuer.valuePool(ghost, _sqrtAt(0));
        assertEq(amount0 | amount1, 0, "zeros");
        assertEq(valuer.totalLiquidity(ghost), 0, "totalLiquidity");
    }

    /// @notice A registered pool with a nonsensical tick spacing is worth zero rather than reverting inside
    ///         `LadderLib.doublingTicks`.
    function test_malformedTickSpacingReturnsZeros() public {
        PoolId broken = PoolId.wrap(keccak256("broken spacing"));
        registry.setPoolConfig(
            broken,
            PoolConfig({
                counter: USDG_ADDRESS,
                poolClass: PoolClass.ENTRY,
                counterDecimals: USDG_DECIMALS,
                tickSpacing: 0,
                buyFeeBps: 30,
                constituentId: 0,
                registered: true,
                gridBaseTick: 0
            })
        );
        (uint256 amount0, uint256 amount1) = valuer.valuePool(broken, _sqrtAt(0));
        assertEq(amount0 | amount1, 0, "zeros");
        assertEq(valuer.totalLiquidity(broken), 0, "totalLiquidity");
    }

    /// @notice A zero reference price is worth zero: `A` is left to the previous checkpoint rather than valued at
    ///         a price of zero.
    function test_zeroReferencePriceReturnsZeros() public {
        _populateWholeGrid();
        (uint256 amount0, uint256 amount1) = valuer.valuePool(id, 0);
        assertEq(amount0 | amount1, 0, "zeros");
        assertGt(valuer.totalLiquidity(id), 0, "but the liquidity is really there");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Decomposition, branch by branch
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Reference **below** the cell: the position is entirely currency0 (an unfilled ask), matching the
    ///         hand-computed `L * (sqrtU - sqrtL) * 2**96 / (sqrtL * sqrtU)` to the wei.
    function test_decompositionBelowTheRange() public {
        (int24 lower, int24 upper) = _cellBounds(3);
        uint128 liquidity = _populateCell(3);
        uint160 sqrtLower = _sqrtAt(lower);
        uint160 sqrtUpper = _sqrtAt(upper);

        // Strictly below, and exactly at the lower bound: the same branch.
        uint160[2] memory refs = [_sqrtAt(lower - 5 * SPACING), sqrtLower];
        for (uint256 i; i < refs.length; ++i) {
            (uint256 amount0, uint256 amount1) = valuer.valuePool(id, refs[i]);
            assertEq(amount1, 0, "no counter asset below the range");
            assertEq(amount0, _exactAmount0(sqrtLower, sqrtUpper, liquidity), "hand-computed amount0");
            assertEq(amount0, LadderLib.amount0ForLiquidity(sqrtLower, sqrtUpper, liquidity), "vs LadderLib");
            assertGt(amount0, 0, "the cell holds AMPS");
        }
    }

    /// @notice Reference **above** the cell: the position is entirely currency1, matching
    ///         `L * (sqrtU - sqrtL) / 2**96` to the wei.
    function test_decompositionAboveTheRange() public {
        (int24 lower, int24 upper) = _cellBounds(-3);
        uint128 liquidity = _populateCell(-3);
        uint160 sqrtLower = _sqrtAt(lower);
        uint160 sqrtUpper = _sqrtAt(upper);

        uint160[2] memory refs = [sqrtUpper, _sqrtAt(upper + 5 * SPACING)];
        for (uint256 i; i < refs.length; ++i) {
            (uint256 amount0, uint256 amount1) = valuer.valuePool(id, refs[i]);
            assertEq(amount0, 0, "no AMPS above the range");
            assertEq(amount1, _exactAmount1(sqrtLower, sqrtUpper, liquidity), "hand-computed amount1");
            assertEq(amount1, LadderLib.amount1ForLiquidity(sqrtLower, sqrtUpper, liquidity), "vs LadderLib");
            assertGt(amount1, 0, "the cell holds USDG");
        }
    }

    /// @notice Reference **inside** the cell: the position splits, `[ref, upper]` in currency0 and `[lower, ref]`
    ///         in currency1, both hand-computed.
    function test_decompositionInsideTheRange() public {
        (int24 lower, int24 upper) = _cellBounds(2);
        uint128 liquidity = _populateCell(2);
        uint160 sqrtLower = _sqrtAt(lower);
        uint160 sqrtUpper = _sqrtAt(upper);
        uint160 sqrtRef = _sqrtAt(lower + width / 2);

        (uint256 amount0, uint256 amount1) = valuer.valuePool(id, sqrtRef);
        assertEq(amount0, _exactAmount0(sqrtRef, sqrtUpper, liquidity), "hand-computed amount0");
        assertEq(amount1, _exactAmount1(sqrtLower, sqrtRef, liquidity), "hand-computed amount1");
        assertGt(amount0, 0, "AMPS above the reference");
        assertGt(amount1, 0, "USDG below the reference");

        // The two halves never exceed the whole: valuing the same cell fully below and fully above bounds them.
        (uint256 wholeAmount0,) = valuer.valuePool(id, sqrtLower);
        (, uint256 wholeAmount1) = valuer.valuePool(id, sqrtUpper);
        assertLt(amount0, wholeAmount0, "part of the AMPS has been converted");
        assertLt(amount1, wholeAmount1, "part of the counter asset has not been raised yet");
    }

    /// @notice A liquidity round trip through `LiquidityAmounts` recovers at most the liquidity we placed: the
    ///         valuer's amounts are the floored inverse of the placement maths, never more.
    function test_amountsRoundTripThroughLiquidityAmounts() public {
        (int24 lower, int24 upper) = _cellBounds(4);
        uint128 liquidity = _populateCell(4);
        uint160 sqrtLower = _sqrtAt(lower);
        uint160 sqrtUpper = _sqrtAt(upper);

        (uint256 amount0,) = valuer.valuePool(id, sqrtLower);
        assertLe(
            LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount0),
            liquidity,
            "amount0 -> liquidity never exceeds what was placed"
        );

        (int24 bidLower, int24 bidUpper) = _cellBounds(-4);
        uint128 bidLiquidity = _populateCell(-4);
        (, uint256 amount1) = valuer.valuePool(id, _sqrtAt(bidUpper));
        // Cell 4's AMPS is entirely above `bidUpper`, so `amount1` is cell -4's alone.
        assertLe(
            LiquidityAmounts.getLiquidityForAmount1(_sqrtAt(bidLower), _sqrtAt(bidUpper), amount1),
            bidLiquidity,
            "amount1 -> liquidity never exceeds what was placed"
        );
    }

    /// @notice Rounding is one-directional: every amount equals the floored formula and is at most the rounded-up
    ///         one, for a fuzzed reference price anywhere across the cell.
    function testFuzz_roundingIsAlwaysDown(uint256 offset) public {
        (int24 lower, int24 upper) = _cellBounds(1);
        uint128 liquidity = _populateCell(1);
        uint160 sqrtLower = _sqrtAt(lower);
        uint160 sqrtUpper = _sqrtAt(upper);
        uint160 sqrtRef = uint160(bound(offset, uint256(sqrtLower), uint256(sqrtUpper)));

        (uint256 amount0, uint256 amount1) = valuer.valuePool(id, sqrtRef);

        uint256 expected0;
        uint256 expected1;
        uint256 up0;
        uint256 up1;
        if (sqrtRef <= sqrtLower) {
            expected0 = _exactAmount0(sqrtLower, sqrtUpper, liquidity);
            up0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (sqrtRef >= sqrtUpper) {
            expected1 = _exactAmount1(sqrtLower, sqrtUpper, liquidity);
            up1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else {
            expected0 = _exactAmount0(sqrtRef, sqrtUpper, liquidity);
            expected1 = _exactAmount1(sqrtLower, sqrtRef, liquidity);
            up0 = SqrtPriceMath.getAmount0Delta(sqrtRef, sqrtUpper, liquidity, true);
            up1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtRef, liquidity, true);
        }
        assertEq(amount0, expected0, "amount0 floored");
        assertEq(amount1, expected1, "amount1 floored");
        assertLe(amount0, up0, "amount0 never rounds up");
        assertLe(amount1, up1, "amount1 never rounds up");
    }

    /// @notice `amount1` is non-decreasing and `amount0` non-increasing as the reference price rises: a ladder is
    ///         converted from AMPS into counter asset from the bottom up.
    function testFuzz_valuationIsMonotoneInTheReference(uint256 lowSeed, uint256 highSeed) public {
        _populateWholeGrid();
        uint160 floorSqrt = _sqrtAt(_cellLower(Constants.GRID_MIN_M));
        uint160 ceilSqrt = _sqrtAt(_cellLower(Constants.GRID_MAX_M));
        uint160 low = uint160(bound(lowSeed, uint256(floorSqrt), uint256(ceilSqrt)));
        uint160 high = uint160(bound(highSeed, uint256(low), uint256(ceilSqrt)));

        (uint256 low0, uint256 low1) = valuer.valuePool(id, low);
        (uint256 high0, uint256 high1) = valuer.valuePool(id, high);
        assertLe(high0, low0, "amount0 non-increasing in the reference price");
        assertGe(high1, low1, "amount1 non-decreasing in the reference price");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Grid enumeration
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `totalLiquidity` is exactly the sum of the 24 grid positions the PoolManager reports.
    function test_totalLiquidityMatchesTheGrid() public {
        _populateWholeGrid();

        uint256 expected;
        uint256 populated;
        for (int24 m = Constants.GRID_MIN_M; m < Constants.GRID_MAX_M; ++m) {
            (int24 lower, int24 upper) = _cellBounds(m);
            uint128 liquidity = poolManager.getPositionLiquidity(
                id, Position.calculatePositionKey(address(this), lower, upper, bytes32(0))
            );
            expected += liquidity;
            if (liquidity != 0) ++populated;
        }
        assertEq(populated, Constants.GRID_CELLS, "every cell populated");
        assertEq(valuer.totalLiquidity(id), uint128(expected), "totalLiquidity");
        assertGt(valuer.totalLiquidity(id), 0, "non-trivial");
    }

    /// @notice A vault position that is **not** on the grid is invisible to the valuer. I39 says one cannot exist;
    ///         this pins the consequence if one ever did.
    function test_offGridPositionsAreIgnored() public {
        _populateWholeGrid();
        (uint256 before0, uint256 before1) = valuer.valuePool(id, _sqrtAt(gridBase));
        uint128 beforeLiquidity = valuer.totalLiquidity(id);

        // Deliberately off-lattice: the grid's cells all start at `gridBase + m*width`.
        int24 lower = gridBase + width / 2;
        int24 upper = lower + width;
        _add(
            key,
            lower,
            upper,
            bytes32(0),
            LiquidityAmounts.getLiquidityForAmount0(_sqrtAt(lower), _sqrtAt(upper), CELL_AMPS)
        );

        (uint256 after0, uint256 after1) = valuer.valuePool(id, _sqrtAt(gridBase));
        assertEq(after0, before0, "amount0 unchanged");
        assertEq(after1, before1, "amount1 unchanged");
        assertEq(valuer.totalLiquidity(id), beforeLiquidity, "totalLiquidity unchanged");
    }

    /// @notice A position on a grid cell opened with a non-zero salt is a different position and is not counted:
    ///         ruling 12 makes `bytes32(0)` the only salt the vault may ever use.
    function test_nonZeroSaltIsIgnored() public {
        _populateWholeGrid();
        (uint256 before0, uint256 before1) = valuer.valuePool(id, _sqrtAt(gridBase));

        (int24 lower, int24 upper) = _cellBounds(3);
        _add(
            key,
            lower,
            upper,
            keccak256("a salt the vault must never use"),
            LiquidityAmounts.getLiquidityForAmount0(_sqrtAt(lower), _sqrtAt(upper), CELL_AMPS)
        );

        (uint256 after0, uint256 after1) = valuer.valuePool(id, _sqrtAt(gridBase));
        assertEq(after0, before0, "amount0 unchanged");
        assertEq(after1, before1, "amount1 unchanged");
    }

    /// @notice Another account's position on a grid cell is not the vault's, and is not counted.
    function test_otherOwnersAreIgnored() public {
        _populateWholeGrid();
        (uint256 before0, uint256 before1) = valuer.valuePool(id, _sqrtAt(gridBase));

        (int24 lower, int24 upper) = _cellBounds(4);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(_sqrtAt(lower), _sqrtAt(upper), 5000e18);
        otherLp.modifyLiquidity(key, lower, upper, int256(uint256(liquidity)), bytes32(0));
        assertGt(
            poolManager.getPositionLiquidity(
                id, Position.calculatePositionKey(address(otherLp), lower, upper, bytes32(0))
            ),
            0,
            "the other LP really has a position there"
        );

        (uint256 after0, uint256 after1) = valuer.valuePool(id, _sqrtAt(gridBase));
        assertEq(after0, before0, "amount0 unchanged");
        assertEq(after1, before1, "amount1 unchanged");
    }

    /// @notice The enumeration walks exactly `[GRID_MIN_M, GRID_MAX_M)` — one cell below and one cell above the
    ///         grid are outside it, whatever they hold.
    function test_cellsOutsideTheGridAreNotEnumerated() public {
        _populateWholeGrid();
        (uint256 before0, uint256 before1) = valuer.valuePool(id, _sqrtAt(gridBase));

        (int24 belowLower, int24 belowUpper) = _cellBounds(Constants.GRID_MIN_M - 1);
        _add(
            key,
            belowLower,
            belowUpper,
            bytes32(0),
            LiquidityAmounts.getLiquidityForAmount1(_sqrtAt(belowLower), _sqrtAt(belowUpper), CELL_USDG)
        );
        (int24 aboveLower, int24 aboveUpper) = _cellBounds(Constants.GRID_MAX_M);
        _add(
            key,
            aboveLower,
            aboveUpper,
            bytes32(0),
            LiquidityAmounts.getLiquidityForAmount0(_sqrtAt(aboveLower), _sqrtAt(aboveUpper), CELL_AMPS)
        );

        (uint256 after0, uint256 after1) = valuer.valuePool(id, _sqrtAt(gridBase));
        assertEq(after0, before0, "amount0 unchanged");
        assertEq(after1, before1, "amount1 unchanged");
    }

    /// @notice A grid whose cells run past `MAX_TICK` is skipped rather than reverting inside `TickMath`. The
    ///         PoolManager cannot hold such a position, so the guard is proved by writing one into its storage
    ///         directly.
    function test_gridCellsOutsideTheTickRangeAreSkipped() public {
        PoolId extreme = PoolId.wrap(keccak256("grid at the tick ceiling"));
        int24 hugeSpacing = TickMath.MAX_TICK_SPACING;
        int24 base = TickMath.maxUsableTick(hugeSpacing);
        registry.setPool(extreme, USDG_ADDRESS, USDG_DECIMALS, hugeSpacing, base);

        int24 cellWidth = LadderLib.doublingTicks(hugeSpacing);
        int24 outOfRangeLower = base + 15 * cellWidth;
        assertGt(int256(outOfRangeLower) + int256(cellWidth), int256(TickMath.MAX_TICK), "cell really is past MAX_TICK");

        bytes32 slot =
            PoolStateLib.positionSlot(extreme, address(this), outOfRangeLower, outOfRangeLower + cellWidth, bytes32(0));
        vm.store(address(poolManager), slot, bytes32(uint256(1e18)));
        assertEq(
            PoolStateLib.positionLiquidity(
                poolManager, extreme, address(this), outOfRangeLower, outOfRangeLower + cellWidth, bytes32(0)
            ),
            1e18,
            "the forged liquidity is readable"
        );

        (uint256 amount0, uint256 amount1) = valuer.valuePool(extreme, _sqrtAt(0));
        assertEq(amount0 | amount1, 0, "an unplaceable cell contributes nothing");
        assertEq(valuer.totalLiquidity(extreme), 1e18, "totalLiquidity still sums the raw words");
    }

    // -------------------------------------------------------------------------------------------------------------
    // I7
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **I7.** Forcing `slot0` +50% and then -50% moves the valuation at the fixed reference price by
    ///         exactly zero, and the NAV numerator `A` computed the way `VaultNavLib` computes it by zero dust.
    function test_i7_forcingSlot0FiftyPercentDoesNotMoveTheValuation() public {
        _populateWholeGrid();

        uint160 sqrtRef = _sqrtAt(gridBase);
        (uint160 sqrtStart, int24 tickStart,,) = poolManager.getSlot0(id);
        (uint256 base0, uint256 base1) = valuer.valuePool(id, sqrtRef);
        uint256 baseA = _navNumeratorUsd18(base1);
        assertGt(base0, 0, "the ladder holds AMPS");
        assertGt(base1, 0, "the ladder holds USDG");
        assertGt(baseA, 0, "A is non-trivial");

        // +50% in price.
        swapper.swapToPrice(key, false, -type(int128).max, _scaleSqrt(sqrtStart, SQRT_1_5_X18));
        (, int24 tickUp,,) = poolManager.getSlot0(id);
        assertGe(tickUp - tickStart, TICKS_UP_50, "slot0 moved at least +50%");
        (uint256 up0, uint256 up1) = valuer.valuePool(id, sqrtRef);
        assertEq(up0, base0, "amount0 unmoved by slot0");
        assertEq(up1, base1, "amount1 unmoved by slot0");
        assertEq(_navNumeratorUsd18(up1), baseA, "A unmoved by slot0");

        // -50% in price, measured from the original price.
        swapper.swapToPrice(key, true, -type(int128).max, _scaleSqrt(sqrtStart, SQRT_0_5_X18));
        (, int24 tickDown,,) = poolManager.getSlot0(id);
        assertLe(tickDown - tickStart, TICKS_DOWN_50, "slot0 moved at least -50%");
        (uint256 down0, uint256 down1) = valuer.valuePool(id, sqrtRef);
        assertEq(down0, base0, "amount0 unmoved by slot0");
        assertEq(down1, base1, "amount1 unmoved by slot0");
        assertApproxEqAbs(_navNumeratorUsd18(down1), baseA, 1, "A unmoved by slot0, to the dust");
    }

    /// @notice The same, one step finer: the swaps really do accrue fee growth, and the valuer still ignores it —
    ///         uncollected fees are excluded from `A` on purpose (§4).
    function test_i7_accruedFeesDoNotEnterTheValuation() public {
        _populateWholeGrid();
        uint160 sqrtRef = _sqrtAt(gridBase);
        (uint256 base0, uint256 base1) = valuer.valuePool(id, sqrtRef);

        (uint160 sqrtStart,,,) = poolManager.getSlot0(id);
        swapper.swapToPrice(key, false, -type(int128).max, _scaleSqrt(sqrtStart, SQRT_1_5_X18));
        swapper.swapToPrice(key, true, -type(int128).max, sqrtStart);

        (uint256 feeGrowth0, uint256 feeGrowth1) = PoolStateLib.feeGrowthGlobals(poolManager, id);
        assertTrue(feeGrowth0 != 0 || feeGrowth1 != 0, "the round trip paid fees");

        (uint256 after0, uint256 after1) = valuer.valuePool(id, sqrtRef);
        assertEq(after0, base0, "amount0 excludes uncollected fees");
        assertEq(after1, base1, "amount1 excludes uncollected fees");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Gas
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Worst case: all 24 grid cells populated, the reference price inside one of them (so the straddle
    ///         branch runs), every slot cold. This is the number quoted in `LadderPositionValuer`'s NatSpec and
    ///         the per-pool term of `checkpoint()`'s cost.
    function test_gasWorstCaseEveryCellPopulated() public {
        _populateWholeGrid();
        uint160 sqrtRef = _sqrtAt(gridBase + width / 2);

        _cool();
        uint256 start = gasleft();
        (uint256 amount0, uint256 amount1) = valuer.valuePool(id, sqrtRef);
        uint256 fullGas = start - gasleft();

        _cool();
        start = gasleft();
        valuer.valuePool(emptyId, sqrtRef);
        uint256 emptyGas = start - gasleft();

        _cool();
        start = gasleft();
        valuer.totalLiquidity(id);
        uint256 totalLiquidityGas = start - gasleft();

        console.log("valuePool, 24/24 cells populated, cold:", fullGas);
        console.log("valuePool, empty pool, cold:          ", emptyGas);
        console.log("totalLiquidity, 24/24 cells, cold:    ", totalLiquidityGas);
        console.log("32-pool checkpoint() worst case:      ", fullGas * 32);

        assertGt(amount0, 0, "the measurement valued something");
        assertGt(amount1, 0, "both sides of the straddle");
        assertLt(fullGas, 200_000, "worst-case valuePool budget, per pool (measured ~152k cold)");
        assertLt(fullGas * 32, 6_400_000, "a 32-pool checkpoint stays inside a block");
        assertLt(emptyGas, 140_000, "an empty pool still pays 24 cold SLOADs of zero (measured ~101k)");
    }

    /// @notice The loop is grid-bounded (ruling 7): filling every cell costs a bounded multiple of an empty pool,
    ///         and nothing a third party does can lengthen it.
    function test_workIsGridBounded() public {
        _cool();
        uint256 start = gasleft();
        valuer.valuePool(id, _sqrtAt(gridBase));
        uint256 emptyGas = start - gasleft();

        _populateWholeGrid();
        // A third party spraying positions across the pool changes nothing about the work.
        for (int24 m = Constants.GRID_MIN_M; m < Constants.GRID_MAX_M; ++m) {
            if (m % 4 != 0) continue;
            (int24 lower, int24 upper) = _cellBounds(m);
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                _sqrtAt(gridBase), _sqrtAt(lower), _sqrtAt(upper), 1000e18, 100e6
            );
            if (liquidity != 0) otherLp.modifyLiquidity(key, lower, upper, int256(uint256(liquidity)), bytes32(0));
        }

        _cool();
        start = gasleft();
        valuer.valuePool(id, _sqrtAt(gridBase + width / 2));
        uint256 fullGas = start - gasleft();

        assertLt(fullGas, emptyGas * 4, "a full grid is a small multiple of an empty one");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `A` the way `VaultNavLib.totalAssetsUsd18` computes it for a single pool: the vault's ERC-6909 claim,
    ///      its idle ERC-20 balance and the valuer's `amount1`, priced through `PriceLib.counterValueUsd18`.
    ///      Every AMPS leg is worth zero (I5), so `amount0` never appears.
    function _navNumeratorUsd18(uint256 amount1) private view returns (uint256 usd18) {
        uint256 balance = poolManager.balanceOf(address(this), uint256(uint160(USDG_ADDRESS)))
            + usdg.balanceOf(address(this)) + amount1;
        usd18 = PriceLib.counterValueUsd18(balance, USDG_DECIMALS, USDG_PRICE_USD8);
    }

    function _cellLower(int24 m) private view returns (int24 lower) {
        lower = int24(int256(gridBase) + int256(m) * int256(width));
    }

    function _cellBounds(int24 m) private view returns (int24 lower, int24 upper) {
        lower = _cellLower(m);
        upper = lower + width;
    }

    function _populateWholeGrid() private {
        for (int24 m = Constants.GRID_MIN_M; m < Constants.GRID_MAX_M; ++m) {
            _populateCell(m);
        }
    }

    /// @dev Places `CELL_AMPS` / `CELL_USDG` into grid cell `m` as the vault, whichever side the cell needs.
    function _populateCell(int24 m) private returns (uint128 liquidity) {
        (int24 lower, int24 upper) = _cellBounds(m);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, _sqrtAt(lower), _sqrtAt(upper), CELL_AMPS, CELL_USDG);
        require(liquidity != 0, "cell liquidity must be non-zero");
        _add(key, lower, upper, bytes32(0), liquidity);
    }

    function _add(PoolKey memory poolKey, int24 lower, int24 upper, bytes32 salt, uint128 liquidity) private {
        poolManager.unlock(abi.encode(ACTION_MODIFY, poolKey, lower, upper, int256(uint256(liquidity)), salt));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "unlockCallback: not the PoolManager");
        (, PoolKey memory poolKey, int24 lower, int24 upper, int256 liquidityDelta, bytes32 salt) =
            abi.decode(data, (uint8, PoolKey, int24, int24, int256, bytes32));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: salt}),
            ""
        );
        _settle(poolKey.currency0, delta.amount0());
        _settle(poolKey.currency1, delta.amount1());
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

    /// @dev `L * (sqrtU - sqrtL) * 2**96 / (sqrtL * sqrtU)`, floored — v4's `getAmount0Delta(..., false)` written
    ///      out so the assertion is against arithmetic rather than against the same call.
    function _exactAmount0(uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity) private pure returns (uint256) {
        uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;
        return FullMath.mulDiv(numerator1, sqrtUpper - sqrtLower, sqrtUpper) / sqrtLower;
    }

    /// @dev `L * (sqrtU - sqrtL) / 2**96`, floored.
    function _exactAmount1(uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity) private pure returns (uint256) {
        return FullMath.mulDiv(liquidity, sqrtUpper - sqrtLower, FixedPoint96.Q96);
    }

    function _scaleSqrt(uint160 sqrtPriceX96, uint256 multiplierX18) private pure returns (uint160) {
        return uint160(FullMath.mulDiv(sqrtPriceX96, multiplierX18, 1e18));
    }

    function _sqrtAt(int24 tick) private pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function _poolKey(int24 tickSpacing) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(AMPS_ADDRESS),
            currency1: Currency.wrap(USDG_ADDRESS),
            fee: 3000,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function _sqrtPriceX96(uint256 num, uint256 den) private pure returns (uint160) {
        uint256 ratioX96 = FullMath.mulDiv(num, 1 << 96, den);
        return uint160(FixedPointMathLib.sqrt(ratioX96 << 96));
    }

    /// @dev Makes the whole v4 stack and both tokens cold again, so a gas measurement prices the cold `SLOAD`s a
    ///      real `checkpoint()` would pay.
    function _cool() private {
        vm.cool(address(poolManager));
        vm.cool(address(valuer));
        vm.cool(address(registry));
        vm.cool(AMPS_ADDRESS);
        vm.cool(USDG_ADDRESS);
    }
}
