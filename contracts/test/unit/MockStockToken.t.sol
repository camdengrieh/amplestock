// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockStockToken} from "../mocks/MockStockToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Re-entered by {MockStockToken} while a transfer is in flight; records what the token's ledger looked like
///      at that instant, which is how the "before" and "after" modes are told apart.
contract ReentrantObserver {
    MockStockToken public token;
    address public watchedFrom;
    address public watchedTo;
    uint256 public calls;
    uint256 public balanceFrom;
    uint256 public balanceTo;
    bool public reverting;

    error ObserverReverted();

    function arm(MockStockToken token_, address from_, address to_) external {
        token = token_;
        watchedFrom = from_;
        watchedTo = to_;
    }

    function setReverting(bool reverting_) external {
        reverting = reverting_;
    }

    /// @notice Re-enters the token to read balances mid-transfer.
    function observe() external {
        ++calls;
        balanceFrom = token.balanceOf(watchedFrom);
        balanceTo = token.balanceOf(watchedTo);
        if (reverting) revert ObserverReverted();
    }

    /// @notice Re-enters the token's transfer path itself, the shape a real reentrancy attack takes.
    function reenterTransfer(address to, uint256 amount) external {
        ++calls;
        token.transfer(to, amount);
    }
}

/// @notice Unit tests for the Stock Token stand-in: beacon selector, denylist, pause, display multiplier and the
///         test-only reentrancy modes.
contract MockStockTokenTest is Test {
    MockStockToken internal stock;
    ReentrantObserver internal observer;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        stock = new MockStockToken("Mock NVDA", "NVDAx");
        observer = new ReentrantObserver();
        stock.mint(alice, 100e18);
    }

    /* -------------------------------- selector ------------------------------ */

    function test_blockAccountsSelectorMatchesTheBeacon() public pure {
        assertEq(
            MockStockToken.blockAccounts.selector,
            bytes4(keccak256("blockAccounts(address[])")),
            "selector must be derived from the observed signature"
        );
        assertEq(MockStockToken.blockAccounts.selector, bytes4(0x6abf7081), "observed beacon selector");
    }

    /* -------------------------------- metadata ------------------------------ */

    function test_metadata() public view {
        assertEq(stock.decimals(), 18);
        assertEq(stock.uiMultiplier(), 1e18);
        assertEq(stock.newUIMultiplier(), 0);
        assertEq(stock.effectiveAt(), 0);
        assertEq(stock.oraclePaused(), false);
    }

    /* -------------------------------- denylist ------------------------------ */

    function test_denylistBlocksBothDirections() public {
        address[] memory accounts = new address[](1);
        accounts[0] = alice;
        stock.blockAccounts(accounts);
        assertTrue(stock.isBlocked(alice));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountBlocked.selector, alice));
        stock.transfer(bob, 1e18);

        stock.mint(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountBlocked.selector, alice));
        stock.transfer(alice, 1e18);

        stock.unblockAccounts(accounts);
        assertFalse(stock.isBlocked(alice));
        vm.prank(alice);
        stock.transfer(bob, 1e18);
        assertEq(stock.balanceOf(bob), 11e18);
    }

    function test_denylistIsOwnerOnly() public {
        address[] memory accounts = new address[](1);
        accounts[0] = alice;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        stock.blockAccounts(accounts);
    }

    /* ---------------------------------- pause -------------------------------- */

    function test_pauseStopsTransfersAndMints() public {
        stock.pause();
        assertTrue(stock.paused());

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        stock.transfer(bob, 1e18);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        stock.mint(bob, 1e18);

        stock.unpause();
        vm.prank(alice);
        stock.transfer(bob, 1e18);
        assertEq(stock.balanceOf(bob), 1e18);
    }

    /* ------------------------------- multiplier ------------------------------ */

    function test_multiplierChangesNeverMoveRawBalances() public {
        uint256 balanceBefore = stock.balanceOf(alice);
        uint256 supplyBefore = stock.totalSupply();

        // an unannounced dividend-reinvestment step
        stock.setUIMultiplier(1.004e18);
        assertEq(stock.uiMultiplier(), 1.004e18);
        assertEq(stock.balanceOf(alice), balanceBefore, "raw balance must not move");
        assertEq(stock.totalSupply(), supplyBefore, "raw supply must not move");

        // a scheduled 4.0 split, as CRWD did
        stock.scheduleUIMultiplier(4e18, block.timestamp + 1 days);
        assertEq(stock.newUIMultiplier(), 4e18);
        assertEq(stock.effectiveAt(), block.timestamp + 1 days);

        stock.setOraclePaused(true);
        assertTrue(stock.oraclePaused());

        vm.warp(block.timestamp + 1 days);
        stock.applyScheduledUIMultiplier();
        assertEq(stock.uiMultiplier(), 4e18);
        assertEq(stock.newUIMultiplier(), 0);
        assertEq(stock.effectiveAt(), 0);
        assertEq(stock.balanceOf(alice), balanceBefore, "raw balance must not move across a split");
        assertEq(stock.totalSupply(), supplyBefore, "raw supply must not move across a split");

        stock.setOraclePaused(false);
        assertFalse(stock.oraclePaused());
    }

    function test_multiplierSettersAreOwnerOnly() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        stock.setUIMultiplier(2e18);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        stock.scheduleUIMultiplier(2e18, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        stock.setOraclePaused(true);
        vm.stopPrank();
    }

    /* ------------------------------- reentrancy ------------------------------ */

    function test_reentrancyModeNoneDoesNotCallBack() public {
        observer.arm(stock, alice, bob);
        stock.setReentrancy(0, address(observer), abi.encodeCall(ReentrantObserver.observe, ()));

        vm.prank(alice);
        stock.transfer(bob, 10e18);
        assertEq(observer.calls(), 0);
    }

    function test_reentrancyBeforeSeesPreTransferBalances() public {
        observer.arm(stock, alice, bob);
        stock.setReentrancy(1, address(observer), abi.encodeCall(ReentrantObserver.observe, ()));

        vm.prank(alice);
        stock.transfer(bob, 10e18);

        assertEq(observer.calls(), 1, "callback must fire");
        assertEq(observer.balanceFrom(), 100e18, "sender balance before the move");
        assertEq(observer.balanceTo(), 0, "recipient balance before the move");
        assertEq(stock.balanceOf(bob), 10e18);
    }

    function test_reentrancyAfterSeesPostTransferBalances() public {
        observer.arm(stock, alice, bob);
        stock.setReentrancy(2, address(observer), abi.encodeCall(ReentrantObserver.observe, ()));

        vm.prank(alice);
        stock.transfer(bob, 10e18);

        assertEq(observer.calls(), 1, "callback must fire");
        assertEq(observer.balanceFrom(), 90e18, "sender balance after the move");
        assertEq(observer.balanceTo(), 10e18, "recipient balance after the move");
    }

    function test_reentrancyFiresOnTransferFromToo() public {
        observer.arm(stock, alice, bob);
        stock.setReentrancy(1, address(observer), abi.encodeCall(ReentrantObserver.observe, ()));

        vm.prank(alice);
        stock.approve(address(this), 10e18);
        stock.transferFrom(alice, bob, 10e18);

        assertEq(observer.calls(), 1);
        assertEq(observer.balanceFrom(), 100e18);
        assertEq(stock.balanceOf(bob), 10e18);
    }

    function test_callbackCanReenterTheTransferPath() public {
        stock.mint(address(observer), 5e18);
        observer.arm(stock, alice, bob);
        stock.setReentrancy(1, address(observer), abi.encodeCall(ReentrantObserver.reenterTransfer, (bob, 5e18)));

        vm.prank(alice);
        stock.transfer(bob, 10e18);

        assertEq(observer.calls(), 1, "the nested transfer executed");
        assertEq(stock.balanceOf(address(observer)), 0, "observer moved its own balance mid-transfer");
        assertEq(stock.balanceOf(bob), 15e18, "both legs landed");
        assertEq(stock.balanceOf(alice), 90e18);
    }

    function test_callbackRevertBubblesUp() public {
        observer.arm(stock, alice, bob);
        observer.setReverting(true);
        stock.setReentrancy(2, address(observer), abi.encodeCall(ReentrantObserver.observe, ()));

        vm.prank(alice);
        vm.expectRevert(ReentrantObserver.ObserverReverted.selector);
        stock.transfer(bob, 10e18);

        assertEq(stock.balanceOf(alice), 100e18, "the whole transfer reverted");
    }
}
