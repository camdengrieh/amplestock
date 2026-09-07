// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IRolloutPolicy
/// @notice The schedule that migrates unfilled ask inventory out of the two entry pools and into the 30 spokes.
///         Pure, stateless, pointer-upgradeable behind the 7-day timelock, and propose-only.
///
/// @dev **Phase 3 consumes this; Phase 2 only declares it.** At genesis nearly all inventory sits in `AMPS/WETH`
///      and `AMPS/USDG` (3,325 of the 4,750 POL AMPS) because that is where the seed liquidity is. Rollout is how
///      the ladder reaches the spokes as bonds and buys bring stock-side depth. Each move is an ordinary
///      placement: withdraw an *unfilled* ask bucket (one strictly above the current price, so no counter-asset is
///      touched) from an entry pool and re-place it in the target spoke's ladder.
///
/// @dev **Three hard limits, all re-checked by the vault** (invariant I32):
///        1. at most `rolloutBpsPerDay` of the POL tranche may move per rolling day (200 bp at launch, hard cap
///           1,000);
///        2. the entry pools may never be taken below `entryFloorBps` of the POL tranche (30% at launch);
///        3. a rolled-out ask is never placed below `P_ref`, so rollout can never undersell the protocol's own
///           backing.
///      A policy that proposes a move violating any of these is refused by the vault, not obeyed.
///
/// @dev **Retirement zeroes a weight, it does not withdraw.** `retireConstituent` sets `rolloutWeightBps = 0` and
///      returns that spoke's unfilled asks to the entry pools; the bids stay as an exit market. Rollout therefore
///      has no special case for retirement — a zero weight simply never wins the allocation.
interface IRolloutPolicy {
    /// @notice The state a rollout decision is made from.
    /// @param polTrancheAmps The POL tranche the daily rate is measured against, in AMPS wei.
    /// @param entryInventoryAmps Unfilled ask AMPS currently held by the two entry pools, in wei.
    /// @param movedLast24hAmps AMPS moved by rollout in the trailing 24 hours, in wei.
    /// @param rolloutBpsPerDay The governed daily rate, in bps of `polTrancheAmps`.
    /// @param entryFloorBps The governed entry-pool floor, in bps of `polTrancheAmps`.
    /// @param targetWeightBps The destination constituent's index target weight.
    /// @param currentWeightBps The destination constituent's realised weight in the POL right now.
    /// @param rolloutWeightBps The destination constituent's share of the daily budget. Zero when retired or frozen.
    /// @param spokeHasDepth True when the spoke already has counter-asset depth from bonds or buys. A spoke with no
    ///        stock at all can still receive asks — that is how it gets a market — but a spoke with depth is
    ///        preferred by the schedule.
    struct RolloutRequest {
        uint256 polTrancheAmps;
        uint256 entryInventoryAmps;
        uint256 movedLast24hAmps;
        uint16 rolloutBpsPerDay;
        uint16 entryFloorBps;
        uint16 targetWeightBps;
        uint16 currentWeightBps;
        uint16 rolloutWeightBps;
        bool spokeHasDepth;
    }

    /// @notice How much may move, and why.
    /// @param amountAmps AMPS wei to move. Zero is a valid answer and means "nothing is due"; the vault treats it
    ///        as a no-op rather than a revert, so an unpaid keeper call costs the caller gas and nothing else.
    /// @param dailyBudgetRemaining AMPS wei still available under `rolloutBpsPerDay` after this move.
    /// @param floorBinding True when `entryFloorBps` is what limited the move.
    struct RolloutDecision {
        uint256 amountAmps;
        uint256 dailyBudgetRemaining;
        bool floorBinding;
    }

    /// @notice Proposes how much inventory to move from the entry pools into one spoke.
    /// @param request The rollout state.
    /// @return decision The proposed move.
    function propose(RolloutRequest calldata request) external pure returns (RolloutDecision memory decision);

    /// @notice Hard ceiling of `rolloutBpsPerDay`. 1,000 bp of the POL tranche per day.
    /// @return value The bound.
    function ROLLOUT_BPS_PER_DAY_MAX() external view returns (uint16 value);

    /// @notice Hard ceiling of `entryFloorBps`. 8,000 bp: above this rollout could never do anything.
    /// @return value The bound.
    function ENTRY_FLOOR_BPS_MAX() external view returns (uint16 value);

    /// @notice The factor applied to a spoke with no counter-asset depth yet. 0.5e18.
    /// @dev A depthless spoke can still receive asks — that is how it gets a market at all — but the schedule
    ///      prefers a spoke that bonds or buys have already given stock-side depth, because asks placed against no
    ///      bid side earn no fees at all until someone brings stock (§9 decision 13's stranded-fee case).
    /// @return value The discount, 1e18 fixed point.
    function DEPTHLESS_DISCOUNT_X18() external view returns (uint256 value);

    /// @notice Identifier of this schedule, for governance diffs and the dApp.
    /// @return id A short identifier, e.g. `bytes32("weighted-deficit-v1")`.
    function version() external pure returns (bytes32 id);
}
