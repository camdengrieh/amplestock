// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {Constants} from "../../src/types/Constants.sol";
import {AlreadyInitialized, NotInitialized, NotTimelock, ZeroAddress, ZeroAmount} from "../../src/types/Errors.sol";
import {AmpsVaultFixture} from "../mocks/AmpsVaultFixture.sol";
import {MockGenesisHolder} from "../mocks/MockGenesisHolder.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";

/// @title VaultGenesisTest
/// @notice Revision 7's two-step genesis, in the vault: `genesisMint` mints `S0` and stops, the whole auction
///         window passes with the protocol shut, and `genesisPlace` takes the proceeds, seeds `P_ref` at the
///         clearing price and opens everything.
///
/// @dev **The window between the two steps is the point of the split, and most of this file.** The auction cannot
///      sell a supply that does not exist, so the mint has to come first; but between the mint and the placement
///      `totalSupply == S0` while `A == 0`, and any path that prices one against the other would read a NAV of
///      nothing. `test_betweenSteps_*` walks that surface: the checkpoint, the watchdog stamp, both bond entry
///      points, the placement path and — the one the brief singles out — `redeemProRata`, which must refuse
///      rather than burn a holder's shares against an empty vault.
///
/// @dev **What `redeemProRata` refusing does *not* cost.** The check reads slot 3, a latch this protocol closes
///      once and can never reopen, and touches no gate, registry, valuer, price or pointer. Section 7's
///      enumeration and its `vm.record` proof are asserted unchanged in `unit/GuardSymmetry.t.sol`; a one-way
///      latch is not a pause.
contract VaultGenesisTest is AmpsVaultFixture {
    /// @dev A launch that raises half of `S0`'s face value, i.e. the shape a full clear at the $1.00 floor
    ///      produces: `A` = $10,000 against `S0` = 20,000 AMPS, so NAV/share is $0.50 and `P0` is $1.00.
    uint256 internal constant AUCTION_WETH = 2e18;
    uint256 internal constant AUCTION_USDG = 5000e6;

    function setUp() public {
        deployVaultWorld();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Step one — genesisMint
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The mint allocates the three tranches and does nothing else: no asset moves, no checkpoint is
    ///         written, and the second latch stays open.
    function test_mint_allocatesAndStops() public {
        vm.prank(TIMELOCK);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IAmpsVault.GenesisMinted(
            TEAM_WALLET,
            CREATOR,
            address(genesisHolder),
            Constants.TEAM_SHARES,
            Constants.AUCTION_SHARES,
            Constants.POL_SHARES
        );
        vault.genesisMint(genesisMintParams());

        assertEq(amps.totalSupply(), Constants.S0, "S0 exists");
        assertEq(amps.balanceOf(TEAM_WALLET), Constants.TEAM_SHARES, "team tranche");
        assertEq(amps.balanceOf(address(genesisHolder)), Constants.AUCTION_SHARES, "auction tranche");
        assertEq(amps.balanceOf(address(vault)), Constants.POL_SHARES, "POL tranche");

        assertTrue(vault.genesisMinted(), "the mint latch closed");
        assertFalse(vault.initialized(), "the place latch did not");
        assertEq(vault.creator(), CREATOR, "the creator is recorded at the mint");
        assertEq(vault.genesisTimestamp(), 0, "but the creator's decay clock has not started");

        assertEq(vault.totalAssetsUsd18(), 0, "A is zero: nothing was pulled");
        assertEq(vault.navPerShareX18(), 0, "and no checkpoint was written");
        assertEq(vault.pRefX18(), 0, "so PoolRegistry still reads 'no reference yet'");
        assertEq(vault.assetCount(), 0, "and no asset is registered yet either");
    }

    /// @notice The mint latch is one-way and only the timelock may turn it.
    function test_mint_latchAndCaller() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.genesisMint(genesisMintParams());

        vm.startPrank(TIMELOCK);
        vault.genesisMint(genesisMintParams());
        vm.expectRevert(IAmpsVault.GenesisAlreadyDone.selector);
        vault.genesisMint(genesisMintParams());
        vm.stopPrank();
    }

    /// @notice The adapter must be the address the vault's own set-once pointer holds, and it must hold code.
    /// @dev Half of `S0` leaves for it in this call. A proposal naming a different address, or an EOA, is a
    ///      permanent loss of the auction tranche, so both are refused before a single AMPS is minted.
    function test_mint_refusesAnAdapterThePointerDoesNotName() public {
        IAmpsVault.GenesisMintParams memory params = genesisMintParams();
        params.genesis = address(new MockGenesisHolder());
        vm.prank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        vault.genesisMint(params);

        assertEq(amps.totalSupply(), 0, "and nothing was minted on the way to that revert");
    }

    /// @notice Each tranche must equal its constant, and the error names all three.
    function test_mint_refusesAnyOtherAllocation() public {
        IAmpsVault.GenesisMintParams memory params = genesisMintParams();
        params.auctionShares = Constants.AUCTION_SHARES - 1;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAmpsVault.InvalidGenesisAllocation.selector,
                params.teamShares,
                params.auctionShares,
                params.polShares,
                Constants.S0
            )
        );
        vault.genesisMint(params);

        params = genesisMintParams();
        params.polShares = Constants.POL_SHARES + 1;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAmpsVault.InvalidGenesisAllocation.selector,
                params.teamShares,
                params.auctionShares,
                params.polShares,
                Constants.S0
            )
        );
        vault.genesisMint(params);
    }

    /// @notice The three tranches sum to `S0` by construction, which is why one equality per tranche is the whole
    ///         allocation check.
    function test_mint_theConstantsClose() public pure {
        assertEq(
            Constants.TEAM_SHARES + Constants.AUCTION_SHARES + Constants.POL_SHARES, Constants.S0, "the split closes"
        );
        assertEq(
            Constants.AUCTION_USDG_SHARES + Constants.AUCTION_ETH_SHARES,
            Constants.AUCTION_SHARES,
            "and so do the two auction legs"
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // The window between the two steps
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every path that would price `S0` against an `A` of zero refuses with `NotInitialized`.
    function test_betweenSteps_everythingThatPricesRefuses() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());

        vm.expectRevert(NotInitialized.selector);
        vault.checkpoint();

        vm.expectRevert(NotInitialized.selector);
        vault.touch();

        vm.prank(BONDS);
        vm.expectRevert(NotInitialized.selector);
        vault.mintVesting(BONDS, 1e18);

        stock.mint(BOB, 10e18);
        vm.prank(BOB);
        stock.approve(address(vault), type(uint256).max);
        vm.prank(BONDS);
        vm.expectRevert(NotInitialized.selector);
        vault.depositBonded(1, address(stock), BOB, 1e18);
    }

    /// @notice `redeemProRata` refuses too, and that is the one refusal worth spelling out: without it a holder
    ///         of the team's or the auction's AMPS could burn shares against a vault with nothing in it.
    /// @dev In practice those AMPS are inside a `VestingWallet` and inside the auctions, and no pool exists so
    ///      nobody else can have any. The latch is what makes that structural rather than circumstantial.
    function test_betweenSteps_redeemRefuses() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());

        // Give ALICE shares the hard way — straight out of the vault's POL inventory — so the refusal below is
        // the latch and not an empty balance.
        giveShares(ALICE, 100e18);

        vm.prank(ALICE);
        vm.expectRevert(NotInitialized.selector);
        vault.redeemProRata(100e18, ALICE);

        assertEq(amps.balanceOf(ALICE), 100e18, "and the shares are untouched");
        assertEq(amps.totalSupply(), Constants.S0, "as is the supply");
    }

    /// @notice `place` refuses too. There is no pool and no reference price to anchor a ladder at, so the
    ///         revert comes out of the placement library rather than from a latch of its own — which is why this
    ///         one is a bare `expectRevert`: what matters is that no ladder can exist before the launch does.
    function test_betweenSteps_placeRefuses() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());

        vm.prank(TIMELOCK);
        vm.expectRevert();
        vault.place(spokePool, true, 1e18);
    }

    /// @notice The set-once pointers are still writable between the steps: the wiring freezes at the placement,
    ///         not at the mint.
    function test_betweenSteps_wiringIsNotFrozenYet() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());

        address replacement = address(new MockStockToken("Replacement", "REPL"));
        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("ladderPolicy"), replacement);
        assertEq(vault.ladderPolicy(), replacement, "an upgradeable pointer moved");

        // ...and the moment `genesisPlace` runs, the set-once half closes for ever.
        _place(Constants.WAD, SEED_WETH, SEED_USDG, 0);
        vm.prank(TIMELOCK);
        vm.expectRevert(AlreadyInitialized.selector);
        vault.setPolicyPointer(bytes32("genesis"), replacement);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Step two — genesisPlace
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The placement requires the mint, and says so in its own words rather than reverting somewhere
    ///         deeper.
    function test_place_requiresTheMintFirst() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(IAmpsVault.GenesisNotMinted.selector);
        vault.genesisPlace(genesisPlaceParams());
    }

    /// @notice Only the `genesis` adapter or the timelock may place, and the latch is one-way.
    function test_place_callerRuleAndLatch() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        vault.genesisPlace(genesisPlaceParams());

        _place(Constants.WAD, SEED_WETH, SEED_USDG, 0);

        vm.prank(TIMELOCK);
        vm.expectRevert(IAmpsVault.GenesisAlreadyDone.selector);
        vault.genesisPlace(genesisPlaceParams());
    }

    /// @notice The adapter's own path: it holds the auction tranche, approves the vault and calls `genesisPlace`
    ///         itself, which is what `AmpsGenesis.settle()` does in one transaction.
    function test_place_byTheAdapter() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());

        weth.mint(address(genesisHolder), AUCTION_WETH);
        usdg.mint(address(genesisHolder), AUCTION_USDG);
        genesisHolder.approve(address(weth), address(vault), AUCTION_WETH);
        genesisHolder.approve(address(usdg), address(vault), AUCTION_USDG);

        genesisHolder.place(address(vault), _params(Constants.WAD, AUCTION_WETH, AUCTION_USDG, 0));

        assertTrue(vault.initialized(), "the adapter opened the protocol");
        assertEq(claimOf(address(weth)), AUCTION_WETH, "the WETH raise settled into claims");
        assertEq(claimOf(address(usdg)), AUCTION_USDG, "and the USDG raise");
    }

    /// @notice `P_ref` is the clearing price, NAV/share is `raised / S0`, and the premium between them is the
    ///         disclosed launch premium rather than something the vault smooths away.
    function test_place_seedsTheReferenceAtP0AndNavAtRaisedOverS0() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());

        // $10,000 raised: 2 WETH at $2,500 and 5,000 USDG at $1.00, i.e. the auction tranche clearing in full at
        // the $1.00 floor.
        _place(Constants.WAD, AUCTION_WETH, AUCTION_USDG, 0);

        assertEq(vault.totalAssetsUsd18(), 10_000e18, "A is the raise");
        assertEq(vault.pRefX18(), Constants.WAD, "P_ref is P0, not NAV");
        assertApproxEqAbs(vault.navPerShareX18(), 0.5e18, 1, "NAV/share is raised / S0, fully diluted");
        assertApproxEqRel(vault.premiumX18(), 1e18, 1e12, "and the premium is the 100% revision 7 discloses");
        assertEq(vault.genesisTimestamp(), uint32(block.timestamp), "the creator's clock starts here");
    }

    /// @notice A `p0X18` below the backing it delivers is floored at NAV/share, so I24 (`P_ref >= NAV`) holds from
    ///         block one whatever a proposal passes.
    function test_place_floorsP0AtNav() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());

        // $20,000 of seed against 20,000 AMPS is NAV/share of $1.00, and the placement asks for a $0.10 reference.
        _place(0.1e18, SEED_WETH, SEED_USDG, 0);

        assertEq(vault.pRefX18(), vault.navPerShareX18(), "the NAV floor bound the reference");
        assertGt(vault.pRefX18(), 0.1e18, "so the reference is not the price that was asked for");
    }

    /// @notice A zero reference price is refused outright: `PoolRegistry` reads a zero `pRefX18` as "no checkpoint
    ///         yet, anchor at $1.00", so writing one would silently open every pool at the wrong price.
    function test_place_refusesAZeroReference() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());

        IAmpsVault.GenesisPlaceParams memory params = _params(0, SEED_WETH, SEED_USDG, 0);
        vm.startPrank(TIMELOCK);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(ZeroAmount.selector);
        vault.genesisPlace(params);
        vm.stopPrank();
    }

    /// @notice The AMPS that never cleared comes back as the vault's own inventory: not minted, not an asset, not
    ///         in `A`, and not swept into a claim.
    function test_place_unsoldAmpsIsInventoryAndNotBacking() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());

        uint256 unsold = 4000e18;
        // The tranche that did not clear is in the adapter's hands. This test drives the *timelock* form of the
        // call, so the AMPS moves to the caller first; {test_place_byTheAdapter} drives the adapter's own form.
        genesisHolder.send(address(amps), TIMELOCK, unsold);

        uint256 supplyBefore = amps.totalSupply();
        _place(Constants.WAD, AUCTION_WETH, AUCTION_USDG, unsold);

        assertEq(amps.totalSupply(), supplyBefore, "nothing was minted or burned: it already existed");
        assertEq(amps.balanceOf(address(vault)), Constants.POL_SHARES + unsold, "it is idle vault inventory");
        assertEq(vault.inventoryAmps(), Constants.POL_SHARES + unsold, "the disclosure sees it");
        assertEq(vault.totalAssetsUsd18(), 10_000e18, "and `A` does not: every AMPS leg is worth zero (I5)");
        assertFalse(vault.isAsset(address(amps)), "AMPS is never an asset");
        assertEq(claimOf(address(amps)), 0, "and sweepClean left it idle rather than making it a claim");
    }

    /// @notice The proceeds never rest on the vault: they go straight into ERC-6909 claims, and the registry's
    ///         world joins the asset list on the way through.
    function test_place_settlesProceedsIntoClaimsAndRegistersAssets() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());
        _place(Constants.WAD, AUCTION_WETH, AUCTION_USDG, 0);

        assertEq(claimOf(address(weth)), AUCTION_WETH, "WETH claim");
        assertEq(claimOf(address(usdg)), AUCTION_USDG, "USDG claim");
        assertEq(weth.balanceOf(address(vault)), 0, "no idle WETH");
        assertEq(usdg.balanceOf(address(vault)), 0, "no idle USDG");
        assertEq(vault.assetCount(), 4, "two constituents plus WETH and USDG");
        assertTrue(vault.isAsset(address(stock)), "the registry's constituents joined the enumeration");
    }

    /// @notice After the placement the protocol is open: the checkpoint runs, the reference moves by the ordinary
    ///         rule from `P0`, and NAV is still the floor under it.
    function test_place_theReferenceKeepsMovingFromP0() public {
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());
        _place(Constants.WAD, AUCTION_WETH, AUCTION_USDG, 0);

        uint256 p0 = vault.pRefX18();
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 300);
        vault.checkpoint();

        // No hub ring exists in this fixture, so `P_mkt` is unusable and the reference falls back to the NAV
        // anchor — which is exactly the documented behaviour, and it is a *fall*, from `P0` down to NAV.
        assertLe(vault.pRefX18(), p0, "the reference never ratchets up on its own");
        assertGe(vault.pRefX18(), vault.navPerShareX18(), "and never below NAV (I24)");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `genesisPlace` as the timelock, funding and approving it first.
    function _place(uint256 p0X18, uint256 wethAmount, uint256 usdgAmount, uint256 unsold) private {
        weth.mint(TIMELOCK, wethAmount);
        usdg.mint(TIMELOCK, usdgAmount);
        vm.startPrank(TIMELOCK);
        // The unsold tranche is pulled with a plain `transferFrom`, so the caller approves AMPS as well.
        amps.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.genesisPlace(_params(p0X18, wethAmount, usdgAmount, unsold));
        vm.stopPrank();
    }

    /// @dev The two-asset placement arguments.
    function _params(uint256 p0X18, uint256 wethAmount, uint256 usdgAmount, uint256 unsold)
        private
        view
        returns (IAmpsVault.GenesisPlaceParams memory params)
    {
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        tokens[0] = address(weth);
        amounts[0] = wethAmount;
        tokens[1] = address(usdg);
        amounts[1] = usdgAmount;
        params = IAmpsVault.GenesisPlaceParams({p0X18: p0X18, tokens: tokens, amounts: amounts, unsoldAmps: unsold});
    }
}
