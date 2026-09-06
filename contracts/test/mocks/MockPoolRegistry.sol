// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolRegistry} from "../../src/interfaces/IPoolRegistry.sol";
import {Constants} from "../../src/types/Constants.sol";
import {LengthMismatch, UnknownConstituent, ZeroAddress} from "../../src/types/Errors.sol";
import {ConstituentConfig, ConstituentStatus, InclusionRecord, PoolClass, PoolConfig} from "../../src/types/Types.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title MockPoolRegistry
/// @notice Settable stand-in for `PoolRegistry` until the real one exists. Every read of `IPoolRegistry` is
///         answered from plain storage that tests write directly, and the four lifecycle actions are implemented
///         as bare state transitions with no vault, hook or PoolManager call.
///
/// @dev **This mock is shared.** The gate, vault and bond suites all register constituents and pools through it,
///      so its setter API is treated as stable: fields are added, never renamed or reordered. The convenience
///      entry point is {addConstituentAndPool}, which writes the constituent, its pool and both directions of the
///      id/pool cross-index in one call.
///
/// @dev What it deliberately does **not** model: the 7-day timelock (every function here is permissionless), the
///      `beforeInitialize` handshake with the hook, weight-band enforcement on {addConstituent} (use
///      {setIndexWeights} or {setTargetWeightBps} to place a weight outside the band on purpose), and the
///      structural `PoolKey` checks. Tests that need those assert against the real registry.
contract MockPoolRegistry is IPoolRegistry {
    /// @inheritdoc IPoolRegistry
    address public vault;

    /// @inheritdoc IPoolRegistry
    address public hook;

    /// @inheritdoc IPoolRegistry
    PoolId public hubPoolId;

    /// @inheritdoc IPoolRegistry
    PoolId public wethPoolId;

    /// @inheritdoc IPoolRegistry
    uint16 public constituentCount;

    /// @inheritdoc IPoolRegistry
    uint16 public poolCount;

    /// @inheritdoc IPoolRegistry
    mapping(address token => uint16 id) public constituentIdOf;

    /// @notice Every constituent id ever issued, in issue order. Ids are 1-based and never reused.
    uint16[] public constituentIds;

    /// @notice Every registered pool id, in registration order.
    PoolId[] public poolIds;

    uint16 internal _activeCount;

    mapping(PoolId poolId => PoolConfig config) internal _pools;
    mapping(PoolId poolId => PoolKey key) internal _keys;
    mapping(uint16 id => ConstituentConfig config) internal _constituents;
    mapping(uint16 id => InclusionRecord record) internal _inclusion;
    mapping(uint16 id => PoolId poolId) internal _poolIdOf;
    mapping(PoolId poolId => uint16 id) internal _constituentOfPool;

    // -----------------------------------------------------------------------------------------------------------
    // Test setters
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Sets the vault address the registry reports.
    /// @param vault_ The vault.
    function setVault(address vault_) external {
        vault = vault_;
    }

    /// @notice Sets the hook address the registry reports.
    /// @param hook_ The hook.
    function setHook(address hook_) external {
        hook = hook_;
    }

    /// @notice Sets the `AMPS/USDG` hub pool id.
    /// @param poolId The hub pool.
    function setHubPoolId(PoolId poolId) external {
        hubPoolId = poolId;
    }

    /// @notice Sets the `AMPS/WETH` entry pool id.
    /// @param poolId The WETH pool.
    function setWethPoolId(PoolId poolId) external {
        wethPoolId = poolId;
    }

    /// @notice Writes a pool record wholesale and indexes it, entry pools included.
    /// @dev Registering the same id twice overwrites the record without double-counting {poolCount}.
    /// @param poolId The pool.
    /// @param config The record to store. `config.registered` is forced true.
    function setPool(PoolId poolId, PoolConfig memory config) public {
        if (!_pools[poolId].registered) {
            poolIds.push(poolId);
            poolCount += 1;
        }
        config.registered = true;
        _pools[poolId] = config;
        _constituentOfPool[poolId] = config.constituentId;
        if (config.constituentId != 0) _poolIdOf[config.constituentId] = poolId;
        emit PoolRegistered(poolId, config.counter, config.poolClass, config.constituentId);
    }

    /// @notice Stores the `PoolKey` a registered pool reports.
    /// @param poolId The pool.
    /// @param key The key.
    function setPoolKey(PoolId poolId, PoolKey calldata key) external {
        _keys[poolId] = key;
    }

    /// @notice Writes a constituent record wholesale and indexes it by token.
    /// @dev Bumps {constituentCount} the first time an id is written, and keeps the active tally in step with
    ///      `config.status`.
    /// @param constituentId The 1-based id.
    /// @param config The record to store.
    function setConstituent(uint16 constituentId, ConstituentConfig memory config) public {
        ConstituentConfig storage existing = _constituents[constituentId];
        bool wasActive = existing.status == ConstituentStatus.ACTIVE;
        if (existing.status == ConstituentStatus.NONE) {
            constituentIds.push(constituentId);
            if (constituentId > constituentCount) constituentCount = constituentId;
        }
        if (existing.token != address(0) && existing.token != config.token) {
            constituentIdOf[existing.token] = 0;
        }
        _constituents[constituentId] = config;
        constituentIdOf[config.token] = constituentId;
        _syncActive(wasActive, config.status == ConstituentStatus.ACTIVE);
    }

    /// @notice Registers a constituent and its spoke pool in one call: the shape every gate, vault and bond test
    ///         needs before it can do anything else.
    /// @param token The Stock Token.
    /// @param feed The Chainlink Standard proxy for `token`.
    /// @param poolId The `AMPS/<stock>` pool.
    /// @param poolClass The fee bucket, normally `SPOKE`.
    /// @param tickSpacing The pool's tick spacing.
    /// @param targetWeightBps The index target weight.
    /// @return constituentId The new 1-based id.
    function addConstituentAndPool(
        address token,
        address feed,
        PoolId poolId,
        PoolClass poolClass,
        int24 tickSpacing,
        uint16 targetWeightBps
    ) external returns (uint16 constituentId) {
        if (token == address(0)) revert ZeroAddress();
        constituentId = constituentCount + 1;
        setConstituent(
            constituentId,
            ConstituentConfig({
                token: token,
                status: ConstituentStatus.ACTIVE,
                decimals: 18,
                targetWeightBps: targetWeightBps,
                rolloutWeightBps: targetWeightBps,
                hSessionOverrideBps: 0,
                hSessionOverrideSet: false,
                caFreezeOverride: false,
                marketId: constituentId,
                feed: feed,
                freezeUntil: 0,
                addedAt: uint32(block.timestamp),
                retiredAt: 0
            })
        );
        setPool(
            poolId,
            PoolConfig({
                counter: token,
                poolClass: poolClass,
                counterDecimals: 18,
                tickSpacing: tickSpacing,
                buyFeeBps: Constants.BUY_FEE_BPS_SPOKE_DEFAULT,
                constituentId: constituentId,
                registered: true
            })
        );
        emit ConstituentAdded(constituentId, token, poolId, targetWeightBps);
    }

    /// @notice Registers one of the two entry pools without any key validation.
    /// @param poolId The pool.
    /// @param counter The counter asset (WETH9 or USDG).
    /// @param counterDecimals The counter asset's decimals.
    /// @param tickSpacing The pool's tick spacing.
    /// @param buyFeeBps The entry buy fee.
    function addEntryPool(PoolId poolId, address counter, uint8 counterDecimals, int24 tickSpacing, uint16 buyFeeBps)
        external
    {
        setPool(
            poolId,
            PoolConfig({
                counter: counter,
                poolClass: PoolClass.ENTRY,
                counterDecimals: counterDecimals,
                tickSpacing: tickSpacing,
                buyFeeBps: buyFeeBps,
                constituentId: 0,
                registered: true
            })
        );
    }

    /// @notice Overwrites a constituent's lifecycle status, keeping the active tally in step.
    /// @param constituentId The constituent.
    /// @param status The new status.
    function setStatus(uint16 constituentId, ConstituentStatus status) external {
        ConstituentConfig storage config = _requireConstituent(constituentId);
        bool wasActive = config.status == ConstituentStatus.ACTIVE;
        config.status = status;
        _syncActive(wasActive, status == ConstituentStatus.ACTIVE);
    }

    /// @notice Overwrites a constituent's index target weight.
    /// @param constituentId The constituent.
    /// @param weightBps The new weight.
    function setTargetWeightBps(uint16 constituentId, uint16 weightBps) external {
        _requireConstituent(constituentId).targetWeightBps = weightBps;
    }

    /// @notice Overwrites a constituent's rollout weight.
    /// @param constituentId The constituent.
    /// @param weightBps The new rollout weight.
    function setRolloutWeightBps(uint16 constituentId, uint16 weightBps) external {
        _requireConstituent(constituentId).rolloutWeightBps = weightBps;
    }

    /// @notice Sets the per-constituent bond haircut override the gate applies instead of the global table.
    /// @param constituentId The constituent.
    /// @param bps The override in bps.
    /// @param isSet Whether the override applies.
    function setHSessionOverride(uint16 constituentId, uint16 bps, bool isSet) external {
        ConstituentConfig storage config = _requireConstituent(constituentId);
        config.hSessionOverrideBps = bps;
        config.hSessionOverrideSet = isSet;
    }

    /// @notice Sets the governance-forced corporate-action freeze flag.
    /// @param constituentId The constituent.
    /// @param forced Whether the constituent is force-frozen.
    function setCaFreezeOverride(uint16 constituentId, bool forced) external {
        _requireConstituent(constituentId).caFreezeOverride = forced;
    }

    /// @notice Replaces a constituent's Chainlink proxy.
    /// @param constituentId The constituent.
    /// @param feed The new aggregator.
    function setFeed(uint16 constituentId, address feed) external {
        _requireConstituent(constituentId).feed = feed;
    }

    /// @notice Replaces a constituent's Stock Token, re-indexing `constituentIdOf`.
    /// @param constituentId The constituent.
    /// @param token The new token.
    function setToken(uint16 constituentId, address token) external {
        ConstituentConfig storage config = _requireConstituent(constituentId);
        constituentIdOf[config.token] = 0;
        config.token = token;
        constituentIdOf[token] = constituentId;
    }

    /// @notice Mirrors a guardian freeze expiry onto the registry record.
    /// @param constituentId The constituent.
    /// @param until The expiry timestamp.
    function setFreezeUntil(uint16 constituentId, uint32 until) external {
        _requireConstituent(constituentId).freezeUntil = until;
        emit ConstituentFrozen(constituentId, until);
    }

    /// @notice Sets the bond market id recorded against a constituent.
    /// @param constituentId The constituent.
    /// @param marketId The 1-based market id.
    function setMarketId(uint16 constituentId, uint16 marketId) external {
        _requireConstituent(constituentId).marketId = marketId;
    }

    /// @notice Records inclusion-rule evidence for a constituent.
    /// @param constituentId The constituent.
    /// @param record The evidence.
    function setInclusionRecord(uint16 constituentId, InclusionRecord calldata record) external {
        _inclusion[constituentId] = record;
    }

    /// @notice Overwrites a registered pool's fee bucket.
    /// @param poolId The pool.
    /// @param poolClass The new class.
    function setPoolClass(PoolId poolId, PoolClass poolClass) external {
        _pools[poolId].poolClass = poolClass;
    }

    /// @notice Overwrites a registered pool's tick spacing.
    /// @param poolId The pool.
    /// @param tickSpacing The new spacing.
    function setTickSpacing(PoolId poolId, int24 tickSpacing) external {
        _pools[poolId].tickSpacing = tickSpacing;
    }

    /// @notice Un-registers a pool, so callers can exercise the `UnknownPool` branch.
    /// @param poolId The pool.
    function unregisterPool(PoolId poolId) external {
        _pools[poolId].registered = false;
    }

    // -----------------------------------------------------------------------------------------------------------
    // IPoolRegistry: reads
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRegistry
    function poolConfig(PoolId poolId) external view returns (PoolConfig memory config) {
        return _pools[poolId];
    }

    /// @inheritdoc IPoolRegistry
    function poolKey(PoolId poolId) external view returns (PoolKey memory key) {
        return _keys[poolId];
    }

    /// @inheritdoc IPoolRegistry
    function constituent(uint16 constituentId) external view returns (ConstituentConfig memory config) {
        return _constituents[constituentId];
    }

    /// @inheritdoc IPoolRegistry
    function inclusionRecord(uint16 constituentId) external view returns (InclusionRecord memory record) {
        return _inclusion[constituentId];
    }

    /// @inheritdoc IPoolRegistry
    function poolIdOf(uint16 constituentId) external view returns (PoolId poolId) {
        return _poolIdOf[constituentId];
    }

    /// @inheritdoc IPoolRegistry
    function constituentOfPool(PoolId poolId) external view returns (uint16 constituentId) {
        return _constituentOfPool[poolId];
    }

    /// @inheritdoc IPoolRegistry
    /// @dev The base mock answers the **target** weight, exactly as the real `PoolRegistry` does in Phase 2, so a
    ///      bond priced against this mock sees `deficit == 0`. `MockRegistryForBonds` overrides it with a settable
    ///      realised weight (and a switch that makes it revert), which is how the bond suite drives the live
    ///      deficit branch and the "registry cannot report a weight" branch.
    function currentWeightBps(uint16 constituentId) external view virtual returns (uint16 weightBps) {
        return _constituents[constituentId].targetWeightBps;
    }

    /// @inheritdoc IPoolRegistry
    function activeConstituentCount() external view returns (uint16 count) {
        return _activeCount;
    }

    /// @inheritdoc IPoolRegistry
    function indexCapBps() external view returns (uint16 capBps) {
        uint16 n = _activeCount;
        if (n == 0) return uint16(Constants.BPS);
        uint256 even = (Constants.BPS + n - 1) / n;
        return even > Constants.INDEX_CAP_FLOOR_BPS ? uint16(even) : Constants.INDEX_CAP_FLOOR_BPS;
    }

    /// @inheritdoc IPoolRegistry
    function indexFloorBps() external view returns (uint16 floorBps) {
        uint16 n = _activeCount;
        if (n == 0) return 0;
        uint256 half = Constants.BPS / (2 * uint256(n));
        return half < Constants.INDEX_FLOOR_CEILING_BPS ? uint16(half) : Constants.INDEX_FLOOR_CEILING_BPS;
    }

    /// @inheritdoc IPoolRegistry
    function isRegistered(PoolId poolId) external view returns (bool registered) {
        return _pools[poolId].registered;
    }

    /// @notice How many constituent ids have been issued through {addConstituentAndPool} or {setConstituent}.
    /// @return length The array length.
    function constituentIdsLength() external view returns (uint256 length) {
        return constituentIds.length;
    }

    /// @notice How many pool ids are indexed.
    /// @return length The array length.
    function poolIdsLength() external view returns (uint256 length) {
        return poolIds.length;
    }

    // -----------------------------------------------------------------------------------------------------------
    // IPoolRegistry: hard bands
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRegistry
    function MAX_CONSTITUENTS() external pure returns (uint16 value) {
        return Constants.MAX_CONSTITUENTS;
    }

    /// @inheritdoc IPoolRegistry
    function BUY_FEE_BPS_ENTRY_MIN() external pure returns (uint16 value) {
        return Constants.BUY_FEE_BPS_ENTRY_MIN;
    }

    /// @inheritdoc IPoolRegistry
    function BUY_FEE_BPS_ENTRY_MAX() external pure returns (uint16 value) {
        return Constants.BUY_FEE_BPS_ENTRY_MAX;
    }

    /// @inheritdoc IPoolRegistry
    function BUY_FEE_BPS_SPOKE_MIN() external pure returns (uint16 value) {
        return Constants.BUY_FEE_BPS_SPOKE_MIN;
    }

    /// @inheritdoc IPoolRegistry
    function BUY_FEE_BPS_SPOKE_MAX() external pure returns (uint16 value) {
        return Constants.BUY_FEE_BPS_SPOKE_MAX;
    }

    /// @inheritdoc IPoolRegistry
    function MIN_HISTORY_DAYS() external pure returns (uint32 value) {
        return Constants.MIN_HISTORY_DAYS;
    }

    // -----------------------------------------------------------------------------------------------------------
    // IPoolRegistry: governance, modelled as bare state transitions
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRegistry
    /// @dev Permissionless here, and it neither validates the key nor calls the vault.
    function registerEntryPool(PoolKey calldata key, uint8 counterDecimals, uint16 buyFeeBps, address feed) external {
        feed; // the mock keeps entry-pool feeds in `FeedRegistry`, not here
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
        _keys[poolId] = key;
        setPool(
            poolId,
            PoolConfig({
                counter: Currency.unwrap(key.currency1),
                poolClass: PoolClass.ENTRY,
                counterDecimals: counterDecimals,
                tickSpacing: key.tickSpacing,
                buyFeeBps: buyFeeBps,
                constituentId: 0,
                registered: true
            })
        );
    }

    /// @inheritdoc IPoolRegistry
    /// @dev Records the constituent and derives a deterministic pool id from the token; no hook handshake.
    function addConstituent(AddConstituentParams calldata params)
        external
        returns (uint16 constituentId, PoolId poolId)
    {
        constituentId = constituentCount + 1;
        poolId = PoolId.wrap(keccak256(abi.encodePacked("mock-pool", params.token)));
        setConstituent(
            constituentId,
            ConstituentConfig({
                token: params.token,
                status: ConstituentStatus.ACTIVE,
                decimals: 18,
                targetWeightBps: params.targetWeightBps,
                rolloutWeightBps: params.rolloutWeightBps,
                hSessionOverrideBps: params.hSessionOverrideBps,
                hSessionOverrideSet: params.hSessionOverrideSet,
                caFreezeOverride: false,
                marketId: params.openBondMarket ? constituentId : 0,
                feed: params.feed,
                freezeUntil: 0,
                addedAt: uint32(block.timestamp),
                retiredAt: 0
            })
        );
        _inclusion[constituentId] = params.inclusion;
        setPool(
            poolId,
            PoolConfig({
                counter: params.token,
                poolClass: params.poolClass,
                counterDecimals: 18,
                tickSpacing: params.tickSpacing,
                buyFeeBps: params.buyFeeBps,
                constituentId: constituentId,
                registered: true
            })
        );
        emit ConstituentAdded(constituentId, params.token, poolId, params.targetWeightBps);
    }

    /// @inheritdoc IPoolRegistry
    function retireConstituent(uint16 constituentId) external {
        ConstituentConfig storage config = _requireConstituent(constituentId);
        bool wasActive = config.status == ConstituentStatus.ACTIVE;
        config.status = ConstituentStatus.RETIRED;
        config.rolloutWeightBps = 0;
        config.retiredAt = uint32(block.timestamp);
        _syncActive(wasActive, false);
        emit ConstituentRetired(constituentId, config.token);
    }

    /// @inheritdoc IPoolRegistry
    function reinstateConstituent(uint16 constituentId, uint16 rolloutWeightBps) external {
        ConstituentConfig storage config = _requireConstituent(constituentId);
        bool wasActive = config.status == ConstituentStatus.ACTIVE;
        config.status = ConstituentStatus.ACTIVE;
        config.rolloutWeightBps = rolloutWeightBps;
        _syncActive(wasActive, true);
        emit ConstituentReinstated(constituentId, rolloutWeightBps);
    }

    /// @inheritdoc IPoolRegistry
    function reconfigureConstituent(uint16 constituentId, ReconfigureParams calldata params) external {
        ConstituentConfig storage config = _requireConstituent(constituentId);
        if (params.setPoolClass) _pools[_poolIdOf[constituentId]].poolClass = params.poolClass;
        if (params.setBuyFeeBps) _pools[_poolIdOf[constituentId]].buyFeeBps = params.buyFeeBps;
        if (params.setTargetWeightBps) config.targetWeightBps = params.targetWeightBps;
        if (params.setRolloutWeightBps) config.rolloutWeightBps = params.rolloutWeightBps;
        if (params.setFeed) config.feed = params.feed;
        if (params.setHSessionOverride) {
            config.hSessionOverrideBps = params.hSessionOverrideBps;
            config.hSessionOverrideSet = params.hSessionOverrideSet;
        }
        if (params.setCaFreezeOverride) config.caFreezeOverride = params.caFreezeOverride;
        emit ConstituentReconfigured(constituentId, "mock", 0, 0);
    }

    /// @inheritdoc IPoolRegistry
    function setIndexWeights(uint16[] calldata ids, uint16[] calldata weightsBps) external {
        if (ids.length != weightsBps.length) revert LengthMismatch();
        for (uint256 i = 0; i < ids.length; ++i) {
            _requireConstituent(ids[i]).targetWeightBps = weightsBps[i];
        }
        emit IndexWeightsSet(ids, weightsBps);
    }

    /// @inheritdoc IPoolRegistry
    /// @dev A no-op: the mock holds no inventory to withdraw.
    function withdrawRetiredBids(uint16 constituentId) external view {
        if (_constituents[constituentId].status == ConstituentStatus.NONE) revert UnknownConstituent(constituentId);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Reverts with `UnknownConstituent` for an id that was never written.
    function _requireConstituent(uint16 constituentId) internal view returns (ConstituentConfig storage config) {
        config = _constituents[constituentId];
        if (config.status == ConstituentStatus.NONE) revert UnknownConstituent(constituentId);
    }

    /// @dev Keeps `_activeCount` in step with a status transition.
    function _syncActive(bool wasActive, bool isActive) internal {
        if (wasActive == isActive) return;
        if (isActive) {
            _activeCount += 1;
        } else {
            _activeCount -= 1;
        }
    }
}
