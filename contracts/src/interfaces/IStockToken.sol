// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IStockToken
/// @notice The Robinhood Stock Token surface Amplestocks depends on: a plain ERC-20 plus an ERC-8056-style display
///         multiplier, an issuer freeze flag and a beacon-level denylist.
///
/// @dev **Nothing in this interface may be called without a bounded `staticcall`.** Every Stock Token is a beacon
///      proxy behind a codeless admin key with no timelock: the implementation can change under us at any block,
///      and a hostile or merely upgraded implementation could revert, return garbage or burn unbounded gas. The
///      hook and the vault therefore probe these views with `Constants.STOCK_TOKEN_PROBE_GAS` and treat a failed
///      probe as *unknown*, never as a revert of the caller's transaction. `beforeSwap` in particular must never
///      revert a swap because an issuer view misbehaved (I15).
///
/// @dev **The multiplier is display-only.** `uiMultiplier()` scales how a balance is *shown*; raw ERC-20 balances
///      never change when it moves, so a split or a dividend reinvestment is value-neutral on-chain. Two rules
///      follow and are load-bearing:
///        1. A Chainlink answer is **never** multiplied by `uiMultiplier()`. The feed already quotes the same units
///           the token trades in. This is the single most likely way to silently misprice the whole index.
///        2. A multiplier change is never allowed to move a tick. Scheduled changes (`newUIMultiplier` /
///           `effectiveAt`) and `oraclePaused()` freeze management actions for that constituent; unannounced small
///           steps (a dividend reinvestment, +0.1% to +1%) are detected in `beforeSwap` by comparing against the
///           cached value and are converted into an asymmetric capture fee rather than a position move.
///
/// @dev **The denylist is the real custody risk.** `blockAccounts(address[])` (selector `0x6abf7081`) is an
///      issuer-side power with no delay. Amplestocks' `sweepClean` invariant (I12) means the only address that
///      usefully holds Stock Tokens is the PoolManager; `isBlocked` is nevertheless read as the trigger predicate
///      for `AmpsVault.emergencyMigrate`.
interface IStockToken is IERC20Metadata {
    /// @notice The current display multiplier, 1e18 == 1.0.
    /// @dev Read as a change detector only. `CRWD` on chain 4663 carries 4.0e18 and is the corporate-action test
    ///      fixture; every launch constituent seen so far carries 1e18.
    /// @return multiplier The multiplier in 1e18 fixed point.
    function uiMultiplier() external view returns (uint256 multiplier);

    /// @notice The scheduled next display multiplier, or 0 when nothing is scheduled.
    /// @return multiplier The pending multiplier in 1e18 fixed point.
    function newUIMultiplier() external view returns (uint256 multiplier);

    /// @notice The timestamp at which {newUIMultiplier} becomes {uiMultiplier}, or 0 when nothing is scheduled.
    /// @dev A pending `effectiveAt` within `Constants.CORPORATE_ACTION_WINDOW` of now puts the constituent into
    ///      `GateState.SCHEDULED_FREEZE`: no placements, no compounding, no bonds, and never a tick shift. The
    ///      indexer additionally polls this by state diff, because the flip can happen unannounced.
    /// @return timestamp The effective timestamp of the scheduled change.
    function effectiveAt() external view returns (uint256 timestamp);

    /// @notice The issuer's freeze flag: true while the issuer considers the token's pricing unreliable.
    /// @dev Treated exactly like a pending corporate action: `SCHEDULED_FREEZE` for that constituent only.
    /// @return paused Whether the issuer has paused.
    function oraclePaused() external view returns (bool paused);

    /// @notice Whether `account` is on the beacon-level denylist.
    /// @dev `isBlocked(vault) == true` for any constituent — or a bounded 1-wei self-transfer probe failing for at
    ///      least two constituents — is the predicate that unlocks the guardian's no-delay
    ///      `AmpsVault.emergencyMigrate`. The predicate is checked on-chain, not asserted off-chain.
    /// @param account The address to test.
    /// @return blocked Whether transfers touching `account` revert.
    function isBlocked(address account) external view returns (bool blocked);

    /// @notice Whether the token is globally paused by the issuer.
    /// @dev Distinct from {oraclePaused}: this stops transfers outright, which shows up to Amplestocks as every
    ///      movement of that constituent reverting.
    /// @return isPaused Whether transfers are paused.
    function paused() external view returns (bool isPaused);
}
