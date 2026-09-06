// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Registry} from "ampsscript/05_Registry.s.sol";
import {Phase3Wire} from "ampsscript/09_Phase3Wire.s.sol";
import {MockWeth9, TestnetPools} from "ampsscript/10_TestnetPools.s.sol";
import {GenesisPlacement} from "ampsscript/11_GenesisPlacement.s.sol";
import {AmpsBonds} from "amps/bonds/AmpsBonds.sol";
import {AmpsHook} from "amps/hook/AmpsHook.sol";
import {IAmpsVault} from "amps/interfaces/IAmpsVault.sol";
import {IFeedRegistry} from "amps/interfaces/IFeedRegistry.sol";
import {IPoolRegistry} from "amps/interfaces/IPoolRegistry.sol";
import {BountyPot} from "amps/keeper/BountyPot.sol";
import {FeedRegistry} from "amps/oracle/FeedRegistry.sol";
import {OracleGate} from "amps/oracle/OracleGate.sol";
import {BondPolicy} from "amps/policy/BondPolicy.sol";
import {FeePolicy} from "amps/policy/FeePolicy.sol";
import {LadderPolicy} from "amps/policy/LadderPolicy.sol";
import {RolloutPolicy} from "amps/policy/RolloutPolicy.sol";
import {PoolRegistry} from "amps/registry/PoolRegistry.sol";
import {AmpsStaking} from "amps/staking/AmpsStaking.sol";
import {Amps} from "amps/token/Amps.sol";
import {Constants} from "amps/types/Constants.sol";
import {FeedConfig} from "amps/types/Types.sol";
import {LadderPositionValuer} from "amps/valuer/LadderPositionValuer.sol";
import {AmpsVault} from "amps/vault/AmpsVault.sol";
import {MockStockToken} from "ampstest/mocks/MockStockToken.sol";
import {MockUsdg} from "ampstest/mocks/MockUsdg.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

/// @title E2ESwapper
/// @notice The smallest v4 router that can drive a swap: unlock, swap, settle what is owed, take what is due.
///         Deliberately not the Universal Router — the indexer only needs `PoolManager.Swap` logs, and a router
///         with Permit2 in front of it would add a deployment and an approval dance that prove nothing here.
/// @dev Holds the tokens it swaps. `settle` is the sync/transfer/settle triple v4 requires; there is no
///      ERC-6909 accounting and no multi-hop.
contract E2ESwapper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;

    struct SwapRequest {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address recipient;
    }

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Swaps `amountIn` of the input currency, exact input, with no price limit beyond v4's own bound.
    /// @param key The pool.
    /// @param zeroForOne True to sell AMPS (currency0), false to buy it.
    /// @param amountIn The exact input amount, in the input currency's own units.
    /// @param recipient Who receives the output.
    /// @return delta The swap delta v4 returned.
    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            poolManager.unlock(abi.encode(SwapRequest(key, zeroForOne, amountIn, recipient))), (BalanceDelta)
        );
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only pool manager");
        SwapRequest memory request = abi.decode(data, (SwapRequest));

        BalanceDelta delta = poolManager.swap(
            request.key,
            SwapParams({
                zeroForOne: request.zeroForOne,
                amountSpecified: -int256(request.amountIn),
                sqrtPriceLimitX96: request.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        (Currency input, Currency output) = request.zeroForOne
            ? (request.key.currency0, request.key.currency1)
            : (request.key.currency1, request.key.currency0);
        int128 owed = request.zeroForOne ? delta.amount0() : delta.amount1();
        int128 due = request.zeroForOne ? delta.amount1() : delta.amount0();

        if (owed < 0) {
            poolManager.sync(input);
            IERC20(Currency.unwrap(input)).transfer(address(poolManager), uint256(uint128(-owed)));
            poolManager.settle();
        }
        if (due > 0) poolManager.take(output, request.recipient, uint256(uint128(due)));

        return abi.encode(delta);
    }

    /// @notice Redeems the swapper's own AMPS pro rata at NAV - `redeemFeeBps`, paying every asset to `to`.
    /// @dev Lives here rather than in the script because the AMPS a swap bought is held by this contract, and
    ///      `redeemProRata` burns the caller's own balance.
    /// @param vault `AmpsVault`.
    /// @param amps The AMPS token.
    /// @param shares AMPS wei to redeem.
    /// @param to The recipient of every asset paid.
    function redeem(address vault, address amps, uint256 shares, address to) external {
        IERC20(amps).approve(vault, shares);
        IAmpsVault(vault).redeemProRata(shares, to);
    }
}

/// @title AmpsE2E
/// @notice Stands the whole Amplestocks system up on a local `anvil` and then drives the user journey the
///         indexer's end-to-end suite indexes: genesis, a buy, a sell, a bond, a compound, a redemption and a
///         simulated beacon-level `blockAccounts` call.
///
/// @dev **This is test fixture code and lives in `apps/indexer/test/contracts/`, not in `contracts/`.** It is
///      compiled by pointing `FOUNDRY_SCRIPT` at this directory with the remappings `amps/=src/` and
///      `ampsscript/=script/`, so it can import the production contracts and the Phase 3 deploy scripts without
///      being part of the contracts project. Nothing in `contracts/` may reach it.
///
/// @dev **It reuses the Phase 3 scripts rather than reimplementing them.** `10_TestnetPools` deploys the mock
///      counter assets and drives `05_Registry` to open the 32 pools; `09_Phase3Wire` deploys `OracleGate`,
///      installs the calendar and moves the six pointers in the §9.1 order; `11_GenesisPlacement` mints `S0` and
///      lays the §3.3 ladders. What this script adds is the core deployment those scripts assume already exists
///      (`Amps`, `AmpsVault`, the mined `AmpsHook`, `PoolRegistry` and the periphery) and the actions afterwards.
///
/// @dev **Every entry point is separately invocable**, because the placement cooldown and the observation ring
///      both need wall-clock time between steps and `anvil`'s clock only moves between transactions. The harness
///      in `test/e2e/` calls them in order with `evm_increaseTime` in between. Addresses travel between
///      invocations through the environment; each step prints the full set as one JSON line prefixed
///      `AMPS_E2E_ADDRESSES`, which the harness parses.
contract AmpsE2E is Script {
    // -----------------------------------------------------------------------------------------------------------
    // Roles. The broadcaster is the timelock, so a script under `--broadcast` performs the governed calls
    // directly rather than pranking, which is not available outside a test.
    // -----------------------------------------------------------------------------------------------------------

    address internal deployer;
    address internal guardian;
    address internal creator;
    address internal team;
    address internal actor;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    /// @dev Two leading zero bytes is enough for AMPS to sort below every CREATE-addressed mock counter, and is
    ///      ~65k attempts rather than the 16.7M production's three bytes needs.
    uint160 internal constant AMPS_CEILING = uint160(1) << 144;

    /// @dev The founders' seed: 1 WETH ($2,500) + 2,500 USDG ($2,500) against `S0` = 5,000 AMPS.
    uint256 internal constant SEED_WETH = 1e18;
    uint256 internal constant SEED_USDG = 2500e6;

    /// @dev The §3.3 genesis ladder: 1,662.5 AMPS of ask in each entry pool, 47.5 in each spoke.
    uint256 internal constant ENTRY_ASK_AMPS = 1662.5e18;
    uint256 internal constant SPOKE_SEED_AMPS = 47.5e18;

    /// @dev What the actor starts with, and what it trades.
    uint256 internal constant ACTOR_USDG = 500e6;
    /// @dev Deliberately small. The genesis hub ladder is 1,662.5 AMPS over ten doublings, so 200 USDG walks the
    ///      tick 11,892 ticks — six times the entry pool's 2,000-tick outer rail — and the *next* deviation-
    ///      increasing swap is refused by the hook, which is the rail working exactly as designed. 10 USDG moves
    ///      the pool ~1,000 ticks and leaves room for the sell that follows.
    uint256 internal constant BUY_USDG_DEFAULT = 10e6;
    uint256 internal constant BOND_STOCK = 1e18;

    // -----------------------------------------------------------------------------------------------------------
    // The system
    // -----------------------------------------------------------------------------------------------------------

    struct Deployment {
        address poolManager;
        address amps;
        address vault;
        address hook;
        address registry;
        address feedRegistry;
        address bonds;
        address staking;
        address bountyPot;
        address valuer;
        address ladderPolicy;
        address rolloutPolicy;
        address feePolicy;
        address bondPolicy;
        address oracleGate;
        address teamVesting;
        address usdg;
        address weth9;
        address swapper;
        address stock0;
        address creator;
        address timelock;
        address guardian;
        address actor;
    }

    Deployment internal d;

    // -----------------------------------------------------------------------------------------------------------
    // Entry points
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Step 1: the counter assets, the core, the periphery, the pointers and the pools.
    /// @dev **Only `AMPS_E2E_SPOKES` of the 30 launch spokes are registered** (three by default). The launch set
    ///      is 32 pools, and `Phase3Scripts.t.sol` proves all 32 register; what this fixture needs is the
    ///      *shape* — the hub, the WETH leg and enough spokes to bond into — and the whole point of running it
    ///      against a real node is that every step is a real transaction, of which 32 pools would be several
    ///      hundred. The registry, the gate and the genesis placement do not care how many there are: the
    ///      launch weight vector is simply left uninstalled, exactly as `_installWeights` does for any partial
    ///      set.
    function deploy() external {
        _roles();
        _ensurePoolManager();
        TestnetPools testnet = new TestnetPools();
        Registry registrar = new Registry();
        testnet.setRegistrar(registrar);

        uint256 spokeCount = vm.envOr("AMPS_E2E_SPOKES", uint256(3));
        TestnetPools.Assets memory empty;
        empty.stocks = new address[](0);
        empty.feeds = new address[](0);
        TestnetPools.Assets memory assets = testnet.deployAssets(deployer, empty, spokeCount);

        _deployCore(assets);
        _deployPeriphery(assets);
        _wirePointers();

        Registry.EntryPoolSpec[] memory entries = registrar.loadEntryPools();
        Registry.SpokeSpec[] memory all = registrar.loadSpokes();
        Registry.SpokeSpec[] memory spokes = new Registry.SpokeSpec[](spokeCount);
        for (uint256 i; i < spokeCount; ++i) {
            spokes[i] = all[i];
            spokes[i].token = assets.stocks[i];
            spokes[i].feed = assets.feeds[i];
        }
        for (uint256 i; i < entries.length; ++i) {
            if (_isSymbol(entries[i].symbol, "USDG")) {
                entries[i].counter = assets.usdg;
                entries[i].feed = assets.usdgFeed;
            } else {
                entries[i].counter = assets.weth9;
                entries[i].feed = assets.wethFeed;
            }
        }

        _register(registrar, entries, spokes);

        d.usdg = assets.usdg;
        d.weth9 = assets.weth9;
        d.stock0 = assets.stocks[0];
        _report();
    }

    function _isSymbol(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev The registration `05_Registry.execute` performs, inlined into *this* script's broadcast window.
    ///
    ///      **Why it is inlined rather than delegated.** `forge script --broadcast` does not increment the
    ///      broadcaster's nonce for `CALL` transactions issued from a `vm.startBroadcast` window opened inside a
    ///      *nested* contract: every such transaction is planned with the same nonce and the run dies with
    ///      "EOA nonce changed unexpectedly". `05_Registry`, `09_Phase3Wire` and `11_GenesisPlacement` all open
    ///      their own windows, which is correct when each is run as its own `forge script` and is what
    ///      `Phase3Scripts.t.sol` exercises. Here they are driven from one script, so this fixture calls their
    ///      *pure and view* halves — `loadEntryPools`, `loadSpokes`, `poolKeyFor`, `buildCalls`, `allPools`,
    ///      `nextPhase`, `checkBootstrap`, `assertGateGreen` — and issues every transaction itself.
    function _register(
        Registry registrar,
        Registry.EntryPoolSpec[] memory entries,
        Registry.SpokeSpec[] memory spokes
    ) private {
        IPoolRegistry registry = IPoolRegistry(d.registry);
        vm.startBroadcast(deployer);
        for (uint256 i; i < entries.length; ++i) {
            Registry.EntryPoolSpec memory e = entries[i];
            _installFeed(e.counter, e.feed, e.heartbeatSeconds);
            registry.registerEntryPool(
                registrar.poolKeyFor(d.amps, e.counter, e.tickSpacing, d.hook),
                e.counterDecimals,
                e.buyFeeBps,
                e.feed
            );
        }
        for (uint256 i; i < spokes.length; ++i) {
            Registry.SpokeSpec memory sp = spokes[i];
            _installFeed(sp.token, sp.feed, sp.heartbeatSeconds);
            registry.addConstituent(
                IPoolRegistry.AddConstituentParams({
                    token: sp.token,
                    feed: sp.feed,
                    poolClass: sp.poolClass,
                    tickSpacing: sp.tickSpacing,
                    buyFeeBps: sp.buyFeeBps,
                    targetWeightBps: 500,
                    rolloutWeightBps: sp.rolloutWeightBps,
                    hSessionOverrideBps: sp.hSessionOverrideBps,
                    hSessionOverrideSet: sp.hSessionOverrideSet,
                    inclusion: sp.inclusion,
                    openBondMarket: sp.openBondMarket
                })
            );
        }
        vm.stopBroadcast();
        console2.log("registered %s entry pools and %s spokes", entries.length, spokes.length);
    }

    /// @dev Allowlists an aggregator as a Chainlink Standard proxy and configures it for `token`, exactly as
    ///      `05_Registry._installFeed` does.
    function _installFeed(address token, address aggregator, uint32 heartbeatSeconds) private {
        IFeedRegistry feeds = IFeedRegistry(d.feedRegistry);
        if (feeds.feedOf(token) == aggregator) return;
        feeds.setStandardProxy(aggregator, true);
        feeds.setFeed(
            token,
            aggregator,
            FeedConfig({
                aggregator: address(0),
                decimals: 0,
                set: false,
                heartbeat: heartbeatSeconds,
                thresholdBps: 50,
                minAnswerUsd8: 1,
                maxAnswerUsd8: type(uint128).max
            })
        );
    }

    /// @notice Step 2: `OracleGate`, the calendar and the six pointer moves. Needs the hub ring to cover
    ///         `twapWindow`, so the harness advances the clock past 30 minutes before calling it.
    function wire() external {
        _load();
        Phase3Wire wiring = new Phase3Wire();

        vm.startBroadcast(deployer);
        OracleGate gate = new OracleGate(deployer, guardian, d.feedRegistry, d.registry, d.hook);
        gate.setDstTable(wiring.dstStarts(), wiring.dstEnds());
        gate.setHolidayBitmap(2026, wiring.holidayBitmap2026());
        vm.stopBroadcast();
        d.oracleGate = address(gate);

        // The six pointer moves, in the §9.1 order `09_Phase3Wire.buildCalls` fixes. The gate pointer is the
        // last of the seven, and `checkBootstrap` runs before it exactly as the script does.
        Phase3Wire.Call[] memory calls = wiring.buildCalls(_targets(), d.oracleGate);
        vm.startBroadcast(deployer);
        for (uint256 i; i + 1 < calls.length; ++i) _send(calls[i]);
        IFeedRegistry(d.feedRegistry).setOracleGate(d.oracleGate);
        vm.stopBroadcast();

        wiring.checkBootstrap(_targets(), IPoolRegistry(d.registry).poolCount());

        vm.startBroadcast(deployer);
        _send(calls[calls.length - 1]);
        vm.stopBroadcast();

        wiring.assertGateGreen(d.oracleGate);
        console2.log("gate is GREEN at %s", d.oracleGate);
        _report();
    }

    function _send(Phase3Wire.Call memory call) private {
        (bool ok, bytes memory reason) = call.target.call(call.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    /// @notice Step 3: `genesis()` and the ask ladder in every pool.
    function genesisAsks() external {
        _load();
        _fundSeed();
        GenesisPlacement placement = new GenesisPlacement();
        IAmpsVault vault = IAmpsVault(d.vault);
        IPoolRegistry registry = IPoolRegistry(d.registry);

        address[] memory seedTokens = new address[](2);
        uint256[] memory seedAmounts = new uint256[](2);
        seedTokens[0] = d.weth9;
        seedAmounts[0] = SEED_WETH;
        seedTokens[1] = d.usdg;
        seedAmounts[1] = SEED_USDG;

        vm.startBroadcast(deployer);
        IERC20(d.weth9).approve(d.vault, SEED_WETH);
        IERC20(d.usdg).approve(d.vault, SEED_USDG);
        vault.genesis(
            IAmpsVault.GenesisParams({
                teamVestingWallet: d.teamVesting,
                creator: creator,
                teamShares: Constants.TEAM_SHARES,
                polShares: Constants.POL_SHARES,
                seedTokens: seedTokens,
                seedAmounts: seedAmounts
            })
        );
        vm.stopBroadcast();

        PoolId hub = registry.hubPoolId();
        PoolId weth = registry.wethPoolId();
        PoolId[] memory pools = placement.allPools(d.vault);
        vm.startBroadcast(deployer);
        for (uint256 i; i < pools.length; ++i) {
            bool isEntry =
                PoolId.unwrap(pools[i]) == PoolId.unwrap(hub) || PoolId.unwrap(pools[i]) == PoolId.unwrap(weth);
            vault.place(pools[i], true, isEntry ? ENTRY_ASK_AMPS : SPOKE_SEED_AMPS);
        }
        vm.stopBroadcast();
        console2.log("genesis: %s ask ladders, nav %s", pools.length, vault.navPerShareX18());
        _report();
    }

    /// @notice Step 4: the two entry-pool seed bid ladders. Needs the 60-second placement cooldown to elapse.
    function genesisBids() external {
        _load();
        IAmpsVault vault = IAmpsVault(d.vault);
        IPoolRegistry registry = IPoolRegistry(d.registry);
        vm.startBroadcast(deployer);
        vault.place(registry.wethPoolId(), false, SEED_WETH);
        vault.place(registry.hubPoolId(), false, SEED_USDG);
        vm.stopBroadcast();
        console2.log("seed bid ladders placed, live cells %s", vault.liveCells());
        _report();
    }

    /// @notice Step 5: a buy through the hub's ask ladder, then a sell back through it. The buy consumes the
    ///         ladder bottom-up and pays the 30 bp entry-pool buy fee; the sell pays the 5% sell fee.
    function trade() external {
        _load();
        IPoolRegistry registry = IPoolRegistry(d.registry);
        PoolKey memory hub = registry.poolKey(registry.hubPoolId());

        uint256 buyUsdg = vm.envOr("AMPS_E2E_BUY_USDG", BUY_USDG_DEFAULT);
        vm.startBroadcast(deployer);
        MockUsdg(d.usdg).mint(d.swapper, ACTOR_USDG);
        E2ESwapper(d.swapper).swap(hub, false, buyUsdg, d.swapper);
        vm.stopBroadcast();

        uint256 bought = IERC20(d.amps).balanceOf(d.swapper);
        console2.log("bought %s AMPS wei for %s USDG", bought, buyUsdg);

        vm.startBroadcast(deployer);
        E2ESwapper(d.swapper).swap(hub, true, bought / 4, d.swapper);
        vm.stopBroadcast();
        console2.log("sold %s AMPS wei back", bought / 4);
        _report();
    }

    /// @notice Step 6: bond a Stock Token into its spoke, at whatever discount the market quotes.
    function bond() external {
        _load();
        IPoolRegistry registry = IPoolRegistry(d.registry);
        uint16 constituentId = registry.constituentIdOf(d.stock0);
        uint16 marketId = registry.constituent(constituentId).marketId;

        vm.startBroadcast(deployer);
        MockStockToken(d.stock0).mint(deployer, BOND_STOCK);
        // `AmpsBonds` settles through the vault, which is the address that pulls the collateral (I12), so the
        // approval goes to `AmpsVault` and not to the bond shell.
        IERC20(d.stock0).approve(d.vault, BOND_STOCK);
        (uint256 out,) = AmpsBonds(d.bonds).bond(marketId, BOND_STOCK, 0, deployer);
        vm.stopBroadcast();
        console2.log("bonded market %s for %s AMPS wei", marketId, out);
        _report();
    }

    /// @notice Step 7: `compound()` on the hub — the four-way split of the AMPS-side fees the sell left behind.
    function compound() external {
        _load();
        IPoolRegistry registry = IPoolRegistry(d.registry);
        vm.startBroadcast(deployer);
        (uint256 fees, uint256 burned) = IAmpsVault(d.vault).compound(registry.hubPoolId());
        vm.stopBroadcast();
        console2.log("compounded: %s fee wei, %s burned", fees, burned);
        _report();
    }

    /// @notice Step 8: a pro-rata redemption at NAV - 1%, the structurally unpausable floor.
    function redeem() external {
        _load();
        uint256 balance = IERC20(d.amps).balanceOf(d.swapper);
        require(balance > 0, "swapper holds no AMPS");
        vm.startBroadcast(deployer);
        E2ESwapper(d.swapper).redeem(d.vault, d.amps, balance / 2, deployer);
        vm.stopBroadcast();
        console2.log("redeemed %s AMPS wei", balance / 2);
        _report();
    }

    /// @notice Step 9: the beacon-level denylist, simulated. `MockStockToken.blockAccounts(address[])` carries
    ///         the same `0x6abf7081` selector as the real one, which is what the alarm watches for.
    function denylist() external {
        _load();
        address[] memory accounts = new address[](1);
        accounts[0] = d.vault;
        vm.startBroadcast(deployer);
        MockStockToken(d.stock0).blockAccounts(accounts);
        vm.stopBroadcast();
        console2.log("blockAccounts called on %s for the vault", d.stock0);
        _report();
    }

    /// @notice A free `checkpoint()`, so the harness can force a reconciliation block whenever it wants one.
    function checkpoint() external {
        _load();
        vm.startBroadcast(deployer);
        IAmpsVault(d.vault).checkpoint();
        vm.stopBroadcast();
        _report();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Deployment
    // -----------------------------------------------------------------------------------------------------------

    function _roles() private {
        deployer = vm.envOr("AMPS_E2E_DEPLOYER", address(0));
        require(deployer != address(0), "AMPS_E2E_DEPLOYER unset");
        guardian = vm.envOr("AMPS_E2E_GUARDIAN", deployer);
        creator = vm.envOr("AMPS_E2E_CREATOR", address(0xC12EA704));
        team = vm.envOr("AMPS_E2E_TEAM", address(0x7EA11));
        actor = deployer;
        d.timelock = deployer;
        d.guardian = guardian;
        d.creator = creator;
        d.actor = actor;
    }

    /// @dev `Amps` (CREATE2, mined below every counter), `AmpsVault`, the flag-mined production `AmpsHook` and
    ///      `PoolRegistry`. The registry's address is predicted because the hook takes it in its constructor and
    ///      the registry takes the hook in its own — the same circularity `04_MineHook` resolves with a
    ///      placeholder. Both the CREATE and the CREATE2 addresses are derived from the *broadcaster*, which is
    ///      what forge uses when the script is broadcasting.
    function _deployCore(TestnetPools.Assets memory assets) private {
        // The four core deployments are consecutive transactions from the broadcaster, and a CREATE2 through
        // the deterministic factory consumes a nonce exactly as a CREATE does. So: `Amps` at `nonce` (CREATE2),
        // `AmpsVault` at `nonce + 1`, `PoolRegistry` at `nonce + 2`, `AmpsHook` at `nonce + 3` (CREATE2). Only
        // the two CREATE addresses have to be predicted; the two CREATE2 ones are derived from their salts.
        uint64 nonce = vm.getNonce(deployer);
        address predictedVault = vm.computeCreateAddress(deployer, nonce + 1);
        address predictedRegistry = vm.computeCreateAddress(deployer, nonce + 2);

        bytes32 ampsSalt = _mineAmpsSalt(predictedVault);
        bytes memory hookArgs =
            abi.encode(d.poolManager, _predictAmps(ampsSalt, predictedVault), predictedVault, predictedRegistry, deployer);
        (address minedHook, bytes32 hookSalt) =
            HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(AmpsHook).creationCode, hookArgs);

        vm.startBroadcast(deployer);
        Amps amps = new Amps{salt: ampsSalt}(predictedVault);
        AmpsVault vault = new AmpsVault(address(amps), d.poolManager, deployer, guardian);
        PoolRegistry registry =
            new PoolRegistry(address(vault), minedHook, deployer, address(amps), assets.weth9, assets.usdg);
        AmpsHook hook = new AmpsHook{salt: hookSalt}(
            IPoolManager(d.poolManager), address(amps), address(vault), address(registry), deployer
        );
        vm.stopBroadcast();

        require(address(amps) == _predictAmps(ampsSalt, predictedVault), "amps address prediction");
        require(address(vault) == predictedVault, "vault address prediction");
        require(address(registry) == predictedRegistry, "registry address prediction");
        require(address(hook) == minedHook, "hook address prediction");

        d.amps = address(amps);
        d.vault = address(vault);
        d.registry = address(registry);
        d.hook = address(hook);
    }

    /// @dev Everything the vault points at, plus the three policies, the team's vesting wallet and the swapper.
    ///      `OracleGate` is deliberately absent: `09_Phase3Wire` deploys it.
    function _deployPeriphery(TestnetPools.Assets memory assets) private {
        vm.startBroadcast(deployer);
        FeedRegistry feeds = new FeedRegistry(deployer, address(0));
        BondPolicy bondPolicy = new BondPolicy();
        AmpsBonds bonds = new AmpsBonds(d.vault, d.registry, address(bondPolicy));
        AmpsStaking staking = new AmpsStaking(IERC20(d.amps), d.vault, deployer);
        BountyPot pot = new BountyPot(assets.usdg, d.vault, deployer);
        LadderPositionValuer valuer =
            new LadderPositionValuer(IExtsload(d.poolManager), d.vault, IPoolRegistry(d.registry));
        LadderPolicy ladderPolicy = new LadderPolicy();
        RolloutPolicy rolloutPolicy = new RolloutPolicy();
        FeePolicy feePolicy =
            new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18);
        VestingWallet vesting = new VestingWallet(team, uint64(block.timestamp), Constants.TEAM_VEST_SECONDS);
        E2ESwapper swapper = new E2ESwapper(IPoolManager(d.poolManager));
        vm.stopBroadcast();

        d.feedRegistry = address(feeds);
        d.bondPolicy = address(bondPolicy);
        d.bonds = address(bonds);
        d.staking = address(staking);
        d.bountyPot = address(pot);
        d.valuer = address(valuer);
        d.ladderPolicy = address(ladderPolicy);
        d.rolloutPolicy = address(rolloutPolicy);
        d.feePolicy = address(feePolicy);
        d.teamVesting = address(vesting);
        d.swapper = address(swapper);
    }

    /// @dev Step 1 of §9.1: every pointer except `oracleGate`, which `09_Phase3Wire` installs last.
    ///      `marketReference` starts on the hook here rather than on a Phase 2 mock — there is no earlier
    ///      pointer to move, and the wiring script leaves an already-correct pointer alone.
    function _wirePointers() private {
        vm.startBroadcast(deployer);
        IAmpsVault vault = IAmpsVault(d.vault);
        vault.setPolicyPointer(bytes32("registry"), d.registry);
        vault.setPolicyPointer(bytes32("bonds"), d.bonds);
        vault.setPolicyPointer(bytes32("staking"), d.staking);
        vault.setPolicyPointer(bytes32("bountyPot"), d.bountyPot);
        vault.setPolicyPointer(bytes32("feedRegistry"), d.feedRegistry);
        vault.setPolicyPointer(bytes32("marketReference"), d.hook);
        vault.setPolicyPointer(bytes32("positionValuer"), d.valuer);
        vm.stopBroadcast();
    }

    function _fundSeed() private {
        vm.startBroadcast(deployer);
        MockWeth9(payable(d.weth9)).mint(deployer, SEED_WETH);
        MockUsdg(d.usdg).mint(deployer, SEED_USDG);
        vm.stopBroadcast();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Wiring structs
    // -----------------------------------------------------------------------------------------------------------

    function _wiring() private view returns (Registry.Wiring memory w) {
        w = Registry.Wiring({
            timelock: deployer,
            registry: d.registry,
            amps: d.amps,
            hook: d.hook,
            feedRegistry: d.feedRegistry,
            bonds: d.bonds,
            registrationWeightBps: 500
        });
    }

    function _targets() private view returns (Phase3Wire.Targets memory t) {
        t = Phase3Wire.Targets({
            timelock: deployer,
            guardian: guardian,
            vault: d.vault,
            hook: d.hook,
            registry: d.registry,
            bonds: d.bonds,
            feedRegistry: d.feedRegistry,
            oracleGate: d.oracleGate,
            positionValuer: d.valuer,
            ladderPolicy: d.ladderPolicy,
            rolloutPolicy: d.rolloutPolicy,
            feePolicy: d.feePolicy,
            bondPolicy: d.bondPolicy
        });
    }

    // -----------------------------------------------------------------------------------------------------------
    // Address transport
    // -----------------------------------------------------------------------------------------------------------

    /// @dev `contracts/foundry.toml` grants write access to `./gas` and `./script/config` only, and this fixture
    ///      must not touch either, so the address book travels over stdout as one JSON line and the harness
    ///      parses it. That is also why every entry point re-prints the whole set.
    function _report() private view {
        console2.log(
            string.concat(
                "AMPS_E2E_ADDRESSES ",
                "{",
                _kv("poolManager", d.poolManager),
                _kv("amps", d.amps),
                _kv("vault", d.vault),
                _kv("hook", d.hook),
                _kv("registry", d.registry),
                _kv("feedRegistry", d.feedRegistry),
                _kv("bonds", d.bonds),
                _kv("staking", d.staking),
                _kv("bountyPot", d.bountyPot),
                _kv("valuer", d.valuer),
                _kv("ladderPolicy", d.ladderPolicy),
                _kv("rolloutPolicy", d.rolloutPolicy)
            )
        );
        console2.log(
            string.concat(
                "AMPS_E2E_ADDRESSES2 ",
                "{",
                _kv("feePolicy", d.feePolicy),
                _kv("bondPolicy", d.bondPolicy),
                _kv("oracleGate", d.oracleGate),
                _kv("teamVesting", d.teamVesting),
                _kv("usdg", d.usdg),
                _kv("weth9", d.weth9),
                _kv("swapper", d.swapper),
                _kv("stock0", d.stock0),
                _kv("creator", creator),
                _kv("timelock", deployer),
                _kv("guardian", guardian),
                _kv("actor", actor)
            )
        );
    }

    function _kv(string memory key, address value) private pure returns (string memory) {
        return string.concat('"', key, '":"', vm.toString(value), '",');
    }

    /// @dev Reload the address book from the environment for a step after `deploy()`.
    function _load() private {
        _roles();
        d.poolManager = vm.envAddress("AMPS_POOL_MANAGER");
        d.amps = vm.envAddress("AMPS_TOKEN");
        d.vault = vm.envAddress("AMPS_VAULT");
        d.hook = vm.envAddress("AMPS_HOOK");
        d.registry = vm.envAddress("AMPS_REGISTRY");
        d.feedRegistry = vm.envAddress("AMPS_FEED_REGISTRY");
        d.bonds = vm.envAddress("AMPS_BONDS");
        d.staking = vm.envAddress("AMPS_STAKING");
        d.bountyPot = vm.envAddress("AMPS_BOUNTY_POT");
        d.valuer = vm.envAddress("AMPS_POSITION_VALUER");
        d.ladderPolicy = vm.envAddress("AMPS_LADDER_POLICY");
        d.rolloutPolicy = vm.envAddress("AMPS_ROLLOUT_POLICY");
        d.feePolicy = vm.envAddress("AMPS_FEE_POLICY");
        d.bondPolicy = vm.envAddress("AMPS_BOND_POLICY");
        d.oracleGate = vm.envOr("AMPS_ORACLE_GATE", address(0));
        d.teamVesting = vm.envAddress("AMPS_TEAM_VESTING");
        d.usdg = vm.envAddress("AMPS_USDG");
        d.weth9 = vm.envAddress("AMPS_WETH9");
        d.swapper = vm.envAddress("AMPS_E2E_SWAPPER");
        d.stock0 = vm.envAddress("AMPS_E2E_STOCK0");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The v4 `PoolManager`, deployed from hookmate's pre-compiled artefact on first use so no v4-core
    ///      source (pinned to solc 0.8.26) enters this compilation graph.
    function _ensurePoolManager() private {
        if (d.poolManager != address(0)) return;
        address configured = vm.envOr("AMPS_POOL_MANAGER", address(0));
        if (configured != address(0)) {
            d.poolManager = configured;
            return;
        }
        vm.startBroadcast(deployer);
        d.poolManager = V4PoolManagerDeployer.deploy(deployer);
        vm.stopBroadcast();
    }

    /// @dev A CREATE2 salt putting `Amps` two leading zero bytes low, so every CREATE-addressed mock counter
    ///      sorts above it and AMPS is `currency0` in all 32 pools.
    function _mineAmpsSalt(address predictedVault) private pure returns (bytes32 salt) {
        bytes32 initHash = keccak256(abi.encodePacked(type(Amps).creationCode, abi.encode(predictedVault)));
        for (uint256 i; i < 1 << 22; ++i) {
            salt = bytes32(i);
            uint160 candidate =
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, initHash))));
            if (candidate < AMPS_CEILING && candidate > 0xffff) return salt;
        }
        revert("no AMPS salt below the ceiling");
    }

    function _predictAmps(bytes32 salt, address predictedVault) private pure returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(Amps).creationCode, abi.encode(predictedVault)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, initHash)))));
    }
}
