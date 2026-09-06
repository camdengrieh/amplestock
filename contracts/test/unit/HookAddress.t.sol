// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MineHook} from "../../script/04_MineHook.s.sol";
import {AmpsHook} from "../../src/hook/AmpsHook.sol";
import {Constants} from "../../src/types/Constants.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @title HookAddressTest
/// @notice The CI `hook address re-check` job. A v4 hook's permissions **are** its address, so the salt recorded
///         in `script/config/hook.json` is valid for exactly one creation-code hash: change `AmpsHook`, anything
///         it imports, the compiler, the optimizer settings or the constructor arguments, and the salt now
///         deploys a different address — one the PoolManager will reject, or worse, one that carries a permission
///         bit the design forbids.
///
/// @dev Three checks, in increasing strictness:
///        1. the current creation code still admits a `0x38C0` address at all, and the one `HookMiner` finds
///           carries no returns-delta and no remove-liquidity bit (this needs no recorded file);
///        2. the recorded address is internally consistent — it is what `CREATE2(factory, salt, initCode)` gives
///           for the recorded init-code hash, and it carries the right bits;
///        3. the recorded init-code hash is still the current one. This is the check that fails on a bytecode
///           change, and the fix is to re-run `forge script script/04_MineHook.s.sol` and commit the result.
///
/// @dev A missing `script/config/hook.json` logs and skips rather than failing, so a fresh checkout is not
///      blocked; the CI job probes for the file for the same reason.
contract HookAddressTest is Test {
    string internal constant CONFIG_PATH = "./script/config/hook.json";

    MineHook internal miner;

    function setUp() public {
        miner = new MineHook();
    }

    /// @notice The creation code as it stands can be mined to `0x38C0`, and to nothing else.
    function test_theCurrentCreationCodeStillAdmitsTheDesignFlags() public view {
        bytes memory args =
            abi.encode(address(0x1111), address(0x2222), address(0x3333), address(0x4444), address(0x5555));
        (address mined,) =
            HookMiner.find(address(this), uint160(Constants.HOOK_FLAGS), type(AmpsHook).creationCode, args);

        assertEq(uint160(mined) & uint160(Hooks.ALL_HOOK_MASK), uint160(0x38C0), "0x38C0");
        miner.assertFlags(mined);
    }

    /// @notice The committed record is self-consistent and carries the design's bits.
    function test_theRecordedAddressMatchesItsOwnSaltAndHash() public view {
        if (!vm.exists(CONFIG_PATH)) {
            console2.log("SKIP: %s not present; run forge script script/04_MineHook.s.sol", CONFIG_PATH);
            return;
        }
        string memory json = vm.readFile(CONFIG_PATH);

        address recorded = vm.parseJsonAddress(json, ".hook");
        bytes32 salt = vm.parseJsonBytes32(json, ".salt");
        bytes32 recordedHash = vm.parseJsonBytes32(json, ".initCodeHash");
        address factory = vm.parseJsonAddress(json, ".factory");

        assertEq(factory, 0x4e59b44847b379578588920cA78FbF26c0B4956C, "the canonical CREATE2 proxy");
        assertEq(vm.parseJsonUint(json, ".flags"), uint256(Constants.HOOK_FLAGS), "the recorded flags");
        assertEq(miner.predictAddress(salt, recordedHash), recorded, "salt + hash => address");
        miner.assertFlags(recorded);
    }

    /// @notice The recorded salt is still valid for the hook as it compiles today.
    /// @dev This is the one that fails after a dependency bump. It is meant to: a stale salt deploys a hook the
    ///      PoolManager rejects. Re-run `forge script script/04_MineHook.s.sol` with the same
    ///      `HOOK_POOL_MANAGER`/`HOOK_AMPS`/`HOOK_VAULT`/`HOOK_REGISTRY`/`HOOK_TIMELOCK` and commit the result.
    function test_theRecordedSaltStillProducesTheRecordedAddress() public view {
        if (!vm.exists(CONFIG_PATH)) {
            console2.log("SKIP: %s not present", CONFIG_PATH);
            return;
        }
        string memory json = vm.readFile(CONFIG_PATH);

        bytes32 currentHash = miner.initCodeHash(
            vm.parseJsonAddress(json, ".poolManager"),
            vm.parseJsonAddress(json, ".amps"),
            vm.parseJsonAddress(json, ".vault"),
            vm.parseJsonAddress(json, ".registry"),
            vm.parseJsonAddress(json, ".timelock")
        );

        assertEq(
            currentHash,
            vm.parseJsonBytes32(json, ".initCodeHash"),
            "AmpsHook's creation code moved: re-run script/04_MineHook.s.sol and commit script/config/hook.json"
        );
        assertEq(
            miner.predictAddress(vm.parseJsonBytes32(json, ".salt"), currentHash),
            vm.parseJsonAddress(json, ".hook"),
            "the recorded salt no longer lands on the recorded address"
        );
    }

    /// @notice The address the fixture actually deploys in every hook suite carries the same bits, which is what
    ///         makes those suites a valid rehearsal of the mined deployment.
    function test_theFlagsConstantAndTheMaskAgree() public pure {
        assertEq(uint256(Constants.HOOK_FLAGS), 0x38C0, "HOOK_FLAGS");
        assertEq(uint256(Constants.HOOK_ADDRESS_MASK), uint256(Hooks.ALL_HOOK_MASK), "HOOK_ADDRESS_MASK");
        assertEq(
            uint256(Constants.HOOK_FLAGS),
            uint256(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ),
            "the five callbacks the design uses, and no others"
        );
    }
}
