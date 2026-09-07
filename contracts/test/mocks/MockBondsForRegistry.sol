// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CollateralClass} from "../../src/types/Types.sol";

/// @title MockBondsForRegistry
/// @notice The slice of `AmpsBonds` the registry drives: `addCollateral` when a proposal opens a bond market with
///         the spoke, `marketIdOf` when it needs to know whether a market is still attached to its collateral,
///         and `setMarketOpen` when a constituent is retired or reinstated.
/// @dev    Every call is recorded so the lifecycle drill can assert that retirement closed exactly one market and
///         that reinstatement reopened it, and both entry points can be told to revert.
/// @dev    {removeCollateral} and the refusal it arms mirror `AmpsBonds` exactly, because the interaction between
///         them and the registry is the whole point: the real `setMarketOpen(id, true)` reverts `UnknownMarket`
///         once `marketIdOf[collateral]` no longer names the market, and it does so **forever**. A registry that
///         called it unconditionally therefore made `reinstateConstituent` permanently impossible for any
///         constituent whose collateral governance had removed. If this mock were lenient the regression would
///         pass silently, so it is not.
contract MockBondsForRegistry {
    /// @notice One recorded `addCollateral` call.
    struct AddCall {
        address collateral;
        CollateralClass class;
        uint16 dBaseBps;
        uint16 dMinBps;
        uint16 dMaxBps;
        uint16 capBpsPerEpoch;
        bool open;
        uint16 marketId;
    }

    /// @notice One recorded `setMarketOpen` call.
    struct OpenCall {
        uint16 marketId;
        bool open;
    }

    AddCall[] internal _addCalls;
    OpenCall[] internal _openCalls;

    /// @notice Market ids issued so far; the next one is `marketCount + 1`.
    uint16 public marketCount;

    /// @notice Whether the market with the given id is open, as this mock last recorded it.
    mapping(uint16 marketId => bool open) public marketOpen;

    /// @notice The market a collateral is attached to, mirroring `AmpsBonds.marketIdOf`. Zero once
    ///         {removeCollateral} has detached it, which is how the registry tells a live market from a stale id.
    mapping(address collateral => uint16 marketId) public marketIdOf;

    /// @notice The collateral each market was opened against, so {removeCollateral} can find it.
    mapping(uint16 marketId => address collateral) public collateralOf;

    /// @notice When true, {addCollateral} reverts.
    bool public addReverts;

    /// @notice When true, {setMarketOpen} reverts.
    bool public setOpenReverts;

    /// @dev The mock's stand-in for any bonds-side failure.
    error BondsRefused();

    /// @dev `AmpsBonds.setMarketOpen` reverts `UnknownMarket` in this case; the name here says why.
    error MarketDetached(uint16 marketId);

    /* ------------------------------------------ registry surface ------------------------------------------ */

    /// @notice Issues the next market id and records the parameters the registry passed.
    function addCollateral(
        address collateral,
        CollateralClass class,
        uint16 dBaseBps,
        uint16 dMinBps,
        uint16 dMaxBps,
        uint16 capBpsPerEpoch,
        bool open
    ) external returns (uint16 marketId) {
        if (addReverts) revert BondsRefused();
        marketId = ++marketCount;
        marketOpen[marketId] = open;
        marketIdOf[collateral] = marketId;
        collateralOf[marketId] = collateral;
        _addCalls.push(
            AddCall({
                collateral: collateral,
                class: class,
                dBaseBps: dBaseBps,
                dMinBps: dMinBps,
                dMaxBps: dMaxBps,
                capBpsPerEpoch: capBpsPerEpoch,
                open: open,
                marketId: marketId
            })
        );
    }

    /// @notice Records an open/close and applies it to {marketOpen}.
    /// @dev Refuses a *reopen* of a market whose collateral has been removed, exactly as `AmpsBonds` does.
    function setMarketOpen(uint16 marketId, bool open) external {
        if (setOpenReverts) revert BondsRefused();
        if (open && marketIdOf[collateralOf[marketId]] != marketId) revert MarketDetached(marketId);
        marketOpen[marketId] = open;
        _openCalls.push(OpenCall({marketId: marketId, open: open}));
    }

    /// @notice Detaches `collateral` from its market and closes it, as `AmpsBonds.removeCollateral` does.
    /// @param collateral The collateral to detach.
    function removeCollateral(address collateral) external {
        uint16 marketId = marketIdOf[collateral];
        require(marketId != 0, "no market");
        delete marketIdOf[collateral];
        marketOpen[marketId] = false;
    }

    /* --------------------------------------------- controls --------------------------------------------- */

    function setAddReverts(bool value) external {
        addReverts = value;
    }

    function setSetOpenReverts(bool value) external {
        setOpenReverts = value;
    }

    /* ---------------------------------------------- reads ----------------------------------------------- */

    function addCallCount() external view returns (uint256 count) {
        count = _addCalls.length;
    }

    function addCall(uint256 index) external view returns (AddCall memory call) {
        call = _addCalls[index];
    }

    function openCallCount() external view returns (uint256 count) {
        count = _openCalls.length;
    }

    function openCall(uint256 index) external view returns (OpenCall memory call) {
        call = _openCalls[index];
    }

    function lastOpenCall() external view returns (OpenCall memory call) {
        call = _openCalls[_openCalls.length - 1];
    }
}
