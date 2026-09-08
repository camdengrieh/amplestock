// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

/// @title ITimelock
/// @notice The three functions of OpenZeppelin's `TimelockController` a deployment script needs. Declared here
///         rather than imported so that a script which only *relays* through the timelock does not pull the whole
///         governance contract into its compilation unit; `03_Core.s.sol`, which deploys one, imports the real
///         thing.
interface ITimelock {
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;
    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        external
        payable;
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;
    function getMinDelay() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title Gov
/// @notice One way for every deployment script to make a governed call, in either of the two shapes a live
///         deployment actually has.
///
///         Every mutator on `AmpsVault`, `PoolRegistry`, `FeedRegistry`, `OracleGate`, `AmpsBonds`, `AmpsHook`
///         and `BountyPot` is `onlyTimelock`, and that address is an **immutable** on the vault, the
///         registry and the hook — it is fixed in the constructor and can never be handed on. So the bootstrap
///         cannot be run by an EOA that is later replaced by governance: whatever address the constructors are
///         given has to make all ~100 registration calls itself.
///
///         Two modes follow from that:
///
///         | mode | `governor` is | who signs | how a call is made |
///         |---|---|---|---|
///         | direct (default) | an EOA or a Safe the operator controls | `governor` | plain `CALL` |
///         | relay (`AMPS_GOV_RELAY=true`) | an OZ `TimelockController` | `AMPS_DEPLOYER` | `schedule` then `execute` |
///
///         Relay is the production shape: `03_Core` deploys the `TimelockController` with `minDelay = 0` and the
///         deployer as a proposer, the bootstrap runs through it at zero delay, and the last governance action of
///         the launch raises `minDelay` to 48 h and revokes the deployer's proposer role
///         (`03_Core` stage `finalize`). Direct is what the fork-free dry run, the testnet fixtures and a
///         single-operator testnet use, and it is the mode every existing test drives.
///
/// @dev **Why this is a library of `internal` functions and not a helper contract.** A `vm.startBroadcast` window
///      opened by a *helper contract* writes every transaction into `broadcast/…/run-latest.json` with the same
///      nonce (Foundry 1.8.1; the run dies with "EOA nonce changed unexpectedly"). Internal library functions are
///      inlined into the calling contract's own code, so the broadcast window and every call {send} makes belong
///      to the script `forge script` was pointed at, which is the rule `docs/deploy-runbook.md` states.
library Gov {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice How a script reaches governance, and who signs for it.
    /// @param governor The address the target contracts accept as their `timelock`.
    /// @param sender The account that signs every broadcast transaction.
    /// @param relay True when {governor} is a `TimelockController` reached by `schedule` + `execute`.
    /// @param counter Calls made so far, which is what makes each relayed operation's salt unique.
    /// @param saltSeed Per-run salt entropy, so re-running a script cannot collide with its own earlier
    ///        (already `Done`) operations, which `TimelockController` would reject.
    struct Ctx {
        address governor;
        address sender;
        bool relay;
        uint256 counter;
        bytes32 saltSeed;
    }

    /// @notice A governed call reverted. The inner reason is bubbled up unchanged where there is one; this is the
    ///         empty-returndata case.
    /// @param target The contract called.
    /// @param selector The selector that failed.
    error CallFailed(address target, bytes4 selector);

    /// @notice Relay mode needs a signer that is not the timelock itself.
    error DeployerRequired();

    /// @notice The timelock is not usable for a zero-delay bootstrap: either the sender is not a proposer, or the
    ///         minimum delay has already been raised to its production value.
    /// @param timelock The timelock.
    /// @param minDelay Its current minimum delay.
    error TimelockNotBootstrappable(address timelock, uint256 minDelay);

    /// @notice `keccak256("PROPOSER_ROLE")`, as `TimelockController` defines it.
    bytes32 internal constant PROPOSER_ROLE = 0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1;

    /// @notice `keccak256("CANCELLER_ROLE")`.
    bytes32 internal constant CANCELLER_ROLE = 0xfd643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783;

    /// @notice `keccak256("EXECUTOR_ROLE")`.
    bytes32 internal constant EXECUTOR_ROLE = 0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63;

    // ---------------------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------------------

    /// @notice The context a script runs under, from the environment.
    /// @dev `AMPS_GOV_RELAY` selects the mode; `AMPS_DEPLOYER` names the signer in relay mode. In direct mode the
    ///      signer *is* the governor, which is what `vm.startBroadcast(timelock)` has always meant in these
    ///      scripts.
    /// @param governor The configured timelock address.
    /// @return ctx The context.
    function load(address governor) internal view returns (Ctx memory ctx) {
        bool relay = vm.envOr("AMPS_GOV_RELAY", false);
        address sender = vm.envOr("AMPS_DEPLOYER", address(0));
        if (relay && (sender == address(0) || sender == governor)) revert DeployerRequired();
        ctx = Ctx({
            governor: governor,
            sender: relay ? sender : governor,
            relay: relay,
            counter: 0,
            saltSeed: keccak256(abi.encodePacked("amplestocks.gov", block.chainid, block.number, block.timestamp))
        });
    }

    // ---------------------------------------------------------------------------------------------------------
    // Broadcasting
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Opens the broadcast window as the account that signs for this context.
    /// @dev Must be called from the script contract `forge script` was pointed at — see the contract note.
    /// @param ctx The context.
    function begin(Ctx memory ctx) internal {
        vm.startBroadcast(ctx.sender);
    }

    /// @notice Closes the broadcast window.
    /// @param ctx The context. Unused, and present so call sites read as a pair with {begin}.
    function end(Ctx memory ctx) internal {
        ctx; // silence the unused-parameter warning without changing the signature
        vm.stopBroadcast();
    }

    /// @notice Makes one governed call, in whichever shape this context is in.
    /// @dev In direct mode the target's return data comes back; in relay mode `TimelockController.execute`
    ///      discards it, so a caller that needs a return value must read it back off the target. Both modes
    ///      bubble the target's revert reason unchanged.
    /// @param ctx The context.
    /// @param target The contract to call.
    /// @param data The calldata.
    /// @return ret The target's return data in direct mode; empty in relay mode.
    function send(Ctx memory ctx, address target, bytes memory data) internal returns (bytes memory ret) {
        if (!ctx.relay) return _call(target, data);

        bytes32 salt = keccak256(abi.encodePacked(ctx.saltSeed, ctx.counter));
        ++ctx.counter;
        _call(ctx.governor, abi.encodeCall(ITimelock.schedule, (target, 0, data, bytes32(0), salt, 0)));
        _call(ctx.governor, abi.encodeCall(ITimelock.execute, (target, 0, data, bytes32(0), salt)));
    }

    /// @notice Makes several governed calls that must all be *scheduled* before any of them executes.
    /// @dev The case this exists for is the last governance action of a launch: raising `minDelay` from zero to
    ///      48 h and revoking the deployer's proposer role. Sent one at a time, the first execution would make the
    ///      second impossible to schedule. As a batch, both are scheduled while the timelock is still at zero
    ///      delay and then executed in order. In direct mode it is simply the calls in order.
    /// @param ctx The context.
    /// @param targets The contracts to call.
    /// @param datas The calldata, parallel to `targets`.
    function sendBatch(Ctx memory ctx, address[] memory targets, bytes[] memory datas) internal {
        if (!ctx.relay) {
            for (uint256 i; i < targets.length; ++i) {
                _call(targets[i], datas[i]);
            }
            return;
        }

        uint256[] memory values = new uint256[](targets.length);
        bytes32 salt = keccak256(abi.encodePacked(ctx.saltSeed, ctx.counter));
        ++ctx.counter;
        _call(ctx.governor, abi.encodeCall(ITimelock.scheduleBatch, (targets, values, datas, bytes32(0), salt, 0)));
        _call(ctx.governor, abi.encodeCall(ITimelock.executeBatch, (targets, values, datas, bytes32(0), salt)));
    }

    // ---------------------------------------------------------------------------------------------------------
    // Checks
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Asserts that a relay context can actually run a bootstrap: the signer is a proposer and the
    ///         timelock's minimum delay is still zero. A no-op in direct mode.
    /// @dev Called at the top of every script that relays, so a run against an already-finalised timelock fails
    ///      immediately with a legible error rather than half way through 97 registrations.
    /// @param ctx The context.
    function requireBootstrappable(Ctx memory ctx) internal view {
        if (!ctx.relay) return;
        ITimelock timelock = ITimelock(ctx.governor);
        uint256 minDelay = timelock.getMinDelay();
        if (minDelay != 0 || !timelock.hasRole(PROPOSER_ROLE, ctx.sender)) {
            revert TimelockNotBootstrappable(ctx.governor, minDelay);
        }
    }

    /// @notice One line describing the mode, for the run log.
    /// @param ctx The context.
    function describe(Ctx memory ctx) internal pure {
        if (ctx.relay) {
            console2.log("governance: relay through TimelockController %s, signed by %s", ctx.governor, ctx.sender);
        } else {
            console2.log("governance: direct, broadcasting as %s", ctx.governor);
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------

    /// @dev A plain call that bubbles the callee's revert data.
    function _call(address target, bytes memory data) private returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        if (ok) return ret;
        if (ret.length == 0) revert CallFailed(target, bytes4(data));
        assembly ("memory-safe") {
            revert(add(ret, 32), mload(ret))
        }
    }
}
