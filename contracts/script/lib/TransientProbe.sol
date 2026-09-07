// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @title TransientProbe
/// @notice A contract whose *constructor* is the EIP-1153 acceptance test: it writes a transient slot, reads it
///         back and reverts on a mismatch, then returns one byte of runtime code.
/// @dev    Never deployed. `00_Preflight` sends its creation code to the node as an `eth_call` with no `to`
///         address, which runs the constructor inside the node's own EVM and returns the runtime code it would
///         have deployed — the plan's "TSTORE/TLOAD accepted (a one-line contract deployed on 46630)" check,
///         without a transaction and without mutating anything. A chain that rejects `TSTORE` fails the call.
contract TransientProbe {
    constructor() {
        assembly ("memory-safe") {
            tstore(0x1153, 0x1153)
            if iszero(eq(tload(0x1153), 0x1153)) { revert(0, 0) }
            mstore(0, 0)
            return(0, 1)
        }
    }
}

/// @title TransientProbeRunner
/// @notice Sends {TransientProbe}'s creation code to the node as an `eth_call` with no `to` address.
///
/// @dev **Why this is a contract and not a method on `00_Preflight`.** The call has to be wrapped in `try` — a
///      node that does not support a `to`-less `eth_call`, or a run with no `--rpc-url`, must produce a `SKIP`
///      rather than abort the pre-flight — and `try this.f()` inside a script trips Foundry's
///      "Usage of `address(this)` detected in script contract" guard. So the `try` target is a separate
///      contract, created outside every broadcast window and never broadcast: it is a `view` helper in the sense
///      that matters, since the only thing it does is one `eth_call`.
contract TransientProbeRunner {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Runs {TransientProbe}'s constructor inside the node's EVM.
    /// @dev Reverts when the RPC refuses the call, which the caller turns into a `SKIP`. A chain that rejects
    ///      `TSTORE` makes the constructor revert, so the call fails there too — the difference is visible in the
    ///      error, and either way EIP-1153 is not proven, which is the honest verdict.
    /// @return runtimeCode The one byte of runtime code the constructor returns on success.
    function probe() external returns (bytes memory runtimeCode) {
        string memory params =
            string.concat("[{\"data\":\"", vm.toString(type(TransientProbe).creationCode), "\"},\"latest\"]");
        runtimeCode = vm.rpc("eth_call", params);
    }
}
