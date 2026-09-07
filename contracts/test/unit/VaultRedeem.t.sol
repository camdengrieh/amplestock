// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsVault} from "../../src/interfaces/IAmpsVault.sol";
import {Constants} from "../../src/types/Constants.sol";
import {GateState, PlacementRecord} from "../../src/types/Types.sol";
import {ClaimMinter} from "../mocks/ClaimMinter.sol";
import {PlacementFixture} from "../mocks/PlacementFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice A contract that reverts on every call, for the hostile-timelock half of the drill.
contract AlwaysRevertsInRedeem {
    fallback() external payable {
        revert("down");
    }
}

/// @title VaultRedeemTest
/// @notice `docs/phase3-state-model.md` §8.1 and §3.10: I23 with **live positions** — exactly
///         `floor(L_p x shares / T)` removed from every record in every pool, every counter asset paid less
///         `redeemFeeBps`, the released inventory AMPS burned — and the floor still succeeding with every feed
///         dead, the watchdog tripped, the guardian freezing and the timelock hostile.
contract VaultRedeemTest is PlacementFixture {
    function setUp() public {
        deployPlacementWorld();
        placeGenesisLadders();
        giveShares(ALICE, 500e18);
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // I23 with live positions
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The removal is exactly `floor(L x shares / T)` from **every** record in **every** pool the vault
    ///         has opened — not a netting, not a substitution, not a subset.
    function test_i23_removesExactlyTheProRataLiquidityFromEveryRecord() public {
        uint256 shares = 500e18;
        uint256 supply = amps.totalSupply();

        PoolId[4] memory pools = [hubPool, wethPool, spokePools[0], spokePools[1]];
        uint128[][] memory before = new uint128[][](pools.length);
        for (uint256 p; p < pools.length; ++p) {
            PlacementRecord[] memory records = ladderOf(pools[p]);
            before[p] = new uint128[](records.length);
            for (uint256 i; i < records.length; ++i) {
                before[p][i] = records[i].liquidity;
            }
        }

        vm.prank(ALICE);
        vault.redeemProRata(shares, ALICE);

        uint256 checked;
        for (uint256 p; p < pools.length; ++p) {
            PlacementRecord[] memory records = ladderOf(pools[p]);
            for (uint256 i; i < records.length; ++i) {
                uint128 removed = uint128(uint256(before[p][i]) * shares / supply);
                assertEq(records[i].liquidity, before[p][i] - removed, "exactly floor(L x shares / T) removed");
                if (before[p][i] != 0) ++checked;
            }
        }
        assertGt(checked, 0, "there were live positions to remove from");
        assertSweepClean("redeemProRata");
    }

    /// @notice And the PoolManager agrees: the position liquidity the vault records is the liquidity the pool
    ///         holds, before and after, so the removal really happened rather than being written down.
    function test_i23_thePoolManagerAgreesWithTheVaultsBook() public {
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        // `LadderPositionValuer.totalLiquidity` reads the grid straight out of the PoolManager by `extsload`.
        PoolId[2] memory pools = [hubPool, wethPool];
        for (uint256 p; p < pools.length; ++p) {
            uint256 booked;
            PlacementRecord[] memory records = ladderOf(pools[p]);
            for (uint256 i; i < records.length; ++i) {
                booked += records[i].liquidity;
            }
            assertEq(valuer.totalLiquidity(pools[p]), booked, "the book and the pool agree");
        }
    }

    /// @notice The payout: every non-AMPS asset, net of `redeemFeeBps`, out of claims and idle balances *and* out
    ///         of the positions the removal just freed.
    function test_i23_paysEveryCounterAssetNetOfTheFee() public {
        (address[] memory tokens, uint256[] memory preview,) = vault.previewRedeem(500e18);

        vm.prank(ALICE);
        (address[] memory paidTokens, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        assertEq(paidTokens.length, tokens.length, "the same asset list");
        uint256 nonZero;
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(paidTokens[i], tokens[i], "in the same order");
            assertEq(IERC20(tokens[i]).balanceOf(ALICE), amounts[i], "the redeemer got exactly what was reported");
            if (amounts[i] != 0) ++nonZero;
        }
        assertGt(nonZero, 0, "and something was actually paid");
        preview;
    }

    /// @notice **The preview cannot drift from the payout.** `previewUnwind` mirrors v4's own decomposition — it
    ///         branches on `slot0.tick` against the range, not on the sqrt price, and every amount rounds down —
    ///         so `previewRedeem` and `redeemProRata` agree to the wei even with the whole ladder live.
    function test_previewMatchesThePayoutToTheWeiWithLivePositions() public {
        (address[] memory tokens, uint256[] memory preview, uint256 previewBurn) = vault.previewRedeem(500e18);

        vm.prank(ALICE);
        (, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        for (uint256 i; i < tokens.length; ++i) {
            assertEq(amounts[i], preview[i], "preview == payout, to the wei");
        }
        previewBurn;
    }

    /// @notice The released inventory AMPS is burned, so `T` falls by **more** than `shares` and the redemption
    ///         is accretive to everyone who stayed.
    function test_i23_releasedInventoryAmpsIsBurnedSoSupplyFallsByMoreThanShares() public {
        uint256 supplyBefore = amps.totalSupply();
        uint256 navBefore = vault.previewNavPerShareX18();

        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        assertLt(amps.totalSupply(), supplyBefore - 500e18, "T fell by more than the shares redeemed");
        assertGe(vault.previewNavPerShareX18(), navBefore, "and NAV/share did not fall");
    }

    /// @notice The fee stays in the vault: the `redeemFeeBps` slice of every payout is left behind as backing for
    ///         the holders who did not redeem.
    function test_theFeeStaysInTheVault() public {
        // The payout is `floor(gross x (BPS - redeemFeeBps) / BPS)` of every asset, where `gross` is the whole
        // pro-rata slice — balances *and* the position principal the unwind would free. Reading the same
        // redemption at a zero fee is the only way to see `gross` without re-deriving it, and the two answers
        // must differ by exactly the fee.
        (address[] memory tokens, uint256[] memory net,) = vault.previewRedeem(500e18);

        vm.prank(TIMELOCK);
        vault.setRedeemFeeBps(0);
        (, uint256[] memory gross,) = vault.previewRedeem(500e18);

        uint256 checked;
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(
                net[i],
                gross[i] * (Constants.BPS - Constants.REDEEM_FEE_BPS_DEFAULT) / Constants.BPS,
                "exactly (1 - redeemFeeBps) of the gross"
            );
            if (gross[i] != 0) ++checked;
        }
        assertGt(checked, 0, "and there was something to take a fee on");

        // The fee is not paid anywhere: it stays as backing for the holders who did not redeem.
        vm.prank(TIMELOCK);
        vault.setRedeemFeeBps(Constants.REDEEM_FEE_BPS_DEFAULT);
        uint256 navBefore = vault.previewNavPerShareX18();
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);
        assertGe(vault.previewNavPerShareX18(), navBefore, "NAV/share did not fall");
    }

    /// @notice A one-wei redemption removes nothing at all — `floor(L x 1 / T)` is zero for every cell — and so
    ///         cannot be used to sweep a position's whole accrued fee balance into a redeemer's payout.
    function test_aDustRedemptionRemovesNoLiquidityAtAll() public {
        PlacementRecord[] memory before = ladderOf(hubPool);
        giveShares(BOB, 1);

        vm.prank(BOB);
        vault.redeemProRata(1, BOB);

        PlacementRecord[] memory after_ = ladderOf(hubPool);
        for (uint256 i; i < before.length; ++i) {
            assertEq(after_[i].liquidity, before[i].liquidity, "nothing was removed");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // §12 ruling F — the AMPS ERC-6909 claim is inventory too
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A merge-add whose collected fees exceed the principal it owes leaves the vault holding AMPS as an
    ///         ERC-6909 claim. That claim is protocol inventory exactly as the idle ERC-20 balance is, so it is in
    ///         the pro-rata base `floor(inventory x shares / T)` that redemption burns — and the preview says so
    ///         before the claim has been swept.
    function test_f_theAmpsClaimIsInventoryAndIsBurnedProRata() public {
        _leaveAnAmpsClaim();
        uint256 claim = claimOf(address(amps));
        assertGt(claim, 0, "the vault holds AMPS as a claim");

        uint256 idle = amps.balanceOf(address(vault));
        uint256 supply = amps.totalSupply();
        (,, uint256 previewBurn) = vault.previewRedeem(500e18);

        // The preview counts the claim: without it the base would be `idle` alone.
        uint256 positionAmps = previewBurn - (idle + claim) * 500e18 / supply;
        assertEq(
            previewBurn, (idle + claim) * 500e18 / supply + positionAmps, "the base is the idle balance plus the claim"
        );
        assertGt(previewBurn, idle * 500e18 / supply + positionAmps, "and the claim really moved the number");

        uint256 supplyBefore = amps.totalSupply();
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        assertEq(supplyBefore - amps.totalSupply(), 500e18 + previewBurn, "burned the shares and the preview");
        assertEq(claimOf(address(amps)), 0, "and the claim was swept to ERC-20 to make the burn possible");
    }

    /// @notice And the sweep is not a giveaway. The claim is swept to ERC-20 so the burn *can* happen, but what
    ///         is burned is `floor(inventory x shares / T)` — so a one-wei redemption sweeps the claim and burns
    ///         none of it, and the vault's AMPS inventory is exactly as large afterwards as before.
    function test_f_aDustRedemptionSweepsTheClaimButBurnsNoneOfIt() public {
        _leaveAnAmpsClaim();
        assertGt(claimOf(address(amps)), 0, "there is a claim to sweep");

        giveShares(BOB, 1);
        uint256 inventoryBefore = amps.balanceOf(address(vault)) + claimOf(address(amps));
        uint256 supplyBefore = amps.totalSupply();
        vm.prank(BOB);
        vault.redeemProRata(1, BOB);

        assertEq(supplyBefore - amps.totalSupply(), 1, "only the one wei of shares was burned");
        assertEq(claimOf(address(amps)), 0, "the claim was swept to ERC-20");
        assertEq(
            amps.balanceOf(address(vault)) + claimOf(address(amps)),
            inventoryBefore,
            "and the inventory is exactly as large as it was"
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // The floor is ungated (I14), even with the whole Phase 3 machinery linked in
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every feed dead, the watchdog tripped, the guardian freezing and the timelock hostile:
    ///         `redeemProRata` still pays, and still removes from every position.
    function test_theFloorHoldsWithTheWholeWorldBroken() public {
        uint256 supply = amps.totalSupply();
        PlacementRecord[] memory before = ladderOf(hubPool);

        _breakTheWorld();

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        uint256 paid;
        for (uint256 i; i < tokens.length; ++i) {
            paid += amounts[i];
        }
        assertGt(paid, 0, "the floor paid");

        PlacementRecord[] memory after_ = ladderOf(hubPool);
        for (uint256 i; i < before.length; ++i) {
            uint128 removed = uint128(uint256(before[i].liquidity) * 500e18 / supply);
            assertEq(after_[i].liquidity, before[i].liquidity - removed, "and removed from every position");
        }
    }

    /// @notice And every *other* path is refused in that same world, which is what makes the exemption mean
    ///         something.
    function test_everyOtherPathIsRefusedInThatWorld() public {
        _breakTheWorld();
        vm.expectPartialRevert(bytes4(keccak256("GateNotHealthy(uint8,bytes32)")));
        vault.compound(hubPool);
    }

    /// @notice The storage-level half, extended to the linked libraries: a redemption reads no slot of the gate,
    ///         the feed registry, the registry or the market reference — and no slot of the *vault* that holds a
    ///         pointer to one of them. `VaultRedeemLib` runs by `DELEGATECALL`, so its reads are recorded here.
    function test_theRedemptionPathTouchesNoGateOrRegistryStorage() public {
        vm.record();
        vm.prank(ALICE);
        vault.redeemProRata(500e18, ALICE);

        _assertUntouched(address(gate), "oracleGate");
        _assertUntouched(address(feeds), "feedRegistry");
        _assertUntouched(address(registry), "registry");
        _assertUntouched(address(hook), "marketReference");
        _assertUntouched(address(valuer), "positionValuer");

        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(vault));
        assertGt(reads.length, 0, "the recording was on");
        for (uint256 i; i < reads.length; ++i) {
            _assertNotAPointerSlot(reads[i]);
        }
        for (uint256 i; i < writes.length; ++i) {
            _assertNotAPointerSlot(writes[i]);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Migration brings the ladder home
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `emergencyMigrate` unwinds the whole ladder before the claims move, so nothing is stranded in v4
    ///         positions owned by a vault the standby cannot act for.
    function test_migrationUnwindsTheLadderBeforeTheClaimsMove() public {
        vm.prank(TIMELOCK);
        vault.setStandbyVault(STANDBY);

        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[0].blockAccounts(blocked);

        vm.prank(GUARDIAN);
        vault.emergencyMigrate(STANDBY);

        assertEq(valuer.totalLiquidity(hubPool), 0, "the hub's positions are gone");
        assertEq(valuer.totalLiquidity(wethPool), 0, "and the WETH pool's");
        assertGt(IERC20(address(usdg)).balanceOf(address(poolManager)), 0, "the assets are still in the PoolManager");
        assertEq(amps.vault(), STANDBY, "and the role moved");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The floor against a hostile constituent (§7, I12, I14)
    // -------------------------------------------------------------------------------------------------------------
    //
    // "Structurally ungated" has to mean ungated by the *constituents* too, not only by the protocol's own
    // switches. A Stock Token is an issuer-controlled contract that can be paused or can denylist an address at
    // will, and the payout walks every registered asset inside one `unlock`, so before these fixes a single
    // hostile token was a global kill switch for the floor:
    //
    //   * `sweepClean` read `balanceOf` unguarded, absorbed with `safeTransfer` and reverted `SweepDirty` on any
    //     residue — so one wei of a paused token, donated by anybody, bricked **every** entry point; and
    //   * `_payOut` took every asset out as an ERC-20, so one paused constituent refused 100% of every redemption.
    //
    // The three cases below are the three shapes an issuer's refusal takes. In all of them the redemption must
    // complete and the other assets must be paid in full.

    /// @notice A **paused** constituent: the `take` reverts, so the redeemer is handed the ERC-6909 claim instead
    ///         and can `take` it whenever the issuer relents. Every other asset is paid as ERC-20, as always.
    function test_aPausedConstituentDoesNotStopTheFloor() public {
        bondDeposit(address(stocks[0]), 20e18);
        assertGt(claimOf(address(stocks[0])), 0, "the vault holds the hostile token as a claim");

        stocks[0].pause();

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        uint256 pausedIndex = _indexOf(tokens, address(stocks[0]));
        assertGt(amounts[pausedIndex], 0, "the paused token was still part of the payout");
        assertEq(
            poolManager.balanceOf(ALICE, uint256(uint160(address(stocks[0])))),
            amounts[pausedIndex],
            "and the redeemer holds a claim on exactly that amount"
        );

        _assertTheHealthyAssetsWerePaid(tokens, amounts, address(stocks[0]));
    }

    /// @notice A constituent that **denylists the vault**: the vault can no longer move it at all, so `sweepClean`
    ///         cannot fold a donated wei into claims. It reports the residue and carries on; nothing reverts.
    function test_aConstituentThatDenylistsTheVaultDoesNotStopTheFloor() public {
        bondDeposit(address(stocks[0]), 20e18);

        // A one-wei donation, which is all the old `SweepDirty` needed, and then the denylisting that pins it.
        stocks[0].mint(address(vault), 1);
        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[0].blockAccounts(blocked);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IAmpsVault.SweepResidue(address(stocks[0]), 1);

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        assertEq(stocks[0].balanceOf(address(vault)), 1, "the frozen wei is still backing, on the vault");
        _assertTheHealthyAssetsWerePaid(tokens, amounts, address(stocks[0]));
    }

    /// @notice A constituent whose **`balanceOf` reverts**: unreadable is not fatal. It contributes nothing to the
    ///         idle side of the pro-rata base and is skipped by the sweep, and the floor pays everything else.
    function test_aConstituentWhoseBalanceOfRevertsDoesNotStopTheFloor() public {
        bondDeposit(address(stocks[0]), 20e18);
        stocks[0].setBalanceOfReverts(true);

        // The preview shares the arithmetic, so it must survive the same token.
        (address[] memory previewTokens, uint256[] memory preview,) = vault.previewRedeem(500e18);

        vm.prank(ALICE);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemProRata(500e18, ALICE);

        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i], previewTokens[i], "the same asset list");
            assertEq(amounts[i], preview[i], "preview == payout, to the wei, with a view that reverts");
        }
        _assertTheHealthyAssetsWerePaid(tokens, amounts, address(stocks[0]));

        // And the claim side of the hostile token was still paid: `take` never asks a token for a balance.
        stocks[0].setBalanceOfReverts(false);
        assertGt(stocks[0].balanceOf(ALICE), 0, "the redeemer was paid the unreadable token too");
    }

    /// @notice The griefing case in its purest form: a donated wei of a token nobody can move must not stop the
    ///         *other* entry points either. `checkpoint()` is the permissionless one, so it is the canary.
    function test_aDonatedWeiOfAFrozenTokenDoesNotBrickTheOtherEntryPoints() public {
        stocks[0].mint(address(vault), 1);
        address[] memory blocked = new address[](1);
        blocked[0] = address(vault);
        stocks[0].blockAccounts(blocked);

        vault.checkpoint();
        vault.touch();

        vm.prank(ALICE);
        vault.redeemProRata(1e18, ALICE);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Gas — the worst reachable redemption (§10 ruling 7)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice **The live-cell budget is what makes the floor executable** (§12 ruling E). This measures the
    ///         marginal cost of a live cell on a fully occupied fixture and asserts that a redemption at the full
    ///         `Constants.MAX_LIVE_CELLS` fits inside 24M gas — Arbitrum's 32M per-transaction cap with a quarter
    ///         in reserve.
    ///
    /// @dev `fixedGas` is measured with a dust redemption, which walks exactly the same loop over exactly the same
    ///      records and removes nothing (`floor(L x 1 / T)` is zero for every cell), so the difference between the
    ///      two measurements is the `modifyLiquidity` work and nothing else. The floor is never gated,
    ///      rate-limited or split into instalments to make this number fit; the budget is.
    function test_e_gasPerLiveCellFitsTheRedemptionBudget() public {
        // Fill the fixture out: both spokes get a bonded bid ladder on top of their seed asks.
        for (uint256 i; i < SPOKES; ++i) {
            bondDeposit(address(stocks[i]), 20e18);
            warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
            vault.deployBonded(constituentIds[i]);
        }
        uint32 cells = vault.liveCells();
        assertEq(cells, countLiveCells(), "the count is exact");
        assertGt(cells, 0, "there is a ladder to unwind");

        giveShares(BOB, 1);
        vm.prank(BOB);
        uint256 g0 = gasleft();
        vault.redeemProRata(1, BOB);
        uint256 fixedGas = g0 - gasleft();

        vm.prank(ALICE);
        uint256 g1 = gasleft();
        vault.redeemProRata(500e18, ALICE);
        uint256 fullGas = g1 - gasleft();

        uint256 perCell = (fullGas - fixedGas) / cells;
        uint256 budgeted = perCell * Constants.MAX_LIVE_CELLS + fixedGas;

        emit log_named_uint("redeemProRata: live cells", cells);
        emit log_named_uint("redeemProRata: fixed gas (dust redemption)", fixedGas);
        emit log_named_uint("redeemProRata: total gas", fullGas);
        emit log_named_uint("redeemProRata: gas per live cell", perCell);
        emit log_named_uint("redeemProRata: at MAX_LIVE_CELLS", budgeted);

        assertLe(budgeted, 24_000_000, "a redemption at the full live-cell budget fits one transaction");
        // A CI-stable restatement of the same bound with ~20% headroom on the measured figure.
        assertLt(perCell, 46_000, "the marginal cost of a live cell");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev Leaves the vault holding AMPS as an ERC-6909 claim, which is what §12 ruling F is about.
    ///
    /// @dev **How it used to be done, and why it cannot be any more** (audit fix, 2026-09-07). The old fixture
    ///      merged a *tiny* placement into a cell holding accrued AMPS fees: `modifyLiquidity` returns
    ///      `principal + feesAccrued`, so the settlement's `currency0` side came out **positive** and
    ///      `VaultPlacementLib._settle` minted the residue back as a claim. That netting was itself the finding
    ///      the remediation closes — it routed the AMPS-side fees straight back into the ladder without the
    ///      creator, staker and burn slices of §3.6 step 5 — so `place` now collects and splits a pool's fees
    ///      before it merges, every settlement it makes is principal, and no placement path can leave a positive
    ///      `currency0` delta any more.
    ///
    ///      The ruling is about what the vault *does* with a claim it holds, not about where the claim came from,
    ///      so the claim is minted directly: AMPS the vault already owns is settled into the PoolManager and
    ///      minted back to the vault as an ERC-6909 claim, which leaves the vault's total AMPS inventory exactly
    ///      as large as it was and moves a slice of it from the ERC-20 side to the claim side. That is precisely
    ///      the state the ruling describes.
    function _leaveAnAmpsClaim() private {
        // Up into the first ask cell, so that cell is in range and earns; then back down *past* it, so it is a
        // pure-AMPS ask again and holds the 500 bp of AMPS the sell paid. The positions are live, which is what
        // makes the pro-rata base below more than the idle balance.
        buyAmps(hubPool, address(usdg), 40e6);
        giveShares(BOB, 200e18);
        sellAmps(hubPool, amps.balanceOf(BOB));
        syncMarket();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);

        ClaimMinter minter = new ClaimMinter(IPoolManager(address(poolManager)));
        vm.prank(address(vault));
        amps.transfer(address(minter), 1e18);
        minter.mintTo(address(vault), Currency.wrap(address(amps)), 1e18);
        assertGt(claimOf(address(amps)), 0, "the vault holds AMPS as a claim");
    }

    /// @dev Every feed dead, the watchdog tripped, a guardian freeze running and the timelock replaced by a
    ///      contract that reverts on any call.
    function _breakTheWorld() private {
        for (uint256 i; i < SPOKES; ++i) {
            stockFeeds[i].setRevert(true);
        }
        wethFeed.setRevert(true);
        usdgFeed.setRevert(true);
        vm.prank(GUARDIAN);
        gate.freezeProtocol(uint32(block.timestamp + 7 days));
        vm.etch(TIMELOCK, address(new AlwaysRevertsInRedeem()).code);
    }

    /// @dev Asserts that neither a read nor a write of `target`'s storage was recorded.
    function _assertUntouched(address target, string memory label) private view {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(target);
        assertEq(reads.length, 0, string.concat(label, ": no storage read"));
        assertEq(writes.length, 0, string.concat(label, ": no storage write"));
    }

    /// @dev Slot 4 `registry`, 8 `marketReference`, 9 `oracleGate`, 10 `feedRegistry`, 11 `positionValuer`,
    ///      12 `ladderPolicy`, 13 `rolloutPolicy`, 14 `standbyVault`.
    function _assertNotAPointerSlot(bytes32 slot) private view {
        uint256 value = uint256(slot);
        assertFalse(value == 4 || (value >= 8 && value <= 14), "the redemption read a pointer slot");
    }

    /// @dev The index of `token` in `tokens`.
    function _indexOf(address[] memory tokens, address token) private pure returns (uint256) {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token) return i;
        }
        revert("token not in the payout");
    }

    /// @dev Every asset but `hostile` reached the redeemer as a real ERC-20, in the reported amount, and at least
    ///      one of them was non-zero — the point being that one refusing constituent costs only itself.
    function _assertTheHealthyAssetsWerePaid(address[] memory tokens, uint256[] memory amounts, address hostile)
        private
        view
    {
        uint256 paid;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == hostile) continue;
            assertEq(IERC20(tokens[i]).balanceOf(ALICE), amounts[i], "a healthy asset was paid in full");
            paid += amounts[i];
        }
        assertGt(paid, 0, "and the floor really did pay");
    }
}
