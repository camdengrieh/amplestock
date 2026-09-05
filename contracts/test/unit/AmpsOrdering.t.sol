// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MineAmps} from "../../script/01_MineAmps.s.sol";
import {Amps} from "../../src/token/Amps.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Guards the reason AMPS is CREATE2-mined at all: it must be `currency0` in every Amplestocks pool, i.e.
///         its address must sort below WETH9, USDG and every Robinhood Stock Token the protocol can ever list.
///         `AmpsHook.beforeInitialize` hard-requires `currency0 == AMPS`, and the sign of every fee direction and
///         one-sided placement follows from it.
/// @dev    Reads the mined example produced by `script/mine-amps.py` and re-derives the CREATE2 address in Solidity,
///         so a stale, hand-edited or wrongly-derived record cannot survive CI.
contract AmpsOrderingTest is Test {
    using stdJson for string;

    string internal constant RECORD = "script/config/amps-mining-example.json";

    /// @dev Exclusive upper bound for three leading zero bytes.
    uint160 internal constant MAX_AMPS_ADDRESS = uint160(0x0000010000000000000000000000000000000000);

    address internal constant DEPLOYMENT_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant PLACEHOLDER_VAULT = 0x000000000000000000000000000000000000dEaD;

    MineAmps internal miner;

    address internal minedAddress;
    bytes32 internal salt;
    bytes32 internal initCodeHash;
    address internal recordedVault;

    function setUp() public {
        miner = new MineAmps();
        string memory json = vm.readFile(RECORD);
        minedAddress = json.readAddress(".predictedAddress");
        salt = json.readBytes32(".salt");
        initCodeHash = json.readBytes32(".initCodeHash");
        recordedVault = json.readAddress(".vault");

        assertEq(json.readAddress(".factory"), DEPLOYMENT_PROXY, "record must use the deterministic-deployment proxy");
        assertEq(json.readUint(".leadingZeroBytes"), 3, "the design requires three leading zero bytes");
        assertTrue(json.readBool(".vaultIsPlaceholder"), "example is mined against a placeholder vault");
        assertEq(recordedVault, PLACEHOLDER_VAULT, "placeholder vault");
    }

    /// @notice The mined address has three leading zero bytes.
    function test_minedAddressHasThreeLeadingZeroBytes() public view {
        assertLt(uint160(minedAddress), MAX_AMPS_ADDRESS, "three leading zero bytes");
        assertTrue(miner.sortsFirst(minedAddress), "script and test agree on the bound");
    }

    /// @notice AMPS sorts strictly below every counter-asset it will ever be paired against.
    function test_minedAddressSortsBelowEveryCounterAsset() public view {
        address[13] memory counterAssets = _counterAssets();
        string[13] memory names = _counterAssetNames();

        for (uint256 i; i < counterAssets.length; ++i) {
            assertLt(
                uint160(minedAddress),
                uint160(counterAssets[i]),
                string.concat("AMPS must be currency0 against ", names[i])
            );
            // sanity: the three-zero-byte bound is what makes the comparison unconditional
            assertGe(uint160(counterAssets[i]), MAX_AMPS_ADDRESS, string.concat("bound too weak for ", names[i]));
        }
    }

    /// @notice Recomputing CREATE2 in Solidity from the recorded salt and init code hash reproduces the address.
    function test_recomputedCreate2AddressMatches() public view {
        address recomputed =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYMENT_PROXY, salt, initCodeHash)))));
        assertEq(recomputed, minedAddress, "recomputed CREATE2 address");
        assertEq(miner.predictAddress(initCodeHash, salt), minedAddress, "script prediction");
    }

    /// @notice The recorded hash is the hash of the init code the current sources actually produce.
    /// @dev    A failure here means the salt is stale: re-run `python3 script/mine-amps.py` (any change to
    ///         `Amps.sol`, to the constructor argument or to the compiler settings moves the init code hash).
    function test_recordedInitCodeHashMatchesCurrentBytecode() public view {
        bytes32 computed = keccak256(abi.encodePacked(type(Amps).creationCode, abi.encode(recordedVault)));
        assertEq(computed, initCodeHash, "init code hash is stale - re-mine the salt");
        assertEq(miner.ampsInitCodeHash(recordedVault), initCodeHash, "script init code hash");
    }

    /* ------------------------------ reference data ---------------------------- */

    /// @dev WETH9, USDG and the eleven Stock Tokens verified on Robinhood Chain (plan: verified reference data).
    function _counterAssets() internal pure returns (address[13] memory) {
        return [
            0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, // WETH9
            0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, // USDG
            0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, // AAPL
            0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, // NVDA
            0x322F0929c4625eD5bAd873c95208D54E1c003b2d, // TSLA
            0xe93237C50D904957Cf27E7B1133b510C669c2e74, // MSFT
            0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, // GOOGL
            0x12f190a9F9d7D37a250758b26824B97CE941bF54, // AMZN
            0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, // META
            0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, // SPY
            0xD5f3879160bc7c32ebb4dC785F8a4F505888de68, // QQQ
            0x6330D8C3178a418788dF01a47479c0ce7CCF450b, // COIN
            0x1b0E319c6A659F002271B69dB8A7df2F911c153E // GME
        ];
    }

    function _counterAssetNames() internal pure returns (string[13] memory) {
        return
            [
                string("WETH9"),
                "USDG",
                "AAPL",
                "NVDA",
                "TSLA",
                "MSFT",
                "GOOGL",
                "AMZN",
                "META",
                "SPY",
                "QQQ",
                "COIN",
                "GME"
            ];
    }
}
