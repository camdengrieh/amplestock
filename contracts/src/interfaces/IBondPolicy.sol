// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IBondPolicy
/// @notice The bond pricing law. Pure, stateless and pointer-upgradeable behind the 7-day timelock: a new discount
///         law needs a new policy contract, not a vault migration.
///
/// @dev **Everything is passed in.** The policy holds no storage, reads no oracle and calls nothing. `AmpsBonds`
///      assembles a {QuoteInput} from its own governed state, the vault's checkpoint and the gate's haircut, and
///      the policy returns numbers. Consequences that make the pointer safe: a hostile policy can only move `q`,
///      never move an asset; and `AmpsBonds` re-checks the accretion floor itself after the call, so a policy that
///      returns a `q` above `qFloor` is rejected in the shell rather than obeyed.
///
/// @dev **The formula** (AMPS out per unit of collateral, `q`):
///
///      ```
///      d_i      = clamp(dBase + k_w x deficit_i - k_c x fill_i, dMin, dMax)
///      q_market = m / (1 - d_i)
///      q_floor  = P_i x (1 - h_session) / (navPerShare x (1 + minAccretionBps))
///      q        = min(q_market, q_floor)
///      ampsOut  = amountIn18 x q
///      ```
///
///      where `m` is the spoke's own 30-minute truncated TWAP in AMPS per unit of collateral (live 24/7),
///      `deficit_i = max(0, w_target - w_current) / w_target` and `fill_i = usedThisEpoch / capacity`.
///
/// @dev **Rounding directions, all of them protocol-favourable.** The implementation must round exactly this way,
///      and the Phase 2 pricing table asserts it:
///
///      | Quantity          | Direction | Why |
///      |-------------------|-----------|-----|
///      | `m`               | down      | fewer AMPS per unit of collateral |
///      | `deficit_i`       | down      | a smaller deficit widens the discount less |
///      | `fill_i`          | up        | a larger fill narrows the discount more |
///      | `d_i`             | down      | a smaller discount issues less AMPS |
///      | `q_market`        | down      | ditto |
///      | `q_floor` numerator | down    | a lower collateral valuation issues less AMPS |
///      | `q_floor` denominator | up    | a higher NAV requirement issues less AMPS |
///      | `q`, `ampsOut`    | down      | the bonder never receives a wei more than the formula |
///
///      Rounding down `ampsOut` is what makes invariant I27 (`NAV/share after a bond >= NAV/share before`) hold
///      exactly rather than up to dust.
///
/// @dev **Why the floor exists.** `q_floor` is computed from the last Chainlink answer with a session haircut,
///      *not* from the pool. It caps what any amount of TWAP manipulation can buy: the best an attacker who dumps
///      a spoke can do is remove their own discount, because `q = min(q_market, q_floor)` and `q_floor` does not
///      move with the pool. It also bounds weekend-gap exposure to `h_session` on the bonded amount.
interface IBondPolicy {
    /// @notice Everything the pricing law is allowed to see. Assembled by `AmpsBonds` from its own state, the
    ///         vault checkpoint and the gate.
    /// @param mX18 The spoke's 30-minute truncated TWAP, in AMPS wei per 1e18 raw units of collateral, rounded
    ///        down. For an `ENTRY`-class market this is the entry pool's own TWAP.
    /// @param navPerShareX18 The vault's checkpointed NAV per share, USD per AMPS, 18 decimals.
    /// @param collateralPriceUsd18 The collateral's last Chainlink answer converted to 18-decimal USD. Never
    ///        multiplied by any `uiMultiplier()`.
    /// @param amountIn18 The deposit, normalised to 18 decimals (USDG's 6 decimals are scaled up by the shell).
    /// @param dBaseBps Base discount for this market.
    /// @param dMinBps Discount floor for this market.
    /// @param dMaxBps Discount ceiling for this market.
    /// @param kWeightX18 `k_w`: discount added per unit of index deficit.
    /// @param kFillX18 `k_c`: discount removed per unit of epoch fill.
    /// @param deficitX18 `max(0, w_target - w_current) / w_target`, 1e18 fixed point, already clamped to `[0, 1e18]`.
    /// @param fillX18 `usedThisEpoch / capacity`, 1e18 fixed point, already clamped to `[0, 1e18]`.
    /// @param hSessionBps The stale-feed haircut in force, from the gate.
    /// @param minAccretionBps The accretion the protocol demands above NAV on every bond.
    struct QuoteInput {
        uint256 mX18;
        uint256 navPerShareX18;
        uint256 collateralPriceUsd18;
        uint256 amountIn18;
        uint16 dBaseBps;
        uint16 dMinBps;
        uint16 dMaxBps;
        uint64 kWeightX18;
        uint64 kFillX18;
        uint64 deficitX18;
        uint64 fillX18;
        uint16 hSessionBps;
        uint16 minAccretionBps;
    }

    /// @notice The priced result.
    /// @param ampsOut AMPS wei the bonder receives, before the capacity check, rounded down.
    /// @param qX18 The applied price, AMPS wei per 1e18 of collateral, `min(qMarketX18, qFloorX18)`.
    /// @param qMarketX18 The market-derived price, `m / (1 - d)`.
    /// @param qFloorX18 The NAV-derived accretion floor.
    /// @param discountBps The clamped discount actually applied.
    /// @param floorBinding True when `qFloorX18 <= qMarketX18`, i.e. the bond issues at the floor rather than at a
    ///        real discount. The dApp shows this; the invariant suite asserts it whenever the premium is below the
    ///        discount.
    struct QuoteOutput {
        uint256 ampsOut;
        uint256 qX18;
        uint256 qMarketX18;
        uint256 qFloorX18;
        uint16 discountBps;
        bool floorBinding;
    }

    /// @notice Thrown when an input is structurally impossible (zero NAV, zero price, `dMin > dMax`). A policy
    ///         never silently substitutes a default: `AmpsBonds` catches nothing, so a bad input closes the market
    ///         for that call rather than mispricing it.
    /// @param reason A short identifier of the offending input, e.g. `bytes32("navPerShareX18")`.
    error InvalidQuoteInput(bytes32 reason);

    /// @notice Prices one bond.
    /// @dev Pure. Must not revert for any input that `AmpsBonds` can produce from in-band governed state and a
    ///      healthy checkpoint.
    /// @param input The assembled inputs.
    /// @return output The priced result.
    function quote(QuoteInput calldata input) external pure returns (QuoteOutput memory output);

    /// @notice The discount term alone, exposed so the dApp and the quoter can show the curve without pricing a
    ///         hypothetical deposit.
    /// @param dBaseBps Base discount.
    /// @param dMinBps Discount floor.
    /// @param dMaxBps Discount ceiling.
    /// @param kWeightX18 `k_w`.
    /// @param kFillX18 `k_c`.
    /// @param deficitX18 The index deficit term.
    /// @param fillX18 The epoch fill term.
    /// @return bps The clamped discount, rounded down.
    function discountBps(
        uint16 dBaseBps,
        uint16 dMinBps,
        uint16 dMaxBps,
        uint64 kWeightX18,
        uint64 kFillX18,
        uint64 deficitX18,
        uint64 fillX18
    ) external pure returns (uint16 bps);

    /// @notice Identifier of this pricing law, for governance diffs and the dApp.
    /// @return id A short identifier, e.g. `bytes32("linear-deficit-fill-v1")`.
    function version() external pure returns (bytes32 id);
}
