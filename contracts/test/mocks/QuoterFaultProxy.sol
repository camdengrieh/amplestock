// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title QuoterFaultProxy
/// @notice A transparent stand-in for any dependency `AmpsQuoter` reads, with a switch that turns it into every
///         way a dependency can fail.
///
/// @dev `IAmpsQuoter`'s specification is a negative — "it never reverts" — and a negative can only be tested by
///      trying to break it. This proxy forwards every call to a real mock while `mode == PASS`, and otherwise
///      reverts, answers empty, answers short, answers with a full-length word soup, burns its whole gas
///      allowance, or floods the caller with returndata. All of it under `staticcall`, because every read the
///      quoter makes is one.
///
/// @dev The word-soup mode is the interesting one. `0xff...ff` in every field means an enum ordinal far out of
///      range, a `bool` that is neither 0 nor 1 and dirty high bits on every narrow integer — exactly the inputs
///      that make Solidity's ABI decoder throw a `Panic` that `try`/`catch` cannot catch. A quoter that decodes
///      structs the ordinary way dies here; one that unpacks words by hand does not.
contract QuoterFaultProxy {
    /// @notice How the proxy answers.
    enum Mode {
        /// @dev Forward to the target and return its answer verbatim.
        PASS,
        /// @dev `revert(0, 0)`: no reason, no data.
        REVERT_EMPTY,
        /// @dev A `require`-style string revert.
        REVERT_REASON,
        /// @dev Return successfully with no data at all, the way a codeless address does.
        EMPTY,
        /// @dev Return five bytes: a success too short for any ABI shape.
        SHORT,
        /// @dev Return 32 full words of `0xff`: the right length for every shape the quoter reads, and garbage in
        ///      every field.
        WORD_SOUP,
        /// @dev Consume the whole gas allowance and revert with out-of-gas.
        OUT_OF_GAS,
        /// @dev Return 1,024 words: a returndata bomb aimed at the caller's memory expansion.
        BOMB
    }

    /// @notice The contract calls are forwarded to while {mode} is `PASS`.
    address public target;

    /// @notice The failure in force.
    Mode public mode;

    /// @notice When non-zero, only this selector misbehaves and every other call is forwarded.
    /// @dev Some dependencies answer several selectors on one call path. Filtering lets a test break exactly one
    ///      of them — which is what isolating a single bounded read, rather than a whole contract, requires.
    bytes4 public faultySelector;

    /// @notice Wraps `target_`.
    /// @param target_ The real implementation.
    constructor(address target_) {
        target = target_;
    }

    /// @notice Switches the failure in force.
    /// @param mode_ The new mode.
    function setMode(Mode mode_) external {
        mode = mode_;
    }

    /// @notice Restricts the failure to one selector, or lifts the restriction with `bytes4(0)`.
    /// @param selector The selector that misbehaves.
    function setFaultySelector(bytes4 selector) external {
        faultySelector = selector;
    }

    /// @notice Repoints the proxy.
    /// @param target_ The new implementation.
    function setTarget(address target_) external {
        target = target_;
    }

    /// @dev Every read the quoter makes lands here. Nothing in any branch writes state, so the whole function is
    ///      safe to run inside a `staticcall` even though a `fallback` cannot be declared `view`.
    fallback() external {
        Mode current = mode;
        bytes4 filter = faultySelector;
        if (filter != bytes4(0) && msg.sig != filter) current = Mode.PASS;

        if (current == Mode.PASS) {
            (bool ok, bytes memory returned) = target.staticcall(msg.data);
            assembly ("memory-safe") {
                if iszero(ok) { revert(add(returned, 0x20), mload(returned)) }
                return(add(returned, 0x20), mload(returned))
            }
        }

        if (current == Mode.REVERT_EMPTY) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }

        if (current == Mode.REVERT_REASON) revert("QuoterFaultProxy: dependency down");

        if (current == Mode.EMPTY) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }

        if (current == Mode.SHORT) {
            assembly ("memory-safe") {
                mstore(0, not(0))
                return(0, 5)
            }
        }

        if (current == Mode.OUT_OF_GAS) {
            uint256 churn = uint256(keccak256(abi.encode(msg.data)));
            while (true) {
                churn = uint256(keccak256(abi.encode(churn)));
            }
        }

        uint256 words = current == Mode.BOMB ? 1024 : 32;
        bytes memory soup = new bytes(words * 32);
        if (current == Mode.WORD_SOUP) {
            for (uint256 i = 0; i < words; ++i) {
                assembly ("memory-safe") {
                    mstore(add(add(soup, 0x20), mul(i, 0x20)), not(0))
                }
            }
        }
        assembly ("memory-safe") {
            return(add(soup, 0x20), mload(soup))
        }
    }
}
