// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAmpsQuoter} from "../../src/interfaces/IAmpsQuoter.sol";
import {Constants} from "../../src/types/Constants.sol";
import {GateSnapshot, GateState, PlacementRecord} from "../../src/types/Types.sol";
import {Phase3Fixture} from "./Phase3Fixture.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "forge-std/console.sol";

/// @title CorporateActionTest
/// @notice `docs/phase3-state-model.md` §8.1's row for `integration/CorporateAction.t.sol`, and the plan's two
///         corporate-action exit clauses: a 0.5% dividend step captured `>= 60%` by the capture fee, and a
///         simulated 10:1 split with `oraclePaused()` producing **zero** position movement, **zero** NAV change
///         and a closed bond market — with the freeze arriving through the hook's own flag as well as through the
///         gate's token probes, and clearing again once the action resolves.
///
/// @dev The whole point of ERC-8056 is that a display multiplier moves no raw balance and no Chainlink answer.
///      Every assertion here therefore has two halves: what must *not* move (NAV, positions, the tick) and what
///      must (the fee on the arbitrage direction, the gate state, the bond market).
contract CorporateActionTest is Phase3Fixture {
    /// @dev `gateFlags` bit 1: the gate says a corporate action is in force.
    uint8 internal constant FLAG_CORPORATE_FREEZE = 2;
    /// @dev `gateFlags` bit 3: the hook's own detector armed on a multiplier step it could not explain.
    uint8 internal constant FLAG_CA_ARMED = 8;

    function setUp() public {
        deployPhase3World();
        placeGenesisLadders();
        fundPot(100_000e6);
        // Let the placement surge decay to nothing, so every fee measured below is the fee law at rest.
        warpBy(Constants.SURGE_HALF_LIFE * 8 + 1);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The dividend step
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The plan's "surge captures `>= 60%` of a simulated 0.5% dividend step".
    ///
    ///         A dividend reinvestment makes each raw stock token worth `1 + delta` of what it was. Nothing on
    ///         chain moves, so the arbitrage is to take stock **out** of the pool — `zeroForOne == true`, because
    ///         AMPS is `currency0` — and the capture fee is charged on exactly that direction, at
    ///         `DIVIDEND_CAPTURE_NUMERATOR_BPS` (80%) of the step. The other direction is untouched.
    function test_dividendStepIsCapturedByAtLeastSixtyPercent() public {
        PoolId spoke = spokePools[0];
        // Two refreshes and a decay window: the first refresh settles `fairTick` (a fair-tick move arms a surge,
        // by design), the wait lets that surge decay to nothing, and the second measurement is then the fee law
        // at rest with nothing but `f_dev` in it.
        refreshGateCache(spoke);
        warpBy(Constants.SURGE_HALF_LIFE * 8 + 1);

        (,, uint16 sellDynBefore,) = hook.quoteFee(spoke, true, true, 1e18);
        (,, uint16 buyDynBefore,) = hook.quoteFee(spoke, false, true, 1e15);
        assertLt(sellDynBefore, Constants.DYN_CAP_NORMAL_BPS, "the fee is not already at its cap");

        // A 0.5% dividend reinvestment: 50 bp, inside `DIVIDEND_STEP_BPS_MAX`, so it is a capture and not an
        // escalation.
        uint16 stepBps = 50;
        stocks[0].setUIMultiplier(1e18 + uint256(stepBps) * 1e18 / Constants.BPS);
        refreshGateCache(spoke);

        // The armed value is the law itself: 80% of the step, and the arbitrageur keeps the other 20%.
        assertEq(
            uint256(hook.poolState(spoke).captureFeeBps),
            uint256(stepBps) * Constants.DIVIDEND_CAPTURE_NUMERATOR_BPS / Constants.BPS,
            "the capture fee armed at exactly 80% of the step"
        );
        assertGe(
            uint256(hook.poolState(spoke).captureFeeBps) * Constants.BPS,
            uint256(stepBps) * 6000,
            "which is at least the 60% the plan requires"
        );

        // What the swapper is charged. A multiplier step also arms a full surge (§1.6), and a surge applies to
        // both directions, so the two are separated by waiting one surge half-life: the capture's own half-life is
        // five times longer, and only the stock-taking direction pays it.
        // Park the pool exactly on its reference first, so `f_dev` is zero on both sides and the only thing left
        // between the two directions is the capture fee itself. (A price-improving swap skips `f_dev` entirely,
        // §12.1 ruling I, which would otherwise show up in the difference.)
        forceTick(spoke, hook.fairTick(spoke));
        warpBy(Constants.SURGE_HALF_LIFE + 5);
        (,, uint16 sellDynAfter,) = hook.quoteFee(spoke, true, true, 1e18);
        (,, uint16 buyDynAfter,) = hook.quoteFee(spoke, false, true, 1e15);

        console.log("sell dyn before", sellDynBefore, "after", sellDynAfter);
        console.log("buy dyn before", buyDynBefore, "after", buyDynAfter);
        uint16 captured = sellDynAfter - buyDynAfter;
        console.log("dividend step bps", stepBps, "charged on the stock-taking side, bps", captured);
        assertLt(sellDynAfter, Constants.DYN_CAP_NORMAL_BPS, "and the charge is not clipped by the cap");
        assertGe(
            uint256(captured) * Constants.BPS,
            uint256(stepBps) * 6000,
            "the direction that takes stock out pays at least 60% of the step"
        );

        // It decays: `DIVIDEND_CAPTURE_HALF_LIFE` is 300 s, so eight half-lives later there is nothing left.
        warpBy(Constants.DIVIDEND_CAPTURE_HALF_LIFE * 8 + 1);
        refreshGateCache(spoke);
        (,, uint16 sellDynDecayed,) = hook.quoteFee(spoke, true, true, 1e18);
        assertLe(sellDynDecayed, sellDynBefore, "and the capture fee decays back to nothing");
    }

    /// @notice A step is a *display* change: the Chainlink answer is never re-multiplied, so NAV, `P_ref` and the
    ///         pool's own tick are all exactly where they were.
    function test_dividendStepMovesNoPriceAndNoNav() public {
        PoolId spoke = spokePools[0];
        uint256 navBefore = vault.previewNavPerShareX18();
        int24 tickBefore = tickOf(spoke);

        stocks[0].setUIMultiplier(1.005e18);
        refreshGateCache(spoke);
        vault.checkpoint();

        assertApproxEqAbs(vault.previewNavPerShareX18(), navBefore, 1e10, "a display multiplier is not a price");
        assertEq(tickOf(spoke), tickBefore, "and it moves no pool");
    }

    // -------------------------------------------------------------------------------------------------------------
    // The split
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The plan's "a simulated 10:1 split with `oraclePaused()` produces zero position movement, zero NAV
    ///         change and a closed bond market", and §8.1's `SCHEDULED_FREEZE` through the hook's flag and the
    ///         token probes both.
    function test_scheduledSplitWithOraclePausedFreezesEverythingAndMovesNothing() public {
        PoolId spoke = spokePools[0];
        uint16 constituentId = constituentIds[0];

        uint256 navBefore = vault.previewNavPerShareX18();
        uint256 supplyBefore = amps.totalSupply();
        uint32 liveCellsBefore = vault.liveCells();
        PlacementRecord[] memory before = ladderOf(spoke);
        int24 tickBefore = tickOf(spoke);

        // The issuer announces a 10:1 split and freezes its own oracle while it happens.
        stocks[0].setOraclePaused(true);
        stocks[0].scheduleUIMultiplier(10e18, vm.getBlockTimestamp() + 1 hours);
        refreshGateCache(spoke);

        // The gate sees it, both ways round.
        GateSnapshot memory snapshot = gate.snapshotByPool(spoke);
        assertTrue(snapshot.corporateFreeze, "the gate's own token probes see the freeze");
        assertEq(uint256(snapshot.state), uint256(GateState.SCHEDULED_FREEZE), "and it is the reported state");
        assertEq(
            hook.poolState(spoke).gateFlags & FLAG_CORPORATE_FREEZE,
            FLAG_CORPORATE_FREEZE,
            "and the hook cached it as its own corporate-freeze flag"
        );

        // Every management path stands still.
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        vm.expectRevert();
        vm.prank(KEEPER);
        vault.compound(spoke);

        vm.expectRevert();
        vm.prank(TIMELOCK);
        vault.place(spoke, true, 1e18);

        vm.expectRevert();
        vm.prank(KEEPER);
        vault.rollout(constituentId);

        // The bond market is closed.
        stocks[0].mint(ALICE, 1e18);
        vm.startPrank(ALICE);
        stocks[0].approve(address(vault), type(uint256).max);
        vm.expectRevert();
        bonds.bond(marketIds[0], 1e18, 0, ALICE);
        vm.stopPrank();

        // And nothing moved.
        PlacementRecord[] memory during = ladderOf(spoke);
        assertEq(during.length, before.length, "no cell opened or closed");
        for (uint256 i; i < during.length; ++i) {
            assertEq(during[i].liquidity, before[i].liquidity, "no position moved");
            assertEq(during[i].lowerTick, before[i].lowerTick, "no range moved");
        }
        assertEq(vault.liveCells(), liveCellsBefore, "the live-cell count is untouched");
        assertEq(tickOf(spoke), tickBefore, "and so is the pool");
        vault.checkpoint();
        assertApproxEqAbs(
            vault.previewNavPerShareX18(), navBefore, 1e10, "NAV/share did not move beyond the reference's own drift"
        );
        assertEq(amps.totalSupply(), supplyBefore, "and nothing was minted or burned");

        // Swaps and redemption are never gated (I15, I14): the market keeps trading through the freeze.
        assertGt(buyAmps(spoke, BOB, 1e14), 0, "a swap still goes through a corporate freeze");
    }

    /// @notice The flag clears once the action resolves: the multiplier is promoted, the schedule is cleared, the
    ///         issuer un-pauses, and one more refresh takes the protocol back to green.
    function test_theFreezeClearsWhenTheActionResolves() public {
        PoolId spoke = spokePools[0];
        stocks[0].setOraclePaused(true);
        stocks[0].scheduleUIMultiplier(10e18, vm.getBlockTimestamp() + 1 hours);
        refreshGateCache(spoke);
        assertTrue(gate.snapshotByPool(spoke).corporateFreeze, "frozen while the action is pending");

        // The split happens: the display multiplier is promoted, the schedule cleared, the oracle un-paused.
        warpBy(2 hours);
        stocks[0].applyScheduledUIMultiplier();
        stocks[0].scheduleUIMultiplier(0, 0);
        stocks[0].setOraclePaused(false);

        // Two refreshes: the first sees the (huge) multiplier step and arms `caArmed`; the second sees a stable
        // multiplier, an un-paused oracle and no schedule, and clears it (§12.1 ruling I).
        refreshGateCache(spoke);
        assertEq(
            hook.poolState(spoke).gateFlags & FLAG_CA_ARMED,
            FLAG_CA_ARMED,
            "a 900% step is an escalation, not a dividend: the hook arms the corporate-action flag"
        );
        assertEq(
            uint256(hook.poolState(spoke).dynCapBps),
            uint256(Constants.DYN_CAP_ESCALATION_BPS),
            "and escalates the dynamic cap while it is armed"
        );

        refreshGateCache(spoke);
        assertEq(hook.poolState(spoke).gateFlags & FLAG_CA_ARMED, 0, "the second refresh clears it");
        assertFalse(gate.snapshotByPool(spoke).corporateFreeze, "and the gate is no longer frozen");

        // Management works again.
        warpBy(Constants.PLACEMENT_COOLDOWN_SECONDS + 1);
        settleTwap();
        vm.prank(TIMELOCK);
        vault.place(spoke, true, 1e18);
    }

    /// @notice Ruling 10's path, in isolation: the **hook's** armed flag alone is enough to freeze the gate, even
    ///         with the token itself reporting a perfectly healthy, un-paused, unscheduled state. That is what
    ///         makes a silent `effectiveAt` flip detectable.
    function test_theHookFlagAloneFreezesTheGate() public {
        PoolId spoke = spokePools[0];
        refreshGateCache(spoke);
        assertFalse(gate.snapshotByPool(spoke).corporateFreeze, "green to begin with");

        // An unannounced multiplier jump, larger than `DIVIDEND_STEP_BPS_MAX`: nothing is paused and nothing is
        // scheduled, so the gate's own probes see a healthy token.
        stocks[0].setUIMultiplier(4e18);
        refreshGateCache(spoke);

        assertFalse(stocks[0].oraclePaused(), "the token says it is fine");
        assertEq(stocks[0].effectiveAt(), 0, "and that nothing is scheduled");
        assertEq(hook.poolState(spoke).gateFlags & FLAG_CA_ARMED, FLAG_CA_ARMED, "but the hook saw the step");
        assertTrue(gate.snapshotByPool(spoke).corporateFreeze, "and the gate reads the hook's flag");
        assertEq(
            uint256(gate.snapshotByPool(spoke).state),
            uint256(GateState.SCHEDULED_FREEZE),
            "SCHEDULED_FREEZE, from the hook rather than from the token"
        );

        // The quoter surfaces it to the dApp.
        IAmpsQuoter.PoolQuote memory quote = quoter.quotePool(spoke);
        assertTrue(quote.corporateFreeze, "and the quoter reports it");
    }
}
