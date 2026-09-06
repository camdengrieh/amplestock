// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Checkpoint, GateState} from "../types/Types.sol";

/// @title IAmpsVault
/// @notice The custody boundary, the NAV authority, the reference price, the redemption floor and the sole
///         `IUnlockCallback`. Immutable bytecode: every parameter below is state the timelock can move inside a
///         hard band, and nothing else about the contract can change without a migration.
///
/// @dev **NAV, exactly as implemented.**
///
///      ```
///      A = SUM_j P_j x ( ERC-6909 claim_j + idle ERC-20_j + positions_j(sqrtPrice_REF) ) - liabilities
///          over j in {constituent Stock Tokens, WETH, USDG}
///          every AMPS leg valued at ZERO (I5); the BountyPot balance is NOT in A (I21)
///      T = Amps.totalSupply()                                fully diluted; inventory counts like any share (I6)
///      navPerShareX18 = (A + 1) * 1e18 / (T + VIRTUAL_SHARES)             VIRTUAL_SHARES = 1e3 wei
///      ```
///
///      `A` is 18-decimal USD and `T` is AMPS wei, so the `1e18` is the unit conversion, not a fudge. The
///      denominator is `totalSupply` and nothing else, which is why no share-accounting reconciliation exists.
///      Positions are decomposed through a pluggable {positionValuer} at the **reference-implied** sqrt price from
///      the previous checkpoint, never at `slot0` (I7); Phase 2 ships a zero-position valuer and Phase 3 replaces
///      the pointer.
///
/// @dev **`P_mkt` and `P_ref`.**
///
///      ```
///      P_mkt = truncTWAP_30m(AMPS/USDG hub), converted to USD through PriceLib and the USDG feed
///      cap   = pRefPrev x (1 + refUpRateBps x min(elapsed, ONE_HOUR x k) / (ONE_HOUR x 10_000))
///      cand  = pMkt <= pRefPrev ? pMkt : min(pMkt, cap)          // up is rate-limited, down is immediate
///      P_ref = max(navPerShareX18, cand)                          // NAV is the floor, always (I24)
///      ```
///
///      Two fallbacks override `cand` entirely and set `P_ref = navPerShareX18`: `REF_DIVERGED` (the hub TWAP and
///      `AMPS/WETH x ETH/USD` disagree by more than `refDivergenceBps`) and `WATCHDOG` (no observation for longer
///      than `GRACE`). `premium = P_ref / navPerShare - 1` is disclosure only and is never used to issue below NAV,
///      because no path issues at NAV at all.
///
/// @dev **Issuance is closed.** `S0` is minted once by {genesis} behind a latch. After that the only mint path in
///      the bytecode is {mintVesting}, callable only by `AmpsBonds` (I10). There is no NAV mint, no
///      `mintInKind`, no `mintWithUSDG`, and the vault never mints AMPS for its own inventory or to defend a price.
///
/// @dev **`redeemProRata` is structurally ungated.** It contains no `_requireHealthy`, no guardian read, no pause
///      flag, no oracle read and no gate reference of any kind — not merely "is not paused", but *cannot be*
///      paused (I14, I23). It succeeds with every feed dead, the watchdog tripped, the guardian frozen and the
///      timelock hostile. Only chain-level censorship remains, and that is disclosed rather than mitigated.
///
/// @dev **Every other external function** takes the EIP-1153 transient reentrancy lock, follows
///      checks-effects-interactions, burns shares before any transfer out, and asserts `sweepClean` (I12) at exit.
interface IAmpsVault {
    /// @notice Arguments to {genesis}. Built by `script/06_Genesis` and executed once.
    /// @param teamVestingWallet The OZ `VestingWallet` that receives the 5% team tranche (2-month linear, no cliff).
    /// @param creator The address that receives the decaying creator fee. Only the creator may later reassign it.
    /// @param teamShares AMPS wei to the vesting wallet. Must equal `Constants.TEAM_SHARES`.
    /// @param polShares AMPS wei retained by the vault as POL inventory. Must equal `Constants.POL_SHARES`.
    /// @param seedTokens The founders' seed assets, pulled from `msg.sender`: WETH9 and USDG.
    /// @param seedAmounts The seed amounts, parallel to `seedTokens`.
    struct GenesisParams {
        address teamVestingWallet;
        address creator;
        uint256 teamShares;
        uint256 polShares;
        address[] seedTokens;
        uint256[] seedAmounts;
    }

    /// @notice Emitted once, by {genesis}.
    /// @param teamVestingWallet The team's vesting wallet.
    /// @param creator The creator address.
    /// @param totalMinted `S0`.
    /// @param navPerShareX18 NAV/share immediately after genesis. $1.00 by construction.
    event Genesis(
        address indexed teamVestingWallet, address indexed creator, uint256 totalMinted, uint256 navPerShareX18
    );

    /// @notice Emitted on every NAV recomputation.
    /// @param navPerShareX18 The new NAV per share.
    /// @param totalAssetsUsd18 `A`.
    /// @param totalSupply `T`.
    event NavCheckpoint(uint256 navPerShareX18, uint256 totalAssetsUsd18, uint256 totalSupply);

    /// @notice Emitted on every reference recomputation, including ones where the rate limit or a fallback bound it.
    /// @param pRefX18 The new reference price.
    /// @param pMktX18 The market price it was derived from.
    /// @param rateLimited Whether the upward rate limit bound the move.
    /// @param navFloored Whether the NAV floor bound the result.
    event RefCheckpoint(uint256 pRefX18, uint256 pMktX18, bool rateLimited, bool navFloored);

    /// @notice Emitted on every redemption.
    /// @param owner The redeemer.
    /// @param to The recipient.
    /// @param shares AMPS wei burned from the redeemer.
    /// @param inventoryBurned Additional AMPS wei burned because it was released from the vault's own inventory,
    ///        which is why `totalSupply` falls by more than `shares` and the redemption is accretive.
    /// @param feeBps The redemption fee applied.
    event Redeem(address indexed owner, address indexed to, uint256 shares, uint256 inventoryBurned, uint16 feeBps);

    /// @notice Emitted when `AmpsBonds` settles a bonded deposit into an ERC-6909 claim.
    /// @param collateral The deposited token.
    /// @param from The bonder the collateral came from.
    /// @param amount The raw amount settled.
    /// @param constituentId The constituent whose spoke will receive it, or 0 for `ENTRY`.
    event BondedDeposit(address indexed collateral, address indexed from, uint256 amount, uint16 constituentId);

    /// @notice Emitted when `AmpsBonds` mints vesting AMPS.
    /// @param to Always the `AmpsBonds` address.
    /// @param amount The AMPS wei minted.
    event VestingMinted(address indexed to, uint256 amount);

    /// @notice Emitted on every AMPS burn the vault performs, whatever the cause.
    /// @param amount The AMPS wei burned.
    /// @param reason A short identifier: `bytes32("redeemInventory")`, `bytes32("compoundBurn")`,
    ///        `bytes32("buybackBurn")`.
    event Burn(uint256 amount, bytes32 reason);

    /// @notice Emitted on every ladder placement. **Phase 3.**
    /// @param poolId The pool.
    /// @param above True for an ask ladder, false for a bid ladder.
    /// @param buckets The bucket count placed.
    /// @param amount The token amount committed.
    /// @param anchorTick The anchor the ladder was measured from.
    event Placement(PoolId indexed poolId, bool above, uint8 buckets, uint256 amount, int24 anchorTick);

    /// @notice Emitted on every `compound()`. **Phase 3.**
    /// @param poolId The pool.
    /// @param ampsFees AMPS-side fees collected.
    /// @param creatorPaid AMPS paid to the creator.
    /// @param stakerPaid AMPS streamed to xAMPS.
    /// @param burned AMPS burned, buyback burn included.
    /// @param relaid AMPS re-placed as asks above the market.
    event Compound(
        PoolId indexed poolId, uint256 ampsFees, uint256 creatorPaid, uint256 stakerPaid, uint256 burned, uint256 relaid
    );

    /// @notice Emitted whenever the vault's view of a pool's gate state changes.
    /// @param poolId The pool.
    /// @param previousState The state before.
    /// @param newState The state after.
    event GateChanged(PoolId indexed poolId, GateState previousState, GateState newState);

    /// @notice Emitted on every governed parameter change.
    /// @param parameter The parameter name as a short string.
    /// @param previousValue The value before.
    /// @param newValue The value after.
    event VaultParameterChanged(bytes32 indexed parameter, uint256 previousValue, uint256 newValue);

    /// @notice Emitted when a pointer-upgradeable policy is replaced.
    /// @param slot The pointer name as a short string: `bytes32("ladderPolicy")`, `bytes32("feePolicy")`,
    ///        `bytes32("rolloutPolicy")`, `bytes32("oracleGate")`, `bytes32("feedRegistry")`,
    ///        `bytes32("positionValuer")`.
    /// @param previousPointer The old address.
    /// @param newPointer The new address.
    event PolicyPointerChanged(bytes32 indexed slot, address indexed previousPointer, address indexed newPointer);

    /// @notice Emitted when a standby vault is registered. 14-day timelock.
    /// @param standby The pre-registered standby vault.
    event StandbyVaultRegistered(address indexed standby);

    /// @notice Emitted when `emergencyMigrate` completes.
    /// @param newVault The vault that now owns everything.
    /// @param navPerShareBefore NAV/share before the migration.
    /// @param navPerShareAfter NAV/share after it.
    event Migrated(address indexed newVault, uint256 navPerShareBefore, uint256 navPerShareAfter);

    /// @notice Emitted when the creator address is reassigned. Only the current creator may do this.
    /// @param previousCreator The old address.
    /// @param newCreator The new address.
    event CreatorChanged(address indexed previousCreator, address indexed newCreator);

    /// @notice {genesis} has already run. The latch is one-way and there is no reset.
    error GenesisAlreadyDone();

    /// @notice The genesis allocation does not sum to `S0`, or a tranche does not match its constant.
    /// @param teamShares The proposed team tranche.
    /// @param polShares The proposed POL tranche.
    /// @param expectedTotal `Constants.S0`.
    error InvalidGenesisAllocation(uint256 teamShares, uint256 polShares, uint256 expectedTotal);

    /// @notice The migration predicate is not satisfied: no constituent reports `isBlocked(vault) == true` and
    ///         fewer than two 1-wei self-transfer probes fail.
    error MigrationPredicateNotMet();

    /// @notice The target is not the pre-registered standby vault.
    /// @param proposed The rejected address.
    /// @param standby The registered standby.
    error NotStandbyVault(address proposed, address standby);

    /// @notice A Phase 3 entry point was called. {place}, {compound}, {rollout}, {deployBonded} and
    ///         {withdrawRetiredBids} are part of the final ABI — the bytecode is immutable, so they have to be —
    ///         but have no implementation until `AmpsHook` and the ladder machinery exist. Each still performs its
    ///         caller and gate checks first, so the guard-symmetry enumeration sees the same refusal every other
    ///         mutating selector gives.
    error Phase3NotImplemented();

    /// @notice `unlockCallback` was entered without the vault having set an action discriminator, i.e. the unlock
    ///         did not originate here.
    error UnknownUnlockAction();

    /// @notice A pointer name handed to {setPolicyPointer} is not one of the vault's pointer slots.
    /// @param slot The rejected slot name.
    error UnknownPointerSlot(bytes32 slot);

    /// @notice A value that must fit a packed `uint128` checkpoint field did not.
    /// @param value The offending value.
    error ValueTooLarge(uint256 value);

    // -------------------------------------------------------------------------------------------------------------
    // Reads — wiring
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The AMPS token.
    /// @return ampsAddress The token address.
    function amps() external view returns (address ampsAddress);

    /// @notice The Uniswap v4 PoolManager. Reached only through the MIT `IPoolManager` interface, and its state
    ///         read only through `IExtsload`/`IExttload` with our own slot arithmetic: `StateLibrary` and
    ///         `TransientStateLibrary` reach BUSL-1.1 files and are confined to `test/` and `script/`.
    /// @return poolManagerAddress The PoolManager address.
    function poolManager() external view returns (address poolManagerAddress);

    /// @notice The pool registry.
    /// @return registryAddress The registry address.
    function registry() external view returns (address registryAddress);

    /// @notice The bonds shell: the only address that may call {depositBonded} and {mintVesting}.
    /// @return bondsAddress The bonds address.
    function bonds() external view returns (address bondsAddress);

    /// @notice The xAMPS staking vault.
    /// @return stakingAddress The staking address.
    function staking() external view returns (address stakingAddress);

    /// @notice The keeper bounty pot. Its balance is excluded from `A` (I21).
    /// @return bountyPotAddress The pot address.
    function bountyPot() external view returns (address bountyPotAddress);

    /// @notice The market reference: `AmpsHook` in production, a mock in Phase 2.
    /// @return marketReferenceAddress The `IMarketReference` address.
    function marketReference() external view returns (address marketReferenceAddress);

    /// @notice The oracle gate pointer.
    /// @return gateAddress The `IOracleGate` address.
    function oracleGate() external view returns (address gateAddress);

    /// @notice The feed registry pointer.
    /// @return feedRegistryAddress The `IFeedRegistry` address.
    function feedRegistry() external view returns (address feedRegistryAddress);

    /// @notice The position valuer pointer. A zero-position valuer in Phase 2.
    /// @return positionValuerAddress The `IPositionValuer` address.
    function positionValuer() external view returns (address positionValuerAddress);

    /// @notice The ladder policy pointer. **Phase 3.**
    /// @return ladderPolicyAddress The `ILadderPolicy` address.
    function ladderPolicy() external view returns (address ladderPolicyAddress);

    /// @notice The rollout policy pointer. **Phase 3.**
    /// @return rolloutPolicyAddress The `IRolloutPolicy` address.
    function rolloutPolicy() external view returns (address rolloutPolicyAddress);

    /// @notice The governance timelock: the only address that may call a `set*` function.
    /// @return timelockAddress The timelock address.
    function timelock() external view returns (address timelockAddress);

    /// @notice The guardian Safe: disable-only freezes and the predicate-gated migration trigger.
    /// @return guardianAddress The guardian address.
    function guardian() external view returns (address guardianAddress);

    /// @notice The creator fee recipient.
    /// @return creatorAddress The creator address.
    function creator() external view returns (address creatorAddress);

    /// @notice The pre-registered standby vault, or `address(0)`.
    /// @return standbyAddress The standby vault.
    function standbyVault() external view returns (address standbyAddress);

    // -------------------------------------------------------------------------------------------------------------
    // Reads — NAV, reference and inventory
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The last checkpoint: NAV/share, `P_ref`, `P_mkt`, timestamp and block. What the hook, `AmpsBonds`
    ///         and `AmpsQuoter` read.
    /// @return snapshot The checkpoint.
    function checkpointData() external view returns (Checkpoint memory snapshot);

    /// @notice The checkpointed NAV per share, USD per AMPS, 18 decimals.
    /// @return value NAV/share.
    function navPerShareX18() external view returns (uint256 value);

    /// @notice The checkpointed reference price, USD per AMPS, 18 decimals. Never below NAV/share (I24).
    /// @return value `P_ref`.
    function pRefX18() external view returns (uint256 value);

    /// @notice The checkpointed market price, USD per AMPS, 18 decimals.
    /// @return value `P_mkt`.
    function pMktX18() external view returns (uint256 value);

    /// @notice `P_ref / navPerShare - 1`, 18 decimals. Disclosure only: no path uses it to issue.
    /// @return value The premium.
    function premiumX18() external view returns (uint256 value);

    /// @notice The NAV numerator `A`, recomputed live rather than read from the checkpoint.
    /// @return value `A`, 18-decimal USD.
    function totalAssetsUsd18() external view returns (uint256 value);

    /// @notice NAV/share recomputed live. The checkpoint is what other contracts read; this is what the dApp and
    ///         the invariant suite compare it against.
    /// @return value NAV/share, 18 decimals.
    function previewNavPerShareX18() external view returns (uint256 value);

    /// @notice Protocol-held AMPS: `Amps.balanceOf(vault)` plus the vault's ERC-6909 AMPS claims plus AMPS inside
    ///         its positions. **Disclosure only** — it is never subtracted from the NAV denominator (I6), and it
    ///         excludes the AMPS `AmpsBonds` holds for vesting (I30).
    /// @return amount The inventory, in AMPS wei.
    function inventoryAmps() external view returns (uint256 amount);

    /// @notice What {redeemProRata} would pay for `shares` right now.
    /// @dev Reads balances only — no oracle, no gate, no price. Never reverts for a live vault.
    /// @param shares AMPS wei to redeem.
    /// @return tokens The assets that would be paid.
    /// @return amounts The raw amounts, parallel to `tokens`, net of `redeemFeeBps`.
    /// @return inventoryBurned Additional AMPS wei that would be burned from released inventory.
    function previewRedeem(uint256 shares)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts, uint256 inventoryBurned);

    /// @notice The creator fee in force at `timestamp`, in bps of sell volume.
    /// @dev `creatorBps(t) = 100 bp x max(0, 1 - (t - genesis) / 30 days)`, monotone non-increasing and exactly
    ///      zero from `genesis + 30 days` (I31). The schedule is immutable: no setter exists.
    /// @param timestamp The time to evaluate at.
    /// @return bps The creator fee.
    function creatorBpsAt(uint256 timestamp) external view returns (uint16 bps);

    /// @notice When {genesis} ran. Zero before it.
    /// @return timestamp The genesis timestamp.
    function genesisTimestamp() external view returns (uint32 timestamp);

    /// @notice Whether {genesis} has run.
    /// @return done The latch.
    function initialized() external view returns (bool done);

    // -------------------------------------------------------------------------------------------------------------
    // Reads — governed parameters
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The redemption fee, in bps. 100 at launch.
    /// @return value The parameter.
    function redeemFeeBps() external view returns (uint16 value);

    /// @notice Share of AMPS-side fees burned at `compound()`, after the creator and staker slices. 1,000 at launch.
    /// @return value The parameter.
    function burnBps() external view returns (uint16 value);

    /// @notice Share of AMPS-side fees streamed to xAMPS. 3,000 at launch.
    /// @return value The parameter.
    function stakerBps() external view returns (uint16 value);

    /// @notice Maximum upward move of `P_ref` per hour, in bps. 1,000 at launch.
    /// @return value The parameter.
    function refUpRateBps() external view returns (uint16 value);

    /// @notice Maximum disagreement between the hub TWAP and `AMPS/WETH x ETH/USD` before `REF_DIVERGED`, in bps.
    ///         500 at launch.
    /// @return value The parameter.
    function refDivergenceBps() external view returns (uint16 value);

    /// @notice The TWAP window the vault reads `P_mkt` over. 1,800 s at launch.
    /// @return value The parameter.
    function twapWindow() external view returns (uint32 value);

    /// @notice The ladder tilt applied to future placements. 1.25e18 at launch. **Phase 3.**
    /// @return value The parameter.
    function ladderTiltX18() external view returns (uint64 value);

    /// @notice The ask ladder's bucket count for future placements. 10 at launch. **Phase 3.**
    /// @return value The parameter.
    function ladderDoublings() external view returns (uint8 value);

    /// @notice The seed bid ladder's bucket count. 4 at launch. **Phase 3.**
    /// @return value The parameter.
    function seedHalvings() external view returns (uint8 value);

    /// @notice The bonded-stock bid ladder's bucket count. 4 at launch. **Phase 3.**
    /// @return value The parameter.
    function bondBidHalvings() external view returns (uint8 value);

    /// @notice The seed ask a newly registered spoke receives, in bps of the entry-pool inventory. 100 at launch.
    ///         **Phase 3.**
    /// @return value The parameter.
    function spokeSeedBps() external view returns (uint16 value);

    /// @notice The daily rollout budget, in bps of the POL tranche. 200 at launch. **Phase 3.**
    /// @return value The parameter.
    function rolloutBpsPerDay() external view returns (uint16 value);

    /// @notice The entry-pool inventory floor, in bps of the POL tranche. 3,000 at launch. **Phase 3.**
    /// @return value The parameter.
    function entryFloorBps() external view returns (uint16 value);

    // -------------------------------------------------------------------------------------------------------------
    // Reads — hard bands
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `S0`: the entire genesis supply. 5,000e18. Not governable.
    /// @return value The constant.
    function S0() external view returns (uint256 value);

    /// @notice The NAV denominator's divide-by-zero guard. 1e3 wei.
    /// @return value The constant.
    function VIRTUAL_SHARES() external view returns (uint256 value);

    /// @notice Hard ceiling of `redeemFeeBps`. 500.
    /// @return value The bound.
    function REDEEM_FEE_BPS_MAX() external view returns (uint16 value);

    /// @notice Hard ceiling of `burnBps`. 2,500.
    /// @return value The bound.
    function BURN_BPS_MAX() external view returns (uint16 value);

    /// @notice Hard ceiling of `stakerBps`. 5,000.
    /// @return value The bound.
    function STAKER_BPS_MAX() external view returns (uint16 value);

    /// @notice Hard floor of `refUpRateBps`. 100.
    /// @return value The bound.
    function REF_UP_RATE_BPS_MIN() external view returns (uint16 value);

    /// @notice Hard ceiling of `refUpRateBps`. 5,000.
    /// @return value The bound.
    function REF_UP_RATE_BPS_MAX() external view returns (uint16 value);

    /// @notice Hard floor of `refDivergenceBps`. 100.
    /// @return value The bound.
    function REF_DIVERGENCE_BPS_MIN() external view returns (uint16 value);

    /// @notice Hard ceiling of `refDivergenceBps`. 2,000.
    /// @return value The bound.
    function REF_DIVERGENCE_BPS_MAX() external view returns (uint16 value);

    /// @notice Hard floor of `twapWindow`. 300 s.
    /// @return value The bound.
    function TWAP_WINDOW_MIN() external view returns (uint32 value);

    /// @notice Hard ceiling of `twapWindow`. 7,200 s.
    /// @return value The bound.
    function TWAP_WINDOW_MAX() external view returns (uint32 value);

    /// @notice Hard floor of `ladderTiltX18`. 1e18.
    /// @return value The bound.
    function LADDER_TILT_X18_MIN() external view returns (uint64 value);

    /// @notice Hard ceiling of `ladderTiltX18`. 1.5e18.
    /// @return value The bound.
    function LADDER_TILT_X18_MAX() external view returns (uint64 value);

    /// @notice Hard floor of `ladderDoublings`. 6.
    /// @return value The bound.
    function LADDER_DOUBLINGS_MIN() external view returns (uint8 value);

    /// @notice Hard ceiling of `ladderDoublings`. 14.
    /// @return value The bound.
    function LADDER_DOUBLINGS_MAX() external view returns (uint8 value);

    /// @notice Hard floor of `seedHalvings` and `bondBidHalvings`. 2.
    /// @return value The bound.
    function HALVINGS_MIN() external view returns (uint8 value);

    /// @notice Hard ceiling of `seedHalvings` and `bondBidHalvings`. 8.
    /// @return value The bound.
    function HALVINGS_MAX() external view returns (uint8 value);

    /// @notice Hard ceiling of `rolloutBpsPerDay`. 1,000.
    /// @return value The bound.
    function ROLLOUT_BPS_PER_DAY_MAX() external view returns (uint16 value);

    /// @notice Hard ceiling of `entryFloorBps`. 8,000.
    /// @return value The bound.
    function ENTRY_FLOOR_BPS_MAX() external view returns (uint16 value);

    /// @notice Hard floor of `spokeSeedBps`. 10.
    /// @return value The bound.
    function SPOKE_SEED_BPS_MIN() external view returns (uint16 value);

    /// @notice Hard ceiling of `spokeSeedBps`. 1,000.
    /// @return value The bound.
    function SPOKE_SEED_BPS_MAX() external view returns (uint16 value);

    /// @notice The R1 bound: a placement may not lower NAV/share by more than this. 2 bp (I11).
    /// @return value The bound.
    function PLACEMENT_BLEED_BPS_MAX() external view returns (uint16 value);

    /// @notice The relaxed R1 bound inside `emergencyMigrate`. 50 bp.
    /// @return value The bound.
    function MIGRATION_BLEED_BPS_MAX() external view returns (uint16 value);

    /// @notice The immutable creator fee at genesis, in bps of sell volume. 100.
    /// @return value The constant.
    function CREATOR_FEE_BPS() external view returns (uint16 value);

    /// @notice The immutable creator decay window. 30 days.
    /// @return value The constant.
    function CREATOR_DECAY_SECONDS() external view returns (uint32 value);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — the ungated floor
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Burns `shares` and pays the caller their pro-rata slice of every non-AMPS asset the vault holds,
    ///         less `redeemFeeBps`. **Structurally ungated and permissionless.**
    ///
    /// @dev The exact procedure, in order (I23):
    ///        1. burn `shares` from `msg.sender` **first**;
    ///        2. remove exactly `floor(L_p x shares / T)` liquidity from every position (Phase 3; no positions
    ///           exist in Phase 2);
    ///        3. pay `floor(b x shares / T) x (1 - redeemFeeBps / 10_000)` of every non-AMPS idle balance, ERC-6909
    ///           claim and released position amount;
    ///        4. burn the AMPS released from the vault's own inventory in step 2, so `T` falls by **more** than
    ///           `shares` and the redemption is accretive to everyone who did not redeem;
    ///        5. the withheld fee stays in the vault as backing.
    ///
    /// @dev No netting, no substitution, no oracle read, no gate read, no reentrancy on a hostile Stock Token
    ///      (shares are burned before any transfer out, and the transient lock is still taken — the lock is not a
    ///      gate and cannot be held by anyone else).
    ///      `T` is read once, before the burn, so a redemption cannot inflate its own share.
    ///      There is no `minAmountsOut` parameter, because any minimum would need a price and this path reads none;
    ///      the payout is a deterministic function of balances that other redemptions can only increase.
    ///
    /// @param shares AMPS wei to redeem.
    /// @param to The recipient of every asset paid.
    /// @return tokens The assets paid.
    /// @return amounts The raw amounts, parallel to `tokens`.
    function redeemProRata(uint256 shares, address to)
        external
        returns (address[] memory tokens, uint256[] memory amounts);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — permissionless upkeep
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Recomputes `A`, NAV/share, `P_mkt` and `P_ref` and writes the checkpoint. **Permissionless and
    ///         unpaid** — no bounty, by design, so it can never be griefed for profit and never depends on the pot.
    /// @return snapshot The checkpoint written.
    function checkpoint() external returns (Checkpoint memory snapshot);

    /// @notice Stamps the layer-A watchdog without recomputing NAV. **Permissionless and unpaid.**
    function touch() external;

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — bonds
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Pulls `amount` of `collateral` from `from` straight into the PoolManager and settles it into an
    ///         ERC-6909 claim. **Only AmpsBonds.**
    /// @dev The collateral never rests on `AmpsBonds` or on the vault: the transfer is
    ///      `from -> PoolManager` inside one `unlock`, so the `sweepClean` invariant (I12) holds at function exit
    ///      for both contracts. The bonder therefore approves the **vault**.
    /// @dev Writes a fresh {checkpointData} **before** settling, under the bond gate policy. `AmpsBonds` calls
    ///      this first and prices afterwards, so every bond is priced against this block's pre-deposit NAV rather
    ///      than a checkpoint up to `CHECKPOINT_MAX_AGE` old that an earlier bond, a redemption or a feed move may
    ///      have left below the live value (the vault half of I27).
    /// @param marketId The bond market, for the event and for routing the proceeds.
    /// @param collateral The token.
    /// @param from The bonder.
    /// @param amount The raw amount.
    /// @return settled The raw amount actually settled.
    function depositBonded(uint16 marketId, address collateral, address from, uint256 amount)
        external
        returns (uint256 settled);

    /// @notice Mints `amount` AMPS to `to`. **Only AmpsBonds**, and `to` must be `AmpsBonds` itself.
    /// @dev The only mint path in the bytecode after the genesis latch closes (I10). The AMPS enters `totalSupply`
    ///      immediately, so NAV/share reflects the issuance at purchase and cannot be gamed by claim timing (I30).
    /// @param to The recipient. Must equal {bonds}.
    /// @param amount The AMPS wei to mint.
    function mintVesting(address to, uint256 amount) external;

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — genesis and placement
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Mints `S0`, allocates the team and POL tranches, pulls the founders' seed and sets the creator.
    ///         **Only timelock**, once, behind a one-way latch.
    /// @param params The genesis arguments.
    function genesis(GenesisParams calldata params) external;

    /// @notice Initialises a registered pool through the PoolManager. **Only registry**, from within
    ///         `addConstituent` (or `registerEntryPool`).
    /// @dev The hook's `beforeInitialize` requires `sender == vault`, so pool creation has to come through here;
    ///      the registry has already checked membership, the dynamic-fee flag and `currency0 == AMPS`. No
    ///      liquidity is placed by this call: the seed ask arrives with the next rollout (Phase 3).
    /// @param key The pool key.
    /// @param sqrtPriceX96 The initial price, `PriceLib.ampsPerCounterToSqrtPriceX96(P_ref, P_counter, decimals)`.
    /// @return poolId The initialised pool.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external returns (PoolId poolId);

    /// @notice Places a ladder into a pool. **Only timelock or a permissionless keeper path, per placement kind.**
    ///         **Phase 3.**
    /// @dev Every placement passes the same gauntlet: gate green (or `REF_DIVERGED` with a NAV anchor);
    ///      `|slot0.tick - tickOf(P_mkt / P_i)| <= PLACEMENT_DIVERGENCE_TICKS` at entry *and* exit; the R1
    ///      post-condition `navPerShareAfter >= navPerShareBefore x (1 - 2 bp)` as a revert; and a 60-second
    ///      per-pool cooldown. Asks are AMPS-only above the tick, bids counter-only below (I9).
    /// @param poolId The pool.
    /// @param above True for an ask ladder.
    /// @param amount The token amount to place.
    /// @return placed The amount actually committed.
    function place(PoolId poolId, bool above, uint256 amount) external returns (uint256 placed);

    /// @notice Collects a pool's fees and applies the creator -> staker -> burn -> re-ladder split, then performs
    ///         the high-water buyback burn and resets the mark. **Permissionless**, paid from `BountyPot`.
    ///         **Phase 3.**
    /// @param poolId The pool.
    /// @return ampsFees AMPS-side fees collected.
    /// @return burned AMPS burned, buyback burn included.
    function compound(PoolId poolId) external returns (uint256 ampsFees, uint256 burned);

    /// @notice Moves unfilled ask inventory from the entry pools into one spoke, inside `rolloutBpsPerDay` and
    ///         above `entryFloorBps`. **Permissionless**, paid from `BountyPot`. **Phase 3.**
    /// @param constituentId The destination constituent.
    /// @return moved AMPS wei moved.
    function rollout(uint16 constituentId) external returns (uint256 moved);

    /// @notice Places idle bonded collateral as the spoke's bid ladder. **Permissionless**, paid from
    ///         `BountyPot`. **Phase 3.**
    /// @param constituentId The constituent.
    /// @return placed The raw amount placed.
    function deployBonded(uint16 constituentId) external returns (uint256 placed);

    /// @notice Moves a retired constituent's unfilled bid inventory out of its pool and into idle claims, where it
    ///         is valued in `A` and paid out by redemption. **Only registry**, from
    ///         `PoolRegistry.withdrawRetiredBids` under the 7-day timelock. **Phase 3.**
    /// @dev Bids are ladder positions and no ladder exists in Phase 2, so this reverts with {Phase3NotImplemented}
    ///      after the caller and gate checks. It is declared now because the vault's bytecode is immutable and the
    ///      registry's retirement path has to be written against the final ABI: the registry is the sole caller,
    ///      and it records whatever amount this reports as moved.
    /// @param constituentId The retired constituent.
    /// @return amountMoved The counter-asset amount moved into claims, in raw units.
    function withdrawRetiredBids(uint16 constituentId) external returns (uint256 amountMoved);

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — governance
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Sets the redemption fee. **Only timelock (48 h).** No governance path can raise it above
    ///         `REDEEM_FEE_BPS_MAX` or block redemption altogether.
    /// @param value The new fee, at most `REDEEM_FEE_BPS_MAX`.
    function setRedeemFeeBps(uint16 value) external;

    /// @notice Sets the burn share. **Only timelock (48 h).**
    /// @param value The new share, at most `BURN_BPS_MAX`.
    function setBurnBps(uint16 value) external;

    /// @notice Sets the staker share. **Only timelock (48 h).**
    /// @param value The new share, at most `STAKER_BPS_MAX`.
    function setStakerBps(uint16 value) external;

    /// @notice Sets the reference rate limit. **Only timelock (48 h).**
    /// @param value The new rate, inside `[REF_UP_RATE_BPS_MIN, REF_UP_RATE_BPS_MAX]`.
    function setRefUpRateBps(uint16 value) external;

    /// @notice Sets the reference divergence threshold. **Only timelock (48 h).**
    /// @param value The new threshold, inside `[REF_DIVERGENCE_BPS_MIN, REF_DIVERGENCE_BPS_MAX]`.
    function setRefDivergenceBps(uint16 value) external;

    /// @notice Sets the TWAP window. **Only timelock (48 h).**
    /// @param value The new window, inside `[TWAP_WINDOW_MIN, TWAP_WINDOW_MAX]`.
    function setTwapWindow(uint32 value) external;

    /// @notice Sets the ladder shape for future placements. **Only timelock (48 h).** Existing positions are never
    ///         re-shaped. **Phase 3.**
    /// @param tiltX18 The new tilt, inside `[LADDER_TILT_X18_MIN, LADDER_TILT_X18_MAX]`.
    /// @param doublings The new ask bucket count, inside `[LADDER_DOUBLINGS_MIN, LADDER_DOUBLINGS_MAX]`.
    /// @param seedHalvings_ The new seed bid bucket count, inside `[HALVINGS_MIN, HALVINGS_MAX]`.
    /// @param bondBidHalvings_ The new bonded bid bucket count, inside the same band.
    function setLadderShape(uint64 tiltX18, uint8 doublings, uint8 seedHalvings_, uint8 bondBidHalvings_) external;

    /// @notice Sets the rollout rate and the entry-pool floor. **Only timelock (48 h).** **Phase 3.**
    /// @param bpsPerDay The new daily rate, at most `ROLLOUT_BPS_PER_DAY_MAX`.
    /// @param floorBps The new entry floor, at most `ENTRY_FLOOR_BPS_MAX`.
    function setRolloutParams(uint16 bpsPerDay, uint16 floorBps) external;

    /// @notice Sets the seed ask a new spoke receives. **Only timelock (48 h).** **Phase 3.**
    /// @param value The new value, inside `[SPOKE_SEED_BPS_MIN, SPOKE_SEED_BPS_MAX]`.
    function setSpokeSeedBps(uint16 value) external;

    /// @notice Replaces a pointer-upgradeable policy **and carries the set-once protocol wiring**. **Only timelock
    ///         (7 d).** None of these can move a fund.
    ///
    /// @dev This is the vault's single pointer setter, and it serves two populations of slot:
    ///
    ///        - **Set-once wiring**, written before {genesis} and refused for ever afterwards: `bytes32("registry")`,
    ///          `bytes32("bonds")`, `bytes32("staking")` and `bytes32("bountyPot")`. Each of those contracts takes
    ///          the vault in *its* constructor, so the vault cannot hold them as immutables; {genesis} sets the
    ///          `wiringFrozen` latch and a later write reverts with `AlreadyInitialized`.
    ///        - **Pointer-upgradeable policies**, replaceable at any time under the same 7-day delay:
    ///          `bytes32("oracleGate")`, `bytes32("feedRegistry")`, `bytes32("positionValuer")`,
    ///          `bytes32("ladderPolicy")` and `bytes32("rolloutPolicy")`. `bytes32("marketReference")` sits between
    ///          the two: set-once before genesis to the Phase 2 mock, and re-pointed to `AmpsHook` afterwards.
    ///
    ///      Any other slot name reverts with {UnknownPointerSlot}, and `address(0)` is refused for every slot.
    ///
    /// @param slot The pointer name as a short string.
    /// @param newPointer The new address.
    function setPolicyPointer(bytes32 slot, address newPointer) external;

    /// @notice Pre-registers the standby vault an emergency migration may target. **Only timelock (14 d).**
    /// @param standby The standby vault.
    function setStandbyVault(address standby) external;

    /// @notice Reassigns the creator fee recipient. **Only the current creator.** Governance cannot change it, and
    ///         the decay schedule is immutable either way.
    /// @param newCreator The new recipient.
    function setCreator(address newCreator) external;

    // -------------------------------------------------------------------------------------------------------------
    // Mutative — emergency
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Migrates every position and every claim to the pre-registered standby vault, and hands the vault
    ///         role on `Amps` and `AmpsBonds` in the same transaction. **Only guardian, no delay, predicate-gated.**
    ///
    /// @dev The predicate is checked **on-chain**: `isBlocked(vault) == true` for at least one constituent, or a
    ///      bounded 1-wei self-transfer probe failing for at least two constituents. Without it the call reverts
    ///      with {MigrationPredicateNotMet}; the guardian cannot migrate at will.
    ///
    /// @dev Per pool, inside one `unlock`: remove liquidity -> `take` as ERC-6909 claims -> transfer the claims
    ///      PoolManager-internally to the standby vault -> the standby vault re-adds at the same ticks. The R1
    ///      bleed cap is relaxed to `MIGRATION_BLEED_BPS_MAX` (50 bp) only inside this call.
    ///
    /// @param standby The standby vault. Must equal {standbyVault}.
    function emergencyMigrate(address standby) external;
}
