// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title MockVaultForRegistry
/// @notice The slice of `AmpsVault` that `PoolRegistry` actually touches: the pointers it reads (`bonds`, `amps`,
///         `timelock`), the reference price it anchors a new pool at, the `initializePool` entry point pool
///         creation has to go through, and the Phase 3 `withdrawRetiredBids` hand-off.
/// @dev    Records every `initializePool` call in order so a test can assert the exact `sqrtPriceX96` the registry
///         computed, and can be told to revert so the registry's failure path is exercised without a real
///         PoolManager. It deliberately implements *only* what the registry calls: a wider stub would let a
///         registry bug hide behind a mock that answers too much.
contract MockVaultForRegistry {
    /// @notice One recorded `initializePool` call.
    /// @param key The pool key the registry built.
    /// @param sqrtPriceX96 The initial price the registry computed.
    /// @param poolId The id derived from `key`.
    struct InitCall {
        PoolKey key;
        uint160 sqrtPriceX96;
        PoolId poolId;
    }

    /// @notice Every `initializePool` call, in order.
    InitCall[] internal _initCalls;

    /// @notice `constituentId` arguments passed to {withdrawRetiredBids}, in order.
    uint16[] public retiredBidWithdrawals;

    /// @notice The `AmpsBonds` pointer the registry reads.
    address public bonds;

    /// @notice The AMPS pointer, for parity with the real vault.
    address public amps;

    /// @notice The timelock pointer, for parity with the real vault.
    address public timelock;

    /// @notice `P_ref` in 18-decimal USD. Zero before genesis, which the registry reads as the $1.00 launch price.
    uint256 public pRefX18;

    /// @notice When true, {initializePool} reverts with {VaultRefused}.
    bool public initializeReverts;

    /// @notice A `PoolId` returned by {initializePool} instead of the real one, to test the registry's own
    ///         cross-check. Zero means "answer honestly".
    PoolId public forcedPoolId;

    /// @notice Counter-asset amount {withdrawRetiredBids} reports moved.
    uint256 public retiredBidsMoved;

    /// @dev The mock's stand-in for any vault-side failure.
    error VaultRefused();

    constructor(address bonds_, address amps_, address timelock_) {
        bonds = bonds_;
        amps = amps_;
        timelock = timelock_;
    }

    /* ------------------------------------------ registry surface ------------------------------------------ */

    /// @notice Records the call and returns the id of `key`.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external returns (PoolId poolId) {
        if (initializeReverts) revert VaultRefused();
        poolId = PoolId.wrap(keccak256(abi.encode(key)));
        _initCalls.push(InitCall({key: key, sqrtPriceX96: sqrtPriceX96, poolId: poolId}));
        if (PoolId.unwrap(forcedPoolId) != bytes32(0)) poolId = forcedPoolId;
    }

    /// @notice Records the call and reports {retiredBidsMoved}.
    function withdrawRetiredBids(uint16 constituentId) external returns (uint256 moved) {
        retiredBidWithdrawals.push(constituentId);
        moved = retiredBidsMoved;
    }

    /* --------------------------------------------- controls --------------------------------------------- */

    function setPRefX18(uint256 value) external {
        pRefX18 = value;
    }

    function setBonds(address value) external {
        bonds = value;
    }

    function setInitializeReverts(bool value) external {
        initializeReverts = value;
    }

    function setForcedPoolId(PoolId value) external {
        forcedPoolId = value;
    }

    function setRetiredBidsMoved(uint256 value) external {
        retiredBidsMoved = value;
    }

    /* ---------------------------------------------- reads ----------------------------------------------- */

    /// @notice How many pools have been initialised through this mock.
    function initCallCount() external view returns (uint256 count) {
        count = _initCalls.length;
    }

    /// @notice One recorded call.
    function initCall(uint256 index) external view returns (InitCall memory call) {
        call = _initCalls[index];
    }

    /// @notice The last recorded call.
    function lastInitCall() external view returns (InitCall memory call) {
        call = _initCalls[_initCalls.length - 1];
    }

    /// @notice How many times the registry asked for a retired spoke's bids.
    function retiredBidWithdrawalCount() external view returns (uint256 count) {
        count = retiredBidWithdrawals.length;
    }
}
