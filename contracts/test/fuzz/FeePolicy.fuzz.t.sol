// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeePolicy} from "../../src/interfaces/IFeePolicy.sol";
import {FeePolicy} from "../../src/policy/FeePolicy.sol";
import {Constants} from "../../src/types/Constants.sol";
import {OutOfBand} from "../../src/types/Errors.sol";
import {GateState, PoolClass, Session} from "../../src/types/Types.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Property tests for the fee law (`docs/phase3-state-model.md` §8.1): monotone in `dev`, continuous at
///         the band and at the rail, `refuse` only on a deviation-increasing swap beyond the rail (I15), totals
///         bounded by `base + dynCap` and by `TOTAL_FEE_BPS_MAX` (I16), the band monotone in closedness (I19), and
///         every constructor coefficient rejected outside its band.
///
/// @dev Deviations are bounded to `[0, 50_000]` ticks and bands to `[1, 400]`. That box covers every reachable
///      state — the widest inner band is 1,500 ticks and the widest rail 4,500, and `TruncatedOracleLib` caps how
///      far a pool can move inside a window — while keeping `K_DEV_BPS x band^2 / BPS` below the escalation cap so
///      the shape of `f_dev` is observable rather than clipped by `dynCapBps` in every run.
contract FeePolicyFuzzTest is Test {
    FeePolicy internal policy;

    int24 internal constant MAX_DEV = 50_000;
    int24 internal constant MAX_BAND = 400;
    int24 internal constant MIN_SPAN = 100;

    /// @dev The whole fuzzed swap state, bundled so the property bodies stay inside solc's stack limit.
    struct Swap {
        bool zeroForOne;
        bool exactInput;
        bool deviationIncreasing;
        uint256 amountIn;
        uint256 rotationCredit;
        uint16 sellFeeBps;
        uint16 buyFeeBps;
        int24 devTicks;
        int24 band;
        int24 rail;
        uint128 varianceX18;
        uint16 dynCapBps;
        uint8 poolClass;
        uint8 session;
        uint8 gate;
    }

    function setUp() public {
        policy = new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The deviation wall
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `f_dev` is monotone non-decreasing in `dev`, everywhere: inside the band, along the ramp, across both
    ///      joins and beyond the rail. A larger gap can never cost less to widen.
    function testFuzz_monotoneInDeviation(int24 bandSeed, int24 railSeed, int24 devSeed, int24 stepSeed) public view {
        (int24 band, int24 rail) = _bandAndRail(bandSeed, railSeed);
        int24 devA = int24(bound(devSeed, 0, MAX_DEV));
        int24 devB = devA + int24(bound(stepSeed, 0, MAX_DEV));

        uint16 feeA = _dynFor(devA, band, rail);
        uint16 feeB = _dynFor(devB, band, rail);
        assertLe(feeA, feeB, "f_dev is monotone non-decreasing in dev");
    }

    /// @dev Continuity at the band: the quadratic and the ramp agree there, and one tick either side moves the fee
    ///      by less than the whole inner value. Continuity at the rail: the ramp reaches `F_WALL_BPS` exactly, and
    ///      the first refused tick charges the same thing.
    function testFuzz_continuousAtTheBandAndAtTheRail(int24 bandSeed, int24 railSeed) public view {
        (int24 band, int24 rail) = _bandAndRail(bandSeed, railSeed);

        uint256 inner =
            uint256(uint24(Constants.K_DEV_BPS)) * uint256(uint24(band)) * uint256(uint24(band)) / Constants.BPS;
        assertEq(_dynFor(band, band, rail), uint16(inner), "the band edge is the quadratic's value");
        assertEq(_dynFor(band + 1, band, rail), uint16(inner), "and the ramp starts from it");

        assertEq(_dynFor(rail, band, rail), Constants.F_WALL_BPS, "the ramp reaches the wall at the rail");
        assertEq(_dynFor(rail + 1, band, rail), Constants.F_WALL_BPS, "and holds it beyond");
    }

    /// @dev I15: `refuse` is true if and only if the swap increases the deviation **and** starts beyond the rail.
    ///      Nothing else — no gate state, no session, no surge, no volatility — can refuse a swap.
    function testFuzz_refuseOnlyWhenDeviationIncreasingBeyondTheRail(Swap memory swap) public view {
        IFeePolicy.FeeInput memory input = _input(swap);
        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);

        bool beyond = input.deviationIncreasing && _abs(input.devTicks) > _nonNegative(input.outerRailTicks);
        assertEq(quote.refuse, beyond, "refuse == deviationIncreasing && dev > rail");

        if (!input.deviationIncreasing) {
            IFeePolicy.FeeInput memory quiet = _input(swap);
            quiet.devTicks = 0;
            assertEq(quote.dynBps, policy.quoteFee(quiet).dynBps, "a price-improving swap pays no deviation component");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Totals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev I16: the returned fee decomposes exactly as `base + dyn`, the dynamic part respects its cap (except
    ///      where the `F_MIN_BPS` floor lifts it), and the total never leaves `[F_MIN_BPS, TOTAL_FEE_BPS_MAX]`.
    function testFuzz_totalsAreBounded(Swap memory swap) public view {
        IFeePolicy.FeeInput memory input = _input(swap);
        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);

        uint256 total = uint256(quote.baseBps) + quote.dynBps;
        assertEq(uint256(quote.feePips), total * Constants.PIPS_PER_BPS, "fee == (base + dyn) x PIPS_PER_BPS");
        assertGe(total, Constants.F_MIN_BPS, "the absolute floor");
        assertLe(total, Constants.TOTAL_FEE_BPS_MAX, "the absolute ceiling");
        assertLe(uint256(quote.feePips), Constants.MAX_LP_FEE, "and v4's own ceiling");

        uint256 cap = input.dynCapBps > Constants.F_MIN_BPS ? input.dynCapBps : Constants.F_MIN_BPS;
        assertLe(quote.dynBps, cap, "the dynamic part respects its cap, up to the F_MIN_BPS floor");
    }

    /// @dev A degraded gate raises the fee and never lowers it, and never refuses.
    function testFuzz_aDegradedGateOnlyRaisesTheFee(Swap memory swap) public view {
        // Two independently built structs: a memory struct assignment copies the reference, not the value.
        IFeePolicy.FeeInput memory green = _input(swap);
        green.gate = GateState.GREEN;
        green.dynCapBps = Constants.DYN_CAP_ESCALATION_BPS;

        IFeePolicy.FeeInput memory degraded = _input(swap);
        degraded.gate = GateState.DEGRADED;
        degraded.dynCapBps = Constants.DYN_CAP_ESCALATION_BPS;

        IFeePolicy.FeeQuote memory a = policy.quoteFee(green);
        IFeePolicy.FeeQuote memory b = policy.quoteFee(degraded);
        assertGe(b.dynBps, a.dynBps, "a degraded gate never lowers the dynamic part");
        assertEq(b.refuse, a.refuse, "and never changes the refusal");
    }

    /// @dev The blended base always lies between the two fees it blends, and the credit consumed is exactly
    ///      `min(amountIn, rotationCredit)` on an exact-input sell and nothing anywhere else (I26).
    function testFuzz_theRotationBlendIsBoundedAndAccountsExactly(Swap memory swap) public view {
        swap.sellFeeBps = uint16(bound(swap.sellFeeBps, Constants.SELL_FEE_BPS_MIN, Constants.SELL_FEE_BPS_MAX));
        swap.buyFeeBps = uint16(bound(swap.buyFeeBps, 1, 100));
        IFeePolicy.FeeInput memory input = _input(swap);
        input.dynCapBps = Constants.DYN_CAP_NORMAL_BPS;

        IFeePolicy.FeeQuote memory quote = policy.quoteFee(input);

        if (input.zeroForOne && input.exactInput && input.amountIn != 0) {
            uint256 expected = input.rotationCredit < input.amountIn ? input.rotationCredit : input.amountIn;
            assertEq(quote.creditConsumed, expected, "credit consumed is min(amountIn, rotationCredit)");
            assertGe(quote.baseBps, input.buyFeeBps, "the blend never falls below the buy fee");
            assertLe(quote.baseBps, input.sellFeeBps, "and never rises above the sell fee");
        } else {
            assertEq(quote.creditConsumed, 0, "only exact-input sells consume credit");
            assertEq(quote.baseBps, input.zeroForOne ? input.sellFeeBps : input.buyFeeBps, "an unblended base");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Bands, rails and decay
    // -------------------------------------------------------------------------------------------------------------

    /// @dev I19: the band never narrows as the market gets more closed, in either coordinate, and the breaker
    ///      cannot reach it at all — `GateState` is not a parameter of `innerBandTicks`.
    function testFuzz_bandIsMonotoneInClosedness(uint8 sessionSeed, uint8 stepSeed, uint16 hoursSeed, uint16 hoursStep)
        public
        view
    {
        uint8 sessionA = uint8(bound(sessionSeed, 0, 3));
        uint8 sessionB = uint8(bound(uint256(sessionA) + stepSeed, sessionA, 3));
        uint16 hoursA = uint16(bound(hoursSeed, 0, type(uint16).max));
        uint16 hoursB = uint16(bound(uint256(hoursA) + hoursStep, hoursA, type(uint16).max));

        int24 bandA = policy.innerBandTicks(PoolClass.SPOKE, Session(sessionA), hoursA);
        int24 bandB = policy.innerBandTicks(PoolClass.SPOKE, Session(sessionB), hoursB);
        assertLe(bandA, bandB, "the band never narrows as closedness rises");
        assertGe(bandA, Constants.INNER_BAND_REGULAR_TICKS, "and never falls below the regular band");
        assertLe(bandB, Constants.INNER_BAND_MAX_TICKS, "or rises above the cap");

        // Entry pools are flat, whatever the session says.
        assertEq(policy.innerBandTicks(PoolClass.ENTRY, Session(sessionB), hoursB), Constants.INNER_BAND_REGULAR_TICKS);
    }

    /// @dev The rail is monotone in the band, never below its floor, and flat for entry pools.
    function testFuzz_railIsMonotoneInTheBand(int24 bandSeed, int24 stepSeed) public view {
        int24 bandA = int24(bound(bandSeed, 0, Constants.INNER_BAND_MAX_TICKS));
        int24 bandB = bandA + int24(bound(stepSeed, 0, Constants.INNER_BAND_MAX_TICKS));

        int24 railA = policy.outerRailTicks(PoolClass.SPOKE, bandA);
        int24 railB = policy.outerRailTicks(PoolClass.SPOKE, bandB);
        assertLe(railA, railB, "the rail is monotone in the band");
        assertGe(railA, Constants.OUTER_RAIL_MIN_TICKS, "and never below its floor");
        assertEq(policy.outerRailTicks(PoolClass.ENTRY, bandB), Constants.OUTER_RAIL_ENTRY_TICKS, "entry pools flat");
    }

    /// @dev Both decays are monotone non-increasing in elapsed time, never exceed what was armed, and are exactly
    ///      zero at eight half-lives.
    function testFuzz_decaysAreMonotoneAndBounded(uint16 armedSeed, uint32 elapsedSeed, uint32 stepSeed) public view {
        uint16 armed = uint16(bound(armedSeed, 0, Constants.SURGE_MAX_BPS));
        uint32 elapsedA = uint32(bound(elapsedSeed, 0, 10_000));
        uint32 elapsedB = uint32(bound(uint256(elapsedA) + stepSeed, elapsedA, type(uint32).max));

        assertLe(policy.surgeDecay(armed, elapsedB), policy.surgeDecay(armed, elapsedA), "surge decays");
        assertLe(policy.surgeDecay(armed, elapsedA), armed, "and never exceeds what was armed");
        assertEq(policy.surgeDecay(armed, uint32(8 * Constants.SURGE_HALF_LIFE)), 0, "zero at eight half-lives");

        assertLe(policy.captureDecay(armed, elapsedB), policy.captureDecay(armed, elapsedA), "capture decays");
        assertEq(
            policy.captureDecay(armed, uint32(8 * Constants.DIVIDEND_CAPTURE_HALF_LIFE)), 0, "on its own half-life"
        );

        // The capture half-life is five times the surge's, so on the same armed value it is never the faster of
        // the two. The armed value has to sit under *both* ceilings for the comparison to be about the half-lives:
        // the surge saturates at 500 bp and the capture at `0.8 x DIVIDEND_STEP_BPS_MAX == 160`.
        uint16 captureCeiling =
            uint16(uint256(Constants.DIVIDEND_STEP_BPS_MAX) * Constants.DIVIDEND_CAPTURE_NUMERATOR_BPS / Constants.BPS);
        uint16 shared = armed > captureCeiling ? captureCeiling : armed;
        assertGe(policy.captureDecay(shared, elapsedA), policy.surgeDecay(shared, elapsedA), "capture outlives surge");
    }

    /// @dev `f_vol` is monotone non-decreasing in variance, never exceeds `F_VOL_CAP_BPS` on its own, and never
    ///      reverts anywhere in the widened `uint128` field (§12.1 ruling H).
    function testFuzz_volatilityIsMonotoneAndCapped(uint128 varianceSeed, uint128 stepSeed) public view {
        uint128 low = uint128(bound(varianceSeed, 0, type(uint128).max));
        uint128 high = uint128(bound(uint256(low) + stepSeed, low, type(uint128).max));

        IFeePolicy.FeeInput memory a = _quiet();
        a.varianceX18 = low;
        IFeePolicy.FeeInput memory b = _quiet();
        b.varianceX18 = high;

        uint16 feeLow = policy.quoteFee(a).dynBps;
        uint16 feeHigh = policy.quoteFee(b).dynBps;
        assertLe(feeLow, feeHigh, "f_vol is monotone in variance");
        assertLe(feeHigh, Constants.F_VOL_CAP_BPS, "and never exceeds its own cap on its own");
        assertEq(feeLow, uint16(_expectedVolBps(low)), "f_vol == min(K_VOL_X18 * varianceX18 / 1e36, F_VOL_CAP_BPS)");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The coefficients
    // -------------------------------------------------------------------------------------------------------------

    function testFuzz_constructorRejectsKVolOutsideItsBand(uint256 seed) public {
        uint256 value = _outside(seed, Constants.K_VOL_X18_MIN, Constants.K_VOL_X18_MAX, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("K_VOL_X18"), value, Constants.K_VOL_X18_MIN, Constants.K_VOL_X18_MAX
            )
        );
        new FeePolicy(value, Constants.K_DEV_BPS, Constants.F_WALL_BPS, Constants.LAMBDA_X18);
    }

    function testFuzz_constructorRejectsKDevOutsideItsBand(uint256 seed) public {
        uint16 value = uint16(_outside(seed, Constants.K_DEV_BPS_MIN, Constants.K_DEV_BPS_MAX, type(uint16).max));
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("K_DEV_BPS"), value, Constants.K_DEV_BPS_MIN, Constants.K_DEV_BPS_MAX
            )
        );
        new FeePolicy(Constants.K_VOL_X18, value, Constants.F_WALL_BPS, Constants.LAMBDA_X18);
    }

    function testFuzz_constructorRejectsFWallOutsideItsBand(uint256 seed) public {
        uint16 value = uint16(_outside(seed, Constants.F_WALL_BPS_MIN, Constants.F_WALL_BPS_MAX, type(uint16).max));
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("F_WALL_BPS"), value, Constants.F_WALL_BPS_MIN, Constants.F_WALL_BPS_MAX
            )
        );
        new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, value, Constants.LAMBDA_X18);
    }

    function testFuzz_constructorRejectsLambdaOutsideItsBand(uint256 seed) public {
        uint64 value = uint64(_outside(seed, Constants.LAMBDA_X18_MIN, Constants.LAMBDA_X18_MAX, type(uint64).max));
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("LAMBDA_X18"), value, Constants.LAMBDA_X18_MIN, Constants.LAMBDA_X18_MAX
            )
        );
        new FeePolicy(Constants.K_VOL_X18, Constants.K_DEV_BPS, Constants.F_WALL_BPS, value);
    }

    /// @dev Any coefficient set inside its band deploys and produces a lawful quote: the bands are not merely
    ///      checked, they are the whole reachable configuration space of a replacement policy.
    function testFuzz_anyInBandCoefficientSetIsLawful(
        uint256 kVolSeed,
        uint16 kDevSeed,
        uint16 wallSeed,
        Swap memory swap
    ) public {
        FeePolicy tuned = new FeePolicy(
            bound(kVolSeed, Constants.K_VOL_X18_MIN, Constants.K_VOL_X18_MAX),
            uint16(bound(kDevSeed, Constants.K_DEV_BPS_MIN, Constants.K_DEV_BPS_MAX)),
            uint16(bound(wallSeed, Constants.F_WALL_BPS_MIN, Constants.F_WALL_BPS_MAX)),
            Constants.LAMBDA_X18
        );

        IFeePolicy.FeeQuote memory quote = tuned.quoteFee(_input(swap));
        uint256 total = uint256(quote.baseBps) + quote.dynBps;
        assertGe(total, Constants.F_MIN_BPS, "the floor holds for every in-band law");
        assertLe(total, Constants.TOTAL_FEE_BPS_MAX, "and so does the ceiling");
        assertEq(uint256(quote.feePips), total * Constants.PIPS_PER_BPS, "and the decomposition");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev A band inside `[1, MAX_BAND]` and a rail at least `MIN_SPAN` above it, which is the configuration the
    ///      ramp is defined over. The minimum span keeps the ramp's first step below one basis point, so the
    ///      continuity assertion at the band can be an equality rather than a tolerance.
    function _bandAndRail(int24 bandSeed, int24 railSeed) private pure returns (int24 band, int24 rail) {
        band = int24(bound(bandSeed, 1, MAX_BAND));
        rail = int24(bound(railSeed, int256(band) + MIN_SPAN, int256(MAX_BAND) * 4));
    }

    /// @dev The dynamic part of a spoke sell with only the deviation armed, at the escalation cap so the shape is
    ///      visible rather than clipped.
    function _dynFor(int24 devTicks, int24 band, int24 rail) private view returns (uint16) {
        IFeePolicy.FeeInput memory input = _quiet();
        input.deviationIncreasing = true;
        input.devTicks = devTicks;
        input.innerBandTicks = band;
        input.outerRailTicks = rail;
        input.dynCapBps = Constants.DYN_CAP_ESCALATION_BPS;
        return policy.quoteFee(input).dynBps;
    }

    /// @dev A spoke sell in the Regular session with nothing armed and a green gate.
    function _quiet() private pure returns (IFeePolicy.FeeInput memory input) {
        input = IFeePolicy.FeeInput({
            zeroForOne: true,
            exactInput: true,
            deviationIncreasing: false,
            amountIn: 0,
            rotationCredit: 0,
            poolClass: PoolClass.SPOKE,
            sellFeeBps: 500,
            buyFeeBps: 5,
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

    /// @dev A fully fuzzed swap, bounded into the reachable state space.
    function _input(Swap memory swap) private pure returns (IFeePolicy.FeeInput memory input) {
        input = _quiet();
        input.zeroForOne = swap.zeroForOne;
        input.exactInput = swap.exactInput;
        input.deviationIncreasing = swap.deviationIncreasing;
        input.amountIn = bound(swap.amountIn, 0, type(uint128).max);
        input.rotationCredit = bound(swap.rotationCredit, 0, type(uint128).max);
        input.sellFeeBps = swap.sellFeeBps;
        input.buyFeeBps = swap.buyFeeBps;
        input.devTicks = int24(bound(int256(swap.devTicks), 0, MAX_DEV));
        input.innerBandTicks = int24(bound(int256(swap.band), 0, Constants.INNER_BAND_MAX_TICKS));
        input.outerRailTicks = int24(bound(int256(swap.rail), 0, int256(Constants.INNER_BAND_MAX_TICKS) * 3));
        // The whole `uint128` range (§12.1 ruling H widened the field from `uint64`): `f_vol` is capped, so every
        // property below has to hold at the field's ceiling too, not only in the calibrated band.
        input.varianceX18 = uint128(bound(swap.varianceX18, 0, type(uint128).max));
        input.dynCapBps = uint16(bound(swap.dynCapBps, 0, Constants.DYN_CAP_ESCALATION_BPS));
        input.poolClass = PoolClass(uint8(bound(swap.poolClass, 0, 3)));
        input.session = Session(uint8(bound(swap.session, 0, 3)));
        input.gate = GateState(uint8(bound(swap.gate, 0, 5)));
    }

    /// @dev The law from §12.1 ruling H, restated independently of the implementation.
    function _expectedVolBps(uint128 varianceX18) private pure returns (uint256 bps) {
        bps = FullMath.mulDiv(Constants.K_VOL_X18, uint256(varianceX18), Constants.WAD * Constants.WAD);
        if (bps > Constants.F_VOL_CAP_BPS) bps = Constants.F_VOL_CAP_BPS;
    }

    function _abs(int24 value) private pure returns (uint256) {
        return value < 0 ? uint256(uint24(-value)) : uint256(uint24(value));
    }

    function _nonNegative(int24 value) private pure returns (uint256) {
        return value <= 0 ? 0 : uint256(uint24(value));
    }

    /// @dev A value outside `[min, max]`, drawn from either side of the band.
    function _outside(uint256 seed, uint256 min, uint256 max, uint256 ceiling) private pure returns (uint256) {
        if (seed % 2 == 0 && min > 0) return bound(seed, 0, min - 1);
        return bound(seed, max + 1, ceiling);
    }
}
