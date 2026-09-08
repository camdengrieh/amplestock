// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsHook} from "../../src/interfaces/IAmpsHook.sol";
import {IMarketReference} from "../../src/interfaces/IMarketReference.sol";
import {Constants} from "../../src/types/Constants.sol";
import {HookPoolState, PoolClass, Session} from "../../src/types/Types.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title QuoterHookStub
/// @notice A settable `IAmpsHook` for the quoter and gate suites: the whole read surface `AmpsQuoter` and
///         `OracleGate` use, with every answer written by a test rather than derived from a pool.
///
/// @dev The real `AmpsHook` is being written in parallel, so the quoter is coded and tested against the interface
///      and this stub, and reconciled against the real hook in integration. Nothing here computes a fee: a test
///      *tells* it what `quoteFee` returns, which is exactly what makes the quoter's own arithmetic — the rotation
///      blend, the `F_MIN` clamp, the degraded bits — testable in isolation.
///
/// @dev Deploy it, then `vm.etch` its runtime code at a `0x38C0`-shaped address: the stub keeps all of its state in
///      storage written by setters, so it survives being moved and behaves identically at the mined address the
///      production hook will occupy.
contract QuoterHookStub is IAmpsHook {
    /// @notice What {quoteFee} answers for one pool and one direction.
    /// @param feePips The total fee in pips.
    /// @param baseBps The base component.
    /// @param dynBps The clamped dynamic component.
    /// @param refuse Whether the swap would be refused.
    struct FeeAnswer {
        uint24 feePips;
        uint16 baseBps;
        uint16 dynBps;
        bool refuse;
    }

    /// @notice The observation ring, flattened.
    /// @param twapTick The mean tick every window answers with.
    /// @param lastTruncated The last truncated tick.
    /// @param highWater The high-water mark.
    /// @param coverage Seconds of history the ring covers.
    /// @param set Whether the pool has been given an observation at all.
    struct Observation {
        int24 twapTick;
        int24 lastTruncated;
        int24 highWater;
        uint32 coverage;
        bool set;
    }

    address public amps;
    address public vault;
    address public registry;
    address public oracleGate;
    address public feePolicy;
    address public timelock;
    uint32 public gateCacheSeconds = Constants.GATE_CACHE_SECONDS_DEFAULT;
    uint16 public ampsFeeBps = Constants.AMPS_FEE_BPS_DEFAULT;
    uint32 internal _twapWindow = Constants.TWAP_WINDOW_DEFAULT;

    mapping(PoolId poolId => HookPoolState state) internal _state;
    /// @dev Keyed by direction **and** by the pass-through flag, because revision 6 gives every direction two
    ///      prices: `[false]` is what an ordinary swap pays (base `ampsFeeBps`) and `[true]` is what one hop of an
    ///      `AmpsRouter.rotate` pays (base `buyFeeBps`).
    mapping(PoolId poolId => mapping(bool zeroForOne => mapping(bool passThrough => FeeAnswer answer))) internal _fees;

    /// @notice The protocol router, as `IAmpsHook.router()`. Settable, and nothing here reads it: the stub is told
    ///         what `quoteFee` answers rather than deriving it.
    address public router;
    mapping(PoolId poolId => Observation observation) internal _obs;

    /// @notice Seeds a pool with the shape a spoke has at rest: initialised, a class, a counter's decimals, a
    ///         spacing, a buy fee, the Regular band and rail, and the normal dynamic cap.
    /// @param poolId The pool.
    /// @param poolClass The class.
    /// @param counterDecimals The counter asset's decimals.
    /// @param tickSpacing The pool's tick spacing.
    /// @param buyFee The pool's base buy fee.
    function initPool(PoolId poolId, PoolClass poolClass, uint8 counterDecimals, int24 tickSpacing, uint16 buyFee)
        external
    {
        HookPoolState storage state = _state[poolId];
        state.initialized = true;
        state.poolClass = poolClass;
        state.counterDecimals = counterDecimals;
        state.tickSpacing = tickSpacing;
        state.buyFeeBps = buyFee;
        state.maxTickMovePerBlock = Constants.MAX_TICK_MOVE_PER_BLOCK_DEFAULT;
        state.uiMultiplierX18 = uint64(Constants.WAD);
        state.innerBandTicks = Constants.INNER_BAND_REGULAR_TICKS;
        state.outerRailTicks = Constants.OUTER_RAIL_MIN_TICKS;
        state.dynCapBps = Constants.DYN_CAP_NORMAL_BPS;
        state.session = Session.REGULAR;
        state.gateRefreshedAt = uint32(block.timestamp);
    }

    /// @notice Overwrites a pool's whole state view.
    /// @param poolId The pool.
    /// @param state The state.
    function setPoolState(PoolId poolId, HookPoolState calldata state) external {
        _state[poolId] = state;
    }

    /// @notice Sets the two ticks the quoter renders.
    /// @param poolId The pool.
    /// @param lastTick The raw tick.
    /// @param fairTick_ The fair tick.
    function setTicks(PoolId poolId, int24 lastTick, int24 fairTick_) external {
        _state[poolId].lastTick = lastTick;
        _state[poolId].fairTick = fairTick_;
    }

    /// @notice Sets the band, the rail and the dynamic cap.
    /// @param poolId The pool.
    /// @param innerBand The inner band half-width.
    /// @param outerRail The outer rail half-width.
    /// @param dynCapBps The dynamic cap.
    function setBands(PoolId poolId, int24 innerBand, int24 outerRail, uint16 dynCapBps) external {
        _state[poolId].innerBandTicks = innerBand;
        _state[poolId].outerRailTicks = outerRail;
        _state[poolId].dynCapBps = dynCapBps;
    }

    /// @notice Sets the cached gate flags: bit0 degraded, bit1 corporateFreeze, bit2 refreshFailed, bit3 caArmed.
    /// @param poolId The pool.
    /// @param flags The bitfield.
    function setGateFlags(PoolId poolId, uint8 flags) external {
        _state[poolId].gateFlags = flags;
    }

    /// @notice Sets the cached session.
    /// @param poolId The pool.
    /// @param session The session.
    function setSession(PoolId poolId, Session session) external {
        _state[poolId].session = session;
    }

    /// @notice Sets what {quoteFee} answers for one direction and one pricing.
    /// @param poolId The pool.
    /// @param zeroForOne True for the sell leg.
    /// @param passThrough True for the rotation-hop price, false for the ordinary one.
    /// @param answer The answer.
    function setFee(PoolId poolId, bool zeroForOne, bool passThrough, FeeAnswer calldata answer) external {
        _fees[poolId][zeroForOne][passThrough] = answer;
    }

    /// @notice Sets all four fee legs from three bps figures, with no dynamic part and no refusal.
    /// @dev Three and not two, because the hook this stub stands in for is asked four questions per pool — buy
    ///      and sell, ordinary and pass-through — and the fixture's pool hook does not have to answer them the
    ///      way the production hook would. `passThroughFee` is what both directions cost on a router rotation hop
    ///      and is also what `buyFeeBps(poolId)` reports; `ordinarySellFee` doubles as `ampsFeeBps()`, which is
    ///      what the quoter's own blend arithmetic is measured against.
    /// @param poolId The pool.
    /// @param ordinaryBuyFee What an ordinary buy costs, in bps.
    /// @param ordinarySellFee What an ordinary sell costs, in bps; also the protocol-wide `ampsFeeBps`.
    /// @param passThroughFee What one hop of a router rotation costs, in bps; also the pool's `buyFeeBps`.
    function setFlatFees(PoolId poolId, uint16 ordinaryBuyFee, uint16 ordinarySellFee, uint16 passThroughFee) external {
        _fees[poolId][false][false] = _flat(ordinaryBuyFee);
        _fees[poolId][true][false] = _flat(ordinarySellFee);
        _fees[poolId][false][true] = _flat(passThroughFee);
        _fees[poolId][true][true] = _flat(passThroughFee);
        _state[poolId].buyFeeBps = passThroughFee;
        ampsFeeBps = ordinarySellFee;
    }

    /// @dev One fee leg with no dynamic part and no refusal.
    function _flat(uint16 bps) private pure returns (FeeAnswer memory answer) {
        answer = FeeAnswer({feePips: uint24(bps) * Constants.PIPS_PER_BPS, baseBps: bps, dynBps: 0, refuse: false});
    }

    /// @notice Sets the refusal flag of one direction, on both of its prices: the rail is a property of the pool
    ///         and the tick, and does not know what the swap is paying.
    /// @param poolId The pool.
    /// @param zeroForOne True for the sell leg.
    /// @param refuse Whether that leg is beyond the rail.
    function setRefuse(PoolId poolId, bool zeroForOne, bool refuse) external {
        _fees[poolId][zeroForOne][false].refuse = refuse;
        _fees[poolId][zeroForOne][true].refuse = refuse;
    }

    /// @notice Sets the router pointer the quoter and the gate may read back.
    /// @param router_ The router.
    function setRouter(address router_) external {
        emit RouterChanged(router, router_);
        router = router_;
    }

    /// @notice Sets the observation ring's answers.
    /// @param poolId The pool.
    /// @param twapTick_ The mean tick.
    /// @param lastTruncated The last truncated tick.
    /// @param coverage Seconds covered.
    function setObservation(PoolId poolId, int24 twapTick_, int24 lastTruncated, uint32 coverage) external {
        _obs[poolId] = Observation({
            twapTick: twapTick_, lastTruncated: lastTruncated, highWater: lastTruncated, coverage: coverage, set: true
        });
    }

    /// @notice Sets the protocol-wide TWAP window.
    /// @param window The window in seconds.
    function setTwapWindow(uint32 window) external {
        _twapWindow = window;
    }

    /// @notice Sets the pointers the quoter and the gate read back.
    /// @param amps_ AMPS.
    /// @param vault_ The vault.
    /// @param registry_ The registry.
    /// @param gate_ The gate.
    function setPointers(address amps_, address vault_, address registry_, address gate_) external {
        amps = amps_;
        vault = vault_;
        registry = registry_;
        oracleGate = gate_;
    }

    // ------------------------------------------------------------------ //
    //                          IMarketReference                          //
    // ------------------------------------------------------------------ //

    /// @inheritdoc IMarketReference
    function twapTick(PoolId poolId, uint32 window) public view returns (int24 meanTick) {
        Observation memory observation = _obs[poolId];
        if (!observation.set) revert PoolNotObserved(poolId);
        if (observation.coverage < window) revert WindowNotCovered(poolId, window, observation.coverage);
        return observation.twapTick;
    }

    /// @inheritdoc IMarketReference
    function twapTick30m(PoolId poolId) external view returns (int24 meanTick) {
        return twapTick(poolId, _twapWindow);
    }

    /// @inheritdoc IMarketReference
    function observationCoverage(PoolId poolId) external view returns (uint32 secondsCovered) {
        return _obs[poolId].coverage;
    }

    /// @inheritdoc IMarketReference
    function lastTruncatedTick(PoolId poolId) external view returns (int24 tick) {
        return _obs[poolId].lastTruncated;
    }

    /// @inheritdoc IMarketReference
    function highWaterTick(PoolId poolId) external view returns (int24 tick) {
        return _obs[poolId].highWater;
    }

    /// @inheritdoc IMarketReference
    function twapWindow() external view returns (uint32 window) {
        return _twapWindow;
    }

    /// @inheritdoc IMarketReference
    function maxTickMovePerBlock(PoolId poolId) external view returns (int24 cap) {
        return _state[poolId].maxTickMovePerBlock;
    }

    // ------------------------------------------------------------------ //
    //                              IAmpsHook                             //
    // ------------------------------------------------------------------ //

    /// @inheritdoc IAmpsHook
    function gridBaseTick(PoolId poolId) external view returns (int24 tick) {
        return _state[poolId].gridBaseTick;
    }

    /// @inheritdoc IAmpsHook
    function poolState(PoolId poolId) external view returns (HookPoolState memory state) {
        return _state[poolId];
    }

    /// @inheritdoc IAmpsHook
    /// @dev The stub holds no transient state, so nobody ever has a credit.
    function rotationCredit(address) external pure returns (uint256 credit) {
        return 0;
    }

    /// @inheritdoc IAmpsHook
    function quoteFee(PoolId poolId, bool zeroForOne, bool, uint256, bool passThrough)
        public
        view
        returns (uint24 feePips, uint16 baseBps, uint16 dynBps, bool refuse)
    {
        FeeAnswer memory answer = _fees[poolId][zeroForOne][passThrough];
        return (answer.feePips, answer.baseBps, answer.dynBps, answer.refuse);
    }

    /// @inheritdoc IAmpsHook
    function quoteFee(PoolId poolId, bool zeroForOne, bool exactInput, uint256 amountIn)
        external
        view
        returns (uint24 feePips, uint16 baseBps, uint16 dynBps, bool refuse)
    {
        return quoteFee(poolId, zeroForOne, exactInput, amountIn, false);
    }

    /// @inheritdoc IAmpsHook
    function innerBandTicks(PoolId poolId) external view returns (int24 ticks) {
        return _state[poolId].innerBandTicks;
    }

    /// @inheritdoc IAmpsHook
    function outerRailTicks(PoolId poolId) external view returns (int24 ticks) {
        return _state[poolId].outerRailTicks;
    }

    /// @inheritdoc IAmpsHook
    function fairTick(PoolId poolId) external view returns (int24 tick) {
        return _state[poolId].fairTick;
    }

    /// @inheritdoc IAmpsHook
    function buyFeeBps(PoolId poolId) external view returns (uint16 value) {
        return _state[poolId].buyFeeBps;
    }

    /// @inheritdoc IAmpsHook
    function AMPS_FEE_BPS_MIN() external pure returns (uint16 value) {
        return Constants.AMPS_FEE_BPS_MIN;
    }

    /// @inheritdoc IAmpsHook
    function AMPS_FEE_BPS_MAX() external pure returns (uint16 value) {
        return Constants.AMPS_FEE_BPS_MAX;
    }

    /// @inheritdoc IAmpsHook
    function TOTAL_FEE_BPS_MAX() external pure returns (uint16 value) {
        return Constants.TOTAL_FEE_BPS_MAX;
    }

    /// @inheritdoc IAmpsHook
    function HOOK_FLAGS() external pure returns (uint16 value) {
        return Constants.HOOK_FLAGS;
    }

    /// @inheritdoc IAmpsHook
    function resetHighWater(PoolId poolId) external returns (int24 previousHighWaterTick) {
        previousHighWaterTick = _obs[poolId].highWater;
        _obs[poolId].highWater = _obs[poolId].lastTruncated;
    }

    /// @inheritdoc IAmpsHook
    function armSurge(PoolId poolId, uint16 surgeBps, bytes32 reason) external {
        _state[poolId].surgeBps = surgeBps;
        _state[poolId].surgeArmedAt = uint32(block.timestamp);
        emit SurgeArmed(poolId, surgeBps, reason);
    }

    /// @inheritdoc IAmpsHook
    function setAmpsFeeBps(uint16 value) external {
        ampsFeeBps = value;
    }

    /// @inheritdoc IAmpsHook
    function setBuyFeeBps(PoolId poolId, uint16 value) external {
        _state[poolId].buyFeeBps = value;
    }

    /// @inheritdoc IAmpsHook
    function setMaxTickMovePerBlock(PoolId poolId, int24 value) external {
        _state[poolId].maxTickMovePerBlock = value;
    }

    /// @inheritdoc IAmpsHook
    function setFeePolicy(address newPolicy) external {
        emit FeePolicyChanged(feePolicy, newPolicy);
        feePolicy = newPolicy;
    }

    /// @inheritdoc IAmpsHook
    /// @dev Unguarded here: the stub exists to be steered by a test, not to enforce the production check.
    function setVault(address newVault) external {
        emit VaultChanged(vault, newVault);
        vault = newVault;
    }
}
