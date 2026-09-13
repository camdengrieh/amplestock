// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {IFeedRegistry} from "../../../src/interfaces/IFeedRegistry.sol";
import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with `FeedRegistry`, the permissionless answer latch in front of Chainlink.
///
/// @dev **Both entry points are permissionless and are called as an actor.** `refresh` is the only way an accepted
///      answer ever moves: a jump larger than `ANSWER_JUMP_BPS` is held back as `Pending` and needs a *second*
///      `refresh` a confirmation window later to latch, so the interesting behaviour needs the same token refreshed
///      twice with a warp in between — which is why the token choice is a seed rather than a fixed pick.
///
/// @dev **One token is the witness for SP-55 and SP-56.** `refreshMany` touches every configured token, so a
///      before/after of all thirty-two would be the dispatcher's whole gas budget. The two identities are
///      per-token, so a violation on any of them is reachable through the witness the seed picks.
abstract contract FeedRegistryHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice The registry's secondary surface: one token, or every token at once.
    /// @param selector Chooses the action.
    /// @param seed Chooses the token.
    function feedRegistry_secondary(uint8 selector, uint256 seed) public {
        ghosts.navClass = NAV_CLASS_MANAGEMENT;
        snapshotBefore();

        address[] memory tokens = feedTokens();
        address witness = tokens[seed % tokens.length];
        uint256 supplyBefore = amps.totalSupply();
        (uint128 answerBefore,, uint80 roundBefore) = _accepted(witness);

        selector = uint8(selector % 3);
        if (selector == 0) _feedRegistry_refresh(seed);
        else if (selector == 1) _feedRegistry_refreshMany();
        else _feedRegistry_refreshUnknown(seed);

        snapshotAfter();

        (uint128 answerAfter,, uint80 roundAfter) = _accepted(witness);

        // SP-01, SP-55 and SP-56.
        property_mintAttribution(supplyBefore, amps.totalSupply(), 0);
        property_acceptedAnswerAdvancesTheRound(answerBefore, answerAfter, roundBefore, roundAfter);
        property_latchClearsPending(roundBefore, roundAfter, _pendingRound(witness));
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    /// @dev One configured token: WETH, USDG or a stock.
    function _feedRegistry_refresh(uint256 tokenSeed) internal asActor {
        address[] memory tokens = feedTokens();
        feeds.refresh(tokens[tokenSeed % tokens.length]);
    }

    /// @dev Every configured token in one call. `refreshMany` skips tokens with no feed rather than reverting, so
    ///      this is also the shape that proves the skip.
    function _feedRegistry_refreshMany() internal asActor {
        feeds.refreshMany(feedTokens());
    }

    /// @dev An address with no feed, which must revert `FeedNotSet` on the single-token path.
    function _feedRegistry_refreshUnknown(uint256 seed) internal asActor {
        feeds.refresh(address(uint160(seed | 1)));
    }

    // ―――――――――――――――― Reads that must not revert ――――――――――――――――

    /// @dev The accepted answer's three fields, or zeros.
    function _accepted(address token) private view returns (uint128 answerUsd8, uint32 updatedAt, uint80 roundId) {
        try feeds.acceptedAnswer(token) returns (IFeedRegistry.Accepted memory a) {
            return (a.answerUsd8, a.updatedAt, a.roundId);
        } catch {
            return (0, 0, 0);
        }
    }

    /// @dev The pending candidate's round, or zero.
    function _pendingRound(address token) private view returns (uint80 roundId) {
        try feeds.pendingAnswer(token) returns (IFeedRegistry.Pending memory p) {
            return p.roundId;
        } catch {
            return 0;
        }
    }
}
