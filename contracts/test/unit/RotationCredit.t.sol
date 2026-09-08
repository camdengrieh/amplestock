// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsHook} from "../../src/interfaces/IAmpsHook.sol";
import {Constants} from "../../src/types/Constants.sol";
import {HookTestFixture} from "../mocks/HookTestFixture.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title RotationCreditTest
/// @notice I26 end to end, in its revision-6 shape: the same-transaction rotation credit exists **only** for the
///         protocol router's rotation hops, is credited by the AMPS such a hop actually received, is consumed
///         only by a flagged exact-input sell, blended and rounded up, and is gone at every transaction boundary.
///
/// @dev **What changed, and why it matters to this suite.** Revision 5 credited every buy, from every sender. A
///      credit was therefore something anyone could manufacture — a dust buy minted a discount that any sell in
///      the same transaction could spend, and a settlement contract batching two unrelated parties blended a
///      stranger's entry into its own exit. Revision 6 keys the whole mechanism to a single governed address and
///      a single flag: `sender == hook.router()` **and** `hookData == Constants.ROUTER_ROTATE`. Everything else
///      pays `ampsFeeBps` in both directions and touches the slot not at all. Most of the tests below are
///      therefore negative: they check that the credit does *not* appear.
///
/// @dev **Every scenario that spans two hops runs inside one self-call.** Foundry 1.8 clears EIP-1153 transient
///      storage between the top-level calls a test makes, so a buy and the sell that spends its credit have to
///      share one call frame to be faithful to the EVM — the same reason `test/gas/GasBaseline.t.sol` uses
///      `this.roundTripEntry()`. A scenario written as two plain statements would silently test nothing.
contract RotationCreditTest is HookTestFixture {
    uint256 internal constant USDG_IN = 10_000e6;
    uint256 internal constant STOCK_IN = 50e18;

    /// @dev Two unrelated parties whose swaps the PoolManager reports under two different `sender`s.
    address internal constant BUYER = address(0xB0B);
    address internal constant FILLER = address(0xF111E5);

    /// @dev The AMPS a seeded buy realises, and therefore the credit it earns.
    uint256 internal constant CREDITED_AMPS = 1000e18;

    uint24 internal constant AMPS_FEE_PIPS = uint24(Constants.AMPS_FEE_BPS_DEFAULT) * Constants.PIPS_PER_BPS;
    uint24 internal constant ENTRY_PASS_THROUGH_PIPS =
        uint24(Constants.BUY_FEE_BPS_ENTRY_DEFAULT) * Constants.PIPS_PER_BPS;
    uint24 internal constant SPOKE_PASS_THROUGH_PIPS =
        uint24(Constants.BUY_FEE_BPS_SPOKE_DEFAULT) * Constants.PIPS_PER_BPS;

    /// @dev The `hookData` the protocol router puts on both hops of a rotation, and the only bytes that mean
    ///      anything to the hook.
    bytes internal rotateFlag;

    function setUp() public {
        _deployFixture();
        rotateFlag = abi.encode(Constants.ROUTER_ROTATE);
        // This suite is about the *base* fee - the blend, the credit and its boundaries - so the dynamic part is
        // pinned to zero and every assertion below is about the base alone. `AmpsHookFee.t.sol` is where the
        // dynamic components are exercised; without this a swap's own realised variance moves `f_vol` by a basis
        // point and the blend arithmetic stops being visible in the `Swap` event.
        policy.setDynOverride(0);
    }

    // -----------------------------------------------------------------------------------------------------------
    // The slot itself
    // -----------------------------------------------------------------------------------------------------------

    /// @notice The transient slot the hook writes is the one `Constants` declares.
    /// @dev The hook spells it as a literal because inline assembly takes only direct number constants. This is
    ///      the drift guard on that literal: it fails the moment either side is edited alone.
    function test_theTransientSlotIsTheDeclaredConstant() public pure {
        assertEq(
            uint256(Constants.ROTATION_CREDIT_SLOT),
            0x28ef4cf38086db5318537797461c68e4f15873dbd0e73f3e45f6b1f32032b976,
            "the literal in AmpsHook.ROTATION_CREDIT_SLOT"
        );
        assertEq(
            Constants.ROTATION_CREDIT_SLOT,
            keccak256("amplestocks.hook.ROTATION_CREDIT"),
            "and the string it is derived from"
        );
    }

    /// @notice And the flag that unlocks it is the one `Constants` declares.
    function test_theRotateFlagIsTheDeclaredConstant() public view {
        assertEq(Constants.ROUTER_ROTATE, keccak256("amplestocks.router.ROTATE"), "the string behind the flag");
        assertEq(router.ROTATE_FLAG(), Constants.ROUTER_ROTATE, "and the router sets exactly it");
    }

    function test_theCreditIsZeroInAFreshTransaction() public view {
        assertEq(hook.rotationCredit(address(router)), 0, "nothing carries in");
        assertEq(hook.rotationCredit(address(swapRouter)), 0, "for anybody");
    }

    // -----------------------------------------------------------------------------------------------------------
    // The rotation itself
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A one-transaction stock -> AMPS -> USDG rotation through the protocol router pays each pool's
    ///         pass-through fee, and leaves no credit behind.
    function test_theRouterRotationPaysPassThroughOnBothHops() public {
        vm.recordLogs();
        uint256 creditAfter = this.rotationEntry(STOCK_IN);

        uint24[] memory fees = _swapFees(vm.getRecordedLogs());
        assertEq(fees.length, 2, "two hops");
        assertEq(fees[0], SPOKE_PASS_THROUGH_PIPS, "hop 1: the spoke's pass-through fee");
        assertEq(fees[1], ENTRY_PASS_THROUGH_PIPS, "hop 2: credited, so the entry pool's pass-through fee");
        assertEq(creditAfter, 0, "hop 2 consumed the whole credit");
    }

    /// @notice Self-call entry point: the whole rotation inside one transaction's transient storage.
    function rotationEntry(uint256 amountIn) external returns (uint256 creditAfter) {
        require(msg.sender == address(this), "self-call only");
        assertEq(hook.rotationCredit(address(router)), 0, "the credit starts at zero");
        _routerRotate(stockKey, usdgKey, amountIn);
        creditAfter = hook.rotationCredit(address(router));
    }

    /// @notice The same two hops built by hand through a general-purpose router pay the AMPS fee twice: the
    ///         exemption is the protocol router's, not the route's.
    function test_theSameTwoHopsThroughAnotherRouterPayTheAmpsFeeTwice() public {
        vm.recordLogs();
        uint256 creditAfter = this.foreignRotationEntry(STOCK_IN);

        uint24[] memory fees = _swapFees(vm.getRecordedLogs());
        assertEq(fees.length, 2, "two hops");
        assertEq(fees[0], AMPS_FEE_PIPS, "hop 1 pays the AMPS fee");
        assertEq(fees[1], AMPS_FEE_PIPS, "and so does hop 2");
        assertEq(creditAfter, 0, "nothing was ever credited");
    }

    /// @notice Self-call entry point: the two-hop `PathKey` route through the generic v4 router.
    function foreignRotationEntry(uint256 amountIn) external returns (uint256 creditAfter) {
        require(msg.sender == address(this), "self-call only");
        _rotate(address(stock), USDG_ADDRESS, amountIn);
        creditAfter = hook.rotationCredit(address(swapRouter));
    }

    /// @notice A rotation really is worth more than the same two legs taken as ordinary trades, and the
    ///         difference is exactly the fee the rotation did not pay.
    function test_theRotationIsWorthWhatItSaves() public {
        uint256 snap = vm.snapshotState();
        (uint256 rotated,) = this.rotationOutEntry(STOCK_IN);
        vm.revertToState(snap);

        // The same two legs as ordinary trades: no flag, no credit, the AMPS fee on both.
        uint256 ampsOut = _buy(stockKey, STOCK_IN);
        uint256 uncredited = _sell(usdgKey, ampsOut);

        assertGt(rotated, uncredited, "the rotation keeps more USDG");
        // Hop 1 at 5 bp instead of 500, hop 2 at 30 bp instead of 500: (0.9995 * 0.997) / (0.95 * 0.95) ~ 1.104.
        assertApproxEqRel((rotated * 1e18) / uncredited, 1.104e18, 0.02e18, "both hops' saving");
    }

    /// @notice Self-call entry point: the rotation, and what it paid out.
    function rotationOutEntry(uint256 amountIn) external returns (uint256 usdgOut, uint256 ampsThrough) {
        require(msg.sender == address(this), "self-call only");
        (usdgOut, ampsThrough) = _routerRotate(stockKey, usdgKey, amountIn);
    }

    // -----------------------------------------------------------------------------------------------------------
    // What no longer earns a credit (revision 6)
    // -----------------------------------------------------------------------------------------------------------

    /// @notice An ordinary buy earns nothing. Under revision 5 this was the whole attack surface.
    function test_anOrdinaryBuyEarnsNoCredit() public {
        (uint256 routerCredit, uint256 v4RouterCredit, uint256 bought) = this.ordinaryBuyEntry(USDG_IN);

        assertGt(bought, 0, "the buy happened");
        assertEq(v4RouterCredit, 0, "the router that settled it holds nothing");
        assertEq(routerCredit, 0, "and neither does the protocol router");
    }

    /// @notice Self-call entry point: one ordinary buy, and who holds a credit afterwards.
    function ordinaryBuyEntry(uint256 amountIn)
        external
        returns (uint256 routerCredit, uint256 v4RouterCredit, uint256 bought)
    {
        require(msg.sender == address(this), "self-call only");
        bought = _buy(usdgKey, amountIn);
        routerCredit = hook.rotationCredit(address(router));
        v4RouterCredit = hook.rotationCredit(address(swapRouter));
    }

    /// @notice The protocol router's own unflagged buy earns nothing either: being the router is not the
    ///         exemption, carrying the flag is.
    function test_theRouterWithoutTheFlagEarnsNothing() public {
        (uint256 credit, uint24 buyFee) = this.routerPlainBuyEntry(USDG_IN);
        assertEq(credit, 0, "no credit");
        assertEq(buyFee, AMPS_FEE_PIPS, "and the buy paid the AMPS fee");
    }

    /// @notice Self-call entry point: `AmpsRouter.buy`, which passes empty `hookData`.
    function routerPlainBuyEntry(uint256 amountIn) external returns (uint256 credit, uint24 buyFee) {
        require(msg.sender == address(this), "self-call only");
        vm.recordLogs();
        _routerBuy(usdgKey, amountIn);
        buyFee = _lastSwapFee(vm.getRecordedLogs());
        credit = hook.rotationCredit(address(router));
    }

    /// @notice A forged flag from a sender that is not the router buys nothing at all: no credit on the buy, and
    ///         the full AMPS fee on the sell.
    /// @dev Driven through the callbacks directly, because a forged `hookData` is precisely what no honest router
    ///      will send. This is the shape an attacker would build by hand.
    function test_aForgedFlagFromAStrangerBuysNothing() public {
        (uint256 credit, uint24 sellFee) = this.forgedFlagEntry();
        assertEq(credit, 0, "a stranger's flagged buy credits nothing");
        assertEq(
            sellFee,
            AMPS_FEE_PIPS | LPFeeLibrary.OVERRIDE_FEE_FLAG,
            "and the stranger's flagged sell pays the AMPS fee in full"
        );
    }

    /// @notice Self-call entry point: a stranger claiming the exemption with the right bytes and the wrong
    ///         address.
    function forgedFlagEntry() external returns (uint256 credit, uint24 sellFee) {
        require(msg.sender == address(this), "self-call only");

        SwapParams memory buy = SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(FILLER, usdgKey, buy, toBalanceDelta(int128(uint128(CREDITED_AMPS)), int128(-1)), rotateFlag);
        credit = hook.rotationCredit(FILLER);

        SwapParams memory sell =
            SwapParams({zeroForOne: true, amountSpecified: -int256(CREDITED_AMPS), sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        (,, sellFee) = hook.beforeSwap(FILLER, usdgKey, sell, rotateFlag);
    }

    /// @notice A credit the router holds is the router's: another sender's flagged sell cannot spend it.
    function test_oneSendersCreditDoesNotDiscountAnothersSell() public {
        (uint256 routerCredit, uint256 fillerCredit, uint24 fillerFee, uint24 routerFee) = this.twoSendersEntry();

        assertEq(routerCredit, CREDITED_AMPS, "the credit is the router's");
        assertEq(fillerCredit, 0, "and the filler holds none of it");
        assertEq(fillerFee, AMPS_FEE_PIPS | LPFeeLibrary.OVERRIDE_FEE_FLAG, "so the filler's exit pays in full");
        assertEq(
            routerFee,
            ENTRY_PASS_THROUGH_PIPS | LPFeeLibrary.OVERRIDE_FEE_FLAG,
            "while the router's own covered sell is a rotation"
        );
    }

    /// @notice Self-call entry point: the router's flagged buy and a filler's flagged sell in one transaction.
    function twoSendersEntry()
        external
        returns (uint256 routerCredit, uint256 fillerCredit, uint24 fillerFee, uint24 routerFee)
    {
        require(msg.sender == address(this), "self-call only");

        SwapParams memory buy = SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(
            address(router), usdgKey, buy, toBalanceDelta(int128(uint128(CREDITED_AMPS)), int128(-1)), rotateFlag
        );

        routerCredit = hook.rotationCredit(address(router));
        fillerCredit = hook.rotationCredit(FILLER);

        SwapParams memory sell =
            SwapParams({zeroForOne: true, amountSpecified: -int256(CREDITED_AMPS), sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        (,, fillerFee) = hook.beforeSwap(FILLER, usdgKey, sell, rotateFlag);

        vm.prank(address(poolManager));
        (,, routerFee) = hook.beforeSwap(address(router), usdgKey, sell, rotateFlag);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Blending (§1.4 step 3)
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A flagged sell larger than the credit that funds it pays the AMPS fee on the excess, rounded up.
    /// @dev `AmpsRouter.rotate` cannot build this — it sells exactly what hop 1 returned — so it is driven
    ///      through the callbacks, which is also the only way a future router could reach it.
    function test_aFlaggedSellLargerThanItsCreditPaysTheAmpsFeeOnTheExcess() public {
        (uint256 creditBefore, uint256 amountIn, uint24 fee, uint256 creditAfter) = this.oversizedSellEntry();

        uint256 uncredited = amountIn - creditBefore;
        uint256 expected = uint256(Constants.BUY_FEE_BPS_ENTRY_DEFAULT)
            + _ceilDiv((Constants.AMPS_FEE_BPS_DEFAULT - Constants.BUY_FEE_BPS_ENTRY_DEFAULT) * uncredited, amountIn);
        assertEq(fee, uint24(expected) * Constants.PIPS_PER_BPS | LPFeeLibrary.OVERRIDE_FEE_FLAG, "blended, up");
        assertEq(creditAfter, 0, "the whole credit was consumed");
        // A sell of exactly twice the credit is half credited: 30 + ceil(470/2) = 265 bp.
        assertEq(expected, 265, "the arithmetic, spelled out");
    }

    /// @notice Self-call entry point: credit `CREDITED_AMPS`, then sell twice that, both flagged.
    function oversizedSellEntry()
        external
        returns (uint256 creditBefore, uint256 amountIn, uint24 fee, uint256 creditAfter)
    {
        require(msg.sender == address(this), "self-call only");

        SwapParams memory buy = SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(
            address(router), usdgKey, buy, toBalanceDelta(int128(uint128(CREDITED_AMPS)), int128(-1)), rotateFlag
        );
        creditBefore = hook.rotationCredit(address(router));

        amountIn = CREDITED_AMPS * 2;
        SwapParams memory sell =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        (,, fee) = hook.beforeSwap(address(router), usdgKey, sell, rotateFlag);
        creditAfter = hook.rotationCredit(address(router));
    }

    /// @notice I26: the credit falls by exactly what the sell consumed, never by more, and the hook says so.
    function test_theCreditIsDecrementedByExactlyWhatWasConsumed() public {
        vm.recordLogs();
        (uint256 creditBefore, uint256 sold, uint256 creditAfter) = this.partialSellEntry();

        assertEq(creditAfter, creditBefore - sold, "decremented by the consumed amount alone");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 consumed;
        uint16 blended;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == IAmpsHook.RotationCreditConsumed.selector) {
                (consumed, blended) = abi.decode(logs[i].data, (uint256, uint16));
            }
        }
        assertEq(consumed, sold, "RotationCreditConsumed reports the consumed amount");
        assertEq(blended, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, "a fully covered sell pays the pass-through fee");
    }

    /// @notice Self-call entry point: a flagged credit, then a flagged sell of a third of it.
    function partialSellEntry() external returns (uint256 creditBefore, uint256 sold, uint256 creditAfter) {
        require(msg.sender == address(this), "self-call only");

        SwapParams memory buy = SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(
            address(router), usdgKey, buy, toBalanceDelta(int128(uint128(CREDITED_AMPS)), int128(-1)), rotateFlag
        );
        creditBefore = hook.rotationCredit(address(router));

        sold = creditBefore / 3;
        SwapParams memory sell = SwapParams({zeroForOne: true, amountSpecified: -int256(sold), sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.beforeSwap(address(router), usdgKey, sell, rotateFlag);
        creditAfter = hook.rotationCredit(address(router));
    }

    // -----------------------------------------------------------------------------------------------------------
    // What the credit does not cover
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Exact-output sells consume no credit and pay the AMPS fee in full, flag or no flag; the router
    ///         only ever builds hop 2 as an exact-input swap.
    function test_flaggedExactOutputSellsPayTheAmpsFeeInFull() public {
        (uint256 creditBefore, uint256 creditAfter, uint24 fee) = this.exactOutputSellEntry();

        assertGt(creditBefore, 0, "there really was a credit to spend");
        assertEq(creditAfter, creditBefore, "and the exact-output sell spent none of it");
        assertEq(fee, AMPS_FEE_PIPS | LPFeeLibrary.OVERRIDE_FEE_FLAG, "full AMPS fee");
    }

    /// @notice Self-call entry point: a flagged credit, then a flagged exact-**output** sell.
    function exactOutputSellEntry() external returns (uint256 creditBefore, uint256 creditAfter, uint24 fee) {
        require(msg.sender == address(this), "self-call only");

        SwapParams memory buy = SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(
            address(router), usdgKey, buy, toBalanceDelta(int128(uint128(CREDITED_AMPS)), int128(-1)), rotateFlag
        );
        creditBefore = hook.rotationCredit(address(router));

        SwapParams memory sell = SwapParams({zeroForOne: true, amountSpecified: int256(100e6), sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        (,, fee) = hook.beforeSwap(address(router), usdgKey, sell, rotateFlag);
        creditAfter = hook.rotationCredit(address(router));
    }

    /// @notice A one-wei flagged buy unlocks one wei of credit and nothing more, so a large flagged sell still
    ///         pays essentially the whole AMPS fee.
    function test_aOneWeiBuyUnlocksOneWei() public {
        (uint256 credit, uint24 fee) = this.oneWeiEntry();

        assertEq(credit, 1, "one wei in, one wei of credit");
        // 30 + ceil(470 * (amountIn - 1) / amountIn) = 500 for any amountIn > 470.
        assertEq(fee, AMPS_FEE_PIPS | LPFeeLibrary.OVERRIDE_FEE_FLAG, "still the full AMPS fee");
    }

    /// @notice Self-call entry point: credit exactly one wei from a realised delta, then sell 1,000 AMPS.
    function oneWeiEntry() external returns (uint256 credit, uint24 fee) {
        require(msg.sender == address(this), "self-call only");

        SwapParams memory buy = SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(address(router), usdgKey, buy, toBalanceDelta(int128(1), int128(-1)), rotateFlag);
        credit = hook.rotationCredit(address(router));

        SwapParams memory sell = SwapParams({zeroForOne: true, amountSpecified: -int256(1000e18), sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        (,, fee) = hook.beforeSwap(address(router), usdgKey, sell, rotateFlag);
    }

    /// @notice No credit survives a transaction boundary: the rotation below and the sell after it are two
    ///         transactions, and the second pays in full.
    function test_noCreditCrossesATransactionBoundary() public {
        (uint256 usdgOut, uint256 ampsThrough) = this.rotationOutEntry(STOCK_IN);
        assertGt(usdgOut, 0, "the rotation happened");
        assertGt(ampsThrough, 0, "and moved AMPS");
        assertEq(hook.rotationCredit(address(router)), 0, "and left nothing behind");

        vm.recordLogs();
        _sell(usdgKey, 100e18);
        assertEq(
            _lastSwapFee(vm.getRecordedLogs()), AMPS_FEE_PIPS, "the next transaction's sell pays the AMPS fee in full"
        );
    }

    // -----------------------------------------------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------------------------------------------

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
