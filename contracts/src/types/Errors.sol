// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Errors.sol
//
// The cross-cutting custom errors: every one of these is thrown by more than one Amplestocks contract, so it lives
// at file level and is imported by name:
//
//     import {NotVault, OutOfBand, ZeroAddress} from "../types/Errors.sol";
//
// Errors that belong to exactly one contract stay in that contract's interface, where their NatSpec can be
// specific. Two rules keep this file honest:
//
//   1. An error moves here the moment a second contract needs it, and never before. A shared error with one
//      caller is just a worse-documented local error.
//   2. Selectors are ABI. The indexer decodes reverts, the dApp maps them to copy, and the fork tests assert on
//      them, so a parameter list is only ever appended to by adding a *new* error, never by editing one here.
//
// Access-control errors all carry the offending caller. That is deliberate: the guard tests assert on the
// argument, and a revert that only says "unauthorised" cannot distinguish a misconfigured keeper from an attack.

// -------------------------------------------------------------------------------------------------------------
// Access control
// -------------------------------------------------------------------------------------------------------------

/// @notice A vault-only entry point was called by someone else.
/// @param caller The rejected caller.
error NotVault(address caller);

/// @notice A timelock-only entry point was called by someone else. The timelock is the sole governance path; the
///         proposer Safe reaches these functions only through it.
/// @param caller The rejected caller.
error NotTimelock(address caller);

/// @notice A guardian-only entry point (disable-only freezes, predicate-gated migration) was called by someone
///         else.
/// @param caller The rejected caller.
error NotGuardian(address caller);

/// @notice An `AmpsBonds`-only entry point (`depositBonded`, `mintVesting`) was called by someone else.
/// @param caller The rejected caller.
error NotBonds(address caller);

/// @notice A hook-only entry point was called by someone else.
/// @param caller The rejected caller.
error NotHook(address caller);

/// @notice A registry-only entry point was called by someone else.
/// @param caller The rejected caller.
error NotRegistry(address caller);

/// @notice A creator-only entry point (reassigning the creator address) was called by someone else.
/// @param caller The rejected caller.
error NotCreator(address caller);

/// @notice The PoolManager unlock callback was entered by anything other than the PoolManager.
/// @param caller The rejected caller.
error NotPoolManager(address caller);

// -------------------------------------------------------------------------------------------------------------
// Arguments
// -------------------------------------------------------------------------------------------------------------

/// @notice A zero address was supplied where a live contract or recipient is required.
error ZeroAddress();

/// @notice A zero amount was supplied where a positive one is required. Zero-amount calls are rejected rather
///         than treated as no-ops so that a mis-encoded keeper call fails loudly.
error ZeroAmount();

/// @notice Two array arguments that must be parallel had different lengths.
error LengthMismatch();

/// @notice An index or id was outside the valid range.
/// @param index The offending value.
/// @param length The exclusive upper bound.
error IndexOutOfRange(uint256 index, uint256 length);

/// @notice A governed parameter was set outside its hard band. Every setter in the protocol throws exactly this.
/// @param parameter The parameter name, as a short string (`bytes32("sellFeeBps")`), so the revert is readable
///                  without an ABI and the governance drill can assert on which parameter failed.
/// @param value The rejected value.
/// @param min The inclusive lower bound from `Constants`.
/// @param max The inclusive upper bound from `Constants`.
error OutOfBand(bytes32 parameter, uint256 value, uint256 min, uint256 max);

/// @notice A user-supplied minimum output was not met. Thrown by `AmpsBonds.bond`. `redeemProRata` has no
///         such parameter: any minimum would need a price, and that path reads none.
/// @param received What the caller would have received.
/// @param minimum What the caller demanded.
error SlippageExceeded(uint256 received, uint256 minimum);

// -------------------------------------------------------------------------------------------------------------
// Lifecycle and state
// -------------------------------------------------------------------------------------------------------------

/// @notice A one-shot initialiser (genesis, pool registration, oracle ring seeding) was called twice.
error AlreadyInitialized();

/// @notice A function that needs initialised state was called before its initialiser.
error NotInitialized();

/// @notice The EIP-1153 transient reentrancy lock was already held. Every external vault and bonds entry point
///         takes it, including the ones that look read-only.
error Reentrancy();

/// @notice A pool id that the registry does not know was supplied.
/// @param poolId The unknown pool.
error UnknownPool(bytes32 poolId);

/// @notice A constituent id outside `[1, MAX_CONSTITUENTS]` or never registered was supplied.
/// @param constituentId The unknown id.
error UnknownConstituent(uint16 constituentId);

/// @notice A bond market id that does not exist was supplied.
/// @param marketId The unknown id.
error UnknownMarket(uint16 marketId);

// -------------------------------------------------------------------------------------------------------------
// Gate and safety
// -------------------------------------------------------------------------------------------------------------

/// @notice The oracle gate refused this path. Thrown by `_requireHealthy` in every state-changing vault and bonds
///         function except `redeemProRata` and `claim` (invariant I14).
/// @param state The `GateState` ordinal that refused, so the dApp can explain which layer tripped.
/// @param poolId The pool the refusal applies to, or `bytes32(0)` for a protocol-wide refusal.
error GateNotHealthy(uint8 state, bytes32 poolId);

/// @notice The constituent is frozen — by the guardian until `until`, or by a corporate action.
/// @param constituentId The frozen constituent.
/// @param until The freeze expiry, or 0 for a corporate-action freeze with no scheduled end.
error ConstituentFrozen(uint16 constituentId, uint32 until);

/// @notice The vault checkpoint the caller depends on is older than `CHECKPOINT_MAX_AGE`. Call the permissionless
///         `AmpsVault.checkpoint()` and retry.
/// @param age The checkpoint's age in seconds.
/// @param maxAge The bound from `Constants`.
error StaleCheckpoint(uint32 age, uint32 maxAge);

/// @notice The R1 post-condition failed: the action would have lowered `navPerShare` by more than the allowed
///         bleed (2 bp normally, 50 bp inside migration).
/// @param navBefore `navPerShareX18` before the action.
/// @param navAfter `navPerShareX18` after the action.
/// @param maxBleedBps The bound that was exceeded.
error NavBleedExceeded(uint256 navBefore, uint256 navAfter, uint16 maxBleedBps);

/// @notice The `sweepClean` invariant (I12) was violated: an ERC-20 balance was left on the vault, the hook or
///         `AmpsBonds` at the end of an external function. Asserted in-contract, not only in tests.
/// @param token The token with a non-zero balance.
/// @param balance The balance found.
error SweepDirty(address token, uint256 balance);

/// @notice A capacity limit was exceeded: per-market per-epoch, or the global daily cap.
/// @param requested The amount asked for.
/// @param available The amount still available.
error CapacityExceeded(uint256 requested, uint256 available);

// -------------------------------------------------------------------------------------------------------------
// The fee wall and the placement gauntlet (Phase 3)
// -------------------------------------------------------------------------------------------------------------
//
// `BeyondRail` is thrown by `AmpsHook`; the rest are thrown by `AmpsVault` *and* by the linked
// `VaultPlacementLib`, which is why they are shared rather than local to either. Every one of them is a deliberate,
// deterministic refusal on a caller's own input — none of them is a downstream failure. That distinction is the
// whole of `afterSwap`'s "may never revert" rule (ruling 2): an oracle, registry, gate or arithmetic failure raises
// a flag and keeps the cached value; {BeyondRail} is the single exception, and it is a decision, not a fault.

/// @notice A deviation-increasing swap at or beyond the pool's outer rail. The **only** reason the hook ever
///         reverts a swap: no gate state, no freeze and no oracle failure can (I15, as restated by
///         `docs/phase3-state-model.md` §10 ruling 2).
///
/// @dev **Checked twice, thrown identically.** `beforeSwap` refuses a swap that *begins* beyond the rail on the
///      deviation-increasing side — the rail is a start-of-swap condition, because v4 needs the fee before the
///      swap and the post-swap tick does not exist yet (§9 decision 2). `afterSwap` refuses one that *ends* beyond
///      it having increased the deviation. One swap may therefore overshoot the rail; the next one in the same
///      direction cannot, and the overshoot is bounded by I25 and by the wall's quadratic ramp.
///
/// @dev A price-improving swap is never refused, at any deviation, in any gate state. That is what lets a hub pump
///      propagate into the spokes through arbitrage instead of being walled out of existence.
/// @param poolId The pool, as `PoolId.unwrap`. `bytes32` rather than `PoolId` so the error is shared by contracts
///        that do not otherwise import v4-core's types.
/// @param devTicks `|poolTick - fairTick|` measured at the point of refusal.
/// @param outerRailTicks The rail half-width in force for that pool.
error BeyondRail(bytes32 poolId, int24 devTicks, int24 outerRailTicks);

/// @notice A placement was attempted inside the pool's 60-second cooldown.
/// @param poolId The pool, as `PoolId.unwrap`.
/// @param readyAt The timestamp the pool becomes placeable again.
error PlacementCooldown(bytes32 poolId, uint32 readyAt);

/// @notice `|slot0.tick - tickOf(P_mkt / P_i)|` exceeded `PLACEMENT_DIVERGENCE_TICKS` at the entry or the exit of
///         a placement. Checked at **both** ends, so a placement cannot be sandwiched into a manipulated tick.
/// @param poolId The pool, as `PoolId.unwrap`.
/// @param poolTick The pool's tick.
/// @param fairTick The fair tick it was measured against.
/// @param maxTicks The bound from `Constants`.
error PlacementDiverged(bytes32 poolId, int24 poolTick, int24 fairTick, int24 maxTicks);

/// @notice A proposed bucket was on the wrong side of the current tick: an ask at or below it, or a bid at or
///         above it. Invariant I9, and it is unconditional — no gate state, no session and no policy can relax it.
/// @param poolId The pool, as `PoolId.unwrap`.
/// @param above True when the offending bucket was proposed as an ask.
/// @param bucketTick The bucket bound that failed: `lowerTick` for an ask, `upperTick` for a bid.
/// @param boundTick The tick it had to clear: `alignUp(slot0.tick)` for an ask, `alignDown(slot0.tick)` for a bid.
error WrongSide(bytes32 poolId, bool above, int24 bucketTick, int24 boundTick);

/// @notice A proposed bucket was not a cell of the pool's canonical doubling grid (invariant I39).
/// @dev Thrown when `lowerTick != gridBaseTick + m * cellWidth` for any `m` in `[GRID_MIN_M, GRID_MAX_M)`, or when
///      the bucket is not exactly one cell wide. The vault re-derives the lattice itself and never trusts the
///      policy's arithmetic: an off-grid position would silently defeat merge-by-cell, the bounded record count
///      and `LadderPositionValuer`'s enumeration at once.
/// @param poolId The pool, as `PoolId.unwrap`.
/// @param lowerTick The offending lower bound.
/// @param gridBaseTick The pool's grid origin.
/// @param cellWidth One doubling in ticks, `LadderLib.doublingTicks(tickSpacing)`.
error OffGrid(bytes32 poolId, int24 lowerTick, int24 gridBaseTick, int24 cellWidth);

/// @notice A placement would open a new ladder cell beyond the vault-wide live-cell budget that bounds the gas of
///         `redeemProRata` (`Constants.MAX_LIVE_CELLS`). Thrown by `place`; the bountied paths merge and idle
///         instead of reverting.
/// @param poolId The pool the cell would have opened in.
/// @param liveCells The live cells the vault already has.
/// @param budget The budget.
error CellBudgetExceeded(bytes32 poolId, uint32 liveCells, uint32 budget);

/// @notice A placement asked to commit more than the vault actually holds of that side.
/// @param requested The amount the buckets summed to.
/// @param available The inventory available.
error InsufficientInventory(uint256 requested, uint256 available);

/// @notice A rollout move breached one of its three hard limits (invariant I32). Re-checked by the vault after the
///         policy has proposed, never taken on trust.
/// @param limit Which one, as a short string: `bytes32("dailyBudget")`, `bytes32("entryFloor")` or
///        `bytes32("belowPRef")`.
/// @param requested The amount the move asked for.
/// @param available The amount that limit allowed.
error RolloutLimitExceeded(bytes32 limit, uint256 requested, uint256 available);
