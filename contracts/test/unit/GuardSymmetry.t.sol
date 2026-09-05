// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {Constants} from "../../src/types/Constants.sol";
import {GateNotHealthy, NotPoolManager} from "../../src/types/Errors.sol";
import {GateState} from "../../src/types/Types.sol";
import {AmpsVaultFixture} from "../mocks/AmpsVaultFixture.sol";
import {MockOracleGate} from "../mocks/MockOracleGate.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice A contract that reverts on every call, used to stand in for a hostile timelock and a broken gate.
contract AlwaysReverts {
    /// @notice Reverts on any call, with or without calldata.
    fallback() external payable {
        revert("down");
    }
}

/// @title GuardSymmetryTest
/// @notice The vault half of the I14 enumeration proof, section 7 of `docs/phase2-state-model.md`.
///
/// @dev Steps 2, 3 and 4 of that proof live here:
///        2. with the gate forced to each of `DEGRADED`, `DIVERGED`, `SCHEDULED_FREEZE` and `WATCHDOG`, every
///           mutating selector except the classified exemptions refuses with `GateNotHealthy`, *called by its own
///           authorised role* — the refusal is the gate's, not the access control's;
///        3. with every feed reverting, the watchdog tripped, a guardian protocol freeze active and the timelock
///           replaced by a contract that reverts on any call, `redeemProRata` succeeds and pays exactly
///           `(1 - redeemFeeBps / BPS) * shares / T` of every non-AMPS balance (I23);
///        4. `vm.record` / `vm.accesses` prove that no storage of the gate, the feed registry, the pool registry or
///           the market reference was touched during that redemption — the storage-level proof that the path
///           *cannot* be gated, not merely that it is not gated today.
///
/// @dev Step 1 (comparing this list against the compiled ABI) is a CI step, because `ffi` is off and
///      `fs_permissions` does not cover the artifact directories. What the Solidity side can do, and does, is hold
///      the list, assert its length against an expected count and assert that the exempt set is exactly the three
///      classified entries — so adding a function without classifying it fails here as well as in CI.
///
/// @dev **Two gate policies.** Every mutating selector but the three exemptions is classified as `MANAGEMENT` or
///      `BONDS`. The management policy is section 7 step 2's four refusing states. The bond policy — taken only by
///      `depositBonded` and `mintVesting` — refuses `DIVERGED` and `SCHEDULED_FREEZE` and tolerates `DEGRADED` and
///      `WATCHDOG`, because bond markets stay open 24/7 through stale feeds and closed sessions and widen
///      `h_session` instead (the plan's Decision 10, and section 2's own table). It mirrors
///      `IOracleGate.checkBond`, so the vault is defence in depth behind the shell rather than a stricter gate.
///
/// @dev **Three classified exemptions, not two.** `redeemProRata` is the structural one section 7 names.
///      `unlockCallback` is guarded by caller identity (`NotPoolManager`) and is unreachable except from inside a
///      call the vault itself started. `emergencyMigrate` is gated by the on-chain denylist predicate instead: the
///      incident it exists for — an issuer denylisting the vault while pausing its oracle — is precisely a state in
///      which `_requireHealthy` refuses, so gating it would brick the evacuation of an immutable contract. Both
///      extra exemptions are asserted below to refuse for their own reason in every gate state.
contract GuardSymmetryTest is AmpsVaultFixture {
    /// @dev Every external state-changing selector on `AmpsVault`. Update the count deliberately, never silently.
    uint256 internal constant EXPECTED_MUTATING_COUNT = 26;

    /// @dev The four states section 7 step 2 forces.
    GateState[4] internal REFUSING_STATES =
        [GateState.DEGRADED, GateState.DIVERGED, GateState.SCHEDULED_FREEZE, GateState.WATCHDOG];

    /// @dev How a selector is guarded.
    enum Guard {
        /// @dev Takes `_requireHealthy`: refuses `DEGRADED`, `DIVERGED`, `SCHEDULED_FREEZE` and `WATCHDOG`.
        MANAGEMENT,
        /// @dev Takes `_requireBondsHealthy`: refuses only `DIVERGED` and `SCHEDULED_FREEZE`, because bond markets
        ///      stay open through stale feeds and closed sessions and widen the haircut instead.
        BONDS,
        /// @dev Classified exemption: guarded by something narrower than the gate, and asserted separately.
        EXEMPT
    }

    /// @dev One entry per external mutating selector.
    struct Entry {
        string name;
        bytes callData;
        address caller;
        Guard guard;
    }

    Entry[] internal entries;

    function setUp() public {
        deployVaultWorld();
        runGenesis();
        giveShares(ALICE, 500e18);
        _buildSelectorTable();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Step 1 — the enumeration itself
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The table covers every mutating selector, each one exactly once, with the classification named.
    function test_step1_enumerationIsCompleteAndClassified() public view {
        assertEq(entries.length, EXPECTED_MUTATING_COUNT, "every mutating selector is classified");

        uint256 exempt;
        uint256 bondsGated;
        for (uint256 i; i < entries.length; ++i) {
            bytes4 selector = bytes4(entries[i].callData);
            for (uint256 j = i + 1; j < entries.length; ++j) {
                assertTrue(selector != bytes4(entries[j].callData), "selectors are distinct");
            }
            if (entries[i].guard == Guard.EXEMPT) ++exempt;
            if (entries[i].guard == Guard.BONDS) ++bondsGated;
        }
        assertEq(exempt, 3, "redeemProRata, emergencyMigrate and unlockCallback, and nothing else");
        assertEq(bondsGated, 2, "depositBonded and mintVesting, and nothing else");
        assertEq(entries.length - exempt - bondsGated, 21, "the rest take the management policy");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Step 2 — every gated selector refuses in every unhealthy state
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `DEGRADED`, `DIVERGED`, `SCHEDULED_FREEZE` and `WATCHDOG` refuse every management-gated selector,
    ///         and `DIVERGED` and `SCHEDULED_FREEZE` refuse the two bond entry points as well.
    function test_step2_everyGatedSelectorRefusesInEveryUnhealthyState() public {
        for (uint256 s; s < REFUSING_STATES.length; ++s) {
            GateState state = REFUSING_STATES[s];
            gate.setDefaultState(state);

            for (uint256 i; i < entries.length; ++i) {
                if (entries[i].guard == Guard.EXEMPT) continue;
                if (
                    entries[i].guard == Guard.BONDS && state != GateState.DIVERGED
                        && state != GateState.SCHEDULED_FREEZE
                ) {
                    continue;
                }
                vm.prank(entries[i].caller);
                (bool ok, bytes memory returndata) = address(vault).call(entries[i].callData);
                assertFalse(ok, string.concat(entries[i].name, " must refuse"));
                assertEq(
                    returndata,
                    abi.encodeWithSelector(GateNotHealthy.selector, uint8(state), bytes32(0)),
                    string.concat(entries[i].name, " must refuse with GateNotHealthy")
                );
            }
        }
    }

    /// @notice A guardian protocol freeze refuses every gated selector too, and expires by itself.
    function test_step2_guardianFreezeRefusesEveryGatedSelector() public {
        gate.setProtocolFreezeUntil(uint32(block.timestamp + 1 days));

        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].guard == Guard.EXEMPT) continue;
            vm.prank(entries[i].caller);
            (bool ok, bytes memory returndata) = address(vault).call(entries[i].callData);
            assertFalse(ok, string.concat(entries[i].name, " must refuse under a guardian freeze"));
            assertEq(
                returndata,
                abi.encodeWithSelector(GateNotHealthy.selector, uint8(GateState.SCHEDULED_FREEZE), bytes32(0)),
                string.concat(entries[i].name, " blames the freeze")
            );
        }

        vm.warp(block.timestamp + 2 days);
        vault.checkpoint(); // the freeze expired with no further action
    }

    /// @notice `GREEN` and `REF_DIVERGED` both pass: section 2's table keeps placements and bonds alive under
    ///         `REF_DIVERGED`, anchored at NAV and priced at `q_floor` respectively.
    function test_step2_refDivergedDoesNotRefuse() public {
        gate.setDefaultState(GateState.REF_DIVERGED);
        vault.checkpoint();
        vm.prank(BONDS);
        vault.mintVesting(BONDS, 1e18);
        vm.prank(TIMELOCK);
        vault.setRedeemFeeBps(50);
    }

    /// @notice The bond entry points survive `DEGRADED` and `WATCHDOG`, which is the whole 24/7 bond decision.
    /// @dev A stale feed or a closed session must widen `h_session`, not close the market. The vault mirrors
    ///      `IOracleGate.checkBond` here rather than applying the stricter management policy, which would shut every
    ///      bond market on every weekend.
    function test_step2_bondEntryPointsSurviveDegradedAndWatchdog() public {
        stock.mint(BOB, 100e18);
        vm.prank(BOB);
        stock.approve(address(vault), type(uint256).max);

        GateState[2] memory tolerated = [GateState.DEGRADED, GateState.WATCHDOG];
        for (uint256 s; s < tolerated.length; ++s) {
            gate.setDefaultState(tolerated[s]);
            gate.setWatchdogTripped(tolerated[s] == GateState.WATCHDOG);

            uint256 claimBefore = claimOf(address(stock));
            uint256 supplyBefore = amps.totalSupply();

            vm.prank(BONDS);
            vault.depositBonded(1, address(stock), BOB, 1e18);
            vm.prank(BONDS);
            vault.mintVesting(BONDS, 1e18);

            assertEq(claimOf(address(stock)), claimBefore + 1e18, "the collateral settled");
            assertEq(amps.totalSupply(), supplyBefore + 1e18, "and the vest was minted");
        }

        // The management policy is unchanged by any of that: a checkpoint still refuses.
        gate.setDefaultState(GateState.DEGRADED);
        vm.expectRevert(abi.encodeWithSelector(GateNotHealthy.selector, uint8(GateState.DEGRADED), bytes32(0)));
        vault.checkpoint();
    }

    /// @notice `REF_DIVERGED` is tolerated by the bond policy too: the shell prices at `q_floor` instead.
    function test_step2_bondEntryPointsSurviveRefDiverged() public {
        gate.setDefaultState(GateState.REF_DIVERGED);
        vm.prank(BONDS);
        vault.mintVesting(BONDS, 1e18);
        assertEq(amps.balanceOf(BONDS), 1e18, "issued under REF_DIVERGED");
    }

    /// @notice The two non-structural exemptions refuse for their own reason in every state, never for the gate's.
    function test_step2_classifiedExemptionsRefuseForTheirOwnReason() public {
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);

        for (uint256 s; s < REFUSING_STATES.length; ++s) {
            gate.setDefaultState(REFUSING_STATES[s]);

            vm.prank(GUARDIAN);
            vm.expectRevert(IAmpsVault.MigrationPredicateNotMet.selector);
            vault.emergencyMigrate(STANDBY);

            vm.prank(ALICE);
            vm.expectRevert(abi.encodeWithSelector(NotPoolManager.selector, ALICE));
            vault.unlockCallback("");
        }
    }

    /// @notice And the evacuation actually completes with the gate in its worst state, which is the point of the
    ///         exemption: an issuer denylist and a tripped gate are the same incident.
    function test_step2_migrationCompletesWhileTheGateRefusesEverythingElse() public {
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);
        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stock.blockAccounts(blocked);

        gate.setDefaultState(GateState.WATCHDOG);
        gate.setProtocolFreezeUntil(uint32(block.timestamp + 7 days));

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);
        assertEq(amps.vault(), STANDBY, "the vault role moved while everything else was refused");
    }

    /// @notice A gate pointer that reverts is read as absent, not as a refusal.
    /// @dev Deliberate, and the opposite of the usual instinct. The vault is immutable and the gate is the one
    ///      pointer that can refuse every governance call; if a broken gate refused, nobody could ever call
    ///      `setPolicyPointer` to replace it, and the protocol would be bricked by a contract that holds no funds.
    ///      Failing open costs nothing an attacker could not already have with a `GREEN` gate.
    function test_aGateThatRevertsFailsOpenSoGovernanceCanReplaceIt() public {
        vm.etch(address(gate), address(new AlwaysReverts()).code);

        vault.checkpoint();

        MockOracleGate replacement = new MockOracleGate();
        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("oracleGate"), address(replacement));
        assertEq(vault.oracleGate(), address(replacement), "governance replaced the broken pointer");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Step 3 — the exemption succeeds in the worst world the protocol can be in
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every feed dead, the watchdog tripped, the guardian freezing and the timelock hostile:
    ///         `redeemProRata` still pays exactly pro rata.
    function test_step3_redeemSucceedsWithEverythingBroken() public {
        _breakTheWorld();

        uint256 supply = amps.totalSupply();
        uint256 wethNet =
            ((SEED_WETH * 500e18) / supply) * (Constants.BPS - Constants.REDEEM_FEE_BPS_DEFAULT) / Constants.BPS;
        uint256 usdgNet =
            ((SEED_USDG * 500e18) / supply) * (Constants.BPS - Constants.REDEEM_FEE_BPS_DEFAULT) / Constants.BPS;

        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        assertEq(weth.balanceOf(ALICE), wethNet, "exactly (1 - fee) x shares / T of the WETH");
        assertEq(usdg.balanceOf(ALICE), usdgNet, "exactly (1 - fee) x shares / T of the USDG");
        assertLt(amps.totalSupply(), supply - 500e18, "and the inventory burn still happened");
    }

    /// @notice The same, with the gate pointer itself replaced by a contract that reverts on every call.
    function test_step3_redeemSucceedsWithAGateThatReverts() public {
        _breakTheWorld();
        vm.etch(address(gate), address(new AlwaysReverts()).code);

        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        assertGt(weth.balanceOf(ALICE), 0, "the floor held");
    }

    /// @notice Every *other* path is refused in that same world, which is what makes the exemption meaningful.
    function test_step3_everythingElseIsRefusedInThatWorld() public {
        _breakTheWorld();
        vm.expectRevert(abi.encodeWithSelector(GateNotHealthy.selector, uint8(GateState.WATCHDOG), bytes32(0)));
        vault.checkpoint();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Step 4 — the storage-level proof
    // -------------------------------------------------------------------------------------------------------------

    /// @notice No storage of the gate, the feed registry, the registry or the market reference is read or written
    ///         during a redemption.
    function test_step4_redeemTouchesNoGateFeedOrRegistryStorage() public {
        vm.record();
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        _assertUntouched(address(gate), "oracleGate");
        _assertUntouched(address(feeds), "feedRegistry");
        _assertUntouched(address(registry), "registry");
        _assertUntouched(address(marketRef), "marketReference");

        // The control: the vault's own storage and the PoolManager's obviously were touched, so `vm.record` was on.
        (bytes32[] memory vaultReads,) = vm.accesses(address(vault));
        assertGt(vaultReads.length, 0, "the vault's own storage was read");
    }

    /// @notice `previewRedeem` is the same path with the same property: balances only, never a price.
    function test_step4_previewRedeemTouchesNothingEither() public {
        vm.record();
        vault.previewRedeem(500e18);

        _assertUntouched(address(gate), "oracleGate");
        _assertUntouched(address(feeds), "feedRegistry");
        _assertUntouched(address(registry), "registry");
        _assertUntouched(address(marketRef), "marketReference");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Every feed dead, the watchdog tripped, a guardian freeze running and the timelock replaced by a
    ///      contract that reverts on any call.
    function _breakTheWorld() private {
        gate.setDefaultState(GateState.WATCHDOG);
        gate.setWatchdogTripped(true);
        gate.setProtocolFreezeUntil(uint32(block.timestamp + 7 days));
        feeds.setReverting(true);
        vm.etch(TIMELOCK, address(new AlwaysReverts()).code);
    }

    /// @dev Asserts that neither a read nor a write of `target`'s storage was recorded.
    function _assertUntouched(address target, string memory label) private view {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(target);
        assertEq(reads.length, 0, string.concat(label, ": no storage read"));
        assertEq(writes.length, 0, string.concat(label, ": no storage write"));
    }

    /// @dev The whole external mutating surface, each entry called by the role that is allowed to call it, so that a
    ///      refusal can only come from the gate.
    function _buildSelectorTable() private {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(usdg)),
            currency1: Currency.wrap(address(weth)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        _add("redeemProRata", abi.encodeCall(IAmpsVault.redeemProRata, (1e18, ALICE)), ALICE, Guard.EXEMPT);
        _add("emergencyMigrate", abi.encodeCall(IAmpsVault.emergencyMigrate, (STANDBY)), GUARDIAN, Guard.EXEMPT);
        _add("unlockCallback", abi.encodeWithSignature("unlockCallback(bytes)", ""), ALICE, Guard.EXEMPT);

        _add("checkpoint", abi.encodeCall(IAmpsVault.checkpoint, ()), ALICE, Guard.MANAGEMENT);
        _add("touch", abi.encodeCall(IAmpsVault.touch, ()), ALICE, Guard.MANAGEMENT);
        _add(
            "depositBonded",
            abi.encodeCall(IAmpsVault.depositBonded, (1, address(stock), BOB, 1e18)),
            BONDS,
            Guard.BONDS
        );
        _add("mintVesting", abi.encodeCall(IAmpsVault.mintVesting, (BONDS, 1e18)), BONDS, Guard.BONDS);
        _add("genesis", abi.encodeCall(IAmpsVault.genesis, (genesisParams())), TIMELOCK, Guard.MANAGEMENT);
        _add(
            "initializePool",
            abi.encodeCall(IAmpsVault.initializePool, (key, 1 << 96)),
            address(registry),
            Guard.MANAGEMENT
        );
        _add("place", abi.encodeCall(IAmpsVault.place, (spokePool, true, 1e18)), ALICE, Guard.MANAGEMENT);
        _add("compound", abi.encodeCall(IAmpsVault.compound, (spokePool)), ALICE, Guard.MANAGEMENT);
        _add("rollout", abi.encodeCall(IAmpsVault.rollout, (1)), ALICE, Guard.MANAGEMENT);
        _add("deployBonded", abi.encodeCall(IAmpsVault.deployBonded, (1)), ALICE, Guard.MANAGEMENT);
        _add(
            "withdrawRetiredBids",
            abi.encodeWithSignature("withdrawRetiredBids(uint16)", 1),
            address(registry),
            Guard.MANAGEMENT
        );
        _add("setRedeemFeeBps", abi.encodeCall(IAmpsVault.setRedeemFeeBps, (50)), TIMELOCK, Guard.MANAGEMENT);
        _add("setBurnBps", abi.encodeCall(IAmpsVault.setBurnBps, (50)), TIMELOCK, Guard.MANAGEMENT);
        _add("setStakerBps", abi.encodeCall(IAmpsVault.setStakerBps, (50)), TIMELOCK, Guard.MANAGEMENT);
        _add("setRefUpRateBps", abi.encodeCall(IAmpsVault.setRefUpRateBps, (500)), TIMELOCK, Guard.MANAGEMENT);
        _add("setRefDivergenceBps", abi.encodeCall(IAmpsVault.setRefDivergenceBps, (500)), TIMELOCK, Guard.MANAGEMENT);
        _add("setTwapWindow", abi.encodeCall(IAmpsVault.setTwapWindow, (900)), TIMELOCK, Guard.MANAGEMENT);
        _add(
            "setLadderShape", abi.encodeCall(IAmpsVault.setLadderShape, (1.25e18, 10, 4, 4)), TIMELOCK, Guard.MANAGEMENT
        );
        _add("setRolloutParams", abi.encodeCall(IAmpsVault.setRolloutParams, (200, 3000)), TIMELOCK, Guard.MANAGEMENT);
        _add("setSpokeSeedBps", abi.encodeCall(IAmpsVault.setSpokeSeedBps, (100)), TIMELOCK, Guard.MANAGEMENT);
        _add(
            "setPolicyPointer",
            abi.encodeCall(IAmpsVault.setPolicyPointer, (bytes32("positionValuer"), address(valuer))),
            TIMELOCK,
            Guard.MANAGEMENT
        );
        _add("setStandbyVault", abi.encodeCall(IAmpsVault.setStandbyVault, (STANDBY)), TIMELOCK, Guard.MANAGEMENT);
        _add("setCreator", abi.encodeCall(IAmpsVault.setCreator, (BOB)), CREATOR, Guard.MANAGEMENT);
    }

    /// @dev Records one classified selector.
    function _add(string memory name, bytes memory callData, address caller, Guard guard) private {
        entries.push(Entry({name: name, callData: callData, caller: caller, guard: guard}));
    }
}
