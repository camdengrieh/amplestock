// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {AmpsVaultFixture} from "../mocks/AmpsVaultFixture.sol";

/// @title AmpsVaultFuzzTest
/// @notice Random interleavings of the four things anyone can do to the Phase 2 vault — bond, mint a vest, move the
///         market and redeem — against the four properties that must survive any order of them:
///
///          - NAV/share is monotone non-decreasing **ex market moves** (I8, and the vault half of I27);
///          - NAV/share is finite and non-zero in every reachable state (I22);
///          - a redemption pays exactly `floor(b x shares / T) x (1 - redeemFeeBps / BPS)` of every asset (I23);
///          - a redemption drops `totalSupply` by more than `shares`, because the released inventory burns too.
contract AmpsVaultFuzzTest is AmpsVaultFixture {
    /// @dev Actions, one per fuzzed byte.
    uint8 internal constant ACTION_BOND = 0;
    uint8 internal constant ACTION_REDEEM = 1;
    uint8 internal constant ACTION_CHECKPOINT = 2;
    uint8 internal constant ACTION_MOVE_MARKET = 3;
    uint8 internal constant ACTION_DONATE = 4;
    uint8 internal constant ACTION_COUNT = 5;

    function setUp() public {
        deployVaultWorld();
        runGenesis();
        giveShares(ALICE, 2000e18);
        stock.mint(BOB, 1_000_000e18);
        vm.prank(BOB);
        stock.approve(address(vault), type(uint256).max);
    }

    /// @notice Eight random actions in a random order, with every property checked after each one.
    /// @param actions The action selector for each step.
    /// @param amounts The magnitude for each step.
    function testFuzz_interleavings(uint8[8] calldata actions, uint128[8] calldata amounts) public {
        for (uint256 i; i < actions.length; ++i) {
            uint8 action = actions[i] % ACTION_COUNT;
            uint256 navBefore = vault.previewNavPerShareX18();

            if (action == ACTION_BOND) {
                _bondAtTheAccretionFloor(uint256(amounts[i]) % 5000e18 + 1e15);
            } else if (action == ACTION_REDEEM) {
                _redeemAndCheck(uint256(amounts[i]) % (amps.balanceOf(ALICE) + 1));
            } else if (action == ACTION_CHECKPOINT) {
                vm.warp(block.timestamp + (uint256(amounts[i]) % 3600) + 1);
                vault.checkpoint();
            } else if (action == ACTION_MOVE_MARKET) {
                _moveMarket(amounts[i]);
                navBefore = 0; // a market move is exactly the exception to monotonicity
            } else {
                stock.mint(address(vault), uint256(amounts[i]) % 100e18);
            }

            uint256 navAfter = vault.previewNavPerShareX18();
            assertGe(navAfter, navBefore, "NAV/share never falls, ex market moves (I8)");
            assertGt(navAfter, 0, "NAV/share is finite and non-zero (I22)");
            assertGe(vault.pRefX18(), vault.navPerShareX18(), "P_ref is never below NAV (I24)");
        }
    }

    /// @notice A redemption of any size pays exactly pro rata and burns strictly more supply than it retires.
    /// @param shares The AMPS wei to redeem.
    function testFuzz_redeemIsExactlyProRata(uint128 shares) public {
        uint256 amount = uint256(shares) % 2000e18 + 1;
        _redeemAndCheck(amount);
    }

    /// @notice The redemption fee is the only leakage, and it never exceeds its band.
    /// @param feeBps The governed fee.
    /// @param shares The AMPS wei to redeem.
    function testFuzz_redeemFeeStaysInsideItsBand(uint16 feeBps, uint128 shares) public {
        uint16 fee = uint16(uint256(feeBps) % (Constants.REDEEM_FEE_BPS_MAX + 1));
        vm.prank(TIMELOCK);
        vault.setRedeemFeeBps(fee);

        uint256 amount = uint256(shares) % 2000e18 + 1;
        uint256 supply = amps.totalSupply();
        uint256 gross = (SEED_USDG * amount) / supply;

        vm.prank(ALICE);
        vault.redeemProRata(amount, ALICE);

        assertEq(usdg.balanceOf(ALICE), (gross * (Constants.BPS - fee)) / Constants.BPS, "fee applied exactly once");
    }

    /// @notice The reference price never leaves `[navPerShare, +inf)` and never rises faster than its rate limit.
    /// @param priceUsd18 The market price to seed.
    /// @param elapsed The time between checkpoints.
    function testFuzz_referenceRespectsItsBounds(uint96 priceUsd18, uint32 elapsed) public {
        uint256 price = uint256(priceUsd18) % 100e18 + 1e12;
        uint256 wait = uint256(elapsed) % 7 days + 1;

        uint256 pRefPrev = vault.pRefX18();
        seedHubPrice(price);
        vm.warp(block.timestamp + wait);
        vault.checkpoint();

        assertGe(vault.pRefX18(), vault.navPerShareX18(), "NAV floor (I24)");
        if (vault.pRefX18() > pRefPrev) {
            uint256 cap = pRefPrev + (pRefPrev * (uint256(Constants.REF_UP_RATE_BPS_DEFAULT) * wait))
                / (Constants.ONE_HOUR * Constants.BPS);
            assertLe(vault.pRefX18(), cap > vault.navPerShareX18() ? cap : vault.navPerShareX18(), "rate limit up");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev A bond as `AmpsBonds` would send it: collateral in, then AMPS minted at or below the accretion floor
    ///      `q_floor = P_i / (navPerShare x (1 + minAccretionBps))`. Issuing at the floor is the worst case for
    ///      NAV/share, which is exactly what the monotonicity assertion needs.
    function _bondAtTheAccretionFloor(uint256 amountStock) private {
        if (amountStock == 0 || stock.balanceOf(BOB) < amountStock) return;
        // The live answer, not the launch constant: a market move earlier in the run may have repriced the
        // collateral, and a bond priced off a stale number would dilute for a reason the vault is not responsible
        // for.
        (uint256 answerUsd8,,) = feeds.latestAnswer(address(stock));
        uint256 valueUsd18 = (amountStock * answerUsd8 * 1e10) / 1e18;
        uint256 nav = vault.previewNavPerShareX18();
        uint256 denominator = (nav * (Constants.BPS + Constants.MIN_ACCRETION_BPS_DEFAULT)) / Constants.BPS;
        uint256 ampsOut = (valueUsd18 * 1e18) / denominator;

        vm.prank(BONDS);
        vault.depositBonded(1, address(stock), BOB, amountStock);
        if (ampsOut == 0) return;
        vm.prank(BONDS);
        vault.mintVesting(BONDS, ampsOut);
    }

    /// @dev Redeems `shares` from Alice and checks the exact I23 arithmetic against the balances read beforehand.
    function _redeemAndCheck(uint256 shares) private {
        if (shares == 0 || amps.balanceOf(ALICE) < shares) return;

        uint256 supply = amps.totalSupply();
        uint256 count = vault.assetCount();
        uint256[] memory expected = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            address token = vault.assetAt(i);
            uint256 gross = (heldBalance(token) * shares) / supply;
            expected[i] = (gross * (Constants.BPS - vault.redeemFeeBps())) / Constants.BPS;
        }
        (,, uint256 inventoryBurned) = vault.previewRedeem(shares);

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory paid) = vault.redeemProRata(shares, BOB);

        for (uint256 i; i < count; ++i) {
            assertEq(tokens[i], vault.assetAt(i), "asset order is the registration order");
            assertEq(paid[i], expected[i], "floor(b x shares / T) x (1 - fee) exactly (I23)");
        }
        assertEq(amps.totalSupply(), supply - shares - inventoryBurned, "supply fell by shares plus inventory");
        assertLe(amps.totalSupply(), supply - shares, "and never by less than the shares burned");
    }

    /// @dev Moves the hub TWAP and the Stock Token's answer: the market half of the world, and the only thing that
    ///      is allowed to push NAV/share down.
    function _moveMarket(uint128 seed) private {
        uint256 price = (uint256(seed) % 10e18) + 1e15;
        seedHubPrice(price);
        uint128 answer = uint128((uint256(seed) % 500e8) + 1e8);
        feeds.setAnswer(address(stock), answer);
    }
}
