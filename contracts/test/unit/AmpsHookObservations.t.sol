// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookStateLib} from "../../src/hook/HookStateLib.sol";
import {IAmpsHook} from "../../src/interfaces/IAmpsHook.sol";
import {IMarketReference} from "../../src/interfaces/IMarketReference.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";
import {Constants} from "../../src/types/Constants.sol";
import {GateState} from "../../src/types/Types.sol";
import {HookFaultyGate} from "../mocks/HookFaultyGate.sol";
import {HookTestFixture} from "../mocks/HookTestFixture.sol";
import {MockOracleGate} from "../mocks/MockOracleGate.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title AmpsHookObservationsTest
/// @notice The `afterSwap` half of the hook: the truncated observation ring (I25), the high-water mark the
///         buyback burn reads, the dividend-step detector, and the promise that nothing but the rail can revert
///         a swap (I15).
contract AmpsHookObservationsTest is HookTestFixture {
    HookFaultyGate internal faultyGate;

    function setUp() public {
        _deployFixture();
        faultyGate = new HookFaultyGate();

        // The rail is exercised in `AmpsHookFee.t.sol`; here it is deliberately out of the way, so that any
        // revert this file sees is a revert the design does not allow at all.
        policy.setRailOverride(800_000);
        _refreshGate(usdgKey);
        _refreshGate(stockKey);
    }

    // -----------------------------------------------------------------------------------------------------------
    // I25: the truncated observation ring
    // -----------------------------------------------------------------------------------------------------------

    /// @notice I25: whatever the swap sequence, the truncated tick moves at most `maxTickMovePerBlock` per block,
    ///         so a 30-minute TWAP cannot be moved by more than the cap times the blocks in the window.
    function testFuzz_theTruncatedTickMovesAtMostTheCapPerBlock(uint96[8] memory sizes, uint8 directions) public {
        int24 cap = hook.maxTickMovePerBlock(usdgId);
        int24 start = hook.lastTruncatedTick(usdgId);

        // `block.timestamp` and `block.number` are loop-invariant to solc, which hoists them straight past a
        // `vm.warp`, so the clock is carried in locals and warped to an explicit value.
        uint256 ts = block.timestamp;
        uint256 bn = block.number;
        uint256 blocks;

        for (uint256 i; i < sizes.length; ++i) {
            ts += 2;
            bn += 1;
            vm.warp(ts);
            vm.roll(bn);
            ++blocks;

            // Two swaps inside the same block, so the per-block allowance is charged against the block's anchor
            // and not against the previous swap: N swaps cannot buy N caps of movement.
            for (uint256 j; j < 2; ++j) {
                if ((directions >> i) & 1 == 1) {
                    _buy(usdgKey, uint256(sizes[i] % 1e9) + 1e6);
                } else {
                    _sell(usdgKey, uint256(sizes[i] % 1e21) + 1e18);
                }
            }
        }

        int24 finish = hook.lastTruncatedTick(usdgId);
        int256 moved = int256(finish) - int256(start);
        if (moved < 0) moved = -moved;
        assertLe(uint256(moved), uint256(uint24(cap)) * blocks, "I25: cap x blocks");
    }

    /// @notice The same bound on the 30-minute TWAP itself, once the ring covers the window.
    function test_theThirtyMinuteTwapIsBoundedByTheCapTimesTheBlocks() public {
        int24 cap = hook.maxTickMovePerBlock(usdgId);

        uint256 ts = block.timestamp;
        uint256 bn = block.number;

        // Fill the window with quiet observations, one per block.
        for (uint256 i; i < 40; ++i) {
            ts += 60;
            bn += 1;
            vm.warp(ts);
            vm.roll(bn);
            _pokeAfterSwap(usdgKey, true);
        }
        assertGe(hook.observationCoverage(usdgId), 1800, "the ring covers the window");
        int24 before = hook.twapTick30m(usdgId);

        // Then hammer it for ten blocks.
        uint256 blocks = 10;
        for (uint256 i; i < blocks; ++i) {
            ts += 1;
            bn += 1;
            vm.warp(ts);
            vm.roll(bn);
            _sellRaw(usdgKey, 100_000e18);
        }

        int256 moved = int256(hook.twapTick30m(usdgId)) - int256(before);
        if (moved < 0) moved = -moved;
        assertLe(uint256(moved), uint256(uint24(cap)) * blocks, "I25 on the TWAP");
        assertLt(_currentTick(usdgId), before - int24(uint24(cap)), "the raw price ran further than the cap");
    }

    /// @notice The liveness half of the ring (§12.3 ruling V). An hour of trading in *every single second* - which
    ///         on a 100 ms chain is ordinary, not adversarial - must never take the 30-minute read away: ring
    ///         insertion is rate-limited, so coverage is bought with elapsed time and can only grow.
    function test_theThirtyMinuteReadSurvivesTradingEverySecond() public {
        uint256 ts = block.timestamp;
        uint256 bn = block.number;

        // First, buy the window with quiet blocks so the read is armed at all.
        for (uint256 i; i < 40; ++i) {
            ts += 60;
            bn += 1;
            vm.warp(ts);
            vm.roll(bn);
            _pokeAfterSwap(usdgKey, true);
        }
        assertGe(hook.observationCoverage(usdgId), 1800, "the ring covers the window");
        uint32 covered = hook.observationCoverage(usdgId);

        // Then write in every second for an hour, with a real swap every other minute so the tick genuinely moves
        // under the writes rather than sitting still.
        for (uint256 i; i < 3600; ++i) {
            ts += 1;
            bn += 1;
            vm.warp(ts);
            vm.roll(bn);
            if (i % 120 == 0) _buyRaw(usdgKey, 20_000e6);
            else if (i % 120 == 60) _sellRaw(usdgKey, 20_000e18);
            else _pokeAfterSwap(usdgKey, i % 2 == 0);

            uint32 nowCovered = hook.observationCoverage(usdgId);
            // Coverage grows until the ring wraps, and a wrapped ring still spans 63 insertion intervals.
            assertTrue(nowCovered >= covered || nowCovered >= 63 * 115, "coverage is never spent by trading");
            assertGe(nowCovered, 1800, "and never falls under the window");
            covered = nowCovered;
            hook.twapTick30m(usdgId); // the read that used to revert `WindowNotCovered` after ~63 swaps
        }

        assertEq(covered, hook.observationCoverage(usdgId), "coverage settled");
        assertEq(hook.twapTick(usdgId, 1800), hook.twapTick30m(usdgId), "and the windowed read agrees with it");
    }

    function test_twapReadsRevertOnlyWhenTheWindowIsNotCovered() public {
        uint32 coverage = hook.observationCoverage(usdgId);
        assertLt(coverage, 1800, "the ring does not reach back a window yet");

        vm.expectRevert(
            abi.encodeWithSelector(IMarketReference.WindowNotCovered.selector, usdgId, uint32(1800), coverage)
        );
        hook.twapTick30m(usdgId);

        vm.expectRevert(abi.encodeWithSelector(IMarketReference.PoolNotObserved.selector, PoolId.wrap(bytes32(0))));
        hook.lastTruncatedTick(PoolId.wrap(bytes32(0)));

        vm.warp(block.timestamp + 100);
        vm.roll(block.number + 1);
        _pokeAfterSwap(usdgKey, true);
        assertEq(hook.observationCoverage(usdgId), coverage + 100, "coverage grows with the ring");
        assertEq(hook.twapTick(usdgId, 100), hook.lastTruncatedTick(usdgId), "a flat window is the flat tick");
    }

    // -----------------------------------------------------------------------------------------------------------
    // The high-water mark (I33)
    // -----------------------------------------------------------------------------------------------------------

    function test_theHighWaterMarkAdvancesAndOnlyTheVaultResetsIt() public {
        int24 opening = hook.highWaterTick(usdgId);

        _buy(usdgKey, 100_000e6);
        int24 peak = hook.highWaterTick(usdgId);
        assertGt(peak, opening, "a buy advanced it");
        assertEq(peak, hook.lastTruncatedTick(usdgId), "to the truncated tick");

        // Coming back down leaves the mark where it was: that is what makes it a *high-water* mark.
        _sell(usdgKey, 200_000e18);
        assertEq(hook.highWaterTick(usdgId), peak, "the mark stands");
        assertLt(hook.lastTruncatedTick(usdgId), peak, "even though the price fell through it");

        vm.prank(STRANGER);
        vm.expectRevert();
        hook.resetHighWater(usdgId);

        int24 consumed = hook.resetHighWater(usdgId);
        assertEq(consumed, peak, "the reset returns the mark it consumed");

        // The mark re-arms at `min(truncated, raw)`: the truncated tick is rate-limited and the sell above ran the
        // raw price straight through it, so here the raw tick is what the next window starts from.
        int24 raw = _currentTick(usdgId);
        int24 truncated = hook.lastTruncatedTick(usdgId);
        assertEq(hook.highWaterTick(usdgId), raw < truncated ? raw : truncated, "re-arms at min(truncated, raw)");
    }

    /// @notice The reset lands on the **raw** clock, not the rate-limited one. `lastTruncatedTick` moves at most
    ///         `maxTickMovePerBlock` per block, so after a fast fall it sits far above the pool; a mark left up
    ///         there already covers the asks `compound` re-lays at the fallen price, and the *next* `compound`
    ///         would withdraw and burn them as bought-back inventory that was never sold.
    function test_theHighWaterResetIsFlooredAtTheRawTick() public {
        int24 cap = hook.maxTickMovePerBlock(usdgId);

        // Upwards first: the raw tick runs above the rate-limited one, so `min` picks the truncated tick and the
        // floor changes nothing. This is the case the reset always handled.
        _buy(usdgKey, 200_000e6);
        assertGt(_currentTick(usdgId), hook.lastTruncatedTick(usdgId), "the raw tick led the truncated one up");
        hook.resetHighWater(usdgId);
        assertEq(hook.highWaterTick(usdgId), hook.lastTruncatedTick(usdgId), "min, so a high raw tick is ignored");

        int24 peak = hook.highWaterTick(usdgId);

        // Downwards is the case that was broken: crash the pool in one block, and the recorded tick is charged one
        // cap while the raw price runs thousands of ticks further.
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        _sell(usdgKey, 400_000e18);

        int24 raw = _currentTick(usdgId);
        int24 truncated = hook.lastTruncatedTick(usdgId);
        assertLt(raw, truncated - cap, "the raw price ran far past the block's allowance");
        assertEq(hook.highWaterTick(usdgId), peak, "and the mark is still the pre-crash peak");

        int24 consumed = hook.resetHighWater(usdgId);
        assertEq(consumed, peak, "the reset consumed the peak");
        assertEq(hook.highWaterTick(usdgId), raw, "and re-armed on the raw clock");
        assertLe(hook.highWaterTick(usdgId), _currentTick(usdgId), "never above where the pool actually is");
        assertLt(hook.highWaterTick(usdgId), truncated, "so the lagging truncated tick did not set it");
        assertEq(hook.lastTruncatedTick(usdgId), truncated, "and the truncated series is untouched");
    }

    /// @notice The reset is the vault's, and the mark it arms is what the event reports.
    function test_theHighWaterResetAnnouncesTheMarkItArmed() public {
        _buy(usdgKey, 100_000e6);
        int24 peak = hook.highWaterTick(usdgId);

        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        _sell(usdgKey, 400_000e18);

        vm.expectEmit(true, false, false, true, address(hook));
        emit IAmpsHook.HighWaterReset(usdgId, peak, _currentTick(usdgId));
        hook.resetHighWater(usdgId);
    }

    function test_theHighWaterAdvanceIsAnnounced() public {
        vm.recordLogs();
        _buy(usdgKey, 100_000e6);

        bool seen;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == IAmpsHook.HighWaterAdvanced.selector) seen = true;
        }
        assertTrue(seen, "HighWaterAdvanced");
    }

    // -----------------------------------------------------------------------------------------------------------
    // The dividend-step detector (§1.5 step 7)
    // -----------------------------------------------------------------------------------------------------------

    function test_aSmallMultiplierStepArmsTheCaptureFee() public {
        assertEq(hook.poolState(stockId).uiMultiplierX9, 1e9, "cached at initialize, as X9");

        stock.setUIMultiplier(1.005e18); // +50 bp, a dividend reinvestment
        vm.recordLogs();
        _refreshGate(stockKey);

        assertEq(hook.poolState(stockId).captureFeeBps, 40, "0.8 x 50 bp");
        assertEq(hook.poolState(stockId).captureArmedAt, uint32(block.timestamp), "armed now");
        assertEq(hook.poolState(stockId).uiMultiplierX9, 1.005e9, "the cache moved");
        assertEq(hook.poolState(stockId).gateFlags & 8, 0, "and it is not a corporate action");

        bool seen;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == IAmpsHook.MultiplierStepDetected.selector) {
                seen = true;
            }
        }
        assertTrue(seen, "MultiplierStepDetected");
    }

    function test_aStepAtTheBoundaryStillArmsTheCaptureFee() public {
        stock.setUIMultiplier(1.02e18); // exactly DIVIDEND_STEP_BPS_MAX
        _refreshGate(stockKey);
        assertEq(hook.poolState(stockId).captureFeeBps, 160, "0.8 x 200 bp");
        assertEq(hook.poolState(stockId).dynCapBps, Constants.DYN_CAP_NORMAL_BPS, "still a normal cap");
    }

    function test_aLargeMultiplierStepIsACorporateActionInstead() public {
        stock.setUIMultiplier(10e18); // a 10:1 split
        _refreshGate(stockKey);

        assertEq(hook.poolState(stockId).captureFeeBps, 0, "no capture fee for a split");
        assertTrue(HookStateLib.hasFlag(hook.poolState(stockId).gateFlags, HookStateLib.FLAG_CA_ARMED), "caArmed");
        assertEq(hook.poolState(stockId).dynCapBps, Constants.DYN_CAP_ESCALATION_BPS, "escalation cap");
        assertEq(hook.poolState(stockId).uiMultiplierX9, 10e9, "the cache still moved");
    }

    /// @notice The corporate-action flag comes back down when the action is over. `OracleGate` reads bit 3 to
    ///         shut a constituent's bonds and placements, so a flag the hook only ever raised would freeze that
    ///         constituent for good.
    function test_aResolvedCorporateActionLowersTheFlag() public {
        stock.setUIMultiplier(10e18); // a 10:1 split
        _refreshGate(stockKey);
        assertTrue(_caArmed(), "armed by the split");
        assertEq(hook.poolState(stockId).dynCapBps, Constants.DYN_CAP_ESCALATION_BPS, "escalation cap");

        // The issuer is still frozen: the flag stands.
        stock.setOraclePaused(true);
        _refreshGate(stockKey);
        assertTrue(_caArmed(), "oraclePaused keeps it up");

        // Un-paused, but with another multiplier change scheduled inside the corporate-action window.
        stock.setOraclePaused(false);
        stock.scheduleUIMultiplier(20e18, block.timestamp + 600);
        _refreshGate(stockKey);
        assertTrue(_caArmed(), "a pending effectiveAt keeps it up");

        // Nothing pending, nothing paused, no further step: resolved.
        stock.scheduleUIMultiplier(0, 0);
        _refreshGate(stockKey);
        assertFalse(_caArmed(), "cleared");
        assertEq(hook.poolState(stockId).dynCapBps, Constants.DYN_CAP_NORMAL_BPS, "and the cap comes back");
    }

    /// @notice A token that cannot answer the two resolution probes leaves the flag exactly where it was.
    function test_anUnreadableTokenLeavesTheCorporateActionFlagUp() public {
        stock.setUIMultiplier(10e18);
        _refreshGate(stockKey);
        assertTrue(_caArmed(), "armed");

        vm.mockCallRevert(address(stock), abi.encodeWithSelector(IStockToken.oraclePaused.selector), bytes("no"));
        _refreshGate(stockKey);
        assertTrue(_caArmed(), "an unreadable probe is not a resolution");
    }

    function _caArmed() private view returns (bool) {
        return HookStateLib.hasFlag(hook.poolState(stockId).gateFlags, HookStateLib.FLAG_CA_ARMED);
    }

    // -----------------------------------------------------------------------------------------------------------
    // The X9 store (re-audit finding 9: the X18 field saturated at 18.45x and silenced the detector for good)
    // -----------------------------------------------------------------------------------------------------------

    /// @notice **Re-audit finding 9.** A multiplier past the old X18 ceiling is stored exactly, and its step is
    ///         armed once and then resolves — not re-armed on every refresh, and not made invisible.
    ///
    /// @dev `Armed.uiMultiplierX9` is 64 bits holding `uiMultiplier() / 1e9`, so the ceiling is ~1.8e10x rather
    ///      than the 18.45x an X18 store gave. `type(uint64).max + 1e18` is ~18.45e18 — the value that used to
    ///      saturate — and it is now kept to the wei-over-1e9.
    function test_r03_aMultiplierPastTheOldCeilingIsStoredExactly() public {
        uint256 m = uint256(type(uint64).max) + 1e18; // ~18.45e18, the old saturation point
        stock.setUIMultiplier(m);
        _refreshGate(stockKey);

        assertEq(hook.poolState(stockId).uiMultiplierX9, uint64(m / 1e9), "the cache holds the real reading");
        assertTrue(_caArmed(), "the jump from 1.0 really is a corporate action");
        assertEq(hook.poolState(stockId).dynCapBps, Constants.DYN_CAP_ESCALATION_BPS, "escalation cap");

        // Nothing at the token moves. The next refresh must therefore see no step at all — and, seeing none, be
        // free to resolve the corporate action it armed.
        vm.recordLogs();
        _refreshGate(stockKey);

        assertFalse(_sawMultiplierStep(vm.getRecordedLogs()), "no phantom step on the second refresh");
        assertFalse(_caArmed(), "so the flag comes back down");
        assertEq(hook.poolState(stockId).dynCapBps, Constants.DYN_CAP_NORMAL_BPS, "and the cap with it");
        assertEq(hook.poolState(stockId).captureFeeBps, 0, "and nothing was armed in its place");
    }

    /// @notice **Re-audit finding 9, the live case.** A 20x name — one 5:1 split away from a 4.0x listing, and
    ///         entirely above the old 18.45x ceiling — pays its dividend toll like any other.
    ///
    /// @dev Under the X18 store both readings clipped to `type(uint64).max`, `deltaBps` was identically zero, and
    ///      the small-step branch then *cleared* any standing corporate-action flag on every single refresh: no
    ///      capture toll, no surge and no freeze could ever arm for that constituent again. The step here is
    ///      `20.0 -> 20.4`, exactly 200 bp, which is `DIVIDEND_STEP_BPS_MAX` — the largest move still treated as a
    ///      dividend — and arms `0.8 x 200 = 160` bp of capture fee.
    function test_r03_aStepAtTwentyTimesArmsTheToll() public {
        stock.setUIMultiplier(20e18);
        _refreshGate(stockKey);
        _refreshGate(stockKey); // the 1.0 -> 20.0 jump is a corporate action; let it resolve
        assertFalse(_caArmed(), "resolved");
        assertEq(hook.poolState(stockId).uiMultiplierX9, 20e9, "20x, stored exactly");

        stock.setUIMultiplier(20.4e18); // +2%, a dividend reinvestment on a 20x name
        vm.recordLogs();
        _refreshGate(stockKey);

        assertTrue(_sawMultiplierStep(vm.getRecordedLogs()), "the step is seen");
        assertEq(hook.poolState(stockId).captureFeeBps, 160, "0.8 x 200 bp, measured correctly at 20x");
        assertEq(hook.poolState(stockId).captureArmedAt, uint32(block.timestamp), "armed now");
        assertEq(hook.poolState(stockId).surgeBps, Constants.SURGE_MAX_BPS, "and the surge with it");
        assertFalse(_caArmed(), "a 2% step is a dividend, not a corporate action");
        assertEq(hook.poolState(stockId).uiMultiplierX9, 20.4e9, "the cache moved to the new reading");
    }

    /// @notice **Re-audit finding 9, the far edge.** A reading that does not fit even the X9 field is a *probe
    ///         failure*, not "nothing observed": `refreshFailed` rises, the cached value stands, and — the part
    ///         that matters — a standing corporate-action flag is neither cleared nor re-armed by it.
    function test_r03_aReadingBeyondTheX9CeilingIsAProbeFailure() public {
        stock.setUIMultiplier(10e18); // a 10:1 split raises the flag
        _refreshGate(stockKey);
        assertTrue(_caArmed(), "armed by the split");

        // Past `type(uint64).max * 1e9`: no honest issuer can mean this, and the detector cannot measure it.
        stock.setUIMultiplier(type(uint256).max);
        vm.recordLogs();
        _refreshGate(stockKey);

        assertTrue(
            HookStateLib.hasFlag(hook.poolState(stockId).gateFlags, HookStateLib.FLAG_REFRESH_FAILED),
            "the probe is reported as failed"
        );
        assertFalse(_sawMultiplierStep(vm.getRecordedLogs()), "and no step is claimed");
        assertEq(hook.poolState(stockId).uiMultiplierX9, 10e9, "the cached reading stands");
        assertTrue(_caArmed(), "and an unreadable probe never clears a corporate action");
        assertEq(hook.poolState(stockId).captureFeeBps, 0, "nothing armed either");

        // And a swap still goes through: an unreadable probe is a flag, never a revert (I15).
        assertGt(_buy(stockKey, 1e18), 0, "swaps are unaffected");
    }

    /// @dev Whether the hook reported a `uiMultiplier()` step in this batch of logs.
    function _sawMultiplierStep(Vm.Log[] memory logs) private pure returns (bool seen) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == IAmpsHook.MultiplierStepDetected.selector) {
                return true;
            }
        }
    }

    /// @notice **Audit finding 11.** A step is a step in either direction. `deltaBps` was computed only when the
    ///         multiplier *rose*, so a reverse split, a negative restatement or any downward `uiMultiplier()` move
    ///         of any size armed nothing at all — no capture fee, no surge, no corporate-action flag — and, worse,
    ///         satisfied the small-step branch, so it could *clear* a flag standing over exactly that event.
    ///
    /// @dev A 50% fall is far past `DIVIDEND_STEP_BPS_MAX`, so it is a corporate action and raises `caArmed`,
    ///      exactly as the 10:1 split above does. The sign says only which way the arbitrage runs, and `FeeInput`
    ///      carries that separately as `captureDirectionTakesStock`.
    function test_f11_aMultiplierThatFallsFarIsACorporateActionToo() public {
        stock.setUIMultiplier(0.5e18);
        _refreshGate(stockKey);

        assertTrue(HookStateLib.hasFlag(hook.poolState(stockId).gateFlags, HookStateLib.FLAG_CA_ARMED), "caArmed");
        assertEq(hook.poolState(stockId).dynCapBps, Constants.DYN_CAP_ESCALATION_BPS, "escalation cap");
        assertEq(hook.poolState(stockId).uiMultiplierX9, 0.5e9, "and the cache is exactly what was read");
    }

    /// @notice And a downward step small enough to be a dividend arms the capture fee, at the same 80% of the step
    ///         an upward one does.
    function test_f11_aSmallDownwardStepArmsTheCaptureFee() public {
        stock.setUIMultiplier(0.995e18); // -50 bp
        _refreshGate(stockKey);

        assertEq(hook.poolState(stockId).captureFeeBps, 40, "0.8 x 50 bp, whichever way the step went");
        assertEq(hook.poolState(stockId).captureArmedAt, uint32(block.timestamp), "armed now");
        assertEq(hook.poolState(stockId).gateFlags & 8, 0, "and it is not a corporate action");
        assertEq(hook.poolState(stockId).uiMultiplierX9, 0.995e9, "the cache is what was read");
    }

    /// @notice **The second half of finding 11.** A one-basis-point step cannot erase a standing toll. The capture
    ///         fee is 80% of the step it was armed for, so a 1 bp step quotes 0 bp — and writing that over an armed
    ///         160 bp fee inside its own decay window handed the dividend arbitrage the rest of the step for the
    ///         price of a dust `uiMultiplier()` nudge by the issuer.
    function test_f11_aOneBasisPointStepDoesNotEraseAnArmedCaptureFee() public {
        stock.setUIMultiplier(1.02e18); // exactly DIVIDEND_STEP_BPS_MAX: 160 bp of capture fee
        _refreshGate(stockKey);
        assertEq(hook.poolState(stockId).captureFeeBps, 160, "the toll is armed");
        uint32 armedAt = hook.poolState(stockId).captureArmedAt;

        // +1 bp on top: `0.8 x 1 bp` rounds to zero, which is what used to be written over the 160.
        stock.setUIMultiplier(1.020102e18);
        _refreshGate(stockKey);
        assertEq(hook.poolState(stockId).captureFeeBps, 160, "the standing toll survives a smaller step");
        assertEq(hook.poolState(stockId).captureArmedAt, armedAt, "with its original clock, so it still expires");
        assertEq(hook.poolState(stockId).uiMultiplierX9, 1.020102e9, "and the cache is exactly what was read");

        // A step at least as large as the standing toll's own does replace it, clock included.
        stock.setUIMultiplier(1.04050404e18); // exactly another 200 bp
        _refreshGate(stockKey);
        assertEq(hook.poolState(stockId).captureFeeBps, 160, "a step of the same size re-arms the same fee");
        assertEq(hook.poolState(stockId).captureArmedAt, uint32(block.timestamp), "with a fresh clock");
    }

    function test_anUnreadableMultiplierIsAFlagAndNotARevert() public {
        vm.mockCallRevert(address(stock), abi.encodeWithSelector(IStockToken.uiMultiplier.selector), bytes("no"));
        _refreshGate(stockKey);

        assertTrue(HookStateLib.hasFlag(hook.poolState(stockId).gateFlags, HookStateLib.FLAG_REFRESH_FAILED), "flagged");
        assertEq(hook.poolState(stockId).uiMultiplierX9, 1e9, "the cached value stands");

        // And a swap still goes through.
        assertGt(_buy(stockKey, 1e18), 0, "swaps are unaffected");
    }

    /// @notice A token that answers with something too short to decode. `try`/`catch` cannot survive this; the
    ///         hook's manual decode can.
    function test_aGarbageMultiplierIsAFlagAndNotARevert() public {
        vm.mockCall(address(stock), abi.encodeWithSelector(IStockToken.uiMultiplier.selector), hex"01");
        _refreshGate(stockKey);
        assertEq(hook.poolState(stockId).uiMultiplierX9, 1e9, "the cached value stands");
        assertGt(_buy(stockKey, 1e18), 0, "swaps are unaffected");
    }

    // -----------------------------------------------------------------------------------------------------------
    // I15: afterSwap never reverts for a non-rail reason
    // -----------------------------------------------------------------------------------------------------------

    /// @notice Every combination of downstream failure, against both directions and a range of sizes. With the
    ///         rail deliberately out of reach, a swap that reverts at all is a bug.
    function testFuzz_noSwapEverRevertsForANonRailReason(uint8 faults, bool sell, uint96 size) public {
        _injectFaults(faults);

        uint256 amountIn = sell ? uint256(size % 1e22) + 1e18 : uint256(size % 1e10) + 1e6;
        if (sell) _sellRaw(usdgKey, amountIn);
        else _buyRaw(usdgKey, amountIn);

        // The pool moved, so the callback really ran.
        assertEq(hook.poolState(usdgId).lastTick, _currentTick(usdgId), "afterSwap recorded the tick");
    }

    /// @notice The same, on a spoke, where the multiplier probe and the constituent gate are also in play.
    function testFuzz_noSpokeSwapEverRevertsForANonRailReason(uint8 faults, bool sell, uint96 size) public {
        _injectFaults(faults);
        vm.warp(block.timestamp + hook.gateCacheSeconds() + 1);

        uint256 amountIn = sell ? uint256(size % 1e22) + 1e18 : uint256(size % 1e19) + 1e15;
        if (sell) _sellRaw(stockKey, amountIn);
        else _buyRaw(stockKey, amountIn);

        assertEq(hook.poolState(stockId).lastTick, _currentTick(stockId), "afterSwap recorded the tick");
    }

    /// @notice A gate that burns every wei of gas it is given cannot take the swap with it.
    function test_anOutOfGasGateIsSurvivable() public {
        faultyGate.setMode(HookFaultyGate.Mode.OUT_OF_GAS);
        _setGatePointer(address(faultyGate));
        vm.warp(block.timestamp + hook.gateCacheSeconds() + 1);

        assertGt(_buy(usdgKey, 1000e6), 0, "the swap completed");
        assertTrue(HookStateLib.hasFlag(hook.poolState(usdgId).gateFlags, HookStateLib.FLAG_REFRESH_FAILED), "flagged");
    }

    /// @notice A gate that answers with impossible values has every one of them clamped before it reaches storage.
    function test_aRogueGateIsClamped() public {
        faultyGate.setMode(HookFaultyGate.Mode.ROGUE);
        _setGatePointer(address(faultyGate));
        vm.warp(block.timestamp + hook.gateCacheSeconds() + 1);
        _pokeAfterSwap(usdgKey, true);

        assertLe(hook.poolState(usdgId).dynCapBps, Constants.DYN_CAP_ESCALATION_BPS, "the cap is clamped");
        assertLe(uint8(hook.poolState(usdgId).session), 3, "the session enum is clamped");
        assertTrue(
            HookStateLib.hasFlag(hook.poolState(usdgId).gateFlags, HookStateLib.FLAG_DEGRADED),
            "an unknown state is treated as degraded"
        );
    }

    /// @notice A spoke whose gate snapshot fails falls back to its own truncated TWAP for the fair tick, exactly
    ///         as an entry pool always does. Leaving the cached value pinned is worse than it looks: a pool whose
    ///         snapshot has never succeeded would keep the *opening* tick as its reference for the whole outage,
    ///         so every deviation, rail check and `RebalanceNeeded` would be measured against a price that stopped
    ///         being true at initialisation.
    function test_aSpokeFallsBackToItsOwnTwapWhenTheSnapshotFails() public {
        int24 opening = hook.poolState(stockId).fairTick;

        // Move the spoke well away from where it opened, then buy the ring a full window of coverage.
        _sell(stockKey, 300_000e18);
        uint256 ts = block.timestamp;
        uint256 bn = block.number;
        for (uint256 i; i < 40; ++i) {
            ts += 60;
            bn += 1;
            vm.warp(ts);
            vm.roll(bn);
            _pokeAfterSwap(stockKey, true);
        }
        assertGe(hook.observationCoverage(stockId), 1800, "the ring covers the window");

        // The healthy mock gate derives no fair tick for this pool, so the cache is still pinned where it opened:
        // this is the state the fallback has to rescue.
        assertEq(hook.poolState(stockId).fairTick, opening, "pinned at the opening tick while the gate answers");
        int24 twap = hook.twapTick30m(stockId);
        assertLt(twap, opening - 100, "and the pool has genuinely moved away from it");

        // Now the gate stops answering.
        faultyGate.setMode(HookFaultyGate.Mode.REVERTS);
        _setGatePointer(address(faultyGate));
        vm.warp(block.timestamp + hook.gateCacheSeconds() + 1);
        vm.roll(block.number + 1);
        _pokeAfterSwap(stockKey, true);

        assertTrue(
            HookStateLib.hasFlag(hook.poolState(stockId).gateFlags, HookStateLib.FLAG_REFRESH_FAILED),
            "the failure is still flagged"
        );
        assertEq(hook.poolState(stockId).fairTick, hook.twapTick30m(stockId), "the fair tick tracks the TWAP");
        assertTrue(hook.poolState(stockId).fairTick != opening, "and is no longer pinned at the opening tick");
    }

    /// @notice The guard on that fallback: below a full window of coverage the ring is not a reference, so the
    ///         last known fair tick stands rather than a half-covered reading or a zero.
    function test_aSpokeWithNoCoverageKeepsItsLastFairTickWhenTheSnapshotFails() public {
        int24 opening = hook.poolState(stockId).fairTick;
        assertLt(hook.observationCoverage(stockId), 1800, "the ring does not reach back a window yet");

        faultyGate.setMode(HookFaultyGate.Mode.REVERTS);
        _setGatePointer(address(faultyGate));
        vm.warp(block.timestamp + hook.gateCacheSeconds() + 1);
        vm.roll(block.number + 1);
        _pokeAfterSwap(stockKey, true);

        assertEq(hook.poolState(stockId).fairTick, opening, "the last known fair tick stands");
    }

    /// @notice And the fallback is only for a snapshot that failed: a gate that answers still owns a spoke's fair
    ///         tick, however far the pool's own TWAP has wandered from it.
    function test_aHealthyGateStillOwnsASpokesFairTick() public {
        _sell(stockKey, 300_000e18);
        uint256 ts = block.timestamp;
        uint256 bn = block.number;
        for (uint256 i; i < 40; ++i) {
            ts += 60;
            bn += 1;
            vm.warp(ts);
            vm.roll(bn);
            _pokeAfterSwap(stockKey, true);
        }
        assertGe(hook.observationCoverage(stockId), 1800, "the ring covers the window");

        MockOracleGate.PoolState memory ps;
        ps.set = true;
        ps.state = GateState.GREEN;
        ps.dynCapBps = Constants.DYN_CAP_NORMAL_BPS;
        ps.fairTick = 12_345;
        gate.setPoolState(stockId, ps);

        vm.warp(block.timestamp + hook.gateCacheSeconds() + 1);
        vm.roll(block.number + 1);
        _pokeAfterSwap(stockKey, true);

        assertEq(hook.poolState(stockId).fairTick, int24(12_345), "the gate's fair tick wins");
        assertTrue(hook.poolState(stockId).fairTick != hook.twapTick30m(stockId), "the TWAP did not overwrite it");
    }

    /// @notice The registry is not on the swap path at all: `beforeSwap` reads three of the hook's own words and
    ///         the pure policy, and nothing else (§1.7).
    function test_theRegistryIsNeverReadOnTheSwapPath() public {
        vm.mockCallRevert(address(registry), bytes(""), bytes("registry down"));
        assertGt(_buy(usdgKey, 1000e6), 0, "the buy completed");
        assertGt(_sell(stockKey, 1e18), 0, "and so did a spoke sell");
    }

    /// @dev Turns the fuzzer's bitmask into a combination of downstream failures.
    function _injectFaults(uint8 faults) private {
        if (faults & 1 != 0) policy.setReverts(true);
        if (faults & 2 != 0) policy.setReturnsGarbage(true);
        if (faults & 4 != 0) {
            faultyGate.setMode(HookFaultyGate.Mode.REVERTS);
            _setGatePointer(address(faultyGate));
        }
        if (faults & 8 != 0) {
            faultyGate.setMode(HookFaultyGate.Mode.GARBAGE);
            _setGatePointer(address(faultyGate));
        }
        if (faults & 16 != 0) {
            faultyGate.setMode(HookFaultyGate.Mode.ROGUE);
            _setGatePointer(address(faultyGate));
        }
        if (faults & 32 != 0) _setGatePointer(address(0xDEAD));
        if (faults & 64 != 0) gatePointerReverts = true;
        if (faults & 128 != 0) {
            vm.mockCallRevert(address(stock), abi.encodeWithSelector(IStockToken.uiMultiplier.selector), bytes("no"));
            vm.mockCallRevert(address(registry), bytes(""), bytes("registry down"));
        }
    }
}
