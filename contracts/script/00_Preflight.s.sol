// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TransientProbeRunner} from "./lib/TransientProbe.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/// @title Preflight
/// @notice Phase 0's on-chain pre-flight, as far as a script can take it: it reads the chain and reports. It
///         deploys nothing, sends nothing and changes nothing — every probe is a `STATICCALL` or an `eth_call`.
///
///         What it checks, against `script/config/preflight.json`, `script/config/constituents.json` and
///         `script/config/deployments.json`:
///
///         | # | Check | Plan reference |
///         |---|---|---|
///         | 1 | `block.chainid` is the chain the config was written for | Phase 0 §3, `cast chain-id` |
///         | 2 | `ArbSys.arbOSVersion()` — 61 means EIP-7702 is live (so `tx.origin` guards are worthless) and Cancun/EIP-1153 is available | Phase 0 §3 |
///         | 3 | `ArbGasInfo.getGasAccountingParams()` — the third return value is `maxTxGasLimit`, which bounds one deployment and one 32-pool `checkpoint()` | Phase 0 §3 |
///         | 4 | `eth_getCode` is non-empty on every configured infrastructure address, the **CREATE2 factory included** | Phase 0 §3 |
///         | 5 | `keccak256(code(PoolManager))` against the hash pinned in `preflight.json` | Phase 0 §3, v4-core 1.0.2 |
///         | 6 | TSTORE/TLOAD are accepted, via {TransientProbe} as a `to`-less `eth_call` | Phase 0 §3 |
///         | 7 | every constituent's Stock Token and Chainlink feed has code | Phase 0 §5, §6 |
///         | 8 | every feed answers `latestRoundData()` with a positive answer inside its heartbeat, at 8 decimals | Phase 0 §6 |
///         | 9 | every feed has the Chainlink **Standard** proxy shape (`aggregator()` + `phaseId()`), and is flagged when its description or `typeAndVersion` names SVR | Phase 0 §6, `FeedRegistry.setStandardProxy` |
///         | 10 | the mined AMPS address, if one is recorded, sorts below WETH9 and every counter asset | Phase 0 §4, invariant I1 |
///         | 11 | which `deployments.json` addresses already hold code, i.e. what a re-run would skip | — |
///
/// @dev **Verdicts, not opinions.** Every check produces one of `PASS`, `WARN`, `FAIL`, `TODO` or `SKIP`.
///      `TODO` is a Phase 0 placeholder (a zero address in the config); `SKIP` is a probe this chain does not
///      expose (the Arbitrum precompiles on a bare anvil, for instance); `WARN` is a finding that does not stop a
///      deployment. The run reverts on any `FAIL` unless `PREFLIGHT_STRICT=false`, and always writes the whole
///      report to `script/config/preflight-report.json` first, so a failing run still leaves the evidence.
///
/// @dev **Usage.**
/// ```
///   forge script script/00_Preflight.s.sol --rpc-url $RPC              # report, revert on FAIL
///   PREFLIGHT_STRICT=false forge script script/00_Preflight.s.sol --rpc-url $RPC   # report only
/// ```
///      No `--broadcast`, ever: there is nothing to broadcast.
contract Preflight is Script {
    using stdJson for string;

    // -----------------------------------------------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The chain reference data this script probes.
    string internal constant PREFLIGHT_PATH = "./script/config/preflight.json";

    /// @notice The launch constituent set.
    string internal constant CONSTITUENTS_PATH = "./script/config/constituents.json";

    /// @notice The deployment's own addresses.
    string internal constant DEPLOYMENTS_PATH = "./script/config/deployments.json";

    /// @notice Where the report is written.
    string internal constant REPORT_PATH = "./script/config/preflight-report.json";

    /// @notice Gas ceiling on every probe, so a hostile or broken contract cannot hang the run.
    uint256 internal constant PROBE_GAS = 200_000;

    /// @notice Chainlink answers are 8-decimal on Robinhood Chain, and `PriceLib` assumes it everywhere.
    uint8 internal constant EXPECTED_FEED_DECIMALS = 8;

    /// @notice AMPS must sort below every counter asset (invariant I1): three leading zero bytes.
    uint160 internal constant MAX_AMPS_ADDRESS = uint160(0x0000010000000000000000000000000000000000);

    // -----------------------------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------------------------

    /// @notice One finding's verdict.
    /// @dev `TODO` and `SKIP` are deliberately not failures: a placeholder address is Phase 0's job to fill in,
    ///      and a precompile a local chain does not implement says nothing about 4663.
    enum Level {
        PASS,
        WARN,
        FAIL,
        TODO,
        SKIP
    }

    /// @notice One check's outcome.
    /// @param level The verdict.
    /// @param what The check's name.
    /// @param detail What was measured.
    struct Finding {
        Level level;
        string what;
        string detail;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------------------------------------------

    /// @notice At least one check failed and `PREFLIGHT_STRICT` is on.
    /// @param failures How many.
    error PreflightFailed(uint256 failures);

    // -----------------------------------------------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Every finding this run produced, in check order.
    Finding[] internal _findings;

    // -----------------------------------------------------------------------------------------------------------
    // Entry point
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Runs every check, prints the report, writes it, and reverts on a failure.
    function run() external {
        string memory cfg = vm.readFile(PREFLIGHT_PATH);

        checkChain(cfg);
        checkPrecompiles(cfg);
        checkInfrastructure(cfg);
        checkPoolManagerCode(cfg);
        checkTransientStorage();
        checkConstituents();
        checkAmpsOrdering();
        checkDeploymentState();

        (uint256 failures, uint256 warnings) = summarise();
        writeReport(failures, warnings);
        if (failures != 0 && vm.envOr("PREFLIGHT_STRICT", true)) revert PreflightFailed(failures);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Checks
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The chain is the one the config was written for.
    /// @param cfg `preflight.json`.
    function checkChain(string memory cfg) public {
        uint256 expected = vm.envOr("PREFLIGHT_CHAIN_ID", cfg.readUint(".chainId"));
        if (block.chainid == expected) {
            _pass("chainId", string.concat("chain ", vm.toString(block.chainid)));
        } else {
            _fail(
                "chainId",
                string.concat("expected ", vm.toString(expected), ", connected to ", vm.toString(block.chainid))
            );
        }
    }

    /// @notice `ArbSys.arbOSVersion()` and `ArbGasInfo.getGasAccountingParams()`, where the chain has them.
    /// @param cfg `preflight.json`.
    function checkPrecompiles(string memory cfg) public {
        address arbSys = cfg.readAddress(".precompiles.arbSys");
        uint256 expectedArbOs = cfg.readUint(".arbOsVersion");

        (bool ok, bytes memory ret) = _probe(arbSys, abi.encodeWithSignature("arbOSVersion()"));
        if (!ok || ret.length < 32) {
            _skip("arbOSVersion", "ArbSys did not answer; not an Arbitrum Orbit chain, or a local node");
        } else {
            uint256 version = abi.decode(ret, (uint256));
            string memory detail = string.concat("ArbOS ", vm.toString(version));
            // ArbOS >= 61 means EIP-7702 is live (tx.origin guards are worthless) and EIP-1153 is available.
            if (version >= expectedArbOs) _pass("arbOSVersion", detail);
            else _warn("arbOSVersion", string.concat(detail, ", below the pinned ", vm.toString(expectedArbOs)));
        }

        address arbGasInfo = cfg.readAddress(".precompiles.arbGasInfo");
        (ok, ret) = _probe(arbGasInfo, abi.encodeWithSignature("getGasAccountingParams()"));
        if (!ok || ret.length < 96) {
            _skip("maxTxGasLimit", "ArbGasInfo.getGasAccountingParams() is not exposed here");
        } else {
            (,, uint256 maxTxGasLimit) = abi.decode(ret, (uint256, uint256, uint256));
            _pass("maxTxGasLimit", string.concat(vm.toString(maxTxGasLimit), " gas per transaction"));
        }
    }

    /// @notice `eth_getCode` on every configured infrastructure address.
    /// @param cfg `preflight.json`.
    function checkInfrastructure(string memory cfg) public {
        uint256 count = cfg.readUint(".infrastructureCount");
        for (uint256 i; i < count; ++i) {
            string memory at = string.concat(".infrastructure[", vm.toString(i), "]");
            string memory name = cfg.readString(string.concat(at, ".name"));
            address target = cfg.readAddress(string.concat(at, ".address"));
            bool required = cfg.readBool(string.concat(at, ".required"));

            if (target == address(0)) {
                _todo(name, "address is a Phase 0 placeholder");
                continue;
            }
            uint256 size = target.code.length;
            string memory detail = string.concat(vm.toString(target), ", ", vm.toString(size), " bytes of code");
            if (size != 0) _pass(name, detail);
            else if (required) _fail(name, string.concat(vm.toString(target), " has NO CODE"));
            else _warn(name, string.concat(vm.toString(target), " has no code"));
        }
    }

    /// @notice `keccak256` of the PoolManager's deployed code against the hash Phase 0 pinned.
    /// @param cfg `preflight.json`.
    function checkPoolManagerCode(string memory cfg) public {
        address poolManager = infrastructureAddress(cfg, "poolManager");
        bytes32 pinned = cfg.readBytes32(".poolManagerCodeHash");
        if (poolManager.code.length == 0) {
            _skip("poolManagerCodeHash", "no code at the PoolManager address");
            return;
        }
        bytes32 actual = keccak256(poolManager.code);
        if (pinned == bytes32(0)) {
            _todo("poolManagerCodeHash", string.concat("measured ", vm.toString(actual), "; pin it in preflight.json"));
        } else if (pinned == actual) {
            _pass("poolManagerCodeHash", vm.toString(actual));
        } else {
            _fail("poolManagerCodeHash", string.concat("expected ", vm.toString(pinned), ", got ", vm.toString(actual)));
        }
    }

    /// @notice EIP-1153 acceptance, through a `to`-less `eth_call` of {TransientProbe}'s creation code.
    /// @dev The vault's reentrancy lock and the hook's rotation credit are both transient storage, so a chain
    ///      that rejects `TSTORE` cannot run this protocol at all. See {TransientProbe}.
    function checkTransientStorage() public {
        // The `try` target is a separate contract, created outside every broadcast window: `try this.f()` inside
        // a script trips Foundry's "Usage of `address(this)` detected in script contract" guard.
        TransientProbeRunner runner = new TransientProbeRunner();
        try runner.probe() returns (bytes memory ret) {
            if (ret.length == 0) _fail("tstore", "the node returned no runtime code: TSTORE/TLOAD rejected");
            else _pass("tstore", "TSTORE/TLOAD accepted (constructor round trip returned runtime code)");
        } catch {
            _skip("tstore", "eth_call with no `to` was refused here; re-run against the target RPC");
        }
    }

    /// @notice Every entry pool and constituent: token code, feed code, `latestRoundData` sanity, proxy shape.
    function checkConstituents() public {
        string memory json = vm.readFile(CONSTITUENTS_PATH);

        for (uint256 i; i < 2; ++i) {
            string memory at = string.concat(".entryPools[", vm.toString(i), "]");
            string memory symbol = json.readString(string.concat(at, ".symbol"));
            _checkToken(symbol, json.readAddress(string.concat(at, ".counter")));
            _checkFeed(
                symbol,
                json.readAddress(string.concat(at, ".feed")),
                uint32(json.readUint(string.concat(at, ".heartbeatSeconds")))
            );
        }

        uint256 n = json.readUint(".constituentCount");
        for (uint256 i; i < n; ++i) {
            string memory at = string.concat(".constituents[", vm.toString(i), "]");
            string memory symbol = json.readString(string.concat(at, ".symbol"));
            _checkToken(symbol, json.readAddress(string.concat(at, ".token")));
            _checkFeed(
                symbol,
                json.readAddress(string.concat(at, ".feed")),
                uint32(json.readUint(string.concat(at, ".heartbeatSeconds")))
            );
        }
    }

    /// @notice The address `preflight.json` records under `name`, or zero when it names nothing.
    /// @dev A scan rather than an index: the array is read in file order everywhere else, and a check that
    ///      silently moved with an edit to the file would be worse than no check.
    /// @param cfg `preflight.json`.
    /// @param name The entry's name.
    /// @return value The address.
    function infrastructureAddress(string memory cfg, string memory name) public pure returns (address value) {
        uint256 count = cfg.readUint(".infrastructureCount");
        bytes32 wanted = keccak256(bytes(name));
        for (uint256 i; i < count; ++i) {
            string memory at = string.concat(".infrastructure[", vm.toString(i), "]");
            if (keccak256(bytes(cfg.readString(string.concat(at, ".name")))) != wanted) continue;
            return cfg.readAddress(string.concat(at, ".address"));
        }
    }

    /// @notice The mined AMPS address, if there is one, sorts below WETH9 and every configured counter asset.
    /// @dev Invariant I1's precondition. `PoolRegistry._validateKeyShape` hard-requires `AMPS == currency0`, so a
    ///      salt that was mined against a different vault address — or not mined at all — makes all 32 pool
    ///      registrations revert, hours into a deployment.
    function checkAmpsOrdering() public {
        address amps = vm.envOr("AMPS_TOKEN", vm.readFile(DEPLOYMENTS_PATH).readAddress(".core.amps"));
        if (amps == address(0)) {
            _todo("ampsOrdering", "no AMPS address recorded yet; 01_MineAmps and 03_Core fix it");
            return;
        }
        if (uint160(amps) >= MAX_AMPS_ADDRESS) {
            _warn(
                "ampsOrdering",
                string.concat(vm.toString(amps), " has fewer than three leading zero bytes; check every counter")
            );
        }

        string memory json = vm.readFile(CONSTITUENTS_PATH);
        uint256 n = json.readUint(".constituentCount");
        uint256 offenders;
        for (uint256 i; i < 2; ++i) {
            address counter = json.readAddress(string.concat(".entryPools[", vm.toString(i), "].counter"));
            if (counter != address(0) && uint160(amps) >= uint160(counter)) ++offenders;
        }
        for (uint256 i; i < n; ++i) {
            address token = json.readAddress(string.concat(".constituents[", vm.toString(i), "].token"));
            if (token != address(0) && uint160(amps) >= uint160(token)) ++offenders;
        }
        if (offenders == 0) _pass("ampsOrdering", string.concat(vm.toString(amps), " sorts below every counter"));
        else _fail("ampsOrdering", string.concat(vm.toString(offenders), " counter assets sort BELOW AMPS"));
    }

    /// @notice Which of the deployment's own addresses already hold code, i.e. what a re-run would skip.
    function checkDeploymentState() public {
        string memory json = vm.readFile(DEPLOYMENTS_PATH);
        string[13] memory names = [
            "timelock",
            "guardian",
            "amps",
            "vault",
            "registry",
            "hook",
            "bonds",
            "staking",
            "bountyPot",
            "feedRegistry",
            "oracleGate",
            "positionValuer",
            "quoter"
        ];
        uint256 deployed;
        for (uint256 i; i < names.length; ++i) {
            address target = _readOptional(json, string.concat(".core.", names[i]));
            if (target != address(0) && target.code.length != 0) ++deployed;
        }
        _pass("deploymentState", string.concat(vm.toString(deployed), " of 13 core addresses already hold code"));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Every finding this run produced.
    /// @return findings The findings, in check order.
    function findings() external view returns (Finding[] memory) {
        return _findings;
    }

    /// @notice Prints the report and counts what matters.
    /// @return failures How many `FAIL` findings there are.
    /// @return warnings How many `WARN` findings there are.
    function summarise() public view returns (uint256 failures, uint256 warnings) {
        for (uint256 i; i < _findings.length; ++i) {
            Finding memory f = _findings[i];
            console2.log("%s %s: %s", _label(f.level), f.what, f.detail);
            if (f.level == Level.FAIL) ++failures;
            if (f.level == Level.WARN) ++warnings;
        }
        console2.log("preflight: %s checks, %s failures, %s warnings", _findings.length, failures, warnings);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Report
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Writes the whole report to `script/config/preflight-report.json`.
    /// @param failures How many failures.
    /// @param warnings How many warnings.
    function writeReport(uint256 failures, uint256 warnings) public {
        string[] memory items = new string[](_findings.length);
        for (uint256 i; i < _findings.length; ++i) {
            string memory obj = string.concat("amplestocks.preflight.", vm.toString(i));
            vm.serializeString(obj, "level", _label(_findings[i].level));
            vm.serializeString(obj, "check", _findings[i].what);
            items[i] = vm.serializeString(obj, "detail", _findings[i].detail);
        }

        string memory root = "amplestocks.preflight";
        vm.serializeString(
            root,
            "$comment",
            "Written by script/00_Preflight.s.sol. A read-only report: the script deploys nothing and sends "
            "nothing. TODO means a Phase 0 placeholder is still in the config; SKIP means this chain does not "
            "expose the probe."
        );
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "blockNumber", block.number);
        vm.serializeUint(root, "timestamp", block.timestamp);
        vm.serializeUint(root, "checks", _findings.length);
        vm.serializeUint(root, "failures", failures);
        vm.serializeUint(root, "warnings", warnings);
        string memory json = vm.serializeString(root, "findings", items);
        vm.writeJson(json, REPORT_PATH);
        console2.log("wrote %s", REPORT_PATH);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev One counter asset or Stock Token: it must have code.
    function _checkToken(string memory symbol, address token) private {
        string memory what = string.concat(symbol, ".token");
        if (token == address(0)) {
            _todo(what, "Phase 0 placeholder");
            return;
        }
        if (token.code.length == 0) _fail(what, string.concat(vm.toString(token), " has NO CODE"));
        else _pass(what, vm.toString(token));
    }

    /// @dev One Chainlink feed: code, decimals, a live answer inside its heartbeat, and the proxy shape.
    function _checkFeed(string memory symbol, address feed, uint32 heartbeat) private {
        string memory what = string.concat(symbol, ".feed");
        if (feed == address(0)) {
            _todo(what, "Phase 0 placeholder");
            return;
        }
        if (feed.code.length == 0) {
            _fail(what, string.concat(vm.toString(feed), " has NO CODE"));
            return;
        }

        (bool ok, bytes memory ret) = _probe(feed, abi.encodeWithSignature("latestRoundData()"));
        if (!ok || ret.length < 160) {
            _fail(what, string.concat(vm.toString(feed), " does not answer latestRoundData()"));
            return;
        }
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            abi.decode(ret, (uint80, int256, uint256, uint256, uint80));

        if (answer <= 0) {
            _fail(what, "latestRoundData answered <= 0");
        } else if (updatedAt == 0 || answeredInRound < roundId) {
            _fail(what, "incomplete round (updatedAt == 0 or answeredInRound < roundId)");
        } else if (block.timestamp > updatedAt && block.timestamp - updatedAt > heartbeat) {
            _warn(
                what,
                string.concat(
                    "stale: ",
                    vm.toString(block.timestamp - updatedAt),
                    "s old against a ",
                    vm.toString(uint256(heartbeat)),
                    "s heartbeat"
                )
            );
        } else {
            _pass(what, string.concat("answer ", vm.toString(uint256(answer)), " (8 dec assumed)"));
        }

        _checkFeedDecimals(symbol, feed);
        _checkProxyShape(symbol, feed);
    }

    /// @dev `decimals()` must be 8: `PriceLib` and every `FeedConfig` band are written in 8-decimal USD.
    function _checkFeedDecimals(string memory symbol, address feed) private {
        (bool ok, bytes memory ret) = _probe(feed, abi.encodeWithSignature("decimals()"));
        string memory what = string.concat(symbol, ".feedDecimals");
        if (!ok || ret.length < 32) {
            _fail(what, "decimals() did not answer");
            return;
        }
        uint8 decimals = uint8(abi.decode(ret, (uint256)));
        if (decimals == EXPECTED_FEED_DECIMALS) _pass(what, "8");
        else _fail(what, string.concat(vm.toString(uint256(decimals)), ", expected 8"));
    }

    /// @dev Standard-vs-SVR detection. A Chainlink **Standard** proxy is an `EACAggregatorProxy`: it answers
    ///      `aggregator()` and `phaseId()`. `FeedRegistry.setStandardProxy` allowlists exactly that shape, and
    ///      `setFeed` refuses anything not allowlisted. An SVR (Smart Value Recapture) feed is a different
    ///      deployment; the RDD is the authority on which is which, so this reports rather than decides — but a
    ///      description or `typeAndVersion` that names SVR is flagged so nobody allowlists one by accident.
    function _checkProxyShape(string memory symbol, address feed) private {
        string memory what = string.concat(symbol, ".feedProxy");
        (bool hasAggregator,) = _probe(feed, abi.encodeWithSignature("aggregator()"));
        (bool hasPhase,) = _probe(feed, abi.encodeWithSignature("phaseId()"));

        string memory version = _probeString(feed, abi.encodeWithSignature("typeAndVersion()"));
        string memory description = _probeString(feed, abi.encodeWithSignature("description()"));

        if (_namesSvr(version) || _namesSvr(description)) {
            _warn(what, string.concat("names SVR: \"", description, "\" / \"", version, "\" - NOT a Standard proxy"));
        } else if (hasAggregator && hasPhase) {
            _pass(what, string.concat("Standard proxy shape, \"", description, "\""));
        } else {
            _warn(what, "no aggregator()/phaseId(): not the Standard EACAggregatorProxy shape");
        }
    }

    /// @dev A gas-bounded `STATICCALL`. Never reverts: a dead or hostile target is a finding, not a crash.
    function _probe(address target, bytes memory data) private view returns (bool ok, bytes memory ret) {
        if (target.code.length == 0) return (false, "");
        (ok, ret) = target.staticcall{gas: PROBE_GAS}(data);
    }

    /// @dev A bounded string read, empty when the call fails or does not decode.
    function _probeString(address target, bytes memory data) private view returns (string memory value) {
        (bool ok, bytes memory ret) = _probe(target, data);
        if (!ok || ret.length < 64) return "";
        value = abi.decode(ret, (string));
    }

    /// @dev Whether `value` contains "SVR" or "svr".
    function _namesSvr(string memory value) private pure returns (bool) {
        bytes memory b = bytes(value);
        if (b.length < 3) return false;
        for (uint256 i; i + 3 <= b.length; ++i) {
            bytes1 a = b[i];
            bytes1 c = b[i + 1];
            bytes1 d = b[i + 2];
            bool s = a == "S" || a == "s";
            bool v = c == "V" || c == "v";
            bool r = d == "R" || d == "r";
            if (s && v && r) return true;
        }
        return false;
    }

    /// @dev An address from a JSON path that may be absent, as zero.
    function _readOptional(string memory json, string memory path) private view returns (address value) {
        if (!vm.keyExistsJson(json, path)) return address(0);
        value = json.readAddress(path);
    }

    function _pass(string memory what, string memory detail) private {
        _findings.push(Finding({level: Level.PASS, what: what, detail: detail}));
    }

    function _warn(string memory what, string memory detail) private {
        _findings.push(Finding({level: Level.WARN, what: what, detail: detail}));
    }

    function _fail(string memory what, string memory detail) private {
        _findings.push(Finding({level: Level.FAIL, what: what, detail: detail}));
    }

    function _todo(string memory what, string memory detail) private {
        _findings.push(Finding({level: Level.TODO, what: what, detail: detail}));
    }

    function _skip(string memory what, string memory detail) private {
        _findings.push(Finding({level: Level.SKIP, what: what, detail: detail}));
    }

    function _label(Level level) private pure returns (string memory) {
        if (level == Level.PASS) return "PASS";
        if (level == Level.WARN) return "WARN";
        if (level == Level.FAIL) return "FAIL";
        if (level == Level.TODO) return "TODO";
        return "SKIP";
    }
}
