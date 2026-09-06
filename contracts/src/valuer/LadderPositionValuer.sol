// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {IPositionValuer} from "../interfaces/IPositionValuer.sol";
import {LadderLib} from "../lib/LadderLib.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {Constants} from "../types/Constants.sol";
import {ZeroAddress} from "../types/Errors.sol";
import {PoolConfig} from "../types/Types.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title LadderPositionValuer
/// @notice The Phase 3 third term of the NAV numerator: what the vault's Uniswap v4 ladder positions are worth,
///         decomposed at the **reference** sqrt price rather than at `slot0`. Replaces `ZeroPositionValuer` under
///         the 7-day pointer swap; nothing about the vault's storage, its NAV formula or its invariants changes.
///
/// @dev **It enumerates the canonical grid, not the vault's records.** Every vault position in a pool lies on that
///      pool's doubling grid (`docs/phase3-state-model.md` §3.2, ruling 1): cell `m` covers
///      `[gridBaseTick + m*D, gridBaseTick + (m+1)*D)` with `D = LadderLib.doublingTicks(tickSpacing)` and `m` in
///      `[Constants.GRID_MIN_M, Constants.GRID_MAX_M)`, all `GRID_CELLS == 24` of them opened with
///      `salt == bytes32(0)` (ruling 12). Three reasons this is better than reading the vault:
///
///      1. `IAmpsVault` exposes no ladder getter and its ABI is final, so a separate contract *cannot* read the
///         vault's private `_ladder` mapping.
///      2. The PoolManager is the authority on what the vault actually owns; a bookkeeping bug in the vault
///         therefore cannot inflate `A`.
///      3. The work is bounded and constant — 24 cells, one batched `extsload` — so `checkpoint()` has a gas cost
///         that does not depend on how many placements have happened.
///
/// @dev **Uncollected fees are excluded** (normative, §4). `A` must never be overstated, and fee growth is the one
///      term an attacker can inflate cheaply by wash-trading. Worse, including it would make `A` depend on
///      `slot0.tick` through `feeGrowthInside`'s branch, contradicting **I7**. The next `compound` sweeps fees into
///      ERC-6909 claims, which the vault already counts, so the omission is a lag and never a loss.
///
/// @dev **Rounding is one-directional: down.** All four decompositions use `SqrtPriceMath.getAmount*Delta(...,
///      false)`, so `A` is understated by at most a wei per cell and never overstated.
///
/// @dev **Never gated, never reverting** (ruling 7). An unregistered pool, a pool with a nonsensical tick spacing,
///      a zero reference price and a pool with no positions at all all return `(0, 0)`. The oracle gate has no say
///      here: a valuer that could refuse would turn a feed outage into an unpriceable NAV.
///
/// @dev **Gas, per pool**, measured cold on a live local pool by `test_gasWorstCaseEveryCellPopulated`:
///
///      ```
///      valuePool, empty pool                 ~101,000
///      valuePool, all 24 cells populated     ~152,000     ~4.9M for a 32-pool checkpoint()
///      totalLiquidity, all 24 cells           ~98,000
///      ```
///
///      The floor is the batched read itself: `IExtsload.extsload(bytes32[])` over 24 **cold** position slots is
///      ~59k (24 x 2,100 of `SLOAD` plus the cold account and the 26-word ABI round trip) and is paid whether the
///      cells hold anything or not, on top of ~12k for the cold `poolConfig` and ~10k to derive the 24 slots
///      (48 `keccak256`s through scratch space). Each **populated** cell then adds ~2.1k: one or two
///      `TickMath.getSqrtPriceAtTick` and one or two `SqrtPriceMath.getAmount*Delta`.
///
///      This is roughly twice the ~70k the Phase 3 design note estimated; the note counted the 24 cold `SLOAD`s
///      and not the call, hashing and ABI overhead around them. It does not change the design decision:
///      `checkpoint()` is permissionless and unpaid, `previewNavPerShareX18` carries the same cost as a `view`,
///      and 4.9M is a fifth of a mainnet block for the pathological case where every one of 32 pools has all 24
///      cells occupied. That is the intended price of I7 holding against the live NAV.
contract LadderPositionValuer is IPositionValuer {
    /// @notice The Uniswap v4 PoolManager, read through the MIT `IExtsload` interface only.
    IExtsload public immutable poolManager;

    /// @notice The `AmpsVault`, which is the owner of every ladder position at the PoolManager.
    address public immutable vault;

    /// @notice The pool registry: the source of `tickSpacing` and `gridBaseTick` for each pool.
    IPoolRegistry public immutable registry;

    /// @param poolManager_ The Uniswap v4 PoolManager.
    /// @param vault_ The `AmpsVault`.
    /// @param registry_ The `PoolRegistry`.
    constructor(IExtsload poolManager_, address vault_, IPoolRegistry registry_) {
        if (address(poolManager_) == address(0) || vault_ == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        vault = vault_;
        registry = registry_;
    }

    /// @inheritdoc IPositionValuer
    /// @dev Per grid cell with non-zero liquidity, at the supplied reference sqrt price `S`:
    ///
    ///      ```
    ///      S <= sqrtLower : amount0 += amount0(sqrtLower, sqrtUpper, L)     entirely AMPS  (an unfilled ask)
    ///      S >= sqrtUpper : amount1 += amount1(sqrtLower, sqrtUpper, L)     entirely counter (a filled ask / bid)
    ///      otherwise      : amount0 += amount0(S,         sqrtUpper, L)
    ///                       amount1 += amount1(sqrtLower, S,         L)     the straddled cell
    ///      ```
    ///
    ///      `S` is `sqrtPrice(P_ref / P_counter)` from the *previous* checkpoint, never `slot0`: that is what makes
    ///      **I7** true, because a flash move of the pool changes no input to this function.
    function valuePool(PoolId poolId, uint160 sqrtPriceRefX96)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (int24 gridBase, int24 width) = _grid(poolId);
        if (width == 0 || sqrtPriceRefX96 == 0) return (0, 0);

        uint128[] memory liquidities =
            PoolStateLib.positionLiquidityAtSlots(poolManager, _gridSlots(poolId, gridBase, width));

        int256 lower = _gridStart(gridBase, width);
        uint256 cells = Constants.GRID_CELLS;
        for (uint256 i; i < cells; ++i) {
            uint128 liquidity = liquidities[i];
            int256 upper = lower + int256(width);
            if (liquidity != 0 && lower >= TickMath.MIN_TICK && upper <= TickMath.MAX_TICK) {
                uint160 sqrtLower = TickMath.getSqrtPriceAtTick(int24(lower));
                uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(int24(upper));
                if (sqrtPriceRefX96 <= sqrtLower) {
                    amount0 += SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
                } else if (sqrtPriceRefX96 >= sqrtUpper) {
                    amount1 += SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
                } else {
                    amount0 += SqrtPriceMath.getAmount0Delta(sqrtPriceRefX96, sqrtUpper, liquidity, false);
                    amount1 += SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceRefX96, liquidity, false);
                }
            }
            lower = upper;
        }
    }

    /// @inheritdoc IPositionValuer
    /// @dev The sum saturates at `type(uint128).max` rather than reverting: `redeemProRata` divides by this, and a
    ///      valuer that reverts would freeze redemption — the one path that must work in every state.
    function totalLiquidity(PoolId poolId) external view returns (uint128 liquidity) {
        (int24 gridBase, int24 width) = _grid(poolId);
        if (width == 0) return 0;

        uint128[] memory liquidities =
            PoolStateLib.positionLiquidityAtSlots(poolManager, _gridSlots(poolId, gridBase, width));

        uint256 total;
        uint256 cells = Constants.GRID_CELLS;
        for (uint256 i; i < cells; ++i) {
            total += liquidities[i];
        }
        liquidity = total > type(uint128).max ? type(uint128).max : uint128(total);
    }

    /// @inheritdoc IPositionValuer
    function version() external pure returns (bytes32 id) {
        return "ladder-grid-valuer-v1";
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The pool's grid origin and cell width, or `width == 0` when the pool has no usable grid (unregistered,
    ///      or a tick spacing outside `[1, TickMath.MAX_TICK_SPACING]`). Callers treat `width == 0` as "worth
    ///      nothing", which is what keeps this contract free of reverts.
    function _grid(PoolId poolId) private view returns (int24 gridBase, int24 width) {
        PoolConfig memory config = registry.poolConfig(poolId);
        if (!config.registered || config.tickSpacing <= 0 || config.tickSpacing > TickMath.MAX_TICK_SPACING) {
            return (0, 0);
        }
        gridBase = config.gridBaseTick;
        width = LadderLib.doublingTicks(config.tickSpacing);
    }

    /// @dev The lower tick of cell `GRID_MIN_M`, in `int256`. `|gridBase| <= 887,272` and
    ///      `|GRID_MIN_M * width| <= 8 * 32,767`, so every cell bound stays well inside `int24`; the wider type is
    ///      used anyway so the bound is a property of the arithmetic rather than of the constants.
    function _gridStart(int24 gridBase, int24 width) private pure returns (int256 lower) {
        lower = int256(gridBase) + int256(Constants.GRID_MIN_M) * int256(width);
    }

    /// @dev The 24 position slots of the pool's grid, in cell order. The positions-mapping base is derived once
    ///      and each cell costs one `positionKey` hash plus one slot hash; the caller turns them into one
    ///      `extsload(bytes32[])` staticcall.
    function _gridSlots(PoolId poolId, int24 gridBase, int24 width) private view returns (bytes32[] memory slots) {
        bytes32 base = PoolStateLib.positionsBaseSlot(poolId);
        address owner = vault;
        uint256 cells = Constants.GRID_CELLS;

        slots = new bytes32[](cells);
        int256 lower = _gridStart(gridBase, width);
        for (uint256 i; i < cells; ++i) {
            int256 upper = lower + int256(width);
            slots[i] = PoolStateLib.positionSlotIn(
                base, PoolStateLib.positionKey(owner, int24(lower), int24(upper), Constants.POSITION_SALT)
            );
            lower = upper;
        }
    }
}
