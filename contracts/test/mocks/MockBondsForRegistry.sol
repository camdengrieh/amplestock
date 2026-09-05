// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CollateralClass} from "../../src/types/Types.sol";

/// @title MockBondsForRegistry
/// @notice The slice of `AmpsBonds` the registry drives: `addCollateral` when a proposal opens a bond market with
///         the spoke, and `setMarketOpen` when a constituent is retired or reinstated.
/// @dev    Every call is recorded so the lifecycle drill can assert that retirement closed exactly one market and
///         that reinstatement reopened it, and both entry points can be told to revert.
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

    /// @notice When true, {addCollateral} reverts.
    bool public addReverts;

    /// @notice When true, {setMarketOpen} reverts.
    bool public setOpenReverts;

    /// @dev The mock's stand-in for any bonds-side failure.
    error BondsRefused();

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
    function setMarketOpen(uint16 marketId, bool open) external {
        if (setOpenReverts) revert BondsRefused();
        marketOpen[marketId] = open;
        _openCalls.push(OpenCall({marketId: marketId, open: open}));
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
