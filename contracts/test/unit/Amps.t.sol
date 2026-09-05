// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Amps} from "../../src/token/Amps.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Unit tests for the share token: metadata, the vault-only mint/burn/setVault surface and permit.
contract AmpsTest is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant VAULT_CHANGED_TOPIC = keccak256("VaultChanged(address,address)");

    Amps internal amps;
    address internal vault = makeAddr("vault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        amps = new Amps(vault);
    }

    /* ------------------------------- metadata ------------------------------- */

    function test_metadata() public view {
        assertEq(amps.name(), "Amplestocks");
        assertEq(amps.symbol(), "AMPS");
        assertEq(amps.decimals(), 18);
        assertEq(amps.totalSupply(), 0, "genesis supply is minted by the vault, not the constructor");
        assertEq(amps.vault(), vault);
    }

    function test_constructorRejectsZeroVault() public {
        vm.expectRevert(Amps.ZeroVault.selector);
        new Amps(address(0));
    }

    function test_constructorEmitsVaultChanged() public {
        vm.recordLogs();
        Amps token = new Amps(vault);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(token) || logs[i].topics[0] != VAULT_CHANGED_TOPIC) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(0), "previousVault");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), vault, "newVault");
            ++seen;
        }
        assertEq(seen, 1, "exactly one VaultChanged at construction");
    }

    /* ------------------------------ mint / burn ----------------------------- */

    function test_vaultMintsAndBurns() public {
        vm.prank(vault);
        amps.mint(alice, 1000e18);
        assertEq(amps.balanceOf(alice), 1000e18);
        assertEq(amps.totalSupply(), 1000e18);

        vm.prank(vault);
        amps.burn(alice, 400e18);
        assertEq(amps.balanceOf(alice), 600e18);
        assertEq(amps.totalSupply(), 600e18);
    }

    function test_mintRevertsForNonVault() public {
        // the deployer holds no privileges at all: the token has no owner
        vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, address(this)));
        amps.mint(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, alice));
        amps.mint(alice, 1e18);

        assertEq(amps.totalSupply(), 0);
    }

    function test_burnRevertsForNonVault() public {
        vm.prank(vault);
        amps.mint(alice, 1e18);

        vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, address(this)));
        amps.burn(alice, 1e18);

        // not even the holder may burn their own balance; only the vault retires supply
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, alice));
        amps.burn(alice, 1e18);

        assertEq(amps.totalSupply(), 1e18);
    }

    function test_burnRevertsAboveBalance() public {
        vm.prank(vault);
        amps.mint(alice, 1e18);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 2e18));
        amps.burn(alice, 2e18);
    }

    /* -------------------------------- setVault ------------------------------ */

    function test_setVaultMovesTheRoleAtomically() public {
        address newVault = makeAddr("newVault");

        vm.expectEmit(true, true, false, true, address(amps));
        emit Amps.VaultChanged(vault, newVault);
        vm.prank(vault);
        amps.setVault(newVault);

        assertEq(amps.vault(), newVault);

        vm.prank(newVault);
        amps.mint(alice, 1e18);
        assertEq(amps.balanceOf(alice), 1e18);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, vault));
        amps.mint(alice, 1e18);
    }

    function test_setVaultRevertsForNonVault() public {
        vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, address(this)));
        amps.setVault(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Amps.NotVault.selector, alice));
        amps.setVault(alice);

        assertEq(amps.vault(), vault);
    }

    function test_setVaultRejectsZero() public {
        vm.prank(vault);
        vm.expectRevert(Amps.ZeroVault.selector);
        amps.setVault(address(0));

        assertEq(amps.vault(), vault);
    }

    /* --------------------------------- permit ------------------------------- */

    function test_permit() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("permitOwner");
        vm.prank(vault);
        amps.mint(owner, 100e18);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonceBefore = amps.nonces(owner);
        bytes32 digest = _permitDigest(owner, bob, 25e18, nonceBefore, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        // anyone may relay the signature
        vm.prank(alice);
        amps.permit(owner, bob, 25e18, deadline, v, r, s);

        assertEq(amps.allowance(owner, bob), 25e18);
        assertEq(amps.nonces(owner), nonceBefore + 1);

        vm.prank(bob);
        amps.transferFrom(owner, bob, 25e18);
        assertEq(amps.balanceOf(bob), 25e18);
        assertEq(amps.allowance(owner, bob), 0);
    }

    function test_permitRevertsOnReplay() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(owner, bob, 1e18, amps.nonces(owner), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        amps.permit(owner, bob, 1e18, deadline, v, r, s);

        // the nonce has moved, so the same signature now recovers a different signer
        vm.expectRevert();
        amps.permit(owner, bob, 1e18, deadline, v, r, s);
    }

    function test_permitRevertsAfterDeadline() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp;
        bytes32 digest = _permitDigest(owner, bob, 1e18, amps.nonces(owner), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSignature("ERC2612ExpiredSignature(uint256)", deadline));
        amps.permit(owner, bob, 1e18, deadline, v, r, s);
    }

    function test_domainSeparatorIsStable() public {
        bytes32 expected = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Amplestocks")),
                keccak256(bytes("1")),
                block.chainid,
                address(amps)
            )
        );
        assertEq(amps.DOMAIN_SEPARATOR(), expected, "domain separator");

        // nothing in the token's own state may move it
        vm.startPrank(vault);
        amps.mint(alice, 1e18);
        amps.setVault(bob);
        vm.stopPrank();
        vm.prank(alice);
        amps.transfer(bob, 1e18);

        assertEq(amps.DOMAIN_SEPARATOR(), expected, "domain separator after state changes");
    }

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                amps.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
            )
        );
    }
}
