// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The configuration one Continuous Clearing Auction is deployed with.
/// @dev Field-for-field the `AuctionParameters` struct of `Uniswap/continuous-clearing-auction` v2.x (MIT), which
///      the factory ABI-decodes out of `configData`. The order and the widths are ABI, so they are restated here
///      exactly rather than paraphrased: a re-ordered field would encode to a valid but wrong auction.
/// @param currency The token bids are denominated in. `address(0)` means native ETH.
/// @param tokensRecipient Who receives the tokens that never cleared.
/// @param fundsRecipient Who receives the currency raised, net of the factory's protocol fee.
/// @param startBlock The block the first issuance step starts on.
/// @param endBlock The block the auction finishes on.
/// @param claimBlock The block from which filled bidders may claim.
/// @param tickSpacing The fixed Q96 price granularity bids must sit on.
/// @param validationHook An `IValidationHook` called before every bid, or `address(0)` for none.
/// @param floorPrice The starting Q96 price: currency raw units per token raw unit, shifted left 96 bits.
/// @param requiredCurrencyRaised The graduation threshold, in currency raw units.
/// @param auctionStepsData The packed issuance schedule. See {IContinuousClearingAuction} for the packing.
struct AuctionParameters {
    address currency;
    address tokensRecipient;
    address fundsRecipient;
    uint64 startBlock;
    uint64 endBlock;
    uint64 claimBlock;
    uint256 tickSpacing;
    address validationHook;
    uint256 floorPrice;
    uint128 requiredCurrencyRaised;
    bytes auctionStepsData;
}

/// @title IContinuousClearingAuction
/// @notice The subset of `Uniswap/continuous-clearing-auction`'s auction surface that `AmpsGenesis` calls or
///         reads. Hand-written from the upstream MIT interface and its `TechnicalDocumentation.md`; see
///         `NOTICES.md`.
///
/// @dev **Why a hand-written subset rather than the vendored interface.** The upstream `IContinuousClearingAuction`
///      inherits six storage interfaces plus `ILBPInitializer` from the `liquidity-launcher` submodule, none of
///      which Amplestocks needs: the protocol consumes the auction through its own settlement (`AmpsGenesis`)
///      rather than through the stock LBP strategy, because `AmpsHook.beforeInitialize` refuses any pool the
///      vault did not open. Vendoring the tree would drag in two submodules to reach five functions.
///
/// @dev **The issuance schedule's packing.** `auctionStepsData` is a concatenation of 8-byte words, each holding
///      a per-block issuance rate in MPS (milli-bips of total supply, `1e7` = 100%) and a block count. Upstream
///      `AuctionStepLib.parse` reads them as
///
///      ```
///      mps        = uint24(bytes3(data));   // the top 24 bits of the word
///      blockDelta = uint40(uint64(data));   // the low 40 bits
///      ```
///
///      i.e. `word = (uint64(mps) << 40) | uint64(blockDelta)`. **The prose example in upstream's
///      `TechnicalDocumentation.md` contradicts its own quoted `parse` and shows `uint64(mps) | (blockDelta <<
///      24)`.** `AmpsGenesis.packStep` implements the `parse`-derived layout, which is the one the deployed
///      bytecode uses, and `AmpsGenesis.stepsTotalMps` validates a blob against it before any auction is created.
///      A deployment must confirm the layout against the live factory on a testnet before the mainnet run.
interface IContinuousClearingAuction {
    /// @notice Registers the checkpoint for the current block and returns it.
    /// @dev Declared as returning nothing. Upstream returns a `Checkpoint` struct out of `CheckpointLib`, which
    ///      would drag that library in for a value `AmpsGenesis` never reads: the settlement calls this only to
    ///      force the end block to be checkpointed before reading {clearingPrice} and {isGraduated}. Solidity
    ///      ignores returndata a call does not decode, so the narrower declaration is call-compatible.
    function checkpoint() external;

    /// @notice The most up-to-date uniform clearing price, Q96, currency raw units per token raw unit.
    /// @dev Callers must ensure the latest checkpoint is current first; {checkpoint} is what does that.
    function clearingPrice() external view returns (uint256 priceQ96);

    /// @notice Whether `currencyRaised >= requiredCurrencyRaised` as of the latest checkpoint.
    function isGraduated() external view returns (bool graduated);

    /// @notice The gross currency raised, before the factory's protocol fee.
    function currencyRaised() external view returns (uint256 raised);

    /// @notice Total token wei cleared to bidders.
    function totalCleared() external view returns (uint256 cleared);

    /// @notice Sends the currency raised, net of the protocol fee, to `fundsRecipient`. One shot.
    /// @dev Only the funds recipient may call it, and only after the auction has ended. A non-graduated auction
    ///      sweeps zero rather than reverting (upstream v2 change), but `AmpsGenesis` calls it only on the
    ///      graduated legs so that behaviour is never load-bearing.
    function sweepCurrency() external;

    /// @notice Sends the tokens that did not clear to `tokensRecipient`. One shot.
    /// @dev Only the tokens recipient may call it, and only after the auction has ended. A graduated auction
    ///      sweeps `remainingSupply()`; a non-graduated one sweeps the whole `totalSupply`.
    function sweepUnsoldTokens() external;

    /// @notice The token being sold.
    function token() external view returns (address tokenAddress);

    /// @notice The token bids are denominated in. `address(0)` for native ETH.
    function currency() external view returns (address currencyAddress);

    /// @notice The token wei the auction was funded with.
    function totalSupply() external view returns (uint128 supply);

    /// @notice Who receives the unsold tokens.
    function tokensRecipient() external view returns (address recipient);

    /// @notice Who receives the currency raised.
    function fundsRecipient() external view returns (address recipient);

    /// @notice The block the first issuance step starts on.
    function startBlock() external view returns (uint64 blockNumber);

    /// @notice The block the auction finishes on.
    function endBlock() external view returns (uint64 blockNumber);

    /// @notice The block from which filled bidders may claim.
    function claimBlock() external view returns (uint64 blockNumber);
}
