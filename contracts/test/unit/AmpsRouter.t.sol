// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AmpsRouter} from "../../src/periphery/AmpsRouter.sol";
import {Constants} from "../../src/types/Constants.sol";
import {
    DeadlineExpired,
    NotPoolManager,
    NotWrappedNative,
    Reentrancy,
    SameHop,
    SlippageExceeded,
    UnexpectedValue,
    UnknownPool,
    ZeroAddress,
    ZeroAmount
} from "../../src/types/Errors.sol";
import {HookTestFixture} from "../mocks/HookTestFixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title AmpsRouterTest
/// @notice `AmpsRouter` end to end against the wired hook: the two fee prices it can obtain, the rotation's
///         structural guarantees, the WETH legs, the guards, and the custody rule that it holds nothing.
///
/// @dev **The one thing worth stating up front.** Being the router buys exactly one privilege: a hop this
///      contract flags with `Constants.ROUTER_ROTATE` is priced at the pool's `buyFeeBps` instead of the
///      protocol-wide `ampsFeeBps`. It flags exactly the two hops of {AmpsRouter-rotate}. Its own {AmpsRouter-buy}
///      and {AmpsRouter-sell} do not carry the flag and pay the AMPS fee, which is what stops "route your exit
///      through the protocol's front end" from being a discount.
contract AmpsRouterTest is HookTestFixture {
    uint256 internal constant USDG_IN = 10_000e6;
    uint256 internal constant STOCK_IN = 50e18;
    uint256 internal constant WETH_IN = 2e18;
    uint256 internal constant AMPS_IN = 1000e18;

    uint24 internal constant AMPS_FEE_PIPS = uint24(Constants.AMPS_FEE_BPS_DEFAULT) * Constants.PIPS_PER_BPS;
    uint24 internal constant ENTRY_PASS_THROUGH_PIPS =
        uint24(Constants.BUY_FEE_BPS_ENTRY_DEFAULT) * Constants.PIPS_PER_BPS;
    uint24 internal constant SPOKE_PASS_THROUGH_PIPS =
        uint24(Constants.BUY_FEE_BPS_SPOKE_DEFAULT) * Constants.PIPS_PER_BPS;

    address internal constant RECIPIENT = address(0x4EC1);

    function setUp() public {
        _deployFixture();
        // This suite is about which base fee each shape pays, so the dynamic part is pinned to zero: without it a
        // swap's own realised variance moves `f_vol` by a basis point and the base stops being readable off the
        // `Swap` event.
        policy.setDynOverride(0);
        usdg.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        amps.approve(address(router), type(uint256).max);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Wiring
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The transient lock slot the router writes is the one its comment claims.
    /// @dev The literal exists because inline assembly takes only direct number constants; this is the drift
    ///      guard on it, and it fails the moment either side is edited alone.
    function test_theLockSlotIsTheDeclaredString() public pure {
        assertEq(
            keccak256("amplestocks.router.REENTRANCY_LOCK"),
            0x8d4554710d68d2fa17f9017173db9ef290e4bf31a3eb1b9b04bd1274abd91940,
            "the literal in AmpsRouter.REENTRANCY_LOCK"
        );
    }

    /// @notice The flag the router sets is the flag the hook checks, and both are the declared string.
    function test_theRotateFlagIsTheOneTheHookChecks() public view {
        assertEq(router.ROTATE_FLAG(), Constants.ROUTER_ROTATE, "the router flags what Constants declares");
        assertEq(Constants.ROUTER_ROTATE, keccak256("amplestocks.router.ROTATE"), "and the string behind it");
    }

    function test_thePointers() public view {
        assertEq(router.poolManager(), address(poolManager), "poolManager");
        assertEq(router.amps(), AMPS_ADDRESS, "amps");
        assertEq(router.registry(), address(registry), "registry");
        assertEq(router.weth(), WETH_ADDRESS, "weth");
        assertEq(hook.router(), address(router), "and the hook names it");
    }

    function test_theConstructorRefusesAZeroPointer() public {
        vm.expectRevert(ZeroAddress.selector);
        new AmpsRouter(poolManager, address(0), address(registry), WETH_ADDRESS);
        vm.expectRevert(ZeroAddress.selector);
        new AmpsRouter(poolManager, AMPS_ADDRESS, address(0), WETH_ADDRESS);
        vm.expectRevert(ZeroAddress.selector);
        new AmpsRouter(poolManager, AMPS_ADDRESS, address(registry), address(0));
    }

    // -----------------------------------------------------------------------------------------------------------
    // What each shape pays (I16)
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A buy through the protocol router pays the AMPS fee, exactly like a buy through anything else.
    ///         Being the router is not itself a discount.
    function test_buyPaysTheAmpsFee() public {
        vm.recordLogs();
        uint256 ampsOut = router.buy(usdgId, USDG_IN, 0, address(this), type(uint256).max);

        assertGt(ampsOut, 0, "the buy happened");
        assertEq(_lastSwapFee(vm.getRecordedLogs()), AMPS_FEE_PIPS, "500 bp, not 30");
    }

    /// @notice And so does a sell.
    function test_sellPaysTheAmpsFee() public {
        uint256 ampsOut = router.buy(usdgId, USDG_IN, 0, address(this), type(uint256).max);

        vm.recordLogs();
        uint256 out = router.sell(usdgId, ampsOut, 0, address(this), false, type(uint256).max);

        assertGt(out, 0, "the sell happened");
        assertEq(_lastSwapFee(vm.getRecordedLogs()), AMPS_FEE_PIPS, "500 bp");
    }

    /// @notice The rotation is the one shape that pays the pass-through fee, and it pays each pool's own.
    function test_rotatePaysThePassThroughFeeOnBothHops() public {
        vm.recordLogs();
        (uint256 amountOut, uint256 ampsThrough) =
            router.rotate(stockId, usdgId, STOCK_IN, 0, address(this), false, type(uint256).max);

        uint24[] memory fees = _swapFees(vm.getRecordedLogs());
        assertEq(fees.length, 2, "two hops");
        assertEq(fees[0], SPOKE_PASS_THROUGH_PIPS, "hop 1: the spoke's pass-through fee");
        assertEq(fees[1], ENTRY_PASS_THROUGH_PIPS, "hop 2: the entry pool's pass-through fee");
        assertGt(amountOut, 0, "USDG came out");
        assertGt(ampsThrough, 0, "AMPS went through");
    }

    /// @notice The router's own `buy` then `sell` inside one transaction is a round trip, not a rotation: it pays
    ///         the AMPS fee twice and earns no credit, because neither hop carries the flag.
    function test_buyThenSellInOneTransactionPaysTheAmpsFeeTwice() public {
        vm.recordLogs();
        uint256 creditAfter = this.roundTripEntry();

        uint24[] memory fees = _swapFees(vm.getRecordedLogs());
        assertEq(fees.length, 2, "two swaps");
        assertEq(fees[0], AMPS_FEE_PIPS, "the buy leg");
        assertEq(fees[1], AMPS_FEE_PIPS, "and the sell leg, undiscounted");
        assertEq(creditAfter, 0, "no credit was ever created");
    }

    /// @notice Self-call entry point: buy then sell inside one transaction's transient storage.
    function roundTripEntry() external returns (uint256 creditAfter) {
        require(msg.sender == address(this), "self-call only");
        assertEq(hook.rotationCredit(address(router)), 0, "the router starts with no credit");
        uint256 ampsOut = router.buy(usdgId, USDG_IN, 0, address(this), type(uint256).max);
        assertEq(hook.rotationCredit(address(router)), 0, "and an unflagged buy creates none");
        router.sell(usdgId, ampsOut, 0, address(this), false, type(uint256).max);
        creditAfter = hook.rotationCredit(address(router));
    }

    /// @notice The rotation really is worth what it costs less: the same two legs as ordinary trades realise less
    ///         USDG, and the gap is the fee the rotation did not pay.
    function test_theRotationBeatsTheSameTwoTradesTakenSeparately() public {
        uint256 snap = vm.snapshotState();
        (uint256 rotated,) = router.rotate(stockId, usdgId, STOCK_IN, 0, address(this), false, type(uint256).max);
        vm.revertToState(snap);

        uint256 ampsOut = router.buy(stockId, STOCK_IN, 0, address(this), type(uint256).max);
        uint256 separately = router.sell(usdgId, ampsOut, 0, address(this), false, type(uint256).max);

        assertGt(rotated, separately, "the rotation keeps more");
        // Hop 1 at 5 bp instead of 500, hop 2 at 30 bp instead of 500: (0.9995 * 0.997) / (0.95 * 0.95) ~ 1.104.
        assertApproxEqRel((rotated * 1e18) / separately, 1.104e18, 0.02e18, "both hops' saving");
    }

    // -----------------------------------------------------------------------------------------------------------
    // The rotation's structural guarantees
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A rotation cannot leave AMPS with the caller: hop 2 sells exactly what hop 1 realised, and the
    ///         router asserts its own AMPS delta is zero before it settles anything.
    function test_aRotationCannotLeaveAmpsWithAnybody() public {
        uint256 callerBefore = amps.balanceOf(address(this));
        (, uint256 ampsThrough) = router.rotate(stockId, usdgId, STOCK_IN, 0, RECIPIENT, false, type(uint256).max);

        assertGt(ampsThrough, 0, "AMPS did pass through");
        assertEq(amps.balanceOf(address(this)), callerBefore, "the caller holds not one wei more");
        assertEq(amps.balanceOf(RECIPIENT), 0, "and neither does the recipient");
        assertEq(amps.balanceOf(address(router)), 0, "nor the router");
    }

    /// @notice The credit a rotation creates is spent by the same rotation and is gone when it returns.
    function test_theCreditIsCreatedAndSpentInsideTheRotation() public {
        uint256 creditAfter = this.rotationCreditEntry();
        assertEq(creditAfter, 0, "hop 2 consumed the whole credit");
    }

    /// @notice Self-call entry point, so the transient credit is observable across the rotation's own frame.
    function rotationCreditEntry() external returns (uint256 creditAfter) {
        require(msg.sender == address(this), "self-call only");
        assertEq(hook.rotationCredit(address(router)), 0, "nothing carries in");
        router.rotate(stockId, usdgId, STOCK_IN, 0, address(this), false, type(uint256).max);
        creditAfter = hook.rotationCredit(address(router));
    }

    /// @notice Both hops must be different pools: buying AMPS in a pool and selling it straight back is a round
    ///         trip on one curve, not a rotation, and two pass-through fees would make the pool's own liquidity
    ///         pay for the caller's noise.
    function test_rotateRefusesTheSamePoolTwice() public {
        vm.expectRevert(abi.encodeWithSelector(SameHop.selector, PoolId.unwrap(usdgId)));
        router.rotate(usdgId, usdgId, USDG_IN, 0, address(this), false, type(uint256).max);
    }

    /// @notice A pool the registry does not know cannot be traded, on any entry point.
    function test_everyEntryPointRefusesAnUnregisteredPool() public {
        PoolId ghost = PoolId.wrap(keccak256("no such pool"));

        vm.expectRevert(abi.encodeWithSelector(UnknownPool.selector, PoolId.unwrap(ghost)));
        router.buy(ghost, USDG_IN, 0, address(this), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(UnknownPool.selector, PoolId.unwrap(ghost)));
        router.sell(ghost, AMPS_IN, 0, address(this), false, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(UnknownPool.selector, PoolId.unwrap(ghost)));
        router.rotate(ghost, usdgId, USDG_IN, 0, address(this), false, type(uint256).max);
    }

    /// @notice A registry that answers with some *other* pool's key is caught: the key is re-hashed and compared
    ///         with the id that asked for it.
    function test_aKeyThatDoesNotHashToItsOwnIdIsRefused() public {
        registry.setPoolKey(stockId, usdgKey);
        vm.expectRevert(abi.encodeWithSelector(UnknownPool.selector, PoolId.unwrap(stockId)));
        router.buy(stockId, STOCK_IN, 0, address(this), type(uint256).max);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Guards
    // -----------------------------------------------------------------------------------------------------------

    function test_everyEntryPointHonoursItsDeadline() public {
        uint256 past = block.timestamp - 1;

        vm.expectRevert(abi.encodeWithSelector(DeadlineExpired.selector, past, block.timestamp));
        router.buy(usdgId, USDG_IN, 0, address(this), past);

        vm.expectRevert(abi.encodeWithSelector(DeadlineExpired.selector, past, block.timestamp));
        router.sell(usdgId, AMPS_IN, 0, address(this), false, past);

        vm.expectRevert(abi.encodeWithSelector(DeadlineExpired.selector, past, block.timestamp));
        router.rotate(stockId, usdgId, STOCK_IN, 0, address(this), false, past);
    }

    function test_everyEntryPointHonoursItsMinimum() public {
        vm.expectRevert();
        router.buy(usdgId, USDG_IN, type(uint256).max, address(this), type(uint256).max);

        uint256 ampsOut = router.buy(usdgId, USDG_IN, 0, address(this), type(uint256).max);
        vm.expectRevert();
        router.sell(usdgId, ampsOut, type(uint256).max, address(this), false, type(uint256).max);

        vm.expectRevert();
        router.rotate(stockId, usdgId, STOCK_IN, type(uint256).max, address(this), false, type(uint256).max);
    }

    /// @notice The minimum really is `SlippageExceeded` and it really carries both numbers.
    function test_theSlippageRevertNamesWhatWasReceived() public {
        uint256 snap = vm.snapshotState();
        uint256 ampsOut = router.buy(usdgId, USDG_IN, 0, address(this), type(uint256).max);
        vm.revertToState(snap);

        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, ampsOut, ampsOut + 1));
        router.buy(usdgId, USDG_IN, ampsOut + 1, address(this), type(uint256).max);
    }

    function test_zeroAmountsAndZeroRecipientsAreRefused() public {
        vm.expectRevert(ZeroAmount.selector);
        router.buy(usdgId, 0, 0, address(this), type(uint256).max);

        vm.expectRevert(ZeroAddress.selector);
        router.buy(usdgId, USDG_IN, 0, address(0), type(uint256).max);

        vm.expectRevert(ZeroAmount.selector);
        router.sell(usdgId, 0, 0, address(this), false, type(uint256).max);

        vm.expectRevert(ZeroAmount.selector);
        router.rotate(stockId, usdgId, 0, 0, address(this), false, type(uint256).max);
    }

    /// @notice `unlockCallback` is the PoolManager's alone, and only inside an unlock this contract opened: the
    ///         transient lock is clear otherwise, so a third party's unlock cannot make the router swap.
    function test_theUnlockCallbackIsRefusedFromEverywhereElse() public {
        vm.expectRevert(abi.encodeWithSelector(NotPoolManager.selector, address(this)));
        router.unlockCallback("");

        vm.prank(address(poolManager));
        vm.expectRevert(Reentrancy.selector);
        router.unlockCallback("");
    }

    /// @notice Ether is accepted from WETH alone. Everything else is somebody's mistake, and a mistake this
    ///         contract kept would be swept to whoever traded next.
    function test_etherIsAcceptedFromWethAlone() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok, "a stranger's ether is refused");
        assertEq(address(router).balance, 0, "and none of it stuck");
    }

    // -----------------------------------------------------------------------------------------------------------
    // The WETH legs
    // -----------------------------------------------------------------------------------------------------------

    /// @notice `msg.value` is wrapped when the pool's counter really is WETH, and the AMPS lands with `to`.
    function test_buyWrapsNativeValue() public {
        vm.deal(address(this), WETH_IN);
        uint256 before = amps.balanceOf(RECIPIENT);

        uint256 ampsOut = router.buy{value: WETH_IN}(wethId, WETH_IN, 0, RECIPIENT, type(uint256).max);

        assertGt(ampsOut, 0, "the buy happened");
        assertEq(amps.balanceOf(RECIPIENT) - before, ampsOut, "the AMPS went to the recipient");
        assertEq(address(this).balance, 0, "and the ether was spent, not refunded");
        assertEq(address(router).balance, 0, "the router kept none");
        assertEq(weth.balanceOf(address(router)), 0, "and no WETH either");
    }

    /// @notice `msg.value` must equal the amount being swapped. A router that accepted more and refunded the rest
    ///         would be a router that can be made to send ether somewhere in the middle of a swap.
    function test_buyRefusesAValueThatDoesNotMatchTheAmount() public {
        vm.deal(address(this), 3e18);
        vm.expectRevert(abi.encodeWithSelector(UnexpectedValue.selector, 3e18));
        router.buy{value: 3e18}(wethId, WETH_IN, 0, address(this), type(uint256).max);
    }

    /// @notice Value on a pool whose counter is not WETH is refused rather than silently wrapped.
    function test_valueOnANonWethPoolIsRefused() public {
        vm.deal(address(this), 1e18);
        vm.expectRevert(abi.encodeWithSelector(NotWrappedNative.selector, USDG_ADDRESS));
        router.buy{value: 1e18}(usdgId, 1e18, 0, address(this), type(uint256).max);
    }

    /// @notice The output is unwrapped to ether when asked, and it lands with `to`.
    function test_sellUnwrapsToEther() public {
        uint256 ampsOut = router.buy(wethId, WETH_IN, 0, address(this), type(uint256).max);

        uint256 out = router.sell(wethId, ampsOut, 0, RECIPIENT, true, type(uint256).max);

        assertGt(out, 0, "the sell happened");
        assertEq(RECIPIENT.balance, out, "paid as ether");
        assertEq(weth.balanceOf(RECIPIENT), 0, "and not as WETH");
        assertEq(address(router).balance, 0, "the router kept none");
    }

    /// @notice And `unwrap` on a pool whose counter is not WETH is a caller error, not a silent no-op.
    function test_unwrapOnANonWethPoolIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(NotWrappedNative.selector, USDG_ADDRESS));
        router.sell(usdgId, AMPS_IN, 0, address(this), true, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(NotWrappedNative.selector, USDG_ADDRESS));
        router.rotate(stockId, usdgId, STOCK_IN, 0, address(this), true, type(uint256).max);
    }

    /// @notice A rotation into the WETH pool can pay out as ether too.
    function test_rotateUnwrapsToEther() public {
        (uint256 amountOut,) = router.rotate(stockId, wethId, STOCK_IN, 0, RECIPIENT, true, type(uint256).max);
        assertGt(amountOut, 0, "the rotation happened");
        assertEq(RECIPIENT.balance, amountOut, "paid as ether");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Custody
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The router holds nothing after any of the three shapes.
    function test_theRouterHoldsNothingAfterATrade() public {
        router.buy(usdgId, USDG_IN, 0, address(this), type(uint256).max);
        _assertRouterIsEmpty("after a buy");

        router.sell(usdgId, AMPS_IN, 0, address(this), false, type(uint256).max);
        _assertRouterIsEmpty("after a sell");

        router.rotate(stockId, usdgId, STOCK_IN, 0, address(this), false, type(uint256).max);
        _assertRouterIsEmpty("after a rotation");
    }

    /// @notice Dust sent to the router is swept to the next caller rather than bricking the route.
    /// @dev The alternative — asserting `balanceOf(this) == 0` — would let anybody disable every trade through a
    ///      pool for the price of one wei of its counter asset, permanently, because nothing could clear it.
    function test_donatedDustIsSweptToTheNextCallerRatherThanBrickingTheRoute() public {
        usdg.transfer(address(router), 1234);
        assertEq(usdg.balanceOf(address(router)), 1234, "the donation landed");

        uint256 before = usdg.balanceOf(address(this));
        uint256 ampsOut = router.buy(usdgId, USDG_IN, 0, address(this), type(uint256).max);

        assertGt(ampsOut, 0, "the trade still went through");
        assertEq(usdg.balanceOf(address(router)), 0, "and the dust left with it");
        assertEq(usdg.balanceOf(address(this)), before - USDG_IN + 1234, "swept to the caller");
    }

    function _assertRouterIsEmpty(string memory what) private view {
        assertEq(amps.balanceOf(address(router)), 0, string.concat("AMPS ", what));
        assertEq(usdg.balanceOf(address(router)), 0, string.concat("USDG ", what));
        assertEq(weth.balanceOf(address(router)), 0, string.concat("WETH ", what));
        assertEq(stock.balanceOf(address(router)), 0, string.concat("STOCK ", what));
        assertEq(address(router).balance, 0, string.concat("ether ", what));
    }

    /// @dev The suite receives ether on the unwrap paths it drives from `address(this)`.
    receive() external payable {}
}
