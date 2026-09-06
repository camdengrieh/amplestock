// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IBountyPot
/// @notice The segregated keeper bounty pot. Immutable bytecode, timelock-governed parameters, funded in USDG.
///
/// @dev **Segregation is the point.** The pot's balance is deliberately **excluded from the NAV numerator `A`**
///      (invariant I21): it is an operating budget, not backing, and counting it would let a bounty payment look
///      like a NAV loss. The vault never reads the pot's balance when computing NAV and never pulls from it for
///      anything but a bounty.
///
/// @dev **A depleted pot degrades, it never reverts.** {pay} returns the amount actually paid, which is zero when
///      the pot is empty or a cap binds. The keeper jobs it funds (`compound`, rollout, bonded-stock deployment)
///      are permissionless and remain callable unpaid, so an empty pot slows the protocol down and stops nothing.
///      `checkpoint()` and `touch()` are unpaid by design and never consult the pot at all.
///
/// @dev **Four independent caps**, each governed and each checked on every payment:
///        - `tipUsd18` — the flat tip per successful job ($0.05 at launch);
///        - `chipBps` — a share of the work value the job realised (2% at launch);
///        - `gasCapMultiple` — the payment may never exceed this multiple of the job's gas cost at a capped
///          basefee, so a gas spike cannot drain the pot;
///        - `dailyCeilingUsd18` — a rolling 24-hour ceiling across all jobs and all callers.
///      `chostUsd18` is not a cap but a floor on the *work*: a job whose realised value is below it pays nothing,
///      which is what makes a spam campaign of dust-sized `compound()` calls unprofitable.
interface IBountyPot {
    /// @notice Emitted on every payment, including zero-value ones, so the keeper dashboards can see refusals.
    /// @param to The recipient.
    /// @param workValueUsd18 The job's realised value, as reported by the vault.
    /// @param paidUsd18 The amount actually paid, in USDG raw units converted to 18-decimal USD for the event.
    /// @param paidRaw The amount actually transferred, in USDG raw units.
    /// @param reason A short identifier when `paidRaw == 0`: `bytes32("depleted")`, `bytes32("chost")`,
    ///        `bytes32("dailyCeiling")` or `bytes32("gasCap")`.
    event BountyPaid(address indexed to, uint256 workValueUsd18, uint256 paidUsd18, uint256 paidRaw, bytes32 reason);

    /// @notice Emitted when anyone funds the pot.
    /// @param from The funder.
    /// @param amountRaw The USDG amount added.
    event PotFunded(address indexed from, uint256 amountRaw);

    /// @notice Emitted when the timelock sweeps the pot.
    /// @param to The recipient.
    /// @param amountRaw The USDG amount removed.
    event PotSwept(address indexed to, uint256 amountRaw);

    /// @notice Emitted on every governed parameter change.
    /// @param parameter The parameter name as a short string.
    /// @param previousValue The value before.
    /// @param newValue The value after.
    event BountyParameterChanged(bytes32 indexed parameter, uint256 previousValue, uint256 newValue);

    /// @notice Emitted at construction (`previousVault == address(0)`) and whenever the vault role is handed on
    ///         during a migration.
    /// @param previousVault The old vault.
    /// @param newVault The new vault.
    event VaultChanged(address indexed previousVault, address indexed newVault);

    /// @notice The pot token reports more than 18 decimals, so 18-decimal USD amounts could not be scaled down to
    ///         its raw units without a loss the accounting does not model. Thrown at construction only.
    /// @param decimals The token's decimals.
    error UnsupportedDecimals(uint8 decimals);

    // -------------------------------------------------------------------------------------------------------------
    // Reads (permissionless)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The pot's token: USDG on chain 4663, 6 decimals.
    /// @return tokenAddress The token address.
    function token() external view returns (address tokenAddress);

    /// @notice The 48-hour timelock: the only address that may {sweep} or move a parameter.
    /// @dev Immutable in the implementation, for the same reason as in `AmpsStaking`: there is no governance path
    ///      that can re-point the parameter setters at a new owner, only a migration.
    /// @return timelockAddress The timelock address.
    function timelock() external view returns (address timelockAddress);

    /// @notice The pot's current balance, in the token's raw units.
    /// @return balanceRaw The balance.
    function balance() external view returns (uint256 balanceRaw);

    /// @notice The vault, the only address that may call {pay}.
    /// @return vaultAddress The vault address.
    function vault() external view returns (address vaultAddress);

    /// @notice The flat tip per successful job, 18-decimal USD.
    /// @return value The parameter. $0.05 at launch.
    function tipUsd18() external view returns (uint256 value);

    /// @notice The share of realised work value added to the tip, in bps.
    /// @return value The parameter. 200 at launch.
    function chipBps() external view returns (uint16 value);

    /// @notice The dust guard: jobs realising less value than this pay nothing.
    /// @return value The parameter. $1 at launch.
    function chostUsd18() external view returns (uint256 value);

    /// @notice The multiple of the job's gas cost a payment may never exceed.
    /// @return value The parameter. 3 at launch.
    function gasCapMultiple() external view returns (uint16 value);

    /// @notice The rolling 24-hour ceiling on total payments, 18-decimal USD.
    /// @return value The parameter.
    function dailyCeilingUsd18() external view returns (uint256 value);

    /// @notice Payments made in the trailing 24 hours, 18-decimal USD.
    /// @return value The rolling total.
    function spentLast24h() external view returns (uint256 value);

    /// @notice What the daily ceiling still allows to be paid inside the open window, 18-decimal USD.
    /// @dev `dailyCeilingUsd18 - spentLast24h()`, floored at zero. The keeper reads it to decide whether a job is
    ///      worth submitting at all, and the dashboards render it as "budget left today".
    /// @return value The remaining budget.
    function budgetLeftUsd18() external view returns (uint256 value);

    /// @notice The same figure as {budgetLeftUsd18}, in the token's raw units and floored to a whole unit.
    /// @return valueRaw The remaining budget in raw token units.
    function budgetLeftRaw() external view returns (uint256 valueRaw);

    /// @notice When the open rolling window started, or zero before the first payment.
    /// @dev The window is a rolling *reset*, not a trailing sum: it opens with the first payment that lands 24 h or
    ///      more after the previous one opened. The indexer uses this to align its own accounting with the chain.
    /// @return timestamp The window start.
    function windowStart() external view returns (uint32 timestamp);

    /// @notice The divisor from 18-decimal USD to the token's raw units, `10 ** (18 - token.decimals())`.
    /// @dev Exposed so a keeper can reproduce {quote} off-chain exactly.
    /// @return scale The divisor.
    function usdScale() external view returns (uint256 scale);

    /// @notice What {pay} would pay for a hypothetical job, without paying it.
    /// @dev Never reverts. The keeper calls this before submitting so it can skip an unprofitable job.
    /// @param workValueUsd18 The job's realised value.
    /// @param gasCostUsd18 The job's gas cost at the capped basefee.
    /// @return payableRaw What would be transferred, in the token's raw units.
    /// @return reason `bytes32(0)` when the payment would succeed, otherwise the refusal reason.
    function quote(uint256 workValueUsd18, uint256 gasCostUsd18)
        external
        view
        returns (uint256 payableRaw, bytes32 reason);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Pays a keeper bounty. **Only vault.**
    /// @dev Never reverts for a depleted pot or a binding cap: it pays what it can, emits {BountyPaid} with a
    ///      reason, and returns zero. The vault must not treat a zero return as a failure.
    /// @param to The keeper.
    /// @param workValueUsd18 The job's realised value, computed by the vault.
    /// @param gasCostUsd18 The job's gas cost at the capped basefee, computed by the vault.
    /// @return paidRaw The amount transferred, in the token's raw units.
    function pay(address to, uint256 workValueUsd18, uint256 gasCostUsd18) external returns (uint256 paidRaw);

    /// @notice Adds funds to the pot. **Permissionless** — anyone may top it up, and doing so is the cheapest way
    ///         for a large holder to keep the keeper jobs paid.
    /// @param amountRaw The USDG amount to pull from `msg.sender`.
    function fund(uint256 amountRaw) external;

    /// @notice Removes funds from the pot. **Only timelock (48 h).** The pot is operating budget, not backing, so
    ///         sweeping it does not touch NAV.
    /// @param to The recipient.
    /// @param amountRaw The amount to remove.
    function sweep(address to, uint256 amountRaw) external;

    /// @notice Sets the flat tip. **Only timelock (48 h).**
    /// @param value The new tip, 18-decimal USD.
    function setTipUsd18(uint256 value) external;

    /// @notice Sets the work-value share. **Only timelock (48 h).**
    /// @param value The new share in bps.
    function setChipBps(uint16 value) external;

    /// @notice Sets the dust guard. **Only timelock (48 h).**
    /// @param value The new guard, 18-decimal USD.
    function setChostUsd18(uint256 value) external;

    /// @notice Sets the gas-cost multiple. **Only timelock (48 h).**
    /// @param value The new multiple.
    function setGasCapMultiple(uint16 value) external;

    /// @notice Sets the rolling daily ceiling. **Only timelock (48 h).**
    /// @param value The new ceiling, 18-decimal USD.
    function setDailyCeilingUsd18(uint256 value) external;

    /// @notice Hands the vault role on. **Only vault**, so a migration moves it atomically in the same transaction
    ///         that moves the liquidity, exactly as `Amps.setVault`, `AmpsBonds.setVault` and
    ///         `AmpsStaking.setVault` do.
    /// @param newVault The new vault.
    function setVault(address newVault) external;
}
