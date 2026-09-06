// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsBonds} from "../../src/bonds/AmpsBonds.sol";
import {IPoolRegistry} from "../../src/interfaces/IPoolRegistry.sol";
import {BondPolicy} from "../../src/policy/BondPolicy.sol";
import {PoolRegistry} from "../../src/registry/PoolRegistry.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotTimelock} from "../../src/types/Errors.sol";
import {BondMarket, CollateralClass, ConstituentStatus, InclusionRecord, PoolClass} from "../../src/types/Types.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockVaultForRegistry} from "../mocks/MockVaultForRegistry.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title RegistryBondsWiringTest
/// @notice The registry-to-bonds hand-off, with **both real contracts**: `PoolRegistry.addConstituent` opening a
///         market on `AmpsBonds`, and `PoolRegistry.retireConstituent` / `reinstateConstituent` closing and
///         reopening it.
///
/// @dev Every other suite drives one of the two through a mock — `PoolRegistry.t.sol` uses `MockBondsForRegistry`,
///      `AmpsBonds.t.sol` uses `MockRegistryForBonds` — so neither of them can see the thing that actually breaks
///      here: `AmpsBonds` gates `addCollateral` and `setMarketOpen` on `_requireGovernance`, which accepts the
///      *registry* alongside the timelock, and the registry reaches the bonds shell through
///      `IAmpsVault.bonds()` rather than through a stored pointer of its own. A mock on either side answers those
///      questions for itself. This file is the one place the two real access-control decisions have to agree.
///
/// @dev What makes the hand-off matter rather than being a convenience: it is what makes "a new constituent opens
///      its bond market" and "a retired constituent has no open bond market" (I37) **atomic**. The alternative —
///      two separate 7-day proposals — leaves a window in which the index and the bond board disagree, and the
///      registry is itself timelock-only, so nothing is loosened by allowing it.
///
/// @dev The vault is still a mock (`MockVaultForRegistry`): the real vault needs a live PoolManager, and nothing
///      on this path touches it beyond three pointer reads and `initializePool`. `AmpsBonds` reads `amps` and
///      `timelock` from it at construction and on every governed call, which is exactly what the mock answers.
contract RegistryBondsWiringTest is Test {
    /// @dev The CREATE2-mined AMPS address from `script/config/amps-mining-example.json`: three leading zero
    ///      bytes, so it sorts below every counter asset and is `currency0` in every pool key the registry builds.
    address internal constant AMPS = 0x000000dD2F33b84B4430E5Bc69c5d4BF1eE9fd4d;

    /// @dev A stand-in for the flag-mined hook: the low 14 bits are `Constants.HOOK_FLAGS`.
    address internal constant HOOK = address(uint160(0x00000000000000000000000000000000000038c0));

    address internal constant TIMELOCK = address(0x7E10C4);
    address internal constant STRANGER = address(0xBAD);

    int24 internal constant TICK_SPACING = 60;

    PoolRegistry internal registry;
    AmpsBonds internal bonds;
    BondPolicy internal policy;
    MockVaultForRegistry internal vault;

    MockStockToken internal weth;
    MockERC20 internal usdg;
    MockStockToken internal nvda;
    MockAggregator internal nvdaFeed;

    function setUp() public {
        // The wiring is circular by construction — the registry takes the vault, the bonds shell takes the
        // registry, and the vault points at the bonds shell — so the vault's bonds pointer is set last, exactly
        // as the real deployment does it through `AmpsVault.setPolicyPointer(bytes32("bonds"), ...)`.
        vault = new MockVaultForRegistry(address(0), AMPS, TIMELOCK);
        vault.setPRefX18(1e18);

        weth = new MockStockToken("Wrapped Ether", "WETH");
        usdg = new MockERC20("Global Dollar", "USDG", 6);

        registry = new PoolRegistry(address(vault), HOOK, TIMELOCK, AMPS, address(weth), address(usdg));
        policy = new BondPolicy();
        bonds = new AmpsBonds(address(vault), address(registry), address(policy));
        vault.setBonds(address(bonds));

        nvda = new MockStockToken("NVDA", "NVDA");
        nvdaFeed = new MockAggregator("NVDA / USD", 8, 180e8);

        vm.label(AMPS, "AMPS");
        vm.label(address(registry), "PoolRegistry");
        vm.label(address(bonds), "AmpsBonds");
        vm.label(address(vault), "MockVault");
    }

    // -------------------------------------------------------------------------------------------------------------
    // addConstituent -> addCollateral
    // -------------------------------------------------------------------------------------------------------------

    /// @notice One 7-day registry proposal opens the spoke *and* its bond market, on the real bonds shell.
    function test_addConstituentOpensTheBondMarketOnTheRealShell() public {
        assertEq(bonds.marketCount(), 0, "no markets before");

        (uint16 constituentId,) = _addNvda(true);

        uint16 marketId = bonds.marketIdOf(address(nvda));
        assertEq(marketId, 1, "the shell issued market 1");
        assertEq(bonds.marketCount(), 1, "and counted it");

        // The registry recorded the id the shell returned, which is what its retirement path later closes.
        assertEq(registry.constituent(constituentId).marketId, marketId, "the registry kept the market id");

        BondMarket memory market = bonds.market(marketId);
        assertEq(market.collateral, address(nvda), "on the right collateral");
        assertTrue(market.open, "open to bonds immediately");
        assertEq(uint8(market.class), uint8(CollateralClass.CONSTITUENT), "as a constituent market");
        assertEq(market.constituentId, constituentId, "cross-indexed to the constituent");
        assertEq(market.decimals, 18, "with the collateral's decimals");

        // The launch defaults from `Constants` travelled across the boundary unchanged.
        assertEq(market.dBaseBps, Constants.BOND_D_BASE_BPS_DEFAULT, "dBase");
        assertEq(market.dMinBps, Constants.BOND_D_MIN_BPS_DEFAULT, "dMin");
        assertEq(market.dMaxBps, Constants.BOND_D_MAX_BPS_DEFAULT, "dMax");
        assertEq(market.capBpsPerEpoch, Constants.BOND_CAP_BPS_PER_EPOCH_DEFAULT, "capBpsPerEpoch");
    }

    /// @notice `openBondMarket == false` registers the spoke and opens no market: the flag is real, not decorative.
    function test_addConstituentWithoutABondMarketOpensNothing() public {
        (uint16 constituentId,) = _addNvda(false);

        assertEq(bonds.marketCount(), 0, "no market was opened");
        assertEq(bonds.marketIdOf(address(nvda)), 0, "and the collateral is unregistered");
        assertEq(registry.constituent(constituentId).marketId, 0, "the registry recorded no market");
    }

    /// @notice The registry is an *additional* caller, not a replacement: a stranger is still refused, and the
    ///         timelock can still call the shell directly.
    function test_addCollateralIsRegistryOrTimelockOnly() public {
        _addNvda(false);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, STRANGER));
        bonds.addCollateral(
            address(nvda),
            CollateralClass.CONSTITUENT,
            Constants.BOND_D_BASE_BPS_DEFAULT,
            Constants.BOND_D_MIN_BPS_DEFAULT,
            Constants.BOND_D_MAX_BPS_DEFAULT,
            Constants.BOND_CAP_BPS_PER_EPOCH_DEFAULT,
            true
        );

        vm.prank(TIMELOCK);
        uint16 marketId = bonds.addCollateral(
            address(nvda),
            CollateralClass.CONSTITUENT,
            Constants.BOND_D_BASE_BPS_DEFAULT,
            Constants.BOND_D_MIN_BPS_DEFAULT,
            Constants.BOND_D_MAX_BPS_DEFAULT,
            Constants.BOND_CAP_BPS_PER_EPOCH_DEFAULT,
            true
        );
        assertEq(marketId, 1, "the timelock's own call still works");
        assertTrue(registry.vault() != TIMELOCK, "and the two callers really are different addresses");
    }

    // -------------------------------------------------------------------------------------------------------------
    // retireConstituent -> setMarketOpen(false), and back
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Retirement closes the market on the real shell inside the same call, which is what makes I37
    ///         atomic rather than a two-proposal race.
    function test_retireConstituentClosesTheMarketOnTheRealShell() public {
        (uint16 constituentId,) = _addNvda(true);
        uint16 marketId = bonds.marketIdOf(address(nvda));
        assertTrue(bonds.market(marketId).open, "open to begin with");

        vm.prank(TIMELOCK);
        registry.retireConstituent(constituentId);

        assertFalse(bonds.market(marketId).open, "retirement closed it");
        assertEq(uint8(registry.constituent(constituentId).status), uint8(ConstituentStatus.RETIRED), "retired");
        assertEq(registry.constituent(constituentId).rolloutWeightBps, 0, "and its rollout weight is zero");

        // The collateral is still registered — only new bonds are stopped — so vesting positions still claim and
        // the market can be reopened without a second `addCollateral`.
        assertEq(bonds.marketIdOf(address(nvda)), marketId, "the collateral is not deregistered");
    }

    /// @notice Reinstatement reopens the same market id, through the same accepted caller.
    function test_reinstateConstituentReopensTheSameMarket() public {
        (uint16 constituentId,) = _addNvda(true);
        uint16 marketId = bonds.marketIdOf(address(nvda));

        vm.prank(TIMELOCK);
        registry.retireConstituent(constituentId);
        assertFalse(bonds.market(marketId).open, "closed");

        vm.prank(TIMELOCK);
        registry.reinstateConstituent(constituentId, 500);

        assertTrue(bonds.market(marketId).open, "reopened");
        assertEq(bonds.marketIdOf(address(nvda)), marketId, "and it is the same market, not a new one");
        assertEq(uint8(registry.constituent(constituentId).status), uint8(ConstituentStatus.ACTIVE), "active again");
        assertEq(registry.constituent(constituentId).rolloutWeightBps, 500, "with the restored rollout weight");
    }

    /// @notice A constituent registered with no bond market retires with no call into the shell at all: the
    ///         registry skips the hand-off on `marketId == 0` rather than asking the shell about market 0.
    function test_retireWithoutAMarketDoesNotTouchTheShell() public {
        (uint16 constituentId,) = _addNvda(false);

        vm.prank(TIMELOCK);
        registry.retireConstituent(constituentId);

        assertEq(uint8(registry.constituent(constituentId).status), uint8(ConstituentStatus.RETIRED), "retired");
        assertEq(bonds.marketCount(), 0, "and the shell was never called");
    }

    /// @notice `setMarketOpen` is registry-or-timelock too, and a stranger is refused by the shell's own check.
    function test_setMarketOpenIsRegistryOrTimelockOnly() public {
        _addNvda(true);
        uint16 marketId = bonds.marketIdOf(address(nvda));

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, STRANGER));
        bonds.setMarketOpen(marketId, false);

        vm.prank(address(registry));
        bonds.setMarketOpen(marketId, false);
        assertFalse(bonds.market(marketId).open, "the registry may close it directly");

        vm.prank(TIMELOCK);
        bonds.setMarketOpen(marketId, true);
        assertTrue(bonds.market(marketId).open, "and the timelock may reopen it");
    }

    // -------------------------------------------------------------------------------------------------------------
    // currentWeightBps, the other half of the registry surface `AmpsBonds` reads
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The real registry answers `currentWeightBps` with the target weight in Phase 2, so the bond
    ///         discount's deficit term is exactly zero rather than unknown.
    function test_currentWeightBpsIsTheTargetWeightInPhase2() public {
        (uint16 constituentId,) = _addNvda(true);

        uint16 target = registry.constituent(constituentId).targetWeightBps;
        assertEq(registry.currentWeightBps(constituentId), target, "realised == target in Phase 2");
        assertEq(IPoolRegistry(address(registry)).currentWeightBps(constituentId), target, "through the interface");

        // An id that was never registered answers zero rather than reverting, so a bond on a stale market prices.
        assertEq(registry.currentWeightBps(9999), 0, "an unknown id is zero, not a revert");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Registers NVDA as a constituent through the 7-day timelock, optionally opening its bond market.
    /// @param openBondMarket Whether the same proposal opens the market on `AmpsBonds`.
    /// @return constituentId The new 1-based id.
    /// @return marketId The market id the shell issued, or 0.
    function _addNvda(bool openBondMarket) private returns (uint16 constituentId, uint16 marketId) {
        IPoolRegistry.AddConstituentParams memory params = IPoolRegistry.AddConstituentParams({
            token: address(nvda),
            feed: address(nvdaFeed),
            poolClass: PoolClass.SPOKE,
            tickSpacing: TICK_SPACING,
            buyFeeBps: Constants.BUY_FEE_BPS_SPOKE_DEFAULT,
            targetWeightBps: 1000,
            rolloutWeightBps: 500,
            hSessionOverrideBps: 0,
            hSessionOverrideSet: false,
            inclusion: InclusionRecord({
                betaX18: 1.2e18, trackingErrorX18: 0.1e18, indexVolX18: 0.3e18, historyDays: 365, recordedAt: 0
            }),
            openBondMarket: openBondMarket
        });

        vm.prank(TIMELOCK);
        (constituentId,) = registry.addConstituent(params);
        marketId = registry.constituent(constituentId).marketId;
    }
}
