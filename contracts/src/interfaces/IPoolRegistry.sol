// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ConstituentConfig, ConstituentStatus, InclusionRecord, PoolClass, PoolConfig} from "../types/Types.sol";

/// @title IPoolRegistry
/// @notice The allowlist and the index. Immutable bytecode, timelock-governed state: which 32 pools exist, which
///         Stock Tokens are constituents, what each one weighs and what fee bucket its pool sits in.
///
/// @dev **The set is dynamic (Decision 19).** The 30 launch names are a starting point, not a fixture: the 7-day
///      timelock can {addConstituent}, {retireConstituent}, {reinstateConstituent} and {reconfigureConstituent} up
///      to `MAX_CONSTITUENTS` = 64. Every action emits an event, records its inputs, and **leaves NAV/share
///      unchanged** — invariant I37 asserts that no lifecycle action moves NAV/share by more than rounding dust or
///      moves a counter-asset anywhere except into the same pool's bids or into idle claims.
///
/// @dev **Ids are 1-based.** `constituentId == 0` means "not a constituent", which is what the entry pools carry.
///      An id is never reused: retiring frees no id, because a v4 pool cannot be deleted and the pool must stay
///      addressable as an exit market.
///
/// @dev **What each lifecycle action actually does.**
///
///      | Action | Pool | Bond market | Rollout weight | Existing liquidity |
///      |---|---|---|---|---|
///      | add | initialised through the hook (`sender == vault`) | opened | set | seeded from the next rollout at `spokeSeedBps` |
///      | retire | flagged `RETIRED`; fee wall and gates stay live | closed to new bonds; vesting claims complete | zeroed | unfilled asks returned to the entry pools; **bids left in place as an exit market** |
///      | reinstate | unchanged | reopened | restored | untouched |
///      | reconfigure | fee bucket may change | parameters may change | may change | untouched |
///
/// @dev **The guardian may only freeze.** It cannot add, retire, reinstate, reconfigure, or move a fund. A freeze
///      lives in `OracleGate` and expires by itself; the registry reflects it as `ConstituentStatus.FROZEN`.
interface IPoolRegistry {
    /// @notice Arguments to {addConstituent}. A struct because the 7-day proposal is built off-chain and reviewed
    ///         as one object.
    /// @param token The Stock Token.
    /// @param feed The Chainlink Standard proxy for `token`. SVR proxies are rejected.
    /// @param poolClass `SPOKE` or `SPOKE_HIGH_VOL`; `ENTRY` is rejected here.
    /// @param tickSpacing The pool's tick spacing.
    /// @param buyFeeBps The pool's buy fee, inside the class's band.
    /// @param targetWeightBps The index target weight, inside `[floor_n, cap_n]` for the resulting `n`.
    /// @param rolloutWeightBps The share of the daily rollout budget. Pass 0 for a name that fails the beta test:
    ///        it still gets a pool, a seed ladder and a bond market, but no rollout.
    /// @param hSessionOverrideBps A per-constituent bond haircut override, or 0.
    /// @param hSessionOverrideSet Whether the override applies.
    /// @param inclusion The inclusion-rule evidence recorded on-chain with the registration.
    /// @param openBondMarket Whether to open a bond market for the name in the same proposal.
    struct AddConstituentParams {
        address token;
        address feed;
        PoolClass poolClass;
        int24 tickSpacing;
        uint16 buyFeeBps;
        uint16 targetWeightBps;
        uint16 rolloutWeightBps;
        uint16 hSessionOverrideBps;
        bool hSessionOverrideSet;
        InclusionRecord inclusion;
        bool openBondMarket;
    }

    /// @notice Arguments to {reconfigureConstituent}. Every field is optional through its `set` flag, so a proposal
    ///         changes exactly what it names and nothing else.
    /// @param setPoolClass Whether to change the fee bucket.
    /// @param poolClass The new class.
    /// @param setBuyFeeBps Whether to change the buy fee.
    /// @param buyFeeBps The new buy fee, inside the class's band.
    /// @param setTargetWeightBps Whether to change the index weight.
    /// @param targetWeightBps The new weight.
    /// @param setRolloutWeightBps Whether to change the rollout weight.
    /// @param rolloutWeightBps The new rollout weight.
    /// @param setFeed Whether to change the feed.
    /// @param feed The new Chainlink Standard proxy.
    /// @param setHSessionOverride Whether to change the haircut override.
    /// @param hSessionOverrideBps The new override.
    /// @param hSessionOverrideSet Whether the override is active after the change.
    /// @param setCaFreezeOverride Whether to change the forced corporate-action freeze.
    /// @param caFreezeOverride The new forced-freeze flag.
    struct ReconfigureParams {
        bool setPoolClass;
        PoolClass poolClass;
        bool setBuyFeeBps;
        uint16 buyFeeBps;
        bool setTargetWeightBps;
        uint16 targetWeightBps;
        bool setRolloutWeightBps;
        uint16 rolloutWeightBps;
        bool setFeed;
        address feed;
        bool setHSessionOverride;
        uint16 hSessionOverrideBps;
        bool hSessionOverrideSet;
        bool setCaFreezeOverride;
        bool caFreezeOverride;
    }

    /// @notice Emitted when a constituent joins the index.
    /// @param constituentId The new 1-based id.
    /// @param token The Stock Token.
    /// @param poolId The initialised `AMPS/<stock>` pool.
    /// @param targetWeightBps The index target weight.
    event ConstituentAdded(
        uint16 indexed constituentId, address indexed token, PoolId indexed poolId, uint16 targetWeightBps
    );

    /// @notice Emitted when a constituent is retired.
    /// @param constituentId The constituent.
    /// @param token The Stock Token.
    event ConstituentRetired(uint16 indexed constituentId, address indexed token);

    /// @notice Emitted when a retirement is reversed.
    /// @param constituentId The constituent.
    /// @param rolloutWeightBps The restored rollout weight.
    event ConstituentReinstated(uint16 indexed constituentId, uint16 rolloutWeightBps);

    /// @notice Emitted for every applied field of a {reconfigureConstituent} call.
    /// @param constituentId The constituent.
    /// @param field The field name as a short string, e.g. `bytes32("buyFeeBps")`.
    /// @param previousValue The value before, as `uint256`.
    /// @param newValue The value after, as `uint256`.
    event ConstituentReconfigured(
        uint16 indexed constituentId, bytes32 indexed field, uint256 previousValue, uint256 newValue
    );

    /// @notice Emitted when the registry observes a guardian freeze on a constituent.
    /// @param constituentId The constituent.
    /// @param until The freeze expiry.
    event ConstituentFrozen(uint16 indexed constituentId, uint32 until);

    /// @notice Emitted when a pool is registered, entry pools included.
    /// @param poolId The pool.
    /// @param counter The pool's `currency1`.
    /// @param poolClass The fee bucket.
    /// @param constituentId The constituent id, or 0 for an entry pool.
    event PoolRegistered(PoolId indexed poolId, address indexed counter, PoolClass poolClass, uint16 constituentId);

    /// @notice Emitted when the index weight vector is replaced wholesale by the quarterly rule.
    /// @param ids The constituents re-weighted.
    /// @param weightsBps The new weights, parallel to `ids`.
    event IndexWeightsSet(uint16[] ids, uint16[] weightsBps);

    /// @notice The constituent set is full.
    /// @param max `MAX_CONSTITUENTS`.
    error ConstituentSetFull(uint16 max);

    /// @notice The token is already a constituent.
    /// @param token The token.
    /// @param constituentId Its existing id.
    error ConstituentExists(address token, uint16 constituentId);

    /// @notice The lifecycle action is not valid from the constituent's current status.
    /// @param constituentId The constituent.
    /// @param status Its current status.
    error InvalidStatusTransition(uint16 constituentId, ConstituentStatus status);

    /// @notice The pool key does not satisfy the registry's structural requirements: `currency0 == AMPS`, the
    ///         dynamic-fee flag, and `hooks == AmpsHook`.
    /// @param reason A short identifier, e.g. `bytes32("currency0NotAmps")`.
    error InvalidPoolKey(bytes32 reason);

    /// @notice The proposed weight is outside `[floor_n, cap_n]` for the current constituent count.
    /// @param weightBps The rejected weight.
    /// @param floorBps The floor for the current `n`.
    /// @param capBps The cap for the current `n`.
    error WeightOutOfRange(uint16 weightBps, uint16 floorBps, uint16 capBps);

    // -------------------------------------------------------------------------------------------------------------
    // Reads (permissionless)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The registry record for a pool.
    /// @param poolId The pool.
    /// @return config The record; `config.registered == false` when unknown.
    function poolConfig(PoolId poolId) external view returns (PoolConfig memory config);

    /// @notice The stored `PoolKey` for a registered pool, so callers can rebuild it without an event scan.
    /// @param poolId The pool.
    /// @return key The pool key.
    function poolKey(PoolId poolId) external view returns (PoolKey memory key);

    /// @notice The record for a constituent.
    /// @param constituentId The 1-based id.
    /// @return config The record; `config.status == NONE` when unknown.
    function constituent(uint16 constituentId) external view returns (ConstituentConfig memory config);

    /// @notice The inclusion-rule evidence recorded at registration.
    /// @param constituentId The 1-based id.
    /// @return record The evidence.
    function inclusionRecord(uint16 constituentId) external view returns (InclusionRecord memory record);

    /// @notice The constituent id for a Stock Token, or 0.
    /// @param token The token.
    /// @return constituentId The 1-based id.
    function constituentIdOf(address token) external view returns (uint16 constituentId);

    /// @notice The pool a constituent trades in.
    /// @param constituentId The 1-based id.
    /// @return poolId The `AMPS/<stock>` pool.
    function poolIdOf(uint16 constituentId) external view returns (PoolId poolId);

    /// @notice The constituent behind a pool, or 0 for an entry pool.
    /// @param poolId The pool.
    /// @return constituentId The 1-based id.
    function constituentOfPool(PoolId poolId) external view returns (uint16 constituentId);

    /// @notice The `AMPS/USDG` settlement hub: the pool `P_mkt` is read from.
    /// @return poolId The hub pool.
    function hubPoolId() external view returns (PoolId poolId);

    /// @notice The `AMPS/WETH` main speculative route, used for the reference cross-check.
    /// @return poolId The WETH entry pool.
    function wethPoolId() external view returns (PoolId poolId);

    /// @notice How many constituents have ever been registered, retired ones included. Ids run `[1, count]`.
    /// @return count The constituent count.
    function constituentCount() external view returns (uint16 count);

    /// @notice How many constituents are currently `ACTIVE`. This is the `n` the index cap and floor use.
    /// @return count The active count.
    function activeConstituentCount() external view returns (uint16 count);

    /// @notice How many pools are registered. 32 at launch.
    /// @return count The pool count.
    function poolCount() external view returns (uint16 count);

    /// @notice The index weight cap for the current `n`: `max(3000, ceilDiv(10000, n))` bps.
    /// @return capBps The cap.
    function indexCapBps() external view returns (uint16 capBps);

    /// @notice The index weight floor for the current `n`: `min(500, 10000 / (2n))` bps.
    /// @return floorBps The floor.
    function indexFloorBps() external view returns (uint16 floorBps);

    /// @notice Whether a pool is one of ours. Read by the hook in `beforeInitialize`.
    /// @param poolId The pool.
    /// @return registered Whether the pool is registered.
    function isRegistered(PoolId poolId) external view returns (bool registered);

    /// @notice The vault: the only address the hook accepts as an initialiser or a liquidity provider.
    /// @return vaultAddress The vault address.
    function vault() external view returns (address vaultAddress);

    /// @notice The hook every registered pool must carry.
    /// @return hookAddress The hook address.
    function hook() external view returns (address hookAddress);

    // -------------------------------------------------------------------------------------------------------------
    // Hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Hard ceiling on the constituent set. 64.
    /// @return value The bound.
    function MAX_CONSTITUENTS() external view returns (uint16 value);

    /// @notice Hard floor of an entry pool's buy fee, in bps. 5.
    /// @return value The bound.
    function BUY_FEE_BPS_ENTRY_MIN() external view returns (uint16 value);

    /// @notice Hard ceiling of an entry pool's buy fee, in bps. 100.
    /// @return value The bound.
    function BUY_FEE_BPS_ENTRY_MAX() external view returns (uint16 value);

    /// @notice Hard floor of a spoke's buy fee, in bps. 1.
    /// @return value The bound.
    function BUY_FEE_BPS_SPOKE_MIN() external view returns (uint16 value);

    /// @notice Hard ceiling of a spoke's buy fee, in bps. 50.
    /// @return value The bound.
    function BUY_FEE_BPS_SPOKE_MAX() external view returns (uint16 value);

    /// @notice Minimum days of price history the inclusion rule requires. 30.
    /// @return value The bound.
    function MIN_HISTORY_DAYS() external view returns (uint32 value);

    // -------------------------------------------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Registers one of the two entry pools. **Only timelock (7 d).** Used once each at deployment.
    /// @param key The pool key. `currency0` must be AMPS and `currency1` must be WETH9 or USDG.
    /// @param counterDecimals The counter asset's decimals (18 for WETH, 6 for USDG).
    /// @param buyFeeBps The entry buy fee, inside `[BUY_FEE_BPS_ENTRY_MIN, BUY_FEE_BPS_ENTRY_MAX]`.
    /// @param feed The counter asset's Chainlink feed.
    function registerEntryPool(PoolKey calldata key, uint8 counterDecimals, uint16 buyFeeBps, address feed) external;

    /// @notice Adds a constituent: initialises its pool through the hook, records the inclusion evidence, sets its
    ///         weights and optionally opens its bond market. **Only timelock (7 d).**
    /// @dev The pool initialisation is performed by the vault (`sender == vault` in `beforeInitialize`), so the
    ///      registry calls into the vault rather than the PoolManager directly. The seed ask arrives with the next
    ///      rollout at `spokeSeedBps` of the entry-pool inventory; nothing is placed inside this call.
    /// @param params The registration arguments.
    /// @return constituentId The new 1-based id.
    /// @return poolId The initialised pool.
    function addConstituent(AddConstituentParams calldata params) external returns (uint16 constituentId, PoolId poolId);

    /// @notice Retires a constituent. **Only timelock (7 d).** Closes the bond market to new bonds, zeroes the
    ///         rollout weight, returns unfilled ask buckets to the entry pools and leaves the bids as an exit
    ///         market. Vesting claims on that market always complete (I38).
    /// @param constituentId The constituent.
    function retireConstituent(uint16 constituentId) external;

    /// @notice Reverses a retirement. **Only timelock (7 d).**
    /// @param constituentId The constituent.
    /// @param rolloutWeightBps The rollout weight to restore.
    function reinstateConstituent(uint16 constituentId, uint16 rolloutWeightBps) external;

    /// @notice Changes a constituent's configuration. **Only timelock (7 d).** Every per-parameter hard band is
    ///         enforced in the consuming contract, not only here.
    /// @param constituentId The constituent.
    /// @param params The fields to change.
    function reconfigureConstituent(uint16 constituentId, ReconfigureParams calldata params) external;

    /// @notice Replaces the index weight vector by the published quarterly rule. **Only timelock (7 d).**
    /// @param ids The constituents to re-weight.
    /// @param weightsBps The new weights, parallel to `ids`, each inside `[indexFloorBps, indexCapBps]`.
    function setIndexWeights(uint16[] calldata ids, uint16[] calldata weightsBps) external;

    /// @notice Moves unfilled bid inventory out of a retired spoke into idle claims, where it is valued in `A` and
    ///         paid out by redemption. **Only timelock (7 d).**
    /// @param constituentId The retired constituent.
    function withdrawRetiredBids(uint16 constituentId) external;
}
