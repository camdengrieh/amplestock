// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolRegistry} from "../interfaces/IPoolRegistry.sol";
import {Constants} from "../types/Constants.sol";
import {ZeroAddress} from "../types/Errors.sol";
import {ConstituentConfig, ConstituentStatus} from "../types/Types.sol";

/// @title PoolRegistryLens
/// @notice The derived reads over `PoolRegistry`: the active constituent list, the index weight vector and the
///         cap/floor rule evaluated at an arbitrary count.
///
/// @dev **Why these live outside the registry.** `PoolRegistry` is immutable bytecode and sits close to the
///      EIP-170 limit, and none of the views here is part of `IPoolRegistry` or read by any contract on a hot
///      path: they exist for the dApp, the indexer, the keeper and the governance drill. Each is a pure function
///      of the registry's own public getters, so the lens holds no state, needs no wiring beyond the registry
///      address, and can be redeployed at any time without touching the registry or a single stored value.
///
/// @dev **Freezes.** `PoolRegistry.constituent` reports a governance-forced corporate-action freeze as
///      `ConstituentStatus.FROZEN` over an otherwise `ACTIVE` record, and a frozen name is still an index member.
///      The list and the weight vector therefore include every constituent that is neither `NONE` nor `RETIRED`,
///      which is exactly the set `PoolRegistry.activeConstituentCount` counts.
contract PoolRegistryLens {
    /// @notice The registry this lens reads.
    IPoolRegistry public immutable registry;

    /// @param registry_ The `PoolRegistry` to read.
    constructor(address registry_) {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = IPoolRegistry(registry_);
    }

    /// @notice The ids of every constituent that is not retired, in ascending id order.
    /// @return ids The active ids.
    function activeConstituents() external view returns (uint16[] memory ids) {
        uint16 count = registry.constituentCount();
        ids = new uint16[](registry.activeConstituentCount());
        uint256 next;
        for (uint16 id = 1; id <= count; ++id) {
            if (_isActive(registry.constituent(id).status)) ids[next++] = id;
        }
    }

    /// @notice The index target weights of every active constituent, parallel to {activeConstituents}.
    /// @return ids The active ids.
    /// @return weightsBps Their target weights, in bps.
    /// @return totalBps The sum, which the quarterly rule holds at `BPS` (10,000).
    function indexWeights() external view returns (uint16[] memory ids, uint16[] memory weightsBps, uint256 totalBps) {
        uint16 count = registry.constituentCount();
        uint16 active = registry.activeConstituentCount();
        ids = new uint16[](active);
        weightsBps = new uint16[](active);
        uint256 next;
        for (uint16 id = 1; id <= count; ++id) {
            ConstituentConfig memory config = registry.constituent(id);
            if (!_isActive(config.status)) continue;
            ids[next] = id;
            weightsBps[next] = config.targetWeightBps;
            totalBps += config.targetWeightBps;
            ++next;
        }
    }

    /// @notice The index cap and floor a set of `n` active constituents carries.
    /// @dev The same rule `PoolRegistry` enforces, evaluated at an arbitrary `n` so that a proposal can be checked
    ///      against the count it *produces* rather than the one it starts from. At the live count it agrees with
    ///      `PoolRegistry.indexFloorBps` and `PoolRegistry.indexCapBps` by construction; the unit suite asserts
    ///      that agreement rather than assuming it.
    /// @param n The active constituent count.
    /// @return floorBps `min(500, 10000 / (2n))`, and 0 for an empty index.
    /// @return capBps `max(3000, ceilDiv(10000, n))`, and `BPS` for an empty index.
    function weightBoundsFor(uint16 n) external pure returns (uint16 floorBps, uint16 capBps) {
        if (n == 0) return (0, uint16(Constants.BPS));
        uint256 cap = (Constants.BPS + n - 1) / n;
        capBps = cap > Constants.INDEX_CAP_FLOOR_BPS ? uint16(cap) : Constants.INDEX_CAP_FLOOR_BPS;
        uint256 floor_ = Constants.BPS / (2 * uint256(n));
        floorBps = floor_ < Constants.INDEX_FLOOR_CEILING_BPS ? uint16(floor_) : Constants.INDEX_FLOOR_CEILING_BPS;
    }

    /// @dev A constituent counts toward the index unless it has been retired. Both loops walk `[1, count]`, and
    ///      every id in that range has been issued, so `NONE` cannot appear and is not tested for; a freeze is
    ///      temporary and disable-only, so a frozen name is still a member.
    function _isActive(ConstituentStatus status) private pure returns (bool active) {
        active = status != ConstituentStatus.RETIRED;
    }
}
