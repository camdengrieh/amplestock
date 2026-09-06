// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILadderPolicy} from "../../src/interfaces/ILadderPolicy.sol";
import {LadderLib} from "../../src/lib/LadderLib.sol";
import {LadderPolicy} from "../../src/policy/LadderPolicy.sol";
import {Constants} from "../../src/types/Constants.sol";
import {LadderLibHarness, PriceLibHarness} from "../utils/LibHarness.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Unit tests for the launch ladder shape: the §3.3 genesis ladders reproduced to the wei, the geometric
///         weights, contiguity, sidedness (I9), grid membership (I39) and the round trip against `LadderLib`.
///
/// @dev The genesis numbers are pinned twice over: once against literals computed independently from the
///      `w_k = tilt^k / SUM tilt^j` series with the library's exact flooring and residue rules, and once against
///      `LadderLib.ladderAmounts` itself, so a drift in either the policy or the library fails a test rather than
///      quietly re-shaping the ladder.
contract LadderPolicyTest is Test {
    LadderPolicy internal policy;
    LadderLibHarness internal ladder;
    PriceLibHarness internal price;

    /// @dev The entry pools run at spacing 10 (`docs/phase3-state-model.md` §3.3's worked example), the spokes at
    ///      60, which is what `unit/PoolRegistry.t.sol` configures.
    int24 internal constant ENTRY_SPACING = 10;
    int24 internal constant SPOKE_SPACING = 60;

    uint64 internal constant TILT = Constants.LADDER_TILT_X18_DEFAULT;
    uint8 internal constant DOUBLINGS = Constants.LADDER_DOUBLINGS_DEFAULT;
    uint8 internal constant HALVINGS = Constants.SEED_HALVINGS_DEFAULT;

    /// @dev 1,662.5 AMPS per entry pool: half of the 3,325 AMPS the two entry pools hold at genesis.
    uint256 internal constant ENTRY_ASK_AMPS = 1662.5e18;

    /// @dev 47.5 AMPS per spoke: 1% of the 4,750-AMPS POL tranche.
    uint256 internal constant SPOKE_ASK_AMPS = 47.5e18;

    /// @dev $2,500 of USDG (6 decimals) as the `AMPS/USDG` seed bid.
    uint256 internal constant SEED_BID_USDG = 2500e6;

    function setUp() public {
        policy = new LadderPolicy();
        ladder = new LadderLibHarness();
        price = new PriceLibHarness();
    }

    /* ------------------------------------------- identity ------------------------------------------- */

    function test_version() public view {
        assertEq(policy.version(), bytes32("geometric-doubling-v1"));
    }

    function test_bandsComeFromConstants() public view {
        assertEq(policy.LADDER_TILT_X18_MIN(), Constants.LADDER_TILT_X18_MIN, "tilt floor");
        assertEq(policy.LADDER_TILT_X18_MAX(), Constants.LADDER_TILT_X18_MAX, "tilt ceiling");
        assertEq(policy.LADDER_DOUBLINGS_MIN(), Constants.LADDER_DOUBLINGS_MIN, "doublings floor");
        assertEq(policy.LADDER_DOUBLINGS_MAX(), Constants.LADDER_DOUBLINGS_MAX, "doublings ceiling");
        assertEq(policy.HALVINGS_MIN(), Constants.HALVINGS_MIN, "halvings floor");
        assertEq(policy.HALVINGS_MAX(), Constants.HALVINGS_MAX, "halvings ceiling");
        // The launch values sit inside their own bands, which is what makes a genesis placement legal at all.
        assertGe(TILT, policy.LADDER_TILT_X18_MIN());
        assertLe(TILT, policy.LADDER_TILT_X18_MAX());
        assertGe(DOUBLINGS, policy.LADDER_DOUBLINGS_MIN());
        assertLe(DOUBLINGS, policy.LADDER_DOUBLINGS_MAX());
    }

    /* --------------------------------------- the genesis ladders --------------------------------------- */

    /// @dev §3.3, entry pools: 1,662.5 AMPS as ten doublings above $1.00 at tilt 1.25. Every bucket to the wei.
    function test_genesisEntryAskLadderToTheWei() public view {
        int24 anchor = _entryAnchor();
        ILadderPolicy.LadderBucket[] memory buckets =
            _propose(anchor, anchor, ENTRY_SPACING, DOUBLINGS, ENTRY_ASK_AMPS, true);

        uint256[10] memory expected = [
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

        uint256 total;
        for (uint256 k = 0; k < DOUBLINGS; ++k) {
            assertEq(buckets[k].amount, expected[k], "genesis entry ask bucket");
            total += buckets[k].amount;
        }
        assertEq(total, ENTRY_ASK_AMPS, "the split is exact");

        // The doc's headline shares: bucket 0 is 3.007% and bucket 9 is 22.406% of the tranche. The re-derived
        // share is a wei under the exact weight, because `split` floors every element but the last.
        //
        // The first draft of `docs/phase3-state-model.md` §3.3 gave `w_9 = 28.008%` (465.7 AMPS), which is
        // `1.25^10 / 33.2529`, one power too many; the doc now carries the correct `1.25^9 / 33.2529 == 22.4058%`
        // (372.4965 AMPS), which is what `LadderLib` computes and what `unit/LadderLib.t.sol` already pins. The
        // arithmetic is pinned here as well so the two can never drift apart again.
        assertApproxEqAbs(buckets[0].amount * 1e18 / ENTRY_ASK_AMPS, 30_072_562_400_417_847, 1, "w_0 == 3.0073%");
        assertApproxEqAbs(buckets[9].amount * 1e18 / ENTRY_ASK_AMPS, 224_058_049_920_334_282, 1, "w_9 == 22.4058%");
    }

    /// @dev §3.3, spokes: 47.5 AMPS, ten doublings, tilt 1.25, anchored at `tickOf(P_ref / P_stock)`.
    function test_genesisSpokeAskLadderToTheWei() public view {
        int24 anchor = _spokeAnchor();
        ILadderPolicy.LadderBucket[] memory buckets =
            _propose(anchor, anchor, SPOKE_SPACING, DOUBLINGS, SPOKE_ASK_AMPS, true);

        uint256[10] memory expected = [
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

        uint256 total;
        for (uint256 k = 0; k < DOUBLINGS; ++k) {
            assertEq(buckets[k].amount, expected[k], "genesis spoke ask bucket");
            total += buckets[k].amount;
        }
        assertEq(total, SPOKE_ASK_AMPS, "the split is exact");
        // Thirty spokes at 47.5 AMPS is the 1,425-AMPS half of the POL tranche.
        assertEq(SPOKE_ASK_AMPS * 30, 1425e18, "the spoke tranche closes");
    }

    /// @dev §3.3, seed bids: $2,500 of USDG as four halvings below $1.00, weighted 1.25x toward the anchor.
    function test_genesisSeedBidLadderToTheWei() public view {
        int24 anchor = _entryAnchor();
        ILadderPolicy.LadderBucket[] memory buckets =
            _propose(anchor, anchor, ENTRY_SPACING, HALVINGS, SEED_BID_USDG, false);

        // The weight vector runs with price, so bucket 0 — the halving adjacent to $1 — is the largest.
        uint256[4] memory expected = [uint256(846_883_469), 677_506_775, 542_005_420, 433_604_336];

        uint256 total;
        uint256 previous = type(uint256).max;
        for (uint256 k = 0; k < HALVINGS; ++k) {
            assertEq(buckets[k].amount, expected[k], "genesis seed bid bucket");
            assertLt(buckets[k].amount, previous, "bids thin out as the price falls");
            previous = buckets[k].amount;
            total += buckets[k].amount;
        }
        assertEq(total, SEED_BID_USDG, "the split is exact");

        // 33.875% / 27.100% / 21.680% / 17.344%, which is the doc's 1.25x tilt toward $1.
        assertEq(buckets[0].amount * 1e18 / SEED_BID_USDG, 338_753_387_600_000_000, "w_0 == 33.8753%");
        assertEq(buckets[3].amount * 1e18 / SEED_BID_USDG, 173_441_734_400_000_000, "w_3 == 17.3442%");
    }

    /// @dev The genesis ask ladder really does span $1 -> ~$1,024 and raise the plan's "about $140 doubles the
    ///      price" out of its first bucket across both entry pools.
    function test_genesisEntryAskLadderSpansOneToAThousandTwentyFour() public view {
        int24 anchor = _entryAnchor();
        ILadderPolicy.LadderBucket[] memory buckets =
            _propose(anchor, anchor, ENTRY_SPACING, DOUBLINGS, ENTRY_ASK_AMPS, true);

        uint256 bottom = price.sqrtPriceX96ToAmpsPriceUsd18(price.tickToSqrtPriceX96(buckets[0].lowerTick), 1e8, 6);
        uint256 top = price.sqrtPriceX96ToAmpsPriceUsd18(price.tickToSqrtPriceX96(buckets[9].upperTick), 1e8, 6);
        assertApproxEqRel(bottom, 1e18, 0.001e18, "the ladder starts at $1.00");
        assertGe(top, 1024e18, "and finishes at or above $1,024");
        assertLe(top, 1040e18, "the doubling rounds up, but only marginally");
    }

    /* ------------------------------------------ the shape ------------------------------------------ */

    /// @dev I34: bucket `k` holds `tilt^k / SUM_j tilt^j`, so consecutive buckets stand in the tilt ratio.
    function test_weightsAreProportionalToTiltToTheK() public view {
        uint256[] memory w = policy.weights(TILT, DOUBLINGS);
        assertEq(w.length, DOUBLINGS, "one weight per bucket");

        uint256 sum;
        for (uint256 k = 0; k < w.length; ++k) {
            sum += w[k];
            if (k > 0) {
                // w_k / w_{k-1} == tilt, to within the flooring of a 1e18 fixed-point ratio.
                assertApproxEqRel(w[k] * 1e18 / w[k - 1], uint256(TILT), 1e9, "consecutive weights are in tilt");
            }
        }
        assertEq(sum, 1e18, "the weights sum to exactly 1e18");
        assertEq(w[0], 30_072_562_400_417_847, "w_0 for ten buckets at tilt 1.25");
        assertEq(w[9], 224_058_049_920_334_282, "w_9 for ten buckets at tilt 1.25");
    }

    /// @dev A flat ladder is the band floor and must give ten equal buckets.
    function test_flatTiltGivesEqualBuckets() public view {
        uint256[] memory w = policy.weights(Constants.LADDER_TILT_X18_MIN, DOUBLINGS);
        for (uint256 k = 0; k + 1 < w.length; ++k) {
            assertEq(w[k], 1e17, "a flat tilt is 10% per bucket");
        }
        assertEq(w[9], 1e17, "including the residue bucket");
    }

    function test_bucketsAreContiguousDoublingsAbove() public view {
        int24 anchor = _entryAnchor();
        int24 width = ladder.doublingTicks(ENTRY_SPACING);
        ILadderPolicy.LadderBucket[] memory buckets =
            _propose(anchor, anchor, ENTRY_SPACING, DOUBLINGS, ENTRY_ASK_AMPS, true);

        assertEq(buckets[0].lowerTick, anchor, "the first ask starts at the aligned anchor");
        for (uint256 k = 0; k < buckets.length; ++k) {
            assertEq(buckets[k].upperTick - buckets[k].lowerTick, width, "one doubling wide");
            assertEq(buckets[k].lowerTick % ENTRY_SPACING, int24(0), "lower aligned to the spacing");
            if (k > 0) assertEq(buckets[k].lowerTick, buckets[k - 1].upperTick, "contiguous with the bucket below");
        }
        assertEq(buckets[9].upperTick, anchor + int24(uint24(DOUBLINGS)) * width, "ten doublings above the anchor");
    }

    function test_bucketsAreContiguousHalvingsBelow() public view {
        int24 anchor = _entryAnchor();
        int24 width = ladder.doublingTicks(ENTRY_SPACING);
        ILadderPolicy.LadderBucket[] memory buckets =
            _propose(anchor, anchor, ENTRY_SPACING, HALVINGS, SEED_BID_USDG, false);

        assertEq(buckets[0].upperTick, anchor, "the first bid ends at the aligned anchor");
        for (uint256 k = 0; k < buckets.length; ++k) {
            assertEq(buckets[k].upperTick - buckets[k].lowerTick, width, "one halving wide");
            if (k > 0) assertEq(buckets[k].upperTick, buckets[k - 1].lowerTick, "contiguous with the bucket above");
        }
        assertEq(buckets[3].lowerTick, anchor - int24(uint24(HALVINGS)) * width, "four halvings below the anchor");
    }

    /// @dev Every bucket count in both governed bands composes, and the split stays exact in all of them.
    function test_everyGovernedBucketCountComposes() public view {
        int24 anchor = _entryAnchor();
        for (uint8 n = Constants.LADDER_DOUBLINGS_MIN; n <= Constants.LADDER_DOUBLINGS_MAX; ++n) {
            ILadderPolicy.LadderBucket[] memory asks = _propose(anchor, anchor, ENTRY_SPACING, n, ENTRY_ASK_AMPS, true);
            assertEq(asks.length, n, "one bucket per doubling");
            assertEq(_sum(asks), ENTRY_ASK_AMPS, "asks split exactly");
        }
        for (uint8 n = Constants.HALVINGS_MIN; n <= Constants.HALVINGS_MAX; ++n) {
            ILadderPolicy.LadderBucket[] memory bids = _propose(anchor, anchor, ENTRY_SPACING, n, SEED_BID_USDG, false);
            assertEq(bids.length, n, "one bucket per halving");
            assertEq(_sum(bids), SEED_BID_USDG, "bids split exactly");
        }
    }

    /* ------------------------------------------ sidedness (I9) ------------------------------------------ */

    /// @dev An ask ladder anchored at or above the current tick is accepted; every bucket sits above the tick.
    function test_asksAreStrictlyAboveAnUnalignedCurrentTick() public view {
        int24 anchor = _entryAnchor();
        int24 currentTick = anchor - 3; // unaligned, just below the anchor
        ILadderPolicy.LadderBucket[] memory buckets =
            _propose(anchor, currentTick, ENTRY_SPACING, DOUBLINGS, ENTRY_ASK_AMPS, true);
        for (uint256 k = 0; k < buckets.length; ++k) {
            assertGt(buckets[k].lowerTick, currentTick, "no ask at or below the current tick");
        }
    }

    function test_bidsAreStrictlyBelowAnUnalignedCurrentTick() public view {
        int24 anchor = _entryAnchor();
        int24 currentTick = anchor + 3; // unaligned, just above the anchor
        ILadderPolicy.LadderBucket[] memory buckets =
            _propose(anchor, currentTick, ENTRY_SPACING, HALVINGS, SEED_BID_USDG, false);
        for (uint256 k = 0; k < buckets.length; ++k) {
            assertLt(buckets[k].upperTick, currentTick, "no bid at or above the current tick");
        }
    }

    function test_revert_askLadderThatWouldStartBelowTheTick() public {
        int24 anchor = _entryAnchor();
        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("askBelowTick")));
        _propose(anchor, anchor + ENTRY_SPACING, ENTRY_SPACING, DOUBLINGS, ENTRY_ASK_AMPS, true);
    }

    function test_revert_bidLadderThatWouldStartAboveTheTick() public {
        int24 anchor = _entryAnchor();
        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("bidAboveTick")));
        _propose(anchor, anchor - ENTRY_SPACING, ENTRY_SPACING, HALVINGS, SEED_BID_USDG, false);
    }

    /* ------------------------------------- the canonical grid (I39) ------------------------------------- */

    /// @dev §3.2: genesis asks occupy cells `m = 0..9` and seed bids `m = -4..-1` of the pool's grid, with the
    ///      grid origin at the genesis anchor. Every bucket this policy proposes is one cell of the same lattice
    ///      `LadderPositionValuer` enumerates.
    function test_genesisBucketsAreExactlyGridCells() public view {
        int24 anchor = _entryAnchor();
        int24 gridBase = anchor;

        ILadderPolicy.LadderBucket[] memory asks =
            _propose(anchor, anchor, ENTRY_SPACING, DOUBLINGS, ENTRY_ASK_AMPS, true);
        for (uint256 k = 0; k < asks.length; ++k) {
            (int24 m, bool onGrid) = policy.cellIndex(asks[k].lowerTick, gridBase, ENTRY_SPACING);
            assertTrue(onGrid, "ask bucket is a placeable grid cell");
            assertEq(m, int24(int256(k)), "ask bucket k is cell m == k");
        }

        ILadderPolicy.LadderBucket[] memory bids =
            _propose(anchor, anchor, ENTRY_SPACING, HALVINGS, SEED_BID_USDG, false);
        for (uint256 k = 0; k < bids.length; ++k) {
            (int24 m, bool onGrid) = policy.cellIndex(bids[k].lowerTick, gridBase, ENTRY_SPACING);
            assertTrue(onGrid, "bid bucket is a placeable grid cell");
            assertEq(m, -int24(int256(k)) - 1, "bid bucket k is cell m == -(k+1)");
        }
    }

    /// @dev A re-laddered placement anchored a whole doubling above the origin lands in cells `m = j..j+n-1`, which
    ///      is what makes `compound`'s merge-by-cell work at all.
    function test_reLadderedPlacementLandsOnTheSameLattice() public view {
        int24 gridBase = _entryAnchor();
        int24 width = ladder.doublingTicks(ENTRY_SPACING);
        int24 anchor = gridBase + 3 * width; // the price has run three doublings

        ILadderPolicy.LadderBucket[] memory buckets = _propose(anchor, anchor, ENTRY_SPACING, 6, 100e18, true);
        for (uint256 k = 0; k < buckets.length; ++k) {
            (int24 m, bool onGrid) = policy.cellIndex(buckets[k].lowerTick, gridBase, ENTRY_SPACING);
            assertTrue(onGrid, "re-laddered bucket is on the grid");
            assertEq(m, int24(int256(k)) + 3, "cells 3..8");
        }
    }

    /// @dev Cells outside `[GRID_MIN_M, GRID_MAX_M)` are never placeable, and a tick that is not a cell boundary is
    ///      never on the grid at all.
    function test_cellIndexRejectsOffGridAndOutOfRangeCells() public view {
        int24 gridBase = _entryAnchor();
        int24 width = ladder.doublingTicks(ENTRY_SPACING);

        (, bool boundary) = policy.cellIndex(gridBase + width / 2, gridBase, ENTRY_SPACING);
        assertFalse(boundary, "a tick inside a cell is not a cell boundary");

        (int24 last, bool lastOnGrid) =
            policy.cellIndex(gridBase + (Constants.GRID_MAX_M - 1) * width, gridBase, ENTRY_SPACING);
        assertEq(last, Constants.GRID_MAX_M - 1, "the highest placeable cell");
        assertTrue(lastOnGrid, "and it is placeable");

        (, bool aboveTop) = policy.cellIndex(gridBase + Constants.GRID_MAX_M * width, gridBase, ENTRY_SPACING);
        assertFalse(aboveTop, "GRID_MAX_M is exclusive");

        (int24 first, bool firstOnGrid) =
            policy.cellIndex(gridBase + Constants.GRID_MIN_M * width, gridBase, ENTRY_SPACING);
        assertEq(first, Constants.GRID_MIN_M, "the lowest placeable cell");
        assertTrue(firstOnGrid, "and it is placeable");

        (, bool belowBottom) = policy.cellIndex(gridBase + (Constants.GRID_MIN_M - 1) * width, gridBase, ENTRY_SPACING);
        assertFalse(belowBottom, "one cell below GRID_MIN_M is off the grid");
    }

    /// @dev The governed bucket bands can never ask for more cells than the grid has on that side: 14 doublings
    ///      against 16 cells above the origin, 8 halvings against 8 below it.
    function test_governedBandsFitInsideTheGrid() public pure {
        assertLe(int24(uint24(Constants.LADDER_DOUBLINGS_MAX)), Constants.GRID_MAX_M, "asks fit above the origin");
        assertLe(int24(uint24(Constants.HALVINGS_MAX)), -Constants.GRID_MIN_M, "bids fit below the origin");
    }

    /* ------------------------------------ the round trip through LadderLib ------------------------------------ */

    /// @dev The policy is a wrapper, not a second implementation: bounds, amounts and liquidity all agree with
    ///      `LadderLib` for both sides.
    function test_roundTripAgainstLadderLib() public view {
        int24 anchor = _entryAnchor();

        _assertMatchesLibrary(anchor, ENTRY_SPACING, DOUBLINGS, ENTRY_ASK_AMPS, true);
        _assertMatchesLibrary(anchor, ENTRY_SPACING, HALVINGS, SEED_BID_USDG, false);
        _assertMatchesLibrary(_spokeAnchor(), SPOKE_SPACING, DOUBLINGS, SPOKE_ASK_AMPS, true);
    }

    /// @dev The externals delegate to the library rather than reimplementing it.
    function test_externalsMatchTheLibrary() public view {
        uint256[] memory expected = ladder.weights(TILT, DOUBLINGS);
        uint256[] memory actual = policy.weights(TILT, DOUBLINGS);
        for (uint256 k = 0; k < expected.length; ++k) {
            assertEq(actual[k], expected[k], "weights");
        }

        uint256[] memory amounts = policy.split(ENTRY_ASK_AMPS, actual);
        uint256[] memory libraryAmounts = ladder.split(ENTRY_ASK_AMPS, expected);
        for (uint256 k = 0; k < amounts.length; ++k) {
            assertEq(amounts[k], libraryAmounts[k], "split");
        }

        (int24 lower, int24 upper) = policy.bucketBounds(_entryAnchor(), ENTRY_SPACING, 7, true);
        (int24 libLower, int24 libUpper) = ladder.bucketBounds(_entryAnchor(), ENTRY_SPACING, 7, true);
        assertEq(lower, libLower, "bucketBounds lower");
        assertEq(upper, libUpper, "bucketBounds upper");
    }

    /// @dev Liquidity rounds down, so re-deriving each bucket's amount from its liquidity never exceeds what was
    ///      assigned and loses at most a wei per bucket. The shortfall stays with the vault as idle inventory.
    function test_liquidityRoundingLosesAtMostDust() public view {
        int24 anchor = _entryAnchor();
        ILadderPolicy.LadderBucket[] memory buckets =
            _propose(anchor, anchor, ENTRY_SPACING, DOUBLINGS, ENTRY_ASK_AMPS, true);

        uint256 placed;
        for (uint256 k = 0; k < buckets.length; ++k) {
            uint256 back = ladder.amount0ForLiquidity(
                price.tickToSqrtPriceX96(buckets[k].lowerTick),
                price.tickToSqrtPriceX96(buckets[k].upperTick),
                buckets[k].liquidity
            );
            assertLe(back, buckets[k].amount, "a position never claims more than it was handed");
            placed += back;
        }
        assertLe(ENTRY_ASK_AMPS - placed, 1e10, "only dust is left unplaced");
    }

    /* -------------------------------------------- refusals -------------------------------------------- */

    function test_revert_zeroInventory() public {
        int24 anchor = _entryAnchor();
        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("inventory")));
        _propose(anchor, anchor, ENTRY_SPACING, DOUBLINGS, 0, true);
    }

    function test_revert_tiltOutsideItsBand() public {
        int24 anchor = _entryAnchor();
        ILadderPolicy.LadderRequest memory request = ILadderPolicy.LadderRequest({
            anchorTick: anchor,
            currentTick: anchor,
            tickSpacing: ENTRY_SPACING,
            buckets: DOUBLINGS,
            tiltX18: Constants.LADDER_TILT_X18_MIN - 1,
            inventory: ENTRY_ASK_AMPS,
            above: true
        });
        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("tilt")));
        policy.propose(request);

        request.tiltX18 = Constants.LADDER_TILT_X18_MAX + 1;
        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("tilt")));
        policy.propose(request);
    }

    function test_revert_bucketCountOutsideItsBand() public {
        int24 anchor = _entryAnchor();
        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("buckets")));
        _propose(anchor, anchor, ENTRY_SPACING, Constants.LADDER_DOUBLINGS_MIN - 1, ENTRY_ASK_AMPS, true);

        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("buckets")));
        _propose(anchor, anchor, ENTRY_SPACING, Constants.LADDER_DOUBLINGS_MAX + 1, ENTRY_ASK_AMPS, true);

        // A five-bucket *bid* ladder is legal even though a five-bucket ask ladder is not: the bands differ.
        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("buckets")));
        _propose(anchor, anchor, ENTRY_SPACING, Constants.HALVINGS_MAX + 1, SEED_BID_USDG, false);
        ILadderPolicy.LadderBucket[] memory ok = _propose(anchor, anchor, ENTRY_SPACING, 5, SEED_BID_USDG, false);
        assertEq(ok.length, 5, "five halvings are inside the bid band");
    }

    function test_revert_badTickSpacing() public {
        int24 anchor = _entryAnchor();
        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("tickSpacing")));
        _propose(anchor, anchor, 0, DOUBLINGS, ENTRY_ASK_AMPS, true);

        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("tickSpacing")));
        _propose(anchor, anchor, TickMath.MAX_TICK_SPACING + 1, DOUBLINGS, ENTRY_ASK_AMPS, true);
    }

    /// @dev A ladder that does not fit above (or below) its anchor is refused, never silently truncated: the
    ///      clamped bucket would collapse to zero width against `TickMath`'s usable range.
    function test_revert_degenerateBucketAtTheTickExtremes() public {
        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("degenerateBucket")));
        _propose(TickMath.MAX_TICK, TickMath.MAX_TICK, ENTRY_SPACING, DOUBLINGS, ENTRY_ASK_AMPS, true);

        vm.expectRevert(abi.encodeWithSelector(ILadderPolicy.LadderNotPlaceable.selector, bytes32("degenerateBucket")));
        _propose(TickMath.MIN_TICK, TickMath.MIN_TICK, ENTRY_SPACING, HALVINGS, SEED_BID_USDG, false);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `AMPS/USDG` at $1.00 with USDG at $1.00 and 6 decimals, on the entry pools' spacing.
    function _entryAnchor() private view returns (int24) {
        return price.fairTick(1e18, 1e8, 6, ENTRY_SPACING);
    }

    /// @dev A spoke at `tickOf(P_ref / P_stock)` with AMPS at $1.00 and the stock at $180, 18 decimals.
    function _spokeAnchor() private view returns (int24) {
        return price.fairTick(1e18, 180e8, 18, SPOKE_SPACING);
    }

    function _propose(
        int24 anchorTick,
        int24 currentTick,
        int24 tickSpacing,
        uint8 buckets,
        uint256 inventory,
        bool above
    ) private view returns (ILadderPolicy.LadderBucket[] memory) {
        return policy.propose(
            ILadderPolicy.LadderRequest({
                anchorTick: anchorTick,
                currentTick: currentTick,
                tickSpacing: tickSpacing,
                buckets: buckets,
                tiltX18: TILT,
                inventory: inventory,
                above: above
            })
        );
    }

    function _assertMatchesLibrary(int24 anchor, int24 spacing, uint8 n, uint256 inventory, bool above) private view {
        ILadderPolicy.LadderBucket[] memory buckets = _propose(anchor, anchor, spacing, n, inventory, above);
        (int24[] memory lowers, int24[] memory uppers, uint128[] memory liquidities) =
            ladder.ladderAmounts(anchor, spacing, n, TILT, inventory, above);

        for (uint256 k = 0; k < n; ++k) {
            assertEq(buckets[k].lowerTick, lowers[k], "lower tick matches the library");
            assertEq(buckets[k].upperTick, uppers[k], "upper tick matches the library");
            assertEq(buckets[k].liquidity, liquidities[k], "liquidity matches the library");
        }
        assertEq(_sum(buckets), inventory, "the amounts sum to the inventory exactly");
    }

    function _sum(ILadderPolicy.LadderBucket[] memory buckets) private pure returns (uint256 total) {
        for (uint256 k = 0; k < buckets.length; ++k) {
            total += buckets[k].amount;
        }
    }
}
