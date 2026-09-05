// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Session} from "../types/Types.sol";

/// @title StreamsSchemaLib
/// @notice Pure translation of a Chainlink Data Streams report's `marketStatus` field into the protocol's
///         {Session}, plus the restrict-only combinator that a future `StreamsRelay` must apply.
///
/// @dev **Groundwork only.** Nothing wires this yet. Layer B of the oracle design is the deterministic on-chain
///      24/5 ET calendar in `OracleGate`, and it is the *floor*: it is always available, costs no subscription and
///      cannot be withheld. Data Streams carry `marketStatus` (the field the Data Feeds do not), but they are a
///      paid, pull-based product whose reports arrive in a caller-supplied transaction. A v2 `StreamsRelay` will
///      verify a report through Chainlink's `VerifierProxy`, decode `marketStatus`, and hand the result to the
///      gate — which is exactly the boundary this library sits on.
///
/// @dev **Restrict-only semantics, and why they are not negotiable.** A stream is supplied by whoever pays for it
///      and lands in a transaction anybody can craft. If a stream could *open* a session the calendar says is
///      closed, then buying one report would re-enable placements, drop the bond haircut from 300 bp to 0 and
///      narrow the hook's inner band — an attacker-chosen state transition. {restrict} therefore returns the
///      **more closed** of the two sessions and never the more open one. `Session` is declared monotone
///      non-decreasing in closedness (`REGULAR < PRE_POST < OVERNIGHT < CLOSED`, invariant I19), so "more
///      restrictive" is simply the larger ordinal and the combinator is a `max`.
///
/// @dev **Schema versions.** Chainlink's stream report schemas differ in how they express market state, and a
///      relay must branch on the schema of the specific stream it verified rather than assume one encoding:
///
///      | Schema | `marketStatus` values |
///      |---|---|
///      | v8, v10 (RWA / NAV streams) | `0` Unknown, `1` Closed, `2` Open |
///      | v11 (24/5 equities)         | `0` Unknown, `1` Pre, `2` Regular, `3` Post, `4` Overnight, `5` Closed |
///
///      A v8/v10 "Open" carries no session detail, so it maps to {Session.REGULAR}: the *least* restrictive open
///      session. Combined with {restrict} that is safe — a v8 stream can never widen the calendar's verdict, it
///      can only confirm it or close the market outright.
///
/// @dev **Unknown is not a session.** `marketStatus == 0` means the report does not assert a market state. It is
///      returned as `known == false` by {tryToSession} and rejected by {toSession}; a relay must treat it as "no
///      information" and leave the calendar's verdict untouched, never as "closed" and never as "open".
library StreamsSchemaLib {
    /// @notice Report schema v8: RWA streams that carry a binary `marketStatus`.
    uint8 internal constant SCHEMA_V8 = 8;

    /// @notice Report schema v10: NAV/RWA streams, same binary `marketStatus` encoding as v8.
    uint8 internal constant SCHEMA_V10 = 10;

    /// @notice Report schema v11: the 24/5 equity streams with a six-valued `marketStatus`.
    uint8 internal constant SCHEMA_V11 = 11;

    /// @notice v8/v10 `marketStatus`: the report asserts nothing about the market.
    uint32 internal constant STATUS_BINARY_UNKNOWN = 0;

    /// @notice v8/v10 `marketStatus`: the market is closed.
    uint32 internal constant STATUS_BINARY_CLOSED = 1;

    /// @notice v8/v10 `marketStatus`: the market is open, with no session detail.
    uint32 internal constant STATUS_BINARY_OPEN = 2;

    /// @notice v11 `marketStatus`: the report asserts nothing about the market.
    uint32 internal constant STATUS_V11_UNKNOWN = 0;

    /// @notice v11 `marketStatus`: pre-market session.
    uint32 internal constant STATUS_V11_PRE = 1;

    /// @notice v11 `marketStatus`: regular session.
    uint32 internal constant STATUS_V11_REGULAR = 2;

    /// @notice v11 `marketStatus`: post-market session.
    uint32 internal constant STATUS_V11_POST = 3;

    /// @notice v11 `marketStatus`: overnight session.
    uint32 internal constant STATUS_V11_OVERNIGHT = 4;

    /// @notice v11 `marketStatus`: closed.
    uint32 internal constant STATUS_V11_CLOSED = 5;

    /// @notice The schema version is not one this library knows how to read.
    /// @param schemaVersion The rejected schema.
    error UnsupportedSchema(uint8 schemaVersion);

    /// @notice The `marketStatus` value is not defined for that schema, or is `Unknown`.
    /// @param schemaVersion The schema.
    /// @param marketStatus The rejected value.
    error UnknownMarketStatus(uint8 schemaVersion, uint32 marketStatus);

    /// @notice The schema version encoded in a Data Streams feed id.
    /// @dev Stream ids are `bytes32` whose leading two bytes are the report schema version, e.g. a v11 equity
    ///      stream begins `0x000b`. A relay reads this once per stream rather than trusting a caller-supplied
    ///      version alongside a report.
    /// @param feedId The stream id.
    /// @return schemaVersion The schema version in the leading two bytes.
    function schemaVersionOf(bytes32 feedId) internal pure returns (uint16 schemaVersion) {
        return uint16(uint256(feedId) >> 240);
    }

    /// @notice Translates a report's `marketStatus` into a {Session}, reverting on anything undefined.
    /// @dev Use {tryToSession} on any path that must not revert on a malformed report.
    /// @param schemaVersion The report schema: 8, 10 or 11.
    /// @param marketStatus The report's `marketStatus` field.
    /// @return session The session the report asserts.
    function toSession(uint8 schemaVersion, uint32 marketStatus) internal pure returns (Session session) {
        bool known;
        (known, session) = tryToSession(schemaVersion, marketStatus);
        if (!known) revert UnknownMarketStatus(schemaVersion, marketStatus);
    }

    /// @notice Translates a report's `marketStatus` into a {Session} without reverting on `Unknown`.
    /// @dev Reverts only for a schema this library does not know, which is a configuration error rather than a
    ///      report contents error: a relay must not silently accept a stream it cannot parse.
    /// @param schemaVersion The report schema: 8, 10 or 11.
    /// @param marketStatus The report's `marketStatus` field.
    /// @return known False when the report asserts nothing (`marketStatus == 0`) or the value is out of range for
    ///         the schema; `session` is then meaningless and the caller must keep its own verdict.
    /// @return session The session the report asserts, when `known`.
    function tryToSession(uint8 schemaVersion, uint32 marketStatus)
        internal
        pure
        returns (bool known, Session session)
    {
        if (schemaVersion == SCHEMA_V8 || schemaVersion == SCHEMA_V10) {
            if (marketStatus == STATUS_BINARY_CLOSED) return (true, Session.CLOSED);
            // "Open" with no session detail: the least restrictive open session. Safe only because every consumer
            // combines it through {restrict}, which can never widen the calendar's verdict.
            if (marketStatus == STATUS_BINARY_OPEN) return (true, Session.REGULAR);
            return (false, Session.CLOSED);
        }
        if (schemaVersion == SCHEMA_V11) {
            if (marketStatus == STATUS_V11_PRE || marketStatus == STATUS_V11_POST) return (true, Session.PRE_POST);
            if (marketStatus == STATUS_V11_REGULAR) return (true, Session.REGULAR);
            if (marketStatus == STATUS_V11_OVERNIGHT) return (true, Session.OVERNIGHT);
            if (marketStatus == STATUS_V11_CLOSED) return (true, Session.CLOSED);
            return (false, Session.CLOSED);
        }
        revert UnsupportedSchema(schemaVersion);
    }

    /// @notice Combines the calendar's verdict with a stream's verdict, restrict-only.
    /// @dev Returns the more closed of the two. A stream can confirm the calendar or close the market early (a
    ///      half day, an unscheduled halt), and can never open a session the calendar says is closed.
    /// @param calendarSession The deterministic on-chain calendar's verdict, i.e. the floor.
    /// @param streamSession The session a verified report asserts.
    /// @return session The effective session.
    function restrict(Session calendarSession, Session streamSession) internal pure returns (Session session) {
        return uint8(streamSession) > uint8(calendarSession) ? streamSession : calendarSession;
    }

    /// @notice Applies a report to the calendar's verdict in one step, ignoring reports that assert nothing.
    /// @dev The exact shape a `StreamsRelay` needs: an unparseable or `Unknown` report leaves `calendarSession`
    ///      untouched rather than defaulting either way.
    /// @param calendarSession The deterministic on-chain calendar's verdict.
    /// @param schemaVersion The report schema: 8, 10 or 11.
    /// @param marketStatus The report's `marketStatus` field.
    /// @return session The effective session after the restrict-only combination.
    /// @return applied Whether the report asserted anything at all.
    function restrictWithReport(Session calendarSession, uint8 schemaVersion, uint32 marketStatus)
        internal
        pure
        returns (Session session, bool applied)
    {
        (bool known, Session streamSession) = tryToSession(schemaVersion, marketStatus);
        if (!known) return (calendarSession, false);
        return (restrict(calendarSession, streamSession), true);
    }
}
