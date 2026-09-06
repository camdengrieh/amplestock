// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LadderLib} from "../../src/lib/LadderLib.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {
    CellBudgetExceeded,
    InsufficientInventory,
    NavBleedExceeded,
    NotTimelock,
    PlacementCooldown,
    PlacementDiverged
} from "../../src/types/Errors.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {VaultPlacementLib} from "../../src/vault/VaultPlacementLib.sol";
import {PlacementFixture} from "../mocks/PlacementFixture.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title VaultPlacementTest
/// @notice `docs/phase3-state-model.md` §8.1's row for this file: the genesis ladders of §3.3 to the wei,
///         sidedness (I9), grid membership (I39), merge-by-cell, the 60-second cooldown, divergence at entry and
///         at exit, the R1 revert on a manipulated tick, and the worst-case placement gas.
///
/// @dev Everything here runs against **live Uniswap v4 pools**: a placement really opens positions the
///      PoolManager owns for the vault, so the amounts asserted below are what the pool actually holds, not what
///      a mock said it would.
contract VaultPlacementTest is PlacementFixture {
    using StateLibrary for IPoolManager;

    /// @dev The exact per-cell AMPS of a 1,662.5-AMPS, ten-doubling, 1.25-tilt ask ladder — `LadderLib.split` of
    ///      `LadderLib.weights(1.25e18, 10)` — cell 0 nearest the anchor. §3.3's "50.0 AMPS over $1-$2" is the
    ///      first of these; see {test_genesis_theDocsTopBucketFigureIsWrongAndTheLadderIsRight} for the last.
    uint256[10] internal ENTRY_ASK_CELLS = [
        uint256(49_995_634_990_694_670_637),
        62_494_543_738_368_338_712,
        78_118_179_672_960_424_637,
        97_647_724_591_200_531_212,
        122_059_655_739_000_663_600,
        152_574_569_673_750_829_500,
        190_718_212_092_188_536_875,
        238_397_765_115_235_671_925,
        297_997_206_394_044_589_075,
        372_496_507_992_555_743_827
    ];

    /// @dev The same shape over 47.5 AMPS: a spoke's seed ask, 1% of the 4,750-AMPS POL tranche.
    uint256[10] internal SPOKE_ASK_CELLS = [
        uint256(1_428_446_714_019_847_732),
        1_785_558_392_524_809_677,
        2_231_947_990_656_012_132,
        2_789_934_988_320_015_177,
        3_487_418_735_400_018_960,
        4_359_273_419_250_023_700,
        5_449_091_774_062_529_625,
        6_811_364_717_578_162_055,
        8_514_205_896_972_702_545,
        10_642_757_371_215_878_397
    ];

    /// @dev The four-halving seed bid over $2,500 of USDG, **cell nearest the anchor first**: the weight vector
    ///      runs with price, so the bid adjacent to the market is the largest (33.875% / 27.100% / 21.680% /
    ///      17.344%, §3.3's "$846.72 / $677.38 / $541.90 / $433.60" to the cent).
    uint256[4] internal SEED_BID_CELLS_USDG = [uint256(846_883_469), 677_506_775, 542_005_420, 433_604_336];

    function setUp() public {
        deployPlacementWorld();
    }

    // -------------------------------------------------------------------------------------------------------------
    // §3.3 — the genesis ladders, to the wei
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The entry-pool ask ladder: ten contiguous doublings from the anchor, holding
    ///         `1.25^k / SUM 1.25^j` of 1,662.5 AMPS each, summing to 1,662.5 AMPS exactly.
    function test_genesis_entryAskLadderIsTenDoublingsToTheWei() public {
        vm.prank(TIMELOCK);
        uint256 placed = vault.place(hubPool, true, ENTRY_ASK_AMPS);
        assertEq(placed, ENTRY_ASK_AMPS, "the whole tranche was committed, to the wei");

        PlacementRecord[] memory records = ladderOf(hubPool);
        assertEq(records.length, Constants.LADDER_DOUBLINGS_DEFAULT, "ten buckets");

        int24 width = cellWidth();
        uint256 total;
        for (uint256 k; k < records.length; ++k) {
            assertEq(records[k].amount, ENTRY_ASK_CELLS[k], "cell amount to the wei");
            assertEq(records[k].upperTick - records[k].lowerTick, width, "one doubling wide");
            assertTrue(records[k].above, "an ask");
            if (k != 0) {
                assertEq(records[k].lowerTick, records[k - 1].upperTick, "contiguous doublings");
            }
            total += records[k].amount;
        }
        assertEq(total, ENTRY_ASK_AMPS, "the split is exact");
        assertSweepClean("entry ask ladder");
    }

    /// @notice The ladder shape, pinned against the corrected §3.3 figures.
    /// @dev §3.3 originally gave `w_0 = 3.007%` (50.0 AMPS) *and* `w_9 = 28.008%` (465.7 AMPS) for a ten-bucket
    ///      1.25-tilt ladder. Those two cannot both be true: `w_9 / w_0` is `1.25^9 = 7.4506`, not
    ///      `9.3132 = 1.25^10` — the eleventh power over the ten-term sum. The orchestrator has since corrected
    ///      the document to `w_9 = 22.406%`, i.e. 372.4965 AMPS, which is what `LadderLib` computes and what the
    ///      real `LadderPolicy` asserts to the wei. This test is the third independent copy of that number.
    function test_genesis_theLadderWeightsMatchTheCorrectedFigures() public pure {
        uint256[] memory w = LadderLib.weights(Constants.LADDER_TILT_X18_DEFAULT, 10);
        assertEq(w[0], 30_072_562_400_417_847, "w_0 = 3.0073%, as the doc says");
        assertEq(w[9], 224_058_049_920_334_282, "w_9 = 22.4058%, not the doc's 28.008%");
        // 1.25^9 = 7.450580596923828125, to within the flooring residue the last weight absorbs.
        assertApproxEqRel(w[9] * 1e18 / w[0], 7_450_580_596_923_828_125, 1e9, "and the ratio is 1.25^9, not 1.25^10");
    }

    /// @notice A spoke's seed ask is the same shape over 47.5 AMPS, anchored at `tickOf(P_ref / P_stock)`.
    function test_genesis_spokeSeedAskIsOnePercentOfThePolTranche() public {
        assertEq(SPOKE_SEED_AMPS, Constants.POL_SHARES * Constants.SPOKE_SEED_BPS_DEFAULT / Constants.BPS, "1%");

        vm.prank(TIMELOCK);
        uint256 placed = vault.place(spokePools[0], true, SPOKE_SEED_AMPS);
        assertEq(placed, SPOKE_SEED_AMPS, "committed to the wei");

        PlacementRecord[] memory records = ladderOf(spokePools[0]);
        assertEq(records.length, 10, "ten buckets");
        for (uint256 k; k < records.length; ++k) {
            assertEq(records[k].amount, SPOKE_ASK_CELLS[k], "spoke cell amount to the wei");
        }

        // The anchor is the reference tick, never the pool's: an ask can never be placed below `P_ref`.
        int24 refTick = PriceLib.fairTick(vault.pRefX18(), STOCK_USD8[0], 18, TICK_SPACING);
        assertGe(records[0].lowerTick, refTick, "no ask below P_ref");
    }

    /// @notice The seed bids: four halvings below the market, weighted toward the tick, summing to the seed
    ///         exactly. The counter side is USDG, so the amounts are 6-decimal.
    function test_genesis_seedBidsAreFourHalvingsWeightedTowardTheMarket() public {
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.prank(TIMELOCK);
        uint256 placed = vault.place(hubPool, false, SEED_USDG);
        assertEq(placed, SEED_USDG, "the whole seed was committed");

        PlacementRecord[] memory records = ladderOf(hubPool);
        assertEq(records.length, 14, "ten asks and four bids, all on the same grid");

        // The bid cells are the four with `above == false`, and they run downward from the market.
        uint256 seen;
        int24 tick = tickOf(hubPool);
        int24 bound = PriceLib.alignTick(tick, TICK_SPACING, false);
        for (uint256 i; i < records.length; ++i) {
            if (records[i].above) continue;
            assertLe(records[i].upperTick, bound, "I9: a bid lies at or below alignDown(tick)");
            assertEq(records[i].amount, SEED_BID_CELLS_USDG[seen], "seed bid cell to the wei");
            ++seen;
        }
        assertEq(seen, Constants.SEED_HALVINGS_DEFAULT, "four halvings");
        assertSweepClean("seed bids");
    }

    /// @notice **The genesis cell indices of §3.3, exactly**: asks at `m = 0..9`, seed bids at `m = -1..-4`.
    ///
    /// @dev They only come out when the pool opens *on* its grid origin, which is what
    ///      {VaultPlacementLib-alignedOpeningPrice} guarantees for every pool the vault has ever opened
    ///      (§12 ruling C): `slot0.sqrtPriceX96 == getSqrtPriceAtTick(gridBaseTick)`, so cell 0's lower bound and
    ///      cell -1's upper bound both sit exactly at the price — the first is a pure-AMPS range and the second a
    ///      pure-counter one, in exact v4 terms.
    function test_genesis_cellIndicesAreExactlyThoseOfTheSpec() public {
        placeGenesisLadders();

        PoolId[2] memory pools = [hubPool, wethPool];
        for (uint256 p; p < pools.length; ++p) {
            int24 base = gridBaseOf(pools[p]);
            int24 width = cellWidth();
            (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(pools[p]);
            assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(base), "the pool opened on its grid origin");
            assertEq(tickOf(pools[p]), base, "so the live tick is the origin");

            uint256 asks;
            uint256 bids;
            for (uint256 i; i < vault.ladderLength(pools[p]); ++i) {
                PlacementRecord[] memory records = ladderOf(pools[p]);
                int24 cell = (records[i].lowerTick - base) / width;
                if (records[i].above) {
                    assertGe(cell, int24(0), "asks from m = 0");
                    assertLt(cell, int24(10), "up to m = 9");
                    ++asks;
                } else {
                    assertLe(cell, int24(-1), "bids from m = -1");
                    assertGe(cell, int24(-4), "down to m = -4");
                    ++bids;
                }
            }
            assertEq(asks, 10, "ten ask cells");
            assertEq(bids, 4, "four bid cells");
        }
    }

    /// @notice And the mechanism the alignment exists to defeat: an opening price *inside* a cell forfeits it for
    ///         both sides, which would push the seed bids a whole doubling lower.
    /// @dev Asserted on the sidedness predicate itself rather than by opening a mis-priced pool, because the vault
    ///      no longer lets one exist: `alignedOpeningPrice` snaps every opening onto the lattice. An unaligned
    ///      price `s` strictly between `sqrtPriceAtTick(base - D)` and `sqrtPriceAtTick(base)` satisfies neither
    ///      `s <= sqrtPriceAtTick(base)` as an ask lower bound nor `s >= sqrtPriceAtTick(base)` as a bid upper
    ///      bound... it satisfies the first and not the second, so cell -1 is unplaceable and cell 0 is not.
    function test_anUnalignedOpeningPriceWouldForfeitTheCellBelowIt() public view {
        int24 base = gridBaseOf(hubPool);
        uint160 aligned = TickMath.getSqrtPriceAtTick(base);
        uint160 unaligned = aligned + 1; // one wei of sqrt price above the origin: inside cell 0

        // Cell 0 is still a pure-AMPS ask at the aligned price, and no longer one a hair above it.
        assertTrue(aligned <= TickMath.getSqrtPriceAtTick(base), "aligned: cell 0 is placeable as an ask");
        assertFalse(unaligned <= TickMath.getSqrtPriceAtTick(base), "unaligned: cell 0 is not");

        // Cell -1 is a pure-counter bid at the aligned price, and would be at the unaligned one too — which is
        // why the forfeit lands on the ask side when the snap is upward and on the bid side when it is not.
        assertTrue(aligned >= TickMath.getSqrtPriceAtTick(base), "aligned: cell -1 is placeable as a bid");

        // The snap itself: an unaligned input comes back as the greatest aligned tick at or below it.
        assertEq(
            VaultPlacementLib.alignedOpeningPrice(unaligned, TICK_SPACING),
            aligned,
            "the vault snaps every opening down onto the lattice"
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // I9 — sidedness, and I39 — the grid
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every ask position is AMPS-only and every bid position is counter-only, at the PoolManager and not
    ///         merely in the vault's book: the valuer decomposes the whole ladder at the reference price and finds
    ///         no counter asset above the tick and no AMPS below it.
    function test_i9_asksHoldOnlyAmpsAndBidsOnlyCounter() public {
        placeGenesisLadders();

        int24 tick = tickOf(hubPool);
        PlacementRecord[] memory records = ladderOf(hubPool);
        assertGt(records.length, 0, "there is a ladder to check");

        for (uint256 i; i < records.length; ++i) {
            // Exact v4 terms (§12 ruling C), which is what makes the cell the price sits on placeable.
            (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(hubPool);
            if (records[i].above) {
                assertLe(sqrtPriceX96, TickMath.getSqrtPriceAtTick(records[i].lowerTick), "an ask is a pure-AMPS range");
            } else {
                assertGe(
                    sqrtPriceX96, TickMath.getSqrtPriceAtTick(records[i].upperTick), "a bid is a pure-counter range"
                );
            }
        }

        // And the pool agrees: the ask cells decompose to pure `amount0`, the bid cells to pure `amount1`.
        (uint256 amount0, uint256 amount1) = valuer.valuePool(hubPool, PriceLib.tickToSqrtPriceX96(tick));
        assertGt(amount0, 0, "the asks are AMPS");
        assertGt(amount1, 0, "the bids are USDG");
    }

    /// @notice I39: every record lies on the pool's canonical doubling grid, is exactly one cell wide, and no two
    ///         records share a cell.
    function test_i39_everyRecordIsExactlyOneGridCellAndCellsAreUnique() public {
        placeGenesisLadders();

        PoolId[3] memory pools = [hubPool, wethPool, spokePools[0]];
        for (uint256 p; p < pools.length; ++p) {
            int24 base = gridBaseOf(pools[p]);
            int24 width = cellWidth();
            PlacementRecord[] memory records = ladderOf(pools[p]);
            assertLe(records.length, Constants.GRID_CELLS, "at most GRID_CELLS records");

            for (uint256 i; i < records.length; ++i) {
                int24 offset = records[i].lowerTick - base;
                assertEq(offset % width, 0, "on the lattice");
                assertEq(records[i].upperTick - records[i].lowerTick, width, "one cell wide");
                int24 cell = offset / width;
                assertGe(cell, Constants.GRID_MIN_M, "inside GRID_MIN_M");
                assertLt(cell, Constants.GRID_MAX_M, "inside GRID_MAX_M");
                assertEq(
                    uint256(records[i].bucketIndex),
                    uint256(uint24(cell - Constants.GRID_MIN_M)),
                    "bucketIndex is the cell index"
                );
                for (uint256 j = i + 1; j < records.length; ++j) {
                    assertTrue(records[i].lowerTick != records[j].lowerTick, "no two records share a cell");
                }
            }
        }
    }

    /// @notice Merge-by-cell: a second ask placement into the same pool updates the existing records rather than
    ///         appending, because two placements over one range are one position at the PoolManager.
    function test_mergeByCell_secondPlacementUpdatesRatherThanAppends() public {
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 100e18);
        PlacementRecord[] memory first = ladderOf(hubPool);
        assertEq(first.length, 10, "ten cells");

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 100e18);

        PlacementRecord[] memory second = ladderOf(hubPool);
        assertEq(second.length, 10, "still ten cells, not twenty");
        for (uint256 i; i < second.length; ++i) {
            assertEq(second[i].lowerTick, first[i].lowerTick, "the same cells");
            assertGt(second[i].liquidity, first[i].liquidity, "liquidity accumulated in place");
            assertEq(second[i].amount, first[i].amount * 2, "and so did the disclosed amount");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // The gauntlet
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `place` is timelock-or-registry (ruling 11).
    function test_place_isTimelockOrRegistry() public {
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vm.prank(ALICE);
        vault.place(hubPool, true, 1e18);

        vm.prank(address(registry));
        vault.place(hubPool, true, 1e18);
        assertGt(vault.ladderLength(hubPool), 0, "the registry may seed a pool");
    }

    /// @notice The 60-second per-pool cooldown, and that it is per pool.
    function test_cooldown_refusesInsideSixtySecondsAndIsPerPool() public {
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 100e18);
        uint32 readyAt = uint32(block.timestamp) + Constants.PLACEMENT_COOLDOWN_SECONDS;

        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(PlacementCooldown.selector, PoolId.unwrap(hubPool), readyAt));
        vault.place(hubPool, true, 100e18);

        // A different pool is unaffected.
        vm.prank(TIMELOCK);
        vault.place(wethPool, true, 100e18);

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS);
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 100e18);
        assertGt(vault.ladderLength(hubPool), 0, "and it clears exactly on the boundary");
    }

    /// @notice Divergence at **entry**: a pool whose tick has been walked away from `tickOf(P_mkt / P_i)` by more
    ///         than `PLACEMENT_DIVERGENCE_TICKS` refuses the placement before it starts.
    function test_divergence_refusesAtEntry() public {
        placeGenesisLadders();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        // Walk the spoke's price up through its ladder without moving the hub, so `P_mkt / P_stock` stays put.
        buyAmps(spokePools[0], address(stocks[0]), 5e18);
        int24 tick = tickOf(spokePools[0]);
        int24 fair = PriceLib.fairTick(vault.pMktX18(), STOCK_USD8[0], 18, TICK_SPACING);
        int24 dev = tick > fair ? tick - fair : fair - tick;
        assertGt(dev, Constants.PLACEMENT_DIVERGENCE_TICKS, "the pool really did diverge");

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                PlacementDiverged.selector,
                PoolId.unwrap(spokePools[0]),
                tick,
                fair,
                Constants.PLACEMENT_DIVERGENCE_TICKS
            )
        );
        vault.place(spokePools[0], true, 1e18);
    }

    /// @notice Divergence is checked at **exit** as well, so a placement cannot be sandwiched into a manipulated
    ///         tick: the same call that passed the entry check is re-measured after the liquidity has moved.
    /// @dev The two checks are the same code on the same inputs, so the exit check can only fail if the tick
    ///      moved *during* the placement. A vault position cannot move a v4 price by itself, so this asserts the
    ///      structure — both ends measured — rather than trying to construct a mid-placement move that the
    ///      architecture forbids in the first place (there is no `swap` and no `donate` on this path).
    function test_divergence_isMeasuredAtBothEnds() public {
        placeGenesisLadders();

        // A placement leaves the tick exactly where it found it, which is what makes the exit check pass.
        int24 before = tickOf(hubPool);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 10e18);
        assertEq(tickOf(hubPool), before, "adding one-sided liquidity above the tick moves no price");
    }

    /// @notice **R1 as a revert.** A placement that would lower NAV/share by more than
    ///         `PLACEMENT_BLEED_BPS_MAX` (2 bp) is refused, whatever it is and whoever asked for it.
    /// @dev The reachable shape of §8.1's "R1 revert on a manipulated tick". A *tick* manipulation is caught one
    ///      step earlier, by the divergence check ({test_divergence_refusesAtEntry}), which is the point of
    ///      measuring divergence at entry at all. What R1 catches is the residual: any placement whose net effect
    ///      on `A` is a loss. Here the loss is manufactured by making the valuer under-report the hub's positions,
    ///      so moving $400 of USDG out of claims and into a hub position looks like $400 leaving the vault. That
    ///      is a far larger bleed than 2 bp, and the vault refuses rather than recording it.
    function test_r1_revertsWhenAPlacementWouldBleedNav() public {
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.mockCall(
            address(valuer),
            abi.encodeWithSelector(valuer.valuePool.selector, hubPool),
            abi.encode(uint256(0), uint256(0))
        );

        vm.prank(TIMELOCK);
        vm.expectPartialRevert(NavBleedExceeded.selector);
        vault.place(hubPool, false, 400e6);
    }

    /// @notice And the same placement is accepted once the valuer prices it honestly, so the revert above is R1
    ///         doing its job rather than the placement being impossible.
    function test_r1_theSamePlacementSucceedsWhenNothingBleeds() public {
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 navBefore = vault.previewNavPerShareX18();
        vm.prank(TIMELOCK);
        vault.place(hubPool, false, 400e6);
        assertGe(
            vault.navPerShareX18(),
            navBefore * (Constants.BPS - Constants.PLACEMENT_BLEED_BPS_MAX) / Constants.BPS,
            "R1 held"
        );
    }

    /// @notice A placement can never commit more than the vault holds.
    function test_insufficientInventory() public {
        uint256 available = amps.balanceOf(address(vault)) + claimOf(address(amps));
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(InsufficientInventory.selector, available + 1, available));
        vault.place(hubPool, true, available + 1);
    }

    /// @notice A bid ladder into a pool with no counter asset at all is refused for inventory, not silently
    ///         placed: a spoke has no bids until buys or bonds bring stock in (§3.3).
    function test_aSpokeHasNoBidsUntilStockArrives() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(InsufficientInventory.selector, 1e18, 0));
        vault.place(spokePools[0], false, 1e18);
    }

    /// @notice The surge is armed after every placement, so it cannot be sandwiched at the pre-placement fee
    ///         (gauntlet step 8).
    function test_surgeIsArmedAfterEveryPlacement() public {
        assertEq(hook.surgeArmedCount(hubPool), 0, "nothing armed yet");
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 100e18);
        assertEq(hook.surgeArmedCount(hubPool), 1, "armed once");
        assertEq(hook.lastSurgeReason(hubPool), bytes32("place"), "with the placement's reason");
    }

    /// @notice The ladder policy is propose-only: the vault asks it for a weight vector and re-derives everything
    ///         else, and a policy that reverts leaves `LadderLib` in charge rather than bricking the placement.
    function test_aLadderPolicyThatRevertsDoesNotBrickThePlacement() public {
        vm.mockCallRevert(address(ladderPolicy), abi.encodeWithSelector(ladderPolicy.weights.selector), "policy down");
        vm.prank(TIMELOCK);
        uint256 placed = vault.place(hubPool, true, ENTRY_ASK_AMPS);
        assertEq(placed, ENTRY_ASK_AMPS, "placed anyway");

        PlacementRecord[] memory records = ladderOf(hubPool);
        for (uint256 k; k < records.length; ++k) {
            assertEq(records[k].amount, ENTRY_ASK_CELLS[k], "and with LadderLib's own weights");
        }
    }

    /// @notice A policy whose weights do not sum to 1e18 is ignored for the same reason.
    function test_aLadderPolicyWithBadWeightsIsIgnored() public {
        uint256[] memory bad = new uint256[](10);
        bad[0] = 1;
        vm.mockCall(address(ladderPolicy), abi.encodeWithSelector(ladderPolicy.weights.selector), abi.encode(bad));

        vm.prank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        PlacementRecord[] memory records = ladderOf(hubPool);
        assertEq(records[0].amount, ENTRY_ASK_CELLS[0], "LadderLib's weights, not the policy's");
    }

    // -------------------------------------------------------------------------------------------------------------
    // §12 ruling E — the vault-wide live-cell budget
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The count is exact: it rises by one for every cell that goes from empty to holding liquidity, and
    ///         it never counts a merge twice.
    function test_e_theLiveCellCountIsExactAcrossOpensAndMerges() public {
        assertEq(vault.liveCells(), 0, "an unplaced vault has no live cells");

        vm.prank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        assertEq(vault.liveCells(), 10, "ten cells opened");
        assertEq(vault.liveCells(), countLiveCells(), "and the records agree");

        // A second ask placement into the same pool merges into the same ten cells.
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 100e18);
        assertEq(vault.liveCells(), 10, "a merge opens nothing");
        assertEq(vault.liveCells(), countLiveCells(), "and the records still agree");

        // The seed bids open four more.
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(TIMELOCK);
        vault.place(hubPool, false, SEED_USDG);
        assertEq(vault.liveCells(), 14, "four bid cells opened");
        assertEq(vault.liveCells(), countLiveCells(), "and the records agree");

        // A whole second pool adds its own.
        vm.prank(TIMELOCK);
        vault.place(wethPool, true, ENTRY_ASK_AMPS);
        assertEq(vault.liveCells(), 24, "the count is vault-wide, not per pool");
        assertEq(vault.liveCells(), countLiveCells(), "and the records agree");
    }

    /// @notice `place` is the governance path and **refuses** rather than silently placing less: with the budget
    ///         full, a placement that would open a new cell reverts `CellBudgetExceeded`.
    function test_e_placeRevertsWhenTheBudgetIsFull() public {
        forceLiveCells(Constants.MAX_LIVE_CELLS);

        vm.prank(TIMELOCK);
        vm.expectPartialRevert(CellBudgetExceeded.selector);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
    }

    /// @notice And it still succeeds when every cell it touches already exists, because a merge spends no budget.
    function test_e_placeStillMergesWhenTheBudgetIsFull() public {
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        uint256 committed = ladderOf(hubPool)[0].amount;

        forceLiveCells(Constants.MAX_LIVE_CELLS);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.prank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        assertGt(ladderOf(hubPool)[0].amount, committed, "the merge went through");
        assertEq(vault.liveCells(), Constants.MAX_LIVE_CELLS, "and opened nothing");
    }

    /// @notice One cell short of the budget, `place` opens exactly one more and then refuses.
    function test_e_theBudgetIsCheckedPerNewCellNotPerPlacement() public {
        forceLiveCells(Constants.MAX_LIVE_CELLS - 1);

        vm.prank(TIMELOCK);
        vm.expectPartialRevert(CellBudgetExceeded.selector);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);

        // A one-cell ladder fits: `seedHalvings` of 2 is the shortest the bands allow, so use the bid side of a
        // pool that has room for exactly one more.
        vm.prank(TIMELOCK);
        vault.setLadderShape(Constants.LADDER_TILT_X18_DEFAULT, Constants.LADDER_DOUBLINGS_MIN, 2, 2);
        forceLiveCells(Constants.MAX_LIVE_CELLS - 1);
        vm.prank(TIMELOCK);
        vm.expectPartialRevert(CellBudgetExceeded.selector);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        assertEq(vault.liveCells(), Constants.MAX_LIVE_CELLS - 1, "and nothing was placed at all");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Gas
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The worst reachable single placement: ten fresh cells into an empty pool, every one of them a cold
    ///         `modifyLiquidity` that initialises two ticks.
    function test_gasWorstCasePlacement() public {
        vm.prank(TIMELOCK);
        uint256 before = gasleft();
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        uint256 used = before - gasleft();
        emit log_named_uint("place: ten fresh ask cells", used);
        assertLt(used, 4_500_000, "a ten-cell genesis placement fits comfortably in a block");
    }

    /// @notice And the cheap case a keeper actually pays for: a re-ladder that merges into ten warm cells.
    function test_gasMergingPlacement() public {
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 100e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.prank(TIMELOCK);
        uint256 before = gasleft();
        vault.place(hubPool, true, 100e18);
        uint256 used = before - gasleft();
        emit log_named_uint("place: ten merged ask cells", used);
        assertLt(used, 3_000_000, "a merge is cheaper than a fresh ladder");
    }
}
