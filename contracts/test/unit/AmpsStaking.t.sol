// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsStaking} from "../../src/interfaces/IAmpsStaking.sol";
import {AmpsStaking} from "../../src/staking/AmpsStaking.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotTimelock, NotVault, OutOfBand, ZeroAddress} from "../../src/types/Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Unit tests for xAMPS: the reward stream's arithmetic, the anti-sandwich property that the stream
///         exists for, the virtual-shares defence, invariant I36 and the whole access-control surface.
/// @dev    The test contract is AMPS's *token* vault (so it can mint) while `vaultAddr` is the staking contract's
///         vault role. Keeping them separate is deliberate: every "only vault" assertion below would pass
///         vacuously if the minter and the notifier were the same address.
contract AmpsStakingTest is Test {
    /// @dev A realistic launch-era timestamp, so `uint32` casts and 7-day windows are exercised at real values.
    uint256 internal constant T0 = 1_800_000_000;

    /// @dev The launch stream length, 24 h.
    uint32 internal constant STREAM = Constants.REWARD_STREAM_SECONDS_DEFAULT;

    Amps internal amps;
    AmpsStaking internal staking;

    address internal vaultAddr = makeAddr("vault");
    address internal timelock = makeAddr("timelock");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        vm.warp(T0);
        amps = new Amps(address(this));
        staking = new AmpsStaking(IERC20(address(amps)), vaultAddr, timelock);
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev Mints AMPS to `to` (the test contract is the token's vault).
    function _mint(address to, uint256 amount) internal {
        amps.mint(to, amount);
    }

    /// @dev Funds `who` and stakes `amount` for them, returning the shares minted.
    function _stake(address who, uint256 amount) internal returns (uint256 shares) {
        _mint(who, amount);
        vm.startPrank(who);
        amps.approve(address(staking), amount);
        shares = staking.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev The production notification sequence from `docs/phase2-state-model.md` §3: the vault transfers the
    ///      AMPS and then notifies, in that order, in one transaction.
    function _notify(uint256 amount) internal {
        _mint(vaultAddr, amount);
        vm.startPrank(vaultAddr);
        amps.transfer(address(staking), amount);
        staking.notifyReward(amount);
        vm.stopPrank();
    }

    /* -------------------------------- metadata -------------------------------- */

    function test_metadata() public view {
        assertEq(staking.name(), "Staked Amplestocks");
        assertEq(staking.symbol(), "xAMPS");
        assertEq(staking.decimals(), 21, "18 asset decimals + a 3-decimal virtual-shares offset");
        assertEq(staking.asset(), address(amps));
        assertEq(staking.vault(), vaultAddr);
        assertEq(staking.timelock(), timelock);
        assertEq(staking.totalAssets(), 0);
        assertEq(staking.totalSupply(), 0);
        assertEq(staking.totalNotified(), 0);
        assertEq(staking.pendingRewards(), 0);
        assertEq(staking.lastAccrualAt(), uint32(T0), "lastAccrualAt is stamped at deployment");
    }

    function test_bandsAndConstantsAreRestatedFromConstants() public view {
        assertEq(staking.rewardStreamSeconds(), Constants.REWARD_STREAM_SECONDS_DEFAULT);
        assertEq(staking.REWARD_STREAM_SECONDS_MIN(), Constants.REWARD_STREAM_SECONDS_MIN);
        assertEq(staking.REWARD_STREAM_SECONDS_MAX(), Constants.REWARD_STREAM_SECONDS_MAX);
        assertEq(staking.DECIMALS_OFFSET(), Constants.STAKING_DECIMALS_OFFSET);
        assertEq(staking.STAKER_BPS_MAX(), Constants.STAKER_BPS_MAX);

        assertEq(staking.REWARD_STREAM_SECONDS_MIN(), 1 hours);
        assertEq(staking.REWARD_STREAM_SECONDS_MAX(), 7 days);
        assertEq(staking.DECIMALS_OFFSET(), 3);
        assertEq(staking.STAKER_BPS_MAX(), 5000);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ZeroAddress.selector);
        new AmpsStaking(IERC20(address(0)), vaultAddr, timelock);

        vm.expectRevert(ZeroAddress.selector);
        new AmpsStaking(IERC20(address(amps)), address(0), timelock);

        vm.expectRevert(ZeroAddress.selector);
        new AmpsStaking(IERC20(address(amps)), vaultAddr, address(0));
    }

    function test_constructorEmitsVaultChanged() public {
        vm.expectEmit(true, true, false, false);
        emit IAmpsStaking.VaultChanged(address(0), vaultAddr);
        new AmpsStaking(IERC20(address(amps)), vaultAddr, timelock);
    }

    /* ---------------------------- deposit / withdraw --------------------------- */

    function test_depositWithdrawRoundTrip() public {
        uint256 shares = _stake(alice, 100e18);

        assertEq(shares, 100e18 * 1000, "first deposit mints assets x 10**offset");
        assertEq(staking.totalAssets(), 100e18);
        assertEq(staking.balanceOf(alice), shares);
        assertEq(amps.balanceOf(alice), 0);

        vm.prank(alice);
        uint256 assets = staking.redeem(shares, alice, alice);

        assertLe(assets, 100e18, "a round trip never returns more than it put in");
        assertGe(assets, 100e18 - 2, "and loses at most the rounding");
        assertEq(staking.balanceOf(alice), 0);
        assertEq(staking.totalSupply(), 0);
    }

    function test_mintRedeemRoundTrip() public {
        _mint(alice, 200e18);
        vm.startPrank(alice);
        amps.approve(address(staking), type(uint256).max);

        uint256 assets = staking.mint(100e18 * 1000, alice);
        assertEq(assets, 100e18);

        uint256 back = staking.withdraw(assets - 2, alice, alice);
        vm.stopPrank();

        assertLe(back, 100e18 * 1000, "withdrawing assets never burns more shares than were minted");
    }

    function test_withdrawWithAllowance() public {
        uint256 shares = _stake(alice, 50e18);

        vm.prank(alice);
        staking.approve(bob, shares);

        vm.prank(bob);
        uint256 assets = staking.redeem(shares, bob, alice);

        assertGt(assets, 0);
        assertEq(amps.balanceOf(bob), assets);
        assertEq(staking.allowance(alice, bob), 0);
    }

    /* ------------------------------- stream maths ------------------------------ */

    function test_streamReleasesLinearlyAtEveryQuarter() public {
        _stake(alice, 1000e18);
        _notify(240e18);

        uint256 rate = uint256(240e18) / STREAM;
        assertEq(staking.rewardRate(), rate);
        assertEq(staking.streamEnd(), uint32(T0 + STREAM));
        assertEq(staking.totalNotified(), 240e18);

        // 0% elapsed: the tranche is entirely invisible to the share price.
        assertEq(staking.pendingRewards(), 240e18);
        assertEq(staking.totalAssets(), 1000e18, "a fresh tranche does not move totalAssets at all");
        assertEq(staking.releasedRewards(), 0);

        // 25%.
        vm.warp(T0 + STREAM / 4);
        assertEq(staking.totalAssets(), 1000e18 + rate * (STREAM / 4));
        assertEq(staking.pendingRewards(), 240e18 - rate * (STREAM / 4));

        // 50%.
        vm.warp(T0 + STREAM / 2);
        assertEq(staking.totalAssets(), 1000e18 + rate * (STREAM / 2));

        // 100%: the floor-division dust is released with the last step, so the whole tranche has landed.
        vm.warp(T0 + STREAM);
        assertEq(staking.pendingRewards(), 0);
        assertEq(staking.totalAssets(), 1000e18 + 240e18, "the whole tranche is released by streamEnd");
        assertEq(staking.releasedRewards(), 240e18);

        // Past the end nothing changes.
        vm.warp(T0 + 10 * STREAM);
        assertEq(staking.pendingRewards(), 0);
        assertEq(staking.totalAssets(), 1240e18);
    }

    function test_streamSecondsRemaining() public {
        assertEq(staking.streamSecondsRemaining(), 0, "nothing streaming before the first notification");

        _stake(alice, 1e18);
        _notify(10e18);
        assertEq(staking.streamSecondsRemaining(), STREAM);

        vm.warp(T0 + STREAM / 2);
        assertEq(staking.streamSecondsRemaining(), STREAM / 2);

        vm.warp(T0 + STREAM + 1);
        assertEq(staking.streamSecondsRemaining(), 0);
    }

    function test_reNotifyMidStreamFoldsTheRemainderAndNeverSpikes() public {
        _stake(alice, 1000e18);
        _notify(240e18);

        uint256 rateBefore = staking.rewardRate();

        vm.warp(T0 + STREAM / 2);
        uint256 remainder = staking.pendingRewards();
        uint256 releasedFirst = staking.releasedRewards();
        assertApproxEqAbs(remainder, 120e18, STREAM, "half the first tranche is still undistributed");

        _notify(240e18);

        assertEq(staking.pendingRewards(), remainder + 240e18, "the remainder is folded into the new tranche");
        assertEq(staking.streamEnd(), uint32(T0 + STREAM / 2 + STREAM), "and re-timed over a fresh window");
        assertEq(staking.totalNotified(), 480e18);
        assertEq(staking.releasedRewards(), releasedFirst, "folding releases nothing by itself");
        assertLt(staking.rewardRate(), rateBefore * 2, "the rate rises but never spikes");

        // Everything notified lands by the new stream end and nothing is lost in the fold.
        vm.warp(T0 + STREAM / 2 + STREAM);
        assertEq(staking.pendingRewards(), 0);
        assertEq(staking.totalAssets(), 1000e18 + 480e18);
    }

    function test_accrueIsPermissionlessAndValueNeutral() public {
        _stake(alice, 1000e18);
        _notify(240e18);
        vm.warp(T0 + 9 hours);

        uint256 assetsBefore = staking.totalAssets();
        uint256 pendingBefore = staking.pendingRewards();
        uint256 previewBefore = staking.previewDeposit(1e18);

        vm.prank(bob);
        staking.accrue();

        assertEq(staking.totalAssets(), assetsBefore, "accrue is a checkpoint, not a state transition");
        assertEq(staking.pendingRewards(), pendingBefore);
        assertEq(staking.previewDeposit(1e18), previewBefore);
        assertEq(staking.lastAccrualAt(), uint32(T0 + 9 hours));

        // Idempotent inside one second.
        staking.accrue();
        assertEq(staking.totalAssets(), assetsBefore);
    }

    function test_depositCheckpointsTheStream() public {
        _stake(alice, 1000e18);
        _notify(240e18);
        vm.warp(T0 + 6 hours);

        _stake(bob, 1e18);
        assertEq(staking.lastAccrualAt(), uint32(T0 + 6 hours), "every deposit checkpoints first");
    }

    function test_rewardsNotifiedWithNoStakersAreNotLost() public {
        _notify(100e18);
        vm.warp(T0 + STREAM);

        assertEq(staking.totalAssets(), 100e18, "released with nobody staked");

        // The next depositor buys in at the raised share price and the virtual shares keep the rest.
        uint256 shares = _stake(alice, 100e18);
        assertGt(shares, 0);
        vm.prank(alice);
        uint256 out = staking.redeem(shares, alice, alice);
        assertLe(out, 100e18 + 100e18, "never more than everything in the vault");
        assertGe(out, 90e18, "and the depositor is not expropriated");
    }

    /* ------------------------------- anti-sandwich ----------------------------- */

    function test_sandwichAtZeroElapsedEarnsExactlyNothing() public {
        _stake(bob, 1000e18);

        uint256 aliceStake = 1000e18;
        uint256 shares = _stake(alice, aliceStake);

        // The whole compound-sandwich, inside one block: stake, the vault compounds, unstake.
        _notify(240e18);

        vm.prank(alice);
        uint256 out = staking.redeem(shares, alice, alice);

        assertLe(out, aliceStake, "a zero-elapsed sandwich earns nothing");
        assertGe(out, aliceStake - 2, "and loses only the rounding");
    }

    function test_sandwichEarnsNoMoreThanItsTimeWeightedShare() public {
        _stake(bob, 1000e18);
        uint256 aliceStake = 1000e18;
        uint256 shares = _stake(alice, aliceStake);

        _notify(240e18);
        uint256 rate = uint256(240e18) / STREAM;

        // Alice holds for one minute of a 24-hour stream.
        vm.warp(T0 + 60);
        vm.prank(alice);
        uint256 out = staking.redeem(shares, alice, alice);

        uint256 released = rate * 60;
        uint256 fairShare = released / 2; // Alice holds half the supply for the whole 60 s.

        assertLe(out, aliceStake + fairShare + 2, "no more than the time-weighted share of what vested");
        assertLt(out - aliceStake, 240e18 / 1000, "which is a rounding error against the tranche itself");
    }

    /* -------------------------- inflation and donations ------------------------ */

    function test_firstDepositorInflationAttackIsUnprofitable() public {
        // The classic attack: seed one wei, donate to inflate the share price, front-run the victim's deposit.
        uint256 donation = 100e18;
        uint256 victimDeposit = 100e18;

        uint256 attackerShares = _stake(attacker, 1);
        _mint(attacker, donation);
        vm.prank(attacker);
        amps.transfer(address(staking), donation);

        uint256 victimShares = _stake(alice, victimDeposit);
        assertGt(victimShares, 0, "the offset keeps the victim's deposit from rounding to zero shares");

        vm.prank(attacker);
        uint256 attackerOut = staking.redeem(attackerShares, attacker, attacker);
        vm.prank(alice);
        uint256 victimOut = staking.redeem(victimShares, alice, alice);

        assertLt(attackerOut, 1 + donation, "the attack costs more than it returns");
        assertLe(attackerOut, donation * 51 / 100, "the attacker recovers about half of the subsidy, never all");
        assertGe(victimOut, (victimDeposit * 999) / 1000, "while the victim keeps all but a rounding slip");
        assertGt(
            (1 + donation) - attackerOut,
            victimDeposit - victimOut,
            "the attacker loses far more than the victim: the attack is a subsidy, not a theft"
        );
    }

    function test_donationRaisesEveryHoldersSharePrice() public {
        uint256 aliceShares = _stake(alice, 100e18);
        uint256 bobShares = _stake(bob, 300e18);

        uint256 aliceBefore = staking.previewRedeem(aliceShares);
        uint256 bobBefore = staking.previewRedeem(bobShares);

        _mint(attacker, 40e18);
        vm.prank(attacker);
        amps.transfer(address(staking), 40e18);

        assertEq(staking.totalAssets(), 440e18, "a donation is counted immediately, unlike a notified tranche");
        assertGt(staking.previewRedeem(aliceShares), aliceBefore);
        assertGt(staking.previewRedeem(bobShares), bobBefore);

        // Pro rata, to within rounding: Alice holds a quarter of the stake, so she takes a quarter of the gift.
        assertApproxEqAbs(staking.previewRedeem(aliceShares) - aliceBefore, 10e18, 1e12);
        assertApproxEqAbs(staking.previewRedeem(bobShares) - bobBefore, 30e18, 1e12);
        assertEq(amps.balanceOf(attacker), 0, "the donor keeps nothing");
    }

    /* ---------------------------------- I36 ------------------------------------ */

    function test_i36_totalAssetsNeverFallsExceptOnWithdrawal() public {
        uint256 aliceShares = _stake(alice, 100e18);
        uint256 seen = staking.totalAssets();

        _notify(50e18);
        seen = _assertNonDecreasing(seen);

        vm.warp(T0 + 3 hours);
        seen = _assertNonDecreasing(seen);

        _stake(bob, 400e18);
        seen = _assertNonDecreasing(seen);

        vm.warp(T0 + 12 hours);
        _notify(50e18);
        seen = _assertNonDecreasing(seen);

        vm.warp(T0 + 40 hours);
        seen = _assertNonDecreasing(seen);

        vm.prank(timelock);
        staking.setRewardStreamSeconds(2 hours);
        seen = _assertNonDecreasing(seen);

        vm.prank(vaultAddr);
        staking.setVault(bob);
        seen = _assertNonDecreasing(seen);

        // Only the withdrawal is allowed to move it down, and by exactly what left.
        uint256 before = staking.totalAssets();
        vm.prank(alice);
        uint256 out = staking.redeem(aliceShares, alice, alice);
        assertEq(staking.totalAssets(), before - out, "a withdrawal moves totalAssets by exactly what it paid");

        assertLe(staking.releasedRewards(), staking.totalNotified(), "released never exceeds notified");
    }

    function _assertNonDecreasing(uint256 previous) internal view returns (uint256 current) {
        current = staking.totalAssets();
        assertGe(current, previous, "I36: totalAssets fell outside a withdrawal");
        assertLe(staking.releasedRewards(), staking.totalNotified(), "I36: released exceeded notified");
    }

    /* ------------------------------ notifyReward ------------------------------- */

    function test_onlyVaultMayNotify() public {
        _mint(address(staking), 10e18);

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, alice));
        vm.prank(alice);
        staking.notifyReward(10e18);

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, timelock));
        vm.prank(timelock);
        staking.notifyReward(10e18);

        vm.prank(vaultAddr);
        staking.notifyReward(10e18);
        assertEq(staking.totalNotified(), 10e18);
    }

    function test_notifyZeroReverts() public {
        vm.expectRevert(IAmpsStaking.ZeroReward.selector);
        vm.prank(vaultAddr);
        staking.notifyReward(0);
    }

    function test_notifyWithoutFundingReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAmpsStaking.RewardNotFunded.selector, 10e18, 0));
        vm.prank(vaultAddr);
        staking.notifyReward(10e18);
    }

    function test_notifyUnfundedBeyondTheBalanceReverts() public {
        _stake(alice, 100e18);
        _notify(50e18);

        // The vault forgets the transfer. Folding 200 AMPS into the 50 still streaming would claim 250 AMPS of
        // undistributed remainder against a 150 AMPS balance, which would make totalAssets() underflow for every
        // subsequent caller, so the notification is refused instead.
        vm.expectRevert(abi.encodeWithSelector(IAmpsStaking.RewardNotFunded.selector, 250e18, 150e18));
        vm.prank(vaultAddr);
        staking.notifyReward(200e18);
    }

    /// @dev The residual trust boundary of the push funding model, stated as a test rather than left implicit:
    ///      the guard cannot tell an unfunded notification from a funded one when the contract happens to hold
    ///      enough already, so I36 holds for any vault that follows the documented transfer-then-notify sequence.
    ///      What the guard *does* guarantee unconditionally is solvency: the undistributed remainder can never
    ///      exceed the balance, so totalAssets() can never revert and the contract can never be bricked.
    function test_pendingNeverExceedsTheBalanceWhateverTheVaultDoes() public {
        _stake(alice, 100e18);
        _notify(50e18);
        _assertSolvent();

        // Every notification the guard lets through, funded or not, leaves the contract solvent.
        vm.prank(vaultAddr);
        staking.notifyReward(50e18);
        _assertSolvent();

        vm.warp(T0 + 3 hours);
        _assertSolvent();

        uint256 required = staking.pendingRewards() + 150e18;
        vm.expectRevert(abi.encodeWithSelector(IAmpsStaking.RewardNotFunded.selector, required, 150e18));
        vm.prank(vaultAddr);
        staking.notifyReward(150e18);

        vm.warp(T0 + 3 days);
        _assertSolvent();
        assertEq(staking.pendingRewards(), 0);
        assertEq(staking.totalAssets(), 150e18);
    }

    function _assertSolvent() internal view {
        assertLe(
            staking.pendingRewards(),
            amps.balanceOf(address(staking)),
            "the undistributed remainder must never exceed the balance"
        );
        staking.totalAssets();
    }

    function test_notifyEmitsRewardNotified() public {
        _mint(vaultAddr, 7e18);
        vm.startPrank(vaultAddr);
        amps.transfer(address(staking), 7e18);

        vm.expectEmit(false, false, false, true, address(staking));
        emit IAmpsStaking.RewardNotified(7e18, uint32(T0 + STREAM));
        staking.notifyReward(7e18);
        vm.stopPrank();
    }

    /* --------------------------------- setVault -------------------------------- */

    function test_setVaultHandsTheRoleOnAtomically() public {
        address newVault = makeAddr("newVault");

        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, timelock));
        vm.prank(timelock);
        staking.setVault(newVault);

        vm.expectEmit(true, true, false, false, address(staking));
        emit IAmpsStaking.VaultChanged(vaultAddr, newVault);
        vm.prank(vaultAddr);
        staking.setVault(newVault);
        assertEq(staking.vault(), newVault);

        // The old vault is powerless and the new one works.
        _mint(address(staking), 5e18);
        vm.expectRevert(abi.encodeWithSelector(NotVault.selector, vaultAddr));
        vm.prank(vaultAddr);
        staking.notifyReward(5e18);

        vm.prank(newVault);
        staking.notifyReward(5e18);
        assertEq(staking.totalNotified(), 5e18);
    }

    function test_setVaultRejectsZero() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(vaultAddr);
        staking.setVault(address(0));
    }

    /* ---------------------------- governed parameters -------------------------- */

    function test_setRewardStreamSecondsIsTimelockOnly() public {
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, vaultAddr));
        vm.prank(vaultAddr);
        staking.setRewardStreamSeconds(2 hours);

        vm.expectEmit(false, false, false, true, address(staking));
        emit IAmpsStaking.RewardStreamSecondsChanged(STREAM, 2 hours);
        vm.prank(timelock);
        staking.setRewardStreamSeconds(2 hours);
        assertEq(staking.rewardStreamSeconds(), 2 hours);
    }

    function test_setRewardStreamSecondsRespectsItsBand() public {
        uint32 min = Constants.REWARD_STREAM_SECONDS_MIN;
        uint32 max = Constants.REWARD_STREAM_SECONDS_MAX;

        vm.startPrank(timelock);

        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("rewardStreamSeconds"), min - 1, min, max));
        staking.setRewardStreamSeconds(min - 1);

        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("rewardStreamSeconds"), max + 1, min, max));
        staking.setRewardStreamSeconds(max + 1);

        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("rewardStreamSeconds"), 0, min, max));
        staking.setRewardStreamSeconds(0);

        staking.setRewardStreamSeconds(min);
        assertEq(staking.rewardStreamSeconds(), min);
        staking.setRewardStreamSeconds(max);
        assertEq(staking.rewardStreamSeconds(), max);

        vm.stopPrank();
    }

    function test_setRewardStreamSecondsDoesNotRetimeALiveStream() public {
        _stake(alice, 100e18);
        _notify(240e18);

        uint32 endBefore = staking.streamEnd();
        uint256 rateBefore = staking.rewardRate();

        vm.prank(timelock);
        staking.setRewardStreamSeconds(Constants.REWARD_STREAM_SECONDS_MAX);

        assertEq(staking.streamEnd(), endBefore, "a running stream is not re-timed");
        assertEq(staking.rewardRate(), rateBefore);

        // The next tranche uses the new window.
        vm.warp(T0 + STREAM);
        _notify(1e18);
        assertEq(staking.streamEnd(), uint32(T0 + STREAM + Constants.REWARD_STREAM_SECONDS_MAX));
    }

    function test_shortestAndLongestStreamsBehave() public {
        vm.prank(timelock);
        staking.setRewardStreamSeconds(Constants.REWARD_STREAM_SECONDS_MIN);

        _stake(alice, 100e18);
        _notify(36e18);
        assertEq(staking.rewardRate(), uint256(36e18) / 1 hours);

        vm.warp(T0 + 1 hours);
        assertEq(staking.pendingRewards(), 0);
        assertEq(staking.totalAssets(), 136e18);

        vm.prank(timelock);
        staking.setRewardStreamSeconds(Constants.REWARD_STREAM_SECONDS_MAX);
        _notify(70e18);

        vm.warp(T0 + 1 hours + 7 days);
        assertEq(staking.pendingRewards(), 0);
        assertEq(staking.totalAssets(), 206e18);
    }
}
