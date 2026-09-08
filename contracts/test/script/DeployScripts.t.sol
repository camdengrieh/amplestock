// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Preflight} from "../../script/00_Preflight.s.sol";
import {Core} from "../../script/03_Core.s.sol";
import {Phase3Wire} from "../../script/09_Phase3Wire.s.sol";
import {Verify} from "../../script/12_Verify.s.sol";
import {Calendar} from "../../script/lib/Calendar.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {Test} from "forge-std/Test.sol";

/// @title DeployScripts
/// @notice The parts of `00_Preflight`, `03_Core`, `12_Verify` and `script/lib/Calendar.sol` that can be proved
///         without a chain: the pre-flight's verdicts, the address arithmetic the whole deployment hangs off, the
///         constructor-argument and verification writers, and the two calendar tables.
///
/// @dev **What is deliberately not here: the timelock relay.** `Gov` picks its mode from `AMPS_GOV_RELAY` and
///      `AMPS_DEPLOYER`, and `vm.setEnv` mutates the *process* environment while `forge test` runs test contracts
///      in parallel — so a relay test in one file could flip the mode under `Phase3Scripts.t.sol` in another. The
///      relay is proved instead by `test/script/broadcast.sh`, which runs the whole pipeline through a real
///      `TimelockController` at zero delay against anvil and then checks the hand-over. That is a better proof
///      anyway: relay mode exists because a broadcast has to be *signed*, and a simulation never signs anything.
///
/// @dev **File writes are backed up and restored.** `writeConstructorArgs`, `writeReport`, `writeScript` and
///      `writeJson` rewrite committed artefacts under `script/config`, which is what `fs_permissions` grants the
///      scripts. Every test that calls one saves the file first and puts it back **before** any assertion runs,
///      so a failure cannot leave the tree dirty.
contract DeployScripts is Test {
    string internal constant DEPLOYMENTS_PATH = "./script/config/deployments.json";
    string internal constant ARGS_PATH = "./script/config/constructor-args.json";
    string internal constant REPORT_PATH = "./script/config/preflight-report.json";
    string internal constant VERIFY_SH_PATH = "./script/config/verify.sh";
    string internal constant VERIFICATION_PATH = "./script/config/verification.json";
    string internal constant PREFLIGHT_PATH = "./script/config/preflight.json";
    string internal constant LIBRARIES_PATH = "./script/config/libraries.json";

    /// @dev The canonical deterministic-deployment proxy every Amplestocks address is mined against.
    address internal constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    Core internal core;
    Preflight internal preflight;
    Verify internal verify;
    Phase3Wire internal wire;

    function setUp() public {
        core = new Core();
        preflight = new Preflight();
        verify = new Verify();
        wire = new Phase3Wire();
    }

    // -----------------------------------------------------------------------------------------------------------
    // script/lib/Calendar.sol
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The DST table is eight ascending windows, each start before its own end and before the next start.
    function test_calendar_dstWindowsAreOrdered() public pure {
        uint32[] memory starts = Calendar.dstStarts();
        uint32[] memory ends = Calendar.dstEnds();
        assertEq(starts.length, 8, "eight DST windows");
        assertEq(ends.length, starts.length, "one end per start");
        for (uint256 i; i < starts.length; ++i) {
            assertLt(starts[i], ends[i], "a window starts before it ends");
            if (i + 1 < starts.length) assertLt(ends[i], starts[i + 1], "windows do not overlap");
        }
    }

    /// @notice Ten NYSE full-day closures in 2026, each inside the year and none duplicated.
    function test_calendar_holidayBitmapHasTenDays() public pure {
        uint256[2] memory bitmap = Calendar.holidayBitmap();
        uint256 set;
        for (uint256 word; word < 2; ++word) {
            for (uint256 bit; bit < 256; ++bit) {
                if (bitmap[word] & (uint256(1) << bit) == 0) continue;
                ++set;
                assertLt(word * 256 + bit, 366, "a holiday inside the year");
            }
        }
        assertEq(set, 10, "ten full-day closures");
        assertEq(Calendar.HOLIDAY_YEAR, 2026, "the year the table covers");
    }

    /// @notice `09_Phase3Wire` installs the shared tables rather than a second copy of them: a redeployed gate and
    ///         a freshly deployed one must get the same calendar or the session logic differs between them.
    function test_calendar_phase3WireDelegatesToTheLibrary() public view {
        uint32[] memory starts = wire.dstStarts();
        uint32[] memory expected = Calendar.dstStarts();
        assertEq(starts.length, expected.length, "same length");
        for (uint256 i; i < starts.length; ++i) {
            assertEq(starts[i], expected[i], "same DST starts");
        }
        uint256[2] memory bitmap = wire.holidayBitmap2026();
        uint256[2] memory shared = Calendar.holidayBitmap();
        assertEq(bitmap[0], shared[0], "same bitmap word 0");
        assertEq(bitmap[1], shared[1], "same bitmap word 1");
    }

    // -----------------------------------------------------------------------------------------------------------
    // 03_Core — the address arithmetic the whole deployment hangs off
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The init-code hash is `keccak256(creationCode ++ abi.encode(vault))` and moves with the vault, which
    ///         is what binds a mined salt to one exact vault address.
    function test_core_ampsInitCodeHashIsBoundToTheVault() public view {
        address vaultA = address(0xA11CE);
        address vaultB = address(0xB0B);
        assertEq(
            core.ampsInitCodeHash(vaultA),
            keccak256(abi.encodePacked(type(Amps).creationCode, abi.encode(vaultA))),
            "the hash is over creationCode ++ abi.encode(vault)"
        );
        assertTrue(core.ampsInitCodeHash(vaultA) != core.ampsInitCodeHash(vaultB), "a different vault, a new hash");
    }

    /// @notice The CREATE2 prediction is the canonical one, under the deterministic-deployment proxy.
    function test_core_create2AddressMatchesTheCanonicalFormula() public view {
        bytes32 salt = keccak256("amplestocks.test");
        bytes32 initCodeHash = core.ampsInitCodeHash(address(0xA11CE));
        assertEq(
            core.create2Address(salt, initCodeHash),
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, salt, initCodeHash))))),
            "0xff ++ factory ++ salt ++ initCodeHash"
        );
    }

    /// @notice The in-script miner really does produce an address with the requested number of leading zero bytes,
    ///         and one that is out of the precompile range.
    /// @dev One byte, not three: this is the arithmetic under test, not the search. Production mines three
    ///      off-chain with `script/mine-amps.py` and passes the result in as `AMPS_SALT`.
    function test_core_minesASaltToTheRequestedStrength() public view {
        Core.Config memory cfg = _config(bytes32(0), 1);
        address vault = address(0xA11CE);
        bytes32 salt = core.ampsSalt(cfg, vault);
        address predicted = core.create2Address(salt, core.ampsInitCodeHash(vault));
        assertLt(uint160(predicted), uint160(1) << 152, "one leading zero byte");
        assertGt(uint160(predicted), 0xffff, "out of the precompile range");
    }

    /// @notice A supplied salt that does not reach the requested strength is refused rather than used. The failure
    ///         mode this prevents is a token that does not sort below every counter, which makes all 32 pool
    ///         registrations revert hours into a deployment.
    function test_core_refusesAWeakSuppliedSalt() public {
        address vault = address(0xA11CE);
        Core.Config memory cfg = _config(bytes32(uint256(1)), 3);
        address predicted = core.create2Address(bytes32(uint256(1)), core.ampsInitCodeHash(vault));
        vm.expectRevert(abi.encodeWithSelector(Core.WeakAmpsSalt.selector, bytes32(uint256(1)), predicted));
        core.ampsSalt(cfg, vault);
    }

    // -----------------------------------------------------------------------------------------------------------
    // The config files, in one test
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Everything that reads or writes `script/config/deployments.json`, in one test function because
    ///         they all share one file. `forge test` gives every test its own EVM but **not** its own working
    ///         tree, and a test that asserts something about the committed file cannot run beside one that
    ///         rewrites it. Split into five tests this was flaky; as one it is deterministic.
    ///
    ///         What it proves, in order:
    ///           1. direct mode with no timelock configured is refused — there would be nothing to broadcast *as*,
    ///              and a `TimelockController` cannot sign its own bootstrap;
    ///           2. the address book round-trips through `03_Core`, key for key, the newest key included;
    ///           3. `12_Verify` reads the same book — it has its own reader, because `Core` embeds every
    ///              contract's creation code and deploying one to call a `view` function would drag all of it
    ///              into `12_Verify`'s artefact;
    ///           4. every constructor argument is recorded ABI-encoded, exactly as
    ///              `forge verify-contract --constructor-args` takes it;
    ///           5. a contract that is not deployed yet is skipped rather than emitted with a zero address, so
    ///              the generated `verify.sh` is runnable part way through a deployment;
    ///           6. with nothing deployed at all, `12_Verify` says so instead of writing a file of zeros.
    ///
    /// @dev Every file is captured before it is written and put back **before** any assertion runs, so a failure
    ///      cannot leave the working tree dirty.
    function test_config_deploymentBookAndVerification() public {
        string memory beforeDeployments = vm.readFile(DEPLOYMENTS_PATH);
        string memory beforeArgs = vm.readFile(ARGS_PATH);
        string memory beforeVerification = vm.readFile(VERIFICATION_PATH);
        string memory beforeLibraries = vm.readFile(LIBRARIES_PATH);

        // 1 — the committed book carries a zero timelock, and AMPS_GOV_RELAY is unset by default.
        bool refusedDirect;
        try core.loadConfig() returns (Core.Config memory) {}
        catch {
            refusedDirect = true;
        }

        // 2, 3 — the round trip, through both readers.
        Core.Set memory set = _sampleSet();
        core.writeDeployments(set);
        Core.Set memory fromCore = core.readDeployments();
        Core.Set memory fromVerify = verify.readDeployments();
        string memory writtenDeployments = vm.readFile(DEPLOYMENTS_PATH);

        // 4 — the constructor arguments.
        core.writeConstructorArgs(set);
        string memory writtenArgs = vm.readFile(ARGS_PATH);

        // 5 — the quoter is not deployed yet, so it is not emitted.
        _writeLibraries();
        Core.Set memory withoutQuoter = _sampleSet();
        withoutQuoter.quoter = address(0);
        core.writeDeployments(withoutQuoter);
        Verify.Target[] memory targets = verify.buildTargets();
        verify.writeScript(targets);
        verify.writeJson(targets);
        string memory script = vm.readFile(VERIFY_SH_PATH);
        string memory verification = vm.readFile(VERIFICATION_PATH);

        // 6 — nothing deployed at all.
        Core.Set memory empty;
        core.writeDeployments(empty);
        bool refusedEmpty;
        try verify.buildTargets() returns (Verify.Target[] memory) {}
        catch {
            refusedEmpty = true;
        }

        vm.writeFile(DEPLOYMENTS_PATH, beforeDeployments);
        vm.writeFile(ARGS_PATH, beforeArgs);
        vm.writeFile(VERIFICATION_PATH, beforeVerification);
        vm.writeFile(LIBRARIES_PATH, beforeLibraries);
        vm.removeFile(VERIFY_SH_PATH);

        // ---- 1 ----
        assertTrue(refusedDirect, "direct mode with no timelock is refused");

        // ---- 2, 3 ----
        assertEq(fromCore.timelock, set.timelock, "timelock");
        assertEq(fromCore.amps, set.amps, "amps");
        assertEq(fromCore.vault, set.vault, "vault");
        assertEq(fromCore.hook, set.hook, "hook");
        assertEq(fromCore.registry, set.registry, "registry");
        assertEq(fromCore.oracleGate, set.oracleGate, "oracleGate");
        assertEq(fromCore.quoter, set.quoter, "quoter");
        assertEq(fromCore.usdg, set.usdg, "usdg");
        assertEq(keccak256(abi.encode(fromVerify)), keccak256(abi.encode(fromCore)), "the two readers agree");
        assertEq(
            vm.parseJsonString(writtenDeployments, ".envOverrides.quoter"),
            "AMPS_QUOTER",
            "the env map survives a write"
        );

        // ---- 4 ----
        assertEq(vm.parseJsonString(writtenArgs, ".contracts[0].name"), "Amps", "Amps is first");
        assertEq(vm.parseJsonBytes(writtenArgs, ".contracts[0].args"), abi.encode(set.vault), "Amps takes the vault");
        assertEq(
            vm.parseJsonBytes(writtenArgs, ".contracts[1].args"),
            abi.encode(set.amps, set.poolManager, set.timelock, set.guardian),
            "AmpsVault takes amps, poolManager, timelock, guardian"
        );
        assertEq(vm.parseJsonBytes(writtenArgs, ".contracts[6].args").length, 0, "BondPolicy takes nothing");

        // ---- 5 ----
        bool sawQuoter;
        bool sawVault;
        for (uint256 i; i < targets.length; ++i) {
            if (keccak256(bytes(targets[i].name)) == keccak256("AmpsQuoter")) sawQuoter = true;
            if (keccak256(bytes(targets[i].name)) == keccak256("AmpsVault")) sawVault = true;
            assertTrue(targets[i].deployed != address(0), "no target carries a zero address");
        }
        assertFalse(sawQuoter, "the undeployed quoter is skipped");
        assertTrue(sawVault, "the vault is emitted");
        assertTrue(_contains(script, "#!/usr/bin/env bash"), "verify.sh is a shell script");
        assertTrue(_contains(script, "set -euo pipefail"), "...that stops on the first failure");
        assertTrue(
            _contains(script, "--libraries src/vault/VaultNavLib.sol:VaultNavLib:"),
            "the linked vault carries its four library flags"
        );
        assertEq(vm.parseJsonUint(verification, ".chainId"), block.chainid, "verification.json records the chain");

        // ---- 6 ----
        assertTrue(refusedEmpty, "buildTargets refuses an empty deployment");
    }

    // -----------------------------------------------------------------------------------------------------------
    // 12_Verify
    // -----------------------------------------------------------------------------------------------------------

    /// @notice One command carries the verifier, the chain, the compiler, the constructor args and — for the vault
    ///         — the four `--libraries` flags a linked `DELEGATECALL` target makes part of the code.
    function test_verify_commandCarriesEverythingBlockscoutNeeds() public view {
        Verify.Target memory target = Verify.Target({
            name: "AmpsVault",
            path: "src/vault/AmpsVault.sol:AmpsVault",
            deployed: address(0x7A017),
            args: abi.encode(address(1), address(2), address(3), address(4)),
            libraryFlags: "--libraries src/vault/VaultNavLib.sol:VaultNavLib:0x0000000000000000000000000000000000000001"
        });
        string memory line = verify.command(target);
        assertTrue(_contains(line, "forge verify-contract --verifier blockscout"), "the verifier");
        assertTrue(_contains(line, "https://robinhoodchain.blockscout.com/api/"), "the verifier url");
        assertTrue(_contains(line, "--compiler-version 0.8.30"), "the compiler");
        assertTrue(_contains(line, "--libraries src/vault/VaultNavLib.sol:VaultNavLib:"), "the library flags");
        assertTrue(_contains(line, "--constructor-args 0x"), "the constructor args");
        assertTrue(_contains(line, "src/vault/AmpsVault.sol:AmpsVault"), "the artefact path");
    }

    // -----------------------------------------------------------------------------------------------------------
    // 00_Preflight
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Every verdict the pre-flight can produce, on a local chain where nothing it looks for exists: the
    ///         chain id is wrong (`FAIL`), the required infrastructure has no code (`FAIL`), the optional pieces
    ///         have none either (`WARN`), and the Arbitrum precompiles are absent (`SKIP`).
    function test_preflight_verdictsOnABareChain() public {
        string memory cfg = vm.readFile(PREFLIGHT_PATH);
        preflight.checkChain(cfg);
        preflight.checkPrecompiles(cfg);
        preflight.checkInfrastructure(cfg);
        preflight.checkPoolManagerCode(cfg);

        Preflight.Finding[] memory findings = preflight.findings();
        assertEq(findings[0].what, "chainId", "the chain is checked first");
        assertTrue(findings[0].level == Preflight.Level.FAIL, "31337 is not 4663");

        (uint256 failures, uint256 warnings) = preflight.summarise();
        assertGe(failures, 4, "the chain id and the three required addresses fail");
        assertGt(warnings, 0, "the optional addresses warn");
        assertTrue(_hasFinding(findings, "create2Factory"), "the CREATE2 factory is probed by name");
        assertTrue(_hasFinding(findings, "arbOSVersion"), "ArbOS is probed");
        assertTrue(_hasFinding(findings, "maxTxGasLimit"), "the per-transaction gas ceiling is probed");
    }

    /// @notice The PoolManager code hash reports `TODO` while `preflight.json` carries no pinned hash, and the
    ///         address it probes is found by name rather than by position in the array.
    function test_preflight_poolManagerHashIsTodoUntilItIsPinned() public {
        string memory cfg = vm.readFile(PREFLIGHT_PATH);
        assertEq(
            preflight.infrastructureAddress(cfg, "poolManager"),
            vm.parseJsonAddress(cfg, ".infrastructure[0].address"),
            "found by name"
        );
        assertEq(preflight.infrastructureAddress(cfg, "nothing"), address(0), "an unknown name is zero");

        // With no code at the address the hash cannot be measured at all, so the verdict is SKIP; once there is
        // code and no pinned hash it is TODO. Both are non-failures on purpose.
        preflight.checkPoolManagerCode(cfg);
        Preflight.Finding[] memory findings = preflight.findings();
        assertTrue(findings[0].level == Preflight.Level.SKIP, "no code, nothing to hash");

        vm.etch(preflight.infrastructureAddress(cfg, "poolManager"), hex"600160005500");
        preflight.checkPoolManagerCode(cfg);
        findings = preflight.findings();
        assertTrue(findings[1].level == Preflight.Level.TODO, "code but no pinned hash");
    }

    /// @notice A constituent whose token or feed is still a Phase 0 placeholder is `TODO`, not `FAIL` — the
    ///         address is Phase 0's job to fill in, and `05_Registry` refuses the name until it is.
    function test_preflight_placeholderConstituentsAreTodo() public {
        preflight.checkConstituents();
        Preflight.Finding[] memory findings = preflight.findings();
        uint256 todos;
        for (uint256 i; i < findings.length; ++i) {
            if (findings[i].level == Preflight.Level.TODO) ++todos;
        }
        assertGt(todos, 20, "the unfilled tokens and feeds are TODO");
    }

    /// @notice The report is written whatever the verdicts are, so a failing pre-flight still leaves the evidence.
    function test_preflight_writesTheReport() public {
        string memory before = vm.readFile(REPORT_PATH);
        string memory cfg = vm.readFile(PREFLIGHT_PATH);

        preflight.checkChain(cfg);
        (uint256 failures, uint256 warnings) = preflight.summarise();
        preflight.writeReport(failures, warnings);
        string memory written = vm.readFile(REPORT_PATH);
        vm.writeFile(REPORT_PATH, before);

        assertEq(vm.parseJsonUint(written, ".checks"), 1, "one check ran");
        assertEq(vm.parseJsonUint(written, ".failures"), failures, "the failure count is recorded");
        assertEq(vm.parseJsonString(written, ".findings[0].check"), "chainId", "the finding is recorded");
        assertEq(vm.parseJsonString(written, ".findings[0].level"), "FAIL", "with its verdict");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------

    /// @dev A `Config` that needs no environment and no chain.
    function _config(bytes32 salt, uint8 zeroBytes) private pure returns (Core.Config memory cfg) {
        cfg.deployer = address(0xDEB10);
        cfg.guardian = address(0x6A4D);
        cfg.creator = address(0xC12E);
        cfg.teamBeneficiary = address(0x7EA1);
        cfg.poolManager = address(0x9004);
        cfg.weth9 = address(0x9E70);
        cfg.usdg = address(0x05D6);
        cfg.ampsSalt = salt;
        cfg.ampsZeroBytes = zeroBytes;
    }

    /// @dev A fully populated address book, with a distinct address per field so a mix-up is visible.
    function _sampleSet() private pure returns (Core.Set memory set) {
        set = Core.Set({
            timelock: address(0x71E10C4),
            guardian: address(0x6A4D1A17),
            creator: address(0xC12EA704),
            teamVestingWallet: address(0x7E511),
            poolManager: address(0x9001),
            amps: address(0x0000A115),
            vault: address(0x7A017),
            registry: address(0x5E915),
            hook: address(0x38C0),
            bonds: address(0xB011D5),
            bountyPot: address(0xB0117),
            feedRegistry: address(0xFEED),
            oracleGate: address(0x6A7E),
            positionValuer: address(0xA1E5),
            ladderPolicy: address(0x1ADDE5),
            rolloutPolicy: address(0x5011),
            feePolicy: address(0xFEE),
            bondPolicy: address(0xB0D),
            quoter: address(0x9407E5),
            weth9: address(0x9E7),
            usdg: address(0x05D9)
        });
    }

    /// @dev Patches `libraries.json` with four distinct non-zero addresses, so the `--libraries` flags the
    ///      generated commands carry are real ones. Targeted key writes, as `02_Libraries` would leave them.
    function _writeLibraries() private {
        vm.writeJson(vm.toString(address(0x11B1)), LIBRARIES_PATH, ".libraries.VaultNavLib.address");
        vm.writeJson(vm.toString(address(0x11B2)), LIBRARIES_PATH, ".libraries.VaultRedeemLib.address");
        vm.writeJson(vm.toString(address(0x11B3)), LIBRARIES_PATH, ".libraries.VaultPlacementLib.address");
        vm.writeJson(vm.toString(address(0x11B4)), LIBRARIES_PATH, ".libraries.VaultRolloutLib.address");
    }

    function _hasFinding(Preflight.Finding[] memory findings, string memory what) private pure returns (bool) {
        for (uint256 i; i < findings.length; ++i) {
            if (keccak256(bytes(findings[i].what)) == keccak256(bytes(what))) return true;
        }
        return false;
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || h.length < n.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool hit = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
