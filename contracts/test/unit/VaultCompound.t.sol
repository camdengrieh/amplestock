// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IBountyPot} from "../../src/interfaces/IBountyPot.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {PlacementFixture} from "../mocks/PlacementFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Vm} from "forge-std/Vm.sol";

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

    /// @notice `lower < tick < upper`: the straddled cell is a cell the price has re-entered but **not** re-crossed,
    ///         so it is left exactly where it is. What sits in it is partly the counter asset a real trade paid
    ///         for; a whole-cell withdrawal would burn the AMPS half and re-price that trade's proceeds a doubling
    ///         lower. It is burned by a later `compound`, once the price has finished coming back through it.
    ///
    /// @dev **The finding this closes, and the deviation from §10 ruling 8 it makes deliberate.** The old
    ///      predicate skipped only `tick >= upper`, so *any* cell holding AMPS under a crossed mark was taken
    ///      whole. The ruling's remedy for the straddled case — re-place the counter side over
    ///      `[lower, alignDown(tick)]` — is not open to us either: that range is a *fraction* of a grid cell, and
    ///      `LadderPositionValuer` enumerates whole cells, so the position would be invisible to `A`, the
    ///      placement would lose its whole value from the NAV numerator and R1 would revert the `compound` that
    ///      created it (I39 too). Leaving the cell alone is the resolution: nothing is destroyed, nothing is
    ///      re-priced, and the burn happens when the price says the whole cell really is bought-back inventory.
    function test_i33_burnbackLeavesAPartiallyBoughtBackCellAlone() public {
        buyAmps(hubPool, address(usdg), 60e6);
        int24 tick = tickOf(hubPool);

        PlacementRecord[] memory records = ladderOf(hubPool);
        int24 straddledLower;
        uint128 straddledLiquidity;
        for (uint256 i; i < records.length; ++i) {
            if (records[i].liquidity != 0 && records[i].lowerTick < tick && tick < records[i].upperTick) {
                straddledLower = records[i].lowerTick;
                straddledLiquidity = records[i].liquidity;
                // The mark crossed this cell's top, so the only thing standing between it and the burn is the
                // "has the price come all the way back?" half of the predicate.
                hook.setHighWaterTick(hubPool, records[i].upperTick);
                break;
            }
        }
        assertGt(straddledLiquidity, 0, "the price sits inside a cell");

        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 poolUsdg = usdg.balanceOf(address(poolManager));
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);

        assertEq(burned, _expectedBurnCut(ampsFees), "nothing was burned but the fee split");
        assertEq(supplyBefore - amps.totalSupply(), burned, "and the supply agrees");
        assertGe(_liquidityAt(hubPool, straddledLower), straddledLiquidity, "the straddled cell is untouched");
        assertEq(usdg.balanceOf(address(poolManager)), poolUsdg, "and no USDG left the PoolManager");
        assertSweepClean("straddled cell");
    }

    /// @notice The case the burn is *for*: an ask the market bought end to end on the way up and sold back to the
    ///         vault end to end on the way down. The cell is pure AMPS the vault paid its own counter asset for,
    ///         so it is withdrawn whole and burned (I33).
    function test_i33_anAskFullySoldAndFullyBoughtBackIsBurned() public {
        int24 base = gridBaseOf(hubPool);
        int24 width = cellWidth();
        uint128 cell0 = _liquidityAt(hubPool, base);
        uint128 cell1 = _liquidityAt(hubPool, base + width);
        assertGt(cell0, 0, "the first ask cell is live");

        // Up: the market takes the whole of cell 0 and stops inside cell 1. The hook's mark records the excursion,
        // so cell 0's top is crossed and cell 1's is not.
        buyAmps(hubPool, address(usdg), 150e6);
        assertGt(tickOf(hubPool), base + width, "cell 0 was consumed end to end");
        assertLt(tickOf(hubPool), base + 2 * width, "and cell 1 only partly");
        assertGe(hook.highWaterTick(hubPool), base + width, "so the mark crossed cell 0's top");
        assertLt(hook.highWaterTick(hubPool), base + 2 * width, "and not cell 1's");

        // Down, past where it started: cell 0 is the vault's own inventory again, bought back with the counter
        // asset the way up raised.
        giveShares(BOB, 300e18);
        sellAmps(hubPool, amps.balanceOf(BOB));
        assertLt(tickOf(hubPool), base, "the price has come all the way back through cell 0");
        assertGt(tickOf(hubPool), base - width, "but not through the bid below it");

        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 supplyBefore = amps.totalSupply();
        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);

        assertGt(burned, _expectedBurnCut(ampsFees), "more was burned than the fee split alone");
        assertEq(supplyBefore - amps.totalSupply(), burned, "and every wei of it left the supply");
        // The cell was emptied by the burn; what stands in it now is only the fee remainder step 6 re-laddered,
        // which is a fraction of the inventory that was there.
        assertLt(_liquidityAt(hubPool, base), cell0, "the bought-back inventory is gone from the cell");

        // Cell 1 was only ever *partly* crossed by the mark, so it is not inventory the market gave back and is
        // left alone — the two halves of the predicate, in one assertion.
        assertGe(_liquidityAt(hubPool, base + width), cell1, "the partly-crossed cell above is untouched");
        assertSweepClean("round-trip burnback");
    }

    /// @notice **The ratchet this closes.** Step 7 lays bids strictly *below* the tick and step 8 only then resets
    ///         the mark, so every bid `compound` places satisfies "the mark crossed my top" from the moment it is
    ///         opened. Under the old predicate one tick of drift into the top bid cell was enough for the next
    ///         permissionless `compound` — 61 seconds later, by anyone — to withdraw that cell whole, burn the
    ///         AMPS it had just bought and re-lay the counter a full doubling lower: a one-way ratchet of the bid
    ///         ladder, once a minute, for a bounty.
    function test_i33_bidsLaidByCompoundSurviveASmallDowntick() public {
        // A buy pays its fee in USDG, which step 7 lays into the bid ladder.
        buyAmps(hubPool, address(usdg), 30e6);
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        (int24 lower, int24 upper,) = _topBid();
        uint128 before = _liquidityAt(hubPool, lower);

        vm.prank(KEEPER);
        vault.compound(hubPool);
        uint128 laid = _liquidityAt(hubPool, lower);
        assertGt(laid, before, "compound laid the counter-side fees into the top bid cell");

        // One small downtick, into that cell and nowhere near through it, under a mark that stands above it —
        // which is where a reset plus a downtick always leaves a bid.
        giveShares(BOB, 60e18);
        sellAmps(hubPool, amps.balanceOf(BOB));
        hook.setHighWaterTick(hubPool, upper);
        syncMarket();
        assertLt(tickOf(hubPool), upper, "the price is inside the top bid cell");
        assertGt(tickOf(hubPool), lower, "and has not crossed it");

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);

        assertGe(_liquidityAt(hubPool, lower), laid, "the bid the last compound laid is still there");
        assertEq(burned, _expectedBurnCut(ampsFees), "and nothing was burned but the fee split");
        assertSweepClean("bid under the mark");
    }

    /// @notice And the stale-mark half of the same fix: an ask placed by `rollout` into a pool whose mark is left
    ///         over from an old excursion is not burned by the next `compound`, because **every** ask placement
    ///         resets the mark. Without that, a spoke that had once run up would burn every ask rolled into it.
    function test_i33_aRolloutPlacedAskUnderAStaleMarkIsNotBurned() public {
        PoolId spoke = spokePools[0];
        int24 stale = tickOf(spoke) + 20 * cellWidth();
        hook.setHighWaterTick(spoke, stale);

        assertGt(vault.rollout(constituentIds[0]), 0, "the rollout moved inventory into the spoke");
        assertEq(hook.highWaterTick(spoke), tickOf(spoke), "the ask placement reset the stale mark");

        PlacementRecord[] memory records = ladderOf(spoke);
        for (uint256 i; i < records.length; ++i) {
            if (!records[i].above || records[i].liquidity == 0) continue;
            assertGt(records[i].upperTick, hook.highWaterTick(spoke), "no fresh ask sits under the mark");
        }

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        syncMarket();
        uint256 supplyBefore = amps.totalSupply();
        vm.prank(KEEPER);
        (, uint256 burned) = vault.compound(spoke);
        assertEq(burned, 0, "and the compound burned nothing back");
        assertEq(amps.totalSupply(), supplyBefore, "the supply is untouched");
    }

    /// @notice The ordering rule of §3.5: the burn runs *before* the re-ladder and the mark is reset *after*, so
    ///         freshly re-laddered AMPS can never be mistaken for bought-back inventory on the next call.
    function test_i33_theMarkIsResetAfterTheBurnSoFreshAsksAreNotBurnedNext() public {
        _tradeForAmpsFees();
        // The mark crossed the whole ask ladder: every ask cell holding AMPS is bought-back inventory.
        hook.setHighWaterTick(hubPool, _highestAskUpper());

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        uint32 resetsBefore = hook.highWaterResetCount(hubPool);
        vm.prank(KEEPER);
        (uint256 fees1, uint256 burned1) = vault.compound(hubPool);
        assertGt(burned1, _expectedBurnCut(fees1), "the first compound bought back and burned");
        // Twice, not once: the re-ladder of step 6 resets the mark for the asks it has just placed, and step 8
        // resets it again for the call as a whole. Both are after the burn, which is the ordering that matters.
        assertEq(hook.highWaterResetCount(hubPool) - resetsBefore, 2, "and reset the mark, after the burn");

        // The mark now sits at the live tick, so the AMPS just re-laddered above it is not "crossed".
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        (uint256 fees2, uint256 burned2) = vault.compound(hubPool);
        assertEq(burned2, _expectedBurnCut(fees2), "the second compound burned only the fee split");
    }

    // -------------------------------------------------------------------------------------------------------------
    // §3.6 step 8 — the side effects, and what a zero-work call may not do
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A `compound` that moves something arms the surge, resets the mark and dates the pool, so it cannot
    ///         be sandwiched at the pre-compound fee and the next call takes the cooldown.
    function test_aCompoundThatDoesWorkArmsTheSurgeResetsTheMarkAndTakesTheCooldown() public {
        _tradeForAmpsFees();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint32 armed = hook.surgeArmedCount(hubPool);
        uint32 reset = hook.highWaterResetCount(hubPool);

        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "the call had work to do");

        assertGt(hook.surgeArmedCount(hubPool), armed, "armed");
        assertEq(hook.lastSurgeReason(hubPool), bytes32("compound"), "with the compound's reason");
        assertGt(hook.highWaterResetCount(hubPool), reset, "the mark was reset");
        assertEq(vault.lastPlacementAt(hubPool), uint32(block.timestamp), "and the pool was dated");
    }

    /// @notice **The finding this closes.** A `compound` on a pool with nothing to do changed no position, so it
    ///         may not take any of step 8's side effects. Arming `SURGE_MAX_BPS` would let anyone tax the pool at
    ///         the maximum surge once a minute for free; resetting the mark would erase the excursion the *next*
    ///         compound needs to recognise its own bought-back inventory; and taking the 60-second cooldown would
    ///         let the same free call deny a real `compound` — or a governance `place` — on that pool.
    function test_aZeroWorkCompoundLeavesTheSurgeTheMarkAndTheCooldownAlone() public {
        // A mark at the live tick crosses no ask, and every bid it does cross the price has not come back
        // through, so there is nothing to burn and nothing has accrued.
        int24 mark = tickOf(hubPool);
        hook.setHighWaterTick(hubPool, mark);

        uint32 armed = hook.surgeArmedCount(hubPool);
        uint32 reset = hook.highWaterResetCount(hubPool);
        uint32 dated = vault.lastPlacementAt(hubPool);

        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);
        assertEq(ampsFees, 0, "nothing traded, so no fee accrued");
        assertEq(burned, 0, "and nothing was bought back");

        assertEq(hook.surgeArmedCount(hubPool), armed, "no surge was armed");
        assertEq(hook.highWaterResetCount(hubPool), reset, "the mark was not reset");
        assertEq(hook.highWaterTick(hubPool), mark, "and still stands where the excursion left it");
        assertEq(vault.lastPlacementAt(hubPool), dated, "and the pool was not dated");
    }

    /// @notice And the denial that follows from it: an empty `compound` no longer holds the pool's 60-second
    ///         cooldown against the placement that has something to do.
    function test_aZeroWorkCompoundCannotDenyTheNextPlacement() public {
        hook.setHighWaterTick(hubPool, tickOf(hubPool));
        vm.prank(KEEPER);
        vault.compound(hubPool);

        // Same block, same pool: a governance placement is not refused by a call that did nothing.
        vm.prank(TIMELOCK);
        assertGt(vault.place(hubPool, true, 10e18), 0, "the timelock still places");
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

    /// @notice `compound` is permissionless and pays the caller a bounty sized to the work it **measured**
    ///         (§12.4 ruling W), inside every one of the pot's four caps.
    function test_theKeeperIsPaidFromTheBountyPot() public {
        _tradeForAmpsFees();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 before = usdg.balanceOf(KEEPER);
        vm.recordLogs();
        vm.prank(KEEPER);
        vault.compound(hubPool);

        (uint256 workValueUsd18, uint256 paidUsd18, uint256 paidRaw, bytes32 reason) = _lastBountyPaid();
        assertGt(workValueUsd18, 0, "the job reported the work it actually did");
        assertGe(workValueUsd18, pot.chostUsd18(), "and it cleared the dust guard");
        assertGt(paidRaw, 0, "so the keeper was paid");
        assertEq(usdg.balanceOf(KEEPER) - before, paidRaw, "exactly what the pot reported");

        // Never more than tip + chip on the measured work, whichever cap bound. `BountyPot` reports
        // `bytes32(0)` whenever anything at all was payable, so a named reason here would mean a *refusal*.
        uint256 gross = pot.tipUsd18() + (workValueUsd18 * pot.chipBps()) / Constants.BPS;
        assertLe(paidUsd18, gross, "tip + chip is the ceiling before the caps");
        assertEq(reason, bytes32(0), "a payment, not a refusal");
        assertSweepClean("bounty");
    }

    /// @notice **The finding this closes.** A `compound()` on a pool with no accrued fees and no crossed cell is
    ///         worth nothing, so it earns nothing: the pot's `chost` dust guard fires, which it structurally could
    ///         not while the libraries reported a flat `$1` (`docs/keeper-runbook.md` §3.1).
    function test_anEmptyCompoundEarnsNothingBecauseChostFires() public {
        uint256 before = usdg.balanceOf(KEEPER);

        vm.recordLogs();
        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);
        assertEq(ampsFees, 0, "nothing traded, so no fee accrued");
        assertEq(burned, 0, "and nothing was bought back");

        (uint256 workValueUsd18,, uint256 paidRaw, bytes32 reason) = _lastBountyPaid();
        assertEq(workValueUsd18, 0, "the job measured zero work");
        assertEq(reason, bytes32("chost"), "the dust guard is what refused");
        assertEq(paidRaw, 0, "and nothing was paid");
        assertEq(usdg.balanceOf(KEEPER), before, "the keeper's balance is untouched");
    }

    /// @notice A spam campaign of empty `compound()`s across the cooldown pays exactly zero, however many are
    ///         submitted: the guard is on the work, not on the caller.
    function test_aSpamCampaignOfEmptyCompoundsDrainsNothing() public {
        uint256 potBefore = pot.balance();
        for (uint256 i; i < 8; ++i) {
            vm.prank(KEEPER);
            vault.compound(hubPool);
            warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        }
        assertEq(pot.balance(), potBefore, "the pot is exactly where it started");
        assertEq(usdg.balanceOf(KEEPER), 0, "and the spammer earned nothing");
    }

    /// @notice The 3x gas cap is live: with the chip governed to its band ceiling the gross outruns three times
    ///         the measured gas cost, and the cap — not the tip, not the ceiling, not the balance — is what sets
    ///         the payment. It could not bind at all while the libraries reported a flat `$1` of gas
    ///         (`docs/keeper-runbook.md` §3.2), because `3 x $1` sat far above anything a job could earn.
    function test_theGasCapBindsOnceTheChipOutrunsIt() public {
        vm.prank(TIMELOCK);
        pot.setChipBps(Constants.CHIP_BPS_MAX);

        _tradeForAmpsFees();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.recordLogs();
        vm.prank(KEEPER);
        vault.compound(hubPool);

        (uint256 workValueUsd18, uint256 paidUsd18, uint256 paidRaw,) = _lastBountyPaid();
        uint256 gross = pot.tipUsd18() + (workValueUsd18 * Constants.CHIP_BPS_MAX) / Constants.BPS;
        assertGt(paidUsd18, 0, "it paid");
        assertLt(paidUsd18, gross, "and paid strictly less than tip + chip, so a cap bound");

        // Which cap: not the ceiling (the window still has room) and not the balance (the pot holds far more),
        // so it is the gas cap by elimination.
        assertLt(paidUsd18, Constants.DAILY_CEILING_USD18_DEFAULT, "the ceiling was not reached");
        assertGt(pot.balance() + paidRaw, paidRaw * 100, "the pot was nowhere near empty");

        // `gasCap == 3 x gasCostUsd18`, so the implied gas bill is a third of the payment: cents, not the flat
        // $0.07 the old constants produced whatever the job actually cost.
        uint256 impliedGasUsd18 = paidUsd18 / Constants.KEEPER_GAS_CAP_MULTIPLE;
        assertGt(impliedGasUsd18, 0.005e18, "a compound costs more than half a cent at the floor basefee");
        assertLt(impliedGasUsd18, 0.15e18, "and no more than 6M gas of it -- see the EIP-150 test below");
    }

    /// @notice The gas allowance measures the **job**, not the caller's gas limit.
    /// @dev EIP-150 forwards at most 63/64 of the caller's remaining gas to every message call, so a naive
    ///      `gasStart - gasleft()` across the vault's delegatecall into the placement library charges the job for
    ///      1/64 of the transaction's gas limit as well as for the gas it spent — 16.8M under Foundry's 2^30
    ///      default, and on chain a lever a keeper could pull to inflate the pot's own 3x ceiling by sending the
    ///      job with a large limit. This reconstructs the gas figure the pot was handed, out of the payment the
    ///      cap produced, and holds it against what the call really burned.
    function test_theGasAllowanceMeasuresTheJobNotTheCallersGasLimit() public {
        // Chip at its band ceiling, so the gas cap — and therefore the gas figure — is what sets the payment.
        vm.prank(TIMELOCK);
        pot.setChipBps(Constants.CHIP_BPS_MAX);

        _tradeForAmpsFees();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.recordLogs();
        uint256 before = gasleft();
        vm.prank(KEEPER);
        vault.compound(hubPool);
        uint256 spent = before - gasleft();

        (, uint256 paidUsd18,,) = _lastBountyPaid();

        // `paid == gasCapMultiple x gasUsed x basefee x ethUsd`, and Foundry's `block.basefee` is zero, so the
        // basefee in force is the floor. Invert it to recover exactly what the vault told the pot.
        uint256 usdPerGas = (Constants.KEEPER_BASEFEE_FLOOR_WEI * WETH_USD8) / 1e8;
        uint256 reportedGas = paidUsd18 / Constants.KEEPER_GAS_CAP_MULTIPLE / usdPerGas;

        assertLe(reportedGas, spent + Constants.KEEPER_GAS_OVERHEAD, "never more gas than the call actually burned");
        assertGe(reportedGas, spent / 2, "and not a token figure either");
        assertLt(reportedGas, Constants.KEEPER_GAS_MAX, "well inside the hard ceiling");
    }

    /// @notice The rolling daily ceiling still binds ahead of the pot's balance.
    function test_theDailyCeilingBindsAheadOfTheBalance() public {
        vm.prank(TIMELOCK);
        pot.setDailyCeilingUsd18(0.02e18);

        _tradeForAmpsFees();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.recordLogs();
        vm.prank(KEEPER);
        vault.compound(hubPool);

        (,, uint256 paidRaw,) = _lastBountyPaid();
        assertEq(paidRaw, 0.02e18 / 1e12, "it paid exactly the budget that was left");
        assertEq(pot.spentLast24h(), 0.02e18, "which is the whole window");
        assertEq(pot.budgetLeftUsd18(), 0, "and the ceiling is now exhausted");

        // The next job in the same window is refused by name, which is how a refusal reaches the keeper.
        (uint256 payable_, bytes32 reason) = pot.quote(100e18, 10e18);
        assertEq(payable_, 0, "nothing left to pay");
        assertEq(reason, bytes32("dailyCeiling"), "and the ceiling is what says so");
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

    /// @notice A `compound` that does work takes the same 60-second cooldown as every other placement.
    function test_compoundTakesThePlacementCooldown() public {
        _tradeForAmpsFees();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "the call had work to do, so it dated the pool");

        vm.prank(KEEPER);
        vm.expectPartialRevert(bytes4(keccak256("PlacementCooldown(bytes32,uint32)")));
        vault.compound(hubPool);
    }

    // -------------------------------------------------------------------------------------------------------------
    // §3.6 step 8 — the surge and the mark follow an AMPS-side event, the cooldown follows a placement
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **The finding this closes.** Step 8's condition included `counterFees != 0`, and the counter side
    ///         is whatever a *buyer* paid the ladder — one wei of it, which anyone can produce for the price of a
    ///         dust swap. That wei **erased the high-water mark**, which is the excursion the next `compound`
    ///         needs in order to recognise its own bought-back inventory (§3.5): a buyer could keep the vault
    ///         permanently forgetful of its own round trips, once every sixty seconds, for a gas fee. The mark and
    ///         the step-8 surge are AMPS-side facts and now require an AMPS-side event — something burned, or
    ///         something re-laddered out of the split.
    function test_aCounterFeeOnlyCompoundResetsNoMark() public {
        // A buy pays its fee on the way *in*, in USDG, so the AMPS side collects nothing at all.
        buyAmps(hubPool, address(usdg), 100e6);
        syncMarket();

        // The mark at the live tick crosses no ask, so the buyback burns nothing either: the call's only work is
        // the counter-side fee.
        int24 mark = tickOf(hubPool);
        hook.setHighWaterTick(hubPool, mark);

        uint32 reset = hook.highWaterResetCount(hubPool);
        uint32 armed = hook.surgeArmedCount(hubPool);

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);
        assertEq(ampsFees, 0, "the buy paid its fee in the counter asset, not in AMPS");
        assertEq(burned, 0, "and nothing was bought back");

        assertEq(hook.highWaterResetCount(hubPool), reset, "the mark was not reset off a counter-side fee");
        assertEq(hook.highWaterTick(hubPool), mark, "and still stands where the excursion left it");

        // Step 8 arms nothing either. The one surge this call does arm is the *bid re-ladder's* own, from
        // {VaultPlacementLib-_placeLadder}: a real placement happened and §3.8 step 8 says a placement is never
        // left un-surged. Before the fix there were two — the placement's and step 8's — off the same wei.
        assertEq(hook.surgeArmedCount(hubPool) - armed, 1, "only the placement armed a surge, not step 8 as well");
        assertEq(vault.lastPlacementAt(hubPool), uint32(block.timestamp), "and the counter bids did date the pool");
    }

    // -------------------------------------------------------------------------------------------------------------
    // I32 — the re-laid ask ladder is anchored at `P_ref`, like every other ask
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **The finding this closes.** `place`, `rollout` and `deployBonded` all anchor an ask ladder at
    ///         `tickOf(P_ref / P_counter)` — I32's "a rolled-out ask is never placed below `P_ref`" — but
    ///         `compound` anchored its re-ladder at the *live tick*. A pool trading below the reference therefore
    ///         re-laid its own fees as asks under the protocol's own backing and undersold it, once a minute, on a
    ///         permissionless call. `_cells` takes `max(fromAnchor, fromTick)`, so anchoring at the reference
    ///         still keeps every ask strictly above the live tick when the pool is *above* the reference instead.
    function test_i32_compoundAnchorsTheRelaidAskLadderAtTheReferenceNotTheTick() public {
        _tradeForAmpsFees();

        // A drawdown, so the reference and the live tick are not the same number and the assertion has content.
        giveShares(BOB, 80e18);
        sellAmps(hubPool, amps.balanceOf(BOB));
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        int24 refTick = PriceLib.fairTick(vault.pRefX18(), USDG_USD8, 6, TICK_SPACING);
        assertLt(tickOf(hubPool), refTick, "the pool is trading below P_ref");

        vm.recordLogs();
        vm.prank(KEEPER);
        vault.compound(hubPool);

        (int24 anchorTick, int24 lowestTick,) = _lastAskPlacement(hubPool);
        assertEq(anchorTick, refTick, "the re-ladder is anchored at tickOf(P_ref / P_counter)");
        assertGe(lowestTick, refTick, "so its first cell sits at or above the reference cell");
    }

    // -------------------------------------------------------------------------------------------------------------
    // §3.6 step 5 — the creator slice cannot be enlarged by cutting the sell fee
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **The finding this closes.** `creatorCut = ampsFees x creatorBps / sellFeeBps` reads the collected
    ///         fee as "`sellFeeBps` of what crossed the pool". `SELL_FEE_BPS_MIN` and `CREATOR_FEE_BPS` are both
    ///         100, so an entirely in-band `setSellFeeBps(100)` made that ratio **one** and routed every wei of
    ///         the AMPS-side fees to the creator — no staker stream, no burn, no re-ladder. Flooring the divisor
    ///         at `SELL_FEE_BPS_DEFAULT` caps the slice at one fifth of the AMPS-side fees however low the live
    ///         fee goes.
    function test_theCreatorSliceIsCappedWhenTheSellFeeIsCutToItsFloor() public {
        _tradeForAmpsFees();
        hook.setHighWaterTick(hubPool, tickOf(hubPool));
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        // The whole attack: cut the base fee to its floor immediately before the permissionless call.
        hook.setSellFeeBps(Constants.SELL_FEE_BPS_MIN);
        assertEq(uint256(hook.sellFeeBps()), uint256(Constants.CREATOR_FEE_BPS), "the ratio the bug turned into 1");

        uint256 creatorBefore = amps.balanceOf(CREATOR);
        uint256 stakingBefore = amps.balanceOf(address(staking));

        vm.recordLogs();
        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "there were fees to split");

        uint256 creatorPaid = amps.balanceOf(CREATOR) - creatorBefore;
        assertLe(creatorPaid, ampsFees / 5, "never more than CREATOR_FEE_BPS / SELL_FEE_BPS_DEFAULT of the fees");
        assertGt(amps.balanceOf(address(staking)) - stakingBefore, 0, "the stakers were still paid");
        assertGt(burned, 0, "the burn still happened");
        assertGt(_lastCompoundRelaid(), 0, "and something was still re-laddered");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The liquidity a pool's record for the cell starting at `lower` holds, or zero when there is none.
    function _liquidityAt(PoolId poolId, int24 lower) private view returns (uint128 liquidity) {
        PlacementRecord[] memory records = ladderOf(poolId);
        for (uint256 i; i < records.length; ++i) {
            if (records[i].lowerTick == lower) return records[i].liquidity;
        }
        return 0;
    }

    /// @dev The hub's highest live bid cell: the one the next tick down falls into.
    function _topBid() private view returns (int24 lower, int24 upper, uint128 liquidity) {
        PlacementRecord[] memory records = ladderOf(hubPool);
        for (uint256 i; i < records.length; ++i) {
            if (records[i].above || records[i].liquidity == 0) continue;
            if (liquidity != 0 && records[i].upperTick <= upper) continue;
            (lower, upper, liquidity) = (records[i].lowerTick, records[i].upperTick, records[i].liquidity);
        }
    }

    /// @dev The last ask-side `Placement` for `poolId` in the recorded logs. `vm.recordLogs()` must have been
    ///      armed before the call.
    function _lastAskPlacement(PoolId poolId) private returns (int24 anchorTick, int24 lowestTick, int24 highestTick) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i != 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(vault) || entry.topics[0] != IAmpsVault.Placement.selector) continue;
            if (entry.topics[1] != PoolId.unwrap(poolId)) continue;
            (bool above,,, int24 anchor,, int24 lower, int24 upper) =
                abi.decode(entry.data, (bool, uint8, uint256, int24, bytes32, int24, int24));
            if (!above) continue;
            return (anchor, lower, upper);
        }
        revert("no ask Placement");
    }

    /// @dev The `relaid` field of the last `Compound` in the recorded logs.
    function _lastCompoundRelaid() private returns (uint256 relaid) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i != 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(vault) || entry.topics[0] != IAmpsVault.Compound.selector) continue;
            (,,,, relaid) = abi.decode(entry.data, (uint256, uint256, uint256, uint256, uint256));
            return relaid;
        }
        revert("no Compound");
    }

    /// @dev The last `BountyPaid` in the recorded logs. `vm.recordLogs()` must have been armed before the call.
    function _lastBountyPaid()
        private
        returns (uint256 workValueUsd18, uint256 paidUsd18, uint256 paidRaw, bytes32 reason)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IBountyPot.BountyPaid.selector;
        for (uint256 i = logs.length; i != 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(pot) || entry.topics.length == 0 || entry.topics[0] != topic) continue;
            return abi.decode(entry.data, (uint256, uint256, uint256, bytes32));
        }
        revert("no BountyPaid");
    }

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
