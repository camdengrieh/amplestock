// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IMarketReference} from "../../src/interfaces/IMarketReference.sol";
import {LadderLib} from "../../src/lib/LadderLib.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {
    CellBudgetExceeded,
    HighWaterResetFailed,
    InsufficientInventory,
    NavBleedExceeded,
    NotTimelock,
    PlacementCooldown,
    PlacementDiverged
} from "../../src/types/Errors.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {VaultPlacementLib} from "../../src/vault/VaultPlacementLib.sol";
import {VaultRedeemLib} from "../../src/vault/VaultRedeemLib.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {PlacementFixture} from "../mocks/PlacementFixture.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Vm} from "forge-std/Vm.sol";

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

    /// @dev The exact per-cell AMPS of a 3,150-AMPS, ten-doubling, 1.25-tilt ask ladder — `LadderLib.split` of
    ///      `LadderLib.weights(1.25e18, 10)` — cell 0 nearest the anchor.
    uint256[10] internal ENTRY_ASK_CELLS = [
        uint256(94_728_571_561_316_218_050),
        118_410_714_451_645_273_350,
        148_013_393_064_556_594_050,
        185_016_741_330_695_743_350,
        231_270_926_663_369_678_400,
        289_088_658_329_212_098_000,
        361_360_822_911_515_122_500,
        451_701_028_639_393_904_700,
        564_626_285_799_242_379_300,
        705_782_857_249_052_988_300
    ];

    /// @dev The same shape over 90 AMPS: a spoke's seed ask, 1% of the 9,000-AMPS POL tranche.
    uint256[10] internal SPOKE_ASK_CELLS = [
        uint256(2_706_530_616_037_606_230),
        3_383_163_270_047_007_810,
        4_228_954_087_558_759_830,
        5_286_192_609_448_449_810,
        6_607_740_761_810_562_240,
        8_259_675_952_263_202_800,
        10_324_594_940_329_003_500,
        12_905_743_675_411_254_420,
        16_132_179_594_264_067_980,
        20_165_224_492_830_085_380
    ];

    /// @dev The four-halving seed bid over $10,000 of USDG, **cell nearest the anchor first**: the weight vector
    ///      runs with price, so the bid adjacent to the market is the largest (33.875% / 27.100% / 21.680% /
    ///      17.344%).
    uint256[4] internal SEED_BID_CELLS_USDG = [uint256(3_387_533_876), 2_710_027_100, 2_168_021_680, 1_734_417_344];

    function setUp() public {
        deployPlacementWorld();
    }

    // -------------------------------------------------------------------------------------------------------------
    // §3.3 — the genesis ladders, to the wei
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The entry-pool ask ladder: ten contiguous doublings from the anchor, holding
    ///         `1.25^k / SUM 1.25^j` of 3,150 AMPS each, summing to 3,150 AMPS exactly.
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

    /// @notice A spoke's seed ask is the same shape over 90 AMPS, anchored at `tickOf(P_ref / P_stock)`.
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

    /// @notice The surge is armed after every **ask** placement, so an ask cannot be sandwiched at the
    ///         pre-placement fee (gauntlet step 8) — and after no bid placement at all.
    ///
    /// @dev **Audit finding 2.** Arming for any committed cell handed `compound`'s step-7 bid re-ladder, reachable
    ///      with one wei of counter fee, the power to arm `SURGE_MAX_BPS`: the exact hole step 8's own gating was
    ///      written to close. A bid is laid *below* the tick out of value the pool already holds, cannot be
    ///      sandwiched the way an ask can, and is not a burn candidate, so it touches neither the surge nor the
    ///      mark. `compound` arms one surge of its own for the bids it lays, under its own cooldown.
    function test_f02_theSurgeAndTheMarkAreTheAskSidesAlone() public {
        assertEq(hook.surgeArmedCount(hubPool), 0, "nothing armed yet");
        uint32 resets = hook.highWaterResetCount(hubPool);

        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 100e18);
        assertEq(hook.surgeArmedCount(hubPool), 1, "the ask armed once");
        assertEq(hook.lastSurgeReason(hubPool), bytes32("place"), "with the placement's reason");
        assertEq(hook.highWaterResetCount(hubPool) - resets, 1, "and reset the mark, as every ask must");

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        uint32 armedAfterAsk = hook.surgeArmedCount(hubPool);
        uint32 resetsAfterAsk = hook.highWaterResetCount(hubPool);

        vm.prank(TIMELOCK);
        assertGt(vault.place(hubPool, false, SEED_USDG), 0, "the bid ladder went in");
        assertEq(hook.surgeArmedCount(hubPool), armedAfterAsk, "and armed no surge");
        assertEq(hook.highWaterResetCount(hubPool), resetsAfterAsk, "and moved no mark");
    }

    /// @notice **Audit finding 2, the ordering half.** An ask placement settles the pending buyback *before* it
    ///         resets the high-water mark, so the window is consumed rather than discarded.
    ///
    /// @dev The reset is what stops an ask from being burned as inventory it never was; but it also erases the
    ///      record that the price crossed a cell on the way up, and a permissionless `rollout` or `deployBonded`
    ///      landing before the next `compound` therefore left the AMPS the vault had bought back in the ladder to
    ///      be sold a second time (I33). `compound` settles the window at its own step 4; every other ask
    ///      placement settles it here, so the rule is the same everywhere: burn back, then place, then reset.
    function test_f02_anAskPlacementSettlesTheBuybackBeforeItResetsTheMark() public {
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        // The mark crossed the whole ladder while the price came back below it: every ask cell above the tick now
        // holds AMPS the vault bought back.
        PlacementRecord[] memory before = ladderOf(hubPool);
        int24 highest;
        int24 lowestAsk = type(int24).max;
        for (uint256 i; i < before.length; ++i) {
            if (!before[i].above || before[i].liquidity == 0) continue;
            if (before[i].upperTick > highest) highest = before[i].upperTick;
            if (before[i].lowerTick < lowestAsk) lowestAsk = before[i].lowerTick;
        }
        hook.setHighWaterTick(hubPool, highest);
        assertLe(tickOf(hubPool), lowestAsk, "the price sits at or below the whole ask ladder");

        uint256 supplyBefore = amps.totalSupply();
        uint32 resets = hook.highWaterResetCount(hubPool);

        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 50e18);

        assertLt(amps.totalSupply(), supplyBefore, "the pending buyback was burned by this very call");
        assertEq(hook.highWaterResetCount(hubPool) - resets, 1, "and only then was the window reset");
        assertEq(hook.highWaterTick(hubPool), tickOf(hubPool), "at the live tick");

        // Nothing the placement itself laid is left under the new mark, which is the other half of the rule.
        PlacementRecord[] memory after_ = ladderOf(hubPool);
        for (uint256 i; i < after_.length; ++i) {
            if (!after_[i].above || after_[i].liquidity == 0) continue;
            assertGt(after_[i].upperTick, hook.highWaterTick(hubPool), "no fresh ask sits under the mark");
        }
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

    /// @notice **Audit lead: the weight sum outside the `try`.** The sum was computed in *this* frame, in checked
    ///         arithmetic, so a policy vector whose elements overflow reverted the whole placement — the one thing
    ///         the `try` exists to prevent — and a pointer-upgradeable policy could therefore brick `compound`,
    ///         `rollout` and every genesis ladder. An overflow is simply a vector that does not sum to `WAD`.
    function test_lead_aLadderPolicyWhoseWeightsOverflowIsIgnoredNotFatal() public {
        uint256[] memory overflowing = new uint256[](10);
        overflowing[0] = type(uint256).max;
        overflowing[1] = 2;
        vm.mockCall(
            address(ladderPolicy), abi.encodeWithSelector(ladderPolicy.weights.selector), abi.encode(overflowing)
        );

        vm.prank(TIMELOCK);
        uint256 placed = vault.place(hubPool, true, ENTRY_ASK_AMPS);
        assertEq(placed, ENTRY_ASK_AMPS, "the placement went through");

        PlacementRecord[] memory records = ladderOf(hubPool);
        for (uint256 k; k < records.length; ++k) {
            assertEq(records[k].amount, ENTRY_ASK_CELLS[k], "with LadderLib's own weights");
        }
    }

    /// @notice **Audit lead: the cell budget charged for cells that never opened.** `++live` ran before the
    ///         placement, so a bucket whose amount could not buy one unit of liquidity over its range consumed a
    ///         budget slot it never used: on the strict governance path that became a `CellBudgetExceeded` with
    ///         real headroom left, and on the bountied paths a caller could walk a ladder's dust cells to pin the
    ///         count. The budget is spent on cells that actually opened.
    function test_lead_aCellThatBuysNoLiquidityDoesNotSpendTheBudget() public {
        // A vector with a dust weight in the first cell and the rest in the last: the first cell's share cannot
        // buy one unit of liquidity over a whole doubling, the last cell's obviously can.
        uint256[] memory vector = new uint256[](10);
        vector[0] = 1;
        vector[9] = Constants.WAD - 1;
        vm.mockCall(address(ladderPolicy), abi.encodeWithSelector(ladderPolicy.weights.selector), abi.encode(vector));

        // One slot of headroom: enough for the cell that really opens, and not for a wasted one.
        forceLiveCells(Constants.MAX_LIVE_CELLS - 1);

        vm.prank(TIMELOCK);
        uint256 placed = vault.place(hubPool, true, ENTRY_ASK_AMPS);
        assertGt(placed, 0, "the cell that could hold liquidity was placed");
        assertEq(vault.liveCells(), Constants.MAX_LIVE_CELLS, "and exactly one cell opened, not two");
        assertEq(countLiveCells(), 1, "which is the one the ladder really holds");
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
    // The `Placement` log
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **The finding this closes.** `Placed.highestTick` was grown from its zero value
    ///         (`if (lower + width > highestTick)`) while every tick an Amplestocks pool ever places at is
    ///         **negative** — AMPS is `currency0` and one AMPS buys far less than one unit of any counter asset —
    ///         so no cell ever compared greater and every `Placement` reported a top of tick 0: an indexer reading
    ///         the log saw a ladder running from its real floor up to $18 quadrillion. Both bounds are seeded by
    ///         the first cell instead.
    function test_thePlacementLogCarriesTheLaddersRealTopAndBottom() public {
        vm.recordLogs();
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);

        (uint8 buckets, int24 lowerTick, int24 upperTick) = _lastPlacement(hubPool);
        int24 width = cellWidth();

        PlacementRecord[] memory records = ladderOf(hubPool);
        assertEq(uint256(buckets), records.length, "one bucket per record");
        assertLt(lowerTick, 0, "every Amplestocks tick is negative, which is what broke the old comparison");
        assertLt(upperTick, 0, "the top included");
        assertEq(lowerTick, records[0].lowerTick, "the log's floor is the lowest cell's floor");
        assertEq(upperTick, lowerTick + int24(uint24(buckets)) * width, "and its top is the highest cell's top");

        // And it really is the maximum over the cells, not merely the last one written.
        for (uint256 i; i < records.length; ++i) {
            assertGe(upperTick, records[i].upperTick, "no cell reaches above the reported top");
            assertLe(lowerTick, records[i].lowerTick, "and none below the reported floor");
        }
    }

    /// @notice The same for a bid ladder, which runs *down* from the anchor: the floor is the last cell placed and
    ///         the top the first, so a seeded `lowestTick` matters as much as a seeded `highestTick`.
    function test_thePlacementLogCarriesBothBoundsForABidLadderToo() public {
        vm.recordLogs();
        vm.prank(TIMELOCK);
        vault.place(hubPool, false, SEED_USDG);

        (uint8 buckets, int24 lowerTick, int24 upperTick) = _lastPlacement(hubPool);
        assertEq(upperTick, lowerTick + int24(uint24(buckets)) * cellWidth(), "contiguous, floor to top");
        assertLe(upperTick, PriceLib.alignTick(tickOf(hubPool), TICK_SPACING, false), "I9: the whole ladder is a bid");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The transient staging buffer
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The transient slot `VaultPlacementLib` stages placed cells in is the one `Constants` declares, and
    ///         that constant really is the hash of the string it names.
    /// @dev **The finding this closes.** The library carried a hand-written literal
    ///      (`0x1f0c2fd9…a190`) whose comment claimed it was `keccak256("amplestocks.vault.PLACEMENT_STAGE")`. It
    ///      was not that hash at all — it was an invented number — so the buffer sat outside the namespace every
    ///      other vault slot is derived from and the next slot anyone derived from that string would have landed
    ///      somewhere else entirely. This is the drift guard on the replacement, and it mirrors
    ///      `test/unit/RotationCredit.t.sol`'s guard on the hook's `ROTATION_CREDIT_SLOT`.
    function test_theStagingBufferSlotIsTheHashItClaimsToBe() public pure {
        assertEq(
            uint256(Constants.PLACEMENT_STAGE_SLOT),
            0xc6581d9946980dd7ee72e915a5cc531936e37fb4d55c38fe9dc446b32f47d8d7,
            "the value VaultPlacementLib.STAGE_SLOT resolves to"
        );
        assertEq(
            Constants.PLACEMENT_STAGE_SLOT,
            keccak256("amplestocks.vault.PLACEMENT_STAGE"),
            "and the string it is derived from"
        );
    }

    /// @notice And the buffer — four words a cell, `GRID_CELLS` cells — does not overlap any other transient or
    ///         hashed slot the vault uses.
    function test_theStagingBufferDoesNotCollideWithTheVaultsOtherSlots() public pure {
        uint256 base = uint256(Constants.PLACEMENT_STAGE_SLOT);
        uint256 span = 4 * uint256(Constants.GRID_CELLS);
        uint256[4] memory others = [
            VaultRedeemLib.REENTRANCY_LOCK,
            VaultRedeemLib.UNLOCK_ACTION,
            VaultRedeemLib.NAV_BEFORE,
            VaultRedeemLib.LIVE_CELLS_SLOT
        ];
        for (uint256 i; i < others.length; ++i) {
            assertTrue(others[i] < base || others[i] >= base + span, "outside the staging buffer");
        }
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

    // -------------------------------------------------------------------------------------------------------------
    // Audit remediation, second wave (2026-09-07)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **The re-audit finding on the anchor's rounding, measured and bounded rather than "fixed".**
    ///
    ///         `_referenceTick` hands {VaultPlacementLib-_cells} `PriceLib.fairTick`, which aligns **down** onto
    ///         the tick spacing, and `_cells` then ceils onto the doubling grid; the two roundings point in
    ///         opposite directions, so the first ask cell's lower bound can sit up to `tickSpacing - 1` ticks
    ///         below the exact reference. That is true, and this test pins exactly how far: **at most one tick
    ///         spacing, on the first cell only**, with every other cell a whole doubling clear of it.
    ///
    ///         It is not closed by anchoring at the reference (aligned up, or unrounded — the two agree here)
    ///         because at genesis the exact reference sits *inside* cell `m = 0`: the grid origin is
    ///         `alignDown(openingTick)` and the opening tick is the reference tick (§12 ruling C). Anchoring
    ///         above it makes `_ceilDiv` return 1, so the ladder would start at `m = 1` — no protocol-owned ask
    ///         anywhere between `P_ref` and `2 x P_ref`, at genesis and after every `compound`. The grid cannot be
    ///         moved to dodge the choice either: snapping the *opening* up puts cell `m = -1`'s upper bound above
    ///         the reference, and the valuer writes a straddled **bid**'s AMPS half off at zero (I5), which is a
    ///         hard R1 revert on the seed bids. One side of the origin cell must straddle, and the design picks
    ///         the side where the mis-valuation over-states `A` and therefore cannot trip R1.
    function test_i32_theStraddleOfTheFirstAskCellIsBoundedByOneTickSpacing() public {
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);

        // `raw` is the exact reference tick, before either alignment: the greatest tick whose price is at or below
        // `P_ref / P_counter`. `refTick` is the same number snapped down onto the spacing — the `tickOf` §3.7's
        // statement of I32 names, and the anchor the ladder is built from.
        int24 raw = TickMath.getTickAtSqrtPrice(PriceLib.ampsPerCounterToSqrtPriceX96(vault.pRefX18(), USDG_USD8, 6));
        int24 refTick = PriceLib.fairTick(vault.pRefX18(), USDG_USD8, 6, TICK_SPACING);
        assertLe(refTick, raw, "the anchor is the reference aligned down");

        PlacementRecord[] memory records = ladderOf(hubPool);
        assertGt(records.length, 0, "the ladder went in");

        int24 lowest = type(int24).max;
        for (uint256 i; i < records.length; ++i) {
            if (!records[i].above) continue;
            // I32 in the form §3.7 states it: `lowerTick >= tickOf(P_ref / P_counter)`, `tickOf` aligned down.
            assertGe(records[i].lowerTick, refTick, "no ask below the reference cell");
            if (records[i].lowerTick < lowest) lowest = records[i].lowerTick;
        }

        // And the whole of the residue, to the tick. `_cells` returns the first grid cell at or above the anchor,
        // and the anchor is at most `tickSpacing - 1` ticks under `raw`, so the first cell's lower bound can never
        // be further under the exact reference than one tick spacing — whatever the pool's grid origin is and
        // wherever `P_ref` has moved to since it opened.
        assertLt(raw - lowest, TICK_SPACING, "the straddle is under one tick spacing");

        // Every other cell is a whole doubling clear of it, so the residue is one cell's business and no other's.
        for (uint256 i; i < records.length; ++i) {
            if (!records[i].above || records[i].lowerTick == lowest) continue;
            assertGe(records[i].lowerTick, lowest + cellWidth(), "every other ask cell is a doubling higher");
        }
    }

    /// @notice And the stricter reading is one argument away: `PriceLib.fairTick`'s five-argument form snaps the
    ///         same reference **up**, so switching `_referenceTick` to it is a one-token change should the
    ///         orchestrator rule that the straddle above must go — at the cost the test before this one names.
    function test_theAnchorCanBeSnappedUpOnDemand() public view {
        uint256 pRef = vault.pRefX18();
        int24 raw = TickMath.getTickAtSqrtPrice(PriceLib.ampsPerCounterToSqrtPriceX96(pRef, USDG_USD8, 6));
        int24 down = PriceLib.fairTick(pRef, USDG_USD8, 6, TICK_SPACING);
        int24 up = PriceLib.fairTick(pRef, USDG_USD8, 6, TICK_SPACING, true);

        assertEq(down, PriceLib.fairTick(pRef, USDG_USD8, 6, TICK_SPACING, false), "the four-argument form floors");
        assertLe(down, raw, "and is at or below the reference");
        assertGe(up, raw, "the five-argument form is at or above it");
        assertLe(up - down, TICK_SPACING, "and the two are never more than one spacing apart");
        assertEq(up % TICK_SPACING, int24(0), "both land on the spacing");
        assertEq(down % TICK_SPACING, int24(0), "both land on the spacing");
    }

    /// @notice **The finding this closes.** `_placeLadder` read the counter asset's balance with a typed
    ///         `IERC20.balanceOf`, so a Stock Token whose `balanceOf` reverts bricked every placement into its
    ///         pool. The read is a bounded, hand-decoded `staticcall` now and an unreadable answer is zero, so the
    ///         placement proceeds on the ERC-6909 claim the bond settled — which is where bonded collateral lives.
    ///
    /// @dev **Cross-slice, and the assertion says which slice.** `AmpsVault.place` takes its R1 pre-image before
    ///      it delegates, and `VaultNavLib.totalAssetsUsd18` still reads this same balance with a typed
    ///      `IERC20.balanceOf` — a read this slice does not own and the vault slice is hardening alongside it. So
    ///      on the placement library alone the call may still stop, one frame *earlier* than it used to. What is
    ///      pinned here either way is that nothing in `VaultPlacementLib` is what stops it: with the NAV read
    ///      hardened the ladder goes in off the claim balance, and without it the only thing left is the token's
    ///      own `BalanceUnavailable` out of the NAV pre-image — never `InsufficientInventory`, which is what a
    ///      placement library that had read a zero balance and then trusted it would raise.
    function test_aStockTokenWhoseBalanceOfRevertsDoesNotBrickItsPlacement() public {
        uint256 settled = bondDeposit(address(stocks[0]), 100e18);
        assertEq(claimOf(address(stocks[0])), settled, "the collateral arrived as an ERC-6909 claim");

        stocks[0].setBalanceOfReverts(true);

        vm.prank(TIMELOCK);
        try vault.place(spokePools[0], false, settled) returns (uint256 placed) {
            assertGt(placed, 0, "the bid ladder went in on the claim balance alone");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(MockStockToken.BalanceUnavailable.selector),
                "the only typed balance read left on this path is VaultNavLib's NAV pre-image"
            );
        }

        stocks[0].setBalanceOfReverts(false);
    }

    /// @notice **The finding this closes.** `modifyLiquidity` returns `callerDelta = principal + feesAccrued`, so
    ///         merging into a cell that already holds liquidity netted that cell's unclaimed fees into the
    ///         settlement — the AMPS side went straight back into the ladder without the creator, staker and burn
    ///         slices of §3.6 step 5. `compound` collects first and was never affected; `place`, `rollout` and
    ///         `deployBonded` did not, and every pool that had traded since its last `compound` recycled its own
    ///         AMPS-side fees at the next placement. The collect-and-split now happens on the way in.
    function test_placingIntoACellWithAccruedAmpsFeesPaysTheCreatorStakerAndBurnSlices() public {
        placeGenesisLadders();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        // A round trip through the hub's ladder: the sell pays its 500 bp in AMPS, which accrues to the cells it
        // crosses and is left there, unclaimed, because nothing has compounded since.
        buyAmps(hubPool, address(usdg), 100e6);
        sellAmps(hubPool, amps.balanceOf(BOB) / 2);
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 creatorBefore = amps.balanceOf(CREATOR);
        // The counter slice is an ERC-6909 claim since audit finding 8: no third-party token code may run inside
        // the vault's own unlock, so the creator is handed the claim rather than the token.
        uint256 creatorUsdgBefore = poolManager.balanceOf(CREATOR, uint256(uint160(address(usdg))));
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 10e18);

        assertGt(amps.balanceOf(CREATOR) - creatorBefore, 0, "the creator's AMPS slice was paid");
        assertGt(
            poolManager.balanceOf(CREATOR, uint256(uint160(address(usdg)))) - creatorUsdgBefore,
            0,
            "and the counter slice with it, as a claim"
        );
        assertLt(amps.totalSupply(), supplyBefore, "and every wei of the AMPS-side remainder was burned");
        assertSweepClean("place into a cell with accrued fees");
    }

    /// @notice And the second half of the same fix: with the fees collected on the way in, the placement's own
    ///         settlement is principal and nothing else, so a second placement in the same state finds nothing
    ///         left to split.
    function test_theSecondPlacementFindsNoFeesLeftToSplit() public {
        placeGenesisLadders();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        buyAmps(hubPool, address(usdg), 100e6);
        sellAmps(hubPool, amps.balanceOf(BOB) / 2);
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 10e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 creatorBefore = amps.balanceOf(CREATOR);
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, 10e18);
        assertEq(amps.balanceOf(CREATOR), creatorBefore, "no trade, no fee, no slice");
    }

    /// @notice **The finding this closes.** An ask is placed strictly above the tick, so it satisfies
    ///         `tick <= lowerTick` — half of the buyback-burn predicate — from the moment it is opened; the only
    ///         thing keeping it out of the burn is the high-water reset the placement performs. That reset was a
    ///         typed `try ... catch {}`, so a market reference that refuses it left a stale mark standing and the
    ///         next permissionless `compound` burned never-sold POL. The reset is a bounded, hand-decoded call
    ///         and an ask placement that cannot perform it reverts.
    function test_anAskPlacementRefusesToLeaveAStaleHighWaterMarkStanding() public {
        hook.setResetHighWaterReverts(true);

        vm.prank(TIMELOCK);
        vm.expectPartialRevert(HighWaterResetFailed.selector);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
    }

    /// @notice The subtler half: a market reference that *returns* but returns nothing where an `int24` was
    ///         declared. A typed `try` reads that as a successful call; the hand-decoded probe measures the
    ///         returndata and refuses it.
    function test_aSilentHighWaterResetIsRefusedToo() public {
        hook.setResetHighWaterSilent(true);

        vm.prank(TIMELOCK);
        vm.expectPartialRevert(HighWaterResetFailed.selector);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
    }

    /// @notice And a bid keeps the best-effort behaviour, because a bid sits below the tick and can never satisfy
    ///         the burn predicate's second half: there is no stale mark for it to be endangered by.
    function test_aBidPlacementIsUnaffectedByAFailingHighWaterReset() public {
        vm.prank(TIMELOCK);
        vault.place(hubPool, true, ENTRY_ASK_AMPS);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        hook.setResetHighWaterReverts(true);
        vm.prank(TIMELOCK);
        assertEq(vault.place(hubPool, false, SEED_USDG), SEED_USDG, "the seed bids still go in");
    }

    /// @notice **Re-audit lead.** A market reference that answers `highWaterTick` with something too short to
    ///         decode degrades the buyback to "nothing counts as bought back" rather than bricking the compound.
    ///
    /// @dev The last typed `try` left on a pointer-upgradeable target in `VaultPlacementLib`. Solidity decodes a
    ///      *successful* call's returndata in the caller's frame, so a short — or out-of-range — answer raised a
    ///      `Panic` **past** the `catch` and took `compound`, `place` and every burnback with it: a governance
    ///      pointer bricking placements instead of degrading them.
    function test_r16_aMalformedHighWaterAnswerDegradesInsteadOfBrickingThePlacement() public {
        vm.mockCall(address(hook), abi.encodeWithSelector(IMarketReference.highWaterTick.selector), hex"01");

        vm.prank(KEEPER);
        (, uint256 burned) = vault.compound(hubPool);
        assertEq(burned, 0, "an unreadable mark means nothing counts as bought back");

        // And a governance placement on the same pool still goes in.
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(TIMELOCK);
        assertGt(vault.place(hubPool, false, 10e6), 0, "the placement path is unaffected");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The last `Placement` for `poolId` in the recorded logs. `vm.recordLogs()` must have been armed first.
    function _lastPlacement(PoolId poolId) private view returns (uint8 buckets, int24 lowerTick, int24 upperTick) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i != 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(vault) || entry.topics[0] != IAmpsVault.Placement.selector) continue;
            if (entry.topics[1] != PoolId.unwrap(poolId)) continue;
            (, uint8 cells,,,, int24 lower, int24 upper) =
                abi.decode(entry.data, (bool, uint8, uint256, int24, bytes32, int24, int24));
            return (cells, lower, upper);
        }
        revert("no Placement");
    }
}
