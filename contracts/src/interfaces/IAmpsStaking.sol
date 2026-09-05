// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IAmpsStaking
/// @notice xAMPS: an immutable ERC-4626 vault over AMPS that receives `stakerBps` of the AMPS-side fees at every
///         `compound()` and releases them linearly over `rewardStreamSeconds`.
///
/// @dev **Nothing is minted here, ever.** Rewards are AMPS the protocol has already collected as sell fees. The
///      share price rises as the stream releases; no new supply is created, there is no lock, and there is no
///      emissions schedule. This is the deliberate rejection of the Olympus reflexive-staking failure mode: xAMPS
///      pays only realised fees (Decision 17).
///
/// @dev **The stream is the anti-sandwich mechanism.** A depositor who stakes immediately before `compound()` and
///      unstakes immediately after captures only the fraction of the notified reward that has actually vested in
///      the intervening seconds, which is approximately nothing over a 24-hour stream. `totalAssets()` therefore
///      counts *released* rewards only, never the undistributed remainder — that is what makes the sandwich
///      unprofitable rather than merely unattractive.
///
/// @dev **First-depositor inflation.** The vault uses OZ's virtual-shares defence with
///      `_decimalsOffset() == Constants.STAKING_DECIMALS_OFFSET` (3), matching the `VIRTUAL_SHARES = 1e3` used by
///      the NAV denominator. An attacker donating AMPS directly to the contract inflates nothing they can extract.
///
/// @dev Invariant I36: `totalAssets()` never decreases except by withdrawals; released rewards never exceed
///      notified rewards; only the vault may notify; `stakerBps <= 5000`.
interface IAmpsStaking is IERC4626 {
    /// @notice Emitted when the vault notifies a new reward tranche at `compound()`.
    /// @param amount The AMPS wei added to the stream.
    /// @param streamEnd When the stream (including this tranche) finishes releasing.
    event RewardNotified(uint256 amount, uint32 streamEnd);

    /// @notice Emitted when `rewardStreamSeconds` changes. 48-hour timelock.
    /// @param previousValue The value before.
    /// @param newValue The value after.
    event RewardStreamSecondsChanged(uint32 previousValue, uint32 newValue);

    /// @notice Emitted when the vault role is handed on during a migration.
    /// @param previousVault The old vault.
    /// @param newVault The new vault.
    event VaultChanged(address indexed previousVault, address indexed newVault);

    /// @notice The reward notified was zero. Notifying nothing would silently restart the stream clock.
    error ZeroReward();

    // -------------------------------------------------------------------------------------------------------------
    // Reads (permissionless)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The vault: the only address that may call {notifyReward}.
    /// @return vaultAddress The vault address.
    function vault() external view returns (address vaultAddress);

    /// @notice AMPS wei notified but not yet released. Deliberately **not** part of {IERC4626-totalAssets}.
    /// @return amount The undistributed remainder.
    function pendingRewards() external view returns (uint256 amount);

    /// @notice When the current stream finishes releasing.
    /// @return timestamp The stream end.
    function streamEnd() external view returns (uint32 timestamp);

    /// @notice When rewards were last released into `totalAssets()`.
    /// @return timestamp The last accrual timestamp.
    function lastAccrualAt() external view returns (uint32 timestamp);

    /// @notice The rate the current stream releases at, in AMPS wei per second.
    /// @return rate The release rate.
    function rewardRate() external view returns (uint256 rate);

    /// @notice Total AMPS ever notified to this contract, for the dApp's realised-APR calculation.
    /// @return amount The cumulative total.
    function totalNotified() external view returns (uint256 amount);

    // -------------------------------------------------------------------------------------------------------------
    // Governed parameters and hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The linear release window for notified rewards. 24 h at launch.
    /// @return value The parameter.
    function rewardStreamSeconds() external view returns (uint32 value);

    /// @notice Hard floor of `rewardStreamSeconds`. 1 h.
    /// @return value The bound.
    function REWARD_STREAM_SECONDS_MIN() external view returns (uint32 value);

    /// @notice Hard ceiling of `rewardStreamSeconds`. 7 d.
    /// @return value The bound.
    function REWARD_STREAM_SECONDS_MAX() external view returns (uint32 value);

    /// @notice The ERC-4626 decimals offset, i.e. the virtual-shares defence. 3.
    /// @return value The offset.
    function DECIMALS_OFFSET() external view returns (uint8 value);

    /// @notice Hard ceiling of the vault-side `stakerBps`, restated here so the dApp can read the bound from the
    ///         staking contract without knowing the vault. 5,000.
    /// @return value The bound.
    function STAKER_BPS_MAX() external view returns (uint16 value);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Adds `amount` AMPS to the reward stream. **Only vault.**
    /// @dev The vault transfers the AMPS in the same transaction. A tranche notified while a previous one is still
    ///      releasing extends the stream: the remainder is folded into the new tranche and the whole amount
    ///      releases over a fresh `rewardStreamSeconds`, so the rate never spikes.
    /// @param amount The AMPS wei added.
    function notifyReward(uint256 amount) external;

    /// @notice Releases whatever the stream owes into `totalAssets()`. **Permissionless and unpaid.**
    /// @dev Every deposit, mint, withdraw and redeem calls this first, so it exists only so that the dApp and the
    ///      indexer can force accrual without moving a share.
    function accrue() external;

    /// @notice Sets the release window. **Only timelock (48 h).** Applies to tranches notified after the change;
    ///         a stream already running is not re-timed.
    /// @param value The new window, inside `[REWARD_STREAM_SECONDS_MIN, REWARD_STREAM_SECONDS_MAX]`.
    function setRewardStreamSeconds(uint32 value) external;

    /// @notice Hands the vault role on. **Only vault**, so a migration moves it atomically in the same transaction
    ///         that moves the liquidity.
    /// @param newVault The new vault.
    function setVault(address newVault) external;
}
