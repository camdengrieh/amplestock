// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {VaultNavLib} from "../src/vault/VaultNavLib.sol";
import {VaultPlacementLib} from "../src/vault/VaultPlacementLib.sol";
import {VaultRedeemLib} from "../src/vault/VaultRedeemLib.sol";
import {VaultRolloutLib} from "../src/vault/VaultRolloutLib.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title Libraries
/// @notice Deploys the four linked vault libraries — `VaultNavLib`, `VaultRedeemLib`, `VaultPlacementLib` and
///         `VaultRolloutLib` — deterministically through the canonical CREATE2 factory, records them in
///         `script/config/libraries.json`, and prints the `--libraries` flags every later build and script needs.
///
/// @dev **Why this runs before the token and the vault.** `AmpsVault` reaches all four libraries by
///      `DELEGATECALL` (`docs/phase2-state-model.md` §10.1, `docs/phase3-state-model.md` §12 ruling A), so an
///      unlinked `AmpsVault` artefact carries `__$...$__` placeholders and cannot be deployed at all. The vault's
///      address depends on its linked bytecode, `Amps`'s CREATE2 salt is mined against `abi.encode(vault)`, and
///      the hook's salt is mined against the vault address in turn — so the library addresses are the first thing
///      the deployment fixes, ahead of `01_MineAmps`'s final mining pass.
///
/// @dev **Why the addresses are not in `foundry.toml`.** A `libraries` key there would pin one chain's addresses
///      into *every* build, including `forge test`, where Foundry deploys its own copies at its own addresses.
///      The flags are therefore passed per command and recorded in `script/config/libraries.json`; `forge build
///      --sizes` and the CI EIP-170 gate must be given the same four flags so they measure the linked artefact.
///
/// @dev **`VaultRolloutLib` is special.** It calls `VaultPlacementLib.place`, which is `public`, so its own
///      artefact carries a link reference: it can only be built once `VaultPlacementLib`'s address is known. That
///      is why {deployCore} and {deployRollout} are two entry points rather than one, and why {deployRollout}
///      re-reads the deployed runtime code and refuses when the address Foundry linked into it is not the
///      `VaultPlacementLib` this script deployed ({UnlinkedRollout}). Deployment is therefore two commands:
///
/// ```
///   # 1. the three link-free libraries; prints VaultPlacementLib's deterministic address
///   forge script script/02_Libraries.s.sol --broadcast --rpc-url $RPC
///
///   # 2. VaultRolloutLib, built against that address
///   LIB_PLACEMENT=0x... LIB_ROLLOUT_ONLY=true forge script script/02_Libraries.s.sol --broadcast \
///     --rpc-url $RPC --libraries src/vault/VaultPlacementLib.sol:VaultPlacementLib:0x...
/// ```
///
///      Both passes are idempotent: a library whose deterministic address already holds code is skipped.
contract Libraries is Script {
    // -----------------------------------------------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The canonical deterministic-deployment proxy, the same CREATE2 sender `01_MineAmps` and
    ///         `04_MineHook` mine against. Recorded as **unverified** on 4663 in the plan's reference table:
    ///         {deployCore} asserts it has code before using it.
    address internal constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Where the four addresses, salts and init-code hashes are recorded.
    string internal constant CONFIG_PATH = "./script/config/libraries.json";

    /// @dev One salt per library, versioned so a recompilation that moves the bytecode does not silently reuse a
    ///      slot: the address is a function of the salt *and* the init code, so a new init code lands elsewhere on
    ///      its own. The version suffix exists for the case where a library must be redeployed at the same code.
    bytes32 internal constant SALT_NAV = keccak256("amplestocks.VaultNavLib.v1");
    bytes32 internal constant SALT_REDEEM = keccak256("amplestocks.VaultRedeemLib.v1");
    bytes32 internal constant SALT_PLACEMENT = keccak256("amplestocks.VaultPlacementLib.v1");
    bytes32 internal constant SALT_ROLLOUT = keccak256("amplestocks.VaultRolloutLib.v1");

    // -----------------------------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The four addresses, in deploy order.
    /// @param navLib `VaultNavLib` — the NAV read side (Phase 2).
    /// @param redeemLib `VaultRedeemLib` — redemption's position removal and the live-cell counter.
    /// @param placementLib `VaultPlacementLib` — the placement engine.
    /// @param rolloutLib `VaultRolloutLib` — rollout, bonded deployment and retired-bid withdrawal.
    struct LibrarySet {
        address navLib;
        address redeemLib;
        address placementLib;
        address rolloutLib;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The CREATE2 factory has no code on this chain.
    /// @param factory The address that was probed.
    error FactoryMissing(address factory);

    /// @notice The factory call reverted or returned something that is not an address.
    /// @param name The library being deployed.
    error DeployFailed(string name, bytes32 salt);

    /// @notice The deployment did not land on the deterministic address.
    /// @param name The library.
    error AddressMismatch(string name, address expected, address actual);

    /// @notice `VaultRolloutLib` was built against a different `VaultPlacementLib` than the one deployed here —
    ///         i.e. the `--libraries` flag was missing or wrong. Deploying it would leave every `rollout`,
    ///         `deployBonded` and `withdrawRetiredBids` call `DELEGATECALL`ing an address that is not ours.
    /// @param placementLib The address it should have been linked against.
    error UnlinkedRollout(address placementLib);

    // -----------------------------------------------------------------------------------------------------------
    // Entry points
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Deploys whichever pass `LIB_ROLLOUT_ONLY` selects and rewrites `script/config/libraries.json`.
    function run() external {
        address sender = vm.envOr("LIB_SENDER", address(0));
        bool rolloutOnly = vm.envOr("LIB_ROLLOUT_ONLY", false);

        LibrarySet memory set = predict();
        if (!rolloutOnly) {
            (set.navLib, set.redeemLib, set.placementLib) = deployCore(sender);
            console2.log("pass 1 complete. Re-run with:");
            console2.log("  LIB_ROLLOUT_ONLY=true --libraries %s", placementFlag(set.placementLib));
        } else {
            set.placementLib = vm.envOr("LIB_PLACEMENT", set.placementLib);
            set.rolloutLib = deployRollout(sender, set.placementLib);
        }

        _report(set);
        writeConfig(set);
    }

    /// @notice Deploys the three libraries that carry no library link references of their own, in order.
    /// @dev Idempotent: a deterministic address that already holds code is left alone.
    /// @param sender The deployer. `address(0)` means "use the default broadcast wallet".
    /// @return navLib `VaultNavLib`.
    /// @return redeemLib `VaultRedeemLib`.
    /// @return placementLib `VaultPlacementLib`.
    function deployCore(address sender) public returns (address navLib, address redeemLib, address placementLib) {
        if (FACTORY.code.length == 0) revert FactoryMissing(FACTORY);

        _begin(sender);
        navLib = _deploy("VaultNavLib", SALT_NAV, type(VaultNavLib).creationCode);
        redeemLib = _deploy("VaultRedeemLib", SALT_REDEEM, type(VaultRedeemLib).creationCode);
        placementLib = _deploy("VaultPlacementLib", SALT_PLACEMENT, type(VaultPlacementLib).creationCode);
        vm.stopBroadcast();
    }

    /// @notice Deploys `VaultRolloutLib` and proves it was linked against `placementLib`.
    /// @dev The proof is a scan of the deployed runtime code for the 20-byte address: a linked library call
    ///      compiles to a `PUSH20 <address>` followed by `DELEGATECALL`, so the address is literally in the code.
    ///      Without `--libraries` Foundry links the artefact against whatever `VaultPlacementLib` the current
    ///      build knows about — in `forge test`, its own auto-deployed copy — and this is what catches it.
    /// @param sender The deployer. `address(0)` means "use the default broadcast wallet".
    /// @param placementLib The `VaultPlacementLib` this rollout library must be bound to.
    /// @return rolloutLib `VaultRolloutLib`.
    function deployRollout(address sender, address placementLib) public returns (address rolloutLib) {
        if (FACTORY.code.length == 0) revert FactoryMissing(FACTORY);

        _begin(sender);
        rolloutLib = _deploy("VaultRolloutLib", SALT_ROLLOUT, type(VaultRolloutLib).creationCode);
        vm.stopBroadcast();

        if (!containsAddress(rolloutLib.code, placementLib)) revert UnlinkedRollout(placementLib);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The four deterministic addresses this script deploys to, whether or not anything is there yet.
    /// @return set The predicted addresses.
    function predict() public pure returns (LibrarySet memory set) {
        set = LibrarySet({
            navLib: predictAddress(SALT_NAV, keccak256(type(VaultNavLib).creationCode)),
            redeemLib: predictAddress(SALT_REDEEM, keccak256(type(VaultRedeemLib).creationCode)),
            placementLib: predictAddress(SALT_PLACEMENT, keccak256(type(VaultPlacementLib).creationCode)),
            rolloutLib: predictAddress(SALT_ROLLOUT, keccak256(type(VaultRolloutLib).creationCode))
        });
    }

    /// @notice The CREATE2 address for `salt` under {FACTORY}.
    /// @param salt The salt.
    /// @param initCodeHash `keccak256` of the creation code.
    /// @return predicted The address.
    function predictAddress(bytes32 salt, bytes32 initCodeHash) public pure returns (address predicted) {
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, salt, initCodeHash)))));
    }

    /// @notice The four init-code hashes, in deploy order. They move with solc, with the optimizer settings and —
    ///         for `VaultRolloutLib` — with the `VaultPlacementLib` address it is linked against.
    /// @return navHash `VaultNavLib`.
    /// @return redeemHash `VaultRedeemLib`.
    /// @return placementHash `VaultPlacementLib`.
    /// @return rolloutHash `VaultRolloutLib`.
    function initCodeHashes()
        public
        pure
        returns (bytes32 navHash, bytes32 redeemHash, bytes32 placementHash, bytes32 rolloutHash)
    {
        navHash = keccak256(type(VaultNavLib).creationCode);
        redeemHash = keccak256(type(VaultRedeemLib).creationCode);
        placementHash = keccak256(type(VaultPlacementLib).creationCode);
        rolloutHash = keccak256(type(VaultRolloutLib).creationCode);
    }

    /// @notice The whole `--libraries` argument list, exactly as `forge build --sizes`, `forge script` and
    ///         `forge verify-contract` need it.
    /// @param set The four addresses.
    /// @return flags The flags, space-separated.
    function librariesFlags(LibrarySet memory set) public pure returns (string memory flags) {
        flags = string.concat(
            "--libraries src/vault/VaultNavLib.sol:VaultNavLib:",
            vm.toString(set.navLib),
            " --libraries src/vault/VaultRedeemLib.sol:VaultRedeemLib:",
            vm.toString(set.redeemLib),
            " --libraries src/vault/VaultPlacementLib.sol:VaultPlacementLib:",
            vm.toString(set.placementLib),
            " --libraries src/vault/VaultRolloutLib.sol:VaultRolloutLib:",
            vm.toString(set.rolloutLib)
        );
    }

    /// @notice Just the `VaultPlacementLib` flag, which is the one `VaultRolloutLib`'s own build needs.
    /// @param placementLib The address.
    /// @return flag The flag.
    function placementFlag(address placementLib) public pure returns (string memory flag) {
        flag = string.concat("src/vault/VaultPlacementLib.sol:VaultPlacementLib:", vm.toString(placementLib));
    }

    /// @notice Asserts that `consumer`'s deployed code carries a `DELEGATECALL` target for every library in `set`,
    ///         i.e. that it really was linked against these four and not against a stale or foreign copy.
    /// @dev The post-deploy check the runbook runs against `AmpsVault`. A linked library call is `PUSH20 <lib>`
    ///      followed by `DELEGATECALL`, so the address is present verbatim in the runtime code; a placeholder or a
    ///      different address is not. It proves presence, not absence of others, which is all a link check can do.
    /// @param consumer The linked contract, normally `AmpsVault`.
    /// @param set The four library addresses.
    function assertLinked(address consumer, LibrarySet memory set) public view {
        bytes memory code = consumer.code;
        if (!containsAddress(code, set.navLib)) revert AddressMismatch("VaultNavLib", set.navLib, address(0));
        if (!containsAddress(code, set.redeemLib)) revert AddressMismatch("VaultRedeemLib", set.redeemLib, address(0));
        if (!containsAddress(code, set.placementLib)) {
            revert AddressMismatch("VaultPlacementLib", set.placementLib, address(0));
        }
        if (!containsAddress(code, set.rolloutLib)) {
            revert AddressMismatch("VaultRolloutLib", set.rolloutLib, address(0));
        }
    }

    /// @notice Whether `code` contains the 20 bytes of `needle` anywhere.
    /// @param code The runtime code to scan.
    /// @param needle The address to look for.
    /// @return found True when present.
    function containsAddress(bytes memory code, address needle) public pure returns (bool found) {
        if (needle == address(0) || code.length < 20) return false;
        bytes20 target = bytes20(needle);
        uint256 last = code.length - 20;
        for (uint256 i; i <= last; ++i) {
            bytes20 window;
            assembly ("memory-safe") {
                window := mload(add(add(code, 32), i))
            }
            if (window == target) return true;
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Rewrites `script/config/libraries.json` with the four addresses, their salts and init-code hashes.
    /// @param set The addresses to record.
    function writeConfig(LibrarySet memory set) public {
        (bytes32 navHash, bytes32 redeemHash, bytes32 placementHash, bytes32 rolloutHash) = initCodeHashes();

        string memory libs = "amplestocks.libraries.entries";
        vm.serializeString(libs, "VaultNavLib", _entry(set.navLib, SALT_NAV, navHash, "VaultNavLib"));
        vm.serializeString(libs, "VaultRedeemLib", _entry(set.redeemLib, SALT_REDEEM, redeemHash, "VaultRedeemLib"));
        vm.serializeString(
            libs, "VaultPlacementLib", _entry(set.placementLib, SALT_PLACEMENT, placementHash, "VaultPlacementLib")
        );
        string memory entries = vm.serializeString(
            libs, "VaultRolloutLib", _entry(set.rolloutLib, SALT_ROLLOUT, rolloutHash, "VaultRolloutLib")
        );

        string memory root = "amplestocks.libraries";
        vm.serializeString(
            root,
            "$comment",
            "Written by script/02_Libraries.s.sol. An address whose code length is zero is the deterministic "
            "CREATE2 prediction, not a deployment. Do NOT copy these into foundry.toml's `libraries` key: that "
            "would pin one chain's addresses into every build, forge test included."
        );
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "factory", FACTORY);
        vm.serializeString(root, "solc", "0.8.30");
        vm.serializeString(root, "profile", "src/vault/* at optimizer_runs = 200, via_ir = true");
        vm.serializeString(root, "deployOrder", "VaultNavLib, VaultRedeemLib, VaultPlacementLib, VaultRolloutLib");
        vm.serializeString(root, "libraries", entries);
        string memory json = vm.serializeString(root, "librariesFlag", librariesFlags(set));
        vm.writeJson(json, CONFIG_PATH);
        console2.log("wrote %s", CONFIG_PATH);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Opens the broadcast window. `address(0)` defers to the wallet Foundry was given.
    function _begin(address sender) private {
        if (sender == address(0)) vm.startBroadcast();
        else vm.startBroadcast(sender);
    }

    /// @dev CREATE2 through the factory, skipping an address that already holds code.
    function _deploy(string memory name, bytes32 salt, bytes memory initCode) private returns (address deployed) {
        address predicted = predictAddress(salt, keccak256(initCode));
        if (predicted.code.length != 0) {
            console2.log("%s already deployed at %s", name, predicted);
            return predicted;
        }

        (bool ok, bytes memory ret) = FACTORY.call(abi.encodePacked(salt, initCode));
        if (!ok || ret.length != 20) revert DeployFailed(name, salt);
        deployed = address(bytes20(ret));
        if (deployed != predicted) revert AddressMismatch(name, predicted, deployed);
        console2.log("%s deployed at %s", name, deployed);
    }

    /// @dev One library's JSON object.
    function _entry(address addr, bytes32 salt, bytes32 initCodeHash, string memory name)
        private
        returns (string memory json)
    {
        string memory obj = string.concat("amplestocks.libraries.", name);
        vm.serializeString(obj, "path", string.concat("src/vault/", name, ".sol:", name));
        vm.serializeAddress(obj, "address", addr);
        vm.serializeBytes32(obj, "salt", salt);
        json = vm.serializeBytes32(obj, "initCodeHash", initCodeHash);
    }

    /// @dev The console summary every run ends with.
    function _report(LibrarySet memory set) private pure {
        console2.log("VaultNavLib       %s", set.navLib);
        console2.log("VaultRedeemLib    %s", set.redeemLib);
        console2.log("VaultPlacementLib %s", set.placementLib);
        console2.log("VaultRolloutLib   %s", set.rolloutLib);
        console2.log("link flags: %s", librariesFlags(set));
    }
}
