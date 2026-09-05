// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsBonds} from "../interfaces/IAmpsBonds.sol";
import {IAmpsVault} from "../interfaces/IAmpsVault.sol";
import {IBondPolicy} from "../interfaces/IBondPolicy.sol";
import {IFeedRegistry} from "../interfaces/IFeedRegistry.sol";
import {IMarketReference} from "../interfaces/IMarketReference.sol";
import {IOracleGate} from "../interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {PriceLib} from "../lib/PriceLib.sol";
import {Constants} from "../types/Constants.sol";
import {
    CapacityExceeded,
    NotInitialized,
    NotTimelock,
    NotVault,
    OutOfBand,
    Reentrancy,
    SlippageExceeded,
    StaleCheckpoint,
    SweepDirty,
    UnknownMarket,
    UnknownPool,
    ZeroAddress,
    ZeroAmount
} from "../types/Errors.sol";
import {
    BondMarket,
    Checkpoint,
    CollateralClass,
    ConstituentConfig,
    ConstituentStatus,
    PoolConfig,
    Session,
    VestingPosition
} from "../types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title AmpsBonds
/// @notice Custody and vesting shell for the only post-genesis AMPS issuance path (Decision 9). Deposit a
///         registered collateral, receive AMPS at a discount to the spoke's own truncated TWAP but never below
///         `navPerShare x (1 + minAccretionBps)`, vesting linearly.
///
/// @dev **Immutable code, governed state** (Decision 20). Every number is a timelock setter inside a hard band
///      read from `Constants`; the pricing law itself lives behind the {policy} pointer. Written from scratch
///      under MIT: Olympus v2 and Bond Protocol are AGPL-3.0 and were neither imported, copied nor ported.
///
/// @dev **The shell never trusts the policy.** It recomputes `qFloor` itself, with the same rounding directions,
///      after `IBondPolicy.quote` returns, and reverts with {AccretionFloorViolated} on any `q` above it. A
///      hostile or buggy policy pointer can therefore refuse to price a bond, but can never issue a dilutive one.
///
/// @dev **Custody never rests here.** `bond` calls `AmpsVault.depositBonded`, which moves the collateral from the
///      bonder straight into the PoolManager inside one `unlock`; the bonder approves the **vault**. The
///      `sweepClean` invariant (I12) is asserted at the end of `bond` against the market's own collateral. AMPS
///      held for vesting is the one balance this contract carries, and I30 makes it part of `totalSupply` from the
///      moment of purchase.
///
/// @dev **`claim` is structurally ungated** (I38, state model §7). Its code path touches the position array and
///      the immutable AMPS address, and nothing else: no gate, no guardian, no pause flag, no registry, no feed,
///      no policy, and not even the {vault} storage slot. Collateral removal, a market pause, a policy swap, a
///      guardian freeze, a dead feed or a vault replaced by a contract that reverts on every call all leave it
///      working.
///
/// @dev **Derived views live in `AmpsBondsLens`.** Position enumeration and the whole-board quote are pure
///      aggregations of the views below, so they are a separate stateless contract rather than bytecode this
///      contract has to carry inside EIP-170.
///
/// @dev **Storage layout** (`docs/phase2-state-model.md` §1.2), asserted by the layout tests:
///      ```
///      slot 0   address vault [0..159] | uint32 epochSeconds [160..191] | uint16 dailyCapBps [192..207]
///               uint32 vestSeconds [208..239] | uint16 minAccretionBps [240..255]
///      slot 1   address policy [0..159] | uint16 marketCount [160..175] | uint64 defaultKWeightX18 [176..239]
///      slot 2   address registry [0..159] | uint64 defaultKFillX18 [160..223]
///      slot 3   uint128 dailyIssued [0..127] | uint32 dailyWindowStart [128..159]
///      slot 4   mapping(uint16 => BondMarket) markets
///      slot 5   mapping(address => uint16) marketIdOf
///      slot 6   mapping(address => VestingPosition[]) positions
///      ```
///      `amps` is immutable (bytecode, no slot), which is what keeps `claim` free of every governed pointer.
contract AmpsBonds is IAmpsBonds {
    using SafeCast for uint256;

    /// @dev `2**96`, the Q96 scale a v4 sqrt price is quoted in.
    uint256 private constant Q96 = 0x1000000000000000000000000;

    /// @notice The AMPS token. Immutable so that {claim} reads no governed pointer (I38).
    address public immutable amps;

    // ---------------------------------------------------------------------------------------------------------
    // Storage. The declaration order below *is* the packing; do not reorder without re-deriving §1.2.
    // ---------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsBonds
    address public vault;

    /// @inheritdoc IAmpsBonds
    uint32 public epochSeconds;

    /// @inheritdoc IAmpsBonds
    uint16 public dailyCapBps;

    /// @inheritdoc IAmpsBonds
    uint32 public vestSeconds;

    /// @inheritdoc IAmpsBonds
    uint16 public minAccretionBps;

    /// @inheritdoc IAmpsBonds
    address public policy;

    /// @inheritdoc IAmpsBonds
    uint16 public marketCount;

    /// @inheritdoc IAmpsBonds
    uint64 public defaultKWeightX18;

    /// @inheritdoc IAmpsBonds
    address public registry;

    /// @inheritdoc IAmpsBonds
    uint64 public defaultKFillX18;

    /// @dev AMPS wei issued across every market in the current daily window.
    uint128 internal _dailyIssued;

    /// @dev Start of the current daily window. The window is fixed, not sliding: it opens at the first bond after
    ///      the previous one aged out, which is the shape the single-slot accounting in §1.2 supports.
    uint32 internal _dailyWindowStart;

    /// @dev The market records, 1-based. Ids are never reused, so a removed collateral leaves its record readable
    ///      for the positions that still reference it.
    mapping(uint16 marketId => BondMarket record) internal _markets;

    /// @inheritdoc IAmpsBonds
    mapping(address collateral => uint16 marketId) public marketIdOf;

    /// @dev Every bonder's vesting positions. Position ids are indices into this array and are never reordered.
    mapping(address owner => VestingPosition[] list) internal _positions;

    /// @dev The transient reentrancy lock. A lock nobody else can hold and that is released in the same
    ///      transaction is not a gate, which is why {claim} may take it and stay structurally ungated (§7).
    bool private transient _entered;

    /// @notice The vault settled a different amount than the bond was priced on.
    /// @dev Pricing happens on `amountIn`, so anything but an exact settlement would issue AMPS against a deposit
    ///      that never arrived. Fee-on-transfer collateral is rejected here rather than mispriced.
    /// @param settled What `AmpsVault.depositBonded` reported.
    /// @param expected The `amountIn` the quote was priced on.
    error DepositMismatch(uint256 settled, uint256 expected);

    /// @notice An `ENTRY`-class collateral was proposed for a token that is neither entry pool's counter asset.
    /// @param collateral The token.
    error NotAnEntryCollateral(address collateral);

    /// @notice The AMPS transfer out of a claim returned false.
    /// @param to The recipient.
    /// @param amount The AMPS wei.
    error AmpsTransferFailed(address to, uint256 amount);

    /// @dev Takes the transient lock for the duration of the call.
    modifier lock() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    /// @param vault_ The vault. Supplies `amps`, the timelock, the oracle gate, the feed registry and the market
    ///        reference, so that each of those has exactly one home and one pointer to re-point.
    /// @param registry_ The pool registry, for constituent status, pool ids and index weights. Set once here: §1.2
    ///        gives it a storage slot rather than an immutable, and nothing may move it afterwards.
    /// @param policy_ The initial `IBondPolicy`. Replaceable by the 7-day timelock through {setPolicy}.
    constructor(address vault_, address registry_, address policy_) {
        if (vault_ == address(0) || registry_ == address(0) || policy_ == address(0)) revert ZeroAddress();

        address ampsAddress = IAmpsVault(vault_).amps();
        if (ampsAddress == address(0)) revert ZeroAddress();

        amps = ampsAddress;
        vault = vault_;
        registry = registry_;
        policy = policy_;

        epochSeconds = Constants.BOND_EPOCH_SECONDS_DEFAULT;
        dailyCapBps = Constants.BOND_DAILY_CAP_BPS_DEFAULT;
        vestSeconds = Constants.BOND_VEST_SECONDS_DEFAULT;
        minAccretionBps = Constants.MIN_ACCRETION_BPS_DEFAULT;
        defaultKWeightX18 = Constants.BOND_K_WEIGHT_X18_DEFAULT;
        defaultKFillX18 = Constants.BOND_K_FILL_X18_DEFAULT;
        _dailyWindowStart = uint32(block.timestamp);

        emit VaultChanged(address(0), vault_);
        emit PolicyChanged(address(0), policy_);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsBonds
    function oracleGate() public view returns (address gateAddress) {
        gateAddress = IAmpsVault(vault).oracleGate();
    }

    /// @inheritdoc IAmpsBonds
    function hSessionBps(Session session) external view returns (uint16 bps) {
        bps = IOracleGate(oracleGate()).hSessionBps(session);
    }

    /// @inheritdoc IAmpsBonds
    function market(uint16 marketId) external view returns (BondMarket memory record) {
        record = _requireMarketStorage(marketId);
    }

    /// @inheritdoc IAmpsBonds
    function capacityRemaining(uint16 marketId) external view returns (uint256 amount) {
        (amount,,) = _capacity(_requireMarketStorage(marketId));
    }

    /// @inheritdoc IAmpsBonds
    function dailyIssuance() external view returns (uint256 issued, uint256 capacity) {
        issued = _dailyIssuedNow();
        capacity = FullMath.mulDiv(IERC20(amps).totalSupply(), dailyCapBps, Constants.BPS);
    }

    /// @inheritdoc IAmpsBonds
    function positionCount(address owner) external view returns (uint256 count) {
        count = _positions[owner].length;
    }

    /// @inheritdoc IAmpsBonds
    function position(address owner, uint256 positionId) external view returns (VestingPosition memory record) {
        VestingPosition[] storage list = _positions[owner];
        if (positionId >= list.length) revert UnknownPosition(owner, positionId);
        record = list[positionId];
    }

    /// @inheritdoc IAmpsBonds
    function claimable(address owner, uint256 positionId) external view returns (uint256 amount) {
        VestingPosition[] storage list = _positions[owner];
        if (positionId >= list.length) revert UnknownPosition(owner, positionId);
        VestingPosition storage record = list[positionId];
        amount = _vested(record) - record.claimed;
    }

    /// @inheritdoc IAmpsBonds
    function claimableTotal(address owner) external view returns (uint256 amount) {
        VestingPosition[] storage list = _positions[owner];
        uint256 length = list.length;
        for (uint256 i; i < length; ++i) {
            VestingPosition storage record = list[i];
            amount += _vested(record) - record.claimed;
        }
    }

    /// @inheritdoc IAmpsBonds
    function quote(uint16 marketId, uint256 amountIn)
        external
        view
        returns (
            uint256 ampsOut,
            uint256 qX18,
            uint16 discountBps,
            bool floorBinding,
            uint256 capacityLeft,
            bytes32 reason
        )
    {
        _Quote memory result = _quote(marketId, _requireMarketStorage(marketId), amountIn);
        return
            (result.ampsOut, result.qX18, result.discountBps, result.floorBinding, result.capacityLeft, result.reason);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsBonds
    function DISCOUNT_BPS_MIN() external pure returns (uint16 value) {
        value = Constants.DISCOUNT_BPS_MIN;
    }

    /// @inheritdoc IAmpsBonds
    function DISCOUNT_BPS_MAX() external pure returns (uint16 value) {
        value = Constants.DISCOUNT_BPS_MAX;
    }

    /// @inheritdoc IAmpsBonds
    function CAP_BPS_PER_EPOCH_MAX() external pure returns (uint16 value) {
        value = Constants.BOND_CAP_BPS_PER_EPOCH_MAX;
    }

    /// @inheritdoc IAmpsBonds
    function DAILY_CAP_BPS_MAX() external pure returns (uint16 value) {
        value = Constants.BOND_DAILY_CAP_BPS_MAX;
    }

    /// @inheritdoc IAmpsBonds
    function EPOCH_SECONDS_MIN() external pure returns (uint32 value) {
        value = Constants.BOND_EPOCH_SECONDS_MIN;
    }

    /// @inheritdoc IAmpsBonds
    function EPOCH_SECONDS_MAX() external pure returns (uint32 value) {
        value = Constants.BOND_EPOCH_SECONDS_MAX;
    }

    /// @inheritdoc IAmpsBonds
    function VEST_SECONDS_MIN() external pure returns (uint32 value) {
        value = Constants.BOND_VEST_SECONDS_MIN;
    }

    /// @inheritdoc IAmpsBonds
    function VEST_SECONDS_MAX() external pure returns (uint32 value) {
        value = Constants.BOND_VEST_SECONDS_MAX;
    }

    /// @inheritdoc IAmpsBonds
    function H_SESSION_BPS_MAX() external pure returns (uint16 value) {
        value = Constants.H_SESSION_BPS_MAX;
    }

    /// @inheritdoc IAmpsBonds
    function MIN_ACCRETION_BPS_MAX() external pure returns (uint16 value) {
        value = Constants.MIN_ACCRETION_BPS_MAX;
    }

    /// @inheritdoc IAmpsBonds
    function COEFFICIENT_X18_MAX() external pure returns (uint64 value) {
        value = Constants.BOND_COEFFICIENT_X18_MAX;
    }

    /// @inheritdoc IAmpsBonds
    function MAX_COLLATERALS() external pure returns (uint16 value) {
        value = Constants.MAX_COLLATERALS;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — user paths
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsBonds
    function bond(uint16 marketId, uint256 amountIn, uint256 minAmpsOut, address to)
        external
        lock
        returns (uint256 ampsOut, uint256 positionId)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        BondMarket storage stored = _requireMarketStorage(marketId);
        if (!stored.open || marketIdOf[stored.collateral] != marketId) revert MarketClosed(marketId);

        // 1. The gate. Only a corporate-action freeze, a guardian freeze or the divergence breaker refuse; a stale
        //    feed or a closed session widen the haircut instead (Decision 10).
        uint16 haircutBps = IOracleGate(IAmpsVault(vault).oracleGate()).checkBond(stored.constituentId);

        // 2. Roll the market's capacity epoch and the global daily window before anything reads them.
        _rollEpoch(marketId, stored);
        _rollDay();

        // 3. Price it: checkpoint, `m`, `P_i`, the policy, and the shell's own accretion floor.
        _Priced memory priced = _price(stored, amountIn, haircutBps);

        // 4. Capacity: per market per epoch, then globally per day. A clamp to zero closes the market until the
        //    epoch rolls; a partial clamp is disclosed by {quote} and bounded by the caller's `minAmpsOut`.
        (uint256 available,,) = _capacity(stored);
        if (available == 0) revert CapacityExceeded(priced.ampsOut, 0);
        ampsOut = priced.ampsOut > available ? available : priced.ampsOut;
        if (ampsOut == 0) revert ZeroAmount();
        if (ampsOut < minAmpsOut) revert SlippageExceeded(ampsOut, minAmpsOut);

        // 5. Effects, before any interaction.
        uint128 issued = ampsOut.toUint128();
        stored.issuedThisEpoch += issued;
        stored.totalIssued += issued;
        stored.lastBondAt = uint32(block.timestamp);
        _dailyIssued += issued;

        positionId = _positions[to].length;
        _positions[to].push(
            VestingPosition({
                principal: issued,
                claimed: 0,
                start: uint32(block.timestamp),
                vestSeconds: vestSeconds,
                marketId: marketId
            })
        );

        // 6. Interactions, the event and `sweepClean`.
        _settle(marketId, stored.collateral, amountIn, ampsOut, positionId, priced);
    }

    /// @dev Everything `bond` does after its effects are written: the collateral moves bonder -> PoolManager
    ///      without ever resting here, the AMPS is minted to this contract and is in `totalSupply` from this
    ///      instant (I30), and I12 is asserted against the market's own collateral.
    function _settle(
        uint16 marketId,
        address collateral,
        uint256 amountIn,
        uint256 ampsOut,
        uint256 positionId,
        _Priced memory priced
    ) internal {
        address vaultAddress = vault;
        uint256 settled = IAmpsVault(vaultAddress).depositBonded(marketId, collateral, msg.sender, amountIn);
        if (settled != amountIn) revert DepositMismatch(settled, amountIn);
        IAmpsVault(vaultAddress).mintVesting(address(this), ampsOut);

        emit Bond(
            msg.sender,
            marketId,
            collateral,
            amountIn,
            ampsOut,
            positionId,
            priced.qX18,
            priced.discountBps,
            priced.floorBinding
        );

        uint256 dust = IERC20(collateral).balanceOf(address(this));
        if (dust != 0) revert SweepDirty(collateral, dust);
    }

    /// @dev The reverting half of the pricing path: the checkpoint staleness bound, `m` from the spoke's own
    ///      30-minute truncated TWAP, `P_i` from the last Chainlink answer (staleness allowed on purpose), the
    ///      policy call, and the shell's independent accretion floor. The floor re-check is what makes the policy
    ///      pointer safe: a hostile policy can refuse to price, never issue a dilutive bond.
    function _price(BondMarket storage record, uint256 amountIn, uint16 haircutBps)
        internal
        view
        returns (_Priced memory priced)
    {
        Checkpoint memory checkpoint = IAmpsVault(vault).checkpointData();
        uint32 age =
            checkpoint.timestamp >= uint32(block.timestamp) ? 0 : uint32(block.timestamp) - checkpoint.timestamp;
        if (age > Constants.CHECKPOINT_MAX_AGE) revert StaleCheckpoint(age, Constants.CHECKPOINT_MAX_AGE);
        if (checkpoint.navPerShareX18 == 0) revert NotInitialized();

        IBondPolicy.QuoteInput memory input;
        input.mX18 = _marketPriceX18(record);
        input.navPerShareX18 = checkpoint.navPerShareX18;
        input.collateralPriceUsd18 = _collateralPriceUsd18(record);
        input.amountIn18 = _amountIn18(record.decimals, amountIn);
        input.hSessionBps = haircutBps;
        _applyMarketParams(record, input);

        IBondPolicy.QuoteOutput memory output = IBondPolicy(policy).quote(input);

        uint256 floorX18 =
            _qFloorX18(input.collateralPriceUsd18, input.navPerShareX18, haircutBps, input.minAccretionBps);
        if (output.qX18 > floorX18) revert AccretionFloorViolated(output.qX18, floorX18);

        priced = _Priced({
            ampsOut: output.ampsOut,
            qX18: output.qX18,
            discountBps: output.discountBps,
            floorBinding: output.floorBinding
        });
    }

    /// @inheritdoc IAmpsBonds
    /// @dev Structurally ungated. The only reads are `_positions[msg.sender]` and the immutable {amps}; the only
    ///      call is the AMPS transfer. Adding any pointer read here would break I38 and the §7 storage-access
    ///      proof, both of which are asserted in `test/unit/AmpsBonds.t.sol`.
    function claim(uint256 positionId, address to) external lock returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();

        VestingPosition[] storage list = _positions[msg.sender];
        if (positionId >= list.length) revert UnknownPosition(msg.sender, positionId);

        VestingPosition storage record = list[positionId];
        uint256 vested = _vested(record);
        amount = vested - record.claimed;
        if (amount == 0) revert ZeroAmount();
        record.claimed = uint128(vested);

        emit Claim(msg.sender, positionId, to, amount);
        if (!IERC20(amps).transfer(to, amount)) revert AmpsTransferFailed(to, amount);
    }

    /// @inheritdoc IAmpsBonds
    /// @dev Structurally ungated, exactly as {claim}: one pass over the caller's own positions and one transfer.
    function claimAll(address to) external lock returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();

        VestingPosition[] storage list = _positions[msg.sender];
        uint256 length = list.length;
        for (uint256 i; i < length; ++i) {
            VestingPosition storage record = list[i];
            uint256 vested = _vested(record);
            uint256 pending = vested - record.claimed;
            if (pending == 0) continue;
            record.claimed = uint128(vested);
            amount += pending;
            emit Claim(msg.sender, i, to, pending);
        }
        if (amount == 0) revert ZeroAmount();

        if (!IERC20(amps).transfer(to, amount)) revert AmpsTransferFailed(to, amount);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — governance
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsBonds
    /// @dev Callable by the timelock, and by {registry} so that `PoolRegistry.addConstituent` can open the new
    ///      name's market inside its own 7-day operation (state model §3). The registry adds at the launch
    ///      defaults; every band below is enforced identically whichever of the two calls.
    function addCollateral(
        address collateral,
        CollateralClass class_,
        uint16 dBaseBps,
        uint16 dMinBps,
        uint16 dMaxBps,
        uint16 capBpsPerEpoch,
        bool open
    ) external lock returns (uint16 marketId) {
        _requireGovernance();
        if (collateral == address(0)) revert ZeroAddress();

        uint16 existing = marketIdOf[collateral];
        if (existing != 0) revert CollateralExists(collateral, existing);
        if (marketCount >= Constants.MAX_COLLATERALS) revert CollateralSetFull(Constants.MAX_COLLATERALS);

        _validateDiscountParams(dBaseBps, dMinBps, dMaxBps);
        _validateCapBpsPerEpoch(capBpsPerEpoch);

        uint8 decimals = IERC20Metadata(collateral).decimals();
        _checkBand("collateralDecimals", decimals, 0, PriceLib.MAX_COUNTER_DECIMALS);

        uint16 constituentId;
        if (class_ == CollateralClass.CONSTITUENT) {
            constituentId = IPoolRegistry(registry).constituentIdOf(collateral);
            if (constituentId == 0) revert NotAConstituent(collateral);
            ConstituentConfig memory config = IPoolRegistry(registry).constituent(constituentId);
            if (config.token != collateral || config.status != ConstituentStatus.ACTIVE) {
                revert NotAConstituent(collateral);
            }
        } else if (!_isEntryCollateral(collateral)) {
            revert NotAnEntryCollateral(collateral);
        }

        marketId = marketCount + 1;
        marketCount = marketId;
        marketIdOf[collateral] = marketId;

        // `kWeightX18`/`kFillX18` are left at zero, which means "inherit the global default"; {setCoefficients}
        // pins a per-market override.
        _markets[marketId] = BondMarket({
            collateral: collateral,
            class: class_,
            open: open,
            decimals: decimals,
            constituentId: constituentId,
            dBaseBps: dBaseBps,
            dMinBps: dMinBps,
            dMaxBps: dMaxBps,
            capBpsPerEpoch: capBpsPerEpoch,
            kWeightX18: 0,
            kFillX18: 0,
            epochStart: uint32(block.timestamp),
            lastBondAt: 0,
            issuedThisEpoch: 0,
            totalIssued: 0
        });

        emit CollateralAdded(marketId, collateral, class_, constituentId);
        emit MarketOpenSet(marketId, open);
    }

    /// @inheritdoc IAmpsBonds
    function removeCollateral(address collateral) external lock {
        _requireTimelock();

        uint16 marketId = marketIdOf[collateral];
        if (marketId == 0) revert UnknownMarket(marketId);

        delete marketIdOf[collateral];
        _markets[marketId].open = false;

        emit MarketOpenSet(marketId, false);
        emit CollateralRemoved(marketId, collateral);
    }

    /// @inheritdoc IAmpsBonds
    /// @dev Callable by the timelock, and by {registry} so that `PoolRegistry.retireConstituent` can close the
    ///      name's market inside its own 7-day operation — which is what makes "a retired constituent has no open
    ///      bond market" (I37) atomic rather than a two-proposal race.
    function setMarketOpen(uint16 marketId, bool open) external lock {
        _requireGovernance();

        BondMarket storage record = _requireMarketStorage(marketId);
        if (open && marketIdOf[record.collateral] != marketId) revert UnknownMarket(marketId);

        record.open = open;
        emit MarketOpenSet(marketId, open);
    }

    /// @inheritdoc IAmpsBonds
    function setDiscountParams(uint16 marketId, uint16 dBaseBps, uint16 dMinBps, uint16 dMaxBps) external lock {
        _requireTimelock();
        _validateDiscountParams(dBaseBps, dMinBps, dMaxBps);

        BondMarket storage record = _requireMarketStorage(marketId);
        emit BondParameterChanged(marketId, "dBaseBps", record.dBaseBps, dBaseBps);
        emit BondParameterChanged(marketId, "dMinBps", record.dMinBps, dMinBps);
        emit BondParameterChanged(marketId, "dMaxBps", record.dMaxBps, dMaxBps);

        record.dBaseBps = dBaseBps;
        record.dMinBps = dMinBps;
        record.dMaxBps = dMaxBps;
    }

    /// @inheritdoc IAmpsBonds
    /// @dev `marketId == 0` sets the global defaults that every market with no override uses; any other id pins an
    ///      override on that market. A market's override is "unset" exactly when it is zero, so pinning a true
    ///      zero coefficient is expressed as 1 wei — a difference of 1e-18 in a term that moves the discount by at
    ///      most `COEFFICIENT_BPS_SCALE` bps per unit.
    function setCoefficients(uint16 marketId, uint64 kWeightX18, uint64 kFillX18) external lock {
        _requireTimelock();
        _checkBand("kWeightX18", kWeightX18, 0, Constants.BOND_COEFFICIENT_X18_MAX);
        _checkBand("kFillX18", kFillX18, 0, Constants.BOND_COEFFICIENT_X18_MAX);

        if (marketId == 0) {
            emit BondParameterChanged(0, "defaultKWeightX18", defaultKWeightX18, kWeightX18);
            emit BondParameterChanged(0, "defaultKFillX18", defaultKFillX18, kFillX18);
            defaultKWeightX18 = kWeightX18;
            defaultKFillX18 = kFillX18;
            return;
        }

        BondMarket storage record = _requireMarketStorage(marketId);
        emit BondParameterChanged(marketId, "kWeightX18", record.kWeightX18, kWeightX18);
        emit BondParameterChanged(marketId, "kFillX18", record.kFillX18, kFillX18);
        record.kWeightX18 = kWeightX18;
        record.kFillX18 = kFillX18;
    }

    /// @inheritdoc IAmpsBonds
    function setCapBpsPerEpoch(uint16 marketId, uint16 capBpsPerEpoch) external lock {
        _requireTimelock();
        _validateCapBpsPerEpoch(capBpsPerEpoch);

        BondMarket storage record = _requireMarketStorage(marketId);
        emit BondParameterChanged(marketId, "capBpsPerEpoch", record.capBpsPerEpoch, capBpsPerEpoch);
        record.capBpsPerEpoch = capBpsPerEpoch;
    }

    /// @inheritdoc IAmpsBonds
    function setEpochSeconds(uint32 value) external lock {
        _requireTimelock();
        _checkBand("epochSeconds", value, Constants.BOND_EPOCH_SECONDS_MIN, Constants.BOND_EPOCH_SECONDS_MAX);
        emit BondParameterChanged(0, "epochSeconds", epochSeconds, value);
        epochSeconds = value;
    }

    /// @inheritdoc IAmpsBonds
    function setDailyCapBps(uint16 value) external lock {
        _requireTimelock();
        _checkBand("dailyCapBps", value, 0, Constants.BOND_DAILY_CAP_BPS_MAX);
        emit BondParameterChanged(0, "dailyCapBps", dailyCapBps, value);
        dailyCapBps = value;
    }

    /// @inheritdoc IAmpsBonds
    function setVestSeconds(uint32 value) external lock {
        _requireTimelock();
        _checkBand("vestSeconds", value, Constants.BOND_VEST_SECONDS_MIN, Constants.BOND_VEST_SECONDS_MAX);
        emit BondParameterChanged(0, "vestSeconds", vestSeconds, value);
        vestSeconds = value;
    }

    /// @inheritdoc IAmpsBonds
    function setMinAccretionBps(uint16 value) external lock {
        _requireTimelock();
        _checkBand("minAccretionBps", value, 0, Constants.MIN_ACCRETION_BPS_MAX);
        emit BondParameterChanged(0, "minAccretionBps", minAccretionBps, value);
        minAccretionBps = value;
    }

    /// @inheritdoc IAmpsBonds
    function setPolicy(address newPolicy) external lock {
        _requireTimelock();
        if (newPolicy == address(0)) revert ZeroAddress();

        address previous = policy;
        policy = newPolicy;
        emit PolicyChanged(previous, newPolicy);
    }

    /// @inheritdoc IAmpsBonds
    function setVault(address newVault) external lock {
        if (msg.sender != vault) revert NotVault(msg.sender);
        if (newVault == address(0)) revert ZeroAddress();

        address previous = vault;
        vault = newVault;
        emit VaultChanged(previous, newVault);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — pricing
    // -------------------------------------------------------------------------------------------------------------

    /// @dev What `bond` keeps of a policy quote once the shell has re-checked the floor.
    struct _Priced {
        uint256 ampsOut;
        uint256 qX18;
        uint16 discountBps;
        bool floorBinding;
    }

    /// @dev The non-reverting quote, shared by {quote}. Every external read is wrapped, so a dead gate, a dead
    ///      feed, an unobserved pool or a hostile policy produce a `reason` rather than a revert.
    struct _Quote {
        uint256 ampsOut;
        uint256 qX18;
        uint16 discountBps;
        bool floorBinding;
        uint256 capacityLeft;
        bytes32 reason;
    }

    /// @dev Everything {quote} must read from another contract, gathered behind try/catch so that a dead gate, a
    ///      dead feed, an unobserved pool or a replaced vault produce a `reason` instead of a revert.
    struct _Context {
        address gate;
        address feed;
        address marketReference;
        uint256 navPerShareX18;
        uint256 mX18;
        uint256 collateralPriceUsd18;
        uint16 haircutBps;
        bytes32 reason;
    }

    /// @dev See {quote}. The pricing arithmetic is shared with `bond`; only the error handling differs.
    function _quote(uint16 marketId, BondMarket storage record, uint256 amountIn)
        internal
        view
        returns (_Quote memory result)
    {
        (result.capacityLeft,,) = _capacity(record);

        if (!record.open || marketIdOf[record.collateral] != marketId) {
            result.reason = "marketClosed";
            return result;
        }

        _Context memory context = _collect(record);
        if (context.reason != bytes32(0)) {
            result.reason = context.reason;
            return result;
        }

        IBondPolicy.QuoteInput memory input;
        input.mX18 = context.mX18;
        input.navPerShareX18 = context.navPerShareX18;
        input.collateralPriceUsd18 = context.collateralPriceUsd18;
        input.amountIn18 = _amountIn18(record.decimals, amountIn);
        input.hSessionBps = context.haircutBps;
        _applyMarketParams(record, input);

        try IBondPolicy(policy).quote(input) returns (IBondPolicy.QuoteOutput memory output) {
            result.ampsOut = output.ampsOut;
            result.qX18 = output.qX18;
            result.discountBps = output.discountBps;
            result.floorBinding = output.floorBinding;
        } catch {
            result.reason = "policyRefused";
            return result;
        }

        if (
            result.qX18
                > _qFloorX18(input.collateralPriceUsd18, input.navPerShareX18, input.hSessionBps, input.minAccretionBps)
        ) {
            result.ampsOut = 0;
            result.reason = "floorViolated";
            return result;
        }

        if (result.capacityLeft == 0) {
            result.ampsOut = 0;
            result.reason = "capacityFull";
            return result;
        }
        if (result.ampsOut > result.capacityLeft) result.ampsOut = result.capacityLeft;
        if (result.ampsOut == 0) result.reason = "zeroAmount";
    }

    /// @dev The gathering half of {quote}: pointers, gate, checkpoint, pool, TWAP and feed answer, each wrapped.
    ///      `context.reason` is non-zero exactly when the bond could not be priced at all.
    function _collect(BondMarket storage record) internal view returns (_Context memory context) {
        address vaultAddress = vault;
        bool pointersOk;
        (pointersOk, context.gate, context.feed, context.marketReference) = _tryPointers(vaultAddress);
        if (!pointersOk) {
            context.reason = "vaultDown";
            return context;
        }

        try IOracleGate(context.gate).checkBond(record.constituentId) returns (uint16 value) {
            context.haircutBps = value;
        } catch {
            context.reason = "gateRefused";
            return context;
        }

        try IAmpsVault(vaultAddress).checkpointData() returns (Checkpoint memory checkpoint) {
            uint32 age =
                checkpoint.timestamp >= uint32(block.timestamp) ? 0 : uint32(block.timestamp) - checkpoint.timestamp;
            if (age > Constants.CHECKPOINT_MAX_AGE) {
                context.reason = "staleCheckpoint";
                return context;
            }
            context.navPerShareX18 = checkpoint.navPerShareX18;
        } catch {
            context.reason = "vaultDown";
            return context;
        }
        if (context.navPerShareX18 == 0) {
            context.reason = "noNav";
            return context;
        }

        (bool poolOk, PoolId poolId) = _tryPoolId(record.class, record.constituentId, record.collateral);
        if (!poolOk) {
            context.reason = "noPool";
            return context;
        }

        try IMarketReference(context.marketReference).twapTick30m(poolId) returns (int24 meanTick) {
            context.mX18 = _ampsPerCollateralX18(meanTick, record.decimals);
        } catch {
            context.reason = "noTwap";
            return context;
        }
        if (context.mX18 == 0) {
            context.reason = "noTwap";
            return context;
        }

        try IFeedRegistry(context.feed).latestAnswer(record.collateral) returns (uint256 answerUsd8, uint32, bool) {
            if (answerUsd8 == 0) {
                context.reason = "noPrice";
                return context;
            }
            context.collateralPriceUsd18 =
                PriceLib.counterValueUsd18(10 ** record.decimals, record.decimals, answerUsd8);
        } catch {
            context.reason = "noPrice";
            return context;
        }
    }

    /// @dev Copies the market's governed parameters into a policy input, resolving the coefficients to the global
    ///      defaults whenever the market carries no override, and computing the deficit and fill terms.
    function _applyMarketParams(BondMarket storage record, IBondPolicy.QuoteInput memory input) internal view {
        // The fill term is measured against the market's own per-epoch capacity, not against what the global daily
        // cap leaves of it: the discount decays as *this market's* epoch fills.
        (, uint256 capacity, uint128 issuedThisEpoch) = _capacity(record);

        input.dBaseBps = record.dBaseBps;
        input.dMinBps = record.dMinBps;
        input.dMaxBps = record.dMaxBps;
        input.kWeightX18 = record.kWeightX18 == 0 ? defaultKWeightX18 : record.kWeightX18;
        input.kFillX18 = record.kFillX18 == 0 ? defaultKFillX18 : record.kFillX18;
        input.deficitX18 = _deficitX18(record);
        input.fillX18 = _fillX18(issuedThisEpoch, capacity);
        input.minAccretionBps = minAccretionBps;
    }

    /// @dev The accretion floor, recomputed by the shell with the rounding directions §6 mandates: numerator down,
    ///      denominator up, quotient down. Deliberately a duplicate of `BondPolicy.qFloorX18` — the whole point is
    ///      that the two are computed independently and compared.
    function _qFloorX18(uint256 collateralPriceUsd18, uint256 navPerShareX18, uint16 haircutBps, uint16 accretionBps)
        internal
        pure
        returns (uint256 floorX18)
    {
        if (haircutBps >= Constants.BPS || navPerShareX18 == 0) return 0;
        uint256 numerator = FullMath.mulDiv(collateralPriceUsd18, Constants.BPS - haircutBps, Constants.BPS);
        uint256 denominator =
            FullMath.mulDivRoundingUp(navPerShareX18, Constants.BPS + uint256(accretionBps), Constants.BPS);
        floorX18 = FullMath.mulDiv(numerator, Constants.WAD, denominator);
    }

    /// @dev `m`: AMPS wei per whole unit of collateral, i.e. per 1e18 of the normalised `amountIn18`, from the
    ///      pool's 30-minute truncated TWAP.
    ///
    ///      AMPS is `currency0` in all 32 pools, so the pool price is *collateral raw units per AMPS raw unit* and
    ///      `m` is its reciprocal scaled to the collateral's decimals:
    ///      `m = 10**decimals x 2**192 / sqrtPriceX96**2`. No USD price enters, which is what keeps `m` live
    ///      through a dead feed and a closed session. Both halves of the division round **down**, so `m` does.
    ///
    ///      The largest reachable value is `1e18 x 2**128` at `MIN_SQRT_PRICE`, comfortably inside `uint256`.
    function _ampsPerCollateralX18(int24 meanTick, uint8 decimals) internal pure returns (uint256 mX18) {
        uint256 sqrtPriceX96 = PriceLib.tickToSqrtPriceX96(meanTick);
        uint256 half = FullMath.mulDiv(10 ** decimals, Q96, sqrtPriceX96);
        mX18 = FullMath.mulDiv(half, Q96, sqrtPriceX96);
    }

    /// @dev {_ampsPerCollateralX18} for a market, resolving the pool it prices against: the constituent's spoke,
    ///      or the entry pool whose counter asset is the collateral.
    function _marketPriceX18(BondMarket storage record) internal view returns (uint256 mX18) {
        (bool ok, PoolId poolId) = _tryPoolId(record.class, record.constituentId, record.collateral);
        if (!ok) revert UnknownPool(bytes32(0));
        int24 meanTick = IMarketReference(IAmpsVault(vault).marketReference()).twapTick30m(poolId);
        mX18 = _ampsPerCollateralX18(meanTick, record.decimals);
    }

    /// @dev The collateral's last Chainlink answer as 18-decimal USD per whole token. Staleness is allowed: the
    ///      haircut, not a revert, is what bounds a stale answer (Decision 10).
    function _collateralPriceUsd18(BondMarket storage record) internal view returns (uint256 price18) {
        (uint256 answerUsd8,,) = IFeedRegistry(IAmpsVault(vault).feedRegistry()).latestAnswer(record.collateral);
        if (answerUsd8 == 0) revert IBondPolicy.InvalidQuoteInput("collateralPriceUsd18");
        price18 = PriceLib.counterValueUsd18(10 ** record.decimals, record.decimals, answerUsd8);
    }

    /// @dev The deposit normalised to 18 decimals, so USDG's 6 decimals are scaled up once, in the shell, before
    ///      the policy sees anything (§6).
    function _amountIn18(uint8 decimals, uint256 amountIn) internal pure returns (uint256 amountIn18) {
        amountIn18 = amountIn * (10 ** (PriceLib.MAX_COUNTER_DECIMALS - decimals));
    }

    /// @dev `deficit = clamp((w_target - w_current) / w_target, 0, 1)`, rounded **down**: a smaller deficit widens
    ///      the discount less. Zero for `ENTRY`-class markets (they are not index constituents) and zero whenever
    ///      the registry cannot report a realised weight — see {_tryCurrentWeightBps}.
    function _deficitX18(BondMarket storage record) internal view returns (uint64 deficitX18) {
        if (record.class != CollateralClass.CONSTITUENT || record.constituentId == 0) return 0;

        address registryAddress = registry;
        uint16 targetWeightBps;
        try IPoolRegistry(registryAddress).constituent(record.constituentId) returns (ConstituentConfig memory config) {
            targetWeightBps = config.targetWeightBps;
        } catch {
            return 0;
        }
        if (targetWeightBps == 0) return 0;

        (bool ok, uint16 currentWeightBps) = _tryCurrentWeightBps(registryAddress, record.constituentId);
        if (!ok || currentWeightBps >= targetWeightBps) return 0;

        deficitX18 = uint64(FullMath.mulDiv(targetWeightBps - currentWeightBps, Constants.WAD, targetWeightBps));
    }

    /// @dev The bounded probe behind `IPoolRegistry.currentWeightBps`. The call is typed — the registry declares
    ///      the view — but it is still capped at `Constants.STOCK_TOKEN_PROBE_GAS` and still `try`/`catch`ed: any
    ///      failure (a revert, a short or malformed return, a registry deployed before the view existed) reads as
    ///      "unknown" and prices `deficit == 0`, never as a weight. A registry that cannot answer must never be
    ///      able to close a bond market, which is why this is not a plain call.
    function _tryCurrentWeightBps(address registryAddress, uint16 constituentId)
        internal
        view
        returns (bool ok, uint16 weightBps)
    {
        try IPoolRegistry(registryAddress).currentWeightBps{gas: Constants.STOCK_TOKEN_PROBE_GAS}(
            constituentId
        ) returns (
            uint16 raw
        ) {
            if (raw > Constants.BPS) return (false, 0);
            return (true, raw);
        } catch {
            return (false, 0);
        }
    }

    /// @dev `fill = clamp(issuedThisEpoch / capacity, 0, 1)`, rounded **up**: a larger fill narrows the discount
    ///      more. A market with no capacity at all reads as completely full.
    function _fillX18(uint128 issuedThisEpoch, uint256 capacity) internal pure returns (uint64 fillX18) {
        if (capacity == 0 || issuedThisEpoch >= capacity) return uint64(Constants.WAD);
        fillX18 = uint64(FullMath.mulDivRoundingUp(issuedThisEpoch, Constants.WAD, capacity));
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — capacity and vesting
    // -------------------------------------------------------------------------------------------------------------

    /// @dev What a market may still issue right now: its per-epoch capacity less what the current epoch has
    ///      already used, then clamped by what the global daily cap leaves. Both are computed against the live
    ///      `Amps.totalSupply()`, and both roll forward in the view exactly as `bond` would roll them in storage.
    /// @return remaining The AMPS wei still issuable, after the daily cap.
    /// @return capacity The market's whole per-epoch capacity.
    /// @return issuedThisEpoch What the current epoch has used, zero when the epoch has aged out.
    function _capacity(BondMarket storage record)
        internal
        view
        returns (uint256 remaining, uint256 capacity, uint128 issuedThisEpoch)
    {
        uint256 supply = IERC20(amps).totalSupply();
        capacity = FullMath.mulDiv(supply, record.capBpsPerEpoch, Constants.BPS);

        bool epochLive = block.timestamp < uint256(record.epochStart) + epochSeconds;
        issuedThisEpoch = epochLive ? record.issuedThisEpoch : 0;

        uint256 epochLeft = capacity > issuedThisEpoch ? capacity - issuedThisEpoch : 0;

        uint256 dailyCapacity = FullMath.mulDiv(supply, dailyCapBps, Constants.BPS);
        uint256 dailyIssued = _dailyIssuedNow();
        uint256 dailyLeft = dailyCapacity > dailyIssued ? dailyCapacity - dailyIssued : 0;

        remaining = epochLeft < dailyLeft ? epochLeft : dailyLeft;
    }

    /// @dev What the current daily window has issued, rolling the window forward in the view.
    function _dailyIssuedNow() internal view returns (uint256 issued) {
        issued = block.timestamp >= uint256(_dailyWindowStart) + Constants.ONE_DAY ? 0 : _dailyIssued;
    }

    /// @dev Advances the market to the epoch containing `block.timestamp`, on the fixed grid its `epochStart`
    ///      defines, and zeroes the epoch's issuance. A no-op inside a live epoch.
    function _rollEpoch(uint16 marketId, BondMarket storage record) internal {
        uint32 length = epochSeconds;
        uint32 start = record.epochStart;
        if (block.timestamp < uint256(start) + length) return;

        uint32 elapsed = uint32(block.timestamp) - start;
        uint32 newStart = start + (elapsed / length) * length;
        uint128 previousIssued = record.issuedThisEpoch;

        record.epochStart = newStart;
        record.issuedThisEpoch = 0;
        emit EpochRolled(marketId, newStart, previousIssued);
    }

    /// @dev Opens a new daily window once the previous one has aged out.
    function _rollDay() internal {
        if (block.timestamp < uint256(_dailyWindowStart) + Constants.ONE_DAY) return;
        _dailyWindowStart = uint32(block.timestamp);
        _dailyIssued = 0;
    }

    /// @dev Linear vest with no cliff, floored: `principal x min(now - start, vestSeconds) / vestSeconds`. The
    ///      position's own `vestSeconds` is used, never the governed one, so a governance change can neither
    ///      lengthen nor shorten a vest already sold (I38).
    function _vested(VestingPosition storage record) internal view returns (uint256 vested) {
        uint256 principal = record.principal;
        uint32 length = record.vestSeconds;
        uint256 elapsed = block.timestamp - record.start;
        if (length == 0 || elapsed >= length) return principal;
        vested = FullMath.mulDiv(principal, elapsed, length);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals — lookups and guards
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The vault's pointers, wrapped so a dead or replaced vault degrades {quote} instead of reverting it.
    function _tryPointers(address vaultAddress)
        internal
        view
        returns (bool ok, address gateAddress, address feedAddress, address referenceAddress)
    {
        try IAmpsVault(vaultAddress).oracleGate() returns (address value) {
            gateAddress = value;
        } catch {
            return (false, address(0), address(0), address(0));
        }
        try IAmpsVault(vaultAddress).feedRegistry() returns (address value) {
            feedAddress = value;
        } catch {
            return (false, address(0), address(0), address(0));
        }
        try IAmpsVault(vaultAddress).marketReference() returns (address value) {
            referenceAddress = value;
        } catch {
            return (false, address(0), address(0), address(0));
        }
        ok = gateAddress != address(0) && feedAddress != address(0) && referenceAddress != address(0);
    }

    /// @dev The pool a market prices against: the constituent's spoke, or whichever entry pool holds this
    ///      collateral as its counter asset. Never reverts; the caller decides what a miss means.
    function _tryPoolId(CollateralClass class_, uint16 constituentId, address collateral)
        internal
        view
        returns (bool ok, PoolId poolId)
    {
        IPoolRegistry poolRegistry = IPoolRegistry(registry);

        if (class_ == CollateralClass.CONSTITUENT) {
            try poolRegistry.poolIdOf(constituentId) returns (PoolId value) {
                return (PoolId.unwrap(value) != bytes32(0), value);
            } catch {
                return (false, PoolId.wrap(bytes32(0)));
            }
        }

        try poolRegistry.hubPoolId() returns (PoolId hub) {
            if (_isCounter(poolRegistry, hub, collateral)) return (true, hub);
        } catch {}

        try poolRegistry.wethPoolId() returns (PoolId weth) {
            if (_isCounter(poolRegistry, weth, collateral)) return (true, weth);
        } catch {}

        return (false, PoolId.wrap(bytes32(0)));
    }

    /// @dev Whether `collateral` is the counter asset of a *registered* pool. An unregistered pool is no pool:
    ///      pricing against one would let a de-registered entry pool keep quoting off a stale observation ring.
    function _isCounter(IPoolRegistry poolRegistry, PoolId poolId, address collateral) internal view returns (bool) {
        if (PoolId.unwrap(poolId) == bytes32(0)) return false;
        try poolRegistry.poolConfig(poolId) returns (PoolConfig memory config) {
            return config.registered && config.counter == collateral;
        } catch {
            return false;
        }
    }

    /// @dev Whether `collateral` is an entry pool's counter asset, i.e. eligible for an `ENTRY`-class market.
    function _isEntryCollateral(address collateral) internal view returns (bool ok) {
        (ok,) = _tryPoolId(CollateralClass.ENTRY, 0, collateral);
    }

    /// @dev The market record, reverting on an id that was never issued.
    function _requireMarketStorage(uint16 marketId) internal view returns (BondMarket storage record) {
        if (marketId == 0 || marketId > marketCount) revert UnknownMarket(marketId);
        record = _markets[marketId];
    }

    /// @dev The governance address: the vault's timelock, which is the protocol's single governance home.
    function _timelock() internal view returns (address timelockAddress) {
        timelockAddress = IAmpsVault(vault).timelock();
    }

    /// @dev Reverts unless the caller is the timelock.
    function _requireTimelock() internal view {
        if (msg.sender != _timelock()) revert NotTimelock(msg.sender);
    }

    /// @dev Reverts unless the caller is the timelock or the pool registry. The registry reaches these two
    ///      functions only from inside its own 7-day lifecycle operations, which is what makes "a new constituent
    ///      opens its bond market" and "a retired constituent has no open bond market" (I37) atomic rather than a
    ///      two-proposal race. A caller that is neither is refused as a governance caller.
    function _requireGovernance() internal view {
        if (msg.sender == registry) return;
        if (msg.sender != _timelock()) revert NotTimelock(msg.sender);
    }

    /// @dev The one band check every governed setter funnels through, so that `OutOfBand(parameter, value, min,
    ///      max)` is constructed in a single place and no bound is ever restated as a literal.
    function _checkBand(bytes32 parameter, uint256 value, uint256 min, uint256 max) internal pure {
        if (value < min || value > max) revert OutOfBand(parameter, value, min, max);
    }

    /// @dev Every discount parameter inside the hard band, and the clamp the right way round.
    function _validateDiscountParams(uint16 dBaseBps, uint16 dMinBps, uint16 dMaxBps) internal pure {
        _checkBand("dBaseBps", dBaseBps, Constants.DISCOUNT_BPS_MIN, Constants.DISCOUNT_BPS_MAX);
        _checkBand("dMinBps", dMinBps, Constants.DISCOUNT_BPS_MIN, Constants.DISCOUNT_BPS_MAX);
        _checkBand("dMaxBps", dMaxBps, Constants.DISCOUNT_BPS_MIN, Constants.DISCOUNT_BPS_MAX);
        if (dMinBps > dMaxBps) revert OutOfBand("dMinBps", dMinBps, Constants.DISCOUNT_BPS_MIN, dMaxBps);
    }

    /// @dev The per-epoch capacity inside its hard ceiling.
    function _validateCapBpsPerEpoch(uint16 capBpsPerEpoch) internal pure {
        _checkBand("capBpsPerEpoch", capBpsPerEpoch, 0, Constants.BOND_CAP_BPS_PER_EPOCH_MAX);
    }
}
