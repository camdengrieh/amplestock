// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IAmpsBonds} from "../interfaces/IAmpsBonds.sol";
import {IAmpsHook} from "../interfaces/IAmpsHook.sol";
import {IAmpsVault} from "../interfaces/IAmpsVault.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {PriceLib} from "../lib/PriceLib.sol";
import {Constants} from "../types/Constants.sol";
import {
    AlreadyInitialized,
    LengthMismatch,
    NotTimelock,
    OutOfBand,
    UnknownConstituent,
    UnknownPool,
    ZeroAddress
} from "../types/Errors.sol";
import {
    CollateralClass,
    ConstituentConfig,
    ConstituentStatus,
    InclusionRecord,
    PoolClass,
    PoolConfig
} from "../types/Types.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title PoolRegistry
/// @notice The allowlist and the index: which pools exist, which Stock Tokens are constituents, what each one
///         weighs, and what fee bucket its pool sits in. Immutable bytecode, 7-day-timelock-governed state
///         (Decision 19, plan §"Pool set, index and allowlist", state model §1.4/§2/§3).
///
/// @dev **Wiring.** `vault` and `hook` are written once, in the constructor, into the slots the state model
///      reserves for them (§1.4 slot 0 and slot 1); there is no setter for either, so the pair is set-once in the
///      strongest sense. `timelock`, `amps`, `weth9` and `usdg` are immutables, which is why they do not appear in
///      the documented storage layout: they live in code. They are passed explicitly rather than read back from
///      the vault so that the registry's constructor makes no assumption about how far the vault's own
///      initialisation has progressed — the AMPS address is CREATE2-mined and the hook address is flag-mined, so
///      both are known before either contract is deployed.
///
/// @dev **What this contract does not do.** It places no liquidity (the seed ask arrives with the next rollout,
///      Phase 3), holds no funds and no token approvals, reads no oracle gate, and never calls the PoolManager:
///      pool initialisation goes through `AmpsVault.initializePool` because `AmpsHook.beforeInitialize` requires
///      `sender == vault`. Every lifecycle action therefore leaves NAV/share untouched by construction (I37).
///
/// @dev **Freezes.** The guardian's freeze lives in `OracleGate` and expires by itself; the registry holds no gate
///      pointer and cannot observe it. What the registry *can* express is the governance-forced corporate-action
///      freeze of {reconfigureConstituent}: while `caFreezeOverride` is set — or while a `freezeUntil` stamp
///      written by a future gate callback is in the future — {constituent} reports `ConstituentStatus.FROZEN` over
///      an otherwise `ACTIVE` record. The overlay is a read-side projection: the lifecycle status underneath stays
///      `ACTIVE`, which is what `activeConstituentCount` counts, because a freeze is temporary and must not move
///      the index cap and floor.
contract PoolRegistry is IPoolRegistry {
    using LPFeeLibrary for uint24;

    // -------------------------------------------------------------------------------------------------------------
    // Errors (registry-local; the shared ones come from `types/Errors.sol` and `IPoolRegistry`)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The proposed feed is not usable: wrong decimals, or a non-positive answer.
    /// @param feed The rejected aggregator.
    /// @param reason A short identifier, e.g. `bytes32("decimals")`.
    error InvalidFeed(address feed, bytes32 reason);

    /// @notice The aggregator advertises itself as an SVR (Smart Value Recapture) proxy. Only Chainlink Standard
    ///         proxies may back a constituent (plan §"Pool set, index and allowlist").
    /// @param feed The rejected aggregator.
    error NotStandardProxy(address feed);

    /// @notice A name that fails the inclusion rule `beta > 0.5 + sigma_u^2 / (2 sigma_I^2)` was given a non-zero
    ///         rollout weight. Such a name may still be registered — with a pool, a seed ladder and a bond market —
    ///         but with `rolloutWeightBps == 0`.
    /// @param betaX18 The recorded beta, 1e18 fixed point.
    /// @param thresholdX18 The threshold it had to exceed, 1e18 fixed point.
    error BetaBelowThreshold(int256 betaX18, uint256 thresholdX18);

    // -------------------------------------------------------------------------------------------------------------
    // Events (registry-local; the indexed lifecycle events come from `IPoolRegistry`)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Emitted when a pool is opened through the vault, entry pools and spokes alike. It carries the two
    ///         numbers `PoolRegistered` and `PoolConfig` have no room for: the feed the initial price was taken
    ///         from, and the price itself. The registry does not *store* a pool's feed — `FeedRegistry` is the
    ///         system of record for every aggregator — so this is what lets the indexer reconcile the two.
    /// @param poolId The pool.
    /// @param feed The Chainlink feed used for the initial price.
    /// @param sqrtPriceX96 The price the pool was opened at.
    event PoolOpened(PoolId indexed poolId, address indexed feed, uint160 sqrtPriceX96);

    /// @notice Emitted when the registry asks the vault to move a retired spoke's bids into idle claims.
    /// @param constituentId The retired constituent.
    /// @param moved The counter-asset amount the vault reports moved, in raw units.
    event RetiredBidsWithdrawn(uint16 indexed constituentId, uint256 moved);

    // -------------------------------------------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The 7-day timelock: the sole caller of every mutator on this contract. Read through {wiring}.
    address internal immutable _timelock;

    /// @dev AMPS. `currency0` of all 32 pools, by construction of its CREATE2-mined address.
    address internal immutable _amps;

    /// @dev WETH9: `currency1` of the main speculative route.
    address internal immutable _weth9;

    /// @dev USDG: `currency1` of the settlement hub.
    address internal immutable _usdg;

    // -------------------------------------------------------------------------------------------------------------
    // Storage — the layout of state model §1.4, slot for slot
    // -------------------------------------------------------------------------------------------------------------

    /// @dev slot 0 [0..159]. Set-once in the constructor.
    address private _vault;

    /// @dev slot 0 [160..175]. Ids ever issued; ids are never reused.
    uint16 private _constituentCount;

    /// @dev slot 0 [176..191]. The `n` the index cap and floor use.
    uint16 private _activeCount;

    /// @dev slot 0 [192..207]. 32 at launch.
    uint16 private _poolCount;

    /// @dev slot 1 [0..159]. Set-once in the constructor.
    address private _hook;

    /// @dev slot 2. `AMPS/USDG`.
    PoolId private _hubPoolId;

    /// @dev slot 3. `AMPS/WETH`.
    PoolId private _wethPoolId;

    /// @dev slot 4. One slot per pool.
    mapping(PoolId poolId => PoolConfig config) private _pools;

    /// @dev slot 5. Three slots per pool.
    mapping(PoolId poolId => PoolKey key) private _keys;

    /// @dev slot 6. Two slots per constituent.
    mapping(uint16 constituentId => ConstituentConfig config) private _constituents;

    /// @dev slot 7. One slot per constituent.
    mapping(uint16 constituentId => InclusionRecord record) private _inclusion;

    /// @dev slot 8.
    mapping(address token => uint16 constituentId) private _constituentIdOf;

    /// @dev slot 9.
    mapping(uint16 constituentId => PoolId poolId) private _poolIdOf;

    // -------------------------------------------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Wires the registry to the vault, the hook and the timelock, and records the three counter-asset
    ///         addresses the pool keys are checked against.
    /// @dev Every argument is required to be non-zero; none of them can ever change. The hook is passed as an
    ///      address rather than an `IHooks` because it is flag-mined and deployed *after* the registry (its own
    ///      constructor takes this contract), so the value is a commitment, not a live contract, at this point.
    /// @param vault_ `AmpsVault`.
    /// @param hook_ The flag-mined `AmpsHook` address.
    /// @param timelock_ The 7-day `TimelockController`.
    /// @param amps_ The CREATE2-mined AMPS address.
    /// @param weth9_ WETH9 on the target chain.
    /// @param usdg_ USDG on the target chain.
    constructor(address vault_, address hook_, address timelock_, address amps_, address weth9_, address usdg_) {
        if (
            vault_ == address(0) || hook_ == address(0) || timelock_ == address(0) || amps_ == address(0)
                || weth9_ == address(0) || usdg_ == address(0)
        ) revert ZeroAddress();

        _vault = vault_;
        _hook = hook_;
        _timelock = timelock_;
        _amps = amps_;
        _weth9 = weth9_;
        _usdg = usdg_;
    }

    /// @dev Every mutator in this contract, without exception, is reachable only from the 7-day timelock (§2).
    modifier onlyTimelock() {
        _requireTimelock();
        _;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Governance — pool registration
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRegistry
    function registerEntryPool(PoolKey calldata key, uint8 counterDecimals, uint16 buyFeeBps, address feed)
        external
        onlyTimelock
    {
        address counter = Currency.unwrap(key.currency1);
        bool isHub = counter == _usdg;
        if (!isHub && counter != _weth9) revert InvalidPoolKey("counterNotEntryAsset");
        _validateKeyShape(key, counter);
        _checkBand("buyFeeBps", buyFeeBps, Constants.BUY_FEE_BPS_ENTRY_MIN, Constants.BUY_FEE_BPS_ENTRY_MAX);
        if (counterDecimals != _tokenDecimals(counter)) revert InvalidPoolKey("counterDecimals");

        PoolId poolId = key.toId();
        if (PoolId.unwrap(isHub ? _hubPoolId : _wethPoolId) != bytes32(0)) revert AlreadyInitialized();
        if (isHub) {
            _hubPoolId = poolId;
        } else {
            _wethPoolId = poolId;
        }

        _registerPool(key, poolId, counter, PoolClass.ENTRY, counterDecimals, buyFeeBps, 0);
        _openPool(key, poolId, feed, counterDecimals);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Governance — constituent lifecycle
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRegistry
    function addConstituent(AddConstituentParams calldata params)
        external
        onlyTimelock
        returns (uint16 constituentId, PoolId poolId)
    {
        if (params.token == address(0)) revert ZeroAddress();
        if (params.poolClass != PoolClass.SPOKE && params.poolClass != PoolClass.SPOKE_HIGH_VOL) {
            revert InvalidPoolKey("poolClassNotSpoke");
        }

        uint16 existing = _constituentIdOf[params.token];
        if (existing != 0) revert ConstituentExists(params.token, existing);

        uint16 count = _constituentCount;
        if (count >= Constants.MAX_CONSTITUENTS) revert ConstituentSetFull(Constants.MAX_CONSTITUENTS);

        _requireBuyFee(params.poolClass, params.buyFeeBps);
        _checkBand("rolloutWeightBps", params.rolloutWeightBps, 0, Constants.BPS);
        _checkBand("hSessionOverrideBps", params.hSessionOverrideBps, 0, Constants.H_SESSION_BPS_MAX);
        _requireInclusion(params.inclusion, params.rolloutWeightBps);
        // The weight band is measured against the count this registration produces, not the one it starts from.
        _requireWeight(params.targetWeightBps, _activeCount + 1);

        uint8 decimals = _tokenDecimals(params.token);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(_amps),
            currency1: Currency.wrap(params.token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(_hook)
        });
        _validateKeyShape(key, params.token);
        poolId = key.toId();

        unchecked {
            constituentId = count + 1;
            _constituentCount = constituentId;
            _activeCount = _activeCount + 1;
        }

        _constituents[constituentId] = ConstituentConfig({
            token: params.token,
            status: ConstituentStatus.ACTIVE,
            decimals: decimals,
            targetWeightBps: params.targetWeightBps,
            rolloutWeightBps: params.rolloutWeightBps,
            hSessionOverrideBps: params.hSessionOverrideSet ? params.hSessionOverrideBps : 0,
            hSessionOverrideSet: params.hSessionOverrideSet,
            caFreezeOverride: false,
            marketId: 0,
            feed: params.feed,
            freezeUntil: 0,
            addedAt: uint32(block.timestamp),
            retiredAt: 0
        });
        _inclusion[constituentId] = InclusionRecord({
            betaX18: params.inclusion.betaX18,
            trackingErrorX18: params.inclusion.trackingErrorX18,
            indexVolX18: params.inclusion.indexVolX18,
            historyDays: params.inclusion.historyDays,
            recordedAt: uint32(block.timestamp)
        });
        _constituentIdOf[params.token] = constituentId;
        _poolIdOf[constituentId] = poolId;
        _registerPool(key, poolId, params.token, params.poolClass, decimals, params.buyFeeBps, constituentId);

        emit ConstituentAdded(constituentId, params.token, poolId, params.targetWeightBps);

        _openPool(key, poolId, params.feed, decimals);

        if (params.openBondMarket) {
            _constituents[constituentId].marketId = IAmpsBonds(_bonds())
                .addCollateral(
                    params.token,
                    CollateralClass.CONSTITUENT,
                    Constants.BOND_D_BASE_BPS_DEFAULT,
                    Constants.BOND_D_MIN_BPS_DEFAULT,
                    Constants.BOND_D_MAX_BPS_DEFAULT,
                    Constants.BOND_CAP_BPS_PER_EPOCH_DEFAULT,
                    true
                );
        }
    }

    /// @inheritdoc IPoolRegistry
    function retireConstituent(uint16 constituentId) external onlyTimelock {
        ConstituentConfig storage config = _requireKnown(constituentId);
        if (config.status != ConstituentStatus.ACTIVE) revert InvalidStatusTransition(constituentId, config.status);

        config.status = ConstituentStatus.RETIRED;
        config.rolloutWeightBps = 0;
        config.retiredAt = uint32(block.timestamp);
        unchecked {
            _activeCount = _activeCount - 1;
        }

        emit ConstituentRetired(constituentId, config.token);

        // The unfilled asks return to the entry pools and the bids stay as an exit market: both are the vault's
        // work in Phase 3. What the registry owns here is the flag, the weight and the bond market.
        uint16 marketId = config.marketId;
        if (marketId != 0) IAmpsBonds(_bonds()).setMarketOpen(marketId, false);
    }

    /// @inheritdoc IPoolRegistry
    function reinstateConstituent(uint16 constituentId, uint16 rolloutWeightBps) external onlyTimelock {
        ConstituentConfig storage config = _requireKnown(constituentId);
        if (config.status != ConstituentStatus.RETIRED) revert InvalidStatusTransition(constituentId, config.status);

        _checkBand("rolloutWeightBps", rolloutWeightBps, 0, Constants.BPS);
        // The set may have grown while this name was out; its stored target weight has to be legal again for the
        // count the reinstatement produces, or governance must re-weight it first.
        _requireWeight(config.targetWeightBps, _activeCount + 1);

        config.status = ConstituentStatus.ACTIVE;
        config.rolloutWeightBps = rolloutWeightBps;
        unchecked {
            _activeCount = _activeCount + 1;
        }

        emit ConstituentReinstated(constituentId, rolloutWeightBps);

        uint16 marketId = config.marketId;
        if (marketId != 0) IAmpsBonds(_bonds()).setMarketOpen(marketId, true);
    }

    /// @inheritdoc IPoolRegistry
    /// @dev Bond parameters (`dBase`, `k_w`, `k_c`, capacity) are deliberately absent from `ReconfigureParams`:
    ///      they are 48-hour setters on `AmpsBonds`, not 7-day registry state, and routing them through here would
    ///      slow every bond retune to a week. The same timelock calls `AmpsBonds` directly.
    function reconfigureConstituent(uint16 constituentId, ReconfigureParams calldata params) external onlyTimelock {
        ConstituentConfig storage config = _requireKnown(constituentId);
        PoolId poolId = _poolIdOf[constituentId];
        PoolConfig storage pool = _pools[poolId];

        // `poolClass` is applied first: a buy fee in the same proposal is measured against the new bucket's band.
        PoolClass class = params.setPoolClass ? params.poolClass : pool.poolClass;
        if (params.setPoolClass) {
            if (class != PoolClass.SPOKE && class != PoolClass.SPOKE_HIGH_VOL) {
                revert InvalidPoolKey("poolClassNotSpoke");
            }
            _emitField(constituentId, "poolClass", uint256(uint8(pool.poolClass)), uint256(uint8(class)));
            pool.poolClass = class;
        }

        if (params.setBuyFeeBps) {
            _requireBuyFee(class, params.buyFeeBps);
            _emitField(constituentId, "buyFeeBps", pool.buyFeeBps, params.buyFeeBps);
            pool.buyFeeBps = params.buyFeeBps;
        }

        if (params.setTargetWeightBps) {
            _requireWeight(params.targetWeightBps, _effectiveCount(config.status));
            _emitField(constituentId, "targetWeightBps", config.targetWeightBps, params.targetWeightBps);
            config.targetWeightBps = params.targetWeightBps;
        }

        if (params.setRolloutWeightBps) {
            // I37: a retired constituent has zero rollout weight, whatever the proposal says.
            if (config.status == ConstituentStatus.RETIRED && params.rolloutWeightBps != 0) {
                revert OutOfBand("rolloutWeightBps", params.rolloutWeightBps, 0, 0);
            }
            _checkBand("rolloutWeightBps", params.rolloutWeightBps, 0, Constants.BPS);
            _emitField(constituentId, "rolloutWeightBps", config.rolloutWeightBps, params.rolloutWeightBps);
            config.rolloutWeightBps = params.rolloutWeightBps;
        }

        if (params.setFeed) {
            _feedAnswerUsd8(params.feed);
            _emitField(constituentId, "feed", uint256(uint160(config.feed)), uint256(uint160(params.feed)));
            config.feed = params.feed;
        }

        if (params.setHSessionOverride) {
            _checkBand("hSessionOverrideBps", params.hSessionOverrideBps, 0, Constants.H_SESSION_BPS_MAX);
            uint16 next = params.hSessionOverrideSet ? params.hSessionOverrideBps : 0;
            _emitField(constituentId, "hSessionOverrideBps", config.hSessionOverrideBps, next);
            _emitField(
                constituentId,
                "hSessionOverrideSet",
                config.hSessionOverrideSet ? 1 : 0,
                params.hSessionOverrideSet ? 1 : 0
            );
            config.hSessionOverrideBps = next;
            config.hSessionOverrideSet = params.hSessionOverrideSet;
        }

        if (params.setCaFreezeOverride) {
            _emitField(
                constituentId, "caFreezeOverride", config.caFreezeOverride ? 1 : 0, params.caFreezeOverride ? 1 : 0
            );
            config.caFreezeOverride = params.caFreezeOverride;
            // A forced corporate-action freeze has no scheduled end, which is what `until == 0` means here and in
            // the shared `ConstituentFrozen` error.
            if (params.caFreezeOverride) emit ConstituentFrozen(constituentId, 0);
        }
    }

    /// @inheritdoc IPoolRegistry
    /// @dev The vector is replaced, not adjusted: after the call the target weights of every `ACTIVE` constituent
    ///      must sum to exactly `BPS`. A valid vector always exists — `n * floor_n <= BPS <= n * cap_n` for every
    ///      `n` in `[1, MAX_CONSTITUENTS]` — so the check can never lock governance out of re-weighting.
    function setIndexWeights(uint16[] calldata ids, uint16[] calldata weightsBps) external onlyTimelock {
        if (ids.length != weightsBps.length) revert LengthMismatch();

        uint16 n = _activeCount;
        (uint16 floorBps_, uint16 capBps_) = _weightBounds(n);

        for (uint256 i; i < ids.length; ++i) {
            ConstituentConfig storage config = _requireKnown(ids[i]);
            if (config.status != ConstituentStatus.ACTIVE) revert InvalidStatusTransition(ids[i], config.status);
            uint16 weight = weightsBps[i];
            if (weight < floorBps_ || weight > capBps_) revert WeightOutOfRange(weight, floorBps_, capBps_);
            config.targetWeightBps = weight;
        }

        if (n != 0) {
            uint256 sum;
            uint16 count = _constituentCount;
            for (uint16 id = 1; id <= count; ++id) {
                ConstituentConfig storage config = _constituents[id];
                if (config.status == ConstituentStatus.ACTIVE) sum += config.targetWeightBps;
            }
            if (sum != Constants.BPS) revert OutOfBand("indexWeightSum", sum, Constants.BPS, Constants.BPS);
        }

        emit IndexWeightsSet(ids, weightsBps);
    }

    /// @inheritdoc IPoolRegistry
    function withdrawRetiredBids(uint16 constituentId) external onlyTimelock {
        ConstituentConfig storage config = _requireKnown(constituentId);
        if (config.status != ConstituentStatus.RETIRED) revert InvalidStatusTransition(constituentId, config.status);

        uint256 moved = IAmpsVault(_vault).withdrawRetiredBids(constituentId);
        emit RetiredBidsWithdrawn(constituentId, moved);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRegistry
    function poolConfig(PoolId poolId) external view returns (PoolConfig memory config) {
        config = _pools[poolId];
    }

    /// @inheritdoc IPoolRegistry
    /// @dev Reverts with {UnknownPool} rather than returning a zeroed key: a `PoolKey` whose `currency0` is
    ///      `address(0)` is a *valid* v4 key for native ETH, so an empty answer here would be a live footgun.
    function poolKey(PoolId poolId) external view returns (PoolKey memory key) {
        if (!_pools[poolId].registered) revert UnknownPool(PoolId.unwrap(poolId));
        key = _keys[poolId];
    }

    /// @inheritdoc IPoolRegistry
    /// @dev The returned `status` carries the freeze overlay described in the contract header; the stored
    ///      lifecycle status is `ACTIVE` or `RETIRED` and is what the counters follow.
    function constituent(uint16 constituentId) external view returns (ConstituentConfig memory config) {
        config = _constituents[constituentId];
        if (config.status == ConstituentStatus.ACTIVE && _isFrozen(config)) config.status = ConstituentStatus.FROZEN;
    }

    /// @inheritdoc IPoolRegistry
    function inclusionRecord(uint16 constituentId) external view returns (InclusionRecord memory record) {
        record = _inclusion[constituentId];
    }

    /// @inheritdoc IPoolRegistry
    function constituentIdOf(address token) external view returns (uint16 constituentId) {
        constituentId = _constituentIdOf[token];
    }

    /// @inheritdoc IPoolRegistry
    function poolIdOf(uint16 constituentId) external view returns (PoolId poolId) {
        poolId = _poolIdOf[constituentId];
    }

    /// @inheritdoc IPoolRegistry
    function constituentOfPool(PoolId poolId) external view returns (uint16 constituentId) {
        constituentId = _pools[poolId].constituentId;
    }

    /// @inheritdoc IPoolRegistry
    /// @dev Phase 2 answers the constituent's **target** weight, which makes `AmpsBonds`'s deficit term exactly
    ///      zero. The realised weight is the vault's valuation of that spoke's position divided by the whole
    ///      index, and Phase 2 ships `ZeroPositionValuer`: there is no position to value, so any other answer
    ///      would be invented. Zero deficit is also the protocol-favourable reading — a smaller deficit means a
    ///      smaller discount and less AMPS issued — so a wrong-because-unknowable input cannot dilute anyone.
    ///      Phase 3 sources the numerator from `AmpsVault`'s valuation; the ABI and this call site do not change.
    ///      An unknown id reads zero rather than reverting, so a bond market on a retired or never-registered
    ///      name still prices.
    function currentWeightBps(uint16 constituentId) external view returns (uint16 weightBps) {
        weightBps = _constituents[constituentId].targetWeightBps;
    }

    /// @inheritdoc IPoolRegistry
    function hubPoolId() external view returns (PoolId poolId) {
        poolId = _hubPoolId;
    }

    /// @inheritdoc IPoolRegistry
    function wethPoolId() external view returns (PoolId poolId) {
        poolId = _wethPoolId;
    }

    /// @inheritdoc IPoolRegistry
    function constituentCount() external view returns (uint16 count) {
        count = _constituentCount;
    }

    /// @inheritdoc IPoolRegistry
    function activeConstituentCount() external view returns (uint16 count) {
        count = _activeCount;
    }

    /// @inheritdoc IPoolRegistry
    function poolCount() external view returns (uint16 count) {
        count = _poolCount;
    }

    /// @inheritdoc IPoolRegistry
    function indexCapBps() external view returns (uint16 capBps) {
        (, capBps) = _weightBounds(_activeCount);
    }

    /// @inheritdoc IPoolRegistry
    function indexFloorBps() external view returns (uint16 floorBps) {
        (floorBps,) = _weightBounds(_activeCount);
    }

    /// @inheritdoc IPoolRegistry
    function isRegistered(PoolId poolId) external view returns (bool registered) {
        registered = _pools[poolId].registered;
    }

    /// @inheritdoc IPoolRegistry
    function vault() external view returns (address vaultAddress) {
        vaultAddress = _vault;
    }

    /// @inheritdoc IPoolRegistry
    function hook() external view returns (address hookAddress) {
        hookAddress = _hook;
    }

    /// @notice The four addresses fixed at construction that `IPoolRegistry` has no getter for.
    /// @dev Returned as one tuple rather than four getters: the registry is immutable bytecode sitting close to
    ///      the EIP-170 limit, and nothing on any path reads these individually. The derived reads that used to
    ///      live here — the active list, the index weight vector and the cap/floor rule at an arbitrary count —
    ///      are in `PoolRegistryLens`, which computes them from the getters below.
    /// @return timelockAddress The 7-day timelock, the sole caller of every mutator.
    /// @return ampsAddress AMPS, `currency0` of every pool.
    /// @return weth9Address WETH9, `currency1` of the main speculative route.
    /// @return usdgAddress USDG, `currency1` of the settlement hub.
    function wiring()
        external
        view
        returns (address timelockAddress, address ampsAddress, address weth9Address, address usdgAddress)
    {
        return (_timelock, _amps, _weth9, _usdg);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRegistry
    function MAX_CONSTITUENTS() external pure returns (uint16 value) {
        value = Constants.MAX_CONSTITUENTS;
    }

    /// @inheritdoc IPoolRegistry
    function BUY_FEE_BPS_ENTRY_MIN() external pure returns (uint16 value) {
        value = Constants.BUY_FEE_BPS_ENTRY_MIN;
    }

    /// @inheritdoc IPoolRegistry
    function BUY_FEE_BPS_ENTRY_MAX() external pure returns (uint16 value) {
        value = Constants.BUY_FEE_BPS_ENTRY_MAX;
    }

    /// @inheritdoc IPoolRegistry
    function BUY_FEE_BPS_SPOKE_MIN() external pure returns (uint16 value) {
        value = Constants.BUY_FEE_BPS_SPOKE_MIN;
    }

    /// @inheritdoc IPoolRegistry
    function BUY_FEE_BPS_SPOKE_MAX() external pure returns (uint16 value) {
        value = Constants.BUY_FEE_BPS_SPOKE_MAX;
    }

    /// @inheritdoc IPoolRegistry
    function MIN_HISTORY_DAYS() external pure returns (uint32 value) {
        value = Constants.MIN_HISTORY_DAYS;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The single access check in this contract. A function rather than an inline test in the modifier so
    ///      that the seven mutators share one copy of it.
    function _requireTimelock() private view {
        if (msg.sender != _timelock) revert NotTimelock(msg.sender);
    }

    /// @dev The index cap and floor for `n` active constituents. `n == 0` has no index: the cap opens to `BPS` and
    ///      the floor drops to zero so that the first registration is bounded only by its own `n == 1` band.
    function _weightBounds(uint16 n) private pure returns (uint16 floorBps, uint16 capBps) {
        if (n == 0) return (0, uint16(Constants.BPS));
        uint256 cap = (Constants.BPS + n - 1) / n;
        capBps = cap > Constants.INDEX_CAP_FLOOR_BPS ? uint16(cap) : Constants.INDEX_CAP_FLOOR_BPS;
        uint256 floor_ = Constants.BPS / (2 * uint256(n));
        floorBps = floor_ < Constants.INDEX_FLOOR_CEILING_BPS ? uint16(floor_) : Constants.INDEX_FLOOR_CEILING_BPS;
    }

    /// @dev The `n` a weight for a constituent in `status` is measured against: the active count already includes
    ///      an active name, and excludes a retired one, which the reinstatement would add back.
    function _effectiveCount(ConstituentStatus status) private view returns (uint16 n) {
        n = status == ConstituentStatus.ACTIVE ? _activeCount : _activeCount + 1;
    }

    function _requireWeight(uint16 weightBps, uint16 n) private pure {
        (uint16 floorBps_, uint16 capBps_) = _weightBounds(n);
        if (weightBps < floorBps_ || weightBps > capBps_) revert WeightOutOfRange(weightBps, floorBps_, capBps_);
    }

    /// @dev The one place a governed value is checked against a hard band, so every band violation in this
    ///      contract reverts with the same shape: `OutOfBand(parameter, value, min, max)`, with the bound read
    ///      from `Constants` and never restated as a literal.
    function _checkBand(bytes32 parameter, uint256 value, uint256 min, uint256 max) private pure {
        if (value < min || value > max) revert OutOfBand(parameter, value, min, max);
    }

    /// @dev A pool's buy fee, against the band of the class it sits in.
    function _requireBuyFee(PoolClass class, uint16 buyFeeBps) private pure {
        (uint16 min, uint16 max) = class == PoolClass.ENTRY
            ? (Constants.BUY_FEE_BPS_ENTRY_MIN, Constants.BUY_FEE_BPS_ENTRY_MAX)
            : (Constants.BUY_FEE_BPS_SPOKE_MIN, Constants.BUY_FEE_BPS_SPOKE_MAX);
        _checkBand("buyFeeBps", buyFeeBps, min, max);
    }

    /// @dev The inclusion rule, exactly as published: `beta_i > 0.5 + sigma_u^2 / (2 sigma_I^2)`, a feed present
    ///      (checked by the caller) and at least `MIN_HISTORY_DAYS` of history. Failing the beta test is not fatal
    ///      — such a name still gets a pool, a seed ladder and a bond market — but it must carry zero rollout
    ///      weight, which is the only consequence the rule has on-chain.
    function _requireInclusion(InclusionRecord calldata record, uint16 rolloutWeightBps) private pure {
        _checkBand("historyDays", record.historyDays, Constants.MIN_HISTORY_DAYS, type(uint32).max);
        _checkBand("indexVolX18", record.indexVolX18, 1, type(uint64).max);
        if (rolloutWeightBps == 0) return;

        uint256 thresholdX18 = Constants.WAD / 2
            + Math.mulDiv(
                uint256(record.trackingErrorX18) * record.trackingErrorX18,
                Constants.WAD,
                2 * uint256(record.indexVolX18) * record.indexVolX18
            );
        if (record.betaX18 <= 0 || uint256(int256(record.betaX18)) <= thresholdX18) {
            revert BetaBelowThreshold(record.betaX18, thresholdX18);
        }
    }

    /// @dev The three structural requirements every Amplestocks pool key carries: AMPS is `currency0`, the fee is
    ///      the dynamic-fee flag, and the hook is ours. Tick spacing is checked here too because a key with an
    ///      unusable spacing cannot be initialised at all.
    function _validateKeyShape(PoolKey memory key, address counter) private view {
        if (Currency.unwrap(key.currency0) != _amps) revert InvalidPoolKey("currency0NotAmps");
        if (uint160(_amps) >= uint160(counter)) revert InvalidPoolKey("currencyOrder");
        if (!key.fee.isDynamicFee()) revert InvalidPoolKey("notDynamicFee");
        if (address(key.hooks) != _hook) revert InvalidPoolKey("hooks");
        if (key.tickSpacing < TickMath.MIN_TICK_SPACING || key.tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidPoolKey("tickSpacing");
        }
    }

    /// @dev Writes the pool record, its key and the pool counter. Shared by both registration paths, and always
    ///      run *before* the vault is called: `AmpsHook.beforeInitialize` calls back into {isRegistered} while the
    ///      pool is being initialised, so the record has to exist by then.
    function _registerPool(
        PoolKey memory key,
        PoolId poolId,
        address counter,
        PoolClass class,
        uint8 counterDecimals,
        uint16 buyFeeBps,
        uint16 constituentId
    ) private {
        if (_pools[poolId].registered) revert AlreadyInitialized();
        _pools[poolId] = PoolConfig({
            counter: counter,
            poolClass: class,
            counterDecimals: counterDecimals,
            tickSpacing: key.tickSpacing,
            buyFeeBps: buyFeeBps,
            constituentId: constituentId,
            registered: true,
            // The grid origin is derived from the price the pool actually opens at, which {_openPool} computes a
            // moment later; it is written there. It cannot be computed here, because the record has to exist
            // *before* the vault opens the pool — `AmpsHook.beforeInitialize` reads it back mid-initialisation.
            gridBaseTick: 0
        });
        _keys[poolId] = key;
        unchecked {
            _poolCount = _poolCount + 1;
        }
        emit PoolRegistered(poolId, counter, class, constituentId);
    }

    /// @dev Prices the pool at `P_ref / P_counter` and opens it through the vault — pool creation has to come
    ///      through there because `AmpsHook.beforeInitialize` requires `sender == vault` — then asserts the vault
    ///      opened the pool this registry recorded and mirrors the pool's canonical grid origin.
    ///
    ///      **The grid origin** (`docs/phase3-state-model.md` §3.2 and §10 ruling 14). Every vault position in the
    ///      pool lies on the lattice `[gridBase + m*D, gridBase + (m+1)*D)`, and `gridBase` is the opening tick
    ///      aligned **upward** to a whole tick spacing. The hook computes it in `afterInitialize`, which has
    ///      already run by the time `initializePool` returns, and this reads that value back rather than
    ///      re-deriving it from `sqrtPriceX96`. Two reasons, and the second is the one that matters: a second
    ///      implementation of `getTickAtSqrtPrice` here would cost 2.8 kB of EIP-170 headroom at this contract's
    ///      optimizer settings, and — far worse — two derivations can disagree, at which point the valuer
    ///      enumerates a lattice the vault never placed on. "Mirrored" is meant literally: there is exactly one
    ///      grid origin per pool and the hook owns it.
    ///
    ///      Before the hook exists (Phase 2, and any fixture that registers pools against a hookless address) the
    ///      mirror is skipped and `gridBaseTick` stays 0, which is correct: without a hook there is no grid. The
    ///      `extcodesize` guard is not decoration — a `staticcall` to an address with no code *succeeds* with
    ///      empty returndata, and a decode failure after a successful call is not catchable by `catch`.
    function _openPool(PoolKey memory key, PoolId poolId, address feed, uint8 counterDecimals) private {
        uint160 sqrtPriceX96 =
            PriceLib.ampsPerCounterToSqrtPriceX96(_referencePriceUsd18(), _feedAnswerUsd8(feed), counterDecimals);
        PoolId opened = IAmpsVault(_vault).initializePool(key, sqrtPriceX96);
        if (PoolId.unwrap(opened) != PoolId.unwrap(poolId)) revert InvalidPoolKey("poolIdMismatch");
        if (_hook.code.length != 0) {
            try IAmpsHook(_hook).gridBaseTick(poolId) returns (int24 gridBaseTick) {
                _pools[poolId].gridBaseTick = gridBaseTick;
            } catch {}
        }
        // The vault snaps the opening price down to the spacing-aligned tick so the grid origin sits exactly on it
        // (Phase 3 §12 ruling C). Emit what the pool actually opened at, read back from the PoolManager, rather
        // than the price this contract asked for, so the event and `slot0` can never disagree; a read that cannot
        // be made (a mock vault, no PoolManager) falls back to the requested price.
        uint160 openedAt = _openedPrice(poolId);
        emit PoolOpened(poolId, feed, openedAt == 0 ? sqrtPriceX96 : openedAt);
    }

    /// @dev `slot0.sqrtPriceX96` of a pool the vault has just opened, through one bounded `extsload` so that a vault
    ///      without a PoolManager (tests) or a manager that misbehaves can never make registration revert. Returns
    ///      0 when the read cannot be made.
    function _openedPrice(PoolId poolId) private view returns (uint160 sqrtPriceX96) {
        address manager;
        try IAmpsVault(_vault).poolManager() returns (address candidate) {
            manager = candidate;
        } catch {
            return 0;
        }
        if (manager.code.length == 0) return 0;
        (bool ok, bytes memory data) = manager.staticcall{gas: 30_000}(
            abi.encodeWithSignature("extsload(bytes32)", PoolStateLib.poolStateSlot(poolId))
        );
        if (!ok || data.length != 32) return 0;
        sqrtPriceX96 = uint160(uint256(abi.decode(data, (bytes32))));
    }

    /// @dev The reference price the initial pool price is anchored at. Before `genesis()` the vault has no
    ///      checkpoint and reports zero; the launch price is $1.00 = NAV/share by construction (Decision 12), and
    ///      the two entry pools are registered in that window.
    function _referencePriceUsd18() private view returns (uint256 pRefUsd18) {
        pRefUsd18 = IAmpsVault(_vault).pRefX18();
        if (pRefUsd18 == 0) pRefUsd18 = Constants.WAD;
    }

    /// @dev `AmpsBonds`, read from the vault rather than stored: the vault is the system of record for every
    ///      protocol pointer, and the registry's documented layout has no slot for a second one.
    function _bonds() private view returns (address bonds) {
        bonds = IAmpsVault(_vault).bonds();
        if (bonds == address(0)) revert ZeroAddress();
    }

    /// @dev Validates an aggregator and returns its current answer in 8-decimal USD.
    function _feedAnswerUsd8(address feed) private view returns (uint256 answerUsd8) {
        if (feed == address(0)) revert ZeroAddress();
        if (IAggregatorV3(feed).decimals() != 8) revert InvalidFeed(feed, "decimals");
        _requireStandardProxy(feed);

        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert InvalidFeed(feed, "answer");
        answerUsd8 = uint256(answer);
    }

    /// @dev Rejects a Chainlink SVR (Smart Value Recapture) proxy, which reports the same pair as the Standard
    ///      proxy but with OEV recapture semantics the protocol must not depend on. There is no on-chain type
    ///      discriminator, so this reads the aggregator's own `description()` — the one field Chainlink marks SVR
    ///      feeds in — behind a bounded, failure-tolerant staticcall. It is defence in depth, not the primary
    ///      control: the authoritative Standard-vs-SVR resolution is the Reference Data Directory pin recorded in
    ///      `packages/config` and reviewed with the 7-day proposal.
    function _requireStandardProxy(address feed) private view {
        (bool ok, bytes memory data) =
            feed.staticcall{gas: Constants.STOCK_TOKEN_PROBE_GAS}(abi.encodeCall(IAggregatorV3.description, ()));
        // A feed that does not answer, or answers with something that is not a plausibly encoded short string,
        // proves nothing either way and is left to the reviewed RDD pin. The return data is therefore parsed by
        // hand rather than through `abi.decode`, which would turn a malformed answer into a revert.
        if (!ok || data.length < 96 || data.length > 320) return;

        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            length := mload(add(data, 0x40))
        }
        if (offset != 0x20 || length < 3 || length + 0x40 > data.length) return;

        for (uint256 i; i + 3 <= length; ++i) {
            bytes3 window;
            assembly ("memory-safe") {
                // `data` is `bytes memory`: 0x20 skips its length, 0x40 more skips the string's offset and length
                // words. `bytesN` is left-aligned, so the load is exactly the three characters at `i`.
                window := mload(add(add(data, 0x60), i))
            }
            if (window == "SVR") revert NotStandardProxy(feed);
        }
    }

    /// @dev ERC-20 decimals of a pool's counter asset, bounded by what `PriceLib` accepts.
    function _tokenDecimals(address token) private view returns (uint8 decimals) {
        decimals = IERC20Metadata(token).decimals();
        if (decimals > PriceLib.MAX_COUNTER_DECIMALS) revert InvalidPoolKey("counterDecimals");
    }

    /// @dev Reverts unless `constituentId` names a registered constituent.
    function _requireKnown(uint16 constituentId) private view returns (ConstituentConfig storage config) {
        config = _constituents[constituentId];
        if (config.status == ConstituentStatus.NONE) revert UnknownConstituent(constituentId);
    }

    /// @dev The read-side freeze overlay: a governance-forced corporate-action freeze, or a `freezeUntil` stamp in
    ///      the future. The guardian's own freeze lives in `OracleGate`.
    function _isFrozen(ConstituentConfig memory config) private view returns (bool frozen) {
        frozen = config.caFreezeOverride || config.freezeUntil > block.timestamp;
    }

    /// @dev One `ConstituentReconfigured` per applied field, so the indexer never has to diff state to learn what
    ///      a proposal actually changed.
    function _emitField(uint16 constituentId, bytes32 field, uint256 previousValue, uint256 newValue) private {
        emit ConstituentReconfigured(constituentId, field, previousValue, newValue);
    }
}
