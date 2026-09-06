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

    /// @notice **BUG (economic, no stated invariant broken).** Splitting one redemption into `n` pieces extracts
    ///         materially *more* than redeeming the same shares once, and the gain grows with `n`.
    ///
    /// @dev **Cause.** `redeemProRata` pays `(1 - redeemFeeBps) * shares / T` of every balance, burns the
    ///      redeemer's `shares`, **and** burns the ladder inventory AMPS the unwind released (I23). `T` therefore
    ///      falls by more than `shares`, which is exactly what makes NAV/share rise on every redemption. A
    ///      redeemer who splits their exit re-reads the *raised* NAV on every subsequent slice and so captures a
    ///      share of the POL inventory burn that a single-shot redeemer leaves to everyone else. Nothing here
    ///      breaks I8, I11 or I23 - NAV/share is still monotone non-decreasing for the holders who stay, and every
    ///      slice pays the same proportional 1% fee - but the redemption floor is not split-neutral, and a large
    ///      holder exiting in pieces is strictly better off than one exiting at once.
    ///
    /// @dev **Repro.** {test_BUG_splittingARedemptionExtractsMoreThanDoingItOnce} below: 300 AMPS in one shot
    ///      against 300 AMPS in sixty slices, from the identical state, with the gain logged per split count.
    ///
    /// @dev **Fix shape** (not applied - `contracts/src/**` is out of scope for this suite). Either price the
    ///      whole redemption against the supply read at its start (which is what `redeemProRata` already does
    ///      *within* one call and what a sequence defeats), or stop burning the released inventory into the same
    ///      denominator the payout divides by - e.g. hold the released inventory as a claim and burn it on the
    ///      next `compound`, so the NAV lift lands after the redemption rather than inside a sequence of them. The
    ///      second is the smaller change and keeps I23's "burns the released inventory" true, one block later.
    function test_BUG_splittingARedemptionExtractsMoreThanDoingItOnce() public {
        uint256 shares = 300e18;
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

        assertGt(proceeds[1], proceeds[0], "five slices already beat one");
        assertGt(proceeds[2], proceeds[1], "twenty beat five");
        assertGt(proceeds[3], proceeds[2], "sixty beat twenty");
        assertGt(proceeds[3] * 100 / proceeds[0], 101, "and the advantage is percentage points, not rounding dust");
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
