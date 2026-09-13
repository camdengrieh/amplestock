// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IOracleGate} from "../../src/interfaces/IOracleGate.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotInitialized, ZeroAddress} from "../../src/types/Errors.sol";
import {GateState} from "../../src/types/Types.sol";
import {AmpsVaultFixture} from "../mocks/AmpsVaultFixture.sol";

/// @notice A gate that answers every call by burning gas and then reverting.
///
/// @dev The griefing shape the `GATE_READ_GAS` cap exists for, and it is not reachable through
///      `setPolicyPointer` either — this has code — so the cap is what stops it, not the pointer guard.
///
/// @dev It burns at most {BURN} and then reverts rather than looping forever, for two reasons. A call the vault
///      caps at `GATE_READ_GAS` (1.5M) is handed less than {BURN}, so it runs out of gas exactly as an unbounded
///      burner would; and a call the vault does *not* cap would otherwise be handed 63/64 of a Foundry test's
///      gas limit and spin for longer than any run allows. The trailing `revert` matters too: returning normally
///      with an empty buffer is the *codeless* failure mode, which the other tests cover, whereas this one is
///      about gas.
contract GasBurningGate {
    /// @dev More than the vault's `GATE_READ_GAS`, so a capped read exhausts itself before reaching the revert.
    uint256 private constant BURN = 2_000_000;

    fallback() external {
        uint256 floor_ = gasleft() > BURN ? gasleft() - BURN : 0;
        while (gasleft() > floor_) {}
        revert("burned");
    }
}

/// @notice A gate whose composite `state(0)` cannot be read but whose one-slot `protocolFreezeUntil()` can.
///
/// @dev The asymmetry is the whole of re-audit finding 6. `IOracleGate.state(0)` walks the calendar, the feed
///      registry, the market reference and the registry — 330-390k gas against real aggregator proxies — while
///      `protocolFreezeUntil()` is a getter over one slot at ~2.6k. A caller who sends a gated selector with a
///      gas limit that starves the first and not the second therefore starved the *un*-starvable signal, because
///      the vault read them in that order and returned on the first. This gate is that state, made explicit:
///      everything but the freeze getter burns more than `GATE_READ_GAS` and then reverts.
contract StarvedStateGate {
    /// @dev More than the vault's `GATE_READ_GAS`, so the capped read exhausts itself before reaching the revert.
    uint256 private constant BURN = 2_000_000;

    uint32 private immutable _until;

    constructor(uint32 until_) {
        _until = until_;
    }

    /// @notice The guardian's protocol-wide freeze, which is always cheap to read.
    /// @return until The timestamp the freeze runs to.
    function protocolFreezeUntil() external view returns (uint32 until) {
        return _until;
    }

    fallback() external {
        uint256 floor_ = gasleft() > BURN ? gasleft() - BURN : 0;
        while (gasleft() > floor_) {}
        revert("burned");
    }
}

/// @title VaultGateResilienceTest
/// @notice `docs/phase2-state-model.md` §7.1: **"a gate pointer that cannot be read is absent, not a refusal"**,
///         taken literally rather than as far as a typed `try` happens to reach.
///
/// @dev The property under test is a *liveness* one and it is unusual in that direction: the vault is immutable,
///      the gate is the one pointer that can refuse every governance call, and `setPolicyPointer` — the only way
///      to replace a bad gate — calls `_requireHealthy` first. So any gate answer the vault cannot digest bricks
///      the protocol permanently, and the ways a `try IOracleGate(gate).state(0) returns (GateState)` fails to
///      digest an answer are not exotic:
///
///        * a **codeless** pointer answers a `staticcall` with success and zero bytes, and the ABI decode of that
///          empty buffer reverts in the *vault's* frame, where the `catch` cannot see it;
///        * an **out-of-range enum ordinal** — any word above `type(GateState).max` — is a `Panic`, likewise;
///        * **short returndata** is a `Panic`, likewise;
///        * and for the `void poke()` the compiler's own `extcodesize` guard reverts before the `try` is entered.
///
///      Each case below therefore forces one of those answers and asserts that every gated selector still works,
///      and that governance can still point the vault at a healthy gate afterwards.
contract VaultGateResilienceTest is AmpsVaultFixture {
    /// @dev §1.1 slot 9: `oracleGate`. Written directly so a test can install a pointer `setPolicyPointer` would
    ///      (now) refuse, which is the only way the broken states below are still reachable at all.
    bytes32 private constant ORACLE_GATE_SLOT = bytes32(uint256(9));

    /// @dev An address with no code. `vm.etch` is never used on it: that is the point.
    address private constant CODELESS_GATE = address(0xBADBADBAD);

    function setUp() public {
        deployVaultWorld();
        runGenesis();
    }

    // -------------------------------------------------------------------------------------------------------------
    // The four shapes a `try` does not catch
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A codeless gate pointer is read as absent, and the vault keeps working — including the one call
    ///         that can replace it.
    function test_aCodelessGatePointerIsAbsentRatherThanFatal() public {
        _forceGate(CODELESS_GATE);

        vault.checkpoint();
        vault.touch();

        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("oracleGate"), address(gate));
        assertEq(vault.oracleGate(), address(gate), "governance pointed the vault back at a healthy gate");
    }

    /// @notice An out-of-range `GateState` ordinal is absent, not a `Panic`. `GateState` has six members, so 77 is
    ///         a word no `abi.decode(..., (GateState))` can accept.
    function test_anOutOfRangeGateStateOrdinalIsAbsentRatherThanFatal() public {
        vm.mockCall(address(gate), abi.encodeCall(IOracleGate.state, (0)), abi.encode(uint256(77)));

        vault.checkpoint();
        vault.touch();

        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("feedRegistry"), address(feeds));
    }

    /// @notice Short returndata is absent too: a single byte where a word was expected.
    function test_shortGateReturndataIsAbsentRatherThanFatal() public {
        vm.mockCall(address(gate), abi.encodeCall(IOracleGate.state, (0)), hex"01");
        vault.checkpoint();
        vault.touch();
    }

    /// @notice And the same for the *second* word the policy reads. The state word has to come back intact for the
    ///         freeze read to be reached at all, so this case is only reachable on its own.
    function test_shortFreezeReturndataIsAbsentRatherThanFatal() public {
        vm.mockCall(address(gate), abi.encodeCall(IOracleGate.protocolFreezeUntil, ()), hex"beef");
        vault.checkpoint();
        vault.touch();

        // A freeze that *is* readable still refuses, so the leniency is about the shape and not about the policy.
        vm.clearMockedCalls();
        gate.setProtocolFreezeUntil(uint32(block.timestamp + 1 days));
        vm.expectRevert(
            abi.encodeWithSignature("GateNotHealthy(uint8,bytes32)", uint8(GateState.SCHEDULED_FREEZE), bytes32(0))
        );
        vault.checkpoint();
    }

    /// @notice A gate whose `poke()` reverts, and a codeless one, are both ignored by the stamp.
    function test_aGateWhosePokeFailsDoesNotBlockTheUpkeepPaths() public {
        vm.mockCallRevert(address(gate), abi.encodeCall(IOracleGate.poke, ()), "down");
        vault.checkpoint();
        vault.touch();

        _forceGate(CODELESS_GATE);
        vault.touch();
    }

    /// @notice A gate that reverts outright is still a refusal-free read, as §7.1 has always said. This is the one
    ///         case the old typed `try` did cover, and it must keep working.
    function test_aRevertingGateIsStillAbsent() public {
        vm.mockCallRevert(address(gate), abi.encodeCall(IOracleGate.state, (0)), "down");
        vault.checkpoint();
        vault.touch();
    }

    /// @notice And none of this makes the gate toothless: a healthy gate reporting a refusing state still refuses,
    ///         with the ordinal it reported.
    function test_aReadableGateStillRefuses() public {
        gate.setDefaultState(GateState.SCHEDULED_FREEZE);
        vm.expectRevert(
            abi.encodeWithSignature("GateNotHealthy(uint8,bytes32)", uint8(GateState.SCHEDULED_FREEZE), bytes32(0))
        );
        vault.checkpoint();
    }

    /// @notice The freeze word is still read, and still refuses, when the state word says nothing is wrong.
    function test_aProtocolFreezeStillRefuses() public {
        gate.setProtocolFreezeUntil(uint32(block.timestamp + 1 days));
        vm.expectRevert(
            abi.encodeWithSignature("GateNotHealthy(uint8,bytes32)", uint8(GateState.SCHEDULED_FREEZE), bytes32(0))
        );
        vault.checkpoint();
    }

    /// @notice **Re-audit finding 6.** A `state(0)` read the caller's gas limit starves no longer carries the
    ///         guardian's protocol freeze down with it.
    ///
    /// @dev `_requireGate` read the expensive composite first and returned as soon as it could not be read — the
    ///      "an unreadable gate is absent" rule, which is load-bearing because this contract is immutable and a
    ///      broken pointer must never lock governance out of replacing it. But the cheap `protocolFreezeUntil()`
    ///      refusal sat *after* that return, so a gated selector sent with a gas limit that starves the 330-390k
    ///      composite and nothing else proceeded while the freeze was live. The order is now the other way round:
    ///      the refusal that cannot be starved runs first, and neither read's own semantics changed.
    function test_r07_aStarvedStateReadStillHonoursTheGuardiansFreeze() public {
        _forceGate(address(new StarvedStateGate(uint32(block.timestamp + 1 days))));

        vm.expectRevert(
            abi.encodeWithSignature("GateNotHealthy(uint8,bytes32)", uint8(GateState.SCHEDULED_FREEZE), bytes32(0))
        );
        vault.checkpoint();
    }

    /// @notice And the rule the reorder must not break: with no freeze in force, an unreadable `state(0)` is still
    ///         *absent* rather than a refusal, so every gated selector still works and governance can still
    ///         replace the gate.
    function test_r07_anUnreadableStateWithNoFreezeIsStillAbsent() public {
        _forceGate(address(new StarvedStateGate(0)));

        vault.checkpoint();
        vault.touch();

        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("oracleGate"), address(gate));
        assertEq(vault.oracleGate(), address(gate), "and governance could still replace it");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The pointer setter's own guard
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `setPolicyPointer` refuses a codeless replacement, which is what stops the broken states above from
    ///         being reachable by a typo in the first place.
    function test_setPolicyPointerRefusesACodelessReplacement() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        vault.setPolicyPointer(bytes32("oracleGate"), CODELESS_GATE);

        vm.expectRevert(ZeroAddress.selector);
        vault.setPolicyPointer(bytes32("feedRegistry"), address(0));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------------------------
    // The gas cap is a griefing bound, not a budget
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A gate that burns everything it is given cannot take the caller down with it: the read is capped,
    ///         and by EIP-150 the vault keeps a 64th of its remaining gas whatever the callee does.
    function test_aGateThatBurnsItsGasIsAbsentRatherThanFatal() public {
        _forceGate(address(new GasBurningGate()));
        vault.checkpoint();
        vault.touch();

        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("oracleGate"), address(gate));
        assertEq(vault.oracleGate(), address(gate), "and governance could still replace it");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Installs `pointer` in slot 9 without going through `setPolicyPointer`, which would now refuse it.
    function _forceGate(address pointer) private {
        vm.store(address(vault), ORACLE_GATE_SLOT, bytes32(uint256(uint160(pointer))));
        assertEq(vault.oracleGate(), pointer, "the gate pointer was forced");
    }
}

/// @title VaultPreGenesisTest
/// @notice The pre-genesis window belongs to pool registration, and an unprivileged `checkpoint()` in it used to
///         poison the reference price for the life of the protocol.
///
/// @dev The mechanism, end to end: `_navPerShare` is `(A + 1) x 1e18 / (T + VIRTUAL_SHARES)`, so with `T == 0` it
///      is `1e18 / 1e3` = 1e15, i.e. $0.001. `checkpoint()` writes that into `_pRefX18`. `PoolRegistry` anchors
///      every pool it opens at `vault.pRefX18()` and substitutes $1.00 **only while that word is still zero**
///      (Decision 12), and the entry pools plus every spoke are registered in exactly this window — with the gate
///      pointer deliberately unset, so nothing else refuses either. One 0-value permissionless call therefore
///      opened every pool registered afterwards a thousand times below NAV, irreversibly.
///
///      Two independent guards close it, and this suite asserts both: the two permissionless upkeep selectors
///      refuse before {genesis}, and `_navPerShare` reports zero rather than $0.001 when there are no shares.
contract VaultPreGenesisTest is AmpsVaultFixture {
    function setUp() public {
        deployVaultWorld();
    }

    /// @notice `checkpoint()` refuses before genesis.
    function test_checkpointRevertsBeforeGenesis() public {
        vm.expectRevert(NotInitialized.selector);
        vault.checkpoint();

        vm.prank(ALICE);
        vm.expectRevert(NotInitialized.selector);
        vault.checkpoint();
    }

    /// @notice And so does `touch()`, the other permissionless upkeep selector.
    function test_touchRevertsBeforeGenesis() public {
        vm.expectRevert(NotInitialized.selector);
        vault.touch();
    }

    /// @notice The consequence the guard exists for: `pRefX18` stays zero until genesis, which is what keeps
    ///         `PoolRegistry`'s $1.00 fallback reachable for every pool registered in the launch window.
    function test_pRefStaysZeroUntilGenesisAndIsOneDollarAfterwards() public {
        assertEq(vault.pRefX18(), 0, "no checkpoint has been written yet");

        vm.expectRevert(NotInitialized.selector);
        vault.checkpoint();
        assertEq(vault.pRefX18(), 0, "and a refused checkpoint wrote nothing");

        runGenesis();
        assertApproxEqAbs(vault.pRefX18(), Constants.WAD, 1, "genesis anchors the reference at $1.00");
        assertGt(vault.pRefX18(), Constants.WAD / 2, "and nowhere near the $0.001 the empty-supply formula gives");
    }

    /// @notice Belt to that pair of braces: with no shares outstanding, NAV/share is zero rather than the
    ///         `1e18 / VIRTUAL_SHARES` artefact of the virtual-share guard.
    function test_navPerShareIsZeroWhileTheSupplyIsZero() public view {
        assertEq(amps.totalSupply(), 0, "no shares exist yet");
        assertEq(vault.previewNavPerShareX18(), 0, "so there is no NAV per share to report");
    }

    /// @notice Genesis itself is unaffected: it mints `S0` before it checkpoints, so the checkpoint it runs sees a
    ///         real supply and writes a real price.
    function test_genesisStillCheckpointsAtOneDollar() public {
        runGenesis();
        assertEq(vault.navPerShareX18(), 999_999_999_999_999_999, "$1.00 to the last wei VIRTUAL_SHARES rounds off");
        assertTrue(vault.initialized(), "and the latch is closed");
    }
}
