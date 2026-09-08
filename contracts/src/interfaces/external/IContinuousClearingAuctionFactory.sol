// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IContinuousClearingAuctionFactory
/// @notice The `Uniswap/continuous-clearing-auction` factory surface `AmpsGenesis` uses: one CREATE2 deployment
///         per auction, plus the address prediction and the fee-controller disclosure. Hand-written from the
///         upstream MIT interface, its `TechnicalDocumentation.md` and its `CHANGELOG.md`; see `NOTICES.md`.
///
/// @dev **Two names for the same function, and why both are declared.** Upstream's `TechnicalDocumentation.md`
///      documents the deployment entry point as `initializeDistribution(token, amount, configData, salt)` and the
///      prediction as `getAuctionAddress(...)`. Upstream's own `CHANGELOG.md` for v2.0.0 records PR #356, which
///      "standardized the factory's distribution interface to the `liquidity-launcher` submodule's
///      `IDistributorFactory`": `initializeDistribution()` renamed to `create()` and `getAuctionAddress()` to
///      `getAddress()`. The two documents disagree and the source is not vendored here, so `AmpsGenesis` tries
///      {create} first — the newer of the two normative statements — and falls back to {initializeDistribution}
///      when the factory has no such function. Both take identical arguments and return the auction address, so
///      the fallback cannot deploy a *different* auction; it can only reach an older factory.
///
/// @dev **The protocol fee.** Every auction is bound at construction to the factory's immutable
///      `IProtocolFeeController`, and the fee is deducted from the currency `sweepCurrency()` forwards. A
///      self-deployed factory with `protocolFeeController() == address(0)` charges nothing. `AmpsGenesis` never
///      predicts the fee: it measures what actually arrived.
interface IContinuousClearingAuctionFactory {
    /// @notice Deploys an auction for `amount` wei of `token` configured by `configData`, at `salt`.
    /// @dev The v2 name (`IDistributorFactory.create`). `configData` is `abi.encode(AuctionParameters)`.
    /// @param token The token to sell.
    /// @param amount The token wei the auction will sell.
    /// @param configData The ABI-encoded `AuctionParameters`.
    /// @param salt The CREATE2 salt, namespaced by the caller.
    /// @return auction The deployed auction.
    function create(address token, uint256 amount, bytes calldata configData, bytes32 salt)
        external
        returns (address auction);

    /// @notice The pre-v2 name of {create}, kept for a factory that predates PR #356.
    /// @param token The token to sell.
    /// @param amount The token wei the auction will sell.
    /// @param configData The ABI-encoded `AuctionParameters`.
    /// @param salt The CREATE2 salt, namespaced by the caller.
    /// @return auction The deployed auction.
    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32 salt)
        external
        returns (address auction);

    /// @notice The fee controller every auction this factory deploys is bound to. `address(0)` disables fees.
    function protocolFeeController() external view returns (address controller);
}
