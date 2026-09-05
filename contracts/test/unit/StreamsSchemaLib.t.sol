// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StreamsSchemaLib} from "../../src/oracle/StreamsSchemaLib.sol";
import {Session} from "../../src/types/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @notice External surface for `StreamsSchemaLib`, so the reverting branches can be asserted with
///         `vm.expectRevert` and every path is charged to a real call frame.
contract StreamsSchemaHarness {
    /// @notice {StreamsSchemaLib.schemaVersionOf}.
    /// @param feedId The stream id.
    /// @return schemaVersion The schema version.
    function schemaVersionOf(bytes32 feedId) external pure returns (uint16 schemaVersion) {
        return StreamsSchemaLib.schemaVersionOf(feedId);
    }

    /// @notice {StreamsSchemaLib.toSession}.
    /// @param schemaVersion The report schema.
    /// @param marketStatus The report's `marketStatus`.
    /// @return session The session.
    function toSession(uint8 schemaVersion, uint32 marketStatus) external pure returns (Session session) {
        return StreamsSchemaLib.toSession(schemaVersion, marketStatus);
    }

    /// @notice {StreamsSchemaLib.tryToSession}.
    /// @param schemaVersion The report schema.
    /// @param marketStatus The report's `marketStatus`.
    /// @return known Whether the report asserted anything.
    /// @return session The session.
    function tryToSession(uint8 schemaVersion, uint32 marketStatus)
        external
        pure
        returns (bool known, Session session)
    {
        return StreamsSchemaLib.tryToSession(schemaVersion, marketStatus);
    }

    /// @notice {StreamsSchemaLib.restrict}.
    /// @param calendarSession The calendar's verdict.
    /// @param streamSession The stream's verdict.
    /// @return session The effective session.
    function restrict(Session calendarSession, Session streamSession) external pure returns (Session session) {
        return StreamsSchemaLib.restrict(calendarSession, streamSession);
    }

    /// @notice {StreamsSchemaLib.restrictWithReport}.
    /// @param calendarSession The calendar's verdict.
    /// @param schemaVersion The report schema.
    /// @param marketStatus The report's `marketStatus`.
    /// @return session The effective session.
    /// @return applied Whether the report asserted anything.
    function restrictWithReport(Session calendarSession, uint8 schemaVersion, uint32 marketStatus)
        external
        pure
        returns (Session session, bool applied)
    {
        return StreamsSchemaLib.restrictWithReport(calendarSession, schemaVersion, marketStatus);
    }
}

/// @notice `StreamsSchemaLib`: the schema mapping and the restrict-only combinator that keeps a purchased report
///         from ever opening a session the calendar says is closed.
contract StreamsSchemaLibTest is Test {
    StreamsSchemaHarness internal lib;

    function setUp() public {
        lib = new StreamsSchemaHarness();
    }

    // -------------------------------------------------------------------------------------------------------------
    // Schema mapping
    // -------------------------------------------------------------------------------------------------------------

    /// @notice v8 and v10 carry a binary status: 1 closed, 2 open with no session detail.
    function test_binarySchemas() public view {
        assertEq(uint8(lib.toSession(8, 1)), uint8(Session.CLOSED), "v8 closed");
        assertEq(uint8(lib.toSession(8, 2)), uint8(Session.REGULAR), "v8 open");
        assertEq(uint8(lib.toSession(10, 1)), uint8(Session.CLOSED), "v10 closed");
        assertEq(uint8(lib.toSession(10, 2)), uint8(Session.REGULAR), "v10 open");
    }

    /// @notice v11 carries the full 24/5 session set, with pre and post both mapping to `PRE_POST`.
    function test_v11Schema() public view {
        assertEq(uint8(lib.toSession(11, 1)), uint8(Session.PRE_POST), "pre");
        assertEq(uint8(lib.toSession(11, 2)), uint8(Session.REGULAR), "regular");
        assertEq(uint8(lib.toSession(11, 3)), uint8(Session.PRE_POST), "post");
        assertEq(uint8(lib.toSession(11, 4)), uint8(Session.OVERNIGHT), "overnight");
        assertEq(uint8(lib.toSession(11, 5)), uint8(Session.CLOSED), "closed");
    }

    /// @notice `marketStatus == 0` asserts nothing, and neither does an out-of-range value.
    function test_unknownStatus() public {
        (bool known,) = lib.tryToSession(11, 0);
        assertFalse(known, "v11 unknown");
        (known,) = lib.tryToSession(8, 0);
        assertFalse(known, "v8 unknown");
        (known,) = lib.tryToSession(11, 6);
        assertFalse(known, "v11 out of range");
        (known,) = lib.tryToSession(8, 3);
        assertFalse(known, "v8 out of range");

        vm.expectRevert(abi.encodeWithSelector(StreamsSchemaLib.UnknownMarketStatus.selector, uint8(11), uint32(0)));
        lib.toSession(11, 0);
    }

    /// @notice A schema the library does not know is a configuration error, and is rejected by both entry points.
    function test_unsupportedSchema() public {
        vm.expectRevert(abi.encodeWithSelector(StreamsSchemaLib.UnsupportedSchema.selector, uint8(3)));
        lib.tryToSession(3, 2);
        vm.expectRevert(abi.encodeWithSelector(StreamsSchemaLib.UnsupportedSchema.selector, uint8(9)));
        lib.toSession(9, 2);
    }

    /// @notice The schema version is the leading two bytes of the stream id.
    function test_schemaVersionOf() public view {
        assertEq(lib.schemaVersionOf(bytes32(uint256(11) << 240)), 11, "v11 id");
        assertEq(lib.schemaVersionOf(bytes32(uint256(8) << 240)), 8, "v8 id");
        assertEq(lib.schemaVersionOf(bytes32(0)), 0, "zero id");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Restrict-only semantics
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A stream may close a session the calendar calls open, and may never open one it calls closed.
    function test_restrict_onlyEverCloses() public view {
        assertEq(
            uint8(lib.restrict(Session.REGULAR, Session.CLOSED)), uint8(Session.CLOSED), "a stream may close early"
        );
        assertEq(
            uint8(lib.restrict(Session.CLOSED, Session.REGULAR)),
            uint8(Session.CLOSED),
            "a stream may never open the weekend"
        );
        assertEq(uint8(lib.restrict(Session.PRE_POST, Session.REGULAR)), uint8(Session.PRE_POST), "no widening");
        assertEq(uint8(lib.restrict(Session.PRE_POST, Session.OVERNIGHT)), uint8(Session.OVERNIGHT), "narrowing");
    }

    /// @notice A v8 "Open" report is the weakest possible assertion and therefore never changes anything.
    function test_restrict_binaryOpenIsInert() public view {
        for (uint8 s = 0; s <= uint8(Session.CLOSED); ++s) {
            (Session effective, bool applied) = lib.restrictWithReport(Session(s), 8, 2);
            assertTrue(applied, "the report did assert something");
            assertEq(uint8(effective), s, "but it can never widen the calendar");
        }
    }

    /// @notice An unknown report leaves the calendar's verdict exactly as it found it.
    function test_restrictWithReport_unknownIsInert() public view {
        (Session effective, bool applied) = lib.restrictWithReport(Session.OVERNIGHT, 11, 0);
        assertFalse(applied, "nothing applied");
        assertEq(uint8(effective), uint8(Session.OVERNIGHT), "unchanged");
    }

    /// @notice A closed report closes whatever the calendar said.
    function test_restrictWithReport_closedAlwaysApplies() public view {
        (Session effective, bool applied) = lib.restrictWithReport(Session.REGULAR, 11, 5);
        assertTrue(applied, "applied");
        assertEq(uint8(effective), uint8(Session.CLOSED), "closed");
    }

    /// @notice The restrict-only property, over every schema and status the library accepts: the effective
    ///         session is never less closed than the calendar's.
    /// @param calendar The calendar's verdict.
    /// @param schemaSeed Picks one of the three known schemas.
    /// @param marketStatus An arbitrary status value.
    function testFuzz_restrictNeverWidens(uint8 calendar, uint8 schemaSeed, uint32 marketStatus) public view {
        Session calendarSession = Session(bound(calendar, 0, uint8(Session.CLOSED)));
        uint8[3] memory schemas = [uint8(8), uint8(10), uint8(11)];
        uint8 schema = schemas[bound(schemaSeed, 0, 2)];
        marketStatus = uint32(bound(marketStatus, 0, 16));

        (Session effective,) = lib.restrictWithReport(calendarSession, schema, marketStatus);
        assertGe(uint8(effective), uint8(calendarSession), "restrict-only");
        assertLe(uint8(effective), uint8(Session.CLOSED), "a valid session");
    }
}
