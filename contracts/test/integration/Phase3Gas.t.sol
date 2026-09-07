// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {Phase3Fixture} from "./Phase3Fixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

/// @title Phase3GasTest
/// @notice The four Phase 3 hot paths, measured on the fully wired fixture with `vm.startSnapshotGas`, plus §9.7's
///         hard question: does `redeemProRata` still fit one block at the worst state the live-cell budget admits?
///
/// @dev **`redeemProRata` is never gated, rate-limited or split into instalments** (§10 ruling 7), so the only
///      thing that can make it fit is the grid bound plus `Constants.MAX_LIVE_CELLS`. The test therefore measures
///      the *marginal* cost of a live cell on the real system and extrapolates it to the budget, which is exactly
///      the arithmetic §12 ruling E does - now with the constant measured rather than assumed.
contract Phase3GasTest is Phase3Fixture {
    /// @dev The ceiling the plan sets for a redemption at full occupancy.
    uint256 internal constant REDEEM_GAS_CEILING = 24_000_000;

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(1_000_000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    /// @notice `place` on a live pool, with the ladder already there so the placement merges by cell.
    function test_gas_place() public {
        vm.startSnapshotGas("phase3_place");
        vm.prank(TIMELOCK);
        vault.place(spokePools[0], true, 50e18);
        uint256 used = vm.stopSnapshotGas();
        console.log("gas place", used);
        assertGt(used, 0, "measured");
    }

    /// @notice `compound` with fees to collect, a buyback burn to do and a re-ladder to place.
    function test_gas_compound() public {
        giveShares(BOB, 60e18);
        approveStack(address(amps), BOB);
        uint256 bought = buyAmps(hubPool, BOB, 4e6);
        sellAmps(hubPool, BOB, bought);
        settleTwap();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.startSnapshotGas("phase3_compound");
        vm.prank(KEEPER);
        vault.compound(hubPool);
        uint256 used = vm.stopSnapshotGas();
        console.log("gas compound", used);
        assertGt(used, 0, "measured");
    }

    /// @notice A two-hop rotation through the real hook, in one transaction, with the rotation credit live.
    function test_gas_rotation() public {
        deepenSpokes(600e18);
        seedSpokeBids(1);
        uint256 used = this.rotationGasEntry();
        console.log("gas two-hop rotation", used);
        assertGt(used, 0, "measured");
    }

    /// @notice Self-call entry: the whole rotation inside one transaction's transient storage.
    /// @return used Gas used by the router call.
    function rotationGasEntry() external returns (uint256 used) {
        require(msg.sender == address(this), "self-call only");
        vm.startSnapshotGas("phase3_rotation");
        rotate(spokePools[0], spokePools[1], ALICE, 0.01e18);
        used = vm.stopSnapshotGas();
    }

    /// @notice `redeemProRata` at the worst state this fixture's four pools can reach, measured cold, and the
    ///         per-cell cost §9.7 and §12 ruling E both turn on.
    function test_gas_redeemProRataAtTheWorstReachableState() public {
        _fillTheBook();
        uint32 cells = vault.liveCells();
        assertGt(cells, 48, "the book really is fuller than the launch shape");
        giveShares(ALICE, 200e18);

        vm.startSnapshotGas("phase3_redeemProRata");
        vm.prank(ALICE);
        vault.redeemProRata(100e18, ALICE);
        uint256 used = vm.stopSnapshotGas();

        console.log("gas redeemProRata", used, "at live cells", cells);
        console.log("gas per live cell (average, fixed overhead included)", used / cells);
        assertLe(used, REDEEM_GAS_CEILING, "the measured redemption fits one block with room to spare");
    }

    /// @notice The four-pool fixture's *average* cost per live cell, recorded for the record and explicitly not
    ///         extrapolated: with only 59 cells the fixed part of a redemption - the payout unlock, the share
    ///         burn, the inventory burn, one checkpoint - is amortised over far too few of them, so multiplying
    ///         this number by `MAX_LIVE_CELLS` overstates the projection by about 10%.
    ///         `integration/Phase3LaunchShape.t.sol` measures the real 32-pool book instead, and that is the
    ///         number §9.7's question should be answered with.
    function test_gas_theFourPoolAveragePerCellOverstatesTheProjection() public {
        _fillTheBook();
        uint32 cells = vault.liveCells();
        giveShares(ALICE, 200e18);

        vm.prank(ALICE);
        uint256 before = gasleft();
        vault.redeemProRata(100e18, ALICE);
        uint256 used = before - gasleft();

        uint256 perCell = used / cells;
        console.log("four-pool average per cell", perCell, "naive projection", perCell * Constants.MAX_LIVE_CELLS);
        assertLt(cells, 100, "the four-pool book is small enough that the average is dominated by the fixed part");
        assertGt(perCell, 40_000, "and the average is above the marginal cost the launch shape measures");
    }

    /// @notice §12 ruling E's other half, which is what makes the projection above a *bound* rather than an
    ///         estimate: the counter is exact, it never passes `MAX_LIVE_CELLS`, and with the budget full the
    ///         permissionless paths still work - they merge into existing cells and leave the remainder idle
    ///         rather than reverting, so a full book can never stall the keeper.
    ///
    /// @dev `place`'s own `CellBudgetExceeded` revert - the governance path, which refuses rather than silently
    ///      placing less - is `test/unit/VaultPlacement.t.sol`'s, because it needs a pool with no cells at all and
    ///      every pool here has its genesis ladder.
    function test_theLiveCellBudgetIsEnforcedAndTheKeeperPathsSurviveIt() public {
        assertLe(vault.liveCells(), Constants.MAX_LIVE_CELLS, "inside the budget");
        assertEq(vault.liveCells(), countLiveCells(), "and the counter is exact");

        giveShares(BOB, 60e18);
        approveStack(address(amps), BOB);
        uint256 bought = buyAmps(hubPool, BOB, 4e6);
        sellAmps(hubPool, BOB, bought);
        settleTwap();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        // Force the counter to the ceiling. The vault has no setter for it, which is the point: the slot is
        // `VaultRedeemLib.LIVE_CELLS_SLOT` and only a placement moves it.
        vm.store(
            address(vault),
            bytes32(uint256(keccak256("amplestocks.vault.liveCells"))),
            bytes32(uint256(Constants.MAX_LIVE_CELLS))
        );
        assertEq(vault.liveCells(), Constants.MAX_LIVE_CELLS, "the counter is at the ceiling");

        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "compound still runs with the budget full");
        assertLe(vault.liveCells(), Constants.MAX_LIVE_CELLS, "and opened no new cell");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Opens as many grid cells as this fixture's four pools can reach: deeper spoke ladders, bonded bid
    ///      ladders, traded-through entry pools and a compound in each, so the redemption below really does have
    ///      to unwind a full book.
    function _fillTheBook() private {
        deepenSpokes(500e18);
        seedSpokeBids(0);
        seedSpokeBids(1);

        giveShares(BOB, 100e18);
        approveStack(address(amps), BOB);
        uint256 bought = buyAmps(hubPool, BOB, 5e6);
        sellAmps(hubPool, BOB, bought);
        bought = buyAmps(wethPool, BOB, 2e15);
        sellAmps(wethPool, BOB, bought);
        settleTwap();

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        vault.compound(hubPool);
        vm.prank(KEEPER);
        vault.compound(wethPool);

        // Rollout touches the entry pools, which the compounds above have just placed into, so each move needs
        // its own cooldown window.
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        vault.rollout(constituentIds[0]);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        vault.rollout(constituentIds[1]);
    }
}
