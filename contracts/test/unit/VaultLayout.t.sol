// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {Constants} from "../../src/types/Constants.sol";
import {AmpsVaultFixture} from "../mocks/AmpsVaultFixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title VaultLayoutTest
/// @notice Pins `AmpsVault`'s storage layout to section 1.1 of `docs/phase2-state-model.md`, slot for slot and bit
///         for bit, with `vm.load`.
///
/// @dev Why this exists as a test rather than a comment: the layout is load-bearing three ways over. The checkpoint
///      is two packed words so that a redemption pays at most two SSTOREs for it; the whole governed numeric set is
///      one word so that every gated path reads it in one SLOAD; and a standby vault written against these slots is
///      what makes `emergencyMigrate` a migration rather than a rewrite. Reordering a field silently would break
///      all three, and nothing else in the build would notice.
contract VaultLayoutTest is AmpsVaultFixture {
    /// @dev Distinct, in-band values so that every field's bit range is separable in the packed word.
    uint16 internal constant P_REDEEM_FEE = 123;
    uint16 internal constant P_BURN = 456;
    uint16 internal constant P_STAKER = 789;
    uint16 internal constant P_REF_UP = 1011;
    uint16 internal constant P_REF_DIV = 1213;
    uint32 internal constant P_TWAP = 1415;
    uint64 internal constant P_TILT = 1.3e18;
    uint8 internal constant P_DOUBLINGS = 7;
    uint8 internal constant P_SEED_HALVINGS = 3;
    uint8 internal constant P_BOND_HALVINGS = 5;
    uint16 internal constant P_SPOKE_SEED = 321;
    uint16 internal constant P_ROLLOUT = 654;
    uint16 internal constant P_ENTRY_FLOOR = 987;

    function setUp() public {
        deployVaultWorld();
        runGenesis();
    }

    /// @notice Slot 0: `uint128 navPerShareX18 [0..127] | uint128 pRefX18 [128..255]`.
    function test_slot0_checkpointWord0() public {
        seedHubPrice(1.5e18);
        vm.warp(block.timestamp + 1800);
        vault.checkpoint();

        uint256 word = uint256(vm.load(address(vault), bytes32(uint256(0))));
        assertEq(uint128(word), vault.navPerShareX18(), "navPerShareX18 in [0..127]");
        assertEq(uint128(word >> 128), vault.pRefX18(), "pRefX18 in [128..255]");
        assertGt(uint128(word), 0, "and both are actually populated");
        assertGt(uint128(word >> 128), 0, "so the assertion is not vacuous");
    }

    /// @notice Slot 1: `uint128 pMktX18 [0..127] | uint32 timestamp [128..159] | uint32 blockNumber [160..191]`.
    function test_slot1_checkpointWord1() public {
        seedHubPrice(1.5e18);
        vm.warp(block.timestamp + 1800);
        vm.roll(block.number + 7);
        vault.checkpoint();

        uint256 word = uint256(vm.load(address(vault), bytes32(uint256(1))));
        assertEq(uint128(word), vault.pMktX18(), "pMktX18 in [0..127]");
        assertEq(uint32(word >> 128), uint32(block.timestamp), "checkpointTimestamp in [128..159]");
        assertEq(uint32(word >> 160), uint32(block.number), "checkpointBlock in [160..191]");
        assertEq(word >> 192, 0, "[192..255] is free");
        assertGt(uint128(word), 0, "P_mkt is populated");
    }

    /// @notice Slot 2: the whole governed numeric set in one word, in the documented bit order.
    function test_slot2_governedParameters() public {
        vm.startPrank(TIMELOCK);
        vault.setRedeemFeeBps(P_REDEEM_FEE);
        vault.setBurnBps(P_BURN);
        vault.setStakerBps(P_STAKER);
        vault.setRefUpRateBps(P_REF_UP);
        vault.setRefDivergenceBps(P_REF_DIV);
        vault.setTwapWindow(P_TWAP);
        vault.setLadderShape(P_TILT, P_DOUBLINGS, P_SEED_HALVINGS, P_BOND_HALVINGS);
        vault.setSpokeSeedBps(P_SPOKE_SEED);
        vault.setRolloutParams(P_ROLLOUT, P_ENTRY_FLOOR);
        vm.stopPrank();

        uint256 word = uint256(vm.load(address(vault), bytes32(uint256(2))));

        assertEq(uint16(word), P_REDEEM_FEE, "redeemFeeBps [0..15]");
        assertEq(uint16(word >> 16), P_BURN, "burnBps [16..31]");
        assertEq(uint16(word >> 32), P_STAKER, "stakerBps [32..47]");
        assertEq(uint16(word >> 48), P_REF_UP, "refUpRateBps [48..63]");
        assertEq(uint16(word >> 64), P_REF_DIV, "refDivergenceBps [64..79]");
        assertEq(uint32(word >> 80), P_TWAP, "twapWindow [80..111]");
        assertEq(uint64(word >> 112), P_TILT, "ladderTiltX18 [112..175]");
        assertEq(uint8(word >> 176), P_DOUBLINGS, "ladderDoublings [176..183]");
        assertEq(uint8(word >> 184), P_SEED_HALVINGS, "seedHalvings [184..191]");
        assertEq(uint8(word >> 192), P_BOND_HALVINGS, "bondBidHalvings [192..199]");
        assertEq(uint16(word >> 200), P_SPOKE_SEED, "spokeSeedBps [200..215]");
        assertEq(uint16(word >> 216), P_ROLLOUT, "rolloutBpsPerDay [216..231]");
        assertEq(uint16(word >> 232), P_ENTRY_FLOOR, "entryFloorBps [232..247]");
        assertEq(word >> 248, 0, "[248..255] is free");

        // The packed word is the full reconstruction, not a lucky set of field reads.
        uint256 expected = uint256(P_REDEEM_FEE) | (uint256(P_BURN) << 16) | (uint256(P_STAKER) << 32)
            | (uint256(P_REF_UP) << 48) | (uint256(P_REF_DIV) << 64) | (uint256(P_TWAP) << 80)
            | (uint256(P_TILT) << 112) | (uint256(P_DOUBLINGS) << 176) | (uint256(P_SEED_HALVINGS) << 184)
            | (uint256(P_BOND_HALVINGS) << 192) | (uint256(P_SPOKE_SEED) << 200) | (uint256(P_ROLLOUT) << 216)
            | (uint256(P_ENTRY_FLOOR) << 232);
        assertEq(word, expected, "slot 2 reconstructed");
    }

    /// @notice Slot 3: `address creator [0..159] | uint32 genesisTimestamp [160..191] | bool initialized [192] |
    ///         bool wiringFrozen [200]`.
    function test_slot3_creatorAndLatches() public view {
        uint256 word = uint256(vm.load(address(vault), bytes32(uint256(3))));

        assertEq(address(uint160(word)), CREATOR, "creator [0..159]");
        assertEq(uint32(word >> 160), vault.genesisTimestamp(), "genesisTimestamp [160..191]");
        assertEq(uint8(word >> 192), 1, "initialized [192..199]");
        assertEq(uint8(word >> 200), 1, "wiringFrozen [200..207]");
        assertEq(word >> 208, 0, "[208..255] is free");

        uint256 expected = uint256(uint160(CREATOR)) | (uint256(vault.genesisTimestamp()) << 160) | (uint256(1) << 192)
            | (uint256(1) << 200);
        assertEq(word, expected, "slot 3 reconstructed");
    }

    /// @notice Slots 4-14: one pointer each, in the documented order.
    function test_slots4to14_pointers() public {
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);

        assertEq(_addressAt(4), address(registry), "slot 4 registry");
        assertEq(_addressAt(5), BONDS, "slot 5 bonds");
        assertEq(_addressAt(6), address(stakingRole), "slot 6 staking");
        assertEq(_addressAt(7), address(potRole), "slot 7 bountyPot");
        assertEq(_addressAt(8), address(marketRef), "slot 8 marketReference");
        assertEq(_addressAt(9), address(gate), "slot 9 oracleGate");
        assertEq(_addressAt(10), address(feeds), "slot 10 feedRegistry");
        assertEq(_addressAt(11), address(valuer), "slot 11 positionValuer");
        assertEq(_addressAt(12), address(0), "slot 12 ladderPolicy, unset in Phase 2");
        assertEq(_addressAt(13), address(0), "slot 13 rolloutPolicy, unset in Phase 2");
        assertEq(_addressAt(14), STANDBY, "slot 14 standbyVault");

        // Every pointer getter reads the slot the layout gives it.
        assertEq(vault.registry(), _addressAt(4), "registry()");
        assertEq(vault.bonds(), _addressAt(5), "bonds()");
        assertEq(vault.staking(), _addressAt(6), "staking()");
        assertEq(vault.bountyPot(), _addressAt(7), "bountyPot()");
        assertEq(vault.marketReference(), _addressAt(8), "marketReference()");
        assertEq(vault.oracleGate(), _addressAt(9), "oracleGate()");
        assertEq(vault.feedRegistry(), _addressAt(10), "feedRegistry()");
        assertEq(vault.positionValuer(), _addressAt(11), "positionValuer()");
        assertEq(vault.ladderPolicy(), _addressAt(12), "ladderPolicy()");
        assertEq(vault.rolloutPolicy(), _addressAt(13), "rolloutPolicy()");
        assertEq(vault.standbyVault(), _addressAt(14), "standbyVault()");
    }

    /// @notice Slot 15: `uint128 rolloutMoved24h [0..127] | uint32 rolloutWindowStart [128..159]`. **Phase 3.**
    function test_slot15_rolloutWindowIsReservedAndUntouched() public view {
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(15)))), 0, "nothing in Phase 2 writes the window");
    }

    /// @notice Slot 16 is the asset array's length, and its elements hash from that slot.
    function test_slot16_assetArray() public view {
        uint256 length = uint256(vm.load(address(vault), bytes32(uint256(16))));
        assertEq(length, vault.assetCount(), "length at slot 16");
        assertEq(length, 4, "two constituents plus WETH and USDG");

        bytes32 base = keccak256(abi.encode(uint256(16)));
        for (uint256 i; i < length; ++i) {
            address stored = address(uint160(uint256(vm.load(address(vault), bytes32(uint256(base) + i)))));
            assertEq(stored, vault.assetAt(i), "element in registration order");
        }
    }

    /// @notice Slot 17 is the 1-based `assetIndex` mapping; zero means "not an asset", which is what AMPS is.
    function test_slot17_assetIndexMapping() public view {
        for (uint256 i; i < vault.assetCount(); ++i) {
            address token = vault.assetAt(i);
            bytes32 key = keccak256(abi.encode(token, uint256(17)));
            assertEq(uint256(vm.load(address(vault), key)), i + 1, "1-based index");
        }
        assertEq(
            uint256(vm.load(address(vault), keccak256(abi.encode(address(amps), uint256(17))))),
            0,
            "AMPS is not an asset (I5)"
        );
    }

    /// @notice Slots 18 and 19 are the Phase 3 ladder mappings: reserved, and empty for every key in Phase 2.
    function test_slots18and19_ladderMappingsAreEmpty() public view {
        PoolId[] memory pools = new PoolId[](3);
        pools[0] = hubPool;
        pools[1] = wethPool;
        pools[2] = spokePool;
        for (uint256 i; i < pools.length; ++i) {
            bytes32 ladderKey = keccak256(abi.encode(pools[i], uint256(18)));
            bytes32 cooldownKey = keccak256(abi.encode(pools[i], uint256(19)));
            assertEq(uint256(vm.load(address(vault), ladderKey)), 0, "slot 18: no placement records");
            assertEq(uint256(vm.load(address(vault), cooldownKey)), 0, "slot 19: no placement timestamps");

            // The Phase 3 read surface over slot 18 agrees, and reports emptiness without reverting.
            assertEq(vault.ladderLength(pools[i]), 0, "ladderLength reads the same empty array");
        }
    }

    /// @notice {IAmpsVault-ladderAt} is the generated getter over slot 18, and an out-of-range index reverts rather
    ///         than returning a zeroed record — reading past the end must never look like an empty cell.
    /// @dev The revert carries **no return data**: Solidity's generated getter for a dynamic array bounds-checks
    ///      with a bare `revert()`, not with `Panic(0x32)` the way an in-contract `arr[i]` would. A consumer must
    ///      therefore call {IAmpsVault-ladderLength} first rather than probing for a decodable error.
    function test_slot18_ladderAtIsBoundsChecked() public {
        (bool ok, bytes memory returndata) =
            address(vault).staticcall(abi.encodeCall(IAmpsVault.ladderAt, (spokePool, 0)));
        assertFalse(ok, "reading past the end reverts");
        assertEq(returndata.length, 0, "and carries no data, so callers must read ladderLength first");
    }

    /// @notice Slot 20: `uint256 deployThresholdUsd18`. **Phase 3.**
    /// @dev `docs/phase3-state-model.md` §10 ruling 15 adds the one governed parameter Phase 3 needs that section
    ///      1.1 has no room for. It is **appended** rather than packed into slot 15's free upper 96 bits, on
    ///      purpose: slots 0-19 are what the Phase 2 state model documents field by field and what a standby vault
    ///      is written against, so the append-only rule is worth a whole word to keep literally true.
    function test_slot20_deployThresholdIsAppendedNotPacked() public {
        assertEq(
            uint256(vm.load(address(vault), bytes32(uint256(20)))),
            Constants.DEPLOY_THRESHOLD_USD18_DEFAULT,
            "the launch threshold sits alone in slot 20"
        );
        assertEq(vault.deployThresholdUsd18(), Constants.DEPLOY_THRESHOLD_USD18_DEFAULT, "and the getter agrees");

        // Slot 15's upper 96 bits stay free: nothing was squeezed in beside the rollout window.
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(15)))) >> 160, 0, "slot 15 [160..255] still free");

        vm.prank(TIMELOCK);
        vault.setDeployThresholdUsd18(4242e18);
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(20)))), 4242e18, "and the setter writes slot 20");
    }

    /// @notice The immutables carry no slot at all: they live in the bytecode, as section 1.1 says.
    function test_immutablesOccupyNoSlot() public view {
        assertEq(vault.amps(), address(amps), "amps");
        assertEq(vault.poolManager(), address(poolManager), "poolManager");
        assertEq(vault.timelock(), TIMELOCK, "timelock");
        assertEq(vault.guardian(), GUARDIAN, "guardian");

        // Slots 21 and beyond are unused: the layout ends at 20.
        for (uint256 slot = 21; slot < 26; ++slot) {
            assertEq(uint256(vm.load(address(vault), bytes32(slot))), 0, "no storage past slot 20");
        }
    }

    /// @dev The address in `slot`.
    function _addressAt(uint256 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), bytes32(slot)))));
    }
}
