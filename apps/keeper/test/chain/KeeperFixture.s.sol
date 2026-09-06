// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsBonds} from "amps/bonds/AmpsBonds.sol";
import {AmpsHook} from "amps/hook/AmpsHook.sol";
import {IAmpsVault} from "amps/interfaces/IAmpsVault.sol";
import {IFeedRegistry} from "amps/interfaces/IFeedRegistry.sol";
import {IOracleGate} from "amps/interfaces/IOracleGate.sol";
import {IPoolRegistry} from "amps/interfaces/IPoolRegistry.sol";
import {BountyPot} from "amps/keeper/BountyPot.sol";
import {FeedRegistry} from "amps/oracle/FeedRegistry.sol";
import {OracleGate} from "amps/oracle/OracleGate.sol";
import {AmpsQuoter} from "amps/periphery/AmpsQuoter.sol";
import {BondPolicy} from "amps/policy/BondPolicy.sol";
import {FeePolicy} from "amps/policy/FeePolicy.sol";
import {LadderPolicy} from "amps/policy/LadderPolicy.sol";
import {RolloutPolicy} from "amps/policy/RolloutPolicy.sol";
import {PoolRegistry} from "amps/registry/PoolRegistry.sol";
import {AmpsStaking} from "amps/staking/AmpsStaking.sol";
import {Amps} from "amps/token/Amps.sol";
import {Constants} from "amps/types/Constants.sol";
import {FeedConfig, GateState, InclusionRecord, PoolClass} from "amps/types/Types.sol";
import {LadderPositionValuer} from "amps/valuer/LadderPositionValuer.sol";
import {AmpsVault} from "amps/vault/AmpsVault.sol";

import {MockWeth9} from "ampsscript/10_TestnetPools.s.sol";
import {GenesisPlacement} from "ampsscript/11_GenesisPlacement.s.sol";

import {MockAggregator} from "ampstest/mocks/MockAggregator.sol";
import {MockMarketReference} from "ampstest/mocks/MockMarketReference.sol";
import {MockStockToken} from "ampstest/mocks/MockStockToken.sol";
import {MockUsdg} from "ampstest/mocks/MockUsdg.sol";

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

/// @title KeeperFixture
/// @notice Stands the whole Amplestocks system up on a local chain so `apps/keeper`'s chain suite can drive the
///         real contracts rather than a mock of them.
///
/// @dev **This is `contracts/test/script/Phase3Scripts.t.sol`'s pipeline, replayed through `--broadcast`.** That
///      suite is the repository's proof that the Phase 3 deployment works; it runs inside `forge test`, where
///      `vm.warp` and `vm.prank` are free. A keeper has to talk to a real chain, so the same sequence is
///      reproduced here as a broadcasting script and the time travel moves to the harness, which drives anvil's
///      `evm_increaseTime` between stages. Everything under `contracts/src/` is the production contract,
///      `AmpsHook` mined to `0x38C0` included; the counter assets are the same mocks `10_TestnetPools` deploys.
///
/// @dev **BUG (Phase 3 scripts, not the contracts): a nested broadcast window mis-assigns nonces, so
///      `10_TestnetPools.run()` and `09_Phase3Wire.run()` cannot broadcast as written.** The first version of
///      this fixture drove `05_Registry.execute` and `09_Phase3Wire.execute` directly, the way
///      `10_TestnetPools` does (`_registrar().execute(...)`). Every transaction the *helper contract's*
///      `vm.startBroadcast` window produced was written into `broadcast/…/run-latest.json` with the **same**
///      nonce — 26 registry calls all at `0x28` — and the broadcast died with `EOA nonce changed unexpectedly
///      while sending transactions. Expected 40 got 41`. Simulation is unaffected, which is exactly why
///      `Phase3Scripts.t.sol` is green and nobody has seen it: the suite never broadcasts. Foundry 1.8.1,
///      `--slow` or not.
///
///      The workaround here, and the one the deploy runbook needs, is that **every broadcast window must be
///      opened by the script `forge script` was pointed at**, so this fixture inlines the registration, the
///      wiring and the genesis placement rather than delegating them. `docs/keeper-runbook.md` records it.
///
/// @dev **Four spokes, not thirty.** The keeper's decision matrix needs a hub, a WETH leg and enough spokes to
///      tell "this pool" from "that pool"; thirty would add minutes of registration to every test run and prove
///      nothing further. `SPOKES` is the only knob.
///
/// @dev **Stages, because the chain has a clock.** `docs/phase2-state-model.md` §9.1 requires thirty minutes of
///      hub observations between pool registration and wiring the gate, and `Constants.PLACEMENT_COOLDOWN_SECONDS`
///      requires sixty seconds between the two genesis placement phases. Neither can be waited out inside one
///      script, so `FIXTURE_STAGE` selects one step and the harness advances the chain between them:
///
///      | stage | what it does |
///      |---|---|
///      | 1 | v4 PoolManager, the mock assets, the core system, every vault pointer **except** the gate |
///      | 2 | feeds, the two entry pools, the spokes, the index weight vector — all with the gate still unset |
///      | 3 | the six Phase 3 pointer moves and the `OracleGate` deploy; the gate must come out GREEN |
///      | 4 | `genesis()` plus an ask ladder in every pool |
///      | 5 | the entry pools' seed bid ladders, once the 60 s cooldown has passed |
///      | 6 | fund `BountyPot`, and mint counter assets to the operator for the swap and bond drills |
///
/// @dev **Addresses travel by log line, not by file.** `fs_permissions` covers `contracts/script/config` and
///      nothing outside the Foundry root, and rewriting a committed artefact to run a test would be worse than
///      parsing stdout. Every address is printed as `FIXTURE <name> <address>` and the harness reads them back.
///
/// @dev **Usage.**
/// ```
///   cd contracts
///   FIXTURE_STAGE=1 FIXTURE_OPERATOR=0xf39F... forge script --tc KeeperFixture \
///       --remappings amps/=src/ --remappings ampstest/=test/ --remappings ampsscript/=script/ \
///       ../apps/keeper/test/chain/KeeperFixture.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $PK
/// ```
contract KeeperFixture is Script {
    // -----------------------------------------------------------------------------------------------------------
    // Shape
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Spokes in the fixture index. See the contract note.
    uint256 internal constant SPOKES = 4;

    /// @notice `AmpsHook`'s mined permission bits, `0x38C0`.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    /// @notice The canonical CREATE2 factory. In a broadcast every `new X{salt: s}()` is routed through it, so it
    ///         is also what the AMPS and hook salt searches mine against.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice AMPS must sort below every counter. Two leading zero bytes is ~65k CREATE2 attempts and is more
    ///         than enough against ordinary CREATE addresses; production mines three.
    uint160 internal constant AMPS_CEILING = uint160(1) << 144;

    /// @notice The founders' seed: 1 WETH ($2,500) + 2,500 USDG against `S0` = 5,000 AMPS.
    uint256 internal constant SEED_WETH = 1e18;
    uint256 internal constant SEED_USDG = 2500e6;

    /// @notice `11_GenesisPlacement`'s per-pool ask inventory: 1,662.5 AMPS per entry pool, 47.5 per spoke.
    uint256 internal constant ENTRY_ASK_AMPS = 1662.5e18;
    uint256 internal constant SPOKE_SEED_AMPS = 47.5e18;

    /// @notice $2,500 and $1.00, 8 decimals.
    int256 internal constant ETH_USD8 = 2500e8;
    int256 internal constant USDG_USD8 = 1e8;

    /// @notice Every spoke opens at $100.00 so the ladder maths is legible in a failure message.
    int256 internal constant STOCK_USD8 = 100e8;

    /// @notice 24 hours, the RDD heartbeat on every equity feed.
    uint32 internal constant HEARTBEAT = 86_400;

    /// @notice `05_Registry`'s feed-config constants.
    uint16 internal constant FEED_THRESHOLD_BPS = 50;
    uint128 internal constant FEED_MIN_ANSWER_USD8 = 1;

    /// @notice Tick spacing for every pool in the fixture, matching `constituents.json`.
    int24 internal constant TICK_SPACING = 60;

    /// @notice USDG to fund `BountyPot` with: 1,000 USDG, forty days of the launch daily ceiling.
    uint256 internal constant POT_FUNDING = 1000e6;

    // -----------------------------------------------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------------------------------------------

    error UnknownStage(uint256 stage);
    error AddressPrediction(string what, address expected, address actual);
    error NoSalt();
    error GateNotGreen(uint8 state);

    // -----------------------------------------------------------------------------------------------------------
    // Entry point
    // -----------------------------------------------------------------------------------------------------------

    function run() external {
        uint256 stage = vm.envUint("FIXTURE_STAGE");
        if (stage == 1) return deploy();
        if (stage == 2) return register();
        if (stage == 3) return wire();
        if (stage == 4) return genesisAsks();
        if (stage == 5) return entryBids();
        if (stage == 6) return fund();
        revert UnknownStage(stage);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Stage 1 — the v4 stack, the mocks, the core and the periphery
    // -----------------------------------------------------------------------------------------------------------

    function deploy() public {
        address operator = vm.envAddress("FIXTURE_OPERATOR");

        vm.startBroadcast(operator);
        address poolManager = V4PoolManagerDeployer.deploy(operator);

        MockUsdg usdg = new MockUsdg("Global Dollar", "USDG", 6);
        MockAggregator usdgFeed = new MockAggregator("USDG / USD", 8, USDG_USD8);
        MockWeth9 weth9 = new MockWeth9();
        MockAggregator wethFeed = new MockAggregator("ETH / USD", 8, ETH_USD8);

        string[4] memory symbols = ["AAPL", "NVDA", "TSLA", "SPY"];
        address[] memory stocks = new address[](SPOKES);
        address[] memory feeds = new address[](SPOKES);
        for (uint256 i; i < SPOKES; ++i) {
            stocks[i] = address(new MockStockToken(symbols[i], symbols[i]));
            feeds[i] = address(new MockAggregator(string.concat(symbols[i], " / USD"), 8, STOCK_USD8));
        }

        // The two address predictions `04_MineHook` resolves the same way. A CREATE2 deploy in a broadcast still
        // consumes the operator's nonce — it is a transaction to the factory — so the vault is the next CREATE
        // and the registry the one after the hook.
        uint64 nonce = vm.getNonce(operator);
        address predictedVault = vm.computeCreateAddress(operator, nonce + 1);
        address predictedRegistry = vm.computeCreateAddress(operator, nonce + 3);

        Amps amps = new Amps{salt: _mineAmpsSalt(predictedVault)}(predictedVault);
        AmpsVault vault = new AmpsVault(address(amps), poolManager, operator, operator);
        if (address(vault) != predictedVault) revert AddressPrediction("vault", predictedVault, address(vault));

        bytes memory hookArgs = abi.encode(poolManager, address(amps), address(vault), predictedRegistry, operator);
        (address minedHook, bytes32 hookSalt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(AmpsHook).creationCode, hookArgs);
        AmpsHook hook = new AmpsHook{salt: hookSalt}(
            IPoolManager(poolManager), address(amps), address(vault), predictedRegistry, operator
        );
        if (address(hook) != minedHook) revert AddressPrediction("hook", minedHook, address(hook));

        PoolRegistry registry =
            new PoolRegistry(address(vault), address(hook), operator, address(amps), address(weth9), address(usdg));
        if (address(registry) != predictedRegistry) {
            revert AddressPrediction("registry", predictedRegistry, address(registry));
        }

        // The periphery. `OracleGate` is deliberately absent: stage 3 deploys it, which is §9.1's ordering — a
        // gate that is unset is exactly as permissive as a gate that is GREEN, and pool registration needs that.
        FeedRegistry feedRegistry = new FeedRegistry(operator, address(0));
        BondPolicy bondPolicy = new BondPolicy();
        AmpsBonds bonds = new AmpsBonds(address(vault), address(registry), address(bondPolicy));
        AmpsStaking staking = new AmpsStaking(IERC20(address(amps)), address(vault), operator);
        BountyPot pot = new BountyPot(address(usdg), address(vault), operator);
        LadderPositionValuer valuer =
            new LadderPositionValuer(IExtsload(poolManager), address(vault), IPoolRegistry(address(registry)));
        LadderPolicy ladderPolicy = new LadderPolicy();
        RolloutPolicy rolloutPolicy = new RolloutPolicy();
        FeePolicy feePolicy =
            new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18);
        MockMarketReference phase2Reference = new MockMarketReference();
        VestingWallet teamVesting = new VestingWallet(operator, uint64(block.timestamp), Constants.TEAM_VEST_SECONDS);
        KeeperSwapper swapper = new KeeperSwapper(IPoolManager(poolManager));

        vault.setPolicyPointer(bytes32("registry"), address(registry));
        vault.setPolicyPointer(bytes32("bonds"), address(bonds));
        vault.setPolicyPointer(bytes32("staking"), address(staking));
        vault.setPolicyPointer(bytes32("bountyPot"), address(pot));
        vault.setPolicyPointer(bytes32("feedRegistry"), address(feedRegistry));
        vault.setPolicyPointer(bytes32("marketReference"), address(phase2Reference));
        vault.setPolicyPointer(bytes32("positionValuer"), address(valuer));
        vm.stopBroadcast();

        _emit("poolManager", poolManager);
        _emit("amps", address(amps));
        _emit("vault", address(vault));
        _emit("hook", address(hook));
        _emit("registry", address(registry));
        _emit("feedRegistry", address(feedRegistry));
        _emit("bonds", address(bonds));
        _emit("bondPolicy", address(bondPolicy));
        _emit("staking", address(staking));
        _emit("bountyPot", address(pot));
        _emit("valuer", address(valuer));
        _emit("ladderPolicy", address(ladderPolicy));
        _emit("rolloutPolicy", address(rolloutPolicy));
        _emit("feePolicy", address(feePolicy));
        _emit("teamVesting", address(teamVesting));
        _emit("swapper", address(swapper));
        _emit("usdg", address(usdg));
        _emit("usdgFeed", address(usdgFeed));
        _emit("weth9", address(weth9));
        _emit("wethFeed", address(wethFeed));
        for (uint256 i; i < SPOKES; ++i) {
            _emit(string.concat("stock", vm.toString(i)), stocks[i]);
            _emit(string.concat("feed", vm.toString(i)), feeds[i]);
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Stage 2 — feeds, pools, constituents, weights (05_Registry, inlined)
    // -----------------------------------------------------------------------------------------------------------

    function register() public {
        address operator = vm.envAddress("FIXTURE_OPERATOR");
        address amps = vm.envAddress("FIXTURE_AMPS");
        address hook = vm.envAddress("FIXTURE_HOOK");
        PoolRegistry registry = PoolRegistry(vm.envAddress("FIXTURE_REGISTRY"));
        IFeedRegistry feeds = IFeedRegistry(vm.envAddress("FIXTURE_FEEDREGISTRY"));

        address usdg = vm.envAddress("FIXTURE_USDG");
        address weth9 = vm.envAddress("FIXTURE_WETH9");

        vm.startBroadcast(operator);

        _installFeed(feeds, usdg, vm.envAddress("FIXTURE_USDGFEED"));
        registry.registerEntryPool(
            _poolKey(amps, usdg, hook), 6, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, vm.envAddress("FIXTURE_USDGFEED")
        );

        _installFeed(feeds, weth9, vm.envAddress("FIXTURE_WETHFEED"));
        registry.registerEntryPool(
            _poolKey(amps, weth9, hook), 18, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, vm.envAddress("FIXTURE_WETHFEED")
        );

        uint16[] memory ids = new uint16[](SPOKES);
        uint16[] memory weights = new uint16[](SPOKES);
        for (uint256 i; i < SPOKES; ++i) {
            address token = vm.envAddress(string.concat("FIXTURE_STOCK", vm.toString(i)));
            address feed = vm.envAddress(string.concat("FIXTURE_FEED", vm.toString(i)));
            _installFeed(feeds, token, feed);
            (uint16 constituentId,) = registry.addConstituent(
                IPoolRegistry.AddConstituentParams({
                    token: token,
                    feed: feed,
                    poolClass: PoolClass.SPOKE,
                    tickSpacing: TICK_SPACING,
                    buyFeeBps: Constants.BUY_FEE_BPS_SPOKE_DEFAULT,
                    // The registration weight has to be legal at every intermediate count; the launch vector is
                    // installed once, below, when all four are in.
                    targetWeightBps: 500,
                    rolloutWeightBps: 2_500,
                    hSessionOverrideBps: 0,
                    hSessionOverrideSet: false,
                    inclusion: InclusionRecord({
                        betaX18: 0.9e18,
                        trackingErrorX18: 0.02e18,
                        indexVolX18: 0.25e18,
                        historyDays: Constants.MIN_HISTORY_DAYS + 30,
                        recordedAt: 0
                    }),
                    openBondMarket: true
                })
            );
            ids[i] = constituentId;
            // 2,500 bp each: sums to 10,000 and sits inside `[500, 3000]`, which is what
            // `PoolRegistryLens.weightBoundsFor(4)` gives.
            weights[i] = 2_500;
        }
        registry.setIndexWeights(ids, weights);
        vm.stopBroadcast();

        console2.log("FIXTURE pools %s", registry.poolCount());
        console2.log("FIXTURE constituents %s", registry.activeConstituentCount());
    }

    // -----------------------------------------------------------------------------------------------------------
    // Stage 3 — the six Phase 3 pointer moves and the gate (09_Phase3Wire, inlined)
    // -----------------------------------------------------------------------------------------------------------

    function wire() public {
        address operator = vm.envAddress("FIXTURE_OPERATOR");
        AmpsVault vault = AmpsVault(vm.envAddress("FIXTURE_VAULT"));
        address hook = vm.envAddress("FIXTURE_HOOK");

        vm.startBroadcast(operator);
        OracleGate gate = new OracleGate(
            operator, operator, vm.envAddress("FIXTURE_FEEDREGISTRY"), vm.envAddress("FIXTURE_REGISTRY"), hook
        );

        vault.setPolicyPointer(bytes32("marketReference"), hook);
        vault.setPolicyPointer(bytes32("positionValuer"), vm.envAddress("FIXTURE_VALUER"));
        vault.setPolicyPointer(bytes32("ladderPolicy"), vm.envAddress("FIXTURE_LADDERPOLICY"));
        vault.setPolicyPointer(bytes32("rolloutPolicy"), vm.envAddress("FIXTURE_ROLLOUTPOLICY"));
        AmpsHook(hook).setFeePolicy(vm.envAddress("FIXTURE_FEEPOLICY"));
        AmpsBonds(vm.envAddress("FIXTURE_BONDS")).setPolicy(vm.envAddress("FIXTURE_BONDPOLICY"));
        IFeedRegistry(vm.envAddress("FIXTURE_FEEDREGISTRY")).setOracleGate(address(gate));
        vault.setPolicyPointer(bytes32("oracleGate"), address(gate));

        AmpsQuoter quoter = new AmpsQuoter(
            vm.envAddress("FIXTURE_POOLMANAGER"),
            hook,
            address(vault),
            vm.envAddress("FIXTURE_REGISTRY"),
            vm.envAddress("FIXTURE_BONDS"),
            address(gate),
            vm.envAddress("FIXTURE_FEEDREGISTRY")
        );
        vm.stopBroadcast();

        // §9.1 step 4: the gate has to be GREEN before genesis can run, and the hub's observation ring has to
        // cover `twapWindow` for it to be. If this reverts, the harness did not advance the chain far enough.
        GateState state = IOracleGate(address(gate)).state(0);
        if (state != GateState.GREEN) revert GateNotGreen(uint8(state));

        _emit("oracleGate", address(gate));
        _emit("quoter", address(quoter));
        console2.log("FIXTURE gateGreen 1");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Stage 4 — genesis and the ask ladders (11_GenesisPlacement phase 1, inlined)
    // -----------------------------------------------------------------------------------------------------------

    function genesisAsks() public {
        address operator = vm.envAddress("FIXTURE_OPERATOR");
        AmpsVault vault = AmpsVault(vm.envAddress("FIXTURE_VAULT"));
        IPoolRegistry registry = IPoolRegistry(vm.envAddress("FIXTURE_REGISTRY"));
        address usdg = vm.envAddress("FIXTURE_USDG");
        address weth9 = vm.envAddress("FIXTURE_WETH9");

        address[] memory seedTokens = new address[](2);
        uint256[] memory seedAmounts = new uint256[](2);
        seedTokens[0] = weth9;
        seedAmounts[0] = SEED_WETH;
        seedTokens[1] = usdg;
        seedAmounts[1] = SEED_USDG;

        vm.startBroadcast(operator);
        MockWeth9(payable(weth9)).mint(operator, SEED_WETH);
        MockUsdg(usdg).mint(operator, SEED_USDG);
        IERC20(weth9).approve(address(vault), SEED_WETH);
        IERC20(usdg).approve(address(vault), SEED_USDG);

        vault.genesis(
            IAmpsVault.GenesisParams({
                teamVestingWallet: vm.envAddress("FIXTURE_TEAMVESTING"),
                creator: operator,
                teamShares: Constants.TEAM_SHARES,
                polShares: Constants.POL_SHARES,
                seedTokens: seedTokens,
                seedAmounts: seedAmounts
            })
        );

        PoolId hub = registry.hubPoolId();
        PoolId weth = registry.wethPoolId();
        PoolId[] memory pools = _allPools(registry);
        for (uint256 i; i < pools.length; ++i) {
            bool isEntry =
                PoolId.unwrap(pools[i]) == PoolId.unwrap(hub) || PoolId.unwrap(pools[i]) == PoolId.unwrap(weth);
            vault.place(pools[i], true, isEntry ? ENTRY_ASK_AMPS : SPOKE_SEED_AMPS);
        }
        vm.stopBroadcast();

        console2.log("FIXTURE navPerShareX18 %s", vault.navPerShareX18());
        console2.log("FIXTURE liveCells %s", vault.liveCells());
    }

    // -----------------------------------------------------------------------------------------------------------
    // Stage 5 — the entry pools' seed bids (11_GenesisPlacement phase 2, inlined)
    // -----------------------------------------------------------------------------------------------------------

    function entryBids() public {
        address operator = vm.envAddress("FIXTURE_OPERATOR");
        AmpsVault vault = AmpsVault(vm.envAddress("FIXTURE_VAULT"));
        IPoolRegistry registry = IPoolRegistry(vm.envAddress("FIXTURE_REGISTRY"));

        vm.startBroadcast(operator);
        vault.place(registry.hubPoolId(), false, SEED_USDG);
        vault.place(registry.wethPoolId(), false, SEED_WETH);
        vm.stopBroadcast();

        // The §3.3 layout, checked by `11_GenesisPlacement`'s own assertion rather than by a copy of it.
        new GenesisPlacement().assertLayout(address(vault));
        console2.log("FIXTURE liveCells %s", vault.liveCells());
        console2.log("FIXTURE layoutOk 1");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Stage 6 — the bounty pot, and assets for the swap and bond drills
    // -----------------------------------------------------------------------------------------------------------

    function fund() public {
        address operator = vm.envAddress("FIXTURE_OPERATOR");
        address usdg = vm.envAddress("FIXTURE_USDG");
        address pot = vm.envAddress("FIXTURE_BOUNTYPOT");
        address swapper = vm.envAddress("FIXTURE_SWAPPER");

        vm.startBroadcast(operator);
        MockUsdg(usdg).mint(operator, POT_FUNDING);
        IERC20(usdg).approve(pot, POT_FUNDING);
        BountyPot(pot).fund(POT_FUNDING);

        // `deployThresholdUsd18` down to its band floor. One bond epoch's capacity is 50 bp of `T` = 25 AMPS,
        // i.e. about $25 of collateral, and the launch threshold is $100 — so at the fixture's size a single
        // bond could never clear it and the `deployBonded` drill would be testing nothing. $10 is
        // `Constants.DEPLOY_THRESHOLD_USD18_MIN`: a governed value inside its hard band, not a contract change.
        AmpsVault(vm.envAddress("FIXTURE_VAULT")).setDeployThresholdUsd18(Constants.DEPLOY_THRESHOLD_USD18_MIN);

        // The swapper trades out of its own balances, so it is funded rather than the operator.
        MockUsdg(usdg).mint(swapper, 1_000_000e6);
        MockWeth9(payable(vm.envAddress("FIXTURE_WETH9"))).mint(swapper, 1_000e18);
        for (uint256 i; i < SPOKES; ++i) {
            address stock = vm.envAddress(string.concat("FIXTURE_STOCK", vm.toString(i)));
            MockStockToken(stock).mint(swapper, 100_000e18);
            MockStockToken(stock).mint(operator, 100_000e18);
        }
        vm.stopBroadcast();

        console2.log("FIXTURE potBalance %s", BountyPot(pot).balance());
    }

    // -----------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The one pool-key shape `PoolRegistry._validateKeyShape` accepts: AMPS as `currency0`, the dynamic-fee
    ///      flag, and `AmpsHook`.
    function _poolKey(address amps, address counter, address hook) private pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(amps),
            currency1: Currency.wrap(counter),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    /// @dev `05_Registry._installFeed`: allowlist the aggregator as a Standard proxy, then configure it.
    function _installFeed(IFeedRegistry feeds, address token, address aggregator) private {
        feeds.setStandardProxy(aggregator, true);
        feeds.setFeed(
            token,
            aggregator,
            FeedConfig({
                aggregator: address(0),
                decimals: 0,
                set: false,
                heartbeat: HEARTBEAT,
                thresholdBps: FEED_THRESHOLD_BPS,
                minAnswerUsd8: FEED_MIN_ANSWER_USD8,
                maxAnswerUsd8: type(uint128).max
            })
        );
    }

    /// @dev The two entry pools, then one per constituent, in registration order.
    function _allPools(IPoolRegistry registry) private view returns (PoolId[] memory pools) {
        uint16 count = registry.constituentCount();
        pools = new PoolId[](uint256(count) + 2);
        pools[0] = registry.hubPoolId();
        pools[1] = registry.wethPoolId();
        for (uint16 id = 1; id <= count; ++id) {
            pools[uint256(id) + 1] = registry.poolIdOf(id);
        }
    }

    /// @dev One machine-readable line per address. See the contract note on why this is not a JSON file.
    function _emit(string memory name, address value) private pure {
        console2.log("FIXTURE %s %s", name, value);
    }

    /// @dev A CREATE2 salt putting AMPS two leading zero bytes low, mined against the factory a broadcast uses.
    function _mineAmpsSalt(address predictedVault) private pure returns (bytes32 salt) {
        bytes32 initHash = keccak256(abi.encodePacked(type(Amps).creationCode, abi.encode(predictedVault)));
        for (uint256 i; i < 1 << 22; ++i) {
            salt = bytes32(i);
            uint160 candidate =
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initHash))));
            if (candidate < AMPS_CEILING && candidate > 0xffff) return salt;
        }
        revert NoSalt();
    }
}
/// @title KeeperSwapper
/// @notice A third-party trader for the keeper's chain suite: it buys and sells against the vault's ladders so
///         that fees actually accrue, which is the only way to make `compound()` worth a bounty in a test.
///
/// @dev Modelled on `contracts/test/mocks/LadderSwapper.sol` and deliberately not imported from it: that file
///      settles through solmate's `MockERC20`, and the fixture's counters are OpenZeppelin ERC-20s. It holds its
///      own balances, is nobody's counterparty but the pool's, and is never the vault — so a swap it makes moves
///      the pool the way an arbitrageur would rather than the way the protocol would.
contract KeeperSwapper is IUnlockCallback {
    IPoolManager public immutable poolManager;

    error NotPoolManager();

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Swaps `amountSpecified` (negative for exact input) through `key`, stopping at `sqrtPriceLimitX96`.
    /// @param key The pool.
    /// @param zeroForOne True to sell AMPS (currency0) and push the price down.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @param sqrtPriceLimitX96 The price bound.
    /// @return delta The realised balance delta.
    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        returns (BalanceDelta delta)
    {
        bytes memory result = poolManager.unlock(abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96));
        delta = abi.decode(result, (BalanceDelta));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
            abi.decode(data, (PoolKey, bool, int256, uint160));

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(poolManager), uint256(uint128(-amount)));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
