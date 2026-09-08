// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsBonds} from "../src/bonds/AmpsBonds.sol";
import {AmpsHook} from "../src/hook/AmpsHook.sol";
import {IAmpsVault} from "../src/interfaces/IAmpsVault.sol";
import {IFeedRegistry} from "../src/interfaces/IFeedRegistry.sol";
import {IPoolRegistry} from "../src/interfaces/IPoolRegistry.sol";
import {BountyPot} from "../src/keeper/BountyPot.sol";
import {FeedRegistry} from "../src/oracle/FeedRegistry.sol";
import {OracleGate} from "../src/oracle/OracleGate.sol";
import {AmpsQuoter} from "../src/periphery/AmpsQuoter.sol";
import {AmpsRouter} from "../src/periphery/AmpsRouter.sol";
import {BondPolicy} from "../src/policy/BondPolicy.sol";
import {FeePolicy} from "../src/policy/FeePolicy.sol";
import {LadderPolicy} from "../src/policy/LadderPolicy.sol";
import {RolloutPolicy} from "../src/policy/RolloutPolicy.sol";
import {PoolRegistry} from "../src/registry/PoolRegistry.sol";
import {Amps} from "../src/token/Amps.sol";
import {Constants} from "../src/types/Constants.sol";
import {LadderPositionValuer} from "../src/valuer/LadderPositionValuer.sol";
import {AmpsVault} from "../src/vault/AmpsVault.sol";
import {Calendar} from "./lib/Calendar.sol";
import {Gov, ITimelock} from "./lib/Gov.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/// @title Core
/// @notice Everything the Amplestocks system is made of, deployed in the one order the constructors allow, and
///         recorded in `script/config/deployments.json` and `script/config/constructor-args.json`.
///
///         It stands in for the plan's `02_Token`, `03_Vault` and `07_Bonds` — those are one
///         transaction batch in practice, because the addresses are mutually dependent and splitting them across
///         scripts would mean re-predicting the same nonces four times. `02_Libraries` still runs first (the
///         vault cannot be *built* without the four library addresses), `04_MineHook` is the same salt search this
///         script performs and stays as the standalone re-check CI runs, and `05`/`09`/`11` still do the
///         registration, the Phase 3 pointer moves and genesis.
///
/// @dev **The address graph, and why it is deployed in exactly this order.**
///
///      | Contract | How its address is fixed |
///      |---|---|
///      | `TimelockController` | plain CREATE; it is an **immutable** constructor argument of the vault, the registry and the hook, so it must exist first and can never be replaced |
///      | `Amps` | CREATE2 through the canonical factory, salt mined so the address has three leading zero bytes and AMPS is `currency0` in all 32 pools |
///      | `AmpsVault` | plain CREATE, address *predicted* — the AMPS salt is mined against `abi.encode(vault)`, so the vault's address has to be known before AMPS exists |
///      | `AmpsHook` | CREATE2, salt mined so the low 14 bits are exactly `0x38C0` |
///      | `PoolRegistry` | plain CREATE, address *predicted* — the hook takes the registry and the registry takes the hook |
///
///      A CREATE2 deployment inside a broadcast is still a transaction from the deployer to the factory, so it
///      consumes a nonce: the vault is `nonce + 1` and the registry `nonce + 3`. Both predictions are asserted
///      rather than trusted.
///
/// @dev **Governance, and why `Gov` exists.** The timelock address is immutable on the vault, the registry and
///      the hook, so the account that makes the ~100 bootstrap calls cannot be swapped out afterwards — it *is*
///      the timelock. This script therefore deploys the `TimelockController` with `minDelay = 0` and the deployer
///      as a second proposer alongside the Safe, runs the whole bootstrap through it at zero delay, and the launch
///      ends with `CORE_STAGE=finalize`, which raises `minDelay` to 48 h and revokes the deployer's proposer role
///      in one batch. Until that batch executes, **the deployer key is as powerful as the Safe** — which is why it
///      is a fresh hardware key, why the launch runbook makes finalisation the last step before the seed goes in,
///      and why `finalize` asserts the result. On a single-operator testnet, `AMPS_TIMELOCK` may simply be an EOA
///      and every call is made directly (`AMPS_GOV_RELAY` unset).
///
/// @dev **Every broadcast window in this file is opened by this contract.** A window opened by a helper contract
///      writes every transaction with the same nonce under Foundry 1.8.1 (`docs/deploy-runbook.md` §0.1), so
///      `Gov` is a library of `internal` functions, no helper contract is instantiated at all, and every call the
///      script makes is issued from this frame.
///
/// @dev **Usage.**
/// ```
///   # the whole system, as the timelock's own proposer
///   AMPS_GOV_RELAY=true AMPS_DEPLOYER=$DEPLOYER CORE_PROPOSER_SAFE=$SAFE AMPS_GUARDIAN=$GUARDIAN \
///     forge script script/03_Core.s.sol --broadcast --rpc-url $RPC $LIBRARY_FLAGS
///
///   # after genesis: hand governance over
///   CORE_STAGE=finalize AMPS_GOV_RELAY=true AMPS_DEPLOYER=$DEPLOYER \
///     forge script script/03_Core.s.sol --broadcast --rpc-url $RPC $LIBRARY_FLAGS
/// ```
contract Core is Script {
    using stdJson for string;

    // -----------------------------------------------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The deployment's own address book.
    string internal constant DEPLOYMENTS_PATH = "./script/config/deployments.json";

    /// @notice Where every constructor argument is recorded, for Blockscout verification.
    string internal constant ARGS_PATH = "./script/config/constructor-args.json";

    /// @notice The four linked vault libraries, as `02_Libraries` recorded them.
    string internal constant LIBRARIES_PATH = "./script/config/libraries.json";

    /// @notice The canonical deterministic-deployment proxy. Every CREATE2 in a Foundry broadcast is routed
    ///         through it, which is why both salt searches mine against it.
    address internal constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Three leading zero bytes: the production strength of the AMPS salt (invariant I1).
    uint8 internal constant AMPS_ZERO_BYTES_DEFAULT = 3;

    /// @notice How many salts the in-script miner tries before giving up and pointing at `mine-amps.py`.
    uint256 internal constant MINE_MAX_TRIES_DEFAULT = 1 << 25;

    /// @notice `AmpsHook`'s mined permission bits.
    uint160 internal constant HOOK_FLAGS = uint160(Constants.HOOK_FLAGS);

    // -----------------------------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------------------------

    /// @notice What the deployment needs to be told. Everything else it works out or deploys.
    /// @param deployer The account that signs every transaction — and, until `finalize`, a timelock proposer.
    /// @param proposerSafe The 3/5 proposer Safe. Zero on a single-operator testnet.
    /// @param guardian The 2/4 guardian Safe: canceller, disable-only freezes, `emergencyMigrate` trigger.
    /// @param creator The creator-fee recipient recorded at genesis (used by `11_GenesisPlacement`, recorded here).
    /// @param teamBeneficiary The team `VestingWallet`'s beneficiary.
    /// @param teamVestStart The vesting start, seconds. Defaults to the deployment's own timestamp.
    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param weth9 The WETH9 the `AMPS/WETH` entry pool trades against.
    /// @param usdg USDG: the hub pool's counter and the `BountyPot`'s unit.
    /// @param timelock An already-deployed governance address, or zero to deploy a `TimelockController`.
    /// @param ampsSalt A pre-mined AMPS salt, or zero to mine one in-script.
    /// @param ampsZeroBytes How many leading zero bytes the mined AMPS address must have.
    struct Config {
        address deployer;
        address proposerSafe;
        address guardian;
        address creator;
        address teamBeneficiary;
        uint64 teamVestStart;
        address poolManager;
        address weth9;
        address usdg;
        address timelock;
        bytes32 ampsSalt;
        uint8 ampsZeroBytes;
    }

    /// @notice Every address the deployment produces or is given. Mirrors `deployments.json`'s `core` object.
    struct Set {
        address timelock;
        address guardian;
        address creator;
        address teamVestingWallet;
        address poolManager;
        address amps;
        address vault;
        address registry;
        address hook;
        address bonds;
        address bountyPot;
        address feedRegistry;
        address oracleGate;
        address positionValuer;
        address ladderPolicy;
        address rolloutPolicy;
        address feePolicy;
        address bondPolicy;
        address quoter;
        address router;
        address weth9;
        address usdg;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A required input is zero.
    /// @param what Which one.
    error MissingAddress(string what);

    /// @notice A CREATE address did not land where it was predicted, so the AMPS salt or the hook salt is bound to
    ///         the wrong argument set and the deployment must be abandoned rather than continued.
    /// @param what The contract.
    /// @param expected The predicted address.
    /// @param actual Where it landed.
    error AddressPrediction(string what, address expected, address actual);

    /// @notice No salt with the requested number of leading zero bytes was found inside the try budget.
    /// @param zeroBytes How many were asked for.
    /// @param tries How many salts were tried.
    error NoAmpsSalt(uint8 zeroBytes, uint256 tries);

    /// @notice A supplied `AMPS_SALT` does not produce an address that sorts below every counter asset.
    /// @param salt The salt.
    /// @param predicted Where it lands.
    error WeakAmpsSalt(bytes32 salt, address predicted);

    /// @notice No timelock is configured and the run is in direct mode, so there is nothing to deploy *as*.
    /// @dev Deploying a `TimelockController` only makes sense in relay mode: a contract cannot sign transactions,
    ///      so the bootstrap has to go through `schedule`/`execute` from the deployer.
    error TimelockRequiresRelay();

    /// @notice `script/config/libraries.json` has no address for a library, so `02_Libraries` has not run on this
    ///         chain and there is no way to know what the vault should have been linked against.
    /// @param name The library.
    error LibraryUnrecorded(string name);

    /// @notice The deployed vault's runtime code does not contain a library's address: the `--libraries` flags
    ///         were missing or wrong, and every `DELEGATECALL` would land somewhere this deployment does not own.
    /// @param name The library.
    /// @param expected The address it should have been linked against.
    error LibraryUnlinked(string name, address expected);

    /// @notice `finalize` was asked for before the timelock could be handed over, or it did not take effect.
    /// @param minDelay The timelock's minimum delay afterwards.
    /// @param deployerStillProposer Whether the deployer can still propose.
    error FinalizeFailed(uint256 minDelay, bool deployerStillProposer);

    // -----------------------------------------------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Whether this run deployed the `OracleGate`, and therefore has to install its calendar. `OracleGate`
    ///      exposes no getter for the DST table, so a re-run cannot ask the gate whether it already has one; this
    ///      is what keeps a second run from re-sending two governed calls that would change nothing.
    bool private _gateDeployedThisRun;

    // -----------------------------------------------------------------------------------------------------------
    // Entry point
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Runs the stage `CORE_STAGE` selects: `deploy` (the default) or `finalize`.
    function run() external {
        Config memory cfg = loadConfig();
        if (keccak256(bytes(vm.envOr("CORE_STAGE", string("deploy")))) == keccak256("finalize")) {
            finalize(cfg);
            return;
        }

        Set memory set = deployAll(cfg);
        writeDeployments(set);
        writeConstructorArgs(set);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Deployment
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Deploys everything that is missing and performs the set-once wiring `docs/phase2-state-model.md`
    ///         §9.1 step 1 calls for — every vault pointer **except** `oracleGate`, which `09_Phase3Wire` moves
    ///         once the pools exist and the hub's observation ring is covered.
    /// @dev Idempotent only at the level of the timelock: a re-run against a `deployments.json` that already names
    ///      a vault redeploys nothing and re-asserts the wiring. A partially failed run is resumed by filling the
    ///      addresses it printed into `deployments.json` and running again.
    /// @param cfg The inputs.
    /// @return set Every address.
    function deployAll(Config memory cfg) public returns (Set memory set) {
        _requireInputs(cfg);

        set = readDeployments();
        set.guardian = cfg.guardian;
        set.creator = cfg.creator;
        set.poolManager = cfg.poolManager;
        set.weth9 = cfg.weth9;
        set.usdg = cfg.usdg;
        set.timelock = cfg.timelock;

        if (set.timelock == address(0)) set.timelock = _deployTimelock(cfg);

        Gov.Ctx memory ctx = Gov.load(set.timelock);
        Gov.describe(ctx);
        Gov.requireBootstrappable(ctx);

        _deployCore(cfg, set);
        _deployPeriphery(cfg, set);
        _assertLinked(set.vault);
        _wire(ctx, set);
        _report(set);
    }

    /// @dev The `TimelockController` itself: `minDelay = 0` for the bootstrap, an **open executor** (the plan's
    ///      `EXECUTOR_ROLE = address(0)`, so anyone may execute a matured operation), the proposer Safe and the
    ///      deployer as proposers, and **no admin** — the timelock administers itself, which is what lets
    ///      `finalize` revoke the deployer through the timelock rather than through a privileged key.
    function _deployTimelock(Config memory cfg) private returns (address timelock) {
        address[] memory proposers = new address[](cfg.proposerSafe == address(0) ? 1 : 2);
        proposers[0] = cfg.deployer;
        if (cfg.proposerSafe != address(0)) proposers[1] = cfg.proposerSafe;
        address[] memory executors = new address[](1); // address(0) == open executor

        vm.startBroadcast(cfg.deployer);
        timelock = address(new TimelockController(0, proposers, executors, address(0)));
        vm.stopBroadcast();
        console2.log("TimelockController %s (minDelay 0 until CORE_STAGE=finalize)", timelock);
    }

    /// @dev `Amps`, `AmpsVault`, `AmpsHook`, `PoolRegistry` — the four mutually dependent addresses.
    function _deployCore(Config memory cfg, Set memory set) private {
        if (set.vault != address(0)) return;

        vm.startBroadcast(cfg.deployer);

        uint64 nonce = vm.getNonce(cfg.deployer);
        address predictedVault = vm.computeCreateAddress(cfg.deployer, nonce + 1);
        address predictedRegistry = vm.computeCreateAddress(cfg.deployer, nonce + 3);
        bytes32 salt = ampsSalt(cfg, predictedVault);

        Amps amps = new Amps{salt: salt}(predictedVault);
        AmpsVault vault = new AmpsVault(address(amps), cfg.poolManager, set.timelock, cfg.guardian);
        if (address(vault) != predictedVault) revert AddressPrediction("vault", predictedVault, address(vault));

        bytes memory hookArgs =
            abi.encode(cfg.poolManager, address(amps), address(vault), predictedRegistry, set.timelock);
        (address minedHook, bytes32 hookSalt) =
            HookMiner.find(FACTORY, HOOK_FLAGS, type(AmpsHook).creationCode, hookArgs);
        AmpsHook hook = new AmpsHook{salt: hookSalt}(
            IPoolManager(cfg.poolManager), address(amps), address(vault), predictedRegistry, set.timelock
        );
        if (address(hook) != minedHook) revert AddressPrediction("hook", minedHook, address(hook));
        _assertHookFlags(address(hook));

        PoolRegistry registry =
            new PoolRegistry(address(vault), address(hook), set.timelock, address(amps), cfg.weth9, cfg.usdg);
        if (address(registry) != predictedRegistry) {
            revert AddressPrediction("registry", predictedRegistry, address(registry));
        }

        vm.stopBroadcast();

        set.amps = address(amps);
        set.vault = address(vault);
        set.hook = address(hook);
        set.registry = address(registry);
    }

    /// @dev Everything that takes the four core addresses: the oracle layer, bonds, the bounty pot, the
    ///      valuer, the three pure policies, the quoter, the router and the team's vesting wallet.
    function _deployPeriphery(Config memory cfg, Set memory set) private {
        vm.startBroadcast(cfg.deployer);

        if (set.feedRegistry == address(0)) set.feedRegistry = address(new FeedRegistry(set.timelock, address(0)));
        if (set.oracleGate == address(0)) {
            set.oracleGate =
                address(new OracleGate(set.timelock, cfg.guardian, set.feedRegistry, set.registry, set.hook));
            _gateDeployedThisRun = true;
        }
        if (set.bondPolicy == address(0)) set.bondPolicy = address(new BondPolicy());
        if (set.bonds == address(0)) set.bonds = address(new AmpsBonds(set.vault, set.registry, set.bondPolicy));
        if (set.bountyPot == address(0)) set.bountyPot = address(new BountyPot(cfg.usdg, set.vault, set.timelock));
        if (set.positionValuer == address(0)) {
            set.positionValuer =
                address(new LadderPositionValuer(IExtsload(cfg.poolManager), set.vault, IPoolRegistry(set.registry)));
        }
        if (set.ladderPolicy == address(0)) set.ladderPolicy = address(new LadderPolicy());
        if (set.rolloutPolicy == address(0)) set.rolloutPolicy = address(new RolloutPolicy());
        if (set.feePolicy == address(0)) {
            set.feePolicy = address(
                new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18)
            );
        }
        if (set.teamVestingWallet == address(0)) {
            set.teamVestingWallet =
                address(new VestingWallet(cfg.teamBeneficiary, cfg.teamVestStart, Constants.TEAM_VEST_SECONDS));
        }
        if (set.quoter == address(0)) {
            set.quoter = address(
                new AmpsQuoter(
                    cfg.poolManager, set.hook, set.vault, set.registry, set.bonds, set.oracleGate, set.feedRegistry
                )
            );
        }
        // The protocol router. It is deployed here and *named* by `09_Phase3Wire`: `AmpsHook.setRouter` is the
        // pass-through exemption, a governed pointer, and until it is sent every hop in every pool pays
        // `ampsFeeBps`. Nothing else in the system points at this address, so a deploy that is never named is
        // inert rather than dangerous.
        if (set.router == address(0)) {
            set.router = address(new AmpsRouter(IPoolManager(cfg.poolManager), set.amps, set.registry, cfg.weth9));
        }

        vm.stopBroadcast();
    }

    /// @dev §9.1 step 1: every set-once vault pointer, the gate's calendar, and the guardian's canceller role.
    ///      `oracleGate` is deliberately left unset on the vault — a gate that is absent is exactly as permissive
    ///      as a gate that is `GREEN`, and that is what lets `05_Registry` open 32 pools whose observation rings
    ///      are empty. `09_Phase3Wire` moves it last.
    function _wire(Gov.Ctx memory ctx, Set memory set) private {
        Gov.begin(ctx);

        IAmpsVault vault = IAmpsVault(set.vault);
        if (vault.registry() == address(0)) {
            Gov.send(ctx, set.vault, abi.encodeCall(IAmpsVault.setPolicyPointer, (bytes32("registry"), set.registry)));
        }
        if (vault.bonds() == address(0)) {
            Gov.send(ctx, set.vault, abi.encodeCall(IAmpsVault.setPolicyPointer, (bytes32("bonds"), set.bonds)));
        }
        if (vault.bountyPot() == address(0)) {
            Gov.send(ctx, set.vault, abi.encodeCall(IAmpsVault.setPolicyPointer, (bytes32("bountyPot"), set.bountyPot)));
        }
        if (vault.feedRegistry() != set.feedRegistry) {
            Gov.send(
                ctx, set.vault, abi.encodeCall(IAmpsVault.setPolicyPointer, (bytes32("feedRegistry"), set.feedRegistry))
            );
        }
        if (vault.marketReference() != set.hook) {
            Gov.send(
                ctx, set.vault, abi.encodeCall(IAmpsVault.setPolicyPointer, (bytes32("marketReference"), set.hook))
            );
        }
        if (vault.positionValuer() != set.positionValuer) {
            Gov.send(
                ctx,
                set.vault,
                abi.encodeCall(IAmpsVault.setPolicyPointer, (bytes32("positionValuer"), set.positionValuer))
            );
        }
        if (IFeedRegistry(set.feedRegistry).oracleGate() != set.oracleGate) {
            Gov.send(ctx, set.feedRegistry, abi.encodeCall(IFeedRegistry.setOracleGate, (set.oracleGate)));
        }

        if (_gateDeployedThisRun) {
            Gov.send(
                ctx, set.oracleGate, abi.encodeCall(OracleGate.setDstTable, (Calendar.dstStarts(), Calendar.dstEnds()))
            );
            Gov.send(
                ctx,
                set.oracleGate,
                abi.encodeCall(OracleGate.setHolidayBitmap, (Calendar.HOLIDAY_YEAR, Calendar.holidayBitmap()))
            );
        }

        // The guardian Safe is a canceller and nothing else. `TimelockController` grants CANCELLER_ROLE to every
        // proposer in its constructor, so the guardian — which must never be able to propose — is granted here,
        // through the timelock itself.
        if (ctx.relay && !ITimelock(set.timelock).hasRole(Gov.CANCELLER_ROLE, set.guardian)) {
            Gov.send(
                ctx,
                set.timelock,
                abi.encodeWithSignature("grantRole(bytes32,address)", Gov.CANCELLER_ROLE, set.guardian)
            );
        }

        Gov.end(ctx);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Hand-over
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The last governance action of a launch: raise `minDelay` from the bootstrap's zero to 48 h and
    ///         revoke the deployer's proposer and canceller roles, leaving the Safe as the only proposer, the
    ///         guardian as a canceller and the executor open.
    /// @dev Both calls go in one batch on purpose. Sent one at a time, executing `updateDelay` first would make
    ///      the second impossible to schedule at zero delay — and executing the revoke first would make the first
    ///      impossible to schedule at all. `TimelockController` checks the delay at `schedule` time, so a batch
    ///      scheduled while the delay is still zero executes both in order.
    /// @param cfg The inputs; only `timelock` and `deployer` are read.
    function finalize(Config memory cfg) public {
        address timelock = cfg.timelock;
        if (timelock == address(0)) revert MissingAddress("timelock");

        Gov.Ctx memory ctx = Gov.load(timelock);
        Gov.describe(ctx);
        // Hand-over only means something when the timelock is a real `TimelockController`. In direct mode the
        // "timelock" is an address the operator holds, `updateDelay` would be a call to an EOA, and the
        // assertions below would fail obscurely instead of saying so here.
        if (!ctx.relay) revert TimelockRequiresRelay();

        address[] memory targets = new address[](3);
        bytes[] memory datas = new bytes[](3);
        targets[0] = timelock;
        datas[0] = abi.encodeWithSignature("updateDelay(uint256)", uint256(Constants.TIMELOCK_FAST_SECONDS));
        targets[1] = timelock;
        datas[1] = abi.encodeWithSignature("revokeRole(bytes32,address)", Gov.PROPOSER_ROLE, ctx.sender);
        targets[2] = timelock;
        datas[2] = abi.encodeWithSignature("revokeRole(bytes32,address)", Gov.CANCELLER_ROLE, ctx.sender);

        Gov.begin(ctx);
        Gov.sendBatch(ctx, targets, datas);
        Gov.end(ctx);

        uint256 minDelay = ITimelock(timelock).getMinDelay();
        bool stillProposer = ITimelock(timelock).hasRole(Gov.PROPOSER_ROLE, ctx.sender);
        if (minDelay != Constants.TIMELOCK_FAST_SECONDS || stillProposer) {
            revert FinalizeFailed(minDelay, stillProposer);
        }
        console2.log("timelock finalised: minDelay %s s, deployer is no longer a proposer", minDelay);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Mining
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The AMPS CREATE2 salt this deployment will use: the configured one when there is one, otherwise a
    ///         freshly mined one.
    /// @dev Mining three leading zero bytes is ~16.7 million attempts and belongs off-chain
    ///      (`python3 script/mine-amps.py --vault <vault>`, then `AMPS_SALT=0x…`). The in-script miner exists so
    ///      a testnet or a local chain — where two zero bytes is plenty against ordinary CREATE addresses — needs
    ///      no second tool.
    /// @param cfg The inputs.
    /// @param vault The vault address the salt is bound to.
    /// @return salt The salt.
    function ampsSalt(Config memory cfg, address vault) public view returns (bytes32 salt) {
        bytes32 initHash = ampsInitCodeHash(vault);
        if (cfg.ampsSalt != bytes32(0)) {
            address predicted = create2Address(cfg.ampsSalt, initHash);
            if (uint160(predicted) >= (uint160(1) << (8 * (20 - cfg.ampsZeroBytes)))) {
                revert WeakAmpsSalt(cfg.ampsSalt, predicted);
            }
            return cfg.ampsSalt;
        }

        uint160 ceiling = uint160(1) << (8 * (20 - cfg.ampsZeroBytes));
        uint256 tries = vm.envOr("AMPS_MINE_MAX_TRIES", MINE_MAX_TRIES_DEFAULT);
        for (uint256 i; i < tries; ++i) {
            salt = bytes32(i);
            // The floor keeps the search out of the precompile range, where an address is unusable as a token.
            uint160 candidate = uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, salt, initHash))));
            if (candidate < ceiling && candidate > 0xffff) return salt;
        }
        revert NoAmpsSalt(cfg.ampsZeroBytes, tries);
    }

    /// @notice `keccak256(type(Amps).creationCode ++ abi.encode(vault))`.
    /// @param vault The vault the token is bound to.
    /// @return hash The init code hash.
    function ampsInitCodeHash(address vault) public pure returns (bytes32 hash) {
        hash = keccak256(abi.encodePacked(type(Amps).creationCode, abi.encode(vault)));
    }

    /// @notice The CREATE2 address for `salt` under the canonical factory.
    /// @param salt The salt.
    /// @param initCodeHash The init code hash.
    /// @return predicted The address.
    function create2Address(bytes32 salt, bytes32 initCodeHash) public pure returns (address predicted) {
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, salt, initCodeHash)))));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The inputs, from `script/config/deployments.json` with the environment winning.
    /// @return cfg The config.
    function loadConfig() public view returns (Config memory cfg) {
        string memory json = vm.readFile(DEPLOYMENTS_PATH);
        bool relay = vm.envOr("AMPS_GOV_RELAY", false);

        cfg.timelock = _address(json, ".core.timelock", "AMPS_TIMELOCK");
        cfg.deployer = vm.envOr("AMPS_DEPLOYER", cfg.timelock);
        if (cfg.timelock == address(0) && !relay) revert TimelockRequiresRelay();

        cfg.proposerSafe = vm.envOr("CORE_PROPOSER_SAFE", address(0));
        cfg.guardian = _address(json, ".core.guardian", "AMPS_GUARDIAN");
        cfg.creator = _address(json, ".core.creator", "AMPS_CREATOR");
        cfg.teamBeneficiary = vm.envOr("AMPS_TEAM_BENEFICIARY", cfg.creator);
        cfg.teamVestStart = uint64(vm.envOr("AMPS_TEAM_VEST_START", block.timestamp));
        cfg.poolManager = _address(json, ".core.poolManager", "AMPS_POOL_MANAGER");
        cfg.weth9 = _address(json, ".core.weth9", "AMPS_WETH9");
        cfg.usdg = _address(json, ".core.usdg", "AMPS_USDG");
        cfg.ampsSalt = vm.envOr("AMPS_SALT", bytes32(0));
        cfg.ampsZeroBytes = uint8(vm.envOr("AMPS_ZERO_BYTES", uint256(AMPS_ZERO_BYTES_DEFAULT)));
    }

    /// @notice What `deployments.json` already names, so a re-run redeploys nothing.
    /// @return set The recorded addresses.
    function readDeployments() public view returns (Set memory set) {
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
        set.bountyPot = _address(json, ".core.bountyPot", "AMPS_BOUNTY_POT");
        set.feedRegistry = _address(json, ".core.feedRegistry", "AMPS_FEED_REGISTRY");
        set.oracleGate = _address(json, ".core.oracleGate", "AMPS_ORACLE_GATE");
        set.positionValuer = _address(json, ".core.positionValuer", "AMPS_POSITION_VALUER");
        set.ladderPolicy = _address(json, ".core.ladderPolicy", "AMPS_LADDER_POLICY");
        set.rolloutPolicy = _address(json, ".core.rolloutPolicy", "AMPS_ROLLOUT_POLICY");
        set.feePolicy = _address(json, ".core.feePolicy", "AMPS_FEE_POLICY");
        set.bondPolicy = _address(json, ".core.bondPolicy", "AMPS_BOND_POLICY");
        set.quoter = _address(json, ".core.quoter", "AMPS_QUOTER");
        set.router = _address(json, ".core.router", "AMPS_ROUTER");
        set.weth9 = _address(json, ".core.weth9", "AMPS_WETH9");
        set.usdg = _address(json, ".core.usdg", "AMPS_USDG");
    }

    /// @notice Rewrites `script/config/deployments.json`.
    /// @param set The addresses to record.
    function writeDeployments(Set memory set) public {
        string memory core = "amplestocks.deployments.core";
        vm.serializeAddress(core, "timelock", set.timelock);
        vm.serializeAddress(core, "guardian", set.guardian);
        vm.serializeAddress(core, "creator", set.creator);
        vm.serializeAddress(core, "teamVestingWallet", set.teamVestingWallet);
        vm.serializeAddress(core, "poolManager", set.poolManager);
        vm.serializeAddress(core, "amps", set.amps);
        vm.serializeAddress(core, "vault", set.vault);
        vm.serializeAddress(core, "registry", set.registry);
        vm.serializeAddress(core, "hook", set.hook);
        vm.serializeAddress(core, "bonds", set.bonds);
        vm.serializeAddress(core, "bountyPot", set.bountyPot);
        vm.serializeAddress(core, "feedRegistry", set.feedRegistry);
        vm.serializeAddress(core, "oracleGate", set.oracleGate);
        vm.serializeAddress(core, "positionValuer", set.positionValuer);
        vm.serializeAddress(core, "ladderPolicy", set.ladderPolicy);
        vm.serializeAddress(core, "rolloutPolicy", set.rolloutPolicy);
        vm.serializeAddress(core, "feePolicy", set.feePolicy);
        vm.serializeAddress(core, "bondPolicy", set.bondPolicy);
        vm.serializeAddress(core, "quoter", set.quoter);
        vm.serializeAddress(core, "router", set.router);
        vm.serializeAddress(core, "weth9", set.weth9);
        string memory coreJson = vm.serializeAddress(core, "usdg", set.usdg);

        string memory root = "amplestocks.deployments";
        vm.serializeString(
            root,
            "$comment",
            "Written by script/03_Core.s.sol (and script/09_Phase3Wire.s.sol for oracleGate). Every entry may be "
            "overridden by the environment variable named beside it in envOverrides. This file is deployment "
            "state, not reference data: the Uniswap, Chainlink and asset addresses live in packages/config, "
            "script/config/preflight.json and script/config/constituents.json."
        );
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "network", vm.envOr("AMPS_NETWORK", string("unset")));
        vm.serializeString(root, "envOverrides", _envOverrides());
        string memory json = vm.serializeString(root, "core", coreJson);
        vm.writeJson(json, DEPLOYMENTS_PATH);
        console2.log("wrote %s", DEPLOYMENTS_PATH);
    }

    /// @notice Records every constructor argument, ABI-encoded exactly as `forge verify-contract` wants it.
    /// @dev Blockscout matches on the creation code, so a wrong argument blob is the single most common reason a
    ///      verification fails hours after the deployment. They are written here, at the moment they are known,
    ///      rather than reconstructed later from memory; `12_Verify` turns this file into the commands.
    /// @param set The addresses.
    function writeConstructorArgs(Set memory set) public {
        string[] memory items = new string[](14);
        items[0] = _argEntry("Amps", "src/token/Amps.sol:Amps", set.amps, abi.encode(set.vault));
        items[1] = _argEntry(
            "AmpsVault",
            "src/vault/AmpsVault.sol:AmpsVault",
            set.vault,
            abi.encode(set.amps, set.poolManager, set.timelock, set.guardian)
        );
        items[2] = _argEntry(
            "AmpsHook",
            "src/hook/AmpsHook.sol:AmpsHook",
            set.hook,
            abi.encode(set.poolManager, set.amps, set.vault, set.registry, set.timelock)
        );
        items[3] = _argEntry(
            "PoolRegistry",
            "src/registry/PoolRegistry.sol:PoolRegistry",
            set.registry,
            abi.encode(set.vault, set.hook, set.timelock, set.amps, set.weth9, set.usdg)
        );
        items[4] = _argEntry(
            "FeedRegistry",
            "src/oracle/FeedRegistry.sol:FeedRegistry",
            set.feedRegistry,
            abi.encode(set.timelock, address(0))
        );
        items[5] = _argEntry(
            "OracleGate",
            "src/oracle/OracleGate.sol:OracleGate",
            set.oracleGate,
            abi.encode(set.timelock, set.guardian, set.feedRegistry, set.registry, set.hook)
        );
        items[6] = _argEntry("BondPolicy", "src/policy/BondPolicy.sol:BondPolicy", set.bondPolicy, "");
        items[7] = _argEntry(
            "AmpsBonds",
            "src/bonds/AmpsBonds.sol:AmpsBonds",
            set.bonds,
            abi.encode(set.vault, set.registry, set.bondPolicy)
        );
        items[8] = _argEntry(
            "BountyPot",
            "src/keeper/BountyPot.sol:BountyPot",
            set.bountyPot,
            abi.encode(set.usdg, set.vault, set.timelock)
        );
        items[9] = _argEntry(
            "LadderPositionValuer",
            "src/valuer/LadderPositionValuer.sol:LadderPositionValuer",
            set.positionValuer,
            abi.encode(set.poolManager, set.vault, set.registry)
        );
        items[10] = _argEntry("LadderPolicy", "src/policy/LadderPolicy.sol:LadderPolicy", set.ladderPolicy, "");
        items[11] = _argEntry("RolloutPolicy", "src/policy/RolloutPolicy.sol:RolloutPolicy", set.rolloutPolicy, "");
        items[12] = _argEntry(
            "AmpsQuoter",
            "src/periphery/AmpsQuoter.sol:AmpsQuoter",
            set.quoter,
            abi.encode(set.poolManager, set.hook, set.vault, set.registry, set.bonds, set.oracleGate, set.feedRegistry)
        );
        items[13] = _argEntry(
            "AmpsRouter",
            "src/periphery/AmpsRouter.sol:AmpsRouter",
            set.router,
            abi.encode(set.poolManager, set.amps, set.registry, set.weth9)
        );

        string memory root = "amplestocks.args";
        vm.serializeString(
            root,
            "$comment",
            "Written by script/03_Core.s.sol. `args` is the ABI-encoded constructor argument blob, ready for "
            "`forge verify-contract --constructor-args`. FeePolicy, the TimelockController and the team "
            "VestingWallet carry value arguments and are emitted by script/12_Verify.s.sol, which reads their "
            "values from Constants and deployments.json."
        );
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "solc", "0.8.30");
        vm.serializeString(
            root, "compilerNote", "src/vault/*, src/bonds/* and src/hook/* compile at optimizer_runs = 200 via_ir"
        );
        string memory json = vm.serializeString(root, "contracts", items);
        vm.writeJson(json, ARGS_PATH);
        console2.log("wrote %s", ARGS_PATH);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    function _requireInputs(Config memory cfg) private pure {
        if (cfg.deployer == address(0)) revert MissingAddress("deployer");
        if (cfg.guardian == address(0)) revert MissingAddress("guardian");
        if (cfg.poolManager == address(0)) revert MissingAddress("poolManager");
        if (cfg.weth9 == address(0)) revert MissingAddress("weth9");
        if (cfg.usdg == address(0)) revert MissingAddress("usdg");
        if (cfg.teamBeneficiary == address(0)) revert MissingAddress("teamBeneficiary");
    }

    /// @dev The vault reaches all four libraries by `DELEGATECALL`, so a missing `--libraries` flag would either
    ///      fail the build or — worse — let `forge script` deploy its own copies at addresses nothing else knows.
    ///      A linked library call compiles to `PUSH20 <address>` followed by `DELEGATECALL`, so each address is
    ///      literally in the deployed runtime code: this scans for the four `02_Libraries` recorded and refuses if
    ///      any is absent. It proves presence, not the absence of others, which is all a link check can do.
    function _assertLinked(address vault) private view {
        string memory json = vm.readFile(LIBRARIES_PATH);
        string[4] memory names = ["VaultNavLib", "VaultRedeemLib", "VaultPlacementLib", "VaultRolloutLib"];
        bytes memory code = vault.code;
        for (uint256 i; i < names.length; ++i) {
            address library_ = json.readAddress(string.concat(".libraries.", names[i], ".address"));
            if (library_ == address(0)) revert LibraryUnrecorded(names[i]);
            if (!_containsAddress(code, library_)) revert LibraryUnlinked(names[i], library_);
        }
        console2.log("AmpsVault is linked against the four libraries in %s", LIBRARIES_PATH);
    }

    /// @dev Whether `code` contains the 20 bytes of `needle` anywhere.
    function _containsAddress(bytes memory code, address needle) private pure returns (bool found) {
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

    /// @dev The mined hook must carry `0x38C0` and none of the bits the design forbids. `BaseHook`'s constructor
    ///      already asserts the address against `getHookPermissions()`; this restates the forbidden ones (I13, I18)
    ///      so a future permission change cannot pass silently.
    function _assertHookFlags(address hook) private pure {
        uint160 flags = uint160(hook) & uint160(Hooks.ALL_HOOK_MASK);
        require(flags == HOOK_FLAGS, "hook flags");
        require(uint160(hook) & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG == 0, "beforeRemove bit");
        require(uint160(hook) & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG == 0, "afterRemove bit");
        require(uint160(hook) & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG == 0, "beforeSwapDelta bit");
        require(uint160(hook) & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG == 0, "afterSwapDelta bit");
    }

    /// @dev One contract's entry in `constructor-args.json`.
    function _argEntry(string memory name, string memory path, address deployed, bytes memory args)
        private
        returns (string memory json)
    {
        string memory obj = string.concat("amplestocks.args.", name);
        vm.serializeString(obj, "name", name);
        vm.serializeString(obj, "path", path);
        vm.serializeAddress(obj, "address", deployed);
        json = vm.serializeBytes(obj, "args", args);
    }

    /// @dev The environment-variable map `deployments.json` carries beside every address.
    function _envOverrides() private returns (string memory json) {
        string memory obj = "amplestocks.deployments.env";
        vm.serializeString(obj, "timelock", "AMPS_TIMELOCK");
        vm.serializeString(obj, "guardian", "AMPS_GUARDIAN");
        vm.serializeString(obj, "creator", "AMPS_CREATOR");
        vm.serializeString(obj, "teamVestingWallet", "AMPS_TEAM_VESTING");
        vm.serializeString(obj, "poolManager", "AMPS_POOL_MANAGER");
        vm.serializeString(obj, "amps", "AMPS_TOKEN");
        vm.serializeString(obj, "vault", "AMPS_VAULT");
        vm.serializeString(obj, "registry", "AMPS_REGISTRY");
        vm.serializeString(obj, "hook", "AMPS_HOOK");
        vm.serializeString(obj, "bonds", "AMPS_BONDS");
        vm.serializeString(obj, "bountyPot", "AMPS_BOUNTY_POT");
        vm.serializeString(obj, "feedRegistry", "AMPS_FEED_REGISTRY");
        vm.serializeString(obj, "oracleGate", "AMPS_ORACLE_GATE");
        vm.serializeString(obj, "positionValuer", "AMPS_POSITION_VALUER");
        vm.serializeString(obj, "ladderPolicy", "AMPS_LADDER_POLICY");
        vm.serializeString(obj, "rolloutPolicy", "AMPS_ROLLOUT_POLICY");
        vm.serializeString(obj, "feePolicy", "AMPS_FEE_POLICY");
        vm.serializeString(obj, "bondPolicy", "AMPS_BOND_POLICY");
        vm.serializeString(obj, "quoter", "AMPS_QUOTER");
        vm.serializeString(obj, "router", "AMPS_ROUTER");
        vm.serializeString(obj, "weth9", "AMPS_WETH9");
        json = vm.serializeString(obj, "usdg", "AMPS_USDG");
    }

    function _report(Set memory set) private pure {
        console2.log("timelock       %s", set.timelock);
        console2.log("amps           %s", set.amps);
        console2.log("vault          %s", set.vault);
        console2.log("hook           %s", set.hook);
        console2.log("registry       %s", set.registry);
        console2.log("feedRegistry   %s", set.feedRegistry);
        console2.log("oracleGate     %s", set.oracleGate);
        console2.log("bonds          %s", set.bonds);
        console2.log("bountyPot      %s", set.bountyPot);
        console2.log("positionValuer %s", set.positionValuer);
        console2.log("ladderPolicy   %s", set.ladderPolicy);
        console2.log("rolloutPolicy  %s", set.rolloutPolicy);
        console2.log("feePolicy      %s", set.feePolicy);
        console2.log("bondPolicy     %s", set.bondPolicy);
        console2.log("quoter         %s", set.quoter);
        console2.log("router         %s", set.router);
        console2.log("teamVesting    %s", set.teamVestingWallet);
    }

    function _address(string memory json, string memory path, string memory envName)
        private
        view
        returns (address value)
    {
        value = vm.envOr(envName, json.readAddress(path));
    }
}
