// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LadderLib} from "../../src/lib/LadderLib.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";

/// @title PriceLibHarness
/// @notice External wrapper around `PriceLib` so tests exercise every function across a real call boundary. This is
///         what makes `vm.expectRevert` unambiguous and what lets `forge coverage` attribute branches to the library.
contract PriceLibHarness {
    function ampsPerCounterToSqrtPriceX96(uint256 pRefUsd18, uint256 counterPriceUsd8, uint8 counterDecimals)
        external
        pure
        returns (uint160)
    {
        return PriceLib.ampsPerCounterToSqrtPriceX96(pRefUsd18, counterPriceUsd8, counterDecimals);
    }

    function sqrtPriceX96ToAmpsPriceUsd18(uint160 sqrtPriceX96, uint256 counterPriceUsd8, uint8 counterDecimals)
        external
        pure
        returns (uint256)
    {
        return PriceLib.sqrtPriceX96ToAmpsPriceUsd18(sqrtPriceX96, counterPriceUsd8, counterDecimals);
    }

    function sqrtPriceX96ToTick(uint160 sqrtPriceX96) external pure returns (int24) {
        return PriceLib.sqrtPriceX96ToTick(sqrtPriceX96);
    }

    function tickToSqrtPriceX96(int24 tick) external pure returns (uint160) {
        return PriceLib.tickToSqrtPriceX96(tick);
    }

    function alignTick(int24 tick, int24 tickSpacing, bool roundUp) external pure returns (int24) {
        return PriceLib.alignTick(tick, tickSpacing, roundUp);
    }

    function fairTick(uint256 pRefUsd18, uint256 counterPriceUsd8, uint8 counterDecimals, int24 tickSpacing)
        external
        pure
        returns (int24)
    {
        return PriceLib.fairTick(pRefUsd18, counterPriceUsd8, counterDecimals, tickSpacing);
    }

    function counterValueUsd18(uint256 counterAmountRaw, uint8 counterDecimals, uint256 counterPriceUsd8)
        external
        pure
        returns (uint256)
    {
        return PriceLib.counterValueUsd18(counterAmountRaw, counterDecimals, counterPriceUsd8);
    }

    function counterAmountFromUsd18(uint256 usd18, uint8 counterDecimals, uint256 counterPriceUsd8)
        external
        pure
        returns (uint256)
    {
        return PriceLib.counterAmountFromUsd18(usd18, counterDecimals, counterPriceUsd8);
    }
}

/// @title LadderLibHarness
/// @notice External wrapper around `LadderLib`, for the same reasons as `PriceLibHarness`.
contract LadderLibHarness {
    function doublingTicks(int24 tickSpacing) external pure returns (int24) {
        return LadderLib.doublingTicks(tickSpacing);
    }

    function bucketBounds(int24 anchorTick, int24 tickSpacing, uint8 k, bool above)
        external
        pure
        returns (int24, int24)
    {
        return LadderLib.bucketBounds(anchorTick, tickSpacing, k, above);
    }

    function weights(uint256 tiltX18, uint8 n) external pure returns (uint256[] memory) {
        return LadderLib.weights(tiltX18, n);
    }

    function split(uint256 amount, uint256[] memory wX18) external pure returns (uint256[] memory) {
        return LadderLib.split(amount, wX18);
    }

    function liquidityForAmount0Above(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount0)
        external
        pure
        returns (uint128)
    {
        return LadderLib.liquidityForAmount0Above(sqrtLower, sqrtUpper, amount0);
    }

    function liquidityForAmount1Below(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount1)
        external
        pure
        returns (uint128)
    {
        return LadderLib.liquidityForAmount1Below(sqrtLower, sqrtUpper, amount1);
    }

    function amount0ForLiquidity(uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity)
        external
        pure
        returns (uint256)
    {
        return LadderLib.amount0ForLiquidity(sqrtLower, sqrtUpper, liquidity);
    }

    function amount1ForLiquidity(uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity)
        external
        pure
        returns (uint256)
    {
        return LadderLib.amount1ForLiquidity(sqrtLower, sqrtUpper, liquidity);
    }

    function ladderAmounts(int24 anchorTick, int24 tickSpacing, uint8 n, uint256 tiltX18, uint256 inventory, bool above)
        external
        pure
        returns (int24[] memory, int24[] memory, uint128[] memory)
    {
        return LadderLib.ladderAmounts(anchorTick, tickSpacing, n, tiltX18, inventory, above);
    }
}
