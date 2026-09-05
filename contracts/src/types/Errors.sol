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
