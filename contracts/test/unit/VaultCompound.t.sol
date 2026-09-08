// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IBountyPot} from "../../src/interfaces/IBountyPot.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {PlacementFixture} from "../mocks/PlacementFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title VaultCompoundTest
/// @notice `docs/phase3-state-model.md` §8.1's row for this file: plan revision 6's split — the creator's slice
///         of **each** currency, then the whole AMPS-side remainder burned and the whole counter-side remainder
///         re-placed as bids — to the wei, `creatorBps(t) == 0` after day 30 (I31), the high-water buyback burn in
///         all three tick positions (I33), the reset ordering, and the keeper bounty.
///
/// @dev The fees are real: they come out of real swaps against the real ladder through the v4 router, at the
///      hook's real directional fee (500 bp on an AMPS-in swap, 30 bp on an AMPS-out one in an entry pool).
contract VaultCompoundTest is PlacementFixture {
    /// @dev The `Compound` event's data half, decoded.
    struct Compounded {
        uint256 ampsFees;
        uint256 counterFees;
        uint256 creatorAmps;
        uint256 creatorCounter;
        uint256 burned;
    }

    /// @dev `vm.getRecordedLogs()` empties the buffer, so a test that reads two things out of one call reads it
    ///      once and keeps it here.
    Vm.Log[] private _logs;

    function setUp() public {
        deployPlacementWorld();
        placeGenesisLadders();
        fundPot(1000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // §3.6 step 5 — the split
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The whole of §3.6 step 5 as revision 6 states it, to the wei:
    ///         ```
    ///         creatorAmps    = ampsFees    x min(creatorBps(t), ampsFeeBps) / ampsFeeBps
    ///         creatorCounter = counterFees x min(creatorBps(t), ampsFeeBps) / ampsFeeBps
    ///         burned         = ampsFees - creatorAmps                       (plus the buyback)
    ///         bids           = counterFees - creatorCounter                 (re-placed below the market)
    ///         ```
    function test_split_creatorInEachCurrencyThenTheWholeAmpsRemainderIsBurned() public {
        _tradeForAmpsFees();
        // The mark sits at the live tick, so nothing is crossed and the only burn is the fee split's. The
        // buyback burn has its own three tests below.
        hook.setHighWaterTick(hubPool, tickOf(hubPool));

        uint256 creatorAmpsBefore = amps.balanceOf(CREATOR);
        uint256 creatorUsdgBefore = usdg.balanceOf(CREATOR);
        uint256 supplyBefore = amps.totalSupply();

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.recordLogs();
        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "the sell really paid a fee in AMPS");

        uint256 ampsFeeBps = hook.ampsFeeBps();
        uint256 creatorBps = vault.creatorBpsAt(block.timestamp);
        Compounded memory log = _lastCompound();
        assertGt(log.counterFees, 0, "and the buy really paid one in USDG");

        uint256 creatorAmps = ampsFees * creatorBps / ampsFeeBps;
        uint256 creatorCounter = log.counterFees * creatorBps / ampsFeeBps;

        // The same fraction of each currency, and the log says the same thing the balances do.
        assertEq(amps.balanceOf(CREATOR) - creatorAmpsBefore, creatorAmps, "the creator's AMPS slice, to the wei");
        assertEq(usdg.balanceOf(CREATOR) - creatorUsdgBefore, creatorCounter, "and the USDG slice, to the wei");
        assertEq(log.creatorAmps, creatorAmps, "the event agrees on AMPS");
        assertEq(log.creatorCounter, creatorCounter, "and on the counter");

        // Every wei of the AMPS side that is left is burned. Nothing is streamed and nothing is re-laddered.
        assertEq(burned, ampsFees - creatorAmps, "the burn is the whole AMPS-side remainder");
        assertEq(supplyBefore - amps.totalSupply(), burned, "totalSupply fell by exactly the burn");
        assertEq(log.burned, burned, "and the event agrees");
        assertEq(creatorAmps + burned, ampsFees, "the AMPS split is exhaustive: creator, then burn, and nothing else");
        assertSweepClean("compound");
    }

    /// @notice The creator slice is `1 / ampsFeeBps` of the AMPS-side fees at genesis: one point of a five-point
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
            ampsFees * creatorBps / hook.ampsFeeBps(),
            "one point of five, less the schedule's first few minutes"
        );
    }

    /// @notice I31: `creatorBps(t)` is monotone non-increasing and exactly zero from `genesis + 30 days`, and the
    ///         schedule is immutable — nothing but time changes it.
    function test_i31_creatorScheduleDecaysToZeroAndStaysThere() public view {
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
        uint256 creatorUsdgBefore = usdg.balanceOf(CREATOR);
        hook.setHighWaterTick(hubPool, tickOf(hubPool));

        vm.recordLogs();
        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);

        assertGt(ampsFees, 0, "there were fees to split");
        assertEq(amps.balanceOf(CREATOR), creatorBefore, "the creator got no AMPS");
        assertEq(usdg.balanceOf(CREATOR), creatorUsdgBefore, "and no counter asset either");

        Compounded memory log = _lastCompound();
        assertEq(log.creatorAmps, 0, "the event says zero");
        assertEq(log.creatorCounter, 0, "in both currencies");
        assertEq(burned, ampsFees, "and the whole AMPS-side fee is burned instead");
    }

    /// @notice The creator's fraction is the same one in every currency at every point of the schedule: day 0,
    ///         mid-decay and after it ends. `creatorBps / ampsFeeBps` of the collected fees is `creatorBps` of the
    ///         volume that produced them, because the hook charges `ampsFeeBps` on both sides of every trade.
    /// @dev The warps are whole weeks so that every sample lands on the same weekday and the same time of day as
    ///      genesis: `OracleGate` reports `DEGRADED` outside regular trading hours, and a `compound` refuses in
    ///      `DEGRADED`, so a mid-decay sample taken on a Saturday would be testing the calendar rather than the
    ///      split. Day 14 is mid-decay (53 bp of 100) and day 35 is past the end of the schedule.
    function test_split_theCreatorTakesTheSameFractionOfEachCurrencyAcrossTheSchedule() public {
        _assertCreatorFraction("day 0");

        warpBy(14 days);
        syncMarket();
        assertGt(vault.creatorBpsAt(block.timestamp), 0, "mid-decay, and not yet zero");
        _assertCreatorFraction("day 14");

        warpBy(21 days);
        syncMarket();
        assertEq(vault.creatorBpsAt(block.timestamp), 0, "the schedule has run out");
        _assertCreatorFraction("day 35");
    }

    /// @notice A counter asset that refuses the creator cannot revert `compound`: the in-kind `take` is bounded,
    ///         its failure falls back to an ERC-6909 claim, and the burn, the bids and the bounty all still happen.
    ///
    /// @dev This is the same shape `VaultRedeemLib._payOut` uses for the redemption floor, and it exists for the
    ///      same reason: the token that refuses is exactly the token whose issuer would otherwise hold a veto over
    ///      the protocol's fee engine.
    function test_split_aGatedCounterTokenPaysTheCreatorInClaimsAndDoesNotRevert() public {
        PoolId spoke = spokePools[0];
        MockStockToken stock = stocks[0];

        // A buy in the spoke pays its fee in the Stock Token, which is the counter side there. The trade is
        // deliberately tiny and the buy fee deliberately large: the spoke's ladder is 90 AMPS and `syncMarket`
        // re-seeds every ring at the *hub's* AMPS price, so a buy that walks the spoke far from the hub would fail
        // the placement divergence check rather than the thing this test is about. A 5% buy fee makes the
        // creator's counter slice comfortably non-zero while what actually reaches the pool moves it ~280 ticks,
        // well inside `PLACEMENT_DIVERGENCE_TICKS`.
        hook.setBuyFeeBps(spoke, 500);
        buyAmps(spoke, address(stock), 0.0004e18);
        syncMarket();
        hook.setHighWaterTick(spoke, tickOf(spoke));
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        // The issuer denylists the creator. An ERC-20 `transfer` to them now reverts.
        address[] memory blocked = new address[](1);
        blocked[0] = CREATOR;
        stock.blockAccounts(blocked);

        uint256 claimBefore = poolManager.balanceOf(CREATOR, uint256(uint160(address(stock))));
        uint256 supplyBefore = amps.totalSupply();

        vm.recordLogs();
        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(spoke);

        Compounded memory log = _lastCompound();
        assertGt(log.counterFees, 0, "the buy paid a counter-side fee");
        assertGt(log.creatorCounter, 0, "and the creator was owed a slice of it");
        assertEq(stock.balanceOf(CREATOR), 0, "the token refused the in-kind transfer");
        assertEq(
            poolManager.balanceOf(CREATOR, uint256(uint160(address(stock)))) - claimBefore,
            log.creatorCounter,
            "so the creator holds the slice as an ERC-6909 claim instead"
        );

        // And the rest of the call happened exactly as it would have.
        assertEq(supplyBefore - amps.totalSupply(), log.burned, "the burn still ran");
        assertEq(log.creatorAmps, ampsFees * vault.creatorBpsAt(block.timestamp) / hook.ampsFeeBps(), "AMPS unaffected");
        assertSweepClean("gated creator");
    }

    /// @notice Counter-side fees leave the protocol only through the creator's slice: everything else goes back
    ///         into the pool as bids below the market, at the prices the ladder raised it at.
    function test_counterSideFeesStayInThePoolAsBidsExceptTheCreatorSlice() public {
        // A buy pays its fee in USDG, which is the counter side of the hub.
        buyAmps(hubPool, address(usdg), 200e6);
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 creatorBefore = usdg.balanceOf(CREATOR);
        uint256 poolBefore = usdg.balanceOf(address(poolManager));

        vm.recordLogs();
        vm.prank(KEEPER);
        vault.compound(hubPool);

        Compounded memory log = _lastCompound();
        assertGt(log.counterFees, 0, "the buy paid a counter-side fee");
        assertEq(
            usdg.balanceOf(CREATOR) - creatorBefore,
            log.counterFees * vault.creatorBpsAt(block.timestamp) / hook.ampsFeeBps(),
            "the creator's slice, to the wei"
        );
        assertEq(
            poolBefore - usdg.balanceOf(address(poolManager)),
            log.creatorCounter,
            "and the creator's slice is the only USDG that left the PoolManager"
        );
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
        uint256 creatorUsdg = usdg.balanceOf(CREATOR);
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);

        assertEq(burned, _expectedBurnCut(ampsFees), "nothing was burned but the fee split");
        assertEq(supplyBefore - amps.totalSupply(), burned, "and the supply agrees");
        assertGe(_liquidityAt(hubPool, straddledLower), straddledLiquidity, "the straddled cell is untouched");
        assertEq(
            poolUsdg - usdg.balanceOf(address(poolManager)),
            usdg.balanceOf(CREATOR) - creatorUsdg,
            "the creator's counter slice is the only USDG that left the PoolManager"
        );
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
        // The cell was emptied by the burn and nothing re-fills it: revision 6 places no ask at `compound`.
        assertEq(_liquidityAt(hubPool, base), 0, "the bought-back inventory is gone from the cell");

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

    /// @notice The ordering rule of §3.5: the burn runs *before* anything this call places, and the mark is reset
    ///         *after*, so nothing `compound` leaves behind can be mistaken for bought-back inventory next time.
    function test_i33_theMarkIsResetAfterTheBurnSoFreshCellsAreNotBurnedNext() public {
        _tradeForAmpsFees();
        // The mark crossed the whole ask ladder: every ask cell holding AMPS is bought-back inventory.
        hook.setHighWaterTick(hubPool, _highestAskUpper());

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        uint32 resetsBefore = hook.highWaterResetCount(hubPool);
        vm.prank(KEEPER);
        (uint256 fees1, uint256 burned1) = vault.compound(hubPool);
        assertGt(burned1, _expectedBurnCut(fees1), "the first compound bought back and burned");
        // Once: step 8's reset for the call as a whole. There is no ask placement to reset it a second time
        // since revision 6, and what matters is unchanged — the reset is *after* the burn.
        assertEq(hook.highWaterResetCount(hubPool) - resetsBefore, 1, "and reset the mark, after the burn");

        // The mark now sits at the live tick, so nothing above it is "crossed".
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

    /// @notice And with the budget full **and** the pool's bid cells already live, the counter re-placement
    ///         merges into them, so nothing is left idle at all.
    function test_e_compoundStillPlacesCounterBidsIntoExistingCellsWhenTheBudgetIsFull() public {
        _tradeForAmpsFees();
        hook.setHighWaterTick(hubPool, tickOf(hubPool));
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 before = _bidAmountTotal();
        forceLiveCells(Constants.MAX_LIVE_CELLS);

        vm.prank(KEEPER);
        vault.compound(hubPool);
        assertGt(_bidAmountTotal(), before, "the bid cells took the counter-side fees");
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
    // I10/I32 — `compound` places no ask at all
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Revision 6's structural half of I10 and I32 at once: `compound` never places an ask. The AMPS-side
    ///         fees are burned rather than re-laddered, so the ask inventory is genesis POL less what the market
    ///         bought and what `rollout` moved, and there is no path on which a permissionless call can re-sell
    ///         AMPS the protocol has just bought back — nor, on a pool trading below the reference, undersell its
    ///         own backing, which is what anchoring the old re-ladder at the live tick did.
    function test_compoundNeverPlacesAnAsk() public {
        _tradeForAmpsFees();

        // A drawdown, so the pool trades below the reference: the exact configuration in which the old re-ladder
        // put asks under the protocol's own backing.
        giveShares(BOB, 80e18);
        sellAmps(hubPool, amps.balanceOf(BOB));
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        int24 refTick = PriceLib.fairTick(vault.pRefX18(), USDG_USD8, 6, TICK_SPACING);
        assertLt(tickOf(hubPool), refTick, "the pool is trading below P_ref");

        uint256 askBefore = _askAmountTotal();
        vm.recordLogs();
        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "the call really had AMPS-side fees it could have re-laddered");

        assertEq(_askPlacementCount(hubPool), 0, "no ask Placement was emitted");
        assertLe(_askAmountTotal(), askBefore, "and no ask cell grew");
        assertGt(_bidPlacementCount(hubPool), 0, "while the counter side was placed as bids, as it always is");
    }

    // -------------------------------------------------------------------------------------------------------------
    // §3.6 step 5 — the creator slice under a governed fee change
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The old divisor floor (`max(ampsFeeBps, AMPS_FEE_BPS_DEFAULT)`) is gone, and what bounds the slice
    ///         now is the clamp `creatorBps <= ampsFeeBps`. Cutting the base fee to its floor cannot pay the
    ///         creator more than the whole of one currency's fees, the split stays exhaustive, and what the
    ///         creator does not take is burned — which is the reason the floor is no longer needed: there is no
    ///         permanent constituency left for a fee cut to starve.
    function test_theCreatorSliceIsClampedToTheWholeFeeWhenTheSellFeeIsCutToItsFloor() public {
        _tradeForAmpsFees();
        hook.setHighWaterTick(hubPool, tickOf(hubPool));
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        // Cut the base fee to its floor immediately before the permissionless call. `AMPS_FEE_BPS_MIN` and
        // `CREATOR_FEE_BPS` are both 100, so the ratio is as large as it can ever be.
        hook.setAmpsFeeBps(Constants.AMPS_FEE_BPS_MIN);
        assertEq(uint256(hook.ampsFeeBps()), uint256(Constants.CREATOR_FEE_BPS), "the ratio is at its ceiling");

        uint256 creatorBefore = amps.balanceOf(CREATOR);
        uint256 supplyBefore = amps.totalSupply();

        vm.recordLogs();
        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "there were fees to split");

        uint256 creatorPaid = amps.balanceOf(CREATOR) - creatorBefore;
        assertLe(creatorPaid, ampsFees, "never more than the whole of the AMPS-side fees");
        assertEq(
            creatorPaid,
            ampsFees * vault.creatorBpsAt(block.timestamp) / Constants.AMPS_FEE_BPS_MIN,
            "exactly creatorBps / ampsFeeBps of them"
        );
        assertEq(burned, ampsFees - creatorPaid, "and every wei that is left is still burned");
        assertEq(supplyBefore - amps.totalSupply(), burned, "the supply agrees");
        assertEq(_askPlacementCount(hubPool), 0, "and nothing was re-laddered");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Revision 6 — the retired surface is gone
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `staking()`, `burnBps()`, `stakerBps()`, their bands and their setters do not exist on the vault
    ///         any more: staking was removed and the burn is unconditional, so there is no parameter to read and
    ///         no selector for a stale integration — or a stale timelock proposal — to reach.
    function test_theRetiredStakingAndBurnSelectorsAreGone() public {
        string[5] memory reads = ["staking()", "burnBps()", "stakerBps()", "BURN_BPS_MAX()", "STAKER_BPS_MAX()"];
        for (uint256 i; i < reads.length; ++i) {
            (bool ok,) = address(vault).staticcall(abi.encodeWithSignature(reads[i]));
            assertFalse(ok, string.concat("selector still reachable: ", reads[i]));
        }

        string[2] memory setters = ["setBurnBps(uint16)", "setStakerBps(uint16)"];
        vm.startPrank(TIMELOCK);
        for (uint256 i; i < setters.length; ++i) {
            (bool ok,) = address(vault).call(abi.encodeWithSignature(setters[i], uint16(1)));
            assertFalse(ok, string.concat("selector still reachable: ", setters[i]));
        }
        vm.stopPrank();
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

    /// @dev How many `Placement` logs for `poolId` on the given side the recorded logs hold. `vm.recordLogs()`
    ///      must have been armed before the call; the logs are *consumed* by the read, so a test asks once.
    function _placementCount(Vm.Log[] memory logs, PoolId poolId, bool wantAbove) private view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(vault) || entry.topics[0] != IAmpsVault.Placement.selector) continue;
            if (entry.topics[1] != PoolId.unwrap(poolId)) continue;
            (bool above,,,,,,) = abi.decode(entry.data, (bool, uint8, uint256, int24, bytes32, int24, int24));
            if (above == wantAbove) ++n;
        }
    }

    /// @dev Ask-side `Placement` logs for `poolId`, out of the buffer this call drains.
    function _askPlacementCount(PoolId poolId) private returns (uint256 n) {
        return _placementCount(_drainLogs(), poolId, true);
    }

    /// @dev Bid-side `Placement` logs for `poolId`, out of the buffer this call drains.
    function _bidPlacementCount(PoolId poolId) private returns (uint256 n) {
        return _placementCount(_drainLogs(), poolId, false);
    }

    /// @dev The recorded logs, cached so several readers in one test see the same buffer: `vm.getRecordedLogs()`
    ///      empties it.
    function _drainLogs() private returns (Vm.Log[] memory logs) {
        if (_logs.length == 0) {
            Vm.Log[] memory fresh = vm.getRecordedLogs();
            for (uint256 i; i < fresh.length; ++i) {
                _logs.push(fresh[i]);
            }
        }
        return _logs;
    }

    /// @dev The last `Compound` in the recorded logs, field by field.
    function _lastCompound() private returns (Compounded memory log) {
        Vm.Log[] memory logs = _drainLogs();
        for (uint256 i = logs.length; i != 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(vault) || entry.topics[0] != IAmpsVault.Compound.selector) continue;
            (log.ampsFees, log.counterFees, log.creatorAmps, log.creatorCounter, log.burned) =
                abi.decode(entry.data, (uint256, uint256, uint256, uint256, uint256));
            return log;
        }
        revert("no Compound");
    }

    /// @dev One round of "trade, compound, and check the creator got `creatorBps / ampsFeeBps` of both sides".
    function _assertCreatorFraction(string memory label) private {
        _tradeForAmpsFees();
        hook.setHighWaterTick(hubPool, tickOf(hubPool));
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        syncMarket();

        uint256 ampsBefore = amps.balanceOf(CREATOR);
        uint256 usdgBefore = usdg.balanceOf(CREATOR);

        delete _logs;
        vm.recordLogs();
        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);

        Compounded memory log = _lastCompound();
        uint256 feeBps = hook.ampsFeeBps();
        uint256 creatorBps = vault.creatorBpsAt(block.timestamp);
        assertGt(ampsFees, 0, string.concat(label, ": the sell paid an AMPS-side fee"));
        assertGt(log.counterFees, 0, string.concat(label, ": the buy paid a counter-side fee"));
        assertEq(
            amps.balanceOf(CREATOR) - ampsBefore, ampsFees * creatorBps / feeBps, string.concat(label, ": AMPS slice")
        );
        assertEq(
            usdg.balanceOf(CREATOR) - usdgBefore,
            log.counterFees * creatorBps / feeBps,
            string.concat(label, ": counter slice")
        );
        delete _logs;
    }

    /// @dev The last `BountyPaid` in the recorded logs. `vm.recordLogs()` must have been armed before the call.
    function _lastBountyPaid()
        private
        view
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

    /// @dev The burn the fee split alone accounts for, so a test can tell it apart from a buyback: since
    ///      revision 6 that is the whole AMPS-side fee less the creator's slice.
    function _expectedBurnCut(uint256 ampsFees) private view returns (uint256) {
        uint256 feeBps = hook.ampsFeeBps();
        uint256 creatorBps = vault.creatorBpsAt(block.timestamp);
        if (creatorBps > feeBps) creatorBps = feeBps;
        return ampsFees - ampsFees * creatorBps / feeBps;
    }

    /// @dev The counter a pool's bid cells have been committed in total, which is what a counter re-placement
    ///      adds to.
    function _bidAmountTotal() private view returns (uint256 total) {
        PlacementRecord[] memory records = ladderOf(hubPool);
        for (uint256 i; i < records.length; ++i) {
            if (!records[i].above) total += records[i].amount;
        }
    }
}
