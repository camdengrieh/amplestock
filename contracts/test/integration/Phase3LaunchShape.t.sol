// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {PoolClass} from "../../src/types/Types.sol";
import {Phase3Fixture} from "./Phase3Fixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

/// @title Phase3LaunchShapeTest
/// @notice The launch shape itself: **32 pools** - the two entry pools and thirty spokes - opened, registered,
///         genesis-laddered and then redeemed against, which is the only place the plan's real numbers can be
///         read rather than extrapolated: the whole 4,750 AMPS POL tranche placed, 328 live grid cells, and one
///         `redeemProRata` that has to unwind every one of them inside a single block.
///
/// @dev {Phase3Fixture} is parameterised on {Phase3Fixture-spokeCount} for exactly this. The four-pool shape of
///      `docs/phase3-state-model.md` §8.2 is what the invariant campaign and the attack suites use, because
///      thirty-two pools is too slow to fuzz; the flywheel's headline numbers are measured here.
contract Phase3LaunchShapeTest is Phase3Fixture {
    /// @inheritdoc Phase3Fixture
    function spokeCount() internal view virtual override returns (uint256 count) {
        return 30;
    }

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(1_000_000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    /// @notice The launch balance sheet: `S0` minted, the whole POL tranche placed across 32 pools, every cell on
    ///         its own pool's grid, and the live-cell count inside the budget with room for growth.
    function test_theLaunchShapeIsThirtyTwoPoolsAndTheWholePolTranche() public view {
        assertEq(allPools().length, 32, "two entry pools and thirty spokes");
        assertEq(amps.totalSupply(), Constants.S0, "S0 minted, and nothing else");
        assertEq(amps.balanceOf(address(teamVesting)), Constants.TEAM_SHARES, "250 AMPS vesting for the team");

        uint256 placed = ENTRY_ASK_AMPS * 2 + SPOKE_SEED_AMPS * spokeCount();
        assertEq(placed, Constants.POL_SHARES, "the ladders account for the whole 4,750 AMPS POL tranche");

        uint32 cells = vault.liveCells();
        console.log("live cells at the launch shape", cells, "budget", Constants.MAX_LIVE_CELLS);
        console.log("A (usd18)", vault.totalAssetsUsd18(), "navPerShareX18", vault.navPerShareX18());
        assertEq(cells, 2 * 14 + spokeCount() * 10, "fourteen cells per entry pool, ten per spoke");
        assertEq(cells, countLiveCells(), "and the counter is exact across all thirty-two");
        assertLe(cells, Constants.MAX_LIVE_CELLS, "inside the live-cell budget");
    }

    /// @notice §9.7's question, answered at the launch shape rather than extrapolated to it: one `redeemProRata`
    ///         unwinding all 328 cells of the real 32-pool book, cold, in one transaction.
    function test_gas_redeemProRataAtTheLaunchShape() public {
        // At the launch shape the whole POL tranche is inside the ladders, so a redeemer buys their shares the
        // way a holder really does: out of the hub's ask ladder.
        uint256 shares = buyAmps(hubPool, ALICE, 5e6);
        assertGt(shares, 1e18, "the redeemer holds real shares");
        uint32 cells = vault.liveCells();

        vm.startSnapshotGas("phase3_redeemProRata_launchShape");
        vm.prank(ALICE);
        vault.redeemProRata(shares, ALICE);
        uint256 used = vm.stopSnapshotGas();

        uint256 perCell = used / cells;
        uint256 projected = perCell * Constants.MAX_LIVE_CELLS;
        console.log("gas redeemProRata across 32 pools", used, "at live cells", cells);
        console.log("gas per live cell", perCell, "projected at MAX_LIVE_CELLS", projected);

        assertLe(used, 24_000_000, "the launch shape's redemption fits one block");
        // The average-cost projection is the conservative one - it charges the fixed part of a redemption to
        // every cell - and even that stays under the ceiling at `MAX_LIVE_CELLS`, which is what makes §12
        // ruling E's budget a bound rather than an estimate.
        assertLe(projected, 24_000_000, "and so does the whole live-cell budget, at the average cost per cell");
        assertEq(vault.liveCells(), countLiveCells(), "and the counter is still exact afterwards");
    }

    /// @notice `checkpoint()` across the whole 32-pool book, which is what every bond pays for on top of itself
    ///         (§4's "a Phase 3 bond costs roughly `checkpoint()` plus ~700k").
    function test_gas_checkpointAcrossThirtyTwoPools() public {
        vm.startSnapshotGas("phase3_checkpoint_32pools");
        vault.checkpoint();
        uint256 used = vm.stopSnapshotGas();
        console.log("gas checkpoint across 32 pools", used);
        assertGt(used, 0, "measured");
    }
}
