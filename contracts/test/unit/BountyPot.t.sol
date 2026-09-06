// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBountyPot} from "../../src/interfaces/IBountyPot.sol";
import {BountyPot} from "../../src/keeper/BountyPot.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotTimelock, NotVault, OutOfBand, ZeroAddress, ZeroAmount} from "../../src/types/Errors.sol";
import {MockUsdg} from "../mocks/MockUsdg.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Unit tests for the segregated keeper bounty pot: every branch of the payout formula, the rolling
///         ceiling and its rollover, graceful depletion, the `chost` dust guard against a spam campaign, and the
///         whole access-control and band surface.
contract BountyPotTest is Test {
    uint256 internal constant T0 = 1_800_000_000;

    /// @dev USDG has 6 decimals, so one 18-decimal USD is `1e12` raw units.
    uint256 internal constant SCALE = 1e12;

    /// @dev $1 of USDG.
    uint256 internal constant ONE_USDG = 1e6;

    MockUsdg internal usdg;
    BountyPot internal pot;

    address internal vaultAddr = makeAddr("vault");
    address internal timelock = makeAddr("timelock");
    address internal keeper = makeAddr("keeper");
    address internal funder = makeAddr("funder");

    function setUp() public {
        vm.warp(T0);
        usdg = new MockUsdg("USD Global", "USDG", 6);
        pot = new BountyPot(address(usdg), vaultAddr, timelock);
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev Tops the pot up with `amountRaw` through the permissionless {BountyPot-fund}.
    function _fund(uint256 amountRaw) internal {
        usdg.mint(funder, amountRaw);
        vm.startPrank(funder);
        usdg.approve(address(pot), amountRaw);
        pot.fund(amountRaw);
        vm.stopPrank();
    }

    function _pay(uint256 workValueUsd18, uint256 gasCostUsd18) internal returns (uint256 paidRaw) {
        vm.prank(vaultAddr);
        paidRaw = pot.pay(keeper, workValueUsd18, gasCostUsd18);
    }

    /* -------------------------------- metadata -------------------------------- */

    function test_launchParametersMatchTheConfirmedTable() public view {
        assertEq(pot.token(), address(usdg));
        assertEq(pot.vault(), vaultAddr);
        assertEq(pot.timelock(), timelock);
        assertEq(pot.usdScale(), SCALE, "18-decimal USD to 6-decimal USDG");

        assertEq(pot.tipUsd18(), Constants.KEEPER_TIP_USD18_DEFAULT, "tip: $0.05");
        assertEq(pot.tipUsd18(), 0.05e18);
        assertEq(pot.chipBps(), Constants.KEEPER_CHIP_BPS_DEFAULT, "chip: 2% of work value");
        assertEq(pot.chipBps(), 200);
        assertEq(pot.chostUsd18(), Constants.KEEPER_CHOST_USD18_DEFAULT, "chost: $1 of work value");
        assertEq(pot.chostUsd18(), 1e18);
        assertEq(pot.gasCapMultiple(), Constants.KEEPER_GAS_CAP_MULTIPLE, "gas cap: 3x");
        assertEq(pot.gasCapMultiple(), 3);
        assertEq(pot.dailyCeilingUsd18(), pot.DAILY_CEILING_USD18_DEFAULT());

        assertEq(pot.balance(), 0);
        assertEq(pot.spentLast24h(), 0);
        assertEq(pot.windowStart(), 0);
        assertEq(pot.budgetLeftUsd18(), pot.DAILY_CEILING_USD18_DEFAULT());
    }

    function test_everyLaunchValueSitsInsideItsBand() public view {
        assertLe(pot.tipUsd18(), pot.TIP_USD18_MAX());
        assertLe(pot.chipBps(), pot.CHIP_BPS_MAX());
        assertLe(pot.chostUsd18(), pot.CHOST_USD18_MAX());
        assertGe(pot.gasCapMultiple(), pot.GAS_CAP_MULTIPLE_MIN());
        assertLe(pot.gasCapMultiple(), pot.GAS_CAP_MULTIPLE_MAX());
        assertLe(pot.dailyCeilingUsd18(), pot.DAILY_CEILING_USD18_MAX());
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ZeroAddress.selector);
        new BountyPot(address(0), vaultAddr, timelock);

        vm.expectRevert(ZeroAddress.selector);
        new BountyPot(address(usdg), address(0), timelock);

        vm.expectRevert(ZeroAddress.selector);
        new BountyPot(address(usdg), vaultAddr, address(0));
    }

    function test_constructorRejectsMoreThanEighteenDecimals() public {
        MockUsdg odd = new MockUsdg("Odd", "ODD", 19);
        vm.expectRevert(abi.encodeWithSelector(IBountyPot.UnsupportedDecimals.selector, uint8(19)));
        new BountyPot(address(odd), vaultAddr, timelock);
    }

    function test_scaleIsReadFromTheToken() public {
        MockUsdg wad = new MockUsdg("Wad", "WAD", 18);
        BountyPot wadPot = new BountyPot(address(wad), vaultAddr, timelock);
        assertEq(wadPot.usdScale(), 1, "an 18-decimal token needs no scaling");

        MockUsdg unitary = new MockUsdg("Unit", "UNI", 0);
        BountyPot unitaryPot = new BountyPot(address(unitary), vaultAddr, timelock);
        assertEq(unitaryPot.usdScale(), 1e18);
    }

    /* ----------------------------------- fund ---------------------------------- */

    function test_fundIsPermissionless() public {
        usdg.mint(keeper, 100 * ONE_USDG);
        vm.startPrank(keeper);
        usdg.approve(address(pot), 100 * ONE_USDG);

        vm.expectEmit(true, false, false, true, address(pot));
        emit IBountyPot.PotFunded(keeper, 100 * ONE_USDG);
        pot.fund(100 * ONE_USDG);
        vm.stopPrank();

        assertEq(pot.balance(), 100 * ONE_USDG);
    }

    function test_fundRejectsZero() public {
        vm.expectRevert(ZeroAmount.selector);
        pot.fund(0);
    }

    /* ------------------------------ the payout formula ------------------------- */

    function test_payTipPlusChip() public {
        _fund(100 * ONE_USDG);

        // $100 of realised work, $1 of gas: $0.05 tip + 2% chip = $2.05, well inside the 3x gas cap.
        uint256 paid = _pay(100e18, 1e18);

        assertEq(paid, 2_050_000, "tip + chip, in 6-decimal USDG");
        assertEq(usdg.balanceOf(keeper), 2_050_000);
        assertEq(pot.balance(), 100 * ONE_USDG - 2_050_000);
        assertEq(pot.spentLast24h(), 2.05e18);
        assertEq(pot.windowStart(), uint32(T0));
    }

    function test_payRefusesBelowTheChostDustGuard() public {
        _fund(100 * ONE_USDG);

        vm.expectEmit(true, false, false, true, address(pot));
        emit IBountyPot.BountyPaid(keeper, 0.999999e18, 0, 0, "chost");
        uint256 paid = _pay(0.999999e18, 100e18);

        assertEq(paid, 0, "a job below the dust guard pays nothing");
        assertEq(pot.balance(), 100 * ONE_USDG, "and costs the pot nothing");
        assertEq(pot.spentLast24h(), 0, "and does not consume the daily budget");
    }

    function test_chostBoundaryIsInclusiveOfTheGuardValue() public {
        _fund(100 * ONE_USDG);

        // Exactly at the guard: the job is worth doing, so it is paid.
        uint256 paid = _pay(1e18, 100e18);
        assertEq(paid, 70_000, "$0.05 tip + 2% of $1");

        (uint256 quoted, bytes32 reason) = pot.quote(1e18 - 1, 100e18);
        assertEq(quoted, 0);
        assertEq(reason, "chost");
    }

    function test_gasCapBindsWithoutRefusing() public {
        _fund(100 * ONE_USDG);

        // $100 of work would earn $2.05, but the job only burned $0.50 of gas at the capped basefee.
        uint256 paid = _pay(100e18, 0.5e18);

        assertEq(paid, 1_500_000, "3 x the gas cost is the ceiling");
        (, bytes32 reason) = pot.quote(100e18, 0.5e18);
        assertEq(reason, bytes32(0), "a binding cap that still pays is not a refusal");
    }

    function test_zeroGasCostPaysNothing() public {
        _fund(100 * ONE_USDG);

        vm.expectEmit(true, false, false, true, address(pot));
        emit IBountyPot.BountyPaid(keeper, 100e18, 0, 0, "gasCap");
        uint256 paid = _pay(100e18, 0);

        assertEq(paid, 0, "a job with no reported gas cost has a zero cap");
        assertEq(pot.balance(), 100 * ONE_USDG);
    }

    function test_gasCapMultipleIsAppliedExactly() public {
        _fund(1000 * ONE_USDG);

        // Work large enough that the gas cap always binds: the payment is exactly 3 x the gas cost.
        assertEq(_pay(10_000e18, 1e18), 3 * ONE_USDG);

        vm.prank(timelock);
        pot.setGasCapMultiple(1);
        assertEq(_pay(10_000e18, 1e18), ONE_USDG, "a 1x cap pays exactly the gas back");

        vm.prank(timelock);
        pot.setGasCapMultiple(10);
        assertEq(_pay(10_000e18, 1e18), 10 * ONE_USDG);
    }

    /* ------------------------------- daily ceiling ----------------------------- */

    function test_dailyCeilingClampsThenRefuses() public {
        _fund(1000 * ONE_USDG);
        vm.prank(timelock);
        pot.setDailyCeilingUsd18(3e18);

        assertEq(_pay(100e18, 100e18), 2_050_000, "the first job fits");
        assertEq(pot.budgetLeftUsd18(), 0.95e18);
        assertEq(pot.budgetLeftRaw(), 950_000);

        assertEq(_pay(100e18, 100e18), 950_000, "the second is clamped to what is left");
        assertEq(pot.budgetLeftUsd18(), 0);

        vm.expectEmit(true, false, false, true, address(pot));
        emit IBountyPot.BountyPaid(keeper, 100e18, 0, 0, "dailyCeiling");
        assertEq(_pay(100e18, 100e18), 0, "and the third is refused outright");

        assertEq(pot.spentLast24h(), 3e18, "exactly one ceiling was spent");
    }

    function test_dailyCeilingRollsOverAfterTwentyFourHours() public {
        _fund(1000 * ONE_USDG);
        vm.prank(timelock);
        pot.setDailyCeilingUsd18(3e18);

        _pay(100e18, 100e18);
        _pay(100e18, 100e18);
        assertEq(pot.budgetLeftUsd18(), 0);

        // One second short of the window: still nothing left.
        vm.warp(T0 + 1 days - 1);
        assertEq(pot.spentLast24h(), 3e18);
        assertEq(pot.budgetLeftUsd18(), 0);
        assertEq(_pay(100e18, 100e18), 0);

        // The window turns over and the whole ceiling is available again.
        vm.warp(T0 + 1 days);
        assertEq(pot.spentLast24h(), 0);
        assertEq(pot.budgetLeftUsd18(), 3e18);

        assertEq(_pay(100e18, 100e18), 2_050_000);
        assertEq(pot.windowStart(), uint32(T0 + 1 days), "a fresh window opens with the first payment after it");
        assertEq(pot.spentLast24h(), 2.05e18);
    }

    function test_zeroCeilingPausesPaidKeepingWithoutPausingTheJobs() public {
        _fund(1000 * ONE_USDG);
        vm.prank(timelock);
        pot.setDailyCeilingUsd18(0);

        (uint256 quoted, bytes32 reason) = pot.quote(100e18, 100e18);
        assertEq(quoted, 0);
        assertEq(reason, "dailyCeiling");
        assertEq(_pay(100e18, 100e18), 0, "the job still runs; it is simply unpaid");
        assertEq(pot.balance(), 1000 * ONE_USDG);
    }

    /* --------------------------------- depletion ------------------------------- */

    function test_depletedPotPaysWhatIsLeftAndThenNothing() public {
        _fund(ONE_USDG); // $1 in the pot against a $2.05 bounty.

        uint256 paid = _pay(100e18, 100e18);
        assertEq(paid, ONE_USDG, "it pays what it has");
        assertEq(pot.balance(), 0);
        assertEq(pot.spentLast24h(), 1e18, "and charges the ceiling only for what left");

        vm.expectEmit(true, false, false, true, address(pot));
        emit IBountyPot.BountyPaid(keeper, 100e18, 0, 0, "depleted");
        assertEq(_pay(100e18, 100e18), 0, "an empty pot refuses without reverting");
    }

    function test_emptyPotNeverReverts() public {
        assertEq(pot.balance(), 0);

        // Every shape of job against an empty pot: all return zero, none revert.
        assertEq(_pay(100e18, 100e18), 0);
        assertEq(_pay(0, 0), 0);
        assertEq(_pay(type(uint128).max, type(uint128).max), 0);
        assertEq(_pay(1e18, 1), 0);
    }

    function test_paymentRoundingBelowOneRawUnitPaysNothing() public {
        _fund(100 * ONE_USDG);
        vm.startPrank(timelock);
        pot.setTipUsd18(0);
        pot.setChipBps(0);
        pot.setChostUsd18(0);
        vm.stopPrank();

        // Nothing is payable at all: no cap bound it, the amount is simply below one raw unit of USDG.
        (uint256 quoted, bytes32 reason) = pot.quote(100e18, 100e18);
        assertEq(quoted, 0);
        assertEq(reason, "depleted", "the documented fallback reason for an unpayable dust amount");
        assertEq(_pay(100e18, 100e18), 0);
    }

    /* ------------------------------ the spam campaign --------------------------- */

    function test_spamCampaignOfSubChostJobsPaysExactlyZero() public {
        _fund(1000 * ONE_USDG);
        uint256 balanceBefore = pot.balance();

        // 250 dust-sized `compound()` calls, each just under the guard, submitted over half a day.
        for (uint256 i; i < 250; ++i) {
            vm.warp(T0 + i * 120);
            uint256 work = pot.chostUsd18() - 1 - (i % 1000);
            (uint256 quoted, bytes32 reason) = pot.quote(work, 100e18);
            assertEq(quoted, 0, "the quote refuses the spam before it is even submitted");
            assertEq(reason, "chost");
            assertEq(_pay(work, 100e18), 0, "and the payment refuses it again");
        }

        assertEq(pot.balance(), balanceBefore, "a spam campaign costs the pot nothing at all");
        assertEq(pot.spentLast24h(), 0, "and never touches the daily budget");
        assertEq(usdg.balanceOf(keeper), 0);
    }

    /* ---------------------------------- quote ---------------------------------- */

    function test_quoteMatchesPayAndMutatesNothing() public {
        _fund(100 * ONE_USDG);

        (uint256 quoted, bytes32 reason) = pot.quote(100e18, 1e18);
        assertEq(reason, bytes32(0));
        assertEq(pot.balance(), 100 * ONE_USDG, "quote is a view: nothing moved");
        assertEq(pot.spentLast24h(), 0);

        assertEq(_pay(100e18, 1e18), quoted, "quote predicts pay exactly");
    }

    /* ------------------------------ access control ----------------------------- */

    function test_onlyVaultMayPay() public {
        _fund(100 * ONE_USDG);

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, keeper));
        vm.prank(keeper);
        pot.pay(keeper, 100e18, 100e18);

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, timelock));
        vm.prank(timelock);
        pot.pay(keeper, 100e18, 100e18);

        assertEq(_pay(100e18, 100e18), 2_050_000);
    }

    function test_payRejectsAZeroRecipient() public {
        _fund(100 * ONE_USDG);

        vm.expectRevert(ZeroAddress.selector);
        vm.prank(vaultAddr);
        pot.pay(address(0), 100e18, 100e18);
    }

    function test_setVaultHandsTheRoleOnAtomically() public {
        _fund(100 * ONE_USDG);
        address newVault = makeAddr("newVault");

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, timelock));
        vm.prank(timelock);
        pot.setVault(newVault);

        vm.expectEmit(true, true, false, false, address(pot));
        emit IBountyPot.VaultChanged(vaultAddr, newVault);
        vm.prank(vaultAddr);
        pot.setVault(newVault);
        assertEq(pot.vault(), newVault);

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, vaultAddr));
        vm.prank(vaultAddr);
        pot.pay(keeper, 100e18, 100e18);

        vm.prank(newVault);
        assertEq(pot.pay(keeper, 100e18, 100e18), 2_050_000);
    }

    function test_setVaultRejectsZero() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(vaultAddr);
        pot.setVault(address(0));
    }

    /* ----------------------------------- sweep --------------------------------- */

    function test_sweepIsTimelockOnly() public {
        _fund(100 * ONE_USDG);

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, keeper));
        vm.prank(keeper);
        pot.pay(keeper, 1e18, 1e18);

        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, vaultAddr));
        vm.prank(vaultAddr);
        pot.sweep(vaultAddr, 1);

        vm.expectEmit(true, false, false, true, address(pot));
        emit IBountyPot.PotSwept(funder, 40 * ONE_USDG);
        vm.prank(timelock);
        pot.sweep(funder, 40 * ONE_USDG);

        assertEq(pot.balance(), 60 * ONE_USDG);
        assertEq(usdg.balanceOf(funder), 40 * ONE_USDG);
    }

    function test_sweepRejectsZeroArguments() public {
        _fund(10 * ONE_USDG);

        vm.startPrank(timelock);
        vm.expectRevert(ZeroAddress.selector);
        pot.sweep(address(0), 1);

        vm.expectRevert(ZeroAmount.selector);
        pot.sweep(funder, 0);
        vm.stopPrank();
    }

    /* ---------------------------- governed parameters -------------------------- */

    function test_settersAreTimelockOnly() public {
        vm.startPrank(vaultAddr);

        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, vaultAddr));
        pot.setTipUsd18(1e18);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, vaultAddr));
        pot.setChipBps(100);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, vaultAddr));
        pot.setChostUsd18(1e18);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, vaultAddr));
        pot.setGasCapMultiple(2);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, vaultAddr));
        pot.setDailyCeilingUsd18(1e18);

        vm.stopPrank();
    }

    function test_settersEmitAndMove() public {
        vm.startPrank(timelock);

        vm.expectEmit(true, false, false, true, address(pot));
        emit IBountyPot.BountyParameterChanged("tipUsd18", 0.05e18, 0.25e18);
        pot.setTipUsd18(0.25e18);
        assertEq(pot.tipUsd18(), 0.25e18);

        vm.expectEmit(true, false, false, true, address(pot));
        emit IBountyPot.BountyParameterChanged("chipBps", 200, 500);
        pot.setChipBps(500);
        assertEq(pot.chipBps(), 500);

        vm.expectEmit(true, false, false, true, address(pot));
        emit IBountyPot.BountyParameterChanged("chostUsd18", 1e18, 5e18);
        pot.setChostUsd18(5e18);
        assertEq(pot.chostUsd18(), 5e18);

        vm.expectEmit(true, false, false, true, address(pot));
        emit IBountyPot.BountyParameterChanged("gasCapMultiple", 3, 5);
        pot.setGasCapMultiple(5);
        assertEq(pot.gasCapMultiple(), 5);

        vm.expectEmit(true, false, false, true, address(pot));
        emit IBountyPot.BountyParameterChanged("dailyCeilingUsd18", pot.DAILY_CEILING_USD18_DEFAULT(), 500e18);
        pot.setDailyCeilingUsd18(500e18);
        assertEq(pot.dailyCeilingUsd18(), 500e18);

        vm.stopPrank();
    }

    function test_everySetterRespectsItsBand() public {
        vm.startPrank(timelock);

        uint256 tipMax = pot.TIP_USD18_MAX();
        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("tipUsd18"), tipMax + 1, 0, tipMax));
        pot.setTipUsd18(tipMax + 1);
        pot.setTipUsd18(tipMax);
        pot.setTipUsd18(0);

        uint16 chipMax = pot.CHIP_BPS_MAX();
        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("chipBps"), chipMax + 1, 0, chipMax));
        pot.setChipBps(chipMax + 1);
        pot.setChipBps(chipMax);
        pot.setChipBps(0);

        uint256 chostMax = pot.CHOST_USD18_MAX();
        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("chostUsd18"), chostMax + 1, 0, chostMax));
        pot.setChostUsd18(chostMax + 1);
        pot.setChostUsd18(chostMax);
        pot.setChostUsd18(0);

        uint16 gasMin = pot.GAS_CAP_MULTIPLE_MIN();
        uint16 gasMax = pot.GAS_CAP_MULTIPLE_MAX();
        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("gasCapMultiple"), 0, gasMin, gasMax));
        pot.setGasCapMultiple(0);
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("gasCapMultiple"), gasMax + 1, gasMin, gasMax)
        );
        pot.setGasCapMultiple(gasMax + 1);
        pot.setGasCapMultiple(gasMin);
        pot.setGasCapMultiple(gasMax);

        uint256 ceilingMax = pot.DAILY_CEILING_USD18_MAX();
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("dailyCeilingUsd18"), ceilingMax + 1, 0, ceilingMax)
        );
        pot.setDailyCeilingUsd18(ceilingMax + 1);
        pot.setDailyCeilingUsd18(ceilingMax);
        pot.setDailyCeilingUsd18(0);

        vm.stopPrank();
    }

    function test_loweringTheCeilingMidWindowStopsFurtherPayments() public {
        _fund(1000 * ONE_USDG);
        _pay(100e18, 100e18); // $2.05 spent.

        vm.prank(timelock);
        pot.setDailyCeilingUsd18(1e18);

        assertEq(pot.budgetLeftUsd18(), 0, "spending already past a lowered ceiling leaves nothing, never a debt");
        assertEq(_pay(100e18, 100e18), 0);
    }
}
