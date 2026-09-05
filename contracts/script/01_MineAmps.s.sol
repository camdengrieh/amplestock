// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Amps} from "../src/token/Amps.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title MineAmps
/// @notice Prints the init code hash for `Amps(vault)` and verifies a mined CREATE2 salt.
/// @dev    AMPS must be `currency0` in every Amplestocks pool, so its address has to sort below WETH9
///         (`0x0Bd7...`) and every Robinhood Stock Token (lowest is SPY `0x117c...`). The token is therefore
///         deployed through the canonical deterministic-deployment proxy with a salt mined to three leading zero
///         bytes: `address < 0x0000010000000000000000000000000000000000`.
///
///         The proxy prepends nothing to the salt - the CREATE2 sender is the proxy itself and the salt is the
///         first 32 bytes of its calldata - so the prediction is the plain
///         `keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]`.
///
///         Mining itself is off-chain (`ffi` is off by design):
///           - `python3 script/mine-amps.py --vault <vault>`  (pure Python, multiprocess), or
///           - `cast create2 --starts-with 000000 --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C
///                  --init-code-hash <hash>`
///
///         Usage:
///           AMPS_VAULT=<vault> forge script script/01_MineAmps.s.sol            # print the init code hash
///           AMPS_VAULT=<vault> AMPS_SALT=<salt> forge script script/01_MineAmps.s.sol   # verify a salt
contract MineAmps is Script {
    /// @notice Canonical deterministic-deployment proxy (same address forge-std calls `CREATE2_FACTORY`).
    address internal constant DEPLOYMENT_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Stand-in used before `AmpsVault` exists; every mined salt is bound to the vault it was mined for.
    address internal constant PLACEHOLDER_VAULT = 0x000000000000000000000000000000000000dEaD;

    /// @notice Exclusive upper bound for a three-leading-zero-byte address.
    uint160 internal constant MAX_AMPS_ADDRESS = uint160(0x0000010000000000000000000000000000000000);

    error SaltTooWeak(bytes32 salt, address predicted);

    function run() external view {
        address vault = vm.envOr("AMPS_VAULT", PLACEHOLDER_VAULT);
        if (vault == PLACEHOLDER_VAULT) {
            console2.log("WARNING: vault is the dEaD placeholder; re-mine once the real AmpsVault address exists.");
        }

        bytes32 initCodeHash = ampsInitCodeHash(vault);
        console2.log("vault          %s", vault);
        console2.log("factory        %s", DEPLOYMENT_PROXY);
        console2.log("init code hash %s", vm.toString(initCodeHash));

        bytes32 salt = vm.envOr("AMPS_SALT", bytes32(0));
        if (salt == bytes32(0)) {
            console2.log("AMPS_SALT unset - mine one, then re-run to verify:");
            console2.log("  python3 script/mine-amps.py --vault %s", vault);
            console2.log(
                string.concat(
                    "  cast create2 --starts-with 000000 --deployer ",
                    vm.toString(DEPLOYMENT_PROXY),
                    " --init-code-hash ",
                    vm.toString(initCodeHash)
                )
            );
            return;
        }

        address predicted = predictAddress(initCodeHash, salt);
        if (!sortsFirst(predicted)) revert SaltTooWeak(salt, predicted);
        console2.log("salt           %s", vm.toString(salt));
        console2.log("address        %s", predicted);
        console2.log("leading zero bytes: 3 - AMPS sorts below WETH9 and every Stock Token");
        console2.log("deploy with: cast send %s $(cast concat-hex %s <initCode>)", DEPLOYMENT_PROXY, vm.toString(salt));
    }

    /// @notice `keccak256(type(Amps).creationCode ++ abi.encode(vault))` - what the miner grinds against.
    function ampsInitCodeHash(address vault) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(type(Amps).creationCode, abi.encode(vault)));
    }

    /// @notice CREATE2 address for `salt` under {DEPLOYMENT_PROXY}.
    function predictAddress(bytes32 initCodeHash, bytes32 salt) public pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYMENT_PROXY, salt, initCodeHash)))));
    }

    /// @notice True when `token` has three leading zero bytes, i.e. it is `currency0` against every counter-asset.
    function sortsFirst(address token) public pure returns (bool) {
        return uint160(token) < MAX_AMPS_ADDRESS;
    }
}
