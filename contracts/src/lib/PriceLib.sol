// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title PriceLib
/// @notice The single audited place where Amplestocks converts between USD prices, token amounts and Uniswap v4
///         prices. Nothing else in the protocol is allowed to do a decimal conversion by hand.
///
/// @dev Units used throughout Amplestocks:
///      - `priceUsd8`     Chainlink USD answers, 8 decimals (`1e8` == $1.00).
///      - `usd18`         USD values carried inside the protocol, 18 decimals (`1e18` == $1.00).
///      - AMPS / stock tokens / WETH: 18 decimals. USDG: 6 decimals.
///      - `sqrtPriceX96`  Uniswap v4 Q64.96 square root of `currency1` raw units per `currency0` raw unit.
///      - `tick`          `log_1.0001(price)`, floored.
///
/// @dev **AMPS is `currency0` in all 32 pools** (the token address is CREATE2-mined below every counter asset), so a
///      pool price is unambiguously *counter asset per AMPS* and this library contains no currency-ordering branch.
///      Raw-unit prices are therefore tiny for 6-decimal counters (AMPS $1 against USDG $1 is `1e6 / 1e18 = 1e-12`
///      raw) and small for expensive stocks (AMPS $1 against NVDA $180 is `1/180` raw); every function below is
///      written for that full dynamic range rather than for values near 1.
///
/// @dev **Rounding.** Every function documents its direction and rounds in favour of the protocol (the vault):
///      - prices *of* AMPS round **up**   → anchors never sit below the true reference, so asks never undersell;
///      - values *of* protocol assets round **down** → NAV is never overstated;
///      - counter amounts *required* round **up** → the protocol never accepts less than it is owed.
///      The only exception is `fairTick`, which is a deviation reference rather than an execution price and is
///      documented in place.
library PriceLib {
    /// @notice Scale of a protocol-internal USD value (18 decimals).
    uint256 internal constant WAD = 1e18;

    /// @notice Scale of a Chainlink USD answer (8 decimals).
    uint256 internal constant USD_PRICE_SCALE = 1e8;

    /// @notice Decimals of AMPS itself.
    uint8 internal constant AMPS_DECIMALS = 18;

    /// @notice Largest counter-asset decimals this library accepts (18 covers stock tokens and WETH; USDG is 6).
    uint8 internal constant MAX_COUNTER_DECIMALS = 18;

    /// @dev `1e36 / USD_PRICE_SCALE`: the fixed part of the raw-price denominator. See `ampsPerCounterToSqrtPriceX96`.
    uint256 internal constant _PRICE_DENOMINATOR_SCALE = 1e28;

    /// @dev `Q64 == 2**64`.
    uint256 internal constant _Q64 = 0x10000000000000000;

    /// @dev `Q128 == 2**128`.
    uint256 internal constant _Q128 = 0x100000000000000000000000000000000;

    /// @dev A price of zero has no logarithm and no square root; every feed answer must be strictly positive.
    error ZeroPrice();

    /// @dev Counter-asset decimals above `MAX_COUNTER_DECIMALS`.
    error DecimalsOutOfRange(uint8 counterDecimals);

    /// @dev An input is so large that the raw-price fraction cannot be formed without overflow.
    error PriceOverflow();

    /// @dev The implied pool price lies outside `[TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE)`.
    error PriceOutOfTickRange();

    /// @dev `sqrtPriceX96` outside `[TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE)`.
    error SqrtPriceOutOfRange(uint160 sqrtPriceX96);

    /// @dev `tick` outside `[TickMath.MIN_TICK, TickMath.MAX_TICK]`.
    error TickOutOfRange(int24 tick);

    /// @dev `tickSpacing` outside `[1, TickMath.MAX_TICK_SPACING]`.
    error InvalidTickSpacing(int24 tickSpacing);

    // -------------------------------------------------------------------------------------------------------------
    // USD  ->  v4 price
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Converts an AMPS reference price and a counter-asset feed price into the pool's `sqrtPriceX96`.
    /// @dev Because AMPS is `currency0`, the pool price is counter-asset raw units per AMPS raw unit:
    ///
    ///        price = (pRefUsd18 / 1e18 / 1e18) / (counterPriceUsd8 / 1e8 / 10**counterDecimals)
    ///              = pRefUsd18 * 10**counterDecimals / (counterPriceUsd8 * 1e28)
    ///
    ///      Worked examples: AMPS $1 against USDG (6 dec) at $1 gives `1e6 / 1e18 = 1e-12`; AMPS $1 against NVDA
    ///      (18 dec) at $180 gives `1/180`.
    ///
    ///      The square root is taken in one of two fixed-point windows so that the full tick range is covered without
    ///      overflow and without losing significance at either extreme:
    ///        - `price < 2**64`  : the ratio is formed in Q192 and its square root is already Q96 (exact to 1 ulp);
    ///        - `price >= 2**64` : the ratio is formed in Q64, its square root is Q32 and is shifted up by 64 bits
    ///                             (relative error below `2**-32`, i.e. ~2e-10, four orders of magnitude finer than
    ///                             one tick).
    ///
    /// @dev Rounds **up**: the returned sqrt price is never below the exact value, so a ladder anchored here never
    ///      sells AMPS below its reference price.
    /// @param pRefUsd18 The AMPS reference price in USD, 18 decimals. Must be non-zero.
    /// @param counterPriceUsd8 The counter asset's Chainlink USD answer, 8 decimals. Must be non-zero.
    /// @param counterDecimals The counter asset's ERC-20 decimals (6 for USDG, 18 for stock tokens and WETH).
    /// @return sqrtPriceX96 The v4 Q64.96 sqrt price for the `AMPS / counter` pool.
    function ampsPerCounterToSqrtPriceX96(uint256 pRefUsd18, uint256 counterPriceUsd8, uint8 counterDecimals)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        (uint256 numerator, uint256 denominator) = _rawPriceFraction(pRefUsd18, counterPriceUsd8, counterDecimals);

        // `q == floor(price)`. `price` can never exceed `(MAX_SQRT_PRICE / 2**96)**2 < 2**128`, so anything at or
        // above `2**128` is out of range by inspection and is rejected before it can overflow the Q64 window below.
        uint256 q = numerator / denominator;
        if (q >= (uint256(1) << 128)) revert PriceOutOfTickRange();

        uint256 result;
        if (q < (uint256(1) << 64)) {
            // price < 2**64  =>  price * 2**192 < 2**256, so the Q192 window is safe and maximally precise.
            result = Math.sqrt(FullMath.mulDivRoundingUp(numerator, uint256(1) << 192, denominator), Math.Rounding.Ceil);
        } else {
            // 2**64 <= price < 2**128  =>  price * 2**64 < 2**192, so the Q64 window is safe. sqrt is then Q32 and
            // must be scaled by 2**64 to reach Q96; the shift only ever loses low-order bits, so the ceiling above
            // is preserved.
            uint256 ratioX64 = FullMath.mulDivRoundingUp(numerator, uint256(1) << 64, denominator);
            result = Math.sqrt(ratioX64, Math.Rounding.Ceil) << 64;
        }

        if (result < TickMath.MIN_SQRT_PRICE || result >= TickMath.MAX_SQRT_PRICE) revert PriceOutOfTickRange();
        sqrtPriceX96 = uint160(result);
    }

    /// @notice Recovers the AMPS price in USD (18 decimals) implied by a pool sqrt price and the counter asset's feed.
    /// @dev Inverse of `ampsPerCounterToSqrtPriceX96`:
    ///
    ///        pRefUsd18 = (sqrtPriceX96 / 2**96)**2 * counterPriceUsd8 * 1e28 / 10**counterDecimals
    ///
    /// @dev Rounds **down**: an AMPS price read back out of a pool is a valuation input, and understating it keeps
    ///      NAV conservative. Relative accuracy is better than 1e-13 across the whole Amplestocks price domain
    ///      (AMPS $1e-6..$1e12 against counters $1e-2..$1e7, 6 or 18 decimals) and degrades only in the last few
    ///      thousand ticks above `MIN_SQRT_PRICE`, which no configured pool can reach.
    /// @param sqrtPriceX96 The pool's Q64.96 sqrt price. Must be a valid v4 sqrt price.
    /// @param counterPriceUsd8 The counter asset's Chainlink USD answer, 8 decimals. Must be non-zero.
    /// @param counterDecimals The counter asset's ERC-20 decimals.
    /// @return pRefUsd18 The implied AMPS price in USD, 18 decimals.
    function sqrtPriceX96ToAmpsPriceUsd18(uint160 sqrtPriceX96, uint256 counterPriceUsd8, uint8 counterDecimals)
        internal
        pure
        returns (uint256 pRefUsd18)
    {
        _validateSqrtPrice(sqrtPriceX96);
        if (counterPriceUsd8 == 0) revert ZeroPrice();
        if (counterDecimals > MAX_COUNTER_DECIMALS) revert DecimalsOutOfRange(counterDecimals);
        if (counterPriceUsd8 > type(uint256).max / _PRICE_DENOMINATOR_SCALE) revert PriceOverflow();

        // The price is carried in Q128 rather than Q96: `sqrtPriceX96**2` alone overflows, but
        // `(MAX_SQRT_PRICE - 1)**2 / 2**64` is 99.993% of `type(uint256).max` and so still fits, and the extra 32
        // bits matter because raw prices here are as small as 1e-25 (AMPS at $1e-6 against a $1e7 6-decimal counter),
        // where a Q96 intermediate would only carry four significant digits.
        uint256 priceX128 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), _Q64);
        pRefUsd18 = FullMath.mulDiv(
            priceX128, counterPriceUsd8 * _PRICE_DENOMINATOR_SCALE, _Q128 * (10 ** uint256(counterDecimals))
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // Tick helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Thin wrapper over `TickMath.getTickAtSqrtPrice` with an Amplestocks-owned range error.
    /// @dev Rounds **down** by construction: returns the greatest tick whose sqrt price is `<= sqrtPriceX96`.
    /// @param sqrtPriceX96 A valid v4 sqrt price.
    /// @return tick The floored tick.
    function sqrtPriceX96ToTick(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        _validateSqrtPrice(sqrtPriceX96);
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice Thin wrapper over `TickMath.getSqrtPriceAtTick` with an Amplestocks-owned range error.
    /// @dev Exact for every tick in range (no rounding decision to make).
    /// @param tick A tick in `[TickMath.MIN_TICK, TickMath.MAX_TICK]`.
    /// @return sqrtPriceX96 The sqrt price at `tick`.
    function tickToSqrtPriceX96(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) revert TickOutOfRange(tick);
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
    }

    /// @notice Snaps `tick` onto the pool's tick spacing.
    /// @dev `roundUp == false` floors toward negative infinity, `roundUp == true` ceils toward positive infinity
    ///      (Solidity integer division truncates toward zero, so the sign is corrected explicitly). The result is
    ///      then clamped into `[TickMath.minUsableTick, TickMath.maxUsableTick]` for the spacing, which is the widest
    ///      band v4 will accept as a position boundary.
    /// @param tick The tick to align. Must be in `[TickMath.MIN_TICK, TickMath.MAX_TICK]`.
    /// @param tickSpacing The pool's tick spacing, in `[1, TickMath.MAX_TICK_SPACING]`.
    /// @param roundUp Ceil when true, floor when false.
    /// @return aligned A multiple of `tickSpacing` inside the usable range.
    function alignTick(int24 tick, int24 tickSpacing, bool roundUp) internal pure returns (int24 aligned) {
        if (tickSpacing <= 0 || tickSpacing > TickMath.MAX_TICK_SPACING) revert InvalidTickSpacing(tickSpacing);
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) revert TickOutOfRange(tick);

        int24 compressed = tick / tickSpacing;
        int24 remainder = tick % tickSpacing;
        if (remainder != 0) {
            if (roundUp && tick > 0) compressed += 1;
            if (!roundUp && tick < 0) compressed -= 1;
        }
        aligned = compressed * tickSpacing;

        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);
        if (aligned < minUsable) aligned = minUsable;
        if (aligned > maxUsable) aligned = maxUsable;
    }

    /// @notice The spacing-aligned tick a pool "should" trade at, given the two USD prices.
    /// @dev Used by the hook as the centre of the fee wall (`dev = |poolTick - fairTick|`) and by the placement path
    ///      as the divergence reference. It is **aligned down**: the fair tick is a measurement reference rather than
    ///      an execution price, and flooring keeps it deterministic and monotone in the underlying price.
    /// @param pRefUsd18 The AMPS reference price in USD, 18 decimals.
    /// @param counterPriceUsd8 The counter asset's Chainlink USD answer, 8 decimals.
    /// @param counterDecimals The counter asset's ERC-20 decimals.
    /// @param tickSpacing The pool's tick spacing.
    /// @return tick The aligned fair tick.
    function fairTick(uint256 pRefUsd18, uint256 counterPriceUsd8, uint8 counterDecimals, int24 tickSpacing)
        internal
        pure
        returns (int24 tick)
    {
        uint160 sqrtPriceX96 = ampsPerCounterToSqrtPriceX96(pRefUsd18, counterPriceUsd8, counterDecimals);
        tick = alignTick(TickMath.getTickAtSqrtPrice(sqrtPriceX96), tickSpacing, false);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Counter-asset valuation
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Values a raw counter-asset balance in USD with 18 decimals.
    /// @dev `usd18 = counterAmountRaw * counterPriceUsd8 * 1e10 / 10**counterDecimals`.
    /// @dev Rounds **down**: this feeds the NAV numerator `A`, which must never be overstated.
    /// @param counterAmountRaw The counter-asset balance in its own raw units.
    /// @param counterDecimals The counter asset's ERC-20 decimals.
    /// @param counterPriceUsd8 The counter asset's Chainlink USD answer, 8 decimals. Must be non-zero.
    /// @return usd18 The USD value, 18 decimals, rounded down.
    function counterValueUsd18(uint256 counterAmountRaw, uint8 counterDecimals, uint256 counterPriceUsd8)
        internal
        pure
        returns (uint256 usd18)
    {
        if (counterPriceUsd8 == 0) revert ZeroPrice();
        if (counterDecimals > MAX_COUNTER_DECIMALS) revert DecimalsOutOfRange(counterDecimals);
        // `WAD / USD_PRICE_SCALE == 1e10` lifts an 8-decimal answer to an 18-decimal value.
        if (counterPriceUsd8 > type(uint256).max / (WAD / USD_PRICE_SCALE)) revert PriceOverflow();

        usd18 = FullMath.mulDiv(
            counterAmountRaw, counterPriceUsd8 * (WAD / USD_PRICE_SCALE), 10 ** uint256(counterDecimals)
        );
    }

    /// @notice The raw counter-asset amount worth (at least) a given USD value.
    /// @dev `raw = ceil(usd18 * 10**counterDecimals / (counterPriceUsd8 * 1e10))`, the exact inverse of
    ///      `counterValueUsd18` up to rounding.
    /// @dev Rounds **up**: this sizes what a counterparty must deliver, so the protocol is never short. It must not
    ///      be used to size a payout — use `counterValueUsd18` and pay the rounded-down value instead.
    /// @param usd18 The USD value to cover, 18 decimals.
    /// @param counterDecimals The counter asset's ERC-20 decimals.
    /// @param counterPriceUsd8 The counter asset's Chainlink USD answer, 8 decimals. Must be non-zero.
    /// @return counterAmountRaw The counter-asset amount in raw units, rounded up.
    function counterAmountFromUsd18(uint256 usd18, uint8 counterDecimals, uint256 counterPriceUsd8)
        internal
        pure
        returns (uint256 counterAmountRaw)
    {
        if (counterPriceUsd8 == 0) revert ZeroPrice();
        if (counterDecimals > MAX_COUNTER_DECIMALS) revert DecimalsOutOfRange(counterDecimals);
        if (counterPriceUsd8 > type(uint256).max / (WAD / USD_PRICE_SCALE)) revert PriceOverflow();

        counterAmountRaw = FullMath.mulDivRoundingUp(
            usd18, 10 ** uint256(counterDecimals), counterPriceUsd8 * (WAD / USD_PRICE_SCALE)
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Builds the exact raw-price fraction `numerator / denominator` used by `ampsPerCounterToSqrtPriceX96`,
    ///      validating every input so neither product can overflow.
    function _rawPriceFraction(uint256 pRefUsd18, uint256 counterPriceUsd8, uint8 counterDecimals)
        private
        pure
        returns (uint256 numerator, uint256 denominator)
    {
        if (pRefUsd18 == 0 || counterPriceUsd8 == 0) revert ZeroPrice();
        if (counterDecimals > MAX_COUNTER_DECIMALS) revert DecimalsOutOfRange(counterDecimals);

        uint256 counterScale = 10 ** uint256(counterDecimals);
        if (pRefUsd18 > type(uint256).max / counterScale) revert PriceOverflow();
        if (counterPriceUsd8 > type(uint256).max / _PRICE_DENOMINATOR_SCALE) revert PriceOverflow();

        numerator = pRefUsd18 * counterScale;
        denominator = counterPriceUsd8 * _PRICE_DENOMINATOR_SCALE;
    }

    /// @dev v4 accepts sqrt prices in `[MIN_SQRT_PRICE, MAX_SQRT_PRICE)`; the upper bound is exclusive because the
    ///      price at `MAX_TICK + 1` is unreachable.
    function _validateSqrtPrice(uint160 sqrtPriceX96) private pure {
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert SqrtPriceOutOfRange(sqrtPriceX96);
        }
    }
}
