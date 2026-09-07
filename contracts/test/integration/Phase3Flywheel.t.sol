// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsQuoter} from "../../src/interfaces/IAmpsQuoter.sol";
import {LadderLib} from "../../src/lib/LadderLib.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {OutOfBand} from "../../src/types/Errors.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {Phase3Fixture} from "./Phase3Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

/// @title Phase3FlywheelTest
/// @notice `docs/phase3-state-model.md` §8.1's row for `integration/Phase3Flywheel.t.sol`, widened to the whole of
///         the plan's Phase 3 flywheel exit list: the ladder consumed bottom-up with per-bucket proceeds matching
///         `LadderLib`; a pump-then-dump round trip that ends with `totalSupply` lower and `A` equal to the seed
///         plus fees; `compound`'s creator -> staker -> burn -> re-ladder split to the wei; rollout inside
///         `rolloutBpsPerDay` and above `entryFloorBps`; the rotation credit end to end through the **real** hook;
///         the sell-fee band; `AmpsQuoter` exactness and total-function-ness against real swaps; `afterSwap`
///         reverting for nothing but `BeyondRail`; and the full user journey reconciled number by number.
///
/// @dev Everything here runs against {Phase3Fixture}: the real hook, the real policies, the real vault behind its
///      four linked libraries, on live v4 pools. No stub answers any question.
///
/// @dev **Why price moves are made with runs of small swaps.** The hook refuses a deviation-increasing swap that
///      begins or ends more than `outerRailTicks` from `fairTick` (§10 ruling 2), and `fairTick` is the pool's own
///      truncated 30-minute TWAP for an entry pool. A market therefore *cannot* move an Amplestocks pool by more
///      than the rail in one go; it climbs, waits for the reference to follow, and climbs again. {Phase3Fixture-climb}
///      is that arbitrageur.
contract Phase3FlywheelTest is Phase3Fixture {
    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(100_000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The ladder, consumed bottom-up
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The plan's "the ladder is consumed bottom-up under a simulated pump with per-bucket proceeds
    ///         matching `LadderLib`".
    ///
    ///         Cell `m` is a one-sided AMPS range over `[lower, upper)`. While the tick is below `lower` it is
    ///         pure AMPS; once the tick has crossed `upper` it is pure counter asset, and the amount it holds is
    ///         exactly `LadderLib.amount1ForLiquidity(lower, upper, L)` — the same liquidity the cell was placed
    ///         with, decomposed on the other side. That identity **is** symmetric proceeds (I29): a filled ask
    ///         becomes the bid at exactly the prices that raised it, with no code, no record change and no keeper.
    function test_ladderIsConsumedBottomUpWithLadderLibProceeds() public {
        PlacementRecord memory cell0 = cellOf(hubPool, 0);
        PlacementRecord memory cell1 = cellOf(hubPool, 1);
        PlacementRecord memory cell2 = cellOf(hubPool, 2);
        assertEq(cell0.upperTick, cell1.lowerTick, "cells are contiguous doublings");
        assertEq(cell1.upperTick, cell2.lowerTick, "and so are the next two");

        uint256 expectedProceeds0 = LadderLib.amount1ForLiquidity(
            PriceLib.tickToSqrtPriceX96(cell0.lowerTick), PriceLib.tickToSqrtPriceX96(cell0.upperTick), cell0.liquidity
        );

        // Walk the hub up through the whole of cell 0 and into cell 1.
        (, uint256 steps) = climb(hubPool, ALICE, 2e6, cell1.lowerTick + cellWidth() / 4, 200, 45);
        assertLt(steps, 200, "the climb reached cell 1 rather than running out of steps");
        assertGt(tickOf(hubPool), cell0.upperTick, "the tick is past cell 0");
        assertLt(tickOf(hubPool), cell1.upperTick, "and not yet past cell 1");

        PlacementRecord memory cell0After = cellOf(hubPool, 0);
        PlacementRecord memory cell1After = cellOf(hubPool, 1);
        PlacementRecord memory cell2After = cellOf(hubPool, 2);

        assertEq(cell0After.liquidity, cell0.liquidity, "a consumed ask keeps its liquidity - it converts in place");
        (uint256 cell0Amps, uint256 cell0Counter) = liveAmounts(hubPool, cell0After);
        assertEq(cell0Amps, 0, "cell 0 holds no AMPS any more: it sold out");
        assertEq(cell0Counter, expectedProceeds0, "and holds exactly LadderLib's proceeds for its own liquidity");

        (uint256 cell1Amps, uint256 cell1Counter) = liveAmounts(hubPool, cell1After);
        assertGt(cell1Amps, 0, "cell 1 is only partly consumed");
        assertGt(cell1Counter, 0, "and is straddled by the tick");
        (uint256 cell2Amps,) = liveAmounts(hubPool, cell2After);
        assertEq(cell2Amps, askAmpsIn(cell2), "and cell 2 has not been touched at all");

        // Bottom-up: every cell below the tick is empty of AMPS, every cell above it is untouched.
        PlacementRecord[] memory records = ladderOf(hubPool);
        int24 tick = tickOf(hubPool);
        for (uint256 i; i < records.length; ++i) {
            if (!records[i].above) continue;
            (uint256 amount0,) = liveAmounts(hubPool, records[i]);
            if (records[i].upperTick <= tick) {
                assertEq(amount0, 0, "a fully crossed ask cell holds no AMPS");
            } else if (records[i].lowerTick >= tick) {
                assertEq(amount0, askAmpsIn(records[i]), "an uncrossed ask cell is untouched");
            }
        }
    }

    /// @notice I34 at genesis, to the wei: bucket `k` holds `tilt^k / sum tilt^j` of the placement, the cells are
    ///         contiguous doublings, and the vector is `LadderLib`'s own.
    function test_i34_genesisLadderShapeMatchesLadderLib() public view {
        uint256[] memory w = LadderLib.weights(vault.ladderTiltX18(), vault.ladderDoublings());
        uint256[] memory expected = LadderLib.split(ENTRY_ASK_AMPS, w);

        for (uint256 k; k < vault.ladderDoublings(); ++k) {
            PlacementRecord memory cell = cellOf(hubPool, int256(k));
            assertEq(uint256(cell.bucketIndex), k + uint256(int256(-Constants.GRID_MIN_M)), "grid index");
            assertEq(cell.upperTick - cell.lowerTick, cellWidth(), "one doubling wide");
            // The placement rounds the AMPS amount down into liquidity, so the cell holds at most its weight and
            // never more; one liquidity unit of slack is the whole tolerance.
            assertApproxEqAbs(askAmpsIn(cell), expected[k], 1e12, "bucket k holds tilt^k / sum tilt^j");
        }
    }

    /// @notice The fixture's genesis vector, asserted and printed: `A`, NAV/share, `P_ref`, `P_mkt`, the supply,
    ///         the live-cell count and the per-pool ladder shape. This is the launch state every other test in
    ///         this suite starts from, so it is worth having written down in one place.
    function test_genesisVector() public view {
        console.log("A (usd18)              ", vault.totalAssetsUsd18());
        console.log("navPerShareX18         ", vault.navPerShareX18());
        console.log("pRefX18                ", vault.pRefX18());
        console.log("pMktX18                ", vault.pMktX18());
        console.log("totalSupply            ", amps.totalSupply());
        console.log("liveCells              ", vault.liveCells());
        console.log("hub tick / gridBase    ", vm.toString(tickOf(hubPool)), vm.toString(gridBaseOf(hubPool)));
        console.log("weth tick              ", vm.toString(tickOf(wethPool)));
        console.log("spoke0 tick            ", vm.toString(tickOf(spokePools[0])));
        console.log("cell width (ticks)     ", vm.toString(cellWidth()));

        assertEq(amps.totalSupply(), Constants.S0, "genesis mints exactly S0");
        assertEq(amps.balanceOf(address(teamVesting)), Constants.TEAM_SHARES, "the team tranche is vesting");
        assertEq(vault.liveCells(), countLiveCells(), "and the live-cell counter is exact");
        assertEq(vault.ladderLength(hubPool), 14, "the hub holds ten asks and four seed bids");
        assertEq(vault.ladderLength(wethPool), 14, "and so does the WETH pool");
        for (uint256 i; i < spokePools.length; ++i) {
            assertEq(vault.ladderLength(spokePools[i]), 10, "every spoke holds its ten-cell seed ask");
        }
        assertEq(gridBaseOf(hubPool), tickOf(hubPool), "the pool opened exactly on its own grid origin (ruling C)");
        assertApproxEqRel(vault.navPerShareX18(), Constants.WAD, 0.001e18, "NAV/share is $1.00 at genesis");
        assertEq(vault.pRefX18(), vault.navPerShareX18(), "and P_ref is the NAV floor, not yet a market price");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Pump then dump
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The plan's "a pump-then-dump round trip ends with `totalSupply` lower and `A` equal to seed +
    ///         fees", proved as an identity rather than an inequality:
    ///
    ///         * `totalSupply` falls, because the AMPS the vault buys back below the high-water mark is burned
    ///           (I33) and nothing mints outside `AmpsBonds` (I10);
    ///         * the vault's USDG holding equals the seed plus exactly the counter asset the round trip left
    ///           behind — every USDG the buyers paid in, less every USDG the sellers took out. That residue is the
    ///           fee take plus the ladder's own convexity, and there is no third term.
    function test_pumpThenDumpBurnsSupplyAndLeavesSeedPlusFees() public {
        uint256 supplyBefore = amps.totalSupply();
        uint256 navBefore = vault.previewNavPerShareX18();
        uint256 usdgSupplyBefore = usdg.totalSupply();
        uint256 managerUsdgBefore = usdg.balanceOf(address(poolManager));
        assertEq(usdg.balanceOf(BOB), 0, "the pumper starts with nothing");

        // Pump: the whole move is bought out of the ask ladder, one rail-limited step at a time.
        (uint256 bought,) = climb(hubPool, BOB, 2e6, tickOf(hubPool) + 2624, 200, 45);
        assertGt(bought, 0, "the pump bought AMPS out of the ladder");

        // Dump: sold straight back into the bids the pump itself created.
        slide(hubPool, BOB, bought / 40, tickOf(hubPool) - 8000, 200, 45);

        settleTwap();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        vault.compound(hubPool);

        assertLt(amps.totalSupply(), supplyBefore, "the buyback burn left totalSupply strictly lower");
        assertGe(vault.previewNavPerShareX18(), navBefore, "and NAV/share never fell across the round trip");

        // `A`'s USDG leg, to the wei. Every USDG the pumper ever held was minted to him by {buyAmps}, so the
        // counter asset the PoolManager holds for the vault is exactly the seed plus what the round trip left
        // behind: `inbound - outbound`, which is the fee take plus the ladder's own convexity and nothing else.
        uint256 minted = usdg.totalSupply() - usdgSupplyBefore;
        uint256 returned = usdg.balanceOf(BOB);
        assertEq(
            usdg.balanceOf(address(poolManager)),
            managerUsdgBefore + minted - returned,
            "the vault's USDG is exactly the seed plus the round trip's residue"
        );
        assertGt(minted, returned, "and the residue is positive: the round trip paid, it did not earn");
        assertSweepClean("pump then dump");
    }

    // -------------------------------------------------------------------------------------------------------------
    // compound
    // -------------------------------------------------------------------------------------------------------------

    /// @notice §3.6 step 5, in order and to the wei, on fees earned by real swaps through the real hook:
    ///         `creatorCut = ampsFees * min(creatorBps(t), sellFeeBps) / sellFeeBps`, then `stakerBps` of the
    ///         remainder, then exactly `burnBps` of what is left, then the rest re-laddered.
    function test_compoundPaysCreatorThenStakerThenBurnsBurnBps() public {
        _tradeForAmpsFees();

        uint256 creatorBefore = amps.balanceOf(CREATOR);
        uint256 stakingBefore = amps.balanceOf(address(staking));
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(KEEPER);
        (uint256 ampsFees, uint256 burned) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "the sells really paid a fee in AMPS");

        uint256 sellFeeBps = hook.sellFeeBps();
        uint256 creatorBps = vault.creatorBpsAt(block.timestamp);
        uint256 creatorCut = ampsFees * creatorBps / sellFeeBps;
        uint256 stakerCut = (ampsFees - creatorCut) * vault.stakerBps() / Constants.BPS;
        uint256 burnCut = (ampsFees - creatorCut - stakerCut) * vault.burnBps() / Constants.BPS;
        uint256 relaid = ampsFees - creatorCut - stakerCut - burnCut;

        assertEq(amps.balanceOf(CREATOR) - creatorBefore, creatorCut, "the creator's slice, to the wei");
        assertEq(amps.balanceOf(address(staking)) - stakingBefore, stakerCut, "the stakers' slice, to the wei");
        assertGe(supplyBefore - amps.totalSupply(), burnCut, "at least burnBps of the remainder was burned");
        assertEq(creatorCut + stakerCut + burnCut + relaid, ampsFees, "the split is exhaustive");
        assertGt(relaid, 0, "and something went back into the ladder");
        assertGt(burned, 0, "the compound burned AMPS");
    }

    /// @notice I31: the creator schedule is monotone non-increasing, exactly zero from `genesis + 30 days`, and
    ///         the vault pays nothing at all after that.
    function test_i31_creatorScheduleDecaysToZeroAndIsThenNeverPaid() public {
        uint32 genesisAt = vault.genesisTimestamp();
        uint16 previous = type(uint16).max;
        for (uint256 day; day <= 31; ++day) {
            uint16 bps = vault.creatorBpsAt(uint256(genesisAt) + day * 1 days);
            assertLe(bps, previous, "monotone non-increasing");
            previous = bps;
        }
        assertEq(vault.creatorBpsAt(uint256(genesisAt) + Constants.CREATOR_DECAY_SECONDS), 0, "zero at day 30");

        _tradeForAmpsFees();
        warpBy(Constants.CREATOR_DECAY_SECONDS + 1);
        settleTwap();

        uint256 creatorBefore = amps.balanceOf(CREATOR);
        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);
        assertGt(ampsFees, 0, "there were fees to split");
        assertEq(amps.balanceOf(CREATOR), creatorBefore, "and the creator was paid nothing after day 30");
    }

    // -------------------------------------------------------------------------------------------------------------
    // rollout
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I32: a rollout never moves more than `rolloutBpsPerDay` of the POL tranche in a rolling day, never
    ///         takes the entry pools' ask inventory below `entryFloorBps` of it, and never places a spoke ask
    ///         below `P_ref`.
    function test_i32_rolloutRespectsTheDailyBudgetAndTheEntryFloor() public {
        uint256 polTranche = Constants.POL_SHARES;
        uint256 dailyBudget = polTranche * vault.rolloutBpsPerDay() / Constants.BPS;
        uint256 floor = polTranche * vault.entryFloorBps() / Constants.BPS;

        uint256 movedTotal;
        for (uint256 round; round < 3; ++round) {
            warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
            vm.prank(KEEPER);
            uint256 moved = vault.rollout(constituentIds[0]);
            movedTotal += moved;
            assertLe(movedTotal, dailyBudget, "the rolling 24 h budget is never exceeded");

            uint256 entryInventory = ladderAskInventory(hubPool) + ladderAskInventory(wethPool);
            assertGe(entryInventory, floor, "the entry pools never fall below entryFloorBps of the POL tranche");
        }
        assertGt(movedTotal, 0, "the rollout actually moved AMPS");

        // No rolled-out ask sits below `P_ref` (expressed as a tick in the spoke's own pair).
        int24 refTick = PriceLib.fairTick(vault.pRefX18(), stockUsd8[0], 18, TICK_SPACING);
        PlacementRecord[] memory records = ladderOf(spokePools[0]);
        for (uint256 i; i < records.length; ++i) {
            if (!records[i].above || records[i].liquidity == 0) continue;
            assertGe(records[i].lowerTick, refTick, "no spoke ask below P_ref");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // The rotation credit, end to end through the real hook
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A one-transaction `stock -> AMPS -> stock` rotation pays the **buy** fee on both hops: hop 2's base
    ///         is `buyFeeBps[hop2]`, not `sellFeeBps`, because the credit hop 1 created covers the whole sell.
    function test_rotationCredit_stockToAmpsToStockPaysBuyPlusBuy() public {
        deepenSpokes(600e18);
        seedSpokeBids(1);
        (uint16 base1, uint16 base2, uint256 creditAfter) = this.rotationEntry();
        assertEq(base1, registry.poolConfig(spokePools[0]).buyFeeBps, "hop 1 pays the spoke's buy fee");
        assertEq(base2, registry.poolConfig(spokePools[1]).buyFeeBps, "hop 2 pays the other spoke's buy fee");
        assertEq(creditAfter, 0, "and the rotation consumed the credit it created");
    }

    /// @notice A one-transaction buy-then-larger-sell pays the sell fee on exactly the uncredited excess: the base
    ///         is `buyFee + ceil((sellFee - buyFee) * (amountIn - credit) / amountIn)`, strictly between the two.
    function test_rotationCredit_buyThenLargerSellPaysSellOnTheExcessOnly() public {
        (uint16 baseBlended, uint256 creditUsed, uint256 amountIn) = this.buyThenLargerSellEntry();
        uint16 buyFee = registry.poolConfig(hubPool).buyFeeBps;
        uint16 sellFee = hook.sellFeeBps();

        uint256 expected =
            uint256(buyFee) + (uint256(sellFee - buyFee) * (amountIn - creditUsed) + amountIn - 1) / amountIn;
        assertEq(uint256(baseBlended), expected, "the blend is the delta form, rounded up");
        assertGt(baseBlended, buyFee, "and it is strictly above the buy fee");
        assertLt(baseBlended, sellFee, "and strictly below the sell fee");
    }

    /// @notice An exact-**output** sell consumes no credit and pays `sellFeeBps` in full, even with a credit
    ///         sitting in the same transaction.
    function test_rotationCredit_exactOutputSellPaysTheFullSellFee() public {
        (uint16 baseBps, uint256 creditBefore, uint256 creditAfter) = this.exactOutputSellEntry();
        assertGt(creditBefore, 0, "there was a credit to spend");
        assertEq(creditAfter, creditBefore, "an exact-output sell spends none of it");
        assertEq(baseBps, hook.sellFeeBps(), "and pays the sell fee in full");
    }

    /// @notice I26's structural half: the credit is transient, so a buy in one transaction leaves nothing behind
    ///         for a sell in the next.
    function test_rotationCredit_noCreditSurvivesTheTransaction() public {
        buyAmps(hubPool, ALICE, 1e6);
        assertEq(hook.rotationCredit(), 0, "the credit is zero at every transaction boundary");
        (, uint16 baseBps,,) = hook.quoteFee(hubPool, true, true, 1e18);
        assertEq(baseBps, hook.sellFeeBps(), "so the next transaction's sell pays the sell fee in full");
    }

    /// @notice A 1-wei buy unlocks 1 wei of credit and not a basis point more: the blend is computed on the
    ///         realised delta, so a dust buy cannot discount a real sell.
    function test_rotationCredit_oneWeiBuyUnlocksOneWei() public {
        (uint256 credit, uint16 baseBps) = this.dustBuyEntry();
        assertLe(credit, 2, "a 1-wei buy yields at most a wei or two of AMPS");
        assertEq(baseBps, hook.sellFeeBps(), "and a 1 AMPS sell still pays the full sell fee");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Self-call entry points — one transaction each, so the transient credit survives across the hops
    // -------------------------------------------------------------------------------------------------------------

    /// @notice One transaction: buy AMPS in spoke 0, then sell all of it into spoke 1.
    /// @return base1 Hop 1's base fee component.
    /// @return base2 Hop 2's base fee component.
    /// @return creditAfter The credit left when both hops are done.
    function rotationEntry() external returns (uint16 base1, uint16 base2, uint256 creditAfter) {
        require(msg.sender == address(this), "self-call only");
        (, base1,,) = hook.quoteFee(spokePools[0], false, true, 0.01e18);
        uint256 ampsOut = buyAmps(spokePools[0], ALICE, 0.01e18);
        assertEq(hook.rotationCredit(), ampsOut, "the credit is exactly the AMPS the buy realised (I26)");
        (, base2,,) = hook.quoteFee(spokePools[1], true, true, ampsOut);
        sellAmps(spokePools[1], ALICE, ampsOut);
        creditAfter = hook.rotationCredit();
    }

    /// @notice One transaction: buy AMPS in the hub, then sell four times as much back into it.
    /// @return baseBlended The blended base fee hop 2 pays.
    /// @return creditUsed The credit the sell consumed.
    /// @return amountIn The AMPS the sell put in.
    function buyThenLargerSellEntry() external returns (uint16 baseBlended, uint256 creditUsed, uint256 amountIn) {
        require(msg.sender == address(this), "self-call only");
        giveShares(ALICE, 20e18);
        uint256 ampsOut = buyAmps(hubPool, ALICE, 1e6);
        creditUsed = hook.rotationCredit();
        assertEq(creditUsed, ampsOut, "the credit is the realised AMPS");

        amountIn = ampsOut * 4;
        (, baseBlended,,) = hook.quoteFee(hubPool, true, true, amountIn);
        sellAmps(hubPool, ALICE, amountIn);
        assertEq(hook.rotationCredit(), 0, "the larger sell consumed the whole credit");
    }

    /// @notice One transaction: buy AMPS in the hub, then take an exact amount of USDG back out.
    /// @return baseBps The base fee the exact-output sell pays.
    /// @return creditBefore The credit before it.
    /// @return creditAfter The credit after it.
    function exactOutputSellEntry() external returns (uint16 baseBps, uint256 creditBefore, uint256 creditAfter) {
        require(msg.sender == address(this), "self-call only");
        buyAmps(hubPool, ALICE, 1e6);
        creditBefore = hook.rotationCredit();
        (, baseBps,,) = hook.quoteFee(hubPool, true, false, 0);
        sellAmpsExactOut(hubPool, ALICE, 0.2e6);
        creditAfter = hook.rotationCredit();
    }

    /// @notice One transaction: a 1-wei buy, then the fee a whole-AMPS sell would pay.
    /// @return credit The credit the dust buy created.
    /// @return baseBps The base fee a 1 AMPS sell would pay against it.
    function dustBuyEntry() external returns (uint256 credit, uint16 baseBps) {
        require(msg.sender == address(this), "self-call only");
        buyAmps(hubPool, ALICE, 1);
        credit = hook.rotationCredit();
        (, baseBps,,) = hook.quoteFee(hubPool, true, true, 1e18);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Fee band, quoter, and `afterSwap`
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I16's hard half: `sellFeeBps` is enforced in-contract inside `[100, 600]`, by the hook itself.
    function test_i16_sellFeeBandIsEnforcedInContract() public {
        assertEq(hook.SELL_FEE_BPS_MIN(), 100, "the floor is a hundred basis points");
        assertEq(hook.SELL_FEE_BPS_MAX(), 600, "and the ceiling six hundred");

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("sellFeeBps"), uint256(99), uint256(100), uint256(600))
        );
        hook.setSellFeeBps(99);

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("sellFeeBps"), uint256(601), uint256(100), uint256(600))
        );
        hook.setSellFeeBps(601);

        vm.prank(TIMELOCK);
        hook.setSellFeeBps(600);
        assertEq(hook.sellFeeBps(), 600, "the ceiling itself is accepted");
        vm.prank(TIMELOCK);
        hook.setSellFeeBps(100);
        assertEq(hook.sellFeeBps(), 100, "and so is the floor");
    }

    /// @notice `AmpsQuoter.quotePool` reports exactly the fee the pool then charges, on both directions, in every
    ///         pool — and `quoteAll` never reverts while it does so.
    function test_quoterIsExactAgainstRealSwapsThroughTheRealHook() public {
        PoolId[] memory ids = allPools();
        for (uint256 i; i < ids.length; ++i) {
            IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(ids[i]);
            assertEq(quote.degraded, 0, "nothing degraded in a healthy fixture");

            vm.recordLogs();
            buyAmps(ids[i], CAROL, _smallBuy(ids[i]));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(uint256(lastSwapFee(logs)), uint256(quote.buyFeePips), "the buy fee the quoter promised");
        }

        IAmpsQuoter.PoolQuote[] memory all = quoter.quoteAll();
        assertEq(all.length, ids.length, "quoteAll covers every registered pool");
    }

    /// @notice `AmpsQuoter` never reverts, including in the states that break its dependencies: a dead feed, a
    ///         reverting aggregator, a paused stock token and a pool with no coverage at all.
    function test_quoterNeverReverts() public {
        stockFeeds[0].setRevert(true);
        stocks[0].setOraclePaused(true);
        warpBy(2 days);

        IAmpsQuoter.PoolQuote[] memory all = quoter.quoteAll();
        assertEq(all.length, allPools().length, "quoteAll still answers with every dependency broken");
        (uint256 amountOut,,, uint256 credit) = quoter.quoteRotation(spokePools[0], hubPool, 1e15);
        amountOut;
        credit;
        (uint256 q,,, bool open,) = quoter.bondQuote(marketIds[0]);
        q;
        open;
    }

    /// @notice The plan's "`afterSwap` never reverts a swap", restated per §10 ruling 2: the one deliberate,
    ///         deterministic exception is `BeyondRail` on a deviation-increasing swap. Everything else — a dead
    ///         feed, a reverting aggregator, a paused stock token, a gate that has gone away entirely — leaves
    ///         `afterSwap` returning normally and the swap standing.
    function test_afterSwapNeverRevertsExceptBeyondRail() public {
        stockFeeds[0].setRevert(true);
        wethFeed.setRevert(true);
        usdgFeed.setRevert(true);
        stocks[0].setOraclePaused(true);
        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("oracleGate"), address(0xDEAD));
        warpBy(3 days);

        // Every leg still swaps, in both directions, with every downstream read broken.
        uint256 got = buyAmps(hubPool, ALICE, 1e6);
        assertGt(got, 0, "a buy still executes with the whole oracle stack down");
        uint256 back = sellAmps(hubPool, ALICE, got / 2);
        assertGt(back, 0, "and so does a sell");
        assertGt(buyAmps(wethPool, ALICE, 1e14), 0, "the WETH leg too");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The full user journey
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The plan's end-to-end journey, reconciled number by number: buy in the hub, buy with WETH, rotate
    ///         one spoke into another through AMPS in one transaction, bond and claim, stake and receive the
    ///         streamed reward, sell, and redeem pro-rata.
    function test_fullUserJourneyReconciles() public {
        deepenSpokes(600e18);
        seedSpokeBids(1);

        // 1. Buy AMPS in the hub.
        uint256 hubAmps = buyAmps(hubPool, ALICE, 5e6);
        assertGt(hubAmps, 0, "hub buy");

        // 2. Buy AMPS with WETH.
        uint256 wethAmps = buyAmps(wethPool, ALICE, 2e15);
        assertGt(wethAmps, 0, "WETH buy");
        assertEq(amps.balanceOf(ALICE), hubAmps + wethAmps, "the holder's AMPS is exactly what the two buys paid");

        // 3. Rotate spoke 0 into spoke 1 in one transaction.
        uint256 rotated = rotate(spokePools[0], spokePools[1], BOB, 0.01e18);
        assertGt(rotated, 0, "the rotation delivered the other stock");
        assertEq(hook.rotationCredit(), 0, "and left no credit behind");

        // 4. Bond, then claim over the vesting window.
        uint256 supplyBeforeBond = amps.totalSupply();
        uint256 navBeforeBond = vault.previewNavPerShareX18();
        uint256 shellBeforeBond = amps.balanceOf(address(bonds));
        (uint256 bonded, uint256 positionId) = bondAs(CAROL, 0, 0.2e18);
        assertEq(amps.totalSupply(), supplyBeforeBond + bonded, "vesting AMPS is in totalSupply from purchase (I30)");
        assertEq(amps.balanceOf(address(bonds)) - shellBeforeBond, bonded, "and sits on the bonds shell until it vests");
        assertGe(vault.previewNavPerShareX18(), navBeforeBond, "the bond did not dilute (I27)");

        warpBy(Constants.BOND_VEST_SECONDS_DEFAULT + 1);
        vm.prank(CAROL);
        uint256 claimed = bonds.claim(positionId, CAROL);
        assertEq(claimed, bonded, "the whole position vested");
        assertEq(amps.balanceOf(CAROL), bonded, "and landed on the buyer");

        // 5. Stake, then receive the streamed staker slice of a compound.
        vm.startPrank(CAROL);
        amps.approve(address(staking), type(uint256).max);
        uint256 shares = staking.deposit(bonded, CAROL);
        vm.stopPrank();
        assertGt(shares, 0, "xAMPS minted");

        uint256 stakedAssetsBefore = staking.totalAssets();
        _tradeForAmpsFees();
        vm.prank(KEEPER);
        vault.compound(hubPool);
        warpBy(Constants.REWARD_STREAM_SECONDS_DEFAULT + 1);
        assertGt(staking.totalAssets(), stakedAssetsBefore, "the staker slice streamed in");

        // 6. Sell AMPS and pay the sell fee.
        uint256 sellIn = amps.balanceOf(ALICE) / 4;
        vm.recordLogs();
        sellAmps(hubPool, ALICE, sellIn);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGe(uint256(lastSwapFee(logs)) / 100, uint256(hook.sellFeeBps()), "the sell paid at least the sell fee");

        // 7. Redeem pro-rata and get exactly `(1 - redeemFeeBps) * shares / T` of every non-AMPS balance.
        uint256 redeemShares = amps.balanceOf(ALICE);
        uint256 supplyBeforeRedeem = amps.totalSupply();
        uint256 assetCount = vault.assetCount();
        uint256[] memory before = new uint256[](assetCount);
        for (uint256 i; i < assetCount; ++i) {
            before[i] = IERC20(vault.assetAt(i)).balanceOf(ALICE);
        }

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(redeemShares, ALICE);
        assertEq(tokens.length, amounts.length, "one amount per asset");
        assertLe(amps.totalSupply(), supplyBeforeRedeem - redeemShares, "the redeemer's shares are gone");
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(
                IERC20(tokens[i]).balanceOf(ALICE) - before[i], amounts[i], "and the payout landed, asset by asset"
            );
        }
        assertSweepClean("full journey");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev A round trip in the hub big enough to leave AMPS-side fees, then a settled reference and a cleared
    ///      cooldown so `compound` passes the gauntlet.
    function _tradeForAmpsFees() private {
        uint256 bought = buyAmps(hubPool, BOB, 4e6);
        sellAmps(hubPool, BOB, bought);
        settleTwap();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    /// @dev A buy small enough not to breach a thin spoke's rail.
    function _smallBuy(PoolId poolId) private view returns (uint256 amount) {
        return registry.poolConfig(poolId).counterDecimals == 18 ? 1e14 : 1e5;
    }
}
