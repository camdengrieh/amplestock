// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GateSnapshot, GateState, Session} from "../../src/types/Types.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title HookFaultyGate
/// @notice An `IOracleGate` stand-in that fails the four ways a real dependency can, so `AmpsHook.afterSwap` can
///         be shown never to revert for any of them (I15).
///
/// @dev The hook calls exactly two things on the gate — `snapshotByPool(PoolId)` and `closedHours()` — so those
///      are all this implements, by selector. Deliberately not `is IOracleGate`: the point is to answer *badly*.
///
/// @dev The four modes, in the order they defeat successively more defensive callers:
///        - `REVERTS`   a plain revert. Caught by `try`/`catch` and by a low-level call alike.
///        - `OUT_OF_GAS` burns every wei of gas it is given. Caught only if the call was given a bounded budget.
///        - `GARBAGE`   returns one byte. **Not** catchable by `try`/`catch`: the call succeeded, so the failure
///                      happens in ABI decoding, in the caller's own frame. Only a manual decode survives it.
///        - `ROGUE`     returns a well-formed snapshot full of impossible values: an enum past its maximum, a
///                      dynamic cap of `type(uint16).max`, a fair tick outside `[MIN_TICK, MAX_TICK]`.
contract HookFaultyGate {
    enum Mode {
        OK,
        REVERTS,
        OUT_OF_GAS,
        GARBAGE,
        ROGUE
    }

    /// @notice The fault in force.
    Mode public mode;

    /// @notice What the `OK` mode answers.
    GateSnapshot internal _snapshot;

    constructor() {
        _snapshot.state = GateState.GREEN;
        _snapshot.session = Session.REGULAR;
        _snapshot.dynCapBps = 300;
    }

    /// @notice Selects the fault.
    /// @param mode_ The mode.
    function setMode(Mode mode_) external {
        mode = mode_;
    }

    /// @notice Sets what the `OK` mode answers.
    /// @param snapshot The snapshot.
    function setSnapshot(GateSnapshot calldata snapshot) external {
        _snapshot = snapshot;
    }

    /// @notice `IOracleGate.snapshotByPool`, answered according to {mode}.
    /// @param poolId Ignored.
    /// @return gate The snapshot.
    function snapshotByPool(PoolId poolId) external view returns (GateSnapshot memory gate) {
        poolId;
        _fault();
        if (mode == Mode.ROGUE) {
            // Thirteen words of nonsense with the right length: enums past their maxima, an impossible cap, a
            // tick far outside the usable range.
            assembly ("memory-safe") {
                let p := mload(0x40)
                mstore(p, 200) // state
                mstore(add(p, 0x20), 77) // session
                mstore(add(p, 0x40), 1)
                mstore(add(p, 0x60), 1) // corporateFreeze
                mstore(add(p, 0x80), 1)
                mstore(add(p, 0xa0), 1)
                mstore(add(p, 0xc0), 65535)
                mstore(add(p, 0xe0), 65535) // dynCapBps
                mstore(add(p, 0x100), 8388607)
                mstore(add(p, 0x120), 8388607) // fairTick, past MAX_TICK
                mstore(add(p, 0x140), timestamp())
                mstore(add(p, 0x160), timestamp())
                mstore(add(p, 0x180), not(0))
                return(p, 0x1a0)
            }
        }
        gate = _snapshot;
        gate.observedAt = uint32(block.timestamp);
    }

    /// @notice `IOracleGate.closedHours`, answered according to {mode}.
    /// @return hoursClosed Zero, when it answers at all.
    function closedHours() external view returns (uint16 hoursClosed) {
        _fault();
        return 0;
    }

    function _fault() private view {
        if (mode == Mode.REVERTS) revert("HookFaultyGate: reverting");
        if (mode == Mode.OUT_OF_GAS) {
            uint256 acc;
            for (uint256 i = 0; i < 10_000_000; ++i) {
                acc = uint256(keccak256(abi.encode(acc, i)));
            }
        }
        if (mode == Mode.GARBAGE) {
            assembly ("memory-safe") {
                return(0, 1)
            }
        }
    }
}
