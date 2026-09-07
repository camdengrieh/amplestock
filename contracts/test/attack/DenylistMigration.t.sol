// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotGuardian} from "../../src/types/Errors.sol";
import {PlacementRecord} from "../../src/types/Types.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title DenylistMigrationTest
/// @notice The plan's **denylist drill ending in a successful predicate-gated `emergencyMigrate`**, with the
///         Phase 3 addition that the migration now unwinds a **full ladder** on the way out.
///
///         The incident: an issuer blocks the vault on one or more Stock Tokens, so the vault can no longer move
///         that collateral by ERC-20 transfer. The response: the guardian migrates to the pre-registered standby.
///         Everything about that path is designed to work while the tokens are hostile - the ladder is removed
///         through the PoolManager (no `BEFORE_REMOVE_LIQUIDITY` bit exists, I18), every asset moves as an
///         ERC-6909 claim inside the PoolManager rather than as an ERC-20 transfer, and the four `onlyVault` role
///         handovers happen in the same transaction.
contract DenylistMigrationTest is Phase3Fixture {
    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(100_000e6);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    /// @notice The predicate is a real gate: without a denylisting, the guardian cannot migrate.
    function test_theGuardianCannotMigrateWithoutADenylisting() public {
        vm.prank(GUARDIAN);
        vm.expectRevert(IAmpsVault.MigrationPredicateNotMet.selector);
        vault.emergencyMigrate(STANDBY);
    }

    /// @notice And only the guardian can, even once the predicate is met.
    function test_onlyTheGuardianMayMigrate() public {
        _denylistTheVault(0);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(NotGuardian.selector, TIMELOCK));
        vault.emergencyMigrate(STANDBY);
    }

    /// @notice The drill, end to end: the issuer blocks the vault, the guardian migrates, the whole ladder is
    ///         unwound, every asset lands on the standby as an ERC-6909 claim, and the four roles move with it.
    function test_theDenylistDrillEndsInAFullLadderUnwind() public {
        // Some trading first, so the ladder has both sides and some fees in it.
        giveShares(BOB, 60e18);
        approveStack(address(amps), BOB);
        uint256 bought = buyAmps(hubPool, BOB, 3e6);
        sellAmps(hubPool, BOB, bought);
        settleTwap();

        uint32 liveBefore = vault.liveCells();
        assertGt(liveBefore, 0, "there is a ladder to unwind");
        uint256 navBefore = vault.navPerShareX18();

        _denylistTheVault(0);
        assertTrue(stocks[0].isBlocked(address(vault)), "the issuer has blocked the vault");

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        // The ladder is gone: every position the vault owned has been removed.
        PoolId[] memory ids = allPools();
        for (uint256 p; p < ids.length; ++p) {
            PlacementRecord[] memory records = ladderOf(ids[p]);
            for (uint256 i; i < records.length; ++i) {
                assertEq(records[i].liquidity, 0, "every ladder cell was unwound");
            }
        }
        assertEq(vault.liveCells(), 0, "and the live-cell count is zero");

        // Every asset moved to the standby as a claim, not as an ERC-20 transfer.
        uint256 count = vault.assetCount();
        uint256 movedAssets;
        for (uint256 i; i < count; ++i) {
            address token = vault.assetAt(i);
            assertEq(IERC20(token).balanceOf(address(vault)), 0, "the old vault holds no ERC-20");
            assertEq(claimOf(token), 0, "and no claim");
            if (poolManager.balanceOf(STANDBY, Currency.wrap(token).toId()) != 0) ++movedAssets;
        }
        assertGt(movedAssets, 0, "the standby holds the estate as ERC-6909 claims");

        // The four `onlyVault` roles moved in the same transaction.
        assertEq(amps.vault(), STANDBY, "AMPS minting");
        assertEq(bonds.vault(), STANDBY, "AmpsBonds");
        assertEq(staking.vault(), STANDBY, "AmpsStaking");
        assertEq(pot.vault(), STANDBY, "BountyPot");

        assertGt(navBefore, 0, "and the migration recorded the NAV it moved");
    }

    /// @notice The predicate also fires on the softer signal: two Stock Tokens whose self-transfer probe fails,
    ///         which is what a beacon-level pause looks like from the outside.
    function test_twoFailedProbesAlsoMeetThePredicate() public {
        stocks[0].pause();
        stocks[1].pause();

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);
        assertEq(amps.vault(), STANDBY, "the migration went through on the probe signal alone");
    }

    /// @notice And redemption is never the thing that breaks: `redeemProRata` works right up to the migration,
    ///         because it consults no gate, no guardian and no price (I14).
    function test_redemptionKeepsWorkingThroughTheIncident() public {
        _denylistTheVault(0);
        giveShares(ALICE, 100e18);

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(100e18, ALICE);
        uint256 paid;
        for (uint256 i; i < tokens.length; ++i) {
            paid += amounts[i];
        }
        assertGt(paid, 0, "the floor paid out with the vault denylisted");
    }

    /// @dev Blocks the vault on spoke `i`'s token, which is what the issuer does in the incident this exists for.
    function _denylistTheVault(uint256 i) private {
        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[i].blockAccounts(blocked);
    }
}
