// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsBonds} from "../interfaces/IAmpsBonds.sol";
import {BondMarket, VestingPosition} from "../types/Types.sol";

/// @title AmpsBondsLens
/// @notice The read-only half of the bond surface: position enumeration and the whole market board in one call.
///
/// @dev **Stateless and disposable.** It holds no storage, has no privileges and takes the `AmpsBonds` instance as
///      an argument, so it can be redeployed at any time without touching the immutable shell. Everything here is
///      derived from `IAmpsBonds`'s own views; nothing in this file can move a token or change a number.
///
/// @dev **Why it is a separate contract.** `AmpsBonds` must fit inside EIP-170 with room for the whole bond call
///      graph, the collateral registry and twelve governed setters. Views that only *aggregate* what the interface
///      already exposes — enumerating a bonder's positions, quoting every market at once — earn no place in that
///      budget, and a caller that wants them can batch this contract into the same `eth_call` multicall.
contract AmpsBondsLens {
    /// @notice One market's live state and a quote for a hypothetical deposit.
    /// @param marketId The market.
    /// @param record The market record.
    /// @param ampsOut The AMPS wei `amountIn` would buy, after the capacity clamp.
    /// @param qX18 The applied price.
    /// @param discountBps The discount applied.
    /// @param floorBinding Whether the accretion floor set the price.
    /// @param capacityLeft AMPS wei still issuable by this market.
    /// @param reason `bytes32(0)` when the bond would succeed, otherwise why it would not.
    struct MarketQuote {
        uint16 marketId;
        BondMarket record;
        uint256 ampsOut;
        uint256 qX18;
        uint16 discountBps;
        bool floorBinding;
        uint256 capacityLeft;
        bytes32 reason;
    }

    /// @notice Every position `owner` holds, in id order.
    /// @param bonds The `AmpsBonds` instance.
    /// @param owner The bonder.
    /// @return records The positions.
    function positionsOf(IAmpsBonds bonds, address owner) external view returns (VestingPosition[] memory records) {
        uint256 count = bonds.positionCount(owner);
        records = new VestingPosition[](count);
        for (uint256 i; i < count; ++i) {
            records[i] = bonds.position(owner, i);
        }
    }

    /// @notice AMPS wei of a position that has vested so far, claimed or not.
    /// @dev `claimable == vestedOf - position.claimed`. Monotone non-decreasing in time and never above the
    ///      principal (I28).
    /// @param bonds The `AmpsBonds` instance.
    /// @param owner The bonder.
    /// @param positionId The index.
    /// @return amount The vested AMPS.
    function vestedOf(IAmpsBonds bonds, address owner, uint256 positionId) external view returns (uint256 amount) {
        amount = bonds.claimable(owner, positionId) + bonds.position(owner, positionId).claimed;
    }

    /// @notice What every position `owner` holds would pay out if the whole vest completed.
    /// @param bonds The `AmpsBonds` instance.
    /// @param owner The bonder.
    /// @return principal Total AMPS purchased across every position.
    /// @return claimed Total already claimed.
    /// @return claimableNow Total claimable right now.
    function positionTotals(IAmpsBonds bonds, address owner)
        external
        view
        returns (uint256 principal, uint256 claimed, uint256 claimableNow)
    {
        uint256 count = bonds.positionCount(owner);
        for (uint256 i; i < count; ++i) {
            VestingPosition memory record = bonds.position(owner, i);
            principal += record.principal;
            claimed += record.claimed;
        }
        claimableNow = bonds.claimableTotal(owner);
    }

    /// @notice The whole bond board: every market from 1 to `marketCount`, quoted at `amountIn` of its own
    ///         collateral.
    /// @dev `IAmpsBonds.quote` never reverts for a known market, so this never reverts either: a closed, gated or
    ///      full market comes back with `ampsOut == 0` and a `reason`.
    /// @param bonds The `AmpsBonds` instance.
    /// @param amountIn The hypothetical deposit, in each collateral's own raw units.
    /// @return quotes One row per market.
    function board(IAmpsBonds bonds, uint256 amountIn) external view returns (MarketQuote[] memory quotes) {
        uint16 count = bonds.marketCount();
        quotes = new MarketQuote[](count);
        for (uint16 i; i < count; ++i) {
            uint16 marketId = i + 1;
            MarketQuote memory row = quotes[i];
            row.marketId = marketId;
            row.record = bonds.market(marketId);
            (row.ampsOut, row.qX18, row.discountBps, row.floorBinding, row.capacityLeft, row.reason) =
                bonds.quote(marketId, amountIn);
        }
    }
}
