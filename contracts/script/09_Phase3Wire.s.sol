// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsHook} from "../src/hook/AmpsHook.sol";
import {IAmpsBonds} from "../src/interfaces/IAmpsBonds.sol";
import {IAmpsVault} from "../src/interfaces/IAmpsVault.sol";
import {IFeedRegistry} from "../src/interfaces/IFeedRegistry.sol";
import {IMarketReference} from "../src/interfaces/IMarketReference.sol";
import {IOracleGate} from "../src/interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../src/interfaces/IPoolRegistry.sol";
import {OracleGate} from "../src/oracle/OracleGate.sol";
import {Constants} from "../src/types/Constants.sol";
import {GateState} from "../src/types/Types.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/// @title Phase3Wire
/// @notice The Phase 3 pointer moves, and the bootstrap ordering they have to happen inside.
///
///         Six moves (`docs/phase3-state-model.md` §7 and §10 ruling 10):
///
///         | # | Move | Delay |
///         |---|---|---|
///         | 1 | `AmpsVault.marketReference -> AmpsHook` | 7 d |
///         | 2 | `AmpsVault.positionValuer -> LadderPositionValuer` | 7 d |
///         | 3 | `AmpsVault.ladderPolicy -> LadderPolicy` | 7 d |
///         | 4 | `AmpsVault.rolloutPolicy -> RolloutPolicy` | 7 d |
///         | 5 | `AmpsHook.setFeePolicy(FeePolicy)` | 48 h |
///         | 6 | `AmpsBonds.setPolicy(BondPolicy)` | 7 d |
///
///         plus the `OracleGate` redeploy: a fresh gate constructed with `AmpsHook` as its `marketReference`, so
///         it reads the hook's `poolState` for the corporate-action flag and keeps its own token probes as the
///         fallback, re-pointed from the vault (`setPolicyPointer("oracleGate")`) and from `FeedRegistry`
///         (`setOracleGate`). Nothing was deployed before Phase 3, so this is a redeploy of an address, not a
///         migration of state — except the calendar, which {installCalendar} re-installs.
///
/// @dev **This script does not choose the delay.** Every call below is a timelock call. With `direct == true`
///      (a test chain whose "timelock" is an EOA the script controls) it makes them directly; with
///      `direct == false` it emits the `TimelockController.scheduleBatch` / `executeBatch` calldata for the
///      proposer Safe to sign, and touches nothing.
///
/// @dev **Bootstrap ordering is the point of the script, not a side note** (`docs/phase2-state-model.md` §9.1).
///      `AmpsVault.initializePool` and `genesis()` both take `_requireHealthy`, and `OracleGate` reports
///      `WATCHDOG` while the hub pool is unregistered *or* its observation ring covers less than `twapWindow`. A
///      freshly initialised pool has no observations, so with the gate already wired **no pool can be registered
///      and `genesis()` can never run**. The order is therefore:
///
///        1. deploy everything; wire the vault's set-once pointers (`registry`, `bonds`, `staking`, `bountyPot`)
///           and `feedRegistry` / `positionValuer` / `marketReference`, and **leave `oracleGate` unset** — a gate
///           that is absent is exactly as permissive as a gate that is `GREEN`;
///        2. register the 32 pools (`05_Registry`), each `vault.initializePool` passing with no gate;
///        3. wait until the hub's ring covers `twapWindow` — thirty minutes of blocks on Robinhood Chain;
///        4. point the vault at `OracleGate` and confirm `gate.state(0) == GREEN`;
///        5. run `genesis()` and the §3.3 ladders (`11_GenesisPlacement`).
///
///      {checkBootstrap} asserts steps 1-4 as a precondition and {assertGateGreen} is the step-4 gate itself, so
///      the ordering is a check in code rather than a paragraph in a runbook.
///
/// @dev **Usage.**
/// ```
///   # emit the proposal calldata for the Safe (default)
///   forge script script/09_Phase3Wire.s.sol
///
///   # execute directly, on a chain where the configured timelock is this script's sender
///   WIRE_DIRECT=true forge script script/09_Phase3Wire.s.sol --broadcast --rpc-url $RPC
/// ```
contract Phase3Wire is Script {
    using stdJson for string;

    // -----------------------------------------------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The core deployment addresses.
    string internal constant DEPLOYMENTS_PATH = "./script/config/deployments.json";

    /// @notice Where the proposal calldata is written when the script runs in proposal mode.
    string internal constant PROPOSAL_PATH = "./script/config/phase3-proposal.json";

    /// @notice The pointer slot names `AmpsVault.setPolicyPointer` dispatches on.
    bytes32 internal constant SLOT_MARKET_REFERENCE = bytes32("marketReference");
    bytes32 internal constant SLOT_POSITION_VALUER = bytes32("positionValuer");
    bytes32 internal constant SLOT_LADDER_POLICY = bytes32("ladderPolicy");
    bytes32 internal constant SLOT_ROLLOUT_POLICY = bytes32("rolloutPolicy");
    bytes32 internal constant SLOT_ORACLE_GATE = bytes32("oracleGate");

    /// @notice The year the bundled NYSE holiday bitmap covers. Later years are installed by their own
    ///         `setHolidayBitmap` proposal; the gate treats an unknown year as having no full-day closures, which
    ///         is a liveness choice, not a safety one.
    uint16 internal constant HOLIDAY_YEAR = 2026;

    // -----------------------------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Everything the six moves and the gate redeploy need.
    struct Targets {
        address timelock;
        address guardian;
        address vault;
        address hook;
        address registry;
        address bonds;
        address feedRegistry;
        address oracleGate;
        address positionValuer;
        address ladderPolicy;
        address rolloutPolicy;
        address feePolicy;
        address bondPolicy;
    }

    /// @notice One timelock call, in `TimelockController.scheduleBatch` order.
    struct Call {
        address target;
        uint256 value;
        bytes data;
        string what;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A required address is zero.
    /// @param what Which one.
    error MissingAddress(string what);

    /// @notice The gate is not `GREEN`, so `genesis()` and every gated path would revert `GateNotHealthy`.
    /// @param actual The state the gate reports.
    error GateNotGreen(GateState actual);

    /// @notice A vault pointer that step 1 of the bootstrap must have set is still zero.
    /// @param slot The pointer name.
    error PointerUnset(bytes32 slot);

    /// @notice The hub pool's observation ring does not yet cover `twapWindow`, so pointing the vault at the gate
    ///         now would make every gated path revert `GateNotHealthy(WATCHDOG)`.
    /// @param covered Seconds the ring covers.
    /// @param required Seconds it must cover.
    error CoverageMissing(uint32 covered, uint32 required);

    /// @notice The registry holds fewer pools than the bootstrap expects, i.e. step 2 has not finished.
    /// @param registered How many are registered.
    /// @param expected How many were expected.
    error PoolsMissing(uint16 registered, uint16 expected);

    /// @notice `genesis()` has already run, so the wiring latch is closed and this batch is stale.
    error AlreadyGenesis();

    // -----------------------------------------------------------------------------------------------------------
    // Entry points
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Builds the batch and either executes it (`WIRE_DIRECT=true`) or writes the proposal calldata.
    function run() external {
        Targets memory t = loadTargets();
        bool direct = vm.envOr("WIRE_DIRECT", false);
        bool redeployGate = vm.envOr("WIRE_REDEPLOY_GATE", true);

        if (direct) {
            address gate = execute(t, redeployGate);
            console2.log("oracleGate now %s", gate);
        } else {
            writeProposal(buildCalls(t, t.oracleGate));
        }
    }

    /// @notice Performs the six pointer moves directly, as the timelock, optionally redeploying `OracleGate`
    ///         first. Idempotent: a pointer that already holds the target address is left alone.
    /// @dev The gate pointer is moved **last**, after {checkBootstrap} has confirmed the pools exist and the hub
    ///      ring covers `twapWindow`, and {assertGateGreen} then proves the vault is genuinely open for business.
    /// @param t The addresses.
    /// @param redeployGate Whether to deploy a fresh `OracleGate` reading `AmpsHook.poolState`.
    /// @return gate The gate the vault ends up pointing at.
    function execute(Targets memory t, bool redeployGate) public returns (address gate) {
        _require(t.timelock, "timelock");
        _require(t.vault, "vault");
        _require(t.hook, "hook");

        IAmpsVault vault = IAmpsVault(t.vault);
        if (vault.initialized()) revert AlreadyGenesis();

        gate = t.oracleGate;
        if (redeployGate) {
            _require(t.guardian, "guardian");
            _require(t.registry, "registry");
            _require(t.feedRegistry, "feedRegistry");
            vm.startBroadcast(t.timelock);
            gate = address(new OracleGate(t.timelock, t.guardian, t.feedRegistry, t.registry, t.hook));
            vm.stopBroadcast();
            console2.log("OracleGate redeployed at %s (marketReference = AmpsHook)", gate);
            installCalendar(t, gate);
        } else if (gate != address(0) && IOracleGate(gate).marketReference() != t.hook) {
            vm.startBroadcast(t.timelock);
            IOracleGate(gate).setMarketReference(t.hook);
            vm.stopBroadcast();
        }
        _require(gate, "oracleGate");

        vm.startBroadcast(t.timelock);

        if (vault.marketReference() != t.hook) vault.setPolicyPointer(SLOT_MARKET_REFERENCE, t.hook);
        if (t.positionValuer != address(0) && vault.positionValuer() != t.positionValuer) {
            vault.setPolicyPointer(SLOT_POSITION_VALUER, t.positionValuer);
        }
        if (t.ladderPolicy != address(0) && vault.ladderPolicy() != t.ladderPolicy) {
            vault.setPolicyPointer(SLOT_LADDER_POLICY, t.ladderPolicy);
        }
        if (t.rolloutPolicy != address(0) && vault.rolloutPolicy() != t.rolloutPolicy) {
            vault.setPolicyPointer(SLOT_ROLLOUT_POLICY, t.rolloutPolicy);
        }
        if (t.feePolicy != address(0) && AmpsHook(t.hook).feePolicy() != t.feePolicy) {
            AmpsHook(t.hook).setFeePolicy(t.feePolicy);
        }
        if (t.bondPolicy != address(0) && t.bonds != address(0) && IAmpsBonds(t.bonds).policy() != t.bondPolicy) {
            IAmpsBonds(t.bonds).setPolicy(t.bondPolicy);
        }
        if (t.feedRegistry != address(0) && IFeedRegistry(t.feedRegistry).oracleGate() != gate) {
            IFeedRegistry(t.feedRegistry).setOracleGate(gate);
        }

        vm.stopBroadcast();

        // Step 4 of §9.1, and only now: the gate pointer goes in last, and only if the pools and the hub ring
        // are actually there. Before this line the vault is ungated, which is what let step 2 happen at all.
        checkBootstrap(t, uint16(_expectedPools()));

        vm.startBroadcast(t.timelock);
        if (vault.oracleGate() != gate) vault.setPolicyPointer(SLOT_ORACLE_GATE, gate);
        vm.stopBroadcast();

        assertGateGreen(gate);
        console2.log("bootstrap step 4 complete: gate is GREEN, genesis() may run");
    }

    /// @notice Re-installs the DST table and the NYSE holiday bitmap on a freshly deployed gate.
    /// @dev The calendar is published data, not chain reference data, so it is carried in the script rather than
    ///      in `packages/config`: `OracleGate` has no getter for the DST table, so a redeploy cannot copy it off
    ///      the old gate and it must come from somewhere. Only {HOLIDAY_YEAR} is bundled; a year with no bitmap
    ///      is treated as having no full-day closures, so the next year's map is its own 48-hour proposal.
    /// @param t The addresses (for the timelock).
    /// @param gate The gate to configure.
    function installCalendar(Targets memory t, address gate) public {
        vm.startBroadcast(t.timelock);
        OracleGate(gate).setDstTable(dstStarts(), dstEnds());
        OracleGate(gate).setHolidayBitmap(HOLIDAY_YEAR, holidayBitmap2026());
        vm.stopBroadcast();
        console2.log("calendar installed on %s (DST 2025-2032, NYSE %s)", gate, uint256(HOLIDAY_YEAR));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Bootstrap checks
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Asserts steps 1-3 of the §9.1 bootstrap: every pointer the vault needs before genesis is set, the
    ///         pools are registered, and the hub pool's observation ring covers `twapWindow`.
    /// @param t The addresses.
    /// @param expectedPools How many pools must already be registered.
    function checkBootstrap(Targets memory t, uint16 expectedPools) public view {
        IAmpsVault vault = IAmpsVault(t.vault);
        if (vault.registry() == address(0)) revert PointerUnset(bytes32("registry"));
        if (vault.bonds() == address(0)) revert PointerUnset(bytes32("bonds"));
        if (vault.staking() == address(0)) revert PointerUnset(bytes32("staking"));
        if (vault.bountyPot() == address(0)) revert PointerUnset(bytes32("bountyPot"));
        if (vault.feedRegistry() == address(0)) revert PointerUnset(bytes32("feedRegistry"));
        if (vault.positionValuer() == address(0)) revert PointerUnset(SLOT_POSITION_VALUER);
        if (vault.marketReference() == address(0)) revert PointerUnset(SLOT_MARKET_REFERENCE);

        IPoolRegistry registry = IPoolRegistry(vault.registry());
        uint16 pools = registry.poolCount();
        if (pools < expectedPools) revert PoolsMissing(pools, expectedPools);

        PoolId hub = registry.hubPoolId();
        uint32 window = vault.twapWindow();
        uint32 covered = IMarketReference(vault.marketReference()).observationCoverage(hub);
        if (covered < window) revert CoverageMissing(covered, window);
    }

    /// @notice Step 4's own assertion: the gate must be `GREEN` before `genesis()` is proposed.
    /// @param gate The gate.
    function assertGateGreen(address gate) public view {
        GateState state = IOracleGate(gate).state(0);
        if (state != GateState.GREEN) revert GateNotGreen(state);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Proposal building
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The six moves as timelock calls, in the order they must execute.
    /// @dev The gate redeploy is not expressible as a proposal call — the gate has to exist before it can be
    ///      pointed at — so in proposal mode it is deployed out of band and its address passed in as `gate`.
    /// @param t The addresses.
    /// @param gate The `OracleGate` the vault should end up pointing at.
    /// @return calls The batch.
    function buildCalls(Targets memory t, address gate) public pure returns (Call[] memory calls) {
        calls = new Call[](7);
        calls[0] = Call({
            target: t.vault,
            value: 0,
            data: abi.encodeCall(IAmpsVault.setPolicyPointer, (SLOT_MARKET_REFERENCE, t.hook)),
            what: "vault.marketReference = AmpsHook"
        });
        calls[1] = Call({
            target: t.vault,
            value: 0,
            data: abi.encodeCall(IAmpsVault.setPolicyPointer, (SLOT_POSITION_VALUER, t.positionValuer)),
            what: "vault.positionValuer = LadderPositionValuer"
        });
        calls[2] = Call({
            target: t.vault,
            value: 0,
            data: abi.encodeCall(IAmpsVault.setPolicyPointer, (SLOT_LADDER_POLICY, t.ladderPolicy)),
            what: "vault.ladderPolicy = LadderPolicy"
        });
        calls[3] = Call({
            target: t.vault,
            value: 0,
            data: abi.encodeCall(IAmpsVault.setPolicyPointer, (SLOT_ROLLOUT_POLICY, t.rolloutPolicy)),
            what: "vault.rolloutPolicy = RolloutPolicy"
        });
        calls[4] = Call({
            target: t.hook,
            value: 0,
            data: abi.encodeCall(AmpsHook.setFeePolicy, (t.feePolicy)),
            what: "hook.setFeePolicy(FeePolicy)"
        });
        calls[5] = Call({
            target: t.bonds,
            value: 0,
            data: abi.encodeCall(IAmpsBonds.setPolicy, (t.bondPolicy)),
            what: "bonds.setPolicy(BondPolicy)"
        });
        calls[6] = Call({
            target: t.vault,
            value: 0,
            data: abi.encodeCall(IAmpsVault.setPolicyPointer, (SLOT_ORACLE_GATE, gate)),
            what: "vault.oracleGate = OracleGate (redeployed, marketReference = AmpsHook)"
        });
    }

    /// @notice `TimelockController.scheduleBatch(targets, values, payloads, predecessor, salt, delay)` calldata
    ///         for `calls`, ready for the proposer Safe.
    /// @param calls The batch.
    /// @param salt The proposal salt.
    /// @param delay The delay in seconds — 7 days for this batch, because the slowest move in it is a 7-day one.
    /// @return data The calldata.
    function scheduleBatchCalldata(Call[] memory calls, bytes32 salt, uint256 delay)
        public
        pure
        returns (bytes memory data)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _split(calls);
        data = abi.encodeWithSignature(
            "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)",
            targets,
            values,
            payloads,
            bytes32(0),
            salt,
            delay
        );
    }

    /// @notice `TimelockController.executeBatch(targets, values, payloads, predecessor, salt)` calldata.
    /// @param calls The batch.
    /// @param salt The same salt the schedule used.
    /// @return data The calldata.
    function executeBatchCalldata(Call[] memory calls, bytes32 salt) public pure returns (bytes memory data) {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _split(calls);
        data = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, values, payloads, bytes32(0), salt
        );
    }

    /// @notice Writes the batch, and the two pieces of timelock calldata, to `script/config/phase3-proposal.json`.
    /// @param calls The batch.
    function writeProposal(Call[] memory calls) public {
        bytes32 salt = keccak256("amplestocks.phase3.wire");
        string[] memory items = new string[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            string memory obj = string.concat("amplestocks.proposal.", vm.toString(i));
            vm.serializeString(obj, "what", calls[i].what);
            vm.serializeAddress(obj, "target", calls[i].target);
            vm.serializeUint(obj, "value", calls[i].value);
            items[i] = vm.serializeBytes(obj, "data", calls[i].data);
            console2.log("%s -> %s", calls[i].what, vm.toString(calls[i].data));
        }

        string memory root = "amplestocks.proposal";
        vm.serializeString(
            root,
            "$comment",
            "Written by script/09_Phase3Wire.s.sol. Hand `scheduleBatch` to the proposer Safe, wait out the "
            "7-day delay, then hand it `executeBatch` with the same salt. The OracleGate must be deployed before "
            "the batch is scheduled, because call 7 points the vault at it."
        );
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeBytes32(root, "salt", salt);
        vm.serializeUint(root, "delaySeconds", Constants.TIMELOCK_SLOW_SECONDS);
        vm.serializeString(root, "calls", items);
        vm.serializeBytes(root, "scheduleBatch", scheduleBatchCalldata(calls, salt, Constants.TIMELOCK_SLOW_SECONDS));
        string memory json = vm.serializeBytes(root, "executeBatch", executeBatchCalldata(calls, salt));
        vm.writeJson(json, PROPOSAL_PATH);
        console2.log("wrote %s", PROPOSAL_PATH);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Config and calendar
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The addresses, from `script/config/deployments.json` with the environment winning.
    /// @return t The targets.
    function loadTargets() public view returns (Targets memory t) {
        string memory json = vm.readFile(DEPLOYMENTS_PATH);
        t = Targets({
            timelock: _address(json, ".core.timelock", "AMPS_TIMELOCK"),
            guardian: _address(json, ".core.guardian", "AMPS_GUARDIAN"),
            vault: _address(json, ".core.vault", "AMPS_VAULT"),
            hook: _address(json, ".core.hook", "AMPS_HOOK"),
            registry: _address(json, ".core.registry", "AMPS_REGISTRY"),
            bonds: _address(json, ".core.bonds", "AMPS_BONDS"),
            feedRegistry: _address(json, ".core.feedRegistry", "AMPS_FEED_REGISTRY"),
            oracleGate: _address(json, ".core.oracleGate", "AMPS_ORACLE_GATE"),
            positionValuer: _address(json, ".core.positionValuer", "AMPS_POSITION_VALUER"),
            ladderPolicy: _address(json, ".core.ladderPolicy", "AMPS_LADDER_POLICY"),
            rolloutPolicy: _address(json, ".core.rolloutPolicy", "AMPS_ROLLOUT_POLICY"),
            feePolicy: _address(json, ".core.feePolicy", "AMPS_FEE_POLICY"),
            bondPolicy: _address(json, ".core.bondPolicy", "AMPS_BOND_POLICY")
        });
    }

    /// @notice US DST window starts, UTC: the second Sunday in March at 02:00 EST, 2025 through 2032.
    /// @return starts The timestamps.
    function dstStarts() public pure returns (uint32[] memory starts) {
        starts = new uint32[](8);
        starts[0] = 1_741_503_600;
        starts[1] = 1_772_953_200;
        starts[2] = 1_805_007_600;
        starts[3] = 1_836_457_200;
        starts[4] = 1_867_906_800;
        starts[5] = 1_899_356_400;
        starts[6] = 1_930_806_000;
        starts[7] = 1_962_860_400;
    }

    /// @notice US DST window ends, UTC: the first Sunday in November at 02:00 EDT, 2025 through 2032.
    /// @return ends The timestamps.
    function dstEnds() public pure returns (uint32[] memory ends) {
        ends = new uint32[](8);
        ends[0] = 1_762_063_200;
        ends[1] = 1_793_512_800;
        ends[2] = 1_825_567_200;
        ends[3] = 1_857_016_800;
        ends[4] = 1_888_466_400;
        ends[5] = 1_919_916_000;
        ends[6] = 1_951_365_600;
        ends[7] = 1_983_420_000;
    }

    /// @notice The 2026 NYSE full-day closures as days of the year, packed into the gate's two-word bitmap.
    /// @return bitmap The bitmap.
    function holidayBitmap2026() public pure returns (uint256[2] memory bitmap) {
        uint16[10] memory daysOfYear = [1, 19, 47, 93, 145, 170, 184, 250, 330, 359];
        for (uint256 i; i < daysOfYear.length; ++i) {
            uint256 index = uint256(daysOfYear[i]) - 1;
            bitmap[index >> 8] |= uint256(1) << (index & 255);
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The pool count the bootstrap expects: the two entry pools plus the configured constituent set.
    function _expectedPools() private view returns (uint256 count) {
        count = vm.envOr("WIRE_EXPECTED_POOLS", uint256(0));
        if (count != 0) return count;
        string memory json = vm.readFile("./script/config/constituents.json");
        count = json.readUint(".constituentCount") + 2;
    }

    /// @dev Splits a batch into the three parallel arrays `TimelockController` takes.
    function _split(Call[] memory calls)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](calls.length);
        values = new uint256[](calls.length);
        payloads = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            targets[i] = calls[i].target;
            values[i] = calls[i].value;
            payloads[i] = calls[i].data;
        }
    }

    function _require(address value, string memory what) private pure {
        if (value == address(0)) revert MissingAddress(what);
    }

    function _address(string memory json, string memory path, string memory envName)
        private
        view
        returns (address value)
    {
        value = vm.envOr(envName, json.readAddress(path));
    }
}
