// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {OracleGate} from "../../src/oracle/OracleGate.sol";
import {LengthMismatch, NotTimelock, OutOfBand} from "../../src/types/Errors.sol";
import {Session} from "../../src/types/Types.sol";
import {OracleGateFixture} from "./OracleGateFixture.sol";

/// @notice Layer B: the deterministic on-chain 24/5 ET calendar.
/// @dev Every timestamp below is a UTC Unix second computed off-chain from the IANA `America/New_York` rules and
///      pinned here with the ET wall-clock time it denotes, so `sessionAt` is checked against an independent
///      source rather than against its own arithmetic. The DST table and the 2026 NYSE holiday bitmap come from
///      {OracleGateFixture}.
contract CalendarTest is OracleGateFixture {
    // ---- 2026-03-06, a Friday on standard time (EST, UTC-5) -----------------------------------------------------
    uint256 internal constant FRI_1000_ET = 1_772_809_200; // 10:00 ET, regular session
    uint256 internal constant FRI_1959_ET = 1_772_845_140; // 19:59 ET, last second of post-market
    uint256 internal constant FRI_2000_ET = 1_772_845_200; // 20:00 ET, the weekly close
    uint256 internal constant FRI_2100_ET = 1_772_848_800; // 21:00 ET, one hour into the close
    uint256 internal constant SAT_1200_ET = 1_772_902_800; // 2026-03-07 12:00 ET

    // ---- 2026-03-08, the spring-forward Sunday, and the Monday after --------------------------------------------
    uint256 internal constant DST_START_BEFORE = 1_772_953_199; // 01:59:59 EST
    uint256 internal constant DST_START_AT = 1_772_953_200; // 03:00:00 EDT
    uint256 internal constant SUN_1900_ET = 1_773_010_800; // 19:00 EDT, still closed
    uint256 internal constant SUN_1959_ET = 1_773_014_340; // 19:59 EDT, last second closed
    uint256 internal constant SUN_2000_ET = 1_773_014_400; // 20:00 EDT, the weekly reopen
    uint256 internal constant MON_0359_ET = 1_773_043_140; // 03:59 EDT, last second overnight
    uint256 internal constant MON_0400_ET = 1_773_043_200; // 04:00 EDT, pre-market opens
    uint256 internal constant MON_0929_ET = 1_773_062_940; // 09:29 EDT
    uint256 internal constant MON_0930_ET = 1_773_063_000; // 09:30 EDT, regular opens
    uint256 internal constant MON_1559_ET = 1_773_086_340; // 15:59 EDT
    uint256 internal constant MON_1600_ET = 1_773_086_400; // 16:00 EDT, post-market opens

    // ---- 2026-11-01, the fall-back Sunday, and the Monday after -------------------------------------------------
    uint256 internal constant DST_END_BEFORE = 1_793_512_799; // 01:59:59 EDT
    uint256 internal constant DST_END_AT = 1_793_512_800; // 01:00:00 EST
    uint256 internal constant MON_NOV_1330_UTC = 1_793_626_200; // 08:30 EST (would be 09:30 on EDT)

    // ---- Christmas 2026, a Friday holiday -----------------------------------------------------------------------
    uint256 internal constant WED_DEC23_2000_ET = 1_798_074_000; // eve of an ordinary Thursday
    uint256 internal constant THU_DEC24_2000_ET = 1_798_160_400; // eve of the holiday
    uint256 internal constant FRI_DEC25_0200_ET = 1_798_182_000; // overnight into the holiday
    uint256 internal constant FRI_DEC25_1000_ET = 1_798_210_800; // regular hours on the holiday
    uint256 internal constant FRI_DEC25_1200_ET = 1_798_218_000;
    uint256 internal constant SAT_DEC26_1200_ET = 1_798_304_400;
    uint256 internal constant SUN_DEC27_2000_ET = 1_798_419_600; // the reopen after the holiday weekend
    uint256 internal constant MON_DEC28_0930_ET = 1_798_468_200;

    // ---- Other calendar corners ---------------------------------------------------------------------------------
    uint256 internal constant FRI_JUL03_1000_ET = 1_783_087_200; // Independence Day observed, day 184
    uint256 internal constant THU_JAN01_1200_ET = 1_767_286_800; // day 1 of the bitmap
    uint256 internal constant FRI_JAN02_1200_ET = 1_767_373_200; // day 2, an ordinary trading day
    uint256 internal constant WED_DEC30_1200_ET = 1_798_650_000; // day 364, past the first bitmap word
    uint256 internal constant TUE_FEB29_2028_ET = 1_835_456_400; // leap day, day 60 of 2028
    uint256 internal constant WED_MAR01_2028_ET = 1_835_542_800; // day 61 of 2028, only in a leap year
    uint256 internal constant FRI_DEC31_2027_ET = 1_830_272_400; // day 365 of a common year

    function setUp() public {
        _deployGate();
    }

    // -------------------------------------------------------------------------------------------------------------
    // The four sessions, boundary by boundary
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Every session boundary of one ordinary trading day, at the second.
    function test_sessionAt_tradingDayBoundaries() public view {
        assertEq(uint8(gate.sessionAt(MON_0359_ET)), uint8(Session.OVERNIGHT), "03:59 overnight");
        assertEq(uint8(gate.sessionAt(MON_0400_ET)), uint8(Session.PRE_POST), "04:00 pre");
        assertEq(uint8(gate.sessionAt(MON_0929_ET)), uint8(Session.PRE_POST), "09:29 pre");
        assertEq(uint8(gate.sessionAt(MON_0930_ET)), uint8(Session.REGULAR), "09:30 regular");
        assertEq(uint8(gate.sessionAt(MON_1559_ET)), uint8(Session.REGULAR), "15:59 regular");
        assertEq(uint8(gate.sessionAt(MON_1600_ET)), uint8(Session.PRE_POST), "16:00 post");
        assertEq(uint8(gate.sessionAt(FRI_1000_ET)), uint8(Session.REGULAR), "Friday 10:00 regular");
    }

    /// @notice Friday 20:00 ET is the weekly close: the overnight session that would start there has no trading
    ///         day to end on.
    function test_sessionAt_fridayTwentyHundredCloses() public view {
        assertEq(uint8(gate.sessionAt(FRI_1959_ET)), uint8(Session.PRE_POST), "19:59 still post");
        assertEq(uint8(gate.sessionAt(FRI_2000_ET)), uint8(Session.CLOSED), "20:00 closed");
        assertEq(uint8(gate.sessionAt(SAT_1200_ET)), uint8(Session.CLOSED), "Saturday closed");
    }

    /// @notice Sunday 20:00 ET is the weekly reopen, into Monday's overnight session.
    function test_sessionAt_sundayTwentyHundredReopens() public view {
        assertEq(uint8(gate.sessionAt(SUN_1959_ET)), uint8(Session.CLOSED), "19:59 still closed");
        assertEq(uint8(gate.sessionAt(SUN_2000_ET)), uint8(Session.OVERNIGHT), "20:00 overnight");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Daylight saving
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The 2026 spring-forward instant flips the offset from UTC-5 to UTC-4, and the Monday session that
    ///         depends on it moves with it: 13:30 UTC is 09:30 EDT (regular) and would be 08:30 EST (pre-market).
    function test_dstStart_2026_03_08() public view {
        assertEq(gate.utcOffsetAt(DST_START_BEFORE), 5 * 3600, "EST before the transition");
        assertEq(gate.utcOffsetAt(DST_START_AT), 4 * 3600, "EDT from the transition");
        assertEq(uint8(gate.sessionAt(MON_0930_ET)), uint8(Session.REGULAR), "09:30 EDT is regular");
    }

    /// @notice The 2026 fall-back instant flips the offset back, and the same 13:30 UTC on the Monday after is
    ///         08:30 EST, i.e. pre-market.
    function test_dstEnd_2026_11_01() public view {
        assertEq(gate.utcOffsetAt(DST_END_BEFORE), 4 * 3600, "EDT before the transition");
        assertEq(gate.utcOffsetAt(DST_END_AT), 5 * 3600, "EST from the transition");
        assertEq(uint8(gate.sessionAt(MON_NOV_1330_UTC)), uint8(Session.PRE_POST), "08:30 EST is pre-market");
    }

    /// @notice With no DST table installed the calendar is standard time all year, which is the correct
    ///         degradation: it never invents an offset it was not given.
    function test_dst_emptyTableIsStandardTime() public {
        OracleGate bare = new OracleGate(TIMELOCK, GUARDIAN, address(0), address(0), address(0));
        assertEq(bare.utcOffsetAt(DST_START_AT), 5 * 3600, "no table, no daylight time");
        // 13:30 UTC on the Monday after the (uninstalled) transition is 08:30 EST, so pre-market rather than
        // regular: the same instant that {test_dstStart_2026_03_08} sees as 09:30.
        assertEq(uint8(bare.sessionAt(MON_0930_ET)), uint8(Session.PRE_POST), "EST all year");
    }

    /// @notice A timestamp before the ET epoch cannot be classified and is reported closed rather than reverting.
    function test_sessionAt_beforeEpochIsClosed() public view {
        assertEq(uint8(gate.sessionAt(0)), uint8(Session.CLOSED), "timestamp 0");
        assertEq(uint8(gate.sessionAt(3600)), uint8(Session.CLOSED), "timestamp inside the offset");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Holidays
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A holiday closes its whole local day, the overnight session that would have ended on it, and the
    ///         overnight session that would have started at 20:00 the evening before.
    function test_holiday_christmas2026() public view {
        assertEq(uint8(gate.sessionAt(WED_DEC23_2000_ET)), uint8(Session.OVERNIGHT), "Wed 20:00 into Thursday");
        assertEq(uint8(gate.sessionAt(THU_DEC24_2000_ET)), uint8(Session.CLOSED), "Thu 20:00 into the holiday");
        assertEq(uint8(gate.sessionAt(FRI_DEC25_0200_ET)), uint8(Session.CLOSED), "holiday overnight");
        assertEq(uint8(gate.sessionAt(FRI_DEC25_1000_ET)), uint8(Session.CLOSED), "holiday regular hours");
        assertEq(uint8(gate.sessionAt(SUN_DEC27_2000_ET)), uint8(Session.OVERNIGHT), "Sunday reopen");
        assertEq(uint8(gate.sessionAt(MON_DEC28_0930_ET)), uint8(Session.REGULAR), "Monday regular");
        assertTrue(gate.isHoliday(FRI_DEC25_1000_ET), "isHoliday");
        assertFalse(gate.isHoliday(MON_DEC28_0930_ET), "not a holiday");
    }

    /// @notice Independence Day observed on Friday 2026-07-03 and New Year's Day, the first bit of the bitmap.
    function test_holiday_otherClosures() public view {
        assertEq(uint8(gate.sessionAt(FRI_JUL03_1000_ET)), uint8(Session.CLOSED), "July 3 observed");
        assertEq(uint8(gate.sessionAt(THU_JAN01_1200_ET)), uint8(Session.CLOSED), "New Year's Day, bit 0");
        assertEq(uint8(gate.sessionAt(FRI_JAN02_1200_ET)), uint8(Session.REGULAR), "January 2 trades");
    }

    /// @notice A day of the year above 256 lands in the bitmap's second word.
    function test_holiday_secondBitmapWord() public {
        assertEq(uint8(gate.sessionAt(WED_DEC30_1200_ET)), uint8(Session.REGULAR), "day 364 trades by default");
        uint16[] memory closures = new uint16[](1);
        closures[0] = 364;
        vm.prank(TIMELOCK);
        gate.setHolidayBitmap(YEAR_2026, _bitmap(closures));
        assertEq(uint8(gate.sessionAt(WED_DEC30_1200_ET)), uint8(Session.CLOSED), "day 364 closed");
        assertEq(uint8(gate.sessionAt(FRI_DEC25_1000_ET)), uint8(Session.REGULAR), "old bitmap replaced wholesale");
    }

    /// @notice Day-of-year indexing survives a leap year: 2028-03-01 is day 61, not day 60, and the leap day
    ///         itself is day 60.
    function test_holiday_leapYearDayOfYear() public {
        uint16[] memory closures = new uint16[](1);
        closures[0] = 61;
        vm.prank(TIMELOCK);
        gate.setHolidayBitmap(2028, _bitmap(closures));
        assertEq(uint8(gate.sessionAt(WED_MAR01_2028_ET)), uint8(Session.CLOSED), "2028-03-01 is day 61");
        assertEq(uint8(gate.sessionAt(TUE_FEB29_2028_ET)), uint8(Session.REGULAR), "the leap day is day 60");
    }

    /// @notice Day 365 of a common year is 31 December, and the bitmap is keyed by the calendar year the day
    ///         belongs to rather than by anything the transition arithmetic invents.
    function test_holiday_lastDayOfCommonYear() public {
        uint16[] memory closures = new uint16[](1);
        closures[0] = 365;
        vm.prank(TIMELOCK);
        gate.setHolidayBitmap(2027, _bitmap(closures));
        assertEq(uint8(gate.sessionAt(FRI_DEC31_2027_ET)), uint8(Session.CLOSED), "2027-12-31 is day 365");
    }

    // -------------------------------------------------------------------------------------------------------------
    // closedHours
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Zero while the market is open, whatever the session.
    function test_closedHours_zeroWhileOpen() public {
        vm.warp(MON_0930_ET);
        assertEq(gate.closedHours(), 0, "regular");
        vm.warp(SUN_2000_ET);
        assertEq(gate.closedHours(), 0, "overnight");
        vm.warp(MON_1600_ET);
        assertEq(gate.closedHours(), 0, "post");
    }

    /// @notice The stretch that starts at Friday's 20:00 close, measured across the spring-forward transition: the
    ///         weekend is 46 hours long at Sunday 19:00 EDT, not 47, because an hour of it did not happen.
    function test_closedHours_weekendAcrossDst() public {
        vm.warp(FRI_2100_ET);
        assertEq(gate.closedHours(), 1, "one hour past the close");
        vm.warp(SAT_1200_ET);
        assertEq(gate.closedHours(), 16, "Saturday noon");
        vm.warp(SUN_1900_ET);
        assertEq(gate.closedHours(), 46, "Sunday 19:00 EDT, an hour shorter than a plain weekend");
    }

    /// @notice A holiday extends the previous evening's close rather than starting a new stretch.
    function test_closedHours_holidayWeekend() public {
        vm.warp(FRI_DEC25_1200_ET);
        assertEq(gate.closedHours(), 16, "since Thursday 20:00");
        vm.warp(SAT_DEC26_1200_ET);
        assertEq(gate.closedHours(), 40, "still the same stretch");
    }

    /// @notice A closure longer than the lookback reports the ceiling instead of walking for ever.
    function test_closedHours_lookbackCeiling() public {
        uint16[] memory everyDay = new uint16[](366);
        for (uint16 i = 0; i < 366; ++i) {
            everyDay[i] = i + 1;
        }
        vm.prank(TIMELOCK);
        gate.setHolidayBitmap(YEAR_2026, _bitmap(everyDay));
        vm.warp(FRI_DEC25_1200_ET);
        assertEq(gate.closedHours(), type(uint16).max, "ceiling");
        assertEq(uint8(gate.sessionAt(FRI_DEC25_1200_ET)), uint8(Session.CLOSED), "and still closed");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Governance of the tables
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Only the timelock may replace the holiday bitmap or the DST table.
    function test_governance_onlyTimelock() public {
        uint256[2] memory bitmap;
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, STRANGER));
        gate.setHolidayBitmap(YEAR_2026, bitmap);

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(NotTimelock.selector, GUARDIAN));
        gate.setDstTable(new uint32[](0), new uint32[](0));
    }

    /// @notice The DST table must be parallel, ordered, non-empty-windowed and bounded.
    function test_setDstTable_rejectsMalformedTables() public {
        vm.startPrank(TIMELOCK);

        vm.expectRevert(LengthMismatch.selector);
        gate.setDstTable(new uint32[](2), new uint32[](1));

        uint32[] memory starts = new uint32[](1);
        uint32[] memory ends = new uint32[](1);
        starts[0] = 100;
        ends[0] = 100;
        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("dstWindow"), uint256(100), 0, uint256(100)));
        gate.setDstTable(starts, ends);

        uint32[] memory s2 = new uint32[](2);
        uint32[] memory e2 = new uint32[](2);
        s2[0] = 100;
        e2[0] = 200;
        s2[1] = 150; // overlaps the first window
        e2[1] = 300;
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("dstWindow"), uint256(150), uint256(201), uint256(type(uint32).max)
            )
        );
        gate.setDstTable(s2, e2);

        uint256 tooMany = gate.DST_TABLE_MAX() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("dstTableLength"), tooMany, 0, gate.DST_TABLE_MAX())
        );
        gate.setDstTable(new uint32[](tooMany), new uint32[](tooMany));

        vm.stopPrank();
    }

    /// @notice The installed tables read back exactly as written.
    function test_dstTable_readsBack() public view {
        (uint32[] memory starts, uint32[] memory ends) = gate.dstTable();
        assertEq(starts.length, 8, "eight windows");
        assertEq(ends.length, 8, "parallel");
        assertEq(starts[1], 1_772_953_200, "2026 start");
        assertEq(ends[1], 1_793_512_800, "2026 end");
        uint256[2] memory bitmap = gate.holidayBitmap(YEAR_2026);
        assertEq(bitmap[0] & 1, 1, "New Year's Day bit");
        assertEq((bitmap[1] >> (358 - 256)) & 1, 1, "Christmas bit in the second word");
    }

    /// @notice The calendar is defined far outside the years the bitmap can address: a year past `uint16` simply
    ///         has no holiday table, and is classified on weekday and clock alone.
    function test_calendar_beyondTheBitmapRange() public view {
        // 3e12 seconds after the epoch is roughly the year 96,000, well past `type(uint16).max`.
        uint8 session = uint8(gate.sessionAt(3e12));
        assertLe(session, uint8(Session.CLOSED), "still a valid session");
        assertFalse(gate.isHoliday(3e12), "no bitmap that far out");
    }

    /// @notice The two reads that have to cope with a timestamp inside the UTC offset itself.
    function test_calendar_insideTheOffset() public {
        assertFalse(gate.isHoliday(100), "cannot be classified, so not a holiday");
        vm.warp(100);
        assertEq(gate.closedHours(), type(uint16).max, "and closed for an unbounded stretch");
    }

    /// @notice At the exact instant of the close the stretch is zero whole hours long.
    function test_closedHours_atTheCloseItself() public {
        vm.warp(FRI_2000_ET);
        assertEq(uint8(gate.sessionAt(FRI_2000_ET)), uint8(Session.CLOSED), "closed");
        assertEq(gate.closedHours(), 0, "and no whole hour has passed");
    }

    /// @notice `sessionAt` is total: it classifies any timestamp without reverting, whatever the tables say.
    /// @param timestamp An arbitrary instant.
    function testFuzz_sessionAt_isTotal(uint40 timestamp) public view {
        uint8 session = uint8(gate.sessionAt(timestamp));
        assertLe(session, uint8(Session.CLOSED), "a valid session ordinal");
    }

    /// @notice A holiday bitmap can only ever close a day, never open one: setting more bits is monotone in
    ///         closedness, which is what invariant I19 needs of layer B.
    /// @param dayOfYear A day to close.
    /// @param timestamp An instant to classify.
    function testFuzz_holidayBitmapOnlyCloses(uint16 dayOfYear, uint40 timestamp) public {
        dayOfYear = uint16(bound(dayOfYear, 1, 366));
        Session before = gate.sessionAt(timestamp);

        uint16[] memory base = _holidays2026();
        uint16[] memory extended = new uint16[](base.length + 1);
        for (uint256 i = 0; i < base.length; ++i) {
            extended[i] = base[i];
        }
        extended[base.length] = dayOfYear;
        vm.prank(TIMELOCK);
        gate.setHolidayBitmap(YEAR_2026, _bitmap(extended));

        assertGe(uint8(gate.sessionAt(timestamp)), uint8(before), "closing a day never opens the market");
    }
}
