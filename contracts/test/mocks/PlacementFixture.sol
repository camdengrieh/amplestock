// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IPoolRegistry} from "../../src/interfaces/IPoolRegistry.sol";
import {BountyPot} from "../../src/keeper/BountyPot.sol";
import {LadderLib} from "../../src/lib/LadderLib.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {FeedRegistry} from "../../src/oracle/FeedRegistry.sol";
import {OracleGate} from "../../src/oracle/OracleGate.sol";
import {PoolRegistry} from "../../src/registry/PoolRegistry.sol";
import {AmpsStaking} from "../../src/staking/AmpsStaking.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {FeedConfig, InclusionRecord, PlacementRecord, PoolClass} from "../../src/types/Types.sol";
import {LadderPositionValuer} from "../../src/valuer/LadderPositionValuer.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {V4TestBase} from "../utils/V4TestBase.sol";
import {MockVaultRole} from "./AmpsVaultFixture.sol";
import {MockAggregator} from "./MockAggregator.sol";
import {MockStockToken} from "./MockStockToken.sol";
import {MockUsdg} from "./MockUsdg.sol";
import {PlacementHookStub} from "./PlacementHookStub.sol";
import {PlacementLadderPolicyStub} from "./PlacementLadderPolicyStub.sol";
import {PlacementRolloutPolicyStub} from "./PlacementRolloutPolicyStub.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title PlacementFixture
/// @notice A real system on `V4TestBase` for the Phase 3 placement suites: real `Amps`, `AmpsVault` (with all
///         three linked libraries), `PoolRegistry`, `OracleGate`, `FeedRegistry`, `AmpsStaking`, `BountyPot` and
///         `LadderPositionValuer`, against **live Uniswap v4 pools** — four of them, so a placement really adds
///         liquidity, a swap really consumes it, and a redemption really removes it.
///
/// @dev Modelled on `test/integration/Phase2Fixture.sol`, with three substitutions. The pool hook is
///      {PlacementHookStub} rather than the production `AmpsHook`, which is being written concurrently: it carries
///      the same `0x38C0` flags, the same `beforeInitialize` preconditions, the `gridBaseTick` /
///      `highWaterTick` / `resetHighWater` / `armSurge` surface the placement path reaches, and the
///      `IMarketReference` observation surface, because in production one contract answers all of them. The ladder
///      and rollout policies are {PlacementLadderPolicyStub} and {PlacementRolloutPolicyStub}, which implement §5
///      over `LadderLib`. Everything the placement invariants assert about is real code.
///
/// @dev **Wiring order**, and it is not the order the state model lists, for the reason `Phase2Fixture` records:
///      `AmpsVault.initializePool` is gated, and `OracleGate` reports `WATCHDOG` until the hub pool has
///      `twapWindow` of observation coverage, so registering the first pool through a wired gate is circular. The
///      pools are registered with the gate pointer unset, the rings are seeded, and only then does the vault get
///      the gate — after which `genesis()` and every placement run fully gated.
abstract contract PlacementFixture is V4TestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // -------------------------------------------------------------------------------------------------------------
    // Roles and launch vector
    // -------------------------------------------------------------------------------------------------------------

    address internal constant TIMELOCK = address(0x71E10C4);
    address internal constant GUARDIAN = address(0x6A4D1A17);
    address internal constant CREATOR = address(0xC12EA704);
    address internal constant STANDBY = address(0x57A4DB1);
    address internal constant TEAM = address(0x7EA11);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant KEEPER = address(0x6EE9E4);
    address internal constant STAKER = address(0x57A4E4);

    /// @dev 2026-09-09 14:00:00 UTC — a Wednesday, 10:00 ET, squarely inside `REGULAR`.
    uint256 internal constant GENESIS_TIME = 1_788_962_400;
    uint256 internal constant GENESIS_BLOCK = 20_000_000;

    uint128 internal constant WETH_USD8 = 2500e8;
    uint128 internal constant USDG_USD8 = 1e8;
    uint256 internal constant SEED_WETH = 1e18;
    uint256 internal constant SEED_USDG = 2500e6;

    /// @dev Two spokes is enough for every property in §3 and keeps the suites fast; the redemption gas test
    ///      extrapolates from the measured per-pool cost to the 32-pool launch shape.
    uint256 internal constant SPOKES = 2;

    int24 internal constant TICK_SPACING = 60;
    uint16 internal constant TARGET_WEIGHT_BPS = 5000;
    uint16 internal constant ROLLOUT_WEIGHT_BPS = 5000;

    /// @dev The confirmed genesis ladder amounts of §3.3: 1,662.5 AMPS of asks in each entry pool, 47.5 AMPS
    ///      (1% of the 4,750 POL tranche) as each spoke's seed ask.
    uint256 internal constant ENTRY_ASK_AMPS = 1662.5e18;
    uint256 internal constant SPOKE_SEED_AMPS = 47.5e18;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    // -------------------------------------------------------------------------------------------------------------
    // The system
    // -------------------------------------------------------------------------------------------------------------

    Amps internal amps;
    AmpsVault internal vault;
    PoolRegistry internal registry;
    AmpsStaking internal staking;
    BountyPot internal pot;
    OracleGate internal gate;
    FeedRegistry internal feeds;
    LadderPositionValuer internal valuer;
    PlacementHookStub internal hook;
    PlacementLadderPolicyStub internal ladderPolicy;
    PlacementRolloutPolicyStub internal rolloutPolicy;

    /// @dev Stands in for `AmpsBonds`: the only address that may deposit collateral, and one of the three role
    ///      handovers `emergencyMigrate` performs. The real shell is Phase 2 code with its own suite.
    MockVaultRole internal bondsRole;

    MockERC20 internal weth;
    MockUsdg internal usdg;
    MockAggregator internal wethFeed;
    MockAggregator internal usdgFeed;

    MockStockToken[SPOKES] internal stocks;
    MockAggregator[SPOKES] internal stockFeeds;
    uint16[SPOKES] internal constituentIds;
    PoolId[SPOKES] internal spokePools;

    PoolId internal hubPool;
    PoolId internal wethPool;

    uint128[SPOKES] internal STOCK_USD8 = [uint128(180e8), 250e8];
    string[SPOKES] internal STOCK_SYMBOLS = ["NVDX", "AAPX"];

    // -------------------------------------------------------------------------------------------------------------
    // Deployment
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Deploys and wires the whole world, registers the four pools and runs `genesis()`. After this the
    ///         vault holds 4,750 AMPS of POL inventory, `A` is $5,000 and NAV/share is $1.00.
    function deployPlacementWorld() internal {
        vm.warp(GENESIS_TIME);
        vm.roll(GENESIS_BLOCK);

        deployV4();
        _deployAssets();
        _deployCore();
        _deployPeriphery();
        _configureOracles();
        _wireVault();
        _registerPools();
        _seedRings(Constants.WAD);
        _pointAtGate();
        _runGenesis();
    }

    /// @notice The §3.3 genesis ladders: the ask ladder in every pool, then — after the 60-second per-pool
    ///         cooldown — the seed bids in the two entry pools.
    function placeGenesisLadders() internal {
        vm.startPrank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        vault.place(wethPool, true, ENTRY_ASK_AMPS);
        for (uint256 i; i < SPOKES; ++i) {
            vault.place(spokePools[i], true, SPOKE_SEED_AMPS);
        }
        vm.stopPrank();

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.startPrank(TIMELOCK);
        vault.place(hubPool, false, SEED_USDG);
        vault.place(wethPool, false, SEED_WETH);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Deployment steps
    // -------------------------------------------------------------------------------------------------------------

    function _deployAssets() private {
        weth = deployToken("Wrapped Ether", "WETH", 18);
        usdg = new MockUsdg("Global Dollar", "USDG", 6);
        wethFeed = new MockAggregator("ETH / USD", 8, int256(uint256(WETH_USD8)));
        usdgFeed = new MockAggregator("USDG / USD", 8, int256(uint256(USDG_USD8)));

        for (uint256 i; i < SPOKES; ++i) {
            stocks[i] = new MockStockToken(STOCK_SYMBOLS[i], STOCK_SYMBOLS[i]);
            stockFeeds[i] =
                new MockAggregator(string.concat(STOCK_SYMBOLS[i], " / USD"), 8, int256(uint256(STOCK_USD8[i])));
            vm.label(address(stocks[i]), STOCK_SYMBOLS[i]);
        }
        vm.label(address(weth), "WETH");
        vm.label(address(usdg), "USDG");
    }

    function _deployCore() private {
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        bytes32 salt = _mineAmpsSalt(predictedVault);

        amps = new Amps{salt: salt}(predictedVault);
        vault = new AmpsVault(address(amps), address(poolManager), TIMELOCK, GUARDIAN);
        require(address(vault) == predictedVault, "vault address prediction");
        _assertAmpsSortsFirst();

        bytes memory args = abi.encode(poolManager, Currency.wrap(address(amps)), address(vault));
        (address mined, bytes32 hookSalt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(PlacementHookStub).creationCode, args);
        hook = new PlacementHookStub{salt: hookSalt}(poolManager, Currency.wrap(address(amps)), address(vault));
        require(address(hook) == mined, "hook address mismatch");

        vm.label(address(amps), "AMPS");
        vm.label(address(vault), "AmpsVault");
        vm.label(address(hook), "PlacementHookStub");
    }

    function _deployPeriphery() private {
        registry =
            new PoolRegistry(address(vault), address(hook), TIMELOCK, address(amps), address(weth), address(usdg));
        feeds = new FeedRegistry(TIMELOCK, address(0));
        gate = new OracleGate(TIMELOCK, GUARDIAN, address(feeds), address(registry), address(hook));
        staking = new AmpsStaking(IERC20(address(amps)), address(vault), TIMELOCK);
        pot = new BountyPot(address(usdg), address(vault), TIMELOCK);
        valuer =
            new LadderPositionValuer(IExtsload(address(poolManager)), address(vault), IPoolRegistry(address(registry)));
        bondsRole = new MockVaultRole(address(vault));
        ladderPolicy = new PlacementLadderPolicyStub();
        rolloutPolicy = new PlacementRolloutPolicyStub();

        vm.label(address(registry), "PoolRegistry");
        vm.label(address(staking), "AmpsStaking");
        vm.label(address(pot), "BountyPot");
        vm.label(address(gate), "OracleGate");
        vm.label(address(valuer), "LadderPositionValuer");
    }

    function _configureOracles() private {
        vm.startPrank(TIMELOCK);
        feeds.setOracleGate(address(gate));
        gate.setDstTable(_dstStarts(), _dstEnds());
        gate.setHolidayBitmap(2026, _bitmap2026());
        vm.stopPrank();

        _installFeed(address(weth), address(wethFeed), 3600);
        _installFeed(address(usdg), address(usdgFeed), Constants.ONE_DAY);
        for (uint256 i; i < SPOKES; ++i) {
            _installFeed(address(stocks[i]), address(stockFeeds[i]), Constants.ONE_DAY);
        }
    }

    function _wireVault() private {
        vm.startPrank(TIMELOCK);
        vault.setPolicyPointer(bytes32("registry"), address(registry));
        vault.setPolicyPointer(bytes32("bonds"), address(bondsRole));
        vault.setPolicyPointer(bytes32("staking"), address(staking));
        vault.setPolicyPointer(bytes32("bountyPot"), address(pot));
        vault.setPolicyPointer(bytes32("marketReference"), address(hook));
        vault.setPolicyPointer(bytes32("feedRegistry"), address(feeds));
        vault.setPolicyPointer(bytes32("positionValuer"), address(valuer));
        vault.setPolicyPointer(bytes32("ladderPolicy"), address(ladderPolicy));
        vault.setPolicyPointer(bytes32("rolloutPolicy"), address(rolloutPolicy));
        vm.stopPrank();
    }

    function _registerPools() private {
        vm.startPrank(TIMELOCK);
        registry.registerEntryPool(_key(address(usdg)), 6, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, address(usdgFeed));
        registry.registerEntryPool(_key(address(weth)), 18, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, address(wethFeed));
        hubPool = _key(address(usdg)).toId();
        wethPool = _key(address(weth)).toId();

        for (uint256 i; i < SPOKES; ++i) {
            (uint16 id, PoolId poolId) = registry.addConstituent(_addParams(i));
            constituentIds[i] = id;
            spokePools[i] = poolId;
        }
        registry.setIndexWeights(_ids(), _weights());
        vm.stopPrank();
    }

    function _seedRings(uint256 ampsUsd18) private {
        _observe(hubPool, ampsUsd18, USDG_USD8, 6);
        _observe(wethPool, ampsUsd18, WETH_USD8, 18);
        for (uint256 i; i < SPOKES; ++i) {
            _observe(spokePools[i], ampsUsd18, STOCK_USD8[i], 18);
        }
    }

    function _pointAtGate() private {
        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("oracleGate"), address(gate));
    }

    function _runGenesis() private {
        weth.mint(TIMELOCK, SEED_WETH);
        usdg.mint(TIMELOCK, SEED_USDG);

        address[] memory seedTokens = new address[](2);
        uint256[] memory seedAmounts = new uint256[](2);
        seedTokens[0] = address(weth);
        seedAmounts[0] = SEED_WETH;
        seedTokens[1] = address(usdg);
        seedAmounts[1] = SEED_USDG;

        vm.startPrank(TIMELOCK);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.genesis(
            IAmpsVault.GenesisParams({
                teamVestingWallet: TEAM,
                creator: CREATOR,
                teamShares: Constants.TEAM_SHARES,
                polShares: Constants.POL_SHARES,
                seedTokens: seedTokens,
                seedAmounts: seedAmounts
            })
        );
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers — time, oracles and rings
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Warps `dt` seconds forward and produces a block per second with it, so the layer-A watchdog sees a
    ///         chain that kept running rather than a stalled sequencer.
    function warpBy(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + dt + 1);
        refreshFeeds();
    }

    /// @notice Republishes every aggregator at its current answer, stamping `updatedAt` with the current block.
    function refreshFeeds() internal {
        wethFeed.setAnswer(int256(uint256(WETH_USD8)));
        usdgFeed.setAnswer(int256(uint256(USDG_USD8)));
        for (uint256 i; i < SPOKES; ++i) {
            stockFeeds[i].setAnswer(int256(uint256(STOCK_USD8[i])));
        }
    }

    /// @notice Re-seeds every ring at one AMPS price. Both entry legs move together, so the vault's layer-F
    ///         cross-check stays satisfied.
    function seedAllRings(uint256 ampsUsd18) internal {
        _observe(hubPool, ampsUsd18, USDG_USD8, 6);
        _observe(wethPool, ampsUsd18, WETH_USD8, 18);
        for (uint256 i; i < SPOKES; ++i) {
            _observe(spokePools[i], ampsUsd18, STOCK_USD8[i], 18);
        }
    }

    /// @notice Brings the market reference back in step with the pools a test has just moved: every ring is
    ///         re-seeded at the hub's live price, the feeds are republished, and the vault takes a fresh
    ///         checkpoint so `P_mkt` — which is what the placement gauntlet measures divergence against — is the
    ///         price the hub is actually trading at.
    /// @dev This is what an arbitraged market and a live truncated TWAP do between blocks. Without it a test that
    ///      moves a pool by more than `PLACEMENT_DIVERGENCE_TICKS` and then compounds is asserting that the
    ///      divergence check works, which is `unit/VaultPlacement.t.sol`'s job, not this one's.
    function syncMarket() internal {
        seedAllRings(hubPriceUsd18());
        refreshFeeds();
        vault.checkpoint();
    }

    /// @notice The AMPS price the hub is actually trading at right now, 18 decimals. Re-seeding every ring at
    ///         this keeps `P_mkt` in step with the pool a test has just moved, which is what an arbitraged market
    ///         and a live truncated TWAP would do between blocks.
    function hubPriceUsd18() internal view returns (uint256 priceUsd18) {
        return PriceLib.sqrtPriceX96ToAmpsPriceUsd18(PriceLib.tickToSqrtPriceX96(tickOf(hubPool)), USDG_USD8, 6);
    }

    function _observe(PoolId poolId, uint256 ampsUsd18, uint256 counterUsd8, uint8 counterDecimals) private {
        int24 tick =
            PriceLib.sqrtPriceX96ToTick(PriceLib.ampsPerCounterToSqrtPriceX96(ampsUsd18, counterUsd8, counterDecimals));
        hook.setObservation(poolId, tick, tick, Constants.TWAP_WINDOW_DEFAULT);
    }

    function _installFeed(address token, address aggregator, uint32 heartbeat) private {
        vm.startPrank(TIMELOCK);
        feeds.setStandardProxy(aggregator, true);
        feeds.setFeed(
            token,
            aggregator,
            FeedConfig({
                aggregator: address(0),
                decimals: 0,
                set: false,
                heartbeat: heartbeat,
                thresholdBps: 50,
                minAnswerUsd8: 1,
                maxAnswerUsd8: type(uint128).max
            })
        );
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers — reading the ladder and the pools
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The vault's placement records for `poolId`, rebuilt from the flattened public getter.
    function ladderOf(PoolId poolId) internal view returns (PlacementRecord[] memory records) {
        uint256 n = vault.ladderLength(poolId);
        records = new PlacementRecord[](n);
        for (uint256 i; i < n; ++i) {
            (
                int24 lowerTick,
                int24 upperTick,
                uint128 liquidity,
                uint8 bucketIndex,
                uint8 buckets,
                bool above,
                uint32 placedAt,
                uint128 amount,
                uint64 tiltX18,
                int24 anchorTick
            ) = vault.ladderAt(poolId, i);
            records[i] = PlacementRecord({
                lowerTick: lowerTick,
                upperTick: upperTick,
                liquidity: liquidity,
                bucketIndex: bucketIndex,
                buckets: buckets,
                above: above,
                placedAt: placedAt,
                amount: amount,
                tiltX18: tiltX18,
                anchorTick: anchorTick
            });
        }
    }

    /// @notice The pool's live tick.
    function tickOf(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(poolManager)).getSlot0(poolId);
    }

    /// @notice The pool's grid origin, as the registry mirrors it from the hook.
    function gridBaseOf(PoolId poolId) internal view returns (int24 tick) {
        return registry.poolConfig(poolId).gridBaseTick;
    }

    /// @notice One doubling in ticks for the fixture's spacing.
    function cellWidth() internal pure returns (int24 width) {
        return LadderLib.doublingTicks(TICK_SPACING);
    }

    /// @notice The AMPS a record's position holds at the record's own range, i.e. its unfilled ask inventory.
    function askAmpsIn(PlacementRecord memory record) internal pure returns (uint256 amount) {
        return LadderLib.amount0ForLiquidity(
            PriceLib.tickToSqrtPriceX96(record.lowerTick),
            PriceLib.tickToSqrtPriceX96(record.upperTick),
            record.liquidity
        );
    }

    /// @notice The live ladder cells the fixture's four pools actually hold, recomputed from the vault's own
    ///         records — the independent number `IAmpsVault.liveCells()` is checked against.
    function countLiveCells() internal view returns (uint32 count) {
        PoolId[2] memory entries = [hubPool, wethPool];
        for (uint256 p; p < entries.length; ++p) {
            count += _liveIn(entries[p]);
        }
        for (uint256 i; i < SPOKES; ++i) {
            count += _liveIn(spokePools[i]);
        }
    }

    /// @dev The live cells of one pool.
    function _liveIn(PoolId poolId) private view returns (uint32 count) {
        uint256 n = vault.ladderLength(poolId);
        for (uint256 i; i < n; ++i) {
            (,, uint128 liquidity,,,,,,,) = vault.ladderAt(poolId, i);
            if (liquidity != 0) ++count;
        }
    }

    /// @notice TEST ONLY. Forces the vault's live-cell counter.
    /// @dev `Constants.MAX_LIVE_CELLS` is 512 and this fixture's four pools can hold at most 96 cells between
    ///      them, so the only way to exercise the budget's edge is to write the counter. The slot is
    ///      `VaultRedeemLib.LIVE_CELLS_SLOT`, and the vault has no setter for it — which is the point.
    function forceLiveCells(uint32 value) internal {
        vm.store(address(vault), bytes32(uint256(keccak256("amplestocks.vault.liveCells"))), bytes32(uint256(value)));
        assertEq(vault.liveCells(), value, "the counter was forced");
    }

    /// @notice The vault's ERC-6909 claim balance for `token`.
    function claimOf(address token) internal view returns (uint256) {
        return IPoolManager(address(poolManager)).balanceOf(address(vault), Currency.wrap(token).toId());
    }

    /// @notice The vault's whole holding of `token`: claims plus any idle ERC-20 balance.
    function heldBalance(address token) internal view returns (uint256) {
        return claimOf(token) + IERC20(token).balanceOf(address(vault));
    }

    /// @notice Moves `amount` of the vault's POL inventory to `to`, so a test has a redeemer without minting.
    function giveShares(address to, uint256 amount) internal {
        vm.prank(address(vault));
        amps.transfer(to, amount);
    }

    /// @notice Buys AMPS out of `poolId`'s ask ladder with `amountIn` of the counter asset, which is what walks
    ///         the price up and fills buckets bottom-up.
    function buyAmps(PoolId poolId, address counter, uint256 amountIn) internal {
        MockERC20(counter).mint(BOB, amountIn);
        vm.startPrank(BOB);
        MockERC20(counter).approve(address(swapRouter), type(uint256).max);
        MockERC20(counter).approve(address(permit2), type(uint256).max);
        permit2.approve(counter, address(swapRouter), type(uint160).max, type(uint48).max);
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: registry.poolKey(poolId),
            hookData: "",
            receiver: BOB,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
    }

    /// @notice Sells `amountIn` AMPS into `poolId`, which walks the price back down through the proceeds bids.
    function sellAmps(PoolId poolId, uint256 amountIn) internal {
        vm.startPrank(BOB);
        amps.approve(address(swapRouter), type(uint256).max);
        amps.approve(address(permit2), type(uint256).max);
        permit2.approve(address(amps), address(swapRouter), type(uint160).max, type(uint48).max);
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: registry.poolKey(poolId),
            hookData: "",
            receiver: BOB,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
    }

    /// @notice Funds the bounty pot so the keeper paths can actually pay.
    function fundPot(uint256 amountRaw) internal {
        usdg.mint(address(this), amountRaw);
        usdg.approve(address(pot), type(uint256).max);
        pot.fund(amountRaw);
    }

    /// @notice Settles `amount` of `token` into the vault's ERC-6909 claims through the bonds entry point, which
    ///         is how bonded collateral arrives before `deployBonded` places it.
    function bondDeposit(address token, uint256 amount) internal returns (uint256 settled) {
        MockStockToken(token).mint(address(this), amount);
        MockStockToken(token).approve(address(vault), type(uint256).max);
        vm.prank(address(bondsRole));
        settled = vault.depositBonded(1, token, address(this), amount);
    }

    /// @notice I12 at the fixture level.
    function assertSweepClean(string memory context) internal view {
        uint256 count = vault.assetCount();
        for (uint256 i; i < count; ++i) {
            address token = vault.assetAt(i);
            assertEq(IERC20(token).balanceOf(address(vault)), 0, string.concat("vault idle balance: ", context));
            assertEq(IERC20(token).balanceOf(address(hook)), 0, string.concat("hook idle balance: ", context));
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers — keys, parameters, calendar tables
    // -------------------------------------------------------------------------------------------------------------

    function _key(address counter) internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(amps)),
            currency1: Currency.wrap(counter),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _addParams(uint256 i) internal view returns (IPoolRegistry.AddConstituentParams memory params) {
        params = IPoolRegistry.AddConstituentParams({
            token: address(stocks[i]),
            feed: address(stockFeeds[i]),
            poolClass: PoolClass.SPOKE,
            tickSpacing: TICK_SPACING,
            buyFeeBps: Constants.BUY_FEE_BPS_SPOKE_DEFAULT,
            targetWeightBps: TARGET_WEIGHT_BPS,
            rolloutWeightBps: ROLLOUT_WEIGHT_BPS,
            hSessionOverrideBps: 0,
            hSessionOverrideSet: false,
            inclusion: InclusionRecord({
                betaX18: 0.9e18, trackingErrorX18: 0.03e18, indexVolX18: 0.2e18, historyDays: 400, recordedAt: 0
            }),
            openBondMarket: false
        });
    }

    function _ids() private view returns (uint16[] memory ids) {
        ids = new uint16[](SPOKES);
        for (uint256 i; i < SPOKES; ++i) {
            ids[i] = constituentIds[i];
        }
    }

    function _weights() private pure returns (uint16[] memory weightsBps) {
        weightsBps = new uint16[](SPOKES);
        for (uint256 i; i < SPOKES; ++i) {
            weightsBps[i] = TARGET_WEIGHT_BPS;
        }
    }

    function _dstStarts() private pure returns (uint32[] memory starts) {
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

    function _dstEnds() private pure returns (uint32[] memory ends) {
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

    function _bitmap2026() private pure returns (uint256[2] memory bitmap) {
        uint16[10] memory daysOfYear = [1, 19, 47, 93, 145, 170, 184, 250, 330, 359];
        for (uint256 i; i < daysOfYear.length; ++i) {
            uint256 index = uint256(daysOfYear[i]) - 1;
            bitmap[index >> 8] |= uint256(1) << (index & 255);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers — AMPS address mining
    // -------------------------------------------------------------------------------------------------------------

    function _mineAmpsSalt(address predictedVault) private view returns (bytes32 salt) {
        bytes32 initHash = keccak256(abi.encodePacked(type(Amps).creationCode, abi.encode(predictedVault)));
        uint160 ceiling = _lowestCounter();
        for (uint256 i; i < 1 << 22; ++i) {
            salt = bytes32(i);
            uint160 candidate =
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))));
            if (candidate < ceiling && candidate > 0xffff) return salt;
        }
        revert("no AMPS salt below every counter");
    }

    function _lowestCounter() private view returns (uint160 lowest) {
        lowest = type(uint160).max;
        if (uint160(address(weth)) < lowest) lowest = uint160(address(weth));
        if (uint160(address(usdg)) < lowest) lowest = uint160(address(usdg));
        for (uint256 i; i < SPOKES; ++i) {
            if (uint160(address(stocks[i])) < lowest) lowest = uint160(address(stocks[i]));
        }
    }

    function _assertAmpsSortsFirst() private view {
        require(uint160(address(amps)) < uint160(address(weth)), "AMPS < WETH");
        require(uint160(address(amps)) < uint160(address(usdg)), "AMPS < USDG");
        for (uint256 i; i < SPOKES; ++i) {
            require(uint160(address(amps)) < uint160(address(stocks[i])), "AMPS < stock");
        }
    }
}
