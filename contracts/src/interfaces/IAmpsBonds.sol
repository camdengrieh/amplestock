// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BondMarket, CollateralClass, Session, VestingPosition} from "../types/Types.sol";

/// @title IAmpsBonds
/// @notice The only path that increases `Amps.totalSupply()` after genesis (Decision 9). Deposit a registered
///         collateral, receive AMPS at a discount to the spoke's market price but never below
///         `navPerShare x (1 + minAccretionBps)`, vesting linearly over 12 hours.
///
/// @dev **Code immutable, state governed** (Decision 20). Nothing about bonds is fixed except the custody logic:
///      discounts, coefficients, capacity, epochs, vest length, accretion floor, haircuts and per-market open/close
///      are 48-hour timelock setters, each checked against a hard band declared here; the collateral set and the
///      `BondPolicy` pointer are 7-day changes; the pricing law itself lives in a pointer-upgradeable
///      `IBondPolicy`. Written from scratch under MIT — Olympus v2 and Bond Protocol are AGPL-3.0 and were read as
///      reference only, never imported, copied or ported. See `NOTICES.md`.
///
/// @dev **Markets are open 24/7, including weekends and stale-feed periods** (Decision 10). Only three things
///      close one: a corporate-action freeze on that constituent, a guardian freeze, and the divergence breaker on
///      that pool. A stale feed or a closed equity session does *not* close a market — it widens `h_session`, which
///      lowers the accretion floor's collateral valuation and therefore lowers `q`. That is what bounds
///      weekend-gap exposure to `h_session` on the bonded amount instead of refusing the trade.
///
/// @dev **Custody never rests here.** `bond()` moves the collateral straight from the bonder into the PoolManager
///      through `AmpsVault.depositBonded`, which settles it into an ERC-6909 claim inside the same `unlock`. The
///      bonder therefore approves the **vault**, not this contract, and the `sweepClean` invariant (I12) holds for
///      `AmpsBonds` trivially: its ERC-20 balance of every collateral is zero at the end of every external
///      function.
///
/// @dev **Vesting AMPS is minted at purchase** (I30): the whole `principal` enters `totalSupply` immediately and is
///      held by this contract until claimed, so NAV/share reflects the issuance the moment it happens and cannot be
///      gamed by claim timing. AMPS held here for vesting is never counted as protocol inventory.
///
/// @dev **`claim()` is structurally ungated.** It reads no gate, no guardian and no pause flag, and it succeeds
///      regardless of collateral removal, market pause, policy swap or guardian freeze (I38). It is the second and
///      last exemption from the `_requireHealthy` enumeration (I14); `AmpsVault.redeemProRata` is the first.
interface IAmpsBonds {
    /// @notice Emitted on every accepted bond.
    /// @param buyer The bonder.
    /// @param marketId The market bought from.
    /// @param collateral The deposited token.
    /// @param amountIn The deposit, in the collateral's raw units.
    /// @param ampsOut The AMPS wei purchased, minted immediately to this contract.
    /// @param positionId The bonder's position index.
    /// @param qX18 The applied price, AMPS wei per 1e18 of collateral.
    /// @param discountBps The discount actually applied.
    /// @param floorBinding Whether the accretion floor, rather than the market discount, set the price.
    event Bond(
        address indexed buyer,
        uint16 indexed marketId,
        address indexed collateral,
        uint256 amountIn,
        uint256 ampsOut,
        uint256 positionId,
        uint256 qX18,
        uint16 discountBps,
        bool floorBinding
    );

    /// @notice Emitted on every claim.
    /// @param owner The position owner.
    /// @param positionId The position claimed from.
    /// @param to The recipient.
    /// @param amount The AMPS wei transferred.
    event Claim(address indexed owner, uint256 indexed positionId, address indexed to, uint256 amount);

    /// @notice Emitted when a collateral joins the set. 7-day timelock.
    /// @param marketId The new 1-based market id.
    /// @param collateral The token.
    /// @param class Where its proceeds are routed.
    /// @param constituentId The constituent whose spoke receives them, or 0 for `ENTRY`.
    event CollateralAdded(
        uint16 indexed marketId, address indexed collateral, CollateralClass class, uint16 constituentId
    );

    /// @notice Emitted when a collateral leaves the set. 7-day timelock. Stops new bonds only; vesting claims on
    ///         existing positions always complete.
    /// @param marketId The market.
    /// @param collateral The token.
    event CollateralRemoved(uint16 indexed marketId, address indexed collateral);

    /// @notice Emitted when a market is opened or closed.
    /// @param marketId The market.
    /// @param open Whether it accepts new bonds.
    event MarketOpenSet(uint16 indexed marketId, bool open);

    /// @notice Emitted when a market's capacity epoch rolls over.
    /// @param marketId The market.
    /// @param epochStart The new epoch's start.
    /// @param previousIssued AMPS issued in the epoch that just ended.
    event EpochRolled(uint16 indexed marketId, uint32 epochStart, uint128 previousIssued);

    /// @notice Emitted on every governed parameter change, global or per market.
    /// @param marketId The market, or 0 for a global parameter.
    /// @param parameter The parameter name as a short string.
    /// @param previousValue The value before.
    /// @param newValue The value after.
    event BondParameterChanged(
        uint16 indexed marketId, bytes32 indexed parameter, uint256 previousValue, uint256 newValue
    );

    /// @notice Emitted when the pricing policy pointer moves. 7-day timelock. Re-prices new bonds only; positions
    ///         already vesting are untouched.
    /// @param previousPolicy The old policy.
    /// @param newPolicy The new policy.
    event PolicyChanged(address indexed previousPolicy, address indexed newPolicy);

    /// @notice Emitted when the vault role is handed on during a migration.
    /// @param previousVault The old vault.
    /// @param newVault The new vault.
    event VaultChanged(address indexed previousVault, address indexed newVault);

    /// @notice The market exists but is closed to new bonds.
    /// @param marketId The market.
    error MarketClosed(uint16 marketId);

    /// @notice The collateral is already registered.
    /// @param collateral The token.
    /// @param marketId Its existing market id.
    error CollateralExists(address collateral, uint16 marketId);

    /// @notice The collateral set is full: `MAX_COLLATERALS`.
    /// @param max The bound.
    error CollateralSetFull(uint16 max);

    /// @notice A `CONSTITUENT`-class collateral was proposed for a token that is not an active constituent.
    /// @param collateral The token.
    error NotAConstituent(address collateral);

    /// @notice The position does not exist, or does not belong to the caller.
    /// @param owner The claimed owner.
    /// @param positionId The position index.
    error UnknownPosition(address owner, uint256 positionId);

    /// @notice The bond would have issued at or below the accretion floor. Thrown by the shell after the policy
    ///         returns, so that a hostile or buggy policy cannot issue a dilutive bond.
    /// @param qX18 The price the policy returned.
    /// @param qFloorX18 The floor the shell computed independently.
    error AccretionFloorViolated(uint256 qX18, uint256 qFloorX18);

    // -------------------------------------------------------------------------------------------------------------
    // Reads (permissionless)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The vault.
    /// @return vaultAddress The vault address.
    function vault() external view returns (address vaultAddress);

    /// @notice The AMPS token.
    /// @return ampsAddress The token address.
    function amps() external view returns (address ampsAddress);

    /// @notice The pool registry.
    /// @return registryAddress The registry address.
    function registry() external view returns (address registryAddress);

    /// @notice The oracle gate. A **pass-through** to `IAmpsVault.oracleGate()`, never a cached copy: the gate is
    ///         pointer-upgradeable behind the 7-day timelock and there must be exactly one pointer to re-point.
    /// @return gateAddress The gate address.
    function oracleGate() external view returns (address gateAddress);

    /// @notice The current pricing policy.
    /// @return policyAddress The `IBondPolicy` address.
    function policy() external view returns (address policyAddress);

    /// @notice How many markets have ever been created. Ids run `[1, count]`.
    /// @return count The market count.
    function marketCount() external view returns (uint16 count);

    /// @notice A market's full record.
    /// @param marketId The 1-based id.
    /// @return record The market record.
    function market(uint16 marketId) external view returns (BondMarket memory record);

    /// @notice The market id for a collateral, or 0.
    /// @param collateral The token.
    /// @return marketId The 1-based id.
    function marketIdOf(address collateral) external view returns (uint16 marketId);

    /// @notice Prices a hypothetical bond without taking it.
    /// @dev Never reverts for a known market: a closed or gated market returns `ampsOut == 0` with a `reason`, so
    ///      the dApp and `AmpsQuoter` can render the whole board in one multicall.
    /// @param marketId The market.
    /// @param amountIn The deposit, in the collateral's raw units.
    /// @return ampsOut The AMPS wei the bonder would receive, after the capacity clamp.
    /// @return qX18 The applied price.
    /// @return discountBps The discount applied.
    /// @return floorBinding Whether the accretion floor set the price.
    /// @return capacityLeft AMPS wei still issuable by this market in the current epoch.
    /// @return reason `bytes32(0)` when the bond would succeed, otherwise why it would not.
    function quote(uint16 marketId, uint256 amountIn)
        external
        view
        returns (
            uint256 ampsOut,
            uint256 qX18,
            uint16 discountBps,
            bool floorBinding,
            uint256 capacityLeft,
            bytes32 reason
        );

    /// @notice AMPS wei this market may still issue in the current epoch, after the global daily cap.
    /// @param marketId The market.
    /// @return amount The remaining capacity.
    function capacityRemaining(uint16 marketId) external view returns (uint256 amount);

    /// @notice AMPS wei issued across all markets in the trailing day, against `dailyCapBps x totalSupply`.
    /// @return issued The rolling total.
    /// @return capacity The current daily capacity.
    function dailyIssuance() external view returns (uint256 issued, uint256 capacity);

    /// @notice How many positions `owner` holds. Position ids are indices into a per-owner array.
    /// @param owner The bonder.
    /// @return count The position count.
    function positionCount(address owner) external view returns (uint256 count);

    /// @notice One vesting position.
    /// @param owner The bonder.
    /// @param positionId The index.
    /// @return record The position.
    function position(address owner, uint256 positionId) external view returns (VestingPosition memory record);

    /// @notice AMPS wei currently claimable from a position.
    /// @dev Monotone non-decreasing in time and never above `principal` (I28).
    /// @param owner The bonder.
    /// @param positionId The index.
    /// @return amount The claimable AMPS.
    function claimable(address owner, uint256 positionId) external view returns (uint256 amount);

    /// @notice AMPS wei claimable across every position `owner` holds.
    /// @param owner The bonder.
    /// @return amount The total claimable.
    function claimableTotal(address owner) external view returns (uint256 amount);

    // -------------------------------------------------------------------------------------------------------------
    // Governed parameters
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The global capacity epoch length. 6 h at launch.
    /// @return value The parameter.
    function epochSeconds() external view returns (uint32 value);

    /// @notice The global daily issuance cap, in bps of `Amps.totalSupply()`. 200 at launch.
    /// @return value The parameter.
    function dailyCapBps() external view returns (uint16 value);

    /// @notice The vest length applied to new positions. 12 h at launch. Positions freeze their own copy.
    /// @return value The parameter.
    function vestSeconds() external view returns (uint32 value);

    /// @notice The accretion the protocol demands above NAV on every bond, in bps. 50 at launch.
    /// @return value The parameter.
    function minAccretionBps() external view returns (uint16 value);

    /// @notice The stale-feed haircut table indexed by {Session}. A **pass-through** to
    ///         `IOracleGate.hSessionBps`, which owns the table because it owns the session calendar; there is no
    ///         setter here, and `IOracleGate.setHSessionBps` (48 h) is the only way to change it.
    /// @param session The session.
    /// @return bps The haircut. 0 / 50 / 150 / 300 at launch.
    function hSessionBps(Session session) external view returns (uint16 bps);

    /// @notice The default `k_w` applied to markets that carry no override.
    /// @return value The parameter.
    function defaultKWeightX18() external view returns (uint64 value);

    /// @notice The default `k_c` applied to markets that carry no override.
    /// @return value The parameter.
    function defaultKFillX18() external view returns (uint64 value);

    // -------------------------------------------------------------------------------------------------------------
    // Hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Hard floor of every discount parameter, in bps. 500.
    /// @return value The bound.
    function DISCOUNT_BPS_MIN() external view returns (uint16 value);

    /// @notice Hard ceiling of every discount parameter, in bps. 2,500.
    /// @return value The bound.
    function DISCOUNT_BPS_MAX() external view returns (uint16 value);

    /// @notice Hard ceiling of `capBpsPerEpoch`, in bps of total supply. 200.
    /// @return value The bound.
    function CAP_BPS_PER_EPOCH_MAX() external view returns (uint16 value);

    /// @notice Hard ceiling of `dailyCapBps`, in bps of total supply. 500.
    /// @return value The bound.
    function DAILY_CAP_BPS_MAX() external view returns (uint16 value);

    /// @notice Hard floor of `epochSeconds`. 1 h.
    /// @return value The bound.
    function EPOCH_SECONDS_MIN() external view returns (uint32 value);

    /// @notice Hard ceiling of `epochSeconds`. 7 d.
    /// @return value The bound.
    function EPOCH_SECONDS_MAX() external view returns (uint32 value);

    /// @notice Hard floor of `vestSeconds`. 1 h.
    /// @return value The bound.
    function VEST_SECONDS_MIN() external view returns (uint32 value);

    /// @notice Hard ceiling of `vestSeconds`. 7 d.
    /// @return value The bound.
    function VEST_SECONDS_MAX() external view returns (uint32 value);

    /// @notice Hard ceiling of any `h_session` entry, in bps. 1,000.
    /// @return value The bound.
    function H_SESSION_BPS_MAX() external view returns (uint16 value);

    /// @notice Hard ceiling of `minAccretionBps`. 500.
    /// @return value The bound.
    function MIN_ACCRETION_BPS_MAX() external view returns (uint16 value);

    /// @notice Hard ceiling of either bond coefficient, 1e18 fixed point. 2e18.
    /// @return value The bound.
    function COEFFICIENT_X18_MAX() external view returns (uint64 value);

    /// @notice Hard ceiling on the collateral set. `MAX_CONSTITUENTS + 2` == 66.
    /// @return value The bound.
    function MAX_COLLATERALS() external view returns (uint16 value);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — user paths
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Buys a bond. **Permissionless.**
    /// @dev Order of operations, all inside one transient reentrancy lock:
    ///      gate check for the constituent → epoch roll → price through `IBondPolicy` → independent floor re-check
    ///      → capacity clamp (per-epoch then global daily) → `minAmpsOut` check → `AmpsVault.depositBonded` pulls
    ///      the collateral straight from `msg.sender` into the PoolManager → `AmpsVault.mintVesting` mints
    ///      `ampsOut` to this contract → position written → event.
    ///      The bonder approves the **vault**, not this contract.
    /// @param marketId The market to buy from.
    /// @param amountIn The deposit, in the collateral's raw units.
    /// @param minAmpsOut The caller's slippage bound.
    /// @param to The address that will own the vesting position.
    /// @return ampsOut The AMPS wei purchased.
    /// @return positionId The new position's index in `to`'s array.
    function bond(uint16 marketId, uint256 amountIn, uint256 minAmpsOut, address to)
        external
        returns (uint256 ampsOut, uint256 positionId);

    /// @notice Claims the vested part of one position. **Structurally ungated** (I38): no gate read, no guardian
    ///         read, no pause flag, no reference to a removed collateral or a swapped policy.
    /// @param positionId The caller's position index.
    /// @param to The recipient.
    /// @return amount The AMPS wei transferred.
    function claim(uint256 positionId, address to) external returns (uint256 amount);

    /// @notice Claims every position the caller holds. **Structurally ungated**, same as {claim}.
    /// @param to The recipient.
    /// @return amount The AMPS wei transferred.
    function claimAll(address to) external returns (uint256 amount);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — governance
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Adds a collateral and opens its market. **Only timelock (7 d).**
    /// @dev A `CONSTITUENT`-class add requires the token to be an active constituent; the same proposal may carry
    ///      `PoolRegistry.addConstituent`, which is how a bond market creates a new spoke's depth.
    /// @param collateral The token.
    /// @param class Where proceeds are routed.
    /// @param dBaseBps Base discount, inside `[DISCOUNT_BPS_MIN, DISCOUNT_BPS_MAX]`.
    /// @param dMinBps Discount floor, inside the same band and at most `dMaxBps`.
    /// @param dMaxBps Discount ceiling, inside the same band.
    /// @param capBpsPerEpoch Per-epoch capacity, at most `CAP_BPS_PER_EPOCH_MAX`.
    /// @param open Whether the market accepts bonds immediately. `ENTRY`-class markets launch closed.
    /// @return marketId The new 1-based market id.
    function addCollateral(
        address collateral,
        CollateralClass class,
        uint16 dBaseBps,
        uint16 dMinBps,
        uint16 dMaxBps,
        uint16 capBpsPerEpoch,
        bool open
    ) external returns (uint16 marketId);

    /// @notice Removes a collateral. **Only timelock (7 d).** Stops new bonds only: every vesting position on the
    ///         market still claims to completion (I38).
    /// @param collateral The token.
    function removeCollateral(address collateral) external;

    /// @notice Opens or closes one market. **Only timelock (48 h).**
    /// @param marketId The market.
    /// @param open Whether it accepts new bonds.
    function setMarketOpen(uint16 marketId, bool open) external;

    /// @notice Sets a market's discount parameters. **Only timelock (48 h).**
    /// @param marketId The market.
    /// @param dBaseBps Base discount.
    /// @param dMinBps Discount floor.
    /// @param dMaxBps Discount ceiling.
    function setDiscountParams(uint16 marketId, uint16 dBaseBps, uint16 dMinBps, uint16 dMaxBps) external;

    /// @notice Sets a market's discount coefficients. **Only timelock (48 h).**
    /// @param marketId The market.
    /// @param kWeightX18 `k_w`, at most `COEFFICIENT_X18_MAX`.
    /// @param kFillX18 `k_c`, at most `COEFFICIENT_X18_MAX`.
    function setCoefficients(uint16 marketId, uint64 kWeightX18, uint64 kFillX18) external;

    /// @notice Sets a market's per-epoch capacity. **Only timelock (48 h).**
    /// @param marketId The market.
    /// @param capBpsPerEpoch The capacity in bps of total supply, at most `CAP_BPS_PER_EPOCH_MAX`.
    function setCapBpsPerEpoch(uint16 marketId, uint16 capBpsPerEpoch) external;

    /// @notice Sets the global epoch length. **Only timelock (48 h).**
    /// @param value The new length, inside `[EPOCH_SECONDS_MIN, EPOCH_SECONDS_MAX]`.
    function setEpochSeconds(uint32 value) external;

    /// @notice Sets the global daily cap. **Only timelock (48 h).**
    /// @param value The new cap in bps, at most `DAILY_CAP_BPS_MAX`.
    function setDailyCapBps(uint16 value) external;

    /// @notice Sets the vest length for new positions. **Only timelock (48 h).** Existing positions keep the value
    ///         frozen at their purchase.
    /// @param value The new length, inside `[VEST_SECONDS_MIN, VEST_SECONDS_MAX]`.
    function setVestSeconds(uint32 value) external;

    /// @notice Sets the accretion floor. **Only timelock (48 h).**
    /// @param value The new floor in bps, at most `MIN_ACCRETION_BPS_MAX`.
    function setMinAccretionBps(uint16 value) external;

    /// @notice Replaces the pricing policy. **Only timelock (7 d).** Re-prices new bonds only.
    /// @param newPolicy The new `IBondPolicy`.
    function setPolicy(address newPolicy) external;

    /// @notice Hands the vault role on. **Only vault**, so a migration moves it atomically alongside
    ///         `Amps.setVault` in the same transaction.
    /// @param newVault The new vault.
    function setVault(address newVault) external;
}
