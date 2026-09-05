// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBountyPot} from "../interfaces/IBountyPot.sol";
import {Constants} from "../types/Constants.sol";
import {NotTimelock, NotVault, OutOfBand, ZeroAddress, ZeroAmount} from "../types/Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title BountyPot
/// @notice The segregated keeper bounty pot: immutable bytecode, timelock-governed parameters, funded in USDG and
///         paid out to whoever calls the permissionless keeper jobs (`compound`, `rollout`, `deployBonded`).
///
/// @dev **Segregation is the point (invariant I21).** The pot's balance is deliberately excluded from the NAV
///      numerator `A`. It is an operating budget, not backing: counting it would make every bounty payment look
///      like a NAV loss, and would let a governance top-up look like accretion. The vault never reads
///      {balance} when it checkpoints, and never moves value out of here for anything but {pay}.
///
/// @dev **A depleted pot degrades, it never reverts.** {pay} returns what it could actually transfer, which is
///      zero when the pot is empty or a cap binds, and emits {BountyPaid} with a `reason` either way so the keeper
///      dashboards can see refusals. The jobs it funds stay permissionless and stay callable unpaid, so an empty
///      pot slows the protocol down and stops nothing. The only reverts on the {pay} path are caller errors: a
///      non-vault caller and a zero recipient.
///
/// @dev **The payout formula**, in the order the caps are applied (Decision 17, "Ladder placement"):
///      ```
///      if (workValueUsd18 <  chostUsd18)                    -> 0, "chost"        // dust guard on the *work*
///      gross   = tipUsd18 + workValueUsd18 * chipBps / BPS                       // flat tip + chip
///      gross   = min(gross, gasCapMultiple * gasCostUsd18)  -> "gasCap"          // gas cost at a capped basefee
///      gross   = min(gross, dailyCeilingUsd18 - spentLast24h()) -> "dailyCeiling"
///      paidRaw = min(gross / 1e12, balance())              -> "depleted"        // USDG has 6 decimals
///      ```
///      `gasCostUsd18` arrives already computed by the vault as `gasUsed x min(basefee, basefeeCap) x ethUsd`, so
///      the basefee cap lives in the caller and this contract only applies the multiple. `chostUsd18` is not a cap
///      but a floor on the work: it is what makes a spam campaign of dust-sized `compound()` calls pay exactly
///      zero, however many of them are submitted.
///
/// @dev **The rolling window.** `docs/phase2-state-model.md` §1.6 gives this contract one accumulator and one
///      timestamp, so the ceiling is a rolling *reset* window rather than a true trailing sum: the window opens
///      with the first payment that lands 24 h or more after the previous one opened, and everything paid inside
///      it counts against one ceiling. A true trailing sum would need a ring buffer that the immutable layout does
///      not have, and would buy nothing: the property that matters is that no 24-hour interval can pay out more
///      than two ceilings, which this gives.
contract BountyPot is IBountyPot {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------------------------------------------
    // Hard bands
    // -----------------------------------------------------------------------------------------------------------
    //
    // Each of these is `Constants`'s band, restated as a getter so the dApp and the governance drills can read the
    // bound off the contract that enforces it rather than off a literal (state model §9). `Constants` is the one
    // declaration; nothing below is a second one.

    /// @notice Hard ceiling of `tipUsd18`. $5 is a hundred times the launch tip and already far past the point
    ///         where a flat tip is the dominant term for a $5k book.
    uint256 public constant TIP_USD18_MAX = Constants.TIP_USD18_MAX;

    /// @notice Hard ceiling of `chipBps`. 10% of realised work value; there is no floor beyond zero.
    uint16 public constant CHIP_BPS_MAX = Constants.CHIP_BPS_MAX;

    /// @notice Hard ceiling of `chostUsd18`. A dust guard above $1,000 of work value would silence every job the
    ///         launch book can generate, which is a migration decision, not a parameter change.
    uint256 public constant CHOST_USD18_MAX = Constants.CHOST_USD18_MAX;

    /// @notice Hard floor of `gasCapMultiple`. Zero would mean no job is ever paid, whatever the other parameters
    ///         say, which is what a zero `dailyCeilingUsd18` is for.
    uint16 public constant GAS_CAP_MULTIPLE_MIN = Constants.GAS_CAP_MULTIPLE_MIN;

    /// @notice Hard ceiling of `gasCapMultiple`. Beyond 10x the observed gas cost the cap stops bounding a gas
    ///         spike at all.
    uint16 public constant GAS_CAP_MULTIPLE_MAX = Constants.GAS_CAP_MULTIPLE_MAX;

    /// @notice Hard ceiling of `dailyCeilingUsd18`. $100k a day is four thousand times the launch ceiling; there is
    ///         no floor, because setting the ceiling to zero is the governance path for pausing paid keeping
    ///         without pausing the jobs themselves.
    uint256 public constant DAILY_CEILING_USD18_MAX = Constants.DAILY_CEILING_USD18_MAX;

    /// @notice Launch `dailyCeilingUsd18`: $25 a day, sized to the $5k launch.
    uint256 public constant DAILY_CEILING_USD18_DEFAULT = Constants.DAILY_CEILING_USD18_DEFAULT;

    // -----------------------------------------------------------------------------------------------------------
    // Immutables
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IBountyPot
    address public immutable override token;

    /// @inheritdoc IBountyPot
    address public immutable override timelock;

    /// @dev `10 ** (18 - token.decimals())`: the divisor from 18-decimal USD to the token's raw units. Read once,
    ///      at construction, so a 6-decimal USDG and an 18-decimal test token both work without a magic number.
    uint256 private immutable _usdScale;

    // -----------------------------------------------------------------------------------------------------------
    // Storage (`docs/phase2-state-model.md` §1.6)
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IBountyPot
    uint256 public override tipUsd18;

    /// @inheritdoc IBountyPot
    uint256 public override chostUsd18;

    /// @inheritdoc IBountyPot
    uint256 public override dailyCeilingUsd18;

    /// @dev Paid inside the open window, 18-decimal USD. Read through {spentLast24h}, which zeroes it once the
    ///      window has expired rather than writing on a view.
    uint128 private _spentWindowUsd18;

    /// @dev When the open window started. Zero before the first payment.
    uint32 private _windowStart;

    /// @inheritdoc IBountyPot
    uint16 public override chipBps;

    /// @inheritdoc IBountyPot
    uint16 public override gasCapMultiple;

    /// @inheritdoc IBountyPot
    address public override vault;

    // -----------------------------------------------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------------------------------------------

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock(msg.sender);
        _;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------------------------------------------

    /// @param token_ The pot's token: USDG on chain 4663, 6 decimals.
    /// @param vault_ The initial `AmpsVault`: the sole caller of {pay} and {setVault}.
    /// @param timelock_ The 48-hour timelock, the sole caller of {sweep} and of every `set*`.
    /// @dev Every parameter starts at its launch value from `Constants`, each inside its band by construction.
    constructor(address token_, address vault_, address timelock_) {
        if (token_ == address(0) || vault_ == address(0) || timelock_ == address(0)) revert ZeroAddress();

        uint8 decimals = IERC20Metadata(token_).decimals();
        if (decimals > 18) revert UnsupportedDecimals(decimals);

        token = token_;
        timelock = timelock_;
        _usdScale = 10 ** (18 - decimals);

        vault = vault_;
        tipUsd18 = Constants.KEEPER_TIP_USD18_DEFAULT;
        chostUsd18 = Constants.KEEPER_CHOST_USD18_DEFAULT;
        dailyCeilingUsd18 = Constants.DAILY_CEILING_USD18_DEFAULT;
        chipBps = Constants.KEEPER_CHIP_BPS_DEFAULT;
        gasCapMultiple = Constants.KEEPER_GAS_CAP_MULTIPLE;

        emit VaultChanged(address(0), vault_);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Reads
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IBountyPot
    function balance() public view override returns (uint256 balanceRaw) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @inheritdoc IBountyPot
    function spentLast24h() public view override returns (uint256 value) {
        uint32 start = _windowStart;
        if (start == 0 || block.timestamp - start >= Constants.ONE_DAY) return 0;
        return _spentWindowUsd18;
    }

    /// @inheritdoc IBountyPot
    function quote(uint256 workValueUsd18, uint256 gasCostUsd18)
        external
        view
        override
        returns (uint256 payableRaw, bytes32 reason)
    {
        return _quote(workValueUsd18, gasCostUsd18);
    }

    /// @inheritdoc IBountyPot
    function budgetLeftUsd18() public view override returns (uint256 value) {
        return Math.saturatingSub(dailyCeilingUsd18, spentLast24h());
    }

    /// @inheritdoc IBountyPot
    /// @dev This is the amount {pay} could still transfer today if the pot held it.
    function budgetLeftRaw() external view override returns (uint256 valueRaw) {
        return budgetLeftUsd18() / _usdScale;
    }

    /// @inheritdoc IBountyPot
    function windowStart() external view override returns (uint32 timestamp) {
        return _windowStart;
    }

    /// @inheritdoc IBountyPot
    function usdScale() external view override returns (uint256 scale) {
        return _usdScale;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Mutative
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IBountyPot
    /// @dev Effects before interactions: the window is charged for exactly what is transferred, before the
    ///      transfer. A zero payment charges nothing and still emits, which is how a refusal reaches the keeper.
    function pay(address to, uint256 workValueUsd18, uint256 gasCostUsd18)
        external
        override
        onlyVault
        returns (uint256 paidRaw)
    {
        if (to == address(0)) revert ZeroAddress();

        bytes32 reason;
        (paidRaw, reason) = _quote(workValueUsd18, gasCostUsd18);
        uint256 paidUsd18 = paidRaw * _usdScale;

        if (paidRaw != 0) {
            _chargeWindow(paidUsd18);
            IERC20(token).safeTransfer(to, paidRaw);
        }

        emit BountyPaid(to, workValueUsd18, paidUsd18, paidRaw, reason);
    }

    /// @inheritdoc IBountyPot
    function fund(uint256 amountRaw) external override {
        if (amountRaw == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountRaw);

        emit PotFunded(msg.sender, amountRaw);
    }

    /// @inheritdoc IBountyPot
    function sweep(address to, uint256 amountRaw) external override onlyTimelock {
        if (to == address(0)) revert ZeroAddress();
        if (amountRaw == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(to, amountRaw);

        emit PotSwept(to, amountRaw);
    }

    /// @inheritdoc IBountyPot
    function setVault(address newVault) external override onlyVault {
        if (newVault == address(0)) revert ZeroAddress();

        address previousVault = vault;
        vault = newVault;

        emit VaultChanged(previousVault, newVault);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Governed parameters
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IBountyPot
    function setTipUsd18(uint256 value) external override onlyTimelock {
        if (value > TIP_USD18_MAX) revert OutOfBand("tipUsd18", value, 0, TIP_USD18_MAX);

        uint256 previousValue = tipUsd18;
        tipUsd18 = value;

        emit BountyParameterChanged("tipUsd18", previousValue, value);
    }

    /// @inheritdoc IBountyPot
    function setChipBps(uint16 value) external override onlyTimelock {
        if (value > CHIP_BPS_MAX) revert OutOfBand("chipBps", value, 0, CHIP_BPS_MAX);

        uint16 previousValue = chipBps;
        chipBps = value;

        emit BountyParameterChanged("chipBps", previousValue, value);
    }

    /// @inheritdoc IBountyPot
    function setChostUsd18(uint256 value) external override onlyTimelock {
        if (value > CHOST_USD18_MAX) revert OutOfBand("chostUsd18", value, 0, CHOST_USD18_MAX);

        uint256 previousValue = chostUsd18;
        chostUsd18 = value;

        emit BountyParameterChanged("chostUsd18", previousValue, value);
    }

    /// @inheritdoc IBountyPot
    function setGasCapMultiple(uint16 value) external override onlyTimelock {
        if (value < GAS_CAP_MULTIPLE_MIN || value > GAS_CAP_MULTIPLE_MAX) {
            revert OutOfBand("gasCapMultiple", value, GAS_CAP_MULTIPLE_MIN, GAS_CAP_MULTIPLE_MAX);
        }

        uint16 previousValue = gasCapMultiple;
        gasCapMultiple = value;

        emit BountyParameterChanged("gasCapMultiple", previousValue, value);
    }

    /// @inheritdoc IBountyPot
    function setDailyCeilingUsd18(uint256 value) external override onlyTimelock {
        if (value > DAILY_CEILING_USD18_MAX) revert OutOfBand("dailyCeilingUsd18", value, 0, DAILY_CEILING_USD18_MAX);

        uint256 previousValue = dailyCeilingUsd18;
        dailyCeilingUsd18 = value;

        emit BountyParameterChanged("dailyCeilingUsd18", previousValue, value);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The payout formula. Pure arithmetic plus one `balanceOf`, so it cannot revert for any input a keeper
    ///      or the vault can produce: the tip and chip are bounded by their bands, the gas cap saturates instead
    ///      of overflowing, and every cap is a `min`.
    ///
    ///      `reason` is `bytes32(0)` whenever anything at all is payable, and otherwise names the binding
    ///      constraint in the order the caps are applied. A payment that rounds to zero raw units with no cap
    ///      binding at all -- only reachable with a zero tip and a zero chip -- is reported as `"depleted"`, the
    ///      one enumerated reason that means "nothing was paid and nothing is coming".
    function _quote(uint256 workValueUsd18, uint256 gasCostUsd18)
        internal
        view
        returns (uint256 payableRaw, bytes32 reason)
    {
        if (workValueUsd18 < chostUsd18) return (0, "chost");

        uint256 gross = tipUsd18 + Math.mulDiv(workValueUsd18, chipBps, Constants.BPS);

        uint256 gasCap = Math.saturatingMul(gasCostUsd18, gasCapMultiple);
        if (gasCap < gross) {
            gross = gasCap;
            reason = "gasCap";
        }

        uint256 budget = budgetLeftUsd18();
        if (budget < gross) {
            gross = budget;
            reason = "dailyCeiling";
        }

        payableRaw = gross / _usdScale;

        uint256 available = balance();
        if (available < payableRaw) {
            payableRaw = available;
            reason = "depleted";
        }

        if (payableRaw != 0) return (payableRaw, bytes32(0));
        return (0, reason == bytes32(0) ? bytes32("depleted") : reason);
    }

    /// @dev Adds `amountUsd18` to the open rolling window, opening a fresh one when the previous has expired.
    ///      The cast is safe: `amountUsd18` is bounded by `budgetLeftUsd18()`, hence by `DAILY_CEILING_USD18_MAX`.
    function _chargeWindow(uint256 amountUsd18) internal {
        uint32 nowTs = SafeCast.toUint32(block.timestamp);
        uint32 start = _windowStart;

        if (start == 0 || nowTs - start >= Constants.ONE_DAY) {
            _windowStart = nowTs;
            _spentWindowUsd18 = SafeCast.toUint128(amountUsd18);
        } else {
            _spentWindowUsd18 += SafeCast.toUint128(amountUsd18);
        }
    }
}
