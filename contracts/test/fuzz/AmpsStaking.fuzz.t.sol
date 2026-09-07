// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsStaking} from "../../src/interfaces/IAmpsStaking.sol";
import {AmpsStaking} from "../../src/staking/AmpsStaking.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotTimelock, NotVault, OutOfBand} from "../../src/types/Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Property fuzzing for xAMPS. Four families:
///         - the ERC-4626 contract itself (`previewX` equals what `X` does, round trips never profit);
///         - the stream (monotone, exact, and bounded by what was notified);
///         - invariant I36 over random operation sequences;
///         - the economics the stream exists for (no profitable compound-sandwich, no profitable first-depositor
///           inflation) and the access-control surface.
contract AmpsStakingFuzzTest is Test {
    uint256 internal constant T0 = 1_800_000_000;
    uint32 internal constant STREAM = Constants.REWARD_STREAM_SECONDS_DEFAULT;

    /// @dev The fuzz range for stakes and rewards: 1 gwei of AMPS up to a million AMPS, which brackets both the
    ///      5,000 AMPS genesis supply and any plausible post-bond supply.
    uint256 internal constant MIN_AMOUNT = 1e9;
    uint256 internal constant MAX_AMOUNT = 1_000_000e18;

    Amps internal amps;
    AmpsStaking internal staking;

    address internal vaultAddr = makeAddr("vault");
    address internal timelock = makeAddr("timelock");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(T0);
        amps = new Amps(address(this));
        staking = new AmpsStaking(IERC20(address(amps)), vaultAddr, timelock);
    }

    /* --------------------------------- helpers -------------------------------- */

    function _stake(address who, uint256 amount) internal returns (uint256 shares) {
        amps.mint(who, amount);
        vm.startPrank(who);
        amps.approve(address(staking), amount);
        shares = staking.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev The documented sequence: the vault transfers, then notifies, in one transaction.
    function _notify(uint256 amount) internal {
        amps.mint(vaultAddr, amount);
        vm.startPrank(vaultAddr);
        amps.transfer(address(staking), amount);
        staking.notifyReward(amount);
        vm.stopPrank();
    }

    function _donate(uint256 amount) internal {
        amps.mint(address(staking), amount);
    }

    /// @dev Puts the vault into an arbitrary but reachable state: two stakers, one reward tranche, some elapsed
    ///      time and an optional donation.
    function _seed(uint256 stakeA, uint256 stakeB, uint256 reward, uint256 donation, uint256 dt) internal {
        _stake(alice, bound(stakeA, MIN_AMOUNT, MAX_AMOUNT));
        _stake(bob, bound(stakeB, MIN_AMOUNT, MAX_AMOUNT));

        uint256 rewardAmount = bound(reward, 0, MAX_AMOUNT);
        if (rewardAmount > 0) _notify(rewardAmount);

        uint256 donationAmount = bound(donation, 0, MAX_AMOUNT);
        if (donationAmount > 0) _donate(donationAmount);

        vm.warp(T0 + bound(dt, 0, 14 days));
    }

    /* ------------------------- ERC-4626 preview equality ----------------------- */

    function testFuzz_previewDepositMatchesDeposit(uint256 stakeA, uint256 stakeB, uint256 reward, uint256 dt) public {
        _seed(stakeA, stakeB, reward, 0, dt);

        uint256 assets = bound(stakeA, MIN_AMOUNT, MAX_AMOUNT);
        amps.mint(address(this), assets);
        amps.approve(address(staking), assets);

        uint256 predicted = staking.previewDeposit(assets);
        assertEq(staking.deposit(assets, address(this)), predicted, "previewDeposit != deposit");
    }

    function testFuzz_previewMintMatchesMint(uint256 stakeA, uint256 stakeB, uint256 reward, uint256 dt) public {
        _seed(stakeA, stakeB, reward, 0, dt);

        uint256 shares = bound(stakeB, MIN_AMOUNT * 1000, MAX_AMOUNT);
        uint256 predicted = staking.previewMint(shares);

        amps.mint(address(this), predicted);
        amps.approve(address(staking), predicted);
        assertEq(staking.mint(shares, address(this)), predicted, "previewMint != mint");
    }

    function testFuzz_previewWithdrawMatchesWithdraw(uint256 stakeA, uint256 stakeB, uint256 reward, uint256 dt)
        public
    {
        _seed(stakeA, stakeB, reward, 0, dt);

        uint256 assets = bound(reward, 0, staking.maxWithdraw(alice));
        uint256 predicted = staking.previewWithdraw(assets);

        vm.prank(alice);
        assertEq(staking.withdraw(assets, alice, alice), predicted, "previewWithdraw != withdraw");
    }

    function testFuzz_previewRedeemMatchesRedeem(uint256 stakeA, uint256 stakeB, uint256 reward, uint256 dt) public {
        _seed(stakeA, stakeB, reward, 0, dt);

        uint256 shares = bound(reward, 0, staking.maxRedeem(bob));
        uint256 predicted = staking.previewRedeem(shares);

        vm.prank(bob);
        assertEq(staking.redeem(shares, bob, bob), predicted, "previewRedeem != redeem");
    }

    /* ------------------------------- round trips ------------------------------- */

    function testFuzz_depositRedeemRoundTripNeverProfits(
        uint256 stakeA,
        uint256 stakeB,
        uint256 reward,
        uint256 donation,
        uint256 amount
    ) public {
        _seed(stakeA, stakeB, reward, donation, 0);

        uint256 assetsIn = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        amps.mint(address(this), assetsIn);
        amps.approve(address(staking), assetsIn);

        uint256 shares = staking.deposit(assetsIn, address(this));
        uint256 oneShare = staking.convertToAssets(1);
        uint256 assetsBack = staking.redeem(shares, address(this), address(this));

        assertLe(assetsBack, assetsIn, "an instant round trip must never profit");
        // Stated additively so the bound holds even where one share is worth more than the whole deposit, which
        // is exactly the state a large donation puts the vault into.
        assertGe(assetsBack + oneShare + 2, assetsIn, "and must lose no more than the rounding: one share plus dust");
    }

    function testFuzz_mintWithdrawRoundTripNeverProfits(uint256 stakeA, uint256 stakeB, uint256 reward, uint256 amount)
        public
    {
        _seed(stakeA, stakeB, reward, 0, 0);

        uint256 shares = bound(amount, MIN_AMOUNT * 1000, MAX_AMOUNT);
        uint256 assetsIn = staking.previewMint(shares);
        amps.mint(address(this), assetsIn);
        amps.approve(address(staking), assetsIn);
        staking.mint(shares, address(this));

        uint256 maxOut = staking.maxWithdraw(address(this));
        assertLe(maxOut, assetsIn, "minting then withdrawing must never profit");
    }

    /* --------------------------------- the stream ------------------------------ */

    function testFuzz_totalAssetsIsBalanceMinusPending(
        uint256 stakeA,
        uint256 stakeB,
        uint256 reward,
        uint256 donation,
        uint256 dt
    ) public {
        _seed(stakeA, stakeB, reward, donation, dt);

        assertEq(
            staking.totalAssets(),
            amps.balanceOf(address(staking)) - staking.pendingRewards(),
            "totalAssets is balance minus the undistributed remainder, by definition"
        );
        assertLe(staking.pendingRewards(), amps.balanceOf(address(staking)), "the pot can never claim what it lacks");
        assertLe(staking.releasedRewards(), staking.totalNotified(), "released never exceeds notified");
    }

    function testFuzz_streamIsMonotoneAndExact(uint256 stake, uint256 reward, uint256[8] memory steps) public {
        _stake(alice, bound(stake, MIN_AMOUNT, MAX_AMOUNT));
        uint256 rewardAmount = bound(reward, MIN_AMOUNT, MAX_AMOUNT);
        _notify(rewardAmount);

        uint256 pendingBefore = staking.pendingRewards();
        uint256 assetsBefore = staking.totalAssets();
        assertEq(pendingBefore, rewardAmount, "nothing vests at zero elapsed time");

        uint256 t = T0;
        for (uint256 i; i < steps.length; ++i) {
            t += bound(steps[i], 0, 6 hours);
            vm.warp(t);

            uint256 pending = staking.pendingRewards();
            uint256 assets = staking.totalAssets();

            assertLe(pending, pendingBefore, "the remainder is non-increasing in time");
            assertGe(assets, assetsBefore, "and the share price only ever rises with it");
            assertEq(assets + pending, assetsBefore + pendingBefore, "value is conserved: nothing appears or leaks");

            pendingBefore = pending;
            assetsBefore = assets;
        }

        vm.warp(T0 + STREAM);
        assertEq(staking.pendingRewards(), 0, "the whole tranche, dust included, is released by streamEnd");
        assertEq(staking.releasedRewards(), rewardAmount);
    }

    function testFuzz_reNotifyFoldsTheRemainderExactly(uint256 stake, uint256 first, uint256 second, uint256 dt)
        public
    {
        _stake(alice, bound(stake, MIN_AMOUNT, MAX_AMOUNT));

        uint256 a = bound(first, MIN_AMOUNT, MAX_AMOUNT);
        uint256 b = bound(second, MIN_AMOUNT, MAX_AMOUNT);
        _notify(a);

        uint256 elapsed = bound(dt, 0, 2 * uint256(STREAM));
        vm.warp(T0 + elapsed);

        uint256 remainder = staking.pendingRewards();
        _notify(b);

        assertEq(staking.pendingRewards(), remainder + b, "the live remainder is folded in, never dropped");
        assertEq(staking.streamEnd(), uint32(T0 + elapsed + STREAM), "and re-timed over a fresh window");
        assertEq(staking.totalNotified(), a + b);

        vm.warp(T0 + elapsed + STREAM);
        assertEq(staking.pendingRewards(), 0);
        assertEq(staking.releasedRewards(), a + b, "everything notified is eventually released, exactly once");
    }

    /* ----------------------------------- I36 ----------------------------------- */

    function testFuzz_i36OverRandomOperationSequences(uint256[12] memory ops, uint256[12] memory amounts) public {
        _stake(alice, 1000e18);
        _stake(bob, 500e18);

        uint256 seen = staking.totalAssets();

        for (uint256 i; i < ops.length; ++i) {
            uint256 op = ops[i] % 5;
            uint256 amount = bound(amounts[i], 1, 10_000e18);

            if (op == 0) {
                _stake(alice, amount);
            } else if (op == 1) {
                _notify(amount);
            } else if (op == 2) {
                _donate(amount);
            } else if (op == 3) {
                vm.warp(block.timestamp + (amount % 3 days) + 1);
            } else {
                uint256 shares = bound(amount, 0, staking.maxRedeem(bob));
                uint256 before = staking.totalAssets();
                vm.prank(bob);
                uint256 out = staking.redeem(shares, bob, bob);
                assertEq(staking.totalAssets(), before - out, "a withdrawal moves totalAssets by exactly what it paid");
                seen = staking.totalAssets();
                continue;
            }

            uint256 current = staking.totalAssets();
            assertGe(current, seen, "I36: totalAssets fell outside a withdrawal");
            assertLe(staking.releasedRewards(), staking.totalNotified(), "I36: released exceeded notified");
            seen = current;
        }
    }

    /* -------------------------------- economics -------------------------------- */

    function testFuzz_sandwichNeverBeatsTheTimeWeightedShare(
        uint256 incumbent,
        uint256 sandwich,
        uint256 reward,
        uint256 dt
    ) public {
        uint256 held = bound(incumbent, MIN_AMOUNT, MAX_AMOUNT);
        uint256 stake = bound(sandwich, MIN_AMOUNT, MAX_AMOUNT);
        uint256 rewardAmount = bound(reward, MIN_AMOUNT, MAX_AMOUNT);
        uint256 elapsed = bound(dt, 0, 12 hours);

        _stake(bob, held);
        uint256 shares = _stake(alice, stake);

        // The sandwich: stake, let the vault compound, unstake `elapsed` seconds later.
        _notify(rewardAmount);
        vm.warp(T0 + elapsed);

        uint256 released = staking.releasedRewards();
        vm.prank(alice);
        uint256 out = staking.redeem(shares, alice, alice);

        if (elapsed == 0) {
            assertLe(out, stake, "a zero-elapsed sandwich earns exactly nothing");
        }
        assertLe(out, stake + released + 2, "and never more than everything that vested while it was in");

        // Tighter: never more than the pro-rata share of what vested, plus rounding.
        uint256 fairShare = (released * stake) / (stake + held);
        assertLe(out, stake + fairShare + 4, "a sandwich cannot beat its time-weighted share");
    }

    function testFuzz_firstDepositorInflationIsUnprofitable(uint256 seed, uint256 donation, uint256 victimDeposit)
        public
    {
        uint256 attackerSeed = bound(seed, 1, 1e12);
        uint256 gift = bound(donation, MIN_AMOUNT, MAX_AMOUNT);
        uint256 victimIn = bound(victimDeposit, MIN_AMOUNT, MAX_AMOUNT);

        uint256 attackerShares = _stake(address(this), attackerSeed);
        _donate(gift);

        uint256 victimShares = _stake(alice, victimIn);

        // The offset is what sets the price of the attack: rounding the victim's shares to zero costs a donation
        // of more than `10 ** DECIMALS_OFFSET` times the victim's deposit, i.e. over a thousand times what is
        // being stolen. Below that ratio the victim always receives shares.
        if (victimIn * (10 ** staking.DECIMALS_OFFSET()) > attackerSeed + gift) {
            assertGt(victimShares, 0, "the 3-decimal offset keeps a real deposit from rounding to zero shares");
        }

        uint256 attackerOut = staking.redeem(attackerShares, address(this), address(this));
        vm.prank(alice);
        uint256 victimOut = staking.redeem(victimShares, alice, alice);

        // `<=`, not `<`: at the exact break-even point (a maximal donation against a maximal victim deposit) the
        // attacker's withdrawal equals its outlay to the wei, which is a loss of the gas and the time value and
        // never a profit. The ci profile's 4,096 runs reach that point; the claim is "never profitable".
        assertLe(attackerOut, attackerSeed + gift, "the inflation attack never returns more than it cost");
        // The attacker's loss bounds the victim's loss from above, to within one wei of redemption rounding: at
        // the break-even point above the attacker loses nothing while the victim's own redemption floors a wei
        // that stays in the vault, owned by the virtual shares rather than by the attacker.
        assertGe(
            (attackerSeed + gift) - attackerOut + 1,
            victimIn - victimOut,
            "the attacker loses at least as much as the victim, to a wei of rounding: the donation is a subsidy"
        );
    }

    /* ----------------------------- access control ------------------------------ */

    function testFuzz_onlyVaultNotifiesAndHandsTheRoleOn(address caller, uint256 amount) public {
        vm.assume(caller != vaultAddr);
        uint256 value = bound(amount, 1, MAX_AMOUNT);
        _donate(value);

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, caller));
        vm.prank(caller);
        staking.notifyReward(value);

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, caller));
        vm.prank(caller);
        staking.setVault(caller);

        vm.prank(vaultAddr);
        staking.notifyReward(value);
        assertEq(staking.totalNotified(), value);
    }

    function testFuzz_onlyTimelockMovesTheStreamWindow(address caller, uint32 value) public {
        vm.assume(caller != timelock);

        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, caller));
        vm.prank(caller);
        staking.setRewardStreamSeconds(value);
    }

    function testFuzz_streamWindowBandIsExact(uint32 value) public {
        uint32 min = Constants.REWARD_STREAM_SECONDS_MIN;
        uint32 max = Constants.REWARD_STREAM_SECONDS_MAX;

        vm.prank(timelock);
        if (value < min || value > max) {
            vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("rewardStreamSeconds"), value, min, max));
            staking.setRewardStreamSeconds(value);
        } else {
            staking.setRewardStreamSeconds(value);
            assertEq(staking.rewardStreamSeconds(), value);
        }
    }

    function testFuzz_zeroNotificationAlwaysReverts(uint256 balanceSeed) public {
        _donate(bound(balanceSeed, 0, MAX_AMOUNT));

        vm.expectRevert(IAmpsStaking.ZeroReward.selector);
        vm.prank(vaultAddr);
        staking.notifyReward(0);
    }
}
