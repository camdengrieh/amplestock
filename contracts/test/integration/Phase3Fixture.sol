// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsBonds} from "../../src/bonds/AmpsBonds.sol";
import {AmpsHook} from "../../src/hook/AmpsHook.sol";
import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IPoolRegistry} from "../../src/interfaces/IPoolRegistry.sol";
import {BountyPot} from "../../src/keeper/BountyPot.sol";
import {LadderLib} from "../../src/lib/LadderLib.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {FeedRegistry} from "../../src/oracle/FeedRegistry.sol";
import {OracleGate} from "../../src/oracle/OracleGate.sol";
import {AmpsQuoter} from "../../src/periphery/AmpsQuoter.sol";
import {BondPolicy} from "../../src/policy/BondPolicy.sol";
import {FeePolicy} from "../../src/policy/FeePolicy.sol";
import {LadderPolicy} from "../../src/policy/LadderPolicy.sol";
import {RolloutPolicy} from "../../src/policy/RolloutPolicy.sol";
import {PoolRegistry} from "../../src/registry/PoolRegistry.sol";
import {AmpsStaking} from "../../src/staking/AmpsStaking.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {FeedConfig, InclusionRecord, PlacementRecord, PoolClass} from "../../src/types/Types.sol";
import {LadderPositionValuer} from "../../src/valuer/LadderPositionValuer.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockUsdg} from "../mocks/MockUsdg.sol";
import {V4TestBase} from "../utils/V4TestBase.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Vm} from "forge-std/Vm.sol";
import {PathKey} from "hookmate/interfaces/router/PathKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title Phase3Fixture
/// @notice The whole Phase 3 system, real contract by real contract, on live Uniswap v4 pools: `Amps` at a mined
///         CREATE2 salt, `AmpsVault` behind its four linked libraries, the **real** `AmpsHook` at a `0x38C0`-shaped
///         address, the real `FeePolicy` / `LadderPolicy` / `RolloutPolicy` / `BondPolicy`,
///         `LadderPositionValuer`, `PoolRegistry`, `AmpsBonds`, `AmpsStaking`, `BountyPot`, `OracleGate` +
///         `FeedRegistry` and `AmpsQuoter`.
///
///         Nothing here is a stub except the assets themselves: `MockStockToken` for the Robinhood Stock Tokens,
///         `MockUsdg`, a solmate `MockERC20` as the WETH stand-in and `MockAggregator` for Chainlink. Every fee,
///         every tick, every observation and every ladder cell is produced by production code.
///
/// @dev **Pool shape.** {spokeCount} is `virtual`: the default is `docs/phase3-state-model.md` §8.2's four-pool
///      shape (hub `AMPS/USDG`, `AMPS/WETH`, one `SPOKE`, one `SPOKE_HIGH_VOL`); a suite that wants the launch
///      shape overrides it and gets 32 pools.
///
/// @dev **Bootstrap ordering** (`docs/phase2-state-model.md` §9.1, and the reason `Phase2Fixture` and
///      `PlacementFixture` both record it): `AmpsVault.initializePool` is gated and `OracleGate` reports
///      `WATCHDOG` until the hub pool carries `twapWindow` of observation coverage, so registering the first pool
///      through a wired gate is circular. Everything except the gate pointer is wired, the pools are registered,
///      the rings are *covered by real elapsed time* — with the production hook the ring is real, so coverage is
///      bought with a warp rather than written by a mock — and only then does the vault get the gate, after which
///      `genesis()` and every placement run fully gated.
///
/// @dev **Transient storage.** Foundry >= 1.8 clears transient storage between top-level calls made by a test, so
///      every scenario that seeds and then spends the hook's rotation credit runs inside one self-call
///      (`this.someEntry()`), exactly as `test/gas/GasBaseline.t.sol` does.
abstract contract Phase3Fixture is V4TestBase {
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
    address internal constant CAROL = address(0xCA401);
    address internal constant KEEPER = address(0x6EE9E4);
    address internal constant STAKER = address(0x57A4E4);

    /// @dev 2026-09-09 14:00:00 UTC — a Wednesday, 10:00 ET, squarely inside `REGULAR`.
    uint256 internal constant GENESIS_TIME = 1_788_962_400;
    uint256 internal constant GENESIS_BLOCK = 20_000_000;

    uint128 internal constant WETH_USD8 = 2500e8;
    uint128 internal constant USDG_USD8 = 1e8;
    uint256 internal constant SEED_WETH = 1e18;
    uint256 internal constant SEED_USDG = 2500e6;

    int24 internal constant TICK_SPACING = 60;
    uint16 internal constant TARGET_WEIGHT_BPS = 1000;
    uint16 internal constant ROLLOUT_WEIGHT_BPS = 1000;

    /// @dev §3.3's confirmed genesis ladders: 1,662.5 AMPS of asks in each entry pool, and each spoke's seed ask
    ///      at 1% of the 4,750 AMPS POL tranche.
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
    AmpsHook internal hook;
    PoolRegistry internal registry;
    AmpsBonds internal bonds;
    BondPolicy internal bondPolicy;
    AmpsStaking internal staking;
    BountyPot internal pot;
    OracleGate internal gate;
    FeedRegistry internal feeds;
    LadderPositionValuer internal valuer;
    FeePolicy internal feePolicy;
    LadderPolicy internal ladderPolicy;
    RolloutPolicy internal rolloutPolicy;
    AmpsQuoter internal quoter;
    VestingWallet internal teamVesting;

    MockERC20 internal weth;
    MockUsdg internal usdg;
    MockAggregator internal wethFeed;
    MockAggregator internal usdgFeed;

    MockStockToken[] internal stocks;
    MockAggregator[] internal stockFeeds;
    uint16[] internal constituentIds;
    uint16[] internal marketIds;
    PoolId[] internal spokePools;
    uint128[] internal stockUsd8;

    PoolId internal hubPool;
    PoolId internal wethPool;

    // -------------------------------------------------------------------------------------------------------------
    // Shape
    // -------------------------------------------------------------------------------------------------------------

    /// @notice How many spokes this fixture opens. §8.2's shape by default: one `SPOKE` and one `SPOKE_HIGH_VOL`.
    /// @return count The spoke count.
    function spokeCount() internal view virtual returns (uint256 count) {
        return 2;
    }

    /// @notice Spoke `i`'s launch price, 8 decimals. $180 and $50 for §8.2's pair, then a spread of realistic
    ///         large-cap prices for the 32-pool launch shape.
    /// @param i The spoke index.
    /// @return priceUsd8 The price.
    function stockPriceUsd8(uint256 i) internal pure virtual returns (uint128 priceUsd8) {
        uint128[10] memory ladder = [uint128(180e8), 50e8, 250e8, 650e8, 400e8, 120e8, 95e8, 310e8, 75e8, 540e8];
        return ladder[i % 10];
    }

    /// @notice Spoke `i`'s class. Index 1 is the high-σ name so §8.2's shape carries one of each.
    /// @param i The spoke index.
    /// @return class The class.
    function stockClass(uint256 i) internal pure virtual returns (PoolClass class) {
        return i % 2 == 1 ? PoolClass.SPOKE_HIGH_VOL : PoolClass.SPOKE;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Deployment
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Deploys and wires the whole Phase 3 world, registers every pool, covers the observation rings,
    ///         points the vault at the gate and runs `genesis()`.
    function deployPhase3World() internal {
        vm.warp(GENESIS_TIME);
        vm.roll(GENESIS_BLOCK);

        deployV4();
        _deployAssets();
        _deployCore();
        _deployPeriphery();
        _configureOracles();
        _wireVault();
        _registerPools();
        _coverRings();
        _pointAtGate();
        _runGenesis();
    }

    /// @notice The §3.3 genesis ladders: the ask ladder in every pool, then — after the 60-second per-pool
    ///         cooldown — the seed bids in the two entry pools.
    function placeGenesisLadders() internal {
        vm.startPrank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        vault.place(wethPool, true, ENTRY_ASK_AMPS);
        for (uint256 i; i < spokePools.length; ++i) {
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

        uint256 n = spokeCount();
        for (uint256 i; i < n; ++i) {
            string memory symbol = string.concat("STK", vm.toString(i));
            MockStockToken token = new MockStockToken(symbol, symbol);
            uint128 priceUsd8 = stockPriceUsd8(i);
            stocks.push(token);
            stockUsd8.push(priceUsd8);
            stockFeeds.push(new MockAggregator(string.concat(symbol, " / USD"), 8, int256(uint256(priceUsd8))));
            vm.label(address(token), symbol);
        }
        vm.label(address(weth), "WETH");
        vm.label(address(usdg), "USDG");
    }

    /// @dev `Amps` (CREATE2, mined below every counter), `AmpsVault` (CREATE, predicted), the real `AmpsHook`
    ///      (CREATE2, flag-mined) and `PoolRegistry` (CREATE, predicted).
    ///
    /// @dev The hook takes the registry in its constructor and the registry takes the hook, so one of the two has
    ///      to be predicted. The hook is the mined one, so the registry is what gets predicted: CREATE2 still
    ///      bumps the creator's nonce, which is what makes `nonce + 1` the registry's slot.
    function _deployCore() private {
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        amps = new Amps{salt: _mineAmpsSalt(predictedVault)}(predictedVault);
        vault = new AmpsVault(address(amps), address(poolManager), TIMELOCK, GUARDIAN);
        require(address(vault) == predictedVault, "vault address prediction");
        _assertAmpsSortsFirst();

        address predictedRegistry = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        bytes memory args = abi.encode(poolManager, address(amps), address(vault), predictedRegistry, TIMELOCK);
        (address mined, bytes32 hookSalt) = HookMiner.find(address(this), HOOK_FLAGS, type(AmpsHook).creationCode, args);
        hook = new AmpsHook{salt: hookSalt}(poolManager, address(amps), address(vault), predictedRegistry, TIMELOCK);
        require(address(hook) == mined, "hook address mismatch");

        registry =
            new PoolRegistry(address(vault), address(hook), TIMELOCK, address(amps), address(weth), address(usdg));
        require(address(registry) == predictedRegistry, "registry address prediction");

        vm.label(address(amps), "AMPS");
        vm.label(address(vault), "AmpsVault");
        vm.label(address(hook), "AmpsHook");
        vm.label(address(registry), "PoolRegistry");
    }

    function _deployPeriphery() private {
        feeds = new FeedRegistry(TIMELOCK, address(0));
        gate = new OracleGate(TIMELOCK, GUARDIAN, address(feeds), address(registry), address(hook));
        bondPolicy = new BondPolicy();
        bonds = new AmpsBonds(address(vault), address(registry), address(bondPolicy));
        staking = new AmpsStaking(IERC20(address(amps)), address(vault), TIMELOCK);
        pot = new BountyPot(address(usdg), address(vault), TIMELOCK);
        valuer =
            new LadderPositionValuer(IExtsload(address(poolManager)), address(vault), IPoolRegistry(address(registry)));
        feePolicy = new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18);
        ladderPolicy = new LadderPolicy();
        rolloutPolicy = new RolloutPolicy();
        quoter = new AmpsQuoter(
            address(poolManager),
            address(hook),
            address(vault),
            address(registry),
            address(bonds),
            address(gate),
            address(feeds)
        );
        teamVesting = new VestingWallet(TEAM, uint64(GENESIS_TIME), Constants.TEAM_VEST_SECONDS);

        vm.prank(TIMELOCK);
        hook.setFeePolicy(address(feePolicy));

        vm.label(address(gate), "OracleGate");
        vm.label(address(feeds), "FeedRegistry");
        vm.label(address(bonds), "AmpsBonds");
        vm.label(address(staking), "AmpsStaking");
        vm.label(address(pot), "BountyPot");
        vm.label(address(valuer), "LadderPositionValuer");
        vm.label(address(quoter), "AmpsQuoter");
    }

    function _configureOracles() private {
        vm.startPrank(TIMELOCK);
        feeds.setOracleGate(address(gate));
        gate.setDstTable(_dstStarts(), _dstEnds());
        gate.setHolidayBitmap(2026, _bitmap2026());
        vm.stopPrank();

        _installFeed(address(weth), address(wethFeed), 3600);
        _installFeed(address(usdg), address(usdgFeed), Constants.ONE_DAY);
        for (uint256 i; i < stocks.length; ++i) {
            _installFeed(address(stocks[i]), address(stockFeeds[i]), Constants.ONE_DAY);
        }
    }

    /// @dev Every pointer except `oracleGate`, which is wired after the pools exist and the rings are covered.
    function _wireVault() private {
        vm.startPrank(TIMELOCK);
        vault.setPolicyPointer(bytes32("registry"), address(registry));
        vault.setPolicyPointer(bytes32("bonds"), address(bonds));
        vault.setPolicyPointer(bytes32("staking"), address(staking));
        vault.setPolicyPointer(bytes32("bountyPot"), address(pot));
        vault.setPolicyPointer(bytes32("marketReference"), address(hook));
        vault.setPolicyPointer(bytes32("feedRegistry"), address(feeds));
        vault.setPolicyPointer(bytes32("positionValuer"), address(valuer));
        vault.setPolicyPointer(bytes32("ladderPolicy"), address(ladderPolicy));
        vault.setPolicyPointer(bytes32("rolloutPolicy"), address(rolloutPolicy));
        vault.setStandbyVault(STANDBY);
        vm.stopPrank();
    }

    function _registerPools() private {
        vm.startPrank(TIMELOCK);
        registry.registerEntryPool(_key(address(usdg)), 6, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, address(usdgFeed));
        registry.registerEntryPool(_key(address(weth)), 18, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, address(wethFeed));
        hubPool = _key(address(usdg)).toId();
        wethPool = _key(address(weth)).toId();

        for (uint256 i; i < stocks.length; ++i) {
            (uint16 id, PoolId poolId) = registry.addConstituent(_addParams(i));
            constituentIds.push(id);
            spokePools.push(poolId);
            marketIds.push(registry.constituent(id).marketId);
        }
        registry.setIndexWeights(_ids(), _weights());
        vm.stopPrank();
    }

    /// @dev With the production hook the observation ring is real: `afterInitialize` seeds it and coverage is
    ///      bought with elapsed time, not written by a mock. One warp past `TWAP_WINDOW` therefore takes every
    ///      pool from "no coverage" to "fully covered at the opening tick", which is what the gate's reference
    ///      integrity layer and the vault's `P_mkt` both need before the gate can be pointed at.
    function _coverRings() private {
        warpBy(Constants.TWAP_WINDOW_DEFAULT + Constants.PLACEMENT_COOLDOWN_SECONDS);
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
                teamVestingWallet: address(teamVesting),
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
    // Helpers — time and oracles
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Warps `dt` seconds forward and produces a block per second with it, so the layer-A watchdog sees a
    ///         chain that kept running rather than a stalled sequencer, then republishes every feed.
    /// @param dt Seconds to warp.
    function warpBy(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + dt + 1);
        refreshFeeds();
    }

    /// @notice Advances the clock by `dt` seconds and one block, then republishes the feeds.
    /// @dev **`block.timestamp` and `block.number` are read through cheatcodes, deliberately.** solc treats
    ///      `TIMESTAMP` and `NUMBER` as loop-invariant and hoists them out of a loop, so
    ///      `vm.roll(block.number + 1)` inside a warping loop rolls exactly once and every later iteration lands
    ///      back on the same block — which silently freezes the observation ring's per-block truncation anchor and
    ///      makes the TWAP stop following the pool. `vm.getBlockNumber()` and `vm.getBlockTimestamp()` are
    ///      external calls the optimizer cannot hoist, so the advance is real on every iteration.
    /// @param dt Seconds to advance.
    function advance(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + 1);
        refreshFeeds();
    }

    /// @notice Repoints spoke `i`'s Chainlink answer, permanently: {refreshFeeds} republishes this value from now
    ///         on, so a scenario can move a stock and have it stay moved.
    /// @param i The spoke index.
    /// @param priceUsd8 The new price, 8 decimals.
    function setStockPrice(uint256 i, uint128 priceUsd8) internal {
        stockUsd8[i] = priceUsd8;
        stockFeeds[i].setAnswer(int256(uint256(priceUsd8)));
    }

    /// @notice Republishes every aggregator at its current answer, stamping `updatedAt` with the current block.
    function refreshFeeds() internal {
        wethFeed.setAnswer(int256(uint256(WETH_USD8)));
        usdgFeed.setAnswer(int256(uint256(USDG_USD8)));
        for (uint256 i; i < stockFeeds.length; ++i) {
            stockFeeds[i].setAnswer(int256(uint256(stockUsd8[i])));
        }
    }

    /// @notice Forces one gate-cache refresh in `poolId` without moving its price: `afterSwap` with a zero delta
    ///         at the pool's own tick, called as the PoolManager. This is what a real swap would do to the cache,
    ///         isolated from what a real swap would do to the price.
    /// @param poolId The pool.
    function refreshGateCache(PoolId poolId) internal {
        vm.warp(vm.getBlockTimestamp() + hook.gateCacheSeconds() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        refreshFeeds();
        _pokeAfterSwap(poolId, true);
    }

    /// @dev `afterSwap` at the current tick with a zero delta. Never moves the pool.
    function _pokeAfterSwap(PoolId poolId, bool zeroForOne) internal {
        SwapParams memory params = SwapParams({zeroForOne: zeroForOne, amountSpecified: -1, sqrtPriceLimitX96: 0});
        PoolKey memory key = registry.poolKey(poolId);
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), key, params, toBalanceDelta(0, 0), "");
    }

    /// @notice TEST ONLY. Places a pool at an arbitrary tick by writing the PoolManager's `slot0` and then letting
    ///         `afterSwap` record it, so the hook's deviation is measured against a price the market could not have
    ///         reached in one move. The outer rail exists precisely to stop that, which is why measuring the fee
    ///         law across the whole band-to-rail range needs a cheatcode rather than a swap.
    /// @dev The poke is made in the *price-improving* direction so that `afterSwap`'s own rail check — the one
    ///      deliberate revert of §10 ruling 2 — cannot refuse it.
    /// @param poolId The pool.
    /// @param target The tick to place it at.
    function forceTick(PoolId poolId, int24 target) internal {
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(uint256(6))));
        uint256 word = uint256(vm.load(address(poolManager), slot));
        uint256 fees = word >> 184;
        uint256 packed = uint256(PriceLib.tickToSqrtPriceX96(target)) | (uint256(uint24(target)) << 160) | (fees << 184);
        vm.store(address(poolManager), slot, bytes32(packed));
        assertEq(tickOf(poolId), target, "the pool was moved to the requested tick");
        _pokeAfterSwap(poolId, target > hook.fairTick(poolId));
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers — reading the ladder and the pools
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The vault's placement records for `poolId`, rebuilt from the flattened public getter.
    /// @param poolId The pool.
    /// @return records The records.
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
    /// @param poolId The pool.
    /// @return tick The tick.
    function tickOf(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(poolManager)).getSlot0(poolId);
    }

    /// @notice The pool's live sqrt price.
    /// @param poolId The pool.
    /// @return sqrtPriceX96 The price.
    function sqrtPriceOf(PoolId poolId) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(poolId);
    }

    /// @notice The pool's grid origin, as the registry mirrors it from the hook.
    /// @param poolId The pool.
    /// @return tick The origin.
    function gridBaseOf(PoolId poolId) internal view returns (int24 tick) {
        return registry.poolConfig(poolId).gridBaseTick;
    }

    /// @notice One doubling in ticks for the fixture's spacing.
    /// @return width The cell width.
    function cellWidth() internal pure returns (int24 width) {
        return LadderLib.doublingTicks(TICK_SPACING);
    }

    /// @notice The AMPS a record's position holds at the record's own range, i.e. its unfilled ask inventory.
    /// @param record The record.
    /// @return amount The AMPS.
    function askAmpsIn(PlacementRecord memory record) internal pure returns (uint256 amount) {
        return LadderLib.amount0ForLiquidity(
            PriceLib.tickToSqrtPriceX96(record.lowerTick),
            PriceLib.tickToSqrtPriceX96(record.upperTick),
            record.liquidity
        );
    }

    /// @notice The counter asset a record's position holds at the record's own range, i.e. its bid depth.
    /// @param record The record.
    /// @return amount The counter asset.
    function bidCounterIn(PlacementRecord memory record) internal pure returns (uint256 amount) {
        return LadderLib.amount1ForLiquidity(
            PriceLib.tickToSqrtPriceX96(record.lowerTick),
            PriceLib.tickToSqrtPriceX96(record.upperTick),
            record.liquidity
        );
    }

    /// @notice Every pool the vault has opened, hub first.
    /// @return ids The pool ids.
    function allPools() internal view returns (PoolId[] memory ids) {
        ids = new PoolId[](2 + spokePools.length);
        ids[0] = hubPool;
        ids[1] = wethPool;
        for (uint256 i; i < spokePools.length; ++i) {
            ids[2 + i] = spokePools[i];
        }
    }

    /// @notice The live ladder cells the fixture's pools actually hold, recomputed from the vault's own records —
    ///         the independent number `IAmpsVault.liveCells()` is checked against.
    /// @return count The count.
    function countLiveCells() internal view returns (uint32 count) {
        PoolId[] memory ids = allPools();
        for (uint256 p; p < ids.length; ++p) {
            uint256 n = vault.ladderLength(ids[p]);
            for (uint256 i; i < n; ++i) {
                (,, uint128 liquidity,,,,,,,) = vault.ladderAt(ids[p], i);
                if (liquidity != 0) ++count;
            }
        }
    }

    /// @notice The vault's ERC-6909 claim balance for `token`.
    /// @param token The token.
    /// @return balance The claim balance.
    function claimOf(address token) internal view returns (uint256 balance) {
        return IPoolManager(address(poolManager)).balanceOf(address(vault), Currency.wrap(token).toId());
    }

    /// @notice The vault's whole holding of `token`: claims plus any idle ERC-20 balance.
    /// @param token The token.
    /// @return balance The holding.
    function heldBalance(address token) internal view returns (uint256 balance) {
        return claimOf(token) + IERC20(token).balanceOf(address(vault));
    }

    /// @notice I12 at the fixture level: nothing rests on an idle ERC-20 balance.
    /// @param context A label for the failure message.
    function assertSweepClean(string memory context) internal view {
        uint256 count = vault.assetCount();
        for (uint256 i; i < count; ++i) {
            address token = vault.assetAt(i);
            assertEq(IERC20(token).balanceOf(address(vault)), 0, string.concat("vault idle balance: ", context));
            assertEq(IERC20(token).balanceOf(address(hook)), 0, string.concat("hook idle balance: ", context));
            assertEq(IERC20(token).balanceOf(address(bonds)), 0, string.concat("bonds idle balance: ", context));
        }
        assertEq(IERC20(address(amps)).balanceOf(address(hook)), 0, string.concat("hook holds no AMPS: ", context));
        assertEq(
            IPoolManager(address(poolManager)).balanceOf(address(hook), Currency.wrap(address(amps)).toId()),
            0,
            string.concat("hook holds no AMPS claim: ", context)
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers — funding, shares and bonds
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Mints `amount` of `token` to `who` and approves the whole local router stack from `who`.
    /// @param token The token.
    /// @param who The recipient.
    /// @param amount The amount.
    function fund(address token, address who, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", who, amount));
        require(ok, "mint failed");
        approveStack(token, who);
    }

    /// @notice Approves permit2 and the v4 router for `who` on `token`.
    /// @param token The token.
    /// @param who The owner.
    function approveStack(address token, address who) internal {
        vm.startPrank(who);
        MockERC20(token).approve(address(permit2), type(uint256).max);
        MockERC20(token).approve(address(swapRouter), type(uint256).max);
        MockERC20(token).approve(address(vault), type(uint256).max);
        permit2.approve(token, address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @notice Moves `amount` of the vault's POL inventory to `to`, so a test has a seller without minting.
    /// @param to The recipient.
    /// @param amount The AMPS.
    function giveShares(address to, uint256 amount) internal {
        vm.prank(address(vault));
        amps.transfer(to, amount);
        approveStack(address(amps), to);
    }

    /// @notice Funds the bounty pot so the keeper paths can actually pay.
    /// @param amountRaw USDG, 6 decimals.
    function fundPot(uint256 amountRaw) internal {
        usdg.mint(address(this), amountRaw);
        usdg.approve(address(pot), type(uint256).max);
        pot.fund(amountRaw);
    }

    /// @notice Buys a bond on spoke `i` as `who`, funding and approving the collateral first.
    /// @param who The buyer.
    /// @param i The spoke index.
    /// @param amountIn Collateral in.
    /// @return ampsOut The AMPS purchased.
    /// @return positionId The vesting position created.
    function bondAs(address who, uint256 i, uint256 amountIn) internal returns (uint256 ampsOut, uint256 positionId) {
        stocks[i].mint(who, amountIn);
        vm.startPrank(who);
        stocks[i].approve(address(vault), type(uint256).max);
        (ampsOut, positionId) = bonds.bond(marketIds[i], amountIn, 0, who);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers — swaps through the real hook
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Exact-input buy: the counter asset in, AMPS out, so `zeroForOne == false` and the buy fee applies.
    /// @param poolId The pool.
    /// @param who The swapper, funded and approved by this call.
    /// @param amountIn Counter asset in.
    /// @return ampsOut AMPS received.
    function buyAmps(PoolId poolId, address who, uint256 amountIn) internal returns (uint256 ampsOut) {
        address counter = registry.poolConfig(poolId).counter;
        fund(counter, who, amountIn);
        PoolKey memory key = registry.poolKey(poolId);
        uint256 before = amps.balanceOf(who);
        vm.prank(who);
        swapRouter.swapExactTokensForTokens(amountIn, 0, false, key, "", who, type(uint256).max);
        ampsOut = amps.balanceOf(who) - before;
    }

    /// @notice Exact-input sell: AMPS in, so `zeroForOne == true` and the sell fee applies.
    /// @param poolId The pool.
    /// @param who The seller, who must already hold the AMPS.
    /// @param amountIn AMPS in.
    /// @return counterOut Counter asset received.
    function sellAmps(PoolId poolId, address who, uint256 amountIn) internal returns (uint256 counterOut) {
        address counter = registry.poolConfig(poolId).counter;
        PoolKey memory key = registry.poolKey(poolId);
        approveStack(address(amps), who);
        uint256 before = IERC20(counter).balanceOf(who);
        vm.prank(who);
        swapRouter.swapExactTokensForTokens(amountIn, 0, true, key, "", who, type(uint256).max);
        counterOut = IERC20(counter).balanceOf(who) - before;
    }

    /// @notice Exact-**output** sell: AMPS in, an exact amount of the counter asset out. Consumes no credit.
    /// @param poolId The pool.
    /// @param who The seller.
    /// @param amountOut Counter asset out.
    /// @return ampsIn AMPS spent.
    function sellAmpsExactOut(PoolId poolId, address who, uint256 amountOut) internal returns (uint256 ampsIn) {
        PoolKey memory key = registry.poolKey(poolId);
        approveStack(address(amps), who);
        uint256 before = amps.balanceOf(who);
        vm.prank(who);
        swapRouter.swapTokensForExactTokens(amountOut, type(uint256).max, true, key, "", who, type(uint256).max);
        ampsIn = before - amps.balanceOf(who);
    }

    /// @notice The two-hop rotation `counterIn -> AMPS -> counterOut` as one exact-input router call, which is the
    ///         shape the rotation credit exists for.
    /// @param hop1 The pool bought in.
    /// @param hop2 The pool sold into.
    /// @param who The rotator, funded and approved by this call.
    /// @param amountIn Hop-1 counter asset in.
    /// @return amountOut Hop-2 counter asset out.
    function rotate(PoolId hop1, PoolId hop2, address who, uint256 amountIn) internal returns (uint256 amountOut) {
        address counterIn = registry.poolConfig(hop1).counter;
        address counterOut = registry.poolConfig(hop2).counter;
        fund(counterIn, who, amountIn);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(amps)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(counterOut),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        uint256 before = IERC20(counterOut).balanceOf(who);
        vm.prank(who);
        swapRouter.swapExactTokensForTokens(amountIn, 0, Currency.wrap(counterIn), path, who, type(uint256).max);
        amountOut = IERC20(counterOut).balanceOf(who) - before;
    }

    /// @notice {buyAmps} as an external self-call, so a scenario can wrap it in `try`/`catch` and treat a
    ///         `BeyondRail` refusal as "wait, the reference has not caught up yet" rather than as a failure.
    /// @param poolId The pool.
    /// @param who The buyer.
    /// @param amountIn Counter asset in.
    /// @return ampsOut AMPS received.
    function buyAmpsExternal(PoolId poolId, address who, uint256 amountIn) external returns (uint256 ampsOut) {
        require(msg.sender == address(this), "self-call only");
        ampsOut = buyAmps(poolId, who, amountIn);
    }

    /// @notice {sellAmps} as an external self-call. See {buyAmpsExternal}.
    /// @param poolId The pool.
    /// @param who The seller.
    /// @param amountIn AMPS in.
    /// @return counterOut Counter asset received.
    function sellAmpsExternal(PoolId poolId, address who, uint256 amountIn) external returns (uint256 counterOut) {
        require(msg.sender == address(this), "self-call only");
        counterOut = sellAmps(poolId, who, amountIn);
    }

    /// @notice Arbitrage a pool upward toward `targetTick`, the way a market really would: repeated small buys,
    ///         one per block, each of which is simply skipped when the hook refuses it for being deviation-
    ///         increasing beyond the outer rail. Waiting is the arbitrageur's only move there, and waiting is what
    ///         lets the truncated TWAP — and with it `fairTick` — catch up.
    /// @param poolId The pool.
    /// @param who The buyer.
    /// @param unit Counter asset per attempted step.
    /// @param targetTick Stop once the pool is at or above this tick.
    /// @param maxSteps Iteration bound.
    /// @param secondsEach Seconds (and one block) per step.
    /// @return ampsOut Total AMPS bought.
    /// @return steps Steps actually taken.
    function climb(PoolId poolId, address who, uint256 unit, int24 targetTick, uint256 maxSteps, uint256 secondsEach)
        internal
        returns (uint256 ampsOut, uint256 steps)
    {
        for (steps = 0; steps < maxSteps; ++steps) {
            if (tickOf(poolId) >= targetTick) break;
            try this.buyAmpsExternal(poolId, who, unit) returns (uint256 got) {
                ampsOut += got;
            } catch {}
            advance(secondsEach);
        }
    }

    /// @notice The mirror of {climb}: arbitrage a pool downward toward `targetTick` with small sells, skipping
    ///         any the rail refuses.
    /// @param poolId The pool.
    /// @param who The seller, who must already hold the AMPS.
    /// @param unit AMPS per attempted step.
    /// @param targetTick Stop once the pool is at or below this tick.
    /// @param maxSteps Iteration bound.
    /// @param secondsEach Seconds (and one block) per step.
    /// @return counterOut Total counter asset received.
    /// @return steps Steps actually taken.
    function slide(PoolId poolId, address who, uint256 unit, int24 targetTick, uint256 maxSteps, uint256 secondsEach)
        internal
        returns (uint256 counterOut, uint256 steps)
    {
        for (steps = 0; steps < maxSteps; ++steps) {
            if (tickOf(poolId) <= targetTick) break;
            if (amps.balanceOf(who) < unit) break;
            try this.sellAmpsExternal(poolId, who, unit) returns (uint256 got) {
                counterOut += got;
            } catch {}
            advance(secondsEach);
        }
    }

    /// @notice Adds `extra` AMPS of ask depth to every spoke, merging into the cells genesis already opened. The
    ///         launch spoke ladder is 1% of the POL tranche, which is deliberately thin — $2 of stock walks it a
    ///         whole doubling — so a scenario that wants to trade a spoke at a realistic size buys the depth
    ///         through the same governed `place` path genesis uses.
    /// @param extra AMPS per spoke.
    function deepenSpokes(uint256 extra) internal {
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.startPrank(TIMELOCK);
        for (uint256 i; i < spokePools.length; ++i) {
            vault.place(spokePools[i], true, extra);
        }
        vm.stopPrank();
    }

    /// @notice Walks a pool's price up with a run of small exact-input buys, one per block, so that the truncated
    ///         observation ring and the hook's gate cache both follow the move. A single large buy cannot do this:
    ///         the outer rail is measured against `fairTick`, which is the pool's own 30-minute truncated TWAP for
    ///         an entry pool and the hub's for a spoke, and a jump larger than the rail is refused (I15).
    /// @param poolId The pool.
    /// @param who The buyer, funded by this call.
    /// @param amountEach Counter asset per step.
    /// @param steps How many buys.
    /// @param secondsEach Seconds (and one block) between steps.
    /// @return ampsOut Total AMPS bought.
    function pump(PoolId poolId, address who, uint256 amountEach, uint256 steps, uint256 secondsEach)
        internal
        returns (uint256 ampsOut)
    {
        for (uint256 i; i < steps; ++i) {
            ampsOut += buyAmps(poolId, who, amountEach);
            advance(secondsEach);
        }
    }

    /// @notice The mirror of {pump}: a run of small exact-input sells that walks the price back down through the
    ///         proceeds bids.
    /// @param poolId The pool.
    /// @param who The seller, who must already hold the AMPS.
    /// @param amountEach AMPS per step.
    /// @param steps How many sells.
    /// @param secondsEach Seconds (and one block) between steps.
    /// @return counterOut Total counter asset received.
    function dumpAmps(PoolId poolId, address who, uint256 amountEach, uint256 steps, uint256 secondsEach)
        internal
        returns (uint256 counterOut)
    {
        for (uint256 i; i < steps; ++i) {
            counterOut += sellAmps(poolId, who, amountEach);
            advance(secondsEach);
        }
    }

    /// @notice Lets the truncated TWAP converge on whatever the pools are now trading at — one full window of
    ///         elapsed time — and takes a checkpoint so the vault's `P_mkt` is the price the hub really shows.
    ///         This is what an arbitraged market does between blocks, and it is what the placement gauntlet's
    ///         divergence check measures against.
    function settleTwap() internal {
        warpBy(Constants.TWAP_WINDOW_DEFAULT + Constants.PLACEMENT_COOLDOWN_SECONDS);
        vault.checkpoint();
    }

    /// @notice What one ladder cell holds **right now**, decomposed at the pool's live price exactly as
    ///         `LadderPositionValuer` decomposes it at the reference price. A crossed ask holds no AMPS and
    ///         exactly `LadderLib.amount1ForLiquidity` of the counter asset; a straddled cell holds both.
    /// @param poolId The pool.
    /// @param record The record.
    /// @return amount0 AMPS held.
    /// @return amount1 Counter asset held.
    function liveAmounts(PoolId poolId, PlacementRecord memory record)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtNow = sqrtPriceOf(poolId);
        uint160 sqrtLower = PriceLib.tickToSqrtPriceX96(record.lowerTick);
        uint160 sqrtUpper = PriceLib.tickToSqrtPriceX96(record.upperTick);
        if (sqrtNow <= sqrtLower) {
            amount0 = LadderLib.amount0ForLiquidity(sqrtLower, sqrtUpper, record.liquidity);
        } else if (sqrtNow >= sqrtUpper) {
            amount1 = LadderLib.amount1ForLiquidity(sqrtLower, sqrtUpper, record.liquidity);
        } else {
            amount0 = LadderLib.amount0ForLiquidity(sqrtNow, sqrtUpper, record.liquidity);
            amount1 = LadderLib.amount1ForLiquidity(sqrtLower, sqrtNow, record.liquidity);
        }
    }

    /// @notice The AMPS still sitting in unfilled ask cells of `poolId`, measured at the pool's live price.
    /// @param poolId The pool.
    /// @return amount The AMPS.
    function ladderAskInventory(PoolId poolId) internal view returns (uint256 amount) {
        PlacementRecord[] memory records = ladderOf(poolId);
        for (uint256 i; i < records.length; ++i) {
            if (!records[i].above || records[i].liquidity == 0) continue;
            (uint256 amount0,) = liveAmounts(poolId, records[i]);
            amount += amount0;
        }
    }

    /// @notice Gives spoke `i` a real bid side the way production does: a bond brings collateral in, and
    ///         `deployBonded` places it as a `bondBidHalvings` ladder strictly below the tick. Until something
    ///         does this a spoke has asks only, and a sell into it walks straight to the tick floor.
    ///
    /// @dev **The bond is sized to the market's capacity, deliberately.** `AmpsBonds.bond` clamps the AMPS it
    ///      issues to the epoch's remaining capacity but keeps the *whole* deposit (`minAmpsOut` is the bonder's
    ///      only protection), so a fixture that bonds an arbitrary amount silently donates the excess to NAV and
    ///      poisons every NAV assertion downstream. The epoch cap is raised to its own hard maximum first, the
    ///      deposit is derived from `quote`, and `minAmpsOut` is set - which is exactly what a real bonder does.
    /// @param i The spoke index.
    /// @return collateral The collateral actually bonded, in the stock's units.
    /// @return ampsOut The AMPS issued for it.
    function seedSpokeBids(uint256 i) internal returns (uint256 collateral, uint256 ampsOut) {
        vm.startPrank(TIMELOCK);
        bonds.setCapBpsPerEpoch(marketIds[i], Constants.BOND_CAP_BPS_PER_EPOCH_MAX);
        bonds.setDailyCapBps(Constants.BOND_DAILY_CAP_BPS_MAX);
        vault.setDeployThresholdUsd18(Constants.DEPLOY_THRESHOLD_USD18_MIN);
        vm.stopPrank();

        uint256 capacity = bonds.capacityRemaining(marketIds[i]);
        (uint256 probeOut,,,,,) = bonds.quote(marketIds[i], 1e18);
        require(probeOut != 0, "bond market cannot price");
        collateral = capacity * 1e18 / probeOut;

        stocks[i].mint(BOB, collateral);
        vm.startPrank(BOB);
        stocks[i].approve(address(vault), type(uint256).max);
        (ampsOut,) = bonds.bond(marketIds[i], collateral, capacity * 9 / 10, BOB);
        vm.stopPrank();

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        vault.deployBonded(constituentIds[i]);
    }

    /// @notice The record for grid cell `m` of `poolId`, or a zeroed record when the cell is not live.
    /// @param poolId The pool.
    /// @param m The grid index, `[GRID_MIN_M, GRID_MAX_M)`.
    /// @return record The record.
    function cellOf(PoolId poolId, int256 m) internal view returns (PlacementRecord memory record) {
        PlacementRecord[] memory records = ladderOf(poolId);
        uint8 index = uint8(uint256(m - Constants.GRID_MIN_M));
        for (uint256 i; i < records.length; ++i) {
            if (records[i].bucketIndex == index) return records[i];
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers — reading the fee the pool actually charged
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every `IPoolManager.Swap` fee field in the recorded logs, in emission order (one per hop).
    /// @param logs The recorded logs.
    /// @return fees The fees, in pips.
    function swapFees(Vm.Log[] memory logs) internal pure returns (uint24[] memory fees) {
        uint256 count;
        uint24[] memory buffer = new uint24[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                buffer[count++] = fee;
            }
        }
        fees = new uint24[](count);
        for (uint256 i; i < count; ++i) {
            fees[i] = buffer[i];
        }
    }

    /// @notice The fee the pool charged on the last recorded swap, in pips.
    /// @param logs The recorded logs.
    /// @return fee The fee.
    function lastSwapFee(Vm.Log[] memory logs) internal pure returns (uint24 fee) {
        uint24[] memory fees = swapFees(logs);
        require(fees.length != 0, "no Swap event");
        fee = fees[fees.length - 1];
    }

    /// @notice A hook revert as the PoolManager re-throws it: ERC-7751 `WrappedError`, not the bare error.
    /// @param hookSelector The hook callback selector.
    /// @param reason The inner revert data.
    /// @return wrapped The expected revert payload.
    function wrappedHookRevert(bytes4 hookSelector, bytes memory reason) internal view returns (bytes memory wrapped) {
        wrapped = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers — keys, parameters, calendar tables
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The one pool-key shape every Amplestocks pool has: AMPS as `currency0`, the dynamic-fee flag, our hook.
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
        PoolClass class = stockClass(i);
        params = IPoolRegistry.AddConstituentParams({
            token: address(stocks[i]),
            feed: address(stockFeeds[i]),
            poolClass: class,
            tickSpacing: TICK_SPACING,
            buyFeeBps: class == PoolClass.SPOKE_HIGH_VOL
                ? Constants.BUY_FEE_BPS_SPOKE_HIGH_VOL_DEFAULT
                : Constants.BUY_FEE_BPS_SPOKE_DEFAULT,
            targetWeightBps: TARGET_WEIGHT_BPS,
            rolloutWeightBps: ROLLOUT_WEIGHT_BPS,
            hSessionOverrideBps: 0,
            hSessionOverrideSet: false,
            inclusion: InclusionRecord({
                betaX18: 0.9e18, trackingErrorX18: 0.03e18, indexVolX18: 0.2e18, historyDays: 400, recordedAt: 0
            }),
            openBondMarket: true
        });
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

    function _ids() private view returns (uint16[] memory ids) {
        ids = new uint16[](constituentIds.length);
        for (uint256 i; i < constituentIds.length; ++i) {
            ids[i] = constituentIds[i];
        }
    }

    /// @dev An even index, with the flooring residue given to the last name so the vector sums to exactly
    ///      `BPS` - which `PoolRegistry.setIndexWeights` requires to the basis point.
    function _weights() private view returns (uint16[] memory weightsBps) {
        uint256 n = constituentIds.length;
        weightsBps = new uint16[](n);
        if (n == 0) return weightsBps;
        uint16 each = uint16(Constants.BPS / n);
        uint16 assigned;
        for (uint256 i; i < n - 1; ++i) {
            weightsBps[i] = each;
            assigned += each;
        }
        weightsBps[n - 1] = uint16(Constants.BPS) - assigned;
    }

    /// @dev US DST window starts, UTC: the second Sunday in March at 02:00 EST, 2025 through 2032.
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

    /// @dev US DST window ends, UTC: the first Sunday in November at 02:00 EDT, 2025 through 2032.
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

    /// @dev The 2026 NYSE full-day closures as days of the year, packed into the gate's two-word bitmap.
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
        for (uint256 i; i < stocks.length; ++i) {
            if (uint160(address(stocks[i])) < lowest) lowest = uint160(address(stocks[i]));
        }
    }

    function _assertAmpsSortsFirst() private view {
        require(uint160(address(amps)) < uint160(address(weth)), "AMPS < WETH");
        require(uint160(address(amps)) < uint160(address(usdg)), "AMPS < USDG");
        for (uint256 i; i < stocks.length; ++i) {
            require(uint160(address(amps)) < uint160(address(stocks[i])), "AMPS < stock");
        }
    }
}
