// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Handlers} from "./handlers/Handlers.sol";
import {console} from "forge-std/console.sol";

/// @notice TEMPORARY smoke harness for the GLOBAL properties. Delete it before the campaign runs — it exists only
///         to prove that every `property_*` in the GLOBAL section of `Properties.sol` is callable, and that none of
///         them fires on a world the protocol itself considers healthy.
///
/// @dev **Why this is worth its own file.** A global property that reverts is invisible in Medusa's assertion mode
///      (a reverted call is not a failed test) and a global property that *fires* on the genesis state costs the
///      whole campaign its signal. Both classes of mistake are cheap to find here and expensive to find after a
///      31-minute recompile plus a fuzzing run.
///
/// @dev Each property is invoked through an external self-call so that an assertion failure inside it surfaces as a
///      revert this harness can attribute to a Spec ID, rather than aborting the test at the first one. Two passes:
///      once on the genesis world, once after a sequence that has bonded, swapped, placed, compounded, redeemed and
///      walked the clock, so a property that only becomes false with real inventory in the ladders is caught too.
contract GlobalSmoke is Handlers {
    string[] internal failures;

    modifier asActor() override {
        vm.prank(actor);
        _;
    }

    function setUp() public {
        setup();
    }

    // forge test --match-test test_globalProperties -vv
    function test_globalProperties() public {
        setCurrentActor(0);

        _sweepAll("genesis");
        _drive();
        _sweepAll("after activity");

        for (uint256 i; i < failures.length; ++i) {
            console.log("FAILED:", failures[i]);
        }
        assertEq(failures.length, 0, "a global property reverted or fired");
    }

    /// @dev A short sequence that puts real inventory, real positions and real fees into the world.
    /// @dev Every step goes through {_try}: a clamped handler reverts as a matter of course here — a placement
    ///      cooldown, a closed market, the hook's outer rail — and this harness is about the properties, not about
    ///      whether one particular step landed. What matters is the state the sequence leaves behind.
    function _drive() private {
        _try(abi.encodeCall(this.ampsBonds_bond_clamped, (uint256(0), uint256(9))));
        _try(abi.encodeCall(this.ampsRouter_buy_clamped, (uint256(0), uint256(3))));
        _try(abi.encodeCall(this.ampsRouter_buy_clamped, (uint256(1), uint256(3))));
        _try(abi.encodeCall(this.ampsVault_checkpoint_clamped, ()));
        warpBy(2 hours);
        _try(abi.encodeCall(this.ampsVault_compound_clamped, (uint256(0))));
        _try(abi.encodeCall(this.ampsVault_secondary, (uint8(0), uint256(0), uint256(0), uint256(7), uint256(0))));
        _try(abi.encodeCall(this.ampsVault_deployBonded_clamped, (uint256(0))));
        _try(abi.encodeCall(this.ampsVault_rollout_clamped, (uint256(0))));
        _try(abi.encodeCall(this.ampsRouter_sell_clamped, (uint256(0), uint256(5))));
        _try(abi.encodeCall(this.ampsVault_redeemProRata_dust, (uint256(3))));
        _try(abi.encodeCall(this.ampsVault_donateERC20, (uint256(0), uint256(1), uint256(5))));
        warpBy(1 days);
        _try(abi.encodeCall(this.ampsBonds_claimAll_clamped, ()));
        _try(abi.encodeCall(this.poolRegistry_secondary, (uint8(0), uint256(1), uint256(0))));
        _try(abi.encodeCall(this.oracleGate_secondary, (uint8(4), uint256(0))));
    }

    function _try(bytes memory payload) private {
        (bool ok,) = address(this).call(payload);
        ok;
    }

    /// @dev Every GL-* property, in Spec ID order. GL-31 is a documented TODO and has no function.
    function _sweepAll(string memory phase) private {
        uint256 seed = uint256(keccak256(abi.encode(phase, block.timestamp)));

        _check(abi.encodeCall(this.property_ampsClosureSumsToSupply, (seed)), phase, "GL-01");
        _check(abi.encodeCall(this.property_supplyUnderGenesisPlusIssuance, (seed)), phase, "GL-02");
        _check(abi.encodeCall(this.property_supplyLedgerCloses, (seed)), phase, "GL-03");
        _check(abi.encodeCall(this.property_shareTokenRolesIntact, ()), phase, "GL-04");
        _check(abi.encodeCall(this.property_bondShellCoversItsBook, (seed)), phase, "GL-05");
        _check(abi.encodeCall(this.property_perMarketIssuanceLedger, (seed)), phase, "GL-06");
        _check(abi.encodeCall(this.property_epochIssuanceContained, ()), phase, "GL-07");
        _check(abi.encodeCall(this.property_bondCapsBindCumulatively, (seed)), phase, "GL-08");
        _check(abi.encodeCall(this.property_vestingBookIsConsistent, (seed)), phase, "GL-09");
        _check(abi.encodeCall(this.property_positionFieldsImmutable, (seed)), phase, "GL-10");
        _check(abi.encodeCall(this.property_claimableIsMonotoneAndOwnerOnly, (seed)), phase, "GL-11");
        _check(abi.encodeCall(this.property_positionCountMonotone, (seed)), phase, "GL-12");
        _check(abi.encodeCall(this.property_totalIssuedMonotone, (seed)), phase, "GL-13");
        _check(abi.encodeCall(this.property_everyVestedPositionIsClaimable, (seed)), phase, "GL-14");
        _check(abi.encodeCall(this.property_positionArrayGriefingBounded, (seed)), phase, "GL-15");
        _check(abi.encodeCall(this.property_closedMarketHasNotIssued, (seed)), phase, "GL-16");
        _check(abi.encodeCall(this.property_marketAttributionAgrees, (seed)), phase, "GL-17");
        _check(abi.encodeCall(this.property_navPerShareIdentity, (seed)), phase, "GL-18");
        _check(abi.encodeCall(this.property_assetsDecomposeIntoA, (seed)), phase, "GL-19");
        _check(abi.encodeCall(this.property_assetRegistryWellFormed, (seed)), phase, "GL-20");
        _check(abi.encodeCall(this.property_inventoryAmpsDecomposes, (seed)), phase, "GL-21");
        _check(abi.encodeCall(this.property_redemptionIsCovered, (seed)), phase, "GL-22");
        _check(abi.encodeCall(this.property_poolManagerCoversClaims, (seed)), phase, "GL-23");
        _check(abi.encodeCall(this.property_zeroStateSafety, (seed)), phase, "GL-24");
        _check(abi.encodeCall(this.property_noShareInflationGrief, (seed)), phase, "GL-25");
        _check(abi.encodeCall(this.property_disclosureNeverReverts, (seed)), phase, "GL-26");
        _check(abi.encodeCall(this.property_theFloorIsAlwaysOpen, (seed)), phase, "GL-27");
        _check(abi.encodeCall(this.property_redemptionIsNotSplittableForProfit, (seed)), phase, "GL-28");
        _check(abi.encodeCall(this.property_previewRedeemIsMonotone, (seed)), phase, "GL-29");
        _check(abi.encodeCall(this.property_noFreeRoundTripOnTheQuoter, (seed)), phase, "GL-30");
        _check(abi.encodeCall(this.property_cumulativeKeeperBleedBounded, (seed)), phase, "GL-32");
        _check(abi.encodeCall(this.property_referencePriceFloorsAtNav, ()), phase, "GL-33");
        _check(abi.encodeCall(this.property_governedScalarsInBand, (seed)), phase, "GL-34");
        _check(abi.encodeCall(this.property_creatorBpsIsMonotone, (seed)), phase, "GL-35");
        _check(abi.encodeCall(this.property_creatorSliceIsBoundedCumulatively, (seed)), phase, "GL-36");
        _check(abi.encodeCall(this.property_rotationCreditIsTransactionScoped, ()), phase, "GL-37");
        _check(abi.encodeCall(this.property_hookHoldsAndMovesNothing, (seed)), phase, "GL-38");
        _check(abi.encodeCall(this.property_routerHoldsNothing, (seed)), phase, "GL-39");
        _check(abi.encodeCall(this.property_liveCellCounterIsHonest, (seed)), phase, "GL-40");
        _check(abi.encodeCall(this.property_recordedLiquidityMatchesPoolManager, (seed)), phase, "GL-41");
        _check(abi.encodeCall(this.property_everyRecordIsOneCanonicalCell, (seed)), phase, "GL-42");
        _check(abi.encodeCall(this.property_ladderSidednessHolds, (seed)), phase, "GL-43");
        _check(abi.encodeCall(this.property_ladderLengthMonotoneAndBounded, (seed)), phase, "GL-44");
        _check(abi.encodeCall(this.property_lastPlacementAtMonotone, (seed)), phase, "GL-45");
        _check(abi.encodeCall(this.property_checkpointStampsMonotone, (seed)), phase, "GL-46");
        _check(abi.encodeCall(this.property_highWaterRisesOnly, (seed)), phase, "GL-47");
        _check(abi.encodeCall(this.property_observationCoverageMonotone, (seed)), phase, "GL-48");
        _check(abi.encodeCall(this.property_rolloutDrainIsBounded, (seed)), phase, "GL-49");
        _check(abi.encodeCall(this.property_activeSetIsConsistent, (seed)), phase, "GL-50");
        _check(abi.encodeCall(this.property_retiredIffStamped, (seed)), phase, "GL-51");
        _check(abi.encodeCall(this.property_retiredNamesAreExitOnly, (seed)), phase, "GL-52");
        _check(abi.encodeCall(this.property_weightVectorNormalises, (seed)), phase, "GL-53");
        _check(abi.encodeCall(this.property_populationCountersBounded, (seed)), phase, "GL-54");
        _check(abi.encodeCall(this.property_pendingImpliesALatch, (seed)), phase, "GL-55");
        _check(abi.encodeCall(this.property_freezeOutranksEveryLayer, (seed)), phase, "GL-56");
        _check(abi.encodeCall(this.property_freezesAreBoundedAndExpire, (seed)), phase, "GL-57");
        _check(abi.encodeCall(this.property_watchdogStampMonotone, (seed)), phase, "GL-58");
        _check(abi.encodeCall(this.property_launchLatchesHold, ()), phase, "GL-59");
        _check(abi.encodeCall(this.property_theBountyPotIsBounded, (seed)), phase, "GL-60");
        _check(abi.encodeCall(this.property_noStuckTransientLock, (seed)), phase, "GL-61");
        _check(abi.encodeCall(this.property_narrowTypesDoNotBrick, (seed)), phase, "GL-62");
        _check(abi.encodeCall(this.property_noPrivilegeEscalation, (seed)), phase, "GL-63");
        _check(abi.encodeCall(this.property_priceLibUsdRawRoundTrip, (seed)), phase, "GL-64");
        _check(abi.encodeCall(this.property_priceLibSqrtRoundTrip, (seed)), phase, "GL-65");
        _check(abi.encodeCall(this.property_tickRoundTripAndAlign, (seed)), phase, "GL-66");
        _check(abi.encodeCall(this.property_ladderAmountLiquidityRoundTrip, (seed)), phase, "GL-67");
        _check(abi.encodeCall(this.property_ladderSplitIsExact, (seed)), phase, "GL-68");
        _check(abi.encodeCall(this.property_hookStatePackRoundTrip, (seed)), phase, "GL-69");
        _check(abi.encodeCall(this.property_priceLibDirections, (seed)), phase, "GL-70");
        _check(abi.encodeCall(this.property_qFloorImplementationsAgree, (seed)), phase, "GL-71");
        _check(abi.encodeCall(this.property_ladderGeometryIsContiguous, (seed)), phase, "GL-72");
        _check(abi.encodeCall(this.property_discountIsBandedAndMonotone, (seed)), phase, "GL-73");
        _check(abi.encodeCall(this.property_zeroInputsAreSafe, (seed)), phase, "GL-74");
        _check(abi.encodeCall(this.property_hookFeeIsWithinI16, (seed)), phase, "GL-75");
        _check(abi.encodeCall(this.property_blendedBaseNeverRoundsDown, (seed)), phase, "GL-76");
        _check(abi.encodeCall(this.property_quoterAgreesWithTheHook, (seed)), phase, "GL-77");
        _check(abi.encodeCall(this.property_priceImpactIsMonotone, (seed)), phase, "GL-78");
        _check(abi.encodeCall(this.property_bondQuoteIsMonotone, (seed)), phase, "GL-79");
        _check(abi.encodeCall(this.property_retiredBidsNeverOverReturn, (seed)), phase, "GL-80");
        _check(abi.encodeCall(this.property_valuerNeverOverstatesAPool, (seed)), phase, "GL-81");
    }

    function _check(bytes memory payload, string memory phase, string memory id) private {
        (bool ok,) = address(this).call(payload);
        if (!ok) failures.push(string.concat(id, " (", phase, ")"));
    }
}
