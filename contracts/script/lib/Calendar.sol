// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Calendar
/// @notice The two published tables `OracleGate` needs and has no getter for: the US daylight-saving windows and
///         the NYSE full-day closures.
///
/// @dev **Why the tables live in a script library.** `OracleGate` stores the DST windows and the holiday bitmap
///      but exposes neither, so a gate redeploy cannot copy them off the old gate — they have to come from
///      somewhere in the deployment. They are published calendar data rather than chain reference data, so they
///      belong with the deployment scripts rather than in `packages/config`, and they are `internal pure` here so
///      that both `03_Core` (which deploys the gate) and `09_Phase3Wire` (which redeploys it) install exactly the
///      same numbers from one source.
///
/// @dev **Only {HOLIDAY_YEAR} ships.** Each later year is its own 48-hour `setHolidayBitmap` proposal. An unknown
///      year is treated by the gate as having no full-day closures, which is a liveness choice — the session
///      resolves to `REGULAR` and bonds price without the closed-session haircut — and not a safety one, because
///      the feed's own staleness still gates everything. Extending the table is a config change, not a code
///      change, and the launch runbook carries it as a recurring December task.
library Calendar {
    /// @notice The year {holidayBitmap} covers.
    uint16 internal constant HOLIDAY_YEAR = 2026;

    /// @notice US DST window starts, UTC: the second Sunday in March at 02:00 EST, 2025 through 2032.
    /// @return starts The timestamps, ascending.
    function dstStarts() internal pure returns (uint32[] memory starts) {
        starts = new uint32[](8);
        starts[0] = 1_741_503_600;
        starts[1] = 1_772_953_200;
        starts[2] = 1_805_007_600;
        starts[3] = 1_836_457_200;
        starts[4] = 1_867_906_800;
        starts[5] = 1_899_356_400;
        starts[6] = 1_930_806_000;
        starts[7] = 1_962_860_400;
    }

    /// @notice US DST window ends, UTC: the first Sunday in November at 02:00 EDT, 2025 through 2032.
    /// @return ends The timestamps, ascending and parallel to {dstStarts}.
    function dstEnds() internal pure returns (uint32[] memory ends) {
        ends = new uint32[](8);
        ends[0] = 1_762_063_200;
        ends[1] = 1_793_512_800;
        ends[2] = 1_825_567_200;
        ends[3] = 1_857_016_800;
        ends[4] = 1_888_466_400;
        ends[5] = 1_919_916_000;
        ends[6] = 1_951_365_600;
        ends[7] = 1_983_420_000;
    }

    /// @notice The {HOLIDAY_YEAR} NYSE full-day closures as days of the year, packed into the gate's two-word
    ///         bitmap: New Year's Day, MLK, Washington's Birthday, Good Friday, Memorial Day, Juneteenth,
    ///         Independence Day (observed), Labor Day, Thanksgiving and Christmas.
    /// @return bitmap The bitmap, day-of-year `d` at bit `d - 1`.
    function holidayBitmap() internal pure returns (uint256[2] memory bitmap) {
        uint16[10] memory daysOfYear = [1, 19, 47, 93, 145, 170, 184, 250, 330, 359];
        for (uint256 i; i < daysOfYear.length; ++i) {
            uint256 index = uint256(daysOfYear[i]) - 1;
            bitmap[index >> 8] |= uint256(1) << (index & 255);
        }
    }
}
