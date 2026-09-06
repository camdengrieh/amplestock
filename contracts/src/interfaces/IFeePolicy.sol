// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GateState, PoolClass, Session} from "../types/Types.sol";

/// @title IFeePolicy
/// @notice The dynamic-fee law: given a swap's direction, the pool's deviation from fair, its realised volatility,
///         the session and the gate, it returns the fee the hook charges. Pure, stateless and pointer-upgradeable
///         behind the 7-day timelock.
///
/// @dev **Phase 3 consumes this; Phase 2 only declares it.** It is fixed now because `AmpsHook` is immutable and
///      because `AmpsQuoter` must be able to reproduce the hook's fee exactly, off the same pure function, without
///      simulating a swap.
///
/// @dev **The law.**
///
///      ```
///      dir  = zeroForOne ? SELL : BUY                       // AMPS is currency0 in all 32 pools
///      base = dir == BUY ? buyFeeBps[poolClass] : sellFeeBps
///      if dir == SELL && exactInput:                        // blended by the same-transaction rotation credit
///          c    = min(amountIn, rotationCredit)
///          base = ceilDiv(buyFeeBps x c + sellFeeBps x (amountIn - c), amountIn)
///      dyn  = f_vol + f_dev + f_div + f_session + surge     // f_dev only on deviation-INCREASING swaps
///      fee  = clamp(base + dyn, F_MIN_BPS, base + dynCapBps)
///      ```
///
///      `base` is rounded **up** on the blend, so a rotation credit never rounds a fee down in the swapper's
///      favour. Exact-output sells pay `sellFeeBps` in full: the credit applies only to exact-input sells, which is
///      why the dApp always builds hop 2 of a rotation as `SWAP_EXACT_IN`.
///
/// @dev **Two things this law may never do**, both asserted by the invariant suite:
///        - it may never make a swap revert for a gate reason (I15). A degraded gate raises `FROZEN_FEE_FLOOR_BPS`
///          on the dynamic part and widens `dynCapBps`; it never closes the pool. Only a *deviation-increasing*
///          swap beyond the outer rail is refused, and that decision is returned as {FeeQuote-refuse} for the hook
///          to act on, never thrown from here.
///        - it may never return a total above `Constants.TOTAL_FEE_BPS_MAX` (2,600 bp), which is far below
///          `MAX_LP_FEE` (I16).
///
/// @dev **Price-improving swaps pay no dynamic component.** `f_dev` is charged only when the swap moves the pool
///      further from `fairTick`. An arbitrageur closing a gap pays the base fee alone, which is what makes the hub
///      pump propagate into the spokes within one TWAP window instead of being taxed out of existence.
interface IFeePolicy {
    /// @notice Everything the fee law is allowed to see. Assembled by `AmpsHook` in `beforeSwap`.
    /// @param zeroForOne True when AMPS is the input, i.e. a sell.
    /// @param exactInput True when `amountSpecified < 0`. Only exact-input sells can consume a rotation credit.
    /// @param deviationIncreasing True when the swap moves the pool away from `fairTick`.
    /// @param amountIn The input amount, in the input currency's raw units. Zero when unknown (exact output).
    /// @param rotationCredit The live same-transaction rotation credit, in AMPS wei.
    /// @param poolClass The pool's fee bucket.
    /// @param sellFeeBps The governed protocol-wide sell fee.
    /// @param buyFeeBps The pool's governed buy fee.
    /// @param devTicks `|poolTick - fairTick|` after the swap, in ticks.
    /// @param innerBandTicks The inner band half-width in force.
    /// @param outerRailTicks The outer rail half-width in force.
    /// @param varianceX18 EWMA realised variance driving `f_vol`.
    /// @param surgeBps The surge fee at its arming time.
    /// @param surgeElapsed Seconds since the surge was armed.
    /// @param captureFeeBps The dividend-step capture fee at its arming time.
    /// @param captureElapsed Seconds since the capture fee was armed.
    /// @param captureDirectionTakesStock True on the swap direction that removes the Stock Token from the pool,
    ///        the only direction the capture fee applies to.
    /// @param session The equity session.
    /// @param gate The pool's gate state.
    /// @param dynCapBps The dynamic-fee cap for that gate state.
    struct FeeInput {
        bool zeroForOne;
        bool exactInput;
        bool deviationIncreasing;
        uint256 amountIn;
        uint256 rotationCredit;
        PoolClass poolClass;
        uint16 sellFeeBps;
        uint16 buyFeeBps;
        int24 devTicks;
        int24 innerBandTicks;
        int24 outerRailTicks;
        uint128 varianceX18;
        uint16 surgeBps;
        uint32 surgeElapsed;
        uint16 captureFeeBps;
        uint32 captureElapsed;
        bool captureDirectionTakesStock;
        Session session;
        GateState gate;
        uint16 dynCapBps;
    }

    /// @notice The quoted fee and its decomposition.
    /// @param feePips The fee the hook returns to the PoolManager, in pips, **without** the override flag. The
    ///        hook ORs `LPFeeLibrary.OVERRIDE_FEE_FLAG` itself.
    /// @param baseBps The base component after any rotation blend.
    /// @param dynBps The dynamic component after clamping.
    /// @param creditConsumed AMPS wei of rotation credit the blend used. The hook decrements the transient slot by
    ///        exactly this (I26).
    /// @param refuse True only for a deviation-increasing swap beyond the outer rail. The hook reverts on this; it
    ///        is returned rather than thrown so that `AmpsQuoter` can report it without a try/catch.
    struct FeeQuote {
        uint24 feePips;
        uint16 baseBps;
        uint16 dynBps;
        uint256 creditConsumed;
        bool refuse;
    }

    /// @notice Quotes the fee for one swap.
    /// @param input The assembled inputs.
    /// @return quote The fee and its decomposition.
    function quoteFee(FeeInput calldata input) external view returns (FeeQuote memory quote);

    /// @notice The inner band half-width for a pool class and session.
    /// @dev Monotone non-decreasing in session closedness, and never widened or narrowed by the breaker (I19).
    ///      Entry pools ignore `session` and `closedHours` entirely: their legs (WETH, USDG) trade 24/7.
    /// @param poolClass The pool's class.
    /// @param session The equity session.
    /// @param closedHours Whole hours the market has been closed, adding
    ///        `INNER_BAND_CLOSED_TICKS_PER_HOUR` each, capped at `INNER_BAND_MAX_TICKS`.
    /// @return ticks The inner band half-width.
    function innerBandTicks(PoolClass poolClass, Session session, uint16 closedHours)
        external
        pure
        returns (int24 ticks);

    /// @notice The outer rail half-width: `max(3 x innerBand, 800)` for spokes, a flat 2,000 for entry pools.
    /// @param poolClass The pool's class.
    /// @param innerBand The inner band half-width from {innerBandTicks}.
    /// @return ticks The outer rail half-width.
    function outerRailTicks(PoolClass poolClass, int24 innerBand) external pure returns (int24 ticks);

    /// @notice The surge fee remaining after `elapsed` seconds of exponential decay.
    /// @dev Half-life `Constants.SURGE_HALF_LIFE` (60 s), zero at 8 half-lives. Reimplemented from the published
    ///      description of Bunni v2's surge shape; see `NOTICES.md`.
    /// @param armedBps The surge at arming time.
    /// @param elapsed Seconds since arming.
    /// @return bps The decayed surge.
    function surgeDecay(uint16 armedBps, uint32 elapsed) external pure returns (uint16 bps);

    /// @notice The dividend-step capture fee remaining after `elapsed` seconds of exponential decay.
    /// @dev Same shape as {surgeDecay}, **different half-life**: `Constants.DIVIDEND_CAPTURE_HALF_LIFE` (300 s)
    ///      rather than 60 s. The two are separate functions because they are separate control loops — a surge
    ///      exists to stop a placement being sandwiched over the next block or two, while a capture fee exists to
    ///      hold an asymmetric toll long enough for the arbitrage against a `uiMultiplier()` step to be taken
    ///      through the pool rather than around it (the plan's "300 s half-life", and `DIVIDEND_CAPTURE_HALF_LIFE`
    ///      would otherwise have no consumer).
    /// @dev `f_div` is this value, and it is charged **only** on the swap direction that takes the Stock Token out
    ///      of the pool ({FeeInput-captureDirectionTakesStock}). A `+Delta` step makes each raw stock token worth
    ///      more, so that is the profitable direction, and it is `zeroForOne == true` because AMPS is `currency0`.
    /// @param armedBps The capture fee at arming time, `deltaBps x DIVIDEND_CAPTURE_NUMERATOR_BPS / BPS`.
    /// @param elapsed Seconds since arming.
    /// @return bps The decayed capture fee.
    function captureDecay(uint16 armedBps, uint32 elapsed) external pure returns (uint16 bps);

    /// @notice Absolute floor on the returned fee, in bps. 3.
    /// @return value The bound.
    function F_MIN_BPS() external view returns (uint16 value);

    /// @notice Dynamic-fee cap when the gate is GREEN, in bps. 300.
    /// @return value The bound.
    function DYN_CAP_NORMAL_BPS() external view returns (uint16 value);

    /// @notice Dynamic-fee cap when the gate is degraded, in bps. 1,000.
    /// @return value The bound.
    function DYN_CAP_DEGRADED_BPS() external view returns (uint16 value);

    /// @notice Dynamic-fee cap during band escalation, in bps. 2,000.
    /// @return value The bound.
    function DYN_CAP_ESCALATION_BPS() external view returns (uint16 value);

    /// @notice Maximum surge fee, in bps. 500.
    /// @return value The bound.
    function SURGE_MAX_BPS() external view returns (uint16 value);

    /// @notice Cap on the volatility component, in bps. 100.
    /// @return value The bound.
    function F_VOL_CAP_BPS() external view returns (uint16 value);

    /// @notice The largest total fee this policy can ever return, in bps. 2,600.
    /// @return value The bound.
    function TOTAL_FEE_BPS_MAX() external view returns (uint16 value);

    /// @notice Floor applied to the dynamic component while the gate is not GREEN, in bps. 100.
    /// @return value The bound.
    function FROZEN_FEE_FLOOR_BPS() external view returns (uint16 value);

    // -------------------------------------------------------------------------------------------------------------
    // Coefficients — the four numbers that make this policy pointer-upgradeable rather than immutable
    // -------------------------------------------------------------------------------------------------------------
    //
    // `docs/phase3-state-model.md` §10 ruling 5: `k_vol`, `k_dev`, `f_wall` and `lambda` live **here**, in the
    // 7-day-replaceable policy, with their hard bands in `Constants`. They are Phase 0 placeholders calibrated
    // against a cadence and volatility sample the protocol does not have yet, which is precisely why they must not
    // sit in the immutable hook. An implementation reads all four from `Constants` and restates none of them as a
    // literal; these getters exist so the dApp, the governance drill and the fuzz suite can read the live law
    // rather than assume it.

    /// @notice `k_vol`, the coefficient on EWMA realised variance in `f_vol = k_vol x sigma^2`. 1e18 fixed point.
    /// @return value The coefficient, inside `[K_VOL_X18_MIN, K_VOL_X18_MAX]`.
    function K_VOL_X18() external view returns (uint256 value);

    /// @notice `k_dev`, the coefficient on the squared deviation inside the inner band:
    ///         `f_dev = K_DEV_BPS x dev^2 / 1e4`, with `dev` in ticks.
    /// @return value The coefficient, inside `[K_DEV_BPS_MIN, K_DEV_BPS_MAX]`.
    function K_DEV_BPS() external view returns (uint16 value);

    /// @notice `f_wall`, the fee the quadratic ramp reaches at the outer rail, in bps. 1,500.
    /// @dev Between band and rail: `f_inner + (F_WALL_BPS - f_inner) x (dev - band)^2 / (rail - band)^2`. A wall,
    ///      not a clamp — the swap is still accepted at the wall; only a deviation-increasing swap beyond the rail
    ///      is refused, and that comes back as {FeeQuote-refuse}, never as a throw.
    /// @return value The wall, inside `[F_WALL_BPS_MIN, F_WALL_BPS_MAX]`.
    function F_WALL_BPS() external view returns (uint16 value);

    /// @notice `lambda`, the EWMA decay on realised variance. 1e18 fixed point, 0.98 at launch.
    /// @return value The decay, inside `[LAMBDA_X18_MIN, LAMBDA_X18_MAX]`.
    function LAMBDA_X18() external view returns (uint64 value);

    /// @notice Identifier of this fee law, for governance diffs and the dApp.
    /// @return id A short identifier, e.g. `bytes32("directional-wall-v1")`.
    function version() external pure returns (bytes32 id);
}
