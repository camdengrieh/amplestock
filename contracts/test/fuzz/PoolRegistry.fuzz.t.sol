// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolRegistry} from "../../src/interfaces/IPoolRegistry.sol";
import {Constants} from "../../src/types/Constants.sol";
import {ConstituentConfig, ConstituentStatus, PoolClass} from "../../src/types/Types.sol";
import {PoolRegistryFixture} from "../unit/PoolRegistry.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title PoolRegistryFuzzTest
/// @notice Property coverage for `PoolRegistry`: the index cap and floor rule at every count, the inclusion rule
///         against an independently computed threshold, the weight band on registration, and the constituent
///         lifecycle driven as a random walk.
/// @dev    The lifecycle walk only ever proposes weights inside `[500, 3000]`. That is not a convenience: 500 is
///         the highest floor any `n` produces and 3000 the lowest cap, so a weight chosen there is legal at every
///         count, which is what lets the walk assert "every active weight is inside the live band" after each step
///         rather than only after the step that set it.
contract PoolRegistryFuzzTest is PoolRegistryFixture {
    /// @dev The widest weight window that is legal at every `n` in `[1, MAX_CONSTITUENTS]`.
    uint16 internal constant UNIVERSAL_WEIGHT_MIN = 500;
    uint16 internal constant UNIVERSAL_WEIGHT_MAX = 3000;

    /// @dev Steps per lifecycle walk. Long enough to interleave every transition, short enough that 512 runs stay
    ///      inside a sane wall-clock budget.
    uint256 internal constant WALK_STEPS = 24;

    // -------------------------------------------------------------------------------------------------------------
    // The index cap and floor rule
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `cap_n = max(3000, ceilDiv(10000, n))` and `floor_n = min(500, 10000 / (2n))` for every reachable
    ///         count, and the two always admit at least one legal vector: `n * floor_n <= BPS <= n * cap_n`.
    function testFuzz_weightBounds(uint16 n) public view {
        n = uint16(bound(n, 1, Constants.MAX_CONSTITUENTS));
        (uint16 floorBps, uint16 capBps) = lens.weightBoundsFor(n);

        uint256 expectedCap = Math.max(Constants.INDEX_CAP_FLOOR_BPS, Math.ceilDiv(Constants.BPS, n));
        uint256 expectedFloor = Math.min(Constants.INDEX_FLOOR_CEILING_BPS, Constants.BPS / (2 * uint256(n)));
        assertEq(capBps, expectedCap, "cap");
        assertEq(floorBps, expectedFloor, "floor");

        assertLe(floorBps, capBps, "floor never exceeds cap");
        assertLe(uint256(floorBps) * n, Constants.BPS, "a legal vector is never forced above 100%");
        assertGe(uint256(capBps) * n, Constants.BPS, "a legal vector can always reach 100%");
        assertLe(capBps, Constants.BPS, "no name is capped above the whole index");
        assertLe(floorBps, Constants.INDEX_FLOOR_CEILING_BPS, "the floor never rises above 5%");
        assertGe(capBps, Constants.INDEX_CAP_FLOOR_BPS, "the cap never falls below 30%");
    }

    /// @notice The live bounds are the pure rule applied to the live active count, whatever the set has been
    ///         through.
    function testFuzz_liveBoundsFollowActiveCount(uint8 adds, uint8 retires) public {
        uint256 addCount = bound(adds, 1, 12);
        for (uint256 i; i < addCount; ++i) {
            _add(i);
        }
        uint256 retireCount = bound(retires, 0, addCount - 1);
        for (uint256 i; i < retireCount; ++i) {
            vm.prank(TIMELOCK);
            registry.retireConstituent(uint16(i + 1));
        }

        uint16 n = registry.activeConstituentCount();
        assertEq(n, uint16(addCount - retireCount), "active count");
        (uint16 floorBps, uint16 capBps) = lens.weightBoundsFor(n);
        assertEq(registry.indexCapBps(), capBps, "live cap");
        assertEq(registry.indexFloorBps(), floorBps, "live floor");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A registration is accepted exactly when its target weight is inside the band for the count the
    ///         registration produces.
    function testFuzz_addConstituent_weightBand(uint16 weightBps, uint8 existing) public {
        uint256 before = bound(existing, 0, 8);
        for (uint256 i; i < before; ++i) {
            _add(i);
        }

        weightBps = uint16(bound(weightBps, 0, Constants.BPS));
        (uint16 floorBps, uint16 capBps) = lens.weightBoundsFor(uint16(before) + 1);

        IPoolRegistry.AddConstituentParams memory params = _addParams(before);
        params.targetWeightBps = weightBps;

        if (weightBps < floorBps || weightBps > capBps) {
            vm.prank(TIMELOCK);
            vm.expectRevert(
                abi.encodeWithSelector(IPoolRegistry.WeightOutOfRange.selector, weightBps, floorBps, capBps)
            );
            registry.addConstituent(params);
            assertEq(registry.constituentCount(), uint16(before), "nothing registered");
        } else {
            (uint16 id,) = _addWith(params);
            assertEq(registry.constituent(id).targetWeightBps, weightBps, "weight recorded");
            assertEq(registry.activeConstituentCount(), uint16(before) + 1, "active count");
        }
    }

    /// @notice The inclusion rule gates the rollout weight and nothing else: a name is registrable at any beta,
    ///         and carries rollout weight exactly when `beta > 0.5 + sigma_u^2 / (2 sigma_I^2)`.
    function testFuzz_inclusionRule(int64 betaX18, uint64 trackingErrorX18, uint64 indexVolX18, uint16 rolloutWeightBps)
        public
    {
        betaX18 = int64(bound(betaX18, -2e18, 5e18));
        trackingErrorX18 = uint64(bound(trackingErrorX18, 0, 1e18));
        indexVolX18 = uint64(bound(indexVolX18, 1, 1e18));
        rolloutWeightBps = uint16(bound(rolloutWeightBps, 0, uint16(Constants.BPS)));

        // The rule, recomputed here from the plan rather than read back from the contract.
        uint256 thresholdX18 = Constants.WAD / 2
            + Math.mulDiv(
                uint256(trackingErrorX18) * trackingErrorX18, Constants.WAD, 2 * uint256(indexVolX18) * indexVolX18
            );
        bool passes = betaX18 > 0 && uint256(int256(betaX18)) > thresholdX18;

        IPoolRegistry.AddConstituentParams memory params = _addParams(0);
        params.inclusion.betaX18 = betaX18;
        params.inclusion.trackingErrorX18 = trackingErrorX18;
        params.inclusion.indexVolX18 = indexVolX18;
        params.rolloutWeightBps = rolloutWeightBps;

        if (rolloutWeightBps != 0 && !passes) {
            vm.prank(TIMELOCK);
            vm.expectRevert();
            registry.addConstituent(params);
            return;
        }

        (uint16 id,) = _addWith(params);
        assertEq(registry.constituent(id).rolloutWeightBps, rolloutWeightBps, "rollout weight");
        assertEq(registry.inclusionRecord(id).betaX18, betaX18, "the evidence is recorded verbatim");
        assertEq(registry.inclusionRecord(id).trackingErrorX18, trackingErrorX18, "tracking error recorded");
        assertEq(registry.inclusionRecord(id).indexVolX18, indexVolX18, "index vol recorded");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The index vector
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `setIndexWeights` accepts a vector exactly when every entry is in band and the whole thing sums to
    ///         `BPS`; when it does, the stored vector is the one proposed.
    function testFuzz_setIndexWeights(uint16 w0, uint16 w1, uint16 w2) public {
        for (uint256 i; i < 4; ++i) {
            _add(i);
        }
        (uint16 floorBps, uint16 capBps) = lens.weightBoundsFor(4);

        uint16[] memory weightsBps = new uint16[](4);
        weightsBps[0] = uint16(bound(w0, floorBps, capBps));
        weightsBps[1] = uint16(bound(w1, floorBps, capBps));
        weightsBps[2] = uint16(bound(w2, floorBps, capBps));
        uint256 head = uint256(weightsBps[0]) + weightsBps[1] + weightsBps[2];

        if (head >= Constants.BPS || Constants.BPS - head > capBps || Constants.BPS - head < floorBps) {
            // The tail cannot close the vector: whatever legal value it takes, the sum check must refuse it.
            weightsBps[3] = uint16(bound(uint256(w0), floorBps, capBps));
            uint256 sum = head + weightsBps[3];
            vm.prank(TIMELOCK);
            if (sum == Constants.BPS) {
                registry.setIndexWeights(_ids(4), weightsBps);
                (,, uint256 totalBps) = lens.indexWeights();
                assertEq(totalBps, Constants.BPS, "sums to 100%");
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        OutOfBandSelector(), bytes32("indexWeightSum"), sum, Constants.BPS, Constants.BPS
                    )
                );
                registry.setIndexWeights(_ids(4), weightsBps);
            }
            return;
        }

        weightsBps[3] = uint16(Constants.BPS - head);
        vm.prank(TIMELOCK);
        registry.setIndexWeights(_ids(4), weightsBps);

        (uint16[] memory ids, uint16[] memory stored, uint256 total) = lens.indexWeights();
        assertEq(total, Constants.BPS, "sums to 100%");
        for (uint256 i; i < 4; ++i) {
            assertEq(ids[i], uint16(i + 1), "ids in order");
            assertEq(stored[i], weightsBps[i], "weight stored verbatim");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // The lifecycle as a random walk
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Add, retire, reinstate and reconfigure in a random order, asserting after every step that the
    ///         active count is exactly the number of live constituents, that every live weight is inside the band,
    ///         that a retired name has no rollout weight, and that no id is ever reused.
    function testFuzz_lifecycleWalk(uint256 seed) public {
        uint16 expectedNextId = 1;

        for (uint256 step; step < WALK_STEPS; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = seed % 4;
            uint16 weightBps =
                uint16(UNIVERSAL_WEIGHT_MIN + ((seed >> 8) % (UNIVERSAL_WEIGHT_MAX - UNIVERSAL_WEIGHT_MIN + 1)));
            uint16 rolloutWeightBps = uint16((seed >> 24) % (Constants.BPS + 1));

            if (op == 0) {
                uint256 index = registry.constituentCount();
                if (index < 30) {
                    IPoolRegistry.AddConstituentParams memory params = _addParams(index);
                    params.targetWeightBps = weightBps;
                    params.rolloutWeightBps = rolloutWeightBps;
                    (uint16 id,) = _addWith(params);
                    assertEq(id, expectedNextId, "ids are issued in strict sequence");
                    ++expectedNextId;
                }
            } else if (op == 1) {
                uint16[] memory active = lens.activeConstituents();
                if (active.length != 0) {
                    uint16 id = active[(seed >> 40) % active.length];
                    vm.prank(TIMELOCK);
                    registry.retireConstituent(id);
                    assertEq(uint8(registry.constituent(id).status), uint8(ConstituentStatus.RETIRED), "retired");
                }
            } else if (op == 2) {
                uint16 id = _pickRetired(seed >> 56);
                if (id != 0) {
                    vm.prank(TIMELOCK);
                    registry.reinstateConstituent(id, rolloutWeightBps);
                    assertEq(uint8(registry.constituent(id).status), uint8(ConstituentStatus.ACTIVE), "reinstated");
                }
            } else {
                uint16 count = registry.constituentCount();
                if (count != 0) {
                    uint16 id = uint16((seed >> 72) % count) + 1;
                    ConstituentConfig memory config = registry.constituent(id);
                    IPoolRegistry.ReconfigureParams memory params;
                    params.setTargetWeightBps = true;
                    params.targetWeightBps = weightBps;
                    params.setRolloutWeightBps = true;
                    params.rolloutWeightBps = config.status == ConstituentStatus.RETIRED ? 0 : rolloutWeightBps;
                    vm.prank(TIMELOCK);
                    registry.reconfigureConstituent(id, params);
                    assertEq(registry.constituent(id).targetWeightBps, weightBps, "weight applied");
                }
            }

            _assertRegistryInvariants(expectedNextId);
        }
    }

    /// @notice The set can be filled, emptied by retirement and refilled without an id ever being reused or the
    ///         hard cap being exceeded.
    function testFuzz_retirementNeverFreesAnId(uint8 rounds) public {
        uint256 roundCount = bound(rounds, 1, 6);
        uint16 issued;

        for (uint256 r; r < roundCount; ++r) {
            uint256 batch = 4;
            for (uint256 i; i < batch; ++i) {
                if (issued >= 30) break;
                _add(issued);
                ++issued;
                assertEq(registry.constituentCount(), issued, "count follows ids issued");
            }
            uint16[] memory active = lens.activeConstituents();
            for (uint256 i; i < active.length; ++i) {
                vm.prank(TIMELOCK);
                registry.retireConstituent(active[i]);
            }
            assertEq(registry.activeConstituentCount(), 0, "everything retired");
            assertEq(registry.constituentCount(), issued, "no id was freed");
            assertEq(registry.poolCount(), issued, "no pool was deleted");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The invariants that must hold after every lifecycle step.
    function _assertRegistryInvariants(uint16 expectedNextId) internal view {
        uint16 count = registry.constituentCount();
        assertEq(count, expectedNextId - 1, "ids run [1, constituentCount]");
        assertLe(count, Constants.MAX_CONSTITUENTS, "I37: n <= MAX_CONSTITUENTS");
        assertEq(registry.poolCount(), count, "one pool per constituent, none deleted");

        (uint16 floorBps, uint16 capBps) = lens.weightBoundsFor(registry.activeConstituentCount());

        uint16 live;
        for (uint16 id = 1; id <= count; ++id) {
            ConstituentConfig memory config = registry.constituent(id);
            assertTrue(config.status != ConstituentStatus.NONE, "every issued id is a constituent");
            assertEq(registry.constituentIdOf(config.token), id, "token -> id is stable");
            assertEq(registry.constituentOfPool(registry.poolIdOf(id)), id, "pool -> id is stable");

            if (config.status == ConstituentStatus.RETIRED) {
                assertEq(config.rolloutWeightBps, 0, "I37: a retired name has zero rollout weight");
            } else {
                ++live;
                assertGe(config.targetWeightBps, floorBps, "weight at or above the live floor");
                assertLe(config.targetWeightBps, capBps, "weight at or below the live cap");
            }
        }

        assertEq(registry.activeConstituentCount(), live, "activeCount == the number of live constituents");
        assertEq(lens.activeConstituents().length, live, "the derived list agrees with the counter");
    }

    /// @dev The `seed`-th retired id, or 0 when nothing is retired.
    function _pickRetired(uint256 seed) internal view returns (uint16 id) {
        uint16 count = registry.constituentCount();
        uint16 retiredCount;
        for (uint16 i = 1; i <= count; ++i) {
            if (registry.constituent(i).status == ConstituentStatus.RETIRED) ++retiredCount;
        }
        if (retiredCount == 0) return 0;

        uint16 target = uint16(seed % retiredCount);
        for (uint16 i = 1; i <= count; ++i) {
            if (registry.constituent(i).status != ConstituentStatus.RETIRED) continue;
            if (target == 0) return i;
            --target;
        }
    }

    /// @dev `OutOfBand`'s selector, spelled out here so the fuzz file does not import the whole error module for
    ///      one `expectRevert`.
    function OutOfBandSelector() internal pure returns (bytes4 selector) {
        selector = bytes4(keccak256("OutOfBand(bytes32,uint256,uint256,uint256)"));
    }
}
