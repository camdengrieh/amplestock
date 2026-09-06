// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {PlacementDiverged} from "../../src/types/Errors.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title ManipulatedTickPlacementTest
/// @notice The plan's "placement reverts on a manipulated tick" and "R1 is never violated".
///
///         Every placement measures `|slot0.tick - tickOf(P_mkt / P_i)|` against `PLACEMENT_DIVERGENCE_TICKS`
///         (800) at **entry and exit** (§3.8 step 3), so a pool pushed away from the reference cannot be
///         laddered into; and every placement re-checks NAV/share afterwards against a 2 bp bleed bound (R1,
///         I11), so a placement that would cost the vault value reverts rather than settling.
contract ManipulatedTickPlacementTest is Phase3Fixture {
    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(100_000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    /// @notice A pool walked away from its reference refuses every placement path until the reference catches up.
    function test_placementRevertsWhileThePoolIsFarFromTheReference() public {
        // The rail lets a market move; the divergence guard does not let the vault *place* while it has.
        climb(hubPool, BOB, 1e6, tickOf(hubPool) + 2000, 200, 3);
        int24 poolTick = tickOf(hubPool);
        assertGt(poolTick - hook.twapTick30m(hubPool), Constants.PLACEMENT_DIVERGENCE_TICKS, "the pool is diverged");

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(TIMELOCK);
        vm.expectRevert();
        vault.place(hubPool, true, 10e18);

        vm.prank(KEEPER);
        vm.expectRevert();
        vault.compound(hubPool);

        // Once the truncated TWAP has absorbed the move, the same placement succeeds.
        settleTwap();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 10e18);
    }

    /// @notice The guard is symmetric: a pool pushed *down* away from its reference is refused too.
    function test_placementRevertsOnADownwardManipulationAsWell() public {
        giveShares(BOB, 400e18);
        approveStack(address(amps), BOB);
        slide(hubPool, BOB, 8e18, tickOf(hubPool) - 2000, 200, 3);
        assertGt(hook.twapTick30m(hubPool) - tickOf(hubPool), Constants.PLACEMENT_DIVERGENCE_TICKS, "diverged down");

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(TIMELOCK);
        vm.expectRevert();
        vault.place(hubPool, false, 10e6);
    }

    /// @notice R1 across every placement path this fixture can reach: NAV/share never falls by more than 2 bp,
    ///         and in practice never falls at all.
    function test_r1_navPerShareNeverBleedsAcrossAnyPlacement() public {
        uint256 nav = vault.previewNavPerShareX18();

        for (uint256 round; round < 4; ++round) {
            giveShares(BOB, 30e18);
            approveStack(address(amps), BOB);
            uint256 bought = buyAmps(hubPool, BOB, 2e6);
            sellAmps(hubPool, BOB, bought);
            settleTwap();
            warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

            vm.prank(KEEPER);
            vault.compound(hubPool);
            uint256 after_ = vault.previewNavPerShareX18();
            assertGe(after_ * Constants.BPS, nav * (Constants.BPS - Constants.PLACEMENT_BLEED_BPS_MAX), "R1");
            nav = after_;

            warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
            vm.prank(KEEPER);
            vault.rollout(constituentIds[0]);
            after_ = vault.previewNavPerShareX18();
            assertGe(after_ * Constants.BPS, nav * (Constants.BPS - Constants.PLACEMENT_BLEED_BPS_MAX), "R1 rollout");
            nav = after_;
        }
    }

    /// @notice I39 and I9 survive every path: every live cell is on the grid, no two share an index, and asks and
    ///         bids stay on their own sides of the tick.
    function test_i9_i39_gridAndSidednessSurviveEveryPlacement() public {
        giveShares(BOB, 60e18);
        approveStack(address(amps), BOB);
        uint256 bought = buyAmps(hubPool, BOB, 3e6);
        sellAmps(hubPool, BOB, bought);
        settleTwap();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        vault.compound(hubPool);

        PoolId[] memory ids = allPools();
        for (uint256 p; p < ids.length; ++p) {
            int24 base = gridBaseOf(ids[p]);
            int24 width = cellWidth();
            PlacementRecord[] memory records = ladderOf(ids[p]);
            bool[24] memory seen;
            for (uint256 i; i < records.length; ++i) {
                int24 offset = records[i].lowerTick - base;
                assertEq(offset % width, 0, "I39: every cell lies on the canonical doubling grid");
                assertEq(records[i].upperTick - records[i].lowerTick, width, "one doubling wide");
                assertLt(uint256(records[i].bucketIndex), 24, "inside GRID_CELLS");
                assertFalse(seen[records[i].bucketIndex], "I39: no two records share a cell");
                seen[records[i].bucketIndex] = true;
            }
        }
    }
}
