// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketReference} from "../../src/interfaces/IMarketReference.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {NotVault} from "../../src/types/Errors.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title PlacementHookStub
/// @notice The pool hook the placement suites run against: `test/gas/StubAmpsHook.sol`'s permission set and
///         preconditions, plus the four surfaces `VaultPlacementLib` actually reaches on the real `AmpsHook` —
///         `gridBaseTick`, `highWaterTick`, `resetHighWater` and `armSurge` — and the `IMarketReference`
///         observation surface, because in production one contract answers all of them.
///
/// @dev **Why a new mock rather than an extension of `StubAmpsHook`.** That contract's hook callbacks are
///      `override` without `virtual`, so they cannot be overridden again; and it is owned by the gas suite, which
///      this slice must not touch. This is the same shape, written once more, with the Phase 3 surface added and
///      a handful of counters the placement tests assert on.
///
/// @dev **What it is not.** No fee wall, no rotation credit, no truncated observation ring, no dividend detector.
///      The real `AmpsHook` is being written concurrently; the integration agent swaps it in by pointing the
///      registry, the vault's `marketReference` and the fee policy at it, and nothing in `src/vault/**` changes.
contract PlacementHookStub is BaseHook, IMarketReference {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev One pool's observable state.
    struct Obs {
        bool observed;
        int24 gridBaseTick;
        int24 lastTick;
        int24 highWater;
        int24 twap;
        uint32 coverage;
        uint32 surgeArmedCount;
        uint32 highWaterResetCount;
        uint16 buyFeeBps;
        bytes32 lastSurgeReason;
    }

    /// @notice AMPS: `currency0` of every Amplestocks pool by construction.
    Currency public immutable amps;

    /// @notice The only address allowed to add liquidity, reset the mark or arm a surge.
    address public immutable vault;

    /// @notice The live sell fee, in bps. `VaultPlacementLib` divides the creator's share by this.
    uint16 public sellFeeBps = 500;

    /// @dev Per-pool state.
    mapping(PoolId => Obs) internal _obs;

    /// @dev The observation window `twapTick30m` answers over.
    uint32 internal _window = 1800;

    /// @notice Emitted by {armSurge}, so a test can assert the placement armed the surge it was supposed to.
    event SurgeArmed(PoolId indexed poolId, uint16 surgeBps, bytes32 reason);

    /// @notice Emitted by {resetHighWater}.
    event HighWaterReset(PoolId indexed poolId, int24 previousHighWaterTick, int24 newHighWaterTick);

    error Currency0NotAmps();
    error FeeNotDynamic();
    error PoolNotInitializedHere();

    /// @param poolManager_ The Uniswap v4 PoolManager.
    /// @param amps_ The AMPS token as a `Currency`.
    /// @param vault_ The `AmpsVault`.
    constructor(IPoolManager poolManager_, Currency amps_, address vault_) BaseHook(poolManager_) {
        amps = amps_;
        vault = vault_;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------------------------------------------
    // The Phase 3 surface `VaultPlacementLib` reaches
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The pool's canonical grid origin, written at `afterInitialize` and mirrored by `PoolRegistry`.
    /// @param poolId The pool.
    /// @return tick The origin.
    function gridBaseTick(PoolId poolId) external view returns (int24 tick) {
        return _obs[poolId].gridBaseTick;
    }

    /// @inheritdoc IMarketReference
    function highWaterTick(PoolId poolId) external view returns (int24 tick) {
        return _obs[poolId].highWater;
    }

    /// @notice Resets the pool's high-water mark to the live tick. **Vault only.**
    /// @param poolId The pool.
    /// @return previousHighWaterTick The mark that was in force.
    function resetHighWater(PoolId poolId) external returns (int24 previousHighWaterTick) {
        if (msg.sender != vault) revert NotVault(msg.sender);
        Obs storage o = _obs[poolId];
        previousHighWaterTick = o.highWater;
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        o.highWater = tick;
        o.highWaterResetCount += 1;
        emit HighWaterReset(poolId, previousHighWaterTick, tick);
    }

    /// @notice Arms the surge fee. **Vault only.**
    /// @param poolId The pool.
    /// @param surgeBps The surge to arm, in bps.
    /// @param reason A short identifier.
    function armSurge(PoolId poolId, uint16 surgeBps, bytes32 reason) external {
        if (msg.sender != vault) revert NotVault(msg.sender);
        Obs storage o = _obs[poolId];
        o.surgeArmedCount += 1;
        o.lastSurgeReason = reason;
        emit SurgeArmed(poolId, surgeBps, reason);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Test surface
    // -------------------------------------------------------------------------------------------------------------

    /// @notice How many times {armSurge} has been called for `poolId`.
    function surgeArmedCount(PoolId poolId) external view returns (uint32 count) {
        return _obs[poolId].surgeArmedCount;
    }

    /// @notice The reason of the last {armSurge} for `poolId`.
    function lastSurgeReason(PoolId poolId) external view returns (bytes32 reason) {
        return _obs[poolId].lastSurgeReason;
    }

    /// @notice How many times {resetHighWater} has been called for `poolId`.
    function highWaterResetCount(PoolId poolId) external view returns (uint32 count) {
        return _obs[poolId].highWaterResetCount;
    }

    /// @notice Forces the high-water mark, so a test can put a cell on either side of it without a real pump.
    function setHighWaterTick(PoolId poolId, int24 tick) external {
        _obs[poolId].highWater = tick;
    }

    /// @notice Seeds the observation the vault's `P_mkt` and the divergence check read.
    function setObservation(PoolId poolId, int24 twap, int24 last, uint32 coverage) external {
        Obs storage o = _obs[poolId];
        o.observed = true;
        o.twap = twap;
        o.lastTick = last;
        o.coverage = coverage;
    }

    /// @notice Sets the live sell fee the creator slice is measured against.
    function setSellFeeBps(uint16 value) external {
        sellFeeBps = value;
    }

    /// @notice Sets a pool's buy fee, in bps.
    function setBuyFeeBps(PoolId poolId, uint16 value) external {
        _obs[poolId].buyFeeBps = value;
    }

    // -------------------------------------------------------------------------------------------------------------
    // IMarketReference
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IMarketReference
    function twapTick(PoolId poolId, uint32 window) public view returns (int24 meanTick) {
        Obs storage o = _obs[poolId];
        if (!o.observed) revert PoolNotObserved(poolId);
        if (o.coverage < window) revert WindowNotCovered(poolId, window, o.coverage);
        return o.twap;
    }

    /// @inheritdoc IMarketReference
    function twapTick30m(PoolId poolId) external view returns (int24 meanTick) {
        return twapTick(poolId, 1800);
    }

    /// @inheritdoc IMarketReference
    function observationCoverage(PoolId poolId) external view returns (uint32 secondsCovered) {
        return _obs[poolId].coverage;
    }

    /// @inheritdoc IMarketReference
    function lastTruncatedTick(PoolId poolId) external view returns (int24 tick) {
        Obs storage o = _obs[poolId];
        if (!o.observed) revert PoolNotObserved(poolId);
        return o.lastTick;
    }

    /// @inheritdoc IMarketReference
    function twapWindow() external view returns (uint32 window) {
        return _window;
    }

    /// @inheritdoc IMarketReference
    function maxTickMovePerBlock(PoolId) external pure returns (int24 cap) {
        return 200;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Hook callbacks
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `currency0 == AMPS` and a dynamic-fee pool: the two production preconditions that cannot be relaxed.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (Currency.unwrap(key.currency0) != Currency.unwrap(amps)) revert Currency0NotAmps();
        if (!key.fee.isDynamicFee()) revert FeeNotDynamic();
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Writes the CONFIG word — `gridBaseTick` included — before returning, which is what
    ///      `PoolRegistry._openPool` reads back on the next line (§11.5).
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        Obs storage o = _obs[key.toId()];
        o.observed = true;
        o.gridBaseTick = PriceLib.alignTick(tick, key.tickSpacing, true);
        o.lastTick = tick;
        o.highWater = tick;
        o.twap = tick;
        o.buyFeeBps = 30;
        return BaseHook.afterInitialize.selector;
    }

    /// @dev POL-only: the vault is the sole liquidity provider.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != vault) revert NotVault(sender);
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @dev A flat directional fee: `zeroForOne == true` is always "AMPS in", i.e. a sell.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Obs storage o = _obs[key.toId()];
        if (!o.observed) revert PoolNotInitializedHere();
        uint24 pips = params.zeroForOne ? uint24(sellFeeBps) * 100 : uint24(o.buyFeeBps) * 100;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, pips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Records the tick and advances the per-pool high-water mark, which is what drives the buyback burn.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        Obs storage o = _obs[id];
        o.lastTick = tick;
        o.twap = tick;
        if (tick > o.highWater) o.highWater = tick;
        return (BaseHook.afterSwap.selector, int128(0));
    }
}
