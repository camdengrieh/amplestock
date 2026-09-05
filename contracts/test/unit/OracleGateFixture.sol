// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeedRegistry} from "../../src/oracle/FeedRegistry.sol";
import {OracleGate} from "../../src/oracle/OracleGate.sol";
import {FeedConfig} from "../../src/types/Types.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockMarketReference} from "../mocks/MockMarketReference.sol";
import {MockPoolRegistry} from "../mocks/MockPoolRegistry.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Shared deployment and calendar fixture for every `OracleGate` / `FeedRegistry` suite.
/// @dev Holds no tests. The calendar tables it installs are the real ones: US DST transitions 2025-2032 (second
///      Sunday in March at 07:00 UTC, first Sunday in November at 06:00 UTC) and the 2026 NYSE holiday calendar,
///      both computed off-chain and pinned here as literals so the contract's own date arithmetic is checked
///      against an independent source rather than against itself.
abstract contract OracleGateFixture is Test {
    /// @notice The governance timelock used by every fixture.
    address internal constant TIMELOCK = address(0xB0B0);

    /// @notice The guardian Safe used by every fixture.
    address internal constant GUARDIAN = address(0x6A6A);

    /// @notice Somebody with no role at all.
    address internal constant STRANGER = address(0xDEAD);

    /// @notice The 2026 launch year the holiday bitmap is installed for.
    uint16 internal constant YEAR_2026 = 2026;

    OracleGate internal gate;
    FeedRegistry internal feeds;
    MockPoolRegistry internal registry;
    MockMarketReference internal marketRef;

    /* --------------------------------------------------------------------------------------------------------- */
    /*                                          calendar installation                                             */
    /* --------------------------------------------------------------------------------------------------------- */

    /// @dev US DST window starts, UTC: the second Sunday in March at 02:00 EST == 07:00 UTC, 2025 through 2032.
    function _dstStarts() internal pure returns (uint32[] memory starts) {
        starts = new uint32[](8);
        starts[0] = 1_741_503_600; // 2025-03-09
        starts[1] = 1_772_953_200; // 2026-03-08
        starts[2] = 1_805_007_600; // 2027-03-14
        starts[3] = 1_836_457_200; // 2028-03-12
        starts[4] = 1_867_906_800; // 2029-03-11
        starts[5] = 1_899_356_400; // 2030-03-10
        starts[6] = 1_930_806_000; // 2031-03-09
        starts[7] = 1_962_860_400; // 2032-03-14
    }

    /// @dev US DST window ends, UTC: the first Sunday in November at 02:00 EDT == 06:00 UTC, 2025 through 2032.
    function _dstEnds() internal pure returns (uint32[] memory ends) {
        ends = new uint32[](8);
        ends[0] = 1_762_063_200; // 2025-11-02
        ends[1] = 1_793_512_800; // 2026-11-01
        ends[2] = 1_825_567_200; // 2027-11-07
        ends[3] = 1_857_016_800; // 2028-11-05
        ends[4] = 1_888_466_400; // 2029-11-04
        ends[5] = 1_919_916_000; // 2030-11-03
        ends[6] = 1_951_365_600; // 2031-11-02
        ends[7] = 1_983_420_000; // 2032-11-07
    }

    /// @dev The 2026 NYSE full-day closures, as days of the year: New Year's Day (1), MLK (19), Presidents' Day
    ///      (47), Good Friday (93), Memorial Day (145), Juneteenth (170), Independence Day observed (184), Labor
    ///      Day (250), Thanksgiving (330), Christmas (359).
    function _holidays2026() internal pure returns (uint16[] memory daysOfYear) {
        daysOfYear = new uint16[](10);
        daysOfYear[0] = 1;
        daysOfYear[1] = 19;
        daysOfYear[2] = 47;
        daysOfYear[3] = 93;
        daysOfYear[4] = 145;
        daysOfYear[5] = 170;
        daysOfYear[6] = 184;
        daysOfYear[7] = 250;
        daysOfYear[8] = 330;
        daysOfYear[9] = 359;
    }

    /// @dev Packs 1-based days of the year into the gate's two-word bitmap.
    function _bitmap(uint16[] memory daysOfYear) internal pure returns (uint256[2] memory bitmap) {
        for (uint256 i = 0; i < daysOfYear.length; ++i) {
            uint256 index = uint256(daysOfYear[i]) - 1;
            bitmap[index >> 8] |= uint256(1) << (index & 255);
        }
    }

    /// @dev Installs the DST table and the 2026 holiday bitmap through the timelock.
    function _installCalendar() internal {
        vm.startPrank(TIMELOCK);
        gate.setDstTable(_dstStarts(), _dstEnds());
        gate.setHolidayBitmap(YEAR_2026, _bitmap(_holidays2026()));
        vm.stopPrank();
    }

    /* --------------------------------------------------------------------------------------------------------- */
    /*                                             deployment                                                     */
    /* --------------------------------------------------------------------------------------------------------- */

    /// @dev Deploys the registry, the market reference, `FeedRegistry` and `OracleGate`, wires them both ways and
    ///      installs the calendar. Callers still have to register pools and feeds.
    function _deployGate() internal {
        registry = new MockPoolRegistry();
        marketRef = new MockMarketReference();
        feeds = new FeedRegistry(TIMELOCK, address(0));
        gate = new OracleGate(TIMELOCK, GUARDIAN, address(feeds), address(registry), address(marketRef));
        vm.prank(TIMELOCK);
        feeds.setOracleGate(address(gate));
        _installCalendar();
    }

    /// @dev Deploys an aggregator, allowlists it as a Standard proxy and configures it for `token`.
    /// @param token The asset the feed prices.
    /// @param answerUsd8 The initial answer, 8 decimals.
    /// @param heartbeat The RDD heartbeat in seconds.
    /// @return aggregator The deployed feed.
    function _installFeed(address token, int256 answerUsd8, uint32 heartbeat)
        internal
        returns (MockAggregator aggregator)
    {
        aggregator = new MockAggregator("mock/usd", 8, answerUsd8);
        vm.startPrank(TIMELOCK);
        feeds.setStandardProxy(address(aggregator), true);
        feeds.setFeed(
            token,
            address(aggregator),
            FeedConfig({
                aggregator: address(0),
                decimals: 0,
                set: false,
                heartbeat: heartbeat,
                thresholdBps: 50,
                minAnswerUsd8: 1,
                maxAnswerUsd8: type(uint128).max
            })
        );
        vm.stopPrank();
    }

    /// @dev A deterministic pool id for a label, so tests read as prose.
    /// @param label The label.
    /// @return poolId The id.
    function _poolId(string memory label) internal pure returns (PoolId poolId) {
        return PoolId.wrap(keccak256(bytes(label)));
    }

    /// @dev Deploys a Stock Token owned by this test contract.
    /// @param symbol The token symbol.
    /// @return token The token.
    function _stockToken(string memory symbol) internal returns (MockStockToken token) {
        token = new MockStockToken(symbol, symbol);
    }
}
