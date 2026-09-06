// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmps} from "../interfaces/IAmps.sol";
import {IAmpsBonds} from "../interfaces/IAmpsBonds.sol";
import {IAmpsStaking} from "../interfaces/IAmpsStaking.sol";
import {IAmpsVault} from "../interfaces/IAmpsVault.sol";
import {IBountyPot} from "../interfaces/IBountyPot.sol";
import {IOracleGate} from "../interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {Constants} from "../types/Constants.sol";
import {
    AlreadyInitialized,
    GateNotHealthy,
    LengthMismatch,
    NavBleedExceeded,
    NotBonds,
    NotCreator,
    NotGuardian,
    NotPoolManager,
    NotRegistry,
    NotTimelock,
    OutOfBand,
    Reentrancy,
    SweepDirty,
    ZeroAddress,
    ZeroAmount
} from "../types/Errors.sol";
import {Checkpoint, GateState, PlacementRecord} from "../types/Types.sol";
import {VaultNavLib} from "./VaultNavLib.sol";
import {VaultPlacementLib} from "./VaultPlacementLib.sol";
import {VaultRedeemLib} from "./VaultRedeemLib.sol";
import {VaultRolloutLib} from "./VaultRolloutLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title AmpsVault
/// @notice The Phase 2 custody boundary, NAV authority, reference price, redemption floor and sole
///         `IUnlockCallback`. See `docs/phase2-state-model.md` sections 1.1, 2, 3, 4, 5, 7, 8 and 9 — this contract
///         is the executable form of those sections and the storage layout below is asserted slot for slot by
///         `test/unit/VaultLayout.t.sol`.
///
/// @dev **What Phase 2 implements.** Genesis, NAV and the reference price, pro-rata redemption, the bonded-deposit
///      and vesting-mint entry points for `AmpsBonds`, pool initialisation for `PoolRegistry`, the governed
///      parameter set with its hard bands, the standby registration and the predicate-gated emergency migration.
///      `place`, `compound`, `rollout`, `deployBonded` and `withdrawRetiredBids` are declared so that the ABI is
///      final, and revert with {Phase3NotImplemented} until the hook and the ladder exist; their setters are live
///      now, with bands.
///
/// @dev **The read side lives in {VaultNavLib}**, a linked library reached by `DELEGATECALL`: `A`, `P_mkt`, the
///      reference overrides, the inventory disclosure and the migration predicate. It is part of this contract for
///      every governance purpose — the address is fixed at link time and holds no storage — and the split exists
///      because the whole of `IAmpsVault` does not fit EIP-170 with that arithmetic inlined. Splitting the reads
///      out rather than the writes is what keeps {redeemProRata} self-contained.
///
/// @dev **What is structurally ungated.** {redeemProRata} contains no reference to the oracle gate, the feed
///      registry, the pool registry, the guardian, the standby vault, a freeze timestamp, a pause flag or any
///      price. It reads the vault's own asset list, the vault's own balances and `Amps.totalSupply()`, and nothing
///      else. The transient reentrancy lock is still taken: a lock nobody else can hold, released in the same
///      transaction, is not a gate (section 7).
///
/// @dev **Two deliberate deviations from a literal reading of section 7**, both documented in the Phase 2 report:
///        1. There are two gate policies, not one. `_requireHealthy` refuses `DEGRADED`, `DIVERGED`,
///           `SCHEDULED_FREEZE` and `WATCHDOG` — the four states section 7 step 2 forces — and passes `GREEN` and
///           `REF_DIVERGED`. {depositBonded} and {mintVesting} instead take `_requireBondsHealthy`, which refuses
///           only `DIVERGED` and `SCHEDULED_FREEZE`: bond markets stay open 24/7 through stale feeds and closed
///           sessions and price the haircut instead (the plan's Decision 10 and section 2's own table), so the
///           management policy would be stricter than the design rather than safer.
///        2. {emergencyMigrate} is not `_requireHealthy`-gated. It is gated by the on-chain denylist predicate,
///           which is strictly narrower, and the incident it exists for (an issuer denylisting the vault while
///           pausing its oracle) is precisely a state in which `_requireHealthy` would refuse. Gating it would
///           brick the evacuation path of an immutable contract.
///        3. A gate pointer that *reverts* is read as absent rather than as a refusal. The gate is the one pointer
///           that can refuse every governance call; if a broken one refused, nobody could call `setPolicyPointer`
///           to replace it and a fund-less contract would have bricked the protocol. Failing open here grants an
///           attacker nothing they would not already have with a `GREEN` gate.
contract AmpsVault is IAmpsVault, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------------------------------------------
    // Transient slots (EIP-1153), `keccak256("amplestocks.vault.<name>")`, hard-coded (section 1.1)
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `keccak256("amplestocks.vault.REENTRANCY_LOCK")`. Taken by every external function, {redeemProRata}
    ///      included. Declared once, in {VaultRedeemLib}, for the reason {UNLOCK_ACTION} gives.
    uint256 private constant REENTRANCY_LOCK = VaultRedeemLib.REENTRANCY_LOCK;

    /// @dev `keccak256("amplestocks.vault.UNLOCK_ACTION")`. The discriminator the sole `IUnlockCallback`
    ///      dispatches on; zero outside an unlock this contract started. **Read from {VaultRedeemLib} rather than
    ///      restated here**: the three linked libraries set it before their own `unlock` calls, and a second copy
    ///      of the number is a second thing that can drift.
    uint256 private constant UNLOCK_ACTION = VaultRedeemLib.UNLOCK_ACTION;

    /// @dev `keccak256("amplestocks.vault.NAV_BEFORE")`. NAV/share captured at entry for the R1 post-condition,
    ///      used by the relaxed migration bleed bound. Declared once, in {VaultRedeemLib}.
    uint256 private constant NAV_BEFORE = VaultRedeemLib.NAV_BEFORE;

    /// @dev The unlock action set lives in {VaultRedeemLib}, which is the one library both the placement path and
    ///      the ungated redemption path may reference, so the discriminators have exactly one home. `ACTION_SETTLE`
    ///      = 1, `ACTION_PAYOUT` = 2, `ACTION_ABSORB` = 3 are Phase 2's; `ACTION_PLACE` = 4, `ACTION_COMPOUND` = 5,
    ///      `ACTION_BURNBACK` = 6, `ACTION_UNWIND` = 7 and `ACTION_HARVEST` = 8 are the Phase 3 set of §3.9.
    ///
    /// @dev slot `keccak256("amplestocks.vault.poolKeys")` — the vault's own list of every `PoolKey` it has
    ///      opened, appended by {initializePool}.
    ///
    ///      **Why a hashed slot and not slot 21.** `redeemProRata` needs a `PoolKey` per pool to remove liquidity,
    ///      and reading one from `PoolRegistry` would put a registry `SLOAD` on the one structurally ungated path
    ///      in the protocol (Phase 2 §7, and `test/unit/GuardSymmetry.t.sol` proves the absence at the storage
    ///      level). The vault therefore keeps its own copy — exactly as it already keeps its own asset list, and
    ///      for exactly the same reason. Hashing the slot rather than appending to the sequential layout keeps
    ///      section 1.1's "the layout ends at slot 20" literally true, which is what a standby vault is written
    ///      against.
    bytes32 private constant POOL_KEYS_SLOT = keccak256("amplestocks.vault.poolKeys");

    // -------------------------------------------------------------------------------------------------------------
    // Storage — the layout of section 1.1, slot for slot
    // -------------------------------------------------------------------------------------------------------------

    /// @dev slot 0 [0..127] — NAV per share, USD per AMPS, 18 decimals.
    uint128 private _navPerShareX18;
    /// @dev slot 0 [128..255] — the reference price, USD per AMPS, 18 decimals.
    uint128 private _pRefX18;

    /// @dev slot 1 [0..127] — the market price, USD per AMPS, 18 decimals.
    uint128 private _pMktX18;
    /// @dev slot 1 [128..159] — when the checkpoint was written.
    uint32 private _checkpointTimestamp;
    /// @dev slot 1 [160..191] — `uint32(block.number)` at the checkpoint, for the layer-A watchdog.
    uint32 private _checkpointBlock;
    /// @dev slot 1 [192..255] — reserved, and declared rather than implied: section 1.1 leaves the top 64 bits of
    ///      the checkpoint's second word free, and without this filler Solidity would pack the first four governed
    ///      `uint16`s in here and shift the whole of slot 2 down by four fields.
    uint64 private _checkpointReserved;

    /// @dev slot 2 [0..15] — the redemption fee in bps.
    uint16 private _redeemFeeBps;
    /// @dev slot 2 [16..31] — share of AMPS-side fees burned at `compound()`.
    uint16 private _burnBps;
    /// @dev slot 2 [32..47] — share of AMPS-side fees streamed to xAMPS.
    uint16 private _stakerBps;
    /// @dev slot 2 [48..63] — maximum upward move of `P_ref` per hour, in bps.
    uint16 private _refUpRateBps;
    /// @dev slot 2 [64..79] — hub-versus-WETH reference divergence threshold, in bps.
    uint16 private _refDivergenceBps;
    /// @dev slot 2 [80..111] — the TWAP window `P_mkt` is read over.
    uint32 private _twapWindow;
    /// @dev slot 2 [112..175] — ladder tilt for future placements. Phase 3.
    uint64 private _ladderTiltX18;
    /// @dev slot 2 [176..183] — ask ladder bucket count. Phase 3.
    uint8 private _ladderDoublings;
    /// @dev slot 2 [184..191] — seed bid ladder bucket count. Phase 3.
    uint8 private _seedHalvings;
    /// @dev slot 2 [192..199] — bonded bid ladder bucket count. Phase 3.
    uint8 private _bondBidHalvings;
    /// @dev slot 2 [200..215] — the seed ask a new spoke receives, in bps of entry inventory. Phase 3.
    uint16 private _spokeSeedBps;
    /// @dev slot 2 [216..231] — daily rollout budget, in bps of the POL tranche. Phase 3.
    uint16 private _rolloutBpsPerDay;
    /// @dev slot 2 [232..247] — entry-pool inventory floor, in bps of the POL tranche. Phase 3.
    uint16 private _entryFloorBps;

    /// @dev slot 3 [0..159] — the creator fee recipient.
    address private _creator;
    /// @dev slot 3 [160..191] — when {genesis} ran.
    uint32 private _genesisTimestamp;
    /// @dev slot 3 [192..199] — the genesis latch, one-way.
    bool private _initialized;
    /// @dev slot 3 [200..207] — set by {genesis}; the set-once pointers refuse afterwards.
    bool private _wiringFrozen;

    /// @dev slot 4 — the pool registry. Set-once.
    address private _registry;
    /// @dev slot 5 — the bonds shell. Set-once.
    address private _bonds;
    /// @dev slot 6 — the xAMPS staking vault. Set-once.
    address private _staking;
    /// @dev slot 7 — the keeper bounty pot. Set-once.
    address private _bountyPot;

    /// @dev slot 8 — the market reference: a mock in Phase 2, re-pointed once to `AmpsHook` under the timelock.
    address private _marketReference;

    /// @dev slot 9 — the oracle gate. Pointer-upgradeable (7 d).
    address private _oracleGate;
    /// @dev slot 10 — the feed registry. Pointer-upgradeable (7 d).
    address private _feedRegistry;
    /// @dev slot 11 — the position valuer. Pointer-upgradeable (7 d); the zero-position stub in Phase 2.
    address private _positionValuer;
    /// @dev slot 12 — the ladder policy. Pointer-upgradeable (7 d). Phase 3.
    address private _ladderPolicy;
    /// @dev slot 13 — the rollout policy. Pointer-upgradeable (7 d). Phase 3.
    address private _rolloutPolicy;

    /// @dev slot 14 — the pre-registered standby vault (14-day timelock).
    address private _standbyVault;

    /// @dev slot 15 [0..127] — AMPS wei moved by rollout in the current window. Phase 3.
    uint128 private _rolloutMoved24h;
    /// @dev slot 15 [128..159] — start of the current rollout window. Phase 3.
    uint32 private _rolloutWindowStart;

    /// @dev slot 16 — the registered non-AMPS assets, in registration order. The enumeration the NAV sum and
    ///      {redeemProRata} walk; the only list either of them reads.
    address[] private _assets;

    /// @dev slot 17 — 1-based index into {_assets}; 0 means "not an asset".
    mapping(address token => uint256 index) private _assetIndex;

    /// @dev slot 18 — placed ladder buckets per pool. Phase 3. Two slots per record, exactly as section 1.1 gives
    ///      it: `Types.PlacementRecord` is the layout itself rather than a struct this contract mirrors, so there
    ///      is no second declaration to keep in step and no storage-to-memory conversion written by hand.
    ///
    ///      **`public`, and that is the implementation of {IAmpsVault-ladderAt}** (ruling 1). Solidity's generated
    ///      getter returns the record's fields flattened, which is 234 bytes smaller than the hand-written
    ///      `PlacementRecord memory` form and 234 bytes is a fifth of this contract's entire EIP-170 headroom.
    ///      The mapping is still only ever *written* by the placement path.
    mapping(PoolId poolId => PlacementRecord[] buckets) public ladderAt;

    /// @dev slot 19 — last placement timestamp per pool, for the 60-second cooldown. Phase 3.
    mapping(PoolId poolId => uint32 at) private _lastPlacementAt;

    /// @dev slot 20 — the idle-collateral floor {deployBonded} refuses to fire below, in 18-decimal USD. Phase 3,
    ///      `docs/phase3-state-model.md` §10 ruling 15. Appended rather than packed into slot 15's free upper 96
    ///      bits so that section 1.1's documented layout for slots 0-19 stays literally true; the parameter is read
    ///      once per `deployBonded` and never on a swap, a bond or a redemption, so a dedicated word costs nothing
    ///      that matters.
    uint256 private _deployThresholdUsd18;

    // -------------------------------------------------------------------------------------------------------------
    // Immutables (bytecode, no slot)
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The AMPS token, CREATE2-mined before this contract is deployed.
    address private immutable _AMPS;
    /// @dev The Uniswap v4 PoolManager.
    address private immutable _POOL_MANAGER;
    /// @dev The governance timelock: the sole caller of every `set*`.
    address private immutable _TIMELOCK;
    /// @dev The guardian Safe: disable-only freezes and the predicate-gated migration trigger.
    address private immutable _GUARDIAN;

    // -------------------------------------------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------------------------------------------

    /// @param amps_ The AMPS token address, mined ahead of this deployment.
    /// @param poolManager_ The Uniswap v4 PoolManager.
    /// @param timelock_ The governance timelock.
    /// @param guardian_ The guardian Safe.
    constructor(address amps_, address poolManager_, address timelock_, address guardian_) {
        if (amps_ == address(0) || poolManager_ == address(0) || timelock_ == address(0) || guardian_ == address(0)) {
            revert ZeroAddress();
        }
        _AMPS = amps_;
        _POOL_MANAGER = poolManager_;
        _TIMELOCK = timelock_;
        _GUARDIAN = guardian_;

        _redeemFeeBps = Constants.REDEEM_FEE_BPS_DEFAULT;
        _burnBps = Constants.BURN_BPS_DEFAULT;
        _stakerBps = Constants.STAKER_BPS_DEFAULT;
        _refUpRateBps = Constants.REF_UP_RATE_BPS_DEFAULT;
        _refDivergenceBps = Constants.REF_DIVERGENCE_BPS_DEFAULT;
        _twapWindow = Constants.TWAP_WINDOW_DEFAULT;
        _ladderTiltX18 = Constants.LADDER_TILT_X18_DEFAULT;
        _ladderDoublings = Constants.LADDER_DOUBLINGS_DEFAULT;
        _seedHalvings = Constants.SEED_HALVINGS_DEFAULT;
        _bondBidHalvings = Constants.BOND_BID_HALVINGS_DEFAULT;
        _spokeSeedBps = Constants.SPOKE_SEED_BPS_DEFAULT;
        _rolloutBpsPerDay = Constants.ROLLOUT_BPS_PER_DAY_DEFAULT;
        _entryFloorBps = Constants.ENTRY_FLOOR_BPS_DEFAULT;
        _deployThresholdUsd18 = Constants.DEPLOY_THRESHOLD_USD18_DEFAULT;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Modifiers and guards
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The EIP-1153 transient lock. Taken by every external entry point including {redeemProRata}: nobody else
    ///      can hold it and it is released in the same transaction, so it is a lock and not a gate (section 7).
    modifier locked() {
        uint256 lockSlot = REENTRANCY_LOCK;
        assembly ("memory-safe") {
            if tload(lockSlot) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(lockSlot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(lockSlot, 0)
        }
    }

    /// @dev Only the governance timelock.
    modifier onlyTimelock() {
        if (msg.sender != _TIMELOCK) revert NotTimelock(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reads — wiring
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsVault
    function amps() external view returns (address ampsAddress) {
        return _AMPS;
    }

    /// @inheritdoc IAmpsVault
    function poolManager() external view returns (address poolManagerAddress) {
        return _POOL_MANAGER;
    }

    /// @inheritdoc IAmpsVault
    function registry() external view returns (address registryAddress) {
        return _registry;
    }

    /// @inheritdoc IAmpsVault
    function bonds() external view returns (address bondsAddress) {
        return _bonds;
    }

    /// @inheritdoc IAmpsVault
    function staking() external view returns (address stakingAddress) {
        return _staking;
    }

    /// @inheritdoc IAmpsVault
    function bountyPot() external view returns (address bountyPotAddress) {
        return _bountyPot;
    }

    /// @inheritdoc IAmpsVault
    function marketReference() external view returns (address marketReferenceAddress) {
        return _marketReference;
    }

    /// @inheritdoc IAmpsVault
    function oracleGate() external view returns (address gateAddress) {
        return _oracleGate;
    }

    /// @inheritdoc IAmpsVault
    function feedRegistry() external view returns (address feedRegistryAddress) {
        return _feedRegistry;
    }

    /// @inheritdoc IAmpsVault
    function positionValuer() external view returns (address positionValuerAddress) {
        return _positionValuer;
    }

    /// @inheritdoc IAmpsVault
    function ladderPolicy() external view returns (address ladderPolicyAddress) {
        return _ladderPolicy;
    }

    /// @inheritdoc IAmpsVault
    function rolloutPolicy() external view returns (address rolloutPolicyAddress) {
        return _rolloutPolicy;
    }

    /// @inheritdoc IAmpsVault
    function timelock() external view returns (address timelockAddress) {
        return _TIMELOCK;
    }

    /// @inheritdoc IAmpsVault
    function guardian() external view returns (address guardianAddress) {
        return _GUARDIAN;
    }

    /// @inheritdoc IAmpsVault
    function creator() external view returns (address creatorAddress) {
        return _creator;
    }

    /// @inheritdoc IAmpsVault
    function standbyVault() external view returns (address standbyAddress) {
        return _standbyVault;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reads — the asset enumeration (disclosure; not part of {IAmpsVault})
    // -------------------------------------------------------------------------------------------------------------

    /// @notice How many non-AMPS assets the vault values and redeems.
    /// @return count The asset count.
    function assetCount() external view returns (uint256 count) {
        return _assets.length;
    }

    /// @notice The asset at `index`.
    /// @param index A zero-based index below {assetCount}.
    /// @return token The asset.
    function assetAt(uint256 index) external view returns (address token) {
        return _assets[index];
    }

    /// @notice Whether `token` is one of the vault's registered assets.
    /// @param token The token to test.
    /// @return registered Whether it is registered.
    function isAsset(address token) external view returns (bool registered) {
        return _assetIndex[token] != 0;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reads — NAV, reference and inventory
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsVault
    /// @dev Never reverts, and never applies a staleness rule of its own: consumers compare `snapshot.timestamp`
    ///      against `Constants.CHECKPOINT_MAX_AGE` and refuse for themselves. Redemption ignores it entirely.
    function checkpointData() external view returns (Checkpoint memory snapshot) {
        return _snapshot();
    }

    /// @inheritdoc IAmpsVault
    function navPerShareX18() external view returns (uint256 value) {
        return _navPerShareX18;
    }

    /// @inheritdoc IAmpsVault
    function pRefX18() external view returns (uint256 value) {
        return _pRefX18;
    }

    /// @inheritdoc IAmpsVault
    function pMktX18() external view returns (uint256 value) {
        return _pMktX18;
    }

    /// @inheritdoc IAmpsVault
    function premiumX18() external view returns (uint256 value) {
        uint256 nav = _navPerShareX18;
        if (nav == 0) return 0;
        uint256 ref = _pRefX18;
        if (ref <= nav) return 0;
        return FullMath.mulDiv(ref - nav, Constants.WAD, nav);
    }

    /// @inheritdoc IAmpsVault
    function totalAssetsUsd18() external view returns (uint256 value) {
        return VaultNavLib.totalAssetsUsd18(_sources(), _assetList(), address(this), true);
    }

    /// @notice `A` measured over an arbitrary holder's balances rather than the vault's own.
    /// @dev Not part of {IAmpsVault}. It exists so that {emergencyMigrate} can price the standby vault through an
    ///      external call it can `try`/`catch`, and so the dApp can show a candidate standby's backing. The
    ///      position term is added only for the vault itself, because the v4 positions belong to the vault and
    ///      would otherwise be double-counted.
    /// @param holder The account to value.
    /// @return value `A` for that account, 18-decimal USD.
    function assetsUsd18Of(address holder) external view returns (uint256 value) {
        return VaultNavLib.totalAssetsUsd18(_sources(), _assetList(), holder, holder == address(this));
    }

    /// @inheritdoc IAmpsVault
    function previewNavPerShareX18() external view returns (uint256 value) {
        return _previewNav();
    }

    /// @inheritdoc IAmpsVault
    function inventoryAmps() external view returns (uint256 amount) {
        return VaultNavLib.inventoryAmps(_sources(), _assetList(), _AMPS, address(this));
    }

    /// @inheritdoc IAmpsVault
    /// @dev Includes the position term from Phase 3: what a pro-rata unwind would free out of the ladder, priced
    ///      exactly as v4 itself would free it, so the preview and the payout agree to the wei.
    function previewRedeem(uint256 shares)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts, uint256 inventoryBurned)
    {
        uint256 supply = IAmps(_AMPS).totalSupply();
        (uint256[] memory released, uint256 releasedAmps) = VaultRedeemLib.previewUnwind(
            ladderAt, _poolKeys(), _assetIndex, _assets.length, _POOL_MANAGER, shares, supply
        );
        VaultRedeemLib.Redemption memory result = VaultRedeemLib.redemption(
            _assets, _POOL_MANAGER, _AMPS, shares, supply, _redeemFeeBps, released, new uint256[](0), releasedAmps, 0
        );
        return (result.tokens, result.amounts, result.inventoryBurned);
    }

    /// @inheritdoc IAmpsVault
    function creatorBpsAt(uint256 timestamp) external view returns (uint16 bps) {
        uint256 start = _genesisTimestamp;
        if (start == 0 || timestamp <= start) return Constants.CREATOR_FEE_BPS;
        uint256 elapsed = timestamp - start;
        if (elapsed >= Constants.CREATOR_DECAY_SECONDS) return 0;
        return uint16(
            (uint256(Constants.CREATOR_FEE_BPS) * (Constants.CREATOR_DECAY_SECONDS - elapsed))
                / Constants.CREATOR_DECAY_SECONDS
        );
    }

    /// @inheritdoc IAmpsVault
    function genesisTimestamp() external view returns (uint32 timestamp) {
        return _genesisTimestamp;
    }

    /// @inheritdoc IAmpsVault
    function initialized() external view returns (bool done) {
        return _initialized;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reads — governed parameters
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsVault
    function redeemFeeBps() external view returns (uint16 value) {
        return _redeemFeeBps;
    }

    /// @inheritdoc IAmpsVault
    function burnBps() external view returns (uint16 value) {
        return _burnBps;
    }

    /// @inheritdoc IAmpsVault
    function stakerBps() external view returns (uint16 value) {
        return _stakerBps;
    }

    /// @inheritdoc IAmpsVault
    function refUpRateBps() external view returns (uint16 value) {
        return _refUpRateBps;
    }

    /// @inheritdoc IAmpsVault
    function refDivergenceBps() external view returns (uint16 value) {
        return _refDivergenceBps;
    }

    /// @inheritdoc IAmpsVault
    function twapWindow() external view returns (uint32 value) {
        return _twapWindow;
    }

    /// @inheritdoc IAmpsVault
    function ladderTiltX18() external view returns (uint64 value) {
        return _ladderTiltX18;
    }

    /// @inheritdoc IAmpsVault
    function ladderDoublings() external view returns (uint8 value) {
        return _ladderDoublings;
    }

    /// @inheritdoc IAmpsVault
    function seedHalvings() external view returns (uint8 value) {
        return _seedHalvings;
    }

    /// @inheritdoc IAmpsVault
    function bondBidHalvings() external view returns (uint8 value) {
        return _bondBidHalvings;
    }

    /// @inheritdoc IAmpsVault
    function spokeSeedBps() external view returns (uint16 value) {
        return _spokeSeedBps;
    }

    /// @inheritdoc IAmpsVault
    function rolloutBpsPerDay() external view returns (uint16 value) {
        return _rolloutBpsPerDay;
    }

    /// @inheritdoc IAmpsVault
    function entryFloorBps() external view returns (uint16 value) {
        return _entryFloorBps;
    }

    /// @inheritdoc IAmpsVault
    function deployThresholdUsd18() external view returns (uint256 value) {
        return _deployThresholdUsd18;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reads — the ladder (Phase 3, `view`-only)
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsVault
    function ladderLength(PoolId poolId) external view returns (uint256 length) {
        return ladderAt[poolId].length;
    }

    /// @inheritdoc IAmpsVault
    /// @dev `docs/phase3-state-model.md` §12 ruling E. The count lives at a hashed slot in {VaultRedeemLib} and is
    ///      maintained by all four libraries on every open, merge, unwind and removal; it is what bounds the gas
    ///      of {redeemProRata}, which is the one path that must never be gated to make it fit.
    function liveCells() external view returns (uint32 count) {
        return VaultRedeemLib.liveCellCount();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reads — hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsVault
    function S0() external pure returns (uint256 value) {
        return Constants.S0;
    }

    /// @inheritdoc IAmpsVault
    function VIRTUAL_SHARES() external pure returns (uint256 value) {
        return Constants.VIRTUAL_SHARES;
    }

    /// @inheritdoc IAmpsVault
    function REDEEM_FEE_BPS_MAX() external pure returns (uint16 value) {
        return Constants.REDEEM_FEE_BPS_MAX;
    }

    /// @inheritdoc IAmpsVault
    function BURN_BPS_MAX() external pure returns (uint16 value) {
        return Constants.BURN_BPS_MAX;
    }

    /// @inheritdoc IAmpsVault
    function STAKER_BPS_MAX() external pure returns (uint16 value) {
        return Constants.STAKER_BPS_MAX;
    }

    /// @inheritdoc IAmpsVault
    function REF_UP_RATE_BPS_MIN() external pure returns (uint16 value) {
        return Constants.REF_UP_RATE_BPS_MIN;
    }

    /// @inheritdoc IAmpsVault
    function REF_UP_RATE_BPS_MAX() external pure returns (uint16 value) {
        return Constants.REF_UP_RATE_BPS_MAX;
    }

    /// @inheritdoc IAmpsVault
    function REF_DIVERGENCE_BPS_MIN() external pure returns (uint16 value) {
        return Constants.REF_DIVERGENCE_BPS_MIN;
    }

    /// @inheritdoc IAmpsVault
    function REF_DIVERGENCE_BPS_MAX() external pure returns (uint16 value) {
        return Constants.REF_DIVERGENCE_BPS_MAX;
    }

    /// @inheritdoc IAmpsVault
    function TWAP_WINDOW_MIN() external pure returns (uint32 value) {
        return Constants.TWAP_WINDOW_MIN;
    }

    /// @inheritdoc IAmpsVault
    function TWAP_WINDOW_MAX() external pure returns (uint32 value) {
        return Constants.TWAP_WINDOW_MAX;
    }

    /// @inheritdoc IAmpsVault
    function LADDER_TILT_X18_MIN() external pure returns (uint64 value) {
        return Constants.LADDER_TILT_X18_MIN;
    }

    /// @inheritdoc IAmpsVault
    function LADDER_TILT_X18_MAX() external pure returns (uint64 value) {
        return Constants.LADDER_TILT_X18_MAX;
    }

    /// @inheritdoc IAmpsVault
    function LADDER_DOUBLINGS_MIN() external pure returns (uint8 value) {
        return Constants.LADDER_DOUBLINGS_MIN;
    }

    /// @inheritdoc IAmpsVault
    function LADDER_DOUBLINGS_MAX() external pure returns (uint8 value) {
        return Constants.LADDER_DOUBLINGS_MAX;
    }

    /// @inheritdoc IAmpsVault
    function HALVINGS_MIN() external pure returns (uint8 value) {
        return Constants.HALVINGS_MIN;
    }

    /// @inheritdoc IAmpsVault
    function HALVINGS_MAX() external pure returns (uint8 value) {
        return Constants.HALVINGS_MAX;
    }

    /// @inheritdoc IAmpsVault
    function ROLLOUT_BPS_PER_DAY_MAX() external pure returns (uint16 value) {
        return Constants.ROLLOUT_BPS_PER_DAY_MAX;
    }

    /// @inheritdoc IAmpsVault
    function ENTRY_FLOOR_BPS_MAX() external pure returns (uint16 value) {
        return Constants.ENTRY_FLOOR_BPS_MAX;
    }

    /// @inheritdoc IAmpsVault
    function SPOKE_SEED_BPS_MIN() external pure returns (uint16 value) {
        return Constants.SPOKE_SEED_BPS_MIN;
    }

    /// @inheritdoc IAmpsVault
    function DEPLOY_THRESHOLD_USD18_MIN() external pure returns (uint256 value) {
        return Constants.DEPLOY_THRESHOLD_USD18_MIN;
    }

    /// @inheritdoc IAmpsVault
    function DEPLOY_THRESHOLD_USD18_MAX() external pure returns (uint256 value) {
        return Constants.DEPLOY_THRESHOLD_USD18_MAX;
    }

    /// @inheritdoc IAmpsVault
    function SPOKE_SEED_BPS_MAX() external pure returns (uint16 value) {
        return Constants.SPOKE_SEED_BPS_MAX;
    }

    /// @inheritdoc IAmpsVault
    function PLACEMENT_BLEED_BPS_MAX() external pure returns (uint16 value) {
        return Constants.PLACEMENT_BLEED_BPS_MAX;
    }

    /// @inheritdoc IAmpsVault
    function MIGRATION_BLEED_BPS_MAX() external pure returns (uint16 value) {
        return Constants.MIGRATION_BLEED_BPS_MAX;
    }

    /// @inheritdoc IAmpsVault
    function CREATOR_FEE_BPS() external pure returns (uint16 value) {
        return Constants.CREATOR_FEE_BPS;
    }

    /// @inheritdoc IAmpsVault
    function CREATOR_DECAY_SECONDS() external pure returns (uint32 value) {
        return Constants.CREATOR_DECAY_SECONDS;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — the ungated floor
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsVault
    /// @dev **Read this against section 7 before changing a line.** The body below contains no reference to
    ///      `_oracleGate`, `_feedRegistry`, `_registry`, `_GUARDIAN`, `_standbyVault`, a freeze timestamp, a pause
    ///      flag or any price. `test/unit/GuardSymmetry.t.sol` proves it at the storage level with
    ///      `vm.record`/`vm.accesses`.
    function redeemProRata(uint256 shares, address to)
        external
        locked
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        if (shares == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        // `T` is read once, before the burn, so a redemption cannot inflate its own share.
        uint256 supply = IAmps(_AMPS).totalSupply();

        // Effects before interactions: the redeemer's shares are gone before a single asset moves.
        IAmps(_AMPS).burn(msg.sender, shares);

        // Phase 3: remove exactly `floor(L x shares / T)` from every record in every pool the vault has opened
        // (I23, §3.10). The counter principal lands in claims, the AMPS principal as an idle balance to burn, and
        // the fees the removal realised stay with the protocol.
        uint256[] memory released;
        uint256[] memory added;
        uint256 releasedAmps;
        uint256 addedAmps;
        if (_poolKeys().length != 0) {
            _setUnlockAction(VaultRedeemLib.ACTION_UNWIND);
            (released, added, releasedAmps, addedAmps) = abi.decode(
                IPoolManager(_POOL_MANAGER).unlock(abi.encode(_AMPS, shares, supply)),
                (uint256[], uint256[], uint256, uint256)
            );
            _setUnlockAction(0);
        }

        VaultRedeemLib.Redemption memory result = VaultRedeemLib.redemption(
            _assets, _POOL_MANAGER, _AMPS, shares, supply, _redeemFeeBps, released, added, releasedAmps, addedAmps
        );
        tokens = result.tokens;
        amounts = result.amounts;

        _setUnlockAction(VaultRedeemLib.ACTION_PAYOUT);
        IPoolManager(_POOL_MANAGER).unlock(abi.encode(tokens, result.fromClaims, result.fromIdle, to));
        _setUnlockAction(0);

        if (result.inventoryBurned != 0) {
            IAmps(_AMPS).burn(address(this), result.inventoryBurned);
            emit Burn(result.inventoryBurned, bytes32("redeemInventory"));
        }

        emit Redeem(msg.sender, to, shares, result.inventoryBurned, _redeemFeeBps);
        _sweepClean();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — permissionless upkeep
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsVault
    /// @dev The gate is poked *before* `_requireHealthy`, so a checkpoint is exactly what clears a layer-A watchdog
    ///      whose cause has passed.
    function checkpoint() external locked returns (Checkpoint memory snapshot) {
        _poke();
        _requireHealthy();
        snapshot = _checkpoint();
        _sweepClean();
    }

    /// @inheritdoc IAmpsVault
    /// @dev Stamps layer A only. It deliberately does not touch `checkpointTimestamp`: refreshing the staleness
    ///      bound without recomputing NAV would let every gated consumer read an old NAV as if it were fresh.
    function touch() external locked {
        _poke();
        _requireHealthy();
        _sweepClean();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — bonds
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsVault
    function depositBonded(uint16 marketId, address collateral, address from, uint256 amount)
        external
        locked
        returns (uint256 settled)
    {
        _requireBondsHealthy();
        if (msg.sender != _bonds) revert NotBonds(msg.sender);
        if (collateral == address(0) || from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // AMPS can never be collateral: it is the share, and a share backing itself is the one leg NAV must not see.
        if (collateral == _AMPS) revert ZeroAddress();
        // `marketId` is the bonds shell's own bookkeeping. The vault records the constituent the proceeds route to,
        // which it reads from the registry, so that the event is meaningful even if a market is later renumbered.
        marketId;

        // A bonded collateral must be valued in `A` and paid out by redemption, so it joins the asset list here.
        _registerAsset(collateral);

        // Checkpoint *before* the collateral lands. `AmpsBonds` prices this bond against `checkpointData()` right
        // after this call returns, so the NAV it reads is this block's pre-deposit NAV — never one a previous bond,
        // a redemption or a feed move inside `CHECKPOINT_MAX_AGE` has already left behind. Without this, a second
        // bond inside the staleness window could issue against a NAV its predecessor had raised and dilute every
        // holder; with it, I27 holds against the live NAV under every gate state the bond policy admits, because
        // the checkpoint runs under that policy rather than behind the management gate of {checkpoint}.
        _checkpoint();

        _setUnlockAction(VaultRedeemLib.ACTION_SETTLE);
        bytes memory result = IPoolManager(_POOL_MANAGER).unlock(abi.encode(collateral, from, amount));
        _setUnlockAction(0);
        settled = abi.decode(result, (uint256));

        uint16 constituentId;
        address registry_ = _registry;
        if (registry_ != address(0)) constituentId = IPoolRegistry(registry_).constituentIdOf(collateral);

        emit BondedDeposit(collateral, from, settled, constituentId);
        _sweepClean();
    }

    /// @inheritdoc IAmpsVault
    function mintVesting(address to, uint256 amount) external locked {
        _requireBondsHealthy();
        address bonds_ = _bonds;
        if (msg.sender != bonds_) revert NotBonds(msg.sender);
        if (to != bonds_) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IAmps(_AMPS).mint(to, amount);
        emit VestingMinted(to, amount);
        _sweepClean();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — genesis and placement
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsVault
    function genesis(GenesisParams calldata params) external locked onlyTimelock {
        _requireHealthy();
        if (_initialized) revert GenesisAlreadyDone();
        // The two tranches are constants, not choices. They are passed so the proposal is auditable on its face,
        // and `TEAM_SHARES + POL_SHARES == S0` holds by construction, so this one check is the whole allocation.
        if (params.teamShares != Constants.TEAM_SHARES || params.polShares != Constants.POL_SHARES) {
            revert InvalidGenesisAllocation(params.teamShares, params.polShares, Constants.S0);
        }
        if (params.teamVestingWallet == address(0) || params.creator == address(0)) revert ZeroAddress();
        if (params.seedTokens.length != params.seedAmounts.length) revert LengthMismatch();
        if (_registry == address(0)) revert ZeroAddress();

        IAmps(_AMPS).mint(params.teamVestingWallet, params.teamShares);
        IAmps(_AMPS).mint(address(this), params.polShares);

        _registerRegistryAssets();

        uint256 seedCount = params.seedTokens.length;
        for (uint256 i; i < seedCount; ++i) {
            address token = params.seedTokens[i];
            uint256 amount = params.seedAmounts[i];
            if (token == address(0) || token == _AMPS) revert ZeroAddress();
            if (amount == 0) revert ZeroAmount();
            _registerAsset(token);
            _setUnlockAction(VaultRedeemLib.ACTION_SETTLE);
            IPoolManager(_POOL_MANAGER).unlock(abi.encode(token, msg.sender, amount));
            _setUnlockAction(0);
        }

        _creator = params.creator;
        _genesisTimestamp = uint32(block.timestamp);
        _initialized = true;
        _wiringFrozen = true;

        Checkpoint memory snapshot = _checkpoint();
        emit Genesis(params.teamVestingWallet, params.creator, Constants.S0, snapshot.navPerShareX18);
        _sweepClean();
    }

    /// @inheritdoc IAmpsVault
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external locked returns (PoolId poolId) {
        _requireHealthy();
        if (msg.sender != _registry) revert NotRegistry(msg.sender);

        // §12 ruling C: every pool opens exactly on a spacing-aligned tick, which is what makes it open on its
        // own grid origin and what puts the genesis asks at cells 0..9 and the seed bids at -1..-4. The snap is at
        // most half a tick spacing, so the launch price is the aligned price nearest the intended one.
        IPoolManager(_POOL_MANAGER)
            .initialize(key, VaultPlacementLib.alignedOpeningPrice(sqrtPriceX96, key.tickSpacing));
        poolId = key.toId();

        // The vault's own pool list, so that `redeemProRata` can reach every position it owns without ever
        // consulting the registry. A second `initializePool` over the same key cannot get here: v4's own
        // `initialize` reverts on an already-initialised pool.
        _poolKeys().push(key);

        // The counter asset joins the NAV sum and the redemption enumeration the moment its pool exists, so that
        // `redeemProRata` never has to consult the registry.
        _registerAsset(Currency.unwrap(key.currency1));
        _registerAsset(Currency.unwrap(key.currency0));
        _sweepClean();
    }

    /// @inheritdoc IAmpsVault
    /// @dev **Timelock or registry** (`docs/phase3-state-model.md` §10 ruling 11): governance places the genesis
    ///      ladders and any hand-directed placement, and `PoolRegistry.addConstituent` places a new spoke's
    ///      `spokeSeedBps` seed ask. `compound`, `rollout` and `deployBonded` are the permissionless bountied
    ///      paths. The whole gauntlet of §3.8 runs here and in {VaultPlacementLib}: the transient lock and the
    ///      management gate above, the pool gate, cooldown, divergence at entry and exit, sidedness, grid
    ///      membership and the inventory bound inside, and R1 plus `sweepClean` in {_afterPlacement}.
    function place(PoolId poolId, bool above, uint256 amount) external locked returns (uint256 placed) {
        if (msg.sender != _TIMELOCK && msg.sender != _registry) revert NotTimelock(msg.sender);
        _requireHealthy();
        uint256 navBefore = _previewNav();
        placed = VaultPlacementLib.place(
            ladderAt, _lastPlacementAt, _POOL_MANAGER, _AMPS, poolId, above, amount, bytes32("place"), true
        );
        _afterPlacement(navBefore);
    }

    /// @inheritdoc IAmpsVault
    /// @dev Permissionless and bountied. See {VaultPlacementLib-compound} for the step-by-step of §3.6.
    function compound(PoolId poolId) external locked returns (uint256 ampsFees, uint256 burned) {
        _requireHealthy();
        uint256 navBefore = _previewNav();
        (ampsFees, burned) = VaultPlacementLib.compound(ladderAt, _lastPlacementAt, _POOL_MANAGER, _AMPS, poolId);
        _afterPlacement(navBefore);
    }

    /// @inheritdoc IAmpsVault
    /// @dev Permissionless and bountied. `amountAmps == 0` from the schedule is a no-op, not a revert.
    function rollout(uint16 constituentId) external locked returns (uint256 moved) {
        _requireHealthy();
        uint256 navBefore = _previewNav();
        moved = VaultRolloutLib.rollout(ladderAt, _lastPlacementAt, _POOL_MANAGER, _AMPS, constituentId);
        _afterPlacement(navBefore);
    }

    /// @inheritdoc IAmpsVault
    /// @dev Permissionless and bountied, and a no-op below `deployThresholdUsd18` of idle collateral so it cannot
    ///      be used to drain the bounty pot a wei at a time (§10 ruling 15).
    function deployBonded(uint16 constituentId) external locked returns (uint256 placed) {
        _requireHealthy();
        uint256 navBefore = _previewNav();
        placed = VaultRolloutLib.deployBonded(ladderAt, _lastPlacementAt, _POOL_MANAGER, _AMPS, constituentId);
        _afterPlacement(navBefore);
    }

    /// @inheritdoc IAmpsVault
    /// @dev **Only registry**, and the caller check comes before the gate check because the registry is the only
    ///      legitimate caller and a wrong caller is not a gate refusal.
    function withdrawRetiredBids(uint16 constituentId) external locked returns (uint256 amountMoved) {
        if (msg.sender != _registry) revert NotRegistry(msg.sender);
        _requireHealthy();
        uint256 navBefore = _previewNav();
        amountMoved = VaultRolloutLib.withdrawRetiredBids(ladderAt, _lastPlacementAt, _POOL_MANAGER, constituentId);
        _afterPlacement(navBefore);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — governance
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsVault
    function setRedeemFeeBps(uint16 value) external locked onlyTimelock {
        _redeemFeeBps = uint16(_band(bytes32("redeemFeeBps"), value, 0, Constants.REDEEM_FEE_BPS_MAX, _redeemFeeBps));
    }

    /// @inheritdoc IAmpsVault
    function setBurnBps(uint16 value) external locked onlyTimelock {
        _burnBps = uint16(_band(bytes32("burnBps"), value, 0, Constants.BURN_BPS_MAX, _burnBps));
    }

    /// @inheritdoc IAmpsVault
    function setStakerBps(uint16 value) external locked onlyTimelock {
        _stakerBps = uint16(_band(bytes32("stakerBps"), value, 0, Constants.STAKER_BPS_MAX, _stakerBps));
    }

    /// @inheritdoc IAmpsVault
    function setRefUpRateBps(uint16 value) external locked onlyTimelock {
        _refUpRateBps = uint16(
            _band(
                bytes32("refUpRateBps"),
                value,
                Constants.REF_UP_RATE_BPS_MIN,
                Constants.REF_UP_RATE_BPS_MAX,
                _refUpRateBps
            )
        );
    }

    /// @inheritdoc IAmpsVault
    function setRefDivergenceBps(uint16 value) external locked onlyTimelock {
        _refDivergenceBps = uint16(
            _band(
                bytes32("refDivergenceBps"),
                value,
                Constants.REF_DIVERGENCE_BPS_MIN,
                Constants.REF_DIVERGENCE_BPS_MAX,
                _refDivergenceBps
            )
        );
    }

    /// @inheritdoc IAmpsVault
    function setTwapWindow(uint32 value) external locked onlyTimelock {
        _twapWindow = uint32(
            _band(bytes32("twapWindow"), value, Constants.TWAP_WINDOW_MIN, Constants.TWAP_WINDOW_MAX, _twapWindow)
        );
    }

    /// @inheritdoc IAmpsVault
    function setLadderShape(uint64 tiltX18, uint8 doublings, uint8 seedHalvings_, uint8 bondBidHalvings_)
        external
        locked
        onlyTimelock
    {
        _ladderTiltX18 = uint64(
            _band(
                bytes32("ladderTiltX18"),
                tiltX18,
                Constants.LADDER_TILT_X18_MIN,
                Constants.LADDER_TILT_X18_MAX,
                _ladderTiltX18
            )
        );
        _ladderDoublings = uint8(
            _band(
                bytes32("ladderDoublings"),
                doublings,
                Constants.LADDER_DOUBLINGS_MIN,
                Constants.LADDER_DOUBLINGS_MAX,
                _ladderDoublings
            )
        );
        _seedHalvings = uint8(
            _band(bytes32("seedHalvings"), seedHalvings_, Constants.HALVINGS_MIN, Constants.HALVINGS_MAX, _seedHalvings)
        );
        _bondBidHalvings = uint8(
            _band(
                bytes32("bondBidHalvings"),
                bondBidHalvings_,
                Constants.HALVINGS_MIN,
                Constants.HALVINGS_MAX,
                _bondBidHalvings
            )
        );
    }

    /// @inheritdoc IAmpsVault
    function setRolloutParams(uint16 bpsPerDay, uint16 floorBps) external locked onlyTimelock {
        _rolloutBpsPerDay = uint16(
            _band(bytes32("rolloutBpsPerDay"), bpsPerDay, 0, Constants.ROLLOUT_BPS_PER_DAY_MAX, _rolloutBpsPerDay)
        );
        _entryFloorBps =
            uint16(_band(bytes32("entryFloorBps"), floorBps, 0, Constants.ENTRY_FLOOR_BPS_MAX, _entryFloorBps));
    }

    /// @inheritdoc IAmpsVault
    function setSpokeSeedBps(uint16 value) external locked onlyTimelock {
        _spokeSeedBps = uint16(
            _band(
                bytes32("spokeSeedBps"),
                value,
                Constants.SPOKE_SEED_BPS_MIN,
                Constants.SPOKE_SEED_BPS_MAX,
                _spokeSeedBps
            )
        );
    }

    /// @inheritdoc IAmpsVault
    function setDeployThresholdUsd18(uint256 value) external locked onlyTimelock {
        _deployThresholdUsd18 = _band(
            bytes32("deployThresholdUsd18"),
            value,
            Constants.DEPLOY_THRESHOLD_USD18_MIN,
            Constants.DEPLOY_THRESHOLD_USD18_MAX,
            _deployThresholdUsd18
        );
    }

    /// @inheritdoc IAmpsVault
    /// @dev The single pointer setter. Five slots are **set-once** and refuse once {genesis} has frozen the wiring
    ///      (`registry`, `bonds`, `staking`, `bountyPot`); `marketReference` is set-once before genesis and may be
    ///      re-pointed afterwards exactly once more, to `AmpsHook`, under the 7-day timelock. The remaining slots
    ///      are freely pointer-upgradeable and none of them can move a fund.
    function setPolicyPointer(bytes32 slot, address newPointer) external locked onlyTimelock {
        _requireHealthy();
        if (newPointer == address(0)) revert ZeroAddress();
        address previous = VaultNavLib.setPointer(slot, newPointer, _wiringFrozen);
        emit PolicyPointerChanged(slot, previous, newPointer);
    }

    /// @inheritdoc IAmpsVault
    function setStandbyVault(address standby) external locked onlyTimelock {
        _requireHealthy();
        if (standby == address(0)) revert ZeroAddress();
        _standbyVault = standby;
        emit StandbyVaultRegistered(standby);
    }

    /// @inheritdoc IAmpsVault
    function setCreator(address newCreator) external locked {
        _requireHealthy();
        address previous = _creator;
        if (msg.sender != previous) revert NotCreator(msg.sender);
        if (newCreator == address(0)) revert ZeroAddress();
        _creator = newCreator;
        emit CreatorChanged(previous, newCreator);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — emergency
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsVault
    /// @dev Not `_requireHealthy`-gated on purpose: the incident this exists for is an issuer denylisting the vault
    ///      while pausing its oracle, which is exactly a state in which the gate refuses. The predicate below is a
    ///      strictly narrower on-chain gate, and the guardian cannot migrate without it.
    function emergencyMigrate(address standby) external locked {
        if (msg.sender != _GUARDIAN) revert NotGuardian(msg.sender);
        address registered = _standbyVault;
        if (standby == address(0) || standby != registered) revert NotStandbyVault(standby, registered);
        if (!VaultNavLib.migrationPredicate(_registry, address(this))) revert MigrationPredicateNotMet();

        uint256 navBefore = _navPerShareX18;
        uint256 navSlot = NAV_BEFORE;
        assembly ("memory-safe") {
            tstore(navSlot, navBefore)
        }

        IPoolManager pm = IPoolManager(_POOL_MANAGER);

        // Phase 3: unwind the ladder first. Liquidity left in v4 positions owned by a denylisted vault would be
        // unreachable by the standby, and the removal itself cannot be blocked — the hook carries no
        // `BEFORE_REMOVE_LIQUIDITY` bit (I18) and the released counter never leaves the PoolManager.
        if (_poolKeys().length != 0) {
            _setUnlockAction(VaultRedeemLib.ACTION_UNWIND);
            pm.unlock(abi.encode(_AMPS, uint256(1), uint256(1)));
            _setUnlockAction(0);
        }

        // Every claim moves PoolManager-internally: no ERC-20 transfer, so a denylist cannot stop the evacuation.
        VaultNavLib.evacuate(_assets, _POOL_MANAGER, _AMPS, standby);

        // The four `onlyVault` role handovers, in the same transaction. Nobody else can perform any of them.
        IAmps(_AMPS).setVault(standby);
        if (_bonds != address(0)) IAmpsBonds(_bonds).setVault(standby);
        if (_staking != address(0)) IAmpsStaking(_staking).setVault(standby);
        if (_bountyPot != address(0)) IBountyPot(_bountyPot).setVault(standby);

        // The relaxed R1 bound, enforced only when the standby can actually be priced. A dead feed must never stand
        // between the guardian and an evacuation: in Phase 2 there are no positions to bleed, every claim moves one
        // for one, and the check is a disclosure rather than the thing that makes the migration safe.
        uint256 navAfter;
        try this.assetsUsd18Of(standby) returns (uint256 assetsAfter) {
            navAfter = _navPerShare(assetsAfter);
            uint256 floor = FullMath.mulDiv(navBefore, Constants.BPS - Constants.MIGRATION_BLEED_BPS_MAX, Constants.BPS);
            if (navAfter < floor) revert NavBleedExceeded(navBefore, navAfter, Constants.MIGRATION_BLEED_BPS_MAX);
        } catch {}

        assembly ("memory-safe") {
            tstore(navSlot, 0)
        }
        emit Migrated(standby, navBefore, navAfter);
        _assertSweepZero();
    }

    // -------------------------------------------------------------------------------------------------------------
    // The sole unlock callback
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IUnlockCallback
    /// @dev Dispatches on the transient `UNLOCK_ACTION` discriminator the vault set immediately before calling
    ///      `unlock`. It takes no reentrancy lock of its own: the entry point that opened the unlock already holds
    ///      it, and the caller check plus the discriminator make an unsolicited entry impossible.
    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != _POOL_MANAGER) revert NotPoolManager(msg.sender);

        uint256 slot = UNLOCK_ACTION;
        uint256 action;
        assembly ("memory-safe") {
            action := tload(slot)
        }

        // The ladder's four actions (§3.9) go to the placement library; the four that move an asset — settle,
        // pay out, absorb and the pro-rata unwind — go to the redemption library, which is the one the ungated
        // path may reach. Both bodies live outside this contract because it has no EIP-170 headroom left.
        if (
            action == VaultRedeemLib.ACTION_PLACE || action == VaultRedeemLib.ACTION_COMPOUND
                || action == VaultRedeemLib.ACTION_BURNBACK || action == VaultRedeemLib.ACTION_HARVEST
        ) {
            return VaultPlacementLib.unlockAction(ladderAt, _POOL_MANAGER, action, data);
        }
        return
            VaultRedeemLib.unlockAction(ladderAt, _poolKeys(), _assetIndex, _assets.length, _POOL_MANAGER, action, data);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — custody
    // -------------------------------------------------------------------------------------------------------------

    /// @dev I12, in {VaultRedeemLib}: any ERC-20 balance the vault is left holding is absorbed into ERC-6909
    ///      claims and the zero balance is then asserted.
    function _sweepClean() private {
        VaultRedeemLib.sweepClean(_assets, _POOL_MANAGER);
    }

    /// @dev The assertion half of {_sweepClean}, without the absorb step: used by {emergencyMigrate}, which has
    ///      just moved every balance to the standby and must not re-deposit anything into the PoolManager.
    function _assertSweepZero() private view {
        uint256 length = _assets.length;
        for (uint256 i; i < length; ++i) {
            uint256 balance = IERC20(_assets[i]).balanceOf(address(this));
            if (balance != 0) revert SweepDirty(_assets[i], balance);
        }
    }

    /// @dev Writes the transient unlock discriminator.
    function _setUnlockAction(uint256 action) private {
        uint256 slot = UNLOCK_ACTION;
        assembly ("memory-safe") {
            tstore(slot, action)
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — the ladder's own storage
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The vault's `PoolKey` list, at {POOL_KEYS_SLOT}. See that constant for why it is not slot 21.
    function _poolKeys() private pure returns (PoolKey[] storage keys) {
        bytes32 slot = POOL_KEYS_SLOT;
        assembly ("memory-safe") {
            keys.slot := slot
        }
    }

    /// @dev The R1 post-condition and the exit sweep, shared by all five Phase 3 entry points. `_checkpoint()`
    ///      recomputes `A` at the *previous* reference price, so `navBefore` and `navAfter` are measured on the
    ///      same basis and a placement is judged on what it moved, never on what the market did (I11).
    function _afterPlacement(uint256 navBefore) private {
        uint256 navAfter = _checkpoint().navPerShareX18;
        uint256 floor = FullMath.mulDiv(navBefore, Constants.BPS - Constants.PLACEMENT_BLEED_BPS_MAX, Constants.BPS);
        if (navAfter < floor) revert NavBleedExceeded(navBefore, navAfter, Constants.PLACEMENT_BLEED_BPS_MAX);
        _sweepClean();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — NAV and the reference price
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The vault's pointers, gathered for {VaultNavLib}. `pRefPrevX18` is the *previous* checkpoint's
    ///      reference price, which is the price positions are decomposed at (I7).
    function _sources() private view returns (VaultNavLib.Sources memory src) {
        src = VaultNavLib.Sources({
            poolManager: _POOL_MANAGER,
            registry: _registry,
            feedRegistry: _feedRegistry,
            positionValuer: _positionValuer,
            marketReference: _marketReference,
            oracleGate: _oracleGate,
            pRefPrevX18: _pRefX18,
            twapWindow: _twapWindow,
            refDivergenceBps: _refDivergenceBps
        });
    }

    /// @dev The registered asset list in memory, for the library's read side. {redeemProRata} deliberately does
    ///      not use this: it walks storage directly so that no call leaves the contract on the ungated path.
    function _assetList() private view returns (address[] memory list) {
        return _assets;
    }

    /// @dev `navPerShareX18 = (A + 1) x 1e18 / (T + VIRTUAL_SHARES)`, rounded down. The denominator is
    ///      `Amps.totalSupply()` and nothing else (I6), and `VIRTUAL_SHARES` makes it non-zero in every reachable
    ///      state (I22).
    function _navPerShare(uint256 assetsUsd18) private view returns (uint256) {
        uint256 supply = IAmps(_AMPS).totalSupply();
        return FullMath.mulDiv(assetsUsd18 + 1, Constants.WAD, supply + Constants.VIRTUAL_SHARES);
    }

    /// @dev NAV/share recomputed from live balances, positions included: what {previewNavPerShareX18} returns and
    ///      what every Phase 3 entry point captures as `navBefore` for R1.
    function _previewNav() private view returns (uint256) {
        return _navPerShare(VaultNavLib.totalAssetsUsd18(_sources(), _assetList(), address(this), true));
    }

    /// @dev Recomputes `A`, NAV/share, `P_mkt` and `P_ref` and writes the two checkpoint words (section 5).
    function _checkpoint() private returns (Checkpoint memory snapshot) {
        VaultNavLib.Sources memory src = _sources();
        uint256 assetsUsd18 = VaultNavLib.totalAssetsUsd18(src, _assetList(), address(this), true);
        uint256 supply = IAmps(_AMPS).totalSupply();
        // The one formula, from the one place: {previewNavPerShareX18} and the checkpoint can never disagree.
        uint256 nav = _navPerShare(assetsUsd18);

        (uint256 pMkt, bool usable) = VaultNavLib.marketPrice(src);
        uint32 last = _checkpointTimestamp;
        (uint256 pRef, bool rateLimited, bool navFloored) = VaultNavLib.referencePrice(
            nav,
            pMkt,
            !usable || VaultNavLib.referenceOverridden(src, pMkt),
            _pRefX18,
            last == 0 ? 0 : block.timestamp - last,
            _refUpRateBps
        );

        _navPerShareX18 = _toUint128(nav);
        _pRefX18 = _toUint128(pRef);
        _pMktX18 = _toUint128(pMkt);
        _checkpointTimestamp = uint32(block.timestamp);
        _checkpointBlock = uint32(block.number);

        emit NavCheckpoint(nav, assetsUsd18, supply);
        emit RefCheckpoint(pRef, pMkt, rateLimited, navFloored);
        return _snapshot();
    }

    /// @dev The checkpoint as a struct.
    function _snapshot() private view returns (Checkpoint memory snapshot) {
        snapshot = Checkpoint({
            navPerShareX18: _navPerShareX18,
            pRefX18: _pRefX18,
            pMktX18: _pMktX18,
            timestamp: _checkpointTimestamp,
            blockNumber: _checkpointBlock
        });
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — gate, assets, migration predicate
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The management policy, taken by every external state-changing function except {redeemProRata}, the two
    ///      `AmpsBonds` entry points and {emergencyMigrate}: `DEGRADED`, `DIVERGED`, `SCHEDULED_FREEZE` and
    ///      `WATCHDOG` refuse — exactly the four states section 7 step 2 forces — while `GREEN` and `REF_DIVERGED`
    ///      pass, because section 2's table keeps placements alive under `REF_DIVERGED`, anchored at NAV.
    function _requireHealthy() private view {
        _requireGate(false);
    }

    /// @dev The bond policy, taken only by {depositBonded} and {mintVesting}: `DIVERGED` and `SCHEDULED_FREEZE`
    ///      refuse, and `GREEN`, `DEGRADED`, `REF_DIVERGED` and `WATCHDOG` all pass.
    ///
    /// @dev This is the 24/7 bond decision, in the vault. A stale feed or a closed session must not close a bond
    ///      market — the haircut `h_session` widens instead — so the management policy above would be *stricter*
    ///      than the design, not safer: it would shut the markets every weekend. Only a corporate-action freeze, a
    ///      guardian freeze and the divergence breaker close a market, which is exactly what
    ///      `IOracleGate.checkBond` enforces on the `AmpsBonds` side. This check mirrors it as defence in depth: a
    ///      buggy or replaced bonds shell still cannot deposit or mint through a closed market.
    function _requireBondsHealthy() private view {
        _requireGate(true);
    }

    /// @dev The two policies over one gate read. A gate that reverts is treated as absent rather than as a refusal:
    ///      this contract is immutable, and a broken pointer must never be able to lock governance out of replacing
    ///      it. A guardian protocol freeze refuses both policies, and reports as `SCHEDULED_FREEZE`.
    /// @param bondsPath Whether to apply the bond policy instead of the management policy.
    function _requireGate(bool bondsPath) private view {
        address gate = _oracleGate;
        if (gate == address(0)) return;

        try IOracleGate(gate).state(0) returns (GateState gateState) {
            bool refuses = bondsPath
                ? (gateState == GateState.DIVERGED || gateState == GateState.SCHEDULED_FREEZE)
                : (gateState != GateState.GREEN && gateState != GateState.REF_DIVERGED);
            if (refuses) revert GateNotHealthy(uint8(gateState), bytes32(0));
        } catch {
            return;
        }

        try IOracleGate(gate).protocolFreezeUntil() returns (uint32 until) {
            if (until > block.timestamp) revert GateNotHealthy(uint8(GateState.SCHEDULED_FREEZE), bytes32(0));
        } catch {}
    }

    /// @dev Stamps layer A. Never reverts for a gate reason, and a gate that reverts is ignored.
    function _poke() private {
        address gate = _oracleGate;
        if (gate == address(0)) return;
        try IOracleGate(gate).poke() {} catch {}
    }

    /// @dev Adds `token` to the NAV/redemption enumeration. AMPS is never an asset (I5), and re-registration is a
    ///      no-op so the list can never carry a duplicate.
    function _registerAsset(address token) private {
        if (token == address(0) || token == _AMPS) return;
        if (_assetIndex[token] != 0) return;
        _assets.push(token);
        _assetIndex[token] = _assets.length;
    }

    /// @dev Copies the registry's view of the world into {_assets} at genesis: every registered constituent, plus
    ///      the two entry pools' counter assets (WETH and USDG).
    function _registerRegistryAssets() private {
        address[] memory tokens = VaultNavLib.registryAssets(_registry);
        uint256 length = tokens.length;
        for (uint256 i; i < length; ++i) {
            _registerAsset(tokens[i]);
        }
    }

    /// @dev Refuses a write to a set-once pointer once {genesis} has frozen the wiring.
    function _requireWiringOpen() private view {
        if (_wiringFrozen) revert AlreadyInitialized();
    }

    /// @dev Every governed numeric setter funnels through here: one band check, one {OutOfBand} revert site and
    ///      one {VaultParameterChanged} emission for the whole parameter set. Section 9 requires each bound to be
    ///      read from `Constants` and never restated as a literal, which is why the bounds are arguments.
    /// @param name The parameter name as a short string, as it appears in the event and the revert.
    /// @param value The proposed value.
    /// @param min The inclusive lower bound from `Constants`.
    /// @param max The inclusive upper bound from `Constants`.
    /// @param previous The value being replaced, for the event.
    /// @return accepted `value`, once it is known to be inside the band.
    function _band(bytes32 name, uint256 value, uint256 min, uint256 max, uint256 previous)
        private
        returns (uint256 accepted)
    {
        _requireHealthy();
        if (value < min || value > max) revert OutOfBand(name, value, min, max);
        emit VaultParameterChanged(name, previous, value);
        return value;
    }

    /// @dev Narrows to the packed width the checkpoint words use.
    function _toUint128(uint256 value) private pure returns (uint128 narrowed) {
        if (value > type(uint128).max) revert ValueTooLarge(value);
        return uint128(value);
    }
}
