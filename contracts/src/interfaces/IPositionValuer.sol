// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IPositionValuer
/// @notice The pluggable third term of the NAV numerator: what the vault's Uniswap v4 positions are worth.
///
/// @dev The NAV numerator is
///
///      ```
///      A = SUM_j P_j x ( ERC-6909 claim_j + idle ERC-20_j + amount_j(positions, sqrtPrice_REF) ) - liabilities
///      ```
///
///      Phase 2 builds the vault with no v4 positions at all: assets live only as ERC-6909 claims and idle ERC-20
///      balances, and the third term is supplied by a **zero-position valuer** that returns `(0, 0)` for every pool.
///      Phase 3 replaces the pointer with the real valuer, which decomposes each `PlacementRecord` at the
///      **reference-implied** sqrt price and sums the amounts. Nothing about the vault's storage, its NAV formula
///      or its invariants changes when the pointer moves; only the numerator gains a term.
///
/// @dev **Why a pointer and not inlined code.** Position decomposition is the one part of NAV that has to change
///      when the placement machinery lands, and the vault is immutable. Making it a pointer keeps the vault's
///      bytecode final in Phase 2 and confines the Phase 3 change to a 7-day timelocked pointer swap. The valuer
///      is `view` and holds no funds, so a hostile pointer can misreport NAV but can never move an asset — and a
///      misreported NAV cannot mint (there is no NAV mint) and cannot be used to redeem more than pro rata
///      (redemption reads balances, never NAV).
///
/// @dev **Rounding is one-directional: down.** Every amount returned feeds `A`, which must never be overstated.
///      A valuer that rounds up is a bug of the same class as an overstated oracle answer.
///
/// @dev **Counterfactual pricing is deliberate.** Positions are decomposed at `sqrtPrice(P_ref / P_j)` from the
///      *previous* checkpoint, not at `slot0`. Invariant I7 asserts the consequence: forcing `slot0` +/-50% moves
///      `A` by no more than dust, so a flash move of a pool cannot inflate NAV. The denominator is
///      `Amps.totalSupply()`, which is exact by definition and never reads a price at all.
///
/// @dev **The Phase 3 implementation enumerates the grid, not the vault's records** (`docs/phase3-state-model.md`
///      §4, §10 ruling 1). `LadderPositionValuer` rebuilds the pool's `Constants.GRID_CELLS` canonical ranges from
///      `PoolConfig.gridBaseTick`, `PoolConfig.tickSpacing` and `Constants.POSITION_SALT`, and reads their
///      liquidity in one batched `IExtsload.extsload(bytes32[])`. Three reasons, in order of weight: `IAmpsVault`
///      exposes no ladder getter on any path NAV may depend on and the ABI is final; the PoolManager, not the
///      vault, is the authority on what the vault actually owns; and a bookkeeping bug in the vault's own records
///      therefore cannot inflate `A`.
///
/// @dev **Uncollected fees are excluded, normatively.** `A` must never be overstated, and fee growth is the one
///      term an attacker can inflate cheaply by wash-trading. Including it would also make `A` depend on
///      `slot0.tick` through `feeGrowthInside`'s branch, which contradicts I7 outright. The next `compound()`
///      collects those fees into ERC-6909 claims, where `A` picks them up like any other balance, so the omission
///      is a lag and never a loss.
interface IPositionValuer {
    /// @notice Values every position the vault holds in `poolId`, decomposed at a supplied reference sqrt price.
    /// @dev Called once per registered pool by `AmpsVault._computeNav`. Implementations must be `view`, must never
    ///      revert for a pool with no positions (return zeros), and must never call back into the vault.
    /// @param poolId The pool to value.
    /// @param sqrtPriceRefX96 The reference-implied sqrt price, `sqrtPrice(P_ref / P_counter)`, from the previous
    ///        checkpoint. Not `slot0`.
    /// @return amount0 AMPS (currency0) held across the pool's positions, rounded down. Valued at **zero** by the
    ///         caller (invariant I5) but returned so the vault can disclose inventory.
    /// @return amount1 Counter asset (currency1) held across the pool's positions, in raw units, rounded down.
    function valuePool(PoolId poolId, uint160 sqrtPriceRefX96) external view returns (uint256 amount0, uint256 amount1);

    /// @notice Total liquidity the vault holds in `poolId`, summed over its buckets.
    /// @dev Used by `redeemProRata` to size the exact `floor(L_p x shares / T)` removal per position (I23) and by
    ///      the dApp to show ladder fill. Zero for the Phase 2 stub.
    /// @param poolId The pool to inspect.
    /// @return liquidity The summed position liquidity.
    function totalLiquidity(PoolId poolId) external view returns (uint128 liquidity);

    /// @notice Human-readable identifier of the valuer implementation, for governance diffs and the dApp.
    /// @return id A short identifier, e.g. `bytes32("zero-position-v1")`.
    function version() external pure returns (bytes32 id);
}
