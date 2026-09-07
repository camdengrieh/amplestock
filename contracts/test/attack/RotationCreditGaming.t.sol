// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Constants} from "../../src/types/Constants.sol";
import {Phase3Fixture} from "../integration/Phase3Fixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title RotationCreditGamingTest
/// @notice The plan's named attack **rotation-credit gaming**: "1-wei buy, buy-then-larger-sell, exactOutput,
///         cross-tx: none reduces the sell fee on net exits".
///
///         The credit exists so that a rotation — `stock -> AMPS -> stock` inside one transaction — is not taxed
///         as an exit. The attack is to manufacture a credit cheaply and spend it on a real exit. All four shapes
///         fail for the same structural reason: the credit is credited from the **realised** `delta.amount0` of a
///         buy (I26), it lives in one transient slot that the EVM zeroes at every transaction boundary, and the
///         blend is rounded up.
contract RotationCreditGamingTest is Phase3Fixture {
    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        giveShares(ALICE, 100e18);
    }

    /// @notice Shape 1 - the dust buy. A 1-wei buy cannot discount a real exit: the credit is exactly the AMPS
    ///         the buy realised, which is at most a wei or two, and the blend is rounded **up**, so a 10 AMPS sell
    ///         still pays the full sell fee to the basis point and realises no more than an honest exit.
    ///
    /// @dev The two branches run as separate top-level calls with a state snapshot between them, because that is
    ///      the only way to compare against a control that has no transient credit at all: Foundry clears
    ///      transient storage between top-level calls, exactly as the EVM clears it between transactions.
    function test_dustBuyCannotDiscountARealExit() public {
        uint256 snapshot = vm.snapshotState();
        (uint256 credit, uint16 baseBps, uint256 gamed) = this.dustBuyEntry();
        vm.revertToState(snapshot);
        uint256 honest = this.honestExitEntry(10e18);

        assertLe(credit, 2, "a 1-wei buy realises a wei or two of AMPS and no more");
        assertEq(baseBps, hook.sellFeeBps(), "and the exit still pays the sell fee in full");
        assertLe(gamed, honest, "the gamed exit is never better than the honest one");
    }

    /// @notice Shape 2 - buy small, sell large. The blend is `buyFee + ceil((sellFee - buyFee) * (in - c) / in)`,
    ///         so the discount is exactly proportional to the credit and nothing more. Netted against the USDG the
    ///         manufacturing buy cost - and its own buy fee, and its own slippage - the manoeuvre is a loss.
    function test_buyThenLargerSellIsNeverProfitable() public {
        uint256 ampsToExit = 20e18;
        uint256 snapshot = vm.snapshotState();
        (int256 gamedNet, uint16 blendedBase) = this.gamedExitEntry(ampsToExit);
        vm.revertToState(snapshot);
        uint256 honest = this.honestExitEntry(ampsToExit);

        assertLt(blendedBase, hook.sellFeeBps(), "the credit really did blend the base fee down");
        assertGt(blendedBase, registry.poolConfig(hubPool).buyFeeBps, "but only partly: this is not a rotation");
        assertLe(gamedNet, int256(honest), "and the netted proceeds never beat the honest exit");
    }

    /// @notice Shape 3 — exact output. An exact-output sell consumes no credit at all (§1.4 step 3), so a swapper
    ///         cannot hold a credit back and spend it on a shape the hook does not police.
    function test_exactOutputConsumesNoCreditAndPaysInFull() public {
        (uint16 baseBps, uint256 creditBefore, uint256 creditAfter) = this.exactOutputEntry();
        assertGt(creditBefore, 0, "there was a credit to spend");
        assertEq(creditAfter, creditBefore, "and the exact-output sell spent none of it");
        assertEq(baseBps, hook.sellFeeBps(), "paying the sell fee in full");
    }

    /// @notice Shape 4 — across transactions. `ROTATION_CREDIT` is one EIP-1153 slot, so the EVM itself zeroes it
    ///         at every transaction boundary: I26's "zero at the start of every transaction" is structural, not
    ///         enforced, and there is no code path that could fail to enforce it.
    function test_noCreditSurvivesToTheNextTransaction() public {
        uint256 bought = buyAmps(hubPool, ALICE, 2e6);
        assertGt(bought, 0, "the buy happened");
        assertEq(hook.rotationCredit(), 0, "and left nothing behind");

        (, uint16 baseBps,,) = hook.quoteFee(hubPool, true, true, bought);
        assertEq(baseBps, hook.sellFeeBps(), "so the next transaction's exit pays the sell fee in full");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Self-call entry points: one transaction each, so the transient credit is live across the hops
    // -------------------------------------------------------------------------------------------------------------

    /// @notice One transaction: a 1-wei buy, then a real exit against the credit it created.
    /// @return credit The credit the dust buy created.
    /// @return baseBps The base fee the exit paid.
    /// @return exitOut USDG the gamed exit realised.
    function dustBuyEntry() external returns (uint256 credit, uint16 baseBps, uint256 exitOut) {
        require(msg.sender == address(this), "self-call only");
        buyAmps(hubPool, ALICE, 1);
        credit = hook.rotationCredit();
        (, baseBps,,) = hook.quoteFee(hubPool, true, true, 10e18);
        exitOut = sellAmps(hubPool, ALICE, 10e18);
    }

    /// @notice One transaction: manufacture a credit with a buy, then exit `ampsOut` AMPS against it.
    /// @param ampsOut The AMPS to exit.
    /// @return net USDG realised less the USDG the manufacturing buy cost.
    /// @return blendedBase The blended base fee the exit paid.
    function gamedExitEntry(uint256 ampsOut) external returns (int256 net, uint16 blendedBase) {
        require(msg.sender == address(this), "self-call only");
        uint256 spent = 1e6;
        buyAmps(hubPool, ALICE, spent);
        (, blendedBase,,) = hook.quoteFee(hubPool, true, true, ampsOut);
        uint256 received = sellAmps(hubPool, ALICE, ampsOut);
        net = int256(received) - int256(spent);
    }

    /// @notice The control: the same exit, in a transaction with no credit in it at all.
    /// @param ampsOut The AMPS to exit.
    /// @return received USDG realised.
    function honestExitEntry(uint256 ampsOut) external returns (uint256 received) {
        require(msg.sender == address(this), "self-call only");
        assertEq(hook.rotationCredit(), 0, "the control starts with no credit");
        received = sellAmps(hubPool, ALICE, ampsOut);
    }

    /// @notice One transaction: buy, then take an exact amount of USDG out.
    /// @return baseBps The base fee the exact-output sell paid.
    /// @return creditBefore The credit before it.
    /// @return creditAfter The credit after it.
    function exactOutputEntry() external returns (uint16 baseBps, uint256 creditBefore, uint256 creditAfter) {
        require(msg.sender == address(this), "self-call only");
        buyAmps(hubPool, ALICE, 2e6);
        creditBefore = hook.rotationCredit();
        (, baseBps,,) = hook.quoteFee(hubPool, true, false, 0);
        sellAmpsExactOut(hubPool, ALICE, 0.5e6);
        creditAfter = hook.rotationCredit();
    }
}
