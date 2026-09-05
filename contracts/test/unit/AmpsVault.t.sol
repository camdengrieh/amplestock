// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {IFeedRegistry} from "../../src/interfaces/IFeedRegistry.sol";
import {Constants} from "../../src/types/Constants.sol";
import {
    AlreadyInitialized,
    GateNotHealthy,
    LengthMismatch,
    NotBonds,
    NotCreator,
    NotGuardian,
    NotPoolManager,
    NotRegistry,
    NotTimelock,
    OutOfBand,
    ZeroAddress,
    ZeroAmount
} from "../../src/types/Errors.sol";
import {Checkpoint, GateState} from "../../src/types/Types.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {AmpsVaultFixture} from "../mocks/AmpsVaultFixture.sol";
import {MockOracleGate} from "../mocks/MockOracleGate.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title AmpsVaultTest
/// @notice The Phase 2 vault's behavioural suite: genesis, NAV, the reference price, pro-rata redemption, the bond
///         entry points, the governed bands, the creator handle and the predicate-gated migration.
/// @dev    Section references are to `docs/phase2-state-model.md`; invariant references (I3, I5, ...) are to the
///         plan's invariant suite.
contract AmpsVaultTest is AmpsVaultFixture {
    function setUp() public {
        deployVaultWorld();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Genesis (section 3)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The launch vector: $5,000 of seed against 5,000 AMPS is $1.00 of backing per AMPS.
    function test_genesis_navPerShareIsOneDollar() public {
        runGenesis();

        assertEq(vault.totalAssetsUsd18(), 5000e18, "A == $5,000");
        assertEq(amps.totalSupply(), Constants.S0, "T == S0");
        // (A + 1) * 1e18 / (T + VIRTUAL_SHARES) rounds down, so NAV/share is $1.00 less one wei by construction.
        assertEq(vault.navPerShareX18(), 999_999_999_999_999_999, "NAV/share");
        assertApproxEqAbs(vault.navPerShareX18(), 1e18, 1, "NAV/share is $1.00 to the wei");
        assertEq(vault.previewNavPerShareX18(), vault.navPerShareX18(), "live NAV matches the checkpoint");
    }

    /// @notice The allocation lands where the launch table says: 250 AMPS vesting, 4,750 AMPS of POL in the vault.
    function test_genesis_allocation() public {
        runGenesis();

        assertEq(amps.balanceOf(TEAM_WALLET), Constants.TEAM_SHARES, "team tranche");
        assertEq(amps.balanceOf(address(vault)), Constants.POL_SHARES, "POL tranche");
        assertEq(amps.balanceOf(TEAM_WALLET) + amps.balanceOf(address(vault)), Constants.S0, "the whole of S0");
        assertEq(vault.creator(), CREATOR, "creator");
        assertEq(vault.genesisTimestamp(), uint32(block.timestamp), "genesis timestamp");
        assertTrue(vault.initialized(), "latch");
    }

    /// @notice The seed never rests on the vault: it goes straight into the PoolManager as ERC-6909 claims (I12).
    function test_genesis_seedBecomesClaims() public {
        runGenesis();

        assertEq(claimOf(address(weth)), SEED_WETH, "WETH claim");
        assertEq(claimOf(address(usdg)), SEED_USDG, "USDG claim");
        assertEq(weth.balanceOf(address(vault)), 0, "no idle WETH");
        assertEq(usdg.balanceOf(address(vault)), 0, "no idle USDG");
        assertEq(weth.balanceOf(TIMELOCK), 0, "the payer's seed is gone");
    }

    /// @notice The registry's world becomes the vault's asset list, and AMPS is never in it (I5).
    function test_genesis_registersAssetsButNeverAmps() public {
        runGenesis();

        assertEq(vault.assetCount(), 4, "two constituents plus WETH and USDG");
        assertTrue(vault.isAsset(address(weth)), "WETH");
        assertTrue(vault.isAsset(address(usdg)), "USDG");
        assertTrue(vault.isAsset(address(stock)), "constituent");
        assertFalse(vault.isAsset(address(amps)), "AMPS is never an asset");
    }

    /// @notice The latch is one-way.
    function test_genesis_revertsOnSecondCall() public {
        runGenesis();
        vm.prank(TIMELOCK);
        vm.expectRevert(IAmpsVault.GenesisAlreadyDone.selector);
        vault.genesis(genesisParams());
    }

    /// @notice Only the timelock may open the protocol.
    function test_genesis_onlyTimelock() public {
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vm.prank(ALICE);
        vault.genesis(genesisParams());
    }

    /// @notice The allocation must be exactly the two constants, and they must sum to `S0`.
    function test_genesis_rejectsWrongAllocation() public {
        IAmpsVault.GenesisParams memory params = genesisParams();
        params.teamShares = Constants.TEAM_SHARES + 1;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAmpsVault.InvalidGenesisAllocation.selector, params.teamShares, params.polShares, Constants.S0
            )
        );
        vault.genesis(params);
    }

    /// @notice Parallel arrays must be parallel.
    function test_genesis_rejectsUnbalancedSeedArrays() public {
        IAmpsVault.GenesisParams memory params = genesisParams();
        params.seedAmounts = new uint256[](1);
        vm.prank(TIMELOCK);
        vm.expectRevert(LengthMismatch.selector);
        vault.genesis(params);
    }

    /// @notice `genesis` freezes the wiring: the four set-once pointers refuse afterwards, the upgradeable ones do not.
    function test_genesis_freezesWiring() public {
        runGenesis();

        vm.startPrank(TIMELOCK);
        vm.expectRevert(AlreadyInitialized.selector);
        vault.setPolicyPointer(bytes32("registry"), address(0xBEEF));
        vm.expectRevert(AlreadyInitialized.selector);
        vault.setPolicyPointer(bytes32("bonds"), address(0xBEEF));
        vm.expectRevert(AlreadyInitialized.selector);
        vault.setPolicyPointer(bytes32("staking"), address(0xBEEF));
        vm.expectRevert(AlreadyInitialized.selector);
        vault.setPolicyPointer(bytes32("bountyPot"), address(0xBEEF));

        // Pointer-upgradeable slots stay open; `marketReference` is re-pointed once, to the hook, in Phase 3.
        vault.setPolicyPointer(bytes32("oracleGate"), address(gate));
        vault.setPolicyPointer(bytes32("feedRegistry"), address(feeds));
        vault.setPolicyPointer(bytes32("positionValuer"), address(valuer));
        vault.setPolicyPointer(bytes32("marketReference"), address(marketRef));
        vault.setPolicyPointer(bytes32("ladderPolicy"), address(0x1ADDE5));
        vault.setPolicyPointer(bytes32("rolloutPolicy"), address(0x2011));
        vm.stopPrank();
    }

    /// @notice An unknown pointer name is rejected rather than silently ignored.
    function test_setPolicyPointer_rejectsUnknownSlot() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(AmpsVault.UnknownPointerSlot.selector, bytes32("nope")));
        vault.setPolicyPointer(bytes32("nope"), address(0xBEEF));
    }

    // -------------------------------------------------------------------------------------------------------------
    // NAV (section 4)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `A` counts ERC-6909 claims and idle ERC-20 alike, each valued through the feed and rounded down.
    function test_nav_countsClaimsAndIdleBalances() public {
        runGenesis();
        uint256 before = vault.totalAssetsUsd18();

        // An idle ERC-20 donation is backing until the next `sweepClean` folds it into claims.
        stock.mint(address(vault), 3e18);
        assertEq(vault.totalAssetsUsd18(), before + 300e18, "3 stock at $100");

        vault.checkpoint();
        assertEq(stock.balanceOf(address(vault)), 0, "sweepClean absorbed the donation");
        assertEq(claimOf(address(stock)), 3e18, "it became a claim, still worth $300");
        assertEq(vault.totalAssetsUsd18(), before + 300e18, "and `A` is unchanged by the move");
    }

    /// @notice Every AMPS leg is worth zero (I5): AMPS sent to the vault raises inventory, never `A`.
    function test_nav_valuesEveryAmpsLegAtZero() public {
        runGenesis();
        uint256 before = vault.totalAssetsUsd18();

        giveShares(ALICE, 100e18);
        vm.prank(ALICE);
        amps.transfer(address(vault), 100e18);

        assertEq(vault.totalAssetsUsd18(), before, "A is blind to AMPS");
        assertEq(vault.inventoryAmps(), Constants.POL_SHARES, "but inventory sees it");
    }

    /// @notice The denominator is `totalSupply` and nothing else (I6): protocol inventory dilutes like any share.
    function test_nav_denominatorIsTotalSupply() public {
        runGenesis();
        uint256 a = vault.totalAssetsUsd18();
        assertEq(
            vault.previewNavPerShareX18(),
            ((a + 1) * 1e18) / (amps.totalSupply() + Constants.VIRTUAL_SHARES),
            "(A + 1) * 1e18 / (T + VIRTUAL_SHARES)"
        );
    }

    /// @notice A balance the protocol cannot price refuses the checkpoint rather than being valued at zero.
    function test_nav_revertsOnUnpriceableBalance() public {
        runGenesis();
        feeds.clearAnswer(address(weth));
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.FeedNotSet.selector, address(weth)));
        vault.checkpoint();
    }

    /// @notice An asset with no answer and no balance is skipped: an unpriced constituent cannot brick the upkeep.
    function test_nav_skipsUnpricedEmptyAsset() public {
        runGenesis();
        feeds.clearAnswer(address(stock));
        vault.checkpoint();
        assertEq(vault.totalAssetsUsd18(), 5000e18, "unchanged");
    }

    /// @notice `checkpoint` is permissionless, pokes the gate and stamps the block.
    function test_checkpoint_isPermissionlessAndStamps() public {
        runGenesis();
        uint256 pokesBefore = gate.pokeCount();

        vm.roll(block.number + 5);
        vm.warp(block.timestamp + 60);
        vm.prank(ALICE);
        Checkpoint memory snapshot = vault.checkpoint();

        assertEq(gate.pokeCount(), pokesBefore + 1, "layer A stamped");
        assertEq(snapshot.timestamp, uint32(block.timestamp), "timestamp");
        assertEq(snapshot.blockNumber, uint32(block.number), "block");
        assertEq(vault.checkpointData().navPerShareX18, snapshot.navPerShareX18, "read back");
    }

    /// @notice `touch` stamps layer A and deliberately does not refresh the checkpoint's staleness bound.
    function test_touch_stampsWithoutRewritingTheCheckpoint() public {
        runGenesis();
        uint32 stamped = vault.checkpointData().timestamp;
        uint256 pokesBefore = gate.pokeCount();

        vm.warp(block.timestamp + 600);
        vm.prank(ALICE);
        vault.touch();

        assertEq(gate.pokeCount(), pokesBefore + 1, "poked");
        assertEq(vault.checkpointData().timestamp, stamped, "checkpoint age untouched");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The reference price (section 5)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice With no observation coverage the reference falls back to NAV and records `P_mkt` as zero.
    function test_pRef_coverageOverrideRecordsZeroMarketPrice() public {
        runGenesis();
        assertEq(vault.pMktX18(), 0, "no coverage, no market price");
        assertEq(vault.pRefX18(), vault.navPerShareX18(), "reference anchored at NAV");
    }

    /// @notice Upward moves are rate-limited to `refUpRateBps` per hour.
    function test_pRef_upIsRateLimited() public {
        runGenesis();
        uint256 pRefPrev = vault.pRefX18();

        uint256 pMkt = seedHubPrice(1.5e18);
        vm.warp(block.timestamp + 1800); // half an hour at 1,000 bp/h == +5%
        vault.checkpoint();

        uint256 cap = pRefPrev + (pRefPrev * (uint256(Constants.REF_UP_RATE_BPS_DEFAULT) * 1800)) / (3600 * 10_000);
        assertEq(vault.pMktX18(), pMkt, "market price recorded in full");
        assertEq(vault.pRefX18(), cap, "reference bound by the hourly cap");
        assertLt(vault.pRefX18(), pMkt, "and strictly below the market");
    }

    /// @notice Downward moves are immediate and unlimited.
    function test_pRef_downIsImmediate() public {
        runGenesis();
        seedHubPrice(1.5e18);
        vm.warp(block.timestamp + 1800);
        vault.checkpoint();
        uint256 raised = vault.pRefX18();
        assertGt(raised, vault.navPerShareX18(), "the reference sits above NAV");

        uint256 pMkt = seedHubPrice(1.02e18);
        vault.checkpoint();

        assertEq(vault.pRefX18(), pMkt, "straight to the market price, in one block");
        assertLt(vault.pRefX18(), raised, "downward, with no rate limit");
    }

    /// @notice NAV is the floor, always (I24).
    function test_pRef_navIsTheFloor() public {
        runGenesis();
        seedHubPrice(0.5e18);
        vm.warp(block.timestamp + 3600);
        vault.checkpoint();

        assertEq(vault.pRefX18(), vault.navPerShareX18(), "floored at NAV");
        assertGt(vault.pMktX18(), 0, "even though the market price is live and lower");
        assertLt(vault.pMktX18(), vault.pRefX18(), "P_mkt below P_ref is exactly what the floor is for");
    }

    /// @notice `REF_DIVERGED` on the hub pins the reference to NAV outright.
    function test_pRef_gateRefDivergedOverride() public {
        runGenesis();
        seedHubPrice(1.5e18);
        vm.warp(block.timestamp + 3600);

        MockOracleGate.PoolState memory poolState;
        poolState.set = true;
        poolState.state = GateState.REF_DIVERGED;
        gate.setPoolState(hubPool, poolState);

        vault.checkpoint();
        assertEq(vault.pRefX18(), vault.navPerShareX18(), "pinned to NAV");
        assertGt(vault.pMktX18(), 0, "the market price is still disclosed");
    }

    /// @notice A tripped layer-A watchdog does the same.
    function test_pRef_watchdogOverride() public {
        runGenesis();
        seedHubPrice(1.5e18);
        vm.warp(block.timestamp + 3600);
        gate.setWatchdogTripped(true);

        vault.checkpoint();
        assertEq(vault.pRefX18(), vault.navPerShareX18(), "pinned to NAV");
    }

    /// @notice Layer F: the hub and `AMPS/WETH x ETH/USD` disagreeing beyond `refDivergenceBps` pins the reference.
    function test_pRef_crossCheckDivergenceOverride() public {
        runGenesis();
        seedHubPrice(1.5e18);
        seedWethPrice(1.9e18); // 27% apart, far outside the 500 bp band
        vm.warp(block.timestamp + 3600);

        vault.checkpoint();
        assertEq(vault.pRefX18(), vault.navPerShareX18(), "pinned to NAV");
    }

    /// @notice A cross-check that agrees does not override.
    function test_pRef_crossCheckInsideBandDoesNotOverride() public {
        runGenesis();
        seedHubPrice(1.5e18);
        seedWethPrice(1.51e18); // well inside 500 bp
        vm.warp(block.timestamp + 3600);

        vault.checkpoint();
        assertGt(vault.pRefX18(), vault.navPerShareX18(), "the reference is allowed to rise");
    }

    /// @notice The premium is disclosure only, and is zero while the reference sits on the NAV floor.
    function test_premium() public {
        runGenesis();
        assertEq(vault.premiumX18(), 0, "no premium at genesis");

        seedHubPrice(1.5e18);
        vm.warp(block.timestamp + 3600);
        vault.checkpoint();

        uint256 expected = ((vault.pRefX18() - vault.navPerShareX18()) * 1e18) / vault.navPerShareX18();
        assertEq(vault.premiumX18(), expected, "P_ref / NAV - 1");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Redemption (section 3, I23)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The exact I23 arithmetic: `floor(b x shares / T) x (BPS - fee) / BPS` of every non-AMPS asset.
    function test_redeem_paysExactlyProRataNetOfFee() public {
        runGenesis();
        giveShares(ALICE, 500e18);

        uint256 supply = amps.totalSupply();
        uint256 wethGross = (SEED_WETH * 500e18) / supply;
        uint256 usdgGross = (SEED_USDG * 500e18) / supply;
        uint256 wethNet = (wethGross * (Constants.BPS - Constants.REDEEM_FEE_BPS_DEFAULT)) / Constants.BPS;
        uint256 usdgNet = (usdgGross * (Constants.BPS - Constants.REDEEM_FEE_BPS_DEFAULT)) / Constants.BPS;

        (address[] memory previewTokens, uint256[] memory previewAmounts,) = vault.previewRedeem(500e18);

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        assertEq(tokens.length, 4, "every registered asset appears");
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i], previewTokens[i], "preview token order");
            assertEq(amounts[i], previewAmounts[i], "preview amount");
        }
        assertEq(weth.balanceOf(ALICE), wethNet, "WETH paid");
        assertEq(usdg.balanceOf(ALICE), usdgNet, "USDG paid");
        assertEq(heldBalance(address(weth)), SEED_WETH - wethNet, "the withheld fee stays as backing");
        assertEq(heldBalance(address(usdg)), SEED_USDG - usdgNet, "same for USDG");
    }

    /// @notice The released inventory is burned too, so `T` falls by more than `shares`.
    function test_redeem_burnsReleasedInventory() public {
        runGenesis();
        giveShares(ALICE, 500e18);

        uint256 supply = amps.totalSupply();
        uint256 inventory = amps.balanceOf(address(vault));
        uint256 expectedBurn = (inventory * 500e18) / supply;

        (,, uint256 previewBurn) = vault.previewRedeem(500e18);
        assertEq(previewBurn, expectedBurn, "preview agrees");

        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        assertEq(amps.totalSupply(), supply - 500e18 - expectedBurn, "T falls by shares plus inventory");
        assertLt(amps.totalSupply(), supply - 500e18, "strictly more than the shares burned");
        assertEq(amps.balanceOf(address(vault)), inventory - expectedBurn, "inventory shrank pro rata");
    }

    /// @notice Redemption is accretive to everyone who did not redeem (I8).
    function test_redeem_raisesNavPerShare() public {
        runGenesis();
        giveShares(ALICE, 500e18);
        uint256 navBefore = vault.previewNavPerShareX18();

        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        assertGt(vault.previewNavPerShareX18(), navBefore, "NAV/share rose");
    }

    /// @notice Payment comes out of the ERC-6909 claims first and out of an idle balance only for the remainder.
    /// @dev Asserted on the PoolManager's own ERC-6909 burn event, because `sweepClean` folds whatever idle balance
    ///      survives the payout back into claims at exit: the end state alone cannot tell the two orders apart.
    function test_redeem_takesClaimsBeforeIdle() public {
        runGenesis();
        giveShares(ALICE, 1000e18);

        // A claim smaller than the payout, so the remainder has to come from the idle balance.
        stock.mint(address(this), 0.1e18);
        bondDeposit(address(stock), address(this), 0.1e18);
        stock.mint(address(vault), 2e18);

        uint256 supply = amps.totalSupply();
        uint256 net = ((((0.1e18 + 2e18) * 1000e18) / supply) * (Constants.BPS - Constants.REDEEM_FEE_BPS_DEFAULT))
            / Constants.BPS;

        vm.recordLogs();
        vm.prank(ALICE);
        vault.redeemProRata(1000e18, ALICE);

        assertEq(stock.balanceOf(ALICE), net, "the redeemer got the whole net amount");
        assertEq(_burnedClaims(address(stock)), 0.1e18, "the claim was drained first, to the last wei");
        assertEq(stock.balanceOf(address(vault)), 0, "and the idle remainder was swept back into claims");
    }

    /// @notice Zero-value calls fail loudly rather than silently no-op.
    function test_redeem_rejectsZeroArguments() public {
        runGenesis();
        giveShares(ALICE, 1e18);

        vm.prank(ALICE);
        vm.expectRevert(ZeroAmount.selector);
        vault.redeemProRata(0, ALICE);

        vm.prank(ALICE);
        vm.expectRevert(ZeroAddress.selector);
        vault.redeemProRata(1e18, address(0));
    }

    /// @notice Redeeming more than the caller holds fails in the token, before anything moves.
    function test_redeem_cannotRedeemMoreThanHeld() public {
        runGenesis();
        giveShares(ALICE, 1e18);
        vm.prank(ALICE);
        vm.expectRevert();
        vault.redeemProRata(2e18, ALICE);
    }

    /// @notice Redeeming everything drains the vault to dust and leaves NAV/share finite (I22).
    function test_redeem_fullSupplyLeavesNavFinite() public {
        runGenesis();
        giveShares(ALICE, Constants.POL_SHARES);
        vm.prank(TEAM_WALLET);
        amps.transfer(ALICE, Constants.TEAM_SHARES);

        vm.prank(ALICE);
        vault.redeemProRata(Constants.S0, ALICE);

        assertEq(amps.totalSupply(), 0, "every share is gone");
        assertGt(vault.previewNavPerShareX18(), 0, "NAV/share is still finite and non-zero");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Bonds (section 3)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Bonded collateral goes from the bonder straight into the PoolManager (I12).
    function test_depositBonded_settlesIntoClaims() public {
        runGenesis();
        uint256 before = claimOf(address(stock));
        stock.mint(BOB, 5e18);

        vm.prank(BOB);
        stock.approve(address(vault), type(uint256).max);
        vm.prank(BONDS);
        uint256 settled = vault.depositBonded(1, address(stock), BOB, 5e18);

        assertEq(settled, 5e18, "settled in full");
        assertEq(claimOf(address(stock)), before + 5e18, "as a claim");
        assertEq(stock.balanceOf(address(vault)), 0, "never on the vault");
        assertEq(vault.totalAssetsUsd18(), 5000e18 + 500e18, "and it is backing at once");
    }

    /// @notice Only the bonds shell may deposit or mint.
    function test_bondEntryPoints_onlyBonds() public {
        runGenesis();
        vm.expectRevert(abi.encodeWithSelector(NotBonds.selector, ALICE));
        vm.prank(ALICE);
        vault.depositBonded(1, address(stock), ALICE, 1e18);

        vm.expectRevert(abi.encodeWithSelector(NotBonds.selector, ALICE));
        vm.prank(ALICE);
        vault.mintVesting(BONDS, 1e18);
    }

    /// @notice `mintVesting` is the only mint path after the latch, and it can only mint to `AmpsBonds` (I10, I30).
    function test_mintVesting_isTheOnlyMintPath() public {
        runGenesis();
        uint256 supply = amps.totalSupply();

        vm.prank(BONDS);
        vault.mintVesting(BONDS, 10e18);

        assertEq(amps.totalSupply(), supply + 10e18, "T rose at purchase, not at claim");
        assertEq(amps.balanceOf(BONDS), 10e18, "held by the bonds shell");

        vm.prank(BONDS);
        vm.expectRevert(ZeroAddress.selector);
        vault.mintVesting(ALICE, 1e18);
    }

    /// @notice A bond raises `A` and `T` together and never lowers NAV/share (the vault half of I27).
    function test_depositBonded_isNotDilutive() public {
        runGenesis();
        uint256 navBefore = vault.previewNavPerShareX18();
        stock.mint(BOB, 10e18);
        bondDeposit(address(stock), BOB, 10e18);
        assertGt(vault.previewNavPerShareX18(), navBefore, "NAV/share rose with the collateral");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Access control and Phase 3 stubs (section 2)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Only the registry may initialise a pool or withdraw retired bids.
    function test_registryOnlyEntryPoints() public {
        runGenesis();
        vm.expectRevert(abi.encodeWithSelector(NotRegistry.selector, ALICE));
        vm.prank(ALICE);
        vault.withdrawRetiredBids(1);

        vm.prank(address(registry));
        vm.expectRevert(AmpsVault.Phase3NotImplemented.selector);
        vault.withdrawRetiredBids(1);
    }

    /// @notice The four Phase 3 keeper entry points are in the ABI and refuse until the hook exists.
    function test_phase3EntryPointsRevert() public {
        runGenesis();
        vm.expectRevert(AmpsVault.Phase3NotImplemented.selector);
        vault.place(spokePool, true, 1e18);
        vm.expectRevert(AmpsVault.Phase3NotImplemented.selector);
        vault.compound(spokePool);
        vm.expectRevert(AmpsVault.Phase3NotImplemented.selector);
        vault.rollout(1);
        vm.expectRevert(AmpsVault.Phase3NotImplemented.selector);
        vault.deployBonded(1);
    }

    /// @notice The unlock callback belongs to the PoolManager alone.
    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(abi.encodeWithSelector(NotPoolManager.selector, ALICE));
        vm.prank(ALICE);
        vault.unlockCallback("");
    }

    /// @notice An unsolicited unlock cannot drive the callback: without a discriminator there is nothing to do.
    function test_unlockCallback_rejectsUnknownAction() public {
        vm.prank(address(poolManager));
        vm.expectRevert(AmpsVault.UnknownUnlockAction.selector);
        vault.unlockCallback("");
    }

    /// @notice Only the current creator may reassign the creator fee, and governance cannot.
    function test_setCreator() public {
        runGenesis();
        vm.expectRevert(abi.encodeWithSelector(NotCreator.selector, TIMELOCK));
        vm.prank(TIMELOCK);
        vault.setCreator(BOB);

        vm.prank(CREATOR);
        vault.setCreator(BOB);
        assertEq(vault.creator(), BOB, "reassigned");

        vm.prank(BOB);
        vm.expectRevert(ZeroAddress.selector);
        vault.setCreator(address(0));
    }

    /// @notice The creator schedule is immutable, monotone non-increasing and exactly zero after 30 days (I31).
    function test_creatorBpsDecaysToZero() public {
        runGenesis();
        uint256 start = vault.genesisTimestamp();

        assertEq(vault.creatorBpsAt(start), Constants.CREATOR_FEE_BPS, "100 bp at genesis");
        assertEq(vault.creatorBpsAt(start + 15 days), Constants.CREATOR_FEE_BPS / 2, "half way");
        assertEq(vault.creatorBpsAt(start + 30 days), 0, "zero at the end of the window");
        assertEq(vault.creatorBpsAt(start + 3650 days), 0, "and stays zero");

        uint16 previous = Constants.CREATOR_FEE_BPS;
        for (uint256 t = start; t <= start + 31 days; t += 1 days) {
            uint16 current = vault.creatorBpsAt(t);
            assertLe(current, previous, "monotone non-increasing");
            previous = current;
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Governed bands (section 9)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every governed setter is timelock-only.
    function test_setters_onlyTimelock() public {
        runGenesis();
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.setRedeemFeeBps(10);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.setBurnBps(10);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.setStakerBps(10);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.setRefUpRateBps(200);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.setRefDivergenceBps(200);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.setTwapWindow(600);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.setLadderShape(1.1e18, 8, 3, 3);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.setRolloutParams(100, 100);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.setSpokeSeedBps(100);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.setPolicyPointer(bytes32("oracleGate"), address(gate));
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.setStandbyVault(STANDBY);
        vm.stopPrank();
    }

    /// @notice The launch values are what the constructor writes.
    function test_launchParameters() public view {
        assertEq(vault.redeemFeeBps(), Constants.REDEEM_FEE_BPS_DEFAULT, "redeemFeeBps");
        assertEq(vault.burnBps(), Constants.BURN_BPS_DEFAULT, "burnBps");
        assertEq(vault.stakerBps(), Constants.STAKER_BPS_DEFAULT, "stakerBps");
        assertEq(vault.refUpRateBps(), Constants.REF_UP_RATE_BPS_DEFAULT, "refUpRateBps");
        assertEq(vault.refDivergenceBps(), Constants.REF_DIVERGENCE_BPS_DEFAULT, "refDivergenceBps");
        assertEq(vault.twapWindow(), Constants.TWAP_WINDOW_DEFAULT, "twapWindow");
        assertEq(vault.ladderTiltX18(), Constants.LADDER_TILT_X18_DEFAULT, "ladderTiltX18");
        assertEq(vault.ladderDoublings(), Constants.LADDER_DOUBLINGS_DEFAULT, "ladderDoublings");
        assertEq(vault.seedHalvings(), Constants.SEED_HALVINGS_DEFAULT, "seedHalvings");
        assertEq(vault.bondBidHalvings(), Constants.BOND_BID_HALVINGS_DEFAULT, "bondBidHalvings");
        assertEq(vault.spokeSeedBps(), Constants.SPOKE_SEED_BPS_DEFAULT, "spokeSeedBps");
        assertEq(vault.rolloutBpsPerDay(), Constants.ROLLOUT_BPS_PER_DAY_DEFAULT, "rolloutBpsPerDay");
        assertEq(vault.entryFloorBps(), Constants.ENTRY_FLOOR_BPS_DEFAULT, "entryFloorBps");
    }

    /// @notice Each band's edges are accepted and each violation throws `OutOfBand` naming the parameter.
    function test_bands() public {
        runGenesis();
        vm.startPrank(TIMELOCK);

        vault.setRedeemFeeBps(Constants.REDEEM_FEE_BPS_MAX);
        assertEq(vault.redeemFeeBps(), Constants.REDEEM_FEE_BPS_MAX, "at the ceiling");
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("redeemFeeBps"),
                uint256(Constants.REDEEM_FEE_BPS_MAX) + 1,
                0,
                Constants.REDEEM_FEE_BPS_MAX
            )
        );
        vault.setRedeemFeeBps(Constants.REDEEM_FEE_BPS_MAX + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("burnBps"), uint256(Constants.BURN_BPS_MAX) + 1, 0, Constants.BURN_BPS_MAX
            )
        );
        vault.setBurnBps(Constants.BURN_BPS_MAX + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("stakerBps"),
                uint256(Constants.STAKER_BPS_MAX) + 1,
                0,
                Constants.STAKER_BPS_MAX
            )
        );
        vault.setStakerBps(Constants.STAKER_BPS_MAX + 1);

        vault.setRefUpRateBps(Constants.REF_UP_RATE_BPS_MIN);
        vault.setRefUpRateBps(Constants.REF_UP_RATE_BPS_MAX);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("refUpRateBps"),
                uint256(Constants.REF_UP_RATE_BPS_MIN) - 1,
                Constants.REF_UP_RATE_BPS_MIN,
                Constants.REF_UP_RATE_BPS_MAX
            )
        );
        vault.setRefUpRateBps(Constants.REF_UP_RATE_BPS_MIN - 1);

        vault.setRefDivergenceBps(Constants.REF_DIVERGENCE_BPS_MIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("refDivergenceBps"),
                uint256(Constants.REF_DIVERGENCE_BPS_MAX) + 1,
                Constants.REF_DIVERGENCE_BPS_MIN,
                Constants.REF_DIVERGENCE_BPS_MAX
            )
        );
        vault.setRefDivergenceBps(Constants.REF_DIVERGENCE_BPS_MAX + 1);

        vault.setTwapWindow(Constants.TWAP_WINDOW_MIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("twapWindow"),
                uint256(Constants.TWAP_WINDOW_MAX) + 1,
                Constants.TWAP_WINDOW_MIN,
                Constants.TWAP_WINDOW_MAX
            )
        );
        vault.setTwapWindow(Constants.TWAP_WINDOW_MAX + 1);

        vault.setSpokeSeedBps(Constants.SPOKE_SEED_BPS_MIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("spokeSeedBps"),
                uint256(Constants.SPOKE_SEED_BPS_MIN) - 1,
                Constants.SPOKE_SEED_BPS_MIN,
                Constants.SPOKE_SEED_BPS_MAX
            )
        );
        vault.setSpokeSeedBps(Constants.SPOKE_SEED_BPS_MIN - 1);

        vault.setRolloutParams(Constants.ROLLOUT_BPS_PER_DAY_MAX, Constants.ENTRY_FLOOR_BPS_MAX);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("rolloutBpsPerDay"),
                uint256(Constants.ROLLOUT_BPS_PER_DAY_MAX) + 1,
                0,
                Constants.ROLLOUT_BPS_PER_DAY_MAX
            )
        );
        vault.setRolloutParams(Constants.ROLLOUT_BPS_PER_DAY_MAX + 1, 0);

        vault.setLadderShape(
            Constants.LADDER_TILT_X18_MAX,
            Constants.LADDER_DOUBLINGS_MAX,
            Constants.HALVINGS_MAX,
            Constants.HALVINGS_MAX
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("ladderTiltX18"),
                uint256(Constants.LADDER_TILT_X18_MIN) - 1,
                Constants.LADDER_TILT_X18_MIN,
                Constants.LADDER_TILT_X18_MAX
            )
        );
        vault.setLadderShape(Constants.LADDER_TILT_X18_MIN - 1, 8, 4, 4);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("ladderDoublings"),
                uint256(Constants.LADDER_DOUBLINGS_MAX) + 1,
                Constants.LADDER_DOUBLINGS_MIN,
                Constants.LADDER_DOUBLINGS_MAX
            )
        );
        vault.setLadderShape(1.25e18, Constants.LADDER_DOUBLINGS_MAX + 1, 4, 4);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("seedHalvings"),
                uint256(Constants.HALVINGS_MIN) - 1,
                Constants.HALVINGS_MIN,
                Constants.HALVINGS_MAX
            )
        );
        vault.setLadderShape(1.25e18, 10, Constants.HALVINGS_MIN - 1, 4);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("bondBidHalvings"),
                uint256(Constants.HALVINGS_MAX) + 1,
                Constants.HALVINGS_MIN,
                Constants.HALVINGS_MAX
            )
        );
        vault.setLadderShape(1.25e18, 10, 4, Constants.HALVINGS_MAX + 1);

        vm.stopPrank();
    }

    /// @notice The hard bands the interface exposes are the ones `Constants` holds — never a restated literal.
    function test_bandGettersMatchConstants() public view {
        assertEq(vault.S0(), Constants.S0, "S0");
        assertEq(vault.VIRTUAL_SHARES(), Constants.VIRTUAL_SHARES, "VIRTUAL_SHARES");
        assertEq(vault.REDEEM_FEE_BPS_MAX(), Constants.REDEEM_FEE_BPS_MAX, "REDEEM_FEE_BPS_MAX");
        assertEq(vault.BURN_BPS_MAX(), Constants.BURN_BPS_MAX, "BURN_BPS_MAX");
        assertEq(vault.STAKER_BPS_MAX(), Constants.STAKER_BPS_MAX, "STAKER_BPS_MAX");
        assertEq(vault.REF_UP_RATE_BPS_MIN(), Constants.REF_UP_RATE_BPS_MIN, "REF_UP_RATE_BPS_MIN");
        assertEq(vault.REF_UP_RATE_BPS_MAX(), Constants.REF_UP_RATE_BPS_MAX, "REF_UP_RATE_BPS_MAX");
        assertEq(vault.REF_DIVERGENCE_BPS_MIN(), Constants.REF_DIVERGENCE_BPS_MIN, "REF_DIVERGENCE_BPS_MIN");
        assertEq(vault.REF_DIVERGENCE_BPS_MAX(), Constants.REF_DIVERGENCE_BPS_MAX, "REF_DIVERGENCE_BPS_MAX");
        assertEq(vault.TWAP_WINDOW_MIN(), Constants.TWAP_WINDOW_MIN, "TWAP_WINDOW_MIN");
        assertEq(vault.TWAP_WINDOW_MAX(), Constants.TWAP_WINDOW_MAX, "TWAP_WINDOW_MAX");
        assertEq(vault.LADDER_TILT_X18_MIN(), Constants.LADDER_TILT_X18_MIN, "LADDER_TILT_X18_MIN");
        assertEq(vault.LADDER_TILT_X18_MAX(), Constants.LADDER_TILT_X18_MAX, "LADDER_TILT_X18_MAX");
        assertEq(vault.LADDER_DOUBLINGS_MIN(), Constants.LADDER_DOUBLINGS_MIN, "LADDER_DOUBLINGS_MIN");
        assertEq(vault.LADDER_DOUBLINGS_MAX(), Constants.LADDER_DOUBLINGS_MAX, "LADDER_DOUBLINGS_MAX");
        assertEq(vault.HALVINGS_MIN(), Constants.HALVINGS_MIN, "HALVINGS_MIN");
        assertEq(vault.HALVINGS_MAX(), Constants.HALVINGS_MAX, "HALVINGS_MAX");
        assertEq(vault.ROLLOUT_BPS_PER_DAY_MAX(), Constants.ROLLOUT_BPS_PER_DAY_MAX, "ROLLOUT_BPS_PER_DAY_MAX");
        assertEq(vault.ENTRY_FLOOR_BPS_MAX(), Constants.ENTRY_FLOOR_BPS_MAX, "ENTRY_FLOOR_BPS_MAX");
        assertEq(vault.SPOKE_SEED_BPS_MIN(), Constants.SPOKE_SEED_BPS_MIN, "SPOKE_SEED_BPS_MIN");
        assertEq(vault.SPOKE_SEED_BPS_MAX(), Constants.SPOKE_SEED_BPS_MAX, "SPOKE_SEED_BPS_MAX");
        assertEq(vault.PLACEMENT_BLEED_BPS_MAX(), Constants.PLACEMENT_BLEED_BPS_MAX, "PLACEMENT_BLEED_BPS_MAX");
        assertEq(vault.MIGRATION_BLEED_BPS_MAX(), Constants.MIGRATION_BLEED_BPS_MAX, "MIGRATION_BLEED_BPS_MAX");
        assertEq(vault.CREATOR_FEE_BPS(), Constants.CREATOR_FEE_BPS, "CREATOR_FEE_BPS");
        assertEq(vault.CREATOR_DECAY_SECONDS(), Constants.CREATOR_DECAY_SECONDS, "CREATOR_DECAY_SECONDS");
    }

    /// @notice A redemption fee at the ceiling still pays 95% and never blocks the exit.
    function test_redeemFeeCeilingStillPays() public {
        runGenesis();
        vm.prank(TIMELOCK);
        vault.setRedeemFeeBps(Constants.REDEEM_FEE_BPS_MAX);
        giveShares(ALICE, 500e18);

        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        uint256 gross = (SEED_USDG * 500e18) / Constants.S0;
        assertEq(usdg.balanceOf(ALICE), (gross * (Constants.BPS - Constants.REDEEM_FEE_BPS_MAX)) / Constants.BPS);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Argument validation
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every zero-value argument is rejected loudly rather than treated as a no-op.
    function test_argumentValidation() public {
        runGenesis();

        vm.startPrank(BONDS);
        vm.expectRevert(ZeroAddress.selector);
        vault.depositBonded(1, address(0), ALICE, 1e18);
        vm.expectRevert(ZeroAddress.selector);
        vault.depositBonded(1, address(stock), address(0), 1e18);
        vm.expectRevert(ZeroAmount.selector);
        vault.depositBonded(1, address(stock), ALICE, 0);
        vm.expectRevert(ZeroAmount.selector);
        vault.mintVesting(BONDS, 0);
        vm.stopPrank();

        vm.startPrank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        vault.setStandbyVault(address(0));
        vm.expectRevert(ZeroAddress.selector);
        vault.setPolicyPointer(bytes32("oracleGate"), address(0));
        vm.stopPrank();

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(IAmpsVault.NotStandbyVault.selector, address(0), address(0)));
        vault.emergencyMigrate(address(0));
    }

    /// @notice `initializePool` is registry-only and registers the pool's counter asset when it succeeds.
    function test_initializePool_onlyRegistryAndRegistersTheCounter() public {
        runGenesis();
        vm.expectRevert(abi.encodeWithSelector(NotRegistry.selector, ALICE));
        vm.prank(ALICE);
        vault.initializePool(_entryKey(), 1 << 96);

        uint256 before = vault.assetCount();
        vm.prank(address(registry));
        PoolId poolId = vault.initializePool(_entryKey(), 1 << 96);
        assertTrue(PoolId.unwrap(poolId) != bytes32(0), "the pool id is returned");
        assertEq(vault.assetCount(), before, "both counters were already registered at genesis");
    }

    /// @notice Genesis rejects a zero vesting wallet, a zero creator and a seed the payer has not approved.
    function test_genesis_rejectsZeroAddresses() public {
        IAmpsVault.GenesisParams memory params = genesisParams();
        params.teamVestingWallet = address(0);
        vm.prank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        vault.genesis(params);

        params = genesisParams();
        params.creator = address(0);
        vm.prank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        vault.genesis(params);

        params = genesisParams();
        params.seedTokens[0] = address(0);
        vm.prank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        vault.genesis(params);

        params = genesisParams();
        params.seedAmounts[0] = 0;
        vm.prank(TIMELOCK);
        vm.expectRevert(ZeroAmount.selector);
        vault.genesis(params);
    }

    /// @notice Before genesis there is no supply, so the redemption preview is all zeroes rather than a revert.
    function test_previewRedeemBeforeGenesis() public view {
        (address[] memory tokens, uint256[] memory amounts, uint256 inventoryBurned) = vault.previewRedeem(1e18);
        assertEq(tokens.length, 0, "no assets are registered yet");
        assertEq(amounts.length, 0, "and nothing would be paid");
        assertEq(inventoryBurned, 0, "and nothing would burn");
    }

    /// @notice With no gate wired the vault is healthy by default, which is how it is reachable before the gate
    ///         pointer is set at deployment.
    function test_unwiredGateIsTreatedAsHealthy() public {
        AmpsVault bare = new AmpsVault(address(amps), address(poolManager), TIMELOCK, GUARDIAN);
        bare.touch();
        bare.checkpoint();
        assertEq(bare.previewNavPerShareX18(), (0 + 1) * 1e18 / Constants.VIRTUAL_SHARES, "empty but finite");
    }

    /// @notice A collateral the registry has never heard of still gets valued, through the ERC-20 `decimals()`
    ///         fallback, and is still redeemable.
    function test_unknownCollateralIsPricedAndRedeemable() public {
        runGenesis();
        giveShares(ALICE, 500e18);

        MockStockToken outsider = new MockStockToken("Outsider", "OUT");
        feeds.setAnswer(address(outsider), 50e8);
        outsider.mint(BOB, 10e18);
        vm.prank(BOB);
        outsider.approve(address(vault), type(uint256).max);
        vm.prank(BONDS);
        vault.depositBonded(0, address(outsider), BOB, 10e18);

        assertTrue(vault.isAsset(address(outsider)), "registered on deposit");
        assertEq(vault.totalAssetsUsd18(), 5000e18 + 500e18, "10 at $50, valued at 18 decimals");

        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        assertGt(outsider.balanceOf(ALICE), 0, "and paid out pro rata like any other asset");
    }

    /// @dev The `AMPS/USDG` entry pool key, ordered so the PoolManager accepts it.
    function _entryKey() private view returns (PoolKey memory key) {
        (address token0, address token1) =
            address(usdg) < address(weth) ? (address(usdg), address(weth)) : (address(weth), address(usdg));
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    // -------------------------------------------------------------------------------------------------------------
    // Emergency migration (section 8)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The guardian cannot migrate at will: without the predicate the call reverts.
    function test_migrate_predicateNotMet() public {
        runGenesis();
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);

        vm.prank(GUARDIAN);
        vm.expectRevert(IAmpsVault.MigrationPredicateNotMet.selector);
        vault.emergencyMigrate(STANDBY);
    }

    /// @notice Only the guardian, and only to the pre-registered standby.
    function test_migrate_accessAndTarget() public {
        runGenesis();
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(NotGuardian.selector, ALICE));
        vault.emergencyMigrate(STANDBY);

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(IAmpsVault.NotStandbyVault.selector, BOB, STANDBY));
        vault.emergencyMigrate(BOB);
    }

    /// @notice `isBlocked(vault) == true` for one constituent unlocks the evacuation, and everything moves.
    function test_migrate_denylistPredicateMovesEverything() public {
        runGenesis();
        stock.mint(BOB, 4e18);
        bondDeposit(address(stock), BOB, 4e18);

        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);

        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stock.blockAccounts(blocked);

        uint256 wethClaim = claimOf(address(weth));
        uint256 usdgClaim = claimOf(address(usdg));
        uint256 stockClaim = claimOf(address(stock));
        uint256 pol = amps.balanceOf(address(vault));

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        assertEq(claimOf(address(weth)), 0, "WETH claim left");
        assertEq(claimOf(address(usdg)), 0, "USDG claim left");
        assertEq(claimOf(address(stock)), 0, "the blocked token's claim left too");
        assertEq(_standbyClaim(address(weth)), wethClaim, "WETH arrived");
        assertEq(_standbyClaim(address(usdg)), usdgClaim, "USDG arrived");
        assertEq(_standbyClaim(address(stock)), stockClaim, "the blocked token arrived");
        assertEq(amps.balanceOf(STANDBY), pol, "the POL inventory arrived");

        assertEq(amps.vault(), STANDBY, "Amps role handed on");
        assertEq(bondsRole.vault(), STANDBY, "AmpsBonds role handed on");
        assertEq(stakingRole.vault(), STANDBY, "AmpsStaking role handed on");
        assertEq(potRole.vault(), STANDBY, "BountyPot role handed on");
    }

    /// @notice Two failing self-transfer probes are the second half of the predicate.
    function test_migrate_twoFailedProbesUnlockIt() public {
        runGenesis();
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);

        // One paused token is not enough: the predicate wants a pattern, not an incident.
        stock.pause();
        vm.prank(GUARDIAN);
        vm.expectRevert(IAmpsVault.MigrationPredicateNotMet.selector);
        vault.emergencyMigrate(STANDBY);

        stock2.pause();
        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);
        assertEq(amps.vault(), STANDBY, "the evacuation completed");
    }

    /// @notice The migration is value-preserving: the standby's NAV/share is the vault's, inside the relaxed 50 bp
    ///         bound that only applies here.
    function test_migrate_preservesNavPerShare() public {
        runGenesis();
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);
        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stock.blockAccounts(blocked);

        uint256 navBefore = vault.navPerShareX18();
        assertEq(navBefore, 999_999_999_999_999_999, "NAV/share before");

        vm.recordLogs();
        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        (uint256 emittedBefore, uint256 emittedAfter) = _migratedNav();
        assertEq(emittedBefore, navBefore, "the event discloses the NAV it started from");
        assertEq(emittedAfter, navBefore, "and the standby carries exactly the same backing per share");
    }

    /// @dev The `navPerShareBefore` and `navPerShareAfter` of the recorded `Migrated` event.
    function _migratedNav() private returns (uint256 navBefore, uint256 navAfter) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 2 || logs[i].topics[0] != IAmpsVault.Migrated.selector) continue;
            (navBefore, navAfter) = abi.decode(logs[i].data, (uint256, uint256));
            return (navBefore, navAfter);
        }
        revert("Migrated event not found");
    }

    /// @notice A dead feed never stands between the guardian and the evacuation: the bleed disclosure is skipped,
    ///         the migration completes.
    function test_migrate_survivesDeadFeeds() public {
        runGenesis();
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);
        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stock.blockAccounts(blocked);
        feeds.setReverting(true);

        vm.recordLogs();
        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        (uint256 emittedBefore, uint256 emittedAfter) = _migratedNav();
        assertEq(emittedBefore, 999_999_999_999_999_999, "the last good NAV is still disclosed");
        assertEq(emittedAfter, 0, "and the unpriceable one is reported as zero rather than blocking");
        assertEq(amps.vault(), STANDBY, "the evacuation completed");
    }

    /// @dev The ERC-6909 amount burned for `token` in the recorded logs: the PoolManager emits
    ///      `Transfer(caller, from, address(0), id, amount)` on every `burn`, which is how a redemption's claim leg
    ///      is observed independently of the end state.
    function _burnedClaims(address token) private view returns (uint256 burned) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Transfer(address,address,address,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(poolManager) || logs[i].topics.length != 4) continue;
            if (logs[i].topics[0] != topic) continue;
            if (uint256(logs[i].topics[2]) != 0) continue;
            if (logs[i].topics[3] != bytes32(uint256(uint160(token)))) continue;
            (, uint256 amount) = abi.decode(logs[i].data, (address, uint256));
            burned += amount;
        }
    }

    /// @dev The standby's ERC-6909 claim balance for `token`.
    function _standbyClaim(address token) private view returns (uint256) {
        return poolManager.balanceOf(STANDBY, uint256(uint160(token)));
    }
}
