// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsBonds} from "../../src/bonds/AmpsBonds.sol";
import {AmpsBondsLens} from "../../src/bonds/AmpsBondsLens.sol";
import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IPoolRegistry} from "../../src/interfaces/IPoolRegistry.sol";
import {BountyPot} from "../../src/keeper/BountyPot.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {FeedRegistry} from "../../src/oracle/FeedRegistry.sol";
import {OracleGate} from "../../src/oracle/OracleGate.sol";
import {BondPolicy} from "../../src/policy/BondPolicy.sol";
import {PoolRegistry} from "../../src/registry/PoolRegistry.sol";
import {PoolRegistryLens} from "../../src/registry/PoolRegistryLens.sol";
import {AmpsStaking} from "../../src/staking/AmpsStaking.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {FeedConfig, InclusionRecord, PoolClass} from "../../src/types/Types.sol";
import {ZeroPositionValuer} from "../../src/valuer/ZeroPositionValuer.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {StubAmpsHook} from "../gas/StubAmpsHook.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockMarketReference} from "../mocks/MockMarketReference.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockUsdg} from "../mocks/MockUsdg.sol";
import {V4TestBase} from "../utils/V4TestBase.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title Phase2Fixture
/// @notice The whole Phase 2 system, real contract by real contract, on the local Uniswap v4 stack: `Amps`,
///         `AmpsVault` (+ the linked `VaultNavLib`), `PoolRegistry` + lens, `AmpsBonds` + `BondPolicy` + lens,
///         `AmpsStaking`, `BountyPot`, `OracleGate` + `FeedRegistry` + `GatePriceMath`, `ZeroPositionValuer`, an
///         OZ `VestingWallet` for the team tranche, and the launch seed that puts NAV/share at $1.00.
///
///         Only three things in here are not the production contract: `AmpsHook` does not exist yet, so the
///         observation surface is `MockMarketReference` and the pool hook is `test/gas/StubAmpsHook.sol` (same
///         `0x38C0` flag set, same `beforeInitialize` preconditions, no business logic); the Stock Tokens are
///         `MockStockToken`; and the Chainlink aggregators are `MockAggregator`. Everything the invariants and the
///         journeys assert about is real code.
///
/// @dev **AMPS ordering.** Production CREATE2-mines AMPS to three leading zero bytes so it is `currency0` in all
///      32 pools (`PoolRegistry._validateKeyShape` hard-requires `uint160(amps) < uint160(counter)`). Etching the
///      runtime code at a low address is not usable here: `Amps.vault` is *storage*, not an immutable (it has to
///      be, because `setVault` hands the role on during migration), so an etched copy would come up with a zero
///      vault and no way to set it. The fixture therefore does what the deploy script does, in miniature: the
///      seven counter assets are deployed first, the vault's CREATE address is predicted, and a CREATE2 salt is
///      mined for `Amps` until its address sorts below every counter. Same shape as production, no etching, and
///      the ordering is a property of the deployment rather than of a lucky nonce.
///
/// @dev **Wiring order, and why it is not the order the state model lists.** `AmpsVault.initializePool` is gated
///      by `_requireHealthy`, and `OracleGate` reports `WATCHDOG` whenever the `AMPS/USDG` hub pool is either
///      unregistered or has less than `twapWindow` of observation coverage (`_referenceIntegrity` ->
///      `coverageMissing`). Registering the very first pool through a wired gate is therefore circular. The
///      fixture wires every pointer except `oracleGate`, registers the 32-pool shape, seeds the hub and WETH
///      rings, and only then points the vault at the gate — after which `genesis()` runs fully gated. See the
///      report accompanying this suite: on a live deployment the same ordering constraint applies, because a
///      freshly initialised hook pool has no 30 minutes of observations either.
abstract contract Phase2Fixture is V4TestBase {
    using PoolIdLibrary for PoolKey;

    // -------------------------------------------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The governance timelock. Pranked directly: the delay itself is `TimelockController`'s business.
    address internal constant TIMELOCK = address(0x71E10C4);
    /// @dev The guardian Safe: disable-only freezes and the predicate-gated migration trigger.
    address internal constant GUARDIAN = address(0x6A4D1A17);
    /// @dev The creator fee recipient recorded at genesis.
    address internal constant CREATOR = address(0xC12EA704);
    /// @dev The pre-registered standby vault an emergency migration may target.
    address internal constant STANDBY = address(0x57A4DB1);
    /// @dev The team's vesting-wallet beneficiary.
    address internal constant TEAM = address(0x7EA11);
    /// @dev Ordinary holders.
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    /// @dev The keeper the bounty pot pays.
    address internal constant KEEPER = address(0x6EE9E4);

    // -------------------------------------------------------------------------------------------------------------
    // Launch vector
    // -------------------------------------------------------------------------------------------------------------

    /// @dev 2026-09-09 14:00:00 UTC — a Wednesday, 10:00 ET on daylight time, i.e. squarely inside `REGULAR`.
    ///      Every gated vault path refuses in a `CLOSED` session (the gate resolves that to `DEGRADED`), so the
    ///      whole fixture is built and run on a live trading clock.
    uint256 internal constant GENESIS_TIME = 1_788_962_400;
    /// @dev A block height whose truncation to `uint32` is still monotone, and far enough above the watchdog's
    ///      `gapSeconds` arithmetic that a warp can always be matched by a roll.
    uint256 internal constant GENESIS_BLOCK = 20_000_000;

    /// @dev WETH at $2,500.
    uint128 internal constant WETH_USD8 = 2500e8;
    /// @dev USDG at $1.00.
    uint128 internal constant USDG_USD8 = 1e8;
    /// @dev The founders' seed: 1 WETH ($2,500) + 2,500 USDG ($2,500) = `A` of $5,000 against `S0` of 5,000 AMPS.
    uint256 internal constant SEED_WETH = 1e18;
    uint256 internal constant SEED_USDG = 2500e6;

    /// @dev The five constituents. Index 0 is the NVDA-like name every bond journey uses; index 4 is the CRWD-like
    ///      name that carries a 4.0 display multiplier from block one (raw balances are unaffected — that is the
    ///      whole point of ERC-8056 — so the multiplier is a change detector, never a price input).
    uint256 internal constant CONSTITUENTS = 5;

    int24 internal constant TICK_SPACING = 60;
    uint16 internal constant TARGET_WEIGHT_BPS = 2000;
    uint16 internal constant ROLLOUT_WEIGHT_BPS = 1500;

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
    PoolRegistryLens internal registryLens;
    AmpsBonds internal bonds;
    AmpsBondsLens internal bondsLens;
    BondPolicy internal policy;
    AmpsStaking internal staking;
    BountyPot internal pot;
    OracleGate internal gate;
    FeedRegistry internal feeds;
    MockMarketReference internal marketRef;
    ZeroPositionValuer internal valuer;
    StubAmpsHook internal hook;
    VestingWallet internal teamVesting;

    MockERC20 internal weth;
    MockUsdg internal usdg;
    MockAggregator internal wethFeed;
    MockAggregator internal usdgFeed;

    MockStockToken[CONSTITUENTS] internal stocks;
    MockAggregator[CONSTITUENTS] internal stockFeeds;
    uint16[CONSTITUENTS] internal constituentIds;
    uint16[CONSTITUENTS] internal marketIds;
    PoolId[CONSTITUENTS] internal spokePools;

    PoolId internal hubPool;
    PoolId internal wethPool;

    /// @dev $180 NVDA-like, $250 AAPL-like, $650 SPY-like, $400, $50 CRWD-like.
    uint128[CONSTITUENTS] internal STOCK_USD8 = [uint128(180e8), 250e8, 650e8, 400e8, 50e8];
    string[CONSTITUENTS] internal STOCK_SYMBOLS = ["NVDX", "AAPX", "SPYX", "MSFX", "CRWX"];

    // -------------------------------------------------------------------------------------------------------------
    // Deployment
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Deploys and wires the entire Phase 2 world, registers the 7-pool launch shape (hub, WETH and five
    ///         spokes) and leaves the vault one call short of {genesis}.
    function deployPhase2World() internal {
        vm.warp(GENESIS_TIME);
        vm.roll(GENESIS_BLOCK);

        deployV4();
        _deployAssets();
        _deployCore();
        _deployPeriphery();
        _configureOracles();
        _seedRings(Constants.WAD);
        _wireVault();
        _registerPools();
    }

    /// @notice Runs `genesis()` with the confirmed launch parameters: 250 AMPS to the team wallet, 4,750 retained
    ///         as POL, 1 WETH and 2,500 USDG of seed.
    function runPhase2Genesis() internal {
        weth.mint(TIMELOCK, SEED_WETH);
        usdg.mint(TIMELOCK, SEED_USDG);

        vm.startPrank(TIMELOCK);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.genesis(genesisParams());
        vm.stopPrank();
    }

    /// @notice The launch genesis arguments.
    function genesisParams() internal view returns (IAmpsVault.GenesisParams memory params) {
        address[] memory seedTokens = new address[](2);
        uint256[] memory seedAmounts = new uint256[](2);
        seedTokens[0] = address(weth);
        seedAmounts[0] = SEED_WETH;
        seedTokens[1] = address(usdg);
        seedAmounts[1] = SEED_USDG;

        params = IAmpsVault.GenesisParams({
            teamVestingWallet: address(teamVesting),
            creator: CREATOR,
            teamShares: Constants.TEAM_SHARES,
            polShares: Constants.POL_SHARES,
            seedTokens: seedTokens,
            seedAmounts: seedAmounts
        });
    }

    // -------------------------------------------------------------------------------------------------------------
    // Deployment steps
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The seven counter assets and their aggregators. Deployed *before* AMPS so the salt can be mined
    ///      against the addresses they actually landed on.
    function _deployAssets() private {
        weth = deployToken("Wrapped Ether", "WETH", 18);
        usdg = new MockUsdg("Global Dollar", "USDG", 6);
        wethFeed = new MockAggregator("ETH / USD", 8, int256(uint256(WETH_USD8)));
        usdgFeed = new MockAggregator("USDG / USD", 8, int256(uint256(USDG_USD8)));

        for (uint256 i; i < CONSTITUENTS; ++i) {
            stocks[i] = new MockStockToken(STOCK_SYMBOLS[i], STOCK_SYMBOLS[i]);
            stockFeeds[i] =
                new MockAggregator(string.concat(STOCK_SYMBOLS[i], " / USD"), 8, int256(uint256(STOCK_USD8[i])));
            vm.label(address(stocks[i]), STOCK_SYMBOLS[i]);
        }

        // The CRWD-like name: a 4.0 display multiplier that has always been 4.0. Raw balances are untouched by it
        // and no Chainlink answer is ever multiplied by it (research finding 2), so nothing downstream may move.
        stocks[4].setUIMultiplier(4e18);

        vm.label(address(weth), "WETH");
        vm.label(address(usdg), "USDG");
    }

    /// @dev `Amps` (CREATE2, mined below every counter), `AmpsVault` (CREATE, predicted), the flag-mined hook.
    function _deployCore() private {
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        bytes32 salt = _mineAmpsSalt(predictedVault);

        amps = new Amps{salt: salt}(predictedVault);
        vault = new AmpsVault(address(amps), address(poolManager), TIMELOCK, GUARDIAN);
        require(address(vault) == predictedVault, "vault address prediction");
        require(amps.vault() == address(vault), "amps points at the vault");
        _assertAmpsSortsFirst();

        bytes memory args = abi.encode(poolManager, Currency.wrap(address(amps)), address(vault));
        (address mined, bytes32 hookSalt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(StubAmpsHook).creationCode, args);
        hook = new StubAmpsHook{salt: hookSalt}(poolManager, Currency.wrap(address(amps)), address(vault));
        require(address(hook) == mined, "hook address mismatch");

        vm.label(address(amps), "AMPS");
        vm.label(address(vault), "AmpsVault");
        vm.label(address(hook), "AmpsHook(stub)");
    }

    /// @dev Everything that takes the vault in its constructor, plus the two lenses and the team vesting wallet.
    function _deployPeriphery() private {
        marketRef = new MockMarketReference();
        registry =
            new PoolRegistry(address(vault), address(hook), TIMELOCK, address(amps), address(weth), address(usdg));
        registryLens = new PoolRegistryLens(address(registry));

        feeds = new FeedRegistry(TIMELOCK, address(0));
        gate = new OracleGate(TIMELOCK, GUARDIAN, address(feeds), address(registry), address(marketRef));

        policy = new BondPolicy();
        bonds = new AmpsBonds(address(vault), address(registry), address(policy));
        bondsLens = new AmpsBondsLens();
        staking = new AmpsStaking(IERC20(address(amps)), address(vault), TIMELOCK);
        pot = new BountyPot(address(usdg), address(vault), TIMELOCK);
        valuer = new ZeroPositionValuer();
        teamVesting = new VestingWallet(TEAM, uint64(GENESIS_TIME), Constants.TEAM_VEST_SECONDS);

        vm.label(address(registry), "PoolRegistry");
        vm.label(address(bonds), "AmpsBonds");
        vm.label(address(staking), "AmpsStaking");
        vm.label(address(pot), "BountyPot");
        vm.label(address(gate), "OracleGate");
        vm.label(address(feeds), "FeedRegistry");
        vm.label(address(teamVesting), "TeamVestingWallet");
    }

    /// @dev The calendar (real 2025-2032 US DST table and the 2026 NYSE holidays) and every feed.
    function _configureOracles() private {
        vm.startPrank(TIMELOCK);
        feeds.setOracleGate(address(gate));
        gate.setDstTable(_dstStarts(), _dstEnds());
        gate.setHolidayBitmap(2026, _bitmap2026());
        vm.stopPrank();

        _installFeed(address(weth), address(wethFeed), 3600);
        _installFeed(address(usdg), address(usdgFeed), Constants.ONE_DAY);
        for (uint256 i; i < CONSTITUENTS; ++i) {
            _installFeed(address(stocks[i]), address(stockFeeds[i]), Constants.ONE_DAY);
        }
    }

    /// @dev Seeds the observation rings the gate and the vault both read. Pool ids are computed from the keys the
    ///      registry will build, so the rings exist *before* the first pool is registered — see the header note.
    /// @param ampsUsd18 The AMPS price every ring is seeded at.
    function _seedRings(uint256 ampsUsd18) private {
        hubPool = _key(address(usdg)).toId();
        wethPool = _key(address(weth)).toId();
        for (uint256 i; i < CONSTITUENTS; ++i) {
            spokePools[i] = _key(address(stocks[i])).toId();
        }
        seedAllRings(ampsUsd18);
    }

    /// @dev Every pointer except `oracleGate`, which is wired after the pools exist.
    function _wireVault() private {
        vm.startPrank(TIMELOCK);
        vault.setPolicyPointer(bytes32("registry"), address(registry));
        vault.setPolicyPointer(bytes32("bonds"), address(bonds));
        vault.setPolicyPointer(bytes32("staking"), address(staking));
        vault.setPolicyPointer(bytes32("bountyPot"), address(pot));
        vault.setPolicyPointer(bytes32("marketReference"), address(marketRef));
        vault.setPolicyPointer(bytes32("feedRegistry"), address(feeds));
        vault.setPolicyPointer(bytes32("positionValuer"), address(valuer));
        vm.stopPrank();
    }

    /// @dev The two entry pools, the five spokes with their bond markets, the index weight vector, and only then
    ///      the gate pointer.
    function _registerPools() private {
        vm.startPrank(TIMELOCK);
        registry.registerEntryPool(_key(address(usdg)), 6, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, address(usdgFeed));
        registry.registerEntryPool(_key(address(weth)), 18, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, address(wethFeed));

        for (uint256 i; i < CONSTITUENTS; ++i) {
            (uint16 id, PoolId poolId) = registry.addConstituent(_addParams(i));
            constituentIds[i] = id;
            require(PoolId.unwrap(poolId) == PoolId.unwrap(spokePools[i]), "spoke pool id");
            marketIds[i] = registry.constituent(id).marketId;
        }

        registry.setIndexWeights(_ids(), _weights());
        vault.setPolicyPointer(bytes32("oracleGate"), address(gate));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers — time, oracles and rings
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Warps `dt` seconds forward and produces one block per second with it, so the layer-A watchdog sees
    ///         a chain that kept running (`produced >= elapsed / gapSeconds`) rather than a stalled sequencer.
    function warpBy(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + dt + 1);
    }

    /// @notice Republishes every aggregator at its current answer, stamping `updatedAt` with the current block.
    function refreshFeeds() internal {
        wethFeed.setAnswer(int256(uint256(WETH_USD8)));
        usdgFeed.setAnswer(int256(uint256(USDG_USD8)));
        for (uint256 i; i < CONSTITUENTS; ++i) {
            stockFeeds[i].setAnswer(int256(uint256(STOCK_USD8[i])));
        }
    }

    /// @notice Re-seeds the hub, the WETH pool and every spoke at one AMPS price. Both entry legs move together,
    ///         so the vault's layer-F cross-check (`|hub - weth x ETH/USD| <= refDivergenceBps`) stays satisfied.
    /// @param ampsUsd18 The AMPS price in USD, 18 decimals.
    function seedAllRings(uint256 ampsUsd18) internal {
        seedEntryRings(ampsUsd18);
        for (uint256 i; i < CONSTITUENTS; ++i) {
            seedSpokeRing(i, ampsUsd18);
        }
    }

    /// @notice Seeds the two entry pools' rings at `ampsUsd18`.
    function seedEntryRings(uint256 ampsUsd18) internal {
        _observe(hubPool, ampsUsd18, USDG_USD8, 6);
        _observe(wethPool, ampsUsd18, WETH_USD8, 18);
    }

    /// @notice Seeds spoke `i`'s ring at `ampsUsd18`, i.e. at `ampsUsd18 / stockPrice` stock per AMPS.
    function seedSpokeRing(uint256 i, uint256 ampsUsd18) internal {
        _observe(spokePools[i], ampsUsd18, STOCK_USD8[i], 18);
    }

    /// @dev One ring entry, at full coverage, for the AMPS/counter pool implied by the two prices.
    function _observe(PoolId poolId, uint256 ampsUsd18, uint256 counterUsd8, uint8 counterDecimals) private {
        int24 tick =
            PriceLib.sqrtPriceX96ToTick(PriceLib.ampsPerCounterToSqrtPriceX96(ampsUsd18, counterUsd8, counterDecimals));
        marketRef.setObservation(poolId, tick, tick, Constants.TWAP_WINDOW_DEFAULT);
    }

    /// @notice The AMPS price the vault will read back out of the hub ring, which is the tick-rounded form of
    ///         whatever was seeded. Every `P_mkt` assertion is written against this rather than the nominal price.
    function hubPriceUsd18() internal view returns (uint256 priceUsd18) {
        int24 tick = marketRef.twapTick(hubPool, Constants.TWAP_WINDOW_DEFAULT);
        priceUsd18 = PriceLib.sqrtPriceX96ToAmpsPriceUsd18(PriceLib.tickToSqrtPriceX96(tick), USDG_USD8, 6);
    }

    /// @dev Allowlists an aggregator as a Standard proxy and configures it for `token`.
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
    // Helpers — balances, shares and bonds
    // -------------------------------------------------------------------------------------------------------------

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

    /// @notice Buys a bond on market `i` as `who`, funding and approving the collateral first.
    /// @return ampsOut The AMPS purchased.
    /// @return positionId The vesting position created.
    function bondAs(address who, uint256 i, uint256 amountIn, uint256 minAmpsOut)
        internal
        returns (uint256 ampsOut, uint256 positionId)
    {
        stocks[i].mint(who, amountIn);
        vm.startPrank(who);
        stocks[i].approve(address(vault), type(uint256).max);
        (ampsOut, positionId) = bonds.bond(marketIds[i], amountIn, minAmpsOut, who);
        vm.stopPrank();
    }

    /// @notice I12 at the integration level: neither the vault nor the bonds shell rests on an ERC-20 balance of
    ///         any registered asset.
    function assertSweepClean(string memory context) internal view {
        uint256 count = vault.assetCount();
        for (uint256 i; i < count; ++i) {
            address token = vault.assetAt(i);
            assertEq(IERC20(token).balanceOf(address(vault)), 0, string.concat("vault idle balance: ", context));
            assertEq(IERC20(token).balanceOf(address(bonds)), 0, string.concat("bonds idle balance: ", context));
        }
        assertEq(IERC20(address(amps)).balanceOf(address(hook)), 0, string.concat("hook holds no AMPS: ", context));
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

    /// @dev A constituent that passes the inclusion rule: beta 0.9 against a 3% tracking error and 20% index vol.
    function _addParams(uint256 i) internal view returns (IPoolRegistry.AddConstituentParams memory params) {
        params = IPoolRegistry.AddConstituentParams({
            token: address(stocks[i]),
            feed: address(stockFeeds[i]),
            poolClass: i == 4 ? PoolClass.SPOKE_HIGH_VOL : PoolClass.SPOKE,
            tickSpacing: TICK_SPACING,
            buyFeeBps: i == 4 ? Constants.BUY_FEE_BPS_SPOKE_HIGH_VOL_DEFAULT : Constants.BUY_FEE_BPS_SPOKE_DEFAULT,
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

    function _ids() private view returns (uint16[] memory ids) {
        ids = new uint16[](CONSTITUENTS);
        for (uint256 i; i < CONSTITUENTS; ++i) {
            ids[i] = constituentIds[i];
        }
    }

    function _weights() private pure returns (uint16[] memory weightsBps) {
        weightsBps = new uint16[](CONSTITUENTS);
        for (uint256 i; i < CONSTITUENTS; ++i) {
            weightsBps[i] = TARGET_WEIGHT_BPS;
        }
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

    /// @dev Mines a CREATE2 salt for `Amps(predictedVault)` whose address sorts below every counter asset already
    ///      deployed, which is what makes AMPS `currency0` in all seven pools. The bound is the real one the
    ///      registry enforces, so the search is over exactly the property production mines for.
    function _mineAmpsSalt(address predictedVault) private view returns (bytes32 salt) {
        bytes32 initHash = keccak256(abi.encodePacked(type(Amps).creationCode, abi.encode(predictedVault)));
        uint160 ceiling = _lowestCounter();
        for (uint256 i; i < 1 << 22; ++i) {
            salt = bytes32(i);
            uint160 candidate =
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))));
            // The floor keeps the search away from the precompile range, where an `extcodesize` check would read
            // a live account that is not ours.
            if (candidate < ceiling && candidate > 0xffff) return salt;
        }
        revert("no AMPS salt below every counter");
    }

    /// @dev The lowest counter-asset address, i.e. the ceiling AMPS has to stay under.
    function _lowestCounter() private view returns (uint160 lowest) {
        lowest = type(uint160).max;
        address[7] memory counters = [
            address(weth),
            address(usdg),
            address(stocks[0]),
            address(stocks[1]),
            address(stocks[2]),
            address(stocks[3]),
            address(stocks[4])
        ];
        for (uint256 i; i < counters.length; ++i) {
            if (uint160(counters[i]) < lowest) lowest = uint160(counters[i]);
        }
    }

    /// @dev The property the whole pool set depends on, asserted rather than assumed.
    function _assertAmpsSortsFirst() private view {
        address[7] memory counters = [
            address(weth),
            address(usdg),
            address(stocks[0]),
            address(stocks[1]),
            address(stocks[2]),
            address(stocks[3]),
            address(stocks[4])
        ];
        for (uint256 i; i < counters.length; ++i) {
            require(uint160(address(amps)) < uint160(counters[i]), "AMPS must sort below every counter");
        }
    }
}
