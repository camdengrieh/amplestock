// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsGenesis} from "../src/interfaces/IAmpsGenesis.sol";
import {IAmpsVault} from "../src/interfaces/IAmpsVault.sol";
import {IFeedRegistry} from "../src/interfaces/IFeedRegistry.sol";
import {Constants} from "../src/types/Constants.sol";
import {Gov} from "./lib/Gov.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/// @title GenesisAuction
/// @notice Bootstrap step 5a: `AmpsVault.genesisMint` — `S0` minted once, split 1,000 / 10,000 / 9,000 — followed
///         by `AmpsGenesis.createAuctions`, which deploys and funds the two Continuous Clearing Auctions.
///
///         Both calls are `onlyTimelock`, so both go through `script/lib/Gov.sol`: a direct call when the
///         configured timelock is an address the operator controls, `schedule(delay 0)` + `execute` when it is a
///         `TimelockController`.
///
/// @dev **Where this sits in the launch** (`docs/genesis-cca.md`):
///
///        1. `03_Core` — deploy everything, `AmpsGenesis` included, and wire the vault's set-once pointers.
///        2. `09_Phase3Wire --deferGate` — the six policy pointers *and* the `genesis` pointer, gate still unset.
///        3. `05_Registry REGISTRY_FEEDS_ONLY=true` — every feed, no pool. `genesisPlace` checkpoints, and a
///           checkpoint prices WETH9 and USDG; this script also reads WETH's feed when `ethUsdX18` is left at zero.
///        4. **this script** — `genesisMint`, then `createAuctions`. No pool exists yet and the gate pointer is
///           deliberately unset, so `_requireHealthy` passes and nothing can be priced against an `A` of zero.
///        5. bidding, for `durationHours` (72 h ≈ 2.59M blocks at 100 ms).
///        6. `06b_GenesisSettle` — permissionless `settle()`, which calls `genesisPlace` and sets `P_ref = P0`.
///        7. `05_Registry` in full — the 32 pools, each opened at `P0` because `PoolRegistry` anchors at
///           `pRefX18()`.
///        8. TWAP warm-up, then `09_Phase3Wire` again for the gate pointer, then `11_GenesisPlacement`.
///
/// @dev **What this script refuses to decide.** The tranche split is `Constants` and `genesisMint` rejects
///      anything else. The floor price is `$1.00` per AMPS and `AmpsGenesis` computes it from the currency's
///      decimals — a floor a config file could set is the one parameter a launch cannot take on trust. What
///      `script/config/genesis.json` does carry is the schedule (start, duration, claim delay), the tick spacing,
///      the graduation thresholds, the validation hook and the issuance steps.
///
/// @dev **The issuance schedule.** `auctionStepsData` is a concatenation of 8-byte words holding a per-block rate
///      in milli-bips and a block count, and `AmpsGenesis.createAuctions` rejects any blob whose rates do not
///      total `1e7` over exactly `endBlock - startBlock` blocks. Leaving `steps` as a single `{mps: 0, blocks: 0}`
///      entry asks this script to build the flat schedule: `floor(1e7 / n)` milli-bips per block, with the
///      remainder spread one milli-bip at a time across the last blocks of the window. Every block then issues
///      the same amount give or take one milli-bip, and the last blocks issue slightly *more* — upstream's own
///      warning is that a schedule which sells almost nothing at the end makes the final clearing price cheap to
///      manipulate, and the final clearing price is what `P0` is.
///
/// @dev **Usage.**
/// ```
///   # mint S0 and open the auctions, as the timelock
///   forge script script/06a_GenesisAuction.s.sol --broadcast --rpc-url $RPC $(cat script/config/libraries.flags)
///
///   # a dry run that only prints what it would build
///   forge script script/06a_GenesisAuction.s.sol
/// ```
contract GenesisAuction is Script {
    using stdJson for string;

    // -----------------------------------------------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The core deployment addresses.
    string internal constant DEPLOYMENTS_PATH = "./script/config/deployments.json";

    /// @notice The auction parameters.
    string internal constant GENESIS_PATH = "./script/config/genesis.json";

    /// @notice `1e7`: the issuance schedule's unit, milli-bips of the tranche.
    uint256 internal constant MPS = 1e7;

    /// @notice Robinhood Chain's block time in milliseconds. 100 ms, so an hour is 36,000 blocks. This is the
    ///         fallback for a `genesis.json` that leaves `blockMs` at zero, not the figure a launch uses.
    uint256 internal constant BLOCK_MS_DEFAULT = 100;

    // -----------------------------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The addresses this script calls into.
    /// @param timelock The 7-day timelock: the sole caller of both governed calls.
    /// @param vault `AmpsVault`.
    /// @param genesis `AmpsGenesis`.
    /// @param teamVestingWallet The OZ `VestingWallet` the 1,000 AMPS team tranche is minted to.
    /// @param creator The creator-fee recipient recorded at the mint.
    /// @param feedRegistry `FeedRegistry`, read only to fill in `ethUsdX18` when the config leaves it at zero.
    /// @param weth9 WETH9, whose feed answer that read uses.
    struct Wiring {
        address timelock;
        address vault;
        address genesis;
        address teamVestingWallet;
        address creator;
        address feedRegistry;
        address weth9;
    }

    /// @notice One leg's configuration, before it becomes an `IAmpsGenesis.AuctionSpec`.
    /// @param enabled Whether the leg runs at all.
    /// @param tickSpacing The Q96 price granularity.
    /// @param requiredCurrencyRaised The graduation threshold, in currency raw units.
    /// @param validationHook The bid validation hook, or zero.
    /// @param salt The CREATE2 salt.
    /// @param stepMps The per-block rates, parallel to `stepBlocks`. Empty or all-zero asks for a flat schedule.
    /// @param stepBlocks The block counts, parallel to `stepMps`.
    struct LegConfig {
        bool enabled;
        uint256 tickSpacing;
        uint128 requiredCurrencyRaised;
        address validationHook;
        bytes32 salt;
        uint24[] stepMps;
        uint40[] stepBlocks;
    }

    /// @notice The whole launch configuration.
    /// @param ethUsdX18 ETH/USD at creation, 18 decimals. Zero means "read the feed".
    /// @param startBlock The first issuance block.
    /// @param endBlock The block bidding closes on.
    /// @param claimBlock The block filled bidders may claim from.
    /// @param usdgLeg The USDG leg.
    /// @param ethLeg The native-ETH leg.
    struct LaunchConfig {
        uint256 ethUsdX18;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        LegConfig usdgLeg;
        LegConfig ethLeg;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A required address is zero.
    /// @param what Which one.
    error MissingAddress(string what);

    /// @notice Both legs are disabled, so there is no auction to run.
    error NoLegEnabled();

    /// @notice `ethUsdX18` is zero in the config and the feed registry cannot supply one either.
    error EthUsdUnavailable();

    /// @notice The vault's `genesis` pointer is not the adapter this script was given, so `genesisMint` would
    ///         refuse. `09_Phase3Wire` sets that pointer and must run first.
    /// @param wired What the vault holds.
    /// @param configured What the config names.
    error AdapterNotWired(address wired, address configured);

    // -----------------------------------------------------------------------------------------------------------
    // Entry points
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Runs whichever of the two steps is still due and prints what it did.
    function run() external {
        Wiring memory w = loadWiring();
        LaunchConfig memory cfg = loadConfig(w);
        execute(w, cfg);
    }

    /// @notice Mints `S0` if it has not been minted, then creates the auctions if they do not exist. Idempotent.
    /// @param w The addresses.
    /// @param cfg The launch configuration.
    function execute(Wiring memory w, LaunchConfig memory cfg) public {
        if (w.timelock == address(0)) revert MissingAddress("timelock");
        if (w.vault == address(0)) revert MissingAddress("vault");
        if (w.genesis == address(0)) revert MissingAddress("genesis");
        if (w.teamVestingWallet == address(0)) revert MissingAddress("teamVestingWallet");
        if (w.creator == address(0)) revert MissingAddress("creator");
        if (!cfg.usdgLeg.enabled && !cfg.ethLeg.enabled) revert NoLegEnabled();

        IAmpsVault vault = IAmpsVault(w.vault);
        if (vault.genesis() != w.genesis) revert AdapterNotWired(vault.genesis(), w.genesis);

        Gov.Ctx memory ctx = Gov.load(w.timelock);
        Gov.describe(ctx);
        Gov.requireBootstrappable(ctx);

        if (!vault.genesisMinted()) {
            Gov.begin(ctx);
            Gov.send(
                ctx,
                w.vault,
                abi.encodeCall(
                    IAmpsVault.genesisMint,
                    (IAmpsVault.GenesisMintParams({
                            teamVestingWallet: w.teamVestingWallet,
                            creator: w.creator,
                            genesis: w.genesis,
                            teamShares: Constants.TEAM_SHARES,
                            auctionShares: Constants.AUCTION_SHARES,
                            polShares: Constants.POL_SHARES
                        }))
                )
            );
            Gov.end(ctx);
            console2.log("genesisMint: S0 minted, creator %s, adapter %s", w.creator, w.genesis);
        } else {
            console2.log("genesisMint already done");
        }

        IAmpsGenesis adapter = IAmpsGenesis(w.genesis);
        if (adapter.usdgAuction() == address(0) && adapter.ethAuction() == address(0)) {
            (IAmpsGenesis.AuctionSpec memory usdgSpec, IAmpsGenesis.AuctionSpec memory ethSpec) = buildSpecs(cfg);
            Gov.begin(ctx);
            Gov.send(ctx, w.genesis, abi.encodeCall(IAmpsGenesis.createAuctions, (usdgSpec, ethSpec, cfg.ethUsdX18)));
            Gov.end(ctx);
            console2.log("createAuctions: usdg %s, eth %s", adapter.usdgAuction(), adapter.ethAuction());
            console2.log("floors Q96: usdg %s, eth %s", adapter.floorUsdgQ96(), adapter.floorEthQ96());
            console2.log("bidding blocks %s -> %s", cfg.startBlock, cfg.endBlock);
        } else {
            console2.log("auctions already created: usdg %s, eth %s", adapter.usdgAuction(), adapter.ethAuction());
        }
    }

    /// @notice Turns the launch configuration into the two `AuctionSpec`s `createAuctions` takes.
    /// @param cfg The launch configuration.
    /// @return usdgSpec The USDG leg. `shares == 0` when it is disabled.
    /// @return ethSpec The native-ETH leg. `shares == 0` when it is disabled.
    function buildSpecs(LaunchConfig memory cfg)
        public
        pure
        returns (IAmpsGenesis.AuctionSpec memory usdgSpec, IAmpsGenesis.AuctionSpec memory ethSpec)
    {
        usdgSpec = _spec(cfg, cfg.usdgLeg, uint128(Constants.AUCTION_USDG_SHARES));
        ethSpec = _spec(cfg, cfg.ethLeg, uint128(Constants.AUCTION_ETH_SHARES));
    }

    /// @notice The flat issuance schedule over `blocks` blocks: `floor(1e7 / blocks)` milli-bips per block, with
    ///         the `1e7 mod blocks` remainder spread one milli-bip at a time over the **last** blocks of the
    ///         window rather than dumped into a single final step.
    ///
    /// @dev That distinction matters at the real launch size and nowhere else. 72 h at 100 ms is 2,592,000
    ///      blocks, and `1e7 / 2,592,000` truncates to 3 — which leaves 22% of the tranche unissued. Piling that
    ///      into one last step would sell 22% of the supply in a single block, which is precisely the shape
    ///      upstream warns makes the final clearing price cheap to manipulate. Spread instead, every block issues
    ///      either 3 or 4 milli-bips and the schedule is very slightly increasing, which is the shape upstream
    ///      recommends.
    /// @param blocks The auction's block window.
    /// @return stepMps The per-block rates.
    /// @return stepBlocks The block counts, parallel to `stepMps`.
    function flatSchedule(uint64 blocks) public pure returns (uint24[] memory stepMps, uint40[] memory stepBlocks) {
        require(blocks != 0, "06a: zero-length auction");
        uint256 perBlock = MPS / uint256(blocks);
        uint256 remainder = MPS - perBlock * uint256(blocks);

        if (remainder == 0) {
            stepMps = new uint24[](1);
            stepBlocks = new uint40[](1);
            stepMps[0] = uint24(perBlock);
            stepBlocks[0] = uint40(blocks);
            return (stepMps, stepBlocks);
        }

        // `remainder < blocks`, so the two steps are both non-empty and
        // `perBlock * (blocks - remainder) + (perBlock + 1) * remainder == 1e7` exactly.
        stepMps = new uint24[](2);
        stepBlocks = new uint40[](2);
        stepMps[0] = uint24(perBlock);
        stepBlocks[0] = uint40(uint256(blocks) - remainder);
        stepMps[1] = uint24(perBlock + 1);
        stepBlocks[1] = uint40(remainder);
    }

    /// @notice Packs a schedule the way upstream `AuctionStepLib.parse` reads it.
    /// @param stepMps The per-block rates.
    /// @param stepBlocks The block counts.
    /// @return data The packed blob.
    function packSteps(uint24[] memory stepMps, uint40[] memory stepBlocks) public pure returns (bytes memory data) {
        require(stepMps.length == stepBlocks.length, "06a: step arrays");
        for (uint256 i; i < stepMps.length; ++i) {
            data = bytes.concat(data, bytes8((uint64(stepMps[i]) << 40) | uint64(stepBlocks[i])));
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
        w.teamVestingWallet = _address(json, ".core.teamVestingWallet", "AMPS_TEAM_VESTING");
        w.creator = _address(json, ".core.creator", "AMPS_CREATOR");
        w.feedRegistry = _address(json, ".core.feedRegistry", "AMPS_FEED_REGISTRY");
        w.weth9 = _address(json, ".core.weth9", "AMPS_WETH9");
    }

    /// @notice The launch configuration, from `script/config/genesis.json` with the environment winning.
    /// @dev Block numbers are derived here rather than stored, so a re-run against a chain that has moved on
    ///      produces a schedule that is still in the future.
    /// @param w The addresses, for the optional ETH/USD feed read.
    /// @return cfg The configuration.
    function loadConfig(Wiring memory w) public view returns (LaunchConfig memory cfg) {
        string memory json = vm.readFile(GENESIS_PATH);

        uint256 blockMs = vm.envOr("AMPS_BLOCK_MS", json.readUint(".blockMs"));
        if (blockMs == 0) blockMs = BLOCK_MS_DEFAULT;
        uint256 startDelay = vm.envOr("AMPS_AUCTION_START_DELAY_HOURS", json.readUint(".startDelayHours"));
        uint256 duration = vm.envOr("AMPS_AUCTION_DURATION_HOURS", json.readUint(".durationHours"));
        uint256 claimDelay = vm.envOr("AMPS_AUCTION_CLAIM_DELAY_HOURS", json.readUint(".claimDelayHours"));

        uint256 blocksPerHour = (3600 * 1000) / blockMs;
        // A rehearsal on a chain nobody is going to mine 2.59 million blocks on needs the window in blocks
        // rather than in hours. `test/script/broadcast.sh` is the caller; a mainnet run leaves both unset.
        uint256 startBlocks = vm.envOr("AMPS_AUCTION_START_BLOCKS", startDelay * blocksPerHour);
        uint256 windowBlocks = vm.envOr("AMPS_AUCTION_WINDOW_BLOCKS", duration * blocksPerHour);
        cfg.startBlock = uint64(block.number + startBlocks);
        cfg.endBlock = uint64(uint256(cfg.startBlock) + windowBlocks);
        cfg.claimBlock = uint64(uint256(cfg.endBlock) + claimDelay * blocksPerHour);

        cfg.ethUsdX18 = vm.envOr("AMPS_ETH_USD_X18", json.readUint(".ethUsdX18"));
        if (cfg.ethUsdX18 == 0) cfg.ethUsdX18 = _feedEthUsdX18(w);
        if (cfg.ethUsdX18 == 0) revert EthUsdUnavailable();

        cfg.usdgLeg = _leg(json, ".usdg", "AMPS_AUCTION_USDG_ENABLED", "AMPS_AUCTION_USDG_REQUIRED");
        cfg.ethLeg = _leg(json, ".eth", "AMPS_AUCTION_ETH_ENABLED", "AMPS_AUCTION_ETH_REQUIRED");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev One leg's `AuctionSpec`, with the flat schedule filled in when the config asked for one.
    function _spec(LaunchConfig memory cfg, LegConfig memory leg, uint128 shares)
        private
        pure
        returns (IAmpsGenesis.AuctionSpec memory spec)
    {
        if (!leg.enabled) return spec;

        uint24[] memory stepMps = leg.stepMps;
        uint40[] memory stepBlocks = leg.stepBlocks;
        if (stepMps.length == 0 || (stepMps.length == 1 && stepMps[0] == 0)) {
            (stepMps, stepBlocks) = flatSchedule(cfg.endBlock - cfg.startBlock);
        }

        spec = IAmpsGenesis.AuctionSpec({
            shares: shares,
            startBlock: cfg.startBlock,
            endBlock: cfg.endBlock,
            claimBlock: cfg.claimBlock,
            tickSpacing: leg.tickSpacing,
            validationHook: leg.validationHook,
            requiredCurrencyRaised: leg.requiredCurrencyRaised,
            auctionStepsData: packSteps(stepMps, stepBlocks),
            salt: leg.salt
        });
    }

    /// @dev One `{mps, blocks}` entry of a leg's issuance schedule, as `vm.parseJson` decodes it: the fields
    ///      must stay in **alphabetical** order, because that is the order the cheatcode ABI-encodes JSON keys in.
    struct StepJson {
        uint256 blocks;
        uint256 mps;
    }

    /// @dev One leg out of the JSON.
    function _leg(string memory json, string memory key, string memory enabledEnv, string memory requiredEnv)
        private
        view
        returns (LegConfig memory leg)
    {
        leg.enabled = vm.envOr(enabledEnv, json.readBool(string.concat(key, ".enabled")));
        leg.tickSpacing = vm.parseUint(json.readString(string.concat(key, ".tickSpacing")));
        leg.requiredCurrencyRaised = uint128(
            vm.envOr(requiredEnv, vm.parseUint(json.readString(string.concat(key, ".requiredCurrencyRaised"))))
        );
        leg.validationHook =
            vm.envOr("AMPS_AUCTION_VALIDATION_HOOK", json.readAddress(string.concat(key, ".validationHook")));
        leg.salt = json.readBytes32(string.concat(key, ".salt"));

        // Decoded as a struct array rather than read with two `steps[*].field` queries: a JSONPath wildcard over
        // a **one-element** array yields the scalar rather than a one-element array, and `parseJsonUintArray`
        // then fails to parse `0` as `uint256[]` — which is exactly the shape the shipped config has, because a
        // single `{mps: 0, blocks: 0}` entry is how a proposal asks for the flat schedule.
        StepJson[] memory steps = abi.decode(vm.parseJson(json, string.concat(key, ".steps")), (StepJson[]));
        leg.stepMps = new uint24[](steps.length);
        leg.stepBlocks = new uint40[](steps.length);
        for (uint256 i; i < steps.length; ++i) {
            leg.stepMps[i] = uint24(steps[i].mps);
            leg.stepBlocks[i] = uint40(steps[i].blocks);
        }
    }

    /// @dev WETH's 18-decimal USD price out of the configured feed registry, or zero when it cannot be read.
    function _feedEthUsdX18(Wiring memory w) private view returns (uint256 price18) {
        if (w.feedRegistry == address(0) || w.weth9 == address(0)) return 0;
        try IFeedRegistry(w.feedRegistry).latestAnswerUsd18(w.weth9) returns (uint256 answer, uint32, bool) {
            return answer;
        } catch {
            return 0;
        }
    }

    function _address(string memory json, string memory path, string memory envName)
        private
        view
        returns (address value)
    {
        value = vm.envOr(envName, json.readAddress(path));
    }
}
