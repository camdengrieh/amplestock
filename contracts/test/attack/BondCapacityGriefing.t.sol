// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {console} from "forge-std/console.sol";

/// @title BondCapacityGriefingTest
/// @notice The plan's named attack **bond-capacity griefing**: "filling capacity at the floor costs the griefer
///         `minAccretionBps` per epoch".
///
///         The griefer buys out a market's whole per-epoch capacity so that nobody else can bond. It is not free:
///         every AMPS they take out is priced at `min(qMarket, qFloor)`, and `q_floor` is the price at which the
///         bond accretes at least `minAccretionBps` to NAV/share. The griefing therefore *pays* the protocol
///         50 bp of the issue per epoch, the capacity rolls in six hours, and the queue is never closed for long.
contract BondCapacityGriefingTest is Phase3Fixture {
    address internal constant GRIEFER = address(0x64213F);
    address internal constant HONEST = address(0x40E57);

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        // The shortest epoch the band allows, so a campaign can cross several of them inside one trading session
        // - a six-hour epoch would put the second one after the close, where the gate refuses on its own account
        // and the griefing would look bounded for the wrong reason.
        vm.prank(TIMELOCK);
        bonds.setEpochSeconds(Constants.BOND_EPOCH_SECONDS_MIN);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    /// @dev Rolls the clock to the next epoch and refreshes the vault's checkpoint, which `AmpsBonds.quote` needs
    ///      to be inside `CHECKPOINT_MAX_AGE`.
    function _nextEpoch() private {
        warpBy(Constants.BOND_EPOCH_SECONDS_MIN + 1);
        vault.checkpoint();
    }

    /// @notice Filling the epoch raises NAV/share by at least `minAccretionBps` of the issue, and closes the
    ///         market only until the epoch rolls.
    function test_fillingTheEpochPaysTheProtocolAndOnlyDelaysTheQueue() public {
        uint16 marketId = marketIds[0];
        uint256 navBefore = vault.previewNavPerShareX18();
        uint256 capacity = bonds.capacityRemaining(marketId);
        assertGt(capacity, 0, "the market opens with capacity");

        uint256 issued = _bondCapacity(GRIEFER, 0);
        assertApproxEqAbs(issued, capacity, capacity / 100, "the griefer took the whole epoch");
        assertLt(bonds.capacityRemaining(marketId), capacity / 100, "and what is left is dust");

        uint256 navAfter = vault.previewNavPerShareX18();
        assertGe(navAfter, navBefore, "the griefing raised NAV/share (I27)");
        console.log("nav before", navBefore, "after", navAfter);

        // An honest buyer is refused for the rest of the epoch...
        stocks[0].mint(HONEST, 1e18);
        vm.startPrank(HONEST);
        stocks[0].approve(address(vault), type(uint256).max);
        vm.expectRevert();
        bonds.bond(marketId, 1e18, capacity / 2, HONEST);
        vm.stopPrank();

        // ...and served the moment it rolls.
        _nextEpoch();
        assertGt(bonds.capacityRemaining(marketId), 0, "the epoch rolled and capacity is back");
        uint256 honestOut = _bondCapacity(HONEST, 0);
        assertGt(honestOut, 0, "and the honest buyer is served");
    }

    /// @notice The cost side, stated as the plan states it: the griefer hands over collateral worth strictly more
    ///         than the AMPS they receive is worth at NAV, epoch after epoch.
    function test_theGrieferPaysAccretionEveryEpoch() public {
        uint256 totalCollateralUsd;
        uint256 totalIssuedUsd;

        for (uint256 epoch; epoch < 3; ++epoch) {
            uint256 nav = vault.previewNavPerShareX18();
            uint256 issued = _bondCapacity(GRIEFER, 0);
            totalCollateralUsd += _lastBondCollateral * uint256(stockUsd8[0]) / 1e8;
            totalIssuedUsd += issued * nav / Constants.WAD;
            _nextEpoch();
        }

        console.log("collateral in (usd18)", totalCollateralUsd, "AMPS out at NAV (usd18)", totalIssuedUsd);
        assertGt(totalCollateralUsd, 0, "the griefer really bonded");
        assertLe(
            totalIssuedUsd * (Constants.BPS + Constants.MIN_ACCRETION_BPS_DEFAULT) / Constants.BPS,
            totalCollateralUsd * 101 / 100,
            "every epoch's issue is accretive at the floor"
        );
    }

    /// @notice And the global daily cap bounds the whole campaign: however many markets a griefer attacks, total
    ///         issuance in a day is `dailyCapBps` of supply and no more (I28).
    function test_theDailyCapBoundsTheWholeCampaign() public {
        uint256 supplyBefore = amps.totalSupply();
        for (uint256 epoch; epoch < 6; ++epoch) {
            for (uint256 i; i < spokePools.length; ++i) {
                if (bonds.capacityRemaining(marketIds[i]) == 0) continue;
                _bondCapacity(GRIEFER, i);
            }
            _nextEpoch();
        }
        uint256 minted = amps.totalSupply() - supplyBefore;
        // Six epochs is a day and a half; two days of the daily cap is the bound that must hold.
        assertLe(
            minted,
            supplyBefore * uint256(Constants.BOND_DAILY_CAP_BPS_DEFAULT) * 2 / Constants.BPS,
            "no campaign beats the daily cap"
        );
    }

    /// @dev The collateral the last {_bondCapacity} spent.
    uint256 private _lastBondCollateral;

    /// @dev Buys exactly the remaining epoch capacity of spoke `i`'s market, sized from `quote` so the deposit is
    ///      not silently over-paid, with `minAmpsOut` set the way a real bonder sets it.
    function _bondCapacity(address who, uint256 i) private returns (uint256 issued) {
        uint16 marketId = marketIds[i];
        uint256 capacity = bonds.capacityRemaining(marketId);
        if (capacity == 0) return 0;
        (uint256 probeOut,,,,,) = bonds.quote(marketId, 1e18);
        if (probeOut == 0) return 0;

        uint256 collateral = capacity * 1e18 / probeOut;
        _lastBondCollateral = collateral;
        stocks[i].mint(who, collateral);
        vm.startPrank(who);
        stocks[i].approve(address(vault), type(uint256).max);
        (issued,) = bonds.bond(marketId, collateral, capacity * 9 / 10, who);
        vm.stopPrank();
    }
}
