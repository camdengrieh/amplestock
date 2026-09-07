// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title VtSwapDoubleDeltaTest
/// @notice The plan's named attack **VTSwapHook double-positive-delta round trip**. The original hook returned a
///         *positive* delta on both currencies of a swap, so a round trip through it left the PoolManager owing
///         the swapper on both legs and the pool could be drained.
///
///         `AmpsHook` cannot express that bug: it carries neither returns-delta permission bit, so the PoolManager
///         never even reads a delta from it, and both callbacks return the zero value unconditionally, in every
///         reachable state, for every input.
contract VtSwapDoubleDeltaTest is Phase3Fixture {
    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        giveShares(ALICE, 200e18);
    }

    /// @notice `beforeSwap` returns `ZERO_DELTA` and `afterSwap` returns `0`, on both directions, on both exact
    ///         kinds, in the healthy state and with the whole oracle stack broken.
    function test_bothCallbacksAlwaysReturnZeroDeltas() public {
        _assertZeroDeltas("healthy");

        stockFeeds[0].setRevert(true);
        usdgFeed.setRevert(true);
        wethFeed.setRevert(true);
        vm.prank(TIMELOCK);
        vault.setPolicyPointer(bytes32("oracleGate"), address(0xDEAD));
        warpBy(3 days);
        _assertZeroDeltas("every dependency broken");
    }

    /// @notice And the economics: a same-transaction round trip through the pool returns strictly less than it
    ///         put in, on both orderings. There is no delta to double, so there is nothing to extract.
    function test_theRoundTripAlwaysLosesValue() public {
        (uint256 usdgIn, uint256 usdgOut) = this.buyThenSellEntry();
        assertLt(usdgOut, usdgIn, "buy then sell loses the two fees and the spread");

        (uint256 ampsIn, uint256 ampsOut) = this.sellThenBuyEntry();
        assertLt(ampsOut, ampsIn, "and so does sell then buy");
    }

    /// @notice One transaction: USDG in, AMPS out, USDG back.
    /// @return usdgIn USDG put in.
    /// @return usdgOut USDG taken back out.
    function buyThenSellEntry() external returns (uint256 usdgIn, uint256 usdgOut) {
        require(msg.sender == address(this), "self-call only");
        usdgIn = 2e6;
        uint256 bought = buyAmps(hubPool, ALICE, usdgIn);
        usdgOut = sellAmps(hubPool, ALICE, bought);
    }

    /// @notice One transaction: AMPS in, USDG out, AMPS back.
    /// @return ampsIn AMPS put in.
    /// @return ampsOut AMPS taken back out.
    function sellThenBuyEntry() external returns (uint256 ampsIn, uint256 ampsOut) {
        require(msg.sender == address(this), "self-call only");
        ampsIn = 5e18;
        uint256 usdg_ = sellAmps(hubPool, ALICE, ampsIn);
        ampsOut = buyAmps(hubPool, ALICE, usdg_);
    }

    /// @dev Both callbacks, both directions, both exact kinds.
    function _assertZeroDeltas(string memory context) private {
        PoolKey memory key = registry.poolKey(hubPool);
        for (uint256 i; i < 4; ++i) {
            SwapParams memory params = SwapParams({
                zeroForOne: i % 2 == 0, amountSpecified: i < 2 ? -int256(1e15) : int256(1e15), sqrtPriceLimitX96: 0
            });

            vm.prank(address(poolManager));
            (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(address(this), key, params, "");
            assertEq(
                BeforeSwapDelta.unwrap(delta),
                BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA),
                string.concat("beforeSwap returns ZERO_DELTA: ", context)
            );
            assertTrue(selector == hook.beforeSwap.selector, "and its own selector");
            assertGt(fee, 0, "with an override fee, which is the only thing it returns");

            vm.prank(address(poolManager));
            (bytes4 afterSelector, int128 hookDelta) =
                hook.afterSwap(address(this), key, params, toBalanceDelta(0, 0), "");
            assertEq(hookDelta, int128(0), string.concat("afterSwap returns 0: ", context));
            assertTrue(afterSelector == hook.afterSwap.selector, "and its own selector");
        }
    }
}
