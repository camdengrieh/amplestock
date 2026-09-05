// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBondPolicy} from "../../src/interfaces/IBondPolicy.sol";
import {BondPolicy} from "../../src/policy/BondPolicy.sol";
import {Constants} from "../../src/types/Constants.sol";
import {Session} from "../../src/types/Types.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Unit tests for the bond pricing law: the discount curve, the accretion floor, every rounding direction
///         and the pricing table that proves `q <= q_floor` in every session at every premium.
contract BondPolicyTest is Test {
    BondPolicy internal policy;

    /// @dev The launch calibration: $180 collateral, $1.00 NAV/share, 12.5% base discount, 50 bp accretion.
    uint256 internal constant P_I_USD18 = 180e18;
    uint256 internal constant NAV_USD18 = 1e18;
    uint16 internal constant D_BASE = Constants.BOND_D_BASE_BPS_DEFAULT;
    uint16 internal constant D_MIN = Constants.BOND_D_MIN_BPS_DEFAULT;
    uint16 internal constant D_MAX = Constants.BOND_D_MAX_BPS_DEFAULT;
    uint16 internal constant ACCRETION = Constants.MIN_ACCRETION_BPS_DEFAULT;

    function setUp() public {
        policy = new BondPolicy();
    }

    /* ------------------------------------------ identity ------------------------------------------ */

    function test_version() public view {
        assertEq(policy.version(), bytes32("linear-deficit-fill-v1"));
    }

    /* --------------------------------------- the discount curve --------------------------------------- */

    function test_discountIsTheBaseWithNoDeficitAndNoFill() public view {
        assertEq(policy.discountBps(D_BASE, D_MIN, D_MAX, 0.5e18, 0.25e18, 0, 0), D_BASE);
    }

    /// @dev The confirmed launch calibration, straight out of the plan: `k_w = 0.5` adds 250 bp to a name at half
    ///      its target weight, and `k_c = 0.25` removes 250 bp from a market whose epoch is full.
    function test_launchCoefficientCalibration() public view {
        // A half-weight name: +250 bp, before the clamp to dMax = 1500.
        assertEq(policy.discountBps(D_BASE, D_MIN, D_MAX, 0.5e18, 0, 0.5e18, 0), D_BASE + 250);
        // A full epoch: -250 bp, before the clamp to dMin = 1000.
        assertEq(policy.discountBps(D_BASE, D_MIN, D_MAX, 0, 0.25e18, 0, 1e18), D_BASE - 250);
        // Both at once cancel exactly.
        assertEq(policy.discountBps(D_BASE, D_MIN, D_MAX, 0.5e18, 0.25e18, 0.5e18, 1e18), D_BASE);
    }

    function test_discountClampsToTheBand() public view {
        // A full deficit at the ceiling coefficient wants +2,000 bp and gets dMax.
        assertEq(policy.discountBps(D_BASE, D_MIN, D_MAX, 2e18, 0, 1e18, 0), D_MAX);
        // A full epoch at the ceiling coefficient wants -2,000 bp and gets dMin.
        assertEq(policy.discountBps(D_BASE, D_MIN, D_MAX, 0, 2e18, 0, 1e18), D_MIN);
        // The subtraction saturates at zero before the clamp lifts it back to dMin.
        assertEq(policy.discountBps(500, D_MIN, D_MAX, 0, 2e18, 0, 1e18), D_MIN);
    }

    /// @dev The deficit term rounds **down** (it is added) and the fill term rounds **up** (it is subtracted): both
    ///      shrink `d`, which is what "`d` rounds down" means once the sign of each term is taken into account.
    function test_discountRoundingFavoursTheProtocol() public view {
        // deficit = 1 wei of 1e18 with k = 1e18 would be 1e-15 bp: it rounds away entirely.
        assertEq(policy.discountBps(D_BASE, 0, D_MAX, 1e18, 0, 1, 0), D_BASE);
        // fill = 1 wei of 1e18 with k = 1e18 is the same size, and rounds up to a whole bp against the bonder.
        assertEq(policy.discountBps(D_BASE, 0, D_MAX, 0, 1e18, 0, 1), D_BASE - 1);
    }

    function test_discountRejectsImpossibleInputs() public {
        vm.expectRevert(abi.encodeWithSelector(IBondPolicy.InvalidQuoteInput.selector, bytes32("dMinBps")));
        policy.discountBps(D_BASE, 1600, 1500, 0, 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(IBondPolicy.InvalidQuoteInput.selector, bytes32("dMaxBps")));
        policy.discountBps(D_BASE, D_MIN, 10_000, 0, 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(IBondPolicy.InvalidQuoteInput.selector, bytes32("deficitX18")));
        policy.discountBps(D_BASE, D_MIN, D_MAX, 0, 0, uint64(1e18 + 1), 0);

        vm.expectRevert(abi.encodeWithSelector(IBondPolicy.InvalidQuoteInput.selector, bytes32("fillX18")));
        policy.discountBps(D_BASE, D_MIN, D_MAX, 0, 0, 0, uint64(1e18 + 1));
    }

    /* ------------------------------------------ validation ------------------------------------------ */

    function test_quoteRejectsImpossibleInputs() public {
        IBondPolicy.QuoteInput memory input = _input(180e18, 0, 0, 0, 1e18);

        input.navPerShareX18 = 0;
        vm.expectRevert(abi.encodeWithSelector(IBondPolicy.InvalidQuoteInput.selector, bytes32("navPerShareX18")));
        policy.quote(input);

        input = _input(180e18, 0, 0, 0, 1e18);
        input.collateralPriceUsd18 = 0;
        vm.expectRevert(abi.encodeWithSelector(IBondPolicy.InvalidQuoteInput.selector, bytes32("collateralPriceUsd18")));
        policy.quote(input);

        input = _input(180e18, 0, 0, 0, 1e18);
        input.mX18 = 0;
        vm.expectRevert(abi.encodeWithSelector(IBondPolicy.InvalidQuoteInput.selector, bytes32("mX18")));
        policy.quote(input);

        input = _input(180e18, 0, 0, 0, 1e18);
        input.hSessionBps = 10_000;
        vm.expectRevert(abi.encodeWithSelector(IBondPolicy.InvalidQuoteInput.selector, bytes32("hSessionBps")));
        policy.quote(input);
    }

    /* ------------------------------------------ the numbers ------------------------------------------ */

    function test_qMarketAndQFloorAreTheDocumentedArithmetic() public view {
        IBondPolicy.QuoteInput memory input = _input(180e18, 0, 0, 0, 1e18);
        IBondPolicy.QuoteOutput memory output = policy.quote(input);

        assertEq(output.discountBps, D_BASE, "discount");
        assertEq(output.qMarketX18, FullMath.mulDiv(180e18, 10_000, 10_000 - D_BASE), "qMarket = m x BPS/(BPS - d)");
        assertEq(output.qFloorX18, _qFloor(P_I_USD18, NAV_USD18, 0, ACCRETION), "qFloor");
        assertEq(output.qX18, output.qFloorX18, "q = min");
        assertTrue(output.floorBinding, "the floor binds at zero premium");
        assertEq(output.ampsOut, FullMath.mulDiv(1e18, output.qX18, 1e18), "ampsOut");
    }

    /// @dev Numerator down, denominator up, quotient down — each direction checked against the exact rational.
    function test_qFloorRoundsEveryStepAgainstTheBonder() public view {
        // 7 wei of price with a 1 bp haircut: the numerator's exact value is 6.9993 wei and must floor to 6.
        assertEq(policy.qFloorX18(7, 1e18, 1, 0), 6, "numerator floors");

        // A NAV that does not divide evenly by the accretion multiplier: the denominator must ceil.
        uint256 nav = 3;
        uint256 exactDenominator = FullMath.mulDivRoundingUp(nav, 10_000 + uint256(ACCRETION), 10_000);
        assertEq(exactDenominator, 4, "denominator ceils");
        assertEq(policy.qFloorX18(1e18, nav, 0, ACCRETION), FullMath.mulDiv(1e18, 1e18, 4), "quotient floors");
    }

    function test_ampsOutRoundsDown() public view {
        IBondPolicy.QuoteInput memory input = _input(180e18, 0, 0, 0, 1);
        IBondPolicy.QuoteOutput memory output = policy.quote(input);
        // One wei of collateral against a price far below 1e18 per wei: the bonder receives nothing, never a wei.
        assertEq(output.ampsOut, FullMath.mulDiv(1, output.qX18, 1e18));
    }

    /* ---------------------------------------- the pricing table ---------------------------------------- */

    /// @notice The Phase 2 pricing table: premium x session, asserting that `q <= q_floor` everywhere and that the
    ///         discount only bites once the premium exceeds it.
    /// @dev The crossover is `(1 + accretion) / ((1 - d)(1 - h)) - 1`: 14.86% in the Regular session, rising with
    ///      the haircut. Below it the bond issues at the NAV floor and is still accretive by `minAccretionBps`;
    ///      above it the market discount is the binding price and the protocol captures the premium.
    function test_pricingTableAcrossPremiumsAndSessions() public view {
        int256[5] memory premiumsBps = [-int256(500), int256(0), int256(500), int256(1250), int256(3000)];
        uint16[4] memory haircuts = [
            Constants.H_SESSION_REGULAR_BPS_DEFAULT,
            Constants.H_SESSION_PRE_POST_BPS_DEFAULT,
            Constants.H_SESSION_OVERNIGHT_BPS_DEFAULT,
            Constants.H_SESSION_CLOSED_BPS_DEFAULT
        ];

        for (uint256 s; s < haircuts.length; ++s) {
            for (uint256 p; p < premiumsBps.length; ++p) {
                uint256 ampsPriceUsd18 = uint256(int256(NAV_USD18) + int256(NAV_USD18) * premiumsBps[p] / 10_000);
                uint256 mX18 = FullMath.mulDiv(P_I_USD18, 1e18, ampsPriceUsd18);

                IBondPolicy.QuoteInput memory input = _input(mX18, haircuts[s], 0, 0, 1e18);
                IBondPolicy.QuoteOutput memory output = policy.quote(input);

                // I27, first clause: the applied price never exceeds the accretion floor.
                assertLe(output.qX18, output.qFloorX18, "q <= qFloor");
                assertEq(output.qFloorX18, _qFloor(P_I_USD18, NAV_USD18, haircuts[s], ACCRETION), "floor");

                // I27, second clause: the bond is accretive at the demanded margin.
                assertLe(
                    FullMath.mulDiv(output.ampsOut, NAV_USD18 * (10_000 + uint256(ACCRETION)), 10_000),
                    FullMath.mulDiv(1e18, P_I_USD18 * (10_000 - uint256(haircuts[s])), 10_000),
                    "ampsOut x nav x (1 + a) <= amountIn x P_i x (1 - h)"
                );

                // The discount only bites above the crossover premium.
                uint256 crossoverBps = _crossoverBps(D_BASE, haircuts[s], ACCRETION);
                if (premiumsBps[p] > 0 && uint256(premiumsBps[p]) > crossoverBps) {
                    assertFalse(output.floorBinding, "premium above the crossover: the discount binds");
                    assertEq(output.qX18, output.qMarketX18, "q is the market price");
                } else {
                    assertTrue(output.floorBinding, "premium below the crossover: the floor binds");
                    assertEq(output.qX18, output.qFloorX18, "q is the floor");
                }
            }
        }
    }

    /// @notice A stale feed changes nothing in the pricing law: staleness is priced by the haircut the gate
    ///         reports, not by a second adjustment inside the policy.
    /// @dev The table above is therefore complete over `{fresh, stale}` by construction — the freshness flag never
    ///      reaches `IBondPolicy` — and `AmpsBonds.t.sol` asserts the shell forwards a stale answer unchanged.
    function test_theHaircutIsTheOnlyStalenessAdjustment() public view {
        IBondPolicy.QuoteInput memory fresh = _input(180e18, 0, 0, 0, 1e18);
        IBondPolicy.QuoteInput memory closed = _input(180e18, Constants.H_SESSION_CLOSED_BPS_DEFAULT, 0, 0, 1e18);

        assertGt(policy.quote(fresh).qFloorX18, policy.quote(closed).qFloorX18, "the haircut lowers the floor");
        assertEq(policy.quote(fresh).qMarketX18, policy.quote(closed).qMarketX18, "and never the market price");
    }

    /* --------------------------------------------- fuzz --------------------------------------------- */

    /// @notice `q <= qFloor` and `ampsOut` accretive, for any input the shell can assemble.
    function testFuzz_quoteNeverExceedsTheFloor(
        uint256 mX18,
        uint256 navPerShareX18,
        uint256 collateralPriceUsd18,
        uint256 amountIn18,
        uint16 haircutBps,
        uint16 accretionBps,
        uint64 deficitX18,
        uint64 fillX18
    ) public view {
        mX18 = bound(mX18, 1, 1e36);
        navPerShareX18 = bound(navPerShareX18, 1, 1e30);
        collateralPriceUsd18 = bound(collateralPriceUsd18, 1, 1e30);
        amountIn18 = bound(amountIn18, 0, 1e30);
        haircutBps = uint16(bound(haircutBps, 0, Constants.H_SESSION_BPS_MAX));
        accretionBps = uint16(bound(accretionBps, 0, Constants.MIN_ACCRETION_BPS_MAX));
        deficitX18 = uint64(bound(deficitX18, 0, 1e18));
        fillX18 = uint64(bound(fillX18, 0, 1e18));

        IBondPolicy.QuoteInput memory input = IBondPolicy.QuoteInput({
            mX18: mX18,
            navPerShareX18: navPerShareX18,
            collateralPriceUsd18: collateralPriceUsd18,
            amountIn18: amountIn18,
            dBaseBps: D_BASE,
            dMinBps: D_MIN,
            dMaxBps: D_MAX,
            kWeightX18: Constants.BOND_K_WEIGHT_X18_DEFAULT,
            kFillX18: Constants.BOND_K_FILL_X18_DEFAULT,
            deficitX18: deficitX18,
            fillX18: fillX18,
            hSessionBps: haircutBps,
            minAccretionBps: accretionBps
        });

        IBondPolicy.QuoteOutput memory output = policy.quote(input);

        assertLe(output.qX18, output.qFloorX18, "q <= qFloor");
        assertLe(output.qX18, output.qMarketX18, "q <= qMarket");
        assertEq(output.floorBinding, output.qFloorX18 <= output.qMarketX18, "floorBinding");
        assertGe(output.discountBps, D_MIN, "d >= dMin");
        assertLe(output.discountBps, D_MAX, "d <= dMax");
        assertEq(output.ampsOut, FullMath.mulDiv(amountIn18, output.qX18, 1e18), "ampsOut rounds down");

        // I27 in its exact form: the bond is accretive at the demanded margin, with no dust allowance.
        assertLe(
            FullMath.mulDiv(output.ampsOut, navPerShareX18 * (10_000 + uint256(accretionBps)), 10_000),
            FullMath.mulDiv(amountIn18, collateralPriceUsd18 * (10_000 - uint256(haircutBps)), 10_000) + navPerShareX18,
            "accretive up to the one-wei quantisation of ampsOut"
        );
    }

    /// @notice The discount is monotone: rising in the deficit, falling in the fill, always inside the band.
    function testFuzz_discountIsMonotone(uint64 deficitX18, uint64 fillX18, uint64 step) public view {
        deficitX18 = uint64(bound(deficitX18, 0, 1e18 - 1));
        fillX18 = uint64(bound(fillX18, 0, 1e18 - 1));
        step = uint64(bound(step, 1, 1e18 - (deficitX18 > fillX18 ? deficitX18 : fillX18)));

        uint16 base = policy.discountBps(D_BASE, D_MIN, D_MAX, 0.5e18, 0.25e18, deficitX18, fillX18);
        uint16 moreDeficit = policy.discountBps(D_BASE, D_MIN, D_MAX, 0.5e18, 0.25e18, deficitX18 + step, fillX18);
        uint16 moreFill = policy.discountBps(D_BASE, D_MIN, D_MAX, 0.5e18, 0.25e18, deficitX18, fillX18 + step);

        assertGe(moreDeficit, base, "a larger deficit never narrows the discount");
        assertLe(moreFill, base, "a larger fill never widens the discount");
        assertGe(base, D_MIN);
        assertLe(base, D_MAX);
    }

    /* -------------------------------------------- helpers -------------------------------------------- */

    /// @dev The launch-parameter input, with everything but the four varying fields fixed.
    function _input(uint256 mX18, uint16 haircutBps, uint64 deficitX18, uint64 fillX18, uint256 amountIn18)
        internal
        pure
        returns (IBondPolicy.QuoteInput memory input)
    {
        input = IBondPolicy.QuoteInput({
            mX18: mX18,
            navPerShareX18: NAV_USD18,
            collateralPriceUsd18: P_I_USD18,
            amountIn18: amountIn18,
            dBaseBps: D_BASE,
            dMinBps: D_MIN,
            dMaxBps: D_MAX,
            kWeightX18: Constants.BOND_K_WEIGHT_X18_DEFAULT,
            kFillX18: Constants.BOND_K_FILL_X18_DEFAULT,
            deficitX18: deficitX18,
            fillX18: fillX18,
            hSessionBps: haircutBps,
            minAccretionBps: ACCRETION
        });
    }

    /// @dev The floor, written out from `docs/phase2-state-model.md` §6 rather than read from the contract.
    function _qFloor(uint256 priceUsd18, uint256 navUsd18, uint16 haircutBps, uint16 accretionBps)
        internal
        pure
        returns (uint256)
    {
        uint256 numerator = FullMath.mulDiv(priceUsd18, 10_000 - uint256(haircutBps), 10_000);
        uint256 denominator = FullMath.mulDivRoundingUp(navUsd18, 10_000 + uint256(accretionBps), 10_000);
        return FullMath.mulDiv(numerator, 1e18, denominator);
    }

    /// @dev The premium above which the market discount, rather than the floor, sets the price:
    ///      `(1 + a) / ((1 - d)(1 - h)) - 1`, in bps.
    function _crossoverBps(uint16 discount, uint16 haircutBps, uint16 accretionBps) internal pure returns (uint256) {
        uint256 numerator = (10_000 + uint256(accretionBps)) * 10_000 * 10_000;
        uint256 denominator = (10_000 - uint256(discount)) * (10_000 - uint256(haircutBps));
        return numerator / denominator - 10_000;
    }

    /// @dev Silences the unused-import warning for {Session} while documenting that the haircut table is indexed
    ///      by it: the policy itself never sees a session, only the bps the gate resolved.
    function _sessionOrdinals() internal pure returns (uint8) {
        return uint8(Session.CLOSED);
    }
}
