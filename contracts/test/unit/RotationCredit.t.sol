// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsHook} from "../../src/interfaces/IAmpsHook.sol";
import {Constants} from "../../src/types/Constants.sol";
import {HookTestFixture} from "../mocks/HookTestFixture.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title RotationCreditTest
/// @notice I26 end to end: the same-transaction rotation credit is credited by the AMPS a buyer actually
///         received, consumed only by exact-input sells, blended and rounded up, and gone at every transaction
///         boundary.
///
/// @dev **Every scenario runs inside one self-call.** Foundry 1.8 clears EIP-1153 transient storage between the
///      top-level calls a test makes, so a buy and the sell that spends its credit have to share one call frame
///      to be faithful to the EVM — the same reason `test/gas/GasBaseline.t.sol` uses `this.roundTripEntry()`.
///      A scenario written as two plain statements would silently test nothing.
contract RotationCreditTest is HookTestFixture {
    uint256 internal constant USDG_IN = 10_000e6;
    uint256 internal constant STOCK_IN = 50e18;

    function setUp() public {
        _deployFixture();
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

    function test_theCreditIsZeroInAFreshTransaction() public view {
        assertEq(hook.rotationCredit(), 0, "nothing carries in");
    }

    // -----------------------------------------------------------------------------------------------------------
    // The rotation itself
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A one-transaction stock -> AMPS -> USDG rotation pays a buy fee on both hops.
    function test_oneTxRotationPaysBuyPlusBuy() public {
        vm.recordLogs();
        uint256 creditAfter = this.rotationEntry(STOCK_IN);

        uint24[] memory fees = _swapFees(vm.getRecordedLogs());
        assertEq(fees.length, 2, "two hops");
        assertEq(fees[0], uint24(Constants.BUY_FEE_BPS_SPOKE_DEFAULT) * Constants.PIPS_PER_BPS, "hop 1: spoke buy");
        assertEq(fees[1], uint24(Constants.BUY_FEE_BPS_ENTRY_DEFAULT) * Constants.PIPS_PER_BPS, "hop 2: credited");
        assertEq(creditAfter, 0, "hop 2 consumed the whole credit");
    }

    /// @notice Self-call entry point: the whole rotation inside one transaction's transient storage.
    function rotationEntry(uint256 amountIn) external returns (uint256 creditAfter) {
        require(msg.sender == address(this), "self-call only");
        assertEq(hook.rotationCredit(), 0, "the credit starts at zero");
        _rotate(address(stock), USDG_ADDRESS, amountIn);
        creditAfter = hook.rotationCredit();
    }

    /// @notice A rotation really is worth more than the same two legs taken in separate transactions, and the
    ///         difference is exactly the fee hop 2 did not pay.
    function test_theRotationIsWorthTheCreditItSpends() public {
        uint256 snap = vm.snapshotState();
        uint256 rotated = this.rotationOutEntry(STOCK_IN);
        vm.revertToState(snap);

        // The same two legs, one per transaction, so nothing credits the exit.
        uint256 ampsOut = _buy(stockKey, STOCK_IN);
        uint256 uncredited = _sell(usdgKey, ampsOut);

        assertGt(rotated, uncredited, "the credited exit keeps more USDG");
        // (1 - 30bp) / (1 - 500bp) = 1.04947...; second-order price impact keeps it inside 1%.
        assertApproxEqRel((rotated * 1e18) / uncredited, 1.049473684210526315e18, 0.01e18, "hop 2 fee saving");
    }

    /// @notice Self-call entry point: the rotation, and what it paid out.
    function rotationOutEntry(uint256 amountIn) external returns (uint256 usdgOut) {
        require(msg.sender == address(this), "self-call only");
        usdgOut = _rotate(address(stock), USDG_ADDRESS, amountIn);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Blending (§1.4 step 3)
    // -----------------------------------------------------------------------------------------------------------

    /// @notice A buy followed by a larger sell pays the sell fee on the uncredited excess, rounded up.
    function test_buyThenLargerSellPaysTheSellFeeOnTheExcess() public {
        vm.recordLogs();
        (uint256 creditBefore, uint256 amountIn, uint256 creditAfter) = this.buyThenLargerSellEntry();

        uint24[] memory fees = _swapFees(vm.getRecordedLogs());
        assertEq(fees.length, 2, "two swaps");
        assertEq(fees[0], uint24(Constants.BUY_FEE_BPS_ENTRY_DEFAULT) * Constants.PIPS_PER_BPS, "the buy leg");

        uint256 uncredited = amountIn - creditBefore;
        uint256 expected = uint256(Constants.BUY_FEE_BPS_ENTRY_DEFAULT)
            + _ceilDiv((Constants.SELL_FEE_BPS_DEFAULT - Constants.BUY_FEE_BPS_ENTRY_DEFAULT) * uncredited, amountIn);
        assertEq(fees[1], uint24(expected) * Constants.PIPS_PER_BPS, "blended, rounded up");
        assertEq(creditAfter, 0, "the whole credit was consumed");
        // A sell of exactly twice the credit is half credited: 30 + ceil(470/2) = 265 bp.
        assertEq(expected, 265, "the arithmetic, spelled out");
    }

    /// @notice Self-call entry point: buy, then sell exactly twice what the buy produced.
    function buyThenLargerSellEntry() external returns (uint256 creditBefore, uint256 amountIn, uint256 after_) {
        require(msg.sender == address(this), "self-call only");
        uint256 ampsOut = _buy(usdgKey, USDG_IN);
        creditBefore = hook.rotationCredit();
        assertEq(creditBefore, ampsOut, "credited by the realised delta, to the wei");

        amountIn = ampsOut * 2;
        _sell(usdgKey, amountIn);
        after_ = hook.rotationCredit();
    }

    /// @notice I26: the credit falls by exactly what the sell consumed, never by more.
    function test_theCreditIsDecrementedByExactlyWhatWasConsumed() public {
        vm.recordLogs();
        (uint256 creditBefore, uint256 sold, uint256 creditAfter) = this.partialSellEntry();

        assertEq(creditAfter, creditBefore - sold, "decremented by the consumed amount alone");

        // And the hook said so.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 consumed;
        uint16 blended;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == IAmpsHook.RotationCreditConsumed.selector) {
                (consumed, blended) = abi.decode(logs[i].data, (uint256, uint16));
            }
        }
        assertEq(consumed, sold, "RotationCreditConsumed reports the consumed amount");
        assertEq(blended, Constants.BUY_FEE_BPS_ENTRY_DEFAULT, "a fully covered sell pays the buy fee");
    }

    /// @notice Self-call entry point: buy, then sell a third of the credit.
    function partialSellEntry() external returns (uint256 creditBefore, uint256 sold, uint256 creditAfter) {
        require(msg.sender == address(this), "self-call only");
        _buy(usdgKey, USDG_IN);
        creditBefore = hook.rotationCredit();
        sold = creditBefore / 3;
        _sell(usdgKey, sold);
        creditAfter = hook.rotationCredit();
    }

    // -----------------------------------------------------------------------------------------------------------
    // What the credit does not cover
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Exact-output sells consume no credit and pay the sell fee in full; the dApp builds hop 2 as
    ///         `SWAP_EXACT_IN` for exactly this reason.
    function test_exactOutputSellsPayTheFullSellFee() public {
        vm.recordLogs();
        (uint256 creditBefore, uint256 creditAfter) = this.exactOutputSellEntry();

        uint24[] memory fees = _swapFees(vm.getRecordedLogs());
        assertEq(fees[fees.length - 1], uint24(Constants.SELL_FEE_BPS_DEFAULT) * Constants.PIPS_PER_BPS, "full");
        assertEq(creditAfter, creditBefore, "and the credit is untouched");
        assertGt(creditBefore, 0, "there really was a credit to spend");
    }

    /// @notice Self-call entry point: buy, then take an exact amount of USDG out.
    function exactOutputSellEntry() external returns (uint256 creditBefore, uint256 creditAfter) {
        require(msg.sender == address(this), "self-call only");
        _buy(usdgKey, USDG_IN);
        creditBefore = hook.rotationCredit();
        _sellExactOut(usdgKey, 100e6);
        creditAfter = hook.rotationCredit();
    }

    /// @notice A one-wei buy unlocks one wei of credit and nothing more, so a large credited sell still pays
    ///         essentially the whole sell fee.
    function test_aOneWeiBuyUnlocksOneWei() public {
        vm.recordLogs();
        (uint256 credit, uint24 fee) = this.oneWeiEntry();

        assertEq(credit, 1, "one wei in, one wei of credit");
        // 30 + ceil(470 * (amountIn - 1) / amountIn) = 500 for any amountIn > 470.
        assertEq(fee, uint24(Constants.SELL_FEE_BPS_DEFAULT) * Constants.PIPS_PER_BPS, "still the full sell fee");
    }

    /// @notice Self-call entry point: credit exactly one wei from a realised delta, then sell 1,000 AMPS.
    /// @dev The credit is armed the way `afterSwap` arms it — from a `BalanceDelta` — because no router call can
    ///      be made to produce a one-wei output on demand.
    function oneWeiEntry() external returns (uint256 credit, uint24 fee) {
        require(msg.sender == address(this), "self-call only");

        SwapParams memory buy = SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), usdgKey, buy, toBalanceDelta(int128(1), int128(-1)), "");
        credit = hook.rotationCredit();

        vm.recordLogs();
        _sell(usdgKey, 1000e18);
        fee = _lastSwapFee(vm.getRecordedLogs());
    }

    /// @notice No credit survives a transaction boundary: the buy and the sell below are two transactions.
    function test_noCreditCrossesATransactionBoundary() public {
        uint256 ampsOut = _buy(usdgKey, USDG_IN);
        assertGt(ampsOut, 0, "the buy happened");
        assertEq(hook.rotationCredit(), 0, "and left nothing behind");

        vm.recordLogs();
        _sell(usdgKey, ampsOut);
        assertEq(
            _lastSwapFee(vm.getRecordedLogs()),
            uint24(Constants.SELL_FEE_BPS_DEFAULT) * Constants.PIPS_PER_BPS,
            "the sell pays in full in the next transaction"
        );
    }

    // -----------------------------------------------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------------------------------------------

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
