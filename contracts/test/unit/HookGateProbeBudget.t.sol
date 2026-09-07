// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Session} from "../../src/types/Types.sol";
import {OracleGateFixture} from "./OracleGateFixture.sol";

/// @title HookGateProbeBudgetTest
/// @notice What `AmpsHook` has to budget for the bounded reads it makes against `OracleGate`, measured against the
///         **real** gate with the deployment's own calendar tables installed rather than against a mock.
///
/// @dev **Why this file exists.** The hook meters every external read: `snapshotByPool` and `closedHours` under
///      `GATE_PROBE_GAS`, `IAmpsVault.oracleGate()` under `POINTER_PROBE_GAS`. A budget that is too tight does not
///      fail loudly — the read simply returns "could not answer", `gateFlags.refreshFailed` is raised, the cache
///      ages past `Constants.GATE_CACHE_MAX_AGE`, and every pool is pinned on the conservative substitute until
///      something else changes. Worse, the calendar read gets *more* expensive with time: `sessionAt` scans every
///      DST window that started before now, so the cost grows with every year the table covers, and `closedHours`
///      is only reached at all when the session is `CLOSED` — so a budget that runs out does so on weekends and
///      holidays only, which is exactly when nobody is watching.
///
/// @dev These are gas measurements against a *ceiling*, not baseline recordings: they assert head-room, so an
///      optimisation never has to re-record them and a regression that eats the head-room fails the suite.
contract HookGateProbeBudgetTest is OracleGateFixture {
    /// @notice `AmpsHook.GATE_PROBE_GAS`, mirrored here because the hook's constants are private. The assertions
    ///         below demand 2x head-room against this number, so the two can drift a long way before it matters.
    uint256 internal constant HOOK_GATE_PROBE_GAS = 1_000_000;

    /// @notice `AmpsHook.POINTER_PROBE_GAS`, mirrored for the same reason. `closedHours` used to be metered here.
    uint256 internal constant HOOK_POINTER_PROBE_GAS = 60_000;

    /// @notice The last year the bundled DST table covers, and therefore the most expensive year to read in.
    uint16 internal constant YEAR_2032 = 2032;

    /// @notice Sunday 2032-12-26, 12:00 EST (17:00 UTC): the end of a three-day holiday close (Christmas Day
    ///         observed on Friday the 24th, then Saturday and Sunday), after the last DST window in the bundled
    ///         table has closed — so `_utcOffsetAt` scans all eight windows and `closedHours` walks back three
    ///         local days before it finds Thursday the 23rd.
    uint256 internal constant SUNDAY_2032_12_26 = 1_987_693_200;

    /// @notice Monday 2025-03-10, 14:00 UTC: one DST window into the table, for the growth comparison.
    uint256 internal constant MONDAY_2025_03_10 = 1_741_620_000;

    /// @notice Day-of-year of 2032-12-24, Christmas Day observed. 2032 is a leap year.
    uint16 internal constant DOY_2032_12_24 = 359;

    function setUp() public {
        _deployGate();
    }

    /// @notice `closedHours()` on the worst realistic day the shipped calendar can produce — the far end of the
    ///         DST table, a holiday weekend, three days of walk-back — fits `GATE_PROBE_GAS` with room to spare.
    ///
    /// @dev This is the read that used to be metered at `POINTER_PROBE_GAS` = 60,000 on the grounds that it was a
    ///      cheap pointer read. It is not one: it runs `sessionAt` (a scan over every DST window that started
    ///      before now, two cold `SLOAD`s each, plus a holiday-bitmap read) and then walks back up to
    ///      `MAX_CLOSED_LOOKBACK_DAYS` local days, each with another bitmap read and two more offset scans.
    function test_closedHoursOnAHolidayWeekendFitsTheGateProbeBudget() public {
        _installHolidayWeekend2032();
        vm.warp(SUNDAY_2032_12_26);

        assertEq(uint8(gate.sessionAt(block.timestamp)), uint8(Session.CLOSED), "a Sunday is CLOSED");

        uint256 before = gasleft();
        uint16 hoursClosed = gate.closedHours();
        uint256 used = before - gasleft();

        // Thursday 20:00 ET to Sunday 12:00 ET is 64 hours. Asserting it is what proves the walk-back really ran
        // all three days rather than short-circuiting into the one-step weekend path.
        assertEq(hoursClosed, uint16(64), "three days of close, so the expensive path really ran");

        emit log_named_uint("closedHours() gas, 2032 holiday weekend", used);
        assertLe(used * 2, HOOK_GATE_PROBE_GAS, "closedHours must fit GATE_PROBE_GAS with 2x margin");
        assertGt(used, HOOK_POINTER_PROBE_GAS / 6, "sanity: this is nothing like a pointer read");
    }

    /// @notice And the arithmetic worst case: every one of the `MAX_CLOSED_LOOKBACK_DAYS` days closed, so the
    ///         walk-back runs its full length and gives up. No real calendar does this; the budget still covers it.
    function test_closedHoursAtTheFullLookbackFitsTheGateProbeBudget() public {
        // Days 340..361 of 2032 (2032-12-05 through 2032-12-26) all marked closed, which is more than the
        // sixteen-day lookback, so the loop exhausts its steps and still finds no trading day behind it.
        uint16[] memory closed = new uint16[](22);
        for (uint256 i; i < closed.length; ++i) {
            closed[i] = uint16(340 + i);
        }
        vm.prank(TIMELOCK);
        gate.setHolidayBitmap(YEAR_2032, _bitmap(closed));
        vm.warp(SUNDAY_2032_12_26);

        uint256 before = gasleft();
        uint16 hoursClosed = gate.closedHours();
        uint256 used = before - gasleft();

        assertEq(hoursClosed, type(uint16).max, "the walk-back ran out, which is the case being priced");
        emit log_named_uint("closedHours() gas, full 16-day lookback", used);
        assertLe(used * 2, HOOK_GATE_PROBE_GAS, "the worst case must fit GATE_PROBE_GAS with 2x margin");
    }

    /// @notice Why the budget cannot be a fixed small number: the calendar scan is linear in the DST windows that
    ///         have already started, so the same call costs more every year the table advances.
    function test_theCalendarScanGrowsWithTheDstTable() public {
        _installHolidayWeekend2032();

        vm.warp(MONDAY_2025_03_10);
        uint256 before = gasleft();
        gate.sessionAt(block.timestamp);
        uint256 early = before - gasleft();

        vm.warp(SUNDAY_2032_12_26);
        before = gasleft();
        gate.sessionAt(block.timestamp);
        uint256 late_ = before - gasleft();

        emit log_named_uint("sessionAt gas, 2025", early);
        emit log_named_uint("sessionAt gas, 2032", late_);
        assertGt(late_, early, "the scan is linear in the windows already started");
        assertLe(late_ * 2, HOOK_GATE_PROBE_GAS, "and still nowhere near the snapshot budget");
    }

    /// @dev Installs the 2032 NYSE bitmap this file needs: Christmas Day observed on Friday 2032-12-24, which with
    ///      the weekend behind it makes Sunday the 26th the end of a three-day close.
    function _installHolidayWeekend2032() private {
        uint16[] memory holidays = new uint16[](1);
        holidays[0] = DOY_2032_12_24;
        vm.prank(TIMELOCK);
        gate.setHolidayBitmap(YEAR_2032, _bitmap(holidays));
    }
}
