// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBondPolicy} from "../interfaces/IBondPolicy.sol";
import {Constants} from "../types/Constants.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title BondPolicy
/// @notice The launch bond pricing law: a linear discount in the index deficit and the epoch fill, capped by the
///         NAV accretion floor. Pure, stateless and holding no funds, so the 7-day timelock can re-point
///         `AmpsBonds.policy()` at a different law without touching custody, vesting or the vault.
///
/// @dev **Written from scratch under MIT.** Olympus v2 and Bond Protocol are AGPL-3.0; neither was imported,
///      copied or ported. The formula below is the one in `docs/phase2-state-model.md` §6 and the plan's "Bonds"
///      section, implemented directly. See `NOTICES.md`.
///
/// @dev **The formula**, all in 1e18 fixed point except the discount, which is in bps:
///
///      ```
///      d        = clamp(dBase + k_w x deficit - k_c x fill, dMin, dMax)
///      qMarket  = m x BPS / (BPS - d)
///      qFloor   = [P_i x (BPS - h_session) / BPS] x 1e18 / [navPerShare x (BPS + minAccretion) / BPS]
///      q        = min(qMarket, qFloor)
///      ampsOut  = amountIn18 x q / 1e18
///      ```
///
/// @dev **Rounding, exactly as `IBondPolicy` mandates.** Every direction favours the protocol, which is what makes
///      I27 (`NAV/share after a bond >= NAV/share before`) exact rather than up to dust:
///
///      | Quantity | Direction | How |
///      |---|---|---|
///      | `k_w x deficit` | down | `FullMath.mulDiv` |
///      | `k_c x fill`    | up   | `FullMath.mulDivRoundingUp` — it is *subtracted*, so rounding it up rounds `d` down |
///      | `d`             | down | the sum of the two above, then clamped |
///      | `qMarket`       | down | `FullMath.mulDiv` |
///      | `qFloor` numerator | down | `FullMath.mulDiv` |
///      | `qFloor` denominator | up | `FullMath.mulDivRoundingUp` |
///      | `qFloor`, `q`, `ampsOut` | down | `FullMath.mulDiv` |
///
///      `m` and `deficit`/`fill` are rounded by `AmpsBonds` before they reach this contract; the directions are
///      documented there.
///
/// @dev **Coefficient units.** `k_w` and `k_c` are 1e18 fixed point and are quoted in units of
///      {COEFFICIENT_BPS_SCALE} bps per unit of their term, which is what reproduces the confirmed launch
///      calibration: `k_w = 0.5e18` adds 250 bp of discount to a name at half its target weight
///      (`deficit = 0.5`), and `k_c = 0.25e18` removes 250 bp from a market whose epoch capacity is full
///      (`fill = 1.0`). The hard ceiling `BOND_COEFFICIENT_X18_MAX = 2e18` is therefore the point at which one
///      term alone can move the discount by 2,000 bp and the clamp to `[dMin, dMax]` binds everywhere — exactly
///      the reading `Constants` gives it.
///
/// @dev **A hostile policy cannot issue a dilutive bond.** `AmpsBonds` recomputes `qFloor` itself after this call
///      and reverts with `AccretionFloorViolated` if the returned `q` is above it, so the worst a broken pointer
///      can do is refuse to price.
contract BondPolicy is IBondPolicy {
    /// @notice Identifier of this pricing law. Returned by {version}.
    bytes32 internal constant VERSION_ID = "linear-deficit-fill-v1";

    /// @notice Bps of discount one whole unit of a coefficient contributes per whole unit of its term.
    /// @dev See the contract-level note on coefficient units: `k = 1e18` moves the discount by 1,000 bp across the
    ///      term's full `[0, 1]` range.
    uint256 internal constant COEFFICIENT_BPS_SCALE = 1000;

    /// @dev `1e36`: the denominator of `k x term`, which is a product of two 1e18 fixed-point numbers.
    uint256 internal constant WAD_SQUARED = Constants.WAD * Constants.WAD;

    /// @inheritdoc IBondPolicy
    function quote(QuoteInput calldata input) external pure returns (QuoteOutput memory output) {
        if (input.navPerShareX18 == 0) revert InvalidQuoteInput("navPerShareX18");
        if (input.collateralPriceUsd18 == 0) revert InvalidQuoteInput("collateralPriceUsd18");
        if (input.mX18 == 0) revert InvalidQuoteInput("mX18");
        if (input.hSessionBps >= Constants.BPS) revert InvalidQuoteInput("hSessionBps");

        output.discountBps = _discountBps(
            input.dBaseBps,
            input.dMinBps,
            input.dMaxBps,
            input.kWeightX18,
            input.kFillX18,
            input.deficitX18,
            input.fillX18
        );

        // qMarket = m / (1 - d), rounded down. `d < BPS` is guaranteed by the `dMaxBps` check inside `_discountBps`.
        output.qMarketX18 = FullMath.mulDiv(input.mX18, Constants.BPS, Constants.BPS - output.discountBps);
        output.qFloorX18 =
            qFloorX18(input.collateralPriceUsd18, input.navPerShareX18, input.hSessionBps, input.minAccretionBps);

        output.floorBinding = output.qFloorX18 <= output.qMarketX18;
        output.qX18 = output.floorBinding ? output.qFloorX18 : output.qMarketX18;
        output.ampsOut = FullMath.mulDiv(input.amountIn18, output.qX18, Constants.WAD);
    }

    /// @inheritdoc IBondPolicy
    function discountBps(
        uint16 dBaseBps,
        uint16 dMinBps,
        uint16 dMaxBps,
        uint64 kWeightX18,
        uint64 kFillX18,
        uint64 deficitX18,
        uint64 fillX18
    ) external pure returns (uint16 bps) {
        bps = _discountBps(dBaseBps, dMinBps, dMaxBps, kWeightX18, kFillX18, deficitX18, fillX18);
    }

    /// @inheritdoc IBondPolicy
    function version() external pure returns (bytes32 id) {
        id = VERSION_ID;
    }

    /// @notice The accretion floor alone, exposed so `AmpsBonds` and the quoter can recompute it independently of
    ///         any policy pointer.
    /// @dev This is the same arithmetic, in the same order and with the same rounding directions, that `AmpsBonds`
    ///      re-implements in its own shell. It is `public pure` rather than `internal` so a reviewer can diff the
    ///      two implementations against one call.
    /// @param collateralPriceUsd18 The collateral's last Chainlink answer in 18-decimal USD.
    /// @param navPerShareX18 The vault's checkpointed NAV per share.
    /// @param hSessionBps The session haircut in force, in bps.
    /// @param minAccretionBps The accretion demanded above NAV, in bps.
    /// @return floorX18 The floor price, AMPS wei per 1e18 of collateral, rounded down.
    function qFloorX18(uint256 collateralPriceUsd18, uint256 navPerShareX18, uint16 hSessionBps, uint16 minAccretionBps)
        public
        pure
        returns (uint256 floorX18)
    {
        // Numerator down: a lower collateral valuation issues less AMPS.
        uint256 numerator = FullMath.mulDiv(collateralPriceUsd18, Constants.BPS - hSessionBps, Constants.BPS);
        // Denominator up: a higher NAV requirement issues less AMPS.
        uint256 denominator =
            FullMath.mulDivRoundingUp(navPerShareX18, Constants.BPS + uint256(minAccretionBps), Constants.BPS);
        floorX18 = FullMath.mulDiv(numerator, Constants.WAD, denominator);
    }

    /// @dev The clamped discount. Shared by {quote} and {discountBps} so the two can never drift.
    function _discountBps(
        uint16 dBaseBps,
        uint16 dMinBps,
        uint16 dMaxBps,
        uint64 kWeightX18,
        uint64 kFillX18,
        uint64 deficitX18,
        uint64 fillX18
    ) internal pure returns (uint16 bps) {
        if (dMinBps > dMaxBps) revert InvalidQuoteInput("dMinBps");
        if (dMaxBps >= Constants.BPS) revert InvalidQuoteInput("dMaxBps");
        if (deficitX18 > Constants.WAD) revert InvalidQuoteInput("deficitX18");
        if (fillX18 > Constants.WAD) revert InvalidQuoteInput("fillX18");

        // The deficit term is added, so it rounds down; the fill term is subtracted, so it rounds up. Both
        // directions shrink `d`, which is what "d rounds down" means once the sign of each term is taken into
        // account. Neither product can overflow: `k <= type(uint64).max` and the term is at most 1e18, so the
        // numerator is below 2**64 x 1e21 and `FullMath` carries the full 512-bit intermediate.
        uint256 added = FullMath.mulDiv(uint256(kWeightX18) * COEFFICIENT_BPS_SCALE, deficitX18, WAD_SQUARED);
        uint256 removed = FullMath.mulDivRoundingUp(uint256(kFillX18) * COEFFICIENT_BPS_SCALE, fillX18, WAD_SQUARED);

        uint256 d = uint256(dBaseBps) + added;
        d = d > removed ? d - removed : 0;

        if (d < dMinBps) d = dMinBps;
        if (d > dMaxBps) d = dMaxBps;
        bps = uint16(d);
    }
}
