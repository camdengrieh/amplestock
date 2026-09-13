// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AuctionParameters} from "../../src/interfaces/external/IContinuousClearingAuction.sol";
import {MockCCA} from "./MockCCA.sol";

/// @title MockCCAFactory
/// @notice A stand-in for `ContinuousClearingAuctionFactory`: it ABI-decodes `configData` into
///         `AuctionParameters`, deploys a {MockCCA} with CREATE2 at the caller's salt, and returns its address.
///
/// @dev **It answers to `create` only, on purpose.** Upstream's `CHANGELOG.md` renamed
///      `initializeDistribution` to `create` in v2.0.0 while its `TechnicalDocumentation.md` still documents the
///      old name; `AmpsGenesis` therefore tries `create` first and falls back. This mock implements the new name
///      and {MockLegacyCCAFactory} implements the old one, so both halves of that fallback are exercised by the
///      suite rather than assumed.
///
/// @dev **It does not pull the tokens.** The adapter approves the factory before calling and pushes whatever the
///      factory did not take, so this mock proves the pushing half; a factory that pulled would be covered by the
///      approval the adapter grants and clears around the call.
contract MockCCAFactory {
    /// @notice Emitted for every auction deployed, as the real factory emits it.
    /// @param auction The auction.
    /// @param token The token being sold.
    /// @param amount The tranche.
    /// @param configData The encoded parameters.
    event AuctionCreated(address indexed auction, address indexed token, uint256 amount, bytes configData);

    /// @notice The protocol fee recipient every auction this factory deploys pays.
    /// @dev Storage rather than an immutable, and settable, so a suite can turn the fee on between two
    ///      `createAuctions` calls without redeploying the world. The real controller is upgradeable too — the
    ///      auction reads the fee at sweep time, not at construction — so this is the more faithful shape anyway.
    address public feeRecipient;

    /// @notice The protocol fee, in bps of the gross raise.
    uint16 public feeBps;

    /// @param feeRecipient_ Who receives the protocol fee, or zero for a fee-free factory.
    /// @param feeBps_ The fee, in bps.
    constructor(address feeRecipient_, uint16 feeBps_) {
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    /// @notice Changes the fee every auction created *after* this call pays. Test-only: unrestricted by design.
    /// @param feeRecipient_ Who receives it, or zero for none.
    /// @param feeBps_ The fee, in bps.
    function setFee(address feeRecipient_, uint16 feeBps_) external {
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    /// @notice The fee controller disclosure. The mock is its own controller.
    function protocolFeeController() external view returns (address controller) {
        return feeRecipient;
    }

    /// @notice Deploys one auction. The v2 name.
    /// @param token The token to sell.
    /// @param amount The tranche.
    /// @param configData The ABI-encoded `AuctionParameters`.
    /// @param salt The CREATE2 salt.
    /// @return auction The deployed auction.
    function create(address token, uint256 amount, bytes calldata configData, bytes32 salt)
        external
        returns (address auction)
    {
        AuctionParameters memory params = abi.decode(configData, (AuctionParameters));
        auction = address(
            new MockCCA{salt: keccak256(abi.encode(msg.sender, salt))}(
                token, uint128(amount), params, feeRecipient, feeBps
            )
        );
        emit AuctionCreated(auction, token, amount, configData);
    }
}

/// @title MockLegacyCCAFactory
/// @notice The same factory under the pre-v2 name `initializeDistribution`, so the suite proves `AmpsGenesis`
///         reaches a factory that predates the `IDistributorFactory` rename rather than only the current one.
contract MockLegacyCCAFactory {
    /// @notice The protocol fee recipient.
    address public immutable feeRecipient;

    /// @notice The protocol fee, in bps.
    uint16 public immutable feeBps;

    /// @param feeRecipient_ Who receives the protocol fee, or zero.
    /// @param feeBps_ The fee, in bps.
    constructor(address feeRecipient_, uint16 feeBps_) {
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    /// @notice The fee controller disclosure.
    function protocolFeeController() external view returns (address controller) {
        return feeRecipient;
    }

    /// @notice Deploys one auction. The pre-v2 name.
    /// @param token The token to sell.
    /// @param amount The tranche.
    /// @param configData The ABI-encoded `AuctionParameters`.
    /// @param salt The CREATE2 salt.
    /// @return auction The deployed auction.
    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32 salt)
        external
        returns (address auction)
    {
        AuctionParameters memory params = abi.decode(configData, (AuctionParameters));
        auction = address(
            new MockCCA{salt: keccak256(abi.encode(msg.sender, salt))}(
                token, uint128(amount), params, feeRecipient, feeBps
            )
        );
    }
}

/// @title RevertingCCAFactory
/// @notice A factory that refuses every deployment, so the suite can prove `AmpsGenesis` surfaces the factory's
///         own revert reason rather than swallowing it behind its two-name fallback.
contract RevertingCCAFactory {
    /// @notice The reason this factory always gives.
    error FactoryRefused(string why);

    /// @notice Always reverts.
    function create(address, uint256, bytes calldata, bytes32) external pure returns (address) {
        revert FactoryRefused("create");
    }

    /// @notice Always reverts.
    function initializeDistribution(address, uint256, bytes calldata, bytes32) external pure returns (address) {
        revert FactoryRefused("initializeDistribution");
    }
}
