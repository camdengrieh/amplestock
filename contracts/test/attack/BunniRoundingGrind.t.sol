// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

/// @title BunniRoundingGrindTest
/// @notice The plan's named attack **Bunni-style rounding grind-down**: repeat a tiny deposit/withdraw - here a
///         tiny redemption, which is the only path that takes value out of the vault - thousands of times, and
///         collect the rounding dust each iteration leaves behind.
///
///         It fails because every division on the redemption path floors in the protocol's favour:
///         `floor(L * shares / T)` comes out of each position, `floor(b * shares / T)` out of each balance, and
///         the redemption fee is taken on top. A dust redemption therefore pays the redeemer **nothing** while
///         still burning their shares, so the grind is a donation.
contract BunniRoundingGrindTest is Phase3Fixture {
    address internal constant GRINDER = address(0x64111D);

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    /// @notice Two hundred dust redemptions in a row: NAV/share never falls, the grinder is paid nothing at all,
    ///         and every share they burned is gone.
    function test_dustRedemptionsPayNothingAndRaiseNavPerShare() public {
        giveShares(GRINDER, 1000e18);
        uint256 navBefore = vault.previewNavPerShareX18();
        uint256 supplyBefore = amps.totalSupply();

        uint256 paidOut;
        for (uint256 i; i < 200; ++i) {
            vm.prank(GRINDER);
            (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(1, GRINDER);
            for (uint256 k; k < tokens.length; ++k) {
                paidOut += amounts[k];
            }
        }

        assertEq(paidOut, 0, "two hundred dust redemptions paid the grinder nothing");
        assertEq(amps.totalSupply(), supplyBefore - 200, "and burned every share they spent");
        assertGe(vault.previewNavPerShareX18(), navBefore, "so NAV/share went up, not down");
        for (uint256 k; k < vault.assetCount(); ++k) {
            assertEq(IERC20(vault.assetAt(k)).balanceOf(GRINDER), 0, "the grinder holds none of any asset");
        }
    }

    /// @notice **Ruling U, closed** (revision 8). Splitting one redemption into `n` pieces used to extract
    ///         materially *more* than redeeming the same shares once, and the gain grew with `n`. It no longer
    ///         does: 2,000 AMPS in sixty slices and 2,000 AMPS in one shot come out within a few basis points of
    ///         each other, and the residue is the redemption fee's own superadditivity rather than a strategy.
    ///
    /// @dev **What the bug was.** `redeemProRata` paid `(1 - redeemFeeBps) * shares / T` of every balance, burned
    ///      the redeemer's `shares`, **and** burned the ladder inventory AMPS the unwind released (I23), all in the
    ///      same transaction. `T` therefore fell by more than `shares`, which is what makes NAV/share rise on
    ///      every redemption — and a redeemer who split their exit re-read the *raised* NAV on every subsequent
    ///      slice, capturing a share of the POL inventory burn that a single-shot redeemer leaves to everyone
    ///      else. Nothing broke I8, I11 or I23; the floor simply was not split-neutral.
    ///
    /// @dev **What was applied.** The second of the two fix shapes this file named — "stop burning the released
    ///      inventory into the same denominator the payout divides by" — in its rate-limited form. Holding the
    ///      release for "the next `compound`" would not have been enough, because `checkpoint()` is permissionless
    ///      and a redeemer can call it between slices; the release is therefore queued and streamed out linearly
    ///      over `Constants.REDEEM_BURN_STREAM_SECONDS`. Slices in one block settle nothing at all, so the lift a
    ///      splitter used to capture is not there to capture. `docs/phase3-state-model.md` §12.3 ruling U.
    function test_r8_splittingARedemptionNoLongerExtractsMore() public {
        uint256 shares = 2000e18; // 10% of `S0`; the vault's idle POL after the genesis ladders is 2,520
        uint256[4] memory splits = [uint256(1), 5, 20, 60];
        uint256[4] memory proceeds;

        for (uint256 s; s < splits.length; ++s) {
            uint256 snapshot = vm.snapshotState();
            giveShares(GRINDER, shares);
            for (uint256 i; i < splits[s]; ++i) {
                vm.prank(GRINDER);
                vault.redeemProRata(shares / splits[s], GRINDER);
            }
            proceeds[s] = usdg.balanceOf(GRINDER);
            console.log("splits", splits[s], "USDG out", proceeds[s]);
            vm.revertToState(snapshot);
        }

        // 25 bp of slack against the 100+ bp advantage this test used to assert. Anything above it would mean the
        // stream had stopped rate-limiting the burn.
        for (uint256 s = 1; s < splits.length; ++s) {
            uint256 gap = proceeds[s] > proceeds[0] ? proceeds[s] - proceeds[0] : proceeds[0] - proceeds[s];
            assertLe(gap * 10_000 / proceeds[0], 25, "splitting is worth at most 25 bp");
        }
    }

    /// @notice The same grind against the ladder: a dust redemption removes `floor(L * shares / T)` from every
    ///         position, which for one wei of shares is zero liquidity, so the book is untouched.
    function test_dustRedemptionDoesNotDisturbTheLadder() public {
        giveShares(GRINDER, 10e18);
        uint32 cellsBefore = vault.liveCells();
        uint256 hubCells = vault.ladderLength(hubPool);

        for (uint256 i; i < 50; ++i) {
            vm.prank(GRINDER);
            vault.redeemProRata(1, GRINDER);
        }

        assertEq(vault.liveCells(), cellsBefore, "no cell was closed by dust");
        assertEq(vault.ladderLength(hubPool), hubCells, "and the hub ladder is intact");
        assertEq(vault.liveCells(), countLiveCells(), "the vault's own count still matches the book");
    }
}
