// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookPoolState} from "../types/Types.sol";
import {IMarketReference} from "./IMarketReference.sol";

/// @title IAmpsHook
/// @notice The read surface `AmpsVault`, `AmpsBonds` and `AmpsQuoter` use against the one immutable hook that
///         serves all 32 pools. This is deliberately **not** the `IHooks` callback surface: the PoolManager talks
///         to the hook through `IHooks`, and the protocol talks to it through this.
///
/// @dev **Permissions are `0x38C0`**: `BEFORE_INITIALIZE | AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP |
///      AFTER_SWAP`. No `*_RETURNS_DELTA` bit and no `BEFORE_REMOVE_LIQUIDITY` bit, ever — removals must never be
///      blockable (I18), and a returns-delta bit is what turned every hook-custody incident in the survey into a
///      loss. The hook holds no ERC-20 and no ERC-6909, mirrors no PoolManager balance, and never calls
///      `settle`, `take`, `mint`, `burn`, `donate` or `swap` (I13).
///
/// @dev **What the vault reads here.**
///        - the market reference (inherited from {IMarketReference}): per-pool truncated TWAPs backing `P_mkt`;
///        - the per-pool high-water tick, and the vault-only {resetHighWater} that arms the next buyback-burn
///          window;
///        - the live same-transaction rotation credit, for the quoter;
///        - per-pool configuration, so the quoter can reproduce a fee without simulating a swap.
///
/// @dev **The rotation credit lives in EIP-1153 transient storage**, so it is zero at the start of every
///      transaction and cannot be carried across one (I26). It is credited in `afterSwap` by the AMPS a buyer
///      actually received, and consumed in `beforeSwap` by an exact-input sell, blended and rounded **up**. A 1-wei
///      buy therefore unlocks a 1-wei credit and nothing more; a buy-then-sell round trip inside one transaction
///      pays a buy fee plus a sell fee on the uncredited excess and nets the swapper nothing.
interface IAmpsHook is IMarketReference {
    /// @notice Emitted by `afterSwap` when a pool's high-water tick advances.
    /// @param poolId The pool.
    /// @param highWaterTick The new mark.
    event HighWaterAdvanced(PoolId indexed poolId, int24 highWaterTick);

    /// @notice Emitted when the vault resets a pool's high-water mark at `compound()`.
    /// @param poolId The pool.
    /// @param previousHighWaterTick The mark that was consumed.
    /// @param newHighWaterTick The mark it was reset to (the tick currently in force).
    event HighWaterReset(PoolId indexed poolId, int24 previousHighWaterTick, int24 newHighWaterTick);

    /// @notice Emitted when a surge fee is armed.
    /// @param poolId The pool.
    /// @param surgeBps The surge, before decay.
    /// @param reason A short identifier: `bytes32("placement")`, `bytes32("sessionOpen")`,
    ///        `bytes32("multiplierStep")` or `bytes32("refJump")`.
    event SurgeArmed(PoolId indexed poolId, uint16 surgeBps, bytes32 reason);

    /// @notice Emitted when a `uiMultiplier()` step is detected on a constituent.
    /// @param poolId The pool.
    /// @param previousMultiplierX18 The cached multiplier.
    /// @param newMultiplierX18 The observed multiplier.
    /// @param captureFeeBps The capture fee armed, or 0 when the step was large enough to freeze instead.
    event MultiplierStepDetected(
        PoolId indexed poolId, uint256 previousMultiplierX18, uint256 newMultiplierX18, uint16 captureFeeBps
    );

    /// @notice Emitted when a same-transaction rotation credit is consumed by a sell.
    /// @param poolId The pool the sell went through.
    /// @param consumed AMPS wei of credit used.
    /// @param blendedFeeBps The blended base fee that resulted.
    event RotationCreditConsumed(PoolId indexed poolId, uint256 consumed, uint16 blendedFeeBps);

    /// @notice `currency0` of the pool being initialised is not AMPS. Hard requirement: it fixes the sign of every
    ///         fee direction and every one-sided placement in the protocol.
    error Currency0NotAmps();

    /// @notice The pool was not initialised with the dynamic-fee flag.
    error FeeNotDynamic();

    /// @notice The pool is not in `PoolRegistry`.
    /// @param poolId The pool.
    error PoolNotRegistered(PoolId poolId);

    /// @notice A deviation-increasing swap beyond the outer rail. The **only** reason the hook ever reverts a
    ///         swap: no gate state, no freeze and no oracle failure can (I15).
    /// @param poolId The pool.
    /// @param devTicks The deviation after the swap.
    /// @param outerRailTicks The rail in force.
    error BeyondOuterRail(PoolId poolId, int24 devTicks, int24 outerRailTicks);

    // -------------------------------------------------------------------------------------------------------------
    // Reads (permissionless)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice AMPS. `currency0` of every Amplestocks pool.
    /// @return ampsAddress The token address.
    function amps() external view returns (address ampsAddress);

    /// @notice The vault: the only address allowed to initialise a pool, add liquidity or reset a high-water mark.
    /// @return vaultAddress The vault address.
    function vault() external view returns (address vaultAddress);

    /// @notice The pool registry.
    /// @return registryAddress The registry address.
    function registry() external view returns (address registryAddress);

    /// @notice The oracle gate.
    /// @return gateAddress The gate address.
    function oracleGate() external view returns (address gateAddress);

    /// @notice The fee policy pointer.
    /// @return policyAddress The `IFeePolicy` address.
    function feePolicy() external view returns (address policyAddress);

    /// @notice The whole per-pool hook state.
    /// @param poolId The pool.
    /// @return state The state, excluding the observation ring (read that through {IMarketReference}).
    function poolState(PoolId poolId) external view returns (HookPoolState memory state);

    /// @notice The live same-transaction rotation credit, in AMPS wei.
    /// @dev Reads EIP-1153 transient storage, so it is always zero when read from a fresh transaction — which is
    ///      exactly what makes it useless to an off-chain observer and safe to expose.
    /// @return credit The credit.
    function rotationCredit() external view returns (uint256 credit);

    /// @notice The fee the hook would charge for a swap right now, without simulating one.
    /// @dev The quoter's entry point. Never reverts: a swap that would be refused returns `refuse == true`.
    /// @param poolId The pool.
    /// @param zeroForOne True for a sell (AMPS in).
    /// @param exactInput True for an exact-input swap.
    /// @param amountIn The input amount, or 0 when unknown.
    /// @return feePips The fee in pips, without the override flag.
    /// @return baseBps The base component after any rotation blend.
    /// @return dynBps The dynamic component after clamping.
    /// @return refuse Whether the swap would be refused for being deviation-increasing beyond the outer rail.
    function quoteFee(PoolId poolId, bool zeroForOne, bool exactInput, uint256 amountIn)
        external
        view
        returns (uint24 feePips, uint16 baseBps, uint16 dynBps, bool refuse);

    /// @notice The inner band half-width currently in force for a pool.
    /// @param poolId The pool.
    /// @return ticks The half-width.
    function innerBandTicks(PoolId poolId) external view returns (int24 ticks);

    /// @notice The outer rail half-width currently in force for a pool.
    /// @param poolId The pool.
    /// @return ticks The half-width.
    function outerRailTicks(PoolId poolId) external view returns (int24 ticks);

    /// @notice The fair tick a pool's deviation is measured against: `tickOf(P_mkt / P_i)` for a spoke, the pool's
    ///         own truncated TWAP for an entry pool.
    /// @dev Deliberately `P_mkt`, not the rate-limited `P_ref`: a spoke must be able to follow a hub move inside
    ///      one TWAP window, which is the mechanism that turns a hub pump into stock backing across all 30 spokes.
    /// @param poolId The pool.
    /// @return tick The fair tick.
    function fairTick(PoolId poolId) external view returns (int24 tick);

    // -------------------------------------------------------------------------------------------------------------
    // Governed parameters
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The protocol-wide sell fee charged on every AMPS-in swap in all 32 pools. 500 bp at launch.
    /// @return value The parameter.
    function sellFeeBps() external view returns (uint16 value);

    /// @notice A pool's base buy fee.
    /// @param poolId The pool.
    /// @return value The parameter. 30 bp entry, 5 or 10 bp spoke.
    function buyFeeBps(PoolId poolId) external view returns (uint16 value);

    // -------------------------------------------------------------------------------------------------------------
    // Hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Hard floor of `sellFeeBps`, in bps. 100.
    /// @return value The bound.
    function SELL_FEE_BPS_MIN() external view returns (uint16 value);

    /// @notice Hard ceiling of `sellFeeBps`, in bps. 600.
    /// @return value The bound.
    function SELL_FEE_BPS_MAX() external view returns (uint16 value);

    /// @notice The largest total fee the hook can ever return, in bps. 2,600, far below `MAX_LP_FEE` (I16).
    /// @return value The bound.
    function TOTAL_FEE_BPS_MAX() external view returns (uint16 value);

    /// @notice The hook's permission bits: `0x38C0`. Asserted against the mined address at deployment and
    ///         re-verified in CI after every dependency bump.
    /// @return value The flags.
    function HOOK_FLAGS() external view returns (uint16 value);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Resets a pool's high-water tick to the truncated tick currently in force. **Only vault.**
    /// @dev Called by `compound()` after the buyback burn has consumed the previous window. Vault-only because the
    ///      mark is what decides which AMPS is bought-back inventory: anyone able to reset it could hide a buyback
    ///      from the burn.
    /// @param poolId The pool.
    /// @return previousHighWaterTick The mark that was consumed.
    function resetHighWater(PoolId poolId) external returns (int24 previousHighWaterTick);

    /// @notice Arms a surge on a pool. **Only vault.** Called after every placement, so a placement cannot be
    ///         sandwiched at the old fee.
    /// @param poolId The pool.
    /// @param surgeBps The surge to arm, at most `Constants.SURGE_MAX_BPS`.
    /// @param reason A short identifier for the event.
    function armSurge(PoolId poolId, uint16 surgeBps, bytes32 reason) external;

    /// @notice Sets the protocol-wide sell fee. **Only timelock (48 h).**
    /// @param value The new fee, inside `[SELL_FEE_BPS_MIN, SELL_FEE_BPS_MAX]`.
    function setSellFeeBps(uint16 value) external;

    /// @notice Sets a pool's buy fee. **Only timelock (48 h).**
    /// @param poolId The pool.
    /// @param value The new fee, inside the pool class's band.
    function setBuyFeeBps(PoolId poolId, uint16 value) external;

    /// @notice Sets a pool's per-block oracle truncation cap. **Only timelock (48 h).**
    /// @param poolId The pool.
    /// @param value The new cap, inside
    ///        `[MAX_TICK_MOVE_PER_BLOCK_MIN, MAX_TICK_MOVE_PER_BLOCK_MAX]`.
    function setMaxTickMovePerBlock(PoolId poolId, int24 value) external;

    /// @notice Replaces the fee policy pointer. **Only timelock (7 d).**
    /// @param newPolicy The new `IFeePolicy`.
    function setFeePolicy(address newPolicy) external;
}
