// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsGenesis} from "../../src/genesis/AmpsGenesis.sol";
import {IAmpsGenesis} from "../../src/interfaces/IAmpsGenesis.sol";
import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotTimelock, ZeroAddress} from "../../src/types/Errors.sol";
import {AmpsVaultFixture} from "../mocks/AmpsVaultFixture.sol";
import {MockCCA} from "../mocks/MockCCA.sol";
import {MockCCAFactory, MockLegacyCCAFactory, RevertingCCAFactory} from "../mocks/MockCCAFactory.sol";
import {MockWeth9} from "../mocks/MockWeth9.sol";

/// @title AmpsGenesisTest
/// @notice The genesis adapter end to end, against a {MockCCAFactory}/{MockCCA} pair faithful to the parts of the
///         real Continuous Clearing Auction that `AmpsGenesis` depends on: the funding handshake, the block
///         schedule, a uniform Q96 clearing price, graduation, the protocol fee taken out of `sweepCurrency`, and
///         the one-shot recipient-restricted sweeps.
///
/// @dev **The four outcomes, each its own test**: both legs graduate, one leg graduates, no leg graduates, and
///      the single-auction configuration. They are not variations on a theme — the third is the one where the
///      protocol does *not* launch through the auction at all, and the founders' seed path has to still be
///      available afterwards.
contract AmpsGenesisTest is AmpsVaultFixture {
    /// @dev ETH/USD, 18 decimals. The fixture's WETH feed says $2,500, so this is what the cross-check expects.
    uint256 internal constant ETH_USD_X18 = 2500e18;

    /// @dev The block window every auction in this file runs over.
    uint64 internal constant START_OFFSET = 10;
    uint64 internal constant WINDOW = 1000;

    /// @dev A bidder with money.
    address internal constant BIDDER = address(0xB1DDE2);
    address internal constant FEE_SINK = address(0xFEE5);

    AmpsGenesis internal adapter;
    MockCCAFactory internal factory;
    MockWeth9 internal weth9;

    function setUp() public {
        deployVaultWorld();
    }

    /// @inheritdoc AmpsVaultFixture
    /// @dev The fixture's WETH is a plain `MockERC20`, and the adapter wraps native value into WETH9 at
    ///      settlement, so this replaces the token's code with {MockWeth9}'s — which adds no storage, exactly so
    ///      that this is safe — and points the adapter at it.
    function deployGenesisAdapter() internal override returns (address adapterAddress) {
        vm.etch(address(weth), address(new MockWeth9()).code);
        weth9 = MockWeth9(payable(address(weth)));

        factory = new MockCCAFactory(address(0), 0);
        adapter =
            new AmpsGenesis(address(vault), address(amps), address(factory), address(weth), address(usdg), TIMELOCK);
        return address(adapter);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Six immutables, no owner, no upgrade path.
    function test_construction_exposesItsWiringAndNothingElse() public view {
        assertEq(adapter.vault(), address(vault), "vault");
        assertEq(adapter.amps(), address(amps), "amps");
        assertEq(adapter.factory(), address(factory), "factory");
        assertEq(adapter.weth9(), address(weth), "weth9");
        assertEq(adapter.usdg(), address(usdg), "usdg");
        assertEq(adapter.timelock(), TIMELOCK, "timelock");
        assertTrue(adapter.phase() == IAmpsGenesis.Phase.Created, "nothing has happened yet");
        assertFalse(adapter.settled(), "and nothing is settled");
    }

    /// @notice Every constructor argument is required.
    function test_construction_refusesAZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        new AmpsGenesis(address(0), address(amps), address(factory), address(weth), address(usdg), TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        new AmpsGenesis(address(vault), address(amps), address(0), address(weth), address(usdg), TIMELOCK);
    }

    // -------------------------------------------------------------------------------------------------------------
    // createAuctions
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Only the timelock creates the auctions, once, and only after the tranche has arrived.
    function test_create_callerLatchAndFunding() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, ALICE));
        adapter.createAuctions(_spec(true, 0), _spec(false, 0), ETH_USD_X18);

        // The mint has not run, so the adapter holds nothing.
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IAmpsGenesis.TrancheNotFunded.selector, 0, Constants.AUCTION_SHARES));
        adapter.createAuctions(_spec(true, 0), _spec(false, 0), ETH_USD_X18);

        _mint();
        _create();

        vm.prank(TIMELOCK);
        vm.expectRevert(IAmpsGenesis.AuctionsAlreadyCreated.selector);
        adapter.createAuctions(_spec(true, 0), _spec(false, 0), ETH_USD_X18);
    }

    /// @notice **Audit finding 12.** One wei of AMPS sent to this address between `genesisMint` and
    ///         `createAuctions` used to strand half of `S0` for ever: the tranche check was `held != AUCTION_SHARES`
    ///         on a balance any AMPS holder can raise, the adapter is ownerless and has no other exit, and NAV/share
    ///         would have halved. The check is `>=`, the tranche is still funded to the wei, and the donation goes
    ///         back to the vault as inventory.
    function test_f12_aOneWeiDonationDoesNotBrickCreateAuctions() public {
        _mint();

        // Anybody with AMPS can do this; the team vesting wallet releases linearly from genesis.
        uint256 donation = 1;
        vm.prank(address(vault));
        amps.transfer(address(this), donation);
        amps.transfer(address(adapter), donation);
        assertEq(amps.balanceOf(address(adapter)), Constants.AUCTION_SHARES + donation, "the tranche plus dust");

        uint256 vaultBefore = amps.balanceOf(address(vault));
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IAmpsGenesis.TrancheSurplusSwept(donation);
        _create();

        assertEq(amps.balanceOf(address(vault)) - vaultBefore, donation, "the donation went back to the vault");
        assertEq(
            amps.balanceOf(adapter.usdgAuction()), Constants.AUCTION_USDG_SHARES, "and the USDG leg is exact anyway"
        );
        assertEq(amps.balanceOf(adapter.ethAuction()), Constants.AUCTION_ETH_SHARES, "as is the ETH leg");
        assertEq(amps.balanceOf(address(adapter)), 0, "with nothing left here");
    }

    /// @notice And a donation to a *leg's* address — derivable from the proposal's own salt, so equally cheap to
    ///         make — no longer forces the whole launch to be re-proposed either.
    function test_f12_aPreDonatedLegIsStillFunded() public {
        _mint();

        // The leg's address is CREATE2 from the factory, the proposal's salt and the init code, so it is knowable
        // before the launch runs: learn it by running the creation once and rolling the state back, which is
        // exactly the information an attacker reads off the proposal.
        uint256 snapshot = vm.snapshotState();
        _create();
        address predicted = adapter.usdgAuction();
        vm.revertToState(snapshot);
        assertEq(adapter.usdgAuction(), address(0), "the state really did roll back");

        // Over-fund it past its own tranche, which is the shape a factory that *pulls* the tranche produces once
        // a donation has arrived first — and the shape `held != spec.shares` reverted on, forcing the whole launch
        // to be re-proposed with a new salt. The adapter tops up only what is missing, so an under-funded address
        // is unchanged; an over-funded one is now simply accepted.
        vm.prank(address(vault));
        amps.transfer(predicted, Constants.AUCTION_USDG_SHARES + 1);

        _create();
        assertEq(adapter.usdgAuction(), predicted, "the leg landed where the salt said it would");
        assertGe(amps.balanceOf(predicted), Constants.AUCTION_USDG_SHARES, "and is funded for its whole tranche");
        assertTrue(MockCCA(payable(predicted)).funded(), "so the funding handshake still completed");
    }

    /// @notice The floor is $1.00 per AMPS in each currency, computed here rather than taken from the proposal.
    function test_create_floorsAreOneDollarPerAmps() public {
        _mint();
        _create();

        // USDG (6 decimals): one AMPS costs 1e6 raw units, so the Q96 price of one AMPS *wei* is 1e6 * 2^96 / 1e18.
        assertEq(adapter.floorUsdgQ96(), (uint256(1e6) * (uint256(1) << 96)) / 1e18, "USDG floor");
        // ETH (18 decimals): one AMPS costs 1/2500 ETH, so the Q96 price is 2^96 * 1e18 / ethUsdX18.
        assertEq(adapter.floorEthQ96(), ((uint256(1) << 96) * uint256(1e18)) / ETH_USD_X18, "ETH floor");
        assertEq(adapter.ethUsdX18(), ETH_USD_X18, "the ETH/USD the floor was derived from");

        // And a floor is a real price: bidding it buys one AMPS per USDG, to the Q96 truncation.
        assertApproxEqAbs(
            _usdToAmpsAtFloor(adapter.floorUsdgQ96(), 1e6), 1e18, 1e6, "1 USDG buys 1 AMPS at the USDG floor"
        );
    }

    /// @notice Both auctions are created, funded to the wei, and the adapter keeps nothing back.
    function test_create_fundsBothLegs() public {
        _mint();
        _create();

        MockCCA usdgAuction = MockCCA(payable(adapter.usdgAuction()));
        MockCCA ethAuction = MockCCA(payable(adapter.ethAuction()));

        assertEq(amps.balanceOf(address(usdgAuction)), Constants.AUCTION_USDG_SHARES, "USDG leg funded");
        assertEq(amps.balanceOf(address(ethAuction)), Constants.AUCTION_ETH_SHARES, "ETH leg funded");
        assertEq(amps.balanceOf(address(adapter)), 0, "and the adapter kept nothing");
        assertTrue(usdgAuction.funded(), "the funding handshake completed");
        assertTrue(ethAuction.funded(), "...on both legs");

        assertEq(usdgAuction.tokensRecipient(), address(adapter), "the adapter takes the unsold tokens");
        assertEq(usdgAuction.fundsRecipient(), address(adapter), "and the currency");
        assertEq(usdgAuction.currency(), address(usdg), "USDG leg currency");
        assertEq(ethAuction.currency(), address(0), "ETH leg is native");
        assertEq(amps.allowance(address(adapter), address(factory)), 0, "the factory allowance was cleared");
    }

    /// @notice A schedule that does not issue exactly 100% of the tranche over exactly the auction's window is
    ///         refused before anything is deployed.
    function test_create_validatesTheIssuanceSchedule() public {
        _mint();

        IAmpsGenesis.AuctionSpec memory bad = _spec(true, 0);
        // Half the supply over the whole window.
        bad.auctionStepsData = abi.encodePacked(_packStep(uint24(5e6 / WINDOW), uint40(WINDOW)));
        (uint256 totalMps, uint256 totalBlocks) = adapter.stepsTotals(bad.auctionStepsData);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IAmpsGenesis.InvalidSteps.selector, totalMps, totalBlocks));
        adapter.createAuctions(bad, _spec(false, 0), ETH_USD_X18);

        // The right rate over the wrong number of blocks.
        bad = _spec(true, 0);
        bad.auctionStepsData = abi.encodePacked(_packStep(uint24(1e7 / (WINDOW / 2)), uint40(WINDOW / 2)));
        (totalMps, totalBlocks) = adapter.stepsTotals(bad.auctionStepsData);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IAmpsGenesis.InvalidSteps.selector, totalMps, totalBlocks));
        adapter.createAuctions(bad, _spec(false, 0), ETH_USD_X18);
    }

    /// @notice A schedule blob round-trips through the packing upstream `AuctionStepLib.parse` reads.
    function test_packStepRoundTrips() public view {
        bytes memory data =
            abi.encodePacked(adapter.packStep(1000, 100), adapter.packStep(2000, 50), adapter.packStep(3000, 10));
        (uint256 totalMps, uint256 totalBlocks) = adapter.stepsTotals(data);
        assertEq(totalMps, 1000 * 100 + 2000 * 50 + 3000 * 10, "SUM(mps x blocks)");
        assertEq(totalBlocks, 160, "SUM(blocks)");

        // A blob that is not a whole number of 8-byte words is not a schedule at all.
        (totalMps, totalBlocks) = adapter.stepsTotals(hex"0011");
        assertEq(totalMps, 0, "a ragged blob totals zero");

        // The fixture packs its own words rather than calling the adapter mid-argument (see {_packStep}); this is
        // what keeps that copy honest.
        assertEq(bytes32(_packStep(1000, 100)), bytes32(adapter.packStep(1000, 100)), "the fixture packs what it packs");
        assertEq(_flatSchedule(), abi.encodePacked(adapter.packStep(uint24(uint256(1e7) / WINDOW), uint40(WINDOW))));
    }

    /// @notice The block schedule has to be monotone and in the future.
    function test_create_validatesTheBlockSchedule() public {
        _mint();

        IAmpsGenesis.AuctionSpec memory bad = _spec(true, 0);
        bad.claimBlock = bad.endBlock - 1;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(IAmpsGenesis.InvalidSchedule.selector, bad.startBlock, bad.endBlock, bad.claimBlock)
        );
        adapter.createAuctions(bad, _spec(false, 0), ETH_USD_X18);
    }

    /// @notice An ETH/USD price the vault's own feed registry disagrees with is refused.
    function test_create_crossChecksEthUsdAgainstTheFeed() public {
        _mint();

        uint256 wrong = ETH_USD_X18 * 2;
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IAmpsGenesis.EthUsdMismatch.selector, wrong, ETH_USD_X18));
        adapter.createAuctions(_spec(true, 0), _spec(false, 0), wrong);

        // Inside `refDivergenceBps` it passes: this is a fat-finger guard, not an oracle.
        uint256 close = ETH_USD_X18 + (ETH_USD_X18 * Constants.REF_DIVERGENCE_BPS_DEFAULT) / Constants.BPS;
        vm.prank(TIMELOCK);
        adapter.createAuctions(_spec(true, 0), _spec(false, 0), close);
        assertEq(adapter.ethUsdX18(), close, "the proposal's price was accepted");
    }

    /// @notice Only one leg: the other tranche is never sold and comes back to the vault at settlement.
    function test_create_singleLegLeavesTheOtherTrancheUnsold() public {
        _mint();

        vm.prank(TIMELOCK);
        adapter.createAuctions(_spec(true, 0), _emptySpec(), ETH_USD_X18);

        assertTrue(adapter.usdgAuction() != address(0), "the USDG leg exists");
        assertEq(adapter.ethAuction(), address(0), "the ETH leg does not");
        assertEq(amps.balanceOf(address(adapter)), Constants.AUCTION_ETH_SHARES, "the ETH tranche stayed here");

        _bidUsdg(5000e6, adapter.floorUsdgQ96());
        _rollPastEnd();
        adapter.settle();

        assertEq(adapter.unsoldAmps(), Constants.AUCTION_ETH_SHARES, "and went back to the vault as unsold");
        assertEq(amps.balanceOf(address(vault)), Constants.POL_SHARES + Constants.AUCTION_ETH_SHARES, "as inventory");
        assertApproxEqAbs(adapter.p0X18(), Constants.WAD, 1e10, "P0 is the USDG leg's clearing price");
    }

    /// @notice Both leg configurations disabled is not a launch.
    function test_create_refusesTwoDisabledLegs() public {
        _mint();
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IAmpsGenesis.InvalidTranche.selector, 0, 0));
        adapter.createAuctions(_emptySpec(), _emptySpec(), ETH_USD_X18);
    }

    /// @notice A factory that only answers to the pre-v2 `initializeDistribution` name is still reached.
    /// @dev Upstream's `CHANGELOG.md` renames `initializeDistribution` to `create` in v2.0.0 while its
    ///      `TechnicalDocumentation.md` still documents the old name. `AmpsGenesis` tries the new name first and
    ///      falls back, and this is the half of that fallback the happy path never exercises.
    function test_create_reachesALegacyFactory() public {
        MockLegacyCCAFactory legacy = new MockLegacyCCAFactory(address(0), 0);
        AmpsGenesis legacyAdapter =
            new AmpsGenesis(address(vault), address(amps), address(legacy), address(weth), address(usdg), TIMELOCK);

        // The vault's `genesis` pointer is set-once and already taken, so this adapter is funded by hand: what is
        // under test is the factory call, not the vault's mint.
        vm.prank(address(vault));
        amps.mint(address(legacyAdapter), Constants.AUCTION_SHARES);

        vm.prank(TIMELOCK);
        legacyAdapter.createAuctions(_spec(true, 0), _spec(false, 0), ETH_USD_X18);

        assertTrue(legacyAdapter.usdgAuction() != address(0), "the legacy name deployed the USDG leg");
        assertEq(amps.balanceOf(legacyAdapter.usdgAuction()), Constants.AUCTION_USDG_SHARES, "and funded it");
    }

    /// @notice A factory that refuses surfaces its own revert reason rather than a generic one.
    function test_create_surfacesTheFactoryRevert() public {
        RevertingCCAFactory refuser = new RevertingCCAFactory();
        AmpsGenesis refused =
            new AmpsGenesis(address(vault), address(amps), address(refuser), address(weth), address(usdg), TIMELOCK);
        vm.prank(address(vault));
        amps.mint(address(refused), Constants.AUCTION_SHARES);

        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(RevertingCCAFactory.FactoryRefused.selector, "initializeDistribution"));
        refused.createAuctions(_spec(true, 0), _spec(false, 0), ETH_USD_X18);
    }

    // -------------------------------------------------------------------------------------------------------------
    // settle — both legs graduate
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The happy path: both tranches clear at the floor, the vault takes the proceeds, `P_ref` becomes
    ///         `P0` and NAV/share is `raised / S0`.
    function test_settle_bothLegsGraduate() public {
        _mint();
        _create();
        _bidUsdg(5000e6, adapter.floorUsdgQ96());
        _bidEth(2e18, adapter.floorEthQ96());
        _rollPastEnd();

        // `Settled` carries no indexed fields, so this asserts the event fired; the figures are read back below.
        vm.expectEmit(false, false, false, false, address(adapter));
        emit IAmpsGenesis.Settled(0, 0, 0, 0, false, false);
        adapter.settle();

        assertTrue(adapter.settled(), "settled");
        assertTrue(adapter.phase() == IAmpsGenesis.Phase.Settled, "and the phase says so");
        // `P0` is $1.00 to within the Q96 floor the auction quotes prices on: the USDG floor is
        // `floor(1e6 * 2^96 / 1e18)`, and converting that back to 18-decimal USD loses a few wei of a wei.
        assertApproxEqAbs(adapter.p0X18(), Constants.WAD, 1e10, "P0 is $1.00");
        assertEq(adapter.raisedUsdg(), 5000e6, "USDG raised");
        assertEq(adapter.raisedWeth(), 2e18, "WETH raised, wrapped from native");
        assertEq(adapter.raisedUsd18(), 10_000e18, "which is $10,000 in all");
        assertEq(adapter.unsoldAmps(), 0, "both tranches cleared in full");

        assertTrue(vault.initialized(), "the vault is open");
        assertEq(vault.pRefX18(), adapter.p0X18(), "P_ref is P0");
        assertEq(vault.totalAssetsUsd18(), 10_000e18, "A is the raise");
        assertApproxEqAbs(vault.navPerShareX18(), 0.5e18, 1, "NAV/share is raised / S0");
        assertEq(claimOf(address(usdg)), 5000e6, "the USDG landed in claims");
        assertEq(claimOf(address(weth)), 2e18, "and the WETH");

        _assertAdapterIsEmpty();
    }

    /// @notice The adapter is swept clean at exit: no ERC-20, no native value, no AMPS.
    function test_settle_leavesNothingBehind() public {
        _settleBothLegs();
        _assertAdapterIsEmpty();
    }

    /// @notice The protocol fee comes out of the raise, and the adapter measures what arrived rather than
    ///         predicting it.
    function test_settle_isNetOfTheProtocolFee() public {
        factory.setFee(FEE_SINK, 100); // 1%, on every auction created after this call

        _mint();
        _create();
        _bidUsdg(5000e6, adapter.floorUsdgQ96());
        _bidEth(2e18, adapter.floorEthQ96());
        _rollPastEnd();
        adapter.settle();

        assertEq(adapter.raisedUsdg(), 4950e6, "1% of the USDG raise went to the fee controller");
        assertEq(adapter.raisedWeth(), 1.98e18, "and 1% of the ETH raise");
        assertEq(usdg.balanceOf(FEE_SINK), 50e6, "the fee sink was paid");
        assertEq(FEE_SINK.balance, 0.02e18, "in native value on the ETH leg");
        assertEq(vault.totalAssetsUsd18(), 9900e18, "and `A` is what actually arrived");
        _assertAdapterIsEmpty();
    }

    /// @notice Whatever did not clear comes back to the vault as inventory, not as backing.
    function test_settle_returnsTheUnsoldTrancheAsInventory() public {
        _mint();
        _create();
        // A quarter of the USDG tranche and none of the ETH tranche.
        _bidUsdg(1250e6, adapter.floorUsdgQ96());
        _bidEth(2e18, adapter.floorEthQ96());
        _rollPastEnd();
        adapter.settle();

        uint256 unsold = adapter.unsoldAmps();
        assertApproxEqAbs(
            unsold, Constants.AUCTION_USDG_SHARES - 1250e18, 1e9, "three quarters of the USDG tranche never cleared"
        );
        assertEq(amps.balanceOf(address(vault)), Constants.POL_SHARES + unsold, "and is the vault's inventory");
        assertEq(vault.totalAssetsUsd18(), 1250e18 + 5000e18, "while `A` is only the currency raised");
    }

    /// @notice Two graduated legs that disagree by more than `refDivergenceBps` emit the disclosure and the USDG
    ///         price is used anyway.
    function test_settle_divergenceIsDisclosedAndTheUsdgPriceWins() public {
        _mint();
        _create();

        // The ETH leg clears well above its floor: a hundred tick spacings up, i.e. roughly twice the floor.
        // The bid has to sit exactly on the grid, which is why this is not simply `floor * 2`.
        uint256 spacing = adapter.floorEthQ96() / 100;
        uint256 ethPriceQ96 = adapter.floorEthQ96() + spacing * 100;
        _bidUsdg(5000e6, adapter.floorUsdgQ96());
        _bidEth(2e18, ethPriceQ96);
        _rollPastEnd();

        vm.expectEmit(false, false, false, false, address(adapter));
        emit IAmpsGenesis.ClearingPricesDiverged(0, 0, 0);
        adapter.settle();

        assertApproxEqAbs(adapter.p0X18(), Constants.WAD, 1e10, "the USDG leg's price is the launch reference");
        assertEq(vault.pRefX18(), adapter.p0X18(), "and it is what the vault was seeded with");
    }

    // -------------------------------------------------------------------------------------------------------------
    // settle — one leg, and none
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Only the ETH leg graduates: `P0` is its clearing price times ETH/USD.
    function test_settle_onlyTheEthLegGraduates() public {
        _mint();
        _create();
        _bidEth(2e18, adapter.floorEthQ96());
        _rollPastEnd();
        adapter.settle();

        assertTrue(adapter.phase() == IAmpsGenesis.Phase.Settled, "it still launched");
        assertApproxEqAbs(adapter.p0X18(), Constants.WAD, 1e10, "P0 = clearingPrice x ETH/USD = $1.00");
        assertEq(adapter.raisedUsdg(), 0, "nothing was raised in USDG");
        assertEq(adapter.unsoldAmps(), Constants.AUCTION_USDG_SHARES, "the USDG tranche came home");
        assertEq(vault.totalAssetsUsd18(), 5000e18, "A is the ETH raise alone");
        assertEq(claimOf(address(usdg)), 0, "and no zero-amount USDG leg was handed to the vault");
    }

    /// @notice No leg graduates: the whole tranche goes back, the vault stays shut, and the founders' seed path
    ///         is still available to the timelock afterwards.
    function test_settle_noGraduationFallsBackToTheFoundersSeed() public {
        _mint();
        _createWithBar(1e18, 1e18); // a graduation bar nobody meets

        _bidUsdg(1e6, adapter.floorUsdgQ96());
        _rollPastEnd();

        adapter.settle();

        assertTrue(adapter.phase() == IAmpsGenesis.Phase.Aborted, "aborted, not settled");
        assertTrue(adapter.settled(), "but it did run");
        assertEq(adapter.p0X18(), 0, "there is no clearing price to launch at");
        assertEq(adapter.unsoldAmps(), Constants.AUCTION_SHARES, "the whole tranche came back");
        assertEq(amps.balanceOf(address(vault)), Constants.POL_SHARES + Constants.AUCTION_SHARES, "as inventory");
        assertFalse(vault.initialized(), "and the vault is still shut");
        _assertAdapterIsEmpty();

        // The bidder gets their money back through the auction, not through the vault.
        assertEq(usdg.balanceOf(address(vault)), 0, "the vault took none of the refundable bids");

        // And the launch proceeds the pre-revision-7 way.
        runGenesisPlaceOnly(Constants.WAD);
        assertTrue(vault.initialized(), "the founders' seed opened it instead");
        assertEq(vault.pRefX18(), Constants.WAD, "at the $1.00 fallback reference");
    }

    // -------------------------------------------------------------------------------------------------------------
    // settle — guards
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Settling before an auction's end block is refused, and the error names the auction.
    function test_settle_beforeTheEndBlockReverts() public {
        _mint();
        _create();
        _bidUsdg(5000e6, adapter.floorUsdgQ96());

        uint64 endBlock = MockCCA(payable(adapter.usdgAuction())).endBlock();
        assertGt(uint256(endBlock), block.number, "the window is still open");
        vm.expectRevert(abi.encodeWithSelector(IAmpsGenesis.AuctionNotEnded.selector, adapter.usdgAuction(), endBlock));
        adapter.settle();
    }

    /// @notice Settling twice is refused.
    function test_settle_twiceReverts() public {
        _settleBothLegs();
        vm.expectRevert(IAmpsGenesis.AlreadySettled.selector);
        adapter.settle();
    }

    /// @notice Settling before the auctions exist is refused.
    function test_settle_beforeCreationReverts() public {
        vm.expectRevert(IAmpsGenesis.AuctionsNotCreated.selector);
        adapter.settle();
    }

    /// @notice `receive()` accepts native value from the ETH auction and from WETH9 and from nowhere else.
    function test_receive_refusesEveryoneButTheAuctionAndWeth9() public {
        _mint();
        _create();

        // The value always leaves *this* contract's balance — `vm.prank` moves `msg.sender`, not the payer — so
        // it is this contract that has to be funded, and the pranked address is what `receive()` judges.
        vm.deal(address(this), 2 ether);
        vm.deal(ALICE, 1 ether);
        vm.deal(adapter.ethAuction(), 1 ether);

        vm.prank(ALICE);
        (bool ok, bytes memory returndata) = address(adapter).call{value: 1 ether}("");
        assertFalse(ok, "a stranger cannot fund the adapter");
        assertEq(returndata, abi.encodeWithSelector(IAmpsGenesis.UnexpectedNative.selector, ALICE), "and is told why");

        vm.prank(adapter.ethAuction());
        (ok,) = address(adapter).call{value: 1 ether}("");
        assertTrue(ok, "the auction's own sweep is accepted");
    }

    // -------------------------------------------------------------------------------------------------------------
    // phase()
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The phase the dApp's Auction surface reads, through its whole life.
    function test_phase_walksTheWholeLaunch() public {
        assertTrue(adapter.phase() == IAmpsGenesis.Phase.Created, "nothing created");

        _mint();
        _create();
        assertTrue(adapter.phase() == IAmpsGenesis.Phase.Created, "created, not yet started");

        vm.roll(block.number + START_OFFSET);
        assertTrue(adapter.phase() == IAmpsGenesis.Phase.Bidding, "bidding");

        _bidUsdg(5000e6, adapter.floorUsdgQ96());
        _bidEth(2e18, adapter.floorEthQ96());
        _rollPastEnd();
        assertTrue(adapter.phase() == IAmpsGenesis.Phase.Ended, "ended, unsettled");

        adapter.settle();
        assertTrue(adapter.phase() == IAmpsGenesis.Phase.Settled, "settled");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev `genesisMint`, which is what puts the tranche on the adapter.
    function _mint() private {
        if (vault.genesisMinted()) return;
        vm.prank(TIMELOCK);
        vault.genesisMint(genesisMintParams());
    }

    /// @dev Both legs, with a graduation bar both of the fixture's bids clear.
    function _create() private {
        _createWithBar(1000e6, 0.4e18);
    }

    /// @dev Both legs at a chosen graduation bar.
    function _createWithBar(uint128 usdgBar, uint128 ethBar) private {
        vm.prank(TIMELOCK);
        adapter.createAuctions(_spec(true, usdgBar), _spec(false, ethBar), ETH_USD_X18);
    }

    /// @dev The whole happy path in one call.
    function _settleBothLegs() private {
        _mint();
        _create();
        _bidUsdg(5000e6, adapter.floorUsdgQ96());
        _bidEth(2e18, adapter.floorEthQ96());
        _rollPastEnd();
        adapter.settle();
    }

    /// @dev One leg's spec: the whole window, a flat schedule, 1% tick spacing.
    function _spec(bool isUsdg, uint128 bar) private view returns (IAmpsGenesis.AuctionSpec memory spec) {
        uint64 start = uint64(block.number) + START_OFFSET;
        uint256 floorQ96 =
            isUsdg ? (uint256(1e6) * (uint256(1) << 96)) / 1e18 : ((uint256(1) << 96) * uint256(1e18)) / ETH_USD_X18;

        spec = IAmpsGenesis.AuctionSpec({
            shares: uint128(isUsdg ? Constants.AUCTION_USDG_SHARES : Constants.AUCTION_ETH_SHARES),
            startBlock: start,
            endBlock: start + WINDOW,
            claimBlock: start + WINDOW,
            tickSpacing: floorQ96 / 100,
            validationHook: address(0),
            requiredCurrencyRaised: bar,
            auctionStepsData: _flatSchedule(),
            salt: bytes32(uint256(isUsdg ? 1 : 2))
        });
    }

    /// @dev A disabled leg.
    function _emptySpec() private pure returns (IAmpsGenesis.AuctionSpec memory spec) {
        spec.auctionStepsData = "";
    }

    /// @dev `1e7 / WINDOW` milli-bips per block for `WINDOW` blocks, which totals exactly 100%.
    function _flatSchedule() private pure returns (bytes memory data) {
        data = abi.encodePacked(_packStep(uint24(uint256(1e7) / WINDOW), uint40(WINDOW)));
    }

    /// @dev {AmpsGenesis.packStep}'s formula, in the test. It is duplicated on purpose: {_spec} runs inside the
    ///      argument list of calls that are pranked and `expectRevert`-ed, and an *external* call there — even a
    ///      `pure` one — is the call the cheatcode latches onto, so the prank and the expectation would be spent
    ///      on `packStep` instead of on `createAuctions`. {test_packStepRoundTrips} pins the two against each
    ///      other so the copy cannot drift.
    function _packStep(uint24 mps, uint40 blockDelta) private pure returns (bytes8 word) {
        word = bytes8((uint64(mps) << 40) | uint64(blockDelta));
    }

    /// @dev One USDG bid at `priceQ96`, rolling into the bidding window first.
    /// @dev The auction is resolved into a local **before** the prank: `adapter.usdgAuction()` is an external
    ///      call, and one of those between `vm.prank` and the call it is meant for is what the prank lands on.
    function _bidUsdg(uint256 amount, uint256 priceQ96) private {
        MockCCA auction = MockCCA(payable(adapter.usdgAuction()));
        if (block.number < uint256(auction.startBlock())) vm.roll(uint256(auction.startBlock()));
        usdg.mint(BIDDER, amount);
        vm.startPrank(BIDDER);
        usdg.approve(address(auction), amount);
        auction.bid(priceQ96, amount);
        vm.stopPrank();
    }

    /// @dev One native bid at `priceQ96`.
    /// @dev Both the bidder and this contract are funded: whether a pranked call debits the pranked address or the
    ///      frame that actually makes it is a Foundry implementation detail, and the bid must not depend on it.
    function _bidEth(uint256 amount, uint256 priceQ96) private {
        MockCCA auction = MockCCA(payable(adapter.ethAuction()));
        if (block.number < uint256(auction.startBlock())) vm.roll(uint256(auction.startBlock()));
        vm.deal(BIDDER, BIDDER.balance + amount);
        vm.deal(address(this), address(this).balance + amount);
        vm.prank(BIDDER);
        auction.bid{value: amount}(priceQ96, amount);
    }

    /// @dev Past the end block of every created leg.
    function _rollPastEnd() private {
        uint64 end;
        if (adapter.usdgAuction() != address(0)) end = MockCCA(payable(adapter.usdgAuction())).endBlock();
        if (adapter.ethAuction() != address(0)) {
            uint64 other = MockCCA(payable(adapter.ethAuction())).endBlock();
            if (other > end) end = other;
        }
        vm.roll(uint256(end) + 1);
    }

    /// @dev The founders' seed path, run by the timelock after a launch that did not graduate — with the
    ///      `p0X18` `script/config/genesis.json`'s `fallback` block carries, rather than the fixture's
    ///      floor-me-at-NAV request, because $1.00 is what `06b_GenesisSettle` would actually send.
    /// @param p0X18 The launch reference to ask for.
    function runGenesisPlaceOnly(uint256 p0X18) private {
        weth9.mint(TIMELOCK, SEED_WETH);
        vm.deal(address(weth9), address(weth9).balance + SEED_WETH);
        usdg.mint(TIMELOCK, SEED_USDG);

        IAmpsVault.GenesisPlaceParams memory params = genesisPlaceParams();
        params.p0X18 = p0X18;

        vm.startPrank(TIMELOCK);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.genesisPlace(params);
        vm.stopPrank();
    }

    /// @dev I12's shape for the adapter: it ends holding nothing at all.
    function _assertAdapterIsEmpty() private view {
        assertEq(address(adapter).balance, 0, "no native value");
        assertEq(amps.balanceOf(address(adapter)), 0, "no AMPS");
        assertEq(usdg.balanceOf(address(adapter)), 0, "no USDG");
        assertEq(weth.balanceOf(address(adapter)), 0, "no WETH");
    }

    /// @dev How many AMPS wei `currencyAmount` buys at `priceQ96`, i.e. the auction's own price convention.
    function _usdToAmpsAtFloor(uint256 priceQ96, uint256 currencyAmount) private pure returns (uint256 amps_) {
        return (currencyAmount << 96) / priceQ96;
    }
}
