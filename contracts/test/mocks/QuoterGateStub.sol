// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GateSnapshot} from "../../src/types/Types.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title QuoterGateStub
/// @notice A one-function gate: `snapshotByPool`, with every field of the snapshot settable.
///
/// @dev `MockOracleGate` models the gate the way the *bond* and *placement* paths use it, keying the freeze and
///      the staleness flags by constituent; `AmpsQuoter` reads `snapshotByPool` and renders four fields that mock
///      answers per constituent and not per pool. Rather than change a mock four other suites depend on, this
///      stub sets the pool-keyed snapshot directly, which is what the production `OracleGate.snapshotByPool`
///      returns.
contract QuoterGateStub {
    mapping(PoolId poolId => GateSnapshot snapshot) internal _snapshots;

    /// @notice Sets the snapshot one pool answers with.
    /// @param poolId The pool.
    /// @param snapshot The snapshot.
    function setSnapshot(PoolId poolId, GateSnapshot calldata snapshot) external {
        _snapshots[poolId] = snapshot;
    }

    /// @notice The gate's per-pool snapshot.
    /// @param poolId The pool.
    /// @return snapshot The snapshot.
    function snapshotByPool(PoolId poolId) external view returns (GateSnapshot memory snapshot) {
        return _snapshots[poolId];
    }
}
