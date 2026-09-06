// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {Constants} from "../../src/types/Constants.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {PlacementFixture} from "../mocks/PlacementFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title VaultCompoundTest
/// @notice `docs/phase3-state-model.md` §8.1's row for this file: the creator -> staker -> burn -> re-ladder split
///         to the wei, `creatorBps(t) == 0` after day 30 (I31), the high-water buyback burn in all three tick
///         positions (I33), the reset ordering, and the keeper bounty.
///
/// @dev The fees are real: they come out of real swaps against the real ladder through the v4 router, at the
///      hook's real directional fee (500 bp on an AMPS-in swap, 30 bp on an AMPS-out one in an entry pool).
contract VaultCompoundTest is PlacementFixture {
    function setUp() public {
        deployPlacementWorld();
        placeGenesisLadders();
        fundPot(1000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // §3.6 step 5 — the split
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The whole of §3.6 step 5, in order and to the wei:
    ///         ```
    ///         creatorCut = ampsFees x min(creatorBps(t), sellFeeBps) / sellFeeBps
    ///         stakerCut  = (ampsFees - creatorCut) x stakerBps / BPS
    ///         burnCut    = (ampsFees - creatorCut - stakerCut) x burnBps / BPS
    ///         relaid     = ampsFees - creatorCut - stakerCut - burnCut
    ///         ```
    function test_split_creatorThenStakerThenBurnThenRelaidToTheWei() public {
        _tradeForAmpsFees();
        // The mark sits at the live tick, so nothing is crossed and the only burn is the fee split's. The
        // buyback burn has its own three tests below.
        hook.setHighWaterTick(hubPool, tickOf(hubPool));

        uint256 creatorBefore = amps.balanceOf(CREATOR);
        uint256 stakingBefore = amps.balanceOf(address(staking));
        uint256 supplyBefore = amps.totalSupply();

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "the sell really paid a fee in AMPS");

        uint256 sellFeeBps = hook.sellFeeBps();
        uint256 creatorBps = vault.creatorBpsAt(block.timestamp);
        uint256 creatorCut = ampsFees * creatorBps / sellFeeBps;
        uint256 stakerCut = (ampsFees - creatorCut) * vault.stakerBps() / Constants.BPS;
        uint256 burnCut = (ampsFees - creatorCut - stakerCut) * vault.burnBps() / Constants.BPS;
        uint256 relaid = ampsFees - creatorCut - stakerCut - burnCut;

        assertEq(amps.balanceOf(CREATOR) - creatorBefore, creatorCut, "the creator's slice, to the wei");
        assertEq(amps.balanceOf(address(staking)) - stakingBefore, stakerCut, "the stakers' slice, to the wei");
        assertEq(burned, burnCut, "and the burn is exactly burnBps of what is left");
        assertEq(supplyBefore - amps.totalSupply(), burnCut, "totalSupply fell by exactly the burn");

        // The remainder went back into the ladder rather than anywhere else: the four slices are the whole fee.
        assertEq(creatorCut + stakerCut + burnCut + relaid, ampsFees, "the split is exhaustive");
        assertGt(relaid, 0, "and something was re-laddered");
        assertSweepClean("compound");
    }

    /// @notice The creator slice is `1 / sellFeeBps` of the AMPS-side fees at genesis: one point of a five-point
    ///         sell fee, exactly as Decision 13 describes it.
    function test_split_creatorIsOnePointOfTheSellFeeAtGenesis() public {
        _tradeForAmpsFees();
        hook.setHighWaterTick(hubPool, tickOf(hubPool));

        uint256 creatorBefore = amps.balanceOf(CREATOR);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        uint16 creatorBps = vault.creatorBpsAt(block.timestamp);
        assertEq(creatorBps, Constants.CREATOR_FEE_BPS - 1, "99 bp a few minutes into a 30-day linear decay");

        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);

        assertEq(
            amps.balanceOf(CREATOR) - creatorBefore,
            ampsFees * creatorBps / hook.sellFeeBps(),
            "one point of five, less the schedule's first few minutes"
        );
    }

    /// @notice I31: `creatorBps(t)` is monotone non-increasing and exactly zero from `genesis + 30 days`, and the
    ///         schedule is immutable — nothing but time changes it.
    function test_i31_creatorScheduleDecaysToZeroAndStaysThere() public {
        uint32 genesis = vault.genesisTimestamp();
        uint16 previous = type(uint16).max;
        for (uint256 day; day <= 31; ++day) {
            uint16 bps = vault.creatorBpsAt(uint256(genesis) + day * 1 days);
            assertLe(bps, previous, "monotone non-increasing");
            previous = bps;
        }
        assertEq(vault.creatorBpsAt(uint256(genesis) + Constants.CREATOR_DECAY_SECONDS), 0, "zero at day 30");
        assertEq(vault.creatorBpsAt(uint256(genesis) + 3650 days), 0, "and zero for good");
    }

    /// @notice And the vault pays it: after day 30 a `compound` sends the creator nothing at all, and the whole
    ///         fee backs AMPS.
    function test_i31_theCreatorIsPaidNothingAfterDayThirty() public {
        _tradeForAmpsFees();
        warpBy(Constants.CREATOR_DECAY_SECONDS + 1);
        syncMarket();

        uint256 creatorBefore = amps.balanceOf(CREATOR);
        uint256 stakingBefore = amps.balanceOf(address(staking));

        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);

        assertGt(ampsFees, 0, "there were fees to split");
        assertEq(amps.balanceOf(CREATOR), creatorBefore, "the creator got nothing");
        assertEq(
            amps.balanceOf(address(staking)) - stakingBefore,
            ampsFees * vault.stakerBps() / Constants.BPS,
            "and the stakers' slice is now measured against the whole fee"
        );
    }

    /// @notice Counter-side fees are left where the ladder raised them: they go back into the pool as bids below
    ///         the market rather than out to anybody.
    function test_counterSideFeesStayInThePoolAsBids() public {
        // A buy pays its fee in USDG, which is the counter side of the hub.
        buyAmps(hubPool, address(usdg), 200e6);
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 usdgOut = usdg.balanceOf(CREATOR) + usdg.balanceOf(address(staking));
        vm.prank(KEEPER);
        vault.compound(hubPool);
        assertEq(usdg.balanceOf(CREATOR) + usdg.balanceOf(address(staking)), usdgOut, "no counter asset left");
        assertSweepClean("counter-side fees");
    }

    // -------------------------------------------------------------------------------------------------------------
    // §3.5 — the buyback burn (I33), in all three tick positions
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `tick <= lower`: the mark crossed the cell and the price came all the way back, so the cell is
    ///         pure AMPS the vault bought back. It is withdrawn whole and burned, and never re-placed.
    function test_i33_burnbackPureAmpsCellIsBurnedWhole() public {
        PlacementRecord[] memory before = ladderOf(hubPool);
        int24 firstAskUpper;
        uint128 firstAskLiquidity;
        int24 firstAskLower;
        for (uint256 i; i < before.length; ++i) {
            if (!before[i].above) continue;
            firstAskLower = before[i].lowerTick;
            firstAskUpper = before[i].upperTick;
            firstAskLiquidity = before[i].liquidity;
            break;
        }
        assertGt(firstAskLiquidity, 0, "there is an ask cell to burn");
        assertLe(tickOf(hubPool), firstAskLower, "and the price is at or below it, so it is pure AMPS");

        // The hook says the high-water mark crossed that cell's top since the last reset.
        hook.setHighWaterTick(hubPool, firstAskUpper);

        uint256 supplyBefore = amps.totalSupply();
        vm.prank(KEEPER);
        (, uint256 burned) = vault.compound(hubPool);

        assertGt(burned, 0, "the bought-back AMPS was burned");
        assertEq(supplyBefore - amps.totalSupply(), burned, "totalSupply fell by exactly that");

        // And it is gone from the ladder: the cell is empty and was not re-placed.
        PlacementRecord[] memory after_ = ladderOf(hubPool);
        for (uint256 i; i < after_.length; ++i) {
            if (after_[i].lowerTick != firstAskLower) continue;
            assertEq(after_[i].liquidity, 0, "the crossed cell is empty");
            assertFalse(after_[i].above, "and is no longer an ask");
        }
    }

    /// @notice `tick >= upper`: the cell was fully sold and holds only the counter asset, so nothing was bought
    ///         back and nothing is burned — the proceeds stay as the bid at the prices that raised them (§3.4).
    function test_i33_burnbackLeavesAFullySoldCellAlone() public {
        // Walk the price up past the first ask cell.
        buyAmps(hubPool, address(usdg), 400e6);
        int24 tick = tickOf(hubPool);

        PlacementRecord[] memory records = ladderOf(hubPool);
        uint256 sold;
        for (uint256 i; i < records.length; ++i) {
            if (records[i].liquidity != 0 && tick >= records[i].upperTick) ++sold;
        }
        assertGt(sold, 0, "at least one cell was consumed end to end");

        hook.setHighWaterTick(hubPool, tick);
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 supplyBefore = amps.totalSupply();
        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);

        // Whatever was burned came out of the fee split, never out of a fully-sold cell.
        uint256 splitBurn = _expectedBurnCut(ampsFees);
        assertEq(burned, splitBurn, "nothing was bought back out of a sold cell");
        assertEq(supplyBefore - amps.totalSupply(), burned, "and the supply agrees");
    }

    /// @notice `lower < tick < upper`: the straddled cell holds both. The AMPS half is bought-back inventory and
    ///         is burned; the counter half is not destroyed — it comes back as a claim and is re-laddered as a bid
    ///         below the market inside the same `compound`.
    /// @dev **The deviation from §10 ruling 8, in the one test that shows why.** The ruling re-places the counter
    ///      side over `[lower, alignDown(tick)]`, which is a *fraction* of a grid cell. `LadderPositionValuer`
    ///      enumerates whole cells, so such a position is invisible to `A`: the placement that created it would
    ///      lose its whole value from the NAV numerator and R1 would revert the `compound`. The counter is
    ///      therefore held as an ERC-6909 claim — §3.5's own fallback for a degenerate range — and re-enters the
    ///      ladder as a proper grid bid in step 7. Nothing leaves the pool's economy.
    function test_i33_burnbackOfAStraddledCellBurnsTheAmpsAndKeepsTheCounter() public {
        buyAmps(hubPool, address(usdg), 60e6);
        int24 tick = tickOf(hubPool);

        PlacementRecord[] memory records = ladderOf(hubPool);
        bool straddled;
        for (uint256 i; i < records.length; ++i) {
            if (records[i].liquidity != 0 && records[i].lowerTick < tick && tick < records[i].upperTick) {
                straddled = true;
                hook.setHighWaterTick(hubPool, records[i].upperTick);
                break;
            }
        }
        assertTrue(straddled, "the price sits inside a cell");

        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 usdgBefore = heldBalance(address(usdg));
        uint256 poolUsdg = usdg.balanceOf(address(poolManager));
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);

        assertGt(burned, _expectedBurnCut(ampsFees), "more was burned than the fee split alone");
        assertEq(supplyBefore - amps.totalSupply(), burned, "and every wei of it left the supply");
        assertEq(usdg.balanceOf(address(poolManager)), poolUsdg, "no USDG left the PoolManager");
        usdgBefore;
        assertSweepClean("straddled burnback");
    }

    /// @notice The ordering rule of §3.5: the burn runs *before* the re-ladder and the mark is reset *after*, so
    ///         freshly re-laddered AMPS can never be mistaken for bought-back inventory on the next call.
    function test_i33_theMarkIsResetAfterTheBurnSoFreshAsksAreNotBurnedNext() public {
        _tradeForAmpsFees();
        // The mark crossed the whole ask ladder: every ask cell holding AMPS is bought-back inventory.
        hook.setHighWaterTick(hubPool, _highestAskUpper());

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        (uint256 fees1, uint256 burned1) = vault.compound(hubPool);
        assertGt(burned1, _expectedBurnCut(fees1), "the first compound bought back and burned");
        assertEq(hook.highWaterResetCount(hubPool), 1, "and reset the mark exactly once");

        // The mark now sits at the live tick, so the AMPS just re-laddered above it is not "crossed".
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        (uint256 fees2, uint256 burned2) = vault.compound(hubPool);
        assertEq(burned2, _expectedBurnCut(fees2), "the second compound burned only the fee split");
    }

    /// @notice The surge is armed on every `compound`, so a compound cannot be sandwiched at the pre-compound fee.
    function test_theSurgeIsArmedOnEveryCompound() public {
        uint32 armed = hook.surgeArmedCount(hubPool);
        vm.prank(KEEPER);
        vault.compound(hubPool);
        assertGt(hook.surgeArmedCount(hubPool), armed, "armed");
        assertEq(hook.lastSurgeReason(hubPool), bytes32("compound"), "with the compound's reason");
    }

    // -------------------------------------------------------------------------------------------------------------
    // §12 ruling E — the bountied paths merge and idle rather than revert
    // -------------------------------------------------------------------------------------------------------------

    /// @notice With the live-cell budget full, `compound` still runs: it merges into the cells that already exist
    ///         and leaves the remainder idle. A full vault must degrade into "the keeper keeps working", never
    ///         into "the keeper reverts" — the fees would otherwise never be split at all.
    function test_e_compoundMergesAndLeavesTheRemainderIdleWhenTheBudgetIsFull() public {
        _tradeForAmpsFees();
        hook.setHighWaterTick(hubPool, tickOf(hubPool));
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint32 live = vault.liveCells();
        forceLiveCells(Constants.MAX_LIVE_CELLS);

        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "the fees were still collected and split");
        assertEq(vault.liveCells(), Constants.MAX_LIVE_CELLS, "and not one new cell was opened");
        live;
        assertSweepClean("compound at the budget");
    }

    /// @notice And with the budget full **and** every cell of the pool already live, the re-ladder merges into
    ///         all of them, so nothing is left idle at all.
    function test_e_compoundStillReLaddersIntoExistingCellsWhenTheBudgetIsFull() public {
        _tradeForAmpsFees();
        hook.setHighWaterTick(hubPool, tickOf(hubPool));
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 before = _askAmountTotal();
        forceLiveCells(Constants.MAX_LIVE_CELLS);

        vm.prank(KEEPER);
        vault.compound(hubPool);
        assertGt(_askAmountTotal(), before, "the ask cells took the re-laddered fees");
    }

    /// @notice The buyback burn takes cells *out* of the count, which is what keeps a long-lived vault from
    ///         ratcheting toward the budget.
    function test_e_theBurnbackReleasesBudget() public {
        uint32 live = vault.liveCells();
        assertEq(live, countLiveCells(), "the count starts exact");

        hook.setHighWaterTick(hubPool, _highestAskUpper());
        vm.prank(KEEPER);
        vault.compound(hubPool);

        assertLt(vault.liveCells(), live, "the burnt-back cells left the count");
        assertEq(vault.liveCells(), countLiveCells(), "and it is still exact");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The keeper bounty
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `compound` is permissionless and pays the caller a flat bounty out of the segregated pot.
    function test_theKeeperIsPaidFromTheBountyPot() public {
        uint256 before = usdg.balanceOf(KEEPER);
        vm.prank(KEEPER);
        vault.compound(hubPool);
        assertGt(usdg.balanceOf(KEEPER), before, "the keeper was paid");
    }

    /// @notice A depleted pot degrades the job to unpaid rather than reverting it (I21).
    function test_aDepletedPotDegradesToUnpaid() public {
        uint256 potBalance = pot.balance();
        vm.prank(TIMELOCK);
        pot.sweep(TIMELOCK, potBalance);
        assertEq(pot.balance(), 0, "the pot is empty");

        uint256 before = usdg.balanceOf(KEEPER);
        vm.prank(KEEPER);
        vault.compound(hubPool);
        assertEq(usdg.balanceOf(KEEPER), before, "unpaid, but the work still happened");
    }

    /// @notice `compound` takes the same 60-second cooldown as every other placement.
    function test_compoundTakesThePlacementCooldown() public {
        vm.prank(KEEPER);
        vault.compound(hubPool);
        vm.prank(KEEPER);
        vm.expectPartialRevert(bytes4(keccak256("PlacementCooldown(bytes32,uint32)")));
        vault.compound(hubPool);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev A buy and then a sell, so the hub has collected fees on both sides: 30 bp of USDG on the way in and
    ///      500 bp of AMPS on the way out.
    function _tradeForAmpsFees() private {
        buyAmps(hubPool, address(usdg), 100e6);
        sellAmps(hubPool, amps.balanceOf(BOB) / 2);
        syncMarket();
    }

    /// @dev The AMPS the hub's ask cells have been committed in total, which is what a re-ladder adds to.
    function _askAmountTotal() private view returns (uint256 total) {
        PlacementRecord[] memory records = ladderOf(hubPool);
        for (uint256 i; i < records.length; ++i) {
            if (records[i].above) total += records[i].amount;
        }
    }

    /// @dev The top of the ask ladder, so a test can put the high-water mark above every ask cell.
    function _highestAskUpper() private view returns (int24 highest) {
        PlacementRecord[] memory records = ladderOf(hubPool);
        for (uint256 i; i < records.length; ++i) {
            if (records[i].above && records[i].upperTick > highest) highest = records[i].upperTick;
        }
    }

    /// @dev The burn the fee split alone accounts for, so a test can tell it apart from a buyback.
    function _expectedBurnCut(uint256 ampsFees) private view returns (uint256) {
        uint256 creatorCut = ampsFees * vault.creatorBpsAt(block.timestamp) / hook.sellFeeBps();
        uint256 stakerCut = (ampsFees - creatorCut) * vault.stakerBps() / Constants.BPS;
        return (ampsFees - creatorCut - stakerCut) * vault.burnBps() / Constants.BPS;
    }
}
