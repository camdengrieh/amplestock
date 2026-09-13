// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsGenesis} from "../src/interfaces/IAmpsGenesis.sol";
import {IAmpsVault} from "../src/interfaces/IAmpsVault.sol";
import {Constants} from "../src/types/Constants.sol";
import {Gov} from "./lib/Gov.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/// @title GenesisSettle
/// @notice Bootstrap step 5b: `AmpsGenesis.settle()` — permissionless, once, after both auctions' end blocks —
///         and, when no leg graduated, the timelock's fallback `AmpsVault.genesisPlace` with the founders' seed.
///
/// @dev **`settle()` needs no signer of consequence.** It sweeps each graduated leg's currency and every leg's
///      unsold tokens, wraps the ETH into WETH9, derives `P0` from the clearing price and calls
///      `AmpsVault.genesisPlace` in the same transaction. Anyone may call it; a keeper job does so the block
///      after `endBlock`, and this script is what the operator runs by hand. It is broadcast by `AMPS_DEPLOYER`
///      when one is configured and by the timelock otherwise, purely because something has to pay the gas.
///
/// @dev **The fallback.** If neither leg reached its `requiredCurrencyRaised`, `settle()` returns the whole
///      auction tranche to the vault and calls nothing: bidders refund themselves through the auctions, and the
///      launch proceeds through the founders' seed exactly as it did before revision 7. This script then makes
///      the two governed calls that path needs — approve the seed out of the timelock, and `genesisPlace` with
///      `p0X18 = 1e18` — so the operator does not have to assemble them under pressure. The amounts come from
///      `script/config/genesis.json`'s `fallback` block and the assets must already be sitting in the timelock.
///
/// @dev **What must not have happened yet.** No pool exists at this point and the vault's gate pointer is still
///      unset: `05_Registry` opens all 32 pools *after* this script, at `pRefX18()`, which is what makes them
///      open at `P0` (`docs/phase3-state-model.md` §12 ruling C). Running `05_Registry` first would open every
///      pool at the $1.00 fallback anchor and leave the ladders a whole grid away from the market.
///
/// @dev **Usage.**
/// ```
///   # settle the auctions and hand the proceeds to the vault
///   forge script script/06b_GenesisSettle.s.sol --broadcast --rpc-url $RPC $(cat script/config/libraries.flags)
///
///   # read-only: what would happen
///   forge script script/06b_GenesisSettle.s.sol
/// ```
contract GenesisSettle is Script {
    using stdJson for string;

    // -----------------------------------------------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The core deployment addresses.
    string internal constant DEPLOYMENTS_PATH = "./script/config/deployments.json";

    /// @notice The launch parameters, for the fallback seed.
    string internal constant GENESIS_PATH = "./script/config/genesis.json";

    // -----------------------------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The addresses this script calls into.
    /// @param timelock The 7-day timelock: the caller of the fallback `genesisPlace`.
    /// @param vault `AmpsVault`.
    /// @param genesis `AmpsGenesis`.
    /// @param weth9 WETH9.
    /// @param usdg USDG.
    struct Wiring {
        address timelock;
        address vault;
        address genesis;
        address weth9;
        address usdg;
    }

    /// @notice The founders' seed used only when nothing graduated.
    /// @param p0X18 The launch reference. `1e18` — $1.00 — by construction.
    /// @param seedWeth WETH wei pulled from the timelock.
    /// @param seedUsdg USDG raw units pulled from the timelock.
    struct Fallback {
        uint256 p0X18;
        uint256 seedWeth;
        uint256 seedUsdg;
    }

    /// @notice What one run did.
    /// @param settled Whether {settle} ran this time or had already run.
    /// @param graduated Whether at least one leg graduated.
    /// @param p0X18 The launch reference the vault ended up with.
    /// @param raisedUsdg USDG raw units the vault took.
    /// @param raisedWeth WETH wei the vault took.
    /// @param unsoldAmps AMPS wei that came back as inventory.
    /// @param fallbackRan Whether this run made the fallback `genesisPlace` call.
    struct Report {
        bool settled;
        bool graduated;
        uint256 p0X18;
        uint256 raisedUsdg;
        uint256 raisedWeth;
        uint256 unsoldAmps;
        bool fallbackRan;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A required address is zero.
    /// @param what Which one.
    error MissingAddress(string what);

    /// @notice `06a_GenesisAuction` has not run: there is no auction to settle.
    error AuctionsNotCreated();

    /// @notice The adapter is still taking bids.
    /// @param current The current block.
    error StillBidding(uint256 current);

    /// @notice `05_Registry` has already opened pools, so the anchor the launch would use is the $1.00 fallback
    ///         rather than `P0` and the ladders would sit a grid away from the market.
    /// @param pools How many pools are registered.
    error PoolsAlreadyOpen(uint16 pools);

    // -----------------------------------------------------------------------------------------------------------
    // Entry points
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Settles, then falls back if nothing graduated. Idempotent: a completed launch is a no-op.
    function run() external {
        Wiring memory w = loadWiring();
        Report memory report = execute(w, loadFallback());
        console2.log("settled %s, graduated %s, P0 %s", report.settled, report.graduated, report.p0X18);
        console2.log("raised: %s USDG, %s WETH", report.raisedUsdg, report.raisedWeth);
        console2.log("unsold AMPS back to the vault: %s", report.unsoldAmps);
        if (report.fallbackRan) console2.log("no leg graduated: the founders' seed path ran instead");
    }

    /// @notice One run.
    /// @param w The addresses.
    /// @param fb The founders' seed, used only when nothing graduated.
    /// @return report What it did.
    function execute(Wiring memory w, Fallback memory fb) public returns (Report memory report) {
        if (w.vault == address(0)) revert MissingAddress("vault");
        if (w.genesis == address(0)) revert MissingAddress("genesis");
        if (w.timelock == address(0)) revert MissingAddress("timelock");

        IAmpsVault vault = IAmpsVault(w.vault);
        IAmpsGenesis adapter = IAmpsGenesis(w.genesis);

        assertReadyToSettle(w);

        if (!adapter.settled()) {
            // Permissionless: the broadcaster is whoever pays the gas, not a role.
            address sender = vm.envOr("AMPS_DEPLOYER", w.timelock);
            vm.startBroadcast(sender);
            adapter.settle();
            vm.stopBroadcast();
        }

        report.settled = adapter.settled();
        report.graduated = adapter.phase() == IAmpsGenesis.Phase.Settled;
        report.raisedUsdg = adapter.raisedUsdg();
        report.raisedWeth = adapter.raisedWeth();
        report.unsoldAmps = adapter.unsoldAmps();

        if (!vault.initialized()) {
            _fallbackPlace(w, fb);
            report.fallbackRan = true;
        }

        report.p0X18 = vault.pRefX18();
    }

    /// @notice The preconditions `settle()` itself cannot state: the auctions exist, bidding is over, and no pool
    ///         has been opened yet.
    /// @param w The addresses.
    function assertReadyToSettle(Wiring memory w) public view {
        IAmpsGenesis adapter = IAmpsGenesis(w.genesis);
        if (adapter.usdgAuction() == address(0) && adapter.ethAuction() == address(0)) revert AuctionsNotCreated();

        IAmpsGenesis.Phase current = adapter.phase();
        if (current == IAmpsGenesis.Phase.Created || current == IAmpsGenesis.Phase.Bidding) {
            revert StillBidding(block.number);
        }

        // `05_Registry` must come after this script, because `PoolRegistry` anchors every pool it opens at
        // `vault.pRefX18()` and that word is zero — the $1.00 fallback — until `genesisPlace` writes `P0`.
        if (!IAmpsVault(w.vault).initialized()) {
            address registry = IAmpsVault(w.vault).registry();
            if (registry != address(0)) {
                (bool ok, bytes memory data) = registry.staticcall(abi.encodeWithSignature("poolCount()"));
                if (ok && data.length >= 32) {
                    uint16 pools = abi.decode(data, (uint16));
                    if (pools != 0) revert PoolsAlreadyOpen(pools);
                }
            }
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The addresses, from `script/config/deployments.json` with the environment winning.
    /// @return w The addresses.
    function loadWiring() public view returns (Wiring memory w) {
        string memory json = vm.readFile(DEPLOYMENTS_PATH);
        w.timelock = _address(json, ".core.timelock", "AMPS_TIMELOCK");
        w.vault = _address(json, ".core.vault", "AMPS_VAULT");
        w.genesis = _address(json, ".core.genesis", "AMPS_GENESIS");
        w.weth9 = _address(json, ".core.weth9", "AMPS_WETH9");
        w.usdg = _address(json, ".core.usdg", "AMPS_USDG");
    }

    /// @notice The founders' seed, from `script/config/genesis.json` with the environment winning.
    /// @return fb The fallback parameters.
    function loadFallback() public view returns (Fallback memory fb) {
        string memory json = vm.readFile(GENESIS_PATH);
        fb.p0X18 = vm.parseUint(json.readString(".fallback.p0X18"));
        fb.seedWeth = vm.envOr("AMPS_SEED_WETH", vm.parseUint(json.readString(".fallback.seedWeth")));
        fb.seedUsdg = vm.envOr("AMPS_SEED_USDG", vm.parseUint(json.readString(".fallback.seedUsdg")));
        if (fb.p0X18 == 0) fb.p0X18 = Constants.WAD;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The founders' seed path: approve out of the timelock, then `genesisPlace` at $1.00. Both are governed
    ///      calls, because `genesisPlace` pulls from `msg.sender` and the caller rule is adapter-or-timelock.
    function _fallbackPlace(Wiring memory w, Fallback memory fb) private {
        uint256 count;
        if (fb.seedWeth != 0) ++count;
        if (fb.seedUsdg != 0) ++count;
        require(count != 0, "06b: fallback seed is empty");

        address[] memory tokens = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 i;
        if (fb.seedWeth != 0) {
            tokens[i] = w.weth9;
            amounts[i] = fb.seedWeth;
            ++i;
        }
        if (fb.seedUsdg != 0) {
            tokens[i] = w.usdg;
            amounts[i] = fb.seedUsdg;
        }

        Gov.Ctx memory ctx = Gov.load(w.timelock);
        Gov.describe(ctx);
        Gov.begin(ctx);
        for (uint256 j; j < count; ++j) {
            Gov.send(ctx, tokens[j], abi.encodeCall(IERC20.approve, (w.vault, amounts[j])));
        }
        Gov.send(
            ctx,
            w.vault,
            abi.encodeCall(
                IAmpsVault.genesisPlace,
                (IAmpsVault.GenesisPlaceParams({p0X18: fb.p0X18, tokens: tokens, amounts: amounts, unsoldAmps: 0}))
            )
        );
        Gov.end(ctx);
    }

    function _address(string memory json, string memory path, string memory envName)
        private
        view
        returns (address value)
    {
        value = vm.envOr(envName, json.readAddress(path));
    }
}
