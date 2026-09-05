// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PriceLib} from "../lib/PriceLib.sol";

/// @title GatePriceMath
/// @notice The two `PriceLib` conversions `OracleGate` needs, behind an external boundary.
///
/// @dev **Why this is a contract and not two internal functions.** `OracleGate` must never revert out of a view:
///      the hook, the quoter and the placement path all read it, and a price that happens to fall outside the v4
///      tick range must degrade to "no fair tick", not brick a swap quote. `PriceLib` reverts on exactly those
///      inputs, so the gate has to call it across a boundary it can `try` — and once the call is external, the
///      `TickMath` tables behind it no longer have to sit in the gate's own runtime code, which is what keeps
///      `OracleGate` inside EIP-170 with a full 24/5 calendar in it.
///
/// @dev Deployed by `OracleGate`'s constructor and held as an immutable, so there is no extra deployment step, no
///      extra governance pointer, and nothing to re-point: it is pure, stateless and shares the gate's lifetime.
contract GatePriceMath {
    /// @notice The spacing-aligned tick a pool should trade at, given the AMPS price and the counter's answer.
    /// @dev Reverts (through `PriceLib`) for a zero price, unsupported decimals or a price outside the v4 tick
    ///      range. The caller is expected to `try` this and treat a revert as "no fair tick".
    /// @param pAmpsUsd18 The AMPS price in USD, 18 decimals.
    /// @param counterPriceUsd8 The counter asset's Chainlink answer, 8 decimals.
    /// @param counterDecimals The counter asset's ERC-20 decimals.
    /// @param tickSpacing The pool's tick spacing.
    /// @return tick The aligned fair tick.
    function fairTick(uint256 pAmpsUsd18, uint256 counterPriceUsd8, uint8 counterDecimals, int24 tickSpacing)
        external
        pure
        returns (int24 tick)
    {
        return PriceLib.fairTick(pAmpsUsd18, counterPriceUsd8, counterDecimals, tickSpacing);
    }

    /// @notice The AMPS price in USD implied by a pool's mean tick and its counter asset's Chainlink answer.
    /// @dev Rounds **down**, like every valuation read in the protocol.
    /// @param meanTick The pool's mean truncated tick.
    /// @param counterPriceUsd8 The counter asset's Chainlink answer, 8 decimals.
    /// @param counterDecimals The counter asset's ERC-20 decimals.
    /// @return price18 The implied AMPS price in USD, 18 decimals.
    function ampsPriceUsd18(int24 meanTick, uint256 counterPriceUsd8, uint8 counterDecimals)
        external
        pure
        returns (uint256 price18)
    {
        return PriceLib.sqrtPriceX96ToAmpsPriceUsd18(
            PriceLib.tickToSqrtPriceX96(meanTick), counterPriceUsd8, counterDecimals
        );
    }
}
