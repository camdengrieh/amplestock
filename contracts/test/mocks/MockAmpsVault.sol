// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeedRegistry} from "../../src/interfaces/IFeedRegistry.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotBonds, ZeroAddress} from "../../src/types/Errors.sol";
import {Checkpoint} from "../../src/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title MockAmpsVault
/// @notice The slice of `IAmpsVault` that `AmpsBonds` touches: the pointer set (`amps`, `timelock`, `oracleGate`,
///         `feedRegistry`, `registry`, `marketReference`), the NAV checkpoint, and the two bond-only entry points
///         `depositBonded` and `mintVesting`.
///
/// @dev Fidelity notes the bond suite depends on:
///      - {depositBonded} pulls the collateral **from the bonder**, not from `AmpsBonds`, which is what makes the
///        bonder approve the vault and what makes I12 (`sweepClean` on `AmpsBonds`) true rather than lucky. The
///        real vault forwards it into the PoolManager inside one `unlock`; here it simply rests on the mock, which
///        is indistinguishable from the bond shell's point of view.
///      - {mintVesting} mints through a real {Amps} instance whose vault is this mock, so `totalSupply` moves for
///        real and the capacity caps are measured against a real number (I30).
///      - `setAutoNav(true)` turns the mock into a NAV accountant: every deposit adds the collateral's USD value
///        (through `PriceLib` and the same feed registry the bonds shell reads) to `A`, every mint adds to `T`, and
///        the checkpoint is rewritten as `(A + 1) x 1e18 / (T + VIRTUAL_SHARES)`. That is the shape I27 is asserted
///        against: NAV/share after a bond is never below NAV/share before.
///      - `setReverting(true)` makes every function revert, which is the "vault pointer replaced by a hostile
///        contract" case that `claim` must survive.
contract MockAmpsVault {
    /// @notice The AMPS token this vault mints.
    address public amps;

    /// @notice The governance address `AmpsBonds` resolves its timelock-only setters against.
    address public timelock;

    /// @dev The pointer set. Exposed through views rather than public getters so that {reverting} makes *every*
    ///      read fail, which is what a vault pointer replaced by a hostile contract actually looks like.
    address internal _oracleGate;
    address internal _feedRegistry;
    address internal _registry;
    address internal _marketReference;

    /// @notice The bonds contract allowed to call {depositBonded} and {mintVesting}.
    address public bonds;

    /// @notice The NAV numerator `A`, 18-decimal USD. Moves on every bonded deposit while {autoNav} is set.
    uint256 public totalAssetsUsd18;

    /// @notice Whether the checkpoint is recomputed from `A` and `T` on every bond.
    bool public autoNav;

    /// @notice When true, every function reverts: the hostile-vault case.
    bool public reverting;

    /// @notice Raw units {depositBonded} quietly fails to settle, so the shell's exact-settlement check can be
    ///         exercised without a fee-on-transfer token.
    uint256 public settleShortfall;

    /// @notice How much of each collateral this mock has received through {depositBonded}.
    mapping(address collateral => uint256 amount) public bondedBalance;

    /// @notice How many times {depositBonded} has been called.
    uint256 public depositCount;

    /// @notice How many times {mintVesting} has been called.
    uint256 public mintCount;

    Checkpoint internal _checkpoint;

    /// @notice Thrown by every function while {reverting} is set.
    error VaultDown();

    /// @notice Mirrors `IAmpsVault.BondedDeposit`.
    event BondedDeposit(address indexed collateral, address indexed from, uint256 amount, uint16 constituentId);

    /// @notice Mirrors `IAmpsVault.VestingMinted`.
    event VestingMinted(address indexed to, uint256 amount);

    /// @param timelock_ The governance address.
    constructor(address timelock_) {
        timelock = timelock_;
        _checkpoint = Checkpoint({
            navPerShareX18: uint128(PriceLib.WAD),
            pRefX18: uint128(PriceLib.WAD),
            pMktX18: uint128(PriceLib.WAD),
            timestamp: uint32(block.timestamp),
            blockNumber: uint32(block.number)
        });
    }

    /* ------------------------------------- test setters ------------------------------------- */

    /// @notice Deploys nothing: the token is created by the test and handed over, because `Amps`'s vault is fixed
    ///         at construction and must be this mock.
    function setAmps(address amps_) external {
        amps = amps_;
    }

    /// @notice Sets the governance address.
    function setTimelock(address timelock_) external {
        timelock = timelock_;
    }

    /// @notice Sets the whole pointer set in one call.
    /// @param gate The oracle gate.
    /// @param feeds The feed registry.
    /// @param registry_ The pool registry.
    /// @param reference_ The market reference.
    function setPointers(address gate, address feeds, address registry_, address reference_) external {
        _oracleGate = gate;
        _feedRegistry = feeds;
        _registry = registry_;
        _marketReference = reference_;
    }

    /// @notice The oracle gate pointer `AmpsBonds` passes through to.
    /// @return gate The gate.
    function oracleGate() external view returns (address gate) {
        if (reverting) revert VaultDown();
        gate = _oracleGate;
    }

    /// @notice The feed registry pointer.
    /// @return feeds The feed registry.
    function feedRegistry() external view returns (address feeds) {
        if (reverting) revert VaultDown();
        feeds = _feedRegistry;
    }

    /// @notice The pool registry pointer.
    /// @return registry_ The registry.
    function registry() external view returns (address registry_) {
        if (reverting) revert VaultDown();
        registry_ = _registry;
    }

    /// @notice The market reference (hook stand-in) pointer.
    /// @return reference_ The market reference.
    function marketReference() external view returns (address reference_) {
        if (reverting) revert VaultDown();
        reference_ = _marketReference;
    }

    /// @notice Sets the bonds contract allowed through the bond-only entry points.
    function setBonds(address bonds_) external {
        bonds = bonds_;
    }

    /// @notice Writes the checkpoint verbatim.
    /// @param nav NAV per share, 18 decimals.
    /// @param pRef The reference price.
    /// @param pMkt The market price.
    /// @param timestamp The checkpoint timestamp, which is what the staleness bound is measured against.
    function setCheckpoint(uint128 nav, uint128 pRef, uint128 pMkt, uint32 timestamp) external {
        _checkpoint = Checkpoint({
            navPerShareX18: nav, pRefX18: pRef, pMktX18: pMkt, timestamp: timestamp, blockNumber: uint32(block.number)
        });
    }

    /// @notice Moves NAV/share alone, restamping the checkpoint at the current block.
    /// @param nav NAV per share, 18 decimals.
    function setNavPerShareX18(uint128 nav) external {
        _checkpoint.navPerShareX18 = nav;
        _checkpoint.timestamp = uint32(block.timestamp);
        _checkpoint.blockNumber = uint32(block.number);
    }

    /// @notice Restamps the checkpoint at the current block without changing any price.
    function touchCheckpoint() external {
        _checkpoint.timestamp = uint32(block.timestamp);
        _checkpoint.blockNumber = uint32(block.number);
    }

    /// @notice Sets the NAV numerator directly, for tests that seed `A` before the first bond.
    function setTotalAssetsUsd18(uint256 value) external {
        totalAssetsUsd18 = value;
    }

    /// @notice Turns real NAV accounting on: `A` grows with every bonded deposit and the checkpoint is recomputed.
    function setAutoNav(bool value) external {
        autoNav = value;
        if (value) _recomputeNav();
    }

    /// @notice Makes every function revert, or stop reverting.
    function setReverting(bool value) external {
        reverting = value;
    }

    /// @notice Makes {depositBonded} report `amount - shortfall` as settled.
    /// @param shortfall The raw units to under-report.
    function setSettleShortfall(uint256 shortfall) external {
        settleShortfall = shortfall;
    }

    /// @notice `(A + 1) x 1e18 / (T + VIRTUAL_SHARES)`, the vault's own NAV/share formula.
    /// @return value NAV per share, 18 decimals.
    function previewNavPerShareX18() public view returns (uint256 value) {
        uint256 supply = amps == address(0) ? 0 : IERC20(amps).totalSupply();
        value = FullMath.mulDiv(totalAssetsUsd18 + 1, PriceLib.WAD, supply + Constants.VIRTUAL_SHARES);
    }

    /* ---------------------------------------- IAmpsVault ---------------------------------------- */

    /// @notice The last checkpoint: what `AmpsBonds` prices against.
    /// @return snapshot The checkpoint.
    function checkpointData() external view returns (Checkpoint memory snapshot) {
        if (reverting) revert VaultDown();
        snapshot = _checkpoint;
    }

    /// @notice The checkpointed NAV per share.
    /// @return value NAV/share, 18 decimals.
    function navPerShareX18() external view returns (uint256 value) {
        if (reverting) revert VaultDown();
        value = _checkpoint.navPerShareX18;
    }

    /// @notice Pulls `amount` of `collateral` from `from`. **Only bonds.**
    /// @param marketId The bond market, for the event.
    /// @param collateral The token.
    /// @param from The bonder.
    /// @param amount The raw amount.
    /// @return settled The raw amount actually settled.
    function depositBonded(uint16 marketId, address collateral, address from, uint256 amount)
        external
        returns (uint256 settled)
    {
        if (reverting) revert VaultDown();
        if (msg.sender != bonds) revert NotBonds(msg.sender);
        if (collateral == address(0) || from == address(0)) revert ZeroAddress();

        uint256 before = IERC20(collateral).balanceOf(address(this));
        IERC20(collateral).transferFrom(from, address(this), amount);
        settled = IERC20(collateral).balanceOf(address(this)) - before;
        if (settleShortfall != 0) settled = settled > settleShortfall ? settled - settleShortfall : 0;

        bondedBalance[collateral] += settled;
        ++depositCount;

        if (autoNav) {
            totalAssetsUsd18 += _valueUsd18(collateral, settled);
            _recomputeNav();
        }

        emit BondedDeposit(collateral, from, settled, marketId);
    }

    /// @notice Mints `amount` AMPS to `to`. **Only bonds**, and `to` must be the bonds contract.
    /// @param to The recipient.
    /// @param amount The AMPS wei.
    function mintVesting(address to, uint256 amount) external {
        if (reverting) revert VaultDown();
        if (msg.sender != bonds) revert NotBonds(msg.sender);
        require(to == bonds, "mintVesting: to != bonds");

        Amps(amps).mint(to, amount);
        ++mintCount;
        if (autoNav) _recomputeNav();

        emit VestingMinted(to, amount);
    }

    /// @notice Mints AMPS outside the bond path, so a test can stand up the genesis supply the capacity caps are
    ///         measured against without running `genesis()`.
    /// @param to The recipient.
    /// @param amount The AMPS wei.
    function mintGenesis(address to, uint256 amount) external {
        Amps(amps).mint(to, amount);
        if (autoNav) _recomputeNav();
    }

    /// @notice Hands the AMPS vault role on, so migration drills can move it in one transaction.
    /// @param newVault The new vault.
    function handOverAmps(address newVault) external {
        Amps(amps).setVault(newVault);
    }

    /* ------------------------------------------ internals ------------------------------------------ */

    /// @dev The collateral's USD value at the same feed answer the bond shell priced it with, rounded down exactly
    ///      as the real NAV numerator does.
    function _valueUsd18(address collateral, uint256 amount) internal view returns (uint256 usd18) {
        if (_feedRegistry == address(0)) return 0;
        (uint256 answerUsd8,,) = IFeedRegistry(_feedRegistry).latestAnswer(collateral);
        if (answerUsd8 == 0) return 0;
        usd18 = PriceLib.counterValueUsd18(amount, IERC20Metadata(collateral).decimals(), answerUsd8);
    }

    /// @dev Rewrites the checkpoint from live `A` and `T`.
    function _recomputeNav() internal {
        _checkpoint.navPerShareX18 = uint128(previewNavPerShareX18());
        _checkpoint.timestamp = uint32(block.timestamp);
        _checkpoint.blockNumber = uint32(block.number);
    }
}
