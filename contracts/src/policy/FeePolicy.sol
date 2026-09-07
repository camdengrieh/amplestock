// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeePolicy} from "../interfaces/IFeePolicy.sol";
import {Constants} from "../types/Constants.sol";
import {OutOfBand} from "../types/Errors.sol";
import {GateState, PoolClass, Session} from "../types/Types.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title FeePolicy
/// @notice The launch dynamic-fee law (`directional-wall-v1`): a directional base fee blended by the
///         same-transaction rotation credit, plus a dynamic part built from realised volatility, deviation from
///         fair, the dividend-capture toll, the session add-on and the placement surge. Pure in substance,
///         stateless, holding no funds, and pointer-upgradeable behind the 7-day timelock, which is how the four
///         Phase 0 coefficients get recalibrated without new `AmpsHook` bytecode.
///
/// @dev **The law**, exactly `docs/phase3-state-model.md` §1.4 steps 3-7:
///
///      ```
///      base = zeroForOne ? sellFeeBps : buyFeeBps
///      if (zeroForOne && exactInput && amountIn != 0):                       // the rotation blend
///          c    = min(amountIn, rotationCredit)
///          base = buyFeeBps + ceilDiv((sellFeeBps - buyFeeBps) * (amountIn - c), amountIn)
///      f_vol     = min(K_VOL_X18 * varianceX18 / 1e36, F_VOL_CAP_BPS)
///      f_dev     = 0                                                          price-improving swaps
///                = K_DEV_BPS * dev^2 / BPS                                    dev <= innerBand
///                = f_inner + (F_WALL_BPS - f_inner) * (dev-band)^2/(rail-band)^2   band < dev <= rail
///                = max(F_WALL_BPS, f_inner)  with refuse = true               dev > rail
///      f_div     = captureDecay(captureFeeBps, captureElapsed)                stock-out direction only
///      f_session = 0 / 5 / 10 / 25 bp                                         stock legs only
///      surge     = surgeDecay(surgeBps, surgeElapsed)
///      dyn       = clamp(f_vol + f_dev + f_div + f_session + surge, gate != GREEN ? 100 : 0, dynCapBps)
///      fee       = clamp(base + dyn, F_MIN_BPS, TOTAL_FEE_BPS_MAX)
///      ```
///
///      The blend rounds **up**, so a rotation credit never rounds a fee down in the swapper's favour, and
///      `creditConsumed` comes back so the hook decrements its transient slot by exactly the amount that was
///      credited (I26). Exact-output sells consume no credit and pay `sellFeeBps` in full.
///
/// @dev **A wall, not a clamp, and never a gate.** Only a *deviation-increasing* swap that starts beyond the outer
///      rail comes back with `refuse == true`, and even that is returned rather than thrown so `AmpsQuoter` can
///      display it (I15). A degraded gate raises the dynamic floor to `FROZEN_FEE_FLOOR_BPS` and widens
///      `dynCapBps`; it never closes a pool. `f_dev` is charged only on the direction that moves the pool away
///      from fair, which is what lets an arbitrageur close a hub-pump gap against a spoke's ladder at the base fee
///      and makes the pump propagate into stock backing within one TWAP window.
///
/// @dev **Continuity.** `f_dev` is continuous at both joins: at `dev == band` the quadratic and the ramp both give
///      `K_DEV_BPS * band^2 / BPS`, and at `dev == rail` the ramp reaches `F_WALL_BPS` exactly, which is also the
///      value returned beyond the rail. It is monotone non-decreasing in `dev` everywhere, including the
///      pathological configurations where `K_DEV_BPS * band^2 / BPS` already exceeds `F_WALL_BPS` (the ramp then
///      runs flat at the inner value rather than sloping downward) and where a governance mistake leaves
///      `rail < band` (the whole region above the rail is refused, and the largest accepted deviation is `rail`).
///
/// @dev **Rounding and saturation always favour the protocol.** The blend rounds up; the decays round up (the
///      linear interpolation across a half-life subtracts a floored amount); `f_vol` and the deviation ramp round
///      down but are additive components of a fee that is floored at `F_MIN_BPS`; and every out-of-band input
///      saturates into the nearest in-band value rather than reverting, because a fee quote that reverts is a swap
///      that reverts and this policy may never be the reason a swap fails.
///
/// @dev **`quoteFee` is `view`, and that is load-bearing.** §10 ruling 5 puts `k_vol`, `k_dev`, `F_WALL_BPS` and
///      `lambda` here as constructor-set `immutable`s, and Solidity forbids a `pure` function from reading an
///      `immutable` ("Function declared as pure, but this expression (potentially) reads from the environment or
///      state"). `IFeePolicy.quoteFee` is therefore declared `view` and this contract declares `is IFeePolicy`, so
///      the compiler — not a test — is what guarantees the immutable hook's call site matches. The bound getters
///      that only read `Constants` are implemented `pure`, which a `view` declaration permits. Callers see no
///      difference: a `view` external call compiles to `STATICCALL` either way, and `AmpsHook` reaches this
///      contract through a hand-decoded `staticcall` of `abi.encodeCall(IFeePolicy.quoteFee, ...)`.
///
/// @dev **`f_vol`'s calibration** (§12.1 ruling H). `AmpsHook` writes `FeeInput.varianceX18 = EWMA(d^2) x 1e18`
///      with `d` the raw tick change of one swap and lambda 0.98 per swap, into a `uint128` field — it was a
///      `uint64`, which saturated at 18.45 ticks^2 and made this whole term structurally zero. At the launch
///      `K_VOL_X18 = 5e15` the law `f_vol_bps = k x varianceX18 / 1e36` therefore reads:
///
///      | per-swap sigma | `varianceX18` | `f_vol` |
///      |---|---|---|
///      | 14 ticks   | `196e18`    | 0 bp (0.98 bp, floored) |
///      | ~14.15     | `2e20`      | 1 bp — the first whole basis point |
///      | 141        | `19_881e18` | 99 bp |
///      | ~142       | `20_164e18` | 100 bp — `F_VOL_CAP_BPS`, and capped above |
///
///      The division floors, which is the one dynamic component that rounds toward the swapper; it is additive
///      inside a total the `F_MIN_BPS` floor already protects. Phase 0 recalibrates `k_vol` from the cadence
///      sample, and recalibration is a pointer swap.
contract FeePolicy is IFeePolicy {
    /// @notice Identifier of this fee law. Returned by {version}.
    bytes32 internal constant VERSION_ID = "directional-wall-v1";

    /// @notice Half-lives after which a surge or a capture fee is exactly zero rather than a rounding tail.
    /// @dev `IFeePolicy.surgeDecay`'s "zero at 8 half-lives". It is a shape constant of the decay curve, not a
    ///      governed parameter, so it has no band in `Constants` and no getter: 8 half-lives is 8 minutes for the
    ///      surge and 40 minutes for the dividend capture.
    uint256 internal constant DECAY_ZERO_HALF_LIVES = 8;

    /// @notice `1e36`, the denominator of `K_VOL_X18 * varianceX18`: a product of two 1e18 fixed-point numbers.
    uint256 internal constant WAD_SQUARED = Constants.WAD * Constants.WAD;

    /// @notice `k_vol`, the coefficient on EWMA realised variance. Set once, inside `[K_VOL_X18_MIN, MAX]`.
    uint256 internal immutable kVolX18;

    /// @notice `k_dev`, the coefficient on the squared deviation. Set once, inside `[K_DEV_BPS_MIN, MAX]`.
    uint16 internal immutable kDevBps;

    /// @notice `f_wall`, the fee the quadratic ramp reaches at the rail. Set once, inside `[F_WALL_BPS_MIN, MAX]`.
    uint16 internal immutable fWallBps;

    /// @notice `lambda`, the EWMA decay the hook applies to realised variance. Set once, inside
    ///         `[LAMBDA_X18_MIN, MAX]`. This policy does not use it — `AmpsHook.afterSwap` does — but it is part of
    ///         the same calibration and is published here so a governance drill reads one law, not two.
    uint64 internal immutable lambdaX18;

    /// @param kVolX18_ `k_vol`, 1e18 fixed point. `Constants.K_VOL_X18` at launch.
    /// @param kDevBps_ `k_dev`, in bps per squared tick over `BPS`. `Constants.K_DEV_BPS` at launch.
    /// @param fWallBps_ `f_wall`, in bps. `Constants.F_WALL_BPS` at launch.
    /// @param lambdaX18_ `lambda`, 1e18 fixed point. `Constants.LAMBDA_X18` at launch.
    constructor(uint256 kVolX18_, uint16 kDevBps_, uint16 fWallBps_, uint64 lambdaX18_) {
        if (kVolX18_ < Constants.K_VOL_X18_MIN || kVolX18_ > Constants.K_VOL_X18_MAX) {
            revert OutOfBand("K_VOL_X18", kVolX18_, Constants.K_VOL_X18_MIN, Constants.K_VOL_X18_MAX);
        }
        if (kDevBps_ < Constants.K_DEV_BPS_MIN || kDevBps_ > Constants.K_DEV_BPS_MAX) {
            revert OutOfBand("K_DEV_BPS", kDevBps_, Constants.K_DEV_BPS_MIN, Constants.K_DEV_BPS_MAX);
        }
        if (fWallBps_ < Constants.F_WALL_BPS_MIN || fWallBps_ > Constants.F_WALL_BPS_MAX) {
            revert OutOfBand("F_WALL_BPS", fWallBps_, Constants.F_WALL_BPS_MIN, Constants.F_WALL_BPS_MAX);
        }
        if (lambdaX18_ < Constants.LAMBDA_X18_MIN || lambdaX18_ > Constants.LAMBDA_X18_MAX) {
            revert OutOfBand("LAMBDA_X18", lambdaX18_, Constants.LAMBDA_X18_MIN, Constants.LAMBDA_X18_MAX);
        }
        kVolX18 = kVolX18_;
        kDevBps = kDevBps_;
        fWallBps = fWallBps_;
        lambdaX18 = lambdaX18_;
    }

    /// @inheritdoc IFeePolicy
    /// @dev `feePips == (baseBps + dynBps) * PIPS_PER_BPS` holds unconditionally, so I16's "fee = base + dyn"
    ///      decomposition is exact rather than nominal: both the `F_MIN_BPS` floor and the `TOTAL_FEE_BPS_MAX`
    ///      ceiling adjust `dynBps` rather than `baseBps` wherever they can.
    function quoteFee(FeeInput calldata input) external view returns (FeeQuote memory quote) {
        (uint256 base, uint256 credit) = _baseBps(input);
        quote.creditConsumed = credit;

        (uint256 fDev, bool beyondRail) = _deviationBps(input);
        quote.refuse = beyondRail;

        uint256 dyn = fDev + _volBps(input.varianceX18) + _sessionBps(input.poolClass, input.session)
            + _surgeBps(input.surgeBps, input.surgeElapsed)
            + (input.captureDirectionTakesStock ? _captureBps(input.captureFeeBps, input.captureElapsed) : 0);

        // A degraded gate raises the floor and widens the cap; it never refuses (I15).
        if (input.gate != GateState.GREEN && dyn < Constants.FROZEN_FEE_FLOOR_BPS) {
            dyn = Constants.FROZEN_FEE_FLOOR_BPS;
        }
        if (dyn > input.dynCapBps) dyn = input.dynCapBps;

        // `clamp(base + dyn, F_MIN_BPS, base + dynCapBps)`: the upper half is already true because `dyn <=
        // dynCapBps`, so only the floor and the absolute ceiling are applied here. Both adjust `dyn` rather than
        // `base` wherever they can, which keeps the returned decomposition exact.
        uint256 total = base + dyn;
        if (total < Constants.F_MIN_BPS) {
            dyn += Constants.F_MIN_BPS - total;
            total = Constants.F_MIN_BPS;
        }
        if (total > Constants.TOTAL_FEE_BPS_MAX) {
            total = Constants.TOTAL_FEE_BPS_MAX;
            if (base >= total) {
                base = total;
                dyn = 0;
            } else {
                dyn = total - base;
            }
        }

        quote.baseBps = uint16(base);
        quote.dynBps = uint16(dyn);
        quote.feePips = uint24(total * Constants.PIPS_PER_BPS);
    }

    /// @inheritdoc IFeePolicy
    /// @dev Monotone non-decreasing in session closedness and in `closedHours` (I19), and never touched by the
    ///      breaker: `GateState` is not an input here at all, which is how "the breaker never changes the band"
    ///      becomes a property of the signature rather than of the implementation. Entry pools ignore both
    ///      arguments — WETH and USDG trade 24/7.
    function innerBandTicks(PoolClass poolClass, Session session, uint16 closedHours)
        external
        pure
        returns (int24 ticks)
    {
        if (!_isSpoke(poolClass)) return Constants.INNER_BAND_REGULAR_TICKS;
        if (session == Session.REGULAR) return Constants.INNER_BAND_REGULAR_TICKS;
        if (session == Session.PRE_POST) return Constants.INNER_BAND_PRE_POST_TICKS;
        if (session == Session.OVERNIGHT) return Constants.INNER_BAND_OVERNIGHT_TICKS;

        // Closed: 770 ticks plus 25 per closed hour, capped. `closedHours` is a `uint16`, so the widening term is
        // at most 1.6e6 and the sum stays inside `int256` by construction.
        int256 widened = int256(Constants.INNER_BAND_CLOSED_TICKS) + int256(uint256(closedHours))
            * int256(Constants.INNER_BAND_CLOSED_TICKS_PER_HOUR);
        if (widened > int256(Constants.INNER_BAND_MAX_TICKS)) return Constants.INNER_BAND_MAX_TICKS;
        ticks = int24(widened);
    }

    /// @inheritdoc IFeePolicy
    /// @dev A negative band is read as zero and the product saturates at `type(int24).max`, so a nonsense band
    ///      widens the rail rather than wrapping it into a value that would refuse swaps (I15).
    function outerRailTicks(PoolClass poolClass, int24 innerBand) external pure returns (int24 ticks) {
        if (!_isSpoke(poolClass)) return Constants.OUTER_RAIL_ENTRY_TICKS;

        int256 scaled = innerBand <= 0 ? int256(0) : int256(innerBand) * int256(Constants.OUTER_RAIL_BAND_MULTIPLE);
        if (scaled > int256(type(int24).max)) return type(int24).max;
        if (scaled < int256(Constants.OUTER_RAIL_MIN_TICKS)) return Constants.OUTER_RAIL_MIN_TICKS;
        ticks = int24(scaled);
    }

    /// @inheritdoc IFeePolicy
    /// @dev Linear interpolation inside each half-life and exactly zero at 8 of them. The armed value saturates at
    ///      `SURGE_MAX_BPS`, so a mis-armed surge cannot exceed the plan's 500 bp ceiling. Reimplemented from the
    ///      published description of Bunni v2's surge shape; see `NOTICES.md`.
    function surgeDecay(uint16 armedBps, uint32 elapsed) external pure returns (uint16 bps) {
        bps = _surgeBps(armedBps, elapsed);
    }

    /// @inheritdoc IFeePolicy
    /// @dev Same shape as {surgeDecay} on the 300-second `DIVIDEND_CAPTURE_HALF_LIFE`. The armed value saturates
    ///      at `DIVIDEND_STEP_BPS_MAX x DIVIDEND_CAPTURE_NUMERATOR_BPS / BPS` (160 bp), which is the largest toll a
    ///      detected dividend step can produce before the step is instead read as a corporate action.
    function captureDecay(uint16 armedBps, uint32 elapsed) external pure returns (uint16 bps) {
        bps = _captureBps(armedBps, elapsed);
    }

    /// @inheritdoc IFeePolicy
    function F_MIN_BPS() external pure returns (uint16 value) {
        value = Constants.F_MIN_BPS;
    }

    /// @inheritdoc IFeePolicy
    function DYN_CAP_NORMAL_BPS() external pure returns (uint16 value) {
        value = Constants.DYN_CAP_NORMAL_BPS;
    }

    /// @inheritdoc IFeePolicy
    function DYN_CAP_DEGRADED_BPS() external pure returns (uint16 value) {
        value = Constants.DYN_CAP_DEGRADED_BPS;
    }

    /// @inheritdoc IFeePolicy
    function DYN_CAP_ESCALATION_BPS() external pure returns (uint16 value) {
        value = Constants.DYN_CAP_ESCALATION_BPS;
    }

    /// @inheritdoc IFeePolicy
    function SURGE_MAX_BPS() external pure returns (uint16 value) {
        value = Constants.SURGE_MAX_BPS;
    }

    /// @inheritdoc IFeePolicy
    function F_VOL_CAP_BPS() external pure returns (uint16 value) {
        value = Constants.F_VOL_CAP_BPS;
    }

    /// @inheritdoc IFeePolicy
    function TOTAL_FEE_BPS_MAX() external pure returns (uint16 value) {
        value = Constants.TOTAL_FEE_BPS_MAX;
    }

    /// @inheritdoc IFeePolicy
    function FROZEN_FEE_FLOOR_BPS() external pure returns (uint16 value) {
        value = Constants.FROZEN_FEE_FLOOR_BPS;
    }

    /// @inheritdoc IFeePolicy
    /// @dev Set in the constructor and validated against `[K_VOL_X18_MIN, K_VOL_X18_MAX]`; see the
    ///      contract-level calibration table for what a value means in basis points.
    function K_VOL_X18() external view returns (uint256 value) {
        value = kVolX18;
    }

    /// @inheritdoc IFeePolicy
    function K_DEV_BPS() external view returns (uint16 value) {
        value = kDevBps;
    }

    /// @inheritdoc IFeePolicy
    function F_WALL_BPS() external view returns (uint16 value) {
        value = fWallBps;
    }

    /// @inheritdoc IFeePolicy
    /// @dev Published here for the governance drill and the dApp; this policy does not use it —
    ///      `AmpsHook.afterSwap` is what applies the EWMA.
    function LAMBDA_X18() external view returns (uint64 value) {
        value = lambdaX18;
    }

    /// @inheritdoc IFeePolicy
    function version() external pure returns (bytes32 id) {
        id = VERSION_ID;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The base fee and the rotation credit it consumed. Buys and exact-output sells are one branch each; an
    ///      exact-input sell blends its credited part at the buy fee and its uncredited part at the sell fee.
    ///
    ///      The blend is written as a delta rather than as `ceilDiv(buy*c + sell*(in-c), in)` because the naive
    ///      form overflows for `amountIn > 2**256 / 600`; both delta forms carry the 512-bit intermediate through
    ///      `FullMath` and neither can underflow, because the branch is chosen on the sign of `sell - buy`. In
    ///      production `sellFeeBps >= buyFeeBps` always (bands `[100, 600]` against `[1, 100]`) and only the first
    ///      branch is reachable; the second exists so a mis-parameterised hook cannot make this function revert.
    function _baseBps(IFeePolicy.FeeInput calldata input) private pure returns (uint256 base, uint256 creditConsumed) {
        if (!input.zeroForOne) return (uint256(input.buyFeeBps), 0);

        base = uint256(input.sellFeeBps);
        if (!input.exactInput || input.amountIn == 0 || input.rotationCredit == 0) return (base, 0);

        uint256 amountIn = input.amountIn;
        creditConsumed = input.rotationCredit < amountIn ? input.rotationCredit : amountIn;

        uint256 buy = uint256(input.buyFeeBps);
        base = buy <= base
            ? buy + FullMath.mulDivRoundingUp(base - buy, amountIn - creditConsumed, amountIn)
            : base + FullMath.mulDivRoundingUp(buy - base, creditConsumed, amountIn);
    }

    /// @dev `f_dev` and the rail decision. A price-improving swap pays nothing and is never refused, which is the
    ///      whole of I15's "only deviation-increasing swaps beyond the rail revert".
    function _deviationBps(IFeePolicy.FeeInput calldata input) private view returns (uint256 fDev, bool beyondRail) {
        if (!input.deviationIncreasing) return (0, false);

        uint256 dev = _abs(input.devTicks);
        uint256 band = _nonNegative(input.innerBandTicks);
        uint256 rail = _nonNegative(input.outerRailTicks);

        if (dev > rail) {
            // The largest deviation that is still accepted is `min(band, rail)`; the wall is the floor beyond it,
            // so the curve is monotone even when the quadratic has already outgrown `F_WALL_BPS`.
            uint256 edge = _quadraticBps(band < rail ? band : rail);
            return (edge > fWallBps ? edge : uint256(fWallBps), true);
        }
        if (dev <= band) return (_quadraticBps(dev), false);

        // `band < dev <= rail` implies `rail > band`, so the ramp's denominator is non-zero here by construction.
        uint256 inner = _quadraticBps(band);
        if (inner >= fWallBps) return (inner, false);

        uint256 over = dev - band;
        uint256 span = rail - band;
        fDev = inner + FullMath.mulDiv(uint256(fWallBps) - inner, over * over, span * span);
    }

    /// @dev `K_DEV_BPS * dev^2 / BPS`. `dev` is bounded by `int24`, so `dev^2 <= 7.1e13` and the product with a
    ///      `uint16` coefficient cannot come close to overflowing.
    function _quadraticBps(uint256 dev) private view returns (uint256 bps) {
        bps = uint256(kDevBps) * dev * dev / Constants.BPS;
    }

    /// @dev `min(K_VOL_X18 * varianceX18 / 1e36, F_VOL_CAP_BPS)`. §11.4: `FeeInput` carries the full-precision
    ///      variance rather than a pre-multiplied `fVolBps`, so the multiply lives here and the hook does none.
    /// @dev The field is a `uint128` (§12.1 ruling H): the product `kVolX18 * varianceX18` reaches 1.7e56 at the
    ///      `K_VOL_X18_MAX` end of the band, which is why it goes through `FullMath`'s 512-bit intermediate rather
    ///      than a plain multiply. The cap is applied after the divide, so no input can make this term unbounded
    ///      and none can make it revert. See the contract-level calibration table for what the numbers mean.
    function _volBps(uint128 varianceX18) private view returns (uint256 bps) {
        bps = FullMath.mulDiv(kVolX18, uint256(varianceX18), WAD_SQUARED);
        if (bps > Constants.F_VOL_CAP_BPS) bps = Constants.F_VOL_CAP_BPS;
    }

    /// @dev The session add-on, **stock legs only**: entry pools trade against WETH and USDG, which have no
    ///      session, and an unregistered pool is treated the same way rather than being charged for one.
    function _sessionBps(PoolClass poolClass, Session session) private pure returns (uint256 bps) {
        if (!_isSpoke(poolClass)) return 0;
        if (session == Session.REGULAR) return Constants.F_SESSION_REGULAR_BPS;
        if (session == Session.PRE_POST) return Constants.F_SESSION_PRE_POST_BPS;
        if (session == Session.OVERNIGHT) return Constants.F_SESSION_OVERNIGHT_BPS;
        bps = Constants.F_SESSION_CLOSED_BPS;
    }

    /// @dev The surge, saturated at its ceiling before decaying.
    function _surgeBps(uint16 armedBps, uint32 elapsed) private pure returns (uint16 bps) {
        uint16 armed = armedBps > Constants.SURGE_MAX_BPS ? Constants.SURGE_MAX_BPS : armedBps;
        bps = _decay(armed, elapsed, Constants.SURGE_HALF_LIFE);
    }

    /// @dev The dividend capture, saturated at `0.8 x DIVIDEND_STEP_BPS_MAX` before decaying on its own half-life.
    function _captureBps(uint16 armedBps, uint32 elapsed) private pure returns (uint16 bps) {
        uint16 ceiling =
            uint16(uint256(Constants.DIVIDEND_STEP_BPS_MAX) * Constants.DIVIDEND_CAPTURE_NUMERATOR_BPS / Constants.BPS);
        uint16 armed = armedBps > ceiling ? ceiling : armedBps;
        bps = _decay(armed, elapsed, Constants.DIVIDEND_CAPTURE_HALF_LIFE);
    }

    /// @dev Exponential decay by halving, with linear interpolation across the remainder of the current half-life
    ///      and an exact zero at {DECAY_ZERO_HALF_LIVES}. `armed >> n` is the value at the start of half-life `n`
    ///      and `armed >> (n+1)` the value at its end; the interpolation subtracts a **floored** share of the gap,
    ///      so the result rounds up and the decay is never faster than the curve.
    function _decay(uint16 armedBps, uint32 elapsed, uint32 halfLife) private pure returns (uint16 bps) {
        if (armedBps == 0) return 0;

        uint256 halves = uint256(elapsed) / halfLife;
        if (halves >= DECAY_ZERO_HALF_LIVES) return 0;

        uint256 top = uint256(armedBps) >> halves;
        uint256 gap = top - (top >> 1);
        bps = uint16(top - gap * (uint256(elapsed) % halfLife) / halfLife);
    }

    /// @dev Spokes carry session widening and the `max(3 x band, 800)` rail; entry pools and unregistered pools do
    ///      not. One predicate, used by every class branch in this contract.
    function _isSpoke(PoolClass poolClass) private pure returns (bool) {
        return poolClass == PoolClass.SPOKE || poolClass == PoolClass.SPOKE_HIGH_VOL;
    }

    /// @dev `|value|` as a `uint256`. `devTicks` arrives as an absolute value from the hook; taking it again here
    ///      costs nothing and removes a way for a caller to under-charge by sign.
    /// @dev The negation widens to `int256` **before** it negates. `-value` on an `int24` would revert with an
    ///      arithmetic panic at `type(int24).min`, and a fee quote that reverts is a swap that reverts: the one
    ///      thing this policy may never cause (I15). `type(int24).min` is unreachable from a real
    ///      `|poolTick - fairTick|`, which is why the widening is the whole defence rather than a range check.
    function _abs(int24 value) private pure returns (uint256) {
        return value < 0 ? uint256(-int256(value)) : uint256(uint24(value));
    }

    /// @dev A band or rail read as zero when negative, so a nonsense width can only widen a fee, never wrap one.
    function _nonNegative(int24 value) private pure returns (uint256) {
        return value <= 0 ? 0 : uint256(uint24(value));
    }
}
