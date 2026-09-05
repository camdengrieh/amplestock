// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBountyPot} from "../../src/interfaces/IBountyPot.sol";
import {BountyPot} from "../../src/keeper/BountyPot.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotTimelock, NotVault, OutOfBand} from "../../src/types/Errors.sol";
import {MockUsdg} from "../mocks/MockUsdg.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Property fuzzing for the keeper bounty pot. The properties are the four caps stated as inequalities
///         that must hold for *every* reachable parameter set and *every* job the vault can report: no payment
///         exceeds the tip-plus-chip, the gas cap, the remaining daily budget or the pot's balance; a job below
///         the dust guard pays exactly zero however many times it is submitted; {BountyPot-quote} predicts
///         {BountyPot-pay} exactly; and {BountyPot-pay} never reverts for a cap or a depleted pot.
contract BountyPotFuzzTest is Test {
    uint256 internal constant T0 = 1_800_000_000;

    MockUsdg internal usdg;
    BountyPot internal pot;

    address internal vaultAddr = makeAddr("vault");
    address internal timelock = makeAddr("timelock");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(T0);
        usdg = new MockUsdg("USD Global", "USDG", 6);
        pot = new BountyPot(address(usdg), vaultAddr, timelock);
    }

    /* --------------------------------- helpers -------------------------------- */

    function _fund(uint256 amountRaw) internal {
        if (amountRaw == 0) return;
        usdg.mint(address(this), amountRaw);
        usdg.approve(address(pot), amountRaw);
        pot.fund(amountRaw);
    }

    function _pay(uint256 workValueUsd18, uint256 gasCostUsd18) internal returns (uint256 paidRaw) {
        vm.prank(vaultAddr);
        paidRaw = pot.pay(keeper, workValueUsd18, gasCostUsd18);
    }

    /// @dev Moves every governed parameter to a random point inside its band.
    function _governTo(uint256 tip, uint256 chip, uint256 chost, uint256 mult, uint256 ceiling) internal {
        vm.startPrank(timelock);
        pot.setTipUsd18(bound(tip, 0, pot.TIP_USD18_MAX()));
        pot.setChipBps(uint16(bound(chip, 0, pot.CHIP_BPS_MAX())));
        pot.setChostUsd18(bound(chost, 0, pot.CHOST_USD18_MAX()));
        pot.setGasCapMultiple(uint16(bound(mult, pot.GAS_CAP_MULTIPLE_MIN(), pot.GAS_CAP_MULTIPLE_MAX())));
        pot.setDailyCeilingUsd18(bound(ceiling, 0, pot.DAILY_CEILING_USD18_MAX()));
        vm.stopPrank();
    }

    /* ---------------------------------- caps ----------------------------------- */

    function testFuzz_noPaymentEverExceedsAnyCap(
        uint256 work,
        uint256 gas,
        uint256 funding,
        uint256 tip,
        uint256 chip,
        uint256 chost,
        uint256 mult,
        uint256 ceiling
    ) public {
        _governTo(tip, chip, chost, mult, ceiling);
        _fund(bound(funding, 0, 1_000_000e6));

        uint256 workValue = bound(work, 0, 1e30);
        uint256 gasCost = bound(gas, 0, 1e30);

        uint256 scale = pot.usdScale();
        uint256 balanceBefore = pot.balance();
        uint256 budgetBefore = pot.budgetLeftUsd18();

        uint256 paidRaw = _pay(workValue, gasCost);
        uint256 paidUsd18 = paidRaw * scale;

        assertLe(paidRaw, balanceBefore, "the pot never pays more than it holds");
        assertLe(paidUsd18, budgetBefore, "nor more than the daily budget still allows");
        assertLe(paidUsd18, uint256(pot.gasCapMultiple()) * gasCost, "nor more than the gas cap");
        assertLe(
            paidUsd18,
            pot.tipUsd18() + (workValue * pot.chipBps()) / Constants.BPS,
            "nor more than the tip plus the chip"
        );

        if (workValue < pot.chostUsd18()) {
            assertEq(paidRaw, 0, "a job below the dust guard is never paid");
        }

        assertEq(pot.balance(), balanceBefore - paidRaw, "the balance moves by exactly what was paid");
        assertEq(usdg.balanceOf(keeper), paidRaw);
    }

    function testFuzz_quotePredictsPayExactly(
        uint256 work,
        uint256 gas,
        uint256 funding,
        uint256 tip,
        uint256 chip,
        uint256 chost,
        uint256 mult,
        uint256 ceiling
    ) public {
        _governTo(tip, chip, chost, mult, ceiling);
        _fund(bound(funding, 0, 1_000_000e6));

        uint256 workValue = bound(work, 0, 1e30);
        uint256 gasCost = bound(gas, 0, 1e30);

        (uint256 quoted, bytes32 reason) = pot.quote(workValue, gasCost);
        assertEq(_pay(workValue, gasCost), quoted, "quote must predict pay exactly");

        if (quoted == 0) {
            assertTrue(
                reason == "chost" || reason == "gasCap" || reason == "dailyCeiling" || reason == "depleted",
                "a refusal always names one of the four enumerated reasons"
            );
        } else {
            assertEq(reason, bytes32(0), "a payment that lands is never a refusal");
        }
    }

    function testFuzz_payNeverRevertsForAnyJob(uint256 work, uint256 gas, uint256 funding) public {
        _fund(bound(funding, 0, 1_000_000e6));

        // Deliberately unbounded, including the values a broken keeper or a hostile vault could report.
        uint256 paidRaw = _pay(work, gas);
        assertLe(paidRaw, usdg.totalSupply(), "a payment is always well defined");
    }

    /* ------------------------------ the daily ceiling -------------------------- */

    function testFuzz_oneWindowNeverPaysMoreThanOneCeiling(
        uint256 ceiling,
        uint256[8] memory works,
        uint256[8] memory gaps
    ) public {
        uint256 cap = bound(ceiling, 0, 1000e18);
        vm.prank(timelock);
        pot.setDailyCeilingUsd18(cap);
        _fund(1_000_000e6);

        uint256 scale = pot.usdScale();
        uint256 total;
        uint256 t = T0;

        for (uint256 i; i < works.length; ++i) {
            // Keep every payment inside a single 24-hour window.
            t += bound(gaps[i], 0, 2 hours);
            vm.warp(t);

            total += _pay(bound(works[i], 1e18, 1e24), 1e24) * scale;

            assertLe(total, cap, "a single window can never pay out more than one ceiling");
            assertEq(pot.spentLast24h(), total, "and the window accounting tracks it exactly");
            assertEq(pot.budgetLeftUsd18(), cap - total);
        }
    }

    function testFuzz_windowRollsOverExactlyAtTwentyFourHours(uint256 ceiling, uint256 dt) public {
        uint256 cap = bound(ceiling, 1e18, 1000e18);
        vm.prank(timelock);
        pot.setDailyCeilingUsd18(cap);
        _fund(1_000_000e6);

        // Exhaust the window.
        for (uint256 i; i < 10 && pot.budgetLeftUsd18() > 0; ++i) {
            _pay(1e24, 1e24);
        }

        uint256 elapsed = bound(dt, 0, 2 days);
        vm.warp(T0 + elapsed);

        if (elapsed < 1 days) {
            assertGt(pot.spentLast24h(), 0, "the window is still open");
        } else {
            assertEq(pot.spentLast24h(), 0, "and turns over exactly at 24 hours");
            assertEq(pot.budgetLeftUsd18(), cap);
        }
    }

    /* ------------------------------ the spam campaign --------------------------- */

    function testFuzz_spamCampaignOfSubChostJobsPaysZero(uint256 chost, uint256[16] memory works, uint256 funding)
        public
    {
        uint256 guard = bound(chost, 1, pot.CHOST_USD18_MAX());
        vm.prank(timelock);
        pot.setChostUsd18(guard);

        uint256 funded = bound(funding, 1, 1_000_000e6);
        _fund(funded);

        for (uint256 i; i < works.length; ++i) {
            uint256 work = bound(works[i], 0, guard - 1);
            (uint256 quoted, bytes32 reason) = pot.quote(work, 1e24);
            assertEq(quoted, 0);
            assertEq(reason, "chost");
            assertEq(_pay(work, 1e24), 0, "no number of sub-chost jobs extracts anything");
        }

        assertEq(pot.balance(), funded, "the pot is untouched by the whole campaign");
        assertEq(pot.spentLast24h(), 0);
        assertEq(usdg.balanceOf(keeper), 0);
    }

    /* --------------------------------- decimals -------------------------------- */

    function testFuzz_scalingIsReadFromTheTokenNotAssumed(uint8 decimals, uint256 work, uint256 gas) public {
        uint8 dec = uint8(bound(decimals, 0, 18));
        MockUsdg token = new MockUsdg("Token", "TKN", dec);
        BountyPot scaled = new BountyPot(address(token), vaultAddr, timelock);

        uint256 scale = 10 ** (18 - uint256(dec));
        assertEq(scaled.usdScale(), scale);

        token.mint(address(this), type(uint128).max);
        token.approve(address(scaled), type(uint128).max);
        scaled.fund(type(uint128).max);

        uint256 workValue = bound(work, 1e18, 1e24);
        uint256 gasCost = bound(gas, 0, 1e24);

        vm.prank(vaultAddr);
        uint256 paidRaw = scaled.pay(keeper, workValue, gasCost);

        assertLe(
            paidRaw * scale,
            scaled.tipUsd18() + (workValue * scaled.chipBps()) / Constants.BPS,
            "the payment is the same USD amount whatever the token's decimals"
        );
        assertEq(token.balanceOf(keeper), paidRaw);
    }

    /* ------------------------------ access control ----------------------------- */

    function testFuzz_onlyVaultPaysAndHandsTheRoleOn(address caller, uint256 work, uint256 gas) public {
        vm.assume(caller != vaultAddr);
        _fund(1000e6);

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, caller));
        vm.prank(caller);
        pot.pay(keeper, work, gas);

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, caller));
        vm.prank(caller);
        pot.setVault(caller);
    }

    function testFuzz_onlyTimelockGovernsOrSweeps(address caller) public {
        vm.assume(caller != timelock);
        _fund(1000e6);

        vm.startPrank(caller);
        bytes memory expected = abi.encodeWithSelector(NotTimelock.selector, caller);

        vm.expectRevert(expected);
        pot.sweep(caller, 1);
        vm.expectRevert(expected);
        pot.setTipUsd18(0);
        vm.expectRevert(expected);
        pot.setChipBps(0);
        vm.expectRevert(expected);
        pot.setChostUsd18(0);
        vm.expectRevert(expected);
        pot.setGasCapMultiple(1);
        vm.expectRevert(expected);
        pot.setDailyCeilingUsd18(0);
        vm.stopPrank();
    }

    /* ----------------------------------- bands --------------------------------- */

    function testFuzz_tipBandIsExact(uint256 value) public {
        uint256 max = pot.TIP_USD18_MAX();
        vm.prank(timelock);
        if (value > max) {
            vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("tipUsd18"), value, 0, max));
            pot.setTipUsd18(value);
        } else {
            pot.setTipUsd18(value);
            assertEq(pot.tipUsd18(), value);
        }
    }

    function testFuzz_chipBandIsExact(uint16 value) public {
        uint16 max = pot.CHIP_BPS_MAX();
        vm.prank(timelock);
        if (value > max) {
            vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("chipBps"), value, 0, max));
            pot.setChipBps(value);
        } else {
            pot.setChipBps(value);
            assertEq(pot.chipBps(), value);
        }
    }

    function testFuzz_chostBandIsExact(uint256 value) public {
        uint256 max = pot.CHOST_USD18_MAX();
        vm.prank(timelock);
        if (value > max) {
            vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("chostUsd18"), value, 0, max));
            pot.setChostUsd18(value);
        } else {
            pot.setChostUsd18(value);
            assertEq(pot.chostUsd18(), value);
        }
    }

    function testFuzz_gasCapMultipleBandIsExact(uint16 value) public {
        uint16 min = pot.GAS_CAP_MULTIPLE_MIN();
        uint16 max = pot.GAS_CAP_MULTIPLE_MAX();
        vm.prank(timelock);
        if (value < min || value > max) {
            vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("gasCapMultiple"), value, min, max));
            pot.setGasCapMultiple(value);
        } else {
            pot.setGasCapMultiple(value);
            assertEq(pot.gasCapMultiple(), value);
        }
    }

    function testFuzz_dailyCeilingBandIsExact(uint256 value) public {
        uint256 max = pot.DAILY_CEILING_USD18_MAX();
        vm.prank(timelock);
        if (value > max) {
            vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("dailyCeilingUsd18"), value, 0, max));
            pot.setDailyCeilingUsd18(value);
        } else {
            pot.setDailyCeilingUsd18(value);
            assertEq(pot.dailyCeilingUsd18(), value);
        }
    }

    /* ---------------------------- funding and sweeping -------------------------- */

    function testFuzz_fundAndSweepConserveTheBalance(uint256 funding, uint256 sweepAmount, address recipient) public {
        vm.assume(recipient != address(0) && recipient != address(pot));
        uint256 funded = bound(funding, 1, 1_000_000e6);
        uint256 taken = bound(sweepAmount, 1, funded);

        _fund(funded);
        assertEq(pot.balance(), funded);

        uint256 recipientBefore = usdg.balanceOf(recipient);
        vm.prank(timelock);
        pot.sweep(recipient, taken);

        assertEq(pot.balance(), funded - taken, "a sweep moves exactly what it says");
        assertEq(usdg.balanceOf(recipient), recipientBefore + taken);
    }
}
