// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsBonds} from "../../src/bonds/AmpsBonds.sol";
import {AmpsBondsLens} from "../../src/bonds/AmpsBondsLens.sol";
import {IAmpsBonds} from "../../src/interfaces/IAmpsBonds.sol";
import {IBondPolicy} from "../../src/interfaces/IBondPolicy.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {BondPolicy} from "../../src/policy/BondPolicy.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {
    CapacityExceeded,
    NotTimelock,
    NotVault,
    OutOfBand,
    Reentrancy,
    SlippageExceeded,
    StaleCheckpoint,
    UnknownMarket,
    UnknownPool,
    ZeroAddress,
    ZeroAmount
} from "../../src/types/Errors.sol";
import {
    BondMarket,
    CollateralClass,
    ConstituentStatus,
    GateState,
    PoolClass,
    Session,
    VestingPosition
} from "../../src/types/Types.sol";
import {MockAmpsVault} from "../mocks/MockAmpsVault.sol";
import {MockFeedRegistry} from "../mocks/MockFeedRegistry.sol";
import {MockMarketReference} from "../mocks/MockMarketReference.sol";
import {MockOracleGate} from "../mocks/MockOracleGate.sol";
import {MockRegistryForBonds} from "../mocks/MockRegistryForBonds.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockUsdg} from "../mocks/MockUsdg.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The shared fixture: a real `Amps`, a vault mock that mints and takes custody, the gate, feed registry,
///         registry and market marketRef the bond shell reads, one `CONSTITUENT` market on a $180 stock and one
///         closed `ENTRY` market on 6-decimal USDG.
/// @dev Numbers are the confirmed launch parameters: 5,000 AMPS of supply at $1.00 NAV/share, so the per-epoch
///      capacity is 25 AMPS (50 bp) and the daily cap is 100 AMPS (200 bp).
abstract contract BondsFixture is Test {
    Amps internal amps;
    MockAmpsVault internal vaultMock;
    MockOracleGate internal gate;
    MockFeedRegistry internal feeds;
    MockRegistryForBonds internal registry;
    MockMarketReference internal marketRef;
    MockStockToken internal stock;
    MockUsdg internal usdg;
    BondPolicy internal policy;
    AmpsBonds internal bonds;
    AmpsBondsLens internal lens;

    address internal timelock = makeAddr("timelock");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    PoolId internal spokePool = PoolId.wrap(keccak256("AMPS/STOCK"));
    PoolId internal hubPool = PoolId.wrap(keccak256("AMPS/USDG"));
    PoolId internal wethPool = PoolId.wrap(keccak256("AMPS/WETH"));

    uint16 internal constituentId;
    uint16 internal marketId;
    uint16 internal entryMarketId;

    uint256 internal constant GENESIS_SUPPLY = Constants.S0;
    uint256 internal constant STOCK_PRICE_USD8 = 180e8;
    uint256 internal constant NAV_X18 = 1e18;
    uint16 internal constant TARGET_WEIGHT_BPS = 333;

    function setUp() public virtual {
        vm.warp(1_800_000_000);

        vaultMock = new MockAmpsVault(timelock);
        amps = new Amps(address(vaultMock));
        vaultMock.setAmps(address(amps));

        gate = new MockOracleGate();
        feeds = new MockFeedRegistry();
        registry = new MockRegistryForBonds();
        marketRef = new MockMarketReference();
        vaultMock.setPointers(address(gate), address(feeds), address(registry), address(marketRef));

        policy = new BondPolicy();
        bonds = new AmpsBonds(address(vaultMock), address(registry), address(policy));
        vaultMock.setBonds(address(bonds));
        lens = new AmpsBondsLens();

        stock = new MockStockToken("Mock NVDA", "mNVDA");
        usdg = new MockUsdg("Mock USDG", "mUSDG", 6);

        constituentId = registry.addConstituentAndPool(
            address(stock), address(0xFEED), spokePool, PoolClass.SPOKE, 60, TARGET_WEIGHT_BPS
        );
        registry.setHubPoolId(hubPool);
        registry.setWethPoolId(wethPool);
        registry.addEntryPool(hubPool, address(usdg), 6, 60, Constants.BUY_FEE_BPS_ENTRY_DEFAULT);

        feeds.setAnswer(address(stock), uint128(STOCK_PRICE_USD8));
        feeds.setAnswer(address(usdg), 1e8);

        // At its target weight by default: the deficit term is exercised on its own, in its own test.
        registry.setCurrentWeightBps(constituentId, TARGET_WEIGHT_BPS);

        // The genesis supply, and the $5,000 of assets behind it.
        vaultMock.mintGenesis(address(this), GENESIS_SUPPLY);
        vaultMock.setTotalAssetsUsd18(5000e18);
        vaultMock.setCheckpoint(uint128(NAV_X18), uint128(NAV_X18), uint128(NAV_X18), uint32(block.timestamp));

        // AMPS at $1.00 against a $180 stock: no premium, so the accretion floor is the binding price.
        _setSpokePriceUsd18(NAV_X18);
        _setEntryPriceUsd18(NAV_X18);

        vm.startPrank(timelock);
        marketId = bonds.addCollateral(
            address(stock),
            CollateralClass.CONSTITUENT,
            Constants.BOND_D_BASE_BPS_DEFAULT,
            Constants.BOND_D_MIN_BPS_DEFAULT,
            Constants.BOND_D_MAX_BPS_DEFAULT,
            Constants.BOND_CAP_BPS_PER_EPOCH_DEFAULT,
            true
        );
        // `ENTRY` collateral is present in the bytecode from v1 but closed at launch (Decision 20).
        entryMarketId = bonds.addCollateral(
            address(usdg),
            CollateralClass.ENTRY,
            Constants.BOND_D_BASE_BPS_DEFAULT,
            Constants.BOND_D_MIN_BPS_DEFAULT,
            Constants.BOND_D_MAX_BPS_DEFAULT,
            Constants.BOND_CAP_BPS_PER_EPOCH_DEFAULT,
            false
        );
        vm.stopPrank();

        _fund(alice, 100e18);
        _fund(bob, 100e18);
    }

    /* -------------------------------------------- helpers -------------------------------------------- */

    /// @dev Funds a bonder and approves the **vault**, which is what takes custody.
    function _fund(address who, uint256 amount) internal {
        stock.mint(who, amount);
        usdg.mint(who, 1_000_000e6);
        vm.startPrank(who);
        stock.approve(address(vaultMock), type(uint256).max);
        usdg.approve(address(vaultMock), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Puts the spoke's 30-minute TWAP at the tick implied by an AMPS price of `ampsPriceUsd18`.
    function _setSpokePriceUsd18(uint256 ampsPriceUsd18) internal {
        int24 tick = _tickFor(ampsPriceUsd18, STOCK_PRICE_USD8, 18);
        marketRef.setObservation(spokePool, tick, tick, 1800);
    }

    /// @dev The same for the 6-decimal entry pool.
    function _setEntryPriceUsd18(uint256 ampsPriceUsd18) internal {
        int24 tick = _tickFor(ampsPriceUsd18, 1e8, 6);
        marketRef.setObservation(hubPool, tick, tick, 1800);
    }

    /// @dev The pool tick at which AMPS is worth `ampsPriceUsd18` against a counter asset at `counterPriceUsd8`.
    function _tickFor(uint256 ampsPriceUsd18, uint256 counterPriceUsd8, uint8 decimals) internal pure returns (int24) {
        return
            PriceLib.sqrtPriceX96ToTick(
                PriceLib.ampsPerCounterToSqrtPriceX96(ampsPriceUsd18, counterPriceUsd8, decimals)
            );
    }

    /// @dev `m`, recomputed from the tick the way §6 defines it: AMPS wei per whole collateral unit.
    function _expectedM(int24 tick, uint8 decimals) internal pure returns (uint256) {
        uint256 sqrtPriceX96 = PriceLib.tickToSqrtPriceX96(tick);
        uint256 half = FullMath.mulDiv(10 ** decimals, 1 << 96, sqrtPriceX96);
        return FullMath.mulDiv(half, 1 << 96, sqrtPriceX96);
    }

    /// @dev The accretion floor, written out from §6.
    function _qFloor(uint256 priceUsd18, uint256 navUsd18, uint16 haircutBps, uint16 accretionBps)
        internal
        pure
        returns (uint256)
    {
        uint256 numerator = FullMath.mulDiv(priceUsd18, 10_000 - uint256(haircutBps), 10_000);
        uint256 denominator = FullMath.mulDivRoundingUp(navUsd18, 10_000 + uint256(accretionBps), 10_000);
        return FullMath.mulDiv(numerator, 1e18, denominator);
    }

    /// @dev Buys a bond as `who`.
    function _bond(address who, uint256 amountIn) internal returns (uint256 ampsOut, uint256 positionId) {
        vm.prank(who);
        return bonds.bond(marketId, amountIn, 0, who);
    }

    /// @dev The market's per-epoch capacity right now.
    function _epochCapacity() internal view returns (uint256) {
        return FullMath.mulDiv(amps.totalSupply(), bonds.market(marketId).capBpsPerEpoch, Constants.BPS);
    }
}

/// @notice Unit tests for the bond shell: wiring, the collateral registry, every governed setter and its band, the
///         `bond` call graph, capacity, vesting, and the structurally ungated `claim`.
contract AmpsBondsTest is BondsFixture {
    /* ------------------------------------------- wiring ------------------------------------------- */

    function test_constructorWiresPointersAndLaunchDefaults() public view {
        assertEq(bonds.vault(), address(vaultMock), "vault");
        assertEq(bonds.amps(), address(amps), "amps");
        assertEq(bonds.registry(), address(registry), "registry");
        assertEq(bonds.policy(), address(policy), "policy");

        assertEq(bonds.epochSeconds(), Constants.BOND_EPOCH_SECONDS_DEFAULT, "epochSeconds");
        assertEq(bonds.dailyCapBps(), Constants.BOND_DAILY_CAP_BPS_DEFAULT, "dailyCapBps");
        assertEq(bonds.vestSeconds(), Constants.BOND_VEST_SECONDS_DEFAULT, "vestSeconds");
        assertEq(bonds.minAccretionBps(), Constants.MIN_ACCRETION_BPS_DEFAULT, "minAccretionBps");
        assertEq(bonds.defaultKWeightX18(), Constants.BOND_K_WEIGHT_X18_DEFAULT, "k_w");
        assertEq(bonds.defaultKFillX18(), Constants.BOND_K_FILL_X18_DEFAULT, "k_c");
        assertEq(bonds.marketCount(), 2, "two markets");
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ZeroAddress.selector);
        new AmpsBonds(address(0), address(registry), address(policy));

        vm.expectRevert(ZeroAddress.selector);
        new AmpsBonds(address(vaultMock), address(0), address(policy));

        vm.expectRevert(ZeroAddress.selector);
        new AmpsBonds(address(vaultMock), address(registry), address(0));
    }

    /// @notice The packed storage layout of `docs/phase2-state-model.md` §1.2, slot by slot and bit by bit. The
    ///         bytecode is immutable, so a reordered field is a migration, not a patch.
    function test_storageLayoutMatchesTheStateModel() public {
        // Move every field off its default first, so a mis-packed neighbour cannot hide behind a zero.
        vm.startPrank(timelock);
        bonds.setEpochSeconds(2 hours);
        bonds.setDailyCapBps(321);
        bonds.setVestSeconds(3 hours);
        bonds.setMinAccretionBps(123);
        bonds.setCoefficients(0, 1.5e18, 0.75e18);
        vm.stopPrank();
        _bond(alice, 0.01e18);

        uint256 slot0 = uint256(vm.load(address(bonds), bytes32(uint256(0))));
        assertEq(address(uint160(slot0)), address(vaultMock), "slot 0 [0..159] vault");
        assertEq(uint32(slot0 >> 160), 2 hours, "slot 0 [160..191] epochSeconds");
        assertEq(uint16(slot0 >> 192), 321, "slot 0 [192..207] dailyCapBps");
        assertEq(uint32(slot0 >> 208), 3 hours, "slot 0 [208..239] vestSeconds");
        assertEq(uint16(slot0 >> 240), 123, "slot 0 [240..255] minAccretionBps");

        uint256 slot1 = uint256(vm.load(address(bonds), bytes32(uint256(1))));
        assertEq(address(uint160(slot1)), address(policy), "slot 1 [0..159] policy");
        assertEq(uint16(slot1 >> 160), 2, "slot 1 [160..175] marketCount");
        assertEq(uint64(slot1 >> 176), 1.5e18, "slot 1 [176..239] defaultKWeightX18");

        uint256 slot2 = uint256(vm.load(address(bonds), bytes32(uint256(2))));
        assertEq(address(uint160(slot2)), address(registry), "slot 2 [0..159] registry");
        assertEq(uint64(slot2 >> 160), 0.75e18, "slot 2 [160..223] defaultKFillX18");

        uint256 slot3 = uint256(vm.load(address(bonds), bytes32(uint256(3))));
        (uint256 dailyIssued,) = bonds.dailyIssuance();
        assertEq(uint128(slot3), dailyIssued, "slot 3 [0..127] dailyIssued");
        assertEq(uint32(slot3 >> 128), uint32(block.timestamp), "slot 3 [128..159] dailyWindowStart");

        // The three mappings live where §1.2 says, which is what the `claim` access proof depends on.
        assertEq(
            uint256(vm.load(address(bonds), keccak256(abi.encode(uint256(marketId), uint256(4))))) & type(uint160).max,
            uint256(uint160(address(stock))),
            "slot 4 markets"
        );
        assertEq(
            uint256(vm.load(address(bonds), keccak256(abi.encode(address(stock), uint256(5))))),
            marketId,
            "slot 5 marketIdOf"
        );
        assertEq(
            uint256(vm.load(address(bonds), keccak256(abi.encode(alice, uint256(6))))),
            1,
            "slot 6 positions (array length)"
        );
    }

    function test_bandGettersReadConstants() public view {
        assertEq(bonds.DISCOUNT_BPS_MIN(), Constants.DISCOUNT_BPS_MIN);
        assertEq(bonds.DISCOUNT_BPS_MAX(), Constants.DISCOUNT_BPS_MAX);
        assertEq(bonds.CAP_BPS_PER_EPOCH_MAX(), Constants.BOND_CAP_BPS_PER_EPOCH_MAX);
        assertEq(bonds.DAILY_CAP_BPS_MAX(), Constants.BOND_DAILY_CAP_BPS_MAX);
        assertEq(bonds.EPOCH_SECONDS_MIN(), Constants.BOND_EPOCH_SECONDS_MIN);
        assertEq(bonds.EPOCH_SECONDS_MAX(), Constants.BOND_EPOCH_SECONDS_MAX);
        assertEq(bonds.VEST_SECONDS_MIN(), Constants.BOND_VEST_SECONDS_MIN);
        assertEq(bonds.VEST_SECONDS_MAX(), Constants.BOND_VEST_SECONDS_MAX);
        assertEq(bonds.H_SESSION_BPS_MAX(), Constants.H_SESSION_BPS_MAX);
        assertEq(bonds.MIN_ACCRETION_BPS_MAX(), Constants.MIN_ACCRETION_BPS_MAX);
        assertEq(bonds.COEFFICIENT_X18_MAX(), Constants.BOND_COEFFICIENT_X18_MAX);
        assertEq(bonds.MAX_COLLATERALS(), Constants.MAX_COLLATERALS);
    }

    /// @dev `oracleGate()` and `hSessionBps()` are pass-throughs, never cached copies: re-pointing the gate on the
    ///      vault moves both immediately, which is the property that keeps one pointer to re-point.
    function test_gateAndHaircutArePassThroughs() public {
        assertEq(bonds.oracleGate(), address(gate));
        assertEq(bonds.hSessionBps(Session.CLOSED), Constants.H_SESSION_CLOSED_BPS_DEFAULT);

        gate.setHSessionBps(Session.CLOSED, 777);
        assertEq(bonds.hSessionBps(Session.CLOSED), 777, "the table lives in the gate");

        MockOracleGate replacement = new MockOracleGate();
        vaultMock.setPointers(address(replacement), address(feeds), address(registry), address(marketRef));
        assertEq(bonds.oracleGate(), address(replacement), "the pointer follows the vault");
        assertEq(bonds.hSessionBps(Session.CLOSED), Constants.H_SESSION_CLOSED_BPS_DEFAULT, "and so does the table");
    }

    /* ------------------------------------ the collateral registry ------------------------------------ */

    function test_addCollateralIsTimelockOnly() public {
        MockStockToken other = new MockStockToken("Other", "OTH");
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, address(this)));
        bonds.addCollateral(address(other), CollateralClass.CONSTITUENT, 1250, 1000, 1500, 50, true);

        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, alice));
        vm.prank(alice);
        bonds.addCollateral(address(other), CollateralClass.CONSTITUENT, 1250, 1000, 1500, 50, true);
    }

    /// @notice The registry may add a collateral inside its own 7-day `addConstituent` operation, at the launch
    ///         defaults, so that a new spoke gets its market atomically (state model §3).
    function test_addCollateralAcceptsTheRegistryAtLaunchDefaults() public {
        MockStockToken other = new MockStockToken("Other", "OTH");
        uint16 otherId = registry.addConstituentAndPool(
            address(other), address(0xFEED), PoolId.wrap(keccak256("AMPS/OTH")), PoolClass.SPOKE, 60, 500
        );

        vm.prank(address(registry));
        uint16 newMarketId = bonds.addCollateral(
            address(other),
            CollateralClass.CONSTITUENT,
            Constants.BOND_D_BASE_BPS_DEFAULT,
            Constants.BOND_D_MIN_BPS_DEFAULT,
            Constants.BOND_D_MAX_BPS_DEFAULT,
            Constants.BOND_CAP_BPS_PER_EPOCH_DEFAULT,
            true
        );

        BondMarket memory record = bonds.market(newMarketId);
        assertEq(record.collateral, address(other));
        assertEq(record.constituentId, otherId);
        assertEq(record.dBaseBps, Constants.BOND_D_BASE_BPS_DEFAULT);
        assertEq(record.capBpsPerEpoch, Constants.BOND_CAP_BPS_PER_EPOCH_DEFAULT);
        assertTrue(record.open);

        // The registry is a governance caller, not an exemption: every band still applies to it.
        MockStockToken third = new MockStockToken("Third", "THR");
        registry.addConstituentAndPool(
            address(third), address(0xFEED), PoolId.wrap(keccak256("AMPS/THR")), PoolClass.SPOKE, 60, 500
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("dBaseBps"), 100, Constants.DISCOUNT_BPS_MIN, Constants.DISCOUNT_BPS_MAX
            )
        );
        vm.prank(address(registry));
        bonds.addCollateral(address(third), CollateralClass.CONSTITUENT, 100, 1000, 1500, 50, true);
    }

    function test_addCollateralStoresTheRecordAndEmits() public {
        MockStockToken other = new MockStockToken("Other", "OTH");
        uint16 otherId = registry.addConstituentAndPool(
            address(other), address(0xFEED), PoolId.wrap(keccak256("AMPS/OTH")), PoolClass.SPOKE, 60, 500
        );

        vm.expectEmit(true, true, false, true, address(bonds));
        emit IAmpsBonds.CollateralAdded(3, address(other), CollateralClass.CONSTITUENT, otherId);
        vm.prank(timelock);
        uint16 newMarketId =
            bonds.addCollateral(address(other), CollateralClass.CONSTITUENT, 1250, 1000, 1500, 50, true);

        BondMarket memory record = bonds.market(newMarketId);
        assertEq(newMarketId, 3, "ids are sequential and never reused");
        assertEq(record.collateral, address(other));
        assertEq(uint8(record.class), uint8(CollateralClass.CONSTITUENT));
        assertTrue(record.open);
        assertEq(record.decimals, 18);
        assertEq(record.constituentId, otherId);
        assertEq(record.dBaseBps, 1250);
        assertEq(record.capBpsPerEpoch, 50);
        assertEq(record.kWeightX18, 0, "no override: the market inherits the global default");
        assertEq(record.epochStart, uint32(block.timestamp));
        assertEq(bonds.marketIdOf(address(other)), newMarketId);
    }

    function test_addCollateralRejectsDuplicates() public {
        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.CollateralExists.selector, address(stock), marketId));
        vm.prank(timelock);
        bonds.addCollateral(address(stock), CollateralClass.CONSTITUENT, 1250, 1000, 1500, 50, true);
    }

    function test_addCollateralRequiresAnActiveConstituent() public {
        MockStockToken stranger = new MockStockToken("Stranger", "STR");
        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.NotAConstituent.selector, address(stranger)));
        vm.prank(timelock);
        bonds.addCollateral(address(stranger), CollateralClass.CONSTITUENT, 1250, 1000, 1500, 50, true);

        // A registered but retired name is not bondable either.
        MockStockToken retired = new MockStockToken("Retired", "RET");
        uint16 retiredId = registry.addConstituentAndPool(
            address(retired), address(0xFEED), PoolId.wrap(keccak256("AMPS/RET")), PoolClass.SPOKE, 60, 500
        );
        registry.setStatus(retiredId, ConstituentStatus.RETIRED);

        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.NotAConstituent.selector, address(retired)));
        vm.prank(timelock);
        bonds.addCollateral(address(retired), CollateralClass.CONSTITUENT, 1250, 1000, 1500, 50, true);
    }

    function test_addCollateralEntryClassRequiresAnEntryPool() public {
        MockUsdg stranger = new MockUsdg("Stranger", "STR", 6);
        vm.expectRevert(abi.encodeWithSelector(AmpsBonds.NotAnEntryCollateral.selector, address(stranger)));
        vm.prank(timelock);
        bonds.addCollateral(address(stranger), CollateralClass.ENTRY, 1250, 1000, 1500, 50, false);
    }

    function test_addCollateralEnforcesEveryBand() public {
        MockStockToken other = new MockStockToken("Other", "OTH");
        registry.addConstituentAndPool(
            address(other), address(0xFEED), PoolId.wrap(keccak256("AMPS/OTH")), PoolClass.SPOKE, 60, 500
        );

        vm.startPrank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("dBaseBps"), 499, Constants.DISCOUNT_BPS_MIN, Constants.DISCOUNT_BPS_MAX
            )
        );
        bonds.addCollateral(address(other), CollateralClass.CONSTITUENT, 499, 1000, 1500, 50, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("dMaxBps"), 2501, Constants.DISCOUNT_BPS_MIN, Constants.DISCOUNT_BPS_MAX
            )
        );
        bonds.addCollateral(address(other), CollateralClass.CONSTITUENT, 1250, 1000, 2501, 50, true);

        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("dMinBps"), 1600, Constants.DISCOUNT_BPS_MIN, 1500)
        );
        bonds.addCollateral(address(other), CollateralClass.CONSTITUENT, 1250, 1600, 1500, 50, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("capBpsPerEpoch"), 201, 0, Constants.BOND_CAP_BPS_PER_EPOCH_MAX
            )
        );
        bonds.addCollateral(address(other), CollateralClass.CONSTITUENT, 1250, 1000, 1500, 201, true);
        vm.stopPrank();
    }

    function test_addCollateralStopsAtTheCollateralSetCeiling() public {
        // Fast-forward `marketCount` to the ceiling: slot 1 packs `policy | marketCount | defaultKWeightX18`.
        bytes32 slot1 = vm.load(address(bonds), bytes32(uint256(1)));
        uint256 cleared = uint256(slot1) & ~(uint256(0xFFFF) << 160);
        vm.store(address(bonds), bytes32(uint256(1)), bytes32(cleared | (uint256(Constants.MAX_COLLATERALS) << 160)));
        assertEq(bonds.marketCount(), Constants.MAX_COLLATERALS);

        MockStockToken other = new MockStockToken("Other", "OTH");
        registry.addConstituentAndPool(
            address(other), address(0xFEED), PoolId.wrap(keccak256("AMPS/OTH")), PoolClass.SPOKE, 60, 500
        );
        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.CollateralSetFull.selector, Constants.MAX_COLLATERALS));
        vm.prank(timelock);
        bonds.addCollateral(address(other), CollateralClass.CONSTITUENT, 1250, 1000, 1500, 50, true);
    }

    /// @notice The collateral add/remove drill: removal stops new bonds and nothing else. Every vesting position on
    ///         the market claims to completion (I38).
    function test_removeCollateralStopsNewBondsButNeverClaims() public {
        (uint256 ampsOut, uint256 positionId) = _bond(alice, 0.05e18);
        assertGt(ampsOut, 0);

        vm.expectEmit(true, true, false, true, address(bonds));
        emit IAmpsBonds.CollateralRemoved(marketId, address(stock));
        vm.prank(timelock);
        bonds.removeCollateral(address(stock));

        assertEq(bonds.marketIdOf(address(stock)), 0, "the collateral is no longer registered");
        assertFalse(bonds.market(marketId).open, "and the market is closed");

        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.MarketClosed.selector, marketId));
        vm.prank(alice);
        bonds.bond(marketId, 0.05e18, 0, alice);

        // The vest still completes, in full.
        vm.warp(block.timestamp + bonds.vestSeconds());
        vm.prank(alice);
        uint256 claimed = bonds.claim(positionId, alice);
        assertEq(claimed, ampsOut, "a removed collateral never strands a vest");
        assertEq(amps.balanceOf(alice), ampsOut);
    }

    function test_removeCollateralIsTimelockOnlyAndRejectsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, address(this)));
        bonds.removeCollateral(address(stock));

        vm.expectRevert(abi.encodeWithSelector(UnknownMarket.selector, 0));
        vm.prank(timelock);
        bonds.removeCollateral(address(0xDEAD));
    }

    /// @dev A removed market must not be re-openable by the 48-hour setter: re-listing it is a 7-day `addCollateral`.
    function test_removedMarketCannotBeReopened() public {
        vm.startPrank(timelock);
        bonds.removeCollateral(address(stock));
        vm.expectRevert(abi.encodeWithSelector(UnknownMarket.selector, marketId));
        bonds.setMarketOpen(marketId, true);
        vm.stopPrank();
    }

    /* --------------------------------------- governed setters --------------------------------------- */

    /// @dev The registry may close a market so that `retireConstituent` is atomic (I37); nobody else but the
    ///      timelock may touch it.
    function test_setMarketOpenAcceptsTimelockAndRegistryOnly() public {
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, alice));
        vm.prank(alice);
        bonds.setMarketOpen(marketId, false);

        vm.prank(address(registry));
        bonds.setMarketOpen(marketId, false);
        assertFalse(bonds.market(marketId).open);

        vm.prank(timelock);
        bonds.setMarketOpen(marketId, true);
        assertTrue(bonds.market(marketId).open);
    }

    function test_setDiscountParams() public {
        vm.expectEmit(true, true, false, true, address(bonds));
        emit IAmpsBonds.BondParameterChanged(marketId, "dBaseBps", Constants.BOND_D_BASE_BPS_DEFAULT, 2000);
        vm.prank(timelock);
        bonds.setDiscountParams(marketId, 2000, 1500, 2500);

        BondMarket memory record = bonds.market(marketId);
        assertEq(record.dBaseBps, 2000);
        assertEq(record.dMinBps, 1500);
        assertEq(record.dMaxBps, 2500);
    }

    function test_setCoefficientsGlobalDefaultAndPerMarketOverride() public {
        vm.startPrank(timelock);
        bonds.setCoefficients(0, 1e18, 0.75e18);
        assertEq(bonds.defaultKWeightX18(), 1e18);
        assertEq(bonds.defaultKFillX18(), 0.75e18);
        assertEq(bonds.market(marketId).kWeightX18, 0, "market 1 still inherits");

        bonds.setCoefficients(marketId, 0.1e18, 0.2e18);
        assertEq(bonds.market(marketId).kWeightX18, 0.1e18);
        assertEq(bonds.market(marketId).kFillX18, 0.2e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("kWeightX18"),
                uint256(Constants.BOND_COEFFICIENT_X18_MAX) + 1,
                0,
                Constants.BOND_COEFFICIENT_X18_MAX
            )
        );
        bonds.setCoefficients(marketId, uint64(Constants.BOND_COEFFICIENT_X18_MAX) + 1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("kFillX18"),
                uint256(Constants.BOND_COEFFICIENT_X18_MAX) + 1,
                0,
                Constants.BOND_COEFFICIENT_X18_MAX
            )
        );
        bonds.setCoefficients(marketId, 0, uint64(Constants.BOND_COEFFICIENT_X18_MAX) + 1);
        vm.stopPrank();
    }

    function test_globalSettersEnforceTheirBands() public {
        vm.startPrank(timelock);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("epochSeconds"),
                Constants.BOND_EPOCH_SECONDS_MIN - 1,
                Constants.BOND_EPOCH_SECONDS_MIN,
                Constants.BOND_EPOCH_SECONDS_MAX
            )
        );
        bonds.setEpochSeconds(Constants.BOND_EPOCH_SECONDS_MIN - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("epochSeconds"),
                Constants.BOND_EPOCH_SECONDS_MAX + 1,
                Constants.BOND_EPOCH_SECONDS_MIN,
                Constants.BOND_EPOCH_SECONDS_MAX
            )
        );
        bonds.setEpochSeconds(Constants.BOND_EPOCH_SECONDS_MAX + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("dailyCapBps"),
                Constants.BOND_DAILY_CAP_BPS_MAX + 1,
                0,
                Constants.BOND_DAILY_CAP_BPS_MAX
            )
        );
        bonds.setDailyCapBps(Constants.BOND_DAILY_CAP_BPS_MAX + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("vestSeconds"),
                Constants.BOND_VEST_SECONDS_MAX + 1,
                Constants.BOND_VEST_SECONDS_MIN,
                Constants.BOND_VEST_SECONDS_MAX
            )
        );
        bonds.setVestSeconds(Constants.BOND_VEST_SECONDS_MAX + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("minAccretionBps"),
                Constants.MIN_ACCRETION_BPS_MAX + 1,
                0,
                Constants.MIN_ACCRETION_BPS_MAX
            )
        );
        bonds.setMinAccretionBps(Constants.MIN_ACCRETION_BPS_MAX + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("capBpsPerEpoch"),
                Constants.BOND_CAP_BPS_PER_EPOCH_MAX + 1,
                0,
                Constants.BOND_CAP_BPS_PER_EPOCH_MAX
            )
        );
        bonds.setCapBpsPerEpoch(marketId, Constants.BOND_CAP_BPS_PER_EPOCH_MAX + 1);

        // The in-band values all stick.
        bonds.setEpochSeconds(Constants.BOND_EPOCH_SECONDS_MIN);
        bonds.setDailyCapBps(Constants.BOND_DAILY_CAP_BPS_MAX);
        bonds.setVestSeconds(Constants.BOND_VEST_SECONDS_MAX);
        bonds.setMinAccretionBps(Constants.MIN_ACCRETION_BPS_MAX);
        bonds.setCapBpsPerEpoch(marketId, Constants.BOND_CAP_BPS_PER_EPOCH_MAX);
        vm.stopPrank();

        assertEq(bonds.epochSeconds(), Constants.BOND_EPOCH_SECONDS_MIN);
        assertEq(bonds.dailyCapBps(), Constants.BOND_DAILY_CAP_BPS_MAX);
        assertEq(bonds.vestSeconds(), Constants.BOND_VEST_SECONDS_MAX);
        assertEq(bonds.minAccretionBps(), Constants.MIN_ACCRETION_BPS_MAX);
        assertEq(bonds.market(marketId).capBpsPerEpoch, Constants.BOND_CAP_BPS_PER_EPOCH_MAX);
    }

    /// @notice I38, first clause: every bond variable is settable only through the timelock.
    function test_everyGovernedSetterIsTimelockOnly() public {
        vm.startPrank(alice);
        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeCall(IAmpsBonds.setDiscountParams, (marketId, 1250, 1000, 1500));
        calls[1] = abi.encodeCall(IAmpsBonds.setCoefficients, (marketId, 1e18, 1e18));
        calls[2] = abi.encodeCall(IAmpsBonds.setCapBpsPerEpoch, (marketId, 100));
        calls[3] = abi.encodeCall(IAmpsBonds.setEpochSeconds, (7200));
        calls[4] = abi.encodeCall(IAmpsBonds.setDailyCapBps, (300));
        calls[5] = abi.encodeCall(IAmpsBonds.setVestSeconds, (7200));
        calls[6] = abi.encodeCall(IAmpsBonds.setMinAccretionBps, (100));
        calls[7] = abi.encodeCall(IAmpsBonds.setPolicy, (address(policy)));

        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory data) = address(bonds).call(calls[i]);
            assertFalse(ok, "a non-timelock caller must be refused");
            assertEq(bytes4(data), NotTimelock.selector, "and refused for the right reason");
        }
        vm.stopPrank();
    }

    function test_setPolicyAndSetVaultAccessControl() public {
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, address(this)));
        bonds.setPolicy(address(policy));

        vm.expectRevert(ZeroAddress.selector);
        vm.prank(timelock);
        bonds.setPolicy(address(0));

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, timelock));
        vm.prank(timelock);
        bonds.setVault(address(0xBEEF));

        vm.expectEmit(true, true, false, false, address(bonds));
        emit IAmpsBonds.VaultChanged(address(vaultMock), address(0xBEEF));
        vm.prank(address(vaultMock));
        bonds.setVault(address(0xBEEF));
        assertEq(bonds.vault(), address(0xBEEF));
    }

    /* ----------------------------------------- bond pricing ----------------------------------------- */

    /// @notice The happy path, priced at the accretion floor because AMPS trades at NAV.
    function test_bondAtTheFloor() public {
        uint256 amountIn = 0.05e18;
        uint256 expectedFloor = _qFloor(STOCK_PRICE_USD8 * 1e10, NAV_X18, 0, Constants.MIN_ACCRETION_BPS_DEFAULT);
        uint256 expectedOut = FullMath.mulDiv(amountIn, expectedFloor, 1e18);

        vm.expectEmit(true, true, true, true, address(bonds));
        emit IAmpsBonds.Bond(alice, marketId, address(stock), amountIn, expectedOut, 0, expectedFloor, 1250, true);
        (uint256 ampsOut, uint256 positionId) = _bond(alice, amountIn);

        assertEq(ampsOut, expectedOut, "priced at the floor");
        assertEq(positionId, 0);
        assertEq(amps.balanceOf(address(bonds)), ampsOut, "vesting AMPS is held by the shell");
        assertEq(amps.totalSupply(), GENESIS_SUPPLY + ampsOut, "and is in totalSupply at once (I30)");
        assertEq(stock.balanceOf(address(bonds)), 0, "sweepClean (I12)");
        assertEq(stock.balanceOf(address(vaultMock)), amountIn, "custody sits with the vault");
        assertEq(vaultMock.bondedBalance(address(stock)), amountIn);

        VestingPosition memory record = bonds.position(alice, positionId);
        assertEq(record.principal, ampsOut);
        assertEq(record.claimed, 0);
        assertEq(record.start, uint32(block.timestamp));
        assertEq(record.vestSeconds, Constants.BOND_VEST_SECONDS_DEFAULT);
        assertEq(record.marketId, marketId);
    }

    /// @notice Above the crossover premium the market discount binds and the protocol captures the premium.
    function test_bondAtTheDiscountWhenThePremiumExceedsIt() public {
        _setSpokePriceUsd18(1.3e18); // AMPS at $1.30: a 30% premium

        int24 tick = _tickFor(1.3e18, STOCK_PRICE_USD8, 18);
        uint256 expectedM = _expectedM(tick, 18);
        uint256 expectedQMarket = FullMath.mulDiv(expectedM, 10_000, 10_000 - 1250);
        uint256 floorX18 = _qFloor(STOCK_PRICE_USD8 * 1e10, NAV_X18, 0, Constants.MIN_ACCRETION_BPS_DEFAULT);
        assertLt(expectedQMarket, floorX18, "the discount is the binding price at a 30% premium");

        (uint256 ampsOut,) = _bond(alice, 0.05e18);
        assertEq(ampsOut, FullMath.mulDiv(0.05e18, expectedQMarket, 1e18), "priced at m/(1 - d)");

        // The independent cross-check: `m` really is AMPS per stock at the quoted prices.
        assertApproxEqRel(expectedM, FullMath.mulDiv(180e18, 1e18, 1.3e18), 2e14, "m within a tick of the exact ratio");
    }

    /// @notice Decision 10: a closed session and a stale answer widen the haircut, they never close the market.
    function test_bondSucceedsThroughAClosedSessionAndAStaleFeed() public {
        gate.setSession(Session.CLOSED);
        feeds.setFresh(address(stock), false);

        uint256 haircut = Constants.H_SESSION_CLOSED_BPS_DEFAULT;
        uint256 expectedFloor =
            _qFloor(STOCK_PRICE_USD8 * 1e10, NAV_X18, uint16(haircut), Constants.MIN_ACCRETION_BPS_DEFAULT);

        (uint256 ampsOut,) = _bond(alice, 0.05e18);
        assertEq(ampsOut, FullMath.mulDiv(0.05e18, expectedFloor, 1e18), "priced at the haircut floor");

        // The same bond in the Regular session buys strictly more: the haircut is the whole weekend-gap bound.
        gate.setSession(Session.REGULAR);
        (uint256 regularOut,) = _bond(bob, 0.05e18);
        assertGt(regularOut, ampsOut, "the closed-session haircut costs the bonder 300 bp");
    }

    /// @notice The pricing table end to end: premium x session x feed freshness, always `q <= qFloor`.
    function test_pricingTableThroughTheShell() public {
        int256[5] memory premiumsBps = [-int256(500), int256(0), int256(500), int256(1250), int256(3000)];
        Session[4] memory sessions = [Session.REGULAR, Session.PRE_POST, Session.OVERNIGHT, Session.CLOSED];

        for (uint256 s; s < sessions.length; ++s) {
            gate.setSession(sessions[s]);
            uint16 haircut = gate.hSessionBps(sessions[s]);

            for (uint256 p; p < premiumsBps.length; ++p) {
                for (uint256 f; f < 2; ++f) {
                    feeds.setFresh(address(stock), f == 0);
                    uint256 ampsPrice = uint256(int256(NAV_X18) + int256(NAV_X18) * premiumsBps[p] / 10_000);
                    _setSpokePriceUsd18(ampsPrice);

                    (uint256 ampsOut, uint256 qX18,, bool floorBinding,, bytes32 reason) =
                        bonds.quote(marketId, 0.01e18);
                    assertEq(reason, bytes32(0), "the market is open in every cell of the table");

                    uint256 floorX18 =
                        _qFloor(STOCK_PRICE_USD8 * 1e10, NAV_X18, haircut, Constants.MIN_ACCRETION_BPS_DEFAULT);
                    assertLe(qX18, floorX18, "q <= qFloor (I27)");
                    assertEq(floorBinding, qX18 == floorX18, "floorBinding");

                    // The discount only bites above the crossover premium.
                    uint256 crossoverBps = (10_000 + uint256(Constants.MIN_ACCRETION_BPS_DEFAULT)) * 10_000 * 10_000
                        / ((10_000 - 1250) * (10_000 - uint256(haircut))) - 10_000;
                    if (premiumsBps[p] > 0 && uint256(premiumsBps[p]) > crossoverBps + 20) {
                        assertFalse(floorBinding, "above the crossover the discount binds");
                    } else if (premiumsBps[p] < int256(crossoverBps)) {
                        assertTrue(floorBinding, "below the crossover the floor binds");
                    }

                    // I27's second clause, on the amount actually issued.
                    assertLe(
                        FullMath.mulDiv(
                            ampsOut, NAV_X18 * (10_000 + uint256(Constants.MIN_ACCRETION_BPS_DEFAULT)), 10_000
                        ),
                        FullMath.mulDiv(0.01e18, STOCK_PRICE_USD8 * 1e10 * (10_000 - uint256(haircut)), 10_000),
                        "the bond is accretive"
                    );
                }
            }
        }
    }

    /// @notice The deficit term: an under-weight name earns a wider discount, and a registry that cannot report a
    ///         realised weight simply prices at `deficit == 0`.
    function test_deficitWidensTheDiscountOnlyWhenTheRegistryReportsAWeight() public {
        _setSpokePriceUsd18(1.5e18); // a premium large enough that the discount, not the floor, is binding

        (,, uint16 baseDiscount,,,) = bonds.quote(marketId, 0.01e18);
        assertEq(baseDiscount, 1250, "at the target weight: no deficit");

        // Half its target weight: +250 bp before the clamp to dMax = 1500.
        registry.setCurrentWeightBps(constituentId, TARGET_WEIGHT_BPS / 2);
        (,, uint16 halfWeightDiscount,,,) = bonds.quote(marketId, 0.01e18);
        assertEq(halfWeightDiscount, 1250 + 250, "k_w x 0.5 = 250 bp");

        // At or above the target weight there is no deficit at all.
        registry.setCurrentWeightBps(constituentId, TARGET_WEIGHT_BPS);
        (,, uint16 atTargetDiscount,,,) = bonds.quote(marketId, 0.01e18);
        assertEq(atTargetDiscount, 1250);

        // A name with no realised weight at all is maximally under-weight: +500 bp, clamped to dMax.
        registry.setCurrentWeightBps(constituentId, 0);
        (,, uint16 zeroWeightDiscount,,,) = bonds.quote(marketId, 0.01e18);
        assertEq(zeroWeightDiscount, Constants.BOND_D_MAX_BPS_DEFAULT, "k_w x 1.0 = 500 bp, clamped to dMax");

        // A registry that refuses to answer is read as "unknown", never as a zero weight.
        registry.setWeightSourceEnabled(false);
        (,, uint16 unknownDiscount,,,) = bonds.quote(marketId, 0.01e18);
        assertEq(unknownDiscount, 1250, "an unavailable weight source cannot widen the discount");
    }

    /// @notice The fill term: as the epoch fills, the discount decays toward dMin.
    function test_fillNarrowsTheDiscount() public {
        _setSpokePriceUsd18(1.5e18);
        vm.prank(timelock);
        bonds.setCoefficients(marketId, 1, 1e18); // k_c = 1.0: a full epoch removes 1,000 bp

        (,, uint16 emptyEpoch,,,) = bonds.quote(marketId, 0.01e18);
        assertEq(emptyEpoch, 1250, "an empty epoch pays the base discount");

        // Fill roughly half the epoch's capacity and re-quote.
        uint256 capacity = _epochCapacity();
        while (bonds.market(marketId).issuedThisEpoch < capacity / 2) {
            _bond(alice, 0.02e18);
        }
        (,, uint16 halfFull,,,) = bonds.quote(marketId, 0.01e18);
        assertLt(halfFull, emptyEpoch, "a filling epoch narrows the discount");
        assertGe(halfFull, Constants.BOND_D_MIN_BPS_DEFAULT, "never below dMin");
    }

    /* ------------------------------------------- refusals ------------------------------------------- */

    function test_bondRefusedByTheGate() public {
        gate.setCorporateFreeze(constituentId, true);
        vm.expectPartialRevert(bytes4(keccak256("ConstituentFrozen(uint16,uint32)")));
        vm.prank(alice);
        bonds.bond(marketId, 0.05e18, 0, alice);

        gate.setCorporateFreeze(constituentId, false);
        gate.freezeProtocol(uint32(block.timestamp + 1 days));
        vm.expectPartialRevert(bytes4(keccak256("GateRefused(uint8,bytes32)")));
        vm.prank(alice);
        bonds.bond(marketId, 0.05e18, 0, alice);
    }

    function test_bondRefusedWhenClosedOrUnknown() public {
        vm.prank(timelock);
        bonds.setMarketOpen(marketId, false);
        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.MarketClosed.selector, marketId));
        vm.prank(alice);
        bonds.bond(marketId, 0.05e18, 0, alice);

        vm.expectRevert(abi.encodeWithSelector(UnknownMarket.selector, uint16(99)));
        vm.prank(alice);
        bonds.bond(99, 0.05e18, 0, alice);

        // The `ENTRY` class ships closed.
        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.MarketClosed.selector, entryMarketId));
        vm.prank(alice);
        bonds.bond(entryMarketId, 1e6, 0, alice);
    }

    function test_bondRejectsZeroInputs() public {
        vm.startPrank(alice);
        vm.expectRevert(ZeroAmount.selector);
        bonds.bond(marketId, 0, 0, alice);

        vm.expectRevert(ZeroAddress.selector);
        bonds.bond(marketId, 0.05e18, 0, address(0));
        vm.stopPrank();
    }

    function test_bondRefusesAStaleCheckpoint() public {
        vm.warp(block.timestamp + Constants.CHECKPOINT_MAX_AGE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaleCheckpoint.selector, Constants.CHECKPOINT_MAX_AGE + 1, Constants.CHECKPOINT_MAX_AGE
            )
        );
        vm.prank(alice);
        bonds.bond(marketId, 0.05e18, 0, alice);

        vaultMock.touchCheckpoint();
        (uint256 ampsOut,) = _bond(alice, 0.05e18);
        assertGt(ampsOut, 0, "a fresh checkpoint reopens the market");
    }

    function test_bondEnforcesMinAmpsOut() public {
        (uint256 expected,,,,,) = bonds.quote(marketId, 0.05e18);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, expected, expected + 1));
        vm.prank(alice);
        bonds.bond(marketId, 0.05e18, expected + 1, alice);
    }

    function test_bondRefusesWhenTheFeedHasNoAnswerAtAll() public {
        feeds.clearAnswer(address(stock));
        vm.expectRevert(abi.encodeWithSelector(IBondPolicy.InvalidQuoteInput.selector, bytes32("collateralPriceUsd18")));
        vm.prank(alice);
        bonds.bond(marketId, 0.05e18, 0, alice);
    }

    /// @notice The transient lock: a collateral that calls back into `bond` mid-transfer is refused, which is the
    ///         shape of every "reentrant Stock Token" case in the plan's attack list.
    function test_reentrantCollateralIsRefused() public {
        stock.setReentrancy(1, address(bonds), abi.encodeCall(IAmpsBonds.bond, (marketId, 1e15, 0, alice)));

        vm.expectRevert(Reentrancy.selector);
        vm.prank(alice);
        bonds.bond(marketId, 0.05e18, 0, alice);
    }

    /// @notice A collateral with more than 18 decimals cannot be normalised, and is refused at registration.
    function test_addCollateralRejectsOversizedDecimals() public {
        MockUsdg weird = new MockUsdg("Weird", "WRD", 24);
        registry.addEntryPool(wethPool, address(weird), 24, 60, Constants.BUY_FEE_BPS_ENTRY_DEFAULT);

        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("collateralDecimals"), 24, 0, 18));
        vm.prank(timelock);
        bonds.addCollateral(address(weird), CollateralClass.ENTRY, 1250, 1000, 1500, 50, false);
    }

    /// @notice The `dMinBps` band, which the clamp check alone does not reach.
    function test_addCollateralRejectsAnOutOfBandFloor() public {
        MockStockToken other = new MockStockToken("Other", "OTH");
        registry.addConstituentAndPool(
            address(other), address(0xFEED), PoolId.wrap(keccak256("AMPS/OTH")), PoolClass.SPOKE, 60, 500
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("dMinBps"), 499, Constants.DISCOUNT_BPS_MIN, Constants.DISCOUNT_BPS_MAX
            )
        );
        vm.prank(timelock);
        bonds.addCollateral(address(other), CollateralClass.CONSTITUENT, 1250, 499, 1500, 50, true);
    }

    /// @notice Every remaining degraded read the quote view has to survive, each reported rather than thrown.
    function test_quoteReportsEveryDegradedRead() public {
        // A policy above the floor: the view says so instead of quoting a dilutive bond.
        address hostile = address(new HostilePolicy());
        vm.prank(timelock);
        bonds.setPolicy(hostile);
        (uint256 ampsOut,,,,, bytes32 reason) = bonds.quote(marketId, 0.05e18);
        assertEq(ampsOut, 0);
        assertEq(reason, bytes32("floorViolated"));
        vm.prank(timelock);
        bonds.setPolicy(address(policy));

        // A vault with no NAV at all.
        vaultMock.setCheckpoint(0, 0, 0, uint32(block.timestamp));
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("noNav"));
        vaultMock.setCheckpoint(uint128(NAV_X18), uint128(NAV_X18), uint128(NAV_X18), uint32(block.timestamp));

        // A pool price so extreme that one AMPS buys less than one raw unit of collateral: `m` floors to zero.
        marketRef.setObservation(spokePool, 500_000, 500_000, 1800);
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("noTwap"));
        _setSpokePriceUsd18(NAV_X18);

        // A registry that cannot resolve the spoke pool.
        vm.mockCallRevert(address(registry), abi.encodeWithSignature("poolIdOf(uint16)", constituentId), "");
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("noPool"));
        vm.clearMockedCalls();

        // A registry that cannot report the constituent: the deficit term degrades to zero, the quote stands.
        vm.mockCallRevert(address(registry), abi.encodeWithSignature("constituent(uint16)", constituentId), "");
        uint16 discount;
        (ampsOut,, discount,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32(0), "an unavailable weight source never closes a market");
        assertEq(discount, Constants.BOND_D_BASE_BPS_DEFAULT);
        assertGt(ampsOut, 0);
        vm.clearMockedCalls();

        // A vault whose checkpoint read is the thing that fails.
        vm.mockCallRevert(address(vaultMock), abi.encodeWithSignature("checkpointData()"), "");
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("vaultDown"));
        vm.clearMockedCalls();

        // A vault whose feed-registry or market-reference pointer is the thing that fails.
        vm.mockCallRevert(address(vaultMock), abi.encodeWithSignature("feedRegistry()"), "");
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("vaultDown"));
        vm.clearMockedCalls();

        vm.mockCallRevert(address(vaultMock), abi.encodeWithSignature("marketReference()"), "");
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("vaultDown"));
        vm.clearMockedCalls();

        // A vault that reports no gate at all is treated the same way.
        vm.mockCall(address(vaultMock), abi.encodeWithSignature("oracleGate()"), abi.encode(address(0)));
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("vaultDown"));
        vm.clearMockedCalls();

        // An entry pool whose config cannot be read at all.
        vm.prank(timelock);
        bonds.setMarketOpen(entryMarketId, true);
        vm.mockCallRevert(address(registry), abi.encodeWithSignature("poolConfig(bytes32)"), "");
        (,,,,, reason) = bonds.quote(entryMarketId, 1e6);
        assertEq(reason, bytes32("noPool"));
        vm.clearMockedCalls();
    }

    /// @notice The bond is priced on `amountIn`, so anything but an exact settlement is refused rather than
    ///         mispriced: fee-on-transfer collateral can never issue AMPS against a deposit that did not arrive.
    function test_bondRejectsAnInexactSettlement() public {
        vaultMock.setSettleShortfall(1);
        vm.expectRevert(abi.encodeWithSelector(AmpsBonds.DepositMismatch.selector, 0.05e18 - 1, 0.05e18));
        vm.prank(alice);
        bonds.bond(marketId, 0.05e18, 0, alice);
    }

    /// @notice An `ENTRY` market whose pool the registry no longer knows cannot be priced at all: the view says so
    ///         and the transaction refuses, rather than pricing off some other pool.
    function test_entryMarketWithoutItsPoolCannotBePriced() public {
        vm.prank(timelock);
        bonds.setMarketOpen(entryMarketId, true);
        registry.unregisterPool(hubPool);

        (uint256 ampsOut,,,,, bytes32 reason) = bonds.quote(entryMarketId, 1e6);
        assertEq(ampsOut, 0);
        assertEq(reason, bytes32("noPool"));

        vm.expectRevert(abi.encodeWithSelector(UnknownPool.selector, bytes32(0)));
        vm.prank(alice);
        bonds.bond(entryMarketId, 1e6, 0, alice);
    }

    /// @notice `claimAll` skips positions with nothing pending rather than reverting on them.
    function test_claimAllSkipsExhaustedPositions() public {
        (uint256 first, uint256 firstId) = _bond(alice, 0.02e18);
        vm.warp(block.timestamp + bonds.vestSeconds());
        vm.prank(alice);
        bonds.claim(firstId, alice);

        vaultMock.touchCheckpoint();
        (uint256 second,) = _bond(alice, 0.02e18);
        vm.warp(block.timestamp + bonds.vestSeconds());

        vm.prank(alice);
        assertEq(bonds.claimAll(alice), second, "the exhausted position contributes nothing");
        assertEq(amps.balanceOf(alice), first + second);
    }

    /// @notice The shell's own floor check: a policy that returns a `q` above the floor is rejected, not obeyed.
    function test_hostilePolicyCannotIssueADilutiveBond() public {
        HostilePolicy hostile = new HostilePolicy();
        vm.prank(timelock);
        bonds.setPolicy(address(hostile));

        vm.expectPartialRevert(IAmpsBonds.AccretionFloorViolated.selector);
        vm.prank(alice);
        bonds.bond(marketId, 0.05e18, 0, alice);
    }

    /// @notice A policy swap re-prices new bonds only; positions already vesting are untouched.
    function test_policySwapRepricesOnlyNewBonds() public {
        (uint256 firstOut, uint256 firstId) = _bond(alice, 0.05e18);

        HalfFloorPolicy half = new HalfFloorPolicy();
        vm.expectEmit(true, true, false, false, address(bonds));
        emit IAmpsBonds.PolicyChanged(address(policy), address(half));
        vm.prank(timelock);
        bonds.setPolicy(address(half));

        (uint256 secondOut,) = _bond(alice, 0.05e18);
        assertApproxEqAbs(secondOut, firstOut / 2, 1, "the new law prices the new bond");
        assertEq(bonds.position(alice, firstId).principal, firstOut, "the old position is untouched");

        vm.warp(block.timestamp + bonds.vestSeconds());
        vm.prank(alice);
        assertEq(bonds.claim(firstId, alice), firstOut, "and still claims in full");
    }

    /* ------------------------------------------- capacity ------------------------------------------- */

    function test_capacityClampsAndTheEpochRefills() public {
        uint256 capacity = _epochCapacity();
        assertEq(capacity, FullMath.mulDiv(GENESIS_SUPPLY, 50, 10_000), "50 bp of supply");
        assertEq(bonds.capacityRemaining(marketId), capacity);

        // One large bond takes the whole epoch: the output is clamped, not reverted.
        (uint256 ampsOut,) = _bond(alice, 1e18);
        assertEq(ampsOut, capacity, "clamped to the epoch capacity");
        // The cap is a fraction of the *live* supply, so issuing 25 AMPS lifts it by 50 bp of 25 AMPS. The daily
        // cap is what actually closes the market, and the epoch tally is what refills.
        assertEq(bonds.capacityRemaining(marketId), _epochCapacity() - ampsOut, "the epoch is spent");
        vm.prank(timelock);
        bonds.setCapBpsPerEpoch(marketId, 50);

        // Drain the last sliver so the market is provably shut until the epoch rolls.
        while (bonds.capacityRemaining(marketId) > 0) {
            _bond(alice, 1e18);
        }

        (uint256 quoted,,,,, bytes32 reason) = bonds.quote(marketId, 0.05e18);
        assertEq(quoted, 0);
        assertEq(reason, bytes32("capacityFull"));

        vm.expectPartialRevert(CapacityExceeded.selector);
        vm.prank(bob);
        bonds.bond(marketId, 0.05e18, 0, bob);

        // The epoch boundary refills it, and the roll is announced.
        vm.warp(block.timestamp + bonds.epochSeconds());
        vaultMock.touchCheckpoint();
        vm.expectEmit(true, false, false, false, address(bonds));
        emit IAmpsBonds.EpochRolled(marketId, 0, 0);
        (uint256 secondOut,) = _bond(bob, 0.05e18);
        assertGt(secondOut, 0, "the market reopens at the epoch boundary");
    }

    function test_dailyCapBindsAcrossEveryMarket() public {
        // A second market, so the daily cap is provably global rather than per market.
        MockStockToken other = new MockStockToken("Other", "OTH");
        PoolId otherPool = PoolId.wrap(keccak256("AMPS/OTH"));
        registry.addConstituentAndPool(address(other), address(0xFEED), otherPool, PoolClass.SPOKE, 60, 500);
        feeds.setAnswer(address(other), uint128(STOCK_PRICE_USD8));
        int24 tick = _tickFor(NAV_X18, STOCK_PRICE_USD8, 18);
        marketRef.setObservation(otherPool, tick, tick, 1800);
        vm.prank(timelock);
        uint16 otherMarket = bonds.addCollateral(
            address(other), CollateralClass.CONSTITUENT, 1250, 1000, 1500, Constants.BOND_CAP_BPS_PER_EPOCH_MAX, true
        );
        other.mint(alice, 100e18);
        vm.prank(alice);
        other.approve(address(vaultMock), type(uint256).max);

        (, uint256 dailyCapacity) = bonds.dailyIssuance();
        assertEq(dailyCapacity, FullMath.mulDiv(GENESIS_SUPPLY, 200, 10_000), "200 bp of supply");

        // Fill the day from the two markets, rolling epochs as needed.
        uint256 issued;
        for (uint256 i; i < 12; ++i) {
            uint256 remaining = bonds.capacityRemaining(otherMarket);
            if (remaining == 0) {
                vm.warp(block.timestamp + bonds.epochSeconds());
                vaultMock.touchCheckpoint();
                continue;
            }
            vm.prank(alice);
            (uint256 out,) = bonds.bond(otherMarket, 1e18, 0, alice);
            issued += out;
            (uint256 dayIssued, uint256 dayCapacity) = bonds.dailyIssuance();
            assertEq(dayIssued, issued, "the daily tally is global");
            assertLe(dayIssued, dayCapacity, "and never exceeds the daily cap (I28)");
        }

        (uint256 finalIssued, uint256 finalCapacity) = bonds.dailyIssuance();
        assertGe(finalIssued, dailyCapacity, "the day fills to the cap it started with");
        assertLe(finalIssued, finalCapacity, "and never past the cap in force (I28)");
        assertEq(
            bonds.capacityRemaining(marketId), finalCapacity - finalIssued, "nothing left but the cap's own growth"
        );

        // A new day reopens both markets.
        vm.warp(block.timestamp + Constants.ONE_DAY);
        vaultMock.touchCheckpoint();
        (uint256 rolledIssued,) = bonds.dailyIssuance();
        assertEq(rolledIssued, 0, "the daily window rolls");
        assertGt(bonds.capacityRemaining(marketId), 0);
    }

    /* -------------------------------------------- entry class -------------------------------------------- */

    /// @notice `ENTRY` collateral routes off the entry pool's own TWAP and normalises 6 decimals in the shell.
    function test_entryClassMarketPricesOffTheEntryPool() public {
        vm.prank(timelock);
        bonds.setMarketOpen(entryMarketId, true);

        uint256 amountIn = 20e6; // 20 USDG, comfortably inside the market's 25 AMPS epoch capacity
        int24 tick = _tickFor(NAV_X18, 1e8, 6);
        uint256 expectedM = _expectedM(tick, 6);
        assertApproxEqRel(expectedM, 1e18, 2e14, "1 AMPS per USDG at $1.00 each");

        uint256 floorX18 = _qFloor(1e18, NAV_X18, 0, Constants.MIN_ACCRETION_BPS_DEFAULT);
        uint256 expectedOut = FullMath.mulDiv(amountIn * 1e12, floorX18, 1e18);

        vm.prank(alice);
        (uint256 ampsOut,) = bonds.bond(entryMarketId, amountIn, 0, alice);
        assertEq(ampsOut, expectedOut, "6 decimals are scaled up once, in the shell");
        assertEq(usdg.balanceOf(address(bonds)), 0, "sweepClean");
        assertEq(usdg.balanceOf(address(vaultMock)), amountIn);
    }

    /* --------------------------------------------- I27 --------------------------------------------- */

    /// @notice I27: NAV/share after a bond is never below NAV/share before, with the vault doing real accounting.
    function test_navPerShareNeverFallsAcrossABond() public {
        vaultMock.setAutoNav(true);
        uint256 before = vaultMock.previewNavPerShareX18();

        for (uint256 i; i < 5; ++i) {
            uint256 navBefore = vaultMock.previewNavPerShareX18();
            _bond(alice, 0.01e18);
            uint256 navAfter = vaultMock.previewNavPerShareX18();
            assertGe(navAfter, navBefore, "NAV/share never falls across a bond (I27)");
        }
        assertGe(vaultMock.previewNavPerShareX18(), before);
    }

    /* -------------------------------------- vesting and claiming -------------------------------------- */

    function test_claimIsLinearWithNoCliff() public {
        (uint256 ampsOut, uint256 positionId) = _bond(alice, 0.05e18);
        uint32 vest = bonds.vestSeconds();

        assertEq(bonds.claimable(alice, positionId), 0, "nothing at t = 0");
        assertEq(lens.vestedOf(bonds, alice, positionId), 0);

        vm.warp(block.timestamp + vest / 2);
        assertEq(bonds.claimable(alice, positionId), ampsOut / 2, "half at the midpoint");

        vm.prank(alice);
        uint256 firstClaim = bonds.claim(positionId, alice);
        assertEq(firstClaim, ampsOut / 2);
        assertEq(amps.balanceOf(alice), firstClaim);
        assertEq(bonds.claimable(alice, positionId), 0, "a claim consumes exactly what had vested");

        vm.warp(block.timestamp + vest);
        assertEq(bonds.claimable(alice, positionId), ampsOut - firstClaim, "the rest at the end");
        assertEq(lens.vestedOf(bonds, alice, positionId), ampsOut);

        vm.prank(alice);
        bonds.claim(positionId, bob);
        assertEq(amps.balanceOf(bob), ampsOut - firstClaim, "and pays whoever the owner names");
        assertEq(bonds.position(alice, positionId).claimed, ampsOut);
        assertEq(amps.balanceOf(address(bonds)), 0, "the shell keeps nothing once a vest completes");
    }

    function test_claimRejectsNothingToClaimAndUnknownPositions() public {
        (, uint256 positionId) = _bond(alice, 0.05e18);

        vm.startPrank(alice);
        vm.expectRevert(ZeroAmount.selector);
        bonds.claim(positionId, alice);

        vm.expectRevert(ZeroAddress.selector);
        bonds.claim(positionId, address(0));

        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.UnknownPosition.selector, alice, uint256(1)));
        bonds.claim(1, alice);
        vm.stopPrank();

        // A position belongs to its owner: nobody else can name its id.
        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.UnknownPosition.selector, bob, uint256(0)));
        vm.prank(bob);
        bonds.claim(0, bob);
    }

    function test_claimAllAggregatesEveryPosition() public {
        (uint256 first,) = _bond(alice, 0.02e18);
        vm.warp(block.timestamp + 1 hours);
        vaultMock.touchCheckpoint();
        (uint256 second,) = _bond(alice, 0.03e18);

        assertEq(bonds.positionCount(alice), 2);
        assertEq(lens.positionsOf(bonds, alice).length, 2);

        (uint256 principal, uint256 claimedSoFar, uint256 claimableNow) = lens.positionTotals(bonds, alice);
        assertEq(principal, first + second, "the lens totals every position");
        assertEq(claimedSoFar, 0);
        assertEq(claimableNow, bonds.claimableTotal(alice));

        vm.warp(block.timestamp + bonds.vestSeconds());
        assertEq(bonds.claimableTotal(alice), first + second);

        vm.prank(alice);
        uint256 claimed = bonds.claimAll(alice);
        assertEq(claimed, first + second);
        assertEq(amps.balanceOf(alice), first + second);

        vm.expectRevert(ZeroAmount.selector);
        vm.prank(alice);
        bonds.claimAll(alice);
    }

    /// @notice I38: a governance change to `vestSeconds` can neither lengthen nor shorten a vest already sold.
    function test_vestLengthIsFrozenAtPurchase() public {
        (uint256 ampsOut, uint256 positionId) = _bond(alice, 0.05e18);

        vm.prank(timelock);
        bonds.setVestSeconds(Constants.BOND_VEST_SECONDS_MAX);

        assertEq(bonds.position(alice, positionId).vestSeconds, Constants.BOND_VEST_SECONDS_DEFAULT);
        vm.warp(block.timestamp + Constants.BOND_VEST_SECONDS_DEFAULT);
        assertEq(bonds.claimable(alice, positionId), ampsOut, "the sold vest completes on its own clock");
    }

    /// @notice `claim` under every hostile condition the design promises it survives (I38, state model §7).
    function test_claimSurvivesEveryHostileCondition() public {
        (uint256 ampsOut, uint256 positionId) = _bond(alice, 0.05e18);
        vm.warp(block.timestamp + bonds.vestSeconds());

        // The gate refuses everything, the guardian has frozen the protocol and the constituent.
        gate.setBondRefusal(true, GateState.WATCHDOG);
        gate.setCorporateFreeze(constituentId, true);
        gate.freezeProtocol(uint32(block.timestamp + 7 days));
        gate.setWatchdogTripped(true);
        gate.setDefaultState(GateState.DIVERGED);

        // Every feed is dead, and the registry reverts on every call.
        feeds.setReverting(true);
        vm.etch(address(registry), hex"60006000fd"); // revert on any call

        // The collateral has been removed and the market paused.
        vm.startPrank(timelock);
        bonds.removeCollateral(address(stock));
        bonds.setPolicy(address(new RevertingPolicy()));
        vm.stopPrank();

        // The vault pointer is a contract that reverts on everything.
        vaultMock.setReverting(true);

        vm.prank(alice);
        uint256 claimed = bonds.claim(positionId, alice);
        assertEq(claimed, ampsOut, "claim completes through all of it");
        assertEq(amps.balanceOf(alice), ampsOut);
    }

    /// @notice State model §7 step 4: the storage-level proof that `claim` *cannot* be gated — it reads no slot of
    ///         the gate, the feed registry, the registry or the vault, and not even its own `vault` pointer.
    function test_claimReadsNoForeignStorage() public {
        (, uint256 positionId) = _bond(alice, 0.05e18);
        vm.warp(block.timestamp + bonds.vestSeconds());

        vm.record();
        vm.prank(alice);
        bonds.claim(positionId, alice);

        _assertNoStorageAccess(address(gate), "oracleGate");
        _assertNoStorageAccess(address(feeds), "feedRegistry");
        _assertNoStorageAccess(address(registry), "registry");
        _assertNoStorageAccess(address(vaultMock), "vault");

        // And on `AmpsBonds` itself: never the vault, policy or registry pointer slots.
        (bytes32[] memory reads,) = vm.accesses(address(bonds));
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(uint256(reads[i]) > 3, "claim reads no governed pointer slot");
        }
    }

    /// @notice The same proof for `claimAll`.
    function test_claimAllReadsNoForeignStorage() public {
        _bond(alice, 0.02e18);
        _bond(alice, 0.02e18);
        vm.warp(block.timestamp + bonds.vestSeconds());

        vm.record();
        vm.prank(alice);
        bonds.claimAll(alice);

        _assertNoStorageAccess(address(gate), "oracleGate");
        _assertNoStorageAccess(address(feeds), "feedRegistry");
        _assertNoStorageAccess(address(registry), "registry");
        _assertNoStorageAccess(address(vaultMock), "vault");
    }

    /* -------------------------------------------- the view -------------------------------------------- */

    function test_quoteMatchesTheBondItPrices() public {
        (uint256 quoted, uint256 qX18, uint16 discount, bool floorBinding, uint256 capacityLeft, bytes32 reason) =
            bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32(0));
        assertEq(capacityLeft, _epochCapacity());

        (uint256 ampsOut,) = _bond(alice, 0.05e18);
        assertEq(ampsOut, quoted, "the view and the transaction agree");
        assertEq(qX18, _qFloor(STOCK_PRICE_USD8 * 1e10, NAV_X18, 0, Constants.MIN_ACCRETION_BPS_DEFAULT));
        assertEq(discount, 1250);
        assertTrue(floorBinding);
    }

    function test_quoteNeverRevertsAndExplainsItself() public {
        // Closed market.
        vm.prank(timelock);
        bonds.setMarketOpen(marketId, false);
        (uint256 ampsOut,,,,, bytes32 reason) = bonds.quote(marketId, 0.05e18);
        assertEq(ampsOut, 0);
        assertEq(reason, bytes32("marketClosed"));
        vm.prank(timelock);
        bonds.setMarketOpen(marketId, true);

        // A refusing gate.
        gate.setBondRefusal(true, GateState.DIVERGED);
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("gateRefused"));
        gate.setBondRefusal(false, GateState.GREEN);

        // A stale checkpoint.
        vm.warp(block.timestamp + Constants.CHECKPOINT_MAX_AGE + 1);
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("staleCheckpoint"));
        vaultMock.touchCheckpoint();

        // An unobserved pool.
        marketRef.clear(spokePool);
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("noTwap"));
        _setSpokePriceUsd18(NAV_X18);

        // A feed with no usable answer, and then a registry that reverts on every read.
        feeds.clearAnswer(address(stock));
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("noPrice"));
        feeds.setReverting(true);
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("noPrice"));
        feeds.setReverting(false);
        feeds.setAnswer(address(stock), uint128(STOCK_PRICE_USD8));

        // A policy that reverts on every quote.
        address deadPolicy = address(new RevertingPolicy());
        vm.prank(timelock);
        bonds.setPolicy(deadPolicy);
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("policyRefused"));
        vm.prank(timelock);
        bonds.setPolicy(address(policy));

        // A vault that reverts on every call.
        vaultMock.setReverting(true);
        (,,,,, reason) = bonds.quote(marketId, 0.05e18);
        assertEq(reason, bytes32("vaultDown"));
        vaultMock.setReverting(false);

        // A zero-amount quote is priced but issues nothing.
        (ampsOut,,,,, reason) = bonds.quote(marketId, 0);
        assertEq(ampsOut, 0);
        assertEq(reason, bytes32("zeroAmount"));
    }

    /// @notice The lens renders the whole board in one call, including the markets that would refuse a bond.
    function test_lensBoardCoversEveryMarket() public view {
        AmpsBondsLens.MarketQuote[] memory rows = lens.board(bonds, 0.01e18);
        assertEq(rows.length, bonds.marketCount(), "one row per market");

        assertEq(rows[0].marketId, marketId);
        assertEq(rows[0].record.collateral, address(stock));
        assertEq(rows[0].reason, bytes32(0), "the constituent market is open");
        assertGt(rows[0].ampsOut, 0);
        assertEq(rows[0].capacityLeft, _epochCapacity());
        assertTrue(rows[0].floorBinding);
        assertEq(rows[0].discountBps, Constants.BOND_D_BASE_BPS_DEFAULT);

        assertEq(rows[1].marketId, entryMarketId);
        assertEq(rows[1].record.collateral, address(usdg));
        assertEq(rows[1].reason, bytes32("marketClosed"), "the entry market ships closed");
        assertEq(rows[1].ampsOut, 0);
    }

    function test_quoteRevertsOnlyForAnUnknownMarket() public {
        vm.expectRevert(abi.encodeWithSelector(UnknownMarket.selector, uint16(0)));
        bonds.quote(0, 1e18);

        vm.expectRevert(abi.encodeWithSelector(UnknownMarket.selector, uint16(42)));
        bonds.quote(42, 1e18);

        vm.expectRevert(abi.encodeWithSelector(UnknownMarket.selector, uint16(42)));
        bonds.market(42);

        vm.expectRevert(abi.encodeWithSelector(UnknownMarket.selector, uint16(42)));
        bonds.capacityRemaining(42);
    }

    function test_positionViewsRejectUnknownIds() public {
        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.UnknownPosition.selector, alice, uint256(0)));
        bonds.position(alice, 0);

        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.UnknownPosition.selector, alice, uint256(0)));
        bonds.claimable(alice, 0);

        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.UnknownPosition.selector, alice, uint256(0)));
        lens.vestedOf(bonds, alice, 0);

        assertEq(bonds.claimableTotal(alice), 0, "an owner with no positions has nothing to claim");
    }

    /* -------------------------------------------- helpers -------------------------------------------- */

    function _assertNoStorageAccess(address target, string memory label) internal view {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(target);
        assertEq(reads.length, 0, string.concat(label, ": claim read its storage"));
        assertEq(writes.length, 0, string.concat(label, ": claim wrote its storage"));
    }
}

/// @notice A policy that always returns a price far above the accretion floor: the shell must reject it.
contract HostilePolicy is IBondPolicy {
    function quote(QuoteInput calldata input) external pure returns (QuoteOutput memory output) {
        output.qX18 = type(uint128).max;
        output.qMarketX18 = type(uint128).max;
        output.qFloorX18 = type(uint128).max;
        output.discountBps = input.dMaxBps;
        output.ampsOut = input.amountIn18;
    }

    function discountBps(uint16, uint16, uint16, uint64, uint64, uint64, uint64) external pure returns (uint16) {
        return 0;
    }

    function version() external pure returns (bytes32) {
        return "hostile";
    }
}

/// @notice A different pricing law behind the same pointer: every bond issues at exactly half the accretion
///         floor. Pure, like every `IBondPolicy`, so it calls nothing.
contract HalfFloorPolicy is IBondPolicy {
    function quote(QuoteInput calldata input) external pure returns (QuoteOutput memory output) {
        uint256 numerator = FullMath.mulDiv(input.collateralPriceUsd18, 10_000 - uint256(input.hSessionBps), 10_000);
        uint256 denominator =
            FullMath.mulDivRoundingUp(input.navPerShareX18, 10_000 + uint256(input.minAccretionBps), 10_000);

        output.qFloorX18 = FullMath.mulDiv(numerator, 1e18, denominator);
        output.qMarketX18 = output.qFloorX18;
        output.qX18 = output.qFloorX18 / 2;
        output.floorBinding = true;
        output.discountBps = input.dBaseBps;
        output.ampsOut = FullMath.mulDiv(input.amountIn18, output.qX18, 1e18);
    }

    function discountBps(uint16 dBaseBps, uint16, uint16, uint64, uint64, uint64, uint64)
        external
        pure
        returns (uint16)
    {
        return dBaseBps;
    }

    function version() external pure returns (bytes32) {
        return "half-floor";
    }
}

/// @notice A policy that refuses to price anything.
contract RevertingPolicy is IBondPolicy {
    error PolicyDown();

    function quote(QuoteInput calldata) external pure returns (QuoteOutput memory) {
        revert PolicyDown();
    }

    function discountBps(uint16, uint16, uint16, uint64, uint64, uint64, uint64) external pure returns (uint16) {
        revert PolicyDown();
    }

    function version() external pure returns (bytes32) {
        return "reverting";
    }
}
