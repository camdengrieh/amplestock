// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeePolicy} from "../../src/interfaces/IFeePolicy.sol";
import {FeePolicy} from "../../src/policy/FeePolicy.sol";
import {Constants} from "../../src/types/Constants.sol";
import {OutOfBand} from "../../src/types/Errors.sol";
import {GateState, PoolClass, Session} from "../../src/types/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Unit tests for the launch fee law: the fee table by direction, class, session and gate state, the
///         rotation blend, the deviation wall, and the surge and dividend-capture decay curves at `t = 0`, one
///         half-life, five half-lives and the zero point.
///
/// @dev `FeePolicy` declares `is IFeePolicy`, so the compiler enforces conformance; §12.1's resolution of the
///      `pure`-versus-`immutable` collision made `IFeePolicy.quoteFee` `view`. The two conformance tests below are
///      kept anyway because they are what catches an ABI drift that still compiles: selector equality resolved at
///      compile time, and every member *called* through an `IFeePolicy` handle across a real call boundary, which
///      is what `AmpsHook`'s hand-decoded `staticcall` does.
contract FeePolicyTest is Test {
    FeePolicy internal policy;

    uint16 internal constant SELL = 500;
    uint16 internal constant BUY_ENTRY = 30;
    uint16 internal constant BUY_SPOKE = 5;

    function setUp() public {
        policy = new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18);
    }

    /* ------------------------------------------- identity ------------------------------------------- */

    function test_version() public view {
        assertEq(policy.version(), bytes32("directional-wall-v1"));
    }

    /// @dev Member-for-member ABI conformance against the frozen interface, resolved at compile time.
    function test_selectorsMatchIFeePolicy() public pure {
        assertEq(FeePolicy.quoteFee.selector, IFeePolicy.quoteFee.selector, "quoteFee");
        assertEq(FeePolicy.innerBandTicks.selector, IFeePolicy.innerBandTicks.selector, "innerBandTicks");
        assertEq(FeePolicy.outerRailTicks.selector, IFeePolicy.outerRailTicks.selector, "outerRailTicks");
        assertEq(FeePolicy.surgeDecay.selector, IFeePolicy.surgeDecay.selector, "surgeDecay");
        assertEq(FeePolicy.captureDecay.selector, IFeePolicy.captureDecay.selector, "captureDecay");
        assertEq(FeePolicy.F_MIN_BPS.selector, IFeePolicy.F_MIN_BPS.selector, "F_MIN_BPS");
        assertEq(FeePolicy.DYN_CAP_NORMAL_BPS.selector, IFeePolicy.DYN_CAP_NORMAL_BPS.selector, "DYN_CAP_NORMAL_BPS");
        assertEq(
            FeePolicy.DYN_CAP_DEGRADED_BPS.selector, IFeePolicy.DYN_CAP_DEGRADED_BPS.selector, "DYN_CAP_DEGRADED_BPS"
        );
        assertEq(
            FeePolicy.DYN_CAP_ESCALATION_BPS.selector,
            IFeePolicy.DYN_CAP_ESCALATION_BPS.selector,
            "DYN_CAP_ESCALATION_BPS"
        );
        assertEq(FeePolicy.SURGE_MAX_BPS.selector, IFeePolicy.SURGE_MAX_BPS.selector, "SURGE_MAX_BPS");
        assertEq(FeePolicy.F_VOL_CAP_BPS.selector, IFeePolicy.F_VOL_CAP_BPS.selector, "F_VOL_CAP_BPS");
        assertEq(FeePolicy.TOTAL_FEE_BPS_MAX.selector, IFeePolicy.TOTAL_FEE_BPS_MAX.selector, "TOTAL_FEE_BPS_MAX");
        assertEq(
            FeePolicy.FROZEN_FEE_FLOOR_BPS.selector, IFeePolicy.FROZEN_FEE_FLOOR_BPS.selector, "FROZEN_FEE_FLOOR_BPS"
        );
        assertEq(FeePolicy.K_VOL_X18.selector, IFeePolicy.K_VOL_X18.selector, "K_VOL_X18");
        assertEq(FeePolicy.K_DEV_BPS.selector, IFeePolicy.K_DEV_BPS.selector, "K_DEV_BPS");
        assertEq(FeePolicy.F_WALL_BPS.selector, IFeePolicy.F_WALL_BPS.selector, "F_WALL_BPS");
        assertEq(FeePolicy.LAMBDA_X18.selector, IFeePolicy.LAMBDA_X18.selector, "LAMBDA_X18");
        assertEq(FeePolicy.version.selector, IFeePolicy.version.selector, "version");
    }

    /// @dev Every member reached through an `IFeePolicy` handle, which is exactly how `AmpsHook` and `AmpsQuoter`
    ///      will reach them: a `pure` declaration on the caller's side compiles to `STATICCALL`, which this
    ///      contract's `view` implementation satisfies.
    function test_everyMemberIsCallableThroughTheInterface() public view {
        IFeePolicy handle = IFeePolicy(address(policy));

        IFeePolicy.FeeQuote memory quote = handle.quoteFee(_buy());
        assertEq(quote.baseBps, BUY_ENTRY, "the interface handle returns the same quote");

        assertEq(handle.innerBandTicks(PoolClass.SPOKE, Session.REGULAR, 0), Constants.INNER_BAND_REGULAR_TICKS);
        assertEq(handle.outerRailTicks(PoolClass.ENTRY, 200), Constants.OUTER_RAIL_ENTRY_TICKS);
        assertEq(handle.surgeDecay(Constants.SURGE_MAX_BPS, 0), Constants.SURGE_MAX_BPS);
        assertEq(handle.captureDecay(160, 0), 160);
        assertEq(handle.F_MIN_BPS(), Constants.F_MIN_BPS);
        assertEq(handle.DYN_CAP_NORMAL_BPS(), Constants.DYN_CAP_NORMAL_BPS);
        assertEq(handle.DYN_CAP_DEGRADED_BPS(), Constants.DYN_CAP_DEGRADED_BPS);
        assertEq(handle.DYN_CAP_ESCALATION_BPS(), Constants.DYN_CAP_ESCALATION_BPS);
        assertEq(handle.SURGE_MAX_BPS(), Constants.SURGE_MAX_BPS);
        assertEq(handle.F_VOL_CAP_BPS(), Constants.F_VOL_CAP_BPS);
        assertEq(handle.TOTAL_FEE_BPS_MAX(), Constants.TOTAL_FEE_BPS_MAX);
        assertEq(handle.FROZEN_FEE_FLOOR_BPS(), Constants.FROZEN_FEE_FLOOR_BPS);
        assertEq(handle.K_VOL_X18(), Constants.K_VOL_X18);
        assertEq(handle.K_DEV_BPS(), Constants.K_DEV_BPS);
        assertEq(handle.F_WALL_BPS(), Constants.F_WALL_BPS);
        assertEq(handle.LAMBDA_X18(), Constants.LAMBDA_X18);
        assertEq(handle.version(), bytes32("directional-wall-v1"));
    }

    /* ------------------------------------ the coefficients and their bands ------------------------------------ */

    function test_coefficientsAreWhatTheDeploymentWasGiven() public {
        FeePolicy tuned = new FeePolicy(
            Constants.K_VOL_X18_MAX, Constants.K_DEV_BPS_MAX, Constants.F_WALL_BPS_MIN, Constants.LAMBDA_X18_MIN
        );
        assertEq(tuned.K_VOL_X18(), Constants.K_VOL_X18_MAX, "k_vol");
        assertEq(tuned.K_DEV_BPS(), Constants.K_DEV_BPS_MAX, "k_dev");
        assertEq(tuned.F_WALL_BPS(), Constants.F_WALL_BPS_MIN, "f_wall");
        assertEq(tuned.LAMBDA_X18(), Constants.LAMBDA_X18_MIN, "lambda");
    }

    function test_revert_constructorRejectsEveryCoefficientOutsideItsBand() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("K_VOL_X18"),
                Constants.K_VOL_X18_MIN - 1,
                Constants.K_VOL_X18_MIN,
                Constants.K_VOL_X18_MAX
            )
        );
        new FeePolicy(Constants.K_VOL_X18_MIN - 1, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("K_DEV_BPS"),
                uint256(Constants.K_DEV_BPS_MAX) + 1,
                Constants.K_DEV_BPS_MIN,
                Constants.K_DEV_BPS_MAX
            )
        );
        new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS_MAX + 1, Constants.F_WALL_BPS, Constants.LAMBDA_X18);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("F_WALL_BPS"),
                uint256(Constants.F_WALL_BPS_MIN) - 1,
                Constants.F_WALL_BPS_MIN,
                Constants.F_WALL_BPS_MAX
            )
        );
        new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS_MIN - 1, Constants.LAMBDA_X18);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("LAMBDA_X18"),
                uint256(Constants.LAMBDA_X18_MAX) + 1,
                Constants.LAMBDA_X18_MIN,
                Constants.LAMBDA_X18_MAX
            )
        );
        new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18_MAX + 1);
    }

    /* --------------------------------------------- the fee table --------------------------------------------- */

    /// @dev The launch table with nothing armed: a buy pays its pool's buy fee and a sell pays `sellFeeBps`,
    ///      with no dynamic component at all.
    function test_feeTableAtRest() public view {
        // entry pool buy / sell
        _assertFee(_buy(), BUY_ENTRY, 0);
        _assertFee(_sell(), SELL, 0);

        // spoke buy / sell
        IFeePolicy.FeeInput memory input = _buy();
        input.poolClass = PoolClass.SPOKE;
        input.buyFeeBps = BUY_SPOKE;
        _assertFee(input, BUY_SPOKE, 0);

        input = _sell();
        input.poolClass = PoolClass.SPOKE;
        input.buyFeeBps = BUY_SPOKE;
        _assertFee(input, SELL, 0);

        // high-volatility spoke buy: same law, a different governed buy fee
        input = _buy();
        input.poolClass = PoolClass.SPOKE_HIGH_VOL;
        input.buyFeeBps = 10;
        _assertFee(input, 10, 0);
    }

    /// @dev `f_session` is 0 / 5 / 10 / 25 bp and applies to **stock legs only**: an entry pool passes
    ///      `Session.REGULAR` unconditionally, but even if it did not, it would pay nothing.
    function test_sessionAddOnAppliesToStockLegsOnly() public view {
        uint16[4] memory expected = [
            Constants.F_SESSION_REGULAR_BPS,
            Constants.F_SESSION_PRE_POST_BPS,
            Constants.F_SESSION_OVERNIGHT_BPS,
            Constants.F_SESSION_CLOSED_BPS
        ];

        for (uint256 s = 0; s < 4; ++s) {
            IFeePolicy.FeeInput memory spoke = _sell();
            spoke.poolClass = PoolClass.SPOKE;
            spoke.session = Session(s);
            _assertFee(spoke, SELL, expected[s]);

            IFeePolicy.FeeInput memory entry = _sell();
            entry.session = Session(s);
            _assertFee(entry, SELL, 0);
        }
    }

    /// @dev A gate that is not GREEN floors the dynamic part at `FROZEN_FEE_FLOOR_BPS` and never refuses (I15).
    function test_gateStateFloorsTheDynamicPartAndNeverRefuses() public view {
        GateState[5] memory degraded = [
            GateState.DEGRADED,
            GateState.DIVERGED,
            GateState.REF_DIVERGED,
            GateState.SCHEDULED_FREEZE,
            GateState.WATCHDOG
        ];
        for (uint256 g = 0; g < degraded.length; ++g) {
            IFeePolicy.FeeInput memory input = _sell();
            input.gate = degraded[g];
            IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
            assertEq(quote.dynBps, Constants.FROZEN_FEE_FLOOR_BPS, "the dynamic floor is in force");
            assertEq(quote.baseBps, SELL, "the base is untouched");
            assertFalse(quote.refuse, "a gate reason never refuses a swap");
        }

        IFeePolicy.FeeInput memory green = _sell();
        assertEq(policy.quoteFee(green).dynBps, 0, "GREEN has no floor");
    }

    /// @dev `dynCapBps` per gate state: the dynamic part is capped, the base never is. Beyond the rail `f_dev`
    ///      alone is `F_WALL_BPS = 1500`, so the NORMAL and DEGRADED caps bind and the ESCALATION cap does not
    ///      until something else is armed on top.
    function test_dynamicCapPerGateState() public view {
        uint16[3] memory caps =
            [Constants.DYN_CAP_NORMAL_BPS, Constants.DYN_CAP_DEGRADED_BPS, Constants.DYN_CAP_ESCALATION_BPS];

        for (uint256 c = 0; c < caps.length; ++c) {
            IFeePolicy.FeeInput memory input = _sell();
            input.deviationIncreasing = true;
            input.devTicks = 5000; // far beyond the rail: f_dev alone is F_WALL_BPS
            input.dynCapBps = caps[c];
            uint16 expected = caps[c] < Constants.F_WALL_BPS ? caps[c] : Constants.F_WALL_BPS;

            IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
            assertEq(quote.dynBps, expected, "the dynamic part is capped at the gate's cap");
            assertEq(quote.baseBps, SELL, "the base is not capped");
            assertEq(uint256(quote.feePips), (uint256(SELL) + expected) * Constants.PIPS_PER_BPS, "fee == base + dyn");
        }

        // The escalation cap binds once the wall is joined by a surge and a closed-session add-on: 1500 + 500 + 25.
        IFeePolicy.FeeInput memory loaded = _spokeSell();
        loaded.deviationIncreasing = true;
        loaded.devTicks = 5000;
        loaded.dynCapBps = Constants.DYN_CAP_ESCALATION_BPS;
        loaded.surgeBps = Constants.SURGE_MAX_BPS;
        loaded.session = Session.CLOSED;
        assertEq(policy.quoteFee(loaded).dynBps, Constants.DYN_CAP_ESCALATION_BPS, "and the escalation cap binds");
    }

    /// @dev I16's ceiling: 600 bp of sell fee plus a 2,000 bp escalation cap is 2,600 bp, which is
    ///      `TOTAL_FEE_BPS_MAX` and a long way below `MAX_LP_FEE`.
    function test_theLargestPossibleFeeIsTotalFeeBpsMax() public view {
        IFeePolicy.FeeInput memory input = _sell();
        input.sellFeeBps = Constants.SELL_FEE_BPS_MAX;
        input.deviationIncreasing = true;
        input.devTicks = type(int24).max;
        input.dynCapBps = Constants.DYN_CAP_ESCALATION_BPS;
        input.surgeBps = Constants.SURGE_MAX_BPS;
        input.session = Session.CLOSED;
        input.poolClass = PoolClass.SPOKE;

        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
        assertEq(uint256(quote.baseBps) + quote.dynBps, Constants.TOTAL_FEE_BPS_MAX, "2,600 bp");
        assertEq(uint256(quote.feePips), uint256(Constants.TOTAL_FEE_BPS_MAX) * Constants.PIPS_PER_BPS);
        assertLt(uint256(quote.feePips), Constants.MAX_LP_FEE, "far below v4's ceiling");
    }

    /// @dev A base fee outside its own governed band cannot push the total past the ceiling: the excess is shaved
    ///      off the dynamic part first and then off the base, so the returned decomposition stays exact.
    function test_anOutOfBandBaseIsClampedIntoTheCeiling() public view {
        IFeePolicy.FeeInput memory input = _sell();
        input.sellFeeBps = type(uint16).max;
        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
        assertEq(quote.baseBps, Constants.TOTAL_FEE_BPS_MAX, "the base absorbs the ceiling");
        assertEq(quote.dynBps, 0, "and the dynamic part is gone");
        assertEq(uint256(quote.feePips), uint256(Constants.TOTAL_FEE_BPS_MAX) * Constants.PIPS_PER_BPS);
    }

    /// @dev The absolute floor: a pool whose buy fee has been governed to zero still charges `F_MIN_BPS`.
    function test_theFloorIsFMinBps() public view {
        IFeePolicy.FeeInput memory input = _buy();
        input.buyFeeBps = 0;
        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
        assertEq(uint256(quote.baseBps) + quote.dynBps, Constants.F_MIN_BPS, "3 bp");
        assertEq(uint256(quote.feePips), uint256(Constants.F_MIN_BPS) * Constants.PIPS_PER_BPS);
    }

    /* ------------------------------------------ the rotation blend ------------------------------------------ */

    function test_rotationBlendIsExactWhenItDivides() public view {
        IFeePolicy.FeeInput memory input = _sell();
        input.poolClass = PoolClass.SPOKE;
        input.buyFeeBps = BUY_ENTRY;
        input.amountIn = 1000;
        input.rotationCredit = 400;

        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
        // (30 * 400 + 500 * 600) / 1000 == 312
        assertEq(quote.baseBps, 312, "the blended base");
        assertEq(quote.creditConsumed, 400, "the hook decrements by exactly this");
    }

    function test_rotationBlendRoundsUp() public view {
        IFeePolicy.FeeInput memory input = _sell();
        input.buyFeeBps = BUY_ENTRY;
        input.amountIn = 1000;
        input.rotationCredit = 333;

        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
        // (30 * 333 + 500 * 667) / 1000 == 343.49, rounded **up** against the swapper.
        assertEq(quote.baseBps, 344, "the blend never rounds a fee down");
        assertEq(quote.creditConsumed, 333);
    }

    function test_aFullCreditPaysTheBuyFeeAndConsumesOnlyWhatItNeeds() public view {
        IFeePolicy.FeeInput memory input = _sell();
        input.buyFeeBps = BUY_ENTRY;
        input.amountIn = 1000;
        input.rotationCredit = 5000;

        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
        assertEq(quote.baseBps, BUY_ENTRY, "a fully credited sell pays the buy fee");
        assertEq(quote.creditConsumed, 1000, "and consumes only the amount it swapped");
    }

    function test_exactOutputSellsAndBuysConsumeNoCredit() public view {
        IFeePolicy.FeeInput memory input = _sell();
        input.exactInput = false;
        input.amountIn = 0;
        input.rotationCredit = 5000;
        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
        assertEq(quote.baseBps, SELL, "an exact-output sell pays the sell fee in full");
        assertEq(quote.creditConsumed, 0, "and consumes nothing");

        IFeePolicy.FeeInput memory buy = _buy();
        buy.rotationCredit = 5000;
        buy.amountIn = 1000;
        quote = policy.quoteFee(buy);
        assertEq(quote.baseBps, BUY_ENTRY, "a buy is a buy");
        assertEq(quote.creditConsumed, 0, "buys never consume credit");
    }

    /// @dev A one-wei credit unlocks one wei of buy-fee treatment and no more; the blend still rounds up.
    function test_aOneWeiCreditBuysOneWei() public view {
        IFeePolicy.FeeInput memory input = _sell();
        input.buyFeeBps = BUY_ENTRY;
        input.amountIn = 1e18;
        input.rotationCredit = 1;

        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
        assertEq(quote.baseBps, SELL, "one wei of credit does not move a whole basis point");
        assertEq(quote.creditConsumed, 1);
    }

    /* -------------------------------------- the deviation wall -------------------------------------- */

    /// @dev Inside the band, `f_dev = K_DEV_BPS * dev^2 / BPS`.
    function test_quadraticInsideTheBand() public view {
        assertEq(_devFee(0), 0, "no deviation, no fee");
        assertEq(_devFee(100), 25, "25 * 100^2 / 1e4");
        assertEq(_devFee(200), 100, "the band edge is 100 bp");
    }

    /// @dev Between band and rail the ramp is quadratic and reaches `F_WALL_BPS` exactly at the rail.
    function test_quadraticRampFromBandToRail() public view {
        // band 200, rail 800, inner 100, wall 1500.
        assertEq(_devFee(200), 100, "continuous at the band");
        assertEq(_devFee(500), 450, "100 + 1400 * 300^2 / 600^2");
        assertEq(_devFee(800), Constants.F_WALL_BPS, "the wall at the rail");
    }

    /// @dev Beyond the rail the fee holds at the wall and the swap is refused — but only on the
    ///      deviation-increasing side (I15).
    function test_refuseOnlyBeyondTheRailAndOnlyWhenDeviationIncreasing() public view {
        IFeePolicy.FeeInput memory input = _spokeSell();
        input.deviationIncreasing = true;
        input.devTicks = 801;
        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
        assertTrue(quote.refuse, "a deviation-increasing swap beyond the rail is refused");

        input.devTicks = 800;
        assertFalse(policy.quoteFee(input).refuse, "at the rail it is still accepted");

        input.devTicks = type(int24).max;
        input.deviationIncreasing = false;
        quote = policy.quoteFee(input);
        assertFalse(quote.refuse, "a price-improving swap is never refused, at any deviation");
        assertEq(quote.dynBps, 0, "and pays no f_dev");
    }

    /// @dev The band and the rail are inputs, not state: a wider band moves both joins with it.
    function test_theWallFollowsTheBandAndRail() public view {
        IFeePolicy.FeeInput memory input = _spokeSell();
        input.deviationIncreasing = true;
        input.session = Session.CLOSED;
        input.innerBandTicks = 770; // Closed
        input.outerRailTicks = 2310; // max(3 x 770, 800)
        input.dynCapBps = Constants.DYN_CAP_ESCALATION_BPS;

        // Inside: 25 * 770^2 / 1e4 == 1482 bp, plus the 25 bp closed-session add-on.
        input.devTicks = 770;
        assertEq(policy.quoteFee(input).dynBps, 1482 + Constants.F_SESSION_CLOSED_BPS, "the widened band edge");
        assertFalse(policy.quoteFee(input).refuse);

        input.devTicks = 2311;
        assertTrue(policy.quoteFee(input).refuse, "and the widened rail");
    }

    /// @dev A fee quote may never revert: it is the one thing that would turn a swap into a failed transaction for
    ///      a reason the swapper cannot see (I15). The extreme `int24` values are unreachable from a real
    ///      `|poolTick - fairTick|`, but they are the arithmetic edges, so they are pinned.
    function test_quoteNeverRevertsAtTheTickExtremes() public view {
        int24[3] memory extremes = [type(int24).min, type(int24).max, type(int24).min + 1];
        for (uint256 i = 0; i < extremes.length; ++i) {
            IFeePolicy.FeeInput memory input = _spokeSell();
            input.deviationIncreasing = true;
            input.devTicks = extremes[i];
            input.innerBandTicks = extremes[i];
            input.outerRailTicks = extremes[i];
            IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
            assertLe(uint256(quote.baseBps) + quote.dynBps, Constants.TOTAL_FEE_BPS_MAX, "still lawful");
        }
    }

    /// @dev A rail governed below the band is a misconfiguration, not a crash: everything above the rail is
    ///      refused and `f_dev` stays monotone.
    function test_aRailBelowTheBandStillBehaves() public view {
        IFeePolicy.FeeInput memory input = _spokeSell();
        input.deviationIncreasing = true;
        input.innerBandTicks = 1000;
        input.outerRailTicks = 100;
        input.dynCapBps = Constants.DYN_CAP_ESCALATION_BPS;

        input.devTicks = 100;
        IFeePolicy.FeeQuote memory atRail = policy.quoteFee(input);
        assertFalse(atRail.refuse, "at the rail it is still accepted");

        input.devTicks = 101;
        IFeePolicy.FeeQuote memory beyond = policy.quoteFee(input);
        assertTrue(beyond.refuse, "and one tick beyond it is refused");
        assertGe(beyond.dynBps, atRail.dynBps, "the curve never steps down");
    }

    /* ---------------------------------------- the band and rail tables ---------------------------------------- */

    /// @dev I19: the band is monotone non-decreasing in closedness and the breaker is not an input at all.
    function test_innerBandTable() public view {
        assertEq(policy.innerBandTicks(PoolClass.SPOKE, Session.REGULAR, 0), int24(200));
        assertEq(policy.innerBandTicks(PoolClass.SPOKE, Session.PRE_POST, 0), int24(300));
        assertEq(policy.innerBandTicks(PoolClass.SPOKE, Session.OVERNIGHT, 0), int24(500));
        assertEq(policy.innerBandTicks(PoolClass.SPOKE, Session.CLOSED, 0), int24(770));
        assertEq(policy.innerBandTicks(PoolClass.SPOKE, Session.CLOSED, 1), int24(795));
        assertEq(policy.innerBandTicks(PoolClass.SPOKE, Session.CLOSED, 29), int24(1495));
        assertEq(policy.innerBandTicks(PoolClass.SPOKE, Session.CLOSED, 30), int24(1500), "the cap binds");
        assertEq(policy.innerBandTicks(PoolClass.SPOKE, Session.CLOSED, type(uint16).max), int24(1500));

        // SPOKE_HIGH_VOL is the same band; only its buy fee differs.
        assertEq(policy.innerBandTicks(PoolClass.SPOKE_HIGH_VOL, Session.CLOSED, 10), int24(1020));
    }

    /// @dev Entry pools have no session widening: WETH and USDG trade 24/7.
    function test_entryPoolsIgnoreTheSession() public view {
        for (uint256 s = 0; s < 4; ++s) {
            assertEq(policy.innerBandTicks(PoolClass.ENTRY, Session(s), 100), Constants.INNER_BAND_REGULAR_TICKS);
            assertEq(policy.innerBandTicks(PoolClass.NONE, Session(s), 100), Constants.INNER_BAND_REGULAR_TICKS);
        }
    }

    function test_outerRailTable() public view {
        assertEq(policy.outerRailTicks(PoolClass.SPOKE, 200), int24(800), "max(600, 800)");
        assertEq(policy.outerRailTicks(PoolClass.SPOKE, 300), int24(900));
        assertEq(policy.outerRailTicks(PoolClass.SPOKE, 500), int24(1500));
        assertEq(policy.outerRailTicks(PoolClass.SPOKE, 770), int24(2310));
        assertEq(policy.outerRailTicks(PoolClass.SPOKE, 1500), int24(4500));
        assertEq(policy.outerRailTicks(PoolClass.SPOKE, 0), Constants.OUTER_RAIL_MIN_TICKS, "the floor holds");
        assertEq(policy.outerRailTicks(PoolClass.SPOKE, -1), Constants.OUTER_RAIL_MIN_TICKS, "a negative band too");

        assertEq(policy.outerRailTicks(PoolClass.ENTRY, 200), int24(2000), "entry pools are flat at 2,000");
        assertEq(policy.outerRailTicks(PoolClass.ENTRY, 1500), int24(2000));
    }

    /* ----------------------------------------- the decay curves ----------------------------------------- */

    /// @dev The surge: 500 bp armed, 60-second half-life, exactly zero at 8 half-lives.
    function test_surgeDecayCurve() public view {
        assertEq(policy.surgeDecay(500, 0), 500, "t = 0");
        assertEq(policy.surgeDecay(500, 30), 375, "half way through the first half-life, interpolated");
        assertEq(policy.surgeDecay(500, 60), 250, "one half-life");
        assertEq(policy.surgeDecay(500, 120), 125, "two");
        assertEq(policy.surgeDecay(500, 300), 15, "five half-lives: 500 >> 5");
        assertEq(policy.surgeDecay(500, 420), 3, "seven");
        assertEq(policy.surgeDecay(500, 480), 0, "eight half-lives is exactly zero");
        assertEq(policy.surgeDecay(500, type(uint32).max), 0, "and stays zero");
        assertEq(policy.surgeDecay(0, 0), 0, "nothing armed, nothing charged");
    }

    /// @dev The dividend capture is the same shape on the 300-second half-life, which is the whole reason
    ///      `captureDecay` exists as a second function (§11.4).
    function test_captureDecayCurveUsesTheDividendHalfLife() public view {
        assertEq(policy.captureDecay(160, 0), 160, "t = 0");
        assertEq(policy.captureDecay(160, 150), 120, "half way through the first half-life");
        assertEq(policy.captureDecay(160, 300), 80, "one half-life");
        assertEq(policy.captureDecay(160, 1500), 5, "five half-lives: 160 >> 5");
        assertEq(policy.captureDecay(160, 2400), 0, "eight half-lives");

        // The two curves are genuinely different: at 300 s the surge has decayed 5 half-lives, the capture 1.
        assertEq(policy.surgeDecay(160, 300), 5);
        assertEq(policy.captureDecay(160, 300), 80);
    }

    function test_decaysSaturateAtTheirCeilings() public view {
        assertEq(policy.surgeDecay(type(uint16).max, 0), Constants.SURGE_MAX_BPS, "a mis-armed surge is capped");
        // 0.8 x DIVIDEND_STEP_BPS_MAX == 160 bp is the largest capture a detected step can produce.
        assertEq(policy.captureDecay(type(uint16).max, 0), 160, "a mis-armed capture is capped");
    }

    /// @dev `f_div` is charged on the direction that takes the Stock Token out of the pool and on no other.
    function test_captureFeeAppliesToOneDirectionOnly() public view {
        IFeePolicy.FeeInput memory input = _spokeSell();
        input.captureFeeBps = 160;
        input.captureElapsed = 0;
        input.captureDirectionTakesStock = true;
        assertEq(policy.quoteFee(input).dynBps, 160, "the stock-out direction pays the toll");

        input.captureDirectionTakesStock = false;
        assertEq(policy.quoteFee(input).dynBps, 0, "the other direction pays nothing");
    }

    /// @dev A placement arms the surge, so the swap immediately after a placement pays the whole of it.
    function test_surgeEntersTheDynamicPart() public view {
        IFeePolicy.FeeInput memory input = _sell();
        input.surgeBps = Constants.SURGE_MAX_BPS;
        input.dynCapBps = Constants.DYN_CAP_ESCALATION_BPS;
        assertEq(policy.quoteFee(input).dynBps, Constants.SURGE_MAX_BPS, "armed");

        input.surgeElapsed = 480;
        assertEq(policy.quoteFee(input).dynBps, 0, "decayed away");
    }

    /* ------------------------------------------- f_vol ------------------------------------------- */

    /// @dev §12.1 ruling H's calibration, on the `uint128` field: `f_vol = min(K_VOL_X18 * varianceX18 / 1e36,
    ///      F_VOL_CAP_BPS)` with `varianceX18 = EWMA(d^2) * 1e18` and `d` the raw tick change of one swap. At the
    ///      launch `K_VOL_X18 = 5e15` a per-swap sigma of ~14 ticks is the first basis point and ~141 ticks is the
    ///      100 bp cap. The divide floors, so 14 ticks exactly (0.98 bp) is still 0 and 14.15 is the first whole
    ///      one; the widened field is what makes any of this reachable, a `uint64` having saturated at 18.45
    ///      ticks^2.
    function test_volatilityComponentCalibration() public view {
        // sigma = 14 ticks: 0.98 bp, floored to zero.
        assertEq(_volFee(196e18), 0, "sigma 14 is just under the first basis point");
        // The first whole basis point: sigma^2 = 200, sigma ~ 14.15 ticks.
        assertEq(_volFee(200e18), 1, "5e15 * 2e20 / 1e36 == 1 bp");
        // sigma = 141 ticks: 99.405 bp, floored.
        assertEq(_volFee(uint128(141) * 141 * 1e18), 99, "sigma 141 is 99 bp");
        // sigma = 142 ticks: 100.82 bp, at the cap.
        assertEq(_volFee(uint128(142) * 142 * 1e18), Constants.F_VOL_CAP_BPS, "sigma 142 reaches the cap");
        // And nothing above it can exceed the cap, including the widest value the field can hold.
        assertEq(_volFee(1e30), Constants.F_VOL_CAP_BPS, "capped");
        assertEq(_volFee(type(uint128).max), Constants.F_VOL_CAP_BPS, "capped at the field's ceiling, no revert");
    }

    /// @dev Monotone non-decreasing in variance across the whole reachable range: a noisier pool never costs less.
    function test_volatilityComponentIsMonotoneInVariance() public view {
        uint128[7] memory points =
            [uint128(0), 196e18, 200e18, 1e21, 1e22, uint128(141) * 141 * 1e18, type(uint128).max];
        uint16 previous;
        for (uint256 i = 0; i < points.length; ++i) {
            uint16 fee = _volFee(points[i]);
            if (i > 0 && points[i] >= points[i - 1]) assertGe(fee, previous, "f_vol is monotone in variance");
            previous = fee;
        }
    }

    /// @dev The coefficient is the whole calibration knob, and it is a pointer swap: the same variance costs
    ///      twenty times more at the band ceiling than at launch.
    function test_volatilityComponentScalesWithTheCoefficient() public {
        FeePolicy tuned =
            new FeePolicy(Constants.K_VOL_X18_MAX, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18);
        IFeePolicy.FeeInput memory input = _sell();
        input.varianceX18 = 200e18;
        // 1e17 * 2e20 / 1e36 == 20 bp, against 1 bp at the launch coefficient.
        assertEq(tuned.quoteFee(input).dynBps, 20, "k_vol scales the term linearly");
        assertEq(_volFee(200e18), 1, "the launch law is unchanged");
    }

    /* -------------------------------------------- composition -------------------------------------------- */

    /// @dev Every component at once on a closed-session spoke, decomposed exactly.
    function test_theWholeDynamicPartComposes() public view {
        IFeePolicy.FeeInput memory input = _spokeSell();
        input.session = Session.CLOSED; // +25 bp
        input.deviationIncreasing = true;
        input.devTicks = 100; // 25 bp
        input.surgeBps = 500;
        input.surgeElapsed = 60; // 250 bp
        input.captureFeeBps = 160;
        input.captureElapsed = 300; // 80 bp
        input.captureDirectionTakesStock = true;
        input.dynCapBps = Constants.DYN_CAP_ESCALATION_BPS;

        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
        assertEq(quote.dynBps, 25 + 25 + 250 + 80, "f_session + f_dev + surge + f_div");
        assertEq(quote.baseBps, SELL, "the base is the sell fee");
        assertEq(uint256(quote.feePips), (uint256(SELL) + 380) * Constants.PIPS_PER_BPS, "fee == base + dyn");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev An entry-pool buy at rest: nothing armed, no deviation, a green gate.
    function _buy() private pure returns (IFeePolicy.FeeInput memory input) {
        input = IFeePolicy.FeeInput({
            zeroForOne: false,
            exactInput: true,
            deviationIncreasing: false,
            amountIn: 0,
            rotationCredit: 0,
            poolClass: PoolClass.ENTRY,
            sellFeeBps: SELL,
            buyFeeBps: BUY_ENTRY,
            devTicks: 0,
            innerBandTicks: Constants.INNER_BAND_REGULAR_TICKS,
            outerRailTicks: Constants.OUTER_RAIL_MIN_TICKS,
            varianceX18: 0,
            surgeBps: 0,
            surgeElapsed: 0,
            captureFeeBps: 0,
            captureElapsed: 0,
            captureDirectionTakesStock: false,
            session: Session.REGULAR,
            gate: GateState.GREEN,
            dynCapBps: Constants.DYN_CAP_NORMAL_BPS
        });
    }

    function _sell() private pure returns (IFeePolicy.FeeInput memory input) {
        input = _buy();
        input.zeroForOne = true;
    }

    function _spokeSell() private pure returns (IFeePolicy.FeeInput memory input) {
        input = _sell();
        input.poolClass = PoolClass.SPOKE;
        input.buyFeeBps = BUY_SPOKE;
    }

    function _assertFee(IFeePolicy.FeeInput memory input, uint16 expectedBase, uint16 expectedDyn) private view {
        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);
        assertEq(quote.baseBps, expectedBase, "base");
        assertEq(quote.dynBps, expectedDyn, "dyn");
        assertEq(
            uint256(quote.feePips),
            (uint256(expectedBase) + expectedDyn) * Constants.PIPS_PER_BPS,
            "feePips == (base + dyn) x 100"
        );
        assertFalse(quote.refuse, "at rest nothing is refused");
    }

    /// @dev `f_vol` alone: an entry-pool sell with no deviation, no surge, no capture and a green gate, so the
    ///      dynamic part is exactly the volatility term.
    function _volFee(uint128 varianceX18) private view returns (uint16) {
        IFeePolicy.FeeInput memory input = _sell();
        input.varianceX18 = varianceX18;
        return policy.quoteFee(input).dynBps;
    }

    /// @dev `f_dev` alone, on a spoke sell with the launch band and rail and no other component armed.
    function _devFee(int24 devTicks) private view returns (uint16) {
        IFeePolicy.FeeInput memory input = _spokeSell();
        input.deviationIncreasing = true;
        input.devTicks = devTicks;
        input.dynCapBps = Constants.DYN_CAP_ESCALATION_BPS;
        return policy.quoteFee(input).dynBps;
    }
}
