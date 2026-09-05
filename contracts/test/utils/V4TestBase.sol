// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Test} from "forge-std/Test.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title V4TestBase
/// @notice Local Uniswap v4 stack for tests. The PoolManager, PositionManager, Permit2 and the v4 swap router are
///         deployed from hookmate's pre-compiled artifacts so that no v4-core source (pinned to solc 0.8.26) enters the
///         compilation graph; every Amplestocks source and test compiles with solc 0.8.30.
/// @dev    On chain id 31337 fresh instances are deployed; on any other chain the canonical addresses from hookmate's
///         AddressConstants are used, which makes the same tests usable as fork tests.
abstract contract V4TestBase is Test {
    IPermit2 internal permit2;
    IPoolManager internal poolManager;
    IPositionManager internal positionManager;
    IUniswapV4Router04 internal swapRouter;

    address internal constant POOL_MANAGER_OWNER = address(0x4444);

    function deployV4() internal {
        _deployPermit2();
        _deployPoolManager();
        _deployPositionManager();
        _deployRouter();
        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(positionManager), "PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");
    }

    /// @notice Deploys a solmate MockERC20 minted to the test contract and approved for the local stack.
    function deployToken(string memory name, string memory symbol, uint8 decimals) internal returns (MockERC20 token) {
        token = new MockERC20(name, symbol, decimals);
        token.mint(address(this), 10_000_000 * (10 ** decimals));
        _approveStack(address(token));
    }

    /// @notice Deploys a MockERC20 whose runtime code is placed at `at`, so tests can control currency ordering
    ///         (AMPS must be currency0 in every Amplestocks pool). Name and symbol live in storage and are re-set.
    function deployTokenAt(address at, string memory name, string memory symbol, uint8 decimals)
        internal
        returns (MockERC20 token)
    {
        MockERC20 impl = new MockERC20(name, symbol, decimals);
        vm.etch(at, address(impl).code);
        token = MockERC20(at);
        // solmate stores name at slot 0 and symbol at slot 1; decimals is immutable and travels with the code.
        vm.store(at, bytes32(uint256(0)), _shortString(name));
        vm.store(at, bytes32(uint256(1)), _shortString(symbol));
        token.mint(address(this), 10_000_000 * (10 ** decimals));
        _approveStack(at);
        vm.label(at, symbol);
    }

    function _approveStack(address token) internal {
        MockERC20(token).approve(address(permit2), type(uint256).max);
        MockERC20(token).approve(address(swapRouter), type(uint256).max);
        MockERC20(token).approve(address(poolManager), type(uint256).max);
        permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(token, address(swapRouter), type(uint160).max, type(uint48).max);
    }

    function _deployPermit2() internal {
        address permit2Address = AddressConstants.getPermit2Address();
        if (permit2Address.code.length == 0) {
            vm.etch(permit2Address, Permit2Deployer.deploy().code);
        }
        permit2 = IPermit2(permit2Address);
    }

    function _deployPoolManager() internal {
        if (block.chainid == 31_337) {
            poolManager = IPoolManager(V4PoolManagerDeployer.deploy(POOL_MANAGER_OWNER));
        } else {
            poolManager = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
        }
    }

    function _deployPositionManager() internal {
        if (block.chainid == 31_337) {
            positionManager = IPositionManager(
                V4PositionManagerDeployer.deploy(
                    address(poolManager), address(permit2), 300_000, address(0), address(0)
                )
            );
        } else {
            positionManager = IPositionManager(AddressConstants.getPositionManagerAddress(block.chainid));
        }
    }

    function _deployRouter() internal {
        if (block.chainid == 31_337) {
            swapRouter = IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(poolManager), address(permit2))));
        } else {
            swapRouter = IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)));
        }
    }

    /// @dev Solidity short-string storage encoding (length < 32): data left-aligned, length*2 in the low byte.
    function _shortString(string memory s) private pure returns (bytes32 out) {
        bytes memory b = bytes(s);
        require(b.length < 32, "short string only");
        assembly ("memory-safe") {
            out := or(mload(add(b, 32)), mul(mload(b), 2))
        }
    }
}
