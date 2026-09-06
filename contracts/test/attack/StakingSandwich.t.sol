// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {console} from "forge-std/console.sol";

/// @title StakingSandwichTest
/// @notice The plan's named attack **staking sandwich around `compound`**: "the 24 h stream leaves a same-block
///         stake/unstake with nothing".
///
///         `AmpsVault.compound` hands the staker slice to `AmpsStaking.notifyReward`, which releases it linearly
///         over `rewardStreamSeconds`. A depositor who arrives in the same block as the compound and leaves in the
///         same block has been staked for zero seconds, so zero of the stream has been released and there is
///         nothing to take. The honest staker who was there all along keeps the whole slice.
contract StakingSandwichTest is Phase3Fixture {
    address internal constant SANDWICHER = address(0x54D41C4);
    address internal constant HONEST = address(0x40E57);

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(100_000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    /// @notice Deposit immediately before `compound`, withdraw immediately after, in the same transaction: the
    ///         sandwicher gets back what they put in and not a wei more.
    function test_sameBlockSandwichEarnsNothing() public {
        giveShares(HONEST, 100e18);
        giveShares(SANDWICHER, 900e18);

        vm.startPrank(HONEST);
        amps.approve(address(staking), type(uint256).max);
        staking.deposit(100e18, HONEST);
        vm.stopPrank();

        _tradeForFees();

        uint256 gained = this.sandwichEntry(900e18);
        assertEq(gained, 0, "a same-block stake/unstake around a compound earns nothing");

        // And the stream really did arrive: the honest staker collects it over the next day.
        uint256 honestBefore = staking.convertToAssets(staking.balanceOf(HONEST));
        warpBy(Constants.REWARD_STREAM_SECONDS_DEFAULT + 1);
        uint256 honestAfter = staking.convertToAssets(staking.balanceOf(HONEST));
        console.log("honest staker assets before", honestBefore, "after", honestAfter);
        assertGt(honestAfter, honestBefore, "the whole slice went to the staker who was actually there");
    }

    /// @notice The same sandwich stretched over an hour still earns strictly less than its time-weighted share of
    ///         the 24-hour stream, and never more.
    function test_anHourLongSandwichEarnsAtMostItsTimeWeightedShare() public {
        giveShares(HONEST, 100e18);
        giveShares(SANDWICHER, 900e18);

        vm.startPrank(HONEST);
        amps.approve(address(staking), type(uint256).max);
        staking.deposit(100e18, HONEST);
        vm.stopPrank();

        _tradeForFees();

        vm.startPrank(SANDWICHER);
        amps.approve(address(staking), type(uint256).max);
        uint256 shares = staking.deposit(900e18, SANDWICHER);
        vm.stopPrank();

        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);
        uint256 stakerSlice = (ampsFees - ampsFees * vault.creatorBpsAt(block.timestamp) / hook.sellFeeBps())
            * vault.stakerBps() / Constants.BPS;

        warpBy(1 hours);
        vm.prank(SANDWICHER);
        uint256 out = staking.redeem(shares, SANDWICHER, SANDWICHER);

        uint256 gained = out > 900e18 ? out - 900e18 : 0;
        // One hour of a twenty-four hour stream, at 90% of the pool: an upper bound the sandwich cannot beat.
        assertLe(gained, stakerSlice * 1 hours / Constants.REWARD_STREAM_SECONDS_DEFAULT + 1, "time-weighted, at most");
    }

    /// @notice One transaction: stake, compound, unstake.
    /// @param amount The AMPS to sandwich with.
    /// @return gained AMPS gained across the sandwich.
    function sandwichEntry(uint256 amount) external returns (uint256 gained) {
        require(msg.sender == address(this), "self-call only");
        vm.startPrank(SANDWICHER);
        amps.approve(address(staking), type(uint256).max);
        uint256 shares = staking.deposit(amount, SANDWICHER);
        vm.stopPrank();

        vm.prank(KEEPER);
        vault.compound(hubPool);

        vm.prank(SANDWICHER);
        uint256 out = staking.redeem(shares, SANDWICHER, SANDWICHER);
        gained = out > amount ? out - amount : 0;
    }

    /// @dev A round trip in the hub that leaves AMPS-side fees, with the reference settled and the cooldown clear.
    function _tradeForFees() private {
        giveShares(BOB, 50e18);
        uint256 bought = buyAmps(hubPool, BOB, 4e6);
        sellAmps(hubPool, BOB, bought);
        settleTwap();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }
}
