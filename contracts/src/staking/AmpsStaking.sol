// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsStaking} from "../interfaces/IAmpsStaking.sol";
import {Constants} from "../types/Constants.sol";
import {NotTimelock, NotVault, OutOfBand, ZeroAddress} from "../types/Errors.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title AmpsStaking
/// @notice xAMPS: the immutable ERC-4626 vault over AMPS that receives `stakerBps` of the AMPS-side sell fees at
///         every `AmpsVault.compound()` and releases them into the share price linearly over
///         `rewardStreamSeconds` (Decision 17).
///
/// @dev **Nothing is minted here and nothing is locked.** Every AMPS this contract ever pays out was collected as
///      a realised sell fee first. There is no emissions schedule, no lock-up, no deposit or withdrawal fee and no
///      performance fee; the only way the share price moves is a reward tranche vesting or a donation.
///
/// @dev **The stream is the whole anti-sandwich mechanism.** {totalAssets} is
///      `amps.balanceOf(this) - pendingRewards()`, and `pendingRewards()` is evaluated at `block.timestamp`, so a
///      notified tranche is invisible to the share price at the instant it lands and becomes visible only as the
///      seconds pass. A depositor who stakes in the block before `compound()` and unstakes in the block after
///      therefore captures the vested fraction of the tranche over that interval, which is zero at zero elapsed
///      time and approximately zero over any handful of blocks against a 24-hour window.
///
/// @dev **Accrual is a bookkeeping checkpoint, not a state transition.** Because `pendingRewards()` already reads
///      the clock, calling {accrue} never changes {totalAssets}, {convertToShares} or any preview: it only folds
///      the elapsed part of the stream out of the stored remainder and moves `lastAccrualAt` forward. That is why
///      it is safe (and free of ordering hazards) for {_deposit} and {_withdraw} to checkpoint before moving
///      value, and why {accrue} can be permissionless and unpaid.
///
/// @dev **Funding model: push, not pull.** The vault transfers the AMPS to this contract and *then* calls
///      {notifyReward} in the same transaction (`docs/phase2-state-model.md` §3). {notifyReward} therefore does no
///      `transferFrom`; it checks that the contract actually holds at least the whole undistributed remainder and
///      reverts with {RewardNotFunded} otherwise, so a mis-sequenced vault fails loudly instead of bricking
///      {totalAssets} with an underflow.
///
/// @dev **Invariant I36.** `totalAssets()` never decreases except through a withdrawal: the balance only rises
///      outside {_withdraw} (deposits, donations, reward transfers) and `pendingRewards()` is non-increasing in
///      time between notifications, while a notification raises it by exactly the amount the vault has already
///      transferred in. Released rewards never exceed notified rewards because the stream releases exactly the
///      remainder it was given and stops at `streamEnd`. Only the vault can notify.
///
/// @dev **First-depositor inflation.** `_decimalsOffset()` is `Constants.STAKING_DECIMALS_OFFSET` (3), matching
///      the `VIRTUAL_SHARES = 1e3` guard in the NAV denominator: the virtual shares absorb a donation attacker's
///      subsidy so that inflating the share price ahead of a victim's deposit costs more than it can ever return.
contract AmpsStaking is ERC4626, IAmpsStaking {
    // -----------------------------------------------------------------------------------------------------------
    // Errors (contract-local: no other Amplestocks contract can throw them)
    // -----------------------------------------------------------------------------------------------------------

    /// @notice {notifyReward} was called without the AMPS having been transferred in first, so honouring the
    ///         notification would push `pendingRewards` above the contract's balance and make {totalAssets}
    ///         underflow for every subsequent caller.
    /// @param required The undistributed remainder the notification implies.
    /// @param held The AMPS the contract actually holds.
    error RewardNotFunded(uint256 required, uint256 held);

    // -----------------------------------------------------------------------------------------------------------
    // Immutables
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The 48-hour timelock: the only address that may call {setRewardStreamSeconds}.
    /// @dev Immutable. Moving governance means migrating the vault, which hands the vault role on through
    ///      {setVault} and redeploys this contract; there is no governance path that can point the parameter
    ///      setter at a new owner.
    address public immutable timelock;

    // -----------------------------------------------------------------------------------------------------------
    // Storage (slot 5, 6, 7 of `docs/phase2-state-model.md` §1.3; ERC20 + ERC4626 occupy 0-4)
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsStaking
    address public override vault;

    /// @inheritdoc IAmpsStaking
    uint32 public override rewardStreamSeconds;

    /// @inheritdoc IAmpsStaking
    uint32 public override streamEnd;

    /// @inheritdoc IAmpsStaking
    uint32 public override lastAccrualAt;

    /// @dev The undistributed remainder *as of `lastAccrualAt`*. The live figure is {pendingRewards}, which walks
    ///      this value forward to `block.timestamp`; this one is only ever read through that.
    uint128 private _pendingRewards;

    /// @dev The release rate of the current stream, AMPS wei per second. Fixed at the notification that opened the
    ///      stream and never recomputed by {accrue}, so the floor-division dust stays inside the stream and is
    ///      released in one step at `streamEnd` rather than being stranded.
    uint128 private _rewardRatePerSecond;

    /// @inheritdoc IAmpsStaking
    uint256 public override totalNotified;

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

    /// @param amps_ The AMPS share token, this vault's underlying asset.
    /// @param vault_ The initial `AmpsVault`: the sole caller of {notifyReward} and {setVault}.
    /// @param timelock_ The 48-hour timelock, the sole caller of {setRewardStreamSeconds}.
    /// @dev `rewardStreamSeconds` starts at `Constants.REWARD_STREAM_SECONDS_DEFAULT` (24 h), inside its band by
    ///      construction. `lastAccrualAt` is stamped at deployment so that the first {accrue} before any
    ///      notification measures elapsed time from a real timestamp rather than from the epoch.
    constructor(IERC20 amps_, address vault_, address timelock_) ERC20("Staked Amplestocks", "xAMPS") ERC4626(amps_) {
        if (address(amps_) == address(0) || vault_ == address(0) || timelock_ == address(0)) revert ZeroAddress();

        timelock = timelock_;
        vault = vault_;
        rewardStreamSeconds = Constants.REWARD_STREAM_SECONDS_DEFAULT;
        lastAccrualAt = SafeCast.toUint32(block.timestamp);

        emit VaultChanged(address(0), vault_);
    }

    // -----------------------------------------------------------------------------------------------------------
    // ERC-4626 overrides
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc ERC4626
    /// @dev The one line invariant I36 and the anti-sandwich property both rest on: the undistributed remainder of
    ///      the stream is subtracted out, so notified-but-unvested AMPS is not part of the share price. A donation
    ///      straight to this address, by contrast, *is* counted immediately and lifts every holder's share price
    ///      rather than the donor's.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - _unreleasedAt(block.timestamp);
    }

    /// @dev Virtual-shares defence, 3 decimals, matching `Constants.VIRTUAL_SHARES == 1e3`.
    function _decimalsOffset() internal pure override returns (uint8) {
        return Constants.STAKING_DECIMALS_OFFSET;
    }

    /// @dev Checkpoints the stream before pulling assets in and minting. Harmless to ordering: {accrue} does not
    ///      move {totalAssets}, so the shares priced by `previewDeposit`/`previewMint` above are the shares minted
    ///      here.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _accrue();
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Checkpoints the stream before burning shares and paying assets out, for the same reason as
    ///      {_deposit}.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _accrue();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Reads
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsStaking
    /// @dev Evaluated at `block.timestamp`, not at `lastAccrualAt`: the stream releases continuously, and
    ///      {totalAssets} must not step when somebody happens to call {accrue}.
    function pendingRewards() public view override returns (uint256 amount) {
        return _unreleasedAt(block.timestamp);
    }

    /// @inheritdoc IAmpsStaking
    function rewardRate() external view override returns (uint256 rate) {
        return _rewardRatePerSecond;
    }

    /// @notice AMPS wei released into {totalAssets} since deployment: `totalNotified` minus what is still pending.
    /// @dev Not part of {IAmpsStaking}; the dApp pairs it with {totalNotified} for the realised-APR panel, and the
    ///      I36 tests assert `releasedRewards() <= totalNotified()` after every step.
    /// @return amount The cumulative released total.
    function releasedRewards() external view returns (uint256 amount) {
        return totalNotified - _unreleasedAt(block.timestamp);
    }

    /// @notice Seconds left in the current stream, zero when nothing is streaming.
    /// @dev Not part of {IAmpsStaking}; the dApp uses it to render the stream countdown.
    /// @return seconds_ The remaining stream length.
    function streamSecondsRemaining() external view returns (uint32 seconds_) {
        uint256 end = streamEnd;
        return block.timestamp >= end ? 0 : uint32(end - block.timestamp);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Bands (restated from `Constants` so the dApp and the governance drills read the bound, never a literal)
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsStaking
    function REWARD_STREAM_SECONDS_MIN() external pure override returns (uint32 value) {
        return Constants.REWARD_STREAM_SECONDS_MIN;
    }

    /// @inheritdoc IAmpsStaking
    function REWARD_STREAM_SECONDS_MAX() external pure override returns (uint32 value) {
        return Constants.REWARD_STREAM_SECONDS_MAX;
    }

    /// @inheritdoc IAmpsStaking
    function DECIMALS_OFFSET() external pure override returns (uint8 value) {
        return Constants.STAKING_DECIMALS_OFFSET;
    }

    /// @inheritdoc IAmpsStaking
    function STAKER_BPS_MAX() external pure override returns (uint16 value) {
        return Constants.STAKER_BPS_MAX;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Mutative
    // -----------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAmpsStaking
    /// @dev Folds the undistributed remainder of any live stream into the new tranche and re-times the whole thing
    ///      over a fresh `rewardStreamSeconds`, so the release rate can rise but never spikes, and no AMPS is ever
    ///      dropped by a re-notification. Rewards notified while `totalSupply() == 0` are not lost either: they
    ///      raise the share price for whoever stakes next (net of the virtual shares' cut).
    function notifyReward(uint256 amount) external override onlyVault {
        if (amount == 0) revert ZeroReward();

        _accrue();

        uint256 pending = uint256(_pendingRewards) + amount;
        uint256 held = IERC20(asset()).balanceOf(address(this));
        if (held < pending) revert RewardNotFunded(pending, held);

        uint32 duration = rewardStreamSeconds;
        uint32 end = SafeCast.toUint32(block.timestamp + duration);

        _pendingRewards = SafeCast.toUint128(pending);
        _rewardRatePerSecond = SafeCast.toUint128(pending / duration);
        streamEnd = end;
        totalNotified += amount;

        emit RewardNotified(amount, end);
    }

    /// @inheritdoc IAmpsStaking
    function accrue() external override {
        _accrue();
    }

    /// @inheritdoc IAmpsStaking
    function setRewardStreamSeconds(uint32 value) external override onlyTimelock {
        if (value < Constants.REWARD_STREAM_SECONDS_MIN || value > Constants.REWARD_STREAM_SECONDS_MAX) {
            revert OutOfBand(
                "rewardStreamSeconds", value, Constants.REWARD_STREAM_SECONDS_MIN, Constants.REWARD_STREAM_SECONDS_MAX
            );
        }

        uint32 previousValue = rewardStreamSeconds;
        rewardStreamSeconds = value;

        emit RewardStreamSecondsChanged(previousValue, value);
    }

    /// @inheritdoc IAmpsStaking
    function setVault(address newVault) external override onlyVault {
        if (newVault == address(0)) revert ZeroAddress();

        address previousVault = vault;
        vault = newVault;

        emit VaultChanged(previousVault, newVault);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Moves the stored remainder forward to now. A no-op within the same second, and a no-op for
    ///      {totalAssets} always: it re-expresses the same released total against a later `lastAccrualAt`.
    function _accrue() internal {
        uint32 nowTs = SafeCast.toUint32(block.timestamp);
        if (lastAccrualAt == nowTs) return;

        _pendingRewards = uint128(_unreleasedAt(nowTs));
        lastAccrualAt = nowTs;
    }

    /// @dev The undistributed remainder at `timestamp`. Piecewise linear and non-increasing: `_pendingRewards` at
    ///      `lastAccrualAt`, falling at `_rewardRatePerSecond`, and exactly zero from `streamEnd` on, which is
    ///      where the floor-division dust of the rate is released. Every caller passes `block.timestamp` and
    ///      `lastAccrualAt` is only ever stamped with a `block.timestamp`, so the subtraction cannot underflow;
    ///      the cast back to `uint128` in {_accrue} is safe because the result is bounded by `_pendingRewards`.
    function _unreleasedAt(uint256 timestamp) internal view returns (uint256) {
        uint256 pending = _pendingRewards;
        if (pending == 0 || timestamp >= streamEnd) return 0;

        uint256 released = (timestamp - lastAccrualAt) * _rewardRatePerSecond;
        return released >= pending ? 0 : pending - released;
    }
}
