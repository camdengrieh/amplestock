// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAmpsGenesis
/// @notice The genesis adapter: `fundsRecipient` and `tokensRecipient` of the two Continuous Clearing Auctions
///         that sell the auction tranche, and the only auction-side caller of `AmpsVault.genesisPlace`.
///
/// @dev **The shape of a launch.** `AmpsVault.genesisMint` mints `S0` once — the team tranche to an OZ
///      `VestingWallet`, the auction tranche to the contract behind this interface, the POL tranche to the vault
///      — and stops. {createAuctions} then builds one auction per currency through the canonical
///      `ContinuousClearingAuctionFactory` and funds each with its tranche. Bidding runs for the configured block
///      window. After both end blocks anyone calls {settle}, which sweeps the raised currency and the unsold
///      tokens, wraps the ETH leg into WETH9, derives the launch reference `P0` from the clearing price and hands
///      everything to `AmpsVault.genesisPlace` in one transaction. Nothing here is upgradeable and nothing here
///      has an owner; {createAuctions} is the only privileged call and it can happen exactly once.
///
/// @dev **`P0` and the divergence cross-check.** `P0` is the USDG auction's clearing price converted to 18-decimal
///      USD per AMPS. When both legs graduate the ETH leg's clearing price times ETH/USD is compared against it;
///      a disagreement wider than the vault's `refDivergenceBps` emits {ClearingPricesDiverged} and the USDG price
///      is used anyway, because it is the one denominated in the unit `P_ref` is quoted in. When only the ETH leg
///      graduates, `P0` is that leg's price times ETH/USD.
///
/// @dev **No graduation is a defined outcome, not a failure.** If neither leg reaches its
///      `requiredCurrencyRaised`, bidders refund in full through the auctions themselves, {settle} returns the
///      whole auction tranche to the vault as inventory and calls nothing else, and {phase} reports
///      {Phase.Aborted}. The launch then proceeds through the founders' seed path: the timelock calls
///      `AmpsVault.genesisPlace` itself with `p0X18 = 1e18`.
interface IAmpsGenesis {
    /// @notice Where a launch has got to, derived from state and the block number rather than stored.
    enum Phase {
        /// @dev Constructed, and either no auctions yet or the first issuance block has not arrived.
        Created,
        /// @dev At least one auction is open for bids.
        Bidding,
        /// @dev Every auction's end block has passed and {settle} has not run.
        Ended,
        /// @dev {settle} ran and at least one leg graduated: the vault holds the proceeds and `P0`.
        Settled,
        /// @dev {settle} ran and no leg graduated: the tranche went back to the vault, bidders refund themselves.
        Aborted
    }

    /// @notice One auction's configuration, as the governance proposal supplies it.
    /// @dev The floor price is not here: it is $1.00 per AMPS by construction, computed inside {createAuctions}
    ///      from the currency's decimals and — for the ETH leg — from the ETH/USD price the same call carries. A
    ///      floor a proposal could set freely is the one parameter a launch cannot safely take on trust.
    /// @param shares AMPS wei this leg sells. Zero disables the leg entirely and its tranche is never minted out.
    /// @param startBlock The block the first issuance step starts on.
    /// @param endBlock The block bidding closes on.
    /// @param claimBlock The block filled bidders may claim from. Must be at or after `endBlock`.
    /// @param tickSpacing The Q96 price granularity bids sit on. Upstream requires at least 2 and recommends at
    ///        least one basis point of the floor price.
    /// @param validationHook An `IValidationHook` (geo-block, allowlist) or `address(0)` for an open auction.
    /// @param requiredCurrencyRaised The graduation threshold, in currency raw units.
    /// @param auctionStepsData The packed per-block issuance schedule. See {packStep}.
    /// @param salt The CREATE2 salt the factory deploys the auction at.
    struct AuctionSpec {
        uint128 shares;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        uint256 tickSpacing;
        address validationHook;
        uint128 requiredCurrencyRaised;
        bytes auctionStepsData;
        bytes32 salt;
    }

    /// @notice Emitted once, by {createAuctions}.
    /// @param usdgAuction The USDG-denominated auction, or zero if that leg was disabled.
    /// @param ethAuction The native-ETH auction, or zero if that leg was disabled.
    /// @param floorUsdgQ96 The USDG floor, Q96 USDG raw units per AMPS wei. `$1.00` per AMPS.
    /// @param floorEthQ96 The ETH floor, Q96 wei per AMPS wei. `$1.00 / ethUsdX18` per AMPS.
    /// @param startBlock The earliest start block across the legs created.
    /// @param endBlock The latest end block across the legs created.
    event AuctionsCreated(
        address indexed usdgAuction,
        address indexed ethAuction,
        uint256 floorUsdgQ96,
        uint256 floorEthQ96,
        uint64 startBlock,
        uint64 endBlock
    );

    /// @notice Emitted once, by {settle}, whatever the outcome.
    /// @param p0X18 The launch reference price, 18-decimal USD per AMPS. Zero when nothing graduated.
    /// @param usdgRaised USDG raw units swept, net of the factory's protocol fee.
    /// @param ethRaised WETH wei swept, net of the protocol fee, after wrapping.
    /// @param unsoldAmps AMPS wei returned to the vault.
    /// @param usdgGraduated Whether the USDG leg reached its threshold.
    /// @param ethGraduated Whether the ETH leg reached its threshold.
    event Settled(
        uint256 p0X18, uint256 usdgRaised, uint256 ethRaised, uint256 unsoldAmps, bool usdgGraduated, bool ethGraduated
    );

    /// @notice Emitted by {settle} when both legs graduated and their implied USD prices disagree by more than the
    ///         vault's `refDivergenceBps`. The USDG price is used regardless; this is disclosure.
    /// @param usdgP0X18 The USDG leg's implied price.
    /// @param ethP0X18 The ETH leg's implied price.
    /// @param toleranceBps The vault's `refDivergenceBps` at settlement.
    event ClearingPricesDiverged(uint256 usdgP0X18, uint256 ethP0X18, uint16 toleranceBps);

    /// @notice {createAuctions} has already run. There is no reset.
    error AuctionsAlreadyCreated();

    /// @notice {createAuctions} has not run, so there is nothing to settle.
    error AuctionsNotCreated();

    /// @notice {settle} has already run.
    error AlreadySettled();

    /// @notice {settle} was called before an auction's end block.
    /// @param auction The auction still open.
    /// @param endBlock The block it closes on.
    error AuctionNotEnded(address auction, uint64 endBlock);

    /// @notice Both legs were disabled, or a leg's share count does not match its constant.
    /// @param usdgShares The USDG leg's tranche.
    /// @param ethShares The ETH leg's tranche.
    error InvalidTranche(uint256 usdgShares, uint256 ethShares);

    /// @notice The block schedule is not monotone: `startBlock < endBlock <= claimBlock` and a start in the future
    ///         are all required.
    /// @param startBlock The proposed start.
    /// @param endBlock The proposed end.
    /// @param claimBlock The proposed claim block.
    error InvalidSchedule(uint64 startBlock, uint64 endBlock, uint64 claimBlock);

    /// @notice The packed issuance schedule does not issue exactly 100% of the tranche over exactly the auction's
    ///         block window.
    /// @param totalMps The schedule's `SUM(mps x blocks)`. Must be `1e7`.
    /// @param totalBlocks The schedule's `SUM(blocks)`. Must be `endBlock - startBlock`.
    error InvalidSteps(uint256 totalMps, uint256 totalBlocks);

    /// @notice The ETH/USD price the proposal carried disagrees with the vault's feed registry by more than the
    ///         vault's `refDivergenceBps`.
    /// @param supplied The proposal's price, 18 decimals.
    /// @param feed The feed registry's price, 18 decimals.
    error EthUsdMismatch(uint256 supplied, uint256 feed);

    /// @notice The adapter does not hold the tranche {createAuctions} is being asked to sell, i.e.
    ///         `AmpsVault.genesisMint` has not run or minted somewhere else.
    /// @param held AMPS wei held.
    /// @param required AMPS wei needed.
    error TrancheNotFunded(uint256 held, uint256 required);

    /// @notice An auction did not end up holding the tranche it was funded with.
    /// @param auction The auction.
    /// @param held Token wei it holds.
    /// @param required Token wei it should hold.
    error AuctionNotFunded(address auction, uint256 held, uint256 required);

    /// @notice A clearing price of zero came back from a graduated auction, so `P0` cannot be derived.
    /// @param auction The auction.
    error ZeroClearingPrice(address auction);

    /// @notice Native value arrived from something other than an auction leg or WETH9.
    /// @param sender The rejected sender.
    error UnexpectedNative(address sender);

    /// @notice The adapter did not end {settle} empty.
    /// @param token The token left behind, or `address(0)` for native ETH.
    /// @param balance What was left.
    error NotSweptClean(address token, uint256 balance);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Creates and funds the two auctions. **Only timelock**, once.
    /// @dev `AmpsVault.genesisMint` must already have delivered `Constants.AUCTION_SHARES` here. Each leg's floor
    ///      is $1.00 per AMPS: for USDG that is `1e6 x 2^96 / 1e18`, for ETH `2^96 x 1e18 / ethUsdX18_`. When the
    ///      vault has a feed registry that prices WETH, `ethUsdX18_` is cross-checked against it inside
    ///      `refDivergenceBps` and the call reverts {EthUsdMismatch} if it is outside.
    /// @param usdgSpec The USDG leg. `shares == 0` disables it.
    /// @param ethSpec The native-ETH leg. `shares == 0` disables it.
    /// @param ethUsdX18_ The ETH/USD price the ETH floor is derived from, 18 decimals.
    function createAuctions(AuctionSpec calldata usdgSpec, AuctionSpec calldata ethSpec, uint256 ethUsdX18_) external;

    /// @notice Settles both auctions and hands the proceeds, the unsold tranche and `P0` to the vault.
    ///         **Permissionless**, once, after every created leg's end block.
    /// @dev Sweeps the currency from each graduated leg and the unsold tokens from every leg, wraps the native
    ///      proceeds into WETH9, then calls `AmpsVault.genesisPlace`. With no graduation it transfers the whole
    ///      tranche to the vault and calls nothing: the timelock runs the fallback `genesisPlace` afterwards.
    function settle() external;

    // -------------------------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The vault this adapter settles into.
    function vault() external view returns (address vaultAddress);

    /// @notice The AMPS token.
    function amps() external view returns (address ampsAddress);

    /// @notice The `ContinuousClearingAuctionFactory` the auctions are deployed through.
    function factory() external view returns (address factoryAddress);

    /// @notice WETH9: the ETH leg's proceeds are wrapped into it before they reach the vault.
    function weth9() external view returns (address weth9Address);

    /// @notice USDG: the hub pool's counter and the USDG leg's currency.
    function usdg() external view returns (address usdgAddress);

    /// @notice The governance timelock: the only caller of {createAuctions}.
    function timelock() external view returns (address timelockAddress);

    /// @notice The USDG-denominated auction, or zero.
    function usdgAuction() external view returns (address auction);

    /// @notice The native-ETH auction, or zero.
    function ethAuction() external view returns (address auction);

    /// @notice Where the launch has got to.
    function phase() external view returns (Phase current);

    /// @notice Whether {settle} has run, whatever its outcome.
    function settled() external view returns (bool done);

    /// @notice The launch reference price handed to the vault, 18-decimal USD per AMPS. Zero until {settle}, and
    ///         zero forever if nothing graduated.
    function p0X18() external view returns (uint256 price);

    /// @notice USDG raw units swept from the USDG leg, net of the protocol fee.
    function raisedUsdg() external view returns (uint256 amount);

    /// @notice WETH wei swept from the ETH leg, net of the protocol fee, after wrapping.
    function raisedWeth() external view returns (uint256 amount);

    /// @notice The two legs' proceeds priced in 18-decimal USD at `ethUsdX18`, i.e. the `A` the vault started with.
    function raisedUsd18() external view returns (uint256 value);

    /// @notice AMPS wei that never cleared and went back to the vault as inventory.
    function unsoldAmps() external view returns (uint256 amount);

    /// @notice The ETH/USD price this adapter used, 18 decimals: the proposal's at {createAuctions}, refreshed
    ///         from the vault's feed registry at {settle} when that read succeeds.
    function ethUsdX18() external view returns (uint256 price);

    /// @notice The USDG leg's floor, Q96.
    function floorUsdgQ96() external view returns (uint256 priceQ96);

    /// @notice The ETH leg's floor, Q96.
    function floorEthQ96() external view returns (uint256 priceQ96);

    /// @notice Packs one issuance step the way upstream `AuctionStepLib.parse` reads it.
    /// @dev `word = (uint64(mps) << 40) | uint64(blockDelta)`. See {IContinuousClearingAuction} for why this
    ///      contradicts the prose example in upstream's documentation and why `parse` wins.
    /// @param mps The per-block issuance rate, in milli-bips of the tranche (`1e7` = 100%).
    /// @param blockDelta How many blocks to issue at that rate.
    /// @return word The packed step.
    function packStep(uint24 mps, uint40 blockDelta) external pure returns (bytes8 word);

    /// @notice Totals a packed schedule, so a proposal can be checked before it is signed.
    /// @param stepsData The packed schedule.
    /// @return totalMps `SUM(mps x blocks)`, which must be `1e7`.
    /// @return totalBlocks `SUM(blocks)`, which must be the auction's block window.
    function stepsTotals(bytes calldata stepsData) external pure returns (uint256 totalMps, uint256 totalBlocks);
}
