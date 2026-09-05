// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsBonds} from "../../src/interfaces/IAmpsBonds.sol";
import {IPoolRegistry} from "../../src/interfaces/IPoolRegistry.sol";
import {BondPolicy} from "../../src/policy/BondPolicy.sol";
import {Constants} from "../../src/types/Constants.sol";
import {GateNotHealthy, OutOfBand} from "../../src/types/Errors.sol";
import {ConstituentStatus, GateState} from "../../src/types/Types.sol";
import {Phase2Fixture} from "./Phase2Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

/// @title Phase2IntegrationTest
/// @notice The Phase 2 exit criteria as end-to-end journeys over the real contracts: genesis and the NAV vector,
///         the bond/claim path at both a zero and a +30% premium, the rate-limited reference price, the ungated
///         redemption floor under every failure mode at once, the staking stream, the constituent lifecycle, the
///         predicate-gated migration drill, the keeper bounty and the gas shape of the four hot paths.
///
/// @dev Every journey ends in {assertSweepClean}, which is invariant I12 stated at the integration level: no
///      registered asset ever rests as an ERC-20 balance on the vault or on `AmpsBonds`.
contract Phase2IntegrationTest is Phase2Fixture {
    /// @dev The NVDA-like constituent every bond journey uses.
    uint256 internal constant NVDA = 0;
    /// @dev The CRWD-like constituent (display multiplier 4.0) the lifecycle journey retires.
    uint256 internal constant CRWD = 4;

    function setUp() public virtual {
        deployPhase2World();
        runPhase2Genesis();
    }

    // -------------------------------------------------------------------------------------------------------------
    // (a) Genesis
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Genesis: five constituents added with their collateral markets, seven pools, `A` = $5,000,
    ///         NAV/share = $1.00 and `P_ref` = NAV because the rate limiter starts from a zero reference.
    function test_a_genesisNavVector() public view {
        assertEq(registry.poolCount(), 7, "two entry pools and five spokes");
        assertEq(registry.activeConstituentCount(), 5, "five active constituents");
        assertEq(bonds.marketCount(), 5, "addConstituent opened five collateral markets");

        assertEq(amps.totalSupply(), Constants.S0, "S0 minted once");
        assertEq(amps.balanceOf(address(teamVesting)), Constants.TEAM_SHARES, "team tranche");
        assertEq(amps.balanceOf(address(vault)), Constants.POL_SHARES, "POL tranche");

        assertEq(vault.totalAssetsUsd18(), 5000e18, "A is exactly $5,000");
        assertEq(vault.navPerShareX18(), 999_999_999_999_999_999, "NAV/share is $1.00 less the virtual-share dust");
        assertEq(vault.pRefX18(), vault.navPerShareX18(), "P_ref is NAV at genesis");

        console.log("[genesis] A usd18          ", vault.totalAssetsUsd18());
        console.log("[genesis] navPerShareX18   ", vault.navPerShareX18());
        console.log("[genesis] pRefX18          ", vault.pRefX18());
        console.log("[genesis] pMktX18          ", vault.pMktX18());
        console.log("[genesis] totalSupply      ", amps.totalSupply());

        assertEq(claimOf(address(weth)), SEED_WETH, "1 WETH of seed, as an ERC-6909 claim");
        assertEq(claimOf(address(usdg)), SEED_USDG, "2,500 USDG of seed, as an ERC-6909 claim");
        assertEq(IERC20(address(weth)).balanceOf(address(vault)), 0, "and never as an idle balance");
        assertEq(uint256(gate.state(0)), uint256(GateState.GREEN), "the gate is green at genesis");
    }

    /// @notice `P_ref` falls back to NAV when the hub cannot be priced at all — and the same missing coverage is
    ///         what the gate reports as `WATCHDOG`, which is why the management-gated `checkpoint()` refuses. The
    ///         bond path is gated by the bond policy, which admits `WATCHDOG`, so a bond is what actually writes
    ///         the NAV-anchored checkpoint with `pMkt == 0` that section 5 describes. All three halves are asserted
    ///         here because only together are they the real behaviour.
    function test_a_referenceFallsBackToNavWhenTheHubIsUnobserved() public {
        marketRef.clear(hubPool);

        assertEq(uint256(gate.state(0)), uint256(GateState.WATCHDOG), "no hub observation trips layer A");
        vm.expectRevert(abi.encodeWithSelector(GateNotHealthy.selector, uint8(GateState.WATCHDOG), bytes32(0)));
        vault.checkpoint();

        // The last checkpoint stands, and it already has `P_ref == NAV`.
        assertEq(vault.pRefX18(), vault.navPerShareX18(), "the standing reference is NAV");
        assertGt(vault.pMktX18(), 0, "and still carries the genesis hub price");

        // A bond goes through under WATCHDOG (24/7 bonds) and its pre-deposit checkpoint takes the coverage branch.
        warpBy(60);
        (uint256 ampsOut,) = bondAs(ALICE, NVDA, 0.1e18, 0);
        assertGt(ampsOut, 0, "the bond issued under WATCHDOG");
        assertEq(vault.checkpointData().blockNumber, uint32(block.number), "the bond wrote a checkpoint");
        assertEq(vault.pMktX18(), 0, "coverage below twapWindow records pMkt as 0");
        assertEq(vault.pRefX18(), vault.navPerShareX18(), "and pins P_ref to NAV");
        assertSweepClean("a/unobserved-hub");
    }

    // -------------------------------------------------------------------------------------------------------------
    // (b) Bond at a zero premium: the accretion floor binds
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A NVDA-like bond with AMPS at NAV: the floor binds, `T` rises at purchase (I30), NAV/share does not
    ///         fall (I27), and the 12-hour vest pays 0 / 50 / 100 %.
    function test_b_bondAtZeroPremiumFloorBindsAndVests() public {
        uint256 amountIn = 0.1e18;

        (uint256 quotedOut, uint256 qX18, uint16 discountBps, bool floorBinding, uint256 capacityLeft, bytes32 reason) =
            bonds.quote(marketIds[NVDA], amountIn);
        assertEq(reason, bytes32(0), "the market quotes");
        assertTrue(floorBinding, "with no premium the accretion floor binds");
        assertGt(capacityLeft, quotedOut, "and the epoch has room for it");
        assertGe(discountBps, Constants.BOND_D_MIN_BPS_DEFAULT, "the discount respects its clamp");
        assertLe(discountBps, Constants.BOND_D_MAX_BPS_DEFAULT, "on both sides");

        uint256 navBefore = vault.previewNavPerShareX18();
        uint256 supplyBefore = amps.totalSupply();

        (uint256 ampsOut, uint256 positionId) = bondAs(ALICE, NVDA, amountIn, quotedOut);

        assertEq(ampsOut, quotedOut, "the quote is the fill");
        assertEq(ampsOut, (amountIn * qX18) / 1e18, "ampsOut is amountIn x q, rounded down");

        // I30: the AMPS is in `totalSupply` from the instant of purchase, and it lives on `AmpsBonds`.
        assertEq(amps.totalSupply(), supplyBefore + ampsOut, "T rises at purchase");
        assertEq(amps.balanceOf(address(bonds)), ampsOut, "the vest is held by the bonds shell");
        assertEq(amps.balanceOf(ALICE), 0, "and none of it is the bonder's yet");

        // I27: `ampsOut x nav x (1 + minAccretion) <= stockIn x P_i x (1 - h_session)`, and NAV/share cannot fall.
        uint256 navAfter = vault.previewNavPerShareX18();
        assertGe(navAfter, navBefore, "I27: the bond is non-dilutive");
        assertLe(
            ampsOut * navBefore * (Constants.BPS + Constants.MIN_ACCRETION_BPS_DEFAULT) / Constants.BPS,
            amountIn * uint256(STOCK_USD8[NVDA]) * 1e10,
            "I27: the accretion inequality"
        );

        // The collateral is custodied as an ERC-6909 claim, never as an idle balance (I12).
        assertEq(claimOf(address(stocks[NVDA])), amountIn, "collateral settled into claims");

        // The vest: nothing at t0, half at t + 6 h, all of it at t + 12 h, and never more.
        assertEq(bonds.claimable(ALICE, positionId), 0, "nothing vests instantly");

        warpBy(6 hours);
        assertApproxEqAbs(bonds.claimable(ALICE, positionId), ampsOut / 2, 1, "half the vest at 6 h");
        vm.prank(ALICE);
        uint256 firstClaim = bonds.claim(positionId, ALICE);
        assertApproxEqAbs(firstClaim, ampsOut / 2, 1, "and it pays out");
        assertEq(amps.balanceOf(ALICE), firstClaim, "to the bonder");

        warpBy(6 hours);
        assertEq(bonds.claimable(ALICE, positionId), ampsOut - firstClaim, "the rest at 12 h");
        vm.prank(ALICE);
        uint256 secondClaim = bonds.claim(positionId, ALICE);
        assertEq(firstClaim + secondClaim, ampsOut, "the whole principal, never more");
        assertEq(amps.balanceOf(address(bonds)), 0, "and nothing is left vesting");

        warpBy(1 days);
        vm.prank(ALICE);
        vm.expectRevert();
        bonds.claim(positionId, ALICE);

        assertSweepClean("b/bond-claim");
    }

    /// @notice The per-epoch capacity is a clamp on `ampsOut`, not on `amountIn`: a deposit larger than the epoch
    ///         can absorb is filled short and the collateral is still taken in full. `minAmpsOut` is the bonder's
    ///         only protection, which is what this asserts.
    function test_b_capacityClampsAmpsOutButNotTheDeposit() public {
        (,,,, uint256 capacityLeft,) = bonds.quote(marketIds[NVDA], 1e18);
        uint256 amountIn = 1e18; // ~179 AMPS at the floor, far past the 25 AMPS per-epoch capacity.

        (uint256 quoted,,,,,) = bonds.quote(marketIds[NVDA], amountIn);
        assertEq(quoted, capacityLeft, "the quote already discloses the clamp");

        (uint256 ampsOut,) = bondAs(ALICE, NVDA, amountIn, 0);
        assertEq(ampsOut, capacityLeft, "filled at the capacity, not at the price");
        assertEq(claimOf(address(stocks[NVDA])), amountIn, "the whole deposit is taken anyway");

        // With `minAmpsOut` set to the price the bonder wanted, the clamp reverts instead.
        stocks[NVDA].mint(BOB, amountIn);
        vm.startPrank(BOB);
        stocks[NVDA].approve(address(vault), type(uint256).max);
        vm.expectRevert();
        bonds.bond(marketIds[NVDA], amountIn, 100e18, BOB);
        vm.stopPrank();

        assertSweepClean("b/capacity");
    }

    /// @notice A second bond in the same block as an over-capacity first one prices against the NAV the first one
    ///         produced, not the checkpoint it started from: `depositBonded` writes a same-block checkpoint before
    ///         it settles and the shell prices after it, so I27 holds against the live NAV.
    ///
    /// @dev **Regression.** Before the fix `AmpsBonds._price` read a checkpoint up to `CHECKPOINT_MAX_AGE`
    ///      (1,800 s) old and nothing on the bond path refreshed it, while `depositBonded` and `mintVesting` are
    ///      exactly what move `A` and `T`. The per-epoch capacity clamp made the gap several-fold rather than
    ///      marginal: it takes the whole deposit while issuing only the capped AMPS, so one over-capacity bond
    ///      raised NAV/share from $1.00 to $3.58 while the checkpoint still said $1.00, and the next bond issued
    ///      24.88 AMPS ($89) for $25 of collateral, lowering NAV/share for every holder.
    function test_b_secondBondInTheSameBlockPricesAgainstTheLiveNav() public {
        // A deliberately over-capacity bond: 20 SPY-like tokens ($13,000) for the 25 AMPS the epoch allows.
        (uint256 firstOut,) = bondAs(ALICE, 2, 20e18, 0);
        assertEq(firstOut, 25e18, "the epoch capacity clamp binds, and the whole deposit is taken anyway");

        uint256 navBefore = vault.previewNavPerShareX18();
        assertGt(navBefore, 3e18, "the live NAV/share is now well above $1");
        // The standing checkpoint is the one `depositBonded` wrote *before* the first deposit landed.
        assertEq(vault.checkpointData().navPerShareX18, 999_999_999_999_999_999, "pre-deposit NAV, $1.00");
        assertEq(vault.checkpointData().blockNumber, uint32(block.number), "written in this block");

        // The second bond refreshes it again before pricing, so it prices off $3.58, not $1.00.
        (uint256 secondOut,) = bondAs(BOB, CRWD, 0.5e18, 0);
        uint256 navAfter = vault.previewNavPerShareX18();
        uint256 collateralUsd18 = (uint256(0.5e18) * uint256(STOCK_USD8[CRWD]) * 1e10) / 1e18;

        assertEq(vault.checkpointData().navPerShareX18, navBefore, "the second bond checkpointed the first's NAV");
        assertLt(secondOut, 7e18, "priced against the live NAV, $25 of collateral buys well under 7 AMPS");
        assertLe(
            (secondOut * navBefore) / 1e18,
            (collateralUsd18 * Constants.BPS) / (Constants.BPS + Constants.MIN_ACCRETION_BPS_DEFAULT) + 1,
            "the shares issued are worth at most the collateral less the accretion floor"
        );
        assertGe(navAfter, navBefore, "I27: the bond did not dilute anyone");

        assertSweepClean("b/same-block-checkpoint");
    }

    /// @notice A permissionless `checkpoint()` between the two bonds changes nothing: the bond path already prices
    ///         against a same-block checkpoint, so the keeper's refresh is disclosure for other readers, not a
    ///         precondition for accretion.
    function test_b_checkpointBetweenBondsIsNotNeededForAccretion() public {
        uint256 snapshot = vm.snapshotState();

        bondAs(ALICE, 2, 20e18, 0);
        (uint256 withoutKeeper,) = bondAs(BOB, CRWD, 0.5e18, 0);
        uint256 navWithoutKeeper = vault.previewNavPerShareX18();

        vm.revertToState(snapshot);

        bondAs(ALICE, 2, 20e18, 0);
        vault.checkpoint();
        uint256 navBefore = vault.previewNavPerShareX18();
        assertEq(vault.checkpointData().navPerShareX18, navBefore, "the keeper's checkpoint is live");
        (uint256 withKeeper,) = bondAs(BOB, CRWD, 0.5e18, 0);

        assertEq(withKeeper, withoutKeeper, "the same AMPS out either way");
        assertEq(vault.previewNavPerShareX18(), navWithoutKeeper, "and the same NAV/share");
        assertGe(vault.previewNavPerShareX18(), navBefore, "I27 holds");

        assertSweepClean("b/checkpointed");
    }

    // -------------------------------------------------------------------------------------------------------------
    // (c) The reference price under a premium
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A +30% hub premium: `P_ref` climbs at `refUpRateBps` per hour, falls immediately, and is floored at
    ///         NAV (I24). The hub and the WETH leg move together so layer F stays satisfied.
    function test_c_referenceRateLimitedUpImmediateDownFlooredAtNav() public {
        uint256 nav = vault.navPerShareX18();
        uint256 pRef0 = vault.pRefX18();
        assertEq(pRef0, nav, "starting from NAV");

        seedAllRings(1.3e18);
        uint256 premiumPrice = hubPriceUsd18();
        assertApproxEqRel(premiumPrice, 1.3e18, 1e15, "the ring reads back as a +30% premium");

        // One hour later the reference may rise by at most 10%.
        uint256 last = vault.checkpointData().timestamp;
        warpBy(1 hours);
        refreshFeeds();
        uint256 elapsed = block.timestamp - last;
        uint256 cap = pRef0 + (pRef0 * Constants.REF_UP_RATE_BPS_DEFAULT * elapsed)
            / (uint256(Constants.ONE_HOUR) * Constants.BPS);
        vault.checkpoint();
        assertEq(vault.pRefX18(), cap, "I24: the up-move is rate limited");
        assertLt(vault.pRefX18(), premiumPrice, "and has not caught the market yet");
        assertGe(vault.pRefX18(), vault.navPerShareX18(), "I24: never below NAV");

        // Three more hours and it catches up, then stops at the market price.
        for (uint256 i; i < 3; ++i) {
            warpBy(1 hours);
            refreshFeeds();
            vault.checkpoint();
        }
        assertEq(vault.pRefX18(), premiumPrice, "the reference reaches the hub TWAP and stops there");
        assertEq(vault.pMktX18(), premiumPrice, "P_mkt is the hub TWAP");

        // Down is immediate, with no rate limit at all.
        seedAllRings(1.05e18);
        warpBy(60);
        refreshFeeds();
        vault.checkpoint();
        assertApproxEqRel(vault.pRefX18(), 1.05e18, 1e15, "the down-move lands in one checkpoint");

        // And the NAV floor holds under the market.
        seedAllRings(0.5e18);
        warpBy(60);
        refreshFeeds();
        vault.checkpoint();
        assertEq(vault.pRefX18(), vault.navPerShareX18(), "I24: P_ref is floored at NAV");
        assertLt(vault.pMktX18(), vault.navPerShareX18(), "even though the market is below it");

        assertSweepClean("c/reference");
    }

    /// @notice At a +30% premium the market discount binds instead of the floor, and the bond is still accretive.
    function test_c_bondAtPremiumDiscountBinds() public {
        seedAllRings(1.3e18);
        warpBy(600);
        refreshFeeds();
        vault.checkpoint();

        uint256 amountIn = 0.1e18;
        (uint256 quoted, uint256 qX18,, bool floorBinding,,) = bonds.quote(marketIds[NVDA], amountIn);
        assertFalse(floorBinding, "the market price is the binding side under a premium");

        uint256 qFloor = policy.qFloorX18(
            uint256(STOCK_USD8[NVDA]) * 1e10, vault.navPerShareX18(), 0, Constants.MIN_ACCRETION_BPS_DEFAULT
        );
        assertLt(qX18, qFloor, "I27: q <= qFloor in every state");

        uint256 navBefore = vault.previewNavPerShareX18();
        (uint256 ampsOut,) = bondAs(BOB, NVDA, amountIn, quoted);
        assertEq(ampsOut, quoted, "the quote is the fill");
        assertGe(vault.previewNavPerShareX18(), navBefore, "I27: still non-dilutive");
        assertLt(ampsOut, amountIn * qFloor / 1e18, "and cheaper for the protocol than the floor");

        assertSweepClean("c/premium-bond");
    }

    // -------------------------------------------------------------------------------------------------------------
    // (d) The ungated redemption floor
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I23, exactly: a redemption pays `floor(floor(b x shares / T) x (BPS - fee) / BPS)` of every non-AMPS
    ///         balance, burns `floor(inventory x shares / T)` of the vault's own AMPS, and leaves the fee behind.
    function test_d_redemptionIsExactlyProRataLessTheFee() public {
        // A bond first, so the vault holds three different assets with three different decimals.
        bondAs(ALICE, NVDA, 0.05e18, 0);
        giveShares(BOB, 500e18);

        uint256 shares = 137e18;
        uint256 supply = amps.totalSupply();
        uint256 keepBps = Constants.BPS - vault.redeemFeeBps();

        uint256 count = vault.assetCount();
        address[] memory tokens = new address[](count);
        uint256[] memory expected = new uint256[](count);
        uint256[] memory vaultBefore = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            tokens[i] = vault.assetAt(i);
            vaultBefore[i] = heldBalance(tokens[i]);
            expected[i] = ((vaultBefore[i] * shares / supply) * keepBps) / Constants.BPS;
        }
        uint256 expectedBurn = amps.balanceOf(address(vault)) * shares / supply;

        (address[] memory previewTokens, uint256[] memory previewAmounts, uint256 previewBurn) =
            vault.previewRedeem(shares);
        assertEq(previewBurn, expectedBurn, "the preview burns what the payout implies");

        vm.prank(BOB);
        (address[] memory paidTokens, uint256[] memory paidAmounts) = vault.redeemProRata(shares, BOB);

        for (uint256 i; i < count; ++i) {
            assertEq(paidTokens[i], tokens[i], "token order is the registration order");
            assertEq(previewTokens[i], tokens[i], "and the preview agrees");
            assertEq(paidAmounts[i], expected[i], "I23: exactly pro-rata, less the fee");
            assertEq(previewAmounts[i], expected[i], "the preview cannot drift from the payout");
            assertEq(IERC20(tokens[i]).balanceOf(BOB), expected[i], "and the redeemer actually receives it");
            assertEq(heldBalance(tokens[i]), vaultBefore[i] - expected[i], "the fee stays in the vault");
        }

        assertEq(amps.totalSupply(), supply - shares - expectedBurn, "T falls by more than `shares` (I23)");
        assertEq(amps.balanceOf(BOB), 500e18 - shares, "the redeemer's shares are gone");
        assertSweepClean("d/redeem");
    }

    /// @notice The floor is structurally unpausable: every feed dead, the gate itself reverting, the guardian
    ///         freeze live and the layer-A watchdog tripped, and `redeemProRata` still pays.
    function test_d_redemptionSurvivesEveryFailureModeAtOnce() public {
        giveShares(BOB, 400e18);

        // Every aggregator reverts.
        wethFeed.setRevert(true);
        usdgFeed.setRevert(true);
        for (uint256 i; i < CONSTITUENTS; ++i) {
            stockFeeds[i].setRevert(true);
        }
        // The guardian freezes the protocol.
        vm.prank(GUARDIAN);
        gate.freezeProtocol(uint32(block.timestamp + 3 days));
        // Time passes with no blocks at all, so the layer-A watchdog trips as well.
        vm.warp(block.timestamp + 2 * Constants.GRACE_SECONDS_DEFAULT);

        // Every gated path is shut.
        vm.expectRevert();
        vault.checkpoint();
        vm.expectRevert();
        vault.touch();

        // And the gate contract itself reverts on every call. Note what this does *not* do: `_requireGate` reads
        // a reverting gate as absent rather than as a refusal, deliberately, so that a broken pointer can never
        // lock governance out of replacing it. The freeze above is what shuts the gated paths; this line only
        // proves the redemption path does not care either way.
        vm.mockCallRevert(address(gate), bytes(""), abi.encodeWithSignature("Error(string)", "gate down"));

        uint256 supply = amps.totalSupply();
        uint256 usdgBefore = heldBalance(address(usdg));
        (, uint256[] memory previewAmounts,) = vault.previewRedeem(200e18);

        vm.prank(BOB);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(200e18, BOB);

        uint256 usdgIndex = type(uint256).max;
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(amounts[i], previewAmounts[i], "the preview held through the outage");
            if (tokens[i] == address(usdg)) usdgIndex = i;
        }
        assertTrue(usdgIndex != type(uint256).max, "USDG is a redeemable asset");
        assertEq(amounts[usdgIndex], ((usdgBefore * 200e18 / supply) * 9900) / Constants.BPS, "and it paid out");
        assertGt(usdg.balanceOf(BOB), 0, "the redeemer was paid with every oracle dead");
        assertLt(amps.totalSupply(), supply, "and the shares were burned");

        vm.clearMockedCalls();
        assertSweepClean("d/outage-redeem");
    }

    /// @notice `claim()` is the second structurally ungated path (I38): a vest already sold completes through a
    ///         removed collateral, a closed market, a swapped policy and a guardian freeze.
    function test_d_claimSurvivesRemovalPauseAndFreeze() public {
        (uint256 ampsOut, uint256 positionId) = bondAs(ALICE, NVDA, 0.05e18, 0);
        warpBy(6 hours);

        vm.startPrank(TIMELOCK);
        bonds.removeCollateral(address(stocks[NVDA]));
        bonds.setPolicy(address(new BondPolicy()));
        vm.stopPrank();
        vm.prank(GUARDIAN);
        gate.freezeProtocol(uint32(block.timestamp + 3 days));

        vm.prank(ALICE);
        uint256 claimed = bonds.claim(positionId, ALICE);
        assertApproxEqAbs(claimed, ampsOut / 2, 1, "I38: the vest pays regardless");

        warpBy(6 hours);
        vm.prank(ALICE);
        assertEq(bonds.claimAll(ALICE), ampsOut - claimed, "and completes");
        assertSweepClean("d/claim-ungated");
    }

    // -------------------------------------------------------------------------------------------------------------
    // (e) Staking
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The staker slice, paid the way `compound()` will pay it in Phase 3: the vault transfers the AMPS in
    ///         and then calls `notifyReward` in the same transaction. The tranche is invisible at the instant it
    ///         lands, releases linearly over 24 hours, and a sandwich around the notification earns nothing (I36).
    function test_e_stakingStreamAndSandwich() public {
        giveShares(ALICE, 1000e18);
        giveShares(BOB, 1000e18);

        vm.startPrank(ALICE);
        amps.approve(address(staking), type(uint256).max);
        staking.deposit(500e18, ALICE);
        vm.stopPrank();
        assertEq(staking.totalAssets(), 500e18, "the deposit is the whole of totalAssets");

        // The vault's own slice of a notional 100 AMPS of sell fees.
        uint256 fees = 100e18;
        uint256 cut = fees * vault.stakerBps() / Constants.BPS;
        assertEq(cut, 30e18, "stakerBps is 30% at launch");

        // BOB sandwiches: in the same block as the notification.
        vm.startPrank(BOB);
        amps.approve(address(staking), type(uint256).max);
        uint256 bobShares = staking.deposit(500e18, BOB);
        vm.stopPrank();

        uint256 assetsBefore = staking.totalAssets();
        vm.startPrank(address(vault));
        amps.transfer(address(staking), cut);
        staking.notifyReward(cut);
        vm.stopPrank();

        assertEq(staking.totalAssets(), assetsBefore, "I36: a notified tranche is invisible until it vests");
        assertEq(staking.pendingRewards(), cut, "the whole tranche is pending");
        assertEq(staking.totalNotified(), cut, "and recorded");

        vm.prank(BOB);
        uint256 bobOut = staking.redeem(bobShares, BOB, BOB);
        assertLe(bobOut, 500e18, "I36: the sandwich earns nothing");

        // Half the stream later, half the tranche is in the share price.
        warpBy(12 hours);
        assertApproxEqRel(staking.pendingRewards(), cut / 2, 1e12, "half the stream is still pending");
        assertApproxEqRel(staking.totalAssets(), 500e18 + cut / 2, 1e12, "and half has vested");

        warpBy(12 hours + 1);
        assertEq(staking.pendingRewards(), 0, "the stream ends");
        assertEq(staking.totalAssets(), 500e18 + cut, "and the whole tranche is in the share price");
        assertLe(staking.releasedRewards(), staking.totalNotified(), "I36: released <= notified");

        uint256 aliceShares = staking.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 aliceOut = staking.redeem(aliceShares, ALICE, ALICE);
        assertGt(aliceOut, 500e18, "the staker who was there for the stream keeps it");

        assertSweepClean("e/staking");
    }

    /// @notice Only the vault may notify, and a notification that was not funded first reverts loudly rather than
    ///         bricking `totalAssets`.
    function test_e_notifyRewardIsVaultOnlyAndMustBeFunded() public {
        vm.expectRevert();
        staking.notifyReward(1e18);

        vm.prank(address(vault));
        vm.expectRevert();
        staking.notifyReward(1e18);
    }

    // -------------------------------------------------------------------------------------------------------------
    // (f) Constituent lifecycle
    // -------------------------------------------------------------------------------------------------------------

    /// @notice I37: retiring a name closes its market and zeroes its rollout weight and leaves NAV/share untouched;
    ///         reinstating reverses it; reconfiguration respects every hard band; a guardian freeze expires by
    ///         itself.
    function test_f_lifecycleRetireReinstateReconfigureFreeze() public {
        uint16 id = constituentIds[CRWD];
        uint16 marketId = marketIds[CRWD];
        uint256 navBefore = vault.previewNavPerShareX18();

        vm.prank(TIMELOCK);
        registry.retireConstituent(id);

        assertEq(uint256(registry.constituent(id).status), uint256(ConstituentStatus.RETIRED), "retired");
        assertEq(registry.constituent(id).rolloutWeightBps, 0, "rollout weight zeroed");
        assertEq(registry.activeConstituentCount(), 4, "and out of the active count");
        assertFalse(bonds.market(marketId).open, "its bond market closed atomically");
        assertEq(vault.previewNavPerShareX18(), navBefore, "I37: NAV/share is unchanged by the lifecycle action");

        stocks[CRWD].mint(ALICE, 1e18);
        vm.startPrank(ALICE);
        stocks[CRWD].approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IAmpsBonds.MarketClosed.selector, marketId));
        bonds.bond(marketId, 1e18, 0, ALICE);
        vm.stopPrank();

        // Retired names may not carry a rollout weight, whatever a proposal says.
        IPoolRegistry.ReconfigureParams memory bad;
        bad.setRolloutWeightBps = true;
        bad.rolloutWeightBps = 100;
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("rolloutWeightBps"), 100, 0, 0));
        registry.reconfigureConstituent(id, bad);

        // Reinstate, and the market reopens in the same operation.
        vm.prank(TIMELOCK);
        registry.reinstateConstituent(id, 1200);
        assertEq(uint256(registry.constituent(id).status), uint256(ConstituentStatus.ACTIVE), "reinstated");
        assertEq(registry.constituent(id).rolloutWeightBps, 1200, "with a rollout weight again");
        assertTrue(bonds.market(marketId).open, "and an open market");
        assertEq(registry.activeConstituentCount(), 5, "back in the active count");
        assertEq(vault.previewNavPerShareX18(), navBefore, "I37: still unchanged");

        // Reconfiguration inside the bands, then outside one.
        IPoolRegistry.ReconfigureParams memory good;
        good.setBuyFeeBps = true;
        good.buyFeeBps = Constants.BUY_FEE_BPS_SPOKE_MAX;
        good.setHSessionOverride = true;
        good.hSessionOverrideBps = 250;
        good.hSessionOverrideSet = true;
        vm.prank(TIMELOCK);
        registry.reconfigureConstituent(id, good);
        assertEq(registry.poolConfig(registry.poolIdOf(id)).buyFeeBps, Constants.BUY_FEE_BPS_SPOKE_MAX, "buy fee");
        assertEq(registry.constituent(id).hSessionOverrideBps, 250, "session haircut override");

        IPoolRegistry.ReconfigureParams memory outOfBand;
        outOfBand.setBuyFeeBps = true;
        outOfBand.buyFeeBps = Constants.BUY_FEE_BPS_SPOKE_MAX + 1;
        vm.prank(TIMELOCK);
        vm.expectRevert();
        registry.reconfigureConstituent(id, outOfBand);

        // A guardian freeze closes the market and then expires with no further action.
        uint32 until = uint32(block.timestamp + 1 days);
        vm.prank(GUARDIAN);
        gate.freezeConstituent(id, until);
        assertEq(uint256(gate.state(id)), uint256(GateState.SCHEDULED_FREEZE), "frozen");
        vm.startPrank(ALICE);
        vm.expectRevert();
        bonds.bond(marketId, 1e18, 0, ALICE);
        vm.stopPrank();

        warpBy(1 days + 1);
        refreshFeeds();
        assertEq(gate.constituentFreezeUntil(id), until, "the stamp is still there");
        assertTrue(uint256(gate.state(id)) != uint256(GateState.SCHEDULED_FREEZE), "but it has expired by itself");
        vault.checkpoint();
        (,,,,, bytes32 reason) = bonds.quote(marketId, 1e18);
        assertEq(reason, bytes32(0), "and the market quotes again");

        assertSweepClean("f/lifecycle");
    }

    /// @notice The CRWD-like constituent: a 4.0 display multiplier is a change *detector*, never a price input, and
    ///         a scheduled change closes that one market through layer D while NAV, redemption and claims carry on.
    function test_f_displayMultiplierAndCorporateActionFreeze() public {
        uint16 id = constituentIds[CRWD];
        uint16 marketId = marketIds[CRWD];
        assertEq(stocks[CRWD].uiMultiplier(), 4e18, "the CRWD-like name carries a 4.0 multiplier");

        // The multiplier never touches pricing: `q` is the accretion floor built from the Chainlink answer alone.
        (, uint256 qX18,, bool floorBinding,,) = bonds.quote(marketId, 1e18);
        assertTrue(floorBinding, "the floor binds at a zero premium");
        assertEq(
            qX18,
            policy.qFloorX18(
                uint256(STOCK_USD8[CRWD]) * 1e10, vault.navPerShareX18(), 0, Constants.MIN_ACCRETION_BPS_DEFAULT
            ),
            "and it is the answer, not the answer x uiMultiplier"
        );

        (uint256 ampsOut, uint256 positionId) = bondAs(ALICE, CRWD, 0.2e18, 0);
        assertGt(ampsOut, 0, "the market is open before the corporate action");
        uint256 navBefore = vault.previewNavPerShareX18();

        // A split is announced 10 minutes out, inside `corporateActionWindow`.
        stocks[CRWD].scheduleUIMultiplier(8e18, block.timestamp + 600);
        assertEq(uint256(gate.state(id)), uint256(GateState.SCHEDULED_FREEZE), "layer D freezes the constituent");
        assertEq(uint256(gate.state(0)), uint256(GateState.GREEN), "and nothing else");
        assertEq(vault.previewNavPerShareX18(), navBefore, "raw balances never move, so NAV/share does not either");

        stocks[CRWD].mint(BOB, 1e18);
        vm.startPrank(BOB);
        stocks[CRWD].approve(address(vault), type(uint256).max);
        vm.expectRevert();
        bonds.bond(marketId, 1e18, 0, BOB);
        vm.stopPrank();

        // The two paths that must never close, do not.
        vault.checkpoint();
        warpBy(6 hours);
        refreshFeeds();
        vm.prank(ALICE);
        assertGt(bonds.claim(positionId, ALICE), 0, "claims are unaffected");
        giveShares(BOB, 10e18);
        vm.prank(BOB);
        vault.redeemProRata(10e18, BOB);

        // An issuer pause is the same layer, reached the other way.
        stocks[CRWD].scheduleUIMultiplier(0, 0);
        stocks[CRWD].setOraclePaused(true);
        assertEq(uint256(gate.state(id)), uint256(GateState.SCHEDULED_FREEZE), "oraclePaused() freezes it too");

        stocks[CRWD].setOraclePaused(false);
        vault.checkpoint();
        (,,,,, bytes32 reason) = bonds.quote(marketId, 1e18);
        assertEq(reason, bytes32(0), "and the market reopens by itself once the action clears");

        assertSweepClean("f/corporate-action");
    }

    // -------------------------------------------------------------------------------------------------------------
    // (g) Migration drill
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The denylist drill: with no predicate the guardian cannot move a wei; with `isBlocked(vault)` true
    ///         on a single constituent every claim and every vault role moves to the standby in one transaction.
    function test_g_emergencyMigrationDrill() public {
        bondAs(ALICE, NVDA, 0.05e18, 0);

        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);

        vm.prank(GUARDIAN);
        vm.expectRevert();
        vault.emergencyMigrate(STANDBY);

        // The issuer denylists the vault on one Stock Token.
        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[NVDA].blockAccounts(blocked);
        assertTrue(stocks[NVDA].isBlocked(address(vault)), "the vault is blocked");

        uint256 count = vault.assetCount();
        uint256[] memory claims = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            claims[i] = claimOf(vault.assetAt(i));
        }
        uint256 polBefore = amps.balanceOf(address(vault));

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        for (uint256 i; i < count; ++i) {
            address token = vault.assetAt(i);
            assertEq(claimOf(token), 0, "the vault kept no claim");
            assertEq(
                poolManager.balanceOf(STANDBY, uint256(uint160(token))), claims[i], "and the standby has all of it"
            );
        }
        assertEq(amps.balanceOf(STANDBY), polBefore, "the POL inventory moved too");
        assertEq(amps.vault(), STANDBY, "Amps.setVault");
        assertEq(bonds.vault(), STANDBY, "AmpsBonds.setVault");
        assertEq(staking.vault(), STANDBY, "AmpsStaking.setVault");
        assertEq(pot.vault(), STANDBY, "BountyPot.setVault");
        assertSweepClean("g/migrated");
    }

    // -------------------------------------------------------------------------------------------------------------
    // (h) The keeper bounty
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The pot pays only the vault, only above the dust guard, and never more than it holds.
    function test_h_bountyPotPayPathAndDustGuard() public {
        usdg.mint(address(this), 50e6);
        usdg.approve(address(pot), type(uint256).max);
        pot.fund(50e6);
        assertEq(pot.balance(), 50e6, "funded");

        // Below `chost` nothing is payable at all.
        vm.prank(address(vault));
        uint256 dust = pot.pay(KEEPER, Constants.KEEPER_CHOST_USD18_DEFAULT - 1, 10e18);
        assertEq(dust, 0, "the dust guard blocks it");
        assertEq(usdg.balanceOf(KEEPER), 0, "and nothing moved");

        // Above it, tip + chip, inside the gas cap and the daily ceiling.
        vm.prank(address(vault));
        uint256 paid = pot.pay(KEEPER, 100e18, 10e18);
        uint256 chip = (uint256(100e18) * uint256(Constants.KEEPER_CHIP_BPS_DEFAULT)) / Constants.BPS;
        uint256 expected = (Constants.KEEPER_TIP_USD18_DEFAULT + chip) / 1e12;
        assertEq(paid, expected, "tip + chip, scaled into USDG's 6 decimals");
        assertEq(usdg.balanceOf(KEEPER), expected, "the keeper was paid");

        // The gas cap binds when the job is cheap to run.
        vm.prank(address(vault));
        uint256 capped = pot.pay(KEEPER, 100e18, 1e15);
        assertEq(capped, (uint256(1e15) * uint256(Constants.KEEPER_GAS_CAP_MULTIPLE)) / 1e12, "3x gas, capped");

        // Nobody else may pay.
        vm.expectRevert();
        pot.pay(KEEPER, 100e18, 10e18);

        // I21: the pot is not in `A`.
        assertFalse(vault.isAsset(address(pot)), "the pot is not an asset");
        assertEq(vault.totalAssetsUsd18(), 5000e18, "and its USDG is outside the numerator");

        assertSweepClean("h/bounty");
    }

    // -------------------------------------------------------------------------------------------------------------
    // (j) Gas
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Gas snapshots of the four Phase 2 hot paths, printed for the report and recorded under the
    ///         `Phase2` group.
    function test_j_gasSnapshots() public {
        giveShares(BOB, 500e18);
        stocks[NVDA].mint(ALICE, 1e18);
        vm.prank(ALICE);
        stocks[NVDA].approve(address(vault), type(uint256).max);

        vm.startPrank(ALICE);
        vm.startSnapshotGas("Phase2", "bond");
        (, uint256 positionId) = bonds.bond(marketIds[NVDA], 0.05e18, 0, ALICE);
        uint256 bondGas = vm.stopSnapshotGas();
        vm.stopPrank();

        warpBy(6 hours);
        refreshFeeds();

        vm.startPrank(ALICE);
        vm.startSnapshotGas("Phase2", "claim");
        bonds.claim(positionId, ALICE);
        uint256 claimGas = vm.stopSnapshotGas();
        vm.stopPrank();

        vm.startSnapshotGas("Phase2", "checkpoint");
        vault.checkpoint();
        uint256 checkpointGas = vm.stopSnapshotGas();

        vm.startPrank(BOB);
        vm.startSnapshotGas("Phase2", "redeemProRata");
        vault.redeemProRata(100e18, BOB);
        uint256 redeemGas = vm.stopSnapshotGas();
        vm.stopPrank();

        console.log("[gas] bond           ", bondGas);
        console.log("[gas] claim          ", claimGas);
        console.log("[gas] checkpoint     ", checkpointGas);
        console.log("[gas] redeemProRata  ", redeemGas);

        assertSweepClean("j/gas");
    }
}
