// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Amps} from "../../src/token/Amps.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Fuzzes invariant I3 directly: over random sequences of mint/burn/transfer/transferFrom (and rejected
///         attempts at each), `totalSupply` moves only through a vault mint or burn, and no account's `balanceOf`
///         moves without a `Transfer` event carrying exactly that delta.
contract AmpsFuzzTest is Test {
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    uint256 internal constant ACTORS = 4;
    uint256 internal constant STEPS = 10;

    Amps internal amps;
    address internal vault = makeAddr("vault");
    address[ACTORS] internal actors;

    /// @dev Supply tracked independently of the token, moved only where the test itself minted or burned as vault.
    uint256 internal expectedSupply;

    function setUp() public {
        amps = new Amps(vault);
        actors[0] = vault;
        actors[1] = makeAddr("alice");
        actors[2] = makeAddr("bob");
        actors[3] = makeAddr("carol");
    }

    function testFuzz_supplyAndBalancesMoveOnlyWithEvents(
        uint8[STEPS] memory ops,
        uint8[STEPS] memory from,
        uint8[STEPS] memory to,
        uint96[STEPS] memory amounts
    ) public {
        for (uint256 i; i < STEPS; ++i) {
            uint256[ACTORS] memory balancesBefore = _balances();
            uint256 supplyBefore = amps.totalSupply();

            vm.recordLogs();
            _step(ops[i] % 8, actors[from[i] % ACTORS], actors[to[i] % ACTORS], amounts[i]);
            _assertLedgerMatchesEvents(balancesBefore, supplyBefore);

            assertEq(amps.totalSupply(), expectedSupply, "supply moved outside a vault mint/burn");
        }
    }

    /// @notice No caller other than the vault can move supply, whatever the arguments.
    function testFuzz_onlyVaultMovesSupply(address caller, address target, uint256 amount) public {
        vm.assume(caller != vault);
        vm.prank(vault);
        amps.mint(target == address(0) ? actors[1] : target, 1e18);
        uint256 supply = amps.totalSupply();

        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, caller));
        amps.mint(target, amount);
        vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, caller));
        amps.burn(target, amount);
        vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, caller));
        amps.setVault(target);
        vm.stopPrank();

        assertEq(amps.totalSupply(), supply);
        assertEq(amps.vault(), vault);
    }

    /* --------------------------------- steps -------------------------------- */

    function _step(uint8 op, address a, address b, uint96 raw) internal {
        if (op == 0) {
            // vault mint, the only way supply grows
            uint256 amount = uint256(raw);
            vm.prank(vault);
            amps.mint(b, amount);
            expectedSupply += amount;
        } else if (op == 1) {
            // vault burn, the only way supply shrinks
            uint256 amount = _bounded(raw, amps.balanceOf(a));
            vm.prank(vault);
            amps.burn(a, amount);
            expectedSupply -= amount;
        } else if (op == 2) {
            uint256 amount = _bounded(raw, amps.balanceOf(a));
            vm.prank(a);
            amps.transfer(b, amount);
        } else if (op == 3) {
            uint256 amount = _bounded(raw, amps.balanceOf(a));
            vm.prank(a);
            amps.approve(b, amount);
            vm.prank(b);
            amps.transferFrom(a, b, amount);
        } else if (op == 4) {
            // rejected mint by a non-vault caller
            address caller = a == vault ? actors[1] : a;
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, caller));
            amps.mint(b, uint256(raw));
        } else if (op == 5) {
            // rejected burn by a non-vault caller (including the holder itself)
            address caller = a == vault ? actors[2] : a;
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, caller));
            amps.burn(a, uint256(raw));
        } else if (op == 6) {
            // rejected transfer above balance
            uint256 balance = amps.balanceOf(a);
            uint256 amount = balance + uint256(raw) + 1;
            vm.prank(a);
            vm.expectRevert(
                abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", a, balance, amount)
            );
            amps.transfer(b, amount);
        } else {
            // rejected transferFrom without an allowance
            uint256 amount = uint256(raw) + 1;
            uint256 allowance = amps.allowance(a, b);
            if (allowance >= amount) return;
            vm.prank(b);
            vm.expectRevert(
                abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", b, allowance, amount)
            );
            amps.transferFrom(a, b, amount);
        }
    }

    /* -------------------------------- checking ------------------------------ */

    /// @dev Replays every `Transfer` the token emitted in the step and requires the ledger to match it exactly.
    function _assertLedgerMatchesEvents(uint256[ACTORS] memory balancesBefore, uint256 supplyBefore) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[ACTORS] memory credited;
        uint256[ACTORS] memory debited;
        uint256 minted;
        uint256 burned;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(amps) || logs[i].topics[0] != TRANSFER_TOPIC) continue;
            address sender = address(uint160(uint256(logs[i].topics[1])));
            address recipient = address(uint160(uint256(logs[i].topics[2])));
            uint256 value = abi.decode(logs[i].data, (uint256));

            if (sender == address(0)) {
                minted += value;
            } else {
                debited[_index(sender)] += value;
            }
            if (recipient == address(0)) {
                burned += value;
            } else {
                credited[_index(recipient)] += value;
            }
        }

        for (uint256 i; i < ACTORS; ++i) {
            assertEq(
                amps.balanceOf(actors[i]),
                balancesBefore[i] + credited[i] - debited[i],
                "balance moved without a matching Transfer"
            );
        }
        assertEq(amps.totalSupply(), supplyBefore + minted - burned, "supply moved without a Transfer");
    }

    function _balances() internal view returns (uint256[ACTORS] memory out) {
        for (uint256 i; i < ACTORS; ++i) {
            out[i] = amps.balanceOf(actors[i]);
        }
    }

    function _index(address account) internal view returns (uint256) {
        for (uint256 i; i < ACTORS; ++i) {
            if (actors[i] == account) return i;
        }
        revert("Transfer touched an account outside the actor set");
    }

    function _bounded(uint96 raw, uint256 max) internal pure returns (uint256) {
        return max == 0 ? 0 : uint256(raw) % (max + 1);
    }
}
