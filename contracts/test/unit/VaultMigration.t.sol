// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {PoolClass} from "../../src/types/Types.sol";
import {AmpsVaultFixture, MockVaultRole} from "../mocks/AmpsVaultFixture.sol";
import {MockNonCanonicalToken} from "../mocks/MockNonCanonicalToken.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice A hook-shaped contract with no `setVault(address)` at all: an older deployment, or one whose flag-mined
///         address predates the handover. Its call must be ignored, not fatal.
contract HookWithoutSetVault {
    /// @notice So the migration's `hook()` read finds something with code.
    uint256 public version = 1;
}

/// @title VaultMigrationTest
/// @notice `docs/phase2-state-model.md` §8: everything about `emergencyMigrate` that a hostile Stock Token used to
///         be able to veto, plus the two roles the handover used to leave behind.
///
/// @dev The incident this path exists for is an *issuer* turning against the protocol, so every step of it has to
///      work while the constituents are hostile. Three ways they were not:
///
///        1. **The predicate decoded untrusted booleans.** `abi.decode(returndata, (bool))` reverts with a `Panic`
///           on any word that is not 0 or 1, in the *vault's* frame. A Stock Token answering `isBlocked` with the
///           word 2 — legal ABI, common in the wild — bricked `emergencyMigrate` outright.
///        2. **The evacuation's idle leg was a `safeTransfer`.** The token that blocks it is by construction the
///           token the guardian is fleeing, so one wei of it was a veto.
///        3. **The exit asserted a clean sweep.** Same veto, one line later.
///
///      And the handover moved four roles of six: `PoolRegistry` and the hook kept pointing at the evacuated
///      shell, so the standby could not open a pool and the hook still trusted a vault holding nothing.
contract VaultMigrationTest is AmpsVaultFixture {
    MockVaultRole private hookRole;

    function setUp() public {
        deployVaultWorld();
        hookRole = new MockVaultRole(address(vault));
        registry.setHook(address(hookRole));
        runGenesis();
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The predicate, against a token that answers in non-canonical booleans
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A constituent whose `isBlocked` returns the word 2 reads as blocked, and the migration goes through.
    ///         Under `abi.decode(..., (bool))` this was a `Panic` in the vault's frame and the evacuation was dead.
    function test_theMigrationPredicateSurvivesANonCanonicalBool() public {
        MockNonCanonicalToken hostile = _registerNonCanonicalConstituent();
        hostile.setBoolAnswer(2);

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);
        assertEq(amps.vault(), STANDBY, "the evacuation completed on a non-canonical `true`");
    }

    /// @notice And the same word coming back from the *self-transfer probe* is a success, not a `Panic`: with
    ///         `isBlocked` answering a canonical `false`, a token that transfers and then says `2` is healthy, so
    ///         one such constituent alone must not meet the predicate.
    function test_aNonCanonicalTransferAnswerIsReadAsSuccess() public {
        MockNonCanonicalToken hostile = _registerNonCanonicalConstituent();
        hostile.setBoolAnswer(0); // `isBlocked` false; `transfer` then also answers 0, i.e. an explicit failure.

        // An explicit `false` from `transfer` is a failed probe, and one failed probe is not the pattern.
        vm.prank(GUARDIAN);
        vm.expectRevert(IAmpsVault.MigrationPredicateNotMet.selector);
        vault.emergencyMigrate(STANDBY);

        // The second failed probe is: pausing a real Stock Token is the other half of the pattern.
        stock.pause();
        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);
        assertEq(amps.vault(), STANDBY, "two failed probes met the predicate");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The evacuation, against a token that refuses to move
    // -------------------------------------------------------------------------------------------------------------

    /// @notice One wei of a blocked token sitting idle on the vault no longer vetoes the evacuation. It stays
    ///         behind — the issuer, not the protocol, is what makes it unmovable — and everything else leaves.
    function test_aBlockedTokenWithAnIdleWeiDoesNotStopTheEvacuation() public {
        // Idle first, denylist second: the mint itself would be refused the other way round.
        stock.mint(address(vault), 1);
        assertEq(stock.balanceOf(address(vault)), 1, "the vault holds one unmovable wei");

        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stock.blockAccounts(blocked);

        uint256 wethClaim = claimOf(address(weth));
        uint256 pol = amps.balanceOf(address(vault));

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        assertEq(stock.balanceOf(address(vault)), 1, "the wei the issuer froze is still frozen, on the old shell");
        assertEq(_standbyClaim(address(weth)), wethClaim, "and every claim reached the standby anyway");
        assertEq(amps.balanceOf(STANDBY), pol, "POL inventory included");
        assertEq(amps.vault(), STANDBY, "and the roles moved");
    }

    /// @notice A paused constituent is the same story with a different cause: the transfer reverts for everybody
    ///         rather than for the vault, and the evacuation still completes.
    function test_aPausedTokenWithAnIdleWeiDoesNotStopTheEvacuation() public {
        stock.mint(address(vault), 3);
        stock.pause();
        stock2.pause();

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        assertEq(amps.vault(), STANDBY, "the evacuation completed with the token paused");
        assertEq(stock.balanceOf(address(vault)), 3, "and the paused balance stayed where the issuer pinned it");
    }

    /// @notice A constituent whose `balanceOf` reverts is skipped rather than fatal, on both the predicate's probe
    ///         and the evacuation's idle leg.
    function test_aTokenWhoseBalanceOfRevertsDoesNotStopTheEvacuation() public {
        stock.setBalanceOfReverts(true);
        stock2.pause();

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);
        assertEq(amps.vault(), STANDBY, "the evacuation completed with a constituent's view unavailable");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The handover: all six roles
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every contract that names a vault is handed on in the same transaction, the registry and the hook
    ///         included. Before this the standby inherited the estate but could never open a pool with it.
    function test_theHandoverMovesAllSixRoles() public {
        stock.pause();
        stock2.pause();

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        assertEq(amps.vault(), STANDBY, "AMPS minting");
        assertEq(bondsRole.vault(), STANDBY, "AmpsBonds");
        assertEq(stakingRole.vault(), STANDBY, "AmpsStaking");
        assertEq(potRole.vault(), STANDBY, "BountyPot");
        assertEq(registry.vault(), STANDBY, "PoolRegistry");
        assertEq(hookRole.vault(), STANDBY, "AmpsHook");
    }

    /// @notice The hook leg is best effort: a hook with no `setVault(address)` cannot trap the estate.
    function test_aHookWithoutTheSetterDoesNotBlockTheEvacuation() public {
        registry.setHook(address(new HookWithoutSetVault()));
        stock.pause();
        stock2.pause();

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        assertEq(amps.vault(), STANDBY, "the other five roles still moved");
        assertEq(registry.vault(), STANDBY, "the registry included");
    }

    /// @notice And so is a registry that names no hook at all.
    function test_aRegistryWithNoHookDoesNotBlockTheEvacuation() public {
        registry.setHook(address(0));
        stock.pause();
        stock2.pause();

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);
        assertEq(registry.vault(), STANDBY, "the registry moved and the missing hook was skipped");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Registers a {MockNonCanonicalToken} as a third constituent and gives the vault a wei of it, so the
    ///      predicate's probe has a balance to move.
    function _registerNonCanonicalConstituent() private returns (MockNonCanonicalToken hostile) {
        hostile = new MockNonCanonicalToken();
        registry.addConstituentAndPool(
            address(hostile), address(0xFEED3), PoolId.wrap(keccak256("AMPS/NONCANON")), PoolClass.SPOKE, 60, 3000
        );
        hostile.mint(address(vault), 1);
    }

    /// @dev The standby's ERC-6909 claim balance for `token`.
    function _standbyClaim(address token) private view returns (uint256) {
        return poolManager.balanceOf(STANDBY, uint256(uint160(token)));
    }
}
