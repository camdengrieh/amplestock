// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookStateLib} from "../../src/hook/HookStateLib.sol";
import {IAmpsHook} from "../../src/interfaces/IAmpsHook.sol";
import {IMarketReference} from "../../src/interfaces/IMarketReference.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";
import {Constants} from "../../src/types/Constants.sol";
import {HookFaultyGate} from "../mocks/HookFaultyGate.sol";
import {HookTestFixture} from "../mocks/HookTestFixture.sol";
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
        assertEq(hook.highWaterTick(usdgId), hook.lastTruncatedTick(usdgId), "and re-arms at the current tick");
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
        assertEq(hook.poolState(stockId).uiMultiplierX18, 1e18, "cached at initialize");

        stock.setUIMultiplier(1.005e18); // +50 bp, a dividend reinvestment
        vm.recordLogs();
        _refreshGate(stockKey);

        assertEq(hook.poolState(stockId).captureFeeBps, 40, "0.8 x 50 bp");
        assertEq(hook.poolState(stockId).captureArmedAt, uint32(block.timestamp), "armed now");
        assertEq(hook.poolState(stockId).uiMultiplierX18, 1.005e18, "the cache moved");
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
        assertEq(hook.poolState(stockId).uiMultiplierX18, 10e18, "the cache still moved");
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

    function test_aMultiplierThatFallsIsIgnored() public {
        stock.setUIMultiplier(0.5e18);
        _refreshGate(stockKey);
        assertEq(hook.poolState(stockId).captureFeeBps, 0, "nothing armed");
        assertEq(hook.poolState(stockId).uiMultiplierX18, 0.5e18, "but the cache follows");
    }

    function test_anUnreadableMultiplierIsAFlagAndNotARevert() public {
        vm.mockCallRevert(address(stock), abi.encodeWithSelector(IStockToken.uiMultiplier.selector), bytes("no"));
        _refreshGate(stockKey);

        assertTrue(HookStateLib.hasFlag(hook.poolState(stockId).gateFlags, HookStateLib.FLAG_REFRESH_FAILED), "flagged");
        assertEq(hook.poolState(stockId).uiMultiplierX18, 1e18, "the cached value stands");

        // And a swap still goes through.
        assertGt(_buy(stockKey, 1e18), 0, "swaps are unaffected");
    }

    /// @notice A token that answers with something too short to decode. `try`/`catch` cannot survive this; the
    ///         hook's manual decode can.
    function test_aGarbageMultiplierIsAFlagAndNotARevert() public {
        vm.mockCall(address(stock), abi.encodeWithSelector(IStockToken.uiMultiplier.selector), hex"01");
        _refreshGate(stockKey);
        assertEq(hook.poolState(stockId).uiMultiplierX18, 1e18, "the cached value stands");
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
