// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {console} from "forge-std/console.sol";

/// @title CreatorFeeWashTest
/// @notice The plan's named attack **creator-fee wash trading**: "every round trip pays the sell fee to earn back
///         at most 1 point of it".
///
///         The creator earns `min(creatorBps(t), sellFeeBps) / sellFeeBps` of the AMPS-side fees a `compound`
///         collects - one point of five at launch, decaying to zero over thirty days. Washing volume to farm it is
///         a 5-for-1 loss before slippage: the wash pays the whole sell fee and the creator gets a fifth of the
///         AMPS-side slice of it back, and only after a keeper compounds.
contract CreatorFeeWashTest is Phase3Fixture {
    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(100_000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    /// @notice Ten round trips by the creator, then a compound. The creator is paid a fraction of the fees they
    ///         themselves generated, and it is a small fraction of what the washing cost them.
    function test_washTradingCostsTheCreatorFarMoreThanItPays() public {
        giveShares(CREATOR, 300e18);
        approveStack(address(amps), CREATOR);

        uint256 usdgMintedBefore = usdg.totalSupply();
        uint256 ampsBefore = amps.balanceOf(CREATOR);

        for (uint256 i; i < 10; ++i) {
            uint256 bought = buyAmps(hubPool, CREATOR, 1e6);
            sellAmps(hubPool, CREATOR, bought);
            advance(30);
        }

        uint256 usdgSpent = usdg.totalSupply() - usdgMintedBefore - usdg.balanceOf(CREATOR);
        uint256 ampsAfterWash = amps.balanceOf(CREATOR);
        assertLe(ampsAfterWash, ampsBefore, "the washing itself lost AMPS to the sell fee");

        settleTwap();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);

        uint256 paid = amps.balanceOf(CREATOR) - ampsAfterWash;
        uint256 costUsd18 = usdgSpent * 1e12 + (ampsBefore - ampsAfterWash) * vault.navPerShareX18() / Constants.WAD;
        uint256 paidUsd18 = paid * vault.navPerShareX18() / Constants.WAD;
        console.log("wash cost (usd18)", costUsd18, "creator fee earned (usd18)", paidUsd18);

        assertGt(ampsFees, 0, "the wash generated AMPS-side fees");
        assertLt(paidUsd18, costUsd18, "and the creator got back far less than the washing cost");
        assertLe(
            paid * uint256(hook.sellFeeBps()),
            ampsFees * uint256(vault.creatorBpsAt(block.timestamp)) + ampsFees,
            "I31: the payout is at most creatorBps / sellFeeBps of the AMPS-side fees"
        );
        assertLe(paid * 5, ampsFees + 5, "one point of a five-point sell fee, and no more");
    }

    /// @notice I31's other half: the creator payout is the **only** transfer of protocol-held AMPS to a non-pool
    ///         address, so there is no second faucet to wash toward.
    function test_theCreatorPayoutIsTheOnlyProtocolAmpsTransfer() public {
        giveShares(BOB, 100e18);
        uint256 bought = buyAmps(hubPool, BOB, 4e6);
        sellAmps(hubPool, BOB, bought);
        settleTwap();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 keeperBefore = amps.balanceOf(KEEPER);
        uint256 stakingBefore = amps.balanceOf(address(staking));
        uint256 creatorBefore = amps.balanceOf(CREATOR);

        vm.recordLogs();
        vm.prank(KEEPER);
        vault.compound(hubPool);

        assertEq(amps.balanceOf(KEEPER), keeperBefore, "the keeper is paid in USDG from the pot, never in AMPS");
        assertGt(amps.balanceOf(CREATOR), creatorBefore, "the creator was paid");
        assertGt(amps.balanceOf(address(staking)), stakingBefore, "and the stakers, which is a contract, not an EOA");
    }

    /// @notice And the faucet closes: after thirty days the creator earns nothing at all, so the wash has no
    ///         upside left even in principle.
    function test_afterThirtyDaysThereIsNothingToWashFor() public {
        warpBy(Constants.CREATOR_DECAY_SECONDS + 1);
        assertEq(vault.creatorBpsAt(block.timestamp), 0, "the schedule is over");

        giveShares(CREATOR, 100e18);
        approveStack(address(amps), CREATOR);
        uint256 bought = buyAmps(hubPool, CREATOR, 4e6);
        sellAmps(hubPool, CREATOR, bought);
        settleTwap();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 creatorBefore = amps.balanceOf(CREATOR);
        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "there were fees");
        assertEq(amps.balanceOf(CREATOR), creatorBefore, "and the creator was paid none of them");
    }
}
