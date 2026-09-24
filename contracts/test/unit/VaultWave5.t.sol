// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IFeedRegistry} from "../../src/interfaces/IFeedRegistry.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Constants} from "../../src/types/Constants.sol";
import {CollateralSetFull, NavBleedExceeded, NotInitialized, SpokeUnpriceable} from "../../src/types/Errors.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {PlacementFixture} from "../mocks/PlacementFixture.sol";
import {GasBurningGate, MalformedLadderPolicy, ShavingValuer} from "../mocks/Wave5Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title VaultWave5Test
/// @notice The revision-8 audit's nine findings and the leads taken with them (`docs/audits/fix-log.md`, wave 5).
///
/// @dev One `test_w5_NN_*` per finding, one `test_w5_LN_*` per lead that takes a test of its own. Leads whose
///      subject already has a home — the fizz properties, the deployment scripts — are asserted there instead and
///      named in the fix log.
contract VaultWave5Test is PlacementFixture {
    /// @dev `keccak256("amplestocks.vault.pendingInventoryBurn")`, `...burnStreamStart`, `...burnStreamLastSettle`.
    bytes32 private constant PENDING_BURN_SLOT = keccak256("amplestocks.vault.pendingInventoryBurn");
    bytes32 private constant BURN_STREAM_START_SLOT = keccak256("amplestocks.vault.burnStreamStart");
    bytes32 private constant BURN_STREAM_LAST_SETTLE_SLOT = keccak256("amplestocks.vault.burnStreamLastSettle");

    /// @dev `TickMath.getSqrtPriceAtTick(0)`, i.e. 1:1, for the hookless pools the collateral-cap test opens.
    uint160 private constant FLAT_SQRT_PRICE_X96 = 79_228_162_514_264_337_593_543_950_336;

    function setUp() public {
        deployPlacementWorld();
        placeGenesisLadders();
        giveShares(ALICE, 1500e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Finding 1 — the R1 bleed bound is measured across the burn stream's settlement
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Finding 1.** `navBefore` came from `_previewNav()`, which divides by the live `totalSupply()`,
    ///         while `navAfter` comes from `_checkpoint()`, whose first statement settles the redemption burn
    ///         stream and burns AMPS. The two sides of the 2 bp post-condition therefore divided by different
    ///         supplies, and any pending stream widened the admitted bleed by `burned / T` — on all five
    ///         placement entry points, three of them permissionless.
    ///
    /// @dev The bleed itself is manufactured, and it has to be: every real mechanism the fixture can reach moves
    ///      `A` by thousandths of a basis point against a 2 bp bound (the creator's counter-side slice of a $100
    ///      swap's fee is six cents against an `A` of $20,000). {ShavingValuer} takes a fixed number of counter
    ///      wei off one pool's position value once that pool has been placed into in this block, which is a fact
    ///      the *placement* establishes and the stream's settlement does not — so the shave lands on `navAfter`
    ///      and not on `navBefore`, which is exactly the asymmetry R1 is meant to catch.
    ///
    /// @dev The assertion is that the two sequences are indistinguishable. Before the fix the pending stream paid
    ///      for the bleed: one hour into a 24-hour window the settled amount is ~4% of the queue, which is
    ///      multiples of the 2 bp bound, so the same placement passed with a stream standing and failed without
    ///      one.
    function test_w5_01_theBleedBoundIsMeasuredAcrossTheSettledSupply() public {
        _tradeForFees();
        uint256 shaveWei = _shaveForTenBpOfA();
        assertGt(shaveWei, 0, "there is a position value to shave");

        ShavingValuer shaver = new ShavingValuer(address(valuer), address(vault));
        shaver.arm(hubPool, shaveWei);
        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("positionValuer"), address(shaver));
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        uint256 snapshot = vm.snapshotState();

        // (a) A burn stream with an hour of it accrued. The state is written rather than produced by a redemption
        //     and a warp, so that the *only* difference between the two branches is the stream: no time passes,
        //     no feed ages, no trading session turns over and the due amount is exactly `P x 1h / 24h`.
        //     `test_w5_02` and `test_w5_03` are what show a real redemption reaches this state.
        uint256 pending = 800e18;
        assertGe(amps.balanceOf(address(vault)), pending, "the vault can actually pay the settlement");
        _forceStream(pending, block.timestamp - 1 hours, block.timestamp - 1 hours);

        uint256 wouldSettle = pending * 1 hours / Constants.REDEEM_BURN_STREAM_SECONDS;
        emit log_named_uint("finding 1: pending stream", pending);
        emit log_named_uint("finding 1: the settlement the old navAfter was credited with", wouldSettle);
        assertGt(
            wouldSettle * Constants.BPS / amps.totalSupply(),
            Constants.PLACEMENT_BLEED_BPS_MAX,
            "the stream alone is worth more than the whole R1 bound, which is the finding"
        );

        vm.prank(KEEPER);
        vm.expectPartialRevert(NavBleedExceeded.selector);
        vault.compound(hubPool);

        // (b) The identical call with no stream at all.
        vm.revertToState(snapshot);
        assertEq(vault.pendingInventoryBurn(), 0, "no stream in this branch");

        vm.prank(KEEPER);
        vm.expectPartialRevert(NavBleedExceeded.selector);
        vault.compound(hubPool);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Finding 2 — a dust redemption may not re-date the whole inventory-burn window
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Finding 2.** The window's opening is now the **amount-weighted** one, so a queue moves the
    ///         deadline in proportion to what it adds: a dust queue by dust, a queue equal to the pending amount
    ///         half way. Restarting at `block.timestamp` for the combined amount let a few tens of wei of shares
    ///         push an arbitrarily large outstanding burn out by a full day, once per block.
    function test_w5_02_aQueueMovesTheDeadlineInProportionToWhatItAdds() public {
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        uint256 openedAt = vault.burnStreamStart();
        assertEq(openedAt, block.timestamp, "the first queue opens the window here");

        warpBy(1 hours);

        // (a) A redemption too small to release anything queues nothing, and a queue of nothing does not touch
        //     the window at all. One wei of shares is below the floor division's threshold once finding 4's
        //     netting has taken the standing queue out of the pro-rata base.
        giveShares(BOB, 1);
        vm.prank(BOB);
        vault.redeemProRata(1, BOB);
        assertEq(vault.burnStreamStart(), openedAt, "a redemption that queued nothing left the window where it was");

        // (b) A dust queue moves the deadline by dust. A micro-AMPS of shares against a supply of ~19,000 AMPS
        //     releases ~1e-11 of the inventory, and that used to be enough to re-date the whole window by a day.
        uint256 supplyBefore = amps.totalSupply();
        uint256 pendingBefore = vault.pendingInventoryBurn();
        giveShares(BOB, 1e12);
        vm.prank(BOB);
        vault.redeemProRata(1e12, BOB);

        uint256 settled = supplyBefore - amps.totalSupply() - 1e12;
        uint256 survived = pendingBefore - settled;
        uint256 added = vault.pendingInventoryBurn() - survived;
        assertGt(added, 0, "the dust redemption really did queue something");

        uint256 openedNow = vault.burnStreamStart();
        // The two `floor`s in the weighting can lose one second between them, in the protocol-favourable
        // direction (earlier), so the move is measured saturating rather than as a bare subtraction.
        uint256 moved = openedNow > openedAt ? openedNow - openedAt : 0;
        emit log_named_uint("finding 2: dust queue", added);
        emit log_named_uint("finding 2: pending it was added to", survived);
        emit log_named_uint("finding 2: seconds the deadline moved", moved);

        assertEq(openedNow, _weightedStart(openedAt, survived, added), "the amount-weighted opening");
        assertGe(openedNow + 1, openedAt, "and never earlier than the rounding's own one second");
        assertLe(
            moved,
            uint256(Constants.REDEEM_BURN_STREAM_SECONDS) * added / survived + 1,
            "a dust queue moves the deadline by at most D x a / P seconds"
        );
        assertLt(moved, 1 hours, "and by strictly less than the time that had elapsed");

        // (c) A queue equal to the pending amount moves the opening exactly half way.
        //
        // The queue a redemption produces falls as the pending amount rises (finding 4's netting), so the fixed
        // point is solved rather than guessed: with `a(X) = floor((inventory - X) x s / T) + releasedAmps`, one
        // pass at `X = 0` gives `a(0)` and `X* = a(0) x T / (T + s)` is where `a(X) == X`.
        uint256 snapshot = vm.snapshotState();
        _forceStream(0, block.timestamp, block.timestamp);
        uint256 supply = amps.totalSupply();
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        uint256 atZero = vault.pendingInventoryBurn();
        vm.revertToState(snapshot);

        uint256 target = FullMath.mulDiv(atZero, supply, supply + 500e18);
        uint256 windowOpenedAt = block.timestamp - 3 hours;
        // `lastSettle == now` makes the settlement that precedes the queue burn nothing, so the pending amount
        // the queue is weighted against is exactly `target`.
        _forceStream(target, windowOpenedAt, block.timestamp);

        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        uint256 queued = vault.pendingInventoryBurn() - target;
        assertApproxEqAbs(queued, target, 8, "the queue equals the pending amount, by construction");
        assertApproxEqAbs(
            vault.burnStreamStart(), windowOpenedAt + 3 hours / 2, 3, "so the opening moved exactly half way"
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // Finding 3 — a settlement the idle cap truncated may not advance the clock
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Finding 3.** `burnStreamLastSettle` is where the "remaining amount over the remaining time" line
    ///         is re-anchored, so stamping it for a settlement the idle balance could not pay re-sloped the queue
    ///         over a shorter window and suppressed the burn. `checkpoint()` is permissionless and free, so one
    ///         call per block held the whole stream back.
    function test_w5_03_aCappedSettlementDoesNotAdvanceTheClock() public {
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        uint256 queued = vault.pendingInventoryBurn();
        assertGt(queued, 0, "something is queued");

        // Zero idle AMPS: the steady state, because the POL lives inside ladders and the placement path does not
        // exclude the queue from its inventory bound.
        uint256 idle = amps.balanceOf(address(vault));
        deal(address(amps), address(vault), 0);

        uint256 snapshot = vm.snapshotState();

        // (a) A free `checkpoint()` at half the window, and *then* inventory arrives.
        warpBy(Constants.REDEEM_BURN_STREAM_SECONDS / 2);
        vault.checkpoint();
        assertEq(vault.pendingInventoryBurn(), queued, "the capped settlement burned nothing");
        deal(address(amps), address(vault), idle);
        uint256 supplyBefore = amps.totalSupply();
        vault.checkpoint();
        uint256 withCheckpoint = supplyBefore - amps.totalSupply();

        // (b) The same instant, with nobody having checkpointed in between.
        vm.revertToState(snapshot);
        warpBy(Constants.REDEEM_BURN_STREAM_SECONDS / 2);
        deal(address(amps), address(vault), idle);
        supplyBefore = amps.totalSupply();
        vault.checkpoint();
        uint256 withoutCheckpoint = supplyBefore - amps.totalSupply();

        emit log_named_uint("finding 3: burned after a suppressing checkpoint", withCheckpoint);
        emit log_named_uint("finding 3: burned with no checkpoint in between", withoutCheckpoint);
        assertGt(withoutCheckpoint, 0, "half a window is really due");
        assertEq(withCheckpoint, withoutCheckpoint, "a capped settlement costs the stream nothing at all");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Finding 4 — the redemption's inventory base double-counted the pending queue
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Finding 4.** AMPS an earlier redemption already queued was re-sliced by every later one inside
    ///         the window. Two same-block redemptions must queue what one redemption of the sum queues, and the
    ///         preview must still equal the payout to the wei with a stream standing.
    function test_w5_04_theInventoryBaseIsNettedOfThePendingQueue() public {
        uint256 snapshot = vm.snapshotState();

        vm.startPrank(ALICE);
        vault.redeemProRata(250e18, ALICE);
        vault.redeemProRata(250e18, ALICE);
        vm.stopPrank();
        uint256 sliced = vault.pendingInventoryBurn();

        vm.revertToState(snapshot);
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        uint256 once = vault.pendingInventoryBurn();

        emit log_named_uint("finding 4: queued by two slices", sliced);
        emit log_named_uint("finding 4: queued by one exit of the sum", once);
        // The un-netted base over-queued by `pending x shares / T` per slice, which at these sizes is ~60 bp.
        assertApproxEqRel(sliced, once, 0.002e18, "two slices queue what one exit of the sum queues");
        assertLe(sliced, once, "and never more");

        // The preview and the payout with a stream in flight.
        warpBy(1 hours);
        (address[] memory tokens, uint256[] memory preview, uint256 release) = vault.previewRedeem(200e18);
        uint256 pendingBefore = vault.pendingInventoryBurn();
        uint256 supplyBefore = amps.totalSupply();

        vm.prank(ALICE);
        (, uint256[] memory paid) = vault.redeemProRata(200e18, ALICE);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(paid[i], preview[i], "preview == payout across a non-zero pending queue");
        }
        uint256 settled = supplyBefore - amps.totalSupply() - 200e18;
        assertGt(settled, 0, "the hour that elapsed really was settled on the way in");
        // No pool has traded in this branch, so the unwind realises no AMPS-side fees and the queue is the
        // preview's figure exactly (lead L-13 adds the fees when there are any).
        assertEq(vault.pendingInventoryBurn(), pendingBefore - settled + release, "and the queue is the preview's");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Finding 5 — `compound`'s bid re-ladder anchors at the reference
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Finding 5.** With the pool above a rate-limited reference, a bid ladder anchored at `slot0.tick`
    ///         straddles `sqrtPrice(P_ref / P_counter)`, which is the price `LadderPositionValuer` decomposes
    ///         every position at (I7) — so the valuer writes the AMPS half of the straddled cell off at zero (I5)
    ///         and R1 reverts the permissionless upkeep path in exactly the dislocated state it exists for.
    function test_w5_05_compoundAnchorsItsBidLadderAtTheReference() public {
        // Walk the hub up and let `P_mkt` follow, but not `P_ref`: the upward rate limit is 10% an hour and no
        // time passes, so the reference stays where it was and the pool sits well above it.
        buyAmps(hubPool, address(usdg), 900e6);
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        int24 refTick = _exactReferenceTick(USDG_USD8, 6);
        int24 poolTick = tickOf(hubPool);
        emit log_named_int("finding 5: pool tick", poolTick);
        emit log_named_int("finding 5: reference tick", refTick);
        assertGt(poolTick - refTick, 1000, "the pool is far above the reference");

        uint256 bidsBefore = _bidCellCount(hubPool);
        vm.prank(KEEPER);
        (uint256 ampsFees,) = vault.compound(hubPool);
        ampsFees;

        PlacementRecord[] memory records = ladderOf(hubPool);
        uint256 touched;
        for (uint256 i; i < records.length; ++i) {
            if (records[i].above || records[i].liquidity == 0) continue;
            if (records[i].placedAt != uint32(block.timestamp)) continue;
            ++touched;
            // The tolerance is `_cells`' own one tick spacing (audit fix R10; wave-5 lead L-8 proposed removing
            // it and was measured and not taken). Sixty ticks against a cell 6,960 wide is what the anchor gives
            // away; the 1,500 ticks the live tick would have cost is what it takes back.
            assertLe(
                records[i].upperTick,
                refTick + TICK_SPACING,
                "every cell this compound bid into is at or below P_ref, to the anchor's one-spacing residue"
            );
        }
        assertGt(touched, 0, "the compound really re-laddered its counter side as bids");
        assertGe(_bidCellCount(hubPool), bidsBefore, "and the bid ladder did not shrink");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Finding 6 — a stranded idle balance may not veto the migration it triggered
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Finding 6.** `navBefore` counts the vault's idle ERC-20 balances, `evacuate` moves them with a
    ///         best-effort transfer the denylisting token refuses, and `navAfter` used to be measured on the
    ///         standby alone — so an issuer who blocks the vault and leaves a percent of `A` on it as an idle
    ///         balance made the 50 bp bound revert the evacuation it had itself provoked.
    function test_w5_06_aStrandedIdleBalanceDoesNotVetoTheMigration() public {
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);
        matureStandby();

        // About 1.8% of `A` ($20,000) left on the vault as an idle balance of a constituent, and then the
        // constituent denylists the vault — which is both the thing that strands the balance and the thing that
        // unlocks the migration.
        uint256 stranded = 2e18;
        stocks[0].mint(address(vault), stranded);
        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[0].blockAccounts(blocked);

        uint256 strandedUsd18 = stranded * uint256(STOCK_USD8[0]) * 1e10 / 1e18;
        emit log_named_uint("finding 6: stranded USD18", strandedUsd18);
        assertGt(
            strandedUsd18 * Constants.BPS / vault.totalAssetsUsd18(),
            Constants.MIGRATION_BLEED_BPS_MAX,
            "the stranded balance alone is worth more than the whole migration bound"
        );

        vm.recordLogs();
        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        assertEq(IERC20(address(stocks[0])).balanceOf(address(vault)), stranded, "the balance really did stay put");
        assertTrue(_sawResidue(address(stocks[0]), stranded), "and `SweepResidue` names the token and the exact amount");
        assertEq(amps.vault(), STANDBY, "the migration completed and the roles moved");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Finding 7 — the per-pool gate read is bounded at the gate's own budget
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Finding 7.** `checkPlacement` used to be capped at `COMPOSITE_READ_GAS` (400,000) while the
    ///         protocol-wide read of the same gate had 1,500,000 — below what an honest `OracleGate` spends when
    ///         a constituent's Stock Token burns its four probes. The gate refuses by reverting, so a starved
    ///         read is a refusal: `place` and `compound` closed for that pool at the issuer's choosing.
    function test_w5_07_theGateReadIsCappedAtTheGateBudget() public {
        // 450,000 is past the old cap and far inside the new one.
        GasBurningGate tolerable = new GasBurningGate(450_000);
        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("oracleGate"), address(tolerable));
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.prank(KEEPER);
        vault.compound(hubPool);

        // 1,600,000 is past the new one, and the placement fails rather than the gate taking the caller's frame.
        GasBurningGate intolerable = new GasBurningGate(1_600_000);
        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("oracleGate"), address(intolerable));
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        vm.prank(KEEPER);
        vm.expectRevert();
        vault.compound(hubPool);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Finding 8 — the live-cell ratchet, accepted; the accounting, asserted
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Finding 8, the reading taken.** A bid cell the price has fallen through holds the AMPS the bid
    ///         bought, and §3.4's symmetric-proceeds rule is that it re-sells on the way back up: §3.5 says in
    ///         terms that a fully crossed bid is not a buyback, it was already finding 15 on 2026-09-08, and §10
    ///         ruling AZ dispositioned the lead as accepted. The economics are therefore unchanged and the
    ///         consequence — a live-cell count that ratchets — is accepted with its arithmetic stated.
    ///
    /// @dev What *is* asserted here is the part a ratchet could hide: that the vault's own live-cell counter is
    ///      exact after a compound opens a cell, so no cell whose liquidity has rounded to zero is being counted
    ///      as live, and that the budget covers the launch shape with the worst case named.
    function test_w5_08_theLiveCellCountIsExactAndTheRatchetIsBounded() public {
        assertEq(vault.liveCells(), countLiveCells(), "the counter starts exact");

        _tradeForFees();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        vault.compound(hubPool);
        assertEq(vault.liveCells(), countLiveCells(), "and is exact after a compound re-ladders its counter side");

        vm.prank(ALICE);
        vault.redeemProRata(1500e18, ALICE);
        assertEq(vault.liveCells(), countLiveCells(), "and after a redemption removes from every cell");

        // The arithmetic the disposition rests on.
        uint256 pools = uint256(Constants.MAX_CONSTITUENTS) + 2;
        assertEq(uint256(Constants.GRID_CELLS) * pools, 864, "24 grid cells x 36 pools is the worst case");
        assertGt(uint256(Constants.GRID_CELLS) * pools, Constants.MAX_LIVE_CELLS, "which is past the 512-cell budget");
        assertLe(
            (uint256(Constants.LADDER_DOUBLINGS_DEFAULT) + Constants.SEED_HALVINGS_DEFAULT) * pools,
            Constants.MAX_LIVE_CELLS,
            "while the launch shape the budget is derived from fits inside it"
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // Finding 9 — the pre-genesis latch on the five forwarders
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Finding 9.** `checkpoint()` and `touch()` refuse before genesis with `NotInitialized`, but the
    ///         five placement forwarders reached the same `_checkpoint()` through `_afterPlacement` without it —
    ///         so with the gate pointer deliberately unset in that window an unprivileged call could stamp
    ///         `checkpointTimestamp`/`checkpointBlock` over a supply that has no `A` behind it and remove the
    ///         `StaleCheckpoint` backstop `depositBonded` documents.
    ///
    /// @dev The fixture's world cannot be built without genesis — pools are registered against `pRefX18()` and
    ///      the ladders are placed out of the POL tranche — so the pre-genesis state is reproduced by clearing
    ///      the one-way latch in slot 3, which is the state the deploy script passes through between
    ///      `genesisMint` and `genesisPlace`.
    function test_w5_09_theForwardersRefuseBeforeGenesis() public {
        uint256 slot3 = uint256(vm.load(address(vault), bytes32(uint256(3))));
        vm.store(address(vault), bytes32(uint256(3)), bytes32(slot3 & ~(uint256(0xff) << 192)));
        assertFalse(vault.initialized(), "the pre-genesis state");

        vm.prank(KEEPER);
        vm.expectRevert(NotInitialized.selector);
        vault.compound(hubPool);

        vm.prank(TIMELOCK);
        vm.expectRevert(NotInitialized.selector);
        vault.place(hubPool, true, 1e18);

        vm.store(address(vault), bytes32(uint256(3)), bytes32(slot3));
        assertTrue(vault.initialized(), "and the latch restored");
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-2 — a malformed ladder policy falls through to `LadderLib`
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-2.** A `uint256[]` return is a dynamic type, so a typed `try` decodes an offset, a length
    ///         and a bounds check **in the caller's frame** — every one of them a `Panic` the `catch` cannot
    ///         reach. Each shape below used to revert `place`, `compound`, `rollout`, `deployBonded` and every
    ///         genesis ladder from a pointer-upgradeable policy.
    function test_w5_L2_aMalformedLadderPolicyFallsThroughToLadderLib() public {
        MalformedLadderPolicy policy = new MalformedLadderPolicy();
        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("ladderPolicy"), address(policy));

        bytes[] memory shapes = new bytes[](5);
        // Empty returndata: the codeless-pointer shape.
        shapes[0] = "";
        // A head that is not 0x20.
        shapes[1] = abi.encodePacked(uint256(0x40), uint256(4), uint256(0), uint256(0), uint256(0), uint256(0));
        // A length header that does not match the words that follow.
        shapes[2] = abi.encodePacked(uint256(0x20), uint256(2), uint256(1), uint256(1), uint256(1), uint256(1));
        // A length that would run off the end of the world.
        shapes[3] = abi.encodePacked(uint256(0x20), type(uint256).max, uint256(0), uint256(0), uint256(0), uint256(0));
        // Well formed, and two enormous numbers that overflow the sum.
        shapes[4] =
            abi.encodePacked(uint256(0x20), uint256(4), type(uint256).max, type(uint256).max, uint256(0), uint256(0));

        for (uint256 i; i < shapes.length; ++i) {
            policy.setAnswer(shapes[i]);
            _placeSeedBidAndUndo(string.concat("malformed shape ", vm.toString(i)));
        }

        policy.setReverts();
        _placeSeedBidAndUndo("a policy that reverts");
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-3 — the standby vault's 14-day tier, on chain
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-3.** `Constants.TIMELOCK_STANDBY_SECONDS` was read by no contract: the address a no-delay
    ///         guardian call hands five `onlyVault` roles and the whole estate to needed only the timelock's own
    ///         48-hour `minDelay`.
    function test_w5_L3_theStandbyTierIsEnforcedOnChain() public {
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);
        uint32 registeredAt = uint32(block.timestamp);

        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[0].blockAccounts(blocked);

        vm.prank(GUARDIAN);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAmpsVault.StandbyNotMatured.selector,
                registeredAt,
                uint256(registeredAt) + Constants.TIMELOCK_STANDBY_SECONDS
            )
        );
        vault.emergencyMigrate(STANDBY);

        // Two days short — the timelock's own delay — is still short.
        vm.warp(uint256(registeredAt) + Constants.TIMELOCK_STANDBY_SECONDS - 1);
        vm.prank(GUARDIAN);
        vm.expectPartialRevert(IAmpsVault.StandbyNotMatured.selector);
        vault.emergencyMigrate(STANDBY);

        vm.warp(uint256(registeredAt) + Constants.TIMELOCK_STANDBY_SECONDS);
        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);
        assertEq(amps.vault(), STANDBY, "at fourteen days the guardian may migrate");
    }

    /// @notice And a re-registration restarts the clock, because a fresh standby is a fresh fourteen days.
    function test_w5_L3_reRegisteringTheStandbyRestartsTheTier() public {
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);
        matureStandby();

        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);

        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[0].blockAccounts(blocked);

        vm.prank(GUARDIAN);
        vm.expectPartialRevert(IAmpsVault.StandbyNotMatured.selector);
        vault.emergencyMigrate(STANDBY);
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-5 — an absorb whose credit disagrees with what was moved is disclosed
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-5.** `sweepClean`'s residue probe reads the *vault's* balance, so a token that accepts the
    ///         transfer into the PoolManager and then makes the credit come out wrong left the wei uncredited
    ///         with no event at all. v4's `sync` is not `onlyWhenUnlocked`, so the token can do it from inside its
    ///         own `transfer` simply by re-snapshotting the reserves the settlement is measured against.
    function test_w5_L5_anUncreditedAbsorbIsDisclosed() public {
        uint256 donated = 5e18;
        stocks[0].mint(address(vault), donated);
        stocks[0].setReentrancy(
            2, address(poolManager), abi.encodeCall(IPoolManager.sync, (Currency.wrap(address(stocks[0]))))
        );

        uint256 claimBefore = claimOf(address(stocks[0]));
        vm.recordLogs();
        vault.checkpoint();

        assertEq(IERC20(address(stocks[0])).balanceOf(address(vault)), 0, "the transfer went through");
        assertEq(claimOf(address(stocks[0])), claimBefore, "and nothing was credited for it");
        assertTrue(_sawResidue(address(stocks[0]), donated), "the shortfall is named rather than silent");
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-6 — the registered asset list has a ceiling
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-6.** `Constants.MAX_COLLATERALS` is the figure the redemption floor's one-transaction gas
    ///         proof is asserted at, and it had three writers and no reader.
    function test_w5_L6_theAssetListRefusesPastTheCollateralCap() public {
        uint256 have = vault.assetCount();
        assertLt(have, Constants.MAX_COLLATERALS, "the fixture starts under the cap");

        for (uint256 i = have; i < Constants.MAX_COLLATERALS; ++i) {
            // The key is built before the prank, because `vm.prank` covers the next call *or create* and
            // `_hooklessKey` deploys the counter.
            PoolKey memory key = _hooklessKey();
            vm.prank(address(registry));
            vault.initializePool(key, FLAT_SQRT_PRICE_X96);
        }
        assertEq(vault.assetCount(), Constants.MAX_COLLATERALS, "the list is full");

        // And the same for the one that must be refused: a `CREATE` would otherwise be the call `vm.expectRevert`
        // was watching for.
        PoolKey memory overflowing = _hooklessKey();
        vm.prank(address(registry));
        vm.expectRevert(abi.encodeWithSelector(CollateralSetFull.selector, Constants.MAX_COLLATERALS));
        vault.initializePool(overflowing, FLAT_SQRT_PRICE_X96);
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-7 — the spoke weight uses the checkpoint's own supply
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-7.** `A` was reconstructed as `navPerShareX18 x (live totalSupply + VIRTUAL_SHARES)`, so
    ///         every burn and vesting mint between checkpoints biased every spoke's weight — and the
    ///         inventory-burn stream moves `T` continuously for a day after any redemption. The weight feeds the
    ///         bond discount's index-deficit term and the rollout schedule.
    function test_w5_L7_theSpokeWeightUsesTheCheckpointsOwnSupply() public {
        bondDeposit(address(stocks[0]), 20e18);
        vault.checkpoint();
        uint16 before = vault.spokeWeightBps(constituentIds[0]);
        assertGt(before, 0, "the spoke has a weight to bias");

        // A burn with no checkpoint behind it: exactly what the stream's settlement does every time anybody
        // touches the protocol in the day after a redemption.
        uint256 supplyBefore = amps.totalSupply();
        vm.prank(address(vault));
        amps.burn(ALICE, 1000e18);
        assertLt(amps.totalSupply(), supplyBefore, "the supply really moved");

        assertEq(vault.spokeWeightBps(constituentIds[0]), before, "and the weight did not");

        // Which is the whole of the lead: the supply the reconstruction multiplies by is the one the checkpointed
        // NAV was divided by, and the burn moved the live supply away from it by 5.3%. The bias fed straight into
        // the bond discount's index-deficit term and the rollout schedule, and the stream moves `T` continuously
        // for a day after any redemption.
        uint256 stored = _checkpointSupply();
        assertEq(stored, supplyBefore, "the stamp is the checkpoint's own supply");
        assertLt(amps.totalSupply(), stored, "and the live supply has moved away from it");

        // A checkpoint re-stamps it, so the pair is always one checkpoint's.
        vault.checkpoint();
        assertEq(_checkpointSupply(), amps.totalSupply(), "a checkpoint writes the supply beside the NAV");
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-8 — the top bid cell never straddles the reference
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-8 (R10's residue): considered, measured and not taken.** The lead is that the bid
    ///         anchor's `+ tickSpacing` term can leave the top bid cell's upper bound up to one tick spacing
    ///         **above** the exact reference, where `LadderPositionValuer` splits the cell and writes its AMPS
    ///         half off at zero (I5). That is true. The replacement — floor the *unaligned* reference tick
    ///         straight onto the doubling grid — makes the bound unconditional and costs a whole **doubling**
    ///         whenever the reference sits inside one tick spacing below a cell boundary, which at genesis is
    ///         systematic rather than rare: a pool opens at `alignDown(refTick)` (§12 ruling C), `P_mkt` is then
    ///         that pool's own TWAP, and the round trip through three flooring conversions lands the reference on
    ///         `gridBaseTick - 1`. This pins both halves of the disposition.
    function test_w5_L8_theBidAnchorKeepsItsOneSpacingTolerance() public {
        int24 base = gridBaseOf(hubPool);
        int24 width = cellWidth();

        // Two references, both inside one tick spacing of the cell boundary the pool is sitting on:
        //   * 35 ticks **above** the origin — the genesis geometry, where the seed bids must stay at
        //     `m = -1..-4`; and
        //   * one tick **below** it — the round-trip artefact, where the zero-tolerance rule would put the
        //     ladder a whole doubling lower and break §3.3.
        int24[2] memory targets = [base + 35, base - 1];
        for (uint256 i; i < targets.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            _forceReferenceAtTick(targets[i]);
            int24 exact = _exactReferenceTick(USDG_USD8, 6);

            usdg.mint(address(vault), 2000e6);
            vm.prank(TIMELOCK);
            assertGt(vault.place(hubPool, false, 2000e6), 0, "the bid ladder was laid");

            PlacementRecord[] memory records = ladderOf(hubPool);
            int24 top = type(int24).min;
            for (uint256 j; j < records.length; ++j) {
                if (records[j].above || records[j].liquidity == 0) continue;
                if (records[j].placedAt != uint32(block.timestamp)) continue;
                if (records[j].upperTick > top) top = records[j].upperTick;
            }
            emit log_named_int("lead L-8: exact reference tick", exact);
            emit log_named_int("lead L-8: top bid cell this placement chose", top);

            // The ladder sits on the grid origin in both cases, which is the `m = -1..-4` shape §3.3 specifies
            // and `script/11_GenesisPlacement.s.sol::assertLayout` enforces at launch.
            assertEq(top, base, "the ladder sits on the grid origin, not a doubling below it");
            // The residue is one-sided and bounded by a tick spacing — the same size and shape as the ask side's
            // accepted residue (ruling AX) — against a cell `width` ticks wide.
            assertLe(top, exact + TICK_SPACING, "and is never more than one tick spacing above the reference");
            assertGt(int256(width), int256(100) * int256(TICK_SPACING), "which is a rounding against the cell");
            vm.revertToState(snapshot);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-9 — an unreadable reference refuses asks and leaves bids their fallback
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-9.** The same `answerUsd8 == 0` used to skip the divergence check *and* anchor asks at the
    ///         live tick, which is what I32 forbids and exactly what a counter feed can be pushed into by being
    ///         made unreadable. Bids keep the fallback: anchoring a bid at the live tick can only lay it below the
    ///         market, which is where a bid belongs.
    function test_w5_L9_anUnreadableReferenceRefusesAsksAndLeavesBidsAlone() public {
        address stock = address(stocks[0]);
        // The vault holds none of this constituent, so `A` skips it entirely and only the placement path sees the
        // unreadable answer.
        assertEq(IERC20(stock).balanceOf(address(vault)), 0, "no idle balance to price");
        assertEq(claimOf(stock), 0, "and no claim either");
        vm.mockCall(
            address(feeds),
            abi.encodeCall(IFeedRegistry.latestAnswer, (stock)),
            abi.encode(uint256(0), uint32(0), false)
        );

        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(SpokeUnpriceable.selector, constituentIds[0], bytes32("refTick")));
        vault.place(spokePools[0], true, 1e18);

        // The bid side is not refused by the same condition.
        vm.prank(TIMELOCK);
        vault.place(spokePools[0], false, 0);

        // And with the answer back, the ask places as it always did.
        vm.clearMockedCalls();
        vm.prank(TIMELOCK);
        assertGt(vault.place(spokePools[0], true, 1e18), 0, "a readable reference places the ask");
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-10 — the redemption tail, and the sweep's absorb guard
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-10.** `sweepClean` runs at the exit of `redeemProRata`, and an absorb is three bounded
    ///         calls plus an `unlock` against a probe that costs ~3k. Sizing the payout reserve for
    ///         `MAX_COLLATERALS` absorbs would hold back tens of millions of gas the redemption then could not
    ///         spend, so the absorb is conditioned on the frame — and the probe and the disclosure still run, so
    ///         a skipped absorb is reported exactly like a refused one.
    function test_w5_L10_theSweepSkipsAndDisclosesAnAbsorbItCannotAfford() public {
        uint256 donated = 3e18;
        stocks[0].mint(address(vault), donated);

        // A frame strictly below the guard, so the absorb cannot run whatever the gate reads cost, and still
        // far more than the call needs to finish: `touch()` is a gate poke, one gate read and the sweep's four
        // bounded balance probes.
        vm.recordLogs();
        (bool ok,) =
            address(vault).call{gas: Constants.SWEEP_ABSORB_MIN_GAS - 200_000}(abi.encodeCall(IAmpsVault.touch, ()));
        assertTrue(ok, "the entry point still succeeds");
        assertEq(IERC20(address(stocks[0])).balanceOf(address(vault)), donated, "the absorb was skipped");
        assertTrue(_sawResidue(address(stocks[0]), donated), "and disclosed");

        // With room, the same balance is absorbed.
        uint256 claimBefore = claimOf(address(stocks[0]));
        vault.touch();
        assertEq(IERC20(address(stocks[0])).balanceOf(address(vault)), 0, "absorbed with room to do it");
        assertEq(claimOf(address(stocks[0])), claimBefore + donated, "into the claim, where `A` counts it");
    }

    /// @notice The reserve the payout holds back covers the claims-only fallback **and** the tail behind it: the
    ///         queue, the `Redeem` event and the sweep over every registered asset.
    function test_w5_L10_theRedemptionTailFitsInsideThePayoutReserve() public {
        // A constituent that burns whatever the ERC-20 `take` is given, so the claims-only fallback is the leg
        // that actually pays — the case the reserve exists for.
        bondDeposit(address(stocks[0]), 20e18);
        stocks[0].setTransferGasBurn(Constants.STOCK_TOKEN_PROBE_GAS * 8);

        uint256 assets = vault.assetCount();
        uint256 reserve =
            Constants.REDEEM_PAYOUT_RESERVE_PER_ASSET_GAS * assets + Constants.REDEEM_PAYOUT_RESERVE_FIXED_GAS;
        emit log_named_uint("lead L-10: assets", assets);
        emit log_named_uint("lead L-10: reserve held back", reserve);

        uint256 before = IERC20(address(usdg)).balanceOf(ALICE);
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        assertGt(IERC20(address(usdg)).balanceOf(ALICE), before, "the floor paid");
        assertGt(
            poolManager.balanceOf(ALICE, uint256(uint160(address(stocks[0])))),
            0,
            "and the hostile constituent was paid as a claim by the fallback"
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-11 — a position that cannot be valued flags the checkpoint
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-11.** `valuePool` was the one unbounded typed read in `A`, called at three sites, so a
    ///         valuer that reverted, answered short or looped bricked the checkpoint, every bond and every
    ///         placement until a 7-day pointer change could land. And a position the protocol cannot price was
    ///         dropped **silently**, so `A` could fall by a constituent's whole ladder with the checkpoint
    ///         recording itself as confirmed.
    function test_w5_L11_anUnvaluablePositionFlagsTheCheckpointRatherThanBrickingIt() public {
        vault.checkpoint();
        assertFalse(vault.navUnconfirmed(), "the fixture checkpoints on live answers");
        uint256 before = vault.totalAssetsUsd18();

        vm.mockCallRevert(
            address(valuer),
            abi.encodeWithSelector(IPositionValuer.valuePool.selector),
            abi.encodeWithSignature("Error(string)", "down")
        );

        // It does not revert, it flags.
        vault.checkpoint();
        assertTrue(vault.navUnconfirmed(), "the checkpoint says it could not price the positions");
        assertLt(vault.totalAssetsUsd18(), before, "and `A` dropped by the position term it had to drop");

        vm.clearMockedCalls();
        vault.checkpoint();
        assertFalse(vault.navUnconfirmed(), "a later confirmed checkpoint clears it");
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-12 — one acceptance rule for a feed answer
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-12.** `VaultNavLib.answer` accepted 32 bytes while `VaultPlacementLib._answer` has always
    ///         required the interface's 96, so a malformed registry was trusted by NAV and read as absent by
    ///         placements — `A` priced a constituent off an answer the placement path would not anchor to.
    function test_w5_L12_aShortFeedAnswerIsAbsentForNavToo() public {
        // A constituent the vault actually holds, so `A`'s walk reaches the answer rather than skipping a
        // zero balance.
        address stock = address(stocks[0]);
        bondDeposit(stock, 20e18);
        assertGt(claimOf(stock), 0, "the vault holds the constituent");

        vm.mockCall(
            address(feeds), abi.encodeCall(IFeedRegistry.latestAnswer, (stock)), abi.encode(uint256(STOCK_USD8[0]))
        );
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.FeedNotSet.selector, stock));
        vault.totalAssetsUsd18();

        // The interface's own shape is accepted.
        vm.mockCall(
            address(feeds),
            abi.encodeCall(IFeedRegistry.latestAnswer, (stock)),
            abi.encode(uint256(STOCK_USD8[0]), uint32(block.timestamp), true)
        );
        assertGt(vault.totalAssetsUsd18(), 0, "three words is the answer, and it is read");
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-13 — the unwind's AMPS fees, and `record.amount`
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-13(a).** The AMPS-side fees a redemption's position removal realises were the one fee
    ///         realisation in the protocol that became ask inventory the ladder could re-sell instead of being
    ///         burned — which revision 6's ruling BG forbids on every other path. They are queued with the
    ///         release now, so `previewRedeem`'s third return is a **lower bound** on what
    ///         `pendingInventoryBurn()` rises by: a `view` cannot ask v4 what fees a removal will realise.
    ///
    /// @dev **L-13(b) — pro-rating `record.amount` — was measured and not taken.** It is a disclosure field in
    ///      the record's second slot, so the write is a cold `SLOAD` plus a dirty `SSTORE` on the one path that
    ///      must stay inside one transaction: it moved the marginal cost of a live cell from 43,032 to 48,531
    ///      gas, i.e. `redeemProRata` at `MAX_LIVE_CELLS` from 22,391,221 to 25,206,709 against the 24,000,000
    ///      bound `VaultRedeem.t.sol::test_e_gasPerLiveCellFitsTheRedemptionBudget` asserts. The second half of
    ///      this
    ///      test pins the behaviour that follows from not taking it, so that it is a recorded decision rather
    ///      than an oversight.
    function test_w5_L13_theUnwindQueuesItsAmpsFeesAndLeavesTheRecordAmount() public {
        _tradeForFees();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        PlacementRecord[] memory before = ladderOf(hubPool);
        uint256 supply = amps.totalSupply();
        uint256 shares = 1000e18;

        (,, uint256 previewRelease) = vault.previewRedeem(shares);
        vm.prank(ALICE);
        vault.redeemProRata(shares, ALICE);

        // The pool has traded, so the removal realised AMPS-side fees, and they are queued with the release.
        uint256 queued = vault.pendingInventoryBurn();
        emit log_named_uint("lead L-13: preview's inventoryReleased", previewRelease);
        emit log_named_uint("lead L-13: actually queued", queued);
        assertGt(queued, previewRelease, "the AMPS fees the unwind realised went into the stream too");

        // And `record.amount` is the one disclosure a redemption deliberately does not follow: the liquidity
        // fell, the field did not.
        PlacementRecord[] memory after_ = ladderOf(hubPool);
        uint256 checked;
        for (uint256 i; i < before.length; ++i) {
            if (before[i].liquidity == 0 || before[i].amount == 0) continue;
            uint128 removed = uint128(FullMath.mulDiv(before[i].liquidity, shares, supply));
            if (removed == 0) continue;
            assertLt(after_[i].liquidity, before[i].liquidity, "the redemption really removed from this cell");
            assertEq(after_[i].amount, before[i].amount, "and `record.amount` is left where the placement put it");
            ++checked;
        }
        assertGt(checked, 0, "there were records with a disclosed amount to check");
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-14 — the surge call is bounded and cannot revert a placement
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-14.** A typed `try` on a `void` external function emits the compiler's own `extcodesize`
    ///         screen *before* the call, so a codeless market reference reverted in the placement's own frame
    ///         rather than reaching the `catch` — the failure its hardened sibling `_resetHighWater` has been
    ///         protected against since 2026-09-07.
    function test_w5_L14_aCodelessMarketReferenceDoesNotRevertTheSurge() public {
        _tradeForFees();

        // A second address with code, pointed at and then emptied: the pool keeps its real hook, so v4's own
        // callbacks are untouched and only the vault's market-reference reads see a codeless target.
        address marketRef = address(new MalformedLadderPolicy());
        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("marketReference"), marketRef);
        vm.etch(marketRef, "");

        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.prank(KEEPER);
        vault.compound(hubPool);
    }

    // -------------------------------------------------------------------------------------------------------------
    // L-15 — every vault pool is AMPS/<counter>, in that order
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **Lead L-15.** `redeemProRata`'s unwind takes `currency0` out as the AMPS to release,
    ///         `_placeLadder` reads `currency1` as the counter and `A` values `currency1` alone, and only the
    ///         registry enforced the ordering.
    function test_w5_L15_initializePoolRefusesANonAmpsCurrency0() public {
        MockERC20 a = deployToken("Alpha", "ALP", 18);
        MockERC20 b = deployToken("Beta", "BET", 18);
        (address lower, address upper) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(lower),
            currency1: Currency.wrap(upper),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.prank(address(registry));
        vm.expectRevert(abi.encodeWithSelector(IAmpsVault.NotAmpsPool.selector, lower));
        vault.initializePool(key, FLAT_SQRT_PRICE_X96);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev One buy and one sell into the hub, which is what leaves a pool with fees in both currencies.
    function _tradeForFees() private {
        buyAmps(hubPool, address(usdg), 100e6);
        sellAmps(hubPool, amps.balanceOf(BOB) / 2);
        syncMarket();
    }

    /// @dev How many USDG wei of the hub's position value have to disappear for `A` to fall by ten basis points.
    function _shaveForTenBpOfA() private view returns (uint256 shaveWei) {
        // `A` is 18-decimal USD and USDG is a 6-decimal dollar, so ten basis points of `A` is
        // `A / 10_000 x 10` dollars, i.e. that many units of `1e18 / 1e6`.
        return vault.totalAssetsUsd18() * 10 / Constants.BPS / 1e12;
    }

    /// @dev The amount-weighted opening {VaultRedeemLib-queueInventoryBurn} writes.
    function _weightedStart(uint256 oldStart, uint256 pending, uint256 added) private view returns (uint256) {
        return
            FullMath.mulDiv(oldStart, pending, pending + added)
                + FullMath.mulDiv(block.timestamp, added, pending + added);
    }

    /// @dev Slot 21 [8..135]: `uint128 checkpointSupply` (`docs/phase2-state-model.md` §1.1).
    function _checkpointSupply() private view returns (uint256 supply) {
        return (uint256(vm.load(address(vault), bytes32(uint256(21)))) >> 8) & type(uint128).max;
    }

    /// @dev TEST ONLY. Writes the burn stream's three hashed slots directly.
    function _forceStream(uint256 pending, uint256 start, uint256 lastSettle) private {
        vm.store(address(vault), PENDING_BURN_SLOT, bytes32(pending));
        vm.store(address(vault), BURN_STREAM_START_SLOT, bytes32(start));
        vm.store(address(vault), BURN_STREAM_LAST_SETTLE_SLOT, bytes32(lastSettle));
    }

    /// @dev The unaligned tick `P_ref / P_counter` implies, which is the bound a bid cell's upper bound must
    ///      respect and the floor an ask cell's lower bound must respect.
    function _exactReferenceTick(uint256 counterUsd8, uint8 decimals) private view returns (int24 tick) {
        return
            PriceLib.sqrtPriceX96ToTick(PriceLib.ampsPerCounterToSqrtPriceX96(vault.pRefX18(), counterUsd8, decimals));
    }

    /// @dev TEST ONLY. Puts `P_ref` at the price whose hub tick is `target`, by inverting the same conversion the
    ///      placement path makes. Slot 0's high half is `pRefX18` (`docs/phase2-state-model.md` §1.1).
    function _forceReferenceAtTick(int24 target) private {
        uint256 priceUsd18 = PriceLib.sqrtPriceX96ToAmpsPriceUsd18(PriceLib.tickToSqrtPriceX96(target), USDG_USD8, 6);
        uint256 word = uint256(vm.load(address(vault), bytes32(uint256(0))));
        vm.store(address(vault), bytes32(uint256(0)), bytes32((priceUsd18 << 128) | (word & type(uint128).max)));
    }

    /// @dev Places a small seed bid into the hub and rolls the state back, so one test can walk a list of
    ///      malformed policy answers without the cooldown or the ladder shape carrying between them.
    function _placeSeedBidAndUndo(string memory context) private {
        uint256 snapshot = vm.snapshotState();
        usdg.mint(address(vault), 500e6);
        vm.prank(TIMELOCK);
        uint256 placed = vault.place(hubPool, false, 500e6);
        assertGt(placed, 0, string.concat("the placement fell through to LadderLib: ", context));
        vm.revertToState(snapshot);
    }

    /// @dev One more hookless `AMPS/<counter>` key against a freshly minted counter, for the vault's own
    ///      registry-only entry point. What is being exercised is `_registerAsset`, which is indifferent to the
    ///      hook and the feed; `currency0` is AMPS because lead L-15 now requires it.
    function _hooklessKey() private returns (PoolKey memory key) {
        MockStockToken extra = new MockStockToken("Extra", "EXTR");
        while (address(extra) <= address(amps)) {
            extra = new MockStockToken("Extra", "EXTR");
        }
        key = PoolKey({
            currency0: Currency.wrap(address(amps)),
            currency1: Currency.wrap(address(extra)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    /// @dev Whether the recorded logs hold `SweepResidue(token, amount)` from the vault.
    function _sawResidue(address token, uint256 amount) private returns (bool seen) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault)) continue;
            if (logs[i].topics[0] != IAmpsVault.SweepResidue.selector) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != token) continue;
            if (abi.decode(logs[i].data, (uint256)) == amount) return true;
        }
    }

    /// @dev How many live bid cells a pool holds.
    function _bidCellCount(PoolId poolId) private view returns (uint256 count) {
        PlacementRecord[] memory records = ladderOf(poolId);
        for (uint256 i; i < records.length; ++i) {
            if (!records[i].above && records[i].liquidity != 0) ++count;
        }
    }
}
