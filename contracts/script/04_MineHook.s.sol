// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsHook} from "../src/hook/AmpsHook.sol";
import {Constants} from "../src/types/Constants.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title MineHook
/// @notice Mines the CREATE2 salt that puts `AmpsHook` at an address whose low 14 bits are exactly `0x38C0`, and
///         optionally deploys it through the canonical deterministic-deployment proxy.
///
/// @dev **Why the address is the permission set.** Uniswap v4 reads a hook's permissions out of its address: the
///      PoolManager calls `beforeSwap` because bit 7 of the address is set, not because the contract says so. The
///      hook must therefore carry `BEFORE_INITIALIZE | AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP |
///      AFTER_SWAP` = `0x38C0` and, just as importantly, must **not** carry `BEFORE_REMOVE_LIQUIDITY` (I18: a
///      removal must never be blockable) or either `*_RETURNS_DELTA` bit (I13: the hook never moves value).
///      `BaseHook`'s constructor asserts the address against `getHookPermissions()`, so a wrong salt fails at
///      deployment rather than in production — but the salt is only valid for one exact creation-code hash, which
///      is why `test/unit/HookAddress.t.sol` re-checks it in CI after every dependency bump.
///
/// @dev **Usage.**
/// ```
///   # print the init code hash and mine a salt against the placeholder constructor arguments
///   forge script script/04_MineHook.s.sol
///
///   # mine against the real deployment arguments and record them
///   HOOK_POOL_MANAGER=0x... HOOK_AMPS=0x... HOOK_VAULT=0x... HOOK_REGISTRY=0x... HOOK_TIMELOCK=0x... \
///     forge script script/04_MineHook.s.sol
///
///   # the same, and actually deploy through the CREATE2 factory
///   ... HOOK_DEPLOY=true forge script script/04_MineHook.s.sol --broadcast --rpc-url $RPC
/// ```
///      Both forms write `script/config/hook.json`. Mining is pure `view` work — no `ffi`, which the project
///      keeps disabled — and `HookMiner` searches at most 160,444 salts, which is ample for a 5-bit-of-14 target.
contract MineHook is Script {
    /// @notice The canonical deterministic-deployment proxy, the CREATE2 sender every Amplestocks address is
    ///         mined against; `forge-std`'s `Base` already declares it under this name and at this address, so it
    ///         is inherited rather than re-declared. Recorded as **unverified** in the plan's reference table:
    ///         assert its code before relying on it on a live chain.
    address internal constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice The v4 PoolManager on Robinhood Chain 4663, used when `HOOK_POOL_MANAGER` is unset.
    address internal constant DEFAULT_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    /// @notice Stand-in for an address the deployment does not know yet. Every mined salt is bound to the exact
    ///         constructor arguments it was mined for, so a placeholder means "re-mine before deploying".
    address internal constant PLACEHOLDER = 0x000000000000000000000000000000000000dEaD;

    /// @notice Where the mined address, its salt and the arguments it is bound to are recorded.
    string internal constant CONFIG_PATH = "./script/config/hook.json";

    /// @notice The mined address does not carry exactly `0x38C0`.
    error WrongFlags(address hook, uint160 flags);

    /// @notice The mined address carries a bit the design forbids.
    error ForbiddenFlag(address hook, bytes32 flag);

    /// @notice The deployed hook has no code.
    error NoCode(address hook);

    /// @notice The deployment did not land on the mined address.
    error AddressMismatch(address expected, address actual);

    function run() external {
        address poolManager = vm.envOr("HOOK_POOL_MANAGER", DEFAULT_POOL_MANAGER);
        address amps = vm.envOr("HOOK_AMPS", PLACEHOLDER);
        address vault = vm.envOr("HOOK_VAULT", PLACEHOLDER);
        address registry = vm.envOr("HOOK_REGISTRY", PLACEHOLDER);
        address timelock = vm.envOr("HOOK_TIMELOCK", PLACEHOLDER);

        bytes memory args = abi.encode(poolManager, amps, vault, registry, timelock);
        bytes32 codeHash = keccak256(abi.encodePacked(type(AmpsHook).creationCode, args));

        console2.log("factory        %s", FACTORY);
        console2.log("flags          0x38C0");
        console2.log("init code hash %s", vm.toString(codeHash));

        (address mined, bytes32 salt) =
            HookMiner.find(FACTORY, uint160(Constants.HOOK_FLAGS), type(AmpsHook).creationCode, args);
        _assertFlags(mined);

        console2.log("salt           %s", vm.toString(salt));
        console2.log("hook           %s", mined);

        if (vm.envOr("HOOK_DEPLOY", false)) {
            vm.startBroadcast();
            AmpsHook hook = new AmpsHook{salt: salt}(IPoolManager(poolManager), amps, vault, registry, timelock);
            vm.stopBroadcast();

            if (address(hook) != mined) revert AddressMismatch(mined, address(hook));
            if (address(hook).code.length == 0) revert NoCode(address(hook));
            _assertFlags(address(hook));
            console2.log("deployed, code length %s", address(hook).code.length);
        }

        _write(mined, salt, codeHash, poolManager, amps, vault, registry, timelock);
    }

    /// @notice The address really does carry the design's permission set, and nothing else.
    /// @dev Public so `test/unit/HookAddress.t.sol` re-runs exactly this check against the committed record.
    /// @param hook The address to check.
    function assertFlags(address hook) public pure {
        _assertFlags(hook);
    }

    /// @notice `keccak256(creationCode ++ abi.encode(args))` for a given argument set: what the miner grinds
    ///         against, and what makes a recorded salt stale the moment the hook's bytecode moves.
    /// @param poolManager The v4 PoolManager.
    /// @param amps The AMPS token.
    /// @param vault The vault.
    /// @param registry The pool registry.
    /// @param timelock The governance timelock.
    /// @return hash The init code hash.
    function initCodeHash(address poolManager, address amps, address vault, address registry, address timelock)
        public
        pure
        returns (bytes32 hash)
    {
        hash = keccak256(
            abi.encodePacked(type(AmpsHook).creationCode, abi.encode(poolManager, amps, vault, registry, timelock))
        );
    }

    /// @notice The CREATE2 address for a salt under {FACTORY}.
    /// @param salt The salt.
    /// @param initCodeHash_ The init code hash.
    /// @return predicted The address.
    function predictAddress(bytes32 salt, bytes32 initCodeHash_) public pure returns (address predicted) {
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, salt, initCodeHash_)))));
    }

    function _assertFlags(address hook) private pure {
        uint160 flags = uint160(hook) & uint160(Hooks.ALL_HOOK_MASK);
        if (flags != uint160(Constants.HOOK_FLAGS)) revert WrongFlags(hook, flags);
        if (uint160(hook) & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0) revert ForbiddenFlag(hook, "beforeSwapDelta");
        if (uint160(hook) & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0) revert ForbiddenFlag(hook, "afterSwapDelta");
        if (uint160(hook) & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG != 0) {
            revert ForbiddenFlag(hook, "addLiquidityDelta");
        }
        if (uint160(hook) & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG != 0) {
            revert ForbiddenFlag(hook, "removeLiquidityDelta");
        }
        if (uint160(hook) & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG != 0) revert ForbiddenFlag(hook, "beforeRemove");
        if (uint160(hook) & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG != 0) revert ForbiddenFlag(hook, "afterRemove");
    }

    function _write(
        address mined,
        bytes32 salt,
        bytes32 initCodeHash_,
        address poolManager,
        address amps,
        address vault,
        address registry,
        address timelock
    ) private {
        string memory obj = "amplestocks.hook";
        vm.serializeAddress(obj, "hook", mined);
        vm.serializeBytes32(obj, "salt", salt);
        vm.serializeBytes32(obj, "initCodeHash", initCodeHash_);
        vm.serializeAddress(obj, "factory", FACTORY);
        vm.serializeUint(obj, "flags", uint256(Constants.HOOK_FLAGS));
        vm.serializeAddress(obj, "poolManager", poolManager);
        vm.serializeAddress(obj, "amps", amps);
        vm.serializeAddress(obj, "vault", vault);
        vm.serializeAddress(obj, "registry", registry);
        vm.serializeString(obj, "solc", "0.8.30");
        vm.serializeString(obj, "profile", "src/hook/* at optimizer_runs = 200, via_ir = true");
        string memory json = vm.serializeAddress(obj, "timelock", timelock);
        vm.writeJson(json, CONFIG_PATH);
        console2.log("wrote %s", CONFIG_PATH);
    }
}
