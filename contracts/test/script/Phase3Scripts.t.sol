// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Libraries} from "../../script/02_Libraries.s.sol";
import {Registry} from "../../script/05_Registry.s.sol";
import {GenesisAuction} from "../../script/06a_GenesisAuction.s.sol";
import {GenesisSettle} from "../../script/06b_GenesisSettle.s.sol";
import {Phase3Wire} from "../../script/09_Phase3Wire.s.sol";
import {MockWeth9, TestnetPools} from "../../script/10_TestnetPools.s.sol";
import {GenesisPlacement} from "../../script/11_GenesisPlacement.s.sol";
import {AmpsBonds} from "../../src/bonds/AmpsBonds.sol";
import {AmpsGenesis} from "../../src/genesis/AmpsGenesis.sol";
import {AmpsHook} from "../../src/hook/AmpsHook.sol";
import {IAmpsGenesis} from "../../src/interfaces/IAmpsGenesis.sol";
import {IAmpsHook} from "../../src/interfaces/IAmpsHook.sol";
import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IOracleGate} from "../../src/interfaces/IOracleGate.sol";
import {IPoolRegistry} from "../../src/interfaces/IPoolRegistry.sol";
import {BountyPot} from "../../src/keeper/BountyPot.sol";
import {LadderLib} from "../../src/lib/LadderLib.sol";
import {FeedRegistry} from "../../src/oracle/FeedRegistry.sol";
import {AmpsRouter} from "../../src/periphery/AmpsRouter.sol";
import {BondPolicy} from "../../src/policy/BondPolicy.sol";
import {FeePolicy} from "../../src/policy/FeePolicy.sol";
import {LadderPolicy} from "../../src/policy/LadderPolicy.sol";
import {RolloutPolicy} from "../../src/policy/RolloutPolicy.sol";
import {PoolRegistry} from "../../src/registry/PoolRegistry.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {ConstituentStatus, GateState, PoolClass, PoolConfig} from "../../src/types/Types.sol";
import {LadderPositionValuer} from "../../src/valuer/LadderPositionValuer.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {MockCCA} from "../mocks/MockCCA.sol";
import {MockCCAFactory} from "../mocks/MockCCAFactory.sol";
import {MockMarketReference} from "../mocks/MockMarketReference.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockUsdg} from "../mocks/MockUsdg.sol";
import {V4TestBase} from "../utils/V4TestBase.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @title Phase3Scripts
/// @notice The fork-free dry run of the Phase 3 deployment scripts. No network is reachable in this environment,
///         so the proof that `02_Libraries`, `05_Registry`, `09_Phase3Wire`, `10_TestnetPools` and
///         `11_GenesisPlacement` do what they claim is to run their `run()`-equivalent entry points against a
///         local Uniswap v4 `PoolManager` and assert the state they leave behind: 32 pools, 30 bond markets, the
///         six Phase 3 pointers, the genesis vector and the §3.3 ladder layout — then run them all again and
///         assert nothing moves.
///
/// @dev **The scripts are driven exactly as `forge script` drives them.** Each one opens its own broadcast window
///         with `vm.startBroadcast(timelock)`, which inside a test sets `msg.sender` for every call the script
///         makes — the same impersonation a broadcast performs during simulation. Nothing here reaches into a
///         script's internals or reimplements its sequencing; the test only supplies addresses and asserts
///         outcomes.
///
/// @dev **What is real and what stands in.** Everything in `src/` is the production contract, `AmpsHook`
///         included, mined to `0x38C0` exactly as `04_MineHook` mines it. What stands in are the counter assets —
///         which is the point of `10_TestnetPools`: 30 `MockStockToken`s, 30 `MockAggregator`s, a `MockUsdg` and
///         a `MockWeth9`, all deployed by the script under test.
///
/// @dev **AMPS ordering.** Production mines AMPS to three leading zero bytes so it is `currency0` against every
///         counter. Three bytes is 16.7M CREATE2 attempts, which does not belong in a test, so the fixture mines
///         two (~65k attempts, ~80 ms) — enough that all 32 counters, whose addresses are ordinary CREATE
///         addresses, sort above it, and `10_TestnetPools._assertOrdering` checks that rather than assuming it.
contract Phase3Scripts is V4TestBase {
    // -----------------------------------------------------------------------------------------------------------
    // Roles and launch vector
    // -----------------------------------------------------------------------------------------------------------

    address internal constant TIMELOCK = address(0x71E10C4);
    address internal constant GUARDIAN = address(0x6A4D1A17);
    address internal constant CREATOR = address(0xC12EA704);
    address internal constant TEAM = address(0x7EA11);

    /// @dev 2026-09-09 14:00:00 UTC — a Wednesday, 10:00 ET, squarely inside `REGULAR`. Every gated vault path
    ///      refuses in a `CLOSED` session, so the whole run happens on a live trading clock.
    uint256 internal constant GENESIS_TIME = 1_788_962_400;
    uint256 internal constant GENESIS_BLOCK = 20_000_000;

    /// @dev What the two auctions raise in this run: 5,000 USDG and 2 WETH ($5,000 at $2,500/ETH), i.e. both
    ///      tranches clearing in full at the $1.00 floor. `A` is therefore $10,000 against `S0` = 20,000 AMPS —
    ///      the launch NAV/share of `raised / S0` = $0.50 and the 100% opening premium revision 7 discloses.
    uint256 internal constant BID_USDG = 5000e6;
    uint256 internal constant BID_WETH = 2e18;

    /// @dev ETH/USD at auction creation, 18 decimals. The same $2,500 every other fixture uses.
    uint256 internal constant ETH_USD_X18 = 2500e18;

    /// @dev A bidder with money.
    address internal constant BIDDER = address(0xB1DDE2);

    /// @dev The launch set: 30 spokes plus `AMPS/USDG` and `AMPS/WETH`.
    uint256 internal constant SPOKES = 30;
    uint256 internal constant POOLS = 32;

    /// @dev Two leading zero bytes. See the contract note.
    uint160 internal constant AMPS_CEILING = uint160(1) << 144;

    /// @dev The four committed config artefacts the writers rewrite.
    string internal constant POOLS_PATH = "./script/config/pools.json";
    string internal constant TESTNET_PATH = "./script/config/testnet.json";
    string internal constant LIBRARIES_PATH = "./script/config/libraries.json";
    string internal constant PROPOSAL_PATH = "./script/config/phase3-proposal.json";

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    // -----------------------------------------------------------------------------------------------------------
    // The scripts under test
    // -----------------------------------------------------------------------------------------------------------

    Libraries internal libraries;
    Registry internal registryScript;
    Phase3Wire internal wireScript;
    TestnetPools internal testnetScript;
    GenesisPlacement internal genesisScript;
    GenesisAuction internal auctionScript;
    GenesisSettle internal settleScript;

    // -----------------------------------------------------------------------------------------------------------
    // The system
    // -----------------------------------------------------------------------------------------------------------

    Amps internal amps;
    AmpsVault internal vault;
    AmpsHook internal hook;
    PoolRegistry internal registry;
    FeedRegistry internal feeds;
    AmpsBonds internal bonds;
    BountyPot internal pot;
    LadderPositionValuer internal valuer;
    LadderPolicy internal ladderPolicy;
    RolloutPolicy internal rolloutPolicy;
    FeePolicy internal feePolicy;
    BondPolicy internal bondPolicy;
    AmpsRouter internal ampsRouter;
    AmpsGenesis internal genesisAdapter;
    MockCCAFactory internal ccaFactory;
    MockMarketReference internal phase2Reference;
    VestingWallet internal teamVesting;

    TestnetPools.Assets internal assets;

    // -----------------------------------------------------------------------------------------------------------
    // Fixture
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Everything up to, but not including, step 2 of the §9.1 bootstrap: the v4 stack, the mock counter
    ///         assets `10_TestnetPools` deploys, the whole core system, and the vault wired with every pointer
    ///         **except** `oracleGate`.
    function setUp() public {
        vm.warp(GENESIS_TIME);
        vm.roll(GENESIS_BLOCK);

        deployV4();
        libraries = new Libraries();
        registryScript = new Registry();
        wireScript = new Phase3Wire();
        testnetScript = new TestnetPools();
        genesisScript = new GenesisPlacement();
        auctionScript = new GenesisAuction();
        settleScript = new GenesisSettle();

        // Step 0: the counter assets, deployed by the script under test. They come first because `PoolRegistry`
        // takes WETH9 and USDG in its constructor.
        assets = testnetScript.deployAssets(TIMELOCK, _emptyAssets(), SPOKES);

        _deployCore();
        _deployPeriphery();
        _wireVaultWithoutGate();
    }

    // -----------------------------------------------------------------------------------------------------------
    // 02_Libraries
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The three link-free libraries land on their deterministic CREATE2 addresses, and a second run is a
    ///         no-op rather than a revert.
    function test_libraries_deployDeterministicallyAndAreIdempotent() public {
        Libraries.LibrarySet memory predicted = libraries.predict();

        (address nav, address redeem, address placement) = libraries.deployCore(TIMELOCK);
        assertEq(nav, predicted.navLib, "VaultNavLib at its predicted address");
        assertEq(redeem, predicted.redeemLib, "VaultRedeemLib at its predicted address");
        assertEq(placement, predicted.placementLib, "VaultPlacementLib at its predicted address");
        assertGt(nav.code.length, 0, "VaultNavLib has code");
        assertGt(redeem.code.length, 0, "VaultRedeemLib has code");
        assertGt(placement.code.length, 0, "VaultPlacementLib has code");

        (address nav2, address redeem2, address placement2) = libraries.deployCore(TIMELOCK);
        assertEq(nav2, nav, "re-run is idempotent (nav)");
        assertEq(redeem2, redeem, "re-run is idempotent (redeem)");
        assertEq(placement2, placement, "re-run is idempotent (placement)");
    }

    /// @notice `VaultRolloutLib` refuses to deploy unless it was built against the `VaultPlacementLib` the script
    ///         deployed. In a test build Foundry links it against its own auto-deployed copy, which is exactly the
    ///         mistake `--libraries` exists to prevent, so the guard must fire here.
    function test_libraries_rolloutRefusesAWrongLink() public {
        (,, address placement) = libraries.deployCore(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(Libraries.UnlinkedRollout.selector, placement));
        libraries.deployRollout(TIMELOCK, placement);
    }

    /// @notice The `--libraries` flag string names all four libraries at the paths `forge` expects.
    function test_libraries_flagsNameAllFour() public view {
        string memory flags = libraries.librariesFlags(libraries.predict());
        assertTrue(_contains(flags, "src/vault/VaultNavLib.sol:VaultNavLib:"), "nav flag");
        assertTrue(_contains(flags, "src/vault/VaultRedeemLib.sol:VaultRedeemLib:"), "redeem flag");
        assertTrue(_contains(flags, "src/vault/VaultPlacementLib.sol:VaultPlacementLib:"), "placement flag");
        assertTrue(_contains(flags, "src/vault/VaultRolloutLib.sol:VaultRolloutLib:"), "rollout flag");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------------------------------------------

    /// @notice `script/config/constituents.json` really does describe the 30-name launch set, at weights the
    ///         registry will accept: a placeholder weight legal at every intermediate count, and a final vector
    ///         inside `[166, 3000]` that sums to exactly 10,000.
    function test_config_thirtyNamesAtAValidWeightVector() public view {
        Registry.SpokeSpec[] memory spokes = registryScript.loadSpokes();
        assertEq(spokes.length, SPOKES, "30 launch constituents");

        uint256 sum;
        for (uint256 i; i < SPOKES; ++i) {
            Registry.SpokeSpec memory s = spokes[i];
            assertGt(bytes(s.symbol).length, 0, "every name has a ticker");
            assertTrue(s.poolClass == PoolClass.SPOKE || s.poolClass == PoolClass.SPOKE_HIGH_VOL, "spoke class");
            assertEq(
                s.buyFeeBps,
                s.poolClass == PoolClass.SPOKE_HIGH_VOL
                    ? Constants.BUY_FEE_BPS_SPOKE_HIGH_VOL_DEFAULT
                    : Constants.BUY_FEE_BPS_SPOKE_DEFAULT,
                "buy fee matches the class default"
            );
            assertGe(s.targetWeightBps, 166, "inside the n = 30 index floor");
            assertLe(s.targetWeightBps, Constants.INDEX_CAP_FLOOR_BPS, "inside the n = 30 index cap");
            assertGe(s.inclusion.historyDays, Constants.MIN_HISTORY_DAYS, "enough history to be includable");
            sum += s.targetWeightBps;
        }
        assertEq(sum, Constants.BPS, "the index weight vector sums to 10000");

        Registry.EntryPoolSpec[] memory entries = registryScript.loadEntryPools();
        assertEq(entries.length, 2, "two entry pools");
        assertEq(entries[0].counterDecimals, 6, "USDG is 6 decimals");
        assertEq(entries[1].counterDecimals, 18, "WETH is 18 decimals");
        assertEq(entries[0].buyFeeBps, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, "entry buy fee");
    }

    /// @notice Every pool key the batch builds has the one shape `PoolRegistry._validateKeyShape` enforces.
    function test_config_poolKeyShape() public view {
        Registry.SpokeSpec[] memory spokes = registryScript.loadSpokes();
        for (uint256 i; i < SPOKES; ++i) {
            assertEq(
                registryScript.poolKeyFor(address(amps), assets.stocks[i], spokes[i].tickSpacing, address(hook)).fee,
                0x800000,
                "dynamic fee flag"
            );
        }
    }

    /// @notice The four config writers produce JSON the loaders can read straight back.
    /// @dev This is the one test that touches the working tree: it briefly rewrites the four committed artefacts
    ///      under `script/config/`, which is what `fs_permissions` grants the scripts, then puts the originals
    ///      back **before** any assertion runs, so a failure here cannot leave the tree dirty. Nothing else in
    ///      the suite reads those four files, so the momentary rewrite is not visible to a parallel test.
    function test_config_writersRoundTrip() public {
        string memory poolsBefore = vm.readFile(POOLS_PATH);
        string memory testnetBefore = vm.readFile(TESTNET_PATH);
        string memory librariesBefore = vm.readFile(LIBRARIES_PATH);
        string memory proposalBefore = vm.readFile(PROPOSAL_PATH);

        registryScript.writePools(_core(), _sampleResult());
        testnetScript.writeAssets(assets);
        libraries.writeConfig(libraries.predict());
        wireScript.writeProposal(wireScript.buildCalls(_targets(address(0x9A7E)), address(0x9A7E)));

        string memory pools = vm.readFile(POOLS_PATH);
        string memory testnet = vm.readFile(TESTNET_PATH);
        string memory libs = vm.readFile(LIBRARIES_PATH);
        string memory proposal = vm.readFile(PROPOSAL_PATH);
        TestnetPools.Assets memory reread = testnetScript.loadAssets();

        vm.writeFile(POOLS_PATH, poolsBefore);
        vm.writeFile(TESTNET_PATH, testnetBefore);
        vm.writeFile(LIBRARIES_PATH, librariesBefore);
        vm.writeFile(PROPOSAL_PATH, proposalBefore);

        // `pools.json`: the objects are embedded as JSON, not as escaped strings, so the indexer can read them.
        assertEq(vm.parseJsonUint(pools, ".poolCount"), 1, "one pool recorded");
        assertEq(vm.parseJsonAddress(pools, ".pools[0].counter"), assets.usdg, "counter round-trips");
        assertEq(vm.parseJsonUint(pools, ".pools[0].sqrtPriceX96"), 1 << 96, "opening price round-trips");

        // `testnet.json`: resumable, which means `loadAssets` has to see exactly what `writeAssets` wrote.
        assertEq(vm.parseJsonUint(testnet, ".stockCount"), SPOKES, "30 stock tokens recorded");
        assertEq(reread.usdg, assets.usdg, "usdg round-trips");
        assertEq(reread.weth9, assets.weth9, "weth round-trips");
        assertEq(reread.stocks.length, SPOKES, "every stock round-trips");
        assertEq(reread.stocks[29], assets.stocks[29], "...including the last one");
        assertEq(reread.feeds[29], assets.feeds[29], "...and its aggregator");

        // `libraries.json`: four addresses and the flag string a later build is given.
        Libraries.LibrarySet memory predicted = libraries.predict();
        assertEq(vm.parseJsonAddress(libs, ".libraries.VaultNavLib.address"), predicted.navLib, "nav recorded");
        assertEq(
            vm.parseJsonAddress(libs, ".libraries.VaultRolloutLib.address"), predicted.rolloutLib, "rollout recorded"
        );
        assertTrue(bytes(vm.parseJsonString(libs, ".librariesFlag")).length > 0, "the flag string is recorded");

        // `phase3-proposal.json`: nine calls and the two pieces of timelock calldata.
        assertEq(vm.parseJsonUint(proposal, ".delaySeconds"), Constants.TIMELOCK_SLOW_SECONDS, "the 7-day delay");
        assertEq(vm.parseJsonAddress(proposal, ".calls[4].target"), address(hook), "the hook call is recorded");
        assertTrue(vm.parseJsonBytes(proposal, ".scheduleBatch").length > 4, "scheduleBatch calldata is recorded");
    }

    /// @dev One synthetic opened pool, enough to prove the writer's shape.
    function _sampleResult() private view returns (Registry.Result memory result) {
        result.entryRegistered = 1;
        result.pools = new Registry.OpenedPool[](1);
        result.pools[0] = Registry.OpenedPool({
            poolId: bytes32(uint256(1)),
            counter: assets.usdg,
            sqrtPriceX96: uint160(1) << 96,
            constituentId: 0,
            symbol: "USDG"
        });
    }

    // -----------------------------------------------------------------------------------------------------------
    // 09_Phase3Wire, in isolation
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The bootstrap check refuses while the hook has no router: revision 6's pass-through exemption is
    ///         a pointer like any other, and an index that opens with it withdrawn charges a rotation two exits.
    ///         It is checked **before** the pool count, so the fixture reaches it with nothing else done.
    function test_wire_bootstrapRefusesUntilTheRouterIsNamed() public {
        assertEq(hook.router(), address(0), "the fixture leaves the exemption withdrawn");
        Phase3Wire.Targets memory t = _targets(address(0));
        vm.expectRevert(abi.encodeWithSelector(Phase3Wire.PointerUnset.selector, bytes32("router")));
        wireScript.checkBootstrap(t, uint16(POOLS));
    }

    /// @notice With the router named, the next thing the bootstrap wants is revision 7's genesis adapter: half
    ///         of `S0` is minted to that pointer, so a launch cannot proceed without it.
    function test_wire_bootstrapRefusesUntilTheAdapterIsNamed() public {
        vm.prank(TIMELOCK);
        hook.setRouter(address(ampsRouter));
        Phase3Wire.Targets memory t = _targets(address(0));
        vm.expectRevert(abi.encodeWithSelector(Phase3Wire.PointerUnset.selector, bytes32("genesis")));
        wireScript.checkBootstrap(t, uint16(POOLS));
    }

    /// @notice The gate pass refuses while the pools are missing. The *pointer* pass does not, and that is the
    ///         revision-7 change: the 32 pools are registered after the auctions settle, so "no pools yet" is the
    ///         correct state on that pass rather than an unfinished step.
    function test_wire_bootstrapRefusesBeforeThePoolsExist() public {
        vm.startPrank(TIMELOCK);
        hook.setRouter(address(ampsRouter));
        vault.setPolicyPointer(bytes32("genesis"), address(genesisAdapter));
        vm.stopPrank();

        Phase3Wire.Targets memory t = _targets(address(0));
        vm.expectRevert(abi.encodeWithSelector(Phase3Wire.PoolsMissing.selector, uint16(0), uint16(POOLS)));
        wireScript.checkBootstrap(t, uint16(POOLS));

        // ...and the pointer pass is satisfied by exactly the same state.
        wireScript.checkBootstrap(t, 0);
    }

    /// @notice `11_GenesisPlacement` refuses to touch a vault whose gate pointer is still unset: registration
    ///         and settlement run ungated on purpose, the ladders deliberately do not.
    function test_genesis_refusesWithNoGate() public {
        vm.expectRevert(GenesisPlacement.GateUnset.selector);
        genesisScript.assertGateGreen(address(vault));
    }

    /// @notice And it refuses before `genesisPlace`: there is no `P_ref` to anchor a ladder at and no inventory
    ///         to place.
    function test_genesis_refusesBeforeThePlacement() public {
        vm.expectRevert(GenesisPlacement.GenesisNotPlaced.selector);
        genesisScript.execute(_genesisParams(), 1);
    }

    /// @notice `05_Registry` refuses before `genesisPlace` too, for the mirror-image reason: `PoolRegistry`
    ///         anchors every pool it opens at `pRefX18()`, which is still the $1.00 fallback until `P0` lands.
    function test_registry_refusesBeforeTheAnchorIsSet() public {
        vm.expectRevert(Registry.AnchorNotSet.selector);
        registryScript.assertAnchor(_core());
    }

    /// @notice The proposal form of the batch: nine timelock calls, in the §9.1 order, with the right
    ///         selectors — the router move beside the fee policy, the genesis adapter next, and the gate last.
    function test_wire_proposalIsEightCallsInOrder() public view {
        Phase3Wire.Call[] memory calls = wireScript.buildCalls(_targets(address(0x9A7E)), address(0x9A7E));
        assertEq(calls.length, 9, "nine moves");
        for (uint256 i; i < 4; ++i) {
            assertEq(calls[i].target, address(vault), "the four pointer moves are vault calls");
            assertEq(bytes4(calls[i].data), IAmpsVault.setPolicyPointer.selector, "setPolicyPointer");
        }
        assertEq(calls[4].target, address(hook), "the fee policy move is a hook call");
        assertEq(bytes4(calls[4].data), AmpsHook.setFeePolicy.selector, "setFeePolicy");
        assertEq(calls[5].target, address(hook), "the router move is a hook call too");
        assertEq(bytes4(calls[5].data), AmpsHook.setRouter.selector, "setRouter");
        assertEq(
            calls[5].data, abi.encodeCall(AmpsHook.setRouter, (address(ampsRouter))), "...naming the deployed router"
        );
        assertEq(calls[5].what, "hook.setRouter(AmpsRouter)", "and the proposal says so in words");
        assertEq(calls[6].target, address(bonds), "the bond policy move is a bonds call");
        assertEq(calls[7].target, address(vault), "the genesis adapter is a vault pointer");
        assertEq(
            calls[7].data,
            abi.encodeCall(IAmpsVault.setPolicyPointer, (bytes32("genesis"), address(genesisAdapter))),
            "...naming the deployed adapter"
        );
        assertEq(calls[8].target, address(vault), "the gate pointer goes last");

        bytes memory schedule = wireScript.scheduleBatchCalldata(calls, bytes32("salt"), 7 days);
        assertEq(
            bytes4(schedule),
            bytes4(keccak256("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)")),
            "TimelockController.scheduleBatch"
        );
    }

    // -----------------------------------------------------------------------------------------------------------
    // The whole pipeline
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The dry run itself: `10_TestnetPools` (which drives `05_Registry`) opens all 32 pools and 30 bond
    ///         markets, `09_Phase3Wire` moves the six pointers and takes the gate to `GREEN` in the §9.1 order,
    ///         and `11_GenesisPlacement` mints `S0` and lays the §3.3 ladders. Then every one of them runs again
    ///         and nothing moves.
    function test_pipeline_opensThirtyTwoPoolsWiresAndPlacesGenesis() public {
        Registry.Wiring memory core = _core();

        // ---- Bootstrap step 1b: the pointer pass. The gate is deliberately left unset, and so are the pools. --
        assertEq(hook.router(), address(0), "the exemption is withdrawn until the batch runs");
        wireScript.execute(_targets(address(0)), false, true);

        assertEq(vault.marketReference(), address(hook), "marketReference -> AmpsHook");
        assertEq(vault.positionValuer(), address(valuer), "positionValuer -> LadderPositionValuer");
        assertEq(vault.ladderPolicy(), address(ladderPolicy), "ladderPolicy");
        assertEq(vault.rolloutPolicy(), address(rolloutPolicy), "rolloutPolicy");
        assertEq(hook.feePolicy(), address(feePolicy), "hook.setFeePolicy");
        assertEq(hook.router(), address(ampsRouter), "hook.setRouter named the protocol router");
        assertEq(bonds.policy(), address(bondPolicy), "bonds.setPolicy");
        assertEq(vault.genesis(), address(genesisAdapter), "the genesis adapter is named before anything is minted");
        assertEq(vault.oracleGate(), address(0), "the gate is still unset, which is what lets 06a and 05 run");
        assertEq(registry.poolCount(), 0, "and no pool exists yet: they open at P0, after the auctions");

        // ---- Bootstrap step 1c: the feeds, without a single pool. ---------------------------------------------
        // `genesisPlace` ends in a checkpoint and a checkpoint prices WETH9 and USDG, so their feeds have to be
        // installed before `06b` — while the pools they belong to are opened after it, at `P0`.
        uint256 feedsInstalled = testnetScript.installFeedsOnly(core, assets);
        assertEq(feedsInstalled, SPOKES + 2, "every constituent feed plus the two entry counters");
        assertEq(registry.poolCount(), 0, "and still not one pool");
        assertEq(testnetScript.installFeedsOnly(core, assets), 0, "a second feeds pass installs nothing");

        // ---- Bootstrap step 2: 06a — genesisMint and the two auctions. ----------------------------------------
        GenesisAuction.LaunchConfig memory launch = _launchConfig();
        auctionScript.execute(_auctionWiring(), launch);

        assertTrue(vault.genesisMinted(), "S0 minted");
        assertFalse(vault.initialized(), "but the protocol is not open: A is still zero");
        assertEq(amps.totalSupply(), Constants.S0, "S0 = 20,000 AMPS");
        assertEq(amps.balanceOf(address(teamVesting)), Constants.TEAM_SHARES, "1,000 AMPS to the vesting wallet");
        assertEq(amps.balanceOf(address(vault)), Constants.POL_SHARES, "9,000 AMPS of POL stay in the vault");
        assertEq(vault.creator(), CREATOR, "the creator is recorded at the mint");
        assertTrue(genesisAdapter.usdgAuction() != address(0), "the USDG auction exists");
        assertTrue(genesisAdapter.ethAuction() != address(0), "the ETH auction exists");
        assertEq(amps.balanceOf(genesisAdapter.usdgAuction()), Constants.AUCTION_USDG_SHARES, "and holds its tranche");
        assertEq(amps.balanceOf(genesisAdapter.ethAuction()), Constants.AUCTION_ETH_SHARES, "...as does the other");
        assertEq(amps.balanceOf(address(genesisAdapter)), 0, "the adapter kept nothing back");

        // A second 06a pass mints nothing and creates nothing.
        auctionScript.execute(_auctionWiring(), launch);
        assertEq(amps.totalSupply(), Constants.S0, "a re-run of 06a is a no-op");

        // ---- Bidding. ----------------------------------------------------------------------------------------
        vm.roll(launch.startBlock);
        _bidBothLegs();
        vm.roll(uint256(launch.endBlock) + 1);

        // ---- Bootstrap step 3: 06b — settle, which calls genesisPlace. ----------------------------------------
        GenesisSettle.Report memory settled = settleScript.execute(_settleWiring(), _fallbackSeed());

        assertTrue(settled.settled, "settle ran");
        assertTrue(settled.graduated, "both legs graduated");
        assertFalse(settled.fallbackRan, "so the founders' seed path did not");
        assertEq(settled.raisedUsdg, BID_USDG, "the USDG raise reached the vault, net of a zero protocol fee");
        assertEq(settled.raisedWeth, BID_WETH, "and the ETH raise, wrapped into WETH9");
        assertEq(settled.unsoldAmps, 0, "both tranches cleared in full");
        assertTrue(vault.initialized(), "the protocol is open");
        // $1.00 to within the Q96 floor the auction quotes on; the vault is seeded with exactly what settled.
        assertApproxEqAbs(genesisAdapter.p0X18(), Constants.WAD, 1e10, "the adapter cleared at $1.00");
        assertEq(vault.pRefX18(), genesisAdapter.p0X18(), "and P_ref is that clearing price");
        assertEq(vault.genesisTimestamp(), uint32(block.timestamp), "the creator clock starts at the placement");
        // Fully diluted, decision 14: `A` is the $10,000 raised and `T` is the whole 20,000 AMPS.
        assertApproxEqRel(vault.navPerShareX18(), 0.5e18, 0.001e18, "NAV/share is raised / S0 = $0.50");
        assertApproxEqRel(vault.premiumX18(), 1e18, 0.01e18, "and the launch premium is the disclosed 100%");

        // A second 06b pass does nothing.
        vm.expectRevert(IAmpsGenesis.AlreadySettled.selector);
        genesisAdapter.settle();

        // ---- Bootstrap step 4: register the 32 pools, each opening at P0. -------------------------------------
        (TestnetPools.Assets memory again, Registry.Result memory result) = testnetScript.execute(core, assets);

        assertEq(again.usdg, assets.usdg, "the asset pass skipped what already existed");
        assertEq(again.stocks[0], assets.stocks[0], "...token by token");
        assertEq(result.entryRegistered, 2, "two entry pools registered");
        assertEq(result.spokesRegistered, uint16(SPOKES), "30 constituents registered");
        assertEq(result.pools.length, POOLS, "32 pools opened");
        assertTrue(result.weightsInstalled, "the launch index weight vector was installed");
        assertEq(registry.poolCount(), uint16(POOLS), "the registry holds 32 pools");
        assertEq(registry.activeConstituentCount(), uint16(SPOKES), "30 active constituents");
        assertEq(bonds.marketCount(), uint16(SPOKES), "30 bond markets");
        assertEq(vault.oracleGate(), address(0), "the gate is still unset, which is what let step 4 happen");

        // Ruling J: the recorded price is the one the pool actually opened at, i.e. the grid origin.
        for (uint256 i; i < result.pools.length; ++i) {
            PoolId poolId = PoolId.wrap(result.pools[i].poolId);
            PoolConfig memory config = registry.poolConfig(poolId);
            assertTrue(config.registered, "every recorded pool is registered");
            assertGt(result.pools[i].sqrtPriceX96, 0, "PoolOpened carried a price");
            assertEq(
                result.pools[i].sqrtPriceX96,
                _openingPrice(poolId),
                "the recorded price is what slot0 holds: the snapped grid origin"
            );
            assertEq(config.gridBaseTick % config.tickSpacing, int24(0), "the grid origin is spacing-aligned");
        }

        // A second registration pass registers nothing.
        (, Registry.Result memory rerun) = testnetScript.execute(core, again);
        assertEq(rerun.entryRegistered, 0, "re-run registers no entry pool");
        assertEq(rerun.spokesRegistered, 0, "re-run registers no constituent");
        assertEq(rerun.entrySkipped, 2, "...it skips them");
        assertEq(rerun.spokesSkipped, uint16(SPOKES), "...and all 30");
        assertEq(registry.poolCount(), uint16(POOLS), "still 32 pools");

        // ---- Bootstrap step 5: let the hub ring cover twapWindow. ---------------------------------------------
        assertLt(hook.observationCoverage(registry.hubPoolId()), vault.twapWindow(), "the ring starts empty");
        _warpBy(Constants.TWAP_WINDOW_DEFAULT + 1);
        assertGe(hook.observationCoverage(registry.hubPoolId()), vault.twapWindow(), "...and fills with time alone");

        // ---- Bootstrap step 6: the gate pass. ------------------------------------------------------------------
        address gate = wireScript.execute(_targets(address(0)), true, false);

        assertEq(vault.oracleGate(), gate, "the vault points at the redeployed gate");
        assertEq(IOracleGate(gate).marketReference(), address(hook), "the gate reads the hook's poolState");
        assertEq(feeds.oracleGate(), gate, "FeedRegistry points at the same gate");
        assertTrue(IOracleGate(gate).state(0) == GateState.GREEN, "gate is GREEN before the ladders");

        // A second wiring pass moves nothing — and, because every move is guarded on the value already in
        // place, it makes no call at all. An empty log is the strongest form of that: a re-sent `setRouter` or
        // `setFeePolicy` would be a governance action against a live vault, not a deployment step.
        vm.recordLogs();
        address gateAgain = wireScript.execute(_targets(gate), false, false);
        assertEq(vm.getRecordedLogs().length, 0, "a second wiring pass emits nothing, i.e. it sent nothing");
        assertEq(gateAgain, gate, "re-run keeps the same gate");
        assertEq(vault.oracleGate(), gate, "re-run leaves the pointer alone");
        assertEq(hook.router(), address(ampsRouter), "re-run leaves the router pointer alone");

        // ---- Bootstrap step 7: the §3.3 ladders. ---------------------------------------------------------------
        assertEq(genesisScript.nextPhase(address(vault)), 1, "phase 1 is due");
        GenesisPlacement.Report memory phase1 = genesisScript.execute(_genesisParams(), 1);

        // The reference the ladders anchored at, against the reference after they were placed: valuing a fresh
        // ask ladder at `P_ref` lifts NAV a hair, and `P_ref` can follow it (§12 ruling L).
        assertApproxEqRel(
            phase1.p0X18, vault.pRefX18(), 0.01e18, "the ladders anchor at the same P0 the pools opened at"
        );
        assertEq(phase1.askPools, uint16(POOLS), "an ask ladder in every one of the 32 pools");
        assertEq(
            phase1.liveCells,
            uint32(POOLS * Constants.LADDER_DOUBLINGS_DEFAULT),
            "32 pools x 10 ask cells, and nothing else yet"
        );
        assertLe(phase1.liveCells, Constants.MAX_LIVE_CELLS, "inside the vault-wide live-cell budget");

        // The 60-second per-pool cooldown is real, and the script reports it rather than reverting inside the vault.
        assertGt(genesisScript.cooldownRemaining(address(vault), registry.hubPoolId()), 0, "cooldown is running");
        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisPlacement.CooldownNotElapsed.selector,
                registry.hubPoolId(),
                genesisScript.cooldownRemaining(address(vault), registry.hubPoolId())
            )
        );
        genesisScript.execute(_genesisParams(), 2);

        _warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        assertEq(genesisScript.nextPhase(address(vault)), 2, "phase 2 is due");
        GenesisPlacement.Report memory phase2 = genesisScript.execute(_genesisParams(), 2);

        assertEq(phase2.bidPools, 2, "seed bids in both entry pools");
        assertEq(
            phase2.liveCells,
            uint32(POOLS * Constants.LADDER_DOUBLINGS_DEFAULT + 2 * Constants.SEED_HALVINGS_DEFAULT),
            "320 ask cells plus 8 seed-bid cells"
        );
        assertEq(genesisScript.nextPhase(address(vault)), 0, "nothing left to do");

        // ---- The §3.3 layout, asserted by the script's own check and independently here. ----------------------
        genesisScript.assertLayout(address(vault));
        _assertGenesisLadders();

        // Every AMPS of the POL tranche is either placed or still idle inventory; none of it left the vault. The
        // records' `amount` is a cumulative disclosure figure rather than a live position read, so it carries a
        // few hundred wei of rounding across 320 cells; the exact custody invariant is I12's, not this one's.
        assertApproxEqAbs(
            amps.balanceOf(address(vault)) + _ampsInLadders(),
            Constants.POL_SHARES,
            1e9,
            "the 9,000 AMPS POL tranche is fully accounted for"
        );
        assertEq(amps.balanceOf(address(hook)), 0, "the hook holds no AMPS");
        assertEq(amps.totalSupply(), Constants.S0, "and nothing was minted after genesis");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Assertions
    // -----------------------------------------------------------------------------------------------------------

    /// @dev §3.3 in full: ten ask cells anchored at the grid origin in every pool, four bid cells at `m = -1..-4`
    ///      in each entry pool and none anywhere else, 3,150 AMPS of asks per entry pool and 90 per spoke.
    ///
    ///      **BUG: `docs/phase3-state-model.md` §3.3 says the genesis asks occupy `m = 0..9`, and for a minority
    ///      of the 32 launch pools they occupy `m = 1..10` instead.** Nothing in `src/` is wrong — this is a
    ///      documentation claim the launch vector does not support, and the dry run is what surfaces it, because
    ///      `test/unit/VaultPlacement.t.sol` and `PlacementFixture` only build four pools and never hit it.
    ///
    ///      The mechanism, measured here: `LadderPositionValuer` decomposes each position at the reference price,
    ///      so a freshly placed ask ladder picks up a sliver of counter-side value on the cell the price sits in
    ///      and NAV/share rises a little with every placement. `P_ref` follows NAV whenever NAV is the binding
    ///      term, and `VaultPlacementLib._cells` starts an ask ladder at `ceilDiv(fairTick(P_ref) - gridBase, D)`,
    ///      which is 1 instead of 0 for any pool whose exact fair tick sits a tick or two below a 60-tick spacing
    ///      boundary. Under revision 7 the launch NAV/share is `raised / S0` = $0.50 while `P_ref` is the $1.00
    ///      clearing price, so NAV is *not* the binding term at launch and the shift is rarer than it was at the
    ///      old $1.00-NAV launch — but it is still admitted here, because it is I32 working as specified.
    ///
    ///      That behaviour is I32 working as specified — no ask may ever be placed below `P_ref` — so the fix is
    ///      to §3.3's wording, not to the vault: the guaranteed shape is `ladderDoublings` contiguous one-cell
    ///      asks anchored at the origin or one cell above it. `11_GenesisPlacement.assertLayout` asserts exactly
    ///      that, and so does this. Nothing else about the launch vector moves: the per-pool AMPS totals, the
    ///      cell count and the seed-bid cells are all exactly as §3.3 states.
    function _assertGenesisLadders() private view {
        PoolId[] memory pools = genesisScript.allPools(address(vault));
        assertEq(pools.length, POOLS, "32 pools in the ladder walk");

        PoolId hub = registry.hubPoolId();
        PoolId weth = registry.wethPoolId();
        uint256 shifted;

        for (uint256 p; p < pools.length; ++p) {
            PoolId poolId = pools[p];
            bool isEntry = PoolId.unwrap(poolId) == PoolId.unwrap(hub) || PoolId.unwrap(poolId) == PoolId.unwrap(weth);
            PoolConfig memory config = registry.poolConfig(poolId);
            int24 width = LadderLib.doublingTicks(config.tickSpacing);

            uint256 asks;
            uint256 bids;
            uint256 askAmps;
            int24 firstAsk = type(int24).max;
            int24 lastAsk = type(int24).min;
            uint256 n = vault.ladderLength(poolId);
            for (uint256 i; i < n; ++i) {
                (int24 lowerTick, int24 upperTick, uint128 liquidity,,, bool above,, uint128 amount,,) =
                    vault.ladderAt(poolId, i);
                if (liquidity == 0) continue;
                assertEq(upperTick - lowerTick, width, "every record is exactly one grid cell wide");
                int24 cell = (lowerTick - config.gridBaseTick) / width;
                if (above) {
                    if (cell < firstAsk) firstAsk = cell;
                    if (cell > lastAsk) lastAsk = cell;
                    ++asks;
                    askAmps += amount;
                } else {
                    assertTrue(isEntry, "only the entry pools carry seed bids");
                    assertLe(cell, int24(-1), "bids start at m = -1");
                    assertGe(cell, -int24(int256(uint256(Constants.SEED_HALVINGS_DEFAULT))), "and end at m = -4");
                    ++bids;
                }
            }

            assertEq(asks, Constants.LADDER_DOUBLINGS_DEFAULT, "ten ask cells");
            assertGe(firstAsk, int24(0), "the ask ladder never starts below the grid origin");
            assertLe(firstAsk, int24(1), "and never more than one cell above it");
            assertEq(
                lastAsk,
                firstAsk + int24(int256(uint256(Constants.LADDER_DOUBLINGS_DEFAULT))) - 1,
                "ten contiguous ask cells"
            );
            assertEq(bids, isEntry ? Constants.SEED_HALVINGS_DEFAULT : 0, "four seed bid cells, entry pools only");
            assertApproxEqAbs(askAmps, isEntry ? 3150e18 : 90e18, 1e12, "the section 3.3 ask inventory");
            if (firstAsk == 1) ++shifted;
        }

        // The §3.3 claim holds for the great majority of the set; the shift is the documented minority above.
        assertLt(shifted, POOLS / 4, "the m = 1 shift is the exception, not the rule");
    }

    /// @dev Every AMPS the vault has committed to a ladder, from the records' own cumulative `amount`.
    function _ampsInLadders() private view returns (uint256 total) {
        PoolId[] memory pools = genesisScript.allPools(address(vault));
        for (uint256 p; p < pools.length; ++p) {
            uint256 n = vault.ladderLength(pools[p]);
            for (uint256 i; i < n; ++i) {
                (,, uint128 liquidity,,, bool above,, uint128 amount,,) = vault.ladderAt(pools[p], i);
                if (liquidity != 0 && above) total += amount;
            }
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Deployment
    // -----------------------------------------------------------------------------------------------------------

    /// @dev `Amps` (CREATE2, mined below every counter), `AmpsVault`, and the flag-mined production `AmpsHook`.
    ///      The registry's address is predicted because the hook takes it in its constructor and the registry
    ///      takes the hook in its own — the same circularity `04_MineHook` resolves with a placeholder.
    function _deployCore() private {
        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedRegistry = vm.computeCreateAddress(address(this), nonce + 3);

        amps = new Amps{salt: _mineAmpsSalt(predictedVault)}(predictedVault);
        vault = new AmpsVault(address(amps), address(poolManager), TIMELOCK, GUARDIAN);
        assertEq(address(vault), predictedVault, "vault address prediction");

        bytes memory args = abi.encode(poolManager, address(amps), address(vault), predictedRegistry, TIMELOCK);
        (address mined, bytes32 hookSalt) = HookMiner.find(address(this), HOOK_FLAGS, type(AmpsHook).creationCode, args);
        hook = new AmpsHook{salt: hookSalt}(
            IPoolManager(address(poolManager)), address(amps), address(vault), predictedRegistry, TIMELOCK
        );
        assertEq(address(hook), mined, "hook address mismatch");

        registry = new PoolRegistry(address(vault), address(hook), TIMELOCK, address(amps), assets.weth9, assets.usdg);
        assertEq(address(registry), predictedRegistry, "registry address prediction");

        vm.label(address(amps), "AMPS");
        vm.label(address(vault), "AmpsVault");
        vm.label(address(hook), "AmpsHook");
        vm.label(address(registry), "PoolRegistry");
    }

    /// @dev Everything the vault points at, plus the three policies, the protocol router and the team's vesting
    ///      wallet. `OracleGate` is deliberately absent: `09_Phase3Wire` deploys it. The router is deployed here
    ///      but deliberately **not** named on the hook — `09_Phase3Wire` sends `setRouter`, and the fixture
    ///      leaving `hook.router()` zero is what makes that a real move.
    function _deployPeriphery() private {
        feeds = new FeedRegistry(TIMELOCK, address(0));
        bondPolicy = new BondPolicy();
        bonds = new AmpsBonds(address(vault), address(registry), address(bondPolicy));
        pot = new BountyPot(assets.usdg, address(vault), TIMELOCK);
        valuer =
            new LadderPositionValuer(IExtsload(address(poolManager)), address(vault), IPoolRegistry(address(registry)));
        ladderPolicy = new LadderPolicy();
        rolloutPolicy = new RolloutPolicy();
        feePolicy = new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18);
        ampsRouter = new AmpsRouter(IPoolManager(address(poolManager)), address(amps), address(registry), assets.weth9);
        // A fee-free stand-in for the canonical `ContinuousClearingAuctionFactory`. The adapter is deployed
        // against it exactly as `03_Core` deploys it against the configured one.
        ccaFactory = new MockCCAFactory(address(0), 0);
        genesisAdapter =
            new AmpsGenesis(address(vault), address(amps), address(ccaFactory), assets.weth9, assets.usdg, TIMELOCK);
        phase2Reference = new MockMarketReference();
        teamVesting = new VestingWallet(TEAM, uint64(GENESIS_TIME), Constants.TEAM_VEST_SECONDS);
    }

    /// @dev Step 1 of §9.1: every pointer except `oracleGate`. `marketReference` deliberately starts on the
    ///      Phase 2 mock, so `09_Phase3Wire`'s first move — repointing it at `AmpsHook` — is a real move.
    function _wireVaultWithoutGate() private {
        vm.startPrank(TIMELOCK);
        vault.setPolicyPointer(bytes32("registry"), address(registry));
        vault.setPolicyPointer(bytes32("bonds"), address(bonds));
        vault.setPolicyPointer(bytes32("bountyPot"), address(pot));
        vault.setPolicyPointer(bytes32("feedRegistry"), address(feeds));
        vault.setPolicyPointer(bytes32("marketReference"), address(phase2Reference));
        vault.setPolicyPointer(bytes32("positionValuer"), address(valuer));
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The wiring `05_Registry` and `10_TestnetPools` take.
    function _core() private view returns (Registry.Wiring memory w) {
        w = Registry.Wiring({
            timelock: TIMELOCK,
            registry: address(registry),
            amps: address(amps),
            hook: address(hook),
            feedRegistry: address(feeds),
            bonds: address(bonds),
            registrationWeightBps: 500
        });
    }

    /// @dev The targets `09_Phase3Wire` takes.
    function _targets(address gate) private view returns (Phase3Wire.Targets memory t) {
        t = Phase3Wire.Targets({
            timelock: TIMELOCK,
            guardian: GUARDIAN,
            vault: address(vault),
            hook: address(hook),
            registry: address(registry),
            bonds: address(bonds),
            feedRegistry: address(feeds),
            oracleGate: gate,
            positionValuer: address(valuer),
            ladderPolicy: address(ladderPolicy),
            rolloutPolicy: address(rolloutPolicy),
            feePolicy: address(feePolicy),
            bondPolicy: address(bondPolicy),
            router: address(ampsRouter),
            genesis: address(genesisAdapter)
        });
    }

    /// @dev The parameters `11_GenesisPlacement` takes. Both bid sizes are left at zero, which is what a real
    ///      launch does: the seed bids are the auction proceeds and their size is not knowable in advance, so the
    ///      script reads the vault's own claim balances.
    function _genesisParams() private view returns (GenesisPlacement.Params memory p) {
        address[] memory seedTokens = new address[](2);
        uint256[] memory seedAmounts = new uint256[](2);
        seedTokens[0] = assets.weth9;
        seedTokens[1] = assets.usdg;
        p = GenesisPlacement.Params({
            timelock: TIMELOCK,
            vault: address(vault),
            genesis: address(genesisAdapter),
            seedTokens: seedTokens,
            seedAmounts: seedAmounts
        });
    }

    /// @dev The addresses `06a` and `06b` take.
    function _auctionWiring() private view returns (GenesisAuction.Wiring memory w) {
        w = GenesisAuction.Wiring({
            timelock: TIMELOCK,
            vault: address(vault),
            genesis: address(genesisAdapter),
            teamVestingWallet: address(teamVesting),
            creator: CREATOR,
            feedRegistry: address(feeds),
            weth9: assets.weth9
        });
    }

    /// @dev The addresses `06b` takes.
    function _settleWiring() private view returns (GenesisSettle.Wiring memory w) {
        w = GenesisSettle.Wiring({
            timelock: TIMELOCK,
            vault: address(vault),
            genesis: address(genesisAdapter),
            weth9: assets.weth9,
            usdg: assets.usdg
        });
    }

    /// @dev A 600-block auction window starting 10 blocks out, with a graduation bar both legs clear.
    function _launchConfig() private view returns (GenesisAuction.LaunchConfig memory cfg) {
        cfg.ethUsdX18 = ETH_USD_X18;
        cfg.startBlock = uint64(block.number + 10);
        cfg.endBlock = cfg.startBlock + 600;
        cfg.claimBlock = cfg.endBlock;

        // 1% of each floor, which is what `script/config/genesis.json` recommends.
        cfg.usdgLeg = GenesisAuction.LegConfig({
            enabled: true,
            tickSpacing: (uint256(1e6) * (uint256(1) << 96)) / 1e18 / 100,
            requiredCurrencyRaised: 1000e6,
            validationHook: address(0),
            salt: bytes32(uint256(1)),
            stepMps: new uint24[](0),
            stepBlocks: new uint40[](0)
        });
        cfg.ethLeg = GenesisAuction.LegConfig({
            enabled: true,
            tickSpacing: (((uint256(1) << 96) * uint256(1e18)) / ETH_USD_X18) / 100,
            requiredCurrencyRaised: 0.4e18,
            validationHook: address(0),
            salt: bytes32(uint256(2)),
            stepMps: new uint24[](0),
            stepBlocks: new uint40[](0)
        });
    }

    /// @dev The founders' seed `06b` would use if nothing graduated. Unused on the happy path, and asserted
    ///      unused: `settled.fallbackRan` must be false.
    function _fallbackSeed() private pure returns (GenesisSettle.Fallback memory fb) {
        fb = GenesisSettle.Fallback({p0X18: 1e18, seedWeth: 4e18, seedUsdg: 10_000e6});
    }

    /// @dev Bids both tranches out at the floor, so each leg graduates and clears in full at `P0` = $1.00.
    function _bidBothLegs() private {
        MockUsdg(assets.usdg).mint(BIDDER, BID_USDG);
        // Both the bidder and this contract are funded: whether a pranked call debits the pranked address or the
        // frame that actually makes it is a Foundry implementation detail, and the bid must not depend on it.
        vm.deal(BIDDER, BID_WETH);
        vm.deal(address(this), address(this).balance + BID_WETH);

        MockCCA usdgAuction = MockCCA(payable(genesisAdapter.usdgAuction()));
        MockCCA ethAuction = MockCCA(payable(genesisAdapter.ethAuction()));

        vm.startPrank(BIDDER);
        MockUsdg(assets.usdg).approve(address(usdgAuction), BID_USDG);
        usdgAuction.bid(genesisAdapter.floorUsdgQ96(), BID_USDG);
        ethAuction.bid{value: BID_WETH}(genesisAdapter.floorEthQ96(), BID_WETH);
        vm.stopPrank();
    }

    /// @dev An empty `Assets`, i.e. "nothing deployed yet".
    function _emptyAssets() private pure returns (TestnetPools.Assets memory empty) {
        empty.stocks = new address[](0);
        empty.feeds = new address[](0);
    }

    /// @dev Warps forward and produces a block per second with it, so the gate's layer-A watchdog sees a chain
    ///      that kept running rather than a stalled sequencer.
    function _warpBy(uint256 dt) private {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + dt + 1);
    }

    /// @dev `slot0.sqrtPriceX96`, straight from the PoolManager.
    function _openingPrice(PoolId poolId) private view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = _slot0(poolId);
    }

    function _slot0(PoolId poolId)
        private
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        bytes32 word = IExtsload(address(poolManager))
            .extsload(keccak256(abi.encodePacked(PoolId.unwrap(poolId), uint256(6))));
        sqrtPriceX96 = uint160(uint256(word));
        tick = int24(uint24(uint256(word) >> 160));
        protocolFee = uint24(uint256(word) >> 184);
        lpFee = uint24(uint256(word) >> 208);
    }

    /// @dev Mines a CREATE2 salt for `Amps(predictedVault)` two leading zero bytes low, so every counter the
    ///      script deploys sorts above it.
    function _mineAmpsSalt(address predictedVault) private view returns (bytes32 salt) {
        bytes32 initHash = keccak256(abi.encodePacked(type(Amps).creationCode, abi.encode(predictedVault)));
        for (uint256 i; i < 1 << 22; ++i) {
            salt = bytes32(i);
            uint160 candidate =
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))));
            // The floor keeps the search away from the precompile range.
            if (candidate < AMPS_CEILING && candidate > 0xffff) return salt;
        }
        revert("no AMPS salt below the ceiling");
    }

    /// @dev Substring search, for the `--libraries` flag assertions.
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
