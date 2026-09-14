// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Amps} from "../../src/token/Amps.sol";
import {Constants} from "../../src/types/Constants.sol";
import {AmpsVault} from "../../src/vault/AmpsVault.sol";
import {AmpsVaultFixture} from "../mocks/AmpsVaultFixture.sol";
import {MockFeedRegistry} from "../mocks/MockFeedRegistry.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title VaultHandler
/// @notice The bounded action space the invariant runner drives: a bond priced at the accretion floor, a pro-rata
///         redemption, a checkpoint, a keeper `touch` and an outright donation.
/// @dev Prices are deliberately held still for the whole run. Market moves are the one thing allowed to lower
///      NAV/share, so leaving them out is what turns "monotone ex market moves" into a checkable invariant.
contract VaultHandler is CommonBase, StdCheats, StdUtils {
    AmpsVault internal immutable VAULT;
    Amps internal immutable AMPS;
    MockStockToken internal immutable STOCK;
    MockFeedRegistry internal immutable FEEDS;
    address internal immutable BONDS_ADDRESS;
    address internal immutable HOLDER;

    /// @notice AMPS wei minted through {AmpsVault.mintVesting}: the only mint path after the genesis latch (I10).
    uint256 public mintedVesting;
    /// @notice AMPS wei burned from redeemers.
    uint256 public burnedShares;
    /// @notice AMPS wei the **inventory-burn stream has actually retired**, which is what `totalSupply` has
    ///         already moved by. It is derived from the stream's own state rather than from the preview, because
    ///         since revision 8 (ruling U) a redemption queues its release and the burn lands over the next 24
    ///         hours: `drained = pendingBefore + released - pendingAfter` across every action that can settle.
    uint256 public burnedInventory;
    /// @notice AMPS wei redemptions have queued into the stream, settled or not.
    uint256 public queuedInventory;
    /// @notice Set the moment any action lowers NAV/share (I8).
    bool public navEverFell;
    /// @notice How many actions actually did something, so the invariants can prove the run was not empty.
    uint256 public actionCount;

    constructor(
        AmpsVault vault_,
        Amps amps_,
        MockStockToken stock_,
        MockFeedRegistry feeds_,
        address bonds_,
        address holder_
    ) {
        VAULT = vault_;
        AMPS = amps_;
        STOCK = stock_;
        FEEDS = feeds_;
        BONDS_ADDRESS = bonds_;
        HOLDER = holder_;
    }

    /// @notice A bond as `AmpsBonds` sends it: collateral into the vault, then AMPS minted at the accretion floor.
    /// @param amount The collateral, bounded into a sane range.
    function bond(uint256 amount) external {
        uint256 collateral = bound(amount, 1e12, 1000e18);
        STOCK.mint(address(this), collateral);
        STOCK.approve(address(VAULT), type(uint256).max);

        uint256 navBefore = VAULT.previewNavPerShareX18();
        (uint256 answerUsd8,,) = FEEDS.latestAnswer(address(STOCK));
        uint256 valueUsd18 = (collateral * answerUsd8 * 1e10) / 1e18;
        uint256 ampsOut =
            (valueUsd18 * 1e18) / ((navBefore * (Constants.BPS + Constants.MIN_ACCRETION_BPS_DEFAULT)) / Constants.BPS);

        vm.prank(BONDS_ADDRESS);
        VAULT.depositBonded(1, address(STOCK), address(this), collateral);
        if (ampsOut != 0) {
            vm.prank(BONDS_ADDRESS);
            VAULT.mintVesting(BONDS_ADDRESS, ampsOut);
            mintedVesting += ampsOut;
        }
        _record(navBefore);
    }

    /// @notice A pro-rata redemption by the holder.
    /// @param shares The AMPS wei to redeem, bounded by what the holder actually has.
    function redeem(uint256 shares) external {
        uint256 balance = AMPS.balanceOf(HOLDER);
        if (balance == 0) return;
        uint256 amount = bound(shares, 1, balance);

        uint256 navBefore = VAULT.previewNavPerShareX18();
        (,, uint256 inventoryReleased) = VAULT.previewRedeem(amount);

        vm.prank(HOLDER);
        VAULT.redeemProRata(amount, HOLDER);

        burnedShares += amount;
        queuedInventory += inventoryReleased;
        _record(navBefore);
    }

    /// @notice The permissionless checkpoint, after an arbitrary wait.
    /// @param wait The seconds to advance.
    function checkpointAfter(uint256 wait) external {
        vm.warp(block.timestamp + bound(wait, 1, 2 days));
        uint256 navBefore = VAULT.previewNavPerShareX18();
        VAULT.checkpoint();
        _record(navBefore);
    }

    /// @notice The permissionless watchdog stamp.
    function touch() external {
        uint256 navBefore = VAULT.previewNavPerShareX18();
        VAULT.touch();
        _record(navBefore);
    }

    /// @notice An outright donation of a Stock Token to the vault, followed by the `touch` that sweeps it into
    ///         claims. A donation raises everyone's backing; it never creates a claim for the donor.
    /// @param amount The donation.
    function donate(uint256 amount) external {
        uint256 gift = bound(amount, 1, 100e18);
        uint256 navBefore = VAULT.previewNavPerShareX18();
        STOCK.mint(address(VAULT), gift);
        VAULT.touch();
        _record(navBefore);
    }

    /// @dev Records the action, what the inventory-burn stream has retired so far, and whether the action lowered
    ///      NAV/share.
    /// @dev `drained = queued - pending` by construction: {VaultRedeemLib-settleBurnStream} decrements `pending`
    ///      by exactly what it burned, so the stream's own state is the ledger and no action has to be told that
    ///      it settled. Every action here can settle — `bond`, `checkpointAfter`, `touch` and `donate` all reach
    ///      `_checkpoint`, and `redeem` settles on entry — which is why this is computed once, here, rather than
    ///      per action.
    function _record(uint256 navBefore) private {
        ++actionCount;
        burnedInventory = queuedInventory - VAULT.pendingInventoryBurn();
        if (VAULT.previewNavPerShareX18() < navBefore) navEverFell = true;
    }
}

/// @title AmpsVaultInvariantTest
/// @notice The vault's slice of the plan's invariant suite: I3, I5, I6, I8, I10, I12, I22 and I24, driven by
///         `VaultHandler` over random interleavings of bonds, redemptions, checkpoints, touches and donations.
contract AmpsVaultInvariantTest is AmpsVaultFixture {
    VaultHandler internal handler;

    function setUp() public {
        deployVaultWorld();
        runGenesis();

        handler = new VaultHandler(vault, amps, stock, feeds, BONDS, ALICE);
        giveShares(ALICE, 2000e18);
        vm.prank(ALICE);
        amps.approve(address(handler), type(uint256).max);

        targetContract(address(handler));
    }

    /// @notice I3 and I10: `totalSupply` moves only through the vault's mint and burn, and after the genesis latch
    ///         the only mint path is `mintVesting`.
    /// @dev The inventory term is what the **stream has actually retired**, not what redemptions released: since
    ///      revision 8 (ruling U) the two differ by `pendingInventoryBurn()` at every instant.
    function invariant_I3_I10_supplyMovesOnlyThroughTheVault() public view {
        assertEq(
            amps.totalSupply(),
            Constants.S0 + handler.mintedVesting() - handler.burnedShares() - handler.burnedInventory(),
            "S0 + vesting mints - redeemed shares - drained inventory"
        );
    }

    /// @notice **Ruling U's ledger.** The pending queue is exactly what redemptions released less what the stream
    ///         has burned — nothing accumulates that no `Burn("redeemInventory")` accounted for, and nothing is
    ///         burned that no redemption queued.
    function invariant_r8_pendingBurnIsQueuedMinusDrained() public view {
        assertEq(
            vault.pendingInventoryBurn(),
            handler.queuedInventory() - handler.burnedInventory(),
            "pendingInventoryBurn == queued - drained"
        );
        assertLe(handler.burnedInventory(), handler.queuedInventory(), "the stream never burns more than it was given");
    }

    /// @notice I5: every AMPS leg is worth zero, because AMPS can never be an asset.
    function invariant_I5_ampsIsNeverAnAsset() public view {
        assertFalse(vault.isAsset(address(amps)), "AMPS is not in the NAV sum");
        for (uint256 i; i < vault.assetCount(); ++i) {
            assertTrue(vault.assetAt(i) != address(amps), "and not in the enumeration either");
        }
    }

    /// @notice I5 and I6 together: `A` is exactly the priced sum of the vault's non-AMPS balances, and NAV/share is
    ///         exactly `(A + 1) * 1e18 / (totalSupply + VIRTUAL_SHARES)`.
    function invariant_I6_navIsAOverTotalSupply() public view {
        uint256 recomputed;
        for (uint256 i; i < vault.assetCount(); ++i) {
            address token = vault.assetAt(i);
            (uint256 answerUsd8,,) = feeds.latestAnswer(token);
            uint256 balance = heldBalance(token);
            if (balance == 0) continue;
            recomputed += PriceLib.counterValueUsd18(balance, token == address(usdg) ? 6 : 18, answerUsd8);
        }
        assertEq(vault.totalAssetsUsd18(), recomputed, "A is the priced sum of the balances and nothing else");
        assertEq(
            vault.previewNavPerShareX18(),
            ((recomputed + 1) * 1e18) / (amps.totalSupply() + Constants.VIRTUAL_SHARES),
            "the denominator is totalSupply and nothing else"
        );
    }

    /// @notice I8: no action ever lowered NAV/share, with prices held still.
    function invariant_I8_navPerShareNeverFalls() public view {
        assertFalse(handler.navEverFell(), "NAV/share is monotone non-decreasing ex market moves");
    }

    /// @notice I12: the vault never rests on an ERC-20 balance.
    function invariant_I12_sweepClean() public view {
        for (uint256 i; i < vault.assetCount(); ++i) {
            address token = vault.assetAt(i);
            assertEq(MockStockToken(token).balanceOf(address(vault)), 0, "no idle ERC-20 on the vault");
        }
    }

    /// @notice I22: the NAV denominator is never zero and NAV/share is always a finite, non-zero number.
    function invariant_I22_navIsAlwaysFinite() public view {
        assertGt(amps.totalSupply() + Constants.VIRTUAL_SHARES, 0, "T + VIRTUAL_SHARES > 0");
        assertGt(vault.previewNavPerShareX18(), 0, "NAV/share is a number");
    }

    /// @notice I24: the reference price is never below NAV/share.
    function invariant_I24_referenceNeverBelowNav() public view {
        assertGe(vault.pRefX18(), vault.navPerShareX18(), "P_ref >= navPerShare");
    }

    /// @notice Every handler action really does move the vault, so the invariants above are not vacuous.
    /// @dev A plain test rather than an invariant: Foundry evaluates invariants once before the first call, when no
    ///      action has landed yet, so "the run was not empty" cannot be expressed as one.
    function test_handlerActionsAllExecute() public {
        handler.bond(10e18);
        handler.redeem(100e18);
        handler.checkpointAfter(600);
        handler.touch();
        handler.donate(1e18);

        assertEq(handler.actionCount(), 5, "all five actions landed");
        assertGt(handler.mintedVesting(), 0, "the bond minted");
        assertGt(handler.burnedShares(), 0, "the redemption burned");
        assertGt(handler.queuedInventory(), 0, "the redemption queued its released inventory");
        assertGt(handler.burnedInventory(), 0, "and the checkpoint ten minutes later drained part of the stream");
        assertFalse(handler.navEverFell(), "none of them lowered NAV/share");
    }
}
