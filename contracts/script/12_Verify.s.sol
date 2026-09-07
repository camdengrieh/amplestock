// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../src/types/Constants.sol";
import {Core} from "./03_Core.s.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/// @title Verify
/// @notice Turns a finished deployment into the exact `forge verify-contract` command line for every contract in
///         it, and writes them to `script/config/verify.sh`.
///
/// @dev **Why this is a script and not a paragraph.** Blockscout matches a submission against the *creation*
///         code, so a verification fails when the constructor-argument blob is wrong — and every Amplestocks
///         constructor takes between one and seven addresses that only exist after the deployment. Re-typing them
///         from a terminal scrollback hours later is how verifications get abandoned. This reads
///         `script/config/deployments.json` and `script/config/libraries.json`, re-encodes every argument from the
///         same code `03_Core` deployed with, and emits a file that can be run.
///
/// @dev **Three things the command line has to carry.**
///      1. `--constructor-args`, the ABI-encoded blob. Empty for the pure policies and the four libraries.
///      2. `--libraries`, four flags, for `AmpsVault` — it reaches all four libraries by `DELEGATECALL`, so its
///         creation code contains their addresses and a verifier given different ones produces different code.
///         `VaultRolloutLib` needs the `VaultPlacementLib` flag for the same reason.
///      3. The compiler profile. `src/vault/*`, `src/bonds/*` and `src/hook/*` build at `optimizer_runs = 200`
///         through the IR pipeline and everything else at 1,000,000 through the legacy one
///         (`foundry.toml`); `forge verify-contract` reads that from the project, which is why the commands are
///         run from `contracts/` and not pasted into a web form.
///
/// @dev **It broadcasts nothing and needs no key.** Verification is a POST to the explorer; the chain is not
///      touched. Run it whenever, and re-run it after `09_Phase3Wire` redeploys the gate.
///
/// @dev **Usage.**
/// ```
///   forge script script/12_Verify.s.sol                 # writes script/config/verify.sh
///   ETHERSCAN_API_KEY= bash script/config/verify.sh     # Blockscout needs no key
/// ```
contract Verify is Script {
    using stdJson for string;

    // -----------------------------------------------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The deployment's address book.
    string internal constant DEPLOYMENTS_PATH = "./script/config/deployments.json";

    /// @notice The four linked vault libraries.
    string internal constant LIBRARIES_PATH = "./script/config/libraries.json";

    /// @notice The generated command file.
    string internal constant VERIFY_PATH = "./script/config/verify.sh";

    /// @notice The machine-readable form of the same thing.
    string internal constant VERIFICATION_PATH = "./script/config/verification.json";

    /// @notice Blockscout's API root on Robinhood Chain mainnet.
    string internal constant VERIFIER_URL_DEFAULT = "https://robinhoodchain.blockscout.com/api/";

    /// @notice The compiler every artefact is built with.
    string internal constant SOLC = "0.8.30";

    // -----------------------------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The four linked vault libraries, as `02_Libraries` recorded them.
    /// @param navLib `VaultNavLib`.
    /// @param redeemLib `VaultRedeemLib`.
    /// @param placementLib `VaultPlacementLib`.
    /// @param rolloutLib `VaultRolloutLib`.
    struct LibrarySet {
        address navLib;
        address redeemLib;
        address placementLib;
        address rolloutLib;
    }

    /// @notice One contract to verify.
    /// @param name The contract name.
    /// @param path `<source path>:<contract name>`, as `forge verify-contract` takes it.
    /// @param deployed Its address.
    /// @param args The ABI-encoded constructor arguments, empty when there are none.
    /// @param libraryFlags The `--libraries` flags this artefact needs, empty when it needs none.
    struct Target {
        string name;
        string path;
        address deployed;
        bytes args;
        string libraryFlags;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Nothing is deployed yet, so there is nothing to verify.
    error NothingDeployed();

    // -----------------------------------------------------------------------------------------------------------
    // Entry point
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Builds the command list and writes `script/config/verify.sh` and `verification.json`.
    function run() external {
        Target[] memory targets = buildTargets();
        writeScript(targets);
        writeJson(targets);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Targets
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Every deployed contract, with its constructor arguments re-encoded from `deployments.json`.
    /// @dev A contract whose address is still zero is skipped rather than emitted with a placeholder, so the
    ///      generated file is runnable at any point in a partially finished deployment.
    /// @return targets The list, in deployment order.
    function buildTargets() public view returns (Target[] memory targets) {
        Core.Set memory set = readDeployments();
        if (set.vault == address(0) && set.amps == address(0)) revert NothingDeployed();

        LibrarySet memory libs = _libraries();
        string memory vaultFlags = _libraryFlags(libs);
        string memory rolloutFlags = libs.placementLib == address(0)
            ? ""
            : string.concat(
                "--libraries src/vault/VaultPlacementLib.sol:VaultPlacementLib:", vm.toString(libs.placementLib)
            );

        Target[] memory buffer = new Target[](20);
        uint256 n;

        n = _add(buffer, n, "VaultNavLib", "src/vault/VaultNavLib.sol:VaultNavLib", libs.navLib, "", "");
        n = _add(buffer, n, "VaultRedeemLib", "src/vault/VaultRedeemLib.sol:VaultRedeemLib", libs.redeemLib, "", "");
        n = _add(
            buffer,
            n,
            "VaultPlacementLib",
            "src/vault/VaultPlacementLib.sol:VaultPlacementLib",
            libs.placementLib,
            "",
            ""
        );
        n = _add(
            buffer,
            n,
            "VaultRolloutLib",
            "src/vault/VaultRolloutLib.sol:VaultRolloutLib",
            libs.rolloutLib,
            "",
            rolloutFlags
        );
        n = _add(buffer, n, "Amps", "src/token/Amps.sol:Amps", set.amps, abi.encode(set.vault), "");
        n = _add(
            buffer,
            n,
            "AmpsVault",
            "src/vault/AmpsVault.sol:AmpsVault",
            set.vault,
            abi.encode(set.amps, set.poolManager, set.timelock, set.guardian),
            vaultFlags
        );
        n = _add(
            buffer,
            n,
            "AmpsHook",
            "src/hook/AmpsHook.sol:AmpsHook",
            set.hook,
            abi.encode(set.poolManager, set.amps, set.vault, set.registry, set.timelock),
            ""
        );
        n = _add(
            buffer,
            n,
            "PoolRegistry",
            "src/registry/PoolRegistry.sol:PoolRegistry",
            set.registry,
            abi.encode(set.vault, set.hook, set.timelock, set.amps, set.weth9, set.usdg),
            ""
        );
        n = _addPeriphery(buffer, n, set);
        n = _addPolicies(buffer, n, set);

        targets = new Target[](n);
        for (uint256 i; i < n; ++i) {
            targets[i] = buffer[i];
        }
    }

    /// @dev The oracle layer, bonds, staking, the pot, the valuer and the quoter.
    function _addPeriphery(Target[] memory buffer, uint256 n, Core.Set memory set) private pure returns (uint256) {
        n = _add(
            buffer,
            n,
            "FeedRegistry",
            "src/oracle/FeedRegistry.sol:FeedRegistry",
            set.feedRegistry,
            abi.encode(set.timelock, address(0)),
            ""
        );
        n = _add(
            buffer,
            n,
            "OracleGate",
            "src/oracle/OracleGate.sol:OracleGate",
            set.oracleGate,
            abi.encode(set.timelock, set.guardian, set.feedRegistry, set.registry, set.hook),
            ""
        );
        n = _add(
            buffer,
            n,
            "AmpsBonds",
            "src/bonds/AmpsBonds.sol:AmpsBonds",
            set.bonds,
            abi.encode(set.vault, set.registry, set.bondPolicy),
            ""
        );
        n = _add(
            buffer,
            n,
            "AmpsStaking",
            "src/staking/AmpsStaking.sol:AmpsStaking",
            set.staking,
            abi.encode(set.amps, set.vault, set.timelock),
            ""
        );
        n = _add(
            buffer,
            n,
            "BountyPot",
            "src/keeper/BountyPot.sol:BountyPot",
            set.bountyPot,
            abi.encode(set.usdg, set.vault, set.timelock),
            ""
        );
        n = _add(
            buffer,
            n,
            "LadderPositionValuer",
            "src/valuer/LadderPositionValuer.sol:LadderPositionValuer",
            set.positionValuer,
            abi.encode(set.poolManager, set.vault, set.registry),
            ""
        );
        n = _add(
            buffer,
            n,
            "AmpsQuoter",
            "src/periphery/AmpsQuoter.sol:AmpsQuoter",
            set.quoter,
            abi.encode(set.poolManager, set.hook, set.vault, set.registry, set.bonds, set.oracleGate, set.feedRegistry),
            ""
        );
        return n;
    }

    /// @dev The four pointer-upgradeable policies. Three take no arguments; `FeePolicy` takes the four dynamic-fee
    ///      coefficients, which are `Constants` values rather than addresses and so are re-read from the source of
    ///      truth rather than from the deployment record.
    function _addPolicies(Target[] memory buffer, uint256 n, Core.Set memory set) private pure returns (uint256) {
        n = _add(buffer, n, "LadderPolicy", "src/policy/LadderPolicy.sol:LadderPolicy", set.ladderPolicy, "", "");
        n = _add(buffer, n, "RolloutPolicy", "src/policy/RolloutPolicy.sol:RolloutPolicy", set.rolloutPolicy, "", "");
        n = _add(buffer, n, "BondPolicy", "src/policy/BondPolicy.sol:BondPolicy", set.bondPolicy, "", "");
        n = _add(
            buffer,
            n,
            "FeePolicy",
            "src/policy/FeePolicy.sol:FeePolicy",
            set.feePolicy,
            abi.encode(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18),
            ""
        );
        return n;
    }

    /// @notice The deployment's address book, read straight out of `script/config/deployments.json`.
    /// @dev Read here rather than through a `Core` instance: `Core` embeds the creation code of every contract in
    ///      the system, and deploying one just to call a `view` function would put all of it into this script's
    ///      own artefact. The two readers must stay in step; `test/script/DeployScripts.t.sol` asserts they do.
    /// @return set The addresses.
    function readDeployments() public view returns (Core.Set memory set) {
        string memory json = vm.readFile(DEPLOYMENTS_PATH);
        set.timelock = _address(json, ".core.timelock", "AMPS_TIMELOCK");
        set.guardian = _address(json, ".core.guardian", "AMPS_GUARDIAN");
        set.creator = _address(json, ".core.creator", "AMPS_CREATOR");
        set.teamVestingWallet = _address(json, ".core.teamVestingWallet", "AMPS_TEAM_VESTING");
        set.poolManager = _address(json, ".core.poolManager", "AMPS_POOL_MANAGER");
        set.amps = _address(json, ".core.amps", "AMPS_TOKEN");
        set.vault = _address(json, ".core.vault", "AMPS_VAULT");
        set.registry = _address(json, ".core.registry", "AMPS_REGISTRY");
        set.hook = _address(json, ".core.hook", "AMPS_HOOK");
        set.bonds = _address(json, ".core.bonds", "AMPS_BONDS");
        set.staking = _address(json, ".core.staking", "AMPS_STAKING");
        set.bountyPot = _address(json, ".core.bountyPot", "AMPS_BOUNTY_POT");
        set.feedRegistry = _address(json, ".core.feedRegistry", "AMPS_FEED_REGISTRY");
        set.oracleGate = _address(json, ".core.oracleGate", "AMPS_ORACLE_GATE");
        set.positionValuer = _address(json, ".core.positionValuer", "AMPS_POSITION_VALUER");
        set.ladderPolicy = _address(json, ".core.ladderPolicy", "AMPS_LADDER_POLICY");
        set.rolloutPolicy = _address(json, ".core.rolloutPolicy", "AMPS_ROLLOUT_POLICY");
        set.feePolicy = _address(json, ".core.feePolicy", "AMPS_FEE_POLICY");
        set.bondPolicy = _address(json, ".core.bondPolicy", "AMPS_BOND_POLICY");
        set.quoter = _address(json, ".core.quoter", "AMPS_QUOTER");
        set.weth9 = _address(json, ".core.weth9", "AMPS_WETH9");
        set.usdg = _address(json, ".core.usdg", "AMPS_USDG");
    }

    /// @dev An address from the config, overridden by `envName` when that variable is set.
    function _address(string memory json, string memory path, string memory envName)
        private
        view
        returns (address value)
    {
        value = vm.envOr(envName, json.readAddress(path));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Output
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The command for one target, exactly as it must be run from `contracts/`.
    /// @param target The contract.
    /// @return line The command.
    function command(Target memory target) public view returns (string memory line) {
        line = string.concat(
            "forge verify-contract --verifier blockscout --verifier-url ",
            vm.envOr("AMPS_VERIFIER_URL", VERIFIER_URL_DEFAULT),
            " --chain-id ",
            vm.toString(block.chainid),
            " --compiler-version ",
            SOLC
        );
        if (bytes(target.libraryFlags).length != 0) line = string.concat(line, " ", target.libraryFlags);
        if (target.args.length != 0) line = string.concat(line, " --constructor-args ", vm.toString(target.args));
        line = string.concat(line, " ", vm.toString(target.deployed), " ", target.path);
    }

    /// @notice Writes `script/config/verify.sh`.
    /// @param targets The contracts to verify.
    function writeScript(Target[] memory targets) public {
        string memory out = string.concat(
            "#!/usr/bin/env bash\n",
            "# SPDX-License-Identifier: MIT\n",
            "# Generated by script/12_Verify.s.sol. Run from contracts/. Blockscout needs no API key.\n",
            "# Chain ",
            vm.toString(block.chainid),
            ", solc ",
            SOLC,
            ", ",
            vm.toString(targets.length),
            " contracts.\n",
            "set -euo pipefail\n",
            "cd \"$(dirname \"$0\")/../..\"\n\n"
        );
        for (uint256 i; i < targets.length; ++i) {
            out = string.concat(out, "echo '== ", targets[i].name, "'\n", command(targets[i]), "\n\n");
            console2.log(command(targets[i]));
        }
        vm.writeFile(VERIFY_PATH, out);
        console2.log("wrote %s (%s contracts)", VERIFY_PATH, targets.length);
    }

    /// @notice Writes the same thing as JSON, for an operator that wants to verify one contract by hand.
    /// @param targets The contracts.
    function writeJson(Target[] memory targets) public {
        string[] memory items = new string[](targets.length);
        for (uint256 i; i < targets.length; ++i) {
            string memory obj = string.concat("amplestocks.verify.", vm.toString(i));
            vm.serializeString(obj, "name", targets[i].name);
            vm.serializeString(obj, "path", targets[i].path);
            vm.serializeAddress(obj, "address", targets[i].deployed);
            vm.serializeString(obj, "libraryFlags", targets[i].libraryFlags);
            vm.serializeString(obj, "command", command(targets[i]));
            items[i] = vm.serializeBytes(obj, "constructorArgs", targets[i].args);
        }

        string memory root = "amplestocks.verify";
        vm.serializeString(
            root,
            "$comment",
            "Written by script/12_Verify.s.sol from deployments.json and libraries.json. `constructorArgs` is the "
            "ABI-encoded blob Blockscout matches the creation code against; AmpsVault and VaultRolloutLib also "
            "need their --libraries flags, because a linked DELEGATECALL target is part of the code."
        );
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "solc", SOLC);
        vm.serializeString(root, "verifierUrl", vm.envOr("AMPS_VERIFIER_URL", VERIFIER_URL_DEFAULT));
        string memory json = vm.serializeString(root, "contracts", items);
        vm.writeJson(json, VERIFICATION_PATH);
        console2.log("wrote %s", VERIFICATION_PATH);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Appends a target, skipping one that has not been deployed.
    function _add(
        Target[] memory buffer,
        uint256 n,
        string memory name,
        string memory path,
        address deployed,
        bytes memory args,
        string memory libraryFlags
    ) private pure returns (uint256) {
        if (deployed == address(0)) return n;
        buffer[n] = Target({name: name, path: path, deployed: deployed, args: args, libraryFlags: libraryFlags});
        return n + 1;
    }

    /// @dev The four library addresses, from `script/config/libraries.json` alone. Zero when `02_Libraries` has
    ///      not run on this chain, in which case the four library entries are skipped and `AmpsVault` is emitted
    ///      without `--libraries` — deliberately, because a linked vault cannot be verified against addresses
    ///      nobody recorded, and a command with zero addresses in it would fail in a way that looks like a
    ///      compiler problem.
    function _libraries() private view returns (LibrarySet memory set) {
        string memory json = vm.readFile(LIBRARIES_PATH);
        set = LibrarySet({
            navLib: json.readAddress(".libraries.VaultNavLib.address"),
            redeemLib: json.readAddress(".libraries.VaultRedeemLib.address"),
            placementLib: json.readAddress(".libraries.VaultPlacementLib.address"),
            rolloutLib: json.readAddress(".libraries.VaultRolloutLib.address")
        });
    }

    /// @dev The four `--libraries` flags `AmpsVault`'s creation code depends on, or an empty string when the
    ///      addresses are not recorded yet.
    function _libraryFlags(LibrarySet memory set) private pure returns (string memory flags) {
        if (set.navLib == address(0)) return "";
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
}
