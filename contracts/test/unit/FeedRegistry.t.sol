// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeedRegistry} from "../../src/interfaces/IFeedRegistry.sol";
import {FeedRegistry} from "../../src/oracle/FeedRegistry.sol";
import {Constants} from "../../src/types/Constants.sol";
import {LengthMismatch, NotTimelock, OutOfBand, ZeroAddress} from "../../src/types/Errors.sol";
import {FeedConfig, FeedStatus, Session} from "../../src/types/Types.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {OracleGateFixture} from "./OracleGateFixture.sol";

/// @dev A "feed" that answers `latestRoundData()` by burning every wei of gas it is given. The bounded probe must
///      report it dead rather than take the whole transaction down with it.
contract GasBurningAggregator {
    uint256 public sink;

    /// @notice Chainlink's decimals view, answered honestly so the feed can be configured at all.
    /// @return value Always 8.
    function decimals() external pure returns (uint8 value) {
        return 8;
    }

    /// @notice Burns storage gas until the call runs out.
    /// @return roundId Never returned.
    /// @return answer Never returned.
    /// @return startedAt Never returned.
    /// @return updatedAt Never returned.
    /// @return answeredInRound Never returned.
    function latestRoundData()
        external
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        for (uint256 i = 0; i < 1_000_000; ++i) {
            sink = i;
        }
        return (1, 1e8, 1, 1, 1);
    }
}

/// @dev An aggregator with code whose `decimals()` reverts: `setFeed` must refuse it rather than record a guess.
contract NoDecimalsAggregator {
    error Nope();

    /// @notice Always reverts.
    /// @return Never returned.
    function decimals() external pure returns (uint8) {
        revert Nope();
    }
}

/// @notice Layer C: `FeedRegistry`'s probes, sanity rules, session-scaled freshness and two-confirmation rule.
contract FeedRegistryTest is OracleGateFixture {
    address internal constant TOKEN = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);

    /// @dev Monday 2026-03-09, 09:30 EDT: the regular session, so the freshness bound is live.
    uint256 internal constant MON_REGULAR = 1_773_063_000;

    /// @dev Saturday 2026-03-07, 12:00 EST: the market is closed and the check is disabled.
    uint256 internal constant SAT_CLOSED = 1_772_902_800;

    /// @dev Monday 2026-03-09, 04:00 EDT: the pre-market session.
    uint256 internal constant MON_PRE = 1_773_043_200;

    /// @dev Monday 2026-03-09, 03:59 EDT: the overnight session.
    uint256 internal constant MON_OVERNIGHT = 1_773_043_140;

    MockAggregator internal feed;

    function setUp() public {
        _deployGate();
        vm.warp(MON_REGULAR);
        feed = _installFeed(TOKEN, 180e8, Constants.ONE_DAY);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `setFeed` records the aggregator, reads its decimals from the contract itself and latches the first
    ///         accepted answer so the two-confirmation rule has a reference from block one.
    function test_setFeed_recordsAndLatches() public view {
        FeedConfig memory config = feeds.feedConfig(TOKEN);
        assertEq(config.aggregator, address(feed), "aggregator");
        assertEq(config.decimals, 8, "decimals read from the aggregator");
        assertTrue(config.set, "set");
        assertEq(config.heartbeat, Constants.ONE_DAY, "heartbeat");
        assertEq(feeds.feedOf(TOKEN), address(feed), "feedOf");

        FeedRegistry.Accepted memory accepted = feeds.acceptedAnswer(TOKEN);
        assertEq(accepted.answerUsd8, 180e8, "latched at configuration");
        assertEq(accepted.updatedAt, uint32(MON_REGULAR), "latched updatedAt");
    }

    /// @notice An aggregator that governance has not recorded as a Standard proxy is refused, and so is an
    ///         aggregator whose Standard-proxy record is later revoked.
    function test_setFeed_rejectsNonStandardProxy() public {
        MockAggregator svr = new MockAggregator("svr/usd", 8, 1e8);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.NotStandardProxy.selector, address(svr)));
        feeds.setFeed(OTHER, address(svr), _config(Constants.ONE_DAY));

        vm.prank(TIMELOCK);
        feeds.setStandardProxy(address(feed), false);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.NotStandardProxy.selector, address(feed)));
        feeds.configureFeed(TOKEN, Constants.ONE_DAY, 50, 1, type(uint128).max);
    }

    /// @notice A feed whose aggregator cannot be read at configuration time is refused outright: there is no
    ///         point recording a dead proxy.
    function test_setFeed_rejectsDeadAggregator() public {
        vm.prank(TIMELOCK);
        feeds.setStandardProxy(OTHER, true);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.FeedDead.selector, OTHER, OTHER));
        feeds.setFeed(OTHER, OTHER, _config(Constants.ONE_DAY));
    }

    /// @notice Decimals above 18 are refused; the rescale to the protocol's 8-decimal unit is only defined below
    ///         that.
    function test_setFeed_rejectsWideDecimals() public {
        MockAggregator wide = new MockAggregator("wide/usd", 27, 1e27);
        vm.startPrank(TIMELOCK);
        feeds.setStandardProxy(address(wide), true);
        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("feedDecimals"), uint256(27), 0, uint256(18))
        );
        feeds.setFeed(OTHER, address(wide), _config(Constants.ONE_DAY));
        vm.stopPrank();
    }

    /// @notice Zero addresses are refused on both sides.
    function test_setFeed_rejectsZeroAddresses() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(ZeroAddress.selector);
        feeds.setFeed(address(0), address(feed), _config(Constants.ONE_DAY));
        vm.expectRevert(ZeroAddress.selector);
        feeds.setFeed(OTHER, address(0), _config(Constants.ONE_DAY));
        vm.expectRevert(ZeroAddress.selector);
        feeds.setStandardProxy(address(0), true);
        vm.expectRevert(ZeroAddress.selector);
        feeds.setOracleGate(address(0));
        vm.stopPrank();
    }

    /// @notice Every band a feed record must satisfy, each naming its own parameter in the revert.
    function test_configureFeed_bands() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("heartbeat"),
                uint256(1),
                uint256(feeds.HEARTBEAT_SECONDS_MIN()),
                uint256(feeds.HEARTBEAT_SECONDS_MAX())
            )
        );
        feeds.configureFeed(TOKEN, 1, 50, 1, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("heartbeat"),
                uint256(Constants.ONE_DAY + 1),
                uint256(feeds.HEARTBEAT_SECONDS_MIN()),
                uint256(feeds.HEARTBEAT_SECONDS_MAX())
            )
        );
        feeds.configureFeed(TOKEN, Constants.ONE_DAY + 1, 50, 1, 2);

        vm.expectRevert(
            abi.encodeWithSelector(OutOfBand.selector, bytes32("thresholdBps"), uint256(0), uint256(1), Constants.BPS)
        );
        feeds.configureFeed(TOKEN, Constants.ONE_DAY, 0, 1, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector, bytes32("thresholdBps"), Constants.BPS + 1, uint256(1), Constants.BPS
            )
        );
        feeds.configureFeed(TOKEN, Constants.ONE_DAY, uint16(Constants.BPS + 1), 1, 2);

        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("minAnswerUsd8"), uint256(5), 0, uint256(0)));
        feeds.configureFeed(TOKEN, Constants.ONE_DAY, 50, 5, 0);

        vm.expectRevert(abi.encodeWithSelector(OutOfBand.selector, bytes32("minAnswerUsd8"), uint256(9), 0, uint256(8)));
        feeds.configureFeed(TOKEN, Constants.ONE_DAY, 50, 9, 9);
        vm.stopPrank();
    }

    /// @notice `configureFeed` needs a configured feed to configure.
    function test_configureFeed_requiresFeed() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.FeedNotSet.selector, OTHER));
        feeds.configureFeed(OTHER, Constants.ONE_DAY, 50, 1, 2);
    }

    /// @notice Every governed entry point is timelock-only.
    function test_governance_onlyTimelock() public {
        vm.startPrank(STRANGER);
        bytes memory expected = abi.encodeWithSelector(NotTimelock.selector, STRANGER);
        vm.expectRevert(expected);
        feeds.setFeed(TOKEN, address(feed), _config(Constants.ONE_DAY));
        vm.expectRevert(expected);
        feeds.configureFeed(TOKEN, Constants.ONE_DAY, 50, 1, 2);
        vm.expectRevert(expected);
        feeds.setFreshnessMultiplier(Session.REGULAR, 200);
        vm.expectRevert(expected);
        feeds.setStandardProxy(address(feed), true);
        vm.expectRevert(expected);
        feeds.setStandardProxies(new address[](0), new bool[](0));
        vm.expectRevert(expected);
        feeds.setConfirmSeconds(600);
        vm.expectRevert(expected);
        feeds.setOracleGate(address(gate));
        vm.stopPrank();
    }

    /// @notice The batch Standard-proxy setter is parallel and rejects zero addresses.
    function test_setStandardProxies() public {
        address[] memory aggregators = new address[](2);
        bool[] memory flags = new bool[](2);
        aggregators[0] = address(0xAAA1);
        aggregators[1] = address(0xAAA2);
        flags[0] = true;
        flags[1] = false;

        vm.startPrank(TIMELOCK);
        vm.expectRevert(LengthMismatch.selector);
        feeds.setStandardProxies(aggregators, new bool[](1));

        feeds.setStandardProxies(aggregators, flags);
        assertTrue(feeds.isStandardProxy(address(0xAAA1)), "first recorded");
        assertFalse(feeds.isStandardProxy(address(0xAAA2)), "second cleared");

        aggregators[0] = address(0);
        vm.expectRevert(ZeroAddress.selector);
        feeds.setStandardProxies(aggregators, flags);
        vm.stopPrank();
    }

    /// @notice Freshness multipliers live inside their hard band and read back per session.
    function test_setFreshnessMultiplier() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("freshnessMultiplier"),
                uint256(99),
                uint256(Constants.FRESHNESS_MULTIPLIER_MIN),
                uint256(Constants.FRESHNESS_MULTIPLIER_MAX)
            )
        );
        feeds.setFreshnessMultiplier(Session.REGULAR, 99);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("freshnessMultiplier"),
                uint256(Constants.FRESHNESS_MULTIPLIER_MAX + 1),
                uint256(Constants.FRESHNESS_MULTIPLIER_MIN),
                uint256(Constants.FRESHNESS_MULTIPLIER_MAX)
            )
        );
        feeds.setFreshnessMultiplier(Session.REGULAR, Constants.FRESHNESS_MULTIPLIER_MAX + 1);

        feeds.setFreshnessMultiplier(Session.REGULAR, 200);
        feeds.setFreshnessMultiplier(Session.PRE_POST, 400);
        feeds.setFreshnessMultiplier(Session.OVERNIGHT, 700);
        feeds.setFreshnessMultiplier(Session.CLOSED, 100);
        vm.stopPrank();

        assertEq(feeds.freshnessMultiplier(Session.REGULAR), 200, "regular");
        assertEq(feeds.freshnessMultiplier(Session.PRE_POST), 400, "pre/post");
        assertEq(feeds.freshnessMultiplier(Session.OVERNIGHT), 700, "overnight");
        assertEq(feeds.freshnessMultiplier(Session.CLOSED), 100, "closed, recorded but unread");
    }

    /// @notice `confirmSeconds` lives inside its band.
    function test_setConfirmSeconds() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutOfBand.selector,
                bytes32("confirmSeconds"),
                uint256(1),
                uint256(feeds.CONFIRM_SECONDS_MIN()),
                uint256(feeds.CONFIRM_SECONDS_MAX())
            )
        );
        feeds.setConfirmSeconds(1);
        feeds.setConfirmSeconds(600);
        vm.stopPrank();
        assertEq(feeds.confirmSeconds(), 600, "set");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Session-scaled freshness
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `maxAge = heartbeat x multiplier / 100`, and no bound at all when the market is closed.
    function test_maxAge_scalesWithSession() public view {
        assertEq(feeds.maxAge(TOKEN, Session.REGULAR), (Constants.ONE_DAY * 150) / 100, "1.5x regular");
        assertEq(feeds.maxAge(TOKEN, Session.PRE_POST), (Constants.ONE_DAY * 300) / 100, "3x pre/post");
        assertEq(feeds.maxAge(TOKEN, Session.OVERNIGHT), (Constants.ONE_DAY * 600) / 100, "6x overnight");
        assertEq(feeds.maxAge(TOKEN, Session.CLOSED), type(uint32).max, "disabled when closed");
    }

    /// @notice An answer that is stale in the regular session is not stale over a closed weekend: a closed
    ///         market's held answer is correct, not stale, which is what keeps the bond market open through it.
    function test_freshness_closedSessionDisablesTheCheck() public {
        vm.warp(MON_REGULAR + (Constants.ONE_DAY * 150) / 100 + 1);
        (uint256 answer,, bool fresh) = feeds.latestAnswerIn(TOKEN, Session.REGULAR);
        assertEq(answer, 180e8, "the answer is still readable");
        assertFalse(fresh, "past 1.5 heartbeats in the regular session");

        (,, fresh) = feeds.latestAnswerIn(TOKEN, Session.OVERNIGHT);
        assertTrue(fresh, "still inside 6 heartbeats overnight");

        (,, fresh) = feeds.latestAnswerIn(TOKEN, Session.CLOSED);
        assertTrue(fresh, "the check is disabled when closed");
    }

    /// @notice The session comes from the gate's calendar when the caller does not supply one.
    function test_freshness_sessionComesFromTheGate() public {
        vm.prank(TIMELOCK);
        feeds.configureFeed(TOKEN, 300, 50, 1, type(uint128).max);
        vm.warp(MON_REGULAR + 451);
        (,, bool fresh) = feeds.latestAnswer(TOKEN);
        assertFalse(fresh, "the gate reports a session with a live bound");
        assertEq(uint8(feeds.sessionNow()), uint8(gate.sessionNow()), "the same session the gate reports");

        vm.warp(SAT_CLOSED);
        assertEq(uint8(feeds.sessionNow()), uint8(Session.CLOSED), "weekend");
        feed.setUpdatedAt(SAT_CLOSED - 10 * Constants.ONE_DAY);
        (,, fresh) = feeds.latestAnswer(TOKEN);
        assertTrue(fresh, "a ten-day-old answer is fine over a closed weekend");
    }

    /// @notice With no gate configured, or an unreadable one, the registry falls back to the tightest session
    ///         rather than the loosest.
    function test_freshness_unreadableGateFallsBackToRegular() public {
        FeedRegistry bare = new FeedRegistry(TIMELOCK, address(0));
        assertEq(uint8(bare.sessionNow()), uint8(Session.REGULAR), "no gate");

        vm.prank(TIMELOCK);
        feeds.setOracleGate(address(0xDEAD1));
        assertEq(uint8(feeds.sessionNow()), uint8(Session.REGULAR), "codeless gate");

        vm.prank(TIMELOCK);
        feeds.setOracleGate(address(feed)); // a contract that has no `sessionNow()`
        assertEq(uint8(feeds.sessionNow()), uint8(Session.REGULAR), "gate that cannot answer");
    }

    /// @notice The 24/7 bond decision, end to end: a weekend-frozen feed still prices, and pre/post and overnight
    ///         each get their own bound.
    function test_freshness_perSessionBounds() public {
        uint32 heartbeat = Constants.ONE_DAY;
        vm.warp(MON_PRE);
        feed.setAnswer(180e8);
        vm.warp(MON_PRE + (heartbeat * 300) / 100);
        (,, bool fresh) = feeds.latestAnswerIn(TOKEN, Session.PRE_POST);
        assertTrue(fresh, "exactly on the pre/post bound is fresh");
        vm.warp(MON_PRE + (heartbeat * 300) / 100 + 1);
        (,, fresh) = feeds.latestAnswerIn(TOKEN, Session.PRE_POST);
        assertFalse(fresh, "one second past is not");
        assertEq(uint8(gate.sessionAt(MON_OVERNIGHT)), uint8(Session.OVERNIGHT), "the overnight fixture is overnight");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Sanity rules
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A non-positive answer, a zero `updatedAt` and a future `updatedAt` are all rejected, and the
    ///         previously latched answer stands.
    function test_sanity_invalidAnswers() public {
        feed.setRoundData(9, -1, block.timestamp, block.timestamp);
        FeedStatus memory status = feeds.feedStatus(TOKEN);
        assertFalse(status.live, "negative answer is not live");
        assertEq(status.answerUsd8, 180e8, "the latched answer stands");
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.InvalidAnswer.selector, TOKEN, int256(-1)));
        feeds.priceUsd8(TOKEN);

        feed.setRoundData(10, 190e8, block.timestamp, 0);
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.InvalidAnswer.selector, TOKEN, int256(190e8)));
        feeds.priceUsd8(TOKEN);

        feed.setRoundData(11, 190e8, block.timestamp, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.InvalidAnswer.selector, TOKEN, int256(190e8)));
        feeds.priceUsd8(TOKEN);
    }

    /// @notice The per-ticker bounds catch an aggregator returning its own circuit-breaker floor or ceiling.
    function test_sanity_perTickerBounds() public {
        vm.prank(TIMELOCK);
        feeds.configureFeed(TOKEN, Constants.ONE_DAY, 50, 100e8, 300e8);

        feed.setAnswer(1e8);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFeedRegistry.AnswerOutOfBounds.selector, TOKEN, uint256(1e8), uint128(100e8), uint128(300e8)
            )
        );
        feeds.priceUsd8(TOKEN);
        assertEq(feeds.feedStatus(TOKEN).answerUsd8, 180e8, "the latched answer stands through it");

        feed.setAnswer(400e8);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFeedRegistry.AnswerOutOfBounds.selector, TOKEN, uint256(400e8), uint128(100e8), uint128(300e8)
            )
        );
        feeds.priceUsd8(TOKEN);
    }

    /// @notice An answer larger than `uint128` is out of bounds by construction, before any rescale can overflow.
    function test_sanity_absurdlyLargeAnswer() public {
        feed.setAnswer(type(int256).max);
        FeedStatus memory status = feeds.feedStatus(TOKEN);
        assertFalse(status.live, "not live");
        assertEq(status.answerUsd8, 180e8, "the latched answer stands");
    }

    /// @notice Feeds that do not answer with 8 decimals are rescaled, rounding down.
    function test_sanity_decimalRescale() public {
        MockAggregator eighteen = new MockAggregator("eighteen/usd", 18, 180_123_456_789_012_345_678);
        MockAggregator six = new MockAggregator("six/usd", 6, 180_123_456);
        vm.startPrank(TIMELOCK);
        feeds.setStandardProxy(address(eighteen), true);
        feeds.setStandardProxy(address(six), true);
        feeds.setFeed(OTHER, address(eighteen), _config(Constants.ONE_DAY));
        feeds.setFeed(address(0xC0FFEE), address(six), _config(Constants.ONE_DAY));
        vm.stopPrank();

        assertEq(feeds.priceUsd8(OTHER), 18_012_345_678, "18 decimals scaled down, floored");
        assertEq(feeds.priceUsd8(address(0xC0FFEE)), 18_012_345_600, "6 decimals scaled up");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Dead feeds
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A reverting aggregator is reported dead, not bubbled: the latched answer stands and ages out.
    function test_dead_revertingAggregator() public {
        // A 300 s heartbeat keeps the whole test inside one regular session, so the freshness bound that expires
        // is the regular one rather than the six-times-looser overnight one.
        vm.prank(TIMELOCK);
        feeds.configureFeed(TOKEN, 300, 50, 1, type(uint128).max);
        feed.setRevert(true);
        FeedStatus memory status = feeds.feedStatus(TOKEN);
        assertFalse(status.live, "not live");
        assertTrue(status.configured, "still configured");
        assertEq(status.answerUsd8, 180e8, "the latched answer stands");
        assertTrue(status.fresh, "and is still fresh right now");

        vm.warp(block.timestamp + 451);
        assertEq(uint8(feeds.sessionNow()), uint8(Session.REGULAR), "still the regular session");
        assertFalse(feeds.feedStatus(TOKEN).fresh, "until it ages out");
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.FeedDead.selector, TOKEN, address(feed)));
        feeds.priceUsd8(TOKEN);
    }

    /// @notice A self-destructed or never-deployed aggregator answers a `staticcall` with no data at all; the
    ///         code-size check is what turns that into "dead" instead of a decode revert.
    function test_dead_codelessAggregator() public {
        vm.etch(address(feed), "");
        FeedStatus memory status = feeds.feedStatus(TOKEN);
        assertFalse(status.live, "codeless is dead");
        assertEq(status.answerUsd8, 180e8, "the latched answer stands");
    }

    /// @notice A feed that burns every wei of gas it is given cannot grief the caller: the probe is capped, so the
    ///         read returns and the transaction survives.
    function test_dead_gasBurningAggregator() public {
        GasBurningAggregator burner = new GasBurningAggregator();
        vm.startPrank(TIMELOCK);
        feeds.setStandardProxy(address(burner), true);
        feeds.setFeed(OTHER, address(burner), _config(Constants.ONE_DAY));
        vm.stopPrank();

        uint256 gasBefore = gasleft();
        FeedStatus memory status = feeds.feedStatus(OTHER);
        uint256 spent = gasBefore - gasleft();
        assertFalse(status.live, "the burner is dead");
        assertEq(status.answerUsd8, 0, "and nothing was ever latched");
        assertLt(spent, 10 * feeds.FEED_PROBE_GAS(), "the probe stayed bounded");
    }

    /// @notice An aggregator whose `decimals()` reverts is refused: a recorded guess at the scale of an answer is
    ///         worse than no feed.
    function test_dead_aggregatorWithoutDecimals() public {
        NoDecimalsAggregator broken = new NoDecimalsAggregator();
        vm.startPrank(TIMELOCK);
        feeds.setStandardProxy(address(broken), true);
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.FeedDead.selector, OTHER, address(broken)));
        feeds.setFeed(OTHER, address(broken), _config(Constants.ONE_DAY));
        vm.stopPrank();
    }

    /// @notice An answer that rounds to nothing at the protocol's 8-decimal scale is rejected as invalid rather
    ///         than adopted as zero.
    function test_sanity_answerThatRoundsToZero() public {
        MockAggregator dust = new MockAggregator("dust/usd", 18, 1);
        vm.startPrank(TIMELOCK);
        feeds.setStandardProxy(address(dust), true);
        feeds.setFeed(
            OTHER,
            address(dust),
            FeedConfig({
                aggregator: address(0),
                decimals: 0,
                set: false,
                heartbeat: Constants.ONE_DAY,
                thresholdBps: 50,
                minAnswerUsd8: 0,
                maxAnswerUsd8: type(uint128).max
            })
        );
        vm.stopPrank();
        assertEq(feeds.acceptedAnswer(OTHER).answerUsd8, 0, "nothing latched");
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.InvalidAnswer.selector, OTHER, int256(1)));
        feeds.priceUsd8(OTHER);
    }

    /// @notice A deployment helper reached through an external call, so `vm.expectRevert` swallows a reverting
    ///         constructor instead of ending the test at it.
    /// @param timelock_ The governor to deploy with.
    /// @return deployed The new registry.
    function deployRegistry(address timelock_) external returns (address deployed) {
        return address(new FeedRegistry(timelock_, address(gate)));
    }

    /// @notice The constructor refuses a governor-less registry.
    function test_constructor_rejectsZeroTimelock() public {
        vm.expectRevert(ZeroAddress.selector);
        this.deployRegistry(address(0));
        assertGt(this.deployRegistry(TIMELOCK).code.length, 0, "and accepts a real one");
    }

    /// @notice The constant getters read their bands.
    function test_bandGetters() public view {
        assertEq(feeds.timelock(), TIMELOCK, "timelock");
        assertEq(feeds.oracleGate(), address(gate), "gate");
        assertEq(feeds.FRESHNESS_MULTIPLIER_MIN(), Constants.FRESHNESS_MULTIPLIER_MIN, "multiplier min");
        assertEq(feeds.FRESHNESS_MULTIPLIER_MAX(), Constants.FRESHNESS_MULTIPLIER_MAX, "multiplier max");
        assertEq(feeds.ANSWER_JUMP_BPS(), Constants.ANSWER_JUMP_BPS, "jump threshold");
        assertEq(feeds.CONFIRM_SECONDS_MIN(), Constants.ANSWER_CONFIRM_SECONDS_MIN, "confirm min");
        assertEq(feeds.CONFIRM_SECONDS_MAX(), Constants.ANSWER_CONFIRM_SECONDS_MAX, "confirm max");
        assertEq(feeds.HEARTBEAT_SECONDS_MIN(), Constants.FEED_HEARTBEAT_SECONDS_MIN, "heartbeat min");
        assertEq(feeds.HEARTBEAT_SECONDS_MAX(), Constants.FEED_HEARTBEAT_SECONDS_MAX, "heartbeat max");
        assertEq(feeds.FEED_PROBE_GAS(), Constants.STOCK_TOKEN_PROBE_GAS, "probe gas");
        assertEq(feeds.SESSION_PROBE_GAS(), 4 * Constants.STOCK_TOKEN_PROBE_GAS, "session probe gas");
        assertEq(feeds.FEED_DECIMALS_MAX(), 18, "decimals ceiling");
    }

    /// @notice A token with no feed at all reads as an all-zero status and reverts only where the interface says
    ///         it must.
    function test_dead_unconfiguredToken() public {
        FeedStatus memory status = feeds.feedStatus(OTHER);
        assertFalse(status.configured, "not configured");
        assertEq(status.answerUsd8, 0, "no answer");
        assertFalse(status.fresh, "not fresh");
        assertEq(feeds.feedOf(OTHER), address(0), "no aggregator");

        (uint256 answer, uint32 updatedAt, bool fresh) = feeds.latestAnswer(OTHER);
        assertEq(answer, 0, "latestAnswer never reverts");
        assertEq(updatedAt, 0, "no timestamp");
        assertFalse(fresh, "not fresh");

        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.FeedNotSet.selector, OTHER));
        feeds.priceUsd8(OTHER);
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.FeedNotSet.selector, OTHER));
        feeds.refresh(OTHER);
    }

    /// @notice With nothing ever latched and a dead aggregator, `priceUsd8` reports the specific failure and
    ///         `latestAnswer` reports "no usable answer".
    function test_dead_neverLatched() public {
        MockAggregator fresh_ = new MockAggregator("fresh/usd", 8, 1e8);
        // `decimals()` still answers, so the feed configures; the round views do not, so nothing is ever latched.
        fresh_.setRevert(true);
        vm.startPrank(TIMELOCK);
        feeds.setStandardProxy(address(fresh_), true);
        feeds.setFeed(OTHER, address(fresh_), _config(Constants.ONE_DAY));
        vm.stopPrank();
        assertEq(feeds.acceptedAnswer(OTHER).answerUsd8, 0, "nothing latched");

        (uint256 answer,, bool isFresh) = feeds.latestAnswer(OTHER);
        assertEq(answer, 0, "no usable answer");
        assertFalse(isFresh, "and not fresh");
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.FeedDead.selector, OTHER, address(fresh_)));
        feeds.priceUsd8(OTHER);
    }

    // -------------------------------------------------------------------------------------------------------------
    // The two-confirmation rule
    // -------------------------------------------------------------------------------------------------------------

    /// @notice A move at the threshold is adopted; a move past it is held, and the accepted answer keeps standing
    ///         with its own `updatedAt` so ordinary freshness decides what happens next.
    function test_jump_heldPendingConfirmation() public {
        vm.warp(MON_REGULAR + 60);
        feed.setAnswer(198e8); // exactly +10%, at the threshold, not past it
        assertEq(feeds.feedStatus(TOKEN).answerUsd8, 198e8, "a move at the threshold is not a jump");

        feeds.refresh(TOKEN);
        vm.warp(block.timestamp + 60);
        feed.setAnswer(240e8); // +21%, a jump
        FeedStatus memory status = feeds.feedStatus(TOKEN);
        assertTrue(status.unconfirmed, "held back");
        assertEq(status.answerUsd8, 198e8, "the accepted answer stands");
        assertEq(status.updatedAt, uint32(MON_REGULAR + 60), "with its own timestamp, so it ages normally");

        vm.expectEmit(true, false, false, true, address(feeds));
        emit IFeedRegistry.AnswerJumpPending(TOKEN, 198e8, 240e8, 3);
        feeds.refresh(TOKEN);

        FeedRegistry.Pending memory pending = feeds.pendingAnswer(TOKEN);
        assertEq(pending.answerUsd8, 240e8, "recorded");
        assertEq(pending.seenAt, uint32(block.timestamp), "stamped");
    }

    /// @notice A second round that agrees with the pending level confirms the jump.
    function test_jump_confirmedBySecondRound() public {
        vm.warp(MON_REGULAR + 60);
        feed.setAnswer(240e8);
        feeds.refresh(TOKEN);
        assertTrue(feeds.feedStatus(TOKEN).unconfirmed, "pending");

        vm.warp(block.timestamp + 60);
        feed.setAnswer(241e8); // a later round, within 10% of the pending level
        FeedStatus memory status = feeds.feedStatus(TOKEN);
        assertFalse(status.unconfirmed, "confirmed");
        assertEq(status.answerUsd8, 241e8, "the new level is adopted");

        feeds.refresh(TOKEN);
        assertEq(feeds.acceptedAnswer(TOKEN).answerUsd8, 241e8, "and latched");
        assertEq(feeds.pendingAnswer(TOKEN).roundId, 0, "the pending record is cleared");
    }

    /// @notice A second round that disagrees with the pending level does not confirm it; the pending record moves
    ///         to the newer round instead.
    function test_jump_secondRoundDisagreeing() public {
        vm.warp(MON_REGULAR + 60);
        feed.setAnswer(240e8);
        feeds.refresh(TOKEN);

        vm.warp(block.timestamp + 60);
        feed.setAnswer(400e8); // a different jump again
        assertTrue(feeds.feedStatus(TOKEN).unconfirmed, "still held");
        feeds.refresh(TOKEN);
        assertEq(feeds.pendingAnswer(TOKEN).answerUsd8, 400e8, "the pending record follows the newest round");
        assertEq(feeds.acceptedAnswer(TOKEN).answerUsd8, 180e8, "the accepted answer has not moved");
    }

    /// @notice A real move must not be held back for ever by an aggregator that stops publishing: after
    ///         `confirmSeconds` the pending answer is adopted with no second round.
    function test_jump_confirmedByElapse() public {
        vm.warp(MON_REGULAR + 60);
        feed.setAnswer(240e8);
        feeds.refresh(TOKEN);
        assertTrue(feeds.feedStatus(TOKEN).unconfirmed, "pending");

        vm.warp(block.timestamp + feeds.confirmSeconds() - 1);
        assertTrue(feeds.feedStatus(TOKEN).unconfirmed, "one second short");

        vm.warp(block.timestamp + 1);
        FeedStatus memory status = feeds.feedStatus(TOKEN);
        assertFalse(status.unconfirmed, "adopted on elapse");
        assertEq(status.answerUsd8, 240e8, "the jump wins");
    }

    /// @notice Two rounds more than a heartbeat apart are not a single-round move, so ordinary drift after a
    ///         quiet stretch is never mistaken for a jump.
    function test_jump_notArmedAcrossAHeartbeat() public {
        vm.warp(MON_REGULAR + Constants.ONE_DAY + 1);
        feed.setAnswer(400e8); // +122% but a day and a second later
        FeedStatus memory status = feeds.feedStatus(TOKEN);
        assertFalse(status.unconfirmed, "not a single-round move");
        assertEq(status.answerUsd8, 400e8, "adopted directly");
    }

    /// @notice A downward jump is held exactly like an upward one.
    function test_jump_downwardIsSymmetric() public {
        vm.warp(MON_REGULAR + 60);
        feed.setAnswer(100e8); // -44%
        assertTrue(feeds.feedStatus(TOKEN).unconfirmed, "held");
        assertEq(feeds.feedStatus(TOKEN).answerUsd8, 180e8, "the accepted answer stands");
    }

    /// @notice With nothing latched there is nothing to jump from, so the first answer is always adopted and the
    ///         rule can never block bootstrapping.
    function test_jump_bootstrapIsNeverHeld() public {
        MockAggregator fresh_ = new MockAggregator("boot/usd", 8, 1e8);
        fresh_.setRevert(true);
        vm.startPrank(TIMELOCK);
        feeds.setStandardProxy(address(fresh_), true);
        feeds.setFeed(OTHER, address(fresh_), _config(Constants.ONE_DAY));
        vm.stopPrank();
        assertEq(feeds.acceptedAnswer(OTHER).answerUsd8, 0, "nothing latched, the aggregator was down");

        fresh_.setRevert(false);
        fresh_.setAnswer(500e8);
        assertEq(feeds.feedStatus(OTHER).answerUsd8, 500e8, "adopted with no confirmation");
    }

    /// @notice Replacing a feed drops both the accepted answer and any jump held against it: the new proxy is a
    ///         different series and must not be measured against the old one's level.
    function test_jump_setFeedClearsTheLatch() public {
        vm.warp(MON_REGULAR + 60);
        feed.setAnswer(240e8);
        feeds.refresh(TOKEN);
        assertEq(feeds.pendingAnswer(TOKEN).answerUsd8, 240e8, "pending");

        MockAggregator replacement = new MockAggregator("repl/usd", 8, 1e8);
        vm.startPrank(TIMELOCK);
        feeds.setStandardProxy(address(replacement), true);
        feeds.setFeed(TOKEN, address(replacement), _config(Constants.ONE_DAY));
        vm.stopPrank();

        assertEq(feeds.pendingAnswer(TOKEN).roundId, 0, "pending cleared");
        assertEq(feeds.acceptedAnswer(TOKEN).answerUsd8, 1e8, "re-latched from the new proxy");
    }

    /// @notice `refresh` never reverts for a feed reason and leaves the latch alone when the round is unusable.
    function test_refresh_toleratesDeadFeeds() public {
        feed.setRevert(true);
        (uint256 answer,, bool fresh) = feeds.refresh(TOKEN);
        assertEq(answer, 180e8, "the latched answer is what comes back");
        assertTrue(fresh, "still inside the bound");
        assertEq(feeds.acceptedAnswer(TOKEN).answerUsd8, 180e8, "untouched");

        address[] memory tokens = new address[](2);
        tokens[0] = TOKEN;
        tokens[1] = OTHER; // no feed configured: skipped rather than reverting
        feeds.refreshMany(tokens);
    }

    /// @notice Re-reading the same round changes nothing.
    function test_refresh_sameRoundIsANoop() public {
        feeds.refresh(TOKEN);
        FeedRegistry.Accepted memory before = feeds.acceptedAnswer(TOKEN);
        vm.warp(block.timestamp + 10);
        feeds.refresh(TOKEN);
        FeedRegistry.Accepted memory afterCall = feeds.acceptedAnswer(TOKEN);
        assertEq(afterCall.roundId, before.roundId, "same round");
        assertEq(afterCall.updatedAt, before.updatedAt, "same timestamp");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Price helpers
    // -------------------------------------------------------------------------------------------------------------

    /// @notice `priceUsd8` reverts on staleness where `latestAnswer` reports it, which is the whole per-path
    ///         staleness policy in two functions.
    function test_priceUsd8_revertsOnStaleness() public {
        vm.prank(TIMELOCK);
        feeds.configureFeed(TOKEN, 300, 50, 1, type(uint128).max);
        uint32 bound_ = feeds.maxAge(TOKEN, Session.REGULAR);
        vm.warp(MON_REGULAR + bound_ + 1);
        assertEq(uint8(feeds.sessionNow()), uint8(Session.REGULAR), "still the regular session");
        vm.expectRevert(abi.encodeWithSelector(IFeedRegistry.StaleAnswer.selector, TOKEN, uint32(bound_ + 1), bound_));
        feeds.priceUsd8(TOKEN);

        (uint256 answer,, bool fresh) = feeds.latestAnswer(TOKEN);
        assertEq(answer, 180e8, "latestAnswer still answers");
        assertFalse(fresh, "and says it is stale");
    }

    /// @notice The 18-decimal helpers agree with the 8-decimal ones.
    function test_priceUsd18() public view {
        assertEq(feeds.priceUsd8(TOKEN), 180e8, "usd8");
        assertEq(feeds.priceUsd18(TOKEN), 180e18, "usd18");
        (uint256 price18,, bool fresh) = feeds.latestAnswerUsd18(TOKEN);
        assertEq(price18, 180e18, "latestAnswerUsd18");
        assertTrue(fresh, "fresh");
    }

    /// @notice `latestAnswerUsd18` reports zero rather than reverting when nothing is readable.
    function test_priceUsd18_unconfigured() public view {
        (uint256 price18, uint32 updatedAt, bool fresh) = feeds.latestAnswerUsd18(OTHER);
        assertEq(price18, 0, "zero");
        assertEq(updatedAt, 0, "no timestamp");
        assertFalse(fresh, "not fresh");
    }

    /// @notice `feedStatusIn` is `feedStatus` against a caller-supplied session.
    function test_feedStatusIn() public {
        vm.warp(MON_REGULAR + (Constants.ONE_DAY * 150) / 100 + 1);
        assertFalse(feeds.feedStatusIn(TOKEN, Session.REGULAR).fresh, "stale in the regular session");
        assertTrue(feeds.feedStatusIn(TOKEN, Session.CLOSED).fresh, "not stale when closed");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Properties
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Whatever the aggregator does, the registry never reverts on the degraded read, never returns an
    ///         answer outside the configured bounds, and never reports a zero answer as fresh.
    /// @param rawAnswer An arbitrary aggregator answer.
    /// @param updatedAt An arbitrary publication timestamp.
    /// @param warpBy How far to advance the clock first.
    /// @param sessionSeed Which session to judge freshness in.
    function testFuzz_feedStatusIsTotal(int256 rawAnswer, uint32 updatedAt, uint32 warpBy, uint8 sessionSeed) public {
        Session session = Session(bound(sessionSeed, 0, uint8(Session.CLOSED)));
        vm.warp(MON_REGULAR + bound(warpBy, 0, 30 days));
        vm.prank(TIMELOCK);
        feeds.configureFeed(TOKEN, Constants.ONE_DAY, 50, 50e8, 500e8);
        feed.setRoundData(7, rawAnswer, updatedAt, updatedAt);

        FeedStatus memory status = feeds.feedStatusIn(TOKEN, session);
        assertTrue(status.configured, "configured");
        if (status.answerUsd8 != 0) {
            assertGe(status.answerUsd8, 50e8, "never below the lower bound");
            assertLe(status.answerUsd8, 500e8, "never above the upper bound");
        } else {
            assertFalse(status.fresh, "a missing answer is never fresh");
        }
        if (status.live) assertFalse(status.unconfirmed, "live and unconfirmed are exclusive readings");
    }

    /* --------------------------------------------------------------------------------------------------------- */

    /// @dev A feed config with only the fields `setFeed` actually reads populated.
    function _config(uint32 heartbeat) internal pure returns (FeedConfig memory config) {
        return FeedConfig({
            aggregator: address(0),
            decimals: 0,
            set: false,
            heartbeat: heartbeat,
            thresholdBps: 50,
            minAnswerUsd8: 1,
            maxAnswerUsd8: type(uint128).max
        });
    }
}
