// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsHook} from "../../src/interfaces/IAmpsHook.sol";
import {AmpsRouter} from "../../src/periphery/AmpsRouter.sol";
import {Constants} from "../../src/types/Constants.sol";
import {NotARotation, SameHop} from "../../src/types/Errors.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title RotationCreditGamingTest
/// @notice The plan's named attack **rotation-credit gaming**, re-aimed at revision 6 of the fee model.
///
///         The credit exists so that a rotation — `stock -> AMPS -> stock` inside one transaction — is not taxed
///         as an exit. The attack is to manufacture a credit cheaply, or to dress an exit up as a rotation, and
///         spend the pass-through fee on a real exit. Revision 6 closes the whole family structurally rather than
///         numerically: a hop is pass-through **only** when the PoolManager reports `sender == hook.router()` and
///         the hop carries `Constants.ROUTER_ROTATE` in its `hookData`. Everything else — every sender, every
///         router, every shape, including the protocol router's own `buy` and `sell` — pays `ampsFeeBps` in both
///         directions and neither earns nor spends a credit.
///
/// @dev The one contract that can claim the exemption is deployed here and named to the hook by the timelock, so
///      every "this does not work" below is measured against a world in which the exemption really exists and
///      really works for its intended shape.
contract RotationCreditGamingTest is Phase3Fixture {
    /// @notice The protocol router, holding the only pass-through exemption in the system.
    AmpsRouter internal protocolRouter;

    /// @dev The bytes the hook checks for. An attacker can send these; what they cannot do is be the router.
    bytes internal rotateFlag;

    /// @dev A stranger, used to show that the flag alone buys nothing.
    address internal constant MALLORY = address(0x4A110);

    /// @dev The rotation size every test below uses. Small, because the shape under test is the *fee*, not the
    ///      curve: a rotation big enough to push either hop past its own 800-tick outer rail is refused by the
    ///      hook for a reason that has nothing to do with the credit (I15, §10 ruling 2).
    uint256 internal constant ROTATION_IN = 1e15;

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        giveShares(ALICE, 100e18);
        // The rotation below buys AMPS out of a spoke and sells it into the hub, so the spoke needs an ask
        // ladder deep enough that a small buy does not walk it off its own rail. `Phase3Flywheel` deepens the
        // spokes for its own rotation test for exactly this reason.
        deepenSpokes(600e18);

        protocolRouter = new AmpsRouter(poolManager, address(amps), address(registry), address(weth));
        vm.label(address(protocolRouter), "AmpsRouter");
        vm.prank(TIMELOCK);
        hook.setRouter(address(protocolRouter));

        rotateFlag = abi.encode(Constants.ROUTER_ROTATE);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The shape that is supposed to work
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The control: a real rotation through the protocol router pays each pool's pass-through fee, once
    ///         per hop, and moves no AMPS to anybody.
    /// @dev **Bases, not totals.** This world runs the production `FeePolicy`, so every realised fee is
    ///      `base + dyn` and `dyn` is whatever the live deviation, variance and session happen to be. The claim
    ///      under test is about the *base*, so hop 1 is checked by differencing two pre-swap quotes of the same
    ///      state — where the dynamic parts are identical by construction and cancel — and hop 2 by the
    ///      `RotationCreditConsumed` event, which reports the blended base the hook actually charged.
    function test_theRealRotationPaysThePassThroughFeeOnBothHops() public {
        uint256 ampsBefore = amps.balanceOf(ALICE);
        uint16 hop1PassThrough = registry.poolConfig(spokePools[0]).buyFeeBps;
        uint16 hop2PassThrough = registry.poolConfig(hubPool).buyFeeBps;

        (uint24 ordinaryPips, uint16 ordinaryBase,,) = hook.quoteFee(spokePools[0], false, true, ROTATION_IN, false);
        (uint24 rotationPips, uint16 rotationBase,,) = hook.quoteFee(spokePools[0], false, true, ROTATION_IN, true);
        assertEq(ordinaryBase, hook.ampsFeeBps(), "an ordinary hop 1 would pay the AMPS fee");
        assertEq(rotationBase, hop1PassThrough, "a flagged hop 1 pays the pool's pass-through fee");

        vm.recordLogs();
        (uint256 amountOut, uint256 ampsThrough) = _rotateThroughRouter(spokePools[0], hubPool, ALICE, ROTATION_IN);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint24[] memory fees = swapFees(logs);
        assertEq(fees.length, 2, "two hops");
        assertEq(fees[0], rotationPips, "hop 1 charged exactly the flagged quote");
        assertEq(
            ordinaryPips - rotationPips,
            uint24(hook.ampsFeeBps() - hop1PassThrough) * Constants.PIPS_PER_BPS,
            "and the whole difference is the base, so the dynamic part is untouched"
        );
        (, uint16 blendedBase) = _lastCreditConsumed(logs);
        assertEq(blendedBase, hop2PassThrough, "hop 2's blended base is hop 2's pass-through fee");

        assertGt(amountOut, 0, "and something came out");
        assertGt(ampsThrough, 0, "having passed through AMPS");
        assertEq(amps.balanceOf(ALICE), ampsBefore, "which the caller never touched");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Shape 1 — an ordinary buy then sell, in one transaction
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A buy and a sell through an ordinary router in one transaction pay the AMPS fee **twice**. Under
    ///         revision 5 the buy minted a credit that discounted the sell to 30 bp; it no longer mints anything.
    function test_anOrdinaryBuyThenSellPaysTheAmpsFeeTwice() public {
        vm.recordLogs();
        (uint256 creditAfter, uint16 buyBase, uint16 sellBase) = this.ordinaryRoundTripEntry();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint24[] memory fees = swapFees(logs);
        assertEq(fees.length, 2, "two swaps");
        assertEq(buyBase, hook.ampsFeeBps(), "the buy's base is the AMPS fee");
        assertEq(sellBase, hook.ampsFeeBps(), "and so is the sell's, quoted after the buy");
        assertGe(fees[0], _ampsFeePips(), "so the buy paid at least the AMPS fee");
        assertGe(fees[1], _ampsFeePips(), "and so did the sell");
        assertEq(creditAfter, 0, "nothing was ever credited");
        assertEq(_creditConsumedCount(logs), 0, "and nothing was ever spent");
    }

    /// @notice Self-call entry point: buy then sell inside one transaction's transient storage.
    /// @dev The sell's base is quoted *after* the buy, which is the whole point: under revision 5 the buy would
    ///      have left a credit that blended this quote down to the buy fee.
    function ordinaryRoundTripEntry() external returns (uint256 creditAfter, uint16 buyBase, uint16 sellBase) {
        require(msg.sender == address(this), "self-call only");
        (, buyBase,,) = hook.quoteFee(hubPool, false, true, 2e6, false);
        uint256 bought = buyAmps(hubPool, ALICE, 2e6);
        assertEq(hook.rotationCredit(address(swapRouter)), 0, "an ordinary buy credits nothing");
        (, sellBase,,) = hook.quoteFee(hubPool, true, true, bought, false);
        sellAmps(hubPool, ALICE, bought);
        creditAfter = hook.rotationCredit(address(swapRouter));
    }

    // -------------------------------------------------------------------------------------------------------------
    // Shape 2 — the same, through the protocol router itself
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Being the router is not the exemption: the router's own `buy` and `sell` carry no flag and pay the
    ///         AMPS fee twice, so "route your exit through the protocol's front end" buys nothing.
    function test_theRoutersOwnBuyThenSellPaysTheAmpsFeeTwice() public {
        vm.recordLogs();
        (uint256 creditAfter, uint16 buyBase, uint16 sellBase) = this.routerRoundTripEntry();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint24[] memory fees = swapFees(logs);
        assertEq(fees.length, 2, "two swaps");
        assertEq(buyBase, hook.ampsFeeBps(), "the router's buy is based at the AMPS fee");
        assertEq(sellBase, hook.ampsFeeBps(), "and so is the router's sell");
        assertGe(fees[0], _ampsFeePips(), "so the buy paid at least the AMPS fee");
        assertGe(fees[1], _ampsFeePips(), "and so did the sell");
        assertEq(creditAfter, 0, "and no credit was created on the way");
        assertEq(_creditConsumedCount(logs), 0, "nor spent");
    }

    /// @notice Self-call entry point: `AmpsRouter.buy` then `AmpsRouter.sell` in one transaction.
    function routerRoundTripEntry() external returns (uint256 creditAfter, uint16 buyBase, uint16 sellBase) {
        require(msg.sender == address(this), "self-call only");

        address counter = registry.poolConfig(hubPool).counter;
        fund(counter, ALICE, 2e6);
        (, buyBase,,) = hook.quoteFee(hubPool, false, true, 2e6, false);

        vm.startPrank(ALICE);
        IERC20(counter).approve(address(protocolRouter), type(uint256).max);
        uint256 bought = protocolRouter.buy(hubPool, 2e6, 0, ALICE, type(uint256).max);
        vm.stopPrank();

        assertEq(hook.rotationCredit(address(protocolRouter)), 0, "an unflagged buy credits nothing");
        (, sellBase,,) = hook.quoteFee(hubPool, true, true, bought, false);

        vm.startPrank(ALICE);
        amps.approve(address(protocolRouter), type(uint256).max);
        protocolRouter.sell(hubPool, bought, 0, ALICE, false, type(uint256).max);
        vm.stopPrank();

        creditAfter = hook.rotationCredit(address(protocolRouter));
    }

    // -------------------------------------------------------------------------------------------------------------
    // Shape 3 — the forged flag
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A stranger who sends the right 32 bytes gets nothing: no credit on the buy, the full AMPS fee on
    ///         the sell. The flag is a declaration the hook checks against an address, not a password.
    function test_aForgedFlagFromANonRouterSenderPaysTheAmpsFeeAndEarnsNothing() public {
        (uint24 honestBuy,) = _ordinaryQuotes();
        (uint256 credit, uint24 buyFee, uint24 sellFee, uint24 honestSell) = this.forgedFlagEntry();

        assertEq(credit, 0, "the forged buy credited nothing");
        assertEq(buyFee & LPFeeLibrary.REMOVE_OVERRIDE_MASK, honestBuy, "and paid what an unflagged buy pays");
        assertEq(sellFee & LPFeeLibrary.REMOVE_OVERRIDE_MASK, honestSell, "as did the forged sell");
        assertGe(honestSell, _ampsFeePips(), "which is the AMPS fee plus whatever the wall adds");
    }

    /// @dev What the hub charges an ordinary hop in each direction right now, at the sizes {forgedFlagEntry}
    ///      drives the callbacks with. The dynamic part is live in this world, so the honest answer is the hook's
    ///      own quote rather than a bare constant.
    function _ordinaryQuotes() private view returns (uint24 buyPips, uint24 sellPips) {
        (buyPips,,,) = hook.quoteFee(hubPool, false, true, 1, false);
        (sellPips,,,) = hook.quoteFee(hubPool, true, true, 1000e18, false);
    }

    /// @notice Self-call entry point: the callbacks driven directly with a forged `hookData`, which is exactly
    ///         what an attacker able to reach the PoolManager would build.
    /// @dev The honest comparison is taken **inside** this frame, immediately before the forged sell. The buy's
    ///      `afterSwap` above updates the pool's variance, its last tick and — past the cache interval — its whole
    ///      gate view, so a quote taken before the entry is a quote of a different state and the comparison would
    ///      be measuring the callback's own side effects rather than the flag.
    function forgedFlagEntry() external returns (uint256 credit, uint24 buyFee, uint24 sellFee, uint24 honestSellPips) {
        require(msg.sender == address(this), "self-call only");

        // Read the key first: `vm.prank` binds to the *next* call, and an argument that is itself an external
        // call would consume it, leaving the callback to arrive from this contract instead of the PoolManager.
        PoolKey memory key = registry.poolKey(hubPool);
        SwapParams memory buy = SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: 0});

        vm.prank(address(poolManager));
        (,, buyFee) = hook.beforeSwap(MALLORY, key, buy, rotateFlag);

        vm.prank(address(poolManager));
        hook.afterSwap(MALLORY, key, buy, toBalanceDelta(int128(uint128(1000e18)), int128(-1)), rotateFlag);
        credit = hook.rotationCredit(MALLORY);

        SwapParams memory sell = SwapParams({zeroForOne: true, amountSpecified: -int256(1000e18), sqrtPriceLimitX96: 0});
        (honestSellPips,,,) = hook.quoteFee(hubPool, true, true, 1000e18, false);
        vm.prank(address(poolManager));
        (,, sellFee) = hook.beforeSwap(MALLORY, key, sell, rotateFlag);
    }

    /// @notice And the router without the flag is a stranger too: the exemption needs both halves.
    function test_theRouterWithoutTheFlagIsOrdinary() public {
        (uint24 flagged, uint24 unflagged) = this.routerFlagContrastEntry();
        // Same pool, same direction, same size, same block: the dynamic part is identical on both, so the whole
        // difference between them is the base, and it is exactly `ampsFeeBps - buyFeeBps`.
        assertEq(
            unflagged - flagged,
            uint24(hook.ampsFeeBps() - registry.poolConfig(hubPool).buyFeeBps) * Constants.PIPS_PER_BPS,
            "the flag is worth exactly the difference between the two bases"
        );
        assertTrue(flagged & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "and both carry the override flag");
        assertTrue(unflagged & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "on both paths");
    }

    /// @notice Self-call entry point: the same hop, from the same sender, with and without the flag.
    function routerFlagContrastEntry() external returns (uint24 flagged, uint24 unflagged) {
        require(msg.sender == address(this), "self-call only");
        PoolKey memory key = registry.poolKey(hubPool);
        SwapParams memory buy = SwapParams({zeroForOne: false, amountSpecified: -1e6, sqrtPriceLimitX96: 0});

        vm.prank(address(poolManager));
        (,, flagged) = hook.beforeSwap(address(protocolRouter), key, buy, rotateFlag);

        vm.prank(address(poolManager));
        (,, unflagged) = hook.beforeSwap(address(protocolRouter), key, buy, "");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Shape 4 — the dust buy, and the oversized exit
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The classic: manufacture a credit with a 1-wei buy, then exit against it. There is no credit to
    ///         manufacture any more — the dust buy is an ordinary buy — so the exit pays the AMPS fee in full and
    ///         is never better than the honest one.
    function test_aDustBuyCannotDiscountARealExit() public {
        // Warm the gate cache first, in a swap both branches share. `beforeSwap` prices a pool whose cache has
        // aged past `GATE_CACHE_MAX_AGE` against the conservative substitute, and the *first* swap of any kind
        // refreshes it — so without this the comparison below would be measuring that refresh (a public good any
        // swap performs, and one the dust buy pays the conservative fee for) rather than the credit.
        buyAmps(hubPool, ALICE, 1e6);

        uint256 snapshot = vm.snapshotState();
        (uint256 credit, uint16 baseBps, uint256 gamed) = this.dustBuyEntry();
        vm.revertToState(snapshot);
        uint256 honest = this.honestExitEntry(10e18);

        assertEq(credit, 0, "a dust buy creates no credit at all");
        assertEq(baseBps, hook.ampsFeeBps(), "and the exit pays the AMPS fee in full");
        assertLe(gamed, honest, "the gamed exit is never better than the honest one");
    }

    /// @notice One transaction: a 1-wei buy, then a real exit against whatever it created.
    function dustBuyEntry() external returns (uint256 credit, uint16 baseBps, uint256 exitOut) {
        require(msg.sender == address(this), "self-call only");
        buyAmps(hubPool, ALICE, 1);
        credit = hook.rotationCredit(address(swapRouter));
        (, baseBps,,) = hook.quoteFee(hubPool, true, true, 10e18, false);
        exitOut = sellAmps(hubPool, ALICE, 10e18);
    }

    /// @notice The control: the same exit, in a transaction with nothing else in it.
    function honestExitEntry(uint256 ampsOut) external returns (uint256 received) {
        require(msg.sender == address(this), "self-call only");
        assertEq(hook.rotationCredit(address(swapRouter)), 0, "the control starts with no credit");
        received = sellAmps(hubPool, ALICE, ampsOut);
    }

    /// @notice A rotation cannot be used to exit: the router sells exactly the AMPS hop 1 realised, so there is no
    ///         "sell more than you bought" shape for it to build, and the caller's own AMPS never enters the call.
    function test_aRotationCannotBeUsedToExitTheCallersOwnAmps() public {
        uint256 ampsBefore = amps.balanceOf(ALICE);
        assertGt(ampsBefore, 0, "ALICE really is holding AMPS she could try to exit");

        (, uint256 ampsThrough) = _rotateThroughRouter(spokePools[0], hubPool, ALICE, ROTATION_IN);

        assertGt(ampsThrough, 0, "AMPS passed through the rotation");
        assertEq(amps.balanceOf(ALICE), ampsBefore, "and none of the caller's own left with it");
        assertEq(amps.balanceOf(address(protocolRouter)), 0, "the router holds none either");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Shape 5 — the shapes the router refuses to build
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `hop1 == hop2` reverts. Buying AMPS in a pool and selling it straight back is a round trip on one
    ///         curve; pricing it at two pass-through fees would make that pool's liquidity pay for the noise.
    function test_aRotationThroughOnePoolTwiceIsRefused() public {
        address counter = registry.poolConfig(hubPool).counter;
        fund(counter, ALICE, 1e6);
        vm.startPrank(ALICE);
        IERC20(counter).approve(address(protocolRouter), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SameHop.selector, PoolId.unwrap(hubPool)));
        protocolRouter.rotate(hubPool, hubPool, 1e6, 0, ALICE, false, type(uint256).max);
        vm.stopPrank();
    }

    /// @notice An exact-**output** hop 2 is unreachable: the router builds both hops as exact-input, and the hook
    ///         gives an exact-output sell the AMPS fee even when it carries the flag.
    /// @dev Both halves are asserted. The first is the ABI — `rotate` takes one `amountIn` and no `amountOut`, and
    ///      hop 2's size is read off hop 1's realised delta — and the second is the hook's own rule, so a future
    ///      router that tried to build it would gain nothing.
    function test_anExactOutputRotationHopIsUnreachableAndWouldPayInFullAnyway() public view {
        (uint16 exactInputBase, uint16 exactOutputBase) = this.exactOutputHopEntry();
        assertEq(exactInputBase, registry.poolConfig(hubPool).buyFeeBps, "a flagged exact-input sell is pass-through");
        assertEq(exactOutputBase, hook.ampsFeeBps(), "a flagged exact-output sell is not");
    }

    /// @notice Self-call entry point: the same flagged sell, exact-input and exact-output.
    function exactOutputHopEntry() external view returns (uint16 exactInputBase, uint16 exactOutputBase) {
        require(msg.sender == address(this), "self-call only");
        (, exactInputBase,,) = hook.quoteFee(hubPool, true, true, 1000e18, true);
        (, exactOutputBase,,) = hook.quoteFee(hubPool, true, false, 0, true);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Shape 5b — what a rotation has to be (audit finding 3)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The shape the exemption is *for* is untouched by the fix: `stock -> AMPS -> stock` pays the two
    ///         pools' pass-through fees, 5-30 bp apiece, and no `ampsFeeBps` anywhere.
    function test_f03_aStockToStockRotationStillPaysBuyPlusBuy() public {
        seedSpokeBids(1);
        uint16 hop1PassThrough = registry.poolConfig(spokePools[0]).buyFeeBps;
        uint16 hop2PassThrough = registry.poolConfig(spokePools[1]).buyFeeBps;

        (uint24 rotationPips, uint16 rotationBase,,) = hook.quoteFee(spokePools[0], false, true, ROTATION_IN, true);
        assertEq(rotationBase, hop1PassThrough, "hop 1 is priced at the spoke's pass-through fee");

        vm.recordLogs();
        (uint256 amountOut, uint256 ampsThrough) =
            _rotateThroughRouter(spokePools[0], spokePools[1], ALICE, ROTATION_IN);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint24[] memory fees = swapFees(logs);
        assertEq(fees.length, 2, "two hops");
        assertEq(fees[0], rotationPips, "hop 1 charged exactly the flagged quote");
        assertLt(fees[0], _ampsFeePips(), "which is nowhere near the AMPS fee");
        assertLt(fees[1], _ampsFeePips(), "and neither is hop 2's");
        (uint256 consumed, uint16 blendedBase) = _lastCreditConsumed(logs);
        assertEq(blendedBase, hop2PassThrough, "hop 2's blended base is the other spoke's pass-through fee");
        assertEq(consumed, ampsThrough, "spending exactly the AMPS hop 1 realised");
        assertGt(amountOut, 0, "and the other constituent came out");
    }

    /// @notice And so is `USDG -> AMPS -> stock`: one entry leg at 30 bp, one spoke leg at its own buy fee, and no
    ///         `ampsFeeBps`. Entering the index and landing on a constituent *is* a move through it; what the fix
    ///         refuses is the route that never touches a constituent at all.
    function test_f03_anEntryToSpokeRotationPaysThirtyBpPlusTheSpokeBuyFee() public {
        seedSpokeBids(0);
        uint16 hop1PassThrough = registry.poolConfig(hubPool).buyFeeBps;
        uint16 hop2PassThrough = registry.poolConfig(spokePools[0]).buyFeeBps;
        assertEq(hop1PassThrough, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, "the hub's pass-through fee is 30 bp");

        (uint24 rotationPips, uint16 rotationBase,,) = hook.quoteFee(hubPool, false, true, 2e6, true);
        assertEq(rotationBase, hop1PassThrough, "hop 1 is the entry pool's pass-through fee");

        vm.recordLogs();
        (uint256 amountOut,) = _rotateThroughRouter(hubPool, spokePools[0], ALICE, 2e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint24[] memory fees = swapFees(logs);
        assertEq(fees.length, 2, "two hops");
        assertEq(fees[0], rotationPips, "hop 1 charged the flagged quote");
        assertLt(fees[0], _ampsFeePips(), "not the AMPS fee");
        assertLt(fees[1], _ampsFeePips(), "and hop 2 did not pay it either");
        (, uint16 blendedBase) = _lastCreditConsumed(logs);
        assertEq(blendedBase, hop2PassThrough, "hop 2's blended base is the spoke's pass-through fee");
        assertGt(amountOut, 0, "and the constituent came out");
    }

    /// @notice **The finding.** `USDG -> AMPS -> WETH` is not a rotation: neither leg is a constituent, so it is a
    ///         60 bp USDG/WETH swap against protocol-owned liquidity where the design charges the AMPS fee on both
    ///         legs — and both entry pools take their fair tick from their own TWAP, so the deviation term that
    ///         would otherwise price the move is structurally zero. It reverts by name.
    function test_f03_anEntryToEntryRotationIsRefused() public {
        address counter = registry.poolConfig(hubPool).counter;
        fund(counter, ALICE, 2e6);
        vm.startPrank(ALICE);
        IERC20(counter).approve(address(protocolRouter), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NotARotation.selector, PoolId.unwrap(hubPool), PoolId.unwrap(wethPool)));
        protocolRouter.rotate(hubPool, wethPool, 2e6, 0, ALICE, false, type(uint256).max);
        vm.stopPrank();

        // The other direction too: the check is on the pair, not on which one is named first.
        address wethCounter = registry.poolConfig(wethPool).counter;
        fund(wethCounter, ALICE, 0.001e18);
        vm.startPrank(ALICE);
        IERC20(wethCounter).approve(address(protocolRouter), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NotARotation.selector, PoolId.unwrap(wethPool), PoolId.unwrap(hubPool)));
        protocolRouter.rotate(wethPool, hubPool, 0.001e18, 0, ALICE, false, type(uint256).max);
        vm.stopPrank();
    }

    /// @notice And the same USDG -> AMPS -> WETH route is still *available* to anybody through an ordinary router
    ///         — it simply pays `ampsFeeBps` on both hops, which is what it always did and what the refusal above
    ///         protects. The protocol refuses to *price* it as a rotation, it does not refuse to let it happen.
    function test_f03_theSameEntryToEntryRouteThroughAnOrdinaryRouterPaysTheAmpsFeeTwice() public {
        vm.recordLogs();
        uint256 amountOut = rotate(hubPool, wethPool, ALICE, 2e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint24[] memory fees = swapFees(logs);
        assertEq(fees.length, 2, "the route executed, two hops");
        assertGe(fees[0], _ampsFeePips(), "hop 1 paid the AMPS fee");
        assertGe(fees[1], _ampsFeePips(), "and so did hop 2");
        assertEq(_creditConsumedCount(logs), 0, "no credit was created, so none was spent");
        assertGt(amountOut, 0, "and the caller got their WETH");
    }

    /// @notice **The second half of the finding.** `rotate(A, B)` then `rotate(B, A)` in one transaction rebuilds
    ///         the round trip `SameHop` refuses, out of two calls. The hook counts the pass-through hops it has
    ///         priced per pool per transaction, so the second pass over each pool pays `ampsFeeBps`: the closing
    ///         leg of a round trip is priced as the exit it is, and the honest one-hop-per-pool rotation above is
    ///         untouched.
    function test_f03_aTwoCallRoundTripPaysTheAmpsFeeOnTheSecondPass() public {
        seedSpokeBids(0);

        vm.recordLogs();
        this.twoCallRoundTripEntry();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint24[] memory fees = swapFees(logs);
        assertEq(fees.length, 4, "four hops in one transaction");
        assertLt(fees[0], _ampsFeePips(), "the first rotation's hop 1 is pass-through");
        assertLt(fees[1], _ampsFeePips(), "and so is its hop 2");
        assertGe(fees[2], _ampsFeePips(), "the second rotation's hop 1 is a second pass over the hub");
        assertGe(fees[3], _ampsFeePips(), "and its hop 2 a second pass over the spoke");
    }

    /// @notice Self-call entry point: two rotations over the same pair of pools inside one transaction's transient
    ///         storage, which is the only place the per-pool count can be observed.
    function twoCallRoundTripEntry() external {
        require(msg.sender == address(this), "self-call only");
        _rotateThroughRouter(spokePools[0], hubPool, ALICE, ROTATION_IN);
        _rotateThroughRouter(hubPool, spokePools[0], ALICE, 2e6);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Shape 6 — across transactions
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `ROTATION_CREDIT` is one EIP-1153 slot, so the EVM itself zeroes it at every transaction boundary:
    ///         I26's "zero at the start of every transaction" is structural, not enforced, and there is no code
    ///         path that could fail to enforce it.
    function test_noCreditSurvivesToTheNextTransaction() public {
        (uint256 amountOut,) = _rotateThroughRouter(spokePools[0], hubPool, ALICE, ROTATION_IN);
        assertGt(amountOut, 0, "the rotation happened");
        assertEq(hook.rotationCredit(address(protocolRouter)), 0, "and left nothing behind");

        uint256 bought = buyAmps(hubPool, ALICE, 2e6);
        assertGt(bought, 0, "the buy happened");
        (, uint16 baseBps,,) = hook.quoteFee(hubPool, true, true, bought, false);
        assertEq(baseBps, hook.ampsFeeBps(), "so the next transaction's exit pays the AMPS fee in full");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Governance can withdraw the exemption
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The exemption is one governed word. Point it at nothing and the rotation pays the AMPS fee like
    ///         everything else — which is the kill switch if the router is ever found to be wrong.
    function test_clearingTheRouterWithdrawsTheExemption() public {
        vm.prank(TIMELOCK);
        hook.setRouter(address(0));

        (uint24 ordinaryPips,,,) = hook.quoteFee(spokePools[0], false, true, ROTATION_IN, false);

        vm.recordLogs();
        _rotateThroughRouter(spokePools[0], hubPool, ALICE, ROTATION_IN);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint24[] memory fees = swapFees(logs);
        assertEq(fees.length, 2, "the rotation still executes");
        assertEq(fees[0], ordinaryPips, "but hop 1 is priced as an ordinary swap");
        assertGe(fees[0], _ampsFeePips(), "which is the AMPS fee, plus whatever the wall adds");
        assertGe(fees[1], _ampsFeePips(), "and so is hop 2");
        assertEq(_creditConsumedCount(logs), 0, "no credit was created, so none was spent");
    }

    // -------------------------------------------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @dev One rotation through the protocol router, funded and approved.
    function _rotateThroughRouter(PoolId hop1, PoolId hop2, address who, uint256 amountIn)
        internal
        returns (uint256 amountOut, uint256 ampsThrough)
    {
        address counter = registry.poolConfig(hop1).counter;
        fund(counter, who, amountIn);
        vm.startPrank(who);
        IERC20(counter).approve(address(protocolRouter), type(uint256).max);
        (amountOut, ampsThrough) = protocolRouter.rotate(hop1, hop2, amountIn, 0, who, false, type(uint256).max);
        vm.stopPrank();
    }

    function _ampsFeePips() internal view returns (uint24 pips) {
        pips = uint24(hook.ampsFeeBps()) * Constants.PIPS_PER_BPS;
    }

    /// @dev The last `RotationCreditConsumed` in `logs`: how much credit a sell spent and the blended base it
    ///      paid. The base is what this suite actually cares about, because the realised `Swap` fee also carries
    ///      the live dynamic part.
    function _lastCreditConsumed(Vm.Log[] memory logs) internal pure returns (uint256 consumed, uint16 blendedBps) {
        for (uint256 i = logs.length; i != 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.topics.length == 0 || entry.topics[0] != IAmpsHook.RotationCreditConsumed.selector) continue;
            return abi.decode(entry.data, (uint256, uint16));
        }
        revert("no RotationCreditConsumed");
    }

    /// @dev How many credits were spent at all. Zero is the assertion most of this suite is making.
    function _creditConsumedCount(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == IAmpsHook.RotationCreditConsumed.selector) ++count;
        }
    }
}
