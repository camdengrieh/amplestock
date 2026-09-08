// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    AuctionParameters,
    IContinuousClearingAuction
} from "../../src/interfaces/external/IContinuousClearingAuction.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockCCA
/// @notice A Continuous Clearing Auction faithful to the parts of the real one that `AmpsGenesis` depends on:
///         the funding handshake, the block schedule, a uniform Q96 clearing price driven by bids at or above the
///         floor on the tick grid, the graduation threshold, the protocol fee taken out of `sweepCurrency`, and
///         the one-shot recipient-restricted sweeps.
///
/// @dev **What it models and what it does not.** It models the *interface contract*: who may call what and when,
///      what a sweep pays out, and what `clearingPrice()`/`isGraduated()` answer afterwards. It does not model the
///      auction's settlement mathematics — the tick book, the supply rollover, the per-block fills or the partial
///      exits — because `AmpsGenesis` never reads any of that. Bids here simply raise the clearing price to the
///      highest price bid and accumulate currency, and `totalCleared` is derived from what was raised at that
///      price, which is enough to exercise every branch of `settle()`.
///
/// @dev **The funding handshake is deliberately the strict one.** The auction refuses to be considered funded
///      until {onTokensReceived} has been called after the tokens arrived, and reverts `TokensNotReceived` on a
///      bid before that. That is the harder of the two shapes the upstream documentation leaves open, so an
///      adapter that works against this mock also works against a factory that funds the auction itself.
contract MockCCA is IContinuousClearingAuction {
    using SafeERC20 for IERC20;

    /// @notice Emitted when the funding handshake completes, as the real auction emits it.
    /// @param supply The token wei recorded.
    event TokensReceived(uint128 supply);

    /// @notice A bid arrived before the tokens did.
    error TokensNotReceived();

    /// @notice A sweep was attempted by anyone other than the configured recipient.
    /// @param authorized Who may call it.
    /// @param caller Who did.
    error NotAuthorized(address authorized, address caller);

    /// @notice A sweep was attempted twice.
    error AlreadySwept();

    /// @notice A sweep or a settlement was attempted before the end block.
    error AuctionNotOver();

    /// @notice A bid arrived outside the auction's block window.
    error AuctionNotStarted();

    /// @notice A bid arrived below the floor or off the tick grid.
    /// @param priceQ96 The rejected price.
    error InvalidBidPrice(uint256 priceQ96);

    address private immutable _TOKEN;
    uint128 private immutable _TOTAL_SUPPLY;
    address private immutable _FEE_RECIPIENT;
    uint16 private immutable _FEE_BPS;

    AuctionParameters private _params;

    bool private _funded;
    uint256 private _clearingPriceQ96;
    uint256 private _currencyRaised;
    uint256 private _totalCleared;
    bool private _currencySwept;
    bool private _tokensSwept;

    /// @param token_ The token being sold.
    /// @param totalSupply_ The token wei the auction will sell.
    /// @param params_ The auction configuration.
    /// @param feeRecipient_ Who receives the protocol fee on `sweepCurrency`, or zero for no fee.
    /// @param feeBps_ The protocol fee, in bps of the gross raise.
    constructor(
        address token_,
        uint128 totalSupply_,
        AuctionParameters memory params_,
        address feeRecipient_,
        uint16 feeBps_
    ) {
        _TOKEN = token_;
        _TOTAL_SUPPLY = totalSupply_;
        _params = params_;
        _FEE_RECIPIENT = feeRecipient_;
        _FEE_BPS = feeBps_;
        _clearingPriceQ96 = params_.floorPrice;
    }

    /// @notice Accepts the native bids of an ETH-denominated auction.
    receive() external payable {}

    // -------------------------------------------------------------------------------------------------------------
    // Funding
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Records that the tranche arrived. The real auction emits `TokensReceived` the same way.
    function onTokensReceived() external {
        require(IERC20(_TOKEN).balanceOf(address(this)) >= _TOTAL_SUPPLY, "MockCCA: underfunded");
        _funded = true;
        emit TokensReceived(_TOTAL_SUPPLY);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Bidding
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Places a bid at `maxPriceQ96` for `amount` of currency. Test-only shape: the bid is taken at face
    ///         value and lifts the clearing price to `maxPriceQ96` when it is higher than the current one.
    /// @param maxPriceQ96 The Q96 price bid.
    /// @param amount The currency raw units bid. For an ETH auction it must equal `msg.value`.
    function bid(uint256 maxPriceQ96, uint256 amount) external payable {
        if (!_funded) revert TokensNotReceived();
        if (block.number < _params.startBlock || block.number >= _params.endBlock) revert AuctionNotStarted();
        if (maxPriceQ96 < _params.floorPrice) revert InvalidBidPrice(maxPriceQ96);
        if ((maxPriceQ96 - _params.floorPrice) % _params.tickSpacing != 0) revert InvalidBidPrice(maxPriceQ96);

        if (_params.currency == address(0)) {
            require(msg.value == amount, "MockCCA: value");
        } else {
            require(msg.value == 0, "MockCCA: not native");
            IERC20(_params.currency).safeTransferFrom(msg.sender, address(this), amount);
        }

        _currencyRaised += amount;
        if (maxPriceQ96 > _clearingPriceQ96) _clearingPriceQ96 = maxPriceQ96;

        // `raised / price` token wei, capped at the tranche. Enough for `totalCleared` to be meaningful without
        // reproducing the real book.
        uint256 cleared = (_currencyRaised << 96) / _clearingPriceQ96;
        _totalCleared = cleared > _TOTAL_SUPPLY ? _TOTAL_SUPPLY : cleared;
    }

    /// @inheritdoc IContinuousClearingAuction
    function checkpoint() external {}

    // -------------------------------------------------------------------------------------------------------------
    // Settlement
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IContinuousClearingAuction
    function sweepCurrency() external {
        if (msg.sender != _params.fundsRecipient) revert NotAuthorized(_params.fundsRecipient, msg.sender);
        if (block.number < _params.endBlock) revert AuctionNotOver();
        if (_currencySwept) revert AlreadySwept();
        _currencySwept = true;
        if (!_graduated()) return;

        uint256 gross = _currencyRaised;
        uint256 fee = _FEE_RECIPIENT == address(0) ? 0 : (gross * _FEE_BPS) / 10_000;
        uint256 net = gross - fee;

        if (_params.currency == address(0)) {
            if (fee != 0) _sendNative(_FEE_RECIPIENT, fee);
            _sendNative(msg.sender, net);
        } else {
            if (fee != 0) IERC20(_params.currency).safeTransfer(_FEE_RECIPIENT, fee);
            IERC20(_params.currency).safeTransfer(msg.sender, net);
        }
    }

    /// @inheritdoc IContinuousClearingAuction
    function sweepUnsoldTokens() external {
        if (msg.sender != _params.tokensRecipient) revert NotAuthorized(_params.tokensRecipient, msg.sender);
        if (block.number < _params.endBlock) revert AuctionNotOver();
        if (_tokensSwept) revert AlreadySwept();
        _tokensSwept = true;

        uint256 unsold = _graduated() ? uint256(_TOTAL_SUPPLY) - _totalCleared : uint256(_TOTAL_SUPPLY);
        if (unsold != 0) IERC20(_TOKEN).safeTransfer(msg.sender, unsold);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IContinuousClearingAuction
    function clearingPrice() external view returns (uint256 priceQ96) {
        return _currencyRaised == 0 ? 0 : _clearingPriceQ96;
    }

    /// @inheritdoc IContinuousClearingAuction
    function isGraduated() external view returns (bool graduated) {
        return _graduated();
    }

    /// @inheritdoc IContinuousClearingAuction
    function currencyRaised() external view returns (uint256 raised) {
        return _currencyRaised;
    }

    /// @inheritdoc IContinuousClearingAuction
    function totalCleared() external view returns (uint256 cleared) {
        return _totalCleared;
    }

    /// @inheritdoc IContinuousClearingAuction
    function token() external view returns (address tokenAddress) {
        return _TOKEN;
    }

    /// @inheritdoc IContinuousClearingAuction
    function currency() external view returns (address currencyAddress) {
        return _params.currency;
    }

    /// @inheritdoc IContinuousClearingAuction
    function totalSupply() external view returns (uint128 supply) {
        return _TOTAL_SUPPLY;
    }

    /// @inheritdoc IContinuousClearingAuction
    function tokensRecipient() external view returns (address recipient) {
        return _params.tokensRecipient;
    }

    /// @inheritdoc IContinuousClearingAuction
    function fundsRecipient() external view returns (address recipient) {
        return _params.fundsRecipient;
    }

    /// @inheritdoc IContinuousClearingAuction
    function startBlock() external view returns (uint64 blockNumber) {
        return _params.startBlock;
    }

    /// @inheritdoc IContinuousClearingAuction
    function endBlock() external view returns (uint64 blockNumber) {
        return _params.endBlock;
    }

    /// @inheritdoc IContinuousClearingAuction
    function claimBlock() external view returns (uint64 blockNumber) {
        return _params.claimBlock;
    }

    /// @notice The configuration the factory deployed this auction with.
    function parameters() external view returns (AuctionParameters memory params) {
        return _params;
    }

    /// @notice Whether the funding handshake completed.
    function funded() external view returns (bool done) {
        return _funded;
    }

    // -------------------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Graduation is the real rule: `currencyRaised >= requiredCurrencyRaised`.
    function _graduated() private view returns (bool graduated) {
        return _currencyRaised >= _params.requiredCurrencyRaised;
    }

    /// @dev A native transfer that surfaces its own failure.
    function _sendNative(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "MockCCA: native send failed");
    }
}
